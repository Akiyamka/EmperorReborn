extends SceneTree

const PlayerDataScript := preload("res://scripts/players/player_data.gd")
const TechnologyTreeScript := preload("res://scripts/buildings/technology_tree.gd")
const BuildingDefinitionCatalogScript := preload("res://scripts/buildings/building_definition_catalog.gd")

var _assertions := 0
var _failures := 0


class BuildingStub extends Node:
	var owner_player_id: int
	var config_id: StringName
	var upgrade_level := 0

	func _init(new_config_id: StringName, new_owner_player_id: int) -> void:
		config_id = new_config_id
		owner_player_id = new_owner_player_id


func _initialize() -> void:
	var catalog = BuildingDefinitionCatalogScript.new()
	var tree = TechnologyTreeScript.new()
	var player = PlayerDataScript.new()
	player.configure(1, "Atreides", Color.WHITE, &"Atreides", [&"Fremen"], 1)

	var roster := catalog.buildable_ids_for_house(player.house_id, player.subhouse_ids)
	_expect(roster.has(&"ATBarracks"), "native Atreides tree is present")
	_expect(roster.has(&"HKBarracks"), "capturable Harkonnen tree is present")
	_expect(roster.has(&"ORBarracks"), "capturable Ordos tree is present")
	_expect(not roster.has(&"IXResCentre"), "unselected sub-house tree stays excluded")
	_expect(
		roster.has(&"ATSmWindtrap")
		and not roster.has(&"HKSmWindtrap")
		and not roster.has(&"ORSmWindtrap"),
		"BuildingGroup variants collapse to one native functional slot"
	)
	_expect(
		catalog.wall_ids_for_house(player.house_id, player.subhouse_ids) == [&"ATWall"],
		"equivalent wall variants collapse to one slot"
	)
	_expect(
		catalog.upgrade_ids_for_house(player.house_id, player.subhouse_ids).has(&"HKConYard"),
		"captured-House upgrades are candidates"
	)

	var at_yard := BuildingStub.new(&"ATConYard", 1)
	var hk_yard := BuildingStub.new(&"HKConYard", 1)
	var or_yard := BuildingStub.new(&"ORConYard", 1)
	var windtrap := BuildingStub.new(&"ATSmWindtrap", 1)
	var buildings: Array[Node] = [at_yard, hk_yard, or_yard, windtrap]
	_expect(tree.is_available(catalog.definition(&"ATBarracks"), player, buildings), "Atreides Barracks unlocks")
	_expect(tree.is_available(catalog.definition(&"HKBarracks"), player, buildings), "Harkonnen Barracks unlocks")
	_expect(tree.is_available(catalog.definition(&"ORBarracks"), player, buildings), "Ordos Barracks unlocks")
	_expect(
		not tree.is_available(catalog.definition(&"HKBarracks"), player, [at_yard, windtrap]),
		"Harkonnen tree locks again without HKConYard"
	)
	var ordos_player = PlayerDataScript.new()
	ordos_player.configure(2, "Ordos", Color.WHITE, &"Ordos")
	var hk_yard_for_ordos := BuildingStub.new(&"HKConYard", 2)
	var ordos_yard := BuildingStub.new(&"ORConYard", 2)
	var hk_hanger_for_ordos := BuildingStub.new(&"HKHanger", 2)
	var helipad = catalog.definition(&"ATHelipad")
	_expect(
		not tree.is_available(helipad, ordos_player, [ordos_yard, hk_hanger_for_ordos]),
		"a grouped slot absent from the native House stays locked"
	)
	_expect(
		tree.is_available(helipad, ordos_player, [hk_yard_for_ordos, hk_hanger_for_ordos]),
		"a captured House variant unlocks its BuildingGroup representative"
	)

	for building in buildings:
		building.free()
	hk_yard_for_ordos.free()
	ordos_yard.free()
	hk_hanger_for_ordos.free()

	if _failures > 0:
		printerr("Multiple-ConYard techtree tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("Multiple-ConYard techtree tests: %d assertions passed" % _assertions)
	quit(0)


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s" % message)
