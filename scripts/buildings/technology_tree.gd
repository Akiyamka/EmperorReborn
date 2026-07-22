class_name TechnologyTree
extends RefCounted
const UnitDefinitionScript := preload("res://scripts/units/unit_definition.gd")
const BuildingDefinitionScript := preload("res://scripts/buildings/building_definition.gd")
const BuildingDefinitionCatalogScript := preload("res://scripts/buildings/building_definition_catalog.gd")

const BUILDING_PRIMARY_REQUIREMENTS := &"requires_primary"
const BUILDING_SECONDARY_REQUIREMENTS := &"requires_secondary"
const UNIT_PRIMARY_REQUIREMENTS := &"primary_buildings"
const UNIT_SECONDARY_REQUIREMENTS := &"secondary_buildings"

## docs/mechanics/production.md section 5 "map tech level": campaign maps are
## supposed to cap accessible tree depth. Checked for a real source
## (Rules.txt [General], MAPINFO.INI, CAMPAIGN.TXT/MISSIONS.TXT, and
## BakedMapData's exported fields) and none exists yet -- the project ships
## one skirmish map and no campaign/mission data. UNLIMITED_TECH_LEVEL keeps
## is_available() a no-op filter until that data source shows up.
const UNLIMITED_TECH_LEVEL := -1
var _building_definition_catalog := BuildingDefinitionCatalogScript.new()
var _houses_by_building_group: Dictionary = {}
var _great_house_ids: Array[StringName] = []
var _building_house_metadata_loaded := false


func is_available(
		config: Resource,
		player,
		buildings: Array[Node],
		max_tech_level: int = UNLIMITED_TECH_LEVEL
) -> bool:
	if config == null or player == null:
		return false
	var owned_buildings := _owned_buildings(buildings, player.player_id)
	if not _passes_house_flags(config, player, owned_buildings):
		return false
	var tech_level := int(config.tech_level)
	if max_tech_level != UNLIMITED_TECH_LEVEL and tech_level > max_tech_level:
		return false

	var primary_requirements := _requirements(config, true)
	if not _has_any_building(primary_requirements, owned_buildings):
		return false
	var needs_upgrade := bool(config.upgraded_primary_required)
	if needs_upgrade and not _has_upgraded_building(
		primary_requirements, owned_buildings
	):
		return false
	return _has_any_building(_requirements(config, false), owned_buildings)


func _passes_house_flags(config: Resource, player, owned_buildings: Array[Node]) -> bool:
	var required_house: StringName = config.house_id
	if String(required_house).is_empty():
		return true
	# A production building determines which units its current owner can train.
	# This intentionally includes captured sub-house buildings: the sub-house
	# flag controls construction of the building, not use of an existing one.
	if config is UnitDefinitionScript:
		return true
	if not _is_great_house(required_house):
		return player.has_subhouse(required_house)

	# Great-House identity is not a player-level technology gate. Ordinary
	# building/unit prerequisites decide which tree is usable. Grouped building
	# representatives need one extra data check because several equivalent
	# House variants intentionally collapse into one menu slot.
	if config is BuildingDefinitionScript and config.building_group_id != &"":
		return _owned_con_yard_has_building_group(owned_buildings, config.building_group_id)
	return true


func _is_great_house(house_id: StringName) -> bool:
	if not _building_house_metadata_loaded:
		_load_building_house_metadata()
	return house_id in _great_house_ids


func _owned_con_yard_has_building_group(
		owned_buildings: Array[Node], building_group_id: StringName
		) -> bool:
	if not _building_house_metadata_loaded:
		_load_building_house_metadata()
	var group_houses: Array = _houses_by_building_group.get(building_group_id, [])
	for building in owned_buildings:
		var definition = _building_definition_catalog.definition(
			StringName(String(building.get("config_id")))
		)
		if definition != null and definition.is_construction_yard \
		and definition.house_id in group_houses:
			return true
	return false


func _load_building_house_metadata() -> void:
	_building_house_metadata_loaded = true
	for config_id in _building_definition_catalog.all_ids():
		var definition = _building_definition_catalog.definition(config_id)
		if definition == null:
			continue
		if definition.is_construction_yard and definition.house_id not in _great_house_ids:
			_great_house_ids.append(definition.house_id)
		if definition.building_group_id == &"":
			continue
		var houses: Array = _houses_by_building_group.get(definition.building_group_id, [])
		if definition.house_id not in houses:
			houses.append(definition.house_id)
		_houses_by_building_group[definition.building_group_id] = houses


func _requirements(config: Resource, primary: bool) -> Array:
	if config is UnitDefinitionScript:
		return config.primary_building_ids if primary else config.secondary_building_ids
	if config is BuildingDefinitionScript:
		return config.primary_building_ids if primary else config.secondary_building_ids
	return []


func _owned_buildings(buildings: Array[Node], player_id: int) -> Array[Node]:
	var result: Array[Node] = []
	for building in buildings:
		if is_instance_valid(building) and int(building.get("owner_player_id")) == player_id:
			result.append(building)
	return result


func _has_any_building(requirements: Array, buildings: Array[Node]) -> bool:
	if requirements.is_empty():
		return true
	for building in buildings:
		if StringName(String(building.get("config_id"))) in requirements:
			return true
	return false


func _has_upgraded_building(requirements: Array, buildings: Array[Node]) -> bool:
	for building in buildings:
		if StringName(String(building.get("config_id"))) in requirements and int(building.get("upgrade_level")) > 0:
			return true
	return false
