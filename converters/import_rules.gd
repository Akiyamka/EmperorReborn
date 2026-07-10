extends SceneTree

const DEFAULT_DB_PATH := "res://assets/rules.db"
const DEFAULT_OUT_DIR := "res://assets/converted/rules"
const DEFAULT_SQLITE := "sqlite3"

const ENTITY_EXPORTS := [
	{
		"table": "terrain_types",
		"folder": "terrain_types",
		"entity_type": "terrain_type",
		"script": "res://scripts/rules/terrain_type_config.gd",
	},
	{
		"table": "armour_types",
		"folder": "armour_types",
		"entity_type": "armour_type",
		"script": "res://scripts/rules/armour_type_config.gd",
	},
	{
		"table": "houses",
		"folder": "houses",
		"entity_type": "house",
		"script": "res://scripts/rules/house_config.gd",
	},
	{
		"table": "building_groups",
		"folder": "building_groups",
		"entity_type": "building_group",
		"script": "res://scripts/rules/building_group_config.gd",
	},
	{
		"table": "unit_groups",
		"folder": "unit_groups",
		"entity_type": "unit_group",
		"script": "res://scripts/rules/unit_group_config.gd",
	},
	{
		"table": "debris_types",
		"folder": "debris",
		"entity_type": "debris",
		"script": "res://scripts/rules/debris_config.gd",
	},
	{
		"table": "warheads",
		"folder": "warheads",
		"entity_type": "warhead",
		"script": "res://scripts/rules/warhead_config.gd",
	},
	{
		"table": "bullets",
		"folder": "bullets",
		"entity_type": "bullet",
		"script": "res://scripts/rules/bullet_config.gd",
	},
	{
		"table": "turrets",
		"folder": "turrets",
		"entity_type": "turret",
		"script": "res://scripts/rules/turret_config.gd",
	},
	{
		"table": "explosion_types",
		"folder": "explosions",
		"entity_type": "explosion",
		"script": "res://scripts/rules/explosion_config.gd",
	},
	{
		"table": "crate_types",
		"folder": "crates",
		"entity_type": "crate",
		"script": "res://scripts/rules/crate_config.gd",
	},
	{
		"table": "splat_types",
		"folder": "splats",
		"entity_type": "splat",
		"script": "res://scripts/rules/splat_config.gd",
	},
	{
		"table": "spice_mound_types",
		"folder": "spice_mounds",
		"entity_type": "spice_mound",
		"script": "res://scripts/rules/spice_mound_config.gd",
	},
	{
		"table": "buildings",
		"folder": "buildings",
		"entity_type": "building",
		"script": "res://scripts/rules/building_config.gd",
	},
	{
		"table": "units",
		"folder": "units",
		"entity_type": "unit",
		"script": "res://scripts/rules/unit_config.gd",
	},
]

const GENERAL_EXPORT := {
	"table": "general_settings",
	"folder": "general",
	"entity_type": "general",
	"script": "res://scripts/rules/general_rules_config.gd",
}

const ART_CONFIG_EXPORT := {
	"table": "art_configs",
	"folder": "art",
	"entity_type": "art_config",
	"script": "res://scripts/rules/art_config.gd",
}

const ART_SIDEBAR_TYPES_EXPORT := {
	"table": "art_sidebar_types",
	"folder": "art",
	"entity_type": "art_sidebar_types",
	"script": "res://scripts/rules/art_sidebar_types_config.gd",
}

const ART_SIDE_RECOLORS_EXPORT := {
	"table": "art_side_recolors",
	"folder": "art",
	"entity_type": "art_side_recolors",
	"script": "res://scripts/rules/art_side_recolors_config.gd",
}

const LOOKUP_TABLES := [
	"terrain_types",
	"armour_types",
	"houses",
	"building_groups",
	"unit_groups",
	"debris_types",
	"warheads",
	"bullets",
	"turrets",
	"explosion_types",
	"crate_types",
	"splat_types",
	"spice_mound_types",
	"buildings",
	"units",
	"building_roles",
]

const FK_TARGETS := {
	"house_id": "houses",
	"unit_group_id": "unit_groups",
	"building_group_id": "building_groups",
	"armour_type_id": "armour_types",
	"armour_modifier_terrain_id": "terrain_types",
	"debris_id": "debris_types",
	"chaos_effect_id": "explosion_types",
	"hawk_effect_id": "explosion_types",
	"damage_effect_id": "explosion_types",
	"explosion_type_id": "explosion_types",
	"chained_explosion_type_id": "explosion_types",
	"view_range_bonus_terrain_id": "terrain_types",
	"special_ground_terrain_id": "terrain_types",
	"turret_attach_id": "turrets",
	"turret_next_joint_id": "turrets",
	"get_unit_when_built_id": "units",
	"bullet_id": "bullets",
	"warhead_id": "warheads",
	"terrain_type_id": "terrain_types",
	"required_building_id": "buildings",
	"building_id": "buildings",
	"unit_id": "units",
	"turret_id": "turrets",
	"role_id": "building_roles",
	"crate_type_id": "crate_types",
}

const BOOL_COLUMNS := {
	"houses": ["is_sub_house"],
	"buildings": [
		"can_be_engineered",
		"can_be_primary",
		"is_con_yard",
		"ai_exit",
		"ai_manufacturing",
		"selectable",
		"ai_defence",
		"ai_critical",
		"ai_core",
		"ai_resource",
		"exclude_from_skirmish_lose",
		"exclude_from_campaign_lose",
		"upgraded_primary_required",
		"disable_with_low_power",
		"disable_if_no_spice_on_map",
		"hide_unit_on_radar",
		"counts_for_stats",
		"gets_height_advantage",
	],
	"units": [
		"tasty_to_worms",
		"can_move_any_direction",
		"can_be_deviated",
		"can_self_repair",
		"can_be_repaired",
		"infantry",
		"crushable",
		"crushes",
		"starportable",
		"ai_special",
		"ai_tank",
		"ai_foot",
		"ai_air",
		"ai_uncontrolled",
		"ai_critical",
		"gets_height_advantage",
		"upgraded_primary_required",
		"crate_gift",
		"can_be_suppressed",
		"can_fly",
		"can_die",
		"cant_be_leeched",
		"advanced_carryall",
		"projectable",
		"circles",
		"selectable",
		"stealthed_when_still",
		"exclude_from_skirmish_lose",
		"can_be_engineered",
	],
	"bullets": [
		"blow_up",
		"reduce_damage_with_distance",
		"anti_aircraft",
		"anti_ground",
		"homing",
		"continuous",
		"trajectory",
		"burnt",
		"ignites",
		"gassed",
		"is_laser",
		"leech",
		"infantry",
		"damage_column",
		"deviate",
		"beserk",
		"retreat",
	],
	"turrets": [
		"turret_disable_if_unit_deployed",
		"turret_disable_if_unit_undeployed",
	],
	"explosion_configs": ["face_camera"],
	"unit_veterancy_levels": ["can_self_repair", "elite", "stealthed_when_still"],
	"general_settings": ["replica_should_fire"],
	"art_configs": ["load_flag_only_preplaced"],
}

const ENTITY_ALIASES := {
	"units": ["unit", "units"],
	"buildings": ["building", "buildings"],
	"bullets": ["bullet", "bullets"],
	"splat_types": ["splat_type", "splat_types"],
	"spice_mound_types": ["spice_mound_type", "spice_mound_types"],
}

const EXPLOSION_EFFECT_ENTITY_TYPES := {
	"units": "unit",
	"buildings": "building",
	"bullets": "bullet",
	"splat_types": "splat_type",
	"spice_mound_types": "spice_mound_type",
}

const RESOURCE_LINK_ENTITY_TYPES := {
	"units": "unit",
	"buildings": "building",
	"splat_types": "splat_type",
	"spice_mound_types": "spice_mound_type",
}

const ART_ENTITY_TABLES := {
	"unit": "units",
	"building": "buildings",
	"bullet": "bullets",
	"explosion_type": "explosion_types",
	"crate_type": "crate_types",
	"debris_type": "debris_types",
	"splat_type": "splat_types",
	"spice_mound_type": "spice_mound_types",
}

var _db_path := DEFAULT_DB_PATH
var _out_dir := DEFAULT_OUT_DIR
var _sqlite_bin := DEFAULT_SQLITE
var _failed := false
var _schema_types := {}


func _init() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	_db_path = _globalize_path(String(args.get("db", DEFAULT_DB_PATH)))
	_out_dir = String(args.get("out", DEFAULT_OUT_DIR))
	_sqlite_bin = String(args.get("sqlite", DEFAULT_SQLITE))

	if not FileAccess.file_exists(_db_path):
		push_error("import_rules: database does not exist: %s" % _db_path)
		quit(1)
		return

	if args.has("clean"):
		_clean_tres(_out_dir)

	var err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_out_dir))
	if err != OK:
		push_error("import_rules: could not create %s (%s)" % [_out_dir, error_string(err)])
		quit(1)
		return

	var lookups := _load_name_lookups()
	var used_names_by_folder := {}
	var written := 0

	for export in ENTITY_EXPORTS:
		var folder := _out_dir.path_join(String(export["folder"]))
		var rows := _query_table(export["table"], "SELECT * FROM %s ORDER BY id" % export["table"])
		for row in rows:
			var config := _build_entity_config(lookups, export, row)
			var filename := _unique_filename(folder, String(config["id"]), used_names_by_folder)
			if _save_config(folder.path_join(filename), export, config) == OK:
				written += 1

	var general_rows := _query_table("general_settings", "SELECT * FROM general_settings WHERE id = 1")
	if not general_rows.is_empty():
		var config := _build_general_config(lookups, general_rows[0])
		if _save_config(_out_dir.path_join(GENERAL_EXPORT["folder"]).path_join("general.tres"), GENERAL_EXPORT, config) == OK:
			written += 1

	var art_folder := _out_dir.path_join(String(ART_CONFIG_EXPORT["folder"]))
	var art_rows := _query_table("art_configs", "SELECT * FROM art_configs ORDER BY id")
	for row in art_rows:
		var config := _build_art_config(lookups, row)
		var filename := _unique_filename(art_folder, String(config["id"]), used_names_by_folder)
		if _save_config(art_folder.path_join(filename), ART_CONFIG_EXPORT, config) == OK:
			written += 1

	var sidebar_types := _query_table("art_sidebar_types", "SELECT * FROM art_sidebar_types ORDER BY seq")
	if not sidebar_types.is_empty():
		var config := _build_art_sidebar_types_config(sidebar_types)
		if _save_config(art_folder.path_join("sidebar_types.tres"), ART_SIDEBAR_TYPES_EXPORT, config) == OK:
			written += 1

	var side_recolors := _query_table("art_side_recolors", "SELECT * FROM art_side_recolors ORDER BY side_id")
	if not side_recolors.is_empty():
		var config := _build_art_side_recolors_config(side_recolors)
		if _save_config(art_folder.path_join("side_recolors.tres"), ART_SIDE_RECOLORS_EXPORT, config) == OK:
			written += 1

	if _failed:
		quit(1)
		return

	print("import_rules: wrote %d rules resources to %s" % [written, _out_dir])
	quit(0)


func _load_name_lookups() -> Dictionary:
	var result := {}
	for table in LOOKUP_TABLES:
		var lookup := {}
		for row in _query("SELECT id, name FROM %s" % table):
			lookup[int(row["id"])] = String(row["name"])
		result[table] = lookup
	return result


func _build_entity_config(lookups: Dictionary, export: Dictionary, row: Dictionary) -> Dictionary:
	var table := String(export["table"])
	var fields := _row_fields(lookups, table, row, ["id", "name"])
	fields.merge(_extra_fields(lookups, table, int(row["id"])), true)

	return {
		"id": String(row["name"]),
		"entity_type": String(export["entity_type"]),
		"source_table": table,
		"source_id": int(row["id"]),
		"fields": fields,
		"lists": _child_lists(lookups, table, int(row["id"])),
		"links": _child_links(table, int(row["id"])),
	}


func _build_general_config(lookups: Dictionary, row: Dictionary) -> Dictionary:
	return {
		"id": "general",
		"entity_type": "general",
		"source_table": "general_settings",
		"source_id": int(row["id"]),
		"fields": _row_fields(lookups, "general_settings", row, ["id"]),
		"lists": {},
		"links": {},
	}


func _build_art_config(lookups: Dictionary, row: Dictionary) -> Dictionary:
	var target_entity_type := String(row["entity_type"])
	var fields := _row_fields(lookups, "art_configs", row, ["id", "art_name", "entity_type", "entity_id"])
	fields["target_entity_type"] = target_entity_type

	if row["entity_id"] != null:
		fields["target_entity_source_id"] = int(row["entity_id"])
		var target_table = ART_ENTITY_TABLES.get(target_entity_type)
		if target_table != null:
			var lookup: Dictionary = lookups[target_table]
			var target_id := int(row["entity_id"])
			if lookup.has(target_id):
				fields["target_entity"] = lookup[target_id]
			else:
				push_error("import_rules: could not resolve art_configs.entity_id=%d via %s" % [target_id, target_table])
				_failed = true

	return {
		"id": String(row["art_name"]),
		"entity_type": String(ART_CONFIG_EXPORT["entity_type"]),
		"source_table": "art_configs",
		"source_id": int(row["id"]),
		"fields": fields,
		"lists": {},
		"links": {},
	}


func _build_art_sidebar_types_config(rows: Array) -> Dictionary:
	var entries := []
	var names := []
	for row in rows:
		var entry := {
			"seq": int(row["seq"]),
			"name": String(row["name"]),
		}
		entries.append(entry)
		names.append(entry["name"])

	return {
		"id": "sidebar_types",
		"entity_type": String(ART_SIDEBAR_TYPES_EXPORT["entity_type"]),
		"source_table": "art_sidebar_types",
		"source_id": -1,
		"fields": {},
		"lists": {
			"entries": entries,
			"names": names,
		},
		"links": {},
	}


func _build_art_side_recolors_config(rows: Array) -> Dictionary:
	var recolors := []
	for row in rows:
		recolors.append({
			"side_id": int(row["side_id"]),
			"red": int(row["red"]),
			"green": int(row["green"]),
			"blue": int(row["blue"]),
		})

	return {
		"id": "side_recolors",
		"entity_type": String(ART_SIDE_RECOLORS_EXPORT["entity_type"]),
		"source_table": "art_side_recolors",
		"source_id": -1,
		"fields": {},
		"lists": {
			"recolors": recolors,
		},
		"links": {},
	}


func _extra_fields(lookups: Dictionary, table: String, source_id: int) -> Dictionary:
	var fields := {}

	if table == "warheads":
		var armour_damage := {}
		for row in _query("SELECT a.name, wd.damage_percent FROM warhead_armour_damage wd JOIN armour_types a ON a.id = wd.armour_type_id WHERE wd.warhead_id = %d ORDER BY a.sort_order, a.id" % source_id):
			armour_damage[String(row["name"])] = _typed_value("warhead_armour_damage", "damage_percent", row["damage_percent"])
		if not armour_damage.is_empty():
			fields["armour_damage"] = armour_damage
	elif table == "explosion_types":
		var configs := _query_table("explosion_configs", "SELECT * FROM explosion_configs WHERE explosion_type_id = %d" % source_id)
		if not configs.is_empty():
			fields.merge(_row_fields(lookups, "explosion_configs", configs[0], ["explosion_type_id"]), true)

	return fields


func _row_fields(lookups: Dictionary, table: String, row: Dictionary, skip: Array) -> Dictionary:
	var fields := {}
	for column in row.keys():
		if skip.has(column):
			continue
		var value = _convert_value(lookups, table, String(column), row[column])
		if value != null:
			fields[_field_key(String(column))] = value
	return fields


func _child_lists(lookups: Dictionary, table: String, source_id: int) -> Dictionary:
	var lists := {}

	if table == "units":
		_set_if_any(lists, "turrets", _names("SELECT t.name FROM unit_turrets ut JOIN turrets t ON t.id = ut.turret_id WHERE ut.unit_id = %d ORDER BY ut.seq" % source_id))
		_set_if_any(lists, "terrain", _names("SELECT t.name FROM unit_terrain ut JOIN terrain_types t ON t.id = ut.terrain_type_id WHERE ut.unit_id = %d ORDER BY t.sort_order, t.id" % source_id))
		_set_if_any(lists, "primary_buildings", _names("SELECT b.name FROM unit_primary_buildings up JOIN buildings b ON b.id = up.building_id WHERE up.unit_id = %d ORDER BY b.id" % source_id))
		_set_if_any(lists, "secondary_buildings", _names("SELECT b.name FROM unit_secondary_buildings us JOIN buildings b ON b.id = us.building_id WHERE us.unit_id = %d ORDER BY b.id" % source_id))

		var veterancy := []
		for row in _query_table("unit_veterancy_levels", "SELECT * FROM unit_veterancy_levels WHERE unit_id = %d ORDER BY level_order" % source_id):
			veterancy.append(_row_fields(lookups, "unit_veterancy_levels", row, ["id", "unit_id"]))
		_set_if_any(lists, "veterancy_levels", veterancy)

	elif table == "buildings":
		var occupy_rows := []
		for row in _query("SELECT pattern FROM building_occupy_rows WHERE building_id = %d ORDER BY row_index" % source_id):
			occupy_rows.append(String(row["pattern"]))
		_set_if_any(lists, "occupy_rows", occupy_rows)
		_set_if_any(lists, "terrain", _names("SELECT t.name FROM building_terrain bt JOIN terrain_types t ON t.id = bt.terrain_type_id WHERE bt.building_id = %d ORDER BY t.sort_order, t.id" % source_id))
		_set_if_any(lists, "requires_primary", _names("SELECT b.name FROM building_requires_primary bp JOIN buildings b ON b.id = bp.required_building_id WHERE bp.building_id = %d ORDER BY b.id" % source_id))
		_set_if_any(lists, "requires_secondary", _names("SELECT b.name FROM building_requires_secondary bs JOIN buildings b ON b.id = bs.required_building_id WHERE bs.building_id = %d ORDER BY b.id" % source_id))

		var deploy_points := []
		for row in _query("SELECT seq, tile_x, tile_y, angle FROM building_deploy_points WHERE building_id = %d ORDER BY seq" % source_id):
			deploy_points.append(_compact_dict({
				"seq": _typed_value("building_deploy_points", "seq", row["seq"]),
				"tile_x": _typed_value("building_deploy_points", "tile_x", row["tile_x"]),
				"tile_y": _typed_value("building_deploy_points", "tile_y", row["tile_y"]),
				"angle": _typed_value("building_deploy_points", "angle", row["angle"]),
			}))
		_set_if_any(lists, "deploy_points", deploy_points)
		_set_if_any(lists, "roles", _names("SELECT r.name FROM building_role_tags bt JOIN building_roles r ON r.id = bt.role_id WHERE bt.building_id = %d ORDER BY r.name" % source_id))

	elif table == "crate_types":
		_set_if_any(lists, "terrain", _names("SELECT t.name FROM crate_terrain ct JOIN terrain_types t ON t.id = ct.terrain_type_id WHERE ct.crate_type_id = %d ORDER BY t.sort_order, t.id" % source_id))

	var effect_type = EXPLOSION_EFFECT_ENTITY_TYPES.get(table)
	if effect_type != null:
		_set_if_any(
			lists,
			"explosion_effects",
			_names("SELECT e.name FROM entity_explosion_effects ee JOIN explosion_types e ON e.id = ee.explosion_type_id WHERE ee.entity_type = %s AND ee.entity_id = %d ORDER BY ee.seq" % [_sql_value(effect_type), source_id])
		)

	return lists


func _child_links(table: String, source_id: int) -> Dictionary:
	var links := {}

	var resource_type = RESOURCE_LINK_ENTITY_TYPES.get(table)
	if resource_type != null:
		var resources := []
		for row in _query("SELECT seq, target_name, source_line FROM entity_resource_links WHERE entity_type = %s AND entity_id = %d ORDER BY seq" % [_sql_value(resource_type), source_id]):
			resources.append(_compact_dict({
				"seq": _typed_value("entity_resource_links", "seq", row["seq"]),
				"target": row["target_name"],
				"source_line": _typed_value("entity_resource_links", "source_line", row["source_line"]),
			}))
		_set_if_any(links, "resources", resources)

	var aliases = ENTITY_ALIASES.get(table, [table])
	var custom_fields := []
	for alias in aliases:
		for row in _query("SELECT entity_type, key, value, source_line FROM custom_fields WHERE entity_type = %s AND entity_id = %d ORDER BY id" % [_sql_value(alias), source_id]):
			custom_fields.append(_compact_dict({
				"entity_type": row["entity_type"],
				"key": row["key"],
				"value": row["value"],
				"source_line": _typed_value("custom_fields", "source_line", row["source_line"]),
			}))
	_set_if_any(links, "custom_fields", custom_fields)

	return links


func _convert_value(lookups: Dictionary, table: String, column: String, value):
	if value == null:
		return null

	var target_table = FK_TARGETS.get(column)
	if target_table != null:
		var lookup: Dictionary = lookups[target_table]
		var id := int(value)
		if not lookup.has(id):
			push_error("import_rules: could not resolve %s.%s=%s via %s" % [table, column, value, target_table])
			_failed = true
			return null
		return lookup[id]

	if BOOL_COLUMNS.get(table, []).has(column):
		return bool(int(value))

	return value


func _field_key(column: String) -> String:
	if column.ends_with("_id"):
		return column.substr(0, column.length() - 3)
	return column


func _names(sql: String) -> Array:
	var result := []
	for row in _query(sql):
		result.append(String(row["name"]))
	return result


func _set_if_any(target: Dictionary, key: String, value) -> void:
	if value:
		target[key] = value


func _compact_dict(value: Dictionary) -> Dictionary:
	var result := {}
	for key in value.keys():
		if value[key] != null:
			result[key] = value[key]
	return result


func _save_config(path: String, export: Dictionary, config: Dictionary) -> Error:
	var script := load(String(export["script"]))
	if script == null:
		push_error("import_rules: could not load script %s" % export["script"])
		_failed = true
		return ERR_FILE_CANT_OPEN

	var resource: Resource = script.new()
	resource.id = StringName(config["id"])
	resource.entity_type = StringName(config["entity_type"])
	resource.source_table = StringName(config["source_table"])
	resource.source_id = int(config["source_id"])
	resource.fields = config["fields"]
	resource.lists = config["lists"]
	resource.links = config["links"]

	var absolute_output := ProjectSettings.globalize_path(path)
	var err := DirAccess.make_dir_recursive_absolute(absolute_output.get_base_dir())
	if err != OK:
		push_error("import_rules: could not create %s (%s)" % [path.get_base_dir(), error_string(err)])
		_failed = true
		return err

	err = ResourceSaver.save(resource, path)
	if err != OK:
		push_error("import_rules: could not save %s (%s)" % [path, error_string(err)])
		_failed = true
		return err

	err = _format_saved_tres(path)
	if err != OK:
		_failed = true
	return err


func _format_saved_tres(path: String) -> Error:
	var absolute_path := ProjectSettings.globalize_path(path)
	var file := FileAccess.open(absolute_path, FileAccess.READ)
	if file == null:
		var err := FileAccess.get_open_error()
		push_error("import_rules: could not open %s for formatting (%s)" % [path, error_string(err)])
		return err

	var text := file.get_as_text()
	file.close()

	var formatted := _format_tres_text(text)
	file = FileAccess.open(absolute_path, FileAccess.WRITE)
	if file == null:
		var err := FileAccess.get_open_error()
		push_error("import_rules: could not write formatted %s (%s)" % [path, error_string(err)])
		return err

	file.store_string(formatted)
	file.close()
	return OK


func _format_tres_text(text: String) -> String:
	var lines := text.split("\n")
	var output := PackedStringArray()
	var i := 0

	while i < lines.size():
		var line := String(lines[i])
		var separator := line.find(" = ")
		if separator == -1:
			output.append(line)
			i += 1
			continue

		var prefix := line.substr(0, separator)
		var value := line.substr(separator + 3).strip_edges()
		if not (value.begins_with("{") or value.begins_with("[")):
			output.append(line)
			i += 1
			continue

		var balance := _variant_container_balance(value)
		while balance > 0 and i + 1 < lines.size():
			i += 1
			var next_line := String(lines[i]).strip_edges()
			value += "\n" + next_line
			balance += _variant_container_balance(next_line)

		output.append("%s = %s" % [prefix, _format_variant_container(value)])
		i += 1

	var result := "\n".join(output)
	return result if result.ends_with("\n") else result + "\n"


func _format_variant_container(value: String) -> String:
	value = value.strip_edges()
	var result := ""
	var indent := 0
	var in_string := false
	var escaped := false
	var i := 0

	while i < value.length():
		var character := value[i]

		if in_string:
			result += character
			if escaped:
				escaped = false
			elif character == "\\":
				escaped = true
			elif character == "\"":
				in_string = false
			i += 1
			continue

		if character == "\"":
			in_string = true
			result += character
		elif character == "{" or character == "[":
			var closing := "}" if character == "{" else "]"
			var next_index := _next_non_whitespace(value, i + 1)
			if next_index != -1 and value[next_index] == closing:
				result += character + closing
				i = next_index
			else:
				result += character
				indent += 1
				result += "\n" + _indent_string(indent)
		elif character == "}" or character == "]":
			indent = maxi(indent - 1, 0)
			result = result.strip_edges(false, true)
			result += "\n" + _indent_string(indent) + character
		elif character == ",":
			result += ","
			var next_index := _next_non_whitespace(value, i + 1)
			if next_index != -1 and value[next_index] != "}" and value[next_index] != "]":
				result += "\n" + _indent_string(indent)
		elif character == ":":
			result += ": "
		elif character == " " or character == "\t" or character == "\n" or character == "\r":
			pass
		else:
			result += character

		i += 1

	return result


func _variant_container_balance(value: String) -> int:
	var balance := 0
	var in_string := false
	var escaped := false

	for i in value.length():
		var character := value[i]
		if in_string:
			if escaped:
				escaped = false
			elif character == "\\":
				escaped = true
			elif character == "\"":
				in_string = false
			continue

		if character == "\"":
			in_string = true
		elif character == "{" or character == "[":
			balance += 1
		elif character == "}" or character == "]":
			balance -= 1

	return balance


func _next_non_whitespace(value: String, start: int) -> int:
	var i := start
	while i < value.length():
		var character := value[i]
		if character != " " and character != "\t" and character != "\n" and character != "\r":
			return i
		i += 1
	return -1


func _indent_string(count: int) -> String:
	var result := ""
	for i in count:
		result += "\t"
	return result


func _unique_filename(folder: String, raw_name: String, used_names_by_folder: Dictionary) -> String:
	var used: Dictionary = used_names_by_folder.get(folder, {})
	var stem := _sanitize_filename(raw_name)
	var filename := "%s.tres" % stem
	if not used.has(filename):
		used[filename] = true
		used_names_by_folder[folder] = used
		return filename

	var suffix := 2
	while true:
		filename = "%s_%d.tres" % [stem, suffix]
		if not used.has(filename):
			used[filename] = true
			used_names_by_folder[folder] = used
			return filename
		suffix += 1

	return "%s.tres" % stem


func _sanitize_filename(value: String) -> String:
	var result := ""
	for i in value.strip_edges().length():
		var character := value.strip_edges()[i]
		var code := character.unicode_at(0)
		var valid := (
			(code >= 65 and code <= 90)
			or (code >= 97 and code <= 122)
			or (code >= 48 and code <= 57)
			or character == "_"
			or character == "."
			or character == "-"
		)
		result += character if valid else "_"

	result = result.strip_edges().trim_prefix(".").trim_prefix("_").trim_suffix(".").trim_suffix("_")
	while result.begins_with(".") or result.begins_with("_"):
		result = result.substr(1)
	while result.ends_with(".") or result.ends_with("_"):
		result = result.substr(0, result.length() - 1)
	return result if not result.is_empty() else "unnamed"


func _query(sql: String) -> Array:
	var output := []
	var args := PackedStringArray(["-json", _db_path, sql])
	var code := OS.execute(_sqlite_bin, args, output, true)
	if code != 0:
		push_error("import_rules: sqlite failed (%d): %s\n%s" % [code, sql, "".join(output)])
		_failed = true
		return []

	var text := "".join(output).strip_edges()
	if text.is_empty():
		return []

	var parsed = JSON.parse_string(text)
	if parsed is Array:
		return parsed

	push_error("import_rules: could not parse sqlite JSON for query: %s" % sql)
	_failed = true
	return []


func _query_table(table: String, sql: String) -> Array:
	var rows := _query(sql)
	for row in rows:
		_normalize_row(table, row)
	return rows


func _normalize_row(table: String, row: Dictionary) -> void:
	for column in row.keys():
		row[column] = _typed_value(table, String(column), row[column])


func _typed_value(table: String, column: String, value):
	if value == null:
		return null

	var type_name := String(_table_schema(table).get(column, "")).to_upper()
	if type_name.contains("INT"):
		return int(value)
	if type_name.contains("REAL") or type_name.contains("FLOA") or type_name.contains("DOUB"):
		return float(value)
	return value


func _table_schema(table: String) -> Dictionary:
	if _schema_types.has(table):
		return _schema_types[table]

	var schema := {}
	for row in _query("PRAGMA table_info(%s)" % table):
		schema[String(row["name"])] = String(row["type"])
	_schema_types[table] = schema
	return schema


func _sql_value(value) -> String:
	if value == null:
		return "NULL"
	if value is int or value is float:
		return str(value)
	return "'%s'" % String(value).replace("'", "''")


func _clean_tres(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return

	dir.list_dir_begin()
	var item := dir.get_next()
	while not item.is_empty():
		if item.begins_with("."):
			item = dir.get_next()
			continue

		var item_path := path.path_join(item)
		if dir.current_is_dir():
			_clean_tres(item_path)
		elif item.get_extension().to_lower() == "tres":
			var err := DirAccess.remove_absolute(ProjectSettings.globalize_path(item_path))
			if err != OK:
				push_error("import_rules: could not remove %s (%s)" % [item_path, error_string(err)])
				_failed = true
		item = dir.get_next()
	dir.list_dir_end()


func _globalize_path(path: String) -> String:
	if path.begins_with("res://") or path.begins_with("user://"):
		return ProjectSettings.globalize_path(path)
	return ProjectSettings.globalize_path(path) if path.is_relative_path() else path


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
