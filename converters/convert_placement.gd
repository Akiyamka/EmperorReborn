extends SceneTree

const ModelBakeBuilderScript := preload("res://converters/model_bake_builder.gd")

const DEFAULT_SOURCE_DIR := "res://assets/raw_original_content/3DDATA/Placement"
const DEFAULT_OUTPUT_DIR := "res://assets/converted/placement"


func _init() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	var source_dir := String(args.get("source-dir", DEFAULT_SOURCE_DIR))
	var output_dir := String(args.get("output-dir", DEFAULT_OUTPUT_DIR))

	var sources := PackedStringArray()
	if args.has("source"):
		sources.append(String(args["source"]))
	else:
		sources = _list_xbf_files(source_dir)
	if sources.is_empty():
		push_error("convert_placement: no .xbf files in %s" % source_dir)
		quit(1)
		return

	var builder = ModelBakeBuilderScript.new()
	builder.source_texture_dir = String(args.get("textures", "res://assets/raw_original_content/3DDATA/Textures"))
	builder.texture_output_dir = String(args.get("texture-output", ""))
	if args.has("world-scale"):
		builder.world_scale = float(args["world-scale"])

	var failures := 0
	for source in sources:
		var basename := source.get_file().get_basename()
		var output := output_dir.path_join("%s.scn" % basename)
		var scene: PackedScene = builder.build(source)
		if scene == null:
			push_error("convert_placement: failed to build %s" % source)
			failures += 1
			continue
		if _save_scene(scene, output) != OK:
			failures += 1
			continue
		print("convert_placement: wrote %s" % output)
		if not builder.missing_textures.is_empty():
			print("convert_placement: missing textures for %s: %s" % [basename, ", ".join(builder.missing_textures)])

	quit(1 if failures > 0 else 0)


func _list_xbf_files(dir_path: String) -> PackedStringArray:
	var sources := PackedStringArray()
	var dir := DirAccess.open(dir_path)
	if dir == null:
		push_error("convert_placement: cannot open %s (%s)" % [dir_path, error_string(DirAccess.get_open_error())])
		return sources
	for file in dir.get_files():
		if file.get_extension().to_lower() == "xbf":
			sources.append(dir_path.path_join(file))
	sources.sort()
	return sources


func _save_scene(scene: PackedScene, output: String) -> Error:
	var absolute_output := ProjectSettings.globalize_path(output)
	var err := DirAccess.make_dir_recursive_absolute(absolute_output.get_base_dir())
	if err != OK:
		push_error("convert_placement: could not create %s (%s)" % [output.get_base_dir(), error_string(err)])
		return err
	err = ResourceSaver.save(scene, output)
	if err != OK:
		push_error("convert_placement: could not save %s (%s)" % [output, error_string(err)])
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
