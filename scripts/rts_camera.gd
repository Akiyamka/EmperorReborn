class_name RTSCamera
extends Node3D

const RTSCameraConfigScript := preload("res://scripts/rts_camera_config.gd")

@export var config: RTSCameraConfig

@onready var camera: Camera3D = $Camera3D

## XZ area the camera target may move in (world units). Empty rect = unrestricted.
var target_bounds := Rect2()

var _zoom := 0.0
var _has_mouse_position := false


func _ready() -> void:
	_ensure_config()
	_apply_camera_defaults()
	_zoom = config.default_zoom
	_apply_zoom()


func _process(delta: float) -> void:
	var input_direction := _keyboard_direction()
	if config.edge_scroll_enabled:
		input_direction += _edge_scroll_direction()

	if input_direction.length_squared() > 1.0:
		input_direction = input_direction.normalized()

	var speed: float = config.move_speed
	if Input.is_key_pressed(KEY_SHIFT):
		speed *= config.fast_multiplier

	var forward := -global_transform.basis.z
	forward.y = 0.0
	forward = forward.normalized()

	var right := global_transform.basis.x
	right.y = 0.0
	right = right.normalized()

	global_position += (right * input_direction.x + forward * input_direction.y) * speed * delta
	_clamp_view_to_bounds()

	var rotation_input := 0.0
	if Input.is_key_pressed(KEY_Q):
		rotation_input -= 1.0
	if Input.is_key_pressed(KEY_E):
		rotation_input += 1.0

	if not is_zero_approx(rotation_input):
		rotate_y(rotation_input * config.rotation_speed * delta)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_has_mouse_position = true

	if event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				_set_zoom(_zoom - config.zoom_speed)
				get_viewport().set_input_as_handled()
			MOUSE_BUTTON_WHEEL_DOWN:
				_set_zoom(_zoom + config.zoom_speed)
				get_viewport().set_input_as_handled()


func set_map_view(center: Vector3, bounds: Rect2) -> void:
	_ensure_config()
	set_target(center)
	set_target_bounds(bounds.grow(config.bounds_margin))


func set_target(target: Vector3) -> void:
	global_position = Vector3(target.x, 0.0, target.z)
	_clamp_view_to_bounds()


func set_target_bounds(bounds: Rect2) -> void:
	target_bounds = bounds
	_clamp_view_to_bounds()


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

	if mouse_position.x <= config.edge_scroll_margin:
		direction.x -= 1.0
	elif mouse_position.x >= viewport_rect.size.x - config.edge_scroll_margin:
		direction.x += 1.0

	if mouse_position.y <= config.edge_scroll_margin:
		direction.y += 1.0
	elif mouse_position.y >= viewport_rect.size.y - config.edge_scroll_margin:
		direction.y -= 1.0

	return direction


## Clamps the point the camera actually looks at (center ray projected onto
## the ground plane) to the map bounds — clamping the rig itself is not
## enough because the pitched camera looks well behind the rig at high zoom.
func _clamp_view_to_bounds() -> void:
	if not target_bounds.has_area():
		return
	var camera_position := camera.global_position
	var view_direction := -camera.global_transform.basis.z
	if view_direction.y >= -0.01:
		return
	var distance := camera_position.y / -view_direction.y
	var view_center := camera_position + view_direction * distance
	var clamped_x := clampf(view_center.x, target_bounds.position.x, target_bounds.end.x)
	var clamped_z := clampf(view_center.z, target_bounds.position.y, target_bounds.end.y)
	global_position.x += clamped_x - view_center.x
	global_position.z += clamped_z - view_center.z


func _set_zoom(value: float) -> void:
	_ensure_config()
	_zoom = clampf(value, config.min_zoom, config.max_zoom)
	_apply_zoom()


func _apply_zoom() -> void:
	camera.position = Vector3(0.0, _zoom * config.camera_height_per_zoom, _zoom)
	camera.rotation_degrees = Vector3(config.camera_pitch_degrees, 0.0, 0.0)
	_clamp_view_to_bounds()


func _apply_camera_defaults() -> void:
	camera.fov = config.fov
	camera.far = config.far


func _ensure_config() -> void:
	if config == null:
		config = RTSCameraConfigScript.new()
