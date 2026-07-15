class_name PanelTab
extends Button
## Tab button for the side panel with the four RTS tab states.
## ACTIVE is normally driven by the panel's ButtonGroup; DISABLED and
## BLINKING are set externally (e.g. production finished -> blinking).

enum State { REGULAR, DISABLED, ACTIVE, BLINKING }

const BLINK_PERIOD := 0.8
const BLINK_COLOR := Color(1.6, 1.4, 0.7)

var state: State = State.REGULAR:
	set = set_state

var _blink_time := 0.0


func _init() -> void:
	toggle_mode = true
	# Tabs are mouse-driven; arrow keys are reserved for camera movement.
	focus_mode = Control.FOCUS_NONE
	set_process(false)


func set_state(value: State) -> void:
	state = value
	disabled = state == State.DISABLED
	set_pressed_no_signal(state == State.ACTIVE)
	_blink_time = 0.0
	set_process(state == State.BLINKING)
	if state != State.BLINKING:
		self_modulate = Color.WHITE


func _process(delta: float) -> void:
	_blink_time += delta
	var pulse := 0.5 + 0.5 * sin(_blink_time * TAU / BLINK_PERIOD)
	self_modulate = Color.WHITE.lerp(BLINK_COLOR, pulse)
