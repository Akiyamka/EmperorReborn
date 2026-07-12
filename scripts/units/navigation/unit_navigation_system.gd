class_name UnitNavigationSystem
extends Node
## Match-scoped RTS navigation coordinator. It owns path work, destination
## assignment and local collision resolution; Unit remains presentation and
## terrain-following code.

const UnitNavigationMapScript := preload("res://scripts/units/navigation/unit_navigation_map.gd")
const UnitNavigationPlannerScript := preload("res://scripts/units/navigation/unit_navigation_planner.gd")

signal destination_slots_assigned(command_id: int, assignments: Array[Dictionary])
signal enemy_blocked(unit: Node3D, blockers: Array[Node3D])

enum MoveMode { FREE, FORMATION }

const NAVIGATION_TICK_RATE := 20.0
const BLOCKER_REFRESH_SECONDS := 0.5
const ENEMY_BLOCK_SECONDS := 0.4
const FRIENDLY_YIELD_SECONDS := 0.8
const FRIENDLY_YIELD_TRIGGER_SECONDS := 0.2
const CELL_BUCKET_SIZE := 4.0
const OCCUPY_CELL_SPAN := 4
const SLOT_SEARCH_RADIUS := 32
const CANDIDATE_ANGLES := [0.0, 0.45, -0.45, 0.9, -0.9, 1.35, -1.35, PI]

var runtime_map = UnitNavigationMapScript.new()
var planner = UnitNavigationPlannerScript.new()

var _agents: Dictionary = {}
var _next_agent_id := 1
var _next_command_id := 1
var _navigation_tick_index := 0
var _navigation_accumulator := 0.0
var _blocker_refresh_remaining := 0.0
var _command_log: Array[Dictionary] = []


func _ready() -> void:
	if not get_tree().node_added.is_connected(_on_tree_node_added):
		get_tree().node_added.connect(_on_tree_node_added)


func _exit_tree() -> void:
	if get_tree() != null and get_tree().node_added.is_connected(_on_tree_node_added):
		get_tree().node_added.disconnect(_on_tree_node_added)


func setup(source_grid: MapNavigationGrid) -> bool:
	if not runtime_map.setup(source_grid):
		push_error("UnitNavigationSystem: navigation grid is unavailable")
		return false
	planner.setup(runtime_map)
	_refresh_building_blockers()
	if is_inside_tree():
		for node in get_tree().get_nodes_in_group("units"):
			if node is Node3D and _owns_node(node):
				register_unit(node)
	return true


func register_unit(unit: Node3D) -> int:
	if unit == null:
		return 0
	var key := unit.get_instance_id()
	if _agents.has(key):
		return int(_agents[key]["id"])
	var profile := _profile_for(unit)
	var agent := {
		"id": _next_agent_id,
		"unit": unit,
		"radius": profile["radius"],
		"pass_mask": profile["pass_mask"],
		"terrain_mask": profile["terrain_mask"],
		"clearance": profile["clearance"],
		"path": [] as Array[Vector2i],
		"path_index": 0,
		"destination": unit.global_position,
		"original_destination": unit.global_position,
		"command_id": 0,
		"mode": MoveMode.FREE,
		"group_speed": INF,
		"hold": false,
		"blocked_time": 0.0,
		"reported_enemy": false,
		"yield_direction": Vector3.ZERO,
		"yield_remaining": 0.0,
		"was_displaced": false,
		"direct_path": false,
	}
	_agents[key] = agent
	_next_agent_id += 1
	planner.prewarm(int(profile["pass_mask"]), int(profile["clearance"]), int(profile["terrain_mask"]))
	unit.set_meta(&"navigation_agent_id", agent["id"])
	if unit.has_method("set_navigation_managed"):
		unit.call("set_navigation_managed", true)
	if unit.has_method("set_navigation_controller"):
		unit.call("set_navigation_controller", self)
	return int(agent["id"])


func unregister_unit(unit: Node3D) -> void:
	if unit == null:
		return
	_agents.erase(unit.get_instance_id())


func set_hold_position(unit: Node3D, active: bool) -> void:
	var agent: Dictionary = _agent_for(unit)
	if agent.is_empty():
		return
	agent["hold"] = active
	if active:
		agent["path"] = [] as Array[Vector2i]
		agent["destination"] = unit.global_position
	_agents[unit.get_instance_id()] = agent


func command_move(units: Array, world_target: Vector3, mode := MoveMode.FREE) -> Array[Dictionary]:
	var ordered: Array[Node3D] = []
	for value in units:
		var unit := value as Node3D
		if unit == null:
			continue
		register_unit(unit)
		ordered.append(unit)
	ordered.sort_custom(func(a: Node3D, b: Node3D) -> bool:
		return int(a.get_meta(&"navigation_agent_id", 0)) < int(b.get_meta(&"navigation_agent_id", 0))
	)
	if ordered.is_empty() or runtime_map.grid == null:
		return []

	var command_id := _next_command_id
	_next_command_id += 1
	var group_speed := _slowest_speed(ordered) if mode == MoveMode.FORMATION else INF
	var assignments := _assign_slots(ordered, world_target, mode)
	for assignment in assignments:
		var unit: Node3D = assignment["unit"]
		var agent: Dictionary = _agents[unit.get_instance_id()]
		agent["destination"] = assignment["position"]
		agent["original_destination"] = assignment["position"]
		agent["command_id"] = command_id
		agent["mode"] = mode
		agent["group_speed"] = group_speed
		agent["hold"] = false
		agent["blocked_time"] = 0.0
		agent["reported_enemy"] = false
		_route_agent(agent, unit.global_position, assignment["position"])
		_agents[unit.get_instance_id()] = agent
		if unit.has_method("set_navigation_destination"):
			unit.call("set_navigation_destination", assignment["position"])
	_command_log.append({
		"tick": _navigation_tick_index,
		"command_id": command_id,
		"mode": mode,
		"target": world_target,
		"agents": assignments.map(func(value: Dictionary): return value["agent_id"]),
		"slots": assignments.map(func(value: Dictionary): return value["position"]),
	})
	destination_slots_assigned.emit(command_id, assignments)
	return assignments


func stop(unit: Node3D) -> void:
	var agent: Dictionary = _agent_for(unit)
	if agent.is_empty():
		return
	agent["path"] = [] as Array[Vector2i]
	agent["path_index"] = 0
	agent["destination"] = unit.global_position
	agent["original_destination"] = unit.global_position
	agent["direct_path"] = false
	_agents[unit.get_instance_id()] = agent


## Computes the whole route synchronously: either a clear straight line or a
## native A* grid path, so the unit can move on the very next navigation tick.
func _route_agent(agent: Dictionary, from: Vector3, destination: Vector3) -> void:
	agent["path"] = [] as Array[Vector2i]
	agent["path_index"] = 0
	agent["direct_path"] = _has_clear_line(from, destination, agent)
	if not bool(agent["direct_path"]):
		agent["path"] = planner.find_path(
			runtime_map.grid.world_to_grid(from),
			runtime_map.grid.world_to_grid(destination),
			int(agent["pass_mask"]), int(agent["clearance"]), int(agent["terrain_mask"])
		)


func agent_debug(unit: Node3D) -> Dictionary:
	var agent := _agent_for(unit)
	if agent.is_empty():
		return {}
	return {
		"id": agent["id"],
		"radius": agent["radius"],
		"destination": agent["destination"],
		"command_id": agent["command_id"],
		"mode": agent["mode"],
		"group_speed": agent["group_speed"],
		"hold": agent["hold"],
		"blocked_time": agent["blocked_time"],
		"route_ready": bool(agent["direct_path"]) or not (agent["path"] as Array).is_empty(),
	}


func command_log() -> Array[Dictionary]:
	return _command_log.duplicate(true)


func _physics_process(delta: float) -> void:
	if runtime_map.grid == null:
		return
	_navigation_accumulator += delta
	var tick_delta := 1.0 / NAVIGATION_TICK_RATE
	while _navigation_accumulator >= tick_delta:
		_navigation_accumulator -= tick_delta
		_navigation_tick(tick_delta)
	_blocker_refresh_remaining -= delta
	if _blocker_refresh_remaining <= 0.0:
		_blocker_refresh_remaining = BLOCKER_REFRESH_SECONDS
		_refresh_building_blockers()


func _navigation_tick(delta: float) -> void:
	_navigation_tick_index += 1
	_prune_agents()
	var ordered := _ordered_agents()
	var buckets := _build_spatial_hash(ordered)
	var resolved_positions: Dictionary = {}
	for agent in ordered:
		var unit: Node3D = agent["unit"]
		var desired := _desired_velocity(agent)
		var result := _resolve_velocity(agent, desired, delta, buckets, resolved_positions)
		var velocity: Vector3 = result["velocity"]
		if desired.length_squared() > 0.01 and velocity.length_squared() < 0.01:
			agent["blocked_time"] = float(agent["blocked_time"]) + delta
		else:
			agent["blocked_time"] = 0.0
			agent["reported_enemy"] = false
		if float(agent["blocked_time"]) >= ENEMY_BLOCK_SECONDS and not bool(agent["reported_enemy"]):
			var enemies: Array[Node3D] = result["enemies"]
			if not enemies.is_empty():
				agent["reported_enemy"] = true
				enemy_blocked.emit(unit, enemies)
				if unit.has_method("navigation_blocked_by_enemy"):
					unit.call("navigation_blocked_by_enemy", enemies)
		if float(agent["blocked_time"]) >= FRIENDLY_YIELD_TRIGGER_SECONDS:
			for friend in result["friends"]:
				_request_yield(friend, desired.normalized())
		if float(agent["yield_remaining"]) > 0.0:
			agent["yield_remaining"] = maxf(0.0, float(agent["yield_remaining"]) - delta)
			if is_zero_approx(float(agent["yield_remaining"])) and bool(agent["was_displaced"]):
				agent["was_displaced"] = false
				var home: Vector3 = agent["original_destination"]
				agent["destination"] = home
				_route_agent(agent, unit.global_position, home)
		_agents[unit.get_instance_id()] = agent
		resolved_positions[unit.get_instance_id()] = unit.global_position + velocity * delta
		if unit.has_method("navigation_step"):
			unit.call("navigation_step", velocity, delta)


func _desired_velocity(agent: Dictionary) -> Vector3:
	var unit: Node3D = agent["unit"]
	if bool(agent["hold"]):
		return Vector3.ZERO
	if float(agent["yield_remaining"]) > 0.0:
		return (agent["yield_direction"] as Vector3) * _unit_speed(unit) * 0.7
	var destination: Vector3 = agent["destination"]
	var offset := destination - unit.global_position
	offset.y = 0.0
	var arrival := maxf(_arrival_radius(unit), float(agent["radius"]) * 0.35)
	if offset.length() <= arrival:
		return Vector3.ZERO
	var direction := Vector3.ZERO
	var path: Array = agent["path"]
	if bool(agent["direct_path"]):
		direction = offset.normalized()
	elif not path.is_empty():
		var path_index := int(agent["path_index"])
		if path_index == 0 and path.size() > 1:
			path_index = 1
		while path_index < path.size() - 1:
			var probe: Vector3 = runtime_map.grid.grid_to_world(path[path_index])
			probe.y = unit.global_position.y
			if unit.global_position.distance_to(probe) > maxf(0.35, float(agent["radius"]) * 0.4):
				break
			path_index += 1
		agent["path_index"] = path_index
		var waypoint: Vector3 = runtime_map.grid.grid_to_world(path[path_index])
		waypoint.y = unit.global_position.y
		direction = unit.global_position.direction_to(waypoint)
		direction.y = 0.0
		direction = direction.normalized()
	if direction.is_zero_approx():
		return Vector3.ZERO
	var speed := _unit_speed(unit)
	if int(agent["mode"]) == MoveMode.FORMATION:
		speed = minf(speed, float(agent["group_speed"]))
	return direction * speed


func _has_clear_line(from: Vector3, to: Vector3, agent: Dictionary) -> bool:
	var start: Vector2i = runtime_map.grid.world_to_grid(from)
	var finish: Vector2i = runtime_map.grid.world_to_grid(to)
	var delta: Vector2i = finish - start
	var steps := maxi(absi(delta.x), absi(delta.y))
	if steps == 0:
		return true
	var previous: Vector2i = start
	for index in range(1, steps + 1):
		var weight := float(index) / float(steps)
		var cell := Vector2i(
			roundi(lerpf(float(start.x), float(finish.x), weight)),
			roundi(lerpf(float(start.y), float(finish.y), weight))
		)
		if not runtime_map.is_passable(cell, int(agent["pass_mask"]), int(agent["clearance"]), int(agent["terrain_mask"])):
			return false
		var step: Vector2i = cell - previous
		if step.x != 0 and step.y != 0:
			if not runtime_map.is_passable(previous + Vector2i(step.x, 0), int(agent["pass_mask"]), int(agent["clearance"]), int(agent["terrain_mask"])):
				return false
			if not runtime_map.is_passable(previous + Vector2i(0, step.y), int(agent["pass_mask"]), int(agent["clearance"]), int(agent["terrain_mask"])):
				return false
		previous = cell
	return true


func _resolve_velocity(agent: Dictionary, desired: Vector3, delta: float, buckets: Dictionary, resolved: Dictionary) -> Dictionary:
	if desired.is_zero_approx():
		return {"velocity": Vector3.ZERO, "enemies": [] as Array[Node3D], "friends": [] as Array[Node3D]}
	var unit: Node3D = agent["unit"]
	var nearby := _nearby_agents(unit.global_position, buckets)
	var enemies: Array[Node3D] = []
	var friends: Array[Node3D] = []
	var best_velocity := Vector3.ZERO
	var best_score := -INF
	for angle in CANDIDATE_ANGLES:
		var candidate := desired.rotated(Vector3.UP, angle)
		var destination := unit.global_position + candidate * delta
		var cell: Vector2i = runtime_map.grid.world_to_grid(destination)
		if not runtime_map.is_passable(cell, int(agent["pass_mask"]), int(agent["clearance"]), int(agent["terrain_mask"])):
			continue
		var fraction := 1.0
		for other in nearby:
			if other["unit"] == unit:
				continue
			var other_unit: Node3D = other["unit"]
			var other_position: Vector3 = resolved.get(other_unit.get_instance_id(), other_unit.global_position)
			var safe := _sweep_fraction(
				unit.global_position,
				candidate * delta,
				other_position,
				float(agent["radius"]) + float(other["radius"])
			)
			if safe < fraction:
				fraction = safe
				if _are_enemies(unit, other_unit) and not enemies.has(other_unit):
					enemies.append(other_unit)
				elif not friends.has(other_unit):
					friends.append(other_unit)
		var velocity := candidate * fraction
		var score := velocity.dot(desired.normalized()) - absf(angle) * 0.05
		if score > best_score:
			best_score = score
			best_velocity = velocity
	return {"velocity": best_velocity, "enemies": enemies, "friends": friends}


func _request_yield(unit: Node3D, direction: Vector3) -> void:
	var agent: Dictionary = _agent_for(unit)
	if agent.is_empty() or bool(agent["hold"]) or direction.is_zero_approx():
		return
	# A unit already following a route normally clears the queue by itself. The
	# request mainly displaces idle friendlies that occupy a choke point.
	if _is_en_route(agent) and float(agent["yield_remaining"]) <= 0.0:
		return
	agent["yield_direction"] = direction
	agent["yield_remaining"] = FRIENDLY_YIELD_SECONDS
	agent["was_displaced"] = true
	_agents[unit.get_instance_id()] = agent


func _is_en_route(agent: Dictionary) -> bool:
	if int(agent["command_id"]) <= 0:
		return false
	var unit: Node3D = agent["unit"]
	var offset: Vector3 = (agent["destination"] as Vector3) - unit.global_position
	offset.y = 0.0
	return offset.length() > maxf(_arrival_radius(unit), float(agent["radius"]) * 0.35)


func _sweep_fraction(start: Vector3, displacement: Vector3, obstacle: Vector3, combined_radius: float) -> float:
	var relative := start - obstacle
	relative.y = 0.0
	var motion := displacement
	motion.y = 0.0
	var c := relative.length_squared() - combined_radius * combined_radius
	if c <= 0.0:
		return 1.0 if relative.dot(motion) >= 0.0 else 0.0
	var a := motion.length_squared()
	if a <= 0.000001:
		return 0.0
	var b := 2.0 * relative.dot(motion)
	var discriminant := b * b - 4.0 * a * c
	if discriminant < 0.0:
		return 1.0
	var hit := (-b - sqrt(discriminant)) / (2.0 * a)
	return clampf(hit - 0.01, 0.0, 1.0) if hit >= 0.0 and hit <= 1.0 else 1.0


func _assign_slots(units: Array[Node3D], world_target: Vector3, mode: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var occupied: Array[Dictionary] = []
	var target_cell: Vector2i = runtime_map.grid.world_to_grid(world_target)
	var formation_spacing := _largest_diameter(units) + 0.25
	for index in units.size():
		var unit := units[index]
		var agent: Dictionary = _agents[unit.get_instance_id()]
		var preferred: Vector2i = target_cell
		if mode == MoveMode.FORMATION:
			preferred += _formation_offset(index, units.size(), formation_spacing)
		else:
			preferred += _crowd_offset(index)
		var slot_cell := _find_slot(preferred, agent, occupied)
		var position: Vector3 = runtime_map.grid.grid_to_world(slot_cell) if slot_cell.x >= 0 else unit.global_position
		position.y = world_target.y
		var assignment := {
			"unit": unit,
			"agent_id": agent["id"],
			"slot_id": index,
			"position": position,
			"available": slot_cell.x >= 0,
		}
		result.append(assignment)
		if slot_cell.x >= 0:
			occupied.append({"position": position, "radius": agent["radius"]})
	return result


func _find_slot(preferred: Vector2i, agent: Dictionary, occupied: Array[Dictionary]) -> Vector2i:
	for radius in range(0, SLOT_SEARCH_RADIUS + 1):
		for offset in _ring_offsets(radius):
			var cell := preferred + offset
			if not runtime_map.is_passable(cell, int(agent["pass_mask"]), int(agent["clearance"]), int(agent["terrain_mask"])):
				continue
			var point: Vector3 = runtime_map.grid.grid_to_world(cell)
			var free := true
			for other in occupied:
				if point.distance_to(other["position"]) < float(agent["radius"]) + float(other["radius"]):
					free = false
					break
			if free:
				return cell
	return Vector2i(-1, -1)


func _ring_offsets(radius: int) -> Array[Vector2i]:
	if radius == 0:
		return [Vector2i.ZERO]
	var result: Array[Vector2i] = []
	for x in range(-radius, radius + 1):
		result.append(Vector2i(x, -radius))
		result.append(Vector2i(x, radius))
	for y in range(-radius + 1, radius):
		result.append(Vector2i(-radius, y))
		result.append(Vector2i(radius, y))
	return result


func _crowd_offset(index: int) -> Vector2i:
	if index == 0:
		return Vector2i.ZERO
	var ring := int(ceil((sqrt(float(index + 1)) - 1.0) * 0.5))
	var side := ring * 2
	var first := (side - 1) * (side - 1)
	var position := index - first
	if position < side:
		return Vector2i(-ring + position, -ring)
	position -= side
	if position < side:
		return Vector2i(ring, -ring + position)
	position -= side
	if position < side:
		return Vector2i(ring - position, ring)
	return Vector2i(-ring, ring - (position - side))


func _formation_offset(index: int, count: int, spacing: float) -> Vector2i:
	var columns := int(ceil(sqrt(float(count))))
	var row := index / columns
	var column := index % columns
	return Vector2i(
		int(round((float(column) - float(columns - 1) * 0.5) * spacing)),
		int(round(float(row) * spacing))
	)


func _build_spatial_hash(agents: Array[Dictionary]) -> Dictionary:
	var buckets := {}
	for agent in agents:
		var unit: Node3D = agent["unit"]
		var key := _bucket_key(unit.global_position)
		if not buckets.has(key):
			buckets[key] = []
		buckets[key].append(agent)
	return buckets


func _nearby_agents(position: Vector3, buckets: Dictionary) -> Array:
	var center := _bucket_key(position)
	var result := []
	for y in range(-1, 2):
		for x in range(-1, 2):
			result.append_array(buckets.get(center + Vector2i(x, y), []))
	return result


func _bucket_key(position: Vector3) -> Vector2i:
	return Vector2i(floori(position.x / CELL_BUCKET_SIZE), floori(position.z / CELL_BUCKET_SIZE))


func _ordered_agents() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for value in _agents.values():
		result.append(value)
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["id"]) < int(b["id"]))
	return result


func _prune_agents() -> void:
	for key in _agents.keys():
		var unit = _agents[key]["unit"]
		if not is_instance_valid(unit) or unit.is_queued_for_deletion():
			_agents.erase(key)


func _agent_for(unit: Node3D) -> Dictionary:
	if unit == null:
		return {}
	return _agents.get(unit.get_instance_id(), {})


func _profile_for(unit: Node3D) -> Dictionary:
	var config = unit.get("unit_config")
	var infantry := bool(config.field(&"infantry", false)) if config != null else false
	var can_fly := bool(config.field(&"can_fly", false)) if config != null else false
	var size := float(config.field(&"size", 1.0)) if config != null else 1.0
	var radius := maxf(0.35, size * 0.42)
	var cell_size: Vector2 = runtime_map.grid.cell_size()
	var clearance := maxi(0, int(ceil(radius / maxf(minf(cell_size.x, cell_size.y), 0.001))) - 1)
	var pass_mask := MapNavigationGrid.PASS_AIR if can_fly else (MapNavigationGrid.PASS_INFANTRY if infantry else MapNavigationGrid.PASS_VEHICLE)
	var terrain_mask := _terrain_mask(config.list(&"terrain") if config != null else [])
	return {"radius": radius, "clearance": clearance, "pass_mask": pass_mask, "terrain_mask": terrain_mask}


func _terrain_mask(names: Array) -> int:
	var result := 0
	for value in names:
		match String(value).to_lower():
			"sand": result |= 1 << MapNavigationGrid.TERRAIN_SAND
			"rock": result |= 1 << MapNavigationGrid.TERRAIN_ROCK
			"cliff": result |= 1 << MapNavigationGrid.TERRAIN_CLIFF
			"nbrock", "nonbuildrock": result |= 1 << MapNavigationGrid.TERRAIN_NONBUILDROCK
			"infrock", "infantryrock": result |= 1 << MapNavigationGrid.TERRAIN_INFANTRYROCK
			"dustbowl": result |= 1 << MapNavigationGrid.TERRAIN_DUSTBOWL
			"ramp": result |= 1 << MapNavigationGrid.TERRAIN_RAMP
	return result


func _refresh_building_blockers() -> void:
	if not is_inside_tree() or runtime_map.grid == null:
		return
	var blocked := {}
	var rules := get_node_or_null("/root/Rules")
	for node in get_tree().get_nodes_in_group("buildings"):
		var building := node as Node3D
		if building == null or not _owns_node(building):
			continue
		var config = building.get("building_config")
		if config == null and rules != null:
			var config_id = building.get("config_id")
			if config_id != null:
				config = rules.call("building", config_id)
		if config == null:
			continue
		var rows: Array = config.list(&"occupy_rows")
		var width := 0
		for row in rows:
			width = maxi(width, String(row).length())
		var nav_size := Vector2i(width, rows.size()) * OCCUPY_CELL_SPAN
		var anchor = building.get_meta(&"placement_anchor_cell") if building.has_meta(&"placement_anchor_cell") else null
		if not anchor is Vector2i:
			anchor = runtime_map.grid.world_to_grid(building.global_position) - nav_size / 2
		for row_index in rows.size():
			var row := String(rows[row_index])
			for column_index in row.length():
				if _empty_occupy_marker(row.substr(column_index, 1)):
					continue
				var origin: Vector2i = anchor + Vector2i(column_index, row_index) * OCCUPY_CELL_SPAN
				for y in OCCUPY_CELL_SPAN:
					for x in OCCUPY_CELL_SPAN:
						blocked[origin + Vector2i(x, y)] = true
	if runtime_map.replace_blocked_cells(blocked):
		_replan_after_map_change()


func _replan_after_map_change() -> void:
	var changed_by_command := {}
	for key in _agents.keys():
		var agent: Dictionary = _agents[key]
		if int(agent["command_id"]) <= 0:
			continue
		var destination: Vector3 = agent["destination"]
		var destination_cell: Vector2i = runtime_map.grid.world_to_grid(destination)
		if not runtime_map.is_passable(destination_cell, int(agent["pass_mask"]), int(agent["clearance"]), int(agent["terrain_mask"])):
			var replacement: Vector2i = runtime_map.nearest_passable(
				destination_cell, int(agent["pass_mask"]), int(agent["clearance"]), SLOT_SEARCH_RADIUS, int(agent["terrain_mask"])
			)
			if replacement.x >= 0:
				destination = runtime_map.grid.grid_to_world(replacement)
				agent["destination"] = destination
				agent["original_destination"] = destination
				var command_id := int(agent["command_id"])
				if not changed_by_command.has(command_id):
					changed_by_command[command_id] = []
				changed_by_command[command_id].append({
					"unit": agent["unit"], "agent_id": agent["id"], "slot_id": -1,
					"position": destination, "available": true,
				})
		_route_agent(agent, (agent["unit"] as Node3D).global_position, destination)
		_agents[key] = agent
	for command_id in changed_by_command:
		destination_slots_assigned.emit(command_id, changed_by_command[command_id])


func _empty_occupy_marker(marker: String) -> bool:
	return marker.is_empty() or marker == " " or marker == "." or marker == "_" or marker.to_lower() == "n"


func _are_enemies(a: Node3D, b: Node3D) -> bool:
	if a.has_method("is_enemy_of"):
		var owner_id = b.get("owner_player_id")
		return owner_id != null and bool(a.call("is_enemy_of", int(owner_id)))
	return false


func _unit_speed(unit: Node3D) -> float:
	var value = unit.get("move_speed")
	return maxf(float(value), 0.0) if value != null else 0.0


func _arrival_radius(unit: Node3D) -> float:
	var value = unit.get("arrival_radius")
	return float(value) if value != null else 0.2


func _slowest_speed(units: Array[Node3D]) -> float:
	var speed := INF
	for unit in units:
		speed = minf(speed, _unit_speed(unit))
	return speed


func _largest_diameter(units: Array[Node3D]) -> float:
	var diameter := 1.0
	for unit in units:
		var agent: Dictionary = _agents[unit.get_instance_id()]
		diameter = maxf(diameter, float(agent["radius"]) * 2.0)
	return diameter


func _on_tree_node_added(node: Node) -> void:
	if not _owns_node(node):
		return
	if node.is_in_group("units") and node is Node3D:
		register_unit.call_deferred(node)
	elif node.is_in_group("buildings"):
		_refresh_building_blockers.call_deferred()


func _owns_node(node: Node) -> bool:
	var match_root := get_parent()
	return match_root != null and (node == match_root or match_root.is_ancestor_of(node))
