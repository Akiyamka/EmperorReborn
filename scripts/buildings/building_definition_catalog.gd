class_name BuildingDefinitionCatalog
extends RefCounted

const Manifest := preload("res://resources/buildings/generated_building_manifest.gd")
var _cache: Dictionary = {}


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
		if _belongs_to_house(item, house_id, subhouse_ids) \
		and not item.primary_building_ids.is_empty() and item.cost > 0:
			result.append(config_id)
	return result


func wall_ids_for_house(house_id: StringName, subhouse_ids: Array[StringName]) -> Array[StringName]:
	var result: Array[StringName] = []
	for config_id in all_ids():
		var item = definition(config_id)
		if _belongs_to_house(item, house_id, subhouse_ids) and item.building_group_id == &"Wall":
			result.append(config_id)
	return result


func upgrade_ids_for_house(house_id: StringName, subhouse_ids: Array[StringName]) -> Array[StringName]:
	var result: Array[StringName] = []
	for config_id in all_ids():
		var item = definition(config_id)
		if _belongs_to_house(item, house_id, subhouse_ids) \
		and item.upgrade_cost > 0 and item.upgrade_tech_level > 0:
			result.append(config_id)
	return result


func _belongs_to_house(item: Resource, house_id: StringName, subhouse_ids: Array[StringName]) -> bool:
	return item != null and (item.house_id == &"" or item.house_id == house_id or item.house_id in subhouse_ids)
