extends SceneTree

const RTSCameraScript := preload("res://scripts/world/camera/rts_camera.gd")
const RTSCameraConfigScript := preload("res://scripts/world/camera/rts_camera_config.gd")

var _assertions := 0
var _failures := 0


func _initialize() -> void:
	await _test_pitched_camera_view_stays_inside_map_bounds()
	await _test_zoom_changes_pitch_without_moving_view_center()

	if _failures > 0:
		printerr("Camera tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("Camera tests: %d assertions passed" % _assertions)
	quit(0)


func _test_pitched_camera_view_stays_inside_map_bounds() -> void:
	var rig := RTSCameraScript.new()
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	rig.add_child(camera)
	get_root().add_child(rig)
	await process_frame

	var map_bounds := Rect2(0.0, 0.0, 100.0, 80.0)
	rig.set_map_view(Vector3(50.0, 0.0, 40.0), map_bounds)
	var expected_bounds: Rect2 = map_bounds.grow(rig.config.bounds_margin)
	_expect(rig.target_bounds == expected_bounds, "set_map_view must retain the configured map bounds")
	_expect(_view_direction(camera).y < -0.01, "the pitched camera must look down toward the ground plane")

	rig.set_target(Vector3(1000.0, 0.0, 1000.0))
	_expect(
		_view_center(camera).is_equal_approx(Vector3(expected_bounds.end.x, 0.0, expected_bounds.end.y)),
		"the ground-plane view center must clamp to the maximum map corner"
	)
	_expect(not rig._can_scroll(Vector2.RIGHT), "east edge scrolling must report blocked at the east map bound")
	_expect(rig._can_scroll(Vector2.LEFT), "west edge scrolling must remain available at the east map bound")

	rig.rotate_y(1.1)
	rig.set_target(Vector3(-1000.0, 0.0, -1000.0))
	_expect(
		_view_center(camera).is_equal_approx(Vector3(expected_bounds.position.x, 0.0, expected_bounds.position.y)),
		"the rotated camera view center must clamp to the minimum map corner"
	)

	rig.queue_free()
	await process_frame


func _test_zoom_changes_pitch_without_moving_view_center() -> void:
	var rig := RTSCameraScript.new()
	rig.config = RTSCameraConfigScript.new()
	rig.config.min_zoom = 10.0
	rig.config.max_zoom = 30.0
	rig.config.default_zoom = 20.0
	rig.config.near_pitch_degrees = -30.0
	rig.config.far_pitch_degrees = -70.0
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	rig.add_child(camera)
	get_root().add_child(rig)
	await process_frame

	_expect(is_equal_approx(camera.rotation_degrees.x, -50.0), "the middle zoom must interpolate its pitch")
	var initial_view_center := _view_center(camera)
	rig._set_zoom(rig.config.min_zoom)
	_expect(is_equal_approx(camera.rotation_degrees.x, -30.0), "near zoom must use the shallower pitch")
	_expect(_view_center(camera).is_equal_approx(initial_view_center), "zooming in must preserve the ground view center")
	rig._set_zoom(rig.config.max_zoom)
	_expect(is_equal_approx(camera.rotation_degrees.x, -70.0), "far zoom must use the steeper pitch")
	_expect(_view_center(camera).is_equal_approx(initial_view_center), "zooming out must preserve the ground view center")

	rig.queue_free()
	await process_frame


func _view_direction(camera: Camera3D) -> Vector3:
	return (camera.global_transform.basis * Vector3.FORWARD).normalized()


func _view_center(camera: Camera3D) -> Vector3:
	var direction := _view_direction(camera)
	var distance := camera.global_position.y / -direction.y
	return camera.global_position + direction * distance


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s" % message)
