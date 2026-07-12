class_name SelectionRectangle
extends Control

## Screen-space feedback for drag-selecting units. Input goes through the match
## controller, so this control must never intercept pointer events.

const FILL_COLOR := Color(0.18, 0.62, 1.0, 0.16)
const BORDER_COLOR := Color(0.45, 0.82, 1.0, 0.95)

var _rectangle := Rect2()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hide()


func show_between(start: Vector2, end: Vector2) -> void:
	_rectangle = Rect2(start, end - start).abs()
	show()
	queue_redraw()


func clear() -> void:
	_rectangle = Rect2()
	hide()


func _draw() -> void:
	if _rectangle.size == Vector2.ZERO:
		return
	draw_rect(_rectangle, FILL_COLOR, true)
	draw_rect(_rectangle, BORDER_COLOR, false, 1.0)
