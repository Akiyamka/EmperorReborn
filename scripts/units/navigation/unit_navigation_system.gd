class_name UnitNavigationSystem
extends Node
## Match-scoped RTS navigation coordinator. It owns path work, destination
## assignment and local collision resolution; Unit remains presentation and
## terrain-following code.

const UnitNavigationMapScript := preload("res://scripts/units/navigation/unit_navigation_map.gd")
const UnitNavigationPlannerScript := preload("res://scripts/units/navigation/unit_navigation_planner.gd")
const BuildingFootprintScript := preload("res://scripts/buildings/building_footprint.gd")

signal destination_slots_assigned(command_id: int, assignments: Array[Dictionary])
signal enemy_blocked(unit: Node3D, blockers: Array[Node3D])

enum MoveMode { FREE, FORMATION }

const NAVIGATION_TICK_RATE := 20.0
const BLOCKER_REFRESH_SECONDS := 0.5
const ENEMY_BLOCK_SECONDS := 0.4
const FRIENDLY_YIELD_SECONDS := 0.4
const FRIENDLY_YIELD_TRIGGER_SECONDS := 0.2
const CELL_BUCKET_SIZE := 4.0
## Blocked cells must cover exactly the footprint the placement grid reserves.
const OCCUPY_CELL_SPAN := BuildingPlacement.NAV_CELLS_PER_OCCUPY_CELL
const SLOT_SEARCH_RADIUS := 32
const CANDIDATE_ANGLES := [0.0, 0.45, -0.45, 0.9, -0.9, 1.35, -1.35, PI / 2.0, -PI / 2.0, PI]
## Units closer than this beyond touching distance count as in contact: they may
## slide tangentially or separate at full speed, just not push deeper in.
const CONTACT_BUFFER := 0.05
## Ticks a unit sits out of assignment trading after a swap (anti flip-flop).
const SWAP_COOLDOWN_TICKS := 10
## Free cells kept between parked footprints, so a standing formation stays
## permeable: small units can thread the lanes between the parking blocks.
const PARKING_GAP_CELLS := 1
## How far ahead local steering checks candidate lanes. A one-tick sweep starts
## turning only at contact, which makes a legitimate detour look like phasing.
const STEERING_LOOKAHEAD_SECONDS := 0.4
## Speed factor for squeezing through friends when steering is walled in.
const SQUEEZE_SPEED_FACTOR := 0.5
## Push speed per unit of overlap depth. Its cap stays below squeeze speed so a
## determined unit can force its way through instead of reaching an overlap
## equilibrium, while idle overlaps are still expelled as soon as room opens.
const SEPARATION_STIFFNESS := 2.5
const SEPARATION_MAX_SPEED_FACTOR := 0.35
## Never let a slow navigation tick create an unbounded catch-up loop. Dropping
## excess simulation time makes units briefly slow down under overload, but the
## render thread can recover instead of spending every following frame on old
## navigation work.
const MAX_CATCH_UP_TICKS := 2

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
		"footprint": profile["footprint"],
		"path": [] as Array[Vector2i],
		"path_index": 0,
		"destination": unit.global_position,
		"command_id": 0,
		"mode": MoveMode.FREE,
		"group_speed": INF,
		"hold": false,
		"blocked_time": 0.0,
		"reported_enemy": false,
		"yield_direction": Vector3.ZERO,
		"yield_remaining": 0.0,
		"direct_path": false,
		"exit_point": Vector3.INF,
		"reserved": true,
		"claim_radius": 0.0,
		"claim_center": unit.global_position,
		"swap_tick": -1000,
		# Per-order exception used only while a harvester enters its reserved
		# refinery pad. Ordinary commands always clear it.
		"allowed_cells": {},
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
		agent["exit_point"] = Vector3.INF
		agent["yield_remaining"] = 0.0
		agent["yield_direction"] = Vector3.ZERO
		agent["reserved"] = true
	_agents[unit.get_instance_id()] = agent


## `exit_point` is a mandatory first waypoint for every unit in the command: a
## production building's front exit that the unit walks straight to before
## regular routing takes over (local steering may cross the building's own
## cells on the way).
func command_move(units: Array, world_target: Vector3, mode := MoveMode.FREE, exit_point := Vector3.INF) -> Array[Dictionary]:
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
	var prepared: Array[Node3D] = []
	for unit in ordered:
		if unit.has_method("prepare_navigation_order") \
		and not bool(unit.call("prepare_navigation_order", world_target, exit_point, mode)):
			continue
		prepared.append(unit)
	ordered = prepared
	if ordered.is_empty() or runtime_map.grid == null:
		return []

	var command_id := _next_command_id
	_next_command_id += 1
	var group_speed := _slowest_speed(ordered) if mode == MoveMode.FORMATION else INF
	var assignments := _assign_slots(ordered, world_target, mode) \
		if mode == MoveMode.FORMATION else _shared_target_assignments(ordered, world_target)
	var claim_radius := _claim_radius_for(ordered)
	for assignment in assignments:
		var unit: Node3D = assignment["unit"]
		var agent: Dictionary = _agents[unit.get_instance_id()]
		agent["destination"] = assignment["position"]
		# Formation slots are planned upfront; a FREE move flies each unit to
		# its shape-preserving aim point and lets it claim a parking block on
		# approach, searching center-out from the shared target.
		agent["reserved"] = mode == MoveMode.FORMATION
		agent["claim_radius"] = claim_radius
		agent["claim_center"] = assignment.get("claim_center", world_target)
		agent["command_id"] = command_id
		agent["mode"] = mode
		agent["group_speed"] = group_speed
		agent["hold"] = false
		agent["blocked_time"] = 0.0
		agent["reported_enemy"] = false
		agent["exit_point"] = exit_point
		agent["allowed_cells"] = {}
		# A fresh order overrides an in-progress yield; a stale yield would keep
		# steering the unit aside and, on expiry, replace this destination with
		# wherever the unit happens to stand.
		agent["yield_remaining"] = 0.0
		agent["yield_direction"] = Vector3.ZERO
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


## Exact single-unit parking order. `allowed_cells` is normally the footprint
## of the refinery that owns the reserved dock; only this agent may route and
## stop there, so the global building blocker map remains unchanged for every
## other unit.
func command_dock(unit: Node3D, world_target: Vector3, allowed_cells: Dictionary) -> bool:
	if unit == null or runtime_map.grid == null or allowed_cells.is_empty():
		return false
	register_unit(unit)
	var agent: Dictionary = _agent_for(unit)
	if agent.is_empty():
		return false
	if unit.has_method("prepare_navigation_order") \
	and not bool(unit.call("prepare_navigation_order", world_target, Vector3.INF, MoveMode.FREE)):
		return false
	var command_id := _next_command_id
	_next_command_id += 1
	agent["destination"] = world_target
	agent["reserved"] = true
	agent["claim_radius"] = 0.0
	agent["claim_center"] = world_target
	agent["command_id"] = command_id
	agent["mode"] = MoveMode.FREE
	agent["group_speed"] = INF
	agent["hold"] = false
	agent["blocked_time"] = 0.0
	agent["reported_enemy"] = false
	agent["exit_point"] = Vector3.INF
	agent["yield_remaining"] = 0.0
	agent["yield_direction"] = Vector3.ZERO
	agent["allowed_cells"] = allowed_cells.duplicate()
	_route_agent(agent, unit.global_position, world_target)
	_agents[unit.get_instance_id()] = agent
	if unit.has_method("set_navigation_destination"):
		unit.call("set_navigation_destination", world_target)
	_command_log.append({
		"tick": _navigation_tick_index,
		"command_id": command_id,
		"mode": MoveMode.FREE,
		"target": world_target,
		"agents": [agent["id"]],
		"slots": [world_target],
		"dock": true,
	})
	return bool(agent["direct_path"])


func stop(unit: Node3D) -> void:
	var agent: Dictionary = _agent_for(unit)
	if agent.is_empty():
		return
	agent["path"] = [] as Array[Vector2i]
	agent["path_index"] = 0
	agent["destination"] = unit.global_position
	agent["direct_path"] = false
	agent["exit_point"] = Vector3.INF
	agent["yield_remaining"] = 0.0
	agent["yield_direction"] = Vector3.ZERO
	agent["reserved"] = true
	_agents[unit.get_instance_id()] = agent


## Computes the whole route synchronously: either a clear straight line or a
## native A* grid path, so the unit can move on the very next navigation tick.
## While an exit point is pending the unit is steered straight at it instead;
## routing takes over from there once it is reached.
func _route_agent(agent: Dictionary, from: Vector3, destination: Vector3) -> void:
	agent["path"] = [] as Array[Vector2i]
	agent["path_index"] = 0
	agent["direct_path"] = false
	if (agent["exit_point"] as Vector3).is_finite():
		return
	agent["direct_path"] = _has_clear_line(from, destination, agent)
	if not bool(agent["direct_path"]):
		var raw_path: Array[Vector2i] = planner.find_path(
			runtime_map.grid.world_to_grid(from),
			runtime_map.grid.world_to_grid(destination),
			int(agent["pass_mask"]), int(agent["clearance"]), int(agent["terrain_mask"])
		)
		agent["path"] = _simplify_path(raw_path, agent)


## AStarGrid2D returns every crossed cell. Keeping that raw list made every
## moving agent rediscover the same visible corner on every navigation tick.
## First retain only direction changes, then greedily join mutually visible
## turns. Runtime steering consequently follows a handful of stable waypoints.
func _simplify_path(raw_path: Array[Vector2i], agent: Dictionary) -> Array[Vector2i]:
	if raw_path.size() <= 2:
		return raw_path
	var turns: Array[Vector2i] = [raw_path[0]]
	var previous_direction := (raw_path[1] - raw_path[0]).sign()
	for index in range(2, raw_path.size()):
		var direction := (raw_path[index] - raw_path[index - 1]).sign()
		if direction != previous_direction:
			turns.append(raw_path[index - 1])
			previous_direction = direction
	turns.append(raw_path.back())
	if turns.size() <= 2:
		return turns

	var result: Array[Vector2i] = [turns[0]]
	var anchor_index := 0
	while anchor_index < turns.size() - 1:
		var furthest_visible := anchor_index + 1
		var from: Vector3 = runtime_map.grid.grid_to_world(turns[anchor_index])
		for probe_index in range(anchor_index + 2, turns.size()):
			var to: Vector3 = runtime_map.grid.grid_to_world(turns[probe_index])
			if not _has_clear_line(from, to, agent):
				break
			furthest_visible = probe_index
		result.append(turns[furthest_visible])
		anchor_index = furthest_visible
	return result


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
		"route_ready": bool(agent["direct_path"]) or not (agent["path"] as Array).is_empty() or (agent["exit_point"] as Vector3).is_finite(),
	}


## Shared arrival contract for navigation-driven gameplay state machines.
## Large authored vehicles stop farther from an exact point than small units;
## callers waiting for arrival must use the same tolerance as steering.
func arrival_tolerance(unit: Node3D) -> float:
	var agent := _agent_for(unit)
	var radius := float(agent.get("radius", 0.0))
	return maxf(_arrival_radius(unit), radius * 0.35)


func command_log() -> Array[Dictionary]:
	return _command_log.duplicate(true)


func _physics_process(delta: float) -> void:
	if runtime_map.grid == null:
		return
	_navigation_accumulator += delta
	var tick_delta := 1.0 / NAVIGATION_TICK_RATE
	var ticks := 0
	while _navigation_accumulator >= tick_delta and ticks < MAX_CATCH_UP_TICKS:
		_navigation_accumulator -= tick_delta
		_navigation_tick(tick_delta)
		ticks += 1
	if _navigation_accumulator >= tick_delta:
		_navigation_accumulator = fmod(_navigation_accumulator, tick_delta)
	_blocker_refresh_remaining -= delta
	if _blocker_refresh_remaining <= 0.0:
		_blocker_refresh_remaining = BLOCKER_REFRESH_SECONDS
		_refresh_building_blockers()


func _navigation_tick(delta: float) -> void:
	_navigation_tick_index += 1
	_prune_agents()
	var ordered := _ordered_agents()
	var claimants: Array[Dictionary] = []
	for agent in ordered:
		if not bool(agent["reserved"]):
			claimants.append(agent)
	# Closest to the target claims first: the unit already standing next to a
	# central block takes it, instead of a far unit crossing the whole pack.
	claimants.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var a_offset: float = ((a["destination"] as Vector3) - (a["unit"] as Node3D).global_position).length()
		var b_offset: float = ((b["destination"] as Vector3) - (b["unit"] as Node3D).global_position).length()
		if is_equal_approx(a_offset, b_offset):
			return int(a["id"]) < int(b["id"])
		return a_offset < b_offset
	)
	for agent in claimants:
		_try_claim_slot(agent)
	_uncross_assignments(ordered)
	var buckets := _build_spatial_hash(ordered)
	var largest_radius := 0.0
	for value in ordered:
		largest_radius = maxf(largest_radius, float(value["radius"]))
	var resolved_positions: Dictionary = {}
	for agent in ordered:
		var unit: Node3D = agent["unit"]
		var desired := _desired_velocity(agent)
		var nearby := _nearby_agents(
			unit.global_position,
			buckets,
			float(agent["radius"]) + largest_radius
		)
		var result := _resolve_velocity(agent, desired, delta, nearby, resolved_positions)
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
				_request_yield(friend, _yield_direction(unit, friend, desired))
		if float(agent["yield_remaining"]) > 0.0:
			agent["yield_remaining"] = maxf(0.0, float(agent["yield_remaining"]) - delta)
			if is_zero_approx(float(agent["yield_remaining"])):
				if int(agent["command_id"]) > 0:
					# A commanded unit owns a unique reserved block nobody else
					# will claim: walk back to it once the passer is through.
					_route_agent(agent, unit.global_position, agent["destination"])
				else:
					# An idle unit displaced off a choke point must not return
					# (it would displace the passer forever); it parks on the
					# nearest free grid block instead.
					agent["destination"] = _snapped_parking(agent, unit.global_position + velocity * delta)
					agent["reserved"] = true
					_route_agent(agent, unit.global_position, agent["destination"])
		# Elastic overlap resolution: overlapping units keep pushing on each
		# other and pop apart the moment free room appears.
		var separation := _separation_velocity(agent, nearby)
		if not separation.is_zero_approx():
			var total := (velocity + separation).limit_length(_unit_speed(unit))
			# Separation may cross friends, but it must not turn the already-safe
			# steering result into motion through an enemy or forbidden terrain.
			if _motion_is_passable(agent, total * delta) \
			and _enemy_sweep_fraction(agent, total * delta, nearby, resolved_positions) >= 0.999:
				velocity = total
				# An idle unit has no spot to defend; it goes where it is pushed
				# instead of fighting its way back into the overlap.
				if int(agent["command_id"]) <= 0 and not bool(agent["hold"]):
					agent["destination"] = unit.global_position + velocity * delta
		_agents[unit.get_instance_id()] = agent
		if unit.has_method("navigation_step"):
			unit.call("navigation_step", velocity, delta)
		# Unit may spend this update turning in place when its rules do not allow
		# simultaneous translation and rotation. Record the actual position so
		# later swept-disc checks do not reserve movement that never happened.
		resolved_positions[unit.get_instance_id()] = unit.global_position


func _desired_velocity(agent: Dictionary) -> Vector3:
	var unit: Node3D = agent["unit"]
	if bool(agent["hold"]):
		return Vector3.ZERO
	if float(agent["yield_remaining"]) > 0.0:
		return (agent["yield_direction"] as Vector3) * _unit_speed(unit) * 0.7
	var exit_point: Vector3 = agent["exit_point"]
	if exit_point.is_finite():
		var exit_offset := exit_point - unit.global_position
		exit_offset.y = 0.0
		if exit_offset.length() > maxf(_arrival_radius(unit), float(agent["radius"]) * 0.35):
			return exit_offset.normalized() * _unit_speed(unit)
		agent["exit_point"] = Vector3.INF
		_route_agent(agent, unit.global_position, agent["destination"])
	var destination: Vector3 = agent["destination"]
	var offset := destination - unit.global_position
	offset.y = 0.0
	var arrival := arrival_tolerance(unit)
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
		if not _agent_cell_passable(agent, cell):
			return false
		var step: Vector2i = cell - previous
		if step.x != 0 and step.y != 0:
			if not _agent_cell_passable(agent, previous + Vector2i(step.x, 0)):
				return false
			if not _agent_cell_passable(agent, previous + Vector2i(0, step.y)):
				return false
		previous = cell
	return true


## Collision is elastic: units steer around each other while there is room
## (full-speed candidate evaluation against every neighbour), but a unit walled
## in by friends squeezes through them at reduced speed — enemies and terrain
## stay solid — while the per-tick separation push works the overlap back out.
func _resolve_velocity(agent: Dictionary, desired: Vector3, delta: float, nearby: Array, resolved: Dictionary) -> Dictionary:
	if desired.is_zero_approx():
		return {"velocity": Vector3.ZERO, "enemies": [] as Array[Node3D], "friends": [] as Array[Node3D]}
	var unit: Node3D = agent["unit"]
	var blockers := []
	for other in nearby:
		if other["unit"] != unit:
			blockers.append(other)
	var full: Dictionary = _evaluate_candidates(agent, desired, delta, blockers, resolved, 1.0)
	var velocity: Vector3 = full["velocity"]
	# Squeezing is not a fallback for any slow result. It is allowed only when
	# friends remove every non-reversing steering lane that would otherwise be
	# open; in ordinary space the full-speed side lane wins and units go around.
	if not bool(full["has_escape"]):
		var solid := []
		for other in blockers:
			if _are_enemies(unit, other["unit"]):
				solid.append(other)
		var squeeze: Dictionary = _evaluate_candidates(agent, desired, delta, solid, resolved, SQUEEZE_SPEED_FACTOR)
		if bool(squeeze["has_escape"]):
			velocity = squeeze["velocity"]
	return {"velocity": velocity, "enemies": full["enemies"], "friends": full["friends"]}


func _evaluate_candidates(agent: Dictionary, desired: Vector3, delta: float, blockers: Array, resolved: Dictionary, speed_scale: float) -> Dictionary:
	var unit: Node3D = agent["unit"]
	var scaled := desired * speed_scale
	var desired_direction := desired.normalized()
	var desired_speed := scaled.length()
	var enemies: Array[Node3D] = []
	var friends: Array[Node3D] = []
	var best_velocity := Vector3.ZERO
	var best_score := -INF
	var has_escape := false
	# A unit standing on building cells cannot satisfy the normal cell filter:
	# inside the interior every neighbour is blocked too, and on the apron the
	# clearance window still touches the building. Interior units steer with
	# the filter suspended (the escape route leads them out); apron units keep
	# the blocked-cell filter but drop the clearance window.
	var origin_cell: Vector2i = runtime_map.grid.world_to_grid(unit.global_position)
	var origin_open := _agent_cell_passable(agent, origin_cell, 0, 0)
	var origin_clearance := int(agent["clearance"])
	if origin_open and not _agent_cell_stoppable(agent, origin_cell, 0, 0):
		origin_clearance = 0
	for angle in CANDIDATE_ANGLES:
		var candidate := scaled.rotated(Vector3.UP, angle)
		var destination := unit.global_position + candidate * delta
		var cell: Vector2i = runtime_map.grid.world_to_grid(destination)
		if origin_open and not _agent_cell_passable(agent, cell, origin_clearance):
			continue
		# Prediction uses unscaled speed, otherwise a slow squeeze probe could
		# mistake a nearby wall for a valid lane merely because it looks less far.
		var prediction := desired.rotated(Vector3.UP, angle) * STEERING_LOOKAHEAD_SECONDS
		var terrain_clear := _motion_is_passable(agent, prediction)
		var fraction := 1.0
		var predicted_fraction := 1.0
		for other in blockers:
			var other_unit: Node3D = other["unit"]
			var other_position: Vector3 = resolved.get(other_unit.get_instance_id(), other_unit.global_position)
			var safe := _sweep_fraction(
				unit.global_position,
				candidate * delta,
				other_position,
				float(agent["radius"]) + float(other["radius"])
			)
			var predicted_safe := _sweep_fraction(
				unit.global_position,
				prediction,
				other_position,
				float(agent["radius"]) + float(other["radius"])
			)
			if safe < fraction:
				fraction = safe
			predicted_fraction = minf(predicted_fraction, predicted_safe)
			if predicted_safe < 0.999 or safe < 0.999:
				if _are_enemies(unit, other_unit):
					if not enemies.has(other_unit):
						enemies.append(other_unit)
				elif not friends.has(other_unit):
					friends.append(other_unit)
		var velocity := candidate * fraction
		var projected := candidate * predicted_fraction
		var score := projected.dot(desired_direction) - absf(angle) * 0.05 * desired_speed
		if not terrain_clear:
			score -= desired_speed * 2.0
		# A near-frozen candidate must lose to any real motion, sideways
		# included, or a unit meeting a stopped friend halts for good instead
		# of sliding around. Backing off still scores below standing still.
		if fraction < 0.15:
			score -= desired_speed
		if terrain_clear and predicted_fraction >= 0.999 \
		and candidate.dot(desired_direction) >= -0.001:
			has_escape = true
		if score > best_score:
			best_score = score
			best_velocity = velocity
	return {"velocity": best_velocity, "enemies": enemies, "friends": friends, "has_escape": has_escape}


## Candidate motion against the map using the agent's real clearance and
## terrain profile. Units spawned inside a building retain the existing escape
## exception until their origin reaches a passable cell.
func _motion_is_passable(agent: Dictionary, displacement: Vector3) -> bool:
	var unit: Node3D = agent["unit"]
	var start: Vector2i = runtime_map.grid.world_to_grid(unit.global_position)
	if not _agent_cell_passable(agent, start, 0, 0):
		return true
	var clearance := int(agent["clearance"])
	if not _agent_cell_stoppable(agent, start, 0, 0):
		clearance = 0
	var finish: Vector2i = runtime_map.grid.world_to_grid(unit.global_position + displacement)
	var cell_delta := finish - start
	var steps := maxi(absi(cell_delta.x), absi(cell_delta.y))
	var previous := start
	for index in range(1, steps + 1):
		var weight := float(index) / float(steps)
		var cell := Vector2i(
			roundi(lerpf(float(start.x), float(finish.x), weight)),
			roundi(lerpf(float(start.y), float(finish.y), weight))
		)
		if not _agent_cell_passable(agent, cell, clearance):
			return false
		var step := cell - previous
		if step.x != 0 and step.y != 0:
			if not _agent_cell_passable(agent, previous + Vector2i(step.x, 0), clearance):
				return false
			if not _agent_cell_passable(agent, previous + Vector2i(0, step.y), clearance):
				return false
		previous = cell
	return true


func _agent_cell_passable(
		agent: Dictionary,
		cell: Vector2i,
		clearance_cells := -1,
		allowed_terrain_mask := -1
	) -> bool:
	var clearance := int(agent["clearance"]) if clearance_cells < 0 else clearance_cells
	var terrain_mask := int(agent["terrain_mask"]) if allowed_terrain_mask < 0 else allowed_terrain_mask
	var pass_mask := int(agent["pass_mask"])
	if runtime_map.is_passable(cell, pass_mask, clearance, terrain_mask):
		return true
	var allowed: Dictionary = agent.get("allowed_cells", {})
	if allowed.is_empty():
		return false
	for y in range(-clearance, clearance + 1):
		for x in range(-clearance, clearance + 1):
			var sample := cell + Vector2i(x, y)
			if not runtime_map.grid.is_passable(sample, pass_mask):
				return false
			if terrain_mask != 0 and (terrain_mask & (1 << runtime_map.grid.terrain_at(sample))) == 0:
				return false
			if runtime_map.is_blocked(sample) and not allowed.has(sample):
				return false
	return true


func _agent_cell_stoppable(
		agent: Dictionary,
		cell: Vector2i,
		clearance_cells := -1,
		allowed_terrain_mask := -1
	) -> bool:
	var clearance := int(agent["clearance"]) if clearance_cells < 0 else clearance_cells
	var terrain_mask := int(agent["terrain_mask"]) if allowed_terrain_mask < 0 else allowed_terrain_mask
	var pass_mask := int(agent["pass_mask"])
	if runtime_map.is_stoppable(cell, pass_mask, clearance, terrain_mask):
		return true
	var allowed: Dictionary = agent.get("allowed_cells", {})
	if allowed.is_empty():
		return false
	for y in range(-clearance, clearance + 1):
		for x in range(-clearance, clearance + 1):
			var sample := cell + Vector2i(x, y)
			if not runtime_map.grid.is_passable(sample, pass_mask):
				return false
			if terrain_mask != 0 and (terrain_mask & (1 << runtime_map.grid.terrain_at(sample))) == 0:
				return false
			if (runtime_map.is_blocked(sample) or runtime_map.is_no_stop(sample)) and not allowed.has(sample):
				return false
	return true


func _enemy_sweep_fraction(agent: Dictionary, displacement: Vector3, nearby: Array, resolved: Dictionary) -> float:
	var unit: Node3D = agent["unit"]
	var fraction := 1.0
	for other in nearby:
		var other_unit: Node3D = other["unit"]
		if other_unit == unit or not _are_enemies(unit, other_unit):
			continue
		var other_position: Vector3 = resolved.get(other_unit.get_instance_id(), other_unit.global_position)
		fraction = minf(fraction, _sweep_fraction(
			unit.global_position,
			displacement,
			other_position,
			float(agent["radius"]) + float(other["radius"])
		))
	return fraction


## The elastic push between overlapping units: proportional to penetration
## depth, capped below squeeze speed, and always pointing apart. Fully stacked
## pairs split along a deterministic axis.
func _separation_velocity(agent: Dictionary, nearby: Array) -> Vector3:
	var unit: Node3D = agent["unit"]
	var push := Vector3.ZERO
	for other in nearby:
		if other["unit"] == unit:
			continue
		var other_unit: Node3D = other["unit"]
		var away := unit.global_position - other_unit.global_position
		away.y = 0.0
		var combined := float(agent["radius"]) + float(other["radius"])
		var distance := away.length()
		if distance >= combined:
			continue
		if distance <= 0.001:
			push += (Vector3.RIGHT if int(agent["id"]) < int(other["id"]) else Vector3.LEFT) * combined
		else:
			push += away / distance * (combined - distance)
	if push.is_zero_approx():
		return Vector3.ZERO
	return (push * SEPARATION_STIFFNESS).limit_length(_unit_speed(unit) * SEPARATION_MAX_SPEED_FACTOR)


## A yielding friend steps sideways out of the requester's lane (toward the
## side it is already offset to), not along it — walking the lane keeps it in
## front of the requester and drags it deep into the crowd.
func _yield_direction(requester: Node3D, friend: Node3D, desired: Vector3) -> Vector3:
	var lateral := desired.normalized().cross(Vector3.UP)
	var side := friend.global_position - requester.global_position
	side.y = 0.0
	if lateral.dot(side) < 0.0:
		lateral = -lateral
	return lateral.normalized()


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
	# The swept stop leaves a hair's gap, so a contact test on the exact radius
	# never fires and every later step quantizes to zero, freezing groups at
	# their first touch. Within the buffer tangential and separating motion pass
	# at full speed; only digging deeper is forbidden.
	var contact := combined_radius + CONTACT_BUFFER
	if relative.length_squared() <= contact * contact:
		return 1.0 if relative.dot(motion) >= 0.0 else 0.0
	var c := relative.length_squared() - combined_radius * combined_radius
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
	var spacing := _largest_footprint(units) + PARKING_GAP_CELLS
	for index in units.size():
		var unit := units[index]
		var agent: Dictionary = _agents[unit.get_instance_id()]
		var span := int(agent["footprint"])
		var preferred := _parking_anchor(world_target, span)
		if mode == MoveMode.FORMATION:
			preferred += _formation_offset(index, units.size(), float(spacing))
		else:
			preferred += _crowd_offset(index) * spacing
		var anchor := _find_slot(preferred, agent, occupied)
		var position: Vector3 = _block_center(anchor, span) if anchor.x >= 0 else unit.global_position
		position.y = world_target.y
		var assignment := {
			"unit": unit,
			"agent_id": agent["id"],
			"slot_id": index,
			"position": position,
			"available": anchor.x >= 0,
		}
		result.append(assignment)
		if anchor.x >= 0:
			occupied.append({"anchor": anchor, "span": span})
	return result


## FREE moves do not pre-plan parking slots: a pre-assigned interior slot
## belongs to whoever happens to arrive last, and the crowd has to fight itself
## to deliver that unit. Each unit aims at the target translated by its own
## offset inside the pack (clamped to the resting pack radius), so the group
## moves as a shape instead of funnelling through one point, then claims the
## best free block on approach (_try_claim_slot), packing in arrival order.
func _shared_target_assignments(units: Array[Node3D], world_target: Vector3) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var centroid := Vector3.ZERO
	for unit in units:
		centroid += unit.global_position
	centroid /= float(units.size())
	var cell: Vector2 = runtime_map.grid.cell_size()
	var pack_radius := ceilf(sqrt(float(units.size()))) * 0.5 \
		* float(_largest_footprint(units) + PARKING_GAP_CELLS) * maxf(cell.x, cell.y)
	var spread := 0.0
	for unit in units:
		spread = maxf(spread, Vector2(unit.global_position.x - centroid.x, unit.global_position.z - centroid.z).length())
	# A compact pack is being MOVED: keep its shape, claims stay at each aim
	# point. A group scattered wider than its resting size is being GATHERED:
	# claims run center-out from the target so the pack fills up tight.
	var gather := spread > pack_radius * 1.5
	for index in units.size():
		var unit := units[index]
		var agent: Dictionary = _agents[unit.get_instance_id()]
		var span := int(agent["footprint"])
		var offset := unit.global_position - centroid
		offset.y = 0.0
		var aim := world_target + offset.limit_length(pack_radius)
		var anchor := _find_slot(_parking_anchor(aim, span), agent, [])
		var position := _block_center(anchor, span) if anchor.x >= 0 else aim
		position.y = world_target.y
		result.append({
			"unit": unit,
			"agent_id": agent["id"],
			"slot_id": index,
			"position": position,
			"available": true,
			"claim_center": world_target if gather else position,
		})
	return result


## The moment a FREE-move unit gets near the shared target it claims a parking
## block: the most central free one, tie-broken toward its own approach side so
## claims do not cross the crowd.
func _try_claim_slot(agent: Dictionary) -> void:
	var unit: Node3D = agent["unit"]
	if bool(agent["hold"]) or (agent["exit_point"] as Vector3).is_finite():
		return
	var destination: Vector3 = agent["destination"]
	var offset := destination - unit.global_position
	offset.y = 0.0
	if offset.length() > float(agent["claim_radius"]):
		return
	var span := int(agent["footprint"])
	# The search is centered on the shared command target, not the unit's own
	# aim point: the pack packs center-out and does not settle into a ring.
	var anchor := _claim_anchor(_parking_anchor(agent["claim_center"], span), agent, _reserved_blocks(agent), unit.global_position)
	if anchor.x < 0:
		return
	agent["reserved"] = true
	var parked := _block_center(anchor, span)
	parked.y = destination.y
	agent["destination"] = parked
	_route_agent(agent, unit.global_position, parked)
	if unit.has_method("set_navigation_destination"):
		unit.call("set_navigation_destination", parked)


## Uncrosses parking assignments within a command: when two units would each
## travel further to their own blocks than to each other's, they trade blocks
## instead of trying to push their bodies past one another. Crossed pairs are
## what makes a nudged pack fight itself indefinitely.
func _uncross_assignments(agents: Array[Dictionary]) -> void:
	var groups := {}
	for agent in agents:
		if int(agent["command_id"]) <= 0 or not bool(agent["reserved"]) or bool(agent["hold"]):
			continue
		if (agent["exit_point"] as Vector3).is_finite():
			continue
		# Only units still moving inside the arrival zone take part: crossings
		# out in the open resolve themselves by steering, and a unit already
		# parked on its block must not be dragged out by a trade.
		var unit: Node3D = agent["unit"]
		var offset: Vector3 = (agent["destination"] as Vector3) - unit.global_position
		offset.y = 0.0
		if offset.length() > float(agent["claim_radius"]):
			continue
		if offset.length() <= maxf(_arrival_radius(unit), float(agent["radius"]) * 0.35):
			continue
		# A cooldown after each trade stops marginal swaps from flip-flopping
		# every tick while two units move in near-symmetry.
		if _navigation_tick_index - int(agent["swap_tick"]) < SWAP_COOLDOWN_TICKS:
			continue
		var key := "%d:%d" % [int(agent["command_id"]), int(agent["footprint"])]
		if not groups.has(key):
			groups[key] = []
		groups[key].append(agent)
	for key in groups:
		var group: Array = groups[key]
		for a_index in group.size():
			for b_index in range(a_index + 1, group.size()):
				var a: Dictionary = group[a_index]
				var b: Dictionary = group[b_index]
				var a_unit: Node3D = a["unit"]
				var b_unit: Node3D = b["unit"]
				var a_destination: Vector3 = a["destination"]
				var b_destination: Vector3 = b["destination"]
				var current := a_unit.global_position.distance_to(a_destination) \
					+ b_unit.global_position.distance_to(b_destination)
				var swapped := a_unit.global_position.distance_to(b_destination) \
					+ b_unit.global_position.distance_to(a_destination)
				if swapped + 0.05 < current:
					a["destination"] = b_destination
					b["destination"] = a_destination
					a["swap_tick"] = _navigation_tick_index
					b["swap_tick"] = _navigation_tick_index
					_route_agent(a, a_unit.global_position, b_destination)
					_route_agent(b, b_unit.global_position, a_destination)
					if a_unit.has_method("set_navigation_destination"):
						a_unit.call("set_navigation_destination", b_destination)
					if b_unit.has_method("set_navigation_destination"):
						b_unit.call("set_navigation_destination", a_destination)


## Parking blocks already promised to other agents: reserved destinations only,
## so shared aim points of units that have not claimed yet do not count.
func _reserved_blocks(agent: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for key in _agents:
		var other: Dictionary = _agents[key]
		if int(other["id"]) == int(agent["id"]) or not bool(other["reserved"]):
			continue
		var other_span := int(other["footprint"])
		result.append({"anchor": _parking_anchor(other["destination"], other_span), "span": other_span})
	return result


func _claim_radius_for(units: Array[Node3D]) -> float:
	var cell: Vector2 = runtime_map.grid.cell_size()
	var pitch := float(_largest_footprint(units) + PARKING_GAP_CELLS)
	var crowd := ceilf(sqrt(float(units.size()))) * 0.5 * pitch
	return (crowd + 2.0) * maxf(cell.x, cell.y)


func _find_slot(preferred: Vector2i, agent: Dictionary, occupied: Array[Dictionary]) -> Vector2i:
	return _claim_anchor(preferred, agent, occupied, _block_center(preferred, int(agent["footprint"])))


## Ring search for a free grid-aligned footprint block: every cell of the
## span x span block must be stoppable and the block may not overlap a block in
## `occupied` ({anchor, span} entries). Inner rings keep priority; ties within
## a ring resolve toward `from`.
func _claim_anchor(preferred: Vector2i, agent: Dictionary, occupied: Array[Dictionary], from: Vector3) -> Vector2i:
	var span := int(agent["footprint"])
	for radius in range(0, SLOT_SEARCH_RADIUS + 1):
		var best := Vector2i(-1, -1)
		var best_distance := INF
		for offset in _ring_offsets(radius):
			var anchor := preferred + offset
			if not _block_stoppable(anchor, span, agent):
				continue
			var blocked := false
			for other in occupied:
				if _blocks_conflict(anchor, span, other["anchor"], int(other["span"])):
					blocked = true
					break
			if blocked:
				continue
			var distance := from.distance_to(_block_center(anchor, span))
			if distance < best_distance:
				best_distance = distance
				best = anchor
		if best.x >= 0:
			return best
	return Vector2i(-1, -1)


func _block_stoppable(anchor: Vector2i, span: int, agent: Dictionary) -> bool:
	for y in span:
		for x in span:
			if not _agent_cell_stoppable(agent, anchor + Vector2i(x, y)):
				return false
	return true


## Two parking blocks conflict when fewer than PARKING_GAP_CELLS free cells
## separate them (in either axis), not only on actual overlap.
func _blocks_conflict(a: Vector2i, a_span: int, b: Vector2i, b_span: int) -> bool:
	return a.x < b.x + b_span + PARKING_GAP_CELLS and b.x < a.x + a_span + PARKING_GAP_CELLS \
		and a.y < b.y + b_span + PARKING_GAP_CELLS and b.y < a.y + a_span + PARKING_GAP_CELLS


## World center of a span x span cell block anchored at its lowest cell. For
## even spans the center sits on the shared cell corner.
func _block_center(anchor: Vector2i, span: int) -> Vector3:
	var center: Vector3 = runtime_map.grid.grid_to_world(anchor)
	var cell: Vector2 = runtime_map.grid.cell_size()
	var shift := float(span - 1) * 0.5
	return center + Vector3(cell.x * shift, 0.0, cell.y * shift)


## Anchor cell of the block whose center lies nearest to `point`.
func _parking_anchor(point: Vector3, span: int) -> Vector2i:
	var cell: Vector2 = runtime_map.grid.cell_size()
	var shift := float(span - 1) * 0.5
	return runtime_map.grid.world_to_grid(point - Vector3(cell.x * shift, 0.0, cell.y * shift))


## Nearest free grid-aligned block center for the agent, avoiding every other
## agent's reserved parking block. Falls back to `point` when nothing is free.
func _snapped_parking(agent: Dictionary, point: Vector3) -> Vector3:
	var span := int(agent["footprint"])
	var anchor := _claim_anchor(_parking_anchor(point, span), agent, _reserved_blocks(agent), point)
	if anchor.x < 0:
		return point
	var parked := _block_center(anchor, span)
	parked.y = point.y
	return parked


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


func _nearby_agents(position: Vector3, buckets: Dictionary, search_radius := CELL_BUCKET_SIZE) -> Array:
	var center := _bucket_key(position)
	var result := []
	var bucket_radius := maxi(1, ceili(search_radius / CELL_BUCKET_SIZE))
	for y in range(-bucket_radius, bucket_radius + 1):
		for x in range(-bucket_radius, bucket_radius + 1):
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
	if unit.has_method("navigation_collision_radius"):
		radius = float(unit.call("navigation_collision_radius", radius))
	var cell_size: Vector2 = runtime_map.grid.cell_size()
	var clearance := maxi(0, int(ceil(radius / maxf(minf(cell_size.x, cell_size.y), 0.001))) - 1)
	var pass_mask := MapNavigationGrid.PASS_AIR if can_fly else (MapNavigationGrid.PASS_INFANTRY if infantry else MapNavigationGrid.PASS_VEHICLE)
	var terrain_mask := _terrain_mask(config.list(&"terrain") if config != null else [])
	# `size` is the side of the unit's square footprint in navigation cells;
	# destinations are always the center of a free size x size cell block.
	var footprint := maxi(1, roundi(size))
	return {"radius": radius, "clearance": clearance, "pass_mask": pass_mask, "terrain_mask": terrain_mask, "footprint": footprint}


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
	var no_stop := {}
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
		var footprint: Dictionary = BuildingFootprintScript.nav_cells_by_marker(
			building, rows, runtime_map.grid, OCCUPY_CELL_SPAN
		)
		for cell in footprint:
			# Skirt cells are freely traversable, but destination and parking
			# selection must never let an ordinary unit stop on them.
			var target := no_stop if String(footprint[cell]).to_lower() == "s" else blocked
			target[cell] = true
	if runtime_map.replace_blocked_cells(blocked, no_stop):
		_replan_after_map_change()


func _replan_after_map_change() -> void:
	var changed_by_command := {}
	for key in _agents.keys():
		var agent: Dictionary = _agents[key]
		if int(agent["command_id"]) <= 0:
			continue
		var destination: Vector3 = agent["destination"]
		var span := int(agent["footprint"])
		if not _block_stoppable(_parking_anchor(destination, span), span, agent):
			var replacement := _find_slot(_parking_anchor(destination, span), agent, _reserved_blocks(agent))
			if replacement.x >= 0:
				var height := destination.y
				destination = _block_center(replacement, span)
				destination.y = height
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


func _largest_footprint(units: Array[Node3D]) -> int:
	var span := 1
	for unit in units:
		var agent: Dictionary = _agents[unit.get_instance_id()]
		span = maxi(span, int(agent["footprint"]))
	return span


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
