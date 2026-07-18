extends SceneTree

## Converts every H0 XBF referenced by a rules-defined unit.
##
## Unit art resources provide the authoritative XAF model prefix. Multiple unit
## definitions may share a source model, so each source scene is written once.

const ModelBakeBuilderScript := preload("res://converters/model_bake_builder.gd")

const UNITS_DIR := "res://assets/converted/rules/units"
const ART_DIR := "res://assets/converted/rules/art"
const MODEL_DIR := "res://assets/raw_original_content/3DDATA/Units"
const TEXTURE_DIR := "res://assets/raw_original_content/3DDATA/Textures"
const OUTPUT_DIR := "res://assets/converted/models"


func _init() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	var force := args.has("force")
	var art_by_unit := _load_art_by_unit()
	var h0_models := _find_h0_models()
	var sources := {}
	var skipped_without_art: PackedStringArray = []
	var skipped_without_model: PackedStringArray = []

	for unit_id in _unit_ids():
		if not art_by_unit.has(unit_id):
			skipped_without_art.append(unit_id)
			continue
		var source_prefix := String(art_by_unit[unit_id])
		var model_path: String = h0_models.get(_normalized_model_name(source_prefix), "")
		if model_path.is_empty():
			skipped_without_model.append("%s (%s)" % [unit_id, source_prefix])
			continue
		sources[model_path] = true

	var converted := 0
	var skipped_existing := 0
	var failures: PackedStringArray = []
	for source in sources:
		var model_name := String(source).get_file().get_basename()
		var output := OUTPUT_DIR.path_join(model_name).path_join("%s.scn" % model_name)
		if not force and ResourceLoader.exists(output):
			skipped_existing += 1
			continue
		var builder = ModelBakeBuilderScript.new()
		builder.source_texture_dir = TEXTURE_DIR
		var scene: PackedScene = builder.build(source)
		if scene == null:
			failures.append(model_name)
			continue
		var err := _save_scene(scene, output)
		if err != OK:
			failures.append(model_name)
			continue
		converted += 1
		print("convert_all_units: wrote %s" % output)

	print("convert_all_units: converted %d models; %d already existed" % [converted, skipped_existing])
	_print_skipped("no art resource", skipped_without_art)
	_print_skipped("no H0 model", skipped_without_model)
	if not failures.is_empty():
		push_error("convert_all_units: failed: %s" % ", ".join(failures))
	quit(1 if not failures.is_empty() else 0)


func _unit_ids() -> PackedStringArray:
	var ids: PackedStringArray = []
	var dir := DirAccess.open(UNITS_DIR)
	if dir == null:
		push_error("convert_all_units: cannot open %s" % UNITS_DIR)
		return ids
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if not dir.current_is_dir() and file_name.get_extension() == "tres":
			var config = ResourceLoader.load(UNITS_DIR.path_join(file_name))
			if config != null and String(config.entity_type) == "unit":
				ids.append(String(config.id))
		file_name = dir.get_next()
	dir.list_dir_end()
	ids.sort()
	return ids


func _load_art_by_unit() -> Dictionary:
	var art_by_unit := {}
	var dir := DirAccess.open(ART_DIR)
	if dir == null:
		push_error("convert_all_units: cannot open %s" % ART_DIR)
		return art_by_unit
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if not dir.current_is_dir() and file_name.get_extension() == "tres":
			var config = ResourceLoader.load(ART_DIR.path_join(file_name))
			if config != null and config.has_method("field") and str(config.field("target_entity_type", "")) == "unit":
				var unit_id := str(config.field("target_entity", ""))
				var xaf := str(config.field("xaf", ""))
				if not unit_id.is_empty() and not xaf.is_empty():
					art_by_unit[unit_id] = xaf
		file_name = dir.get_next()
	dir.list_dir_end()
	return art_by_unit


func _find_h0_models() -> Dictionary:
	var models := {}
	var dir := DirAccess.open(MODEL_DIR)
	if dir == null:
		push_error("convert_all_units: cannot open %s" % MODEL_DIR)
		return models
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		var stem := file_name.get_basename()
		if not dir.current_is_dir() and file_name.get_extension().to_lower() == "xbf" and stem.to_lower().ends_with("_h0"):
			models[_normalized_model_name(stem.left(-3))] = MODEL_DIR.path_join(file_name)
		file_name = dir.get_next()
	dir.list_dir_end()
	return models


func _normalized_model_name(value: String) -> String:
	return value.to_lower().replace("_", "").replace(" ", "")


func _save_scene(scene: PackedScene, output: String) -> Error:
	var absolute_output := ProjectSettings.globalize_path(output)
	var err := DirAccess.make_dir_recursive_absolute(absolute_output.get_base_dir())
	if err != OK:
		push_error("convert_all_units: could not create %s (%s)" % [output.get_base_dir(), error_string(err)])
		return err
	err = ResourceSaver.save(scene, output)
	if err != OK:
		push_error("convert_all_units: could not save %s (%s)" % [output, error_string(err)])
	return err


func _print_skipped(reason: String, unit_ids: PackedStringArray) -> void:
	if not unit_ids.is_empty():
		print("convert_all_units: skipped %d (%s): %s" % [unit_ids.size(), reason, ", ".join(unit_ids)])


func _parse_args(raw_args: PackedStringArray) -> Dictionary:
	var parsed := {}
	for arg in raw_args:
		if arg.begins_with("--"):
			parsed[arg.substr(2)] = true
	return parsed
