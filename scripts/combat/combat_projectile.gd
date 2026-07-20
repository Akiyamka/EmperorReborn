class_name CombatProjectile
extends Node3D

## A physical, world-space delivery instance for one CombatBullet payload.
## CombatBullet remains the immutable Rules.txt view; this node owns flight,
## homing, collision and lifetime state for one emitted shot.

signal impacted(target: Object, damage: float, world_position: Vector3)
signal finished(reason: StringName, world_position: Vector3)

enum State {
	READY,
	FLYING,
	IMPACTED,
	EXPIRED,
}

const RULE_UPDATES_PER_SECOND := 20.0
const SOURCE_MODEL_WORLD_SCALE := 0.0625
const MAX_SIMULATION_STEP := 1.0 / RULE_UPDATES_PER_SECOND
const COMBAT_COLLISION_MASK := 3
const DEFAULT_TARGET_HIT_RADIUS := 0.25
const MAX_PIERCING_COLLISIONS_PER_STEP := 64

var bullet
var state := State.READY
var finish_reason: StringName = &""
var velocity := Vector3.ZERO
var traveled_distance := 0.0
var elapsed_seconds := 0.0

var _direction := Vector3.ZERO
var _launch_position := Vector3.ZERO
var _aim_position := Vector3.ZERO
var _aim_travel_distance := 0.0
var _target_ref: WeakRef
var _tracks_live_target := false
var _source_ref: WeakRef
var _excluded_rids: Array[RID] = []
var _gravity_world := 0.0
var _trajectory_duration := 0.0
var _trajectory_initial_velocity := Vector3.ZERO


func _init() -> void:
	set_physics_process(false)


func launch(
		bullet_payload,
		emission: Dictionary,
		target_or_position: Variant,
		source: Object = null,
		bullet_gravity := 1.0,
		aim_offset := Vector3.ZERO
	) -> bool:
	if not is_inside_tree() \
	or state != State.READY or bullet_payload == null or bullet_payload.config == null:
		return false
	if not emission.has("position"):
		return false

	var resolved_target := _resolve_target_position(target_or_position)
	if not resolved_target["valid"]:
		return false

	bullet = bullet_payload
	name = "Bullet_%s" % String(bullet.id())
	if get_parent() is Node3D:
		top_level = true
	global_position = Vector3(emission["position"])
	_launch_position = global_position
	_aim_position = Vector3(resolved_target["position"]) + aim_offset
	if target_or_position is Object:
		_target_ref = weakref(target_or_position as Object)
		_tracks_live_target = true
		if not bullet.can_hit(target_or_position as Object):
			return false
		if not _target_is_alive():
			return false
	if source != null and is_instance_valid(source):
		_source_ref = weakref(source)
		_collect_collision_rids(source, _excluded_rids)

	var authored_direction := Vector3(emission.get("direction", Vector3.ZERO))
	_direction = authored_direction.normalized() if not authored_direction.is_zero_approx() \
		else _launch_position.direction_to(_aim_position)
	if _direction.is_zero_approx():
		_direction = Vector3.FORWARD
	_aim_travel_distance = _launch_position.distance_to(_aim_position)
	_gravity_world = maxf(float(bullet_gravity), 0.0) \
		* SOURCE_MODEL_WORLD_SCALE * RULE_UPDATES_PER_SECOND * RULE_UPDATES_PER_SECOND

	state = State.FLYING
	set_physics_process(true)
	_face_direction(_direction)

	if not bullet.can_reach(_launch_position, _aim_position):
		_expire(&"out_of_range")
		return false
	if bullet.is_hitscan():
		_resolve_hitscan()
	elif bullet.has_trajectory():
		_configure_trajectory()
	elif bullet.speed() <= 0.0 or bullet.maximum_range_world() <= 0.0:
		_resolve_arrival(_launch_position)
	else:
		velocity = _direction * bullet.speed()
	return true


func advance(delta: float) -> void:
	if state != State.FLYING or delta <= 0.0:
		return
	var remaining := delta
	while remaining > 0.000001 and state == State.FLYING:
		var step := minf(remaining, MAX_SIMULATION_STEP)
		if bullet.is_homing() and _tracks_live_target and not _target_is_alive():
			_expire(&"target_lost")
			break
		var previous_elapsed := elapsed_seconds
		elapsed_seconds += step
		if bullet.has_trajectory():
			_advance_trajectory(previous_elapsed, elapsed_seconds)
		else:
			_advance_direct(step, previous_elapsed)
		remaining -= step


func is_finished() -> bool:
	return state == State.IMPACTED or state == State.EXPIRED


func direction() -> Vector3:
	return _direction


func aim_position() -> Vector3:
	return _aim_position


func target() -> Object:
	return _target_ref.get_ref() if _target_ref != null else null


func _physics_process(delta: float) -> void:
	advance(delta)


func _resolve_hitscan() -> void:
	var collisions := _collisions_between(_launch_position, _aim_position)
	if _handle_collisions(collisions):
		return
	global_position = _aim_position
	var intended_target := target()
	if intended_target != null and _target_is_alive() and bullet.can_hit(intended_target):
		_impact_target(intended_target, _aim_position, true)
	else:
		_finish_impact(&"impact_ground", _aim_position)


func _configure_trajectory() -> void:
	var offset := _aim_position - _launch_position
	var horizontal := Vector3(offset.x, 0.0, offset.z)
	var horizontal_distance := horizontal.length()
	if bullet.speed() > 0.0:
		_trajectory_duration = maxf(horizontal_distance / bullet.speed(), MAX_SIMULATION_STEP)
	elif _gravity_world > 0.0 and horizontal_distance > 0.0:
		# With no per-bullet Speed in Rules.txt, use the source gravity to solve
		# a 45-degree arc. This makes Trajectory the high-arc delivery described
		# by the rules without introducing a fabricated per-weapon speed.
		_trajectory_duration = sqrt(2.0 * horizontal_distance / _gravity_world)
	else:
		_trajectory_duration = MAX_SIMULATION_STEP

	var horizontal_velocity := horizontal / _trajectory_duration
	var vertical_velocity := (
		offset.y + 0.5 * _gravity_world * _trajectory_duration * _trajectory_duration
	) / _trajectory_duration
	_trajectory_initial_velocity = horizontal_velocity + Vector3.UP * vertical_velocity
	velocity = _trajectory_initial_velocity
	_direction = velocity.normalized() if not velocity.is_zero_approx() else _direction
	_face_direction(_direction)


func _advance_trajectory(_previous_elapsed: float, current_elapsed: float) -> void:
	var from := global_position
	var time := minf(current_elapsed, _trajectory_duration)
	var to := _launch_position + _trajectory_initial_velocity * time \
		+ Vector3.DOWN * (0.5 * _gravity_world * time * time)
	var segment := to - from
	traveled_distance += segment.length()
	velocity = _trajectory_initial_velocity + Vector3.DOWN * (_gravity_world * time)
	if _handle_collisions(_collisions_between(from, to)):
		return
	if _fallback_target_collision(from, to):
		return
	global_position = to
	if not segment.is_zero_approx():
		_direction = segment.normalized()
		_face_direction(_direction)
	if current_elapsed + 0.000001 >= _trajectory_duration:
		_resolve_arrival(_aim_position)


func _advance_direct(delta: float, previous_elapsed: float) -> void:
	if bullet.is_homing() and _tracks_live_target \
	and previous_elapsed * RULE_UPDATES_PER_SECOND \
		>= bullet.homing_delay_ticks():
		_update_homing(delta)

	var remaining_range := maxf(bullet.maximum_range_world() - traveled_distance, 0.0)
	if remaining_range <= 0.000001:
		_expire(&"range_exhausted")
		return
	var step_distance := minf(bullet.speed() * delta, remaining_range)
	var from := global_position
	var to := from + _direction * step_distance
	velocity = _direction * bullet.speed()
	traveled_distance += step_distance
	if _handle_collisions(_collisions_between(from, to)):
		return
	if _fallback_target_collision(from, to):
		return
	global_position = to
	_face_direction(_direction)

	if not (bullet.is_homing() and _tracks_live_target) \
	and traveled_distance + 0.000001 >= _aim_travel_distance:
		_resolve_arrival(global_position)
	elif traveled_distance + 0.000001 >= bullet.maximum_range_world():
		_expire(&"range_exhausted")


func _update_homing(delta: float) -> void:
	var target_position := _current_target_position()
	if not target_position.is_finite():
		return
	var desired_direction := global_position.direction_to(target_position)
	if desired_direction.is_zero_approx():
		return
	var angle := _direction.angle_to(desired_direction)
	if angle <= 0.000001:
		_direction = desired_direction
		return
	var maximum_turn: float = float(bullet.turn_rate()) * RULE_UPDATES_PER_SECOND * delta
	_direction = _direction.slerp(desired_direction, minf(maximum_turn / angle, 1.0)).normalized()


func _resolve_arrival(world_position: Vector3) -> void:
	global_position = world_position
	var intended_target := target()
	if intended_target != null and _target_is_alive() and bullet.can_hit(intended_target):
		var target_position := _current_target_position()
		if target_position.is_finite() \
		and target_position.distance_to(world_position) <= _target_hit_radius(intended_target):
			_impact_target(intended_target, world_position, true)
			return
	_finish_impact(&"impact_ground", world_position)


func _fallback_target_collision(from: Vector3, to: Vector3) -> bool:
	var intended_target := target()
	if intended_target == null or not _target_is_alive() or not bullet.can_hit(intended_target):
		return false
	var target_position := _current_target_position()
	if not target_position.is_finite():
		return false
	if _distance_to_segment(target_position, from, to) > _target_hit_radius(intended_target):
		return false
	_impact_target(intended_target, target_position, not bullet.is_piercing())
	return state != State.FLYING


func _handle_collisions(collisions: Array[Dictionary]) -> bool:
	for collision in collisions:
		var collider: Object = collision.get("collider") as Object
		var entity := _combat_entity(collider)
		if entity != null and entity == _source():
			continue
		if entity != null:
			if not bullet.can_hit(entity):
				continue
			_impact_target(entity, Vector3(collision["position"]), not bullet.is_piercing())
			if state != State.FLYING:
				return true
			continue
		if not bullet.is_piercing():
			_finish_impact(&"impact_ground", Vector3(collision["position"]))
			return true
	return false


func _impact_target(entity: Object, world_position: Vector3, stop: bool) -> void:
	global_position = world_position
	var damage: float = float(bullet.impact(entity))
	impacted.emit(entity, damage, world_position)
	if stop:
		_finish_impact(&"impact_target", world_position)


func _finish_impact(reason: StringName, world_position: Vector3) -> void:
	state = State.IMPACTED
	_finish(reason, world_position)


func _expire(reason: StringName) -> void:
	state = State.EXPIRED
	_finish(reason, global_position)


func _finish(reason: StringName, world_position: Vector3) -> void:
	finish_reason = reason
	velocity = Vector3.ZERO
	set_physics_process(false)
	finished.emit(finish_reason, world_position)
	if is_inside_tree():
		call_deferred("_queue_free_finished")


func _queue_free_finished() -> void:
	if is_instance_valid(self) and not is_queued_for_deletion():
		queue_free()


func _collisions_between(from: Vector3, to: Vector3) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if from.is_equal_approx(to) or not is_inside_tree() or get_world_3d() == null:
		return result
	var excludes: Array[RID] = _excluded_rids.duplicate()
	for index in MAX_PIERCING_COLLISIONS_PER_STEP:
		var query := PhysicsRayQueryParameters3D.create(from, to, COMBAT_COLLISION_MASK, excludes)
		query.collide_with_areas = true
		query.collide_with_bodies = true
		query.hit_from_inside = true
		var hit := get_world_3d().direct_space_state.intersect_ray(query)
		if hit.is_empty():
			break
		result.append(hit)
		var rid: RID = hit.get("rid", RID())
		if not rid.is_valid():
			break
		excludes.append(rid)
	return result


func _combat_entity(collider: Object) -> Object:
	var current := collider as Node
	while current != null:
		if current.has_method("combat_armour_type"):
			return current
		current = current.get_parent()
	return null


func _collect_collision_rids(object: Object, result: Array[RID]) -> void:
	if object is CollisionObject3D:
		result.append((object as CollisionObject3D).get_rid())
	if object is Node:
		for child in (object as Node).get_children():
			_collect_collision_rids(child, result)


func _resolve_target_position(target_or_position: Variant) -> Dictionary:
	if target_or_position is Vector3:
		return {"valid": true, "position": target_or_position}
	if target_or_position is Object and is_instance_valid(target_or_position):
		var position := _object_position(target_or_position as Object)
		return {"valid": position.is_finite(), "position": position}
	return {"valid": false, "position": Vector3.ZERO}


func _object_position(object: Object) -> Vector3:
	if object == null or not is_instance_valid(object):
		return Vector3.INF
	if object.has_method("combat_aim_position"):
		var value: Variant = object.call("combat_aim_position")
		if value is Vector3:
			return value
	if object is Node3D:
		return (object as Node3D).global_position
	return Vector3.INF


func _current_target_position() -> Vector3:
	var intended_target := target()
	return _object_position(intended_target) if intended_target != null else Vector3.INF


func _target_is_alive() -> bool:
	var intended_target := target()
	if intended_target == null or not is_instance_valid(intended_target):
		return false
	if intended_target is Node and (intended_target as Node).is_queued_for_deletion():
		return false
	if intended_target.has_method("combat_is_alive"):
		return bool(intended_target.call("combat_is_alive"))
	return true


func _target_hit_radius(intended_target: Object) -> float:
	if intended_target != null and intended_target.has_method("combat_hit_radius"):
		return maxf(float(intended_target.call("combat_hit_radius")), DEFAULT_TARGET_HIT_RADIUS)
	return DEFAULT_TARGET_HIT_RADIUS


func _source() -> Object:
	return _source_ref.get_ref() if _source_ref != null else null


func _face_direction(new_direction: Vector3) -> void:
	if new_direction.is_zero_approx():
		return
	var up := Vector3.FORWARD if absf(new_direction.normalized().dot(Vector3.UP)) > 0.999 \
		else Vector3.UP
	global_basis = Basis.looking_at(new_direction.normalized(), up)


func _distance_to_segment(point: Vector3, from: Vector3, to: Vector3) -> float:
	var segment := to - from
	var length_squared := segment.length_squared()
	if length_squared <= 0.000001:
		return point.distance_to(from)
	var amount := clampf((point - from).dot(segment) / length_squared, 0.0, 1.0)
	return point.distance_to(from + segment * amount)
