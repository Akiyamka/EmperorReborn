class_name RulesCatalog
extends Resource

const DEFAULT_RULES_ROOT := "res://assets/converted/rules"
const RuleEntityConfigScript := preload("res://scripts/rules/rule_entity_config.gd")

## Non-roster building_group/roles values: Wall uses an interactive line pick;
## RefineryDock is an in-place refinery state upgrade. Neither follows the
## plain "queue then place" flow, so they are surfaced through their own methods
## below (wall_building_ids_for_house/refinery_dock_building_ids_for_house)
## rather than mixed into the general roster.
const _EXCLUDED_BUILDING_GROUPS: Array[StringName] = [&"Wall", &"RefineryDock"]
const _EXCLUDED_ROLES: Array[StringName] = [&"Wall", &"Dockable"]
const _WALL_BUILDING_GROUP := &"Wall"
const _REFINERY_DOCK_BUILDING_GROUP := &"RefineryDock"
const _MCV_UNIT_IDS: Array[StringName] = [&"ATMCV", &"HKMCV", &"ORMCV"]

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


## Roster of player-buildable buildings for a house: everything a house could
## potentially construct through the building panel, regardless of whether the
## technology tree currently unlocks it. Excludes the Construction Yard
## (built only via MCV deploy), Wall (its own placement mode), RefineryDock
## (an in-place refinery upgrade),
## and decorative Incidental scenery (no requires_primary, so they never gate
## behind the tech tree).
func buildable_building_ids_for_house(
		house_id: StringName, subhouse_ids: Array[StringName] = []
) -> Array[StringName]:
	var result: Array[StringName] = []
	var bucket: Dictionary = _by_type.get("building", {})
	var keys := bucket.keys()
	keys.sort()
	for id_key in keys:
		var config: Resource = bucket[id_key]
		if not _matches_house(config, house_id, subhouse_ids):
			continue
		if _is_buildable_roster_building(config):
			result.append(StringName(id_key))
	return result


## Wall counterpart to buildable_building_ids_for_house(): the id(s) of the
## house's Wall building_group entries, so BuildingController can list wall
## as a normal grid slot while still routing its click through the wall
## line-picking flow instead of the plain queue-then-place flow.
func wall_building_ids_for_house(
		house_id: StringName, subhouse_ids: Array[StringName] = []
) -> Array[StringName]:
	return _building_ids_for_group(house_id, subhouse_ids, _WALL_BUILDING_GROUP)


## RefineryDock counterpart to buildable_building_ids_for_house(): the id(s)
## of the house's RefineryDock building_group entries, so
## BuildingUpgradeController can list the dock as a normal upgrade grid slot
## while still routing its click through the automatic refinery-upgrade flow
## instead of the plain global-purchase flow.
func refinery_dock_building_ids_for_house(
		house_id: StringName, subhouse_ids: Array[StringName] = []
) -> Array[StringName]:
	return _building_ids_for_group(house_id, subhouse_ids, _REFINERY_DOCK_BUILDING_GROUP)


## Upgrades are not the same roster as constructible buildings: Construction
## Yards are deployed rather than built, but their global upgrade must still be
## purchasable from the upgrade panel.
func upgrade_building_ids_for_house(
		house_id: StringName, subhouse_ids: Array[StringName] = []
) -> Array[StringName]:
	var result: Array[StringName] = []
	var bucket: Dictionary = _by_type.get("building", {})
	var keys := bucket.keys()
	keys.sort()
	for id_key in keys:
		var config: Resource = bucket[id_key]
		if not _matches_house(config, house_id, subhouse_ids):
			continue
		if float(config.field(&"upgrade_cost", 0)) <= 0.0:
			continue
		if int(config.field(&"upgrade_tech_level", 0)) <= 0:
			continue
		result.append(StringName(id_key))
	return result


## Unit counterpart to buildable_building_ids_for_house(): everything a house
## could potentially produce through the unit panel, regardless of whether the
## technology tree currently unlocks it. A producible unit is one with a
## production entry point (non-empty primary_buildings) and a real price --
## cost 0 marks palace weapons (e.g. ATHawkWeapon) that list a primary
## building but are fired, not bought. Shared units (Harvester, Carryall)
## carry no house field and belong to every roster. The three concrete MCV
## entries are also present in every player's candidate roster so capturing a
## foreign factory can expose its MCV; the tech tree still hides every variant
## whose own factory is not currently owned.
func producible_unit_ids_for_house(
		house_id: StringName, subhouse_ids: Array[StringName] = []
) -> Array[StringName]:
	var result: Array[StringName] = []
	var bucket: Dictionary = _by_type.get("unit", {})
	var keys := bucket.keys()
	keys.sort()
	for id_key in keys:
		var config: Resource = bucket[id_key]
		var config_house := String(config.field(&"house", ""))
		var is_mcv := StringName(id_key) in _MCV_UNIT_IDS
		if (
			not is_mcv
			and not config_house.is_empty()
			and not _matches_house(config, house_id, subhouse_ids)
		):
			continue
		if config.list(&"primary_buildings").is_empty():
			continue
		if int(config.field(&"cost", 0)) <= 0:
			continue
		result.append(StringName(id_key))
	return result


func _building_ids_for_group(
		house_id: StringName, subhouse_ids: Array[StringName], building_group: StringName
) -> Array[StringName]:
	var result: Array[StringName] = []
	var bucket: Dictionary = _by_type.get("building", {})
	var keys := bucket.keys()
	keys.sort()
	for id_key in keys:
		var config: Resource = bucket[id_key]
		if not _matches_house(config, house_id, subhouse_ids):
			continue
		if StringName(String(config.field(&"building_group", ""))) == building_group:
			result.append(StringName(id_key))
	return result


func _matches_house(
		config: Resource, house_id: StringName, subhouse_ids: Array[StringName]
) -> bool:
	var config_house := StringName(String(config.field(&"house", "")))
	return config_house == house_id or subhouse_ids.has(config_house)


func _is_buildable_roster_building(config: Resource) -> bool:
	if bool(config.field(&"is_con_yard", false)):
		return false

	var building_group := StringName(String(config.field(&"building_group", "")))
	if building_group in _EXCLUDED_BUILDING_GROUPS:
		return false

	var roles: Array = config.list(&"roles")
	if roles.size() == 1 and StringName(String(roles[0])) in _EXCLUDED_ROLES:
		return false

	return not config.list(&"requires_primary").is_empty()


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
