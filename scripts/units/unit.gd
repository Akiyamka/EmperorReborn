extends CharacterBody3D
class_name Unit

const AutoloadLookupScript := preload("res://scripts/players/autoload_lookup.gd")
const EntityQueryScript := preload("res://scripts/world/entity_query.gd")
const TeamColorScript := preload("res://scripts/world/team_color.gd")
const CombatTargetScript := preload("res://scripts/combat/combat_target.gd")
const AuthoredModelScript := preload("res://scripts/world/authored_model.gd")
const CombatRulesScript := preload("res://scripts/combat/combat_rules.gd")
const DamagePolicyScript := preload("res://scripts/combat/damage_policy.gd")
const AuthoredFireControllerScript := preload(
	"res://scripts/combat/authored_fire_controller.gd"
)
const SelectionHaloBindingScript := preload("res://scripts/ui/selection_halo_binding.gd")
const SpatialOrientationScript := preload("res://scripts/world/spatial_orientation.gd")
const CombatTurretScript := preload("res://scripts/combat/combat_turret.gd")
const UnitSceneCatalogScript := preload("res://scripts/units/unit_scene_catalog.gd")
const UnitFlightControllerScript := preload("res://scripts/units/navigation/unit_flight_controller.gd")
const UnitTerrainAlignmentScript := preload("res://scripts/units/unit_terrain_alignment.gd")
const NavConstantsScript := preload("res://scripts/units/navigation/shared/nav_constants.gd")
const UnitDeathSequenceScript := preload("res://scripts/units/unit_death_sequence.gd")
const UnitShaderFxScript := preload("res://scripts/units/unit_shader_fx.gd")
const CombatTargetAcquisitionScript := preload(
	"res://scripts/combat/combat_target_acquisition.gd"
)
static var _definition_catalog := UnitSceneCatalogScript.shared()

signal owner_changed(player_id: int)
signal navigation_enemy_encountered(enemies: Array[Node3D])
signal deployment_animation_finished
signal attack_order_changed(active: bool, target: Variant)
signal weapon_fired(projectiles: Array, target: Variant, weapon_index: int)

const PlayerDataScript := preload("res://scripts/players/player_data.gd")
const SelectionHaloScript := preload("res://scripts/ui/selection_halo.gd")

const COLLISION_OBJECT_NAME := "#~~0"
## The incidental Tleilaxu walker predates the Mech rule used by the three
## playable House walkers, but its converted model has the same articulated
## leg hierarchy and must retain a level gameplay root as well.
const LEGACY_WALKER_UNIT_IDS: Array[StringName] = [&"INTLWalker"]
## Rules.txt stores TurnRate in radians per movement update. Navigation runs at
## 20 fixed updates per second, so use the same cadence for the unmanaged
## fallback to keep turning independent of the caller's frame rate.
const RULE_MOVEMENT_UPDATES_PER_SECOND := UnitTerrainAlignmentScript.MOVEMENT_UPDATES_PER_SECOND
## Converted XBF tracks use a 20 Hz timeline, while the original firing
## cadence measured from ReloadCount and Fire clip frame counts is 25 Hz.
## Fire clips therefore traverse the baked timeline at 25/20 speed.
const BAKED_MODEL_FRAMES_PER_SECOND := 20.0
const RULE_COMBAT_TICKS_PER_SECOND := CombatRulesScript.TICKS_PER_SECOND
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
var _shader_fx := UnitShaderFxScript.new()
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
var _terrain_alignment := UnitTerrainAlignmentScript.new()
var _uses_mech_gait := false
var _mech_gait_elapsed := 0.0
var _mech_motion_profile: Array[Dictionary] = []
var _mech_authored_average_speed := 0.0
var _mech_motion_cycle_seconds := DEFAULT_MECH_MOVE_CYCLE_SECONDS
var _mech_locomotion_state := MechLocomotionState.IDLE
var _mech_start_remaining := 0.0
var _flight_controller: UnitFlightController = null
var _death_sequence := UnitDeathSequenceScript.new()
## Not `velocity`: navigation_step() zeroes its vertical component, and
## UnitFlightController writes global_position directly, bypassing velocity
## entirely during takeoff/landing. Updated at the top of every
## _physics_process call (see the comment there) so it always holds the
## unit's position at the start of the most recent physics step, regardless
## of which movement path is active.
var _previous_global_position := Vector3.ZERO
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
## Test-only compatibility property: tests/combat/run.gd reads this by name.
@warning_ignore("unused_private_class_variable")
var _fire_sequence_active: bool:
	get:
		return not _weapon_fire_sequences.is_empty()
## Weapon-indexed state keeps multi-turret vehicles independent. It remains on
## Unit because combat tests intentionally inject sequence state directly.
var _weapon_fire_sequences: Dictionary = {}
var _authored_fire_controller = AuthoredFireControllerScript.new()
var _weapon_targets: Dictionary = {}
var _target_acquisition := CombatTargetAcquisitionScript.new()
var _moving_fire_weapons: Dictionary = {}
var _weapon_can_fire_while_moving: Dictionary = {}
var _weapon_fire_overlays: Dictionary = {}


## Modules that hold no tree state are bound here rather than in _ready(), so
## they also work on a unit whose _ready() is stubbed out (see the harvester
## suite's TestHarvester) and before the node enters the tree.
func _init() -> void:
	_terrain_alignment.configure(self)
	_death_sequence.configure(self)
	_shader_fx.configure(self)
	_target_acquisition.configure(self)


func _ready() -> void:
	if not _authored_fire_controller.weapon_fired.is_connected(
		_on_authored_weapon_fired
	):
		_authored_fire_controller.weapon_fired.connect(_on_authored_weapon_fired)
	# The authored rest pose only exists once visual_root has resolved.
	_terrain_alignment.capture_rest_pose()
	_apply_unit_definition()
	target_position = global_position
	_previous_global_position = global_position
	# Terrain height is sampled explicitly below. Letting CharacterBody collide
	# with the terrain mesh makes each triangle edge behave like a small wall,
	# which prevents units from climbing otherwise traversable slopes. The
	# collision layer remains enabled, so mouse rays can still select this unit.
	collision_mask = 0
	_add_authored_collision()
	_shader_fx.attach_model()
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
	_target_acquisition.advance(delta)
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
	_shader_fx.advance(delta, shields)


func _physics_process(delta: float) -> void:
	# Captured before this frame's movement runs, so by the time anything
	# reads it later (death momentum, see _begin_death_sequence) it holds
	# "position at the start of the most recent physics step" — equivalent to
	# updating it at the end of the previous call, but without duplicating
	# the assignment above every early return below.
	_previous_global_position = global_position
	if _flight_controller != null and _flight_controller.flight_controls_transition():
		_flight_controller.advance(delta)
		return
	if is_deploying():
		velocity = Vector3.ZERO
		if _deployment_aligning:
			if _turn_toward(_deployment_alignment_direction, delta):
				_deployment_aligning = false
				_terrain_alignment.refresh_slope_target()
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
		_navigation_system.command_move([self], world_position, NavConstantsScript.MoveMode.FREE, exit_point)
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
func flight_request_land(landing_position: Vector3, allowed_cells: Dictionary = {}) -> bool:
	return _flight_controller != null and _flight_controller.flight_request_land(landing_position, allowed_cells)


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


## Narrow public surface used by UnitFlightController. Keeping these details
## on Unit preserves its ownership of terrain and presentation state without
## making the controller reach through to private implementation methods.
func flight_set_movement_animation(is_moving: bool) -> void:
	_set_movement_animation(is_moving)


func flight_snap_to_terrain() -> void:
	_terrain_snap_body()


func flight_set_visual_slope_target(terrain_normal: Vector3) -> void:
	_set_visual_slope_target(terrain_normal)


func flight_terrain_hit_at(position: Vector3) -> Dictionary:
	return _terrain_hit_at(position)


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
	var model_root := AuthoredFireControllerScript.find_xbf_motion_root(visual_root)
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


func _terrain_snap_body() -> void:
	_terrain_alignment.snap_body_to_terrain()


## Test-only shim: tests/match/demo_boot_run.gd calls this by name. Not
## architecture — the state lives in UnitTerrainAlignment.
func _set_visual_slope_target(terrain_normal: Vector3) -> void:
	_terrain_alignment.set_slope_target(terrain_normal)


## Test-only shim: tests/match/demo_boot_run.gd calls this by name.
func _advance_visual_slope_alignment(delta: float) -> void:
	_terrain_alignment.advance_slope_alignment(delta)


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
	return _terrain_alignment.slope_speed_multiplier(direction, delta)


## Kept on the facade for Harvester (harvester.gd:376) and
## tests/match/demo_boot_run.gd, both of which call it by name.
func _turn_toward(direction: Vector3, delta: float) -> bool:
	return _terrain_alignment.turn_toward(direction, delta)


func facing_direction() -> Vector3:
	return SpatialOrientationScript.world_forward(self)


func face_direction(direction: Vector3) -> void:
	var current_yaw := global_rotation.y if is_inside_tree() else rotation.y
	var target_yaw := SpatialOrientationScript.yaw_facing(direction, current_yaw)
	if is_inside_tree():
		global_rotation.y = target_yaw
		# Yaw moved, so the model's slope tilt is re-derived from the same
		# terrain normal rather than waiting for the next terrain sample.
		_terrain_alignment.refresh_slope_target()
	else:
		rotation.y = target_yaw


func _terrain_hit_at(position: Vector3) -> Dictionary:
	return _terrain_alignment.terrain_hit_at(position)


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
	_terrain_alignment.refresh_slope_target()


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
	_shader_fx.attach_model()
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


func take_damage(amount: float, death_cause: StringName = &"") -> void:
	# The arithmetic is shared with Building.take_damage(); applying it is not,
	# because the health/shields setters here run unit-specific side effects.
	var outcome := DamagePolicyScript.resolve(amount, health, shields, invulnerable)
	if outcome.absorbed_by_shields > 0.0:
		shields -= outcome.absorbed_by_shields
	if outcome.health_delta == 0.0:
		return
	health += outcome.health_delta
	if outcome.is_lethal:
		_begin_death_sequence(death_cause)


func combat_armour_type() -> StringName:
	return armour_type


func combat_is_airborne() -> bool:
	return unit_definition != null and unit_definition.can_fly


## Entry point kept on the facade: take_damage() calls it, and the surrounding
## docs (death_corpse.gd, unit_death_strategy.gd) name it. Everything it used
## to do lives in UnitDeathSequence; _previous_global_position is the facade's
## own bookkeeping and is handed over by value.
func _begin_death_sequence(cause: StringName) -> void:
	_death_sequence.begin(cause, _previous_global_position)


## Scrubs the runtime state Unit bound onto the model subtree before handing
## it to the corpse: an unbound combat turret, a lit shield/scroll-fx mesh or
## a leftover fire-overlay AnimationPlayer would otherwise keep acting like a
## live unit under the corpse's ownership.
##
## THIS IS THE HANDOFF NEUTRALIZATION STEP. queue_free() does not stop the
## rest of this frame's ticks or signal emissions — cdc79b6 and 2b745b2 were
## the same defect (a "dead" unit still running code that reaches into a
## subtree it no longer owns) caught at two different symptom sites. Rather
## than trust that every future caching site gets remembered by hand, this
## function is the single place that must be extended whenever a new field
## caches a reference into `model`'s subtree, or a new signal gets connected
## onto one of its nodes: everything below is redundant with
## tests/units/death_animation_run.gd's reflection-based invariant test,
## which walks this instance's own script variables after a death and fails
## if anything still points at a node under the corpse — so forgetting an
## entry here fails loudly in that test rather than regressing silently.
func prepare_model_for_corpse(model: Node3D) -> void:
	# Must run before any overlay player is freed below: a fire sequence's
	# state dict can still hold that same player in state["player"], and
	# freeing it out from under a live entry leaves a dangling reference that
	# _exit_tree()'s teardown (_cancel_all_fire_sequences) would later cast.
	# restore_idle=false because the unit is being discarded this frame, same
	# as every other pre-teardown call site (setup(), replace_visual_scene()).
	_cancel_all_fire_sequences(false)
	for turret in combat_turrets:
		turret.unbind_model()
	_shader_fx.detach_model()
	for overlay_value: Variant in _weapon_fire_overlays.values():
		if is_instance_valid(overlay_value):
			(overlay_value as Node).free()
	_weapon_fire_overlays.clear()
	# Generic: disconnect every signal connection THIS unit made onto `model`
	# or any of its descendants, regardless of which signal or when it was
	# connected. This is what closes _prepare_idle_animations()'s
	# `player.animation_finished.connect(_on_animation_finished.bind(player))`
	# (the connection lives on the AnimationPlayer node handed to the corpse,
	# not on this Unit, so clearing _animation_players below never touched
	# it) without needing to know the exact signal/callable shape, and
	# without needing to be revisited if a future change adds another
	# connection onto a model node.
	_sever_connections_into(model)
	# The model subtree (and every AnimationPlayer/mesh inside it) now belongs
	# to the corpse. Direct references into it must be dropped too — a signal
	# disconnect alone does not help a plain field that some other code path
	# reads without going through a signal.
	_animation_players.clear()
	# _deployment_animation_player is populated straight from
	# _animation_players (_start_deployment_animation(), line ~2408) but,
	# unlike _animation_players itself, is a scalar field that keeps pointing
	# at that same model AnimationPlayer until explicitly cleared — nothing
	# else resets it on death, so a unit killed while deploying kept a live
	# direct pointer into the corpse's subtree here. This is the newly-found
	# third site in the same class as cdc79b6/2b745b2.
	_deployment_animation_player = null
	_deployment_animation_name = &""
	# Reachable only via _on_animation_finished (now unreachable, see above),
	# but nulled anyway so nothing can call back into it and so it no longer
	# holds this Unit and one of the corpse's players alive together.
	_flight_controller = null
	# queue_free() does not stop this frame's remaining _process()/
	# _physics_process() calls, so without halting processing here, a still-
	# pending tick (e.g. a blocking fire sequence's was_blocking branch in
	# _finish_fire_sequence_for calling _set_movement_animation) can still
	# run this frame and try to act on a unit that has already given
	# everything away.
	set_process(false)
	set_physics_process(false)


## Disconnects every signal connection this Unit made onto `subtree_root` or
## any of its descendants. Generic on purpose: rather than track down each
## individual `.connect()` call site that targets a model node (today just
## _prepare_idle_animations()'s animation_finished hookup, but nothing stops
## a future change from adding another), this walks every signal already
## live on the subtree at handoff time and drops any connection whose
## callable belongs to `self`. Connections other objects made onto these
## nodes (e.g. DeathCorpse's own animation_finished hookup, added after this
## runs) are left untouched.
func _sever_connections_into(subtree_root: Node) -> void:
	var stack: Array[Node] = [subtree_root]
	while not stack.is_empty():
		var node := stack.pop_back() as Node
		for child in node.get_children():
			stack.append(child)
		for signal_info: Dictionary in node.get_signal_list():
			var signal_name := StringName(signal_info.get("name", &""))
			for connection: Dictionary in node.get_signal_connection_list(signal_name):
				var callable := connection.get("callable") as Callable
				if callable.get_object() == self:
					node.disconnect(signal_name, callable)


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
	_target_acquisition.clear()
	_moving_fire_weapons.clear()
	for turret in _active_turrets():
		if turret.can_target(target_or_position):
			_set_weapon_target(turret.weapon_index(), target_or_position)
	attack_order_changed.emit(true, target_or_position)
	return true


func cancel_attack_order() -> void:
	_cancel_all_fire_sequences()
	_weapon_targets.clear()
	_target_acquisition.clear()
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
	_target_acquisition.clear()
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
	var obstructed_turrets: Array = []
	for turret in _active_turrets():
		if turret.target_range(attack_target) != CombatTurretScript.TargetRange.IN_RANGE:
			continue
		if turret.has_line_of_fire(attack_target, self):
			in_range_turrets.append(turret)
		else:
			obstructed_turrets.append(turret)
	if in_range_turrets.is_empty():
		_recenter_unengaged_turrets([], delta)
		# A blocked line is solved the same way as a distant target: keep closing
		# until the cliff shoulder or building no longer covers it. Firing from
		# here would only damage the obstacle standing in front of the order.
		if not obstructed_turrets.is_empty() \
		or primary_turret.target_range(attack_target) == CombatTurretScript.TargetRange.TOO_FAR:
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
			else _target_acquisition.target_for(turret)
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
			_target_acquisition.forget(weapon_index)
			retained_target = null
		var turret_target: Variant = null
		if retained_target != null:
			var target_world_position := _combat_target_position(retained_target)
			if (
				turret.target_range(retained_target)
					== CombatTurretScript.TargetRange.IN_RANGE
				and not turret.requires_hull_turn_for(target_world_position)
				and turret.has_line_of_fire(retained_target, self)
			):
				turret_target = retained_target
		if turret_target == null and autonomous:
			turret_target = _target_acquisition.target_for(turret)
		if not _advance_turret_engagement(turret, turret_target, delta):
			_recenter_turret_if_idle(turret, delta)


func _advance_turret_engagement(
	turret, target: Variant, delta: float, aimed_override: Variant = null
	) -> bool:
	if turret == null or target == null:
		return false
	var target_world_position := _combat_target_position(target)
	if not target_world_position.is_finite() \
	or turret.target_range(target) != CombatTurretScript.TargetRange.IN_RANGE:
		return false
	var aimed := bool(aimed_override) if aimed_override is bool \
		else bool(turret.aim_at(target_world_position, delta))
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
	return _authored_fire_controller.start_sequence(
		_weapon_fire_sequences,
		turret,
		attack_target,
		playback_player,
		animation_name,
		animation,
		_authored_fire_shot_times(player, animation, turret, animation_name),
		not can_fire_moving,
		_reload_starts_after_fire_animation(),
		_restore_combat_turret_poses
	)


func _advance_fire_sequences(delta: float) -> void:
	var restore_idle := _authored_fire_controller.advance_sequences(
		_weapon_fire_sequences, delta, self, _reload_starts_after_fire_animation()
	)
	if restore_idle and not _movement_animation_active:
		_set_movement_animation(false)


func _on_authored_weapon_fired(
	projectiles: Array, target: Variant, weapon_index: int
	) -> void:
	weapon_fired.emit(projectiles, target, weapon_index)


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
	var restore_idle := _authored_fire_controller.finish_sequence(
		_weapon_fire_sequences, weapon_index, _reload_starts_after_fire_animation()
	)
	if restore_idle and not _movement_animation_active:
		_set_movement_animation(false)


func _cancel_all_fire_sequences(restore_idle := true) -> void:
	var had_blocking := _authored_fire_controller.cancel_sequences(
		_weapon_fire_sequences, _reload_starts_after_fire_animation()
	)
	if restore_idle and had_blocking:
		_set_movement_animation(false)


func _has_blocking_fire_sequence() -> bool:
	return _authored_fire_controller.has_blocking_sequence(
		_weapon_fire_sequences
	)


func _cancel_blocking_fire_sequences() -> void:
	_authored_fire_controller.cancel_sequences(
		_weapon_fire_sequences,
		_reload_starts_after_fire_animation(),
		true,
		false
	)


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
	## Test-only shim: tests/combat/run.gd calls this by name. Not architecture.
	return AuthoredFireControllerScript.authored_fire_shot_times(
		player, animation, turret, visual_root, animation_name
	)


func _xbf_fire_shot_times(
	animation_name: StringName, animation: Animation, turret
	) -> Array[float]:
	## Test-only shim: tests/combat/run.gd calls this by name. Not architecture.
	return AuthoredFireControllerScript.xbf_fire_shot_times(
		animation_name, animation, turret, visual_root
	)


func _primary_attack_turret(attack_target: Variant):
	for turret in _active_turrets():
		if turret.can_target(attack_target):
			return turret
	return null


## Accepts only perches whose muzzle would see the ordered target. The probe
## samples terrain height at the candidate because navigation cells carry the
## map floor rather than the elevation the unit will actually stand at.
func _line_of_fire_probe(primary_turret) -> Callable:
	var target: Variant = attack_order_target()
	if primary_turret == null or target == null:
		return Callable()
	var muzzle_origin: Vector3 = primary_turret.muzzle_origin()
	var muzzle_height := maxf(muzzle_origin.y - global_position.y, 0.0) \
		if muzzle_origin.is_finite() else 0.0
	return func(candidate: Vector3) -> bool:
		var hit := _terrain_hit_at(candidate)
		var ground: Vector3 = hit["position"] if not hit.is_empty() else candidate
		return primary_turret.has_line_of_fire_from(
			ground + Vector3.UP * muzzle_height, target, self
		)


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
		var maximum_range := float(primary_turret.maximum_range_world())
		reachable_position = _navigation_system.call(
			"reachable_attack_position",
			self,
			target_world_position,
			maximum_range,
			_line_of_fire_probe(primary_turret)
		)
		if not reachable_position.is_finite():
			var any_perch: Vector3 = _navigation_system.call(
				"reachable_attack_position", self, target_world_position, maximum_range
			)
			if any_perch.is_finite():
				# The search covered every reachable cell within weapon range and
				# none of them can see the target: the obstacle shields it from
				# this side entirely. Hold instead of grinding into it.
				stop_at_current_position()
				_attack_is_pursuing = false
				_attack_pursuit_destination = Vector3.INF
				return
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
			[self], pursuit_position, NavConstantsScript.MoveMode.FREE
		)
		move_issued = not assignments.is_empty()
	else:
		move_to(pursuit_position)
	_issuing_attack_move = false
	_attack_pursuit_rejected = not move_issued
	_attack_is_pursuing = move_issued


func _combat_target_position(attack_target: Variant) -> Vector3:
	return CombatTargetScript.position_of(attack_target, global_position)


func _combat_target_is_alive(attack_target: Variant) -> bool:
	return CombatTargetScript.is_alive(attack_target)


func stop_at_current_position() -> void:
	if _navigation_managed and _navigation_system != null:
		_navigation_system.stop(self)
	target_position = global_position
	velocity = Vector3.ZERO
	_set_navigation_debug_direction(Vector3.ZERO)
	_set_movement_animation(false)


## Shared Stop-command contract. Subclasses with additional order state
## override this, clear their own state, and then call super.
func cancel_all_orders() -> bool:
	var had_order := (
		_has_attack_order
		or _has_pending_navigation_order
		or _mech_has_active_move_order()
	)
	if not had_order:
		return false
	cancel_attack_order()
	_has_pending_navigation_order = false
	_pending_navigation_order = Vector3.ZERO
	_pending_navigation_exit = Vector3.INF
	stop_at_current_position()
	return had_order


## Shared unit deployment interface. Eligibility and the per-unit strategy
## live in UnitDeploymentController; Unit owns the common locked alignment and
## animation phases so future deployable units can reuse the same contract.
func deploy(desired_facing: Vector3 = Vector3.ZERO) -> bool:
	if _deploy_state != DeployState.TRAVEL:
		return false
	_deploy_state = DeployState.DEPLOYING
	_sync_active_turret_weapons()
	stop_at_current_position()
	if _navigation_system != null and _navigation_system.has_method("set_hold_position"):
		_navigation_system.call("set_hold_position", self, true)

	_deployment_alignment_direction = Vector3(
		desired_facing.x, 0.0, desired_facing.z
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
	var found := find_animation_clip(candidates)
	_deployment_animation_player = found.get("player") as AnimationPlayer
	_deployment_animation_name = StringName(found.get("name", &""))

	if _deployment_animation_player == null:
		call_deferred("_emit_deployment_animation_finished")
		return

	var animation := _deployment_animation_player.get_animation(_deployment_animation_name)
	if animation != null:
		animation.loop_mode = Animation.LOOP_NONE
	_deployment_animation_player.stop()
	_deployment_animation_player.play(_deployment_animation_name)


## Shared "first player owning one of these candidate clips" scan, in
## candidate-preference order. Used by both deployment transitions and death
## animation selection (_begin_death_sequence) so the two don't drift apart.
func find_animation_clip(candidates: Array[StringName]) -> Dictionary:
	return AuthoredModelScript.find_clip(_animation_players, candidates)


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
		_target_acquisition.forget(weapon_index)
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
	return EntityQueryScript.owner_player(self, _players())


func is_neutral_owner() -> bool:
	return owner_player_id == PlayerDataScript.NEUTRAL_PLAYER_ID


func is_owned_by(player_id: int) -> bool:
	return EntityQueryScript.is_owned_by(self, player_id)


func is_allied_with(player_id: int) -> bool:
	return EntityQueryScript.is_allied_with(self, player_id, _players())


func is_enemy_of(player_id: int) -> bool:
	return EntityQueryScript.is_enemy_of(self, player_id, _players())


func _refresh_shield_visibility() -> void:
	_shader_fx.refresh_shield_visibility(shields)


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
	_death_sequence.adopt_definition(unit_definition)
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


func _collect_animation_players() -> Array[AnimationPlayer]:
	return AuthoredModelScript.animation_players(visual_root)


func weapon_can_fire_while_moving(weapon_index: int) -> bool:
	return bool(_weapon_can_fire_while_moving.get(weapon_index, false))


func _refresh_weapon_runtime() -> void:
	for overlay_value: Variant in _weapon_fire_overlays.values():
		if is_instance_valid(overlay_value) and overlay_value is AnimationPlayer:
			(overlay_value as AnimationPlayer).queue_free()
	_weapon_fire_overlays.clear()
	_weapon_can_fire_while_moving.clear()
	_weapon_targets.clear()
	_target_acquisition.clear()
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
	# Keep the outgoing pose while stopping so its first-frame effects are not
	# exposed, then apply the incoming transform pose immediately. Waiting for
	# the next AnimationPlayer tick leaves a one-frame hybrid of the outgoing
	# pose and incoming playback state (notably Kobra's vertical barrel at both
	# boundaries of its horizontal travel-mode Fire clips).
	player.stop(true)
	player.play(animation_name)
	_apply_animation_start_transforms(player, animation_name)
	_restore_combat_turret_poses()


func _apply_animation_start_transforms(
	player: AnimationPlayer, animation_name: StringName
) -> void:
	var animation := player.get_animation(animation_name)
	if animation == null:
		return
	for track in animation.get_track_count():
		if animation.track_get_type(track) != Animation.TYPE_VALUE \
		or not String(animation.track_get_path(track)).ends_with(":transform") \
		or animation.track_get_key_count(track) == 0 \
		or animation.track_get_key_time(track, 0) > FIRE_EVENT_EPSILON:
			continue
		var target := _animation_track_node(
			player, String(animation.track_get_path(track))
		) as Node3D
		var value: Variant = animation.track_get_key_value(track, 0)
		if target != null and value is Transform3D:
			target.transform = value as Transform3D


func _restore_combat_turret_poses() -> void:
	# An inactive deploy-state turret shares authored pivots with the active
	# model pose but must not write its own rest transform over that animation.
	for turret in _active_turrets():
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
	var fire_finish_result: int = _authored_fire_controller.finish_animation(
		_weapon_fire_sequences,
		player,
		animation_name,
		self,
		_reload_starts_after_fire_animation()
	)
	if fire_finish_result > 0:
		if fire_finish_result == 2 and not _movement_animation_active:
			_set_movement_animation(false)
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
	TeamColorScript.apply(visual_root, _owner_team_color())


func _owner_team_color() -> Color:
	return TeamColorScript.color_for(owner_player(), Color(0.2, 0.85, 1.0))


func _players():
	return AutoloadLookupScript.roster(self)


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
	return AuthoredModelScript.collision_sources(visual_root, [
		{"name": COLLISION_OBJECT_NAME, "prefix": false},
		{"name": "slct", "prefix": true},
	])


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
	var anchor := SelectionHaloBindingScript.anchor(visual_root)
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
	return SelectionHaloBindingScript.radius(visual_root, self)


func _selection_position() -> Vector3:
	return SelectionHaloBindingScript.position(visual_root, self)


func _selection_bounds() -> AABB:
	return AuthoredModelScript.selection_bounds(visual_root, self)


func _halo_anchor_node(node: Node) -> Node3D:
	return SelectionHaloBindingScript.anchor(node)


func _aabb_corners(bounds: AABB) -> Array[Vector3]:
	var corners: Array[Vector3] = []
	for x in [bounds.position.x, bounds.end.x]:
		for y in [bounds.position.y, bounds.end.y]:
			for z in [bounds.position.z, bounds.end.z]:
				corners.append(Vector3(x, y, z))
	return corners
