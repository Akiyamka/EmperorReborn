extends Node3D

@export var move_speed := 18.0
@export var fast_multiplier := 2.0
@export var rotation_speed := 1.8
@export var zoom_speed := 3.0
@export var min_zoom := 14.0
@export var max_zoom := 240.0
@export var edge_scroll_margin := 16.0
@export var edge_scroll_enabled := true

@onready var camera: Camera3D = $Camera3D

var _zoom := 32.0
var _has_mouse_position := false


func _ready() -> void:
	_zoom = camera.position.z
	_apply_zoom()


func _process(delta: float) -> void:
	var input_direction := _keyboard_direction()
	if edge_scroll_enabled:
		input_direction += _edge_scroll_direction()

	if input_direction.length_squared() > 1.0:
		input_direction = input_direction.normalized()

	var speed := move_speed
	if Input.is_key_pressed(KEY_SHIFT):
		speed *= fast_multiplier

	var forward := -global_transform.basis.z
	forward.y = 0.0
	forward = forward.normalized()

	var right := global_transform.basis.x
	right.y = 0.0
	right = right.normalized()

	global_position += (right * input_direction.x + forward * input_direction.y) * speed * delta

	var rotation_input := 0.0
	if Input.is_key_pressed(KEY_Q):
		rotation_input -= 1.0
	if Input.is_key_pressed(KEY_E):
		rotation_input += 1.0

	if not is_zero_approx(rotation_input):
		rotate_y(rotation_input * rotation_speed * delta)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_has_mouse_position = true

	if event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				_set_zoom(_zoom - zoom_speed)
				get_viewport().set_input_as_handled()
			MOUSE_BUTTON_WHEEL_DOWN:
				_set_zoom(_zoom + zoom_speed)
				get_viewport().set_input_as_handled()


func _keyboard_direction() -> Vector2:
	var direction := Vector2.ZERO

	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		direction.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		direction.x += 1.0
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		direction.y += 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		direction.y -= 1.0

	return direction


func _edge_scroll_direction() -> Vector2:
	var viewport_rect := get_viewport().get_visible_rect()
	var mouse_position := get_viewport().get_mouse_position()
	var direction := Vector2.ZERO

	if not _has_mouse_position or viewport_rect.size == Vector2.ZERO:
		return direction

	if mouse_position.x < 0.0 or mouse_position.y < 0.0:
		return direction
	if mouse_position.x > viewport_rect.size.x or mouse_position.y > viewport_rect.size.y:
		return direction

	if mouse_position.x <= edge_scroll_margin:
		direction.x -= 1.0
	elif mouse_position.x >= viewport_rect.size.x - edge_scroll_margin:
		direction.x += 1.0

	if mouse_position.y <= edge_scroll_margin:
		direction.y += 1.0
	elif mouse_position.y >= viewport_rect.size.y - edge_scroll_margin:
		direction.y -= 1.0

	return direction


func _set_zoom(value: float) -> void:
	_zoom = clampf(value, min_zoom, max_zoom)
	_apply_zoom()


func _apply_zoom() -> void:
	camera.position = Vector3(0.0, _zoom * 0.75, _zoom)
	camera.rotation_degrees = Vector3(-60.0, 0.0, 0.0)
