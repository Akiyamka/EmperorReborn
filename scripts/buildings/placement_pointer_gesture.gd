class_name PlacementPointerGesture
extends RefCounted

const ROTATION_DRAG_THRESHOLD := 8.0

var _placement
var _pointer_down := false
var _press_position := Vector2.ZERO
var _rotated_during_press := false


func configure(placement) -> void:
	_placement = placement


func begin(screen_position: Vector2) -> void:
	_pointer_down = true
	_press_position = screen_position
	_rotated_during_press = false
	_placement.process(screen_position)


func update_rotation(screen_position: Vector2) -> void:
	if not _pointer_down:
		return
	if _press_position.distance_to(screen_position) < ROTATION_DRAG_THRESHOLD:
		return
	if _placement.face_toward_pointer(_press_position, screen_position):
		_rotated_during_press = true
	_placement.process(_press_position)


func finish(screen_position: Vector2, status: Callable, place: Callable) -> void:
	if not _pointer_down:
		return
	update_rotation(screen_position)
	var placement_position := _press_position
	var rotated := _rotated_during_press
	reset()
	if rotated:
		status.call("%s rotated; click to place" % _placement.display_name())
		return
	place.call(placement_position)


func reset() -> void:
	_pointer_down = false
	_press_position = Vector2.ZERO
	_rotated_during_press = false


func pointer_down() -> bool:
	return _pointer_down


func press_position() -> Vector2:
	return _press_position


func rotated_during_press() -> bool:
	return _rotated_during_press


func set_pointer_down(value: bool) -> void:
	_pointer_down = value


func set_press_position(value: Vector2) -> void:
	_press_position = value


func set_rotated_during_press(value: bool) -> void:
	_rotated_during_press = value
