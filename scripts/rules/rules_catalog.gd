class_name RulesCatalog
extends Resource

const DEFAULT_RULES_ROOT := "res://assets/converted/rules"
const RuleEntityConfigScript := preload("res://scripts/rules/rule_entity_config.gd")

@export_dir var rules_root := DEFAULT_RULES_ROOT

var _by_type: Dictionary = {}
var _all: Array = []


func reload() -> void:
	load_from_path(rules_root)


func load_from_path(root_path: String) -> void:
	_by_type.clear()
	_all.clear()

	if DirAccess.open(root_path) == null:
		push_warning("Rules root does not exist: %s" % root_path)
		return

	_scan_dir(root_path)


func get_entity(entity_type: StringName, entity_id: StringName) -> Resource:
	var bucket: Dictionary = _by_type.get(String(entity_type), {})
	return bucket.get(String(entity_id))


func has_entity(entity_type: StringName, entity_id: StringName) -> bool:
	var bucket: Dictionary = _by_type.get(String(entity_type), {})
	return bucket.has(String(entity_id))


func all(entity_type: StringName = &"") -> Array:
	if String(entity_type).is_empty():
		return _all.duplicate()

	var bucket: Dictionary = _by_type.get(String(entity_type), {})
	return bucket.values()


func ids(entity_type: StringName) -> Array:
	var bucket: Dictionary = _by_type.get(String(entity_type), {})
	var result := bucket.keys()
	result.sort()
	return result


func unit(entity_id: StringName) -> Resource:
	return get_entity(&"unit", entity_id)


func building(entity_id: StringName) -> Resource:
	return get_entity(&"building", entity_id)


func turret(entity_id: StringName) -> Resource:
	return get_entity(&"turret", entity_id)


func bullet(entity_id: StringName) -> Resource:
	return get_entity(&"bullet", entity_id)


func warhead(entity_id: StringName) -> Resource:
	return get_entity(&"warhead", entity_id)


func general_rules() -> Resource:
	return get_entity(&"general", &"general")


func _scan_dir(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		push_warning("Could not open rules directory: %s" % path)
		return

	dir.list_dir_begin()
	var item := dir.get_next()
	while not item.is_empty():
		if item.begins_with("."):
			item = dir.get_next()
			continue

		var item_path := path.path_join(item)
		if dir.current_is_dir():
			_scan_dir(item_path)
		elif item.get_extension().to_lower() == "tres":
			_load_config(item_path)

		item = dir.get_next()
	dir.list_dir_end()


func _load_config(path: String) -> void:
	var resource := ResourceLoader.load(path)
	if not resource is RuleEntityConfigScript:
		return

	var config := resource
	if String(config.id).is_empty() or String(config.entity_type).is_empty():
		push_warning("Rules config is missing id or entity_type: %s" % path)
		return

	var type_key := String(config.entity_type)
	var id_key := String(config.id)
	if not _by_type.has(type_key):
		_by_type[type_key] = {}

	var bucket: Dictionary = _by_type[type_key]
	if bucket.has(id_key):
		push_warning("Duplicate %s rules id %s in %s" % [type_key, id_key, path])

	bucket[id_key] = config
	_all.append(config)
