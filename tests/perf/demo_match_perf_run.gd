extends SceneTree

## Smoke performance test for the demo match.
##
## It reproduces the manual measurement that first exposed the refactor's
## frame-time regression: load `demo_match.tscn`, restore a snapshot with 49
## buildings packed footprint-to-footprint, park the camera rig at the spot
## where the FPS label was observed dropping, then time a fixed number of
## frames.
##
## The snapshot lives next to this script instead of `user://` so every commit
## measures the same scene, and the harness never touches the developer's own
## saved start state.
##
## Runs with or without a rendering driver:
##   godot --headless --path . --script res://tests/perf/demo_match_perf_run.gd
##   godot --path . --script res://tests/perf/demo_match_perf_run.gd
## Headless isolates CPU/script cost; a windowed run also charges GPU work.
##
## User args (after `--`):
##   --frames=N        measured frames (default 600)
##   --warmup=N        discarded frames before measuring (default 180)
##   --budget-ms=F     fail when the median frame exceeds this many ms
##   --out=PATH        append the JSON result line to PATH (res://, user:// or OS path)
##   --label=TEXT      free-form tag copied into the JSON result
##   --camera-pos=X,Y,Z  CameraRig position (default 197,0,63)
##   --camera-yaw=DEG    CameraRig rotation around Y (default 30)
##   --zoom=F            camera zoom; drives eye height, pitch and view centre (default 160)
##   --screenshot=PATH   save the measured view as a PNG (windowed runs only)

const DEMO_MATCH_SCENE_PATH := "res://scenes/match/demo_match.tscn"
const SNAPSHOT_PATH := "res://tests/perf/fixtures/demo_match_perf_snapshot.json"
const MatchSnapshotScript := preload("res://scripts/match/match_snapshot.gd")

## Camera placement the regression was observed at (CameraRig inspector values).
## The rig's Y is always flattened to 0 by RTSCamera.set_target(); the eye
## height and pitch come from the zoom instead.
const CAMERA_POSITION := Vector3(197.0, 0.0, 63.0)
const CAMERA_ROTATION_Y_DEGREES := 30.0
## Fully zoomed out (RTSCameraConfig.max_zoom). The zoom is what decides what
## the rig actually looks at -- at this zoom the screen centre lands on
## (245, 8, 146), which frames the packed base, while the config's default zoom
## of 70 would look at empty sand ~65 units short of it.
const DEFAULT_ZOOM := 160.0
## Ground height the view centre is reported against: the snapshot's buildings
## all sit at roughly this elevation.
const GROUND_HEIGHT := 8.0

## Frames spent letting the scene settle before the warmup even starts:
## buildings stream in their models and the first frames are dominated by
## resource loading, not by the steady-state cost we care about.
const BOOT_FRAMES := 30

var _frames := 600
var _warmup := 180
var _budget_ms := 0.0
var _out_path := ""
var _label := ""
var _camera_position := CAMERA_POSITION
var _camera_yaw_degrees := CAMERA_ROTATION_Y_DEGREES
var _zoom := DEFAULT_ZOOM
var _screenshot_path := ""


func _initialize() -> void:
	_parse_args()

	# The project caps itself at 60 FPS, which would flatten every measurement
	# into "16.6 ms" and hide the regression entirely. A windowed run needs
	# vsync off for the same reason.
	Engine.max_fps = 0
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)

	var scene: Node = load(DEMO_MATCH_SCENE_PATH).instantiate()
	root.add_child(scene)
	for _i in BOOT_FRAMES:
		await process_frame

	var restore_message := _restore_snapshot(scene)
	var camera_rig := scene.get_node("CameraRig") as Node3D
	_aim_camera(camera_rig)
	for _i in BOOT_FRAMES:
		await process_frame

	var samples := await _measure()
	if not _screenshot_path.is_empty():
		_save_screenshot()
	var result := _summarize(samples, scene, camera_rig, restore_message)
	_report(result)
	quit(0 if bool(result["ok"]) else 1)


func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		var parts := arg.split("=", true, 1)
		var key := parts[0]
		var value := parts[1] if parts.size() > 1 else ""
		match key:
			"--frames":
				_frames = maxi(int(value), 1)
			"--warmup":
				_warmup = maxi(int(value), 0)
			"--budget-ms":
				_budget_ms = maxf(float(value), 0.0)
			"--out":
				_out_path = value
			"--label":
				_label = value
			"--camera-pos":
				var coordinates := value.split_floats(",")
				if coordinates.size() >= 3:
					_camera_position = Vector3(
						coordinates[0], coordinates[1], coordinates[2]
					)
				else:
					push_error("--camera-pos needs X,Y,Z")
			"--camera-yaw":
				_camera_yaw_degrees = float(value)
			"--zoom":
				_zoom = float(value)
			"--screenshot":
				_screenshot_path = value
			_:
				push_warning("Unknown perf argument: %s" % arg)


func _restore_snapshot(scene: Node) -> String:
	var snapshot = MatchSnapshotScript.new(SNAPSHOT_PATH)
	var result: Dictionary = snapshot.restore(
		scene.get_node("Buildings") as Node3D, scene.get_node("Units") as Node3D
	)
	var message := String(result.get("message", ""))
	if not bool(result.get("ok", false)):
		push_error("Perf snapshot restore failed: %s" % message)
	return message


## Pins the view. RTSCamera keeps driving its rig from keyboard/edge-scroll
## input every frame and clamps the looked-at point to the map bounds, so its
## `_process` is switched off: the measured view then stays exactly where it was
## asked for, and a focused window cannot scroll the camera mid-measurement.
func _aim_camera(camera_rig: Node3D) -> void:
	if _zoom >= 0.0:
		camera_rig.call("_set_zoom", _zoom)
	camera_rig.set_process(false)
	camera_rig.global_position = Vector3(_camera_position.x, 0.0, _camera_position.z)
	camera_rig.global_rotation = Vector3(0.0, deg_to_rad(_camera_yaw_degrees), 0.0)


## Where the screen centre ray meets the buildings' ground plane -- the rig
## position alone does not say what is on screen, because the pitched camera
## sits behind and above the rig and looks well past it.
func _view_centre(camera: Camera3D) -> Vector3:
	var origin := camera.global_position
	var direction := -camera.global_transform.basis.z
	if absf(direction.y) < 0.0001:
		return origin
	return origin + direction * ((GROUND_HEIGHT - origin.y) / direction.y)


func _buildings_in_view(camera: Camera3D, buildings_root: Node3D) -> int:
	var count := 0
	for child in buildings_root.get_children():
		var building := child as Node3D
		if building != null and camera.is_position_in_frustum(building.global_position):
			count += 1
	return count


func _save_screenshot() -> void:
	if DisplayServer.get_name() == "headless":
		push_warning("Screenshots need a rendering driver; skipping in headless mode")
		return
	var error := root.get_texture().get_image().save_png(_screenshot_path)
	if error != OK:
		push_error("Cannot save screenshot to %s (error %d)" % [_screenshot_path, error])
	else:
		print("screenshot: %s" % _screenshot_path)


## Returns per-frame wall time and engine-reported process times, in
## milliseconds. Wall time is the metric: it is what the FPS label reflects.
## The `Performance.TIME_*` monitors are informational only -- the engine
## refreshes them on its own interval, so consecutive frames read the same held
## value and their mean can even exceed the measured frame time.
func _measure() -> Dictionary:
	for _i in _warmup:
		await process_frame

	var wall_ms := PackedFloat64Array()
	var process_ms := PackedFloat64Array()
	var physics_ms := PackedFloat64Array()
	var previous_usec := Time.get_ticks_usec()
	for _i in _frames:
		await process_frame
		var now := Time.get_ticks_usec()
		wall_ms.append(float(now - previous_usec) / 1000.0)
		previous_usec = now
		process_ms.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
		physics_ms.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	return {"wall_ms": wall_ms, "process_ms": process_ms, "physics_ms": physics_ms}


func _summarize(
	samples: Dictionary, scene: Node, camera_rig: Node3D, restore_message: String
) -> Dictionary:
	var wall: PackedFloat64Array = samples["wall_ms"]
	var median_wall := _percentile(wall, 0.5)
	var ok := _budget_ms <= 0.0 or median_wall <= _budget_ms
	var buildings_root := scene.get_node("Buildings") as Node3D
	var camera := camera_rig.get_node("Camera3D") as Camera3D
	return {
		"ok": ok,
		"label": _label,
		"frames": _frames,
		"warmup": _warmup,
		"budget_ms": _budget_ms,
		"headless": DisplayServer.get_name() == "headless",
		"video_driver": RenderingServer.get_video_adapter_name(),
		"buildings": buildings_root.get_child_count(),
		"buildings_in_view": _buildings_in_view(camera, buildings_root),
		"units": (scene.get_node("Units") as Node3D).get_child_count(),
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"restore": restore_message,
		"camera_position": _vector_to_array(camera_rig.global_position),
		"camera_rotation_y_deg": rad_to_deg(camera_rig.global_rotation.y),
		"zoom": _zoom,
		"camera_eye": _vector_to_array(camera.global_position),
		"camera_pitch_deg": snappedf(camera.rotation_degrees.x, 0.01),
		"camera_fov": camera.fov,
		"view_centre": _vector_to_array(_view_centre(camera)),
		"wall_ms": _stats(wall),
		"process_ms": _stats(samples["process_ms"]),
		"physics_ms": _stats(samples["physics_ms"]),
		"fps_from_median_wall": 1000.0 / maxf(median_wall, 0.0001),
	}


func _stats(values: PackedFloat64Array) -> Dictionary:
	var total := 0.0
	for value in values:
		total += value
	return {
		"mean": total / maxf(float(values.size()), 1.0),
		"p50": _percentile(values, 0.5),
		"p90": _percentile(values, 0.9),
		"p99": _percentile(values, 0.99),
		"min": _percentile(values, 0.0),
		"max": _percentile(values, 1.0),
	}


func _percentile(values: PackedFloat64Array, quantile: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	var index := clampi(int(round(quantile * float(sorted.size() - 1))), 0, sorted.size() - 1)
	return sorted[index]


func _vector_to_array(value: Vector3) -> Array:
	return [
		snappedf(value.x, 0.001), snappedf(value.y, 0.001), snappedf(value.z, 0.001)
	]


func _report(result: Dictionary) -> void:
	var wall: Dictionary = result["wall_ms"]
	var process: Dictionary = result["process_ms"]
	print("--- demo_match perf ---")
	print("label:      %s" % result["label"])
	print("display:    %s" % ("headless" if bool(result["headless"]) else result["video_driver"]))
	print("scene:      %d buildings (%d in view), %d units, %d nodes" % [
		result["buildings"], result["buildings_in_view"], result["units"], result["nodes"]
	])
	print("rig:        %s yaw=%.1f" % [result["camera_position"], result["camera_rotation_y_deg"]])
	print("eye:        %s pitch=%.1f fov=%.1f" % [
		result["camera_eye"], result["camera_pitch_deg"], result["camera_fov"]
	])
	print("view centre:%s (ground y=%.1f)" % [result["view_centre"], GROUND_HEIGHT])
	print("frames:     %d measured after %d warmup" % [result["frames"], result["warmup"]])
	print("frame ms:   p50=%.3f p90=%.3f p99=%.3f mean=%.3f" % [
		wall["p50"], wall["p90"], wall["p99"], wall["mean"]
	])
	print("process ms: (coarse monitor) p50=%.3f p90=%.3f mean=%.3f" % [
		process["p50"], process["p90"], process["mean"]
	])
	print("fps:        %.1f (from median frame time)" % result["fps_from_median_wall"])
	if result["budget_ms"] > 0.0:
		print("budget:     %.3f ms -> %s" % [
			result["budget_ms"], "PASS" if bool(result["ok"]) else "FAIL"
		])
	print("json:       %s" % JSON.stringify(result))
	if _out_path.is_empty():
		return
	var file := FileAccess.open(_out_path, FileAccess.READ_WRITE) \
		if FileAccess.file_exists(_out_path) else FileAccess.open(_out_path, FileAccess.WRITE)
	if file == null:
		push_error("Cannot write perf result to %s" % _out_path)
		return
	file.seek_end()
	file.store_line(JSON.stringify(result))
	file.close()
