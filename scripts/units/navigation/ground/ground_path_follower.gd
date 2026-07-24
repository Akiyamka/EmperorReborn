class_name GroundPathFollower
extends RefCounted
## Runtime pursuit of a compact A* path: look-ahead steering target, monotonic
## waypoint advancement, cross-route lane offsetting, and the swept-disc
## visibility tests (chord/line-of-sight, per-cell passable/stoppable) that
## everything else in ground navigation treats as the real movement
## constraint. Also owns the two "second half of an order" continuations that
## only make sense once the follower has delivered the unit: releasing a
## harvester's temporary refinery-apron access, and auto-parking off no-stop
## transit space.

var _facade: Node


func setup(facade: Node) -> void:
	_facade = facade


## Follow a point ahead on the compact path instead of aiming at a corner until
## its centre is reached. The look-ahead combines body radius with minimum turn
## radius, so a large slow-turning unit begins one continuous bend earlier.
## A chord across the corner is accepted only while the agent's real swept disc
## remains clear; otherwise a short binary search keeps the furthest safe point.
func path_steering_target(
		agent: Dictionary,
		path: Array,
		path_index: int,
		position: Vector3,
		speed: float
	) -> Vector3:
	var current: Vector3 = _facade.runtime_map.grid.grid_to_world(path[path_index])
	current.y = position.y
	if path_index >= path.size() - 1:
		var destination: Vector3 = agent["destination"]
		destination.y = position.y
		return destination if path_chord_is_clear(agent, position, destination) else current
	var look_ahead := path_look_ahead_distance(agent, speed)
	var first_leg := current - position
	first_leg.y = 0.0
	if first_leg.length() >= look_ahead:
		return current
	var remaining := look_ahead - first_leg.length()
	var cursor := current
	var candidate := current
	for index in range(path_index + 1, path.size()):
		var endpoint: Vector3 = _facade.runtime_map.grid.grid_to_world(path[index])
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
	if path_chord_is_clear(agent, position, candidate):
		return candidate
	if not path_chord_is_clear(agent, position, current):
		return current
	var safe := current
	var blocked := candidate
	for _iteration in 8:
		var probe := safe.lerp(blocked, 0.5)
		if path_chord_is_clear(agent, position, probe):
			safe = probe
		else:
			blocked = probe
	return safe


## A compact-path waypoint is a cross-section of the route, not a pin that the
## unit centre must touch. Collision steering can displace a large body past a
## corner without ever entering the old radius-based capture circle. Once it is
## on the outgoing side and still near that segment, progress is monotonic and
## the follower must not turn back toward the missed cell centre.
func advanced_path_index(
		agent: Dictionary,
		path: Array,
		path_index: int,
		position: Vector3
	) -> int:
	var result := path_index
	var cell_size: Vector2 = _facade.runtime_map.grid.cell_size()
	var cell_width := maxf(minf(cell_size.x, cell_size.y), 0.001)
	var capture := maxf(0.35, float(agent["radius"]) * 0.4)
	var corridor := maxf(float(agent["radius"]) * 2.0, cell_width * 1.5)
	while result < path.size() - 1:
		var waypoint: Vector3 = _facade.runtime_map.grid.grid_to_world(path[result])
		var next: Vector3 = _facade.runtime_map.grid.grid_to_world(path[result + 1])
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
func path_lane_target(
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
	var positive_open := has_clear_line(base_target, positive, agent)
	var negative_open := has_clear_line(base_target, negative, agent)
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
	var fade_distance := maxf(path_look_ahead_distance(agent, speed) * 2.0, 0.001)
	lane_offset *= clampf(base_target.distance_to(destination) / fade_distance, 0.0, 1.0)
	if absf(lane_offset) <= 0.01:
		return base_target
	var candidate := base_target + lateral * lane_offset
	if path_chord_is_clear(agent, position, candidate):
		return candidate
	# The route can narrow after a broad approach. Retain as much lateral order
	# as the real swept body can reach rather than snapping every unit to centre.
	var safe := base_target
	var blocked := candidate
	for _iteration in 8:
		var probe := safe.lerp(blocked, 0.5)
		if path_chord_is_clear(agent, position, probe):
			safe = probe
		else:
			blocked = probe
	return safe


func path_chord_is_clear(agent: Dictionary, from: Vector3, to: Vector3) -> bool:
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
	if not agent_cell_passable(agent, _facade.runtime_map.grid.world_to_grid(from), 0):
		return has_clear_line(from, to, agent)
	return _facade.avoidance.terrain_sweep_fraction(agent, to - from) >= 0.999


func path_look_ahead_distance(agent: Dictionary, speed: float) -> float:
	var cell_size: Vector2 = _facade.runtime_map.grid.cell_size()
	var cell_width := maxf(minf(cell_size.x, cell_size.y), 0.001)
	var radius_distance := float(agent.get("rotation_radius", agent["radius"])) * 1.5
	var unit: Node3D = agent["unit"]
	var turn_rate_value = unit.get("turn_rate")
	var turn_distance := cell_width
	var omnidirectional_value = unit.get("can_move_any_direction")
	if (omnidirectional_value == null or not bool(omnidirectional_value)) \
	and turn_rate_value != null and float(turn_rate_value) > 0.0:
		var angular_speed := float(turn_rate_value) * UnitNavigationSystem.NAVIGATION_TICK_RATE
		turn_distance = clampf(speed / angular_speed * 2.5, cell_width, cell_width * 6.0)
	return maxf(radius_distance, turn_distance)


func release_departure_access_if_clear(agent: Dictionary) -> void:
	if not bool(agent.get("departure_access", false)):
		return
	var allowed: Dictionary = agent["allowed_cells"]
	agent["allowed_cells"] = {}
	_facade._set_agent_rotation_envelope(agent, true)
	var unit: Node3D = agent["unit"]
	var anchor: Vector2i = _facade._parking_anchor(unit.global_position, int(agent["footprint"]))
	if not _facade._block_stoppable(anchor, int(agent["footprint"]), agent):
		_facade._set_agent_rotation_envelope(agent, false)
		agent["allowed_cells"] = allowed
		return
	agent["departure_access"] = false
	_facade._route_agent(agent, unit.global_position, agent["destination"])


## Completes the second half of an ordinary no-stop order. This is internal
## navigation work rather than a new gameplay order, so it must not call
## Unit.prepare_navigation_order() and cancel the unit's action state again.
func auto_vacate_no_stop(agent: Dictionary) -> bool:
	var unit: Node3D = agent["unit"]
	var span := int(agent["footprint"])
	var anchor: Vector2i = _facade._claim_anchor(
		_facade._parking_anchor(agent["destination"], span),
		agent,
		_facade._reserved_blocks(agent),
		unit.global_position
	)
	if anchor.x < 0:
		return false
	var destination: Vector3 = _facade._block_center(anchor, span)
	destination.y = (agent["destination"] as Vector3).y
	var command_id: int = _facade._next_command_id
	_facade._next_command_id += 1
	agent["destination"] = destination
	agent["claim_center"] = destination
	agent["command_id"] = command_id
	agent["mode"] = UnitNavigationSystem.MoveMode.FREE
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
	_facade._route_agent(agent, unit.global_position, destination)
	if unit.has_method("set_navigation_destination"):
		unit.call("set_navigation_destination", destination)
	var assignment := {
		"unit": unit,
		"agent_id": agent["id"],
		"slot_id": -1,
		"position": destination,
		"available": true,
	}
	_facade._command_log.append({
		"tick": _facade._navigation_tick_index,
		"command_id": command_id,
		"mode": UnitNavigationSystem.MoveMode.FREE,
		"target": destination,
		"agents": [agent["id"]],
		"slots": [destination],
		"auto_vacate_no_stop": true,
	})
	_facade.destination_slots_assigned.emit(command_id, [assignment])
	return true


func has_clear_line(from: Vector3, to: Vector3, agent: Dictionary) -> bool:
	var start: Vector2i = _facade.runtime_map.grid.world_to_grid(from)
	var finish: Vector2i = _facade.runtime_map.grid.world_to_grid(to)
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
		if not agent_cell_passable(agent, cell):
			return false
		var step: Vector2i = cell - previous
		if step.x != 0 and step.y != 0:
			if not agent_cell_passable(agent, previous + Vector2i(step.x, 0)):
				return false
			if not agent_cell_passable(agent, previous + Vector2i(0, step.y)):
				return false
		previous = cell
	return true


func agent_cell_passable(
		agent: Dictionary,
		cell: Vector2i,
		clearance_cells := -1,
		allowed_terrain_mask := -1
	) -> bool:
	var clearance := int(agent["clearance"]) if clearance_cells < 0 else clearance_cells
	var terrain_mask := int(agent["terrain_mask"]) if allowed_terrain_mask < 0 else allowed_terrain_mask
	var pass_mask := int(agent["pass_mask"])
	if _facade.runtime_map.is_passable(cell, pass_mask, clearance, terrain_mask):
		return true
	var allowed: Dictionary = agent.get("allowed_cells", {})
	if allowed.is_empty():
		return false
	for y in range(-clearance, clearance + 1):
		for x in range(-clearance, clearance + 1):
			var sample := cell + Vector2i(x, y)
			if not _facade.runtime_map.grid.is_passable(sample, pass_mask):
				return false
			if terrain_mask != 0 and (terrain_mask & (1 << _facade.runtime_map.grid.terrain_at(sample))) == 0:
				return false
			if _facade.runtime_map.is_blocked(sample) and not allowed.has(sample):
				return false
	return true


func agent_cell_stoppable(
		agent: Dictionary,
		cell: Vector2i,
		clearance_cells := -1,
		allowed_terrain_mask := -1
	) -> bool:
	var clearance := int(agent["clearance"]) if clearance_cells < 0 else clearance_cells
	var terrain_mask := int(agent["terrain_mask"]) if allowed_terrain_mask < 0 else allowed_terrain_mask
	var pass_mask := int(agent["pass_mask"])
	if _facade.runtime_map.is_stoppable(cell, pass_mask, clearance, terrain_mask):
		return true
	var allowed: Dictionary = agent.get("allowed_cells", {})
	if allowed.is_empty():
		return false
	for y in range(-clearance, clearance + 1):
		for x in range(-clearance, clearance + 1):
			var sample := cell + Vector2i(x, y)
			if not _facade.runtime_map.grid.is_passable(sample, pass_mask):
				return false
			if terrain_mask != 0 and (terrain_mask & (1 << _facade.runtime_map.grid.terrain_at(sample))) == 0:
				return false
			if (_facade.runtime_map.is_blocked(sample) or _facade.runtime_map.is_no_stop(sample)) \
			and not allowed.has(sample):
				return false
	return true
