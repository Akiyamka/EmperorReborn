class_name Ballistics
extends RefCounted

## The flight math behind a shot: how fast the world pulls a shell down, which
## launch velocity puts it on a target, and where an artillery barrel's own
## heading crosses the target plane.
##
## All static and stateless. CombatProjectile uses it to fly the shot;
## CombatTurret uses the same functions to decide, before firing, whether the
## elevation limits allow the shot at all -- and the answer has to be the same
## in both places, which is why this is one implementation rather than a
## simulation and a prediction of it.

## Rules.txt values are per bullet update, and the original engine ran twenty
## of those per second. Deliberately not CombatRules.TICKS_PER_SECOND: that is
## the turret aim rate, which is a different clock in the source data.
const RULE_UPDATES_PER_SECOND := 20.0
## One source-model unit in Godot units.
const SOURCE_MODEL_WORLD_SCALE := 0.0625


## Rules BulletGravity is per update in source units; this is the same
## acceleration in Godot units per second squared.
static func gravity_world(rule_gravity: float) -> float:
	return maxf(rule_gravity, 0.0) \
		* SOURCE_MODEL_WORLD_SCALE * RULE_UPDATES_PER_SECOND * RULE_UPDATES_PER_SECOND


## Projects an artillery shell straight ahead from its muzzle until it reaches
## the plane through the sampled target. Only the vertical launch angle is
## solved ballistically; no horizontal correction converges parallel barrels.
static func parallel_impact_position(
		launch_position: Vector3,
		target_aim_position: Vector3,
		forward_direction: Vector3
	) -> Vector3:
	var horizontal_forward := Vector3(
		forward_direction.x, 0.0, forward_direction.z
	)
	var horizontal_offset := Vector3(
		target_aim_position.x - launch_position.x,
		0.0,
		target_aim_position.z - launch_position.z
	)
	if horizontal_forward.is_zero_approx() or horizontal_offset.is_zero_approx():
		return target_aim_position
	horizontal_forward = horizontal_forward.normalized()
	var forward_distance := horizontal_offset.dot(horizontal_forward)
	if forward_distance <= 0.000001:
		return target_aim_position
	var result := launch_position + horizontal_forward * forward_distance
	result.y = target_aim_position.y
	return result


## Returns the low and high ballistic solutions for a trajectory bullet whose
## Rules.txt entry omits Speed. MaxRange defines the distance reached at 45
## degrees under the global BulletGravity; nearer targets therefore get a
## flatter low solution unless the weapon's elevation limits require the high
## one. `gravity_world` is already in Godot units per second².
static func launch_velocities(
		bullet_payload,
		launch_position: Vector3,
		target_aim_position: Vector3,
		gravity: float,
		maximum_range_override := -1.0
	) -> Array[Vector3]:
	var result: Array[Vector3] = []
	if (
		bullet_payload == null
		or not bullet_payload.has_trajectory()
		or bullet_payload.speed() > 0.0
		or gravity <= 0.0
	):
		return result
	var offset := target_aim_position - launch_position
	var horizontal := Vector3(offset.x, 0.0, offset.z)
	var horizontal_distance := horizontal.length()
	var maximum_range: float = maximum_range_override \
		if maximum_range_override > 0.0 \
		else float(bullet_payload.maximum_range_world())
	if horizontal_distance <= 0.000001 or maximum_range <= 0.0:
		return result

	var speed_squared: float = gravity * maximum_range
	var discriminant: float = speed_squared * speed_squared - gravity * (
		gravity * horizontal_distance * horizontal_distance
		+ 2.0 * offset.y * speed_squared
	)
	if discriminant < -0.000001:
		return result
	var root: float = sqrt(maxf(discriminant, 0.0))
	var launch_speed: float = sqrt(speed_squared)
	var horizontal_direction := horizontal / horizontal_distance
	var numerators: Array[float] = [speed_squared - root, speed_squared + root]
	for numerator in numerators:
		var tangent := numerator / (gravity * horizontal_distance)
		var cosine := 1.0 / sqrt(1.0 + tangent * tangent)
		var sine := tangent * cosine
		var candidate := (
			horizontal_direction * (launch_speed * cosine)
			+ Vector3.UP * (launch_speed * sine)
		)
		if result.is_empty() or result.front().angle_to(candidate) > 0.0001:
			result.append(candidate)
	return result


## Of the (up to two) solutions, the one that departs closest to where the
## barrel is already pointing -- normally the flat one, but the high arc when
## the muzzle is raised over an obstacle.
static func closest_velocity(candidates: Array[Vector3], preferred_direction: Vector3) -> Vector3:
	var result: Vector3 = candidates.front()
	if preferred_direction.is_zero_approx():
		return result
	var normalized_direction := preferred_direction.normalized()
	var best_dot: float = -INF
	for candidate in candidates:
		var score := normalized_direction.dot(candidate.normalized())
		if score > best_dot:
			best_dot = score
			result = candidate
	return result


## How close a point passes to a travelled segment. A shot that crosses a
## target between two simulation steps never occupies the same position as it,
## so proximity to the segment is what counts as a hit.
static func distance_to_segment(point: Vector3, from: Vector3, to: Vector3) -> float:
	var segment := to - from
	var length_squared := segment.length_squared()
	if length_squared <= 0.000001:
		return point.distance_to(from)
	var amount := clampf((point - from).dot(segment) / length_squared, 0.0, 1.0)
	return point.distance_to(from + segment * amount)
