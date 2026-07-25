extends SceneTree

const ModelBakeBuilderScript := preload("res://converters/model_bake_builder.gd")

const SOURCE_DIRECTORY := "res://assets/raw_original_content/UI0001/CURSORS"
const OUTPUT_DIRECTORY := "res://assets/converted/ui/cursor_previews"
const MODEL_SCALE := 0.0625
const PREVIEW_SIZE := Vector2i(192, 192)
const CAMERA_ORTHO_SIZE := 3.0
const CAMERA_TILT_DEGREES := 50.0


func _initialize() -> void:
	call_deferred("_render_all")


func _render_all() -> void:
	var output_absolute := ProjectSettings.globalize_path(OUTPUT_DIRECTORY)
	var directory_error := DirAccess.make_dir_recursive_absolute(output_absolute)
	if directory_error != OK:
		_fail("could not create %s (%s)" % [OUTPUT_DIRECTORY, error_string(directory_error)])
		return

	var viewport := _create_preview_viewport()
	get_root().add_child(viewport)

	var source_files := PackedStringArray()
	for file_name in DirAccess.get_files_at(SOURCE_DIRECTORY):
		if file_name.get_extension().to_lower() == "xbf":
			source_files.append(file_name)
	source_files.sort()

	var rendered := 0
	for file_name in source_files:
		var builder = ModelBakeBuilderScript.new()
		builder.world_scale = MODEL_SCALE
		var scene: PackedScene = builder.build(SOURCE_DIRECTORY.path_join(file_name))
		if scene == null:
			_fail("could not convert %s" % file_name)
			return
		if not builder.missing_textures.is_empty():
			push_warning(
				"%s is missing textures: %s"
				% [file_name, ", ".join(builder.missing_textures)]
			)

		var model := scene.instantiate() as Node3D
		if model == null:
			_fail("could not instantiate %s" % file_name)
			return
		viewport.get_node("ModelRoot").add_child(model)
		viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		await process_frame
		await process_frame

		var image := viewport.get_texture().get_image()
		var output_path := OUTPUT_DIRECTORY.path_join("%s.png" % file_name.get_basename())
		var save_error := image.save_png(ProjectSettings.globalize_path(output_path))
		if save_error != OK:
			_fail("could not save %s (%s)" % [output_path, error_string(save_error)])
			return

		model.queue_free()
		await process_frame
		rendered += 1

	print("Rendered %d cursor previews to %s" % [rendered, OUTPUT_DIRECTORY])
	quit(0)


func _create_preview_viewport() -> SubViewport:
	var viewport := SubViewport.new()
	viewport.size = PREVIEW_SIZE
	viewport.transparent_bg = false
	viewport.own_world_3d = true
	viewport.msaa_3d = Viewport.MSAA_4X
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED

	var model_root := Node3D.new()
	model_root.name = "ModelRoot"
	viewport.add_child(model_root)

	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("#20242b")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color.WHITE
	environment.ambient_light_energy = 0.75
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	viewport.add_child(world_environment)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55.0, -35.0, 0.0)
	light.light_energy = 0.8
	light.shadow_enabled = false
	viewport.add_child(light)

	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = CAMERA_ORTHO_SIZE
	camera.near = 0.05
	camera.far = 30.0
	var camera_tilt := deg_to_rad(CAMERA_TILT_DEGREES)
	var camera_distance := 12.0
	var camera_position := Vector3(
		0.0,
		sin(camera_tilt) * camera_distance,
		-cos(camera_tilt) * camera_distance
	)
	camera.look_at_from_position(camera_position, Vector3.ZERO, Vector3.UP)
	camera.current = true
	viewport.add_child(camera)
	return viewport


func _fail(message: String) -> void:
	printerr("Cursor gallery rendering failed: %s" % message)
	quit(1)
