class_name UnitDeployState
extends RefCounted

## The deploy/undeploy state machine shared by every deployable unit: the
## locked alignment turn, the authored transition clip, and the four states
## around them. Eligibility and the per-unit strategy stay in
## UnitDeploymentController; what a deploying unit *is* lives here.
##
## MCV deploy (TRAVEL -> DEPLOYING -> [consumed: unit freed]) uses only the
## first half of this machine. Combat deploy (Kindjal/Mortar/Kobra) uses all
## four states, toggling DEPLOYED <-> TRAVEL through DEPLOYING/UNDEPLOYING.
##
## Caches the model's transition AnimationPlayer, so it implements the
## attach/detach protocol; detach_model() is idempotent because a unit killed
## mid-deploy runs the corpse handoff and then _exit_tree() as well.

const SpatialOrientationScript := preload("res://scripts/world/spatial_orientation.gd")

## The original MCV model has no clip literally named Deploy. Move_Stop is its
## authored transition from driving to a braced stationary pose and is the
## source-backed fallback for the first phase of deployment. Deploy_Gun is the
## authored clip for the combat-deploy strategy (Kindjal/Mortar/Kobra); it is
## first so those units resolve it before ever reaching the MCV fallback.
const DEPLOY_ANIMATION_CANDIDATES: Array[StringName] = [
	&"Deploy_Gun", &"Deploy", &"Deploying", &"Unpack", &"Move_Stop"
]
## Undeploy has no MCV-side authored clip at all (the Construction Yard's own
## Deconstruct animation handles that transformation instead), so this list
## only ever resolves for the combat-deploy strategy.
const UNDEPLOY_ANIMATION_CANDIDATES: Array[StringName] = [
	&"Undeploy_Gun", &"Undeploy", &"Undeploying"
]

enum State {
	TRAVEL,
	DEPLOYING,
	DEPLOYED,
	UNDEPLOYING,
}

var _unit: CharacterBody3D
var _state := State.TRAVEL
var _aligning := false
var _alignment_direction := Vector3.ZERO
var _transition_player: AnimationPlayer
var _transition_animation: StringName = &""


func configure(unit: CharacterBody3D) -> void:
	_unit = unit


func detach_model() -> void:
	_transition_player = null
	_transition_animation = &""


func dispose() -> void:
	detach_model()
	_unit = null


## Both transition directions count as "deploying" for every gameplay lock: a
## unit is equally immobile while folding out and while folding back in.
func is_transitioning() -> bool:
	return _state == State.DEPLOYING or _state == State.UNDEPLOYING


## Stationary combat mode (Kindjal/Mortar/Kobra). Never true for the MCV,
## which has no DEPLOYED state of its own: a successful deploy consumes it
## into a Construction Yard instead.
func is_deployed() -> bool:
	return _state == State.DEPLOYED


## Read accessor for the cached transition player. Production never needs it;
## tests/units/death_animation_run.gd does, to assert the corpse handoff drops
## exactly this kind of reference.
func transition_player() -> AnimationPlayer:
	return _transition_player


func begin_deploy(desired_facing: Vector3) -> bool:
	if _state != State.TRAVEL:
		return false
	_state = State.DEPLOYING
	_unit.sync_active_turret_weapons()
	_unit.stop_at_current_position()
	_unit.set_navigation_hold(true)

	_alignment_direction = Vector3(desired_facing.x, 0.0, desired_facing.z)
	_aligning = (
		_alignment_direction.length_squared() > SpatialOrientationScript.DIRECTION_EPSILON
		and not _unit.turn_toward(_alignment_direction, 0.0)
	)
	if _aligning and float(_unit.turn_rate) > 0.0:
		_alignment_direction = _alignment_direction.normalized()
		return true
	if _aligning:
		# A deployable unit without an authored turn rate cannot complete a
		# gradual alignment, so preserve the generic deployment contract.
		_unit.face_direction(_alignment_direction)
		_aligning = false

	start_transition(DEPLOY_ANIMATION_CANDIDATES)
	return true


## Combat-deploy strategy's toggle-back. The MCV/Construction Yard pair never
## calls this: its "undeploy" is a different unit (the spawned MCV) built by
## UnitDeploymentController's own Deconstruct handling, not a state on the
## same Unit instance.
func begin_undeploy() -> bool:
	if _state != State.DEPLOYED:
		return false
	_state = State.UNDEPLOYING
	_unit.sync_active_turret_weapons()
	_unit.stop_at_current_position()
	_unit.set_navigation_hold(true)
	start_transition(UNDEPLOY_ANIMATION_CANDIDATES)
	return true


## Turns toward the requested facing while the unit is locked in place.
## Returns true on the frame the heading is reached, so the caller can settle
## the visual slope before the transition clip starts.
func advance_alignment(delta: float) -> bool:
	if not _aligning:
		return false
	if not _unit.turn_toward(_alignment_direction, delta):
		return false
	_aligning = false
	return true


func start_deploy_animation() -> void:
	start_transition(DEPLOY_ANIMATION_CANDIDATES)


func start_transition(candidates: Array[StringName]) -> void:
	var found: Dictionary = _unit.find_animation_clip(candidates)
	_transition_player = found.get("player") as AnimationPlayer
	_transition_animation = StringName(found.get("name", &""))

	if _transition_player == null:
		_unit.call_deferred("emit_deployment_animation_finished")
		return

	var animation := _transition_player.get_animation(_transition_animation)
	if animation != null:
		animation.loop_mode = Animation.LOOP_NONE
	_transition_player.stop()
	_transition_player.play(_transition_animation)


## True when the finished clip is the transition this machine is waiting for;
## the facade emits the signal, so subscribers stay attached to the Unit.
func on_animation_finished(animation_name: StringName, player: AnimationPlayer) -> bool:
	return is_transitioning() \
		and player == _transition_player \
		and animation_name == _transition_animation


## The deployment strategy calls this after the animation-to-world handoff.
## `consumed` means the transition completed as intended: for the MCV this is
## true only on a successful Construction Yard placement (the unit is freed
## immediately after by the caller, so the resulting state is moot); for the
## combat strategy it is true whenever deploy()/undeploy() simply run to
## completion, since nothing here is ever destroyed. `false` means the
## transition was aborted (MCV placement failed after the animation already
## played) and must fully unwind back to the state before it started.
## Returns false when there was no transition to finish.
func finish(consumed: bool) -> bool:
	if not is_transitioning():
		return false
	var was_deploying := _state == State.DEPLOYING
	_aligning = false
	_alignment_direction = Vector3.ZERO
	detach_model()
	if consumed:
		_state = State.DEPLOYED if was_deploying else State.TRAVEL
	else:
		_state = State.TRAVEL if was_deploying else State.DEPLOYED
	_unit.sync_active_turret_weapons()
	_unit.set_navigation_hold(is_deployed())
	return true
