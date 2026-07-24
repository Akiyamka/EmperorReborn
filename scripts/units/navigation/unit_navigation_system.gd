class_name UnitNavigationSystem
extends Node
## Match-scoped RTS navigation coordinator. It owns path work and destination
## assignment, delegates short-range collision steering to UnitLocalAvoidance,
## and leaves presentation/terrain following to Unit.

const UnitNavigationMapScript := preload("res://scripts/units/navigation/unit_navigation_map.gd")
const UnitNavigationPlannerScript := preload("res://scripts/units/navigation/unit_navigation_planner.gd")
const UnitLocalAvoidanceScript := preload("res://scripts/units/navigation/unit_local_avoidance.gd")
const UnitNavigationDebugScript := preload("res://scripts/units/navigation/unit_navigation_debug.gd")
const NavAgentRegistryScript := preload("res://scripts/units/navigation/shared/nav_agent_registry.gd")
const NavSpatialHashScript := preload("res://scripts/units/navigation/shared/nav_spatial_hash.gd")
const GroundSlotAllocatorScript := preload("res://scripts/units/navigation/ground/ground_slot_allocator.gd")
const GroundPathFollowerScript := preload("res://scripts/units/navigation/ground/ground_path_follower.gd")
const NavBlockerTrackerScript := preload("res://scripts/units/navigation/shared/nav_blocker_tracker.gd")
const GroundNavigationScript := preload("res://scripts/units/navigation/ground/ground_navigation.gd")
const PathFunnelScript := preload("res://scripts/units/navigation/ground/path_funnel.gd")
const AirNavigationScript := preload("res://scripts/units/navigation/air/air_navigation.gd")
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
## A building-blocker change only reroutes agents whose stored corridor or
## destination block actually overlaps the changed cells (see
## `_agent_route_intersects`); this caps how many of those dirty agents get an
## actual `find_path` re-run per navigation tick so a large simultaneous change
## (e.g. a building placed in the middle of a crowd) cannot burst every
## commanded agent's A* in one frame.
const REROUTE_BUDGET_PER_TICK := 8

var runtime_map = UnitNavigationMapScript.new()
var planner = UnitNavigationPlannerScript.new()
var avoidance = UnitLocalAvoidanceScript.new()
var navigation_debug = UnitNavigationDebugScript.new()
var registry := NavAgentRegistryScript.new()
var spatial_hash := NavSpatialHashScript.new()
var slot_allocator := GroundSlotAllocatorScript.new()
var path_follower := GroundPathFollowerScript.new()
var path_funnel := PathFunnelScript.new()
var blocker_tracker := NavBlockerTrackerScript.new()
var ground_navigation := GroundNavigationScript.new()
var air_navigation := AirNavigationScript.new()

var _agents: Dictionary = {}
var _next_command_id := 1
var _navigation_tick_index := 0
var _navigation_accumulator := 0.0
var _blocker_refresh_remaining := 0.0
var _command_log: Array[Dictionary] = []
var _debug_enabled := false
## Agent keys (unit instance ids) queued for a budgeted reroute after a
## building-blocker change; see `_replan_after_map_change`/`_process_reroute_queue`.
var _reroute_queue: Array = []


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
	registry.setup(self)
	slot_allocator.setup(self)
	path_follower.setup(self)
	path_funnel.setup(self)
	blocker_tracker.setup(self)
	ground_navigation.setup(self)
	air_navigation.setup(self)
	_refresh_building_blockers()
	if is_inside_tree():
		for node in get_tree().get_nodes_in_group("units"):
			if node is Node3D and _owns_node(node):
				register_unit(node)
	return true


func register_unit(unit: Node3D) -> int:
	return registry.register_unit(_agents, unit, _debug_enabled)


func unregister_unit(unit: Node3D) -> void:
	registry.unregister_unit(_agents, unit)


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
		if int(agent["pass_mask"]) == MapNavigationGrid.PASS_AIR \
		and registry.domain_for({"pass_mask": agent["pass_mask"], "unit": unit}) == NavAgentRegistryScript.Domain.AIR:
			if air_navigation.in_bounds(world_target):
				return true
			continue
		if _ground_target_is_legal(agent, world_target, allow_no_stop) \
		and _ground_target_is_reachable(unit, agent, world_target, allow_no_stop):
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
	# A landed flyer swept into a group selection never went through
	# Unit.move_to() (command controllers call this facade directly), so its
	# own takeoff redirect never ran. Peel it off here and let it take off
	# through the normal single-unit path instead of being routed as ground.
	var remaining: Array[Node3D] = []
	for unit in ordered:
		var config = unit.get("unit_definition")
		var flies := config != null and bool(config.can_fly)
		if flies and unit.has_method("flight_is_landed") and bool(unit.call("flight_is_landed")) \
		and unit.has_method("move_to"):
			unit.call("move_to", world_target, exit_point)
		else:
			remaining.append(unit)
	ordered = remaining
	# Reject an exact, otherwise legal ground destination when it belongs to a
	# different connected component. Doing this before prepare_navigation_order
	# keeps an impossible click from cancelling the unit's current gameplay
	# action. Blocked clicks are retained: slot allocation deliberately turns
	# those into a reachable approach point on the unit's side of the obstacle.
	remaining = []
	var clicked_no_stop: bool = runtime_map.grid != null \
		and runtime_map.is_no_stop(runtime_map.grid.world_to_grid(world_target))
	for unit in ordered:
		var agent: Dictionary = _movement_probe_for(unit)
		var is_air := int(agent["pass_mask"]) == MapNavigationGrid.PASS_AIR \
			and registry.domain_for({"pass_mask": agent["pass_mask"], "unit": unit}) == NavAgentRegistryScript.Domain.AIR
		if not is_air \
		and _ground_target_is_legal(agent, world_target, clicked_no_stop) \
		and not _ground_target_is_reachable(unit, agent, world_target, clicked_no_stop):
			continue
		remaining.append(unit)
	ordered = remaining
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
	var ground_units: Array[Node3D] = []
	var air_units: Array[Node3D] = []
	for unit in ordered:
		var agent: Dictionary = _agents[unit.get_instance_id()]
		avoidance.reset_agent(agent)
		_set_agent_rotation_envelope(agent, true)
		agent["allowed_cells"] = {}
		agent["vacate_no_stop"] = false
		agent["departure_access"] = false
		agent["domain"] = registry.domain_for(agent)
		_agents[unit.get_instance_id()] = agent
		if int(agent["domain"]) == NavAgentRegistryScript.Domain.AIR:
			air_units.append(unit)
		else:
			ground_units.append(unit)

	var command_id := _next_command_id
	_next_command_id += 1
	var group_speed := _slowest_speed(ordered) if mode == MoveMode.FORMATION else INF
	var assignments: Array[Dictionary] = []
	if not ground_units.is_empty():
		assignments += _assign_slots(ground_units, world_target, mode) \
			if mode == MoveMode.FORMATION else _shared_target_assignments(ground_units, world_target)
	if not air_units.is_empty():
		assignments += air_navigation.target_assignments(_agents, air_units, world_target)
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
	_assign_route_lanes(ground_units, world_target)
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
	agent["domain"] = registry.domain_for(agent)
	if int(agent["domain"]) == NavAgentRegistryScript.Domain.AIR:
		air_navigation.route_agent(agent, from, destination)
	else:
		ground_navigation.route_agent(agent, from, destination)


## AStarGrid2D returns every crossed cell. Keeping that raw list made every
## moving agent rediscover the same visible corner on every navigation tick.
## First retain only direction changes, then greedily join mutually visible
## turns. Runtime steering consequently follows a handful of stable waypoints.
func _simplify_path(raw_path: Array[Vector2i], agent: Dictionary) -> Array[Vector2i]:
	return ground_navigation.simplify_path(raw_path, agent)


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
	_process_reroute_queue()
	var ordered := _ordered_agents()
	registry.update_domains(ordered)
	var ground_agents: Array[Dictionary] = []
	var air_agents: Array[Dictionary] = []
	for agent in ordered:
		if int(agent["domain"]) == NavAgentRegistryScript.Domain.AIR:
			air_agents.append(agent)
		else:
			ground_agents.append(agent)
	var claimants: Array[Dictionary] = []
	for agent in ground_agents:
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
	_uncross_assignments(ground_agents)
	var ground_buckets := _build_spatial_hash(ground_agents)
	ground_navigation.tick(delta, ground_agents, ground_buckets)
	if not air_agents.is_empty():
		var air_buckets := _build_spatial_hash(air_agents)
		air_navigation.tick(delta, air_agents, air_buckets)
	_refresh_navigation_debug()


func _desired_velocity(agent: Dictionary) -> Vector3:
	if int(agent.get("domain", NavAgentRegistryScript.Domain.GROUND)) == NavAgentRegistryScript.Domain.AIR:
		return air_navigation.desired_velocity(agent)
	return ground_navigation.desired_velocity(agent)


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
				var path_points: Array = ground_navigation.path_points_for(agent)
				var path_index := clampi(int(agent["path_index"]), 0, path_points.size() - 1)
				for index in range(path_index, path_points.size()):
					var point: Vector3 = _debug_height(path_points[index], height)
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
	return path_follower.path_steering_target(agent, path, path_index, position, speed)


## A compact-path waypoint is a cross-section of the route, not a pin that the
## unit centre must touch. Collision steering can displace a large body past a
## corner without ever entering the old radius-based capture circle. Once it is
## on the outgoing side and still near that segment, progress is monotonic and
## the follower must not turn back toward the missed cell centre.
func _advanced_path_index(
		agent: Dictionary,
		path: Array,
		path_index: int,
		position: Vector3,
		speed := 0.0
	) -> int:
	return path_follower.advanced_path_index(agent, path, path_index, position, speed)


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
	return path_follower.path_lane_target(agent, path, path_index, position, base_target, speed)


func _path_chord_is_clear(agent: Dictionary, from: Vector3, to: Vector3) -> bool:
	return path_follower.path_chord_is_clear(agent, from, to)


func _path_look_ahead_distance(agent: Dictionary, speed: float) -> float:
	return path_follower.path_look_ahead_distance(agent, speed)


func _release_departure_access_if_clear(agent: Dictionary) -> void:
	path_follower.release_departure_access_if_clear(agent)


## Completes the second half of an ordinary no-stop order. This is internal
## navigation work rather than a new gameplay order, so it must not call
## Unit.prepare_navigation_order() and cancel the unit's action state again.
func _auto_vacate_no_stop(agent: Dictionary) -> bool:
	return path_follower.auto_vacate_no_stop(agent)


func _has_clear_line(from: Vector3, to: Vector3, agent: Dictionary) -> bool:
	return path_follower.has_clear_line(from, to, agent)


func _agent_cell_passable(
		agent: Dictionary,
		cell: Vector2i,
		clearance_cells := -1,
		allowed_terrain_mask := -1
	) -> bool:
	return path_follower.agent_cell_passable(agent, cell, clearance_cells, allowed_terrain_mask)


func _agent_cell_stoppable(
		agent: Dictionary,
		cell: Vector2i,
		clearance_cells := -1,
		allowed_terrain_mask := -1
	) -> bool:
	return path_follower.agent_cell_stoppable(agent, cell, clearance_cells, allowed_terrain_mask)


## A yielding friend steps sideways out of the requester's lane (toward the
## side it is already offset to), not along it — walking the lane keeps it in
## front of the requester and drags it deep into the crowd.
func _yield_direction(requester: Node3D, friend: Node3D, desired: Vector3) -> Vector3:
	return ground_navigation.yield_direction(requester, friend, desired)


func _request_yield(unit: Node3D, direction: Vector3) -> void:
	ground_navigation.request_yield(unit, direction)


func _is_en_route(agent: Dictionary) -> bool:
	return ground_navigation.is_en_route(agent)


## Captures the group's initial lateral ordering once per player command. The
## value is deliberately geometric rather than agent-id based: units that
## already form an upper/lower row keep that row while the common A* centreline
## bends around terrain. Very scattered groups are clamped to their natural
## resting-pack width so a gather order does not create enormous detours.
func _assign_route_lanes(units: Array[Node3D], world_target: Vector3) -> void:
	slot_allocator.assign_route_lanes(_agents, units, world_target)


func _assign_slots(units: Array[Node3D], world_target: Vector3, mode: int) -> Array[Dictionary]:
	return slot_allocator.assign_slots(_agents, units, world_target, mode)


## FREE moves do not pre-plan parking slots: a pre-assigned interior slot
## belongs to whoever happens to arrive last, and the crowd has to fight itself
## to deliver that unit. Each unit aims at the target translated by its own
## offset inside the pack (clamped to the resting pack radius), so the group
## moves as a shape instead of funnelling through one point, then claims the
## best free block on approach (_try_claim_slot), packing in arrival order.
func _shared_target_assignments(units: Array[Node3D], world_target: Vector3) -> Array[Dictionary]:
	return slot_allocator.shared_target_assignments(_agents, units, world_target)


## The moment a FREE-move unit gets near the shared target it claims a parking
## block: the most central free one, tie-broken toward its own approach side so
## claims do not cross the crowd.
func _try_claim_slot(agent: Dictionary) -> void:
	slot_allocator.try_claim_slot(_agents, agent)


## Uncrosses parking assignments within a command: when two units would each
## travel further to their own blocks than to each other's, they trade blocks
## instead of trying to push their bodies past one another. Crossed pairs are
## what makes a nudged pack fight itself indefinitely.
func _uncross_assignments(agents: Array[Dictionary]) -> void:
	slot_allocator.uncross_assignments(agents)


## Parking blocks already promised to other agents: reserved destinations only,
## so shared aim points of units that have not claimed yet do not count.
func _reserved_blocks(agent: Dictionary) -> Array[Dictionary]:
	return slot_allocator.reserved_blocks(_agents, agent)


func _claim_radius_for(units: Array[Node3D]) -> float:
	return slot_allocator.claim_radius_for(_agents, units)


func _find_slot(preferred: Vector2i, agent: Dictionary, occupied: Array[Dictionary]) -> Vector2i:
	return slot_allocator.find_slot(preferred, agent, occupied)


## Initial FREE-move aim selection. Walks outward from a blocked target toward
## the unit, so approaching a building does not send every unit to whichever
## corner happens to occur on the first valid Chebyshev ring.
func _approach_anchor(preferred: Vector2i, agent: Dictionary, from: Vector3) -> Vector2i:
	return slot_allocator.approach_anchor(preferred, agent, from)


## Ring search for a free grid-aligned footprint block: every cell of the
## span x span block must be stoppable and the block may not overlap a block in
## `occupied` ({anchor, span} entries). Inner rings keep priority; ties within
## a ring resolve toward `from`.
func _claim_anchor(preferred: Vector2i, agent: Dictionary, occupied: Array[Dictionary], from: Vector3) -> Vector2i:
	return slot_allocator.claim_anchor(preferred, agent, occupied, from)


## No-stop command legs need the same nearest, non-overlapping block search as
## ordinary parking, but accept any traversable block for their temporary end.
func _claim_passable_anchor(
		preferred: Vector2i,
		agent: Dictionary,
		occupied: Array[Dictionary],
		from: Vector3
	) -> Vector2i:
	return slot_allocator.claim_passable_anchor(preferred, agent, occupied, from)


func _block_passable(anchor: Vector2i, span: int, agent: Dictionary) -> bool:
	return slot_allocator.block_passable(anchor, span, agent)


func _block_stoppable(anchor: Vector2i, span: int, agent: Dictionary) -> bool:
	return slot_allocator.block_stoppable(anchor, span, agent)


## Two parking blocks conflict when fewer than PARKING_GAP_CELLS free cells
## separate them (in either axis), not only on actual overlap.
func _blocks_conflict(a: Vector2i, a_span: int, b: Vector2i, b_span: int) -> bool:
	return slot_allocator.blocks_conflict(a, a_span, b, b_span)


## World center of a span x span cell block anchored at its lowest cell. For
## even spans the center sits on the shared cell corner.
func _block_center(anchor: Vector2i, span: int) -> Vector3:
	return slot_allocator.block_center(anchor, span)


## Anchor cell of the block whose center lies nearest to `point`.
func _parking_anchor(point: Vector3, span: int) -> Vector2i:
	return slot_allocator.parking_anchor(point, span)


## Nearest free grid-aligned block center for the agent, avoiding every other
## agent's reserved parking block. Falls back to `point` when nothing is free.
func _snapped_parking(agent: Dictionary, point: Vector3) -> Vector3:
	return slot_allocator.snapped_parking(_agents, agent, point)


func _ring_offsets(radius: int) -> Array[Vector2i]:
	return slot_allocator.ring_offsets(radius)


func _crowd_offset(index: int) -> Vector2i:
	return slot_allocator.crowd_offset(index)


func _formation_offset(index: int, count: int, spacing: float) -> Vector2i:
	return slot_allocator.formation_offset(index, count, spacing)


func _build_spatial_hash(agents: Array[Dictionary]) -> Dictionary:
	return spatial_hash.build(agents)


func _nearby_agents(position: Vector3, buckets: Dictionary, search_radius := CELL_BUCKET_SIZE) -> Array:
	return spatial_hash.nearby(position, buckets, search_radius)


func _bucket_key(position: Vector3) -> Vector2i:
	return spatial_hash.bucket_key(position)


func _ordered_agents() -> Array[Dictionary]:
	return registry.ordered_agents(_agents)


func _prune_agents() -> void:
	registry.prune_agents(_agents)


func _agent_for(unit: Node3D) -> Dictionary:
	return registry.agent_for(_agents, unit)


func _movement_probe_for(unit: Node3D) -> Dictionary:
	return registry.movement_probe_for(_agents, unit)


func _ground_target_is_legal(agent: Dictionary, world_target: Vector3, allow_no_stop: bool) -> bool:
	var span: int = int(agent["footprint"])
	var anchor: Vector2i = _parking_anchor(world_target, span)
	return _block_passable(anchor, span, agent) if allow_no_stop \
		else _block_stoppable(anchor, span, agent)


func _ground_target_is_reachable(
		unit: Node3D, agent: Dictionary, world_target: Vector3, allow_no_stop := false
	) -> bool:
	var span: int = int(agent["footprint"])
	var anchor: Vector2i = _parking_anchor(world_target, span)
	var target_center := _block_center(anchor, span)
	var target_cell: Vector2i = runtime_map.grid.world_to_grid(target_center)
	var stoppable_no_stop_cells := {target_cell: true} if allow_no_stop else {}
	return planner.is_reachable(
		runtime_map.grid.world_to_grid(unit.global_position),
		target_cell,
		int(agent["pass_mask"]), int(agent["clearance"]), int(agent["terrain_mask"]),
		stoppable_no_stop_cells
	)


func _profile_for(unit: Node3D) -> Dictionary:
	return registry.profile_for(unit)


func _set_agent_rotation_envelope(agent: Dictionary, active: bool) -> void:
	registry.set_agent_rotation_envelope(agent, active)


func _terrain_mask(names: Array) -> int:
	return registry.terrain_mask(names)


func _refresh_building_blockers() -> void:
	blocker_tracker.refresh_building_blockers()


## Blocker refreshes run independently of navigation ticks, so an agent's unit
## may have been freed since the last regular pruning pass. Only identifies
## agents whose route the change might have invalidated and queues them for a
## budgeted reroute (`_process_reroute_queue`) — replanning every commanded
## agent unconditionally here is what used to turn a single building change
## into an O(N) full-A* burst.
func _replan_after_map_change() -> void:
	blocker_tracker.replan_after_map_change()


## True when a building-blocker change might invalidate `agent`'s current
## route: its destination block, or (for an A*-routed agent) any raw cell
## along its stored corridor, or (for a direct-path agent, which has no
## corridor) its straight line no longer being clear, lies in/crosses
## `changed_lookup`. The corridor check looks at the whole corridor rather
## than only the remaining cells ahead of the follower's path index — the raw
## corridor's indices do not line up with the simplified waypoint list's
## `path_index` cursor, and reconciling that would need restructuring the path
## representation, which is out of scope for this pass. The corridor is
## bounded in length and this only runs on the rare tick a blocker actually
## changes, so scanning all of it (or re-checking one direct line) is still
## cheap next to the previous unconditional full replan of every commanded
## agent.
func _agent_route_intersects(agent: Dictionary, changed_lookup: Dictionary) -> bool:
	return blocker_tracker.agent_route_intersects(agent, changed_lookup)


## Drains up to REROUTE_BUDGET_PER_TICK agents from `_reroute_queue` each
## navigation tick, so a large simultaneous blocker change spreads its A*
## re-runs over several ticks instead of stalling one frame. Queued agents
## keep following their existing (possibly slightly stale, but still mostly
## valid) path until their turn comes.
func _process_reroute_queue() -> void:
	blocker_tracker.process_reroute_queue()


func _empty_occupy_marker(marker: String) -> bool:
	return blocker_tracker.empty_occupy_marker(marker)


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
