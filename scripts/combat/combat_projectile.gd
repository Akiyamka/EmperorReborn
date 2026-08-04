class_name CombatProjectile
extends Node3D

const CombatImpactResolverScript := preload("res://scripts/combat/combat_impact_resolver.gd")
const CombatImpactEffectScript := preload("res://scripts/combat/combat_impact_effect.gd")
const CombatGroundDecalScript := preload("res://scripts/combat/combat_ground_decal.gd")
const CombatLingerEffectScript := preload("res://scripts/combat/combat_linger_effect.gd")

## A physical, world-space delivery instance for one CombatBullet payload.
## CombatBullet remains the immutable typed-definition view; this node owns flight,
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

const BallisticsScript := preload("res://scripts/combat/ballistics.gd")
const RULE_UPDATES_PER_SECOND := BallisticsScript.RULE_UPDATES_PER_SECOND
const SOURCE_MODEL_WORLD_SCALE := BallisticsScript.SOURCE_MODEL_WORLD_SCALE
const MAX_SIMULATION_STEP := 1.0 / RULE_UPDATES_PER_SECOND
const CombatTargetScript := preload("res://scripts/combat/combat_target.gd")
const CombatRulesScript := preload("res://scripts/combat/combat_rules.gd")
const COMBAT_COLLISION_MASK := CombatRulesScript.COLLISION_MASK
const MAX_PIERCING_COLLISIONS_PER_STEP := 64
const DIRECT_PROJECTILE_SIZE := 0.12
const HOMING_PROJECTILE_SIZE := 0.16
const TRAJECTORY_PROJECTILE_SIZE := 0.18
const MISSILE_TRAIL_SIDES := 6
const MAX_MISSILE_TRAIL_POINTS := 128
const MISSILE_TRAIL_RADIUS_SCALE := SOURCE_MODEL_WORLD_SCALE * 0.65
const NO_PROPULSION_FLASH_BULLETS: Array[StringName] = [&"KobraHowitzer_B"]
const LASER_VISUAL_DURATION := 0.16
const LASER_CORE_RADIUS := 0.025
const LASER_GLOW_RADIUS := 0.07
const LASER_TANK_GLOW_RADIUS := 0.1
const LASER_RADIAL_SEGMENTS := 8
const LASER_TANK_COLOR := Color(0.2, 1.0, 0.08)
const LASER_TANK_GLOW_COLOR := Color(0.08, 0.72, 1.0, 0.24)
const LASER_TANK_GLOW_ENERGY := 3.0
const INFANTRY_LASER_COLOR := Color(1.0, 0.55, 0.08)

var bullet
var _damage_scale := 1.0
var state := State.READY
var finish_reason: StringName = &""
var velocity := Vector3.ZERO
var traveled_distance := 0.0
var elapsed_seconds := 0.0

var _direction := Vector3.ZERO
var _launch_position := Vector3.ZERO
var _aim_position := Vector3.ZERO
var _trajectory_impact_position := Vector3.ZERO
var _aim_travel_distance := 0.0
var _target_range_allowance := 0.0
var _target_ref: WeakRef
var _tracks_live_target := false
var _targets_ground_position := false
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

	var resolved_target := _resolve_target_position(
		target_or_position, Vector3(emission["position"])
	)
	if not resolved_target["valid"]:
		return false

	_damage_scale = float(bullet_payload.damage_scale) \
		if "definition" in bullet_payload else 1.0
	bullet = bullet_payload.definition if "definition" in bullet_payload else bullet_payload
	name = "Bullet_%s" % String(bullet.id())
	_create_visual()
	if get_parent() is Node3D:
		top_level = true
	global_position = Vector3(emission["position"])
	_launch_position = global_position
	_aim_position = Vector3(resolved_target["position"]) + aim_offset
	_trajectory_impact_position = _aim_position
	_targets_ground_position = target_or_position is Vector3
	var gameplay_range_origin := range_origin \
		if range_origin.is_finite() else _launch_position
	if target_or_position is Object:
		var center_offset := _aim_position - gameplay_range_origin
		var center_distance := Vector2(center_offset.x, center_offset.z).length()
		var surface_distance: float = bullet.horizontal_target_distance(
			gameplay_range_origin,
			_aim_position,
			target_or_position as Object
		)
		_target_range_allowance = maxf(center_distance - surface_distance, 0.0)
	# Flight budget, not firing range: a homing shot spends extra distance
	# steering, so its allowance exceeds the straight line the turret checked.
	_maximum_flight_distance = bullet.flight_range_world() \
		+ gameplay_range_origin.distance_to(_launch_position) \
		+ _target_range_allowance
	if target_or_position is Object:
		_target_ref = weakref(target_or_position as Object)
		_tracks_live_target = true
		if not bullet.can_hit(target_or_position as Object):
			return false
		if not _target_is_alive():
			return false
	if source != null and is_instance_valid(source):
		_source_ref = weakref(source)
		_excluded_rids.append_array(CombatTargetScript.collision_rids(source))

	var authored_direction := Vector3(emission.get("direction", Vector3.ZERO))
	var attack_ground_direction := _launch_position.direction_to(_aim_position) \
		if target_or_position is Vector3 and not bullet.has_trajectory() \
		else Vector3.ZERO
	# A yaw-only launcher cannot encode the vertical component of an
	# attack-ground shot in its muzzle marker. Direct coordinate shots must use
	# the complete sampled direction or they fly horizontally and merely expire
	# above/below the requested point. Artillery keeps its authored heading so
	# parallel barrels retain their geometric spread.
	_direction = attack_ground_direction \
		if not attack_ground_direction.is_zero_approx() \
		else authored_direction.normalized() if not authored_direction.is_zero_approx() \
		else _launch_position.direction_to(_aim_position)
	if _direction.is_zero_approx():
		_direction = Vector3.FORWARD
	_aim_travel_distance = _launch_position.distance_to(_aim_position)
	_gravity_world = BallisticsScript.gravity_world(bullet_gravity)

	state = State.FLYING
	set_physics_process(true)
	_face_direction(_direction)
	_create_missile_trail()

	if (
		target_or_position is Object
		and not bullet.can_reach_target(
			gameplay_range_origin,
			_aim_position,
			target_or_position as Object
		)
	) or (
		not target_or_position is Object
		and not bullet.can_reach(gameplay_range_origin, _aim_position)
	):
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
	# Ordinary hitscan bullets resolve during launch and have no flight interval
	# to draw. Lasers get a short-lived resolved segment in `_finish()` once the
	# raycast has established the actual impact point.
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
	# Model-authored particle banks provide the visible gas/flame stream for
	# continuous delivery. Do not expose the missing projectile mesh as a
	# yellow debug bolt inside that stream.
	if bullet.is_continuous():
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


func trajectory_impact_position() -> Vector3:
	return _trajectory_impact_position


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
	# Artillery shells retain the muzzle's horizontal heading. Side-by-side
	# barrels therefore fly in parallel instead of steering every shell toward
	# one common point; elevation remains the ballistic solution for the target
	# plane. This is the Minotaurus' original deterministic "spread".
	_trajectory_impact_position = BallisticsScript.parallel_impact_position(
		_launch_position, _aim_position, _direction
	)
	var offset := _trajectory_impact_position - _launch_position
	var horizontal := Vector3(offset.x, 0.0, offset.z)
	var horizontal_distance := horizontal.length()
	var ballistic_velocities: Array[Vector3] = BallisticsScript.launch_velocities(
		bullet, _launch_position, _trajectory_impact_position, _gravity_world,
		bullet.maximum_range_world() + _target_range_allowance
	)
	if not ballistic_velocities.is_empty():
		_trajectory_initial_velocity = BallisticsScript.closest_velocity(
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


func _advance_trajectory(_previous_elapsed: float, current_elapsed: float) -> void:
	var from := global_position
	var time := current_elapsed
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
	if (
		_targets_ground_position
		and current_elapsed + 0.000001 >= _trajectory_duration
	):
		_resolve_arrival(_trajectory_impact_position)


func _advance_direct(delta: float, previous_elapsed: float) -> void:
	var tracks_live_homing_target: bool = bullet.is_homing() and _tracks_live_target
	if tracks_live_homing_target \
	and previous_elapsed * RULE_UPDATES_PER_SECOND \
		>= bullet.homing_delay_ticks():
		_update_homing(delta)

	var remaining_range := maxf(_maximum_flight_distance - traveled_distance, 0.0)
	if remaining_range <= 0.000001:
		_expire(&"range_exhausted")
		return
	var step_distance := minf(bullet.speed() * delta, remaining_range)
	if not tracks_live_homing_target:
		step_distance = minf(
			step_distance, maxf(_aim_travel_distance - traveled_distance, 0.0)
		)
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

	if not tracks_live_homing_target \
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
	if intended_target.has_method("combat_has_precise_collision") \
	and bool(intended_target.call("combat_has_precise_collision")):
		return false
	var target_position := _current_target_position()
	if not target_position.is_finite():
		return false
	if BallisticsScript.distance_to_segment(target_position, from, to) \
	> _target_hit_radius(intended_target):
		return false
	_impact_target(intended_target, target_position, _stops_at(intended_target))
	return state != State.FLYING


func _handle_collisions(collisions: Array[Dictionary]) -> bool:
	for collision in collisions:
		var collider: Object = collision.get("collider") as Object
		var entity := CombatTargetScript.entity_of(collider)
		if entity != null and entity == _source():
			continue
		if entity != null:
			if not bullet.can_hit(entity):
				continue
			_impact_target(entity, Vector3(collision["position"]), _stops_at(entity))
			if state != State.FLYING:
				return true
			continue
		if not bullet.is_piercing():
			_impact_ground(Vector3(collision["position"]))
			return true
	return false


## Whether hitting `entity` should stop this projectile's travel. Explicitly
## piercing bullets (the Sonic wave) never stop. Continuous streams (flame,
## gas) represent an ongoing jet rather than a single discrete shot: they
## keep burning through every unit and building in their path (matching the
## original engine's "sprays a whole line of infantry" behavior) but still
## stop dead at walls, which the source rules model as a distinct fortified
## obstacle rather than an ordinary building.
func _stops_at(entity: Object) -> bool:
	if bullet.is_piercing():
		return false
	if bullet.is_continuous():
		return entity is Node and (entity as Node).is_in_group("wall_buildings")
	return true


func _impact_target(entity: Object, world_position: Vector3, stop: bool) -> void:
	global_position = world_position
	_resolve_impact(entity, world_position)
	if stop:
		_finish_impact(&"impact_target", world_position)


func _impact_ground(world_position: Vector3) -> void:
	var intended_target := target()
	if intended_target != null \
	and _target_is_alive() \
	and bullet.can_hit(intended_target) \
	and intended_target.has_method("combat_contains_impact_position") \
	and bool(intended_target.call(
		"combat_contains_impact_position", world_position
	)):
		_impact_target(intended_target, world_position, true)
		return
	global_position = world_position
	_resolve_impact(null, world_position)
	_finish_impact(&"impact_ground", world_position)


func _resolve_impact(direct_target: Object, world_position: Vector3) -> void:
	var results: Array[Dictionary] = _impact_resolver.resolve(
		bullet, self, world_position, direct_target, _source(), _damage_scale
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
	_spawn_explosion_visuals(world_position)
	_spawn_ground_decal(direct_target, world_position)
	_spawn_linger_effect(direct_target, world_position)


func _spawn_linger_effect(
		direct_target: Object,
		world_position: Vector3
	) -> void:
	if bullet == null \
	or bullet.linger_duration_ticks() <= 0.0 \
	or bullet.linger_damage() <= 0.0 \
	or direct_target == null \
	or not is_instance_valid(direct_target) \
	or get_parent() == null \
	or not get_parent().is_inside_tree():
		return
	var effect = CombatLingerEffectScript.new()
	get_parent().add_child(effect)
	if not effect.configure(bullet, direct_target, world_position):
		effect.free()


func _spawn_explosion_visuals(world_position: Vector3) -> void:
	if bullet == null or get_parent() == null or not get_parent().is_inside_tree():
		return
	for effect_id in bullet.explosion_effect_ids():
		var scene: PackedScene = bullet.explosion_visual_scene(effect_id)
		if scene == null:
			continue
		var effect = CombatImpactEffectScript.new()
		get_parent().add_child(effect)
		if not effect.configure(effect_id, scene, world_position):
			effect.free()


func _spawn_ground_decal(direct_target: Object, world_position: Vector3) -> void:
	if (
		bullet == null
		or bullet.damage_to_tile() <= 0.0
		or get_parent() == null
		or not get_parent().is_inside_tree()
	):
		return
	# MissileHit also belongs to air-only projectiles. Their detonation does not
	# touch a terrain tile and therefore must not paint a crater underneath an
	# aircraft.
	if (
		direct_target != null
		and is_instance_valid(direct_target)
		and direct_target.has_method("combat_is_airborne")
		and bool(direct_target.call("combat_is_airborne"))
	):
		return
	var ground_decal = CombatGroundDecalScript.new()
	get_parent().add_child(ground_decal)
	if not ground_decal.configure(bullet.damage_to_tile(), world_position):
		ground_decal.free()


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
	var keeps_laser_visual: bool = (
		bullet != null
		and bullet.is_laser()
		and reason in [&"impact_target", &"impact_ground"]
		and _create_laser_visual(_launch_position, world_position)
	)
	finished.emit(finish_reason, world_position)
	if not is_inside_tree():
		return
	if keeps_laser_visual:
		var cleanup := Timer.new()
		cleanup.name = "LaserCleanup"
		cleanup.one_shot = true
		cleanup.wait_time = LASER_VISUAL_DURATION
		add_child(cleanup)
		cleanup.timeout.connect(_queue_free_finished)
		cleanup.start()
	else:
		call_deferred("_queue_free_finished")


func _create_laser_visual(start_position: Vector3, end_position: Vector3) -> bool:
	if not is_inside_tree() or get_node_or_null("LaserBeam") != null:
		return false
	var segment := end_position - start_position
	var length := segment.length()
	if length <= 0.000001:
		return false

	var beam_direction := segment / length
	var beam := Node3D.new()
	beam.name = "LaserBeam"
	beam.set_meta("start_position", start_position)
	beam.set_meta("end_position", end_position)
	add_child(beam)
	# Impact resolution moves the projectile node to the hit position. Keeping
	# the beam top-level prevents that parent move from dragging its midpoint
	# away from the muzzle on the same frame.
	beam.top_level = true
	beam.global_transform = Transform3D(
		Basis(Quaternion(Vector3.UP, beam_direction)),
		start_position.lerp(end_position, 0.5)
	)

	var is_infantry_laser: bool = bullet.id() == &"InfLaser_B"
	var color: Color = INFANTRY_LASER_COLOR if is_infantry_laser else LASER_TANK_COLOR
	var glow_color: Color = Color(color.r, color.g, color.b, 0.24) \
		if is_infantry_laser else LASER_TANK_GLOW_COLOR
	var glow_energy: float = 2.5 if is_infantry_laser else LASER_TANK_GLOW_ENERGY
	var glow_radius: float = LASER_GLOW_RADIUS \
		if is_infantry_laser else LASER_TANK_GLOW_RADIUS
	_add_laser_layer(
		beam, "Glow", length, glow_radius,
		glow_color, glow_energy
	)
	_add_laser_layer(
		beam, "Core", length, LASER_CORE_RADIUS,
		Color(
			lerpf(color.r, 1.0, 0.72),
			lerpf(color.g, 1.0, 0.72),
			lerpf(color.b, 1.0, 0.72),
			0.98
		),
		5.0
	)
	return true


func _add_laser_layer(
		parent: Node3D,
		layer_name: String,
		length: float,
		radius: float,
		color: Color,
		emission_energy: float
	) -> void:
	var mesh := CylinderMesh.new()
	mesh.height = length
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.radial_segments = LASER_RADIAL_SEGMENTS
	mesh.rings = 1

	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = Color(color.r, color.g, color.b)
	material.emission_energy_multiplier = emission_energy
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.material = material

	var visual := MeshInstance3D.new()
	visual.name = layer_name
	visual.mesh = mesh
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(visual)


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
		var rid: RID = hit.get("rid", RID())
		if not rid.is_valid():
			break
		var collider := hit.get("collider") as CollisionObject3D
		if collider != null and collider.get_meta("combat_ignore", false):
			excludes.append(rid)
			continue
		result.append(hit)
		excludes.append(rid)
	return result


func _resolve_target_position(
		target_or_position: Variant,
		world_origin := Vector3.INF
	) -> Dictionary:
	if target_or_position is Vector3:
		return {"valid": true, "position": target_or_position}
	if target_or_position is Object and is_instance_valid(target_or_position):
		var position := _object_position(target_or_position as Object, world_origin)
		return {"valid": position.is_finite(), "position": position}
	return {"valid": false, "position": Vector3.ZERO}


func _object_position(object: Object, world_origin := Vector3.INF) -> Vector3:
	return CombatTargetScript.position_of(object, world_origin)


func _current_target_position() -> Vector3:
	var intended_target := target()
	return _object_position(intended_target, global_position) \
		if intended_target != null else Vector3.INF


func _target_is_alive() -> bool:
	return CombatTargetScript.is_alive(target())


func _target_hit_radius(intended_target: Object) -> float:
	return CombatTargetScript.hit_radius(
		intended_target, CombatRulesScript.DEFAULT_TARGET_HIT_RADIUS
	)


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
