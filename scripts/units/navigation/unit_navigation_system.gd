class_name UnitNavigationSystem
extends Node
## Match-scoped RTS navigation coordinator. It owns path work and destination
## assignment, delegates short-range collision steering to UnitLocalAvoidance,
## and leaves presentation/terrain following to Unit.

const UnitNavigationMapScript := preload("res://scripts/units/navigation/unit_navigation_map.gd")
const UnitNavigationPlannerScript := preload("res://scripts/units/navigation/unit_navigation_planner.gd")
const UnitLocalAvoidanceScript := preload("res://scripts/units/navigation/unit_local_avoidance.gd")
const UnitNavigationDebugScript := preload("res://scripts/units/navigation/unit_navigation_debug.gd")
const BuildingFootprintScript := preload("res://scripts/buildings/building_footprint.gd")
const BuildingDefinitionCatalogScript := preload("res://scripts/buildings/building_definition_catalog.gd")
static var _building_definition_catalog := BuildingDefinitionCatalogScript.new()

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
## Ticks a unit sits out of assignment trading after a swap (anti flip-flop).
const SWAP_COOLDOWN_TICKS := 10
## Free cells kept between parked footprints, so a standing formation stays
## permeable: small units can thread the lanes between the parking blocks.
const PARKING_GAP_CELLS := 1
## Parallel route lanes must sit outside the same soft personal-space field
## used by local avoidance. Otherwise units technically have different targets
## but still spend the whole trip steering away from each other.
const ROUTE_LANE_COMFORT_RADIUS_FACTOR := 0.4
## Never let a slow navigation tick create an unbounded catch-up loop. Dropping
## excess simulation time makes units briefly slow down under overload, but the
## render thread can recover instead of spending every following frame on old
## navigation work.
const MAX_CATCH_UP_TICKS := 2

var runtime_map = UnitNavigationMapScript.new()
var planner = UnitNavigationPlannerScript.new()
var avoidance = UnitLocalAvoidanceScript.new()
var navigation_debug = UnitNavigationDebugScript.new()

var _agents: Dictionary = {}
var _next_agent_id := 1
var _next_command_id := 1
var _navigation_tick_index := 0
var _navigation_accumulator := 0.0
var _blocker_refresh_remaining := 0.0
var _command_log: Array[Dictionary] = []
var _debug_enabled := false


func _ready() -> void:
	if navigation_debug.get_parent() == null:
		navigation_debug.name = "NavigationDebug"
		add_child(navigation_debug)
	navigation_debug.set_enabled(_debug_enabled)
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
	avoidance.setup(runtime_map)
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
		"rotation_radius": profile["rotation_radius"],
		"terrain_radius": profile["rotation_radius"],
		"pass_mask": profile["pass_mask"],
		"terrain_mask": profile["terrain_mask"],
		"clearance": profile["clearance"],
		"body_clearance": profile["body_clearance"],
		"rotation_clearance": profile["clearance"],
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
		"avoidance_direction": Vector3.ZERO,
		"avoidance_side": 0,
		"steering_turn_in_place": false,
		"steering_target": unit.global_position,
		# Units issued one group order keep their initial cross-route ordering.
		# The compact A* paths may share a corner cell, but the runtime follower
		# treats it as a gate and gives each body a parallel lane through it.
		"route_lane_offset": 0.0,
		"route_lane_min": 0.0,
		"route_lane_max": 0.0,
		"yield_direction": Vector3.ZERO,
		"yield_remaining": 0.0,
		"direct_path": false,
		"exit_point": Vector3.INF,
		"reserved": true,
		"claim_radius": 0.0,
		"claim_center": unit.global_position,
		"swap_tick": -1000,
		# An ordinary order may deliberately end on traversable no-stop space.
		# Once that first leg arrives, navigation immediately parks the unit on
		# the nearest ordinary stopping block.
		"vacate_no_stop": false,
		# A harvester leaving a refinery temporarily keeps access to that
		# refinery's d/p cells. The exception is dropped as soon as its complete
		# footprint reaches ordinary stoppable ground.
		"departure_access": false,
		# Per-order exception used only while a harvester enters its reserved
		# refinery pad. Ordinary commands always clear it.
		"allowed_cells": {},
	}
	_agents[key] = agent
	_next_agent_id += 1
	planner.prewarm(int(profile["pass_mask"]), int(profile["clearance"]), int(profile["terrain_mask"]))
	avoidance.prewarm(int(profile["pass_mask"]), int(profile["terrain_mask"]))
	unit.set_meta(&"navigation_agent_id", agent["id"])
	if unit.has_method("set_navigation_managed"):
		unit.call("set_navigation_managed", true)
	if unit.has_method("set_navigation_controller"):
		unit.call("set_navigation_controller", self)
	if unit.has_method("set_navigation_debug_visible"):
		unit.call("set_navigation_debug_visible", _debug_enabled)
	return int(agent["id"])


func unregister_unit(unit: Node3D) -> void:
	if unit == null:
		return
	if unit.has_method("set_navigation_debug_visible"):
		unit.call("set_navigation_debug_visible", false)
	_agents.erase(unit.get_instance_id())


func set_debug_enabled(value: bool) -> void:
	_debug_enabled = value
	navigation_debug.set_enabled(value)
	for agent_value in _agents.values():
		var unit: Node3D = (agent_value as Dictionary).get("unit")
		if is_instance_valid(unit) and unit.has_method("set_navigation_debug_visible"):
			unit.call("set_navigation_debug_visible", value)
	if value:
		_refresh_navigation_debug()


func debug_enabled() -> bool:
	return _debug_enabled


func set_hold_position(unit: Node3D, active: bool) -> void:
	var agent: Dictionary = _agent_for(unit)
	if agent.is_empty():
		return
	agent["hold"] = active
	if active:
		avoidance.reset_agent(agent)
		agent["path"] = [] as Array[Vector2i]
		agent["destination"] = unit.global_position
		agent["exit_point"] = Vector3.INF
		agent["yield_remaining"] = 0.0
		agent["yield_direction"] = Vector3.ZERO
		agent["reserved"] = true
	_agents[unit.get_instance_id()] = agent


## Read-only counterpart of an ordinary move order. It checks the exact
## clicked destination against each unit's movement profile without preparing
## the unit, changing its route, or reserving a parking slot.
func can_move_to(units: Array, world_target: Vector3) -> bool:
	if runtime_map.grid == null:
		return false
	var target_cell: Vector2i = runtime_map.grid.world_to_grid(world_target)
	var allow_no_stop: bool = runtime_map.is_no_stop(target_cell)
	for value in units:
		var unit := value as Node3D
		if unit == null:
			continue
		var agent: Dictionary = _movement_probe_for(unit)
		var span: int = int(agent["footprint"])
		var anchor: Vector2i = _parking_anchor(world_target, span)
		if allow_no_stop:
			if _block_passable(anchor, span, agent):
				return true
		elif _block_stoppable(anchor, span, agent):
			return true
	return false


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
	# Slot selection must use ordinary movement rules. In particular, a unit's
	# previous refinery-dock exception must not make that dock look like a legal
	# permanent destination for its next player order.
	for unit in ordered:
		var agent: Dictionary = _agents[unit.get_instance_id()]
		avoidance.reset_agent(agent)
		_set_agent_rotation_envelope(agent, true)
		agent["allowed_cells"] = {}
		agent["vacate_no_stop"] = false
		agent["departure_access"] = false
		_agents[unit.get_instance_id()] = agent

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
		agent["vacate_no_stop"] = bool(assignment.get("vacate_no_stop", false))
		agent["reserved"] = mode == MoveMode.FORMATION or bool(agent["vacate_no_stop"])
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
	_assign_route_lanes(ordered, world_target)
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


## Ordinary single-unit movement that starts on a reserved refinery pad.
## Unlike command_dock(), the destination is claimed with normal FREE-move
## parking rules, so several departing harvesters never reserve the same spice
## cell. `allowed_cells` exists only long enough to clear the refinery apron.
func command_depart(unit: Node3D, world_target: Vector3, allowed_cells: Dictionary) -> bool:
	if unit == null or allowed_cells.is_empty():
		return false
	var assignments := command_move([unit], world_target, MoveMode.FREE)
	if assignments.is_empty():
		return false
	var agent: Dictionary = _agent_for(unit)
	_set_agent_rotation_envelope(agent, false)
	agent["allowed_cells"] = allowed_cells.duplicate()
	agent["departure_access"] = true
	_route_agent(agent, unit.global_position, agent["destination"])
	_agents[unit.get_instance_id()] = agent
	return bool(agent["direct_path"]) or not (agent["path"] as Array).is_empty()


## Exact single-unit parking order. `allowed_cells` normally contains the d/p
## cells of the refinery that owns the reserved dock. Only this agent may stop
## there; they remain ordinary no-stop transit space for every other unit.
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
	avoidance.reset_agent(agent)
	# Refinery d/p cells deliberately receive the harvester body. Its full
	# direction-independent rotation envelope would also cover adjacent solid
	# refinery cells and make the authored dock unreachable. Use capsule width
	# only inside this explicitly reserved corridor; ordinary buildings still
	# use the full nose/tail envelope.
	_set_agent_rotation_envelope(agent, false)
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
	agent["route_lane_offset"] = 0.0
	agent["route_lane_min"] = 0.0
	agent["route_lane_max"] = 0.0
	agent["vacate_no_stop"] = false
	agent["departure_access"] = false
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
	return bool(agent["direct_path"]) or not (agent["path"] as Array).is_empty()


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
	agent["vacate_no_stop"] = false
	if bool(agent.get("departure_access", false)):
		agent["departure_access"] = false
		agent["allowed_cells"] = {}
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
		var stoppable_no_stop_cells: Dictionary = agent.get("allowed_cells", {}).duplicate()
		if bool(agent.get("vacate_no_stop", false)):
			stoppable_no_stop_cells[runtime_map.grid.world_to_grid(destination)] = true
		var raw_path: Array[Vector2i] = planner.find_path(
			runtime_map.grid.world_to_grid(from),
			runtime_map.grid.world_to_grid(destination),
			int(agent["pass_mask"]), int(agent["clearance"]), int(agent["terrain_mask"]),
			stoppable_no_stop_cells
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
		"rotation_radius": agent["rotation_radius"],
		"terrain_radius": agent["terrain_radius"],
		"destination": agent["destination"],
		"command_id": agent["command_id"],
		"mode": agent["mode"],
		"group_speed": agent["group_speed"],
		"hold": agent["hold"],
		"vacate_no_stop": agent["vacate_no_stop"],
		"departure_access": agent["departure_access"],
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
		_release_departure_access_if_clear(agent)
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
		var result := avoidance.resolve_velocity(
			agent, desired, delta, nearby, resolved_positions
		)
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
		# Elastic overlap resolution normally lets overlapping units push each
		# other apart. A held unit, however, owns its exact position (for example
		# a harvester unloading on a refinery pad); only the other agent may move
		# to resolve an overlap with it.
		var separation := Vector3.ZERO if bool(agent["hold"]) \
			else avoidance.separation_velocity(agent, nearby)
		if not separation.is_zero_approx():
			var total := (velocity + separation).limit_length(_unit_speed(unit))
			# Separation may cross friends, but it must not turn the already-safe
			# steering result into motion through an enemy or forbidden terrain.
			if avoidance.motion_is_passable(agent, total * delta) \
			and avoidance.enemy_sweep_fraction(
				agent, total * delta, nearby, resolved_positions
			) >= 0.999:
				velocity = total
				# An idle unit has no spot to defend; it goes where it is pushed
				# instead of fighting its way back into the overlap.
				if int(agent["command_id"]) <= 0 and not bool(agent["hold"]):
					agent["destination"] = unit.global_position + velocity * delta
		velocity = avoidance.stabilize_velocity(
			agent, velocity, delta, nearby, resolved_positions
		)
		_agents[unit.get_instance_id()] = agent
		if unit.has_method("navigation_step"):
			unit.call("navigation_step", velocity, delta)
		# Unit may spend this update turning in place when its rules do not allow
		# simultaneous translation and rotation. Record the actual position so
		# later swept-disc checks do not reserve movement that never happened.
		resolved_positions[unit.get_instance_id()] = unit.global_position
	_refresh_navigation_debug()


func _desired_velocity(agent: Dictionary) -> Vector3:
	var unit: Node3D = agent["unit"]
	agent["steering_target"] = unit.global_position
	if bool(agent["hold"]):
		return Vector3.ZERO
	if float(agent["yield_remaining"]) > 0.0:
		agent["steering_target"] = unit.global_position \
			+ (agent["yield_direction"] as Vector3) * maxf(float(agent["radius"]) * 2.0, 2.0)
		return (agent["yield_direction"] as Vector3) * _unit_speed(unit) * 0.7
	var exit_point: Vector3 = agent["exit_point"]
	if exit_point.is_finite():
		var exit_offset := exit_point - unit.global_position
		exit_offset.y = 0.0
		if exit_offset.length() > maxf(_arrival_radius(unit), float(agent["radius"]) * 0.35):
			agent["steering_target"] = exit_point
			return exit_offset.normalized() * _unit_speed(unit)
		agent["exit_point"] = Vector3.INF
		_route_agent(agent, unit.global_position, agent["destination"])
	var destination: Vector3 = agent["destination"]
	var offset := destination - unit.global_position
	offset.y = 0.0
	agent["steering_target"] = destination
	var arrival := arrival_tolerance(unit)
	if offset.length() <= arrival:
		if not bool(agent.get("vacate_no_stop", false)) or not _auto_vacate_no_stop(agent):
			return Vector3.ZERO
		destination = agent["destination"]
		offset = destination - unit.global_position
		offset.y = 0.0
	var speed := _unit_speed(unit)
	if int(agent["mode"]) == MoveMode.FORMATION:
		speed = minf(speed, float(agent["group_speed"]))
	var direction := Vector3.ZERO
	var path: Array = agent["path"]
	if bool(agent["direct_path"]):
		direction = offset.normalized()
	elif not path.is_empty():
		var path_index := int(agent["path_index"])
		if path_index == 0 and path.size() > 1:
			path_index = 1
		path_index = _advanced_path_index(agent, path, path_index, unit.global_position)
		agent["path_index"] = path_index
		var steering_target := _path_steering_target(
			agent, path, path_index, unit.global_position, speed
		)
		steering_target = _path_lane_target(
			agent, path, path_index, unit.global_position, steering_target, speed
		)
		agent["steering_target"] = steering_target
		direction = unit.global_position.direction_to(steering_target)
		direction.y = 0.0
		direction = direction.normalized()
	if direction.is_zero_approx():
		return Vector3.ZERO
	return direction * speed


func _refresh_navigation_debug() -> void:
	if navigation_debug == null or not navigation_debug.is_inside_tree():
		return
	if not _debug_enabled:
		return
	var snapshots: Array[Dictionary] = []
	for value in _agents.values():
		var agent: Dictionary = value
		var unit: Node3D = agent["unit"]
		if not is_instance_valid(unit) or not &"is_selected" in unit \
		or not bool(unit.get("is_selected")):
			continue
		var height := unit.global_position.y + maxf(float(agent["radius"]) * 0.12, 0.18)
		var position := _debug_height(unit.global_position, height)
		var destination := _debug_height(agent["destination"], height)
		var route: Array[Vector3] = [position]
		var waypoint := Vector3.INF
		var exit_point: Vector3 = agent["exit_point"]
		if exit_point.is_finite():
			waypoint = _debug_height(exit_point, height)
			route.append(waypoint)
		elif bool(agent["direct_path"]):
			waypoint = destination
			route.append(destination)
		else:
			var path: Array = agent["path"]
			if not path.is_empty():
				var path_index := clampi(int(agent["path_index"]), 0, path.size() - 1)
				for index in range(path_index, path.size()):
					var point: Vector3 = runtime_map.grid.grid_to_world(path[index])
					point = _debug_height(point, height)
					if route.back().distance_squared_to(point) > 0.0001:
						route.append(point)
				if route.size() > 1:
					waypoint = route[1]
			if route.back().distance_squared_to(destination) > 0.0001:
				route.append(destination)
		var look_ahead: Vector3 = agent.get("steering_target", Vector3.INF)
		if look_ahead.is_finite():
			look_ahead = _debug_height(look_ahead, height)
		snapshots.append({
			"radius": agent["radius"],
			"route": route,
			"waypoint": waypoint,
			"look_ahead": look_ahead,
			"destination": destination,
		})
	navigation_debug.update_agents(snapshots)


static func _debug_height(point: Vector3, height: float) -> Vector3:
	return Vector3(point.x, height, point.z)


## Follow a point ahead on the compact path instead of aiming at a corner until
## its centre is reached. The look-ahead combines body radius with minimum turn
## radius, so a large slow-turning unit begins one continuous bend earlier.
## A chord across the corner is accepted only while the agent's real swept disc
## remains clear; otherwise a short binary search keeps the furthest safe point.
func _path_steering_target(
		agent: Dictionary,
		path: Array,
		path_index: int,
		position: Vector3,
		speed: float
	) -> Vector3:
	var current: Vector3 = runtime_map.grid.grid_to_world(path[path_index])
	current.y = position.y
	if path_index >= path.size() - 1:
		var destination: Vector3 = agent["destination"]
		destination.y = position.y
		return destination if _path_chord_is_clear(agent, position, destination) else current
	var look_ahead := _path_look_ahead_distance(agent, speed)
	var first_leg := current - position
	first_leg.y = 0.0
	if first_leg.length() >= look_ahead:
		return current
	var remaining := look_ahead - first_leg.length()
	var cursor := current
	var candidate := current
	for index in range(path_index + 1, path.size()):
		var endpoint: Vector3 = runtime_map.grid.grid_to_world(path[index])
		endpoint.y = position.y
		var segment := endpoint - cursor
		segment.y = 0.0
		var length := segment.length()
		if length >= remaining and length > 0.001:
			candidate = cursor + segment / length * remaining
			break
		candidate = endpoint
		remaining -= length
		cursor = endpoint
		if remaining <= 0.001:
			break
	if _path_chord_is_clear(agent, position, candidate):
		return candidate
	if not _path_chord_is_clear(agent, position, current):
		return current
	var safe := current
	var blocked := candidate
	for _iteration in 8:
		var probe := safe.lerp(blocked, 0.5)
		if _path_chord_is_clear(agent, position, probe):
			safe = probe
		else:
			blocked = probe
	return safe


## A compact-path waypoint is a cross-section of the route, not a pin that the
## unit centre must touch. Collision steering can displace a large body past a
## corner without ever entering the old radius-based capture circle. Once it is
## on the outgoing side and still near that segment, progress is monotonic and
## the follower must not turn back toward the missed cell centre.
func _advanced_path_index(
		agent: Dictionary,
		path: Array,
		path_index: int,
		position: Vector3
	) -> int:
	var result := path_index
	var cell_size: Vector2 = runtime_map.grid.cell_size()
	var cell_width := maxf(minf(cell_size.x, cell_size.y), 0.001)
	var capture := maxf(0.35, float(agent["radius"]) * 0.4)
	var corridor := maxf(float(agent["radius"]) * 2.0, cell_width * 1.5)
	while result < path.size() - 1:
		var waypoint: Vector3 = runtime_map.grid.grid_to_world(path[result])
		var next: Vector3 = runtime_map.grid.grid_to_world(path[result + 1])
		waypoint.y = position.y
		next.y = position.y
		var outgoing := next - waypoint
		outgoing.y = 0.0
		var length := outgoing.length()
		if length <= 0.001:
			result += 1
			continue
		outgoing /= length
		var relative := position - waypoint
		relative.y = 0.0
		var along := relative.dot(outgoing)
		var lateral := (relative - outgoing * clampf(along, 0.0, length)).length()
		if relative.length() <= capture or (along > 0.0 and lateral <= corridor):
			result += 1
			continue
		break
	return result


## Preserve the group's cross-route order while several A* paths share a
## corner. In open space lanes remain centred around the path. If one side of a
## waypoint is terrain, the whole set is rebased onto the open side: the
## innermost unit follows the A* centre line and its neighbours remain outside
## it instead of being squeezed into the obstacle.
func _path_lane_target(
		agent: Dictionary,
		path: Array,
		path_index: int,
		position: Vector3,
		base_target: Vector3,
		speed: float
	) -> Vector3:
	if path_index >= path.size() - 1:
		return base_target
	var lane_min := float(agent.get("route_lane_min", 0.0))
	var lane_max := float(agent.get("route_lane_max", 0.0))
	var lane_span := lane_max - lane_min
	if lane_span <= 0.05:
		return base_target
	var forward := base_target - position
	forward.y = 0.0
	if forward.length_squared() <= 0.0001:
		return base_target
	forward = forward.normalized()
	var lateral := forward.cross(Vector3.UP).normalized()
	var probe_distance := maxf(lane_span, float(agent["radius"]) * 0.75)
	var positive := base_target + lateral * probe_distance
	var negative := base_target - lateral * probe_distance
	var positive_open := _has_clear_line(base_target, positive, agent)
	var negative_open := _has_clear_line(base_target, negative, agent)
	var lane_offset := float(agent.get("route_lane_offset", 0.0))
	if positive_open and not negative_open:
		lane_offset -= lane_min
	elif negative_open and not positive_open:
		lane_offset -= lane_max
	elif not positive_open and not negative_open:
		return base_target
	# Merge back into the unit's exact destination instead of carrying a lane
	# offset into the final parking block.
	var destination: Vector3 = agent["destination"]
	destination.y = position.y
	var fade_distance := maxf(_path_look_ahead_distance(agent, speed) * 2.0, 0.001)
	lane_offset *= clampf(base_target.distance_to(destination) / fade_distance, 0.0, 1.0)
	if absf(lane_offset) <= 0.01:
		return base_target
	var candidate := base_target + lateral * lane_offset
	if _path_chord_is_clear(agent, position, candidate):
		return candidate
	# The route can narrow after a broad approach. Retain as much lateral order
	# as the real swept body can reach rather than snapping every unit to centre.
	var safe := base_target
	var blocked := candidate
	for _iteration in 8:
		var probe := safe.lerp(blocked, 0.5)
		if _path_chord_is_clear(agent, position, probe):
			safe = probe
		else:
			blocked = probe
	return safe


func _path_chord_is_clear(agent: Dictionary, from: Vector3, to: Vector3) -> bool:
	# Square visibility belongs to global A*: it is conservative enough to find
	# a route for every footprint, but releases a rounded corner one whole cell
	# at a time. Runtime pursuit already starts at the real unit position, so its
	# swept disc against the rounded obstacle field is both the exact movement
	# constraint and a continuous visibility test. Keeping _has_clear_line here
	# made the yellow look-ahead target advance in visible steps.
	# A unit spawned inside production/refinery body cells temporarily receives
	# an escape sweep which accepts outward motion. That exception is safe for a
	# short movement tick but must not declare an arbitrary long look-ahead chord
	# clear through the building it is leaving.
	if not _agent_cell_passable(agent, runtime_map.grid.world_to_grid(from), 0):
		return _has_clear_line(from, to, agent)
	return avoidance.terrain_sweep_fraction(agent, to - from) >= 0.999


func _path_look_ahead_distance(agent: Dictionary, speed: float) -> float:
	var cell_size: Vector2 = runtime_map.grid.cell_size()
	var cell_width := maxf(minf(cell_size.x, cell_size.y), 0.001)
	var radius_distance := float(agent.get("rotation_radius", agent["radius"])) * 1.5
	var unit: Node3D = agent["unit"]
	var turn_rate_value = unit.get("turn_rate")
	var turn_distance := cell_width
	var omnidirectional_value = unit.get("can_move_any_direction")
	if (omnidirectional_value == null or not bool(omnidirectional_value)) \
	and turn_rate_value != null and float(turn_rate_value) > 0.0:
		var angular_speed := float(turn_rate_value) * NAVIGATION_TICK_RATE
		turn_distance = clampf(speed / angular_speed * 2.5, cell_width, cell_width * 6.0)
	return maxf(radius_distance, turn_distance)


func _release_departure_access_if_clear(agent: Dictionary) -> void:
	if not bool(agent.get("departure_access", false)):
		return
	var allowed: Dictionary = agent["allowed_cells"]
	agent["allowed_cells"] = {}
	_set_agent_rotation_envelope(agent, true)
	var unit: Node3D = agent["unit"]
	var anchor := _parking_anchor(unit.global_position, int(agent["footprint"]))
	if not _block_stoppable(anchor, int(agent["footprint"]), agent):
		_set_agent_rotation_envelope(agent, false)
		agent["allowed_cells"] = allowed
		return
	agent["departure_access"] = false
	_route_agent(agent, unit.global_position, agent["destination"])


## Completes the second half of an ordinary no-stop order. This is internal
## navigation work rather than a new gameplay order, so it must not call
## Unit.prepare_navigation_order() and cancel the unit's action state again.
func _auto_vacate_no_stop(agent: Dictionary) -> bool:
	var unit: Node3D = agent["unit"]
	var span := int(agent["footprint"])
	var anchor := _claim_anchor(
		_parking_anchor(agent["destination"], span),
		agent,
		_reserved_blocks(agent),
		unit.global_position
	)
	if anchor.x < 0:
		return false
	var destination := _block_center(anchor, span)
	destination.y = (agent["destination"] as Vector3).y
	var command_id := _next_command_id
	_next_command_id += 1
	agent["destination"] = destination
	agent["claim_center"] = destination
	agent["command_id"] = command_id
	agent["mode"] = MoveMode.FREE
	agent["group_speed"] = INF
	agent["reserved"] = true
	agent["claim_radius"] = 0.0
	agent["blocked_time"] = 0.0
	agent["reported_enemy"] = false
	agent["exit_point"] = Vector3.INF
	agent["yield_remaining"] = 0.0
	agent["yield_direction"] = Vector3.ZERO
	agent["vacate_no_stop"] = false
	agent["departure_access"] = false
	agent["allowed_cells"] = {}
	_route_agent(agent, unit.global_position, destination)
	if unit.has_method("set_navigation_destination"):
		unit.call("set_navigation_destination", destination)
	var assignment := {
		"unit": unit,
		"agent_id": agent["id"],
		"slot_id": -1,
		"position": destination,
		"available": true,
	}
	_command_log.append({
		"tick": _navigation_tick_index,
		"command_id": command_id,
		"mode": MoveMode.FREE,
		"target": destination,
		"agents": [agent["id"]],
		"slots": [destination],
		"auto_vacate_no_stop": true,
	})
	destination_slots_assigned.emit(command_id, [assignment])
	return true


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
	# Yield is internal steering, not an order. It deliberately bypasses
	# Unit.prepare_navigation_order(), so action state machines and the player's
	# current command remain intact. Commanded agents resume their reserved
	# destination when the short displacement expires (see _navigation_tick).
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


## Captures the group's initial lateral ordering once per player command. The
## value is deliberately geometric rather than agent-id based: units that
## already form an upper/lower row keep that row while the common A* centreline
## bends around terrain. Very scattered groups are clamped to their natural
## resting-pack width so a gather order does not create enormous detours.
func _assign_route_lanes(units: Array[Node3D], world_target: Vector3) -> void:
	if units.is_empty():
		return
	var centroid := Vector3.ZERO
	for unit in units:
		centroid += unit.global_position
	centroid /= float(units.size())
	var travel := world_target - centroid
	travel.y = 0.0
	if units.size() <= 1 or travel.length_squared() <= 0.0001:
		for unit in units:
			var agent: Dictionary = _agents[unit.get_instance_id()]
			agent["route_lane_offset"] = 0.0
			agent["route_lane_min"] = 0.0
			agent["route_lane_max"] = 0.0
		return
	var lateral := travel.normalized().cross(Vector3.UP).normalized()
	var cell: Vector2 = runtime_map.grid.cell_size()
	var lane_limit := ceilf(sqrt(float(units.size()))) * 0.5 \
		* float(_largest_footprint(units) + PARKING_GAP_CELLS) * maxf(cell.x, cell.y)
	var entries: Array[Dictionary] = []
	for unit in units:
		var offset := unit.global_position - centroid
		offset.y = 0.0
		var agent: Dictionary = _agents[unit.get_instance_id()]
		entries.append({
			"unit": unit,
			"raw": clampf(offset.dot(lateral), -lane_limit, lane_limit),
			"radius": float(agent["radius"]),
			"id": int(agent["id"]),
		})
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if is_equal_approx(float(a["raw"]), float(b["raw"])):
			return int(a["id"]) < int(b["id"])
		return float(a["raw"]) < float(b["raw"])
	)
	# Units already in the same longitudinal file have essentially identical
	# lateral coordinates and should keep one lane. Distinct files are expanded
	# only when their authored spacing is narrower than the collision field.
	var clusters: Array[Dictionary] = []
	for entry in entries:
		if clusters.is_empty():
			clusters.append({
				"entries": [entry], "raw_sum": float(entry["raw"]),
				"raw_max": float(entry["raw"]), "radius": float(entry["radius"]),
			})
			continue
		var cluster: Dictionary = clusters.back()
		var same_lane_threshold := minf(float(cluster["radius"]), float(entry["radius"])) * 0.35
		if float(entry["raw"]) - float(cluster["raw_max"]) <= same_lane_threshold:
			(cluster["entries"] as Array).append(entry)
			cluster["raw_sum"] = float(cluster["raw_sum"]) + float(entry["raw"])
			cluster["raw_max"] = float(entry["raw"])
			cluster["radius"] = maxf(float(cluster["radius"]), float(entry["radius"]))
		else:
			clusters.append({
				"entries": [entry], "raw_sum": float(entry["raw"]),
				"raw_max": float(entry["raw"]), "radius": float(entry["radius"]),
			})
	var previous_lane := -INF
	var previous_radius := 0.0
	for cluster in clusters:
		var cluster_entries: Array = cluster["entries"]
		var raw_center := float(cluster["raw_sum"]) / float(cluster_entries.size())
		var lane := raw_center
		if previous_lane > -INF:
			var comfort := minf(previous_radius, float(cluster["radius"])) \
				* ROUTE_LANE_COMFORT_RADIUS_FACTOR
			lane = maxf(lane, previous_lane + previous_radius + float(cluster["radius"]) + comfort)
		cluster["raw_center"] = raw_center
		cluster["lane"] = lane
		previous_lane = lane
		previous_radius = float(cluster["radius"])
	# Expanding from the low side alone would translate the whole formation.
	# Recenter the packed lanes around the midpoint of their original span.
	var raw_midpoint := (float(clusters.front()["raw_center"]) + float(clusters.back()["raw_center"])) * 0.5
	var lane_midpoint := (float(clusters.front()["lane"]) + float(clusters.back()["lane"])) * 0.5
	var recenter := raw_midpoint - lane_midpoint
	var offsets := {}
	var lane_min := INF
	var lane_max := -INF
	for cluster in clusters:
		var lane := float(cluster["lane"]) + recenter
		for entry in cluster["entries"]:
			offsets[(entry["unit"] as Node3D).get_instance_id()] = lane
		lane_min = minf(lane_min, lane)
		lane_max = maxf(lane_max, lane)
	for unit in units:
		var agent: Dictionary = _agents[unit.get_instance_id()]
		agent["route_lane_offset"] = float(offsets[unit.get_instance_id()])
		agent["route_lane_min"] = lane_min
		agent["route_lane_max"] = lane_max


func _assign_slots(units: Array[Node3D], world_target: Vector3, mode: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var occupied: Array[Dictionary] = []
	var spacing := _largest_footprint(units) + PARKING_GAP_CELLS
	var allow_no_stop := runtime_map.is_no_stop(runtime_map.grid.world_to_grid(world_target))
	for index in units.size():
		var unit := units[index]
		var agent: Dictionary = _agents[unit.get_instance_id()]
		var span := int(agent["footprint"])
		var preferred := _parking_anchor(world_target, span)
		if mode == MoveMode.FORMATION:
			preferred += _formation_offset(index, units.size(), float(spacing))
		else:
			preferred += _crowd_offset(index) * spacing
		var anchor := _claim_passable_anchor(preferred, agent, occupied, unit.global_position) \
			if allow_no_stop else _find_slot(preferred, agent, occupied)
		var position: Vector3 = _block_center(anchor, span) if anchor.x >= 0 else unit.global_position
		position.y = world_target.y
		var assignment := {
			"unit": unit,
			"agent_id": agent["id"],
			"slot_id": index,
			"position": position,
			"available": anchor.x >= 0,
			"vacate_no_stop": anchor.x >= 0 and not _block_stoppable(anchor, span, agent),
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
	var occupied: Array[Dictionary] = []
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
	var allow_no_stop := runtime_map.is_no_stop(runtime_map.grid.world_to_grid(world_target))
	for index in units.size():
		var unit := units[index]
		var agent: Dictionary = _agents[unit.get_instance_id()]
		var span := int(agent["footprint"])
		var offset := unit.global_position - centroid
		offset.y = 0.0
		var aim := world_target + offset.limit_length(pack_radius)
		# When the aim lies inside a building footprint, approach it radially from
		# this unit's current side. A ring-first search otherwise picks a corner
		# before the centered cell on the same side of a rectangular building.
		var preferred := _parking_anchor(aim, span)
		var anchor := _claim_passable_anchor(preferred, agent, occupied, unit.global_position) \
			if allow_no_stop else _approach_anchor(preferred, agent, unit.global_position)
		var position := _block_center(anchor, span) if anchor.x >= 0 else aim
		position.y = world_target.y
		var vacate_no_stop := anchor.x >= 0 and not _block_stoppable(anchor, span, agent)
		result.append({
			"unit": unit,
			"agent_id": agent["id"],
			"slot_id": index,
			"position": position,
			"available": true,
			"claim_center": world_target if gather else position,
			"vacate_no_stop": vacate_no_stop,
		})
		if allow_no_stop and anchor.x >= 0:
			occupied.append({"anchor": anchor, "span": span})
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
		if int(agent["command_id"]) <= 0 or not bool(agent["reserved"]) or bool(agent["hold"]) \
		or bool(agent.get("vacate_no_stop", false)):
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


## Initial FREE-move aim selection. Walks outward from a blocked target toward
## the unit, so approaching a building does not send every unit to whichever
## corner happens to occur on the first valid Chebyshev ring.
func _approach_anchor(preferred: Vector2i, agent: Dictionary, from: Vector3) -> Vector2i:
	var span := int(agent["footprint"])
	var from_anchor := _parking_anchor(from, span)
	var delta := from_anchor - preferred
	var length := maxi(absi(delta.x), absi(delta.y))
	if length > 0:
		var limit := mini(length, SLOT_SEARCH_RADIUS)
		for distance in range(0, limit + 1):
			var weight := float(distance) / float(length)
			var offset := Vector2i(
				roundi(float(delta.x) * weight),
				roundi(float(delta.y) * weight)
			)
			var candidate := preferred + offset
			if _block_stoppable(candidate, span, agent):
				return candidate
	return _claim_anchor(preferred, agent, [], from)


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


## No-stop command legs need the same nearest, non-overlapping block search as
## ordinary parking, but accept any traversable block for their temporary end.
func _claim_passable_anchor(
		preferred: Vector2i,
		agent: Dictionary,
		occupied: Array[Dictionary],
		from: Vector3
	) -> Vector2i:
	var span := int(agent["footprint"])
	for radius in range(0, SLOT_SEARCH_RADIUS + 1):
		var best := Vector2i(-1, -1)
		var best_distance := INF
		for offset in _ring_offsets(radius):
			var anchor := preferred + offset
			if not _block_passable(anchor, span, agent):
				continue
			var occupied_block := false
			for other in occupied:
				if _blocks_conflict(anchor, span, other["anchor"], int(other["span"])):
					occupied_block = true
					break
			if occupied_block:
				continue
			var distance := from.distance_to(_block_center(anchor, span))
			if distance < best_distance:
				best_distance = distance
				best = anchor
		if best.x >= 0:
			return best
	return Vector2i(-1, -1)


func _block_passable(anchor: Vector2i, span: int, agent: Dictionary) -> bool:
	for y in span:
		for x in span:
			if not _agent_cell_passable(agent, anchor + Vector2i(x, y)):
				return false
	return true


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


func _movement_probe_for(unit: Node3D) -> Dictionary:
	var registered := _agent_for(unit)
	if not registered.is_empty():
		return {
			"clearance": registered["rotation_clearance"],
			"pass_mask": registered["pass_mask"],
			"terrain_mask": registered["terrain_mask"],
			"footprint": registered["footprint"],
			"allowed_cells": {},
		}
	var profile := _profile_for(unit)
	return {
		"clearance": profile["clearance"],
		"pass_mask": profile["pass_mask"],
		"terrain_mask": profile["terrain_mask"],
		"footprint": profile["footprint"],
		"allowed_cells": {},
	}


func _profile_for(unit: Node3D) -> Dictionary:
	var config = unit.get("unit_definition")
	var infantry := bool(config.infantry) if config != null else false
	var can_fly := bool(config.can_fly) if config != null else false
	var size := float(config.size) if config != null else 1.0
	var radius := maxf(0.35, size * 0.42)
	if unit.has_method("navigation_collision_radius"):
		radius = float(unit.call("navigation_collision_radius", radius))
	var rotation_radius := radius
	if unit.has_method("navigation_rotation_radius"):
		rotation_radius = maxf(
			radius, float(unit.call("navigation_rotation_radius", rotation_radius))
		)
	var cell_size: Vector2 = runtime_map.grid.cell_size()
	var body_clearance := maxi(
		0,
		int(ceil(radius / maxf(minf(cell_size.x, cell_size.y), 0.001))) - 1
	)
	var clearance := maxi(
		0,
		int(ceil(rotation_radius / maxf(minf(cell_size.x, cell_size.y), 0.001))) - 1
	)
	var pass_mask := MapNavigationGrid.PASS_AIR if can_fly else (MapNavigationGrid.PASS_INFANTRY if infantry else MapNavigationGrid.PASS_VEHICLE)
	var terrain_mask := _terrain_mask(config.terrain_ids if config != null else [])
	# `size` is the side of the unit's square footprint in navigation cells;
	# destinations are always the center of a free size x size cell block.
	var footprint := maxi(1, roundi(size))
	return {
		"radius": radius,
		"rotation_radius": rotation_radius,
		"body_clearance": body_clearance,
		"clearance": clearance,
		"pass_mask": pass_mask,
		"terrain_mask": terrain_mask,
		"footprint": footprint,
	}


func _set_agent_rotation_envelope(agent: Dictionary, active: bool) -> void:
	agent["terrain_radius"] = agent["rotation_radius"] if active else agent["radius"]
	agent["clearance"] = agent["rotation_clearance"] \
		if active else agent["body_clearance"]


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
	for node in get_tree().get_nodes_in_group("buildings"):
		var building := node as Node3D
		if building == null or not _owns_node(building):
			continue
		var config = building.get("building_definition") as Resource \
			if "building_definition" in building else null
		if config == null:
			var config_id := StringName(str(building.get("config_id")))
			config = _building_definition_catalog.definition(config_id)
		if config == null:
			continue
		var rows: Array = config.occupy_rows
		var footprint: Dictionary = BuildingFootprintScript.nav_cells_by_marker(
			building, rows, runtime_map.grid, OCCUPY_CELL_SPAN
		)
		for cell in footprint:
			# Skirts, doors and pads are transit space, but ordinary orders must
			# not park there. The refinery grants its reserved harvester a local
			# d/p stopping exception; authored building body cells stay solid.
			var marker := String(footprint[cell]).to_lower()
			var target := no_stop if marker in ["s", "d", "p"] else blocked
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
		var destination_anchor := _parking_anchor(destination, span)
		var destination_stoppable := _block_stoppable(destination_anchor, span, agent)
		if bool(agent.get("vacate_no_stop", false)) and destination_stoppable:
			agent["vacate_no_stop"] = false
		if not destination_stoppable \
		and not (bool(agent.get("vacate_no_stop", false)) and _block_passable(destination_anchor, span, agent)):
			var replacement := _find_slot(_parking_anchor(destination, span), agent, _reserved_blocks(agent))
			if replacement.x >= 0:
				var height := destination.y
				destination = _block_center(replacement, span)
				destination.y = height
				agent["destination"] = destination
				agent["vacate_no_stop"] = false
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


func _unit_speed(unit: Node3D) -> float:
	if unit.has_method("navigation_move_speed"):
		return maxf(float(unit.call("navigation_move_speed")), 0.0)
	var value = unit.get("move_speed")
	return maxf(float(value), 0.0) if value != null else 0.0


func _unit_cruise_speed(unit: Node3D) -> float:
	var value = unit.get("move_speed")
	return maxf(float(value), 0.0) if value != null else 0.0


func _arrival_radius(unit: Node3D) -> float:
	var value = unit.get("arrival_radius")
	return float(value) if value != null else 0.2


func _slowest_speed(units: Array[Node3D]) -> float:
	var speed := INF
	for unit in units:
		# Formation pace is a persistent cap. Capturing a mech's temporary
		# between-step speed here would pin the whole group to that low phase.
		speed = minf(speed, _unit_cruise_speed(unit))
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
