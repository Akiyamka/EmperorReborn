extends SceneTree

const BuildingBakeBuilderScript := preload("res://importers/building_bake_builder.gd")


func _init() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	var building := String(args.get("building", ""))
	if building.is_empty():
		building = OS.get_environment("EMPEROR_CONVERT_BUILDING")
	if building.is_empty():
		_usage("missing --building")
		return

	var output := String(args.get("output", ""))
	if output.is_empty():
		output = "res://assets/converted_buildings".path_join(building).path_join("%s.scn" % building)

	var builder = BuildingBakeBuilderScript.new()
	builder.building_model_dir = String(args.get("source", "res://assets/unpacked_rfd/3DDATA/Buildings"))
	builder.source_texture_dir = String(args.get("textures", "res://assets/unpacked_rfd/3DDATA/Textures"))
	builder.texture_output_dir = String(args.get("texture-output", ""))
	if args.has("prefix"):
		builder.source_prefix = String(args["prefix"])
	if args.has("world-scale"):
		builder.world_scale = float(args["world-scale"])
	if args.has("fps"):
		builder.fps = float(args["fps"])

	var scene: PackedScene = builder.build(StringName(building))
	if scene == null:
		quit(1)
		return

	var err := _save_scene(scene, output)
	if err != OK:
		quit(1)
		return

	print("convert_building: wrote %s" % output)
	print("convert_building: imported %d H-state XBF files" % builder.imported_files.size())
	if not builder.missing_states.is_empty():
		print("convert_building: missing optional H states: %s" % ", ".join(builder.missing_states))
	if not builder.missing_textures.is_empty():
		print("convert_building: missing %d textures: %s" % [builder.missing_textures.size(), ", ".join(builder.missing_textures)])
	quit()


func _save_scene(scene: PackedScene, output: String) -> Error:
	var absolute_output := ProjectSettings.globalize_path(output)
	var err := DirAccess.make_dir_recursive_absolute(absolute_output.get_base_dir())
	if err != OK:
		push_error("convert_building: could not create %s (%s)" % [output.get_base_dir(), error_string(err)])
		return err
	err = ResourceSaver.save(scene, output)
	if err != OK:
		push_error("convert_building: could not save %s (%s)" % [output, error_string(err)])
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
	push_error("convert_building: %s" % error)
	print("Usage:")
	print("  godot --headless --path . --script res://importers/convert_building.gd -- --building ATBarracks")
	print("Options:")
	print("  --prefix at_barracks")
	print("  --source res://assets/unpacked_rfd/3DDATA/Buildings")
	print("  --textures res://assets/unpacked_rfd/3DDATA/Textures")
	print("  --output res://assets/converted_buildings/ATBarracks/ATBarracks.scn")
	print("  --world-scale 0.0625")
	print("  --fps 20")
	quit(1)
