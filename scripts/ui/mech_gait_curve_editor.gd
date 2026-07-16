extends Control

signal tuning_changed

const UnitScript := preload("res://scripts/units/unit.gd")
const HANDLE_RADIUS := 7.0
const HANDLE_PICK_RADIUS := 16.0
const PLOT_INSET := Vector2(12.0, 12.0)
const CURVE_SAMPLES := 128
const HANDLE_KEYS: Array[StringName] = [
	&"rise_start",
	&"rise_end",
	&"fall_start",
	&"fall_end",
]

var _dragged_key := &""


func _ready() -> void:
	custom_minimum_size = Vector2(336.0, 176.0)
	mouse_default_cursor_shape = Control.CURSOR_CROSS
	mouse_filter = Control.MOUSE_FILTER_STOP
	tooltip_text = "Drag the four points horizontally. Bottom is MechSpeed; top is ordinary Speed."
	queue_redraw()


func _draw() -> void:
	var plot := _plot_rect()
	draw_rect(plot, Color(0.025, 0.04, 0.065, 0.96), true)
	for division in range(5):
		var fraction := float(division) / 4.0
		var vertical_x := lerpf(plot.position.x, plot.end.x, fraction)
		var horizontal_y := lerpf(plot.position.y, plot.end.y, fraction)
		draw_line(
			Vector2(vertical_x, plot.position.y),
			Vector2(vertical_x, plot.end.y),
			Color(0.22, 0.28, 0.36, 0.42),
			1.0
		)
		draw_line(
			Vector2(plot.position.x, horizontal_y),
			Vector2(plot.end.x, horizontal_y),
			Color(0.22, 0.28, 0.36, 0.42),
			1.0
		)
	draw_rect(plot, Color(0.48, 0.58, 0.7, 0.8), false, 1.0)

	var values := UnitScript.mech_gait_tuning()
	var points := PackedVector2Array()
	for sample in range(CURVE_SAMPLES + 1):
		var phase := float(sample) / float(CURVE_SAMPLES)
		points.append(_curve_point(plot, phase, _speed_blend(values, phase)))
	draw_polyline(points, Color(1.0, 0.77, 0.2), 3.0, true)

	for key in HANDLE_KEYS:
		var handle := _handle_position(plot, key, values)
		var color := Color(0.3, 0.9, 0.55) if String(key).begins_with("rise") \
			else Color(1.0, 0.42, 0.34)
		draw_line(
			Vector2(handle.x, plot.position.y),
			Vector2(handle.x, plot.end.y),
			Color(color, 0.2),
			1.0
		)
		draw_circle(handle, HANDLE_RADIUS + 2.0, Color(0.02, 0.03, 0.05), true)
		draw_circle(handle, HANDLE_RADIUS, color, true)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_dragged_key = _nearest_handle(event.position)
			if not _dragged_key.is_empty():
				accept_event()
		else:
			_dragged_key = &""
			accept_event()
		return
	if not (event is InputEventMouseMotion) or _dragged_key.is_empty():
		return
	var plot := _plot_rect()
	var phase := inverse_lerp(plot.position.x, plot.end.x, event.position.x)
	UnitScript.set_mech_gait_tuning_value(_dragged_key, clampf(phase, 0.0, 1.0))
	tuning_changed.emit()
	queue_redraw()
	accept_event()


func refresh() -> void:
	queue_redraw()


func _nearest_handle(position: Vector2) -> StringName:
	var plot := _plot_rect()
	var values := UnitScript.mech_gait_tuning()
	var nearest := &""
	var nearest_distance := HANDLE_PICK_RADIUS
	for key in HANDLE_KEYS:
		var distance := position.distance_to(_handle_position(plot, key, values))
		if distance <= nearest_distance:
			nearest_distance = distance
			nearest = key
	return nearest


func _plot_rect() -> Rect2:
	return Rect2(PLOT_INSET, (size - PLOT_INSET * 2.0).max(Vector2.ONE))


func _handle_position(plot: Rect2, key: StringName, values: Dictionary) -> Vector2:
	var phase := float(values[key])
	var blend := 0.0 if key == &"rise_start" or key == &"fall_end" else 1.0
	return _curve_point(plot, phase, blend)


static func _curve_point(plot: Rect2, phase: float, blend: float) -> Vector2:
	return Vector2(
		lerpf(plot.position.x, plot.end.x, phase),
		lerpf(plot.end.y, plot.position.y, blend)
	)


static func _speed_blend(values: Dictionary, phase: float) -> float:
	var rise := smoothstep(float(values[&"rise_start"]), float(values[&"rise_end"]), phase)
	var fall := 1.0 - smoothstep(float(values[&"fall_start"]), float(values[&"fall_end"]), phase)
	return rise * fall
