extends SceneTree

## Converts every available XBF referenced by a bullet ArtIni entry.
##
## Several bullets share one XAF (for example Howitzer_B and
## KobraHowitzer_B both use shell.xaf), so each source visual is baked once and
## addressed at runtime by the normalized XAF basename.

const ModelBakeBuilderScript := preload("res://converters/model_bake_builder.gd")

const ART_DIR := "res://assets/converted/rules/art"
const SOURCE_DIR := "res://assets/raw_original_content/3DDATA/bullets"
const TEXTURE_DIR := "res://assets/raw_original_content/3DDATA/Textures"
const OUTPUT_DIR := "res://assets/converted/projectiles"


func _init() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	var force := args.has("force")
	var source_by_name := _find_source_models()
	var visual_names := _bullet_visual_names()
	var converted := 0
	var skipped_existing := 0
	var skipped_missing: PackedStringArray = []
	var failures: PackedStringArray = []

	for visual_name in visual_names:
		var source: String = source_by_name.get(visual_name, "")
		if source.is_empty():
			skipped_missing.append(visual_name)
			continue
		var output := OUTPUT_DIR.path_join(visual_name).path_join("%s.scn" % visual_name)
		if not force and ResourceLoader.exists(output):
			skipped_existing += 1
			continue
		var builder = ModelBakeBuilderScript.new()
		builder.source_texture_dir = TEXTURE_DIR
		var scene: PackedScene = builder.build(source)
		if scene == null or _save_scene(scene, output) != OK:
			failures.append(visual_name)
			continue
		converted += 1
		print("convert_all_projectiles: wrote %s" % output)

	print(
		"convert_all_projectiles: converted %d visuals; %d already existed"
		% [converted, skipped_existing]
	)
	if not skipped_missing.is_empty():
		print(
			"convert_all_projectiles: skipped %d ArtIni visuals without a local XBF: %s"
			% [skipped_missing.size(), ", ".join(skipped_missing)]
		)
	if not failures.is_empty():
		push_error("convert_all_projectiles: failed: %s" % ", ".join(failures))
	quit(1 if not failures.is_empty() else 0)


func _bullet_visual_names() -> PackedStringArray:
	var names := {}
	var dir := DirAccess.open(ART_DIR)
	if dir == null:
		push_error("convert_all_projectiles: cannot open %s" % ART_DIR)
		return PackedStringArray()
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if not dir.current_is_dir() and file_name.get_extension() == "tres":
			var config = ResourceLoader.load(ART_DIR.path_join(file_name))
			if (
				config != null
				and config.has_method("field")
				and String(config.field(&"target_entity_type", "")) == "bullet"
			):
				var xaf := String(config.field(&"xaf", ""))
				if not xaf.is_empty():
					names[xaf.get_file().get_basename().to_lower()] = true
		file_name = dir.get_next()
	dir.list_dir_end()
	var result: PackedStringArray = []
	for visual_name in names:
		result.append(String(visual_name))
	result.sort()
	return result


func _find_source_models() -> Dictionary:
	var result := {}
	var dir := DirAccess.open(SOURCE_DIR)
	if dir == null:
		push_error("convert_all_projectiles: cannot open %s" % SOURCE_DIR)
		return result
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if not dir.current_is_dir() and file_name.get_extension().to_lower() == "xbf":
			result[file_name.get_basename().to_lower()] = SOURCE_DIR.path_join(file_name)
		file_name = dir.get_next()
	dir.list_dir_end()
	return result


func _save_scene(scene: PackedScene, output: String) -> Error:
	var absolute_output := ProjectSettings.globalize_path(output)
	var err := DirAccess.make_dir_recursive_absolute(absolute_output.get_base_dir())
	if err != OK:
		push_error(
			"convert_all_projectiles: could not create %s (%s)"
			% [output.get_base_dir(), error_string(err)]
		)
		return err
	err = ResourceSaver.save(scene, output)
	if err != OK:
		push_error(
			"convert_all_projectiles: could not save %s (%s)"
			% [output, error_string(err)]
		)
	return err


func _parse_args(raw_args: PackedStringArray) -> Dictionary:
	var parsed := {}
	for arg in raw_args:
		if arg.begins_with("--"):
			parsed[arg.substr(2)] = true
	return parsed
