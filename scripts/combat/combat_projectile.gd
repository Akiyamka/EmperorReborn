class_name CombatProjectile
extends Node3D

const CombatImpactResolverScript := preload("res://scripts/combat/combat_impact_resolver.gd")

## A physical, world-space delivery instance for one CombatBullet payload.
## CombatBullet remains the immutable Rules.txt view; this node owns flight,
## homing, collision and lifetime state for one emitted shot.

signal impacted(target: Object, damage: float, world_position: Vector3)
signal impact_resolved(results: Array[Dictionary], world_position: Vector3)
signal impact_effect_applied(target: Object, effect: StringName, world_position: Vector3)
signal explosion_requested(
	explosion_type: StringName, explosion_effects: Array, world_position: Vector3
)
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
const DIRECT_PROJECTILE_SIZE := 0.12
const HOMING_PROJECTILE_SIZE := 0.16
const TRAJECTORY_PROJECTILE_SIZE := 0.18
const MISSILE_TRAIL_SIDES := 6
const MAX_MISSILE_TRAIL_POINTS := 128
const MISSILE_TRAIL_RADIUS_SCALE := SOURCE_MODEL_WORLD_SCALE * 0.65
const NO_PROPULSION_FLASH_BULLETS: Array[StringName] = [&"KobraHowitzer_B"]

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
var _maximum_flight_distance := 0.0
var _missile_trail_mesh: ImmediateMesh
var _missile_trail_material: StandardMaterial3D
var _missile_trail_points: Array[Dictionary] = []
var _missile_trail_duration := 0.0
var _impact_resolver = CombatImpactResolverScript.new()


func _init() -> void:
	set_physics_process(false)


func launch(
		bullet_payload,
		emission: Dictionary,
		target_or_position: Variant,
		source: Object = null,
		bullet_gravity := 1.0,
		aim_offset := Vector3.ZERO,
		range_origin := Vector3.INF
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
	_create_visual()
	if get_parent() is Node3D:
		top_level = true
	global_position = Vector3(emission["position"])
	_launch_position = global_position
	_aim_position = Vector3(resolved_target["position"]) + aim_offset
	var gameplay_range_origin := range_origin \
		if range_origin.is_finite() else _launch_position
	_maximum_flight_distance = bullet.maximum_range_world() \
		+ gameplay_range_origin.distance_to(_launch_position)
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
	_gravity_world = trajectory_gravity_world(bullet_gravity)

	state = State.FLYING
	set_physics_process(true)
	_face_direction(_direction)
	_create_missile_trail()

	if not bullet.can_reach(gameplay_range_origin, _aim_position):
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


func _create_visual() -> void:
	# Hitscan bullets resolve during launch and have no flight interval to draw.
	if bullet == null or bullet.is_hitscan():
		return
	if bullet.visual_scene != null:
		var authored_visual := bullet.visual_scene.instantiate() as Node3D
		if authored_visual != null:
			authored_visual.name = "Visual"
			add_child(authored_visual)
			if bullet.id() in NO_PROPULSION_FLASH_BULLETS:
				_hide_authored_propulsion_flash(authored_visual)
			return
	# Keep an unmistakable fallback for bullets whose ArtIni XAF has not yet
	# been converted. Rules-backed weapons with a converted scene never use it.
	var size := DIRECT_PROJECTILE_SIZE
	var color := Color(1.0, 0.82, 0.32)
	if bullet.is_homing():
		size = HOMING_PROJECTILE_SIZE
		color = Color(1.0, 0.58, 0.18)
	elif bullet.has_trajectory():
		size = TRAJECTORY_PROJECTILE_SIZE
		color = Color(1.0, 0.72, 0.28)

	var bolt_mesh := BoxMesh.new()
	bolt_mesh.size = Vector3(size, size, size * 2.5)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = 2.0
	bolt_mesh.material = material

	var visual := MeshInstance3D.new()
	visual.name = "Visual"
	visual.mesh = bolt_mesh
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(visual)


func _hide_authored_propulsion_flash(node: Node) -> void:
	# shell.xbf contains `_flashl02`, a gameplay-controlled helper mesh. The
	# original Minotaurus shot renders as a dark shell with a MissileTrail, not
	# as a rocket with this helper burning continuously.
	if node is Node3D and String(node.name).to_lower().contains("flashl"):
		(node as Node3D).visible = false
	for child in node.get_children():
		_hide_authored_propulsion_flash(child)


func _create_missile_trail() -> void:
	if (
		bullet == null
		or bullet.is_hitscan()
		or not bullet.has_missile_trail()
		or bullet.missile_trail_size() <= 0.0
		or bullet.missile_trail_length() <= 0
	):
		return

	# Treat Length as the authored history count and Delta as its fractional
	# rule-tick spacing. Keeping that history in seconds lets the wake follow the
	# projectile's actual past positions along a ballistic arc.
	_missile_trail_duration = maxf(
		float(bullet.missile_trail_length())
			* maxf(bullet.missile_trail_delta(), 0.05)
			/ RULE_UPDATES_PER_SECOND,
		1.0 / RULE_UPDATES_PER_SECOND
	)
	_missile_trail_mesh = ImmediateMesh.new()
	_missile_trail_material = StandardMaterial3D.new()
	_missile_trail_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_missile_trail_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_missile_trail_material.vertex_color_use_as_albedo = true
	_missile_trail_material.albedo_color = Color.WHITE
	_missile_trail_material.cull_mode = BaseMaterial3D.CULL_DISABLED

	var trail_visual := MeshInstance3D.new()
	trail_visual.name = "MissileTrail"
	trail_visual.mesh = _missile_trail_mesh
	trail_visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(trail_visual)
	_missile_trail_points.append({
		"position": global_position,
		"time": elapsed_seconds,
	})


func _sample_missile_trail() -> void:
	if _missile_trail_mesh == null:
		return
	var point := {
		"position": global_position,
		"time": elapsed_seconds,
	}
	if _missile_trail_points.is_empty():
		_missile_trail_points.append(point)
	else:
		var previous_position := Vector3(_missile_trail_points.back()["position"])
		if previous_position.distance_squared_to(global_position) > 0.000001:
			_missile_trail_points.append(point)

	var oldest_time := elapsed_seconds - _missile_trail_duration
	while (
		_missile_trail_points.size() > 2
		and float(_missile_trail_points[1]["time"]) < oldest_time
	):
		_missile_trail_points.pop_front()
	while _missile_trail_points.size() > MAX_MISSILE_TRAIL_POINTS:
		_missile_trail_points.pop_front()
	_rebuild_missile_trail()


func _rebuild_missile_trail() -> void:
	_missile_trail_mesh.clear_surfaces()
	if _missile_trail_points.size() < 2 or _missile_trail_duration <= 0.0:
		return

	var trail_color := _missile_trail_color(bullet.missile_trail_style())
	var base_radius: float = bullet.missile_trail_size() * MISSILE_TRAIL_RADIUS_SCALE
	_missile_trail_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, _missile_trail_material)
	for point_index in _missile_trail_points.size() - 1:
		var first_ring := _missile_trail_ring(point_index, base_radius, trail_color)
		var second_ring := _missile_trail_ring(point_index + 1, base_radius, trail_color)
		for side in MISSILE_TRAIL_SIDES:
			var next_side := (side + 1) % MISSILE_TRAIL_SIDES
			_add_missile_trail_vertex(first_ring[side])
			_add_missile_trail_vertex(second_ring[side])
			_add_missile_trail_vertex(second_ring[next_side])
			_add_missile_trail_vertex(first_ring[side])
			_add_missile_trail_vertex(second_ring[next_side])
			_add_missile_trail_vertex(first_ring[next_side])
	_missile_trail_mesh.surface_end()


func _missile_trail_ring(
		point_index: int,
		base_radius: float,
		trail_color: Color
	) -> Array[Dictionary]:
	var world_position := Vector3(_missile_trail_points[point_index]["position"])
	var previous_position := Vector3(
		_missile_trail_points[maxi(point_index - 1, 0)]["position"]
	)
	var next_position := Vector3(
		_missile_trail_points[mini(point_index + 1, _missile_trail_points.size() - 1)]["position"]
	)
	var tangent := previous_position.direction_to(next_position)
	if tangent.is_zero_approx():
		tangent = _direction if not _direction.is_zero_approx() else Vector3.FORWARD
	var reference := Vector3.RIGHT if absf(tangent.dot(Vector3.UP)) > 0.9 else Vector3.UP
	var axis_a := tangent.cross(reference).normalized()
	var axis_b := tangent.cross(axis_a).normalized()
	var age := maxf(elapsed_seconds - float(_missile_trail_points[point_index]["time"]), 0.0)
	var remaining := clampf(1.0 - age / _missile_trail_duration, 0.0, 1.0)
	var radius := base_radius * lerpf(0.08, 1.0, remaining)
	var color := trail_color
	color.a *= remaining * remaining

	var ring: Array[Dictionary] = []
	for side in MISSILE_TRAIL_SIDES:
		var angle := TAU * float(side) / float(MISSILE_TRAIL_SIDES)
		var offset := (axis_a * cos(angle) + axis_b * sin(angle)) * radius
		ring.append({
			"position": to_local(world_position + offset),
			"color": color,
		})
	return ring


func _add_missile_trail_vertex(vertex: Dictionary) -> void:
	_missile_trail_mesh.surface_set_color(Color(vertex["color"]))
	_missile_trail_mesh.surface_add_vertex(Vector3(vertex["position"]))


func _missile_trail_color(style: int) -> Color:
	# Style 6 is KobraHowitzer_B's pale aerodynamic wake. The remaining styles
	# retain a neutral smoke presentation until their original palettes are
	# characterized independently.
	if style == 6:
		return Color(0.58, 0.65, 0.68, 0.48)
	return Color(0.62, 0.62, 0.60, 0.56)


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
		_sample_missile_trail()
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
		_impact_ground(_aim_position)


func _configure_trajectory() -> void:
	var offset := _aim_position - _launch_position
	var horizontal := Vector3(offset.x, 0.0, offset.z)
	var horizontal_distance := horizontal.length()
	var ballistic_velocities: Array[Vector3] = trajectory_launch_velocities(
		bullet, _launch_position, _aim_position, _gravity_world,
		_maximum_flight_distance
	)
	if not ballistic_velocities.is_empty():
		_trajectory_initial_velocity = _closest_velocity(
			ballistic_velocities, _direction
		)
		var horizontal_speed := Vector2(
			_trajectory_initial_velocity.x, _trajectory_initial_velocity.z
		).length()
		_trajectory_duration = maxf(
			horizontal_distance / horizontal_speed, MAX_SIMULATION_STEP
		) if horizontal_speed > 0.0 else MAX_SIMULATION_STEP
		velocity = _trajectory_initial_velocity
		_direction = velocity.normalized()
		_face_direction(_direction)
		return
	if bullet.speed() > 0.0:
		_trajectory_duration = maxf(horizontal_distance / bullet.speed(), MAX_SIMULATION_STEP)
	elif _gravity_world > 0.0 and horizontal_distance > 0.0:
		# Degenerate fallback for an unreachable ballistic solution.
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


## Returns the low and high ballistic solutions for a trajectory bullet whose
## Rules.txt entry omits Speed. MaxRange defines the distance reached at 45
## degrees under the global BulletGravity; nearer targets therefore get a
## flatter low solution unless the weapon's elevation limits require the high
## one. `_gravity_world` is already converted to Godot units per second².
static func trajectory_launch_velocities(
		bullet_payload,
		launch_position: Vector3,
		aim_position: Vector3,
		gravity_world: float,
		maximum_range_override := -1.0
	) -> Array[Vector3]:
	var result: Array[Vector3] = []
	if (
		bullet_payload == null
		or not bullet_payload.has_trajectory()
		or bullet_payload.speed() > 0.0
		or gravity_world <= 0.0
	):
		return result
	var offset := aim_position - launch_position
	var horizontal := Vector3(offset.x, 0.0, offset.z)
	var horizontal_distance := horizontal.length()
	var maximum_range: float = maximum_range_override \
		if maximum_range_override > 0.0 \
		else float(bullet_payload.maximum_range_world())
	if horizontal_distance <= 0.000001 or maximum_range <= 0.0:
		return result

	var speed_squared: float = gravity_world * maximum_range
	var discriminant: float = speed_squared * speed_squared - gravity_world * (
		gravity_world * horizontal_distance * horizontal_distance
		+ 2.0 * offset.y * speed_squared
	)
	if discriminant < -0.000001:
		return result
	var root: float = sqrt(maxf(discriminant, 0.0))
	var launch_speed: float = sqrt(speed_squared)
	var horizontal_direction := horizontal / horizontal_distance
	var numerators: Array[float] = [speed_squared - root, speed_squared + root]
	for numerator in numerators:
		var tangent := numerator / (gravity_world * horizontal_distance)
		var cosine := 1.0 / sqrt(1.0 + tangent * tangent)
		var sine := tangent * cosine
		var candidate := (
			horizontal_direction * (launch_speed * cosine)
			+ Vector3.UP * (launch_speed * sine)
		)
		if result.is_empty() or result.front().angle_to(candidate) > 0.0001:
			result.append(candidate)
	return result


static func trajectory_gravity_world(rule_gravity: float) -> float:
	return maxf(rule_gravity, 0.0) \
		* SOURCE_MODEL_WORLD_SCALE * RULE_UPDATES_PER_SECOND * RULE_UPDATES_PER_SECOND


static func _closest_velocity(candidates: Array[Vector3], direction: Vector3) -> Vector3:
	var result: Vector3 = candidates.front()
	if direction.is_zero_approx():
		return result
	var normalized_direction := direction.normalized()
	var best_dot: float = -INF
	for candidate in candidates:
		var score := normalized_direction.dot(candidate.normalized())
		if score > best_dot:
			best_dot = score
			result = candidate
	return result


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

	var remaining_range := maxf(_maximum_flight_distance - traveled_distance, 0.0)
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
	elif traveled_distance + 0.000001 >= _maximum_flight_distance:
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
	_impact_ground(world_position)


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
			_impact_ground(Vector3(collision["position"]))
			return true
	return false


func _impact_target(entity: Object, world_position: Vector3, stop: bool) -> void:
	global_position = world_position
	_resolve_impact(entity, world_position)
	if stop:
		_finish_impact(&"impact_target", world_position)


func _impact_ground(world_position: Vector3) -> void:
	global_position = world_position
	_resolve_impact(null, world_position)
	_finish_impact(&"impact_ground", world_position)


func _resolve_impact(direct_target: Object, world_position: Vector3) -> void:
	var results: Array[Dictionary] = _impact_resolver.resolve(
		bullet, self, world_position, direct_target, _source()
	)
	for result in results:
		var resolved_target: Object = result["target"] as Object
		impacted.emit(resolved_target, float(result["damage"]), world_position)
		for effect in result["effects"]:
			impact_effect_applied.emit(resolved_target, StringName(effect), world_position)
	impact_resolved.emit(results, world_position)
	var explosion_type: StringName = bullet.explosion_type()
	var explosion_effects: Array = bullet.explosion_effects()
	if explosion_type != &"" or not explosion_effects.is_empty():
		explosion_requested.emit(explosion_type, explosion_effects, world_position)


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
	# XBF conversion mirrors source Z, so the authored projectile nose that was
	# local -Z becomes local +Z in the baked scene. `use_model_front=true`
	# aligns that converted +Z nose with flight instead of pointing it backward.
	global_basis = Basis.looking_at(new_direction.normalized(), up, true)


func _distance_to_segment(point: Vector3, from: Vector3, to: Vector3) -> float:
	var segment := to - from
	var length_squared := segment.length_squared()
	if length_squared <= 0.000001:
		return point.distance_to(from)
	var amount := clampf((point - from).dot(segment) / length_squared, 0.0, 1.0)
	return point.distance_to(from + segment * amount)
