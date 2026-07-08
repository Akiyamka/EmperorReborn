class_name RTSBuilding
extends Node3D

@export var default_state := &"idle"

var current_state := &""


func _ready() -> void:
	play_state(default_state)


func play_state(state: StringName) -> void:
	current_state = state
	var player := get_node_or_null("StatePlayer") as AnimationPlayer
	if player != null and player.has_animation(state):
		player.play(state)
		return

	var states := get_node_or_null("States")
	if states == null:
		return

	for child in states.get_children():
		var child_state := StringName(String(child.get_meta("state", child.name.to_lower())))
		child.visible = child_state == state
