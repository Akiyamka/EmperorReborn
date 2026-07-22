class_name BuildingDefinitionCatalog
extends RefCounted

const Manifest := preload("res://resources/buildings/generated_building_manifest.gd")
var _cache: Dictionary = {}
var _construction_yard_house_ids: Array[StringName] = []
var _construction_yard_houses_loaded := false


func definition(config_id: StringName) -> Resource:
	if _cache.has(config_id):
		return _cache[config_id] as Resource
	var path := String(Manifest.DEFINITION_PATHS.get(config_id, ""))
	var result := load(path) as Resource if not path.is_empty() and ResourceLoader.exists(path) else null
	_cache[config_id] = result
	return result


func all_ids() -> Array[StringName]:
	var result: Array[StringName] = []
	result.assign(Manifest.DEFINITION_PATHS.keys())
	result.sort()
	return result


func buildable_ids_for_house(house_id: StringName, subhouse_ids: Array[StringName]) -> Array[StringName]:
	var result: Array[StringName] = []
	for config_id in all_ids():
		var item = definition(config_id)
		if _belongs_to_house_or_capturable_house(item, house_id, subhouse_ids) \
		and item.building_group_id not in [&"Wall", &"RefineryDock"] \
		and not item.primary_building_ids.is_empty() and item.cost > 0:
			result.append(config_id)
	return _collapse_building_groups(result, house_id, subhouse_ids)


func wall_ids_for_house(house_id: StringName, subhouse_ids: Array[StringName]) -> Array[StringName]:
	var result: Array[StringName] = []
	for config_id in all_ids():
		var item = definition(config_id)
		if _belongs_to_house_or_capturable_house(item, house_id, subhouse_ids) \
		and item.building_group_id == &"Wall":
			result.append(config_id)
	return _collapse_building_groups(result, house_id, subhouse_ids)


func upgrade_ids_for_house(house_id: StringName, subhouse_ids: Array[StringName]) -> Array[StringName]:
	var result: Array[StringName] = []
	for config_id in all_ids():
		var item = definition(config_id)
		if _belongs_to_house_or_capturable_house(item, house_id, subhouse_ids) \
		and item.upgrade_cost > 0 and item.upgrade_tech_level > 0:
			result.append(config_id)
	return result


func _belongs_to_house(item: Resource, house_id: StringName, subhouse_ids: Array[StringName]) -> bool:
	return item != null and (item.house_id == &"" or item.house_id == house_id or item.house_id in subhouse_ids)


## The sidebar roster is configured once when a match starts. Great-House
## buildings must therefore be present (initially disabled) even when they do
## not belong to the player's starting House, so capturing that House's
## Construction Yard can reveal its tree without rebuilding the UI. Sub-house
## entries remain limited to the player's configured allies.
func _belongs_to_house_or_capturable_house(
		item: Resource, house_id: StringName, subhouse_ids: Array[StringName]
		) -> bool:
	if _belongs_to_house(item, house_id, subhouse_ids):
		return true
	return item != null and item.house_id in _construction_yard_houses()


func _construction_yard_houses() -> Array[StringName]:
	if _construction_yard_houses_loaded:
		return _construction_yard_house_ids
	_construction_yard_houses_loaded = true
	for config_id in all_ids():
		var item = definition(config_id)
		if item != null and item.is_construction_yard \
		and item.house_id != &"" and item.house_id not in _construction_yard_house_ids:
			_construction_yard_house_ids.append(item.house_id)
	return _construction_yard_house_ids


## Rules.txt declares BuildingGroupTypes specifically to "stop duplicate
## icons". Keep one functional slot for equivalent visual variants, preferring
## the player's native House, then a selected sub-house, then a deterministic
## capturable Great-House representative.
func _collapse_building_groups(
		ids: Array[StringName], house_id: StringName, subhouse_ids: Array[StringName]
		) -> Array[StringName]:
	var result: Array[StringName] = []
	var group_indices: Dictionary = {}
	for config_id in ids:
		var item = definition(config_id)
		var group_id: StringName = item.building_group_id if item != null else &""
		if group_id == &"":
			result.append(config_id)
			continue
		if not group_indices.has(group_id):
			group_indices[group_id] = result.size()
			result.append(config_id)
			continue
		var index := int(group_indices[group_id])
		var current = definition(result[index])
		if _house_preference(item.house_id, house_id, subhouse_ids) \
		< _house_preference(current.house_id, house_id, subhouse_ids):
			result[index] = config_id
	return result


func _house_preference(
		candidate_house: StringName, house_id: StringName, subhouse_ids: Array[StringName]
		) -> int:
	if candidate_house == house_id:
		return 0
	if candidate_house in subhouse_ids:
		return 1
	return 2
