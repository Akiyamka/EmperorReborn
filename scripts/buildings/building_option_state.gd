class_name BuildingOptionState
extends RefCounted

enum State { AVAILABLE, DISABLED, BLOCKED, PROGRESS, READY }

var building_id: StringName
var state: State
var progress: float
var status_text: String
var tooltip: String


func _init(
		option_building_id: StringName,
		option_state: State,
		option_progress := 0.0,
		option_status_text := "",
		option_tooltip := ""
) -> void:
	building_id = option_building_id
	state = option_state
	progress = clampf(option_progress, 0.0, 100.0)
	status_text = option_status_text
	tooltip = option_tooltip
