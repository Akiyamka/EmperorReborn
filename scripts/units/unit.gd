extends CharacterBody3D
class_name Unit

const SpatialOrientationScript := preload("res://scripts/world/spatial_orientation.gd")
const CombatTurretScript := preload("res://scripts/combat/combat_turret.gd")
const UnitSceneCatalogScript := preload("res://scripts/units/unit_scene_catalog.gd")
const UnitFlightControllerScript := preload("res://scripts/units/navigation/unit_flight_controller.gd")
const UnitNavigationSystemScript := preload("res://scripts/units/navigation/unit_navigation_system.gd")
static var _definition_catalog := UnitSceneCatalogScript.new()

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
## Converted XBF tracks use a 20 Hz timeline, while the original firing
## cadence measured from ReloadCount and Fire clip frame counts is 25 Hz.
## Fire clips therefore traverse the baked timeline at 25/20 speed.
const BAKED_MODEL_FRAMES_PER_SECOND := 20.0
const RULE_COMBAT_TICKS_PER_SECOND := 25.0
const FIRE_ANIMATION_SPEED_SCALE := (
	RULE_COMBAT_TICKS_PER_SECOND / BAKED_MODEL_FRAMES_PER_SECOND
)
const FIRE_ANIMATION_PREFIX := "Fire_"
const FIRE_EVENT_EPSILON := 0.0001
const MOVING_ANIMATION := &"Move"
const MOVE_START_ANIMATION := &"Move_Start"
const MOVE_STOP_ANIMATION := &"Move_Stop"
const TURN_LEFT_ANIMATION := &"Turn_Left"
const TURN_RIGHT_ANIMATION := &"Turn_Right"
const IDLE_ANIMATION := &"Stationary"
const IDLE_ANIMATION_PREFIX := "Idle"
## The original MCV model has no clip literally named Deploy. Move_Stop is its
## authored transition from driving to a braced stationary pose and is the
## source-backed fallback for the first phase of deployment. Deploy_Gun is the
## authored clip for the combat-deploy strategy (Kindjal/Mortar/Kobra); it is
## first so those units resolve it before ever reaching the MCV fallback.
const DEPLOYMENT_ANIMATION_CANDIDATES: Array[StringName] = [
	&"Deploy_Gun", &"Deploy", &"Deploying", &"Unpack", &"Move_Stop"
]
## Undeploy has no MCV-side authored clip at all (the Construction Yard's own
## Deconstruct animation handles that transformation instead), so this list
## only ever resolves for the combat-deploy strategy.
const UNDEPLOYMENT_ANIMATION_CANDIDATES: Array[StringName] = [
	&"Undeploy_Gun", &"Undeploy", &"Undeploying"
]
## Deployed-mode idle clips (Kindjal only) mirror the travel-mode Idle_*
## naming so the same random-variant machinery in _idle_animations applies.
const DEPLOYED_IDLE_ANIMATION_PREFIX := "Deployed_Idle"
## The single canonical deployed-mode fire clip after the converter-stage
## rename (see converters/model_bake_builder.gd CLIP_NAME_OVERRIDES).
const DEPLOYED_FIRE_ANIMATION := &"Deployed_Fire"
## Deploy_Gun_Hold is the authored held pose at the end of the deploy clip.
## Mortar/Kobra have no Deployed_Idle_* clips, so this is played once and
## held rather than falling back to Stationary/Idle_* (the travel-mode pose).
const DEPLOYED_HOLD_ANIMATION := &"Deploy_Gun_Hold"
const DEFAULT_MECH_MOVE_CYCLE_SECONDS := 1.0
const ATTACK_REPATH_INTERVAL_SECONDS := 0.25
const ATTACK_REPATH_DISTANCE := 0.5
const AUTO_TARGET_REFRESH_SECONDS := 0.25

enum SlopeAlignmentMode {
	AUTO,
	ENABLED,
	DISABLED,
}

enum MechLocomotionState {
	IDLE,
	STARTING,
	MOVING,
	TURNING_LEFT,
	TURNING_RIGHT,
	STOPPING,
}

## MCV deploy (TRAVEL -> DEPLOYING -> [consumed: unit freed]) uses only the
## first half of this machine. Combat deploy (Kindjal/Mortar/Kobra) uses all
## four states, toggling DEPLOYED <-> TRAVEL through DEPLOYING/UNDEPLOYING.
enum DeployState {
	TRAVEL,
	DEPLOYING,
	DEPLOYED,
	UNDEPLOYING,
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

var unit_definition: Resource
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
var _mech_motion_profile: Array[Dictionary] = []
var _mech_authored_average_speed := 0.0
var _mech_motion_cycle_seconds := DEFAULT_MECH_MOVE_CYCLE_SECONDS
var _mech_locomotion_state := MechLocomotionState.IDLE
var _mech_start_remaining := 0.0
var _flight_controller: UnitFlightController = null
var _deploy_state := DeployState.TRAVEL
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
var _attack_pursuit_destination := Vector3.INF
var _attack_pursuit_rejected := false
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
## Weapon-indexed state keeps multi-turret vehicles independent. The legacy
## scalar fields above mirror whether any sequence exists for tests and older
## callers; sequence timing and targets live here.
var _weapon_fire_sequences: Dictionary = {}
var _weapon_targets: Dictionary = {}
var _weapon_auto_targets: Dictionary = {}
var _weapon_auto_target_cooldowns: Dictionary = {}
var _moving_fire_weapons: Dictionary = {}
var _weapon_can_fire_while_moving: Dictionary = {}
var _weapon_fire_overlays: Dictionary = {}


func _ready() -> void:
	if visual_root != null:
		_visual_root_rest_basis = visual_root.transform.basis.orthonormalized()
		_visual_slope_target_basis = _visual_root_rest_basis
	_apply_unit_definition()
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
	_refresh_weapon_runtime()
	_refresh_mech_motion_profile()
	_prioritize_animations_before_unit_logic()
	_prepare_idle_animations()
	_set_movement_animation(false)
	health = max_health
	shields = max_shields
	_add_selection_halo()
	_refresh_owner_visuals()


func _exit_tree() -> void:
	_cancel_all_fire_sequences(false)
	for turret in combat_turrets:
		turret.cancel_authored_fire_fx()


func _process(delta: float) -> void:
	_advance_auto_target_cooldowns(delta)
	for turret in combat_turrets:
		turret.advance_ticks(delta * RULE_COMBAT_TICKS_PER_SECOND)
	# Authored locomotion/fire overlays run before Unit. Restore and advance the
	# combat-owned servo first, then sample the muzzle for this frame's shots;
	# otherwise a moving turret launches along the clip's forward rest pose.
	_advance_attack_order(delta)
	_advance_fire_sequences(delta)
	if (
		not _has_attack_order
		and _weapon_targets.is_empty()
		and _moving_fire_weapons.is_empty()
	):
		# Movement/idle animations key some of the same model pivots as combat.
		# Keep the combat angle authoritative after an order ends and return it
		# to the authored forward pose through the normal turret servo. Without
		# this, the animation snaps the visible pivot to rest while current_yaw
		# stays cached, and the stale angle reappears on the next attack order.
		# Only turrets live in the current deploy state: an inactive turret's
		# pivot is owned by its own deploy/undeploy/idle animation, not combat.
		for turret in _active_turrets():
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
	if _flight_controller != null and _flight_controller.flight_controls_transition():
		_flight_controller.advance(delta)
		return
	if is_deploying():
		velocity = Vector3.ZERO
		if _deployment_aligning:
			if _turn_toward(_deployment_alignment_direction, delta):
				_deployment_aligning = false
				_set_visual_slope_target(_last_terrain_normal)
				_start_deployment_animation()
		return
	if is_deployed():
		velocity = Vector3.ZERO
		return
	if _navigation_managed:
		return
	_advance_mech_start_transition(delta)
	var offset := target_position - global_position
	offset.y = 0.0
	var requested_velocity := Vector3.ZERO
	var movement_speed := navigation_move_speed()
	var turn_animation := &""

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
		if not heading_reached:
			turn_animation = _mech_turn_animation_for_direction(direction)

	_set_navigation_debug_direction(requested_velocity)
	var animation_speed_scale := _movement_animation_speed_scale()
	_set_movement_animation(
		not velocity.is_zero_approx()
			or not turn_animation.is_empty()
			or _mech_transition_or_pause_has_move_order(),
		animation_speed_scale,
		turn_animation
	)
	if _mech_locomotion_state == MechLocomotionState.STARTING:
		velocity = Vector3.ZERO
	_advance_mech_gait(delta, animation_speed_scale)
	move_and_slide()
	_snap_to_terrain(delta)


## `exit_point` is a mandatory first waypoint (a production building's front
## exit): the unit walks straight to it before regular routing takes over.
func move_to(world_position: Vector3, exit_point := Vector3.INF) -> void:
	if _flight_controller != null and _flight_controller.flight_is_landed():
		_flight_controller.begin_takeoff_toward(world_position, exit_point)
		return
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


## Called only by UnitRosterController right after producing a flying unit:
## the unit first moves along the apron to `exit_point`, then takes off clear of
## the producer and moves toward `rally_point`.
## Non-flying units fall back to an ordinary move order.
func begin_hangar_takeoff(rally_point: Vector3, exit_point: Vector3) -> bool:
	if _flight_controller == null:
		move_to(rally_point, exit_point)
		return true
	_flight_controller.begin_hangar_takeoff(rally_point, exit_point)
	return true


## True for every flight phase except grounded/landed. Used by the nav system
## (duck-typed, see UnitLocalAvoidance/UnitNavigationPlanner) to ignore
## buildings, and internally to route movement/animation through the
## flight controller. Always false for non-flying units.
func flight_is_airborne_phase() -> bool:
	return _flight_controller != null and _flight_controller.flight_is_airborne_phase()


## True while grounded/landed (including a flying unit that has not yet taken
## off). This is the seam a later combat pass wires into combat_is_airborne()
## so a landed plane counts as a ground unit for targeting — not done here.
func flight_is_landed() -> bool:
	return _flight_controller == null or _flight_controller.flight_is_landed()


## Only Ornithopters (ammo-replenish docking) or carriers (pickup sequence) may
## ever leave cruise/hover to land; every other CanFly unit rejects this and
## only ever takes off once, at spawn. No AI calls this yet in this pass —
## `allowed_cells` mirrors the command_dock exception shape for the follow-up
## pass that issues real land orders.
func flight_request_land(target_position: Vector3, allowed_cells: Dictionary = {}) -> bool:
	return _flight_controller != null and _flight_controller.flight_request_land(target_position, allowed_cells)


## Called by UnitLocalAvoidance when two air agents' lateral paths converge —
## blends this unit's altitude toward cruise_altitude + value.
func flight_set_vertical_offset(value: float) -> void:
	if _flight_controller != null:
		_flight_controller.flight_set_vertical_offset(value)


## Pickup sequence stubs — phases/clips exist and are individually triggerable;
## nothing drives them automatically yet (follow-up carryall-AI pass).
func flight_begin_pickup_sequence() -> void:
	if _flight_controller != null:
		_flight_controller.flight_begin_pickup_sequence()


func flight_advance_pickup(next_sub_phase: int) -> void:
	if _flight_controller != null:
		_flight_controller.flight_advance_pickup(next_sub_phase)


func flight_complete_pickup_sequence() -> void:
	if _flight_controller != null:
		_flight_controller.flight_complete_pickup_sequence()


## Ensures `name` is the active animation on the first player that has it,
## restarting playback only if it isn't already current (mirrors
## _set_movement_animation's MOVING_ANIMATION idiom, unlike
## _start_deployment_animation which always restarts) — safe to call every
## tick. Returns the player it played on, or null if no player has the clip.
func flight_play_clip(clip_name: StringName, loop: bool, speed_scale: float = 1.0) -> AnimationPlayer:
	for player in _animation_players:
		if not player.has_animation(clip_name):
			continue
		var animation := player.get_animation(clip_name)
		if animation != null:
			animation.loop_mode = Animation.LOOP_LINEAR if loop else Animation.LOOP_NONE
		if player.current_animation != clip_name:
			player.stop()
			player.play(clip_name)
		player.speed_scale = speed_scale
		return player
	return null


## Same lookup idiom as _mech_move_cycle_duration(): the authored clip length
## if any player has it, else `fallback`.
func flight_clip_length(clip_name: StringName, fallback: float) -> float:
	for player in _animation_players:
		if not player.has_animation(clip_name):
			continue
		var animation := player.get_animation(clip_name)
		if animation != null and animation.length > 0.0:
			return animation.length
	return fallback


## Called by UnitNavigationSystem before it mutates an agent's route. Units may
## perform order-specific cleanup or return false to defer/reject the route.
## Unmanaged fallback movement uses the same API, keeping order preparation in
## the unit instead of teaching command controllers about unit state machines.
func prepare_navigation_order(
	_world_position: Vector3, _exit_point := Vector3.INF, _move_mode := 0
	) -> bool:
	if not _issuing_attack_move:
		_replace_attack_with_move()
	return not (is_deploying() or is_deployed())


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
	if _flight_controller != null and _flight_controller.flight_controls_transition():
		_flight_controller.advance(delta)
		return
	if is_deploying() or is_deployed():
		velocity = Vector3.ZERO
		_set_navigation_debug_direction(Vector3.ZERO)
		return
	_advance_mech_start_transition(delta)
	# Preserve the requested course before a tracked unit possibly converts its
	# translational velocity to zero while turning in place. This is the value
	# shown by the selected-unit navigation debug arrow.
	_set_navigation_debug_direction(horizontal_velocity)
	velocity = Vector3(horizontal_velocity.x, 0.0, horizontal_velocity.z)
	var turn_animation := &""
	var steering_direction := velocity.normalized() \
		if velocity.length_squared() > 0.000001 else Vector3.ZERO
	if (
		steering_direction.is_zero_approx()
		and _uses_mech_gait
		and _mech_locomotion_state != MechLocomotionState.STARTING
		and _mech_has_active_move_order()
	):
		var destination_offset := target_position - global_position
		destination_offset.y = 0.0
		steering_direction = destination_offset.normalized()
	# Crowded units receive tiny non-zero velocities from collision resolution;
	# skip negligible motion so it cannot jitter the unit's heading.
	if not steering_direction.is_zero_approx():
		var heading_reached := _turn_toward(steering_direction, delta)
		if not can_move_any_direction and not heading_reached:
			velocity = Vector3.ZERO
		if not heading_reached:
			turn_animation = _mech_turn_animation_for_direction(steering_direction)
	var animation_speed_scale := _movement_animation_speed_scale()
	_set_movement_animation(
		not velocity.is_zero_approx()
			or not turn_animation.is_empty()
			or _mech_transition_or_pause_has_move_order(),
		animation_speed_scale,
		turn_animation
	)
	if _mech_locomotion_state == MechLocomotionState.STARTING:
		velocity = Vector3.ZERO
	_advance_mech_gait(delta, animation_speed_scale)
	# Unit/unit collision has already been resolved centrally as swept discs.
	# Applying the exact fixed navigation delta avoids depending on physics-frame
	# frequency and keeps command replays stable.
	global_position += velocity * delta
	_snap_to_terrain(delta)


## The navigation solver must see the phase speed before avoidance is resolved;
## applying it afterwards would let following units plan through a mech that is
## currently in its slower between-step phase.
func navigation_move_speed() -> float:
	if not _uses_mech_gait:
		return move_speed
	if _mech_motion_profile.is_empty():
		return mech_speed
	return _mech_authored_phase_speed() * _mech_gait_cadence()


func _advance_mech_gait(delta: float, animation_speed_scale: float) -> void:
	if (
		not _uses_mech_gait
		or _mech_locomotion_state != MechLocomotionState.MOVING
		or delta <= 0.0
	):
		return
	var cycle_duration := _mech_move_cycle_duration()
	_mech_gait_elapsed = fposmod(
		_mech_gait_elapsed + delta * maxf(animation_speed_scale, 0.0),
		cycle_duration
	)


func _advance_mech_start_transition(delta: float) -> void:
	if _mech_locomotion_state != MechLocomotionState.STARTING or delta <= 0.0:
		return
	# Physics owns the transition deadline as well as AnimationPlayer. This
	# keeps deterministic/manual simulations moving even when no render frame
	# advances the player, while the normal animation_finished path can still
	# switch to Move first during ordinary scene playback.
	_mech_start_remaining = maxf(_mech_start_remaining - delta, 0.0)
	if _mech_start_remaining <= 0.0:
		_begin_mech_move(_mech_gait_cadence())


func _mech_move_cycle_duration() -> float:
	if not _mech_motion_profile.is_empty():
		return _mech_motion_cycle_seconds
	for player in _animation_players:
		if not player.has_animation(MOVING_ANIMATION):
			continue
		var animation := player.get_animation(MOVING_ANIMATION)
		if animation != null and animation.length > 0.0:
			return animation.length
	return DEFAULT_MECH_MOVE_CYCLE_SECONDS


func _mech_authored_phase_speed() -> float:
	if _mech_motion_profile.is_empty():
		return mech_speed
	var phase := fposmod(_mech_gait_elapsed, _mech_motion_cycle_seconds)
	var result := float(_mech_motion_profile[0]["speed"])
	for key in _mech_motion_profile:
		if float(key["time"]) > phase + 0.000001:
			break
		result = float(key["speed"])
	return maxf(result, 0.0)


func _mech_gait_cadence() -> float:
	if _mech_motion_profile.is_empty() or _mech_authored_average_speed <= 0.0:
		return 1.0
	return mech_speed / _mech_authored_average_speed


func _mech_transition_or_pause_has_move_order() -> bool:
	if not _uses_mech_gait or not _mech_has_active_move_order():
		return false
	if _mech_locomotion_state in [
		MechLocomotionState.STARTING,
		MechLocomotionState.TURNING_LEFT,
		MechLocomotionState.TURNING_RIGHT,
		MechLocomotionState.STOPPING,
	]:
		return true
	return not _mech_motion_profile.is_empty() and _mech_authored_phase_speed() <= 0.0


func _mech_has_active_move_order() -> bool:
	var tolerance := arrival_radius
	if (
		_navigation_managed
		and _navigation_system != null
		and _navigation_system.has_method("arrival_tolerance")
	):
		tolerance = maxf(
			tolerance,
			float(_navigation_system.call("arrival_tolerance", self))
		)
	var offset := target_position - global_position
	offset.y = 0.0
	return offset.length() > tolerance


func _mech_turn_animation_for_direction(direction: Vector3) -> StringName:
	if not _uses_mech_gait or direction.length_squared() <= 0.000001:
		return &""
	var target_yaw := SpatialOrientationScript.yaw_facing(direction, global_rotation.y)
	var signed_angle := angle_difference(global_rotation.y, target_yaw)
	if is_zero_approx(signed_angle):
		return &""
	return TURN_LEFT_ANIMATION if signed_angle > 0.0 else TURN_RIGHT_ANIMATION


func _refresh_mech_motion_profile() -> void:
	_mech_motion_profile.clear()
	_mech_authored_average_speed = 0.0
	_mech_motion_cycle_seconds = DEFAULT_MECH_MOVE_CYCLE_SECONDS
	if not _uses_mech_gait or visual_root == null:
		return
	var model_root := _find_xbf_motion_root(visual_root)
	if model_root == null:
		return
	var move_entry := {}
	for entry_value: Variant in model_root.get_meta("xbf_animation_entries", []):
		var entry := entry_value as Dictionary
		if String(entry.get("name", "")).strip_edges() == String(MOVING_ANIMATION):
			move_entry = entry
			break
	if move_entry.is_empty():
		return
	var start_frame := int(move_entry.get("start_frame", -1))
	var end_frame := int(move_entry.get("end_frame", -1))
	if start_frame < 0 or end_frame < start_frame:
		return
	_mech_motion_cycle_seconds = (
		float(end_frame - start_frame + 1) / BAKED_MODEL_FRAMES_PER_SECOND
	)
	for event_value: Variant in model_root.get_meta("xbf_fx_events", []):
		var event := event_value as Dictionary
		var frame := int(event.get("frame", -1))
		if int(event.get("type", -1)) != 11 \
		or frame < start_frame or frame > end_frame:
			continue
		var speed := _xbf_scalar_event_value(event)
		if speed < 0.0:
			continue
		_mech_motion_profile.append({
			"time": float(frame - start_frame) / BAKED_MODEL_FRAMES_PER_SECOND,
			"speed": speed,
		})
	_mech_motion_profile.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["time"]) < float(b["time"])
	)
	if _mech_motion_profile.is_empty() \
	or not is_zero_approx(float(_mech_motion_profile[0]["time"])):
		_mech_motion_profile.clear()
		return
	var distance_per_cycle := 0.0
	for index in _mech_motion_profile.size():
		var segment_start := float(_mech_motion_profile[index]["time"])
		var segment_end := _mech_motion_cycle_seconds
		if index + 1 < _mech_motion_profile.size():
			segment_end = float(_mech_motion_profile[index + 1]["time"])
		distance_per_cycle += float(_mech_motion_profile[index]["speed"]) \
			* maxf(segment_end - segment_start, 0.0)
	_mech_authored_average_speed = distance_per_cycle / _mech_motion_cycle_seconds
	if _mech_authored_average_speed <= 0.0:
		_mech_motion_profile.clear()


func _find_xbf_motion_root(node: Node) -> Node:
	if node.has_meta("xbf_animation_entries") and node.has_meta("xbf_fx_events"):
		return node
	for child in node.get_children():
		var found := _find_xbf_motion_root(child)
		if found != null:
			return found
	return null


static func _xbf_scalar_event_value(event: Dictionary) -> float:
	if event.has("value"):
		return float(event["value"])
	var payload: Variant = event.get("raw_payload")
	if not payload is PackedByteArray or (payload as PackedByteArray).size() != 8:
		return -1.0
	var buffer := StreamPeerBuffer.new()
	buffer.data_array = payload as PackedByteArray
	return buffer.get_double()


func navigation_blocked_by_enemy(enemies: Array[Node3D]) -> void:
	if enemies.is_empty():
		return
	if has_method("attack_target"):
		call("attack_target", enemies[0])
	else:
		navigation_enemy_encountered.emit(enemies)


func _snap_to_terrain(delta: float = 0.0) -> void:
	if _flight_controller != null:
		_flight_controller.advance(delta)
		return
	_terrain_snap_body()


## Extracted so a landed/grounded flying unit (UnitFlightController.advance)
## sits on real terrain/apron height exactly like a ground unit; airborne
## flight phases bypass this entirely (fixed cruise altitude, no terrain-follow).
func _terrain_snap_body() -> void:
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
	if unit_definition == null:
		return false
	return (
		float(unit_definition.size) > 1.0
		and not unit_definition.infantry
		and not unit_definition.can_fly
		and not unit_definition.mech
		and config_id not in LEGACY_WALKER_UNIT_IDS
	)


func _slope_speed_multiplier(direction: Vector3, delta: float) -> float:
	if _flight_controller != null and _flight_controller.flight_is_airborne_phase():
		return 1.0
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
	_cancel_all_fire_sequences(false)
	config_id = unit_id
	if not is_inside_tree():
		return

	_apply_unit_definition()
	_refresh_weapon_runtime()
	_refresh_mech_motion_profile()
	health = max_health
	shields = max_shields
	_set_visual_slope_target(_last_terrain_normal)


## Used by runtime unit production and startup snapshots when a generic Unit
## scene must display a different converted model.
func replace_visual_scene(model_scene: PackedScene) -> void:
	if model_scene == null or visual_root == null:
		return
	_cancel_all_fire_sequences(false)
	for child in visual_root.get_children():
		visual_root.remove_child(child)
		child.free()
	visual_root.add_child(model_scene.instantiate())
	_bind_combat_turrets()
	_shield_meshes = _collect_shield_meshes()
	_scroll_fx_meshes = _collect_scroll_fx_meshes()
	_animation_players = _collect_animation_players()
	_refresh_weapon_runtime()
	_refresh_mech_motion_profile()
	_prioritize_animations_before_unit_logic()
	_prepare_idle_animations()
	_set_movement_animation(false)
	# Packed model scenes keep gameplay-controlled effect meshes hidden and
	# carry no per-instance owner color. Reapply the unit's current runtime
	# state after swapping the visual (for example during F7 snapshot restore).
	_refresh_shield_visibility()
	_refresh_owner_visuals()
	_rebuild_selection_halo()


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
	return unit_definition != null and unit_definition.can_fly


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


## Turrets whose TurretDefinition.disabled_when_deployed/disabled_when_undeployed
## keep them live in the unit's current deploy state. Both transition states
## (DEPLOYING/UNDEPLOYING) intentionally expose no active turret, preserving
## "cannot attack while deploying" for every unit, deployable or not.
func _active_turrets() -> Array:
	if is_deploying():
		return []
	var deployed := is_deployed()
	var active: Array = []
	for turret in combat_turrets:
		if turret.is_active_while_deployed(deployed):
			active.append(turret)
	return active


func can_attack(target_or_position: Variant) -> bool:
	for turret in _active_turrets():
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
	_cancel_all_fire_sequences()
	stop_at_current_position()
	_has_attack_order = true
	_attack_is_ground = target_or_position is Vector3
	_attack_ground_position = target_or_position if _attack_is_ground else Vector3.INF
	_attack_target_ref = null if _attack_is_ground else weakref(target_or_position as Object)
	_attack_is_pursuing = false
	_attack_repath_remaining = 0.0
	_attack_last_path_position = Vector3.INF
	_attack_pursuit_destination = Vector3.INF
	_attack_pursuit_rejected = false
	_weapon_targets.clear()
	_weapon_auto_targets.clear()
	_weapon_auto_target_cooldowns.clear()
	_moving_fire_weapons.clear()
	for turret in _active_turrets():
		if turret.can_target(target_or_position):
			_set_weapon_target(turret.weapon_index(), target_or_position)
	attack_order_changed.emit(true, target_or_position)
	return true


func cancel_attack_order() -> void:
	_cancel_all_fire_sequences()
	_weapon_targets.clear()
	_weapon_auto_targets.clear()
	_weapon_auto_target_cooldowns.clear()
	_moving_fire_weapons.clear()
	if not _has_attack_order:
		return
	_has_attack_order = false
	_attack_is_ground = false
	_attack_ground_position = Vector3.INF
	_attack_target_ref = null
	_attack_is_pursuing = false
	_attack_repath_remaining = 0.0
	_attack_last_path_position = Vector3.INF
	_attack_pursuit_destination = Vector3.INF
	_attack_pursuit_rejected = false
	attack_order_changed.emit(false, null)


func _replace_attack_with_move() -> void:
	var retained_targets: Dictionary = {}
	_moving_fire_weapons.clear()
	for turret in combat_turrets:
		var weapon_index: int = turret.weapon_index()
		if not weapon_can_fire_while_moving(weapon_index):
			continue
		_moving_fire_weapons[weapon_index] = true
		if _weapon_targets.has(weapon_index):
			retained_targets[weapon_index] = (
				_weapon_targets[weapon_index] as Dictionary
			).duplicate()
	_cancel_blocking_fire_sequences()
	var had_attack_order := _has_attack_order
	_has_attack_order = false
	_attack_is_ground = false
	_attack_ground_position = Vector3.INF
	_attack_target_ref = null
	_attack_is_pursuing = false
	_attack_repath_remaining = 0.0
	_attack_last_path_position = Vector3.INF
	_attack_pursuit_destination = Vector3.INF
	_attack_pursuit_rejected = false
	_weapon_targets = retained_targets
	_weapon_auto_targets.clear()
	_weapon_auto_target_cooldowns.clear()
	if had_attack_order:
		attack_order_changed.emit(false, null)


func has_attack_order() -> bool:
	return _has_attack_order


func has_active_order() -> bool:
	return _has_attack_order or is_deploying() or _mech_has_active_move_order()


func attack_order_target() -> Variant:
	if not _has_attack_order:
		return null
	if _attack_is_ground:
		return _attack_ground_position
	return _attack_target_ref.get_ref() if _attack_target_ref != null else null


func _advance_attack_order(delta: float) -> void:
	if _active_turrets().is_empty():
		return
	if not _has_attack_order:
		_advance_retained_weapon_targets(delta)
		return
	var attack_target: Variant = attack_order_target()
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
	for turret in _active_turrets():
		if turret.target_range(attack_target) == CombatTurretScript.TargetRange.IN_RANGE:
			in_range_turrets.append(turret)
	if in_range_turrets.is_empty():
		_recenter_unengaged_turrets([], delta)
		if primary_turret.target_range(attack_target) == CombatTurretScript.TargetRange.TOO_FAR:
			_advance_attack_pursuit(target_world_position, primary_turret, delta)
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

	var direct_turrets: Array = []
	for turret in in_range_turrets:
		if not turret.requires_hull_turn_for(target_world_position):
			direct_turrets.append(turret)

	# A limited side turret must not drag the hull away from a target already
	# covered by another weapon. Only a real all-weapon blind zone requests a
	# hull correction, and the smallest correction brings the nearest sector
	# boundary onto the commanded target.
	var hull_turret = null
	var fixed_hull_aimed := false
	if direct_turrets.is_empty():
		var smallest_adjustment := INF
		for turret in in_range_turrets:
			var adjustment: float = turret.hull_yaw_adjustment_for(
				target_world_position
			)
			if absf(adjustment) < smallest_adjustment:
				smallest_adjustment = absf(adjustment)
				hull_turret = turret
		if hull_turret != null:
			if hull_turret.requires_hull_turn():
				fixed_hull_aimed = _turn_toward(
					target_world_position - global_position, delta
				)
			else:
				_turn_hull_by_adjustment(
					hull_turret.hull_yaw_adjustment_for(target_world_position),
					delta
				)

	var engaged_turrets: Array = []
	for turret in in_range_turrets:
		var turret_target: Variant = attack_target \
			if turret in direct_turrets or turret == hull_turret \
			else _automatic_target_for(turret)
		if _advance_turret_engagement(
			turret, turret_target, delta,
			fixed_hull_aimed if turret == hull_turret \
				and turret.requires_hull_turn() else null
			):
			engaged_turrets.append(turret)
	_recenter_unengaged_turrets(engaged_turrets, delta)


func _advance_retained_weapon_targets(delta: float) -> void:
	if _weapon_targets.is_empty() and _moving_fire_weapons.is_empty():
		return
	for turret in _active_turrets():
		var weapon_index: int = turret.weapon_index()
		var autonomous := _moving_fire_weapons.has(weapon_index)
		if not autonomous and not _weapon_targets.has(weapon_index):
			continue
		var retained_target: Variant = _weapon_target(weapon_index)
		if retained_target != null and not _combat_target_is_alive(retained_target):
			_weapon_targets.erase(weapon_index)
			_weapon_auto_targets.erase(weapon_index)
			_weapon_auto_target_cooldowns.erase(weapon_index)
			retained_target = null
		var turret_target: Variant = null
		if retained_target != null:
			var target_position := _combat_target_position(retained_target)
			if (
				turret.target_range(retained_target)
					== CombatTurretScript.TargetRange.IN_RANGE
				and not turret.requires_hull_turn_for(target_position)
			):
				turret_target = retained_target
		if turret_target == null and autonomous:
			turret_target = _automatic_target_for(turret)
		if not _advance_turret_engagement(turret, turret_target, delta):
			_recenter_turret_if_idle(turret, delta)


func _advance_turret_engagement(
	turret, target: Variant, delta: float, aimed_override: Variant = null
	) -> bool:
	if turret == null or target == null:
		return false
	var target_position := _combat_target_position(target)
	if not target_position.is_finite() \
	or turret.target_range(target) != CombatTurretScript.TargetRange.IN_RANGE:
		return false
	var aimed := bool(aimed_override) if aimed_override is bool \
		else bool(turret.aim_at(target_position, delta))
	if not aimed or _weapon_fire_sequences.has(turret.weapon_index()):
		return true
	# A stream weapon's authored Fire clip is one short burst meant to replay
	# back-to-back for the duration of a burst window (sized to ReloadCount,
	# matching the original engine's roughly symmetric on/off cadence, e.g.
	# the Flame Tank's ~2.4s burst followed by a ~2.4s reload) rather than
	# waiting out the full ReloadCount between each short clip, which would
	# otherwise turn a sustained flame into one brief puff per cooldown.
	var is_continuous: bool = bool(turret.is_continuous_bullet())
	var starting_new_burst := false
	var ready_to_restart: bool
	if is_continuous and bool(turret.continuous_burst_active()):
		ready_to_restart = true
	else:
		ready_to_restart = bool(turret.is_ready())
		starting_new_burst = is_continuous and ready_to_restart
	if ready_to_restart and _start_authored_fire_sequence(turret, target):
		if starting_new_burst:
			turret.begin_continuous_burst()
		return true
	var projectiles: Array = turret.try_fire_at(target, self)
	if not projectiles.is_empty():
		weapon_fired.emit(projectiles, target, turret.weapon_index())
	return true


func _recenter_unengaged_turrets(engaged_turrets: Array, delta: float) -> void:
	# Inactive turrets are excluded: their pivot belongs to the model's own
	# deploy/undeploy/idle animation while disabled for the current deploy
	# state, not to the combat servo.
	for turret in _active_turrets():
		if turret not in engaged_turrets:
			_recenter_turret_if_idle(turret, delta)


func _recenter_turret_if_idle(turret, delta: float) -> void:
	if turret == null or _weapon_fire_sequences.has(turret.weapon_index()):
		return
	turret.recenter(delta)


func _automatic_target_for(turret) -> Variant:
	if turret == null:
		return null
	var weapon_index: int = turret.weapon_index()
	var cached: Variant = _weak_target(_weapon_auto_targets.get(weapon_index, {}))
	if _automatic_target_is_usable(turret, cached):
		return cached
	if float(_weapon_auto_target_cooldowns.get(weapon_index, 0.0)) > 0.0:
		return null
	_weapon_auto_target_cooldowns[weapon_index] = AUTO_TARGET_REFRESH_SECONDS
	var best_target: Node3D = null
	var best_distance := INF
	var tree := get_tree()
	if tree == null:
		return null
	var candidates: Array[Node] = []
	candidates.append_array(tree.get_nodes_in_group(&"units"))
	candidates.append_array(tree.get_nodes_in_group(&"buildings"))
	for candidate_node in candidates:
		if not candidate_node is Node3D or candidate_node == self:
			continue
		var candidate := candidate_node as Node3D
		if not _automatic_target_is_usable(turret, candidate):
			continue
		var distance := global_position.distance_squared_to(candidate.global_position)
		if distance < best_distance \
		or (
			is_equal_approx(distance, best_distance)
			and best_target != null
			and candidate.get_instance_id() < best_target.get_instance_id()
		):
			best_distance = distance
			best_target = candidate
	if best_target == null:
		_weapon_auto_targets.erase(weapon_index)
		return null
	_weapon_auto_targets[weapon_index] = {"ref": weakref(best_target)}
	return best_target


func _advance_auto_target_cooldowns(delta: float) -> void:
	for weapon_index: Variant in _weapon_auto_target_cooldowns.keys():
		var remaining := maxf(
			float(_weapon_auto_target_cooldowns[weapon_index]) - maxf(delta, 0.0),
			0.0
		)
		if remaining <= 0.0:
			_weapon_auto_target_cooldowns.erase(weapon_index)
		else:
			_weapon_auto_target_cooldowns[weapon_index] = remaining


func _automatic_target_is_usable(turret, target: Variant) -> bool:
	if not target is Node3D or not is_instance_valid(target):
		return false
	var candidate := target as Node3D
	if not _combat_target_is_alive(candidate) \
	or not candidate.has_method("is_enemy_of") \
	or not bool(candidate.call("is_enemy_of", owner_player_id)):
		return false
	if turret.target_range(candidate) != CombatTurretScript.TargetRange.IN_RANGE:
		return false
	var target_position := _combat_target_position(candidate)
	return target_position.is_finite() \
		and not turret.requires_hull_turn_for(target_position)


func _turn_hull_by_adjustment(adjustment: float, delta: float) -> bool:
	if absf(adjustment) <= 0.0001:
		return true
	if turn_rate <= 0.0 or delta <= 0.0:
		return false
	var current_yaw := global_rotation.y
	var target_yaw := current_yaw + adjustment
	var maximum_step := turn_rate * RULE_MOVEMENT_UPDATES_PER_SECOND * delta
	global_rotation.y = rotate_toward(current_yaw, target_yaw, maximum_step)
	return absf(angle_difference(global_rotation.y, target_yaw)) <= 0.0001


func _set_weapon_target(weapon_index: int, target: Variant) -> void:
	if target is Vector3:
		_weapon_targets[weapon_index] = {
			"ground": target,
			"is_ground": true,
		}
	elif target is Object and is_instance_valid(target):
		_weapon_targets[weapon_index] = {
			"ref": weakref(target as Object),
			"is_ground": false,
		}


func _weapon_target(weapon_index: int) -> Variant:
	var state: Dictionary = _weapon_targets.get(weapon_index, {})
	if state.is_empty():
		return null
	if bool(state.get("is_ground", false)):
		return state.get("ground", Vector3.INF)
	return _weak_target(state)


func _weak_target(state: Variant) -> Variant:
	if not state is Dictionary:
		return null
	var target_ref: WeakRef = (state as Dictionary).get("ref") as WeakRef
	return target_ref.get_ref() if target_ref != null else null


func _start_authored_fire_sequence(turret, attack_target: Variant = null) -> bool:
	var weapon_index: int = turret.weapon_index()
	if _weapon_fire_sequences.has(weapon_index):
		return false
	if attack_target == null:
		attack_target = attack_order_target()
	var binding := _fire_animation_binding(turret.weapon_index())
	if binding.is_empty():
		return false
	var player := binding["player"] as AnimationPlayer
	var animation_name := StringName(binding["name"])
	var animation := player.get_animation(animation_name)
	if animation == null or animation.length <= 0.0:
		return false

	var can_fire_moving := weapon_can_fire_while_moving(weapon_index)
	var playback_player: AnimationPlayer = _weapon_fire_overlays.get(
		weapon_index
	) as AnimationPlayer if can_fire_moving else player
	if not can_fire_moving:
		for state_value: Variant in _weapon_fire_sequences.values():
			if bool((state_value as Dictionary).get("blocking", false)):
				return false
		stop_at_current_position()
	var target_state := _encoded_target(attack_target)
	if target_state.is_empty():
		return false
	_weapon_fire_sequences[weapon_index] = {
		"turret": turret,
		"target": target_state,
		"player": playback_player,
		"animation": animation_name,
		"duration": animation.length,
		"elapsed": 0.0,
		"shot_times": _authored_fire_shot_times(
			player, animation, turret, animation_name
		),
		"next_shot": 0,
		"shots_emitted": 0,
		"blocking": not can_fire_moving,
	}
	# Vehicle turrets reload independently while their authored clip plays.
	# Infantry Fire clips animate the whole actor through one locked action, so
	# their post-action ReloadCount is started by _finish_fire_sequence instead.
	# Committed shots bypass either timer so multi-muzzle salvos finish normally.
	if not _reload_starts_after_fire_animation():
		turret.begin_reload()
	if playback_player != null and playback_player.has_animation(animation_name):
		playback_player.speed_scale = FIRE_ANIMATION_SPEED_SCALE
		_play_animation_from_start(playback_player, animation_name)
	turret.start_authored_fire_fx(
		animation_name, null, FIRE_ANIMATION_SPEED_SCALE
	)
	_sync_legacy_fire_sequence()
	return true


func _advance_fire_sequences(delta: float) -> void:
	for weapon_index: Variant in _weapon_fire_sequences.keys():
		if not _weapon_fire_sequences.has(weapon_index):
			continue
		var state: Dictionary = _weapon_fire_sequences[weapon_index]
		var elapsed := minf(
			float(state.get("elapsed", 0.0))
				+ maxf(delta, 0.0) * FIRE_ANIMATION_SPEED_SCALE,
			float(state.get("duration", 0.0))
		)
		state["elapsed"] = elapsed
		var shot_times: Array = state.get("shot_times", [])
		var next_shot := int(state.get("next_shot", 0))
		var turret = state.get("turret")
		var attack_target: Variant = _decoded_target(
			state.get("target", {})
		)
		# A continuous stream's authored Damage is one clip's total payload,
		# not each per-frame pulse's own full hit; split it evenly across
		# every scheduled pulse so one full stream deals Damage once overall.
		var damage_scale := 1.0
		if bool(turret.is_continuous_bullet()) and shot_times.size() > 0:
			damage_scale = 1.0 / shot_times.size()
		while (
			next_shot < shot_times.size()
			and float(shot_times[next_shot]) <= elapsed + FIRE_EVENT_EPSILON
		):
			next_shot += 1
			if attack_target == null:
				continue
			var projectiles: Array = turret.try_fire_at(
				attack_target, self, null, Vector3.ZERO, false, false, true, damage_scale
			)
			if projectiles.is_empty():
				continue
			state["shots_emitted"] = int(state.get("shots_emitted", 0)) \
				+ projectiles.size()
			weapon_fired.emit(projectiles, attack_target, int(weapon_index))
		state["next_shot"] = next_shot
		_weapon_fire_sequences[weapon_index] = state
		if elapsed + FIRE_EVENT_EPSILON >= float(state.get("duration", 0.0)):
			_finish_fire_sequence_for(int(weapon_index))
	_sync_legacy_fire_sequence()


func _finish_fire_sequence() -> void:
	if _weapon_fire_sequences.is_empty():
		return
	_finish_fire_sequence_for(int(_weapon_fire_sequences.keys().front()))


func _cancel_fire_sequence(restore_idle := true) -> void:
	_cancel_all_fire_sequences(restore_idle)


func _reload_starts_after_fire_animation() -> bool:
	return unit_definition != null and unit_definition.infantry


func _clear_fire_sequence() -> void:
	_cancel_all_fire_sequences(false)


func _finish_fire_sequence_for(weapon_index: int) -> void:
	if not _weapon_fire_sequences.has(weapon_index):
		return
	var state: Dictionary = _weapon_fire_sequences[weapon_index]
	_weapon_fire_sequences.erase(weapon_index)
	var player := state.get("player") as AnimationPlayer
	if player != null and is_instance_valid(player):
		# stop() without keep_state rewinds the just-finished Fire clip to its
		# first frame immediately. Deployed Kindjal/Mortar clips begin with a
		# large embedded bigflash, while Deploy_Gun_Hold is not evaluated until
		# the next animation tick, producing a duplicate one-frame muzzle flash.
		player.stop(true)
	var turret = state.get("turret")
	if turret != null:
		turret.cancel_authored_fire_fx()
	if _reload_starts_after_fire_animation() \
	and int(state.get("shots_emitted", 0)) > 0 and turret != null:
		turret.begin_reload()
	var was_blocking := bool(state.get("blocking", false))
	_sync_legacy_fire_sequence()
	if was_blocking and not _movement_animation_active:
		_set_movement_animation(false)


func _cancel_all_fire_sequences(restore_idle := true) -> void:
	var had_blocking := false
	for weapon_index: Variant in _weapon_fire_sequences.keys():
		var state: Dictionary = _weapon_fire_sequences[weapon_index]
		had_blocking = had_blocking or bool(state.get("blocking", false))
		var player := state.get("player") as AnimationPlayer
		if player != null and is_instance_valid(player):
			player.stop(true)
		var turret = state.get("turret")
		if turret != null:
			turret.cancel_authored_fire_fx()
		if _reload_starts_after_fire_animation() \
		and int(state.get("shots_emitted", 0)) > 0 and turret != null:
			turret.begin_reload()
	_weapon_fire_sequences.clear()
	_sync_legacy_fire_sequence()
	if restore_idle and had_blocking:
		_set_movement_animation(false)


func _has_blocking_fire_sequence() -> bool:
	for state_value: Variant in _weapon_fire_sequences.values():
		if bool((state_value as Dictionary).get("blocking", false)):
			return true
	return false


func _cancel_blocking_fire_sequences() -> void:
	for weapon_index: Variant in _weapon_fire_sequences.keys():
		var state: Dictionary = _weapon_fire_sequences[weapon_index]
		if not bool(state.get("blocking", false)):
			continue
		var player := state.get("player") as AnimationPlayer
		if player != null and is_instance_valid(player):
			player.stop(true)
		var turret = state.get("turret")
		if turret != null:
			turret.cancel_authored_fire_fx()
		_weapon_fire_sequences.erase(weapon_index)
	_sync_legacy_fire_sequence()


func _sync_legacy_fire_sequence() -> void:
	_fire_sequence_active = false
	_fire_sequence_turret = null
	_fire_sequence_player = null
	_fire_sequence_animation = &""
	_fire_sequence_duration = 0.0
	_fire_sequence_elapsed = 0.0
	_fire_sequence_shot_times.clear()
	_fire_sequence_next_shot = 0
	_fire_sequence_shots_emitted = 0
	if _weapon_fire_sequences.is_empty():
		return
	var state: Dictionary = _weapon_fire_sequences.values().front()
	_fire_sequence_active = true
	_fire_sequence_turret = state.get("turret")
	_fire_sequence_player = state.get("player") as AnimationPlayer
	_fire_sequence_animation = StringName(state.get("animation", &""))
	_fire_sequence_duration = float(state.get("duration", 0.0))
	_fire_sequence_elapsed = float(state.get("elapsed", 0.0))
	_fire_sequence_shot_times.assign(state.get("shot_times", []))
	_fire_sequence_next_shot = int(state.get("next_shot", 0))
	_fire_sequence_shots_emitted = int(state.get("shots_emitted", 0))


func _encoded_target(target: Variant) -> Dictionary:
	if target is Vector3:
		return {"is_ground": true, "ground": target}
	if target is Object and is_instance_valid(target):
		return {"is_ground": false, "ref": weakref(target as Object)}
	return {}


func _decoded_target(state: Variant) -> Variant:
	if not state is Dictionary or (state as Dictionary).is_empty():
		return null
	if bool((state as Dictionary).get("is_ground", false)):
		return (state as Dictionary).get("ground", Vector3.INF)
	return _weak_target(state)


## Deployed state always resolves the single canonical Deployed_Fire clip
## (see converters/model_bake_builder.gd CLIP_NAME_OVERRIDES); the ordinary
## Fire_<index> chain below is travel-mode only and must never be reached
## while deployed, since Fire_0 is the travel-mode animation.
func _fire_animation_binding(weapon_index: int) -> Dictionary:
	if is_deployed():
		for player in _animation_players:
			if player.has_animation(DEPLOYED_FIRE_ANIMATION):
				return {"player": player, "name": DEPLOYED_FIRE_ANIMATION}
		return {}
	var variants := _travel_fire_variant_bindings(weapon_index)
	if not variants.is_empty():
		return variants[randi() % variants.size()]
	var fallback_candidates: Array[StringName] = [&"Fire"]
	if weapon_index != 0:
		fallback_candidates.append(&"Fire_0")
	for player in _animation_players:
		for animation_name in fallback_candidates:
			if player.has_animation(animation_name):
				return {"player": player, "name": animation_name}
	return {}


## Every Fire_<N> clip belonging to this weapon: its own authored
## Fire_<weapon_index>, plus — only on a combat-deployable unit (Kindjal,
## Mortar, Kobra; see _is_combat_deployable) — any Fire_<N> whose index is not
## claimed by any configured turret (an orphan travel-mode variant, e.g.
## Kobra's Fire_2 once Fire_1 is renamed to Deployed_Fire). These orphan
## clips are equivalent shot variants for the same weapon, not per-weapon-
## index clips, and are chosen at random per shot, mirroring the idle-variant
## selection in _idle_animations/_play_random_idle. An ordinary multi-turret
## unit (e.g. ATMinotaurus, which authors an unrelated, unused Fire_1
## alongside its single real turret's Fire_0) is never a combat-deployable
## eligibility match, so it always resolves exactly one binding here — its
## own Fire_<weapon_index> — matching the previous index-keyed lookup
## byte-for-byte.
func _travel_fire_variant_bindings(weapon_index: int) -> Array[Dictionary]:
	var include_orphans := _is_combat_deployable()
	var configured_indices := {}
	if include_orphans:
		for turret in combat_turrets:
			configured_indices[turret.weapon_index()] = true
	var seen := {}
	var bindings: Array[Dictionary] = []
	for player in _animation_players:
		for animation_name in player.get_animation_list():
			var name_text := String(animation_name)
			if not name_text.begins_with(FIRE_ANIMATION_PREFIX):
				continue
			var suffix := name_text.trim_prefix(FIRE_ANIMATION_PREFIX)
			if not suffix.is_valid_int():
				continue
			var suffix_index := int(suffix)
			if suffix_index != weapon_index \
			and (not include_orphans or configured_indices.has(suffix_index)):
				continue
			var key := "%d:%s" % [player.get_instance_id(), name_text]
			if seen.has(key):
				continue
			seen[key] = true
			bindings.append({"player": player, "name": animation_name})
	return bindings


## Data-driven combat-deploy eligibility (mirrors combat_deploy_strategy.gd):
## at least one configured turret gated disabled_when_deployed and at least
## one gated disabled_when_undeployed. Scoped to this unit's own turrets so it
## needs no rules database access, unlike the strategy's version which must
## work before any Unit instance exists.
func _is_combat_deployable() -> bool:
	var has_travel_gate := false
	var has_deployed_gate := false
	for turret in combat_turrets:
		if turret.config == null:
			continue
		if bool(turret.config.disabled_when_deployed):
			has_travel_gate = true
		if bool(turret.config.disabled_when_undeployed):
			has_deployed_gate = true
	return has_travel_gate and has_deployed_gate


func _authored_fire_shot_times(
		player: AnimationPlayer,
		animation: Animation,
		turret,
		animation_name: StringName = &""
	) -> Array[float]:
	if animation_name.is_empty():
		for candidate_name: StringName in player.get_animation_list():
			if player.get_animation(candidate_name) == animation:
				animation_name = candidate_name
				break
	var xbf_events := _xbf_fire_shot_times(animation_name, animation, turret)
	if not xbf_events.is_empty():
		return xbf_events
	var configured_burst := _configured_burst_shot_times(animation, turret)
	if not configured_burst.is_empty():
		return configured_burst
	var fallback: Array[float] = [
		minf(1.0 / BAKED_MODEL_FRAMES_PER_SECOND, animation.length)
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


## XBF type-10 records are gameplay projectile events. Their integer payload
## selects the source muzzle, while their absolute frame locates the shot in
## the containing animation entry. Converted clips are sliced from those same
## absolute ranges, so subtracting the clip start preserves the authored delay.
func _xbf_fire_shot_times(
		animation_name: StringName, animation: Animation, turret
	) -> Array[float]:
	if animation_name.is_empty() or visual_root == null:
		return []
	var model_root := _find_xbf_motion_root(visual_root)
	if model_root == null \
	or not bool(model_root.get_meta("xbf_fx_events_complete", false)):
		return []
	var source_entry := {}
	for entry_value: Variant in model_root.get_meta("xbf_animation_entries", []):
		var entry := entry_value as Dictionary
		var converted_name := String(entry.get("name", "")).strip_edges().replace(" ", "_")
		if converted_name == String(animation_name):
			source_entry = entry
			break
	if source_entry.is_empty():
		return []
	var start_frame := int(source_entry.get("start_frame", -1))
	var end_frame := int(source_entry.get("end_frame", -1))
	if start_frame < 0 or end_frame < start_frame:
		return []
	var result: Array[float] = []
	for event_value: Variant in model_root.get_meta("xbf_fx_events", []):
		var event := event_value as Dictionary
		var frame := int(event.get("frame", -1))
		if int(event.get("type", -1)) == 10 \
		and frame >= start_frame and frame <= end_frame:
			result.append(clampf(
				float(frame - start_frame) / BAKED_MODEL_FRAMES_PER_SECOND,
				0.0,
				animation.length
			))
	# Continuous bullets author one type-10 launch and keep their stream banks
	# active for the remaining damage pulses. Expand that launch over the
	# source-backed stream interval instead of treating it as one ordinary shot.
	if (
		result.size() == 1
		and turret.bullet_config != null
		and bool(turret.bullet_config.continuous)
	):
		var first_shot_frame := int(round(
			result[0] * BAKED_MODEL_FRAMES_PER_SECOND
		)) + start_frame
		var continuous_result := _xbf_continuous_fire_shot_times(
			model_root, start_frame, end_frame, animation.length, first_shot_frame
		)
		if continuous_result.size() > 1:
			return continuous_result
	# Generated launcher configuration remains a safe fallback for a partial or
	# ambiguous source schedule; never silently drop part of a known salvo.
	if turret.firing_config != null:
		var configured_count := int(turret.firing_config.burst_shot_count)
		if configured_count > 0 and result.size() != configured_count:
			return []
	return result


func _xbf_continuous_fire_shot_times(
		model_root: Node,
		clip_start: int,
		clip_end: int,
		animation_length: float,
		first_shot_frame: int
	) -> Array[float]:
	var stream_stop_frame := first_shot_frame + 1
	var events := model_root.get_meta("xbf_fx_events", []) as Array
	for start_value: Variant in events:
		var start_event := start_value as Dictionary
		if String(start_event.get("action", "")) != "start":
			continue
		var start_frame := int(start_event.get("frame", -1))
		if start_frame < clip_start or start_frame > first_shot_frame:
			continue
		var attachment := String(start_event.get("attachment", "")).to_lower()
		if not attachment.begins_with(">>") and not attachment.contains("gun"):
			continue
		var bank_id := String(start_event.get("bank_id", ""))
		for stop_value: Variant in events:
			var stop_event := stop_value as Dictionary
			if (
				String(stop_event.get("action", "")) != "stop"
				or String(stop_event.get("bank_id", "")) != bank_id
				or String(stop_event.get("attachment", "")).nocasecmp_to(
					String(start_event.get("attachment", ""))
				) != 0
			):
				continue
			var stop_frame := int(stop_event.get("frame", -1))
			if stop_frame > first_shot_frame and stop_frame <= clip_end:
				stream_stop_frame = maxi(stream_stop_frame, stop_frame)
				break
	var result: Array[float] = []
	for frame in range(first_shot_frame, stream_stop_frame):
		result.append(clampf(
			float(frame - clip_start) / BAKED_MODEL_FRAMES_PER_SECOND,
			0.0,
			animation_length
		))
	return result


func _configured_burst_shot_times(animation: Animation, turret) -> Array[float]:
	if turret.firing_config == null:
		return []
	var count := int(turret.firing_config.burst_shot_count)
	if count <= 0:
		return []
	var first_shot_time := minf(1.0 / BAKED_MODEL_FRAMES_PER_SECOND, animation.length)
	var interval_seconds := maxf(
		float(turret.firing_config.burst_interval_ticks), 0.0
	) / RULE_COMBAT_TICKS_PER_SECOND
	var result: Array[float] = []
	for index in count:
		result.append(minf(
			first_shot_time + float(index) * interval_seconds,
			animation.length
		))
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
	for turret in _active_turrets():
		if turret.can_target(attack_target):
			return turret
	return null


func _advance_attack_pursuit(
	target_world_position: Vector3, primary_turret, delta: float
	) -> void:
	_attack_repath_remaining = maxf(_attack_repath_remaining - delta, 0.0)
	var target_moved := not _attack_last_path_position.is_finite() \
		or _attack_last_path_position.distance_to(target_world_position) >= ATTACK_REPATH_DISTANCE
	var route_unreachable: bool = (
		_navigation_managed
		and _navigation_system != null
		and _navigation_system.has_method("route_is_unreachable")
		and bool(_navigation_system.call("route_is_unreachable", self))
	)
	if target_moved:
		_attack_pursuit_destination = Vector3.INF
		_attack_pursuit_rejected = false
		route_unreachable = false
	if _attack_repath_remaining > 0.0 \
	or (
		_attack_is_pursuing
		and not target_moved
		and not route_unreachable
		and _mech_has_active_move_order()
	):
		return
	_attack_is_pursuing = true
	_attack_last_path_position = target_world_position
	_attack_repath_remaining = ATTACK_REPATH_INTERVAL_SECONDS
	var pursuit_position := target_world_position
	var horizontal_offset := target_world_position - global_position
	horizontal_offset.y = 0.0
	var preferred_range := float(primary_turret.maximum_range_world()) * 0.8 \
		if primary_turret != null else 0.0
	var reachable_position := Vector3.INF
	if (
		_navigation_managed
		and _navigation_system != null
		and primary_turret != null
		and _navigation_system.has_method("reachable_attack_position")
	):
		reachable_position = _navigation_system.call(
			"reachable_attack_position",
			self,
			target_world_position,
			float(primary_turret.maximum_range_world())
		)
	if reachable_position.is_finite():
		pursuit_position = reachable_position
	elif preferred_range > 0.0:
		# Navigate to a firing position rather than the target coordinate itself.
		# An attack-ground point on top of a cliff may be unreachable to a ground
		# unit even though a position in front of it is a valid artillery perch.
		# If that first perch still cannot satisfy the elevation limits, halve
		# the remaining distance on the next arrival and continue approaching.
		var remaining_distance := minf(
			preferred_range, horizontal_offset.length() * 0.5
		)
		pursuit_position = target_world_position \
			- horizontal_offset.normalized() * remaining_distance
	if (
		not reachable_position.is_finite()
		and (route_unreachable or _attack_pursuit_rejected)
		and _attack_pursuit_destination.is_finite()
	):
		# The requested perch landed on disconnected terrain (commonly the red
		# face or the separately connected top of a cliff). Back it toward the
		# unit until the navigation grid accepts a firing position on this side.
		pursuit_position = global_position.lerp(
			_attack_pursuit_destination, 0.5
		)
	_attack_pursuit_destination = pursuit_position
	_issuing_attack_move = true
	var move_issued := true
	if _navigation_managed and _navigation_system != null:
		var assignments: Array = _navigation_system.command_move(
			[self], pursuit_position, UnitNavigationSystemScript.MoveMode.FREE
		)
		move_issued = not assignments.is_empty()
	else:
		move_to(pursuit_position)
	_issuing_attack_move = false
	_attack_pursuit_rejected = not move_issued
	_attack_is_pursuing = move_issued


func _combat_target_position(attack_target: Variant) -> Vector3:
	if attack_target is Vector3:
		return attack_target
	if not attack_target is Object or not is_instance_valid(attack_target):
		return Vector3.INF
	var target_object := attack_target as Object
	if target_object.has_method("combat_aim_position_from"):
		var value: Variant = target_object.call(
			"combat_aim_position_from", global_position
		)
		if value is Vector3:
			return value
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
	if _deploy_state != DeployState.TRAVEL:
		return false
	_deploy_state = DeployState.DEPLOYING
	_sync_active_turret_weapons()
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


## Combat-deploy strategy's toggle-back. The MCV/Construction Yard pair never
## calls this: its "undeploy" is a different unit (the spawned MCV) built by
## UnitDeploymentController's own Deconstruct handling, not a state on the
## same Unit instance.
func undeploy() -> bool:
	if _deploy_state != DeployState.DEPLOYED:
		return false
	_deploy_state = DeployState.UNDEPLOYING
	_sync_active_turret_weapons()
	stop_at_current_position()
	if _navigation_system != null and _navigation_system.has_method("set_hold_position"):
		_navigation_system.call("set_hold_position", self, true)
	_start_undeployment_animation()
	return true


func _start_deployment_animation() -> void:
	_start_transition_animation(DEPLOYMENT_ANIMATION_CANDIDATES)


func _start_undeployment_animation() -> void:
	_start_transition_animation(UNDEPLOYMENT_ANIMATION_CANDIDATES)


func _start_transition_animation(candidates: Array[StringName]) -> void:
	_deployment_animation_player = null
	_deployment_animation_name = &""
	for candidate in candidates:
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


## Both transition directions count as "deploying" for every gameplay lock: a
## unit is equally immobile while folding out and while folding back in.
func is_deploying() -> bool:
	return _deploy_state == DeployState.DEPLOYING or _deploy_state == DeployState.UNDEPLOYING


## Stationary combat mode (Kindjal/Mortar/Kobra). Never true for the MCV,
## which has no DEPLOYED state of its own: a successful deploy consumes it
## into a Construction Yard instead.
func is_deployed() -> bool:
	return _deploy_state == DeployState.DEPLOYED


func _emit_deployment_animation_finished() -> void:
	if is_deploying():
		deployment_animation_finished.emit()


## The deployment strategy calls this after the animation-to-world handoff.
## `consumed` means the transition completed as intended: for the MCV this is
## true only on a successful Construction Yard placement (the unit is freed
## immediately after by the caller, so the resulting DeployState is moot); for
## the combat strategy it is true whenever deploy()/undeploy() simply run to
## completion, since nothing here is ever destroyed. `false` means the
## transition was aborted (MCV placement failed after the animation already
## played) and must fully unwind back to the state before it started.
func finish_deployment(consumed: bool) -> void:
	if not is_deploying():
		return
	var was_deploying := _deploy_state == DeployState.DEPLOYING
	_deployment_aligning = false
	_deployment_alignment_direction = Vector3.ZERO
	_deployment_animation_player = null
	_deployment_animation_name = &""
	if consumed:
		_deploy_state = DeployState.DEPLOYED if was_deploying else DeployState.TRAVEL
	else:
		_deploy_state = DeployState.TRAVEL if was_deploying else DeployState.DEPLOYED
	_sync_active_turret_weapons()
	var still_locked := is_deployed()
	if _navigation_system != null and _navigation_system.has_method("set_hold_position"):
		_navigation_system.call("set_hold_position", self, still_locked)
	_set_movement_animation(false)


## Cancels any in-flight fire sequence and clears retained targets for every
## weapon whose turret just became inactive under the current deploy state,
## then zeroes its servo angle for next time it's reactivated. Turrets that
## stay active are left untouched. This does not touch the pivot transform:
## while inactive, the pivot belongs to the model's own deploy/undeploy/idle
## animation, and stamping the combat-owned rest pose here would fight or
## outlast that animation (e.g. snapping a just-folded-away deploy-only
## turret back to its deployed pose).
func _sync_active_turret_weapons() -> void:
	var active_indices := {}
	for turret in _active_turrets():
		active_indices[turret.weapon_index()] = true
	for turret in combat_turrets:
		var weapon_index: int = turret.weapon_index()
		if active_indices.has(weapon_index):
			continue
		_finish_fire_sequence_for(weapon_index)
		_weapon_targets.erase(weapon_index)
		_weapon_auto_targets.erase(weapon_index)
		_weapon_auto_target_cooldowns.erase(weapon_index)
		_moving_fire_weapons.erase(weapon_index)
		turret.reset_aim()


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


func _apply_unit_definition() -> void:
	if String(config_id).is_empty():
		return

	unit_definition = _definition_catalog.definition_for(config_id)
	if unit_definition == null:
		push_warning("Unit definition not found: %s" % String(config_id))
		return

	move_speed = float(unit_definition.speed)
	mech_speed = maxf(float(unit_definition.mech_speed), 0.0)
	_uses_mech_gait = unit_definition.mech and mech_speed > 0.0
	_mech_gait_elapsed = 0.0
	_mech_locomotion_state = MechLocomotionState.IDLE
	_mech_start_remaining = 0.0
	turn_rate = maxf(float(unit_definition.turn_rate), 0.0)
	can_move_any_direction = unit_definition.can_move_any_direction
	max_health = float(unit_definition.health)
	max_shields = float(unit_definition.shield_health)
	armour_type = unit_definition.armour_type
	_configure_combat_turrets()
	if unit_definition.can_fly:
		if _flight_controller == null:
			_flight_controller = UnitFlightControllerScript.new()
		_flight_controller.configure(self, unit_definition)
	else:
		_flight_controller = null


func _configure_combat_turrets() -> void:
	combat_turrets.clear()
	var turret_values: Array = unit_definition.turret_ids
	for weapon_index in turret_values.size():
		var turret_value: Variant = turret_values[weapon_index]
		var turret = CombatTurretScript.new()
		if turret.configure(StringName(String(turret_value))):
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


func weapon_can_fire_while_moving(weapon_index: int) -> bool:
	return bool(_weapon_can_fire_while_moving.get(weapon_index, false))


func _refresh_weapon_runtime() -> void:
	for overlay_value: Variant in _weapon_fire_overlays.values():
		if is_instance_valid(overlay_value) and overlay_value is AnimationPlayer:
			(overlay_value as AnimationPlayer).queue_free()
	_weapon_fire_overlays.clear()
	_weapon_can_fire_while_moving.clear()
	_weapon_targets.clear()
	_weapon_auto_targets.clear()
	_weapon_auto_target_cooldowns.clear()
	_moving_fire_weapons.clear()
	# Only a turret active in the unit's spawn-time state (always TRAVEL) can
	# ever fire while moving; a combat-deploy unit's deployed turret is
	# inactive here and immobile whenever it later becomes active, so it never
	# needs a fire-while-moving overlay bound to the wrong (travel-mode) clip.
	for turret in _active_turrets():
		var weapon_index: int = turret.weapon_index()
		var binding := _fire_animation_binding(weapon_index)
		var can_layer := false
		if turret.has_independent_yaw() and not binding.is_empty():
			can_layer = (
				unit_definition != null and unit_definition.can_fly
			) or _fire_animation_is_turret_local(binding, turret)
		_weapon_can_fire_while_moving[weapon_index] = can_layer
		if can_layer:
			var overlay := _create_fire_overlay(binding, turret)
			if overlay != null:
				_weapon_fire_overlays[weapon_index] = overlay


func _fire_animation_is_turret_local(binding: Dictionary, turret) -> bool:
	var player := binding.get("player") as AnimationPlayer
	var animation_name := StringName(binding.get("name", &""))
	if player == null:
		return false
	var animation := player.get_animation(animation_name)
	if animation == null:
		return false
	for track in animation.get_track_count():
		if not _animation_track_changes(animation, track):
			continue
		var track_path := String(animation.track_get_path(track))
		if not track_path.ends_with(":transform"):
			continue
		var target_node := _animation_track_node(player, track_path)
		if target_node != null and not turret.owns_aim_branch(target_node):
			return false
	return true


func _create_fire_overlay(binding: Dictionary, turret) -> AnimationPlayer:
	var source_player := binding.get("player") as AnimationPlayer
	var animation_name := StringName(binding.get("name", &""))
	if source_player == null or source_player.get_parent() == null:
		return null
	var source_animation := source_player.get_animation(animation_name)
	if source_animation == null:
		return null
	var animation := source_animation.duplicate(true) as Animation
	for track in range(animation.get_track_count() - 1, -1, -1):
		var track_path := String(animation.track_get_path(track))
		var target_node := _animation_track_node(source_player, track_path)
		var keep: bool = _animation_track_changes(animation, track) \
			and (
				(unit_definition != null and unit_definition.can_fly)
				or target_node == null
				or turret.owns_aim_branch(target_node)
			)
		if not keep:
			animation.remove_track(track)
	var overlay := AnimationPlayer.new()
	overlay.name = "WeaponFireOverlay_%d" % turret.weapon_index()
	overlay.root_node = source_player.root_node
	overlay.process_priority = process_priority - 1
	overlay.set_meta("combat_weapon_fire_overlay", true)
	source_player.get_parent().add_child(overlay)
	var library := AnimationLibrary.new()
	library.add_animation(animation_name, animation)
	overlay.add_animation_library(&"", library)
	return overlay


func _animation_track_node(player: AnimationPlayer, track_path: String) -> Node:
	if player == null:
		return null
	var animation_root := player.get_node_or_null(player.root_node)
	if animation_root == null:
		return null
	var separator := track_path.find(":")
	var node_path := track_path.substr(0, separator) \
		if separator >= 0 else track_path
	return animation_root.get_node_or_null(NodePath(node_path))


func _animation_track_changes(animation: Animation, track: int) -> bool:
	if animation.track_get_key_count(track) < 2:
		return false
	var first: Variant = animation.track_get_key_value(track, 0)
	for key in range(1, animation.track_get_key_count(track)):
		var value: Variant = animation.track_get_key_value(track, key)
		if first is Transform3D and value is Transform3D:
			var a := first as Transform3D
			var b := value as Transform3D
			if not a.origin.is_equal_approx(b.origin) \
			or not a.basis.is_equal_approx(b.basis):
				return true
		elif value != first:
			return true
	return false


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


func _set_movement_animation(
		is_moving: bool, speed_scale := 1.0, turn_animation: StringName = &""
	) -> void:
	if _flight_controller != null and _flight_controller.flight_is_airborne_phase():
		_flight_controller.set_cruise_moving(is_moving, speed_scale)
		return
	if _has_blocking_fire_sequence():
		if not is_moving:
			return
		_cancel_blocking_fire_sequences()
	if _uses_mech_gait:
		_set_mech_locomotion_animation(is_moving, speed_scale, turn_animation)
		_restore_combat_turret_poses()
		return
	if not is_moving:
		_mech_gait_elapsed = 0.0
		_mech_start_remaining = 0.0
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


func _set_mech_locomotion_animation(
		is_moving: bool, move_speed_scale: float, turn_animation: StringName
	) -> void:
	var was_moving := _movement_animation_active
	_movement_animation_active = is_moving
	if not is_moving:
		_mech_gait_elapsed = 0.0
		_mech_start_remaining = 0.0
		if (
			_mech_locomotion_state == MechLocomotionState.STOPPING
			and _any_animation_playing(MOVE_STOP_ANIMATION)
		):
			return
		if was_moving and _any_player_has_animation(MOVE_STOP_ANIMATION):
			_mech_locomotion_state = MechLocomotionState.STOPPING
			_play_mech_clip(MOVE_STOP_ANIMATION, _mech_gait_cadence())
			return
		_mech_locomotion_state = MechLocomotionState.IDLE
		for player in _animation_players:
			player.speed_scale = 1.0
			_play_idle_sequence(player)
		return

	if turn_animation in [TURN_LEFT_ANIMATION, TURN_RIGHT_ANIMATION] \
	and _any_player_has_animation(turn_animation):
		_mech_start_remaining = 0.0
		_mech_locomotion_state = MechLocomotionState.TURNING_LEFT \
			if turn_animation == TURN_LEFT_ANIMATION \
			else MechLocomotionState.TURNING_RIGHT
		# TurnRate already controls the physical hull yaw. These authored clips
		# describe the feet/body pose during that turn and retain their own time.
		_play_mech_clip(turn_animation, 1.0)
		return

	if (
		_mech_locomotion_state == MechLocomotionState.STARTING
		and _any_animation_playing(MOVE_START_ANIMATION)
	):
		return
	if _mech_locomotion_state == MechLocomotionState.MOVING:
		_play_mech_clip(MOVING_ANIMATION, move_speed_scale)
		return

	if _any_player_has_animation(MOVE_START_ANIMATION):
		_mech_locomotion_state = MechLocomotionState.STARTING
		var start_speed_scale := _mech_gait_cadence()
		_mech_start_remaining = _animation_playback_duration(
			MOVE_START_ANIMATION, start_speed_scale
		)
		_play_mech_clip(MOVE_START_ANIMATION, start_speed_scale)
		if _mech_start_remaining <= 0.0:
			_begin_mech_move(move_speed_scale)
		return
	_begin_mech_move(move_speed_scale)


func _begin_mech_move(speed_scale: float) -> void:
	_mech_locomotion_state = MechLocomotionState.MOVING
	_mech_start_remaining = 0.0
	_play_mech_clip(MOVING_ANIMATION, speed_scale)


func _play_mech_clip(animation_name: StringName, speed_scale: float) -> void:
	for player in _animation_players:
		var selected_animation := animation_name
		if not player.has_animation(selected_animation):
			if animation_name in [
				MOVE_START_ANIMATION,
				MOVE_STOP_ANIMATION,
				TURN_LEFT_ANIMATION,
				TURN_RIGHT_ANIMATION,
			] and player.has_animation(MOVING_ANIMATION):
				selected_animation = MOVING_ANIMATION
			else:
				continue
		if (
			player.current_animation != selected_animation
			or not player.is_playing()
		):
			if player.current_animation == selected_animation:
				player.stop()
			player.play(selected_animation)
		player.speed_scale = maxf(speed_scale, 0.0)


func _any_player_has_animation(animation_name: StringName) -> bool:
	for player in _animation_players:
		if player.has_animation(animation_name):
			return true
	return false


func _any_animation_playing(animation_name: StringName) -> bool:
	for player in _animation_players:
		if (
			player.has_animation(animation_name)
			and player.current_animation == animation_name
			and player.is_playing()
		):
			return true
	return false


func _animation_playback_duration(animation_name: StringName, speed_scale: float) -> float:
	var duration := 0.0
	var safe_speed_scale := maxf(speed_scale, 0.000001)
	for player in _animation_players:
		if not player.has_animation(animation_name):
			continue
		var animation := player.get_animation(animation_name)
		if animation != null:
			duration = maxf(duration, animation.length / safe_speed_scale)
	return duration


func _play_idle_sequence(player: AnimationPlayer) -> void:
	var idle_animations := _idle_animations(player)
	if idle_animations.is_empty():
		if is_deployed() and player.has_animation(DEPLOYED_HOLD_ANIMATION):
			_hold_deployed_pose(player)
			return
		if player.has_animation(IDLE_ANIMATION) and player.current_animation != IDLE_ANIMATION:
			player.play(IDLE_ANIMATION)
		return

	var player_id := player.get_instance_id()
	var is_sequence_animation := player.current_animation == IDLE_ANIMATION \
		or player.current_animation in idle_animations
	if is_sequence_animation and player.is_playing() and _stationary_repeats_remaining.has(player_id):
		return
	_start_stationary_batch(player, idle_animations)


## Kobra/Mortar have no authored Deployed_Idle_* clip: rather than falling
## back to the travel-mode Stationary/Idle_* pose, hold the braced pose at the
## end of Deploy_Gun (Deploy_Gun_Hold) for as long as the unit stays deployed.
func _hold_deployed_pose(player: AnimationPlayer) -> void:
	if player.current_animation == DEPLOYED_HOLD_ANIMATION and player.is_playing():
		return
	var animation := player.get_animation(DEPLOYED_HOLD_ANIMATION)
	if animation != null:
		animation.loop_mode = Animation.LOOP_LINEAR
	# Preserve the hidden final bigflash pose until the hold clip receives its
	# first animation tick. Rewinding the completed Deployed_Fire here exposes
	# its large first-frame flash for one rendered frame.
	player.stop(true)
	player.play(DEPLOYED_HOLD_ANIMATION)
	_restore_combat_turret_poses()


func _start_stationary_batch(player: AnimationPlayer, idle_animations: Array[StringName]) -> void:
	var player_id := player.get_instance_id()
	# A deployed unit must only ever consider its Deployed_Idle_* clips here:
	# a literal "Stationary" clip on the same model belongs to travel mode.
	if not is_deployed() and player.has_animation(IDLE_ANIMATION):
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
	# Keep the outgoing pose until the newly played clip is evaluated. Resetting
	# the outgoing animation here can expose its first-frame effects for the
	# remainder of the current rendered frame.
	player.stop(true)
	player.play(animation_name)
	_restore_combat_turret_poses()


func _restore_combat_turret_poses() -> void:
	for turret in combat_turrets:
		if turret != null:
			turret.restore_aim_pose()


func _idle_animations(player: AnimationPlayer) -> Array[StringName]:
	var prefix := DEPLOYED_IDLE_ANIMATION_PREFIX if is_deployed() else IDLE_ANIMATION_PREFIX
	var result: Array[StringName] = []
	for animation_name in player.get_animation_list():
		if String(animation_name).begins_with(prefix):
			result.append(animation_name)
	return result


func _on_animation_finished(animation_name: StringName, player: AnimationPlayer) -> void:
	if _flight_controller != null and _flight_controller.notify_animation_finished(animation_name, player):
		return
	if (
		_fire_sequence_active
		and player == _fire_sequence_player
		and animation_name == _fire_sequence_animation
	):
		# A long render frame may jump directly past the last authored shot.
		# Move this sequence to its logical end; the shared advancement path
		# emits every remaining committed projectile exactly once.
		for weapon_index: Variant in _weapon_fire_sequences.keys():
			var state: Dictionary = _weapon_fire_sequences[weapon_index]
			if state.get("player") == player \
			and StringName(state.get("animation", &"")) == animation_name:
				state["elapsed"] = float(state.get("duration", 0.0))
				_weapon_fire_sequences[weapon_index] = state
				_advance_fire_sequences(0.0)
				break
		return
	if (
		is_deploying()
		and player == _deployment_animation_player
		and animation_name == _deployment_animation_name
	):
		deployment_animation_finished.emit()
		return
	if _uses_mech_gait:
		if (
			_mech_locomotion_state == MechLocomotionState.STARTING
			and animation_name == MOVE_START_ANIMATION
		):
			_begin_mech_move(_mech_gait_cadence())
			return
		if (
			_mech_locomotion_state == MechLocomotionState.STOPPING
			and animation_name == MOVE_STOP_ANIMATION
		):
			_mech_locomotion_state = MechLocomotionState.IDLE
			_mech_start_remaining = 0.0
			for animation_player in _animation_players:
				animation_player.speed_scale = 1.0
				_play_idle_sequence(animation_player)
			return
		var active_turn_animation := TURN_LEFT_ANIMATION \
			if _mech_locomotion_state == MechLocomotionState.TURNING_LEFT \
			else TURN_RIGHT_ANIMATION
		if (
			_mech_locomotion_state in [
				MechLocomotionState.TURNING_LEFT,
				MechLocomotionState.TURNING_RIGHT,
			]
			and animation_name == active_turn_animation
			and _movement_animation_active
		):
			player.stop()
			player.play(animation_name)
			player.speed_scale = 1.0
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
	if _uses_mech_gait and not _mech_motion_profile.is_empty():
		var cadence := _mech_gait_cadence()
		if _mech_authored_phase_speed() <= 0.0:
			return cadence
		return cadence * velocity.length() / maxf(phase_speed, 0.000001)
	if phase_speed <= 0.0:
		return 1.0
	return velocity.length() / phase_speed


func _refresh_owner_visuals() -> void:
	var color := _owner_team_color()
	for mesh_instance in _mesh_instances():
		if _mesh_declares_team_color(mesh_instance):
			mesh_instance.set_instance_shader_parameter("team_color", color)


func _mesh_declares_team_color(mesh_instance: MeshInstance3D) -> bool:
	var materials: Array[Material] = []
	if mesh_instance.material_override != null:
		materials.append(mesh_instance.material_override)
	if mesh_instance.material_overlay != null:
		materials.append(mesh_instance.material_overlay)
	if mesh_instance.mesh != null:
		for surface_index in mesh_instance.mesh.get_surface_count():
			var material := mesh_instance.get_surface_override_material(surface_index)
			if material == null:
				material = mesh_instance.mesh.surface_get_material(surface_index)
			if material != null:
				materials.append(material)
	for material in materials:
		if material is ShaderMaterial:
			var shader := (material as ShaderMaterial).shader
			if shader != null and "instance uniform vec4 team_color" in shader.code:
				return true
	return false


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
	var anchor := _halo_anchor_node(visual_root)
	_selection_halo.configure(
		self, _selection_radius(), _selection_position(), anchor
	)
	_selection_halo.set_movement_direction(_navigation_requested_velocity)
	_selection_halo.set_movement_debug_visible(_navigation_debug_visible)


func _rebuild_selection_halo() -> void:
	if not is_instance_valid(_selection_halo):
		return
	remove_child(_selection_halo)
	_selection_halo.free()
	_add_selection_halo()
	_selection_halo.set_selected(is_selected)
	_selection_halo.set_hovered(is_hovered)


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
	var source_to_global := anchor.global_transform
	var reference_basis: Variant = (
		anchor.get_meta("halo_anchor_reference_basis")
		if anchor.has_meta("halo_anchor_reference_basis")
		else null
	)
	var anchor_parent := anchor.get_parent() as Node3D
	if reference_basis is Basis and anchor_parent != null:
		source_to_global.basis = (
			anchor_parent.global_transform.basis * (reference_basis as Basis)
		)
	var bounds := AABB()
	var has_bounds := false
	for corner in _aabb_corners(source_bounds):
		var point := to_local(source_to_global * corner)
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
