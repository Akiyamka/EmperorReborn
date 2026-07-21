class_name TechnologyTree
extends RefCounted
const UnitDefinitionScript := preload("res://scripts/units/unit_definition.gd")
const BuildingDefinitionScript := preload("res://scripts/buildings/building_definition.gd")

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


func is_available(
		config: Resource,
		player,
		buildings: Array[Node],
		max_tech_level: int = UNLIMITED_TECH_LEVEL
) -> bool:
	if config == null or player == null:
		return false
	if not _belongs_to_player_house(config, player):
		return false
	var tech_level := int(config.tech_level)
	if max_tech_level != UNLIMITED_TECH_LEVEL and tech_level > max_tech_level:
		return false

	var owned_buildings := _owned_buildings(buildings, player.player_id)
	var primary_requirements := _requirements(config, true)
	if not _has_any_building(primary_requirements, owned_buildings):
		return false
	var needs_upgrade := bool(config.upgraded_primary_required)
	if needs_upgrade and not _has_upgraded_building(
		primary_requirements, owned_buildings
	):
		return false
	return _has_any_building(_requirements(config, false), owned_buildings)


func _belongs_to_player_house(config: Resource, player) -> bool:
	var required_house: StringName = config.house_id
	return (
		String(required_house).is_empty()
		or required_house == player.house_id
		or player.has_subhouse(required_house)
	)


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
