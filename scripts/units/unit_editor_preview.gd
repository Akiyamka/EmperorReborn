@tool
extends Node

## Keeps converted unit models in their authored resting pose while a scene is
## viewed in the Godot editor. Runtime Unit owns all animation selection, so
## this node intentionally does nothing outside editor previews.

const STATIONARY_ANIMATION := &"Stationary"
const IDLE_PREFIX := "Idle"


func _ready() -> void:
	if Engine.is_editor_hint():
		call_deferred("_show_resting_pose")


func _show_resting_pose() -> void:
	if not Engine.is_editor_hint():
		return
	var unit_root := get_parent()
	if unit_root == null:
		return
	for player_variant in unit_root.find_children("*", "AnimationPlayer", true, false):
		var player := player_variant as AnimationPlayer
		if player == null:
			continue
		var animation_name := _resting_animation(player)
		if animation_name == &"":
			continue
		player.play(animation_name)
		player.advance(0.0)
		# `play()` keeps the AnimationPlayer processing in the editor even after
		# the requested pose has been applied. Freeze it immediately: the preview
		# only needs a stable authored pose, not a continuously running animation.
		player.pause()


func _resting_animation(player: AnimationPlayer) -> StringName:
	if player.has_animation(STATIONARY_ANIMATION):
		return STATIONARY_ANIMATION
	var names: Array[StringName] = []
	for name_variant in player.get_animation_list():
		var name := StringName(name_variant)
		if String(name).begins_with(IDLE_PREFIX):
			names.append(name)
	names.sort()
	return names.front() if not names.is_empty() else &""
