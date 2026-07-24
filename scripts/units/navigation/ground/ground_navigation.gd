class_name GroundNavigation
extends RefCounted
## Ground agent per-tick steering: desired-velocity computation (slots/lanes/
## exit-point/yield), avoidance resolution, blocked/enemy reporting, and yield
## requests. Also owns the two path-computation entry points (`route_agent`,
## `simplify_path`) that every command handler and the reroute queue call to
## (re)plan an agent's route.

var _facade: Node


func setup(facade: Node) -> void:
	_facade = facade


## Computes the whole route synchronously: either a clear straight line or a
## native A* grid path, so the unit can move on the very next navigation tick.
## While an exit point is pending the unit is steered straight at it instead;
## routing takes over from there once it is reached.
func route_agent(agent: Dictionary, from: Vector3, destination: Vector3) -> void:
	agent["path"] = [] as Array[Vector2i]
	agent["path_index"] = 0
	agent["corridor"] = PackedInt32Array()
	agent["direct_path"] = false
	if (agent["exit_point"] as Vector3).is_finite():
		return
	agent["direct_path"] = _facade._has_clear_line(from, destination, agent)
	if not bool(agent["direct_path"]):
		var stoppable_no_stop_cells: Dictionary = agent.get("allowed_cells", {}).duplicate()
		if bool(agent.get("vacate_no_stop", false)):
			stoppable_no_stop_cells[_facade.runtime_map.grid.world_to_grid(destination)] = true
		var raw_path: Array[Vector2i] = _facade.planner.find_path(
			_facade.runtime_map.grid.world_to_grid(from),
			_facade.runtime_map.grid.world_to_grid(destination),
			int(agent["pass_mask"]), int(agent["clearance"]), int(agent["terrain_mask"]),
			stoppable_no_stop_cells
		)
		agent["path"] = simplify_path(raw_path, agent)
		var corridor := PackedInt32Array()
		corridor.resize(raw_path.size())
		for index in raw_path.size():
			corridor[index] = _facade.runtime_map.grid.cell_index(raw_path[index])
		agent["corridor"] = corridor


## AStarGrid2D returns every crossed cell. Keeping that raw list made every
## moving agent rediscover the same visible corner on every navigation tick.
## First retain only direction changes, then greedily join mutually visible
## turns. Runtime steering consequently follows a handful of stable waypoints.
func simplify_path(raw_path: Array[Vector2i], agent: Dictionary) -> Array[Vector2i]:
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
		var from: Vector3 = _facade.runtime_map.grid.grid_to_world(turns[anchor_index])
		for probe_index in range(anchor_index + 2, turns.size()):
			var to: Vector3 = _facade.runtime_map.grid.grid_to_world(turns[probe_index])
			if not _facade._has_clear_line(from, to, agent):
				break
			furthest_visible = probe_index
		result.append(turns[furthest_visible])
		anchor_index = furthest_visible
	return result


func desired_velocity(agent: Dictionary) -> Vector3:
	var unit: Node3D = agent["unit"]
	agent["steering_target"] = unit.global_position
	if bool(agent["hold"]):
		return Vector3.ZERO
	if float(agent["yield_remaining"]) > 0.0:
		agent["steering_target"] = unit.global_position \
			+ (agent["yield_direction"] as Vector3) * maxf(float(agent["radius"]) * 2.0, 2.0)
		return (agent["yield_direction"] as Vector3) * _facade._unit_speed(unit) * 0.7
	var exit_point: Vector3 = agent["exit_point"]
	if exit_point.is_finite():
		var exit_offset := exit_point - unit.global_position
		exit_offset.y = 0.0
		if exit_offset.length() > maxf(_facade._arrival_radius(unit), float(agent["radius"]) * 0.35):
			agent["steering_target"] = exit_point
			return exit_offset.normalized() * _facade._unit_speed(unit)
		agent["exit_point"] = Vector3.INF
		route_agent(agent, unit.global_position, agent["destination"])
	var destination: Vector3 = agent["destination"]
	var offset := destination - unit.global_position
	offset.y = 0.0
	agent["steering_target"] = destination
	var arrival: float = _facade.arrival_tolerance(unit)
	if offset.length() <= arrival:
		if not bool(agent.get("vacate_no_stop", false)) or not _facade._auto_vacate_no_stop(agent):
			return Vector3.ZERO
		destination = agent["destination"]
		offset = destination - unit.global_position
		offset.y = 0.0
	var speed: float = _facade._unit_speed(unit)
	if int(agent["mode"]) == UnitNavigationSystem.MoveMode.FORMATION:
		speed = minf(speed, float(agent["group_speed"]))
	var direction := Vector3.ZERO
	var path: Array = agent["path"]
	if bool(agent["direct_path"]):
		direction = offset.normalized()
	elif not path.is_empty():
		var path_index := int(agent["path_index"])
		if path_index == 0 and path.size() > 1:
			path_index = 1
		path_index = _facade._advanced_path_index(agent, path, path_index, unit.global_position)
		agent["path_index"] = path_index
		var steering_target: Vector3 = _facade._path_steering_target(
			agent, path, path_index, unit.global_position, speed
		)
		steering_target = _facade._path_lane_target(
			agent, path, path_index, unit.global_position, steering_target, speed
		)
		agent["steering_target"] = steering_target
		direction = unit.global_position.direction_to(steering_target)
		direction.y = 0.0
		direction = direction.normalized()
	if direction.is_zero_approx():
		return Vector3.ZERO
	return direction * speed


## A yielding friend steps sideways out of the requester's lane (toward the
## side it is already offset to), not along it — walking the lane keeps it in
## front of the requester and drags it deep into the crowd.
func yield_direction(requester: Node3D, friend: Node3D, desired: Vector3) -> Vector3:
	var lateral := desired.normalized().cross(Vector3.UP)
	var side := friend.global_position - requester.global_position
	side.y = 0.0
	if lateral.dot(side) < 0.0:
		lateral = -lateral
	return lateral.normalized()


func request_yield(unit: Node3D, direction: Vector3) -> void:
	# Yield is internal steering, not an order. It deliberately bypasses
	# Unit.prepare_navigation_order(), so action state machines and the player's
	# current command remain intact. Commanded agents resume their reserved
	# destination when the short displacement expires (see tick()).
	var agent: Dictionary = _facade._agent_for(unit)
	if agent.is_empty() or bool(agent["hold"]) or direction.is_zero_approx():
		return
	# A unit already following a route normally clears the queue by itself. The
	# request mainly displaces idle friendlies that occupy a choke point.
	if is_en_route(agent) and float(agent["yield_remaining"]) <= 0.0:
		return
	agent["yield_direction"] = direction
	agent["yield_remaining"] = UnitNavigationSystem.FRIENDLY_YIELD_SECONDS
	_facade._agents[unit.get_instance_id()] = agent


func is_en_route(agent: Dictionary) -> bool:
	if int(agent["command_id"]) <= 0:
		return false
	var unit: Node3D = agent["unit"]
	var offset: Vector3 = (agent["destination"] as Vector3) - unit.global_position
	offset.y = 0.0
	return offset.length() > maxf(_facade._arrival_radius(unit), float(agent["radius"]) * 0.35)


## Per-agent steering resolution for one navigation tick, in the exact order
## the facade's `_ordered_agents()` list provides (determinism: yield/claim/
## resolved-position bookkeeping all depend on this order being stable).
func tick(delta: float, ordered: Array[Dictionary], buckets: Dictionary) -> void:
	var largest_radius := 0.0
	for value in ordered:
		largest_radius = maxf(largest_radius, float(value["radius"]))
	var resolved_positions: Dictionary = {}
	for agent in ordered:
		var unit: Node3D = agent["unit"]
		var desired := desired_velocity(agent)
		var nearby: Array = _facade._nearby_agents(
			unit.global_position,
			buckets,
			float(agent["radius"]) + largest_radius
		)
		var result: Dictionary = _facade.avoidance.resolve_velocity(
			agent, desired, delta, nearby, resolved_positions
		)
		var velocity: Vector3 = result["velocity"]
		if desired.length_squared() > 0.01 and velocity.length_squared() < 0.01:
			agent["blocked_time"] = float(agent["blocked_time"]) + delta
		else:
			agent["blocked_time"] = 0.0
			agent["reported_enemy"] = false
		if float(agent["blocked_time"]) >= UnitNavigationSystem.ENEMY_BLOCK_SECONDS and not bool(agent["reported_enemy"]):
			var enemies: Array[Node3D] = result["enemies"]
			if not enemies.is_empty():
				agent["reported_enemy"] = true
				_facade.enemy_blocked.emit(unit, enemies)
				if unit.has_method("navigation_blocked_by_enemy"):
					unit.call("navigation_blocked_by_enemy", enemies)
		if float(agent["blocked_time"]) >= UnitNavigationSystem.FRIENDLY_YIELD_TRIGGER_SECONDS:
			for friend in result["friends"]:
				request_yield(friend, yield_direction(unit, friend, desired))
		if float(agent["yield_remaining"]) > 0.0:
			agent["yield_remaining"] = maxf(0.0, float(agent["yield_remaining"]) - delta)
			if is_zero_approx(float(agent["yield_remaining"])):
				if int(agent["command_id"]) > 0:
					# A commanded unit owns a unique reserved block nobody else
					# will claim: walk back to it once the passer is through.
					route_agent(agent, unit.global_position, agent["destination"])
				else:
					# An idle unit displaced off a choke point must not return
					# (it would displace the passer forever); it parks on the
					# nearest free grid block instead.
					agent["destination"] = _facade._snapped_parking(agent, unit.global_position + velocity * delta)
					agent["reserved"] = true
					route_agent(agent, unit.global_position, agent["destination"])
		# Elastic overlap resolution normally lets overlapping units push each
		# other apart. A held unit, however, owns its exact position (for example
		# a harvester unloading on a refinery pad); only the other agent may move
		# to resolve an overlap with it.
		var separation: Vector3 = Vector3.ZERO if bool(agent["hold"]) \
			else _facade.avoidance.separation_velocity(agent, nearby)
		if not separation.is_zero_approx():
			var total: Vector3 = (velocity + separation).limit_length(_facade._unit_speed(unit))
			# Separation may cross friends, but it must not turn the already-safe
			# steering result into motion through an enemy or forbidden terrain.
			if _facade.avoidance.motion_is_passable(agent, total * delta) \
			and _facade.avoidance.enemy_sweep_fraction(
				agent, total * delta, nearby, resolved_positions
			) >= 0.999:
				velocity = total
				# An idle unit has no spot to defend; it goes where it is pushed
				# instead of fighting its way back into the overlap.
				if int(agent["command_id"]) <= 0 and not bool(agent["hold"]):
					agent["destination"] = unit.global_position + velocity * delta
		velocity = _facade.avoidance.stabilize_velocity(
			agent, velocity, delta, nearby, resolved_positions
		)
		_facade._agents[unit.get_instance_id()] = agent
		if unit.has_method("navigation_step"):
			unit.call("navigation_step", velocity, delta)
		# Unit may spend this update turning in place when its rules do not allow
		# simultaneous translation and rotation. Record the actual position so
		# later swept-disc checks do not reserve movement that never happened.
		resolved_positions[unit.get_instance_id()] = unit.global_position
