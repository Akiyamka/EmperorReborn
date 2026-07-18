extends SceneTree

## Generates one wrapper scene per rules-defined building with an H0 XBF model.
##
## Art resources are the source of truth for model names: their `xaf` field is
## much more reliable than deriving a filename from a building identifier.

const BuildingBakeBuilderScript := preload("res://converters/building_bake_builder.gd")

const BUILDINGS_DIR := "res://assets/converted/rules/buildings"
const ART_DIR := "res://assets/converted/rules/art"
const MODEL_DIR := "res://assets/raw_original_content/3DDATA/Buildings"
const TEXTURE_DIR := "res://assets/raw_original_content/3DDATA/Textures"
const OUTPUT_DIR := "res://assets/converted/buildings"

# The art table has two legacy names that do not match their XBF filenames.
const MODEL_PREFIX_ALIASES := {
	"INGUCyclopseHouse": "IN_GU_CyclopseHouse",
	"PenguinRock": "OR_IN_Penguins",
}


func _init() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	var force := args.has("force")
	var art_by_building := _load_art_by_building()
	var h0_prefixes := _find_h0_prefixes()
	var converted := 0
	var skipped_existing := 0
	var skipped_without_model: PackedStringArray = []
	var skipped_without_art: PackedStringArray = []
	var failures: PackedStringArray = []

	for building_id in _building_ids():
		if not art_by_building.has(building_id):
			skipped_without_art.append(building_id)
			continue
		var source_prefix := String(MODEL_PREFIX_ALIASES.get(building_id, art_by_building[building_id]))
		if not h0_prefixes.has(_normalized_model_name(source_prefix)):
			skipped_without_model.append("%s (%s)" % [building_id, source_prefix])
			continue

		var output := OUTPUT_DIR.path_join(building_id).path_join("%s.scn" % building_id)
		if not force and ResourceLoader.exists(output):
			skipped_existing += 1
			continue

		var builder = BuildingBakeBuilderScript.new()
		builder.building_model_dir = MODEL_DIR
		builder.source_texture_dir = TEXTURE_DIR
		builder.source_prefix = source_prefix
		var scene: PackedScene = builder.build(StringName(building_id))
		if scene == null:
			failures.append(building_id)
			continue
		var err := _save_scene(scene, output)
		if err != OK:
			failures.append(building_id)
			continue
		converted += 1
		print("convert_all_buildings: wrote %s" % output)

	print("convert_all_buildings: converted %d buildings; %d already existed" % [converted, skipped_existing])
	_print_skipped("no art resource", skipped_without_art)
	_print_skipped("no H0 model", skipped_without_model)
	if not failures.is_empty():
		push_error("convert_all_buildings: failed: %s" % ", ".join(failures))
	quit(1 if not failures.is_empty() else 0)


func _building_ids() -> PackedStringArray:
	var ids: PackedStringArray = []
	var dir := DirAccess.open(BUILDINGS_DIR)
	if dir == null:
		push_error("convert_all_buildings: cannot open %s" % BUILDINGS_DIR)
		return ids
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if not dir.current_is_dir() and file_name.get_extension() == "tres":
			var config = ResourceLoader.load(BUILDINGS_DIR.path_join(file_name))
			if config != null and String(config.entity_type) == "building":
				ids.append(String(config.id))
		file_name = dir.get_next()
	dir.list_dir_end()
	ids.sort()
	return ids


func _load_art_by_building() -> Dictionary:
	var art_by_building := {}
	var dir := DirAccess.open(ART_DIR)
	if dir == null:
		push_error("convert_all_buildings: cannot open %s" % ART_DIR)
		return art_by_building
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if not dir.current_is_dir() and file_name.get_extension() == "tres":
			var config = ResourceLoader.load(ART_DIR.path_join(file_name))
			if config != null and config.has_method("field") and str(config.field("target_entity_type", "")) == "building":
				var building_id := str(config.field("target_entity", ""))
				var xaf := str(config.field("xaf", ""))
				if not building_id.is_empty() and not xaf.is_empty():
					art_by_building[building_id] = xaf
		file_name = dir.get_next()
	dir.list_dir_end()
	return art_by_building


func _find_h0_prefixes() -> Dictionary:
	var prefixes := {}
	var dir := DirAccess.open(MODEL_DIR)
	if dir == null:
		push_error("convert_all_buildings: cannot open %s" % MODEL_DIR)
		return prefixes
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		var stem := file_name.get_basename()
		if not dir.current_is_dir() and file_name.get_extension().to_lower() == "xbf" and stem.to_lower().ends_with("_h0"):
			prefixes[_normalized_model_name(stem.left(-3))] = true
		file_name = dir.get_next()
	dir.list_dir_end()
	return prefixes


func _normalized_model_name(value: String) -> String:
	return value.to_lower().replace("_", "").replace(" ", "")


func _save_scene(scene: PackedScene, output: String) -> Error:
	var absolute_output := ProjectSettings.globalize_path(output)
	var err := DirAccess.make_dir_recursive_absolute(absolute_output.get_base_dir())
	if err != OK:
		push_error("convert_all_buildings: could not create %s (%s)" % [output.get_base_dir(), error_string(err)])
		return err
	err = ResourceSaver.save(scene, output)
	if err != OK:
		push_error("convert_all_buildings: could not save %s (%s)" % [output, error_string(err)])
	return err


func _print_skipped(reason: String, building_ids: PackedStringArray) -> void:
	if not building_ids.is_empty():
		print("convert_all_buildings: skipped %d (%s): %s" % [building_ids.size(), reason, ", ".join(building_ids)])


func _parse_args(raw_args: PackedStringArray) -> Dictionary:
	var parsed := {}
	for arg in raw_args:
		if arg.begins_with("--"):
			parsed[arg.substr(2)] = true
	return parsed
