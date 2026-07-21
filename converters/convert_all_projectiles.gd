extends SceneTree

## Converts every available XBF referenced by a bullet ArtIni entry, every
## TurretMuzzleFlash referenced by a turret rule, and every ExplosionType
## referenced by a bullet.
##
## Several bullets share one XAF (for example Howitzer_B and
## KobraHowitzer_B both use shell.xaf), so each source visual is baked once and
## addressed at runtime by the normalized XAF basename.

const ModelBakeBuilderScript := preload("res://converters/model_bake_builder.gd")

const ART_DIR := "res://assets/converted/rules/art"
const BULLET_DIR := "res://assets/converted/rules/bullets"
const TURRET_DIR := "res://assets/converted/rules/turrets"
const PROJECTILE_SOURCE_DIR := "res://assets/raw_original_content/3DDATA/bullets"
const EFFECT_SOURCE_DIR := "res://assets/raw_original_content/3DDATA/Explosion"
const TEXTURE_DIR := "res://assets/raw_original_content/3DDATA/Textures"
const PROJECTILE_OUTPUT_DIR := "res://assets/converted/projectiles"
const MUZZLE_FLASH_OUTPUT_DIR := "res://assets/converted/muzzle_flashes"
const IMPACT_EFFECT_OUTPUT_DIR := "res://assets/converted/impact_effects"


func _init() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	var force := args.has("force")
	var projectile_result := _convert_visuals(
		&"projectile",
		_bullet_visual_names(),
		_find_source_models(PROJECTILE_SOURCE_DIR),
		PROJECTILE_OUTPUT_DIR,
		force,
		false
	)
	var muzzle_flash_result := _convert_visuals(
		&"muzzle flash",
		_muzzle_flash_visual_names(),
		_find_source_models(EFFECT_SOURCE_DIR),
		MUZZLE_FLASH_OUTPUT_DIR,
		force,
		true
	)
	var impact_effect_result := _convert_visuals(
		&"impact effect",
		_impact_effect_visual_names(),
		_find_source_models(EFFECT_SOURCE_DIR),
		IMPACT_EFFECT_OUTPUT_DIR,
		force,
		true
	)
	var failure_count := int(projectile_result["failures"]) \
		+ int(muzzle_flash_result["failures"]) \
		+ int(impact_effect_result["failures"])
	quit(1 if failure_count > 0 else 0)


func _convert_visuals(
		label: StringName,
		visual_names: PackedStringArray,
		source_by_name: Dictionary,
		output_dir: String,
		force: bool,
		standalone_effect: bool
	) -> Dictionary:
	var converted := 0
	var skipped_existing := 0
	var skipped_missing: PackedStringArray = []
	var failures: PackedStringArray = []
	for visual_name in visual_names:
		var source: String = source_by_name.get(visual_name, "")
		if source.is_empty():
			skipped_missing.append(visual_name)
			continue
		var output := output_dir.path_join(visual_name).path_join("%s.scn" % visual_name)
		if not force and ResourceLoader.exists(output):
			skipped_existing += 1
			continue
		var builder = ModelBakeBuilderScript.new()
		builder.source_texture_dir = TEXTURE_DIR
		builder.bake_embedded_muzzle_flash_visibility = not standalone_effect
		builder.stationary_clip_loops = not standalone_effect
		var scene: PackedScene = builder.build(source)
		if scene == null or _save_scene(scene, output) != OK:
			failures.append(visual_name)
			continue
		converted += 1
		print("convert_all_projectiles: wrote %s" % output)

	print(
		"convert_all_projectiles: converted %d %s visuals; %d already existed"
		% [converted, String(label), skipped_existing]
	)
	if not skipped_missing.is_empty():
		print(
			"convert_all_projectiles: skipped %d %s visuals without a local XBF: %s"
			% [skipped_missing.size(), String(label), ", ".join(skipped_missing)]
		)
	if not failures.is_empty():
		push_error(
			"convert_all_projectiles: failed %s visuals: %s"
			% [String(label), ", ".join(failures)]
		)
	return {
		"converted": converted,
		"skipped_existing": skipped_existing,
		"skipped_missing": skipped_missing.size(),
		"failures": failures.size(),
	}


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


func _muzzle_flash_visual_names() -> PackedStringArray:
	var art_xaf_by_id := _art_xaf_by_id()
	var names := {}
	var dir := DirAccess.open(TURRET_DIR)
	if dir == null:
		push_error("convert_all_projectiles: cannot open %s" % TURRET_DIR)
		return PackedStringArray()
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if not dir.current_is_dir() and file_name.get_extension() == "tres":
			var config = ResourceLoader.load(TURRET_DIR.path_join(file_name))
			if config != null and config.has_method("field"):
				var flash_id := String(config.field(&"turret_muzzle_flash", ""))
				var xaf := String(art_xaf_by_id.get(flash_id.to_lower(), ""))
				if not xaf.is_empty():
					names[xaf.get_file().get_basename().to_lower()] = true
		file_name = dir.get_next()
	dir.list_dir_end()
	var result: PackedStringArray = []
	for visual_name in names:
		result.append(String(visual_name))
	result.sort()
	return result


func _impact_effect_visual_names() -> PackedStringArray:
	var art_xaf_by_id := _art_xaf_by_id()
	var names := {}
	var dir := DirAccess.open(BULLET_DIR)
	if dir == null:
		push_error("convert_all_projectiles: cannot open %s" % BULLET_DIR)
		return PackedStringArray()
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if not dir.current_is_dir() and file_name.get_extension() == "tres":
			var config = ResourceLoader.load(BULLET_DIR.path_join(file_name))
			if config != null and config.has_method("list"):
				var effect_ids: Array = config.list(&"explosion_effects")
				if effect_ids.is_empty():
					var primary_id := String(config.field(&"explosion_type", ""))
					if not primary_id.is_empty():
						effect_ids.append(primary_id)
				for effect_id in effect_ids:
					var xaf := String(art_xaf_by_id.get(String(effect_id).to_lower(), ""))
					if not xaf.is_empty():
						names[xaf.get_file().get_basename().to_lower()] = true
		file_name = dir.get_next()
	dir.list_dir_end()
	var result: PackedStringArray = []
	for visual_name in names:
		result.append(String(visual_name))
	result.sort()
	return result


func _art_xaf_by_id() -> Dictionary:
	var result := {}
	var dir := DirAccess.open(ART_DIR)
	if dir == null:
		return result
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if not dir.current_is_dir() and file_name.get_extension() == "tres":
			var config = ResourceLoader.load(ART_DIR.path_join(file_name))
			if config != null and config.has_method("field"):
				var xaf := String(config.field(&"xaf", ""))
				if not xaf.is_empty():
					result[String(config.id).to_lower()] = xaf
		file_name = dir.get_next()
	dir.list_dir_end()
	return result


func _find_source_models(source_dir: String) -> Dictionary:
	var result := {}
	var dir := DirAccess.open(source_dir)
	if dir == null:
		push_error("convert_all_projectiles: cannot open %s" % source_dir)
		return result
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if not dir.current_is_dir() and file_name.get_extension().to_lower() == "xbf":
			result[file_name.get_basename().to_lower()] = source_dir.path_join(file_name)
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
