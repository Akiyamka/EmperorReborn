extends SceneTree

const ModelBakeBuilderScript := preload("res://scripts/model_bake_builder.gd")


func _init() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	var source := String(args.get("source", ""))
	if source.is_empty():
		source = OS.get_environment("EMPEROR_CONVERT_MODEL")
	if source.is_empty():
		_usage("missing --source")
		return

	var output := String(args.get("output", ""))
	if output.is_empty():
		output = "res://assets/converted_models".path_join(source.get_file().get_basename()).path_join("%s.tscn" % source.get_file().get_basename())

	var builder = ModelBakeBuilderScript.new()
	builder.source_texture_dir = String(args.get("textures", ProjectSettings.globalize_path("res://../extracted/textures")))
	builder.texture_output_dir = String(args.get("texture-output", "res://assets/model_textures/3DDATA0001"))
	if args.has("world-scale"):
		builder.world_scale = float(args["world-scale"])
	if args.has("fps"):
		builder.fps = float(args["fps"])

	var scene: PackedScene = builder.build(source)
	if scene == null:
		quit(1)
		return

	var err := _save_scene(scene, output)
	if err != OK:
		quit(1)
		return

	print("convert_model: wrote %s" % output)
	if not builder.copied_textures.is_empty():
		print("convert_model: copied %d model textures to %s" % [builder.copied_textures.size(), builder.texture_output_dir])
	if not builder.missing_textures.is_empty():
		print("convert_model: missing %d textures: %s" % [builder.missing_textures.size(), ", ".join(builder.missing_textures)])
	quit()


func _save_scene(scene: PackedScene, output: String) -> Error:
	var absolute_output := ProjectSettings.globalize_path(output)
	var err := DirAccess.make_dir_recursive_absolute(absolute_output.get_base_dir())
	if err != OK:
		push_error("convert_model: could not create %s (%s)" % [output.get_base_dir(), error_string(err)])
		return err
	err = ResourceSaver.save(scene, output)
	if err != OK:
		push_error("convert_model: could not save %s (%s)" % [output, error_string(err)])
	return err


func _parse_args(raw_args: PackedStringArray) -> Dictionary:
	var parsed := {}
	var i := 0
	while i < raw_args.size():
		var arg := raw_args[i]
		if arg.begins_with("--"):
			var key := arg.substr(2)
			if i + 1 < raw_args.size() and not raw_args[i + 1].begins_with("--"):
				parsed[key] = raw_args[i + 1]
				i += 2
			else:
				parsed[key] = true
				i += 1
		else:
			i += 1
	return parsed


func _usage(error: String) -> void:
	push_error("convert_model: %s" % error)
	print("Usage:")
	print("  godot --headless --path . --script res://scripts/convert_model.gd -- --source /path/to/Units/AT_inf_H0.xbf")
	print("Options:")
	print("  --output res://assets/converted_models/AT_inf_H0/AT_inf_H0.tscn")
	print("  --textures /home/aki/git/com.emperor/extracted/textures")
	print("  --texture-output res://assets/model_textures/3DDATA0001")
	print("  --world-scale 0.0625")
	print("  --fps 20")
	quit(1)
