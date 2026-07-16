class_name UnitLocalAvoidance
extends RefCounted
## Continuous local steering layered on top of the discrete A* route.
##
## Pathfinding owns only the list of waypoints. This class owns the short-range
## geometry between them: units are swept discs, an impassable navigation cell
## is an inscribed disc (so an isolated cell is genuinely round), friendly
## personal space is a soft field, and only enemies/terrain remain hard limits.

const CONTACT_BUFFER := 0.05
const STEERING_LOOKAHEAD_SECONDS := 0.4
const SQUEEZE_SPEED_FACTOR := 0.5
const SEPARATION_STIFFNESS := 2.5
const SEPARATION_MAX_SPEED_FACTOR := 0.35
const FRIEND_COMFORT_RADIUS_FACTOR := 0.35
const TERRAIN_SOFT_MARGIN_CELLS := 0.8
const TERRAIN_PRESSURE_WEIGHT := 0.65
const PASSING_SIDE_BIAS := 0.06
const STEERING_CONTINUITY_WEIGHT := 0.22
const STEERING_SIDE_SWITCH_PENALTY := 0.18
const STEERING_TURN_RATE_SHARE := 0.85
const STEERING_CLOSE_TARGET_MAX_BEARING := 0.65
const STEERING_DRIVEN_ARC_MAX_BEARING := 1.7
const STEERING_CLOSE_TARGET_TURN_RADIUS_FACTOR := 1.25
const STEERING_DEFLECTION_EPSILON := 0.03
const MIN_ROUTE_PROGRESS_DOT := -0.001
const RULE_MOVEMENT_UPDATES_PER_SECOND := 20.0
const OBSTACLE_BUCKET_CELLS := 8

## Small angles let large round bodies slide along a boundary instead of
## alternating between two coarse, mutually blocking detours.
const CANDIDATE_ANGLES := [
	0.0,
	0.25, -0.25,
	0.5, -0.5,
	0.8, -0.8,
	1.1, -1.1,
	1.4, -1.4,
	PI / 2.0, -PI / 2.0,
]

## The lattice above quantizes the course to 0.25 rad notches. While the
## pressured base direction rotates smoothly along an obstacle boundary, a
## purely discrete winner alternates between adjacent notches and a chassis
## that can meet each request within one tick visibly wags left and right.
## A short ternary search between the winner's neighbours keeps the returned
## course a continuous function of the agent's state.
const CANDIDATE_REFINEMENT_SPAN := 0.125
const CANDIDATE_REFINEMENT_STEPS := 5

## Score-space hysteresis alone cannot damp the position-mediated feedback
## loop along a boundary: steering toward the optimum moves the body, and the
## moved body's sweep fractions push the next optimum back the other way, so
## the commanded course alternates at half the tick rate and the chassis
## visibly wags. Rotating the previous course only this share of the way to
## the new optimum makes the loop converge. Genuine manoeuvres are unaffected:
## for any course gap a rules-limited chassis can act on, this step is larger
## than the chassis' own turn step.
const STEERING_COURSE_DAMPING_SHARE := 0.35

var runtime_map = null
var _obstacle_profiles: Dictionary = {}


func setup(source_runtime_map) -> void:
	runtime_map = source_runtime_map
	_obstacle_profiles.clear()


func prewarm(pass_mask: int, terrain_mask: int) -> void:
	_obstacle_profile(pass_mask, terrain_mask)


func reset_agent(agent: Dictionary) -> void:
	_clear_preference(agent)
	agent["steering_turn_in_place"] = false


func _clear_preference(agent: Dictionary) -> void:
	agent["avoidance_direction"] = Vector3.ZERO
	agent["avoidance_side"] = 0


## Friends first behave as expanded soft discs. If they close every forward or
## lateral lane, the second pass removes only those soft discs and lets units
## squeeze through at reduced speed. Terrain and enemies are never removed.
func resolve_velocity(
		agent: Dictionary,
		desired: Vector3,
		delta: float,
		nearby: Array,
		resolved: Dictionary
	) -> Dictionary:
	if desired.is_zero_approx():
		reset_agent(agent)
		return _empty_result()
	var unit: Node3D = agent["unit"]
	var blockers := []
	for other in nearby:
		if other["unit"] != unit:
			blockers.append(other)
	# The same small obstacle set is reused by every candidate. Re-scanning the
	# grid per angle makes dense battles scale with candidates x nearby cells.
	var terrain := _terrain_context(
		agent, desired.length() * STEERING_LOOKAHEAD_SECONDS
	)
	var pressure := _terrain_pressure_from(agent, terrain)
	var pressured_desired := _apply_pressure(desired, pressure)
	var preferred_direction: Vector3 = agent.get("avoidance_direction", Vector3.ZERO)
	var preferred_side := int(agent.get("avoidance_side", 0))
	# Course damping only fights the feedback loop with static geometry; against
	# moving units it merely delays reciprocal manoeuvres and prolongs contact.
	var dampen_course := not pressure.is_zero_approx()
	var full := _evaluate_candidates(
		agent, pressured_desired, desired.normalized(), delta, blockers, resolved, terrain, 1.0,
		preferred_direction, preferred_side, dampen_course
	)
	var velocity: Vector3 = full["velocity"]
	var chosen: Dictionary = full
	if not bool(full["has_escape"]):
		var hard_blockers := []
		for other in blockers:
			if _are_enemies(unit, other["unit"]):
				hard_blockers.append(other)
		var squeeze := _evaluate_candidates(
			agent,
			pressured_desired,
			desired.normalized(),
			delta,
			hard_blockers,
			resolved,
			terrain,
			SQUEEZE_SPEED_FACTOR,
			preferred_direction,
			preferred_side,
			dampen_course
		)
		if bool(squeeze["has_escape"]):
			velocity = squeeze["velocity"]
			chosen = squeeze
	var chosen_direction: Vector3 = chosen["direction"]
	var avoidance_active := not pressure.is_zero_approx() or bool(chosen["avoidance_active"])
	if avoidance_active and not chosen_direction.is_zero_approx():
		agent["avoidance_direction"] = chosen_direction
		var chosen_side := int(chosen["side"])
		if chosen_side != 0:
			agent["avoidance_side"] = chosen_side
	else:
		_clear_preference(agent)
	return {
		"velocity": velocity,
		"enemies": full["enemies"],
		"friends": full["friends"],
	}


func _evaluate_candidates(
		agent: Dictionary,
		steering_desired: Vector3,
		route_direction: Vector3,
		delta: float,
		blockers: Array,
		resolved: Dictionary,
		terrain: Dictionary,
		speed_scale: float,
		preferred_direction: Vector3,
		preferred_side: int,
		dampen_course: bool
	) -> Dictionary:
	var scaled := steering_desired * speed_scale
	var enemies: Array[Node3D] = []
	var friends: Array[Node3D] = []
	var best := {}
	var best_angle := 0.0
	var has_escape := false
	for angle in CANDIDATE_ANGLES:
		var evaluation := _candidate_evaluation(
			agent, float(angle), scaled, steering_desired, route_direction, delta,
			blockers, resolved, terrain, preferred_direction, preferred_side,
			enemies, friends
		)
		if evaluation.is_empty():
			continue
		if float(evaluation["predicted_fraction"]) >= 0.999:
			has_escape = true
		if best.is_empty() or float(evaluation["score"]) > float(best["score"]):
			best = evaluation
			best_angle = float(angle)
	# Un-quantize the winner: keep the furthest safe course between its lattice
	# neighbours instead of snapping to the notch itself.
	if not best.is_empty():
		var low := best_angle - CANDIDATE_REFINEMENT_SPAN
		var high := best_angle + CANDIDATE_REFINEMENT_SPAN
		for _iteration in CANDIDATE_REFINEMENT_STEPS:
			var left_angle := lerpf(low, high, 1.0 / 3.0)
			var right_angle := lerpf(low, high, 2.0 / 3.0)
			var left := _candidate_evaluation(
				agent, left_angle, scaled, steering_desired, route_direction, delta,
				blockers, resolved, terrain, preferred_direction, preferred_side,
				enemies, friends
			)
			var right := _candidate_evaluation(
				agent, right_angle, scaled, steering_desired, route_direction, delta,
				blockers, resolved, terrain, preferred_direction, preferred_side,
				enemies, friends
			)
			var left_score := float(left["score"]) if not left.is_empty() else -INF
			var right_score := float(right["score"]) if not right.is_empty() else -INF
			if left_score > float(best["score"]):
				best = left
			if right_score > float(best["score"]):
				best = right
			if left_score >= right_score:
				high = right_angle
			else:
				low = left_angle
	# Damp the commanded course: follow the previous course a bounded share of
	# the way toward this tick's optimum. The damped course is re-swept through
	# the same evaluation, so every hard boundary still applies to the returned
	# velocity.
	if dampen_course and not best.is_empty() and not preferred_direction.is_zero_approx():
		var course_gap := preferred_direction.normalized().signed_angle_to(
			best["direction"] as Vector3, Vector3.UP
		)
		if absf(course_gap) > 0.005:
			var damped_direction := (preferred_direction.normalized() as Vector3) \
				.rotated(Vector3.UP, course_gap * STEERING_COURSE_DAMPING_SHARE)
			var damped_angle := (scaled.normalized() as Vector3).signed_angle_to(
				damped_direction, Vector3.UP
			)
			var damped := _candidate_evaluation(
				agent, damped_angle, scaled, steering_desired, route_direction, delta,
				blockers, resolved, terrain, preferred_direction, preferred_side,
				enemies, friends
			)
			if not damped.is_empty():
				best = damped
	if best.is_empty():
		return {
			"velocity": Vector3.ZERO,
			"enemies": enemies,
			"friends": friends,
			"has_escape": has_escape,
			"direction": Vector3.ZERO,
			"side": 0,
			"avoidance_active": false,
		}
	var best_direction: Vector3 = best["direction"]
	return {
		"velocity": best["velocity"],
		"enemies": enemies,
		"friends": friends,
		"has_escape": has_escape,
		"direction": best_direction,
		"side": best["side"],
		"avoidance_active": float(best["fraction"]) < 0.999 \
			or float(best["predicted_fraction"]) < 0.999 \
			or route_direction.angle_to(best_direction) > STEERING_DEFLECTION_EPSILON,
	}


func _candidate_evaluation(
		agent: Dictionary,
		angle: float,
		scaled: Vector3,
		steering_desired: Vector3,
		route_direction: Vector3,
		delta: float,
		blockers: Array,
		resolved: Dictionary,
		terrain: Dictionary,
		preferred_direction: Vector3,
		preferred_side: int,
		enemies: Array[Node3D],
		friends: Array[Node3D]
	) -> Dictionary:
	var unit: Node3D = agent["unit"]
	var desired_speed := scaled.length()
	var candidate := scaled.rotated(Vector3.UP, angle)
	var candidate_direction := candidate.normalized()
	# Avoidance may slow the route down or slide sideways, but it must not
	# turn a stable path target into a reverse order. Near a rounded boundary
	# the old PI candidate alternated with the forward candidate after only a
	# few pixels of movement, making slow-turning harvesters rotate 180 degrees
	# back and forth. A genuine retreat belongs to a new route/yield decision,
	# which has the persistence that per-tick candidate scoring does not.
	if candidate_direction.dot(route_direction) < MIN_ROUTE_PROGRESS_DOT:
		return {}
	var candidate_side := _side_of(route_direction, candidate_direction)
	var actual_displacement := candidate * delta
	var terrain_fraction := _terrain_sweep_fraction_from(
		agent, actual_displacement, terrain
	)
	var prediction := steering_desired.rotated(Vector3.UP, angle) \
		* STEERING_LOOKAHEAD_SECONDS
	var predicted_fraction := _terrain_sweep_fraction_from(
		agent, prediction, terrain
	)
	var unit_fraction := 1.0
	for other in blockers:
		var other_unit: Node3D = other["unit"]
		var other_position: Vector3 = resolved.get(
			other_unit.get_instance_id(), other_unit.global_position
		)
		var combined := float(agent["radius"]) + float(other["radius"])
		var actual_safe := sweep_fraction(
			unit.global_position, actual_displacement, other_position, combined
		)
		var prediction_radius := combined
		if not _are_enemies(unit, other_unit):
			prediction_radius += minf(float(agent["radius"]), float(other["radius"])) \
				* FRIEND_COMFORT_RADIUS_FACTOR
		var predicted_safe := sweep_fraction(
			unit.global_position, prediction, other_position, prediction_radius
		)
		unit_fraction = minf(unit_fraction, actual_safe)
		predicted_fraction = minf(predicted_fraction, predicted_safe)
		if predicted_safe < 0.999 or actual_safe < 0.999:
			if _are_enemies(unit, other_unit):
				if not enemies.has(other_unit):
					enemies.append(other_unit)
			elif not friends.has(other_unit):
				friends.append(other_unit)
	var fraction := minf(unit_fraction, terrain_fraction)
	var velocity := candidate * fraction
	var projected := candidate * predicted_fraction
	var score := projected.dot(route_direction) - absf(angle) * 0.05 * desired_speed
	# Keep the chosen arc until it stops making useful progress. Without this
	# hysteresis adjacent angle samples trade first place as a round corner's
	# pressure vector changes, making slow-turning chassis repeatedly correct.
	if not preferred_direction.is_zero_approx():
		score -= (1.0 - clampf(
			preferred_direction.normalized().dot(candidate_direction), -1.0, 1.0
		)) * STEERING_CONTINUITY_WEIGHT * desired_speed
	if preferred_side != 0 and candidate_side != 0 and candidate_side != preferred_side:
		score -= STEERING_SIDE_SWITCH_PENALTY * desired_speed
	# A persistent right-hand traffic preference makes reciprocal agents choose
	# complementary world-space sides instead of changing their minds each tick.
	if not blockers.is_empty() and not is_zero_approx(angle):
		score += signf(angle) * PASSING_SIDE_BIAS * desired_speed
	if fraction < 0.15:
		score -= desired_speed
	return {
		"score": score,
		"velocity": velocity,
		"direction": candidate_direction,
		"side": candidate_side,
		"fraction": fraction,
		"predicted_fraction": predicted_fraction,
	}


## A non-omnidirectional Unit otherwise receives a new, instantly rotated
## velocity every navigation tick, while Unit.navigation_step must stop until
## its chassis catches that heading. Limit the requested course to slightly
## less than the same rules turn step, so a corner becomes one driven arc.
## If that intermediate arc would cross a hard boundary, retain the already
## safe target: the unit then turns in place instead of cutting the corner.
func stabilize_velocity(
		agent: Dictionary,
		proposed: Vector3,
		delta: float,
		nearby: Array,
		resolved: Dictionary
	) -> Vector3:
	if proposed.is_zero_approx() or delta <= 0.0:
		agent["steering_turn_in_place"] = false
		return proposed
	var unit: Node3D = agent["unit"]
	if not unit.has_method("facing_direction"):
		return proposed
	var omnidirectional = unit.get("can_move_any_direction")
	if omnidirectional != null and bool(omnidirectional):
		return proposed
	var turn_rate_value = unit.get("turn_rate")
	if turn_rate_value == null or float(turn_rate_value) <= 0.0:
		return proposed
	var facing: Vector3 = unit.call("facing_direction")
	facing.y = 0.0
	if facing.is_zero_approx():
		return proposed
	facing = facing.normalized()
	var target_direction := proposed.normalized()
	var difference := facing.signed_angle_to(target_direction, Vector3.UP)
	var maximum_step := float(turn_rate_value) * RULE_MOVEMENT_UPDATES_PER_SECOND \
		* delta * STEERING_TURN_RATE_SHARE
	if bool(agent.get("steering_turn_in_place", false)):
		if absf(difference) <= maximum_step:
			agent["steering_turn_in_place"] = false
		else:
			return proposed
	if absf(difference) <= maximum_step:
		return proposed
	# A large bearing only creates an orbit when the pursuit point is inside the
	# chassis' turn circle. Far corners should start a driven arc; stopping there
	# turns every smoothly moving look-ahead target into visible stop-and-go.
	# A genuinely reverse bearing still turns in place instead of making a wide
	# U-turn away from the order.
	var angular_speed := float(turn_rate_value) * RULE_MOVEMENT_UPDATES_PER_SECOND
	var turn_radius := proposed.length() / maxf(angular_speed, 0.001)
	var steering_target: Vector3 = agent.get("steering_target", unit.global_position)
	var target_offset := steering_target - unit.global_position
	target_offset.y = 0.0
	var close_target := target_offset.length() <= maxf(
		float(agent["radius"]), turn_radius * STEERING_CLOSE_TARGET_TURN_RADIUS_FACTOR
	)
	if absf(difference) > STEERING_DRIVEN_ARC_MAX_BEARING \
	or (close_target and absf(difference) > STEERING_CLOSE_TARGET_MAX_BEARING):
		agent["steering_turn_in_place"] = true
		return proposed
	var reachable_direction := facing.rotated(
		Vector3.UP, clampf(difference, -maximum_step, maximum_step)
	).normalized()
	var reachable := reachable_direction * proposed.length()
	var displacement := reachable * delta
	var hard_fraction := terrain_sweep_fraction(agent, displacement)
	hard_fraction = minf(
		hard_fraction,
		enemy_sweep_fraction(agent, displacement, nearby, resolved)
	)
	if hard_fraction <= 0.001:
		agent["steering_turn_in_place"] = true
		return proposed
	return reachable * hard_fraction


## Hard terrain fraction for a swept unit disc against nearby round cells.
## Starting in a truly forbidden cell keeps the production/refinery escape
## exception: the route may move outward until its centre reaches open ground.
func terrain_sweep_fraction(agent: Dictionary, displacement: Vector3) -> float:
	return _terrain_sweep_fraction_from(
		agent, displacement, _terrain_context(agent, displacement.length())
	)


func _terrain_sweep_fraction_from(
		agent: Dictionary,
		displacement: Vector3,
		terrain: Dictionary
	) -> float:
	if runtime_map == null or runtime_map.grid == null:
		return 0.0
	if bool(terrain.get("escape", false)):
		return 1.0
	var unit: Node3D = agent["unit"]
	var start := unit.global_position
	var combined := float(terrain["hard_radius"])
	var fraction := 1.0
	for value in terrain["obstacles"]:
		fraction = minf(
			fraction,
			sweep_fraction(start, displacement, value as Vector3, combined)
		)
	return fraction


func motion_is_passable(agent: Dictionary, displacement: Vector3) -> bool:
	return terrain_sweep_fraction(agent, displacement) >= 0.999


## Smooth repulsion begins before hard contact. It biases candidate generation
## but never authorizes motion through the hard swept-disc limit above.
func terrain_pressure(agent: Dictionary) -> Vector3:
	return _terrain_pressure_from(
		agent, _terrain_context(agent, 0.0)
	)


func _terrain_pressure_from(agent: Dictionary, terrain: Dictionary) -> Vector3:
	if runtime_map == null or runtime_map.grid == null:
		return Vector3.ZERO
	if bool(terrain.get("escape", false)):
		return Vector3.ZERO
	var unit: Node3D = agent["unit"]
	var position := unit.global_position
	var soft_margin := float(terrain["soft_margin"])
	var field_radius := float(terrain["field_radius"])
	var pressure := Vector3.ZERO
	for value in terrain["obstacles"]:
		var away := position - (value as Vector3)
		away.y = 0.0
		var distance := away.length()
		if distance >= field_radius:
			continue
		if distance <= 0.001:
			away = Vector3.RIGHT
			distance = 0.001
		var weight := clampf((field_radius - distance) / soft_margin, 0.0, 1.0)
		pressure += away / distance * weight * weight
	return pressure.limit_length(1.0)


func _apply_pressure(desired: Vector3, pressure: Vector3) -> Vector3:
	if pressure.is_zero_approx():
		return desired
	return (desired + pressure * desired.length() * TERRAIN_PRESSURE_WEIGHT) \
		.limit_length(desired.length())


func _terrain_context(agent: Dictionary, movement_reach: float) -> Dictionary:
	var unit: Node3D = agent["unit"]
	var position := unit.global_position
	var origin: Vector2i = runtime_map.grid.world_to_grid(position)
	var cell_size: Vector2 = runtime_map.grid.cell_size()
	var obstacle_radius := maxf(minf(cell_size.x, cell_size.y) * 0.5, 0.001)
	var soft_margin := maxf(
		minf(cell_size.x, cell_size.y) * TERRAIN_SOFT_MARGIN_CELLS, 0.001
	)
	# Unit/unit spacing uses the capsule width. Static terrain uses the full
	# rotation envelope so the nose and tail of a long chassis remain clear while
	# it changes heading around a building corner.
	var hard_radius := float(agent.get(
		"terrain_radius", agent.get("rotation_radius", agent["radius"])
	)) + obstacle_radius
	var field_radius := hard_radius + soft_margin
	var scan_world := maxf(
		field_radius,
		hard_radius + movement_reach + CONTACT_BUFFER
	)
	var scan_x := ceili(scan_world / maxf(cell_size.x, 0.001)) + 1
	var scan_y := ceili(scan_world / maxf(cell_size.y, 0.001)) + 1
	var obstacles: Array[Vector3] = []
	var profile := _obstacle_profile(int(agent["pass_mask"]), int(agent["terrain_mask"]))
	var buckets: Dictionary = profile["buckets"]
	var first := origin - Vector2i(scan_x, scan_y)
	var last := origin + Vector2i(scan_x, scan_y)
	var first_bucket := Vector2i(
		floori(float(first.x) / float(OBSTACLE_BUCKET_CELLS)),
		floori(float(first.y) / float(OBSTACLE_BUCKET_CELLS))
	)
	var last_bucket := Vector2i(
		floori(float(last.x) / float(OBSTACLE_BUCKET_CELLS)),
		floori(float(last.y) / float(OBSTACLE_BUCKET_CELLS))
	)
	var allowed: Dictionary = agent.get("allowed_cells", {})
	for bucket_y in range(first_bucket.y, last_bucket.y + 1):
		for bucket_x in range(first_bucket.x, last_bucket.x + 1):
			for cell_variant in buckets.get(Vector2i(bucket_x, bucket_y), []):
				var cell: Vector2i = cell_variant
				if cell.x < first.x or cell.x > last.x \
				or cell.y < first.y or cell.y > last.y:
					continue
				if allowed.has(cell) and not _cell_is_solid(agent, cell):
					continue
				obstacles.append(_obstacle_world(cell, position.y))
	# The cached profile contains only in-bounds cells. Add the small outside
	# strip only for units whose continuous field actually reaches a map edge.
	if first.x < 0 or first.y < 0 \
	or last.x >= MapNavigationGrid.NAV_SIZE or last.y >= MapNavigationGrid.NAV_SIZE:
		for y in range(first.y, last.y + 1):
			for x in range(first.x, last.x + 1):
				var cell := Vector2i(x, y)
				if runtime_map.grid.in_bounds(cell):
					continue
				obstacles.append(_obstacle_world(cell, position.y))
	return {
		"escape": not _agent_cell_passable(agent, origin, 0, 0),
		"obstacles": obstacles,
		"hard_radius": hard_radius,
		"soft_margin": soft_margin,
		"field_radius": field_radius,
	}


func _obstacle_profile(pass_mask: int, terrain_mask: int) -> Dictionary:
	var key := "%d:%d" % [pass_mask, terrain_mask]
	var profile: Dictionary = _obstacle_profiles.get(key, {})
	if not profile.is_empty() and int(profile["revision"]) == runtime_map.revision:
		return profile
	var buckets := {}
	var grid = runtime_map.grid
	var blocked: PackedByteArray = runtime_map.blocked_cells()
	for index in MapNavigationGrid.NAV_SIZE * MapNavigationGrid.NAV_SIZE:
		if (grid.pass_mask[index] & pass_mask) != 0 and blocked[index] == 0 \
		and (terrain_mask == 0 or (terrain_mask & (1 << grid.terrain_type[index])) != 0):
			continue
		var cell := Vector2i(
			index % MapNavigationGrid.NAV_SIZE,
			index / MapNavigationGrid.NAV_SIZE
		)
		var bucket := Vector2i(
			cell.x / OBSTACLE_BUCKET_CELLS,
			cell.y / OBSTACLE_BUCKET_CELLS
		)
		if not buckets.has(bucket):
			buckets[bucket] = [] as Array[Vector2i]
		(buckets[bucket] as Array).append(cell)
	profile = {"revision": runtime_map.revision, "buckets": buckets}
	_obstacle_profiles[key] = profile
	return profile


func _obstacle_world(cell: Vector2i, height: float) -> Vector3:
	var result: Vector3 = runtime_map.grid.grid_to_world(cell)
	result.y = height
	return result


func enemy_sweep_fraction(
		agent: Dictionary,
		displacement: Vector3,
		nearby: Array,
		resolved: Dictionary
	) -> float:
	var unit: Node3D = agent["unit"]
	var fraction := 1.0
	for other in nearby:
		var other_unit: Node3D = other["unit"]
		if other_unit == unit or not _are_enemies(unit, other_unit):
			continue
		var other_position: Vector3 = resolved.get(
			other_unit.get_instance_id(), other_unit.global_position
		)
		fraction = minf(fraction, sweep_fraction(
			unit.global_position,
			displacement,
			other_position,
			float(agent["radius"]) + float(other["radius"])
		))
	return fraction


## Elastic penetration field. Friendly squeeze may overlap temporarily; this
## bounded force continuously restores the round non-overlapping state.
func separation_velocity(agent: Dictionary, nearby: Array) -> Vector3:
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
			push += (Vector3.RIGHT if int(agent["id"]) < int(other["id"]) else Vector3.LEFT) \
				* combined
		else:
			push += away / distance * (combined - distance)
	if push.is_zero_approx():
		return Vector3.ZERO
	return (push * SEPARATION_STIFFNESS).limit_length(
		_unit_speed(unit) * SEPARATION_MAX_SPEED_FACTOR
	)


static func sweep_fraction(
		start: Vector3,
		displacement: Vector3,
		obstacle: Vector3,
		combined_radius: float
	) -> float:
	var relative := start - obstacle
	relative.y = 0.0
	var motion := displacement
	motion.y = 0.0
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


static func _side_of(route_direction: Vector3, candidate_direction: Vector3) -> int:
	var signed := route_direction.signed_angle_to(candidate_direction, Vector3.UP)
	return 0 if absf(signed) <= STEERING_DEFLECTION_EPSILON else int(signf(signed))


func _cell_is_solid(agent: Dictionary, cell: Vector2i) -> bool:
	var grid = runtime_map.grid
	if not grid.in_bounds(cell):
		return true
	var pass_mask := int(agent["pass_mask"])
	if not grid.is_passable(cell, pass_mask):
		return true
	var terrain_mask := int(agent["terrain_mask"])
	if terrain_mask != 0 and (terrain_mask & (1 << grid.terrain_at(cell))) == 0:
		return true
	return runtime_map.is_blocked(cell) and not (agent.get("allowed_cells", {}) as Dictionary).has(cell)


func _agent_cell_passable(
		agent: Dictionary,
		cell: Vector2i,
		clearance_cells := -1,
		allowed_terrain_mask := -1
	) -> bool:
	var clearance := int(agent["clearance"]) if clearance_cells < 0 else clearance_cells
	var terrain_mask := int(agent["terrain_mask"]) \
		if allowed_terrain_mask < 0 else allowed_terrain_mask
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
			if terrain_mask != 0 \
			and (terrain_mask & (1 << runtime_map.grid.terrain_at(sample))) == 0:
				return false
			if runtime_map.is_blocked(sample) and not allowed.has(sample):
				return false
	return true


static func _are_enemies(a: Node3D, b: Node3D) -> bool:
	if a.has_method("is_enemy_of"):
		var owner_id = b.get("owner_player_id")
		return owner_id != null and bool(a.call("is_enemy_of", int(owner_id)))
	return false


static func _unit_speed(unit: Node3D) -> float:
	var value = unit.get("move_speed")
	return maxf(float(value), 0.0) if value != null else 0.0


static func _empty_result() -> Dictionary:
	return {
		"velocity": Vector3.ZERO,
		"enemies": [] as Array[Node3D],
		"friends": [] as Array[Node3D],
	}
