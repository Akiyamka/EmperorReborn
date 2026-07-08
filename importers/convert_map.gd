extends SceneTree

const MapBakeBuilderScript := preload("res://importers/map_bake_builder.gd")


func _init() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	var source_dir := String(args.get("source", ""))
	if source_dir.is_empty():
		source_dir = OS.get_environment("EMPEROR_CONVERT_MAP")
	if source_dir.is_empty():
		_usage("missing --source")
		return

	if not source_dir.begins_with("res://"):
		source_dir = ProjectSettings.localize_path(source_dir)
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(source_dir)):
		_usage("source directory does not exist: %s" % source_dir)
		return

	var output_dir := String(args.get("output", ""))
	if output_dir.is_empty():
		output_dir = "res://assets/converted_maps".path_join(source_dir.get_file())

	var builder = MapBakeBuilderScript.new()
	if args.has("world-scale"):
		builder.world_scale = float(args["world-scale"])
	builder.mottle_full_map = args.has("mottle-full-map")

	var data: Resource = builder.build(source_dir)
	if data == null:
		quit(1)
		return

	var err := _save_outputs(builder, data, output_dir)
	if err != OK:
		quit(1)
		return

	print("convert_map: wrote %s" % output_dir)
	print("convert_map: instance %s in scenes that use this map" % output_dir.path_join("terrain.tscn"))
	quit()


func _save_outputs(builder: RefCounted, data: Resource, output_dir: String) -> Error:
	var absolute_output := ProjectSettings.globalize_path(output_dir)
	var err := DirAccess.make_dir_recursive_absolute(absolute_output)
	if err != OK:
		push_error("convert_map: could not create %s (%s)" % [output_dir, error_string(err)])
		return err

	var data_path := output_dir.path_join("map_data.tres")
	err = ResourceSaver.save(data, data_path)
	if err != OK:
		push_error("convert_map: could not save %s (%s)" % [data_path, error_string(err)])
		return err

	var terrain_scene_path := output_dir.path_join("terrain.tscn")
	var terrain_scene: PackedScene = builder.set_terrain_scene_map_data_path(data_path)
	if terrain_scene == null:
		return FAILED
	err = ResourceSaver.save(terrain_scene, terrain_scene_path)
	if err != OK:
		push_error("convert_map: could not save %s (%s)" % [terrain_scene_path, error_string(err)])
		return err
	return OK


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
	push_error("convert_map: %s" % error)
	print("Usage:")
	print("  godot --headless --path . --script res://importers/convert_map.gd -- --source res://assets/unpacked_rfd/MAPS/#M70\\ Claw\\ Rock")
	print("Options:")
	print("  --output res://assets/converted_maps/<name>")
	print("  --world-scale 0.0625")
	print("  --mottle-full-map")
	quit(1)
