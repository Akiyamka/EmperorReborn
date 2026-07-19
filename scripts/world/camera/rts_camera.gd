class_name RTSCamera
extends Node3D

const SpatialOrientationScript := preload("res://scripts/world/spatial_orientation.gd")
const CursorManagerScript := preload("res://scripts/ui/cursor_manager.gd")

const RTSCameraConfigScript := preload("res://scripts/world/camera/rts_camera_config.gd")

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
	var edge_scroll_direction := Vector2.ZERO
	if config.edge_scroll_enabled:
		edge_scroll_direction = _edge_scroll_direction()
		input_direction += edge_scroll_direction

	if input_direction.length_squared() > 1.0:
		input_direction = input_direction.normalized()

	var speed: float = config.move_speed
	if Input.is_key_pressed(KEY_SHIFT):
		speed *= config.fast_multiplier

	var forward := SpatialOrientationScript.world_forward(self)
	var right := SpatialOrientationScript.world_right(self)

	global_position += (right * input_direction.x + forward * input_direction.y) * speed * delta
	_clamp_view_to_bounds()
	_update_edge_scroll_cursor(edge_scroll_direction)

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


func _exit_tree() -> void:
	var cursors: Variant = _cursor_manager()
	if cursors != null:
		cursors.clear_override(CursorManagerScript.EDGE_SCROLL_OVERRIDE)


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


func _update_edge_scroll_cursor(direction: Vector2) -> void:
	var cursors: Variant = _cursor_manager()
	if cursors == null:
		return
	cursors.set_edge_scroll_cursor(direction, _can_scroll(direction))


func _can_scroll(direction: Vector2) -> bool:
	if direction.is_zero_approx() or not target_bounds.has_area():
		return not direction.is_zero_approx()
	var view_center_value: Variant = _ground_view_center()
	if view_center_value == null:
		return true
	var view_center: Vector3 = view_center_value
	var world_direction := (
		SpatialOrientationScript.world_right(self) * direction.x
		+ SpatialOrientationScript.world_forward(self) * direction.y
	)
	if world_direction.is_zero_approx():
		return false
	world_direction = world_direction.normalized()
	var requested := Vector2(view_center.x + world_direction.x, view_center.z + world_direction.z)
	var clamped := Vector2(
		clampf(requested.x, target_bounds.position.x, target_bounds.end.x),
		clampf(requested.y, target_bounds.position.y, target_bounds.end.y)
	)
	return not clamped.is_equal_approx(Vector2(view_center.x, view_center.z))


func _cursor_manager() -> Variant:
	if not is_inside_tree():
		return null
	return get_node_or_null("/root/Cursors")


## Clamps the point the camera actually looks at (center ray projected onto
## the ground plane) to the map bounds — clamping the rig itself is not
## enough because the pitched camera looks well behind the rig at high zoom.
func _clamp_view_to_bounds() -> void:
	if not target_bounds.has_area():
		return
	var view_center: Variant = _ground_view_center()
	if view_center == null:
		return
	var center: Vector3 = view_center
	var clamped_x := clampf(center.x, target_bounds.position.x, target_bounds.end.x)
	var clamped_z := clampf(center.z, target_bounds.position.y, target_bounds.end.y)
	global_position.x += clamped_x - center.x
	global_position.z += clamped_z - center.z


func _set_zoom(value: float) -> void:
	_ensure_config()
	_zoom = clampf(value, config.min_zoom, config.max_zoom)
	_apply_zoom(true)


func _apply_zoom(preserve_view_center := false) -> void:
	var previous_view_center = _ground_view_center() if preserve_view_center else null
	camera.position = Vector3(0.0, _zoom * config.camera_height_per_zoom, _zoom)
	camera.rotation_degrees = Vector3(_zoom_pitch_degrees(), 0.0, 0.0)
	if previous_view_center != null:
		var current_view_center: Variant = _ground_view_center()
		if current_view_center != null:
			var previous: Vector3 = previous_view_center
			var current: Vector3 = current_view_center
			global_position.x += previous.x - current.x
			global_position.z += previous.z - current.z
	_clamp_view_to_bounds()


func _zoom_pitch_degrees() -> float:
	var zoom_range := config.max_zoom - config.min_zoom
	if is_zero_approx(zoom_range):
		return config.near_pitch_degrees
	var zoom_ratio := clampf((_zoom - config.min_zoom) / zoom_range, 0.0, 1.0)
	return lerpf(config.near_pitch_degrees, config.far_pitch_degrees, zoom_ratio)


func _ground_view_center() -> Variant:
	var camera_position := camera.global_position
	var view_direction := SpatialOrientationScript.world_axis(camera, SpatialOrientationScript.LOCAL_FORWARD)
	if view_direction.y >= -0.01:
		return null
	var distance := camera_position.y / -view_direction.y
	return camera_position + view_direction * distance


func _apply_camera_defaults() -> void:
	camera.fov = config.fov
	camera.far = config.far


func _ensure_config() -> void:
	if config == null:
		config = RTSCameraConfigScript.new()
