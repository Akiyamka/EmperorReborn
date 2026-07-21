extends CharacterBody3D
class_name Unit

const SpatialOrientationScript := preload("res://scripts/world/spatial_orientation.gd")
const CombatTurretScript := preload("res://scripts/combat/combat_turret.gd")

signal owner_changed(player_id: int)
signal navigation_enemy_encountered(enemies: Array[Node3D])
signal deployment_animation_finished
signal attack_order_changed(active: bool, target: Variant)
signal weapon_fired(projectiles: Array, target: Variant, weapon_index: int)

const PlayerDataScript := preload("res://scripts/players/player_data.gd")
const SelectionHaloScript := preload("res://scripts/ui/selection_halo.gd")

const COLLISION_OBJECT_NAME := "#~~0"
const TERRAIN_COLLISION_MASK := 1
const TERRAIN_RAY_HEIGHT := 200.0
const MIN_SLOPE_SPEED_MULTIPLIER := 0.65
const MAX_SLOPE_SPEED_MULTIPLIER := 1.50
const SLOPE_PROBE_DISTANCE := 0.5
const SLOPE_ALIGNMENT_RESPONSE := 10.0
## The incidental Tleilaxu walker predates the Mech rule used by the three
## playable House walkers, but its converted model has the same articulated
## leg hierarchy and must retain a level gameplay root as well.
const LEGACY_WALKER_UNIT_IDS: Array[StringName] = [&"INTLWalker"]
## Rules.txt stores TurnRate in radians per movement update. Navigation runs at
## 20 fixed updates per second, so use the same cadence for the unmanaged
## fallback to keep turning independent of the caller's frame rate.
const RULE_MOVEMENT_UPDATES_PER_SECOND := 20.0
## ReloadCount is authored in the same 20 Hz frame domain as the XBF model
## animations. Reload starts after an authored Fire clip completes.
const RULE_COMBAT_TICKS_PER_SECOND := 20.0
const FIRE_ANIMATION_PREFIX := "Fire_"
const FIRE_EVENT_EPSILON := 0.0001
const MOVING_ANIMATION := &"Move"
const IDLE_ANIMATION := &"Stationary"
const IDLE_ANIMATION_PREFIX := "Idle"
## The original MCV model has no clip literally named Deploy. Move_Stop is its
## authored transition from driving to a braced stationary pose and is the
## source-backed fallback for the first phase of deployment.
const DEPLOYMENT_ANIMATION_CANDIDATES: Array[StringName] = [
	&"Deploy", &"Deploying", &"Unpack", &"Move_Stop"
]
## A converted Move clip contains a complete left/right gait cycle. Each half
## alternates an authored walking-speed phase with the slower MechSpeed pause.
const MECH_STEPS_PER_MOVE_CYCLE := 2.0
const MECH_STEP_RISE_START := 0.38
const MECH_STEP_RISE_END := 0.46
const MECH_STEP_FALL_START := 0.47
const MECH_STEP_FALL_END := 0.63
const DEFAULT_MECH_MOVE_CYCLE_SECONDS := 1.0
const ATTACK_REPATH_INTERVAL_SECONDS := 0.25
const ATTACK_REPATH_DISTANCE := 0.5

enum SlopeAlignmentMode {
	AUTO,
	ENABLED,
	DISABLED,
}

@export var config_id: StringName
@export var owner_player_id := PlayerDataScript.NEUTRAL_PLAYER_ID:
	set(value):
		if owner_player_id == value:
			return
		owner_player_id = value
		if is_inside_tree():
			_refresh_owner_visuals()
		owner_changed.emit(owner_player_id)
@export var move_speed := 5.0
@export var mech_speed := 0.0
@export var turn_rate := 0.0
@export var can_move_any_direction := false
@export var arrival_radius := 0.2
@export var visual_root_path := NodePath("VisualRoot")
## AUTO follows the terrain only for ground vehicles. Infantry, aircraft and
## articulated Mech units stay upright; individual scenes can force either
## behavior for unusual visuals that are not described by the original rules.
@export var slope_alignment_mode := SlopeAlignmentMode.AUTO
@export var max_health := 0.0
@export var max_shields := 0.0
@export var max_passengers := 0.0
@export var armour_type: StringName = &""

@onready var visual_root: Node3D = get_node_or_null(visual_root_path)

var unit_config: Resource
var target_position: Vector3
var is_selected := false
var is_hovered := false
var invulnerable := false
var health := 0.0:
	set(value):
		health = clampf(value, 0.0, max_health)
var shields := 0.0:
	set(value):
		shields = clampf(value, 0.0, max_shields)
		_refresh_shield_visibility()
var passengers := 0.0
var combat_turrets: Array = []
var _shield_meshes: Array[MeshInstance3D] = []
var _shield_time := 0.0
var _scroll_fx_meshes: Array[MeshInstance3D] = []
var _scroll_fx_time := 0.0
var _selection_halo
var _animation_players: Array[AnimationPlayer] = []
var _movement_animation_active := false
var _stationary_repeats_remaining: Dictionary = {}
var _navigation_managed := false
var _navigation_system = null
var _pending_navigation_order := Vector3.ZERO
var _pending_navigation_exit := Vector3.INF
var _has_pending_navigation_order := false
var _navigation_requested_velocity := Vector3.ZERO
var _navigation_debug_visible := false
var _visual_root_rest_basis := Basis.IDENTITY
var _visual_slope_target_basis := Basis.IDENTITY
var _last_terrain_normal := Vector3.UP
var _uses_mech_gait := false
var _mech_gait_elapsed := 0.0
var _is_deploying := false
var _deployment_aligning := false
var _deployment_alignment_direction := Vector3.ZERO
var _deployment_animation_player: AnimationPlayer
var _deployment_animation_name: StringName = &""
var _has_attack_order := false
var _attack_ground_position := Vector3.INF
var _attack_target_ref: WeakRef
var _attack_is_ground := false
var _attack_is_pursuing := false
var _attack_repath_remaining := 0.0
var _attack_last_path_position := Vector3.INF
var _issuing_attack_move := false
var _fire_sequence_active := false
var _fire_sequence_turret
var _fire_sequence_player: AnimationPlayer
var _fire_sequence_animation: StringName = &""
var _fire_sequence_duration := 0.0
var _fire_sequence_elapsed := 0.0
var _fire_sequence_shot_times: Array[float] = []
var _fire_sequence_next_shot := 0
var _fire_sequence_shots_emitted := 0


func _ready() -> void:
	if visual_root != null:
		_visual_root_rest_basis = visual_root.transform.basis.orthonormalized()
		_visual_slope_target_basis = _visual_root_rest_basis
	_apply_rules_config()
	target_position = global_position
	# Terrain height is sampled explicitly below. Letting CharacterBody collide
	# with the terrain mesh makes each triangle edge behave like a small wall,
	# which prevents units from climbing otherwise traversable slopes. The
	# collision layer remains enabled, so mouse rays can still select this unit.
	collision_mask = 0
	_add_authored_collision()
	_shield_meshes = _collect_shield_meshes()
	_scroll_fx_meshes = _collect_scroll_fx_meshes()
	_animation_players = _collect_animation_players()
	_prioritize_animations_before_unit_logic()
	_prepare_idle_animations()
	_set_movement_animation(false)
	health = max_health
	shields = max_shields
	_add_selection_halo()
	_refresh_owner_visuals()


func _process(delta: float) -> void:
	for turret in combat_turrets:
		turret.advance_ticks(delta * RULE_COMBAT_TICKS_PER_SECOND)
	_advance_attack_order(delta)
	if not _has_attack_order:
		# Movement/idle animations key some of the same model pivots as combat.
		# Keep the combat angle authoritative after an order ends and return it
		# to the authored forward pose through the normal turret servo. Without
		# this, the animation snaps the visible pivot to rest while current_yaw
		# stays cached, and the stale angle reappears on the next attack order.
		for turret in combat_turrets:
			turret.recenter(delta)
	_advance_visual_slope_alignment(delta)
	# These shaders take their scroll/pulse phase from here: a continuous
	# phase cannot come from animation tracks (it would snap on clip loops),
	# and TIME in the shader would keep the editor viewport redrawing.
	if shields > 0.0 and not _shield_meshes.is_empty():
		_shield_time += delta
		for mesh_instance in _shield_meshes:
			mesh_instance.set_instance_shader_parameter("fx_time", _shield_time)
	if not _scroll_fx_meshes.is_empty():
		_scroll_fx_time += delta
		for mesh_instance in _scroll_fx_meshes:
			mesh_instance.set_instance_shader_parameter("fx_time", _scroll_fx_time)


func _physics_process(delta: float) -> void:
	if _is_deploying:
		velocity = Vector3.ZERO
		if _deployment_aligning:
			if _turn_toward(_deployment_alignment_direction, delta):
				_deployment_aligning = false
				_set_visual_slope_target(_last_terrain_normal)
				_start_deployment_animation()
		return
	if _navigation_managed:
		return
	var offset := target_position - global_position
	offset.y = 0.0
	var requested_velocity := Vector3.ZERO
	var movement_speed := navigation_move_speed()

	if offset.length() <= arrival_radius:
		velocity = Vector3.ZERO
	else:
		var direction := offset.normalized()
		requested_velocity = direction * movement_speed
		var heading_reached := _turn_toward(direction, delta)
		if can_move_any_direction or heading_reached:
			velocity = direction * movement_speed * _slope_speed_multiplier(direction, delta)
		else:
			velocity = Vector3.ZERO

	_set_navigation_debug_direction(requested_velocity)
	var animation_speed_scale := _movement_animation_speed_scale()
	_set_movement_animation(not velocity.is_zero_approx(), animation_speed_scale)
	_advance_mech_gait(delta, animation_speed_scale)
	move_and_slide()
	_snap_to_terrain()


## `exit_point` is a mandatory first waypoint (a production building's front
## exit): the unit walks straight to it before regular routing takes over.
func move_to(world_position: Vector3, exit_point := Vector3.INF) -> void:
	if _navigation_managed and _navigation_system != null:
		_navigation_system.command_move([self], world_position, _navigation_system.MoveMode.FREE, exit_point)
		return
	if not prepare_navigation_order(world_position, exit_point, 0):
		return
	# The navigation system registers freshly added units deferred, and the
	# registration resets the agent's destination to the unit's position. An
	# order issued in the spawn frame (the production rally point) is kept
	# here so the registration handoff can re-issue it.
	_pending_navigation_order = world_position
	_pending_navigation_exit = exit_point
	_has_pending_navigation_order = true
	target_position = Vector3(world_position.x, global_position.y, world_position.z)
	_set_movement_animation(global_position.distance_to(target_position) > arrival_radius)


## Called by UnitNavigationSystem before it mutates an agent's route. Units may
## perform order-specific cleanup or return false to defer/reject the route.
## Unmanaged fallback movement uses the same API, keeping order preparation in
## the unit instead of teaching command controllers about unit state machines.
func prepare_navigation_order(
		_world_position: Vector3, _exit_point := Vector3.INF, _move_mode := 0
	) -> bool:
	if not _issuing_attack_move:
		cancel_attack_order()
	return not _is_deploying


func set_navigation_managed(active: bool) -> void:
	_navigation_managed = active
	if active:
		velocity = Vector3.ZERO
		_set_navigation_debug_direction(Vector3.ZERO)


func set_navigation_controller(controller) -> void:
	_navigation_system = controller
	if _navigation_system == null or not _has_pending_navigation_order:
		return
	var order := _pending_navigation_order
	var exit_point := _pending_navigation_exit
	_has_pending_navigation_order = false
	_pending_navigation_exit = Vector3.INF
	move_to(order, exit_point)


func set_navigation_destination(world_position: Vector3) -> void:
	target_position = Vector3(world_position.x, global_position.y, world_position.z)


## Local avoidance uses discs, while authored unit volumes may be long boxes.
## The smaller horizontal half-extent is the stable body width: using the long
## axis would leave vehicle-sized gaps beside every tank, while the rules-only
## radius is small enough for infantry to run visibly through their hulls.
func navigation_collision_radius(fallback: float) -> float:
	var half_extents := _navigation_collision_half_extents()
	var authored_width_radius := minf(half_extents.x, half_extents.y)
	return maxf(fallback, authored_width_radius)


## Long vehicles are represented as rounded capsules for navigation. `radius`
## above is their cross-section and remains the right unit/unit spacing. Around
## static terrain, however, a freely turning capsule needs its complete rotation
## envelope: otherwise the centre path clears a building while the harvester's
## nose and tail still sweep through its cells.
func navigation_rotation_radius(fallback: float) -> float:
	var half_extents := _navigation_collision_half_extents()
	return maxf(fallback, maxf(half_extents.x, half_extents.y))


func _navigation_collision_half_extents() -> Vector2:
	# Lightweight gameplay test doubles intentionally omit the converted visual
	# hierarchy; in that case the rules-derived fallback remains authoritative.
	if visual_root == null:
		return Vector2.ZERO
	var maximum_x := 0.0
	var maximum_z := 0.0
	var to_unit := global_transform.affine_inverse()
	for source in _collision_sources():
		var points: PackedVector3Array = source.get_meta("collision_points", PackedVector3Array())
		var source_to_unit: Transform3D = to_unit * source.global_transform
		for point in points:
			var local_point: Vector3 = source_to_unit * point
			maximum_x = maxf(maximum_x, absf(local_point.x))
			maximum_z = maxf(maximum_z, absf(local_point.z))
	return Vector2(maximum_x, maximum_z)


func navigation_step(horizontal_velocity: Vector3, delta: float) -> void:
	if _is_deploying:
		velocity = Vector3.ZERO
		_set_navigation_debug_direction(Vector3.ZERO)
		return
	# Preserve the requested course before a tracked unit possibly converts its
	# translational velocity to zero while turning in place. This is the value
	# shown by the selected-unit navigation debug arrow.
	_set_navigation_debug_direction(horizontal_velocity)
	velocity = Vector3(horizontal_velocity.x, 0.0, horizontal_velocity.z)
	# Crowded units receive tiny non-zero velocities from collision resolution;
	# skip negligible motion so it cannot jitter the unit's heading.
	if velocity.length_squared() > 0.000001:
		var heading_reached := _turn_toward(velocity.normalized(), delta)
		if not can_move_any_direction and not heading_reached:
			velocity = Vector3.ZERO
	var animation_speed_scale := _movement_animation_speed_scale()
	_set_movement_animation(not velocity.is_zero_approx(), animation_speed_scale)
	_advance_mech_gait(delta, animation_speed_scale)
	# Unit/unit collision has already been resolved centrally as swept discs.
	# Applying the exact fixed navigation delta avoids depending on physics-frame
	# frequency and keeps command replays stable.
	global_position += velocity * delta
	_snap_to_terrain()


## The navigation solver must see the phase speed before avoidance is resolved;
## applying it afterwards would let following units plan through a mech that is
## currently in its slower between-step phase.
func navigation_move_speed() -> float:
	if not _uses_mech_gait:
		return move_speed
	var cycle_duration := _mech_move_cycle_duration()
	var cycle_phase := fposmod(_mech_gait_elapsed, cycle_duration) / cycle_duration
	var step_phase := fposmod(cycle_phase * MECH_STEPS_PER_MOVE_CYCLE, 1.0)
	# Smoothstep keeps the two rule-defined speeds intact away from the short
	# transition windows while preventing an abrupt velocity change at a footfall.
	var rise := smoothstep(MECH_STEP_RISE_START, MECH_STEP_RISE_END, step_phase)
	var fall := 1.0 - smoothstep(MECH_STEP_FALL_START, MECH_STEP_FALL_END, step_phase)
	return lerpf(mech_speed, move_speed, rise * fall)


func _advance_mech_gait(delta: float, animation_speed_scale: float) -> void:
	if not _uses_mech_gait or not _movement_animation_active or delta <= 0.0:
		return
	var cycle_duration := _mech_move_cycle_duration()
	_mech_gait_elapsed = fposmod(
		_mech_gait_elapsed + delta * maxf(animation_speed_scale, 0.0),
		cycle_duration
	)


func _mech_move_cycle_duration() -> float:
	for player in _animation_players:
		if not player.has_animation(MOVING_ANIMATION):
			continue
		var animation := player.get_animation(MOVING_ANIMATION)
		if animation != null and animation.length > 0.0:
			return animation.length
	return DEFAULT_MECH_MOVE_CYCLE_SECONDS


func navigation_blocked_by_enemy(enemies: Array[Node3D]) -> void:
	if enemies.is_empty():
		return
	if has_method("attack_target"):
		call("attack_target", enemies[0])
	else:
		navigation_enemy_encountered.emit(enemies)


func _snap_to_terrain() -> void:
	# Units are moved horizontally, then projected back onto the terrain mesh.
	# Keeping this independent of CharacterBody's floor state lets authored unit
	# collision volumes remain usable for selection while the unit follows every
	# height change in the map instead of retaining its spawn elevation.
	var hit := _terrain_hit_at(global_position)
	if hit.is_empty():
		return

	global_position.y = (hit["position"] as Vector3).y
	_set_visual_slope_target(hit.get("normal", Vector3.UP) as Vector3)


## Keeps gameplay orientation, navigation collision and the selection halo
## upright while tilting only the rendered model. A terrain normal uniquely
## determines pitch and roll; projecting the unit's forward vector onto that
## plane preserves its current yaw.
func _set_visual_slope_target(terrain_normal: Vector3) -> void:
	_last_terrain_normal = terrain_normal.normalized() \
		if terrain_normal.length_squared() > 0.000001 else Vector3.UP
	if _last_terrain_normal.dot(Vector3.UP) < 0.0:
		_last_terrain_normal = -_last_terrain_normal
	if visual_root == null or not aligns_visual_to_terrain_slope():
		_visual_slope_target_basis = _visual_root_rest_basis
		return

	var unit_basis := global_transform.basis.orthonormalized()
	var slope_forward := (-unit_basis.z).slide(_last_terrain_normal)
	if slope_forward.length_squared() <= 0.000001:
		slope_forward = unit_basis.x.cross(_last_terrain_normal)
	if slope_forward.length_squared() <= 0.000001:
		_visual_slope_target_basis = _visual_root_rest_basis
		return
	slope_forward = slope_forward.normalized()
	var slope_z := -slope_forward
	var slope_x := _last_terrain_normal.cross(slope_z).normalized()
	var slope_basis := Basis(slope_x, _last_terrain_normal, slope_z).orthonormalized()
	_visual_slope_target_basis = (
		unit_basis.inverse() * slope_basis * _visual_root_rest_basis
	).orthonormalized()


func _advance_visual_slope_alignment(delta: float) -> void:
	if visual_root == null or delta <= 0.0:
		return
	var blend := 1.0 - exp(-SLOPE_ALIGNMENT_RESPONSE * delta)
	visual_root.transform.basis = visual_root.transform.basis.orthonormalized().slerp(
		_visual_slope_target_basis, clampf(blend, 0.0, 1.0)
	).orthonormalized()


func aligns_visual_to_terrain_slope() -> bool:
	match slope_alignment_mode:
		SlopeAlignmentMode.ENABLED:
			return true
		SlopeAlignmentMode.DISABLED:
			return false
	if unit_config == null:
		return false
	return (
		float(unit_config.field(&"size", 1.0)) > 1.0
		and not bool(unit_config.field(&"infantry", false))
		and not bool(unit_config.field(&"can_fly", false))
		and not bool(unit_config.field(&"mech", false))
		and config_id not in LEGACY_WALKER_UNIT_IDS
	)


func _slope_speed_multiplier(direction: Vector3, delta: float) -> float:
	var current_hit := _terrain_hit_at(global_position)
	if current_hit.is_empty():
		return 1.0

	var probe_distance := maxf(move_speed * delta, SLOPE_PROBE_DISTANCE)
	var ahead := global_position + direction * probe_distance
	var ahead_hit := _terrain_hit_at(ahead)
	if ahead_hit.is_empty():
		return 1.0

	var current_position: Vector3 = current_hit["position"]
	var ahead_position: Vector3 = ahead_hit["position"]
	var slope := (ahead_position.y - current_position.y) / probe_distance
	if slope > 0.0:
		return maxf(1.0 - slope * 0.65, MIN_SLOPE_SPEED_MULTIPLIER)
	return minf(1.0 - slope * 0.75, MAX_SLOPE_SPEED_MULTIPLIER)


func _turn_toward(direction: Vector3, delta: float) -> bool:
	var horizontal_direction := Vector3(direction.x, 0.0, direction.z)
	if horizontal_direction.length_squared() <= 0.000001:
		return true
	horizontal_direction = horizontal_direction.normalized()
	var current_yaw := global_rotation.y
	var target_yaw := SpatialOrientationScript.yaw_facing(horizontal_direction, current_yaw)
	if is_zero_approx(angle_difference(current_yaw, target_yaw)):
		return true
	if turn_rate <= 0.0 or delta <= 0.0:
		return false
	var maximum_step := turn_rate * RULE_MOVEMENT_UPDATES_PER_SECOND * delta
	global_rotation.y = rotate_toward(current_yaw, target_yaw, maximum_step)
	return is_zero_approx(angle_difference(global_rotation.y, target_yaw))


func facing_direction() -> Vector3:
	return SpatialOrientationScript.world_forward(self)


func face_direction(direction: Vector3) -> void:
	var current_yaw := global_rotation.y if is_inside_tree() else rotation.y
	var target_yaw := SpatialOrientationScript.yaw_facing(direction, current_yaw)
	if is_inside_tree():
		global_rotation.y = target_yaw
		_set_visual_slope_target(_last_terrain_normal)
	else:
		rotation.y = target_yaw


func _terrain_hit_at(position: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(
		position + Vector3.UP * TERRAIN_RAY_HEIGHT,
		position - Vector3.UP * TERRAIN_RAY_HEIGHT,
		TERRAIN_COLLISION_MASK
	)
	query.exclude = [get_rid()]
	return get_world_3d().direct_space_state.intersect_ray(query)


func setup(unit_id: StringName) -> void:
	_cancel_fire_sequence(true, false)
	config_id = unit_id
	if not is_inside_tree():
		return

	_apply_rules_config()
	health = max_health
	shields = max_shields
	_set_visual_slope_target(_last_terrain_normal)


## Used by runtime unit production and startup snapshots when a generic Unit
## scene must display a different converted model.
func replace_visual_scene(model_scene: PackedScene) -> void:
	if model_scene == null or visual_root == null:
		return
	_cancel_fire_sequence(true, false)
	for child in visual_root.get_children():
		visual_root.remove_child(child)
		child.free()
	visual_root.add_child(model_scene.instantiate())
	_bind_combat_turrets()
	_shield_meshes = _collect_shield_meshes()
	_scroll_fx_meshes = _collect_scroll_fx_meshes()
	_animation_players = _collect_animation_players()
	_prioritize_animations_before_unit_logic()
	_prepare_idle_animations()
	_set_movement_animation(false)
	# Packed model scenes keep gameplay-controlled effect meshes hidden and
	# carry no per-instance owner color. Reapply the unit's current runtime
	# state after swapping the visual (for example during F7 snapshot restore).
	_refresh_shield_visibility()
	_refresh_owner_visuals()


func set_invulnerable(value: bool) -> void:
	invulnerable = value


func grant_temporary_invulnerability(duration: float) -> void:
	# Mirrors Building.set_invulnerable/take_damage; used e.g. by
	# BuildingSurvivors for the 1s post-spawn splash immunity from §2.1.
	invulnerable = true
	get_tree().create_timer(duration).timeout.connect(_clear_invulnerability)


func take_damage(amount: float) -> void:
	if invulnerable or amount <= 0.0 or health <= 0.0:
		return

	var remaining_damage := amount
	if shields > 0.0:
		var absorbed := minf(shields, remaining_damage)
		shields -= absorbed
		remaining_damage -= absorbed
	if remaining_damage <= 0.0:
		return
	health -= remaining_damage
	if health <= 0.0:
		queue_free()


func combat_armour_type() -> StringName:
	return armour_type


func combat_is_airborne() -> bool:
	return unit_config != null and bool(unit_config.field(&"can_fly", false))


func combat_aim_position() -> Vector3:
	# The gameplay root sits on the terrain. A projectile aimed there forces
	# horizontal-only weapons to compare their muzzle direction with a point
	# below the target, so they can turn in yaw forever without ever satisfying
	# the pitch tolerance. The converted selection volume follows the visible
	# body and gives combat a stable centre point after runtime model swaps.
	return to_global(_selection_bounds().get_center())


func combat_is_alive() -> bool:
	return health > 0.0 and not is_queued_for_deletion()


func combat_hit_radius() -> float:
	return maxf(arrival_radius, 0.25)


func combat_owner_player_id() -> int:
	# Stable combat-facing ownership contract used for friendly-fire scaling.
	return owner_player_id


## Rotates every authored weapon joint toward a world-space point. The return
## value becomes true only when every configured weapon is inside its own
## acceptable-aim tolerance from Rules.txt.
func aim_turrets_at(world_position: Vector3, delta: float) -> bool:
	if combat_turrets.is_empty():
		return false
	var all_aimed := true
	for turret in combat_turrets:
		all_aimed = turret.aim_at(world_position, delta) and all_aimed
	return all_aimed


## Returns world transforms/positions/directions for every authored muzzle of
## one weapon. Multi-barrel weapons expose all >> markers beneath their ::N
## pivot instead of confusing muzzle numbers with weapon numbers.
func turret_emission_points(weapon_index: int = 0) -> Array[Dictionary]:
	var turret = _combat_turret_for_weapon(weapon_index)
	if turret == null:
		return []
	return turret.emission_points()


## Selects the next muzzle in authored marker order and advances the sequence.
func next_turret_emission(weapon_index: int = 0) -> Dictionary:
	var turret = _combat_turret_for_weapon(weapon_index)
	if turret == null:
		return {}
	return turret.next_emission()


## Fires one rules-backed weapon from its next authored muzzle. A live target
## remains attached only for homing; ordinary projectiles keep this frame's
## position, matching the original no-lead behavior.
func fire_weapon_at(
		target_or_position: Variant,
		weapon_index: int = 0,
		projectile_parent: Node = null,
		aim_offset := Vector3.ZERO
	) -> Array:
	var turret = _combat_turret_for_weapon(weapon_index)
	if turret == null:
		return []
	return turret.try_fire_at(target_or_position, self, projectile_parent, aim_offset)


func _combat_turret_for_weapon(weapon_index: int):
	if weapon_index < 0:
		return null
	for turret in combat_turrets:
		if turret.weapon_index() == weapon_index:
			return turret
	return null


func can_attack(target_or_position: Variant) -> bool:
	if _is_deploying:
		return false
	for turret in combat_turrets:
		if turret.can_target(target_or_position):
			return true
	return false


## Installs an explicit player attack order. A Node target is tracked until it
## dies; a Vector3 remains a fixed attack-ground coordinate. Relation checks
## belong to UnitCommandController so Ctrl can deliberately force friendly or
## neutral fire through this same combat-facing API.
func command_attack(target_or_position: Variant) -> bool:
	if not can_attack(target_or_position):
		return false
	_cancel_fire_sequence(true)
	stop_at_current_position()
	_has_attack_order = true
	_attack_is_ground = target_or_position is Vector3
	_attack_ground_position = target_or_position if _attack_is_ground else Vector3.INF
	_attack_target_ref = null if _attack_is_ground else weakref(target_or_position as Object)
	_attack_is_pursuing = false
	_attack_repath_remaining = 0.0
	_attack_last_path_position = Vector3.INF
	attack_order_changed.emit(true, target_or_position)
	return true


func cancel_attack_order() -> void:
	_cancel_fire_sequence(true)
	if not _has_attack_order:
		return
	_has_attack_order = false
	_attack_is_ground = false
	_attack_ground_position = Vector3.INF
	_attack_target_ref = null
	_attack_is_pursuing = false
	_attack_repath_remaining = 0.0
	_attack_last_path_position = Vector3.INF
	attack_order_changed.emit(false, null)


func has_attack_order() -> bool:
	return _has_attack_order


func attack_order_target() -> Variant:
	if not _has_attack_order:
		return null
	if _attack_is_ground:
		return _attack_ground_position
	return _attack_target_ref.get_ref() if _attack_target_ref != null else null


func _advance_attack_order(delta: float) -> void:
	if not _has_attack_order or combat_turrets.is_empty() or _is_deploying:
		return
	var attack_target: Variant = attack_order_target()
	if _fire_sequence_active:
		var firing_turret = _fire_sequence_turret
		var sequence_target_alive := _attack_is_ground \
			or _combat_target_is_alive(attack_target)
		var sequence_target_position := _combat_target_position(attack_target) \
			if sequence_target_alive else Vector3.INF
		if firing_turret == null or not sequence_target_position.is_finite():
			# Losing a target does not truncate recoil/recovery frames from an
			# already-started attack. Remaining projectile events are skipped.
			_advance_fire_sequence(delta, attack_target)
			return
		if firing_turret.requires_hull_turn_for(sequence_target_position):
			_turn_toward(
				sequence_target_position - global_position, delta
			)
		firing_turret.aim_at(sequence_target_position, delta)
		# The authored salvo continues as one action. Individual shot validation
		# still rejects a projectile if its target has moved outside legal range.
		_advance_fire_sequence(delta, attack_target)
		return
	if not _attack_is_ground and not _combat_target_is_alive(attack_target):
		cancel_attack_order()
		stop_at_current_position()
		return
	var target_world_position := _combat_target_position(attack_target)
	if not target_world_position.is_finite():
		cancel_attack_order()
		stop_at_current_position()
		return
	var primary_turret = _primary_attack_turret(attack_target)
	if primary_turret == null:
		cancel_attack_order()
		stop_at_current_position()
		return
	var in_range_turrets: Array = []
	for turret in combat_turrets:
		if turret.target_range(attack_target) == CombatTurretScript.TargetRange.IN_RANGE:
			in_range_turrets.append(turret)
	if in_range_turrets.is_empty():
		if primary_turret.target_range(attack_target) == CombatTurretScript.TargetRange.TOO_FAR:
			_advance_attack_pursuit(target_world_position, delta)
			return
		# A minimum-range violation is not solved by moving closer. Keep the
		# explicit order active so a moving target can re-enter weapon range.
		if _attack_is_pursuing:
			stop_at_current_position()
			_attack_is_pursuing = false
		return
	if _attack_is_pursuing:
		stop_at_current_position()
		_attack_is_pursuing = false

	var hull_aimed := true
	for turret in in_range_turrets:
		if turret.requires_hull_turn_for(target_world_position):
			hull_aimed = _turn_toward(target_world_position - global_position, delta)
			break
	for turret in in_range_turrets:
		var aimed: bool = bool(turret.aim_at(target_world_position, delta))
		if turret.requires_hull_turn():
			aimed = aimed and hull_aimed
		if not aimed:
			continue
		if turret.is_ready() and _start_authored_fire_sequence(turret):
			return
		var projectiles: Array = turret.try_fire_at(attack_target, self)
		if not projectiles.is_empty():
			weapon_fired.emit(projectiles, attack_target, turret.weapon_index())


func _start_authored_fire_sequence(turret) -> bool:
	var binding := _fire_animation_binding(turret.weapon_index())
	if binding.is_empty():
		return false
	var player := binding["player"] as AnimationPlayer
	var animation_name := StringName(binding["name"])
	var animation := player.get_animation(animation_name)
	if animation == null or animation.length <= 0.0:
		return false

	stop_at_current_position()
	_fire_sequence_active = true
	_fire_sequence_turret = turret
	_fire_sequence_player = player
	_fire_sequence_animation = animation_name
	_fire_sequence_duration = animation.length
	_fire_sequence_elapsed = 0.0
	_fire_sequence_shot_times = _authored_fire_shot_times(player, animation, turret)
	_fire_sequence_next_shot = 0
	_fire_sequence_shots_emitted = 0
	player.speed_scale = 1.0
	_play_animation_from_start(player, animation_name)
	return true


func _advance_fire_sequence(delta: float, attack_target: Variant) -> void:
	if not _fire_sequence_active:
		return
	_fire_sequence_elapsed = minf(
		_fire_sequence_elapsed + maxf(delta, 0.0), _fire_sequence_duration
	)
	while (
		_fire_sequence_next_shot < _fire_sequence_shot_times.size()
		and _fire_sequence_shot_times[_fire_sequence_next_shot]
			<= _fire_sequence_elapsed + FIRE_EVENT_EPSILON
	):
		_fire_sequence_next_shot += 1
		var projectiles: Array = _fire_sequence_turret.try_fire_at(
			attack_target, self, null, Vector3.ZERO, false, false
		)
		if projectiles.is_empty():
			continue
		_fire_sequence_shots_emitted += projectiles.size()
		weapon_fired.emit(
			projectiles, attack_target, _fire_sequence_turret.weapon_index()
		)
	if _fire_sequence_elapsed + FIRE_EVENT_EPSILON >= _fire_sequence_duration:
		_finish_fire_sequence()


func _finish_fire_sequence() -> void:
	if not _fire_sequence_active:
		return
	var turret = _fire_sequence_turret
	var emitted := _fire_sequence_shots_emitted
	_clear_fire_sequence()
	if emitted > 0 and turret != null:
		turret.begin_reload()
	_set_movement_animation(false)


func _cancel_fire_sequence(begin_reload_if_fired: bool, restore_idle := true) -> void:
	if not _fire_sequence_active:
		return
	var turret = _fire_sequence_turret
	var emitted := _fire_sequence_shots_emitted
	_clear_fire_sequence()
	if begin_reload_if_fired and emitted > 0 and turret != null:
		turret.begin_reload()
	if restore_idle:
		_set_movement_animation(false)


func _clear_fire_sequence() -> void:
	if _fire_sequence_player != null and is_instance_valid(_fire_sequence_player):
		_fire_sequence_player.stop()
	_fire_sequence_active = false
	_fire_sequence_turret = null
	_fire_sequence_player = null
	_fire_sequence_animation = &""
	_fire_sequence_duration = 0.0
	_fire_sequence_elapsed = 0.0
	_fire_sequence_shot_times.clear()
	_fire_sequence_next_shot = 0
	_fire_sequence_shots_emitted = 0


func _fire_animation_binding(weapon_index: int) -> Dictionary:
	var candidates: Array[StringName] = [
		StringName("%s%d" % [FIRE_ANIMATION_PREFIX, weapon_index]),
		&"Fire",
	]
	if weapon_index != 0:
		candidates.append(&"Fire_0")
	for player in _animation_players:
		for animation_name in candidates:
			if player.has_animation(animation_name):
				return {"player": player, "name": animation_name}
	return {}


func _authored_fire_shot_times(
		player: AnimationPlayer, animation: Animation, turret
	) -> Array[float]:
	var fallback: Array[float] = [
		minf(1.0 / RULE_COMBAT_TICKS_PER_SECOND, animation.length)
	]
	if turret.muzzle_count() <= 1:
		return fallback
	var animation_root := player.get_node_or_null(player.root_node)
	if animation_root == null:
		return fallback

	var events: Array[Dictionary] = []
	var used_tracks: Dictionary = {}
	for emission: Dictionary in turret.emission_points():
		var muzzle := emission.get("node") as Node
		if muzzle == null:
			return fallback
		var current := muzzle.get_parent()
		var found := false
		while current != null and (
			current == animation_root or animation_root.is_ancestor_of(current)
		):
			var relative_path := animation_root.get_path_to(current)
			var track_path := NodePath("%s:transform" % String(relative_path))
			var track := animation.find_track(track_path, Animation.TYPE_VALUE)
			if track >= 0:
				var peak := _animation_transform_peak(animation, track)
				if float(peak.get("score", 0.0)) > FIRE_EVENT_EPSILON:
					var track_key := String(track_path)
					if used_tracks.has(track_key):
						return fallback
					used_tracks[track_key] = true
					events.append({
						"muzzle": int(emission.get("index", events.size())),
						"time": clampf(float(peak["time"]), 0.0, animation.length),
					})
					found = true
					break
			if current == animation_root:
				break
			current = current.get_parent()
		if not found:
			return fallback
	if events.size() != turret.muzzle_count():
		return fallback
	events.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["time"]) < float(b["time"])
	)
	var result: Array[float] = []
	for event in events:
		result.append(float(event["time"]))
	return result


func _animation_transform_peak(animation: Animation, track: int) -> Dictionary:
	if animation.track_get_key_count(track) <= 1:
		return {}
	var rest: Variant = animation.track_get_key_value(track, 0)
	if not rest is Transform3D:
		return {}
	var peak_score := 0.0
	var peak_time := 0.0
	for key_index in animation.track_get_key_count(track):
		var value: Variant = animation.track_get_key_value(track, key_index)
		if not value is Transform3D:
			continue
		var score := _transform_difference(rest as Transform3D, value as Transform3D)
		if score > peak_score:
			peak_score = score
			peak_time = animation.track_get_key_time(track, key_index)
	return {"score": peak_score, "time": peak_time}


func _transform_difference(a: Transform3D, b: Transform3D) -> float:
	var result := a.origin.distance_to(b.origin)
	result += a.basis.get_scale().distance_to(b.basis.get_scale())
	var relative_basis := a.basis.orthonormalized().inverse() * b.basis.orthonormalized()
	result += absf(relative_basis.get_rotation_quaternion().get_angle())
	return result


func _primary_attack_turret(attack_target: Variant):
	for turret in combat_turrets:
		if turret.can_target(attack_target):
			return turret
	return null


func _advance_attack_pursuit(target_world_position: Vector3, delta: float) -> void:
	_attack_repath_remaining = maxf(_attack_repath_remaining - delta, 0.0)
	var target_moved := not _attack_last_path_position.is_finite() \
		or _attack_last_path_position.distance_to(target_world_position) >= ATTACK_REPATH_DISTANCE
	if _attack_repath_remaining > 0.0 \
	or (_attack_is_pursuing and not target_moved):
		return
	_attack_is_pursuing = true
	_attack_last_path_position = target_world_position
	_attack_repath_remaining = ATTACK_REPATH_INTERVAL_SECONDS
	_issuing_attack_move = true
	var move_issued := true
	if _navigation_managed and _navigation_system != null:
		var assignments: Array = _navigation_system.command_move(
			[self], target_world_position, UnitNavigationSystem.MoveMode.FREE
		)
		move_issued = not assignments.is_empty()
	else:
		move_to(target_world_position)
	_issuing_attack_move = false
	_attack_is_pursuing = move_issued


func _combat_target_position(attack_target: Variant) -> Vector3:
	if attack_target is Vector3:
		return attack_target
	if not attack_target is Object or not is_instance_valid(attack_target):
		return Vector3.INF
	var target_object := attack_target as Object
	if target_object.has_method("combat_aim_position"):
		var value: Variant = target_object.call("combat_aim_position")
		if value is Vector3:
			return value
	return (target_object as Node3D).global_position if target_object is Node3D else Vector3.INF


func _combat_target_is_alive(attack_target: Variant) -> bool:
	if not attack_target is Object or not is_instance_valid(attack_target):
		return false
	var target_object := attack_target as Object
	if target_object is Node and (target_object as Node).is_queued_for_deletion():
		return false
	return not target_object.has_method("combat_is_alive") \
		or bool(target_object.call("combat_is_alive"))


func stop_at_current_position() -> void:
	if _navigation_managed and _navigation_system != null:
		_navigation_system.stop(self)
	target_position = global_position
	velocity = Vector3.ZERO
	_set_navigation_debug_direction(Vector3.ZERO)
	_set_movement_animation(false)


## Shared unit deployment interface. Eligibility and the per-unit strategy
## live in UnitDeploymentController; Unit owns the common locked alignment and
## animation phases so future deployable units can reuse the same contract.
func deploy(facing_direction: Vector3 = Vector3.ZERO) -> bool:
	if _is_deploying:
		return false
	_is_deploying = true
	stop_at_current_position()
	if _navigation_system != null and _navigation_system.has_method("set_hold_position"):
		_navigation_system.call("set_hold_position", self, true)

	_deployment_alignment_direction = Vector3(
		facing_direction.x, 0.0, facing_direction.z
	)
	_deployment_aligning = (
		_deployment_alignment_direction.length_squared()
			> SpatialOrientationScript.DIRECTION_EPSILON
		and not _turn_toward(_deployment_alignment_direction, 0.0)
	)
	if _deployment_aligning and turn_rate > 0.0:
		_deployment_alignment_direction = _deployment_alignment_direction.normalized()
		return true
	if _deployment_aligning:
		# A deployable unit without an authored turn rate cannot complete a
		# gradual alignment, so preserve the generic deployment contract.
		face_direction(_deployment_alignment_direction)
		_deployment_aligning = false

	_start_deployment_animation()
	return true


func _start_deployment_animation() -> void:
	_deployment_animation_player = null
	_deployment_animation_name = &""
	for candidate in DEPLOYMENT_ANIMATION_CANDIDATES:
		for player in _animation_players:
			if not player.has_animation(candidate):
				continue
			_deployment_animation_player = player
			_deployment_animation_name = candidate
			break
		if _deployment_animation_player != null:
			break

	if _deployment_animation_player == null:
		call_deferred("_emit_deployment_animation_finished")
		return

	var animation := _deployment_animation_player.get_animation(_deployment_animation_name)
	if animation != null:
		animation.loop_mode = Animation.LOOP_NONE
	_deployment_animation_player.stop()
	_deployment_animation_player.play(_deployment_animation_name)


func is_deploying() -> bool:
	return _is_deploying


func _emit_deployment_animation_finished() -> void:
	if _is_deploying:
		deployment_animation_finished.emit()


## The deployment strategy calls this after the animation-to-world handoff.
## A failed late recheck releases the unit; a successful one consumes it.
func finish_deployment(consumed: bool) -> void:
	if not _is_deploying:
		return
	_is_deploying = false
	_deployment_aligning = false
	_deployment_alignment_direction = Vector3.ZERO
	_deployment_animation_player = null
	_deployment_animation_name = &""
	if _navigation_system != null and _navigation_system.has_method("set_hold_position"):
		_navigation_system.call("set_hold_position", self, false)
	if not consumed:
		_set_movement_animation(false)


func set_selected(value: bool) -> void:
	if is_selected == value:
		return

	is_selected = value
	if _selection_halo != null:
		_selection_halo.set_selected(value)


func navigation_requested_velocity() -> Vector3:
	return _navigation_requested_velocity


func _set_navigation_debug_direction(value: Vector3) -> void:
	_navigation_requested_velocity = Vector3(value.x, 0.0, value.z)
	if _selection_halo != null:
		_selection_halo.set_movement_direction(_navigation_requested_velocity)


func set_navigation_debug_visible(value: bool) -> void:
	_navigation_debug_visible = value
	if _selection_halo != null:
		_selection_halo.set_movement_debug_visible(value)


func set_hovered(value: bool) -> void:
	if is_hovered == value:
		return
	is_hovered = value
	if _selection_halo != null:
		_selection_halo.set_hovered(value)


func set_owner_player_id(player_id: int) -> void:
	owner_player_id = player_id


func owner_player():
	var players = _players()
	if players == null:
		return null
	return players.player(owner_player_id)


func is_neutral_owner() -> bool:
	return owner_player_id == PlayerDataScript.NEUTRAL_PLAYER_ID


func is_owned_by(player_id: int) -> bool:
	return owner_player_id == player_id


func is_allied_with(player_id: int) -> bool:
	var players = _players()
	return players != null and players.are_allied(owner_player_id, player_id)


func is_enemy_of(player_id: int) -> bool:
	var players = _players()
	return players != null and players.are_enemies(owner_player_id, player_id)


func _refresh_shield_visibility() -> void:
	for mesh_instance in _shield_meshes:
		mesh_instance.visible = shields > 0.0


func _apply_rules_config() -> void:
	if String(config_id).is_empty():
		return

	var rules := get_node_or_null("/root/Rules")
	if rules == null:
		push_warning("Rules autoload is not available; using scene defaults for %s" % name)
		return

	unit_config = rules.call("unit", config_id)
	if unit_config == null:
		push_warning("Unit rules config not found: %s" % String(config_id))
		return

	move_speed = float(unit_config.field(&"speed", move_speed))
	mech_speed = maxf(float(unit_config.field(&"mech_speed", move_speed)), 0.0)
	_uses_mech_gait = bool(unit_config.field(&"mech", false)) \
		and mech_speed > 0.0 \
		and not is_equal_approx(mech_speed, move_speed)
	_mech_gait_elapsed = 0.0
	turn_rate = maxf(float(unit_config.field(&"turn_rate", 0.0)), 0.0)
	can_move_any_direction = bool(unit_config.field(&"can_move_any_direction", false))
	max_health = float(unit_config.field(&"health", max_health))
	max_shields = float(unit_config.field(&"shield_health", 0.0))
	armour_type = StringName(String(unit_config.field(&"armour_type", "")))
	_configure_combat_turrets(rules)


func _configure_combat_turrets(rules: Object) -> void:
	combat_turrets.clear()
	var turret_values: Array = unit_config.list(&"turrets")
	for weapon_index in turret_values.size():
		var turret_value: Variant = turret_values[weapon_index]
		var turret_config: Resource = rules.call("turret", StringName(String(turret_value)))
		if turret_config == null:
			continue
		var turret = CombatTurretScript.new()
		if turret.configure_from_rules(turret_config, rules):
			turret.bind_model(visual_root, weapon_index)
			combat_turrets.append(turret)


func _bind_combat_turrets() -> void:
	for turret in combat_turrets:
		turret.bind_model(visual_root, turret.weapon_index())


func _collect_shield_meshes() -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	for mesh_instance in _mesh_instances():
		if String(mesh_instance.get_parent().name).to_lower().contains("shield"):
			result.append(mesh_instance)
	return result


func _collect_scroll_fx_meshes() -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	for mesh_instance in _mesh_instances():
		if mesh_instance.has_meta("scroll_fx"):
			result.append(mesh_instance)
	return result


func _collect_animation_players() -> Array[AnimationPlayer]:
	var result: Array[AnimationPlayer] = []
	if visual_root == null:
		return result
	for node in visual_root.find_children("*", "AnimationPlayer", true, false):
		result.append(node as AnimationPlayer)
	return result


func _prioritize_animations_before_unit_logic() -> void:
	# AnimationPlayer uses internal frame processing. Converted Stationary/Move
	# tracks may key the same authored pivots that combat rotates; if they run
	# after Unit._process(), they erase the turret transform while its logical
	# yaw/pitch continue advancing. Apply authored animation first so combat aim
	# is the final transform for the frame and remains the feedback state used by
	# the next frame's muzzle-to-target servo.
	for player in _animation_players:
		player.process_priority = mini(player.process_priority, process_priority - 1)


func _prepare_idle_animations() -> void:
	_stationary_repeats_remaining.clear()
	for player in _animation_players:
		var idle_animations := _idle_animations(player)
		for animation_name in idle_animations:
			var animation := player.get_animation(animation_name)
			if animation != null:
				animation.loop_mode = Animation.LOOP_NONE
		if not idle_animations.is_empty() and player.has_animation(IDLE_ANIMATION):
			var stationary := player.get_animation(IDLE_ANIMATION)
			if stationary != null:
				stationary.loop_mode = Animation.LOOP_NONE
		if not player.animation_finished.is_connected(_on_animation_finished.bind(player)):
			player.animation_finished.connect(_on_animation_finished.bind(player))


func _set_movement_animation(is_moving: bool, speed_scale := 1.0) -> void:
	if _fire_sequence_active:
		if not is_moving:
			return
		_cancel_fire_sequence(true, false)
	if not is_moving:
		_mech_gait_elapsed = 0.0
	_movement_animation_active = is_moving
	for player in _animation_players:
		if is_moving:
			if player.has_animation(MOVING_ANIMATION):
				if player.current_animation != MOVING_ANIMATION:
					player.play(MOVING_ANIMATION)
				player.speed_scale = speed_scale
				continue
		player.speed_scale = 1.0
		_play_idle_sequence(player)
	_restore_combat_turret_poses()


func _play_idle_sequence(player: AnimationPlayer) -> void:
	var idle_animations := _idle_animations(player)
	if idle_animations.is_empty():
		if player.has_animation(IDLE_ANIMATION) and player.current_animation != IDLE_ANIMATION:
			player.play(IDLE_ANIMATION)
		return

	var player_id := player.get_instance_id()
	var is_sequence_animation := player.current_animation == IDLE_ANIMATION \
		or player.current_animation in idle_animations
	if is_sequence_animation and player.is_playing() and _stationary_repeats_remaining.has(player_id):
		return
	_start_stationary_batch(player, idle_animations)


func _start_stationary_batch(player: AnimationPlayer, idle_animations: Array[StringName]) -> void:
	var player_id := player.get_instance_id()
	if player.has_animation(IDLE_ANIMATION):
		_stationary_repeats_remaining[player_id] = randi_range(5, 15)
		_play_animation_from_start(player, IDLE_ANIMATION)
		return
	_stationary_repeats_remaining[player_id] = 0
	_play_random_idle(player, idle_animations)


func _play_random_idle(player: AnimationPlayer, idle_animations: Array[StringName]) -> void:
	var total_weight := 0.0
	for animation_name in idle_animations:
		total_weight += _idle_animation_weight(animation_name)

	var roll := randf() * total_weight
	for animation_name in idle_animations:
		roll -= _idle_animation_weight(animation_name)
		if roll <= 0.0:
			_play_animation_from_start(player, animation_name)
			return
	_play_animation_from_start(player, idle_animations.back())


func _idle_animation_weight(animation_name: StringName) -> float:
	var suffix := String(animation_name).trim_prefix(IDLE_ANIMATION_PREFIX).trim_prefix("_")
	if not suffix.is_valid_int():
		return 1.0
	return 1.0 / float(maxi(int(suffix), 0) + 1)


func _play_animation_from_start(player: AnimationPlayer, animation_name: StringName) -> void:
	player.stop()
	player.play(animation_name)
	_restore_combat_turret_poses()


func _restore_combat_turret_poses() -> void:
	for turret in combat_turrets:
		if turret != null:
			turret.restore_aim_pose()


func _idle_animations(player: AnimationPlayer) -> Array[StringName]:
	var result: Array[StringName] = []
	for animation_name in player.get_animation_list():
		if String(animation_name).begins_with(IDLE_ANIMATION_PREFIX):
			result.append(animation_name)
	return result


func _on_animation_finished(animation_name: StringName, player: AnimationPlayer) -> void:
	if (
		_fire_sequence_active
		and player == _fire_sequence_player
		and animation_name == _fire_sequence_animation
	):
		# A long render frame may jump directly past the last authored shot.
		# Complete the animation timeline before starting post-animation reload.
		var attack_target: Variant = attack_order_target()
		if attack_target != null:
			_fire_sequence_elapsed = _fire_sequence_duration
			while _fire_sequence_next_shot < _fire_sequence_shot_times.size():
				_fire_sequence_next_shot += 1
				var projectiles: Array = _fire_sequence_turret.try_fire_at(
					attack_target, self, null, Vector3.ZERO, false, false
				)
				if projectiles.is_empty():
					continue
				_fire_sequence_shots_emitted += projectiles.size()
				weapon_fired.emit(
					projectiles, attack_target, _fire_sequence_turret.weapon_index()
				)
		_finish_fire_sequence()
		return
	if (
		_is_deploying
		and player == _deployment_animation_player
		and animation_name == _deployment_animation_name
	):
		deployment_animation_finished.emit()
		return
	if _movement_animation_active:
		return
	var idle_animations := _idle_animations(player)
	if idle_animations.is_empty():
		return
	var player_id := player.get_instance_id()
	if animation_name == IDLE_ANIMATION:
		var repeats_left := int(_stationary_repeats_remaining.get(player_id, 1)) - 1
		_stationary_repeats_remaining[player_id] = repeats_left
		if repeats_left > 0:
			_play_animation_from_start(player, IDLE_ANIMATION)
		else:
			_play_random_idle(player, idle_animations)
	elif animation_name in idle_animations:
		_start_stationary_batch(player, idle_animations)


func _movement_animation_speed_scale() -> float:
	var phase_speed := navigation_move_speed()
	if phase_speed <= 0.0:
		return 1.0
	return velocity.length() / phase_speed


func _refresh_owner_visuals() -> void:
	var color := _owner_team_color()
	for mesh_instance in _mesh_instances():
		mesh_instance.set_instance_shader_parameter("team_color", color)


func _owner_team_color() -> Color:
	var roster_player = owner_player()
	if roster_player == null or roster_player.is_neutral:
		return Color(0.2, 0.85, 1.0)
	return roster_player.team_color


func _players():
	if not is_inside_tree():
		return null
	return get_node_or_null("/root/Players")


func _clear_invulnerability() -> void:
	invulnerable = false


func _add_authored_collision() -> void:
	for source in _collision_sources():
		var shape := _collision_shape(source)
		if shape == null:
			push_warning("Unit: collision mesh %s has no usable convex shape" % source.get_path())
			continue

		var collision := CollisionShape3D.new()
		collision.name = "AuthoredCollision"
		collision.shape = shape
		add_child(collision)
		# The source mesh is nested beneath VisualRoot and model-space nodes;
		# copying its global transform preserves its authored position and scale.
		collision.global_transform = source.global_transform


func _collision_sources() -> Array[Node3D]:
	var result: Array[Node3D] = []
	_collect_collision_sources(visual_root, COLLISION_OBJECT_NAME, result)
	if result.is_empty():
		_collect_collision_sources(visual_root, "slct", result, true)
	return result


func _collect_collision_sources(node: Node, original_name: String, result: Array[Node3D], prefix_match := false) -> void:
	if node is Node3D and _is_collision_source(node, original_name, prefix_match):
		_hide_collision_meshes(node)
		result.append(node)
		return
	for child in node.get_children():
		_collect_collision_sources(child, original_name, result, prefix_match)


func _is_collision_source(node: Node3D, original_name: String, prefix_match: bool) -> bool:
	var source_name := String(node.get_meta("original_name", ""))
	var matches := source_name.to_lower().begins_with(original_name) if prefix_match else source_name == original_name
	var points: PackedVector3Array = node.get_meta("collision_points", PackedVector3Array())
	return matches and points.size() >= 4


func _collision_shape(source: Node3D) -> Shape3D:
	var points: PackedVector3Array = source.get_meta("collision_points", PackedVector3Array())
	if points.size() >= 4:
		var shape := ConvexPolygonShape3D.new()
		shape.points = points
		return shape
	for child in source.get_children():
		if child is MeshInstance3D and child.mesh != null:
			return child.mesh.create_convex_shape(true, false)
	return null


func _hide_collision_meshes(node: Node) -> void:
	for child in node.get_children():
		if child is MeshInstance3D and child.has_meta("collision_mesh"):
			child.visible = false


func _add_selection_halo() -> void:
	_selection_halo = SelectionHaloScript.new()
	_selection_halo.name = "SelectionHalo"
	add_child(_selection_halo)
	_selection_halo.configure(self, _selection_radius(), _selection_position())
	_selection_halo.set_movement_direction(_navigation_requested_velocity)
	_selection_halo.set_movement_debug_visible(_navigation_debug_visible)


func _selection_radius() -> float:
	var anchor_bounds := _halo_anchor_bounds()
	if anchor_bounds.size.x > 0.0 or anchor_bounds.size.z > 0.0:
		return maxf(anchor_bounds.size.x, anchor_bounds.size.z) * 0.5

	var bounds := _selection_bounds()
	# A halo is circular: its diameter follows the authored selection volume's
	# narrow horizontal axis, not its length.  This keeps long vehicles and
	# buildings from receiving an oversized circle.
	return minf(bounds.size.x, bounds.size.z) * 0.5


func _selection_position() -> Vector3:
	var anchor: Node3D = _halo_anchor_node(visual_root)
	if anchor != null:
		return to_local(anchor.to_global(Vector3.ZERO))

	return Vector3(0.0, _selection_bounds().end.y + 0.05, 0.0)


func _halo_anchor_bounds() -> AABB:
	var anchor: Node3D = _halo_anchor_node(visual_root)
	if anchor == null or not anchor.has_meta("halo_anchor_bounds"):
		return AABB()
	var source_bounds: AABB = anchor.get_meta("halo_anchor_bounds")
	var bounds := AABB()
	var has_bounds := false
	for corner in _aabb_corners(source_bounds):
		var point := to_local(anchor.to_global(corner))
		if has_bounds:
			bounds = bounds.expand(point)
		else:
			bounds = AABB(point, Vector3.ZERO)
			has_bounds = true
	return bounds


func _selection_bounds() -> AABB:
	var highest := 0.0
	var bounds := AABB()
	var has_bounds := false
	for marker in _selection_marker_nodes(visual_root):
		var marker_bounds: AABB = marker.get_meta("selection_bounds")
		for corner in _aabb_corners(marker_bounds):
			var point := to_local(marker.to_global(corner))
			if has_bounds:
				bounds = bounds.expand(point)
			else:
				bounds = AABB(point, Vector3.ZERO)
				has_bounds = true
	if has_bounds:
		return bounds
	return AABB(Vector3.ZERO, Vector3(1.0, 1.0, 1.0))


func _selection_marker_nodes(node: Node) -> Array[Node3D]:
	var result: Array[Node3D] = []
	_collect_selection_marker_nodes(node, result)
	return result


func _collect_selection_marker_nodes(node: Node, result: Array[Node3D]) -> void:
	if node is Node3D and node.has_meta("selection_bounds"):
		result.append(node)
	for child in node.get_children():
		_collect_selection_marker_nodes(child, result)


func _halo_anchor_node(node: Node) -> Node3D:
	if node is Node3D and node.has_meta("halo_anchor"):
		return node
	for child in node.get_children():
		var anchor: Node3D = _halo_anchor_node(child)
		if anchor != null:
			return anchor
	return null


func _aabb_corners(bounds: AABB) -> Array[Vector3]:
	var corners: Array[Vector3] = []
	for x in [bounds.position.x, bounds.end.x]:
		for y in [bounds.position.y, bounds.end.y]:
			for z in [bounds.position.z, bounds.end.z]:
				corners.append(Vector3(x, y, z))
	return corners


func _mesh_instances() -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	if visual_root == null:
		return result
	_collect_mesh_instances(visual_root, result)
	return result


func _collect_mesh_instances(node: Node, result: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		result.append(node)
	for child in node.get_children():
		_collect_mesh_instances(child, result)
