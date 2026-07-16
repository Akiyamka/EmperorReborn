extends PanelContainer

const UnitScript := preload("res://scripts/units/unit.gd")
const MechGaitCurveEditorScript := preload("res://scripts/ui/mech_gait_curve_editor.gd")

const FIELD_SPECS: Array[Dictionary] = [
	{
		"key": &"steps_per_cycle",
		"label": "Steps / Move cycle",
		"minimum": 1.0,
		"maximum": 6.0,
		"step": 1.0,
		"tooltip": "Number of repeated gait pulses in one authored Move clip.",
	},
	{
		"key": &"rise_start",
		"label": "Acceleration start",
		"minimum": 0.0,
		"maximum": 1.0,
		"step": 0.01,
		"tooltip": "Normalized phase inside each step where MechSpeed starts blending upward.",
	},
	{
		"key": &"rise_end",
		"label": "Full Speed starts",
		"minimum": 0.0,
		"maximum": 1.0,
		"step": 0.01,
		"tooltip": "Normalized phase where the upward blend reaches ordinary Speed.",
	},
	{
		"key": &"fall_start",
		"label": "Deceleration start",
		"minimum": 0.0,
		"maximum": 1.0,
		"step": 0.01,
		"tooltip": "Normalized phase where ordinary Speed starts blending downward.",
	},
	{
		"key": &"fall_end",
		"label": "MechSpeed starts",
		"minimum": 0.0,
		"maximum": 1.0,
		"step": 0.01,
		"tooltip": "Normalized phase where the downward blend reaches MechSpeed.",
	},
	{
		"key": &"fallback_cycle_seconds",
		"label": "Fallback cycle, sec",
		"minimum": 0.05,
		"maximum": 10.0,
		"step": 0.05,
		"tooltip": "Used only when a mech model has no authored Move animation.",
	},
]

var _controls: Dictionary = {}
var _summary: Label
var _curve_editor: Control
var _refreshing := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(360.0, 0.0)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 10)
	add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	margin.add_child(column)

	var heading := HBoxContainer.new()
	column.add_child(heading)
	var title := Label.new()
	title.text = "MECH GAIT DEBUG"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", 18)
	heading.add_child(title)
	var reset := Button.new()
	reset.text = "Reset"
	reset.tooltip_text = "Restore the defaults from unit.gd."
	reset.pressed.connect(_on_reset_pressed)
	heading.add_child(reset)

	var hint := Label.new()
	hint.text = "Drag green/red points · live for all mechs"
	hint.modulate = Color(0.75, 0.82, 0.9)
	column.add_child(hint)

	var speed_labels := HBoxContainer.new()
	column.add_child(speed_labels)
	var fast_label := Label.new()
	fast_label.text = "Speed"
	fast_label.modulate = Color(1.0, 0.77, 0.2)
	fast_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	speed_labels.add_child(fast_label)
	var phase_label := Label.new()
	phase_label.text = "one step phase 0 → 1"
	phase_label.modulate = Color(0.65, 0.7, 0.78)
	phase_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	speed_labels.add_child(phase_label)

	_curve_editor = MechGaitCurveEditorScript.new()
	_curve_editor.tuning_changed.connect(_on_curve_tuning_changed)
	column.add_child(_curve_editor)
	var slow_label := Label.new()
	slow_label.text = "MechSpeed"
	slow_label.modulate = Color(1.0, 0.77, 0.2)
	column.add_child(slow_label)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 4)
	column.add_child(grid)
	for spec in FIELD_SPECS:
		_add_field(grid, spec)

	_summary = Label.new()
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_summary.modulate = Color(0.86, 0.9, 0.72)
	column.add_child(_summary)
	_refresh_controls()


func _add_field(grid: GridContainer, spec: Dictionary) -> void:
	var label := Label.new()
	label.text = String(spec["label"])
	label.tooltip_text = String(spec["tooltip"])
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(label)

	var control := SpinBox.new()
	control.custom_minimum_size = Vector2(116.0, 0.0)
	control.min_value = float(spec["minimum"])
	control.max_value = float(spec["maximum"])
	control.step = float(spec["step"])
	control.allow_greater = false
	control.allow_lesser = false
	control.update_on_text_changed = true
	control.tooltip_text = String(spec["tooltip"])
	var key: StringName = spec["key"]
	control.value_changed.connect(_on_value_changed.bind(key))
	grid.add_child(control)
	_controls[key] = control


func _on_value_changed(value: float, key: StringName) -> void:
	if _refreshing:
		return
	UnitScript.set_mech_gait_tuning_value(key, value)
	_refresh_controls()


func _on_reset_pressed() -> void:
	UnitScript.reset_mech_gait_tuning()
	_refresh_controls()


func _on_curve_tuning_changed() -> void:
	_refresh_controls()


func _refresh_controls() -> void:
	_refreshing = true
	var values := UnitScript.mech_gait_tuning()
	for key in _controls:
		(_controls[key] as SpinBox).value = float(values[key])
	_refreshing = false
	if _curve_editor != null:
		_curve_editor.call("refresh")

	var acceleration := (float(values[&"rise_end"]) - float(values[&"rise_start"])) * 100.0
	var full_speed := (float(values[&"fall_start"]) - float(values[&"rise_end"])) * 100.0
	var deceleration := (float(values[&"fall_end"]) - float(values[&"fall_start"])) * 100.0
	_summary.text = "Per step: blend up %.0f%% · full Speed %.0f%% · blend down %.0f%%" % [
		acceleration,
		full_speed,
		deceleration,
	]
