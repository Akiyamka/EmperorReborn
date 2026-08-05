class_name UnitIdleAnimations
extends RefCounted

## Picks what a standing unit plays: the authored Stationary clip repeated a
## random number of times, then a weighted random Idle_* variation, then back
## to Stationary. Deployed units run the same machine over their
## Deployed_Idle_* set, or hold the braced Deploy_Gun_Hold pose when the model
## authored no deployed idle at all.
##
## Caches no model nodes: the per-player repeat counters are keyed by instance
## id, and every entry point receives the AnimationPlayer to act on. A model
## swap therefore only leaves stale integer keys behind, which reset() drops.

const IDLE_ANIMATION := &"Stationary"
const IDLE_ANIMATION_PREFIX := "Idle"
const DEPLOYED_IDLE_ANIMATION_PREFIX := "Deployed_Idle"
const DEPLOYED_HOLD_ANIMATION := &"Deploy_Gun_Hold"

var _unit: CharacterBody3D
var _stationary_repeats_remaining: Dictionary = {}


func configure(unit: CharacterBody3D) -> void:
	_unit = unit


func dispose() -> void:
	reset()
	_unit = null


func reset() -> void:
	_stationary_repeats_remaining.clear()


## Loop modes for the clips this machine chains. Each one must end so
## animation_finished can pick the next; only the deployed hold pose loops,
## and that is set where it is played.
func prepare(player: AnimationPlayer) -> void:
	var idle_animations := animations_for(player)
	for animation_name in idle_animations:
		var animation := player.get_animation(animation_name)
		if animation != null:
			animation.loop_mode = Animation.LOOP_NONE
	if not idle_animations.is_empty() and player.has_animation(IDLE_ANIMATION):
		var stationary := player.get_animation(IDLE_ANIMATION)
		if stationary != null:
			stationary.loop_mode = Animation.LOOP_NONE


## The undeploy leg briefly re-evaluates idle animation while UnitDeployState
## turns the turret back to hull-aligned (see begin_undeploy()'s turret-
## recenter gate) before the Undeploy_Gun clip actually starts. Treating
## is_undeploying() the same as is_deployed() here keeps the model on its
## deployed idle/hold pose through that gate instead of flashing to the
## travel-mode Stationary pose and back.
func _shows_deployed_pose() -> bool:
	return _unit.is_deployed() or _unit.is_undeploying()


func animations_for(player: AnimationPlayer) -> Array[StringName]:
	var prefix := DEPLOYED_IDLE_ANIMATION_PREFIX if _shows_deployed_pose() \
		else IDLE_ANIMATION_PREFIX
	var result: Array[StringName] = []
	for animation_name in player.get_animation_list():
		if String(animation_name).begins_with(prefix):
			result.append(animation_name)
	return result


func play_sequence(player: AnimationPlayer) -> void:
	var idle_animations := animations_for(player)
	if idle_animations.is_empty():
		if _shows_deployed_pose() and player.has_animation(DEPLOYED_HOLD_ANIMATION):
			_hold_deployed_pose(player)
			return
		if player.has_animation(IDLE_ANIMATION) and player.current_animation != IDLE_ANIMATION:
			player.play(IDLE_ANIMATION)
		return

	var player_id := player.get_instance_id()
	var is_sequence_animation := player.current_animation == IDLE_ANIMATION \
		or player.current_animation in idle_animations
	if is_sequence_animation and player.is_playing() \
	and _stationary_repeats_remaining.has(player_id):
		return
	_start_stationary_batch(player, idle_animations)


## Continues the chain when one of its clips ends. Returns false if the
## finished clip has nothing to do with idling, so the facade's dispatcher can
## keep looking.
func on_animation_finished(animation_name: StringName, player: AnimationPlayer) -> bool:
	var idle_animations := animations_for(player)
	if idle_animations.is_empty():
		return false
	var player_id := player.get_instance_id()
	if animation_name == IDLE_ANIMATION:
		var repeats_left := int(_stationary_repeats_remaining.get(player_id, 1)) - 1
		_stationary_repeats_remaining[player_id] = repeats_left
		if repeats_left > 0:
			_unit.play_animation_from_start(player, IDLE_ANIMATION)
		else:
			_play_random_idle(player, idle_animations)
		return true
	if animation_name in idle_animations:
		_start_stationary_batch(player, idle_animations)
		return true
	return false


## Weight of one Idle_N variation: the plain authored order is a preference
## order, so Idle_0 shows up more often than Idle_1 and so on.
func weight_of(animation_name: StringName) -> float:
	var suffix := String(animation_name).trim_prefix(IDLE_ANIMATION_PREFIX).trim_prefix("_")
	if not suffix.is_valid_int():
		return 1.0
	return 1.0 / float(maxi(int(suffix), 0) + 1)


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
	_unit.restore_combat_turret_poses()


func _start_stationary_batch(
	player: AnimationPlayer, idle_animations: Array[StringName]
) -> void:
	var player_id := player.get_instance_id()
	# A deployed unit must only ever consider its Deployed_Idle_* clips here:
	# a literal "Stationary" clip on the same model belongs to travel mode.
	if not _shows_deployed_pose() and player.has_animation(IDLE_ANIMATION):
		_stationary_repeats_remaining[player_id] = randi_range(5, 15)
		_unit.play_animation_from_start(player, IDLE_ANIMATION)
		return
	_stationary_repeats_remaining[player_id] = 0
	_play_random_idle(player, idle_animations)


func _play_random_idle(
	player: AnimationPlayer, idle_animations: Array[StringName]
) -> void:
	var total_weight := 0.0
	for animation_name in idle_animations:
		total_weight += weight_of(animation_name)

	var roll := randf() * total_weight
	for animation_name in idle_animations:
		roll -= weight_of(animation_name)
		if roll <= 0.0:
			_unit.play_animation_from_start(player, animation_name)
			return
	_unit.play_animation_from_start(player, idle_animations.back())
