extends SceneTree

const UnitSceneCatalogScript := preload("res://scripts/units/unit_scene_catalog.gd")
const UnitDefinitionScript := preload("res://scripts/units/unit_definition.gd")
const UnitScript := preload("res://scripts/units/unit.gd")
const HarvesterScript := preload("res://scripts/units/harvester.gd")
const UnitScene := preload("res://scenes/units/unit.tscn")

var _assertions := 0
var _failures := 0


func _initialize() -> void:
	var catalog := UnitSceneCatalogScript.new()
	_expect(catalog._scene_cache.is_empty(), "catalog construction must not eagerly load unit scenes")
	_expect(catalog._definition_cache.is_empty(), "catalog construction must not eagerly load definitions")

	var scout_definition := catalog.definition_for(&"ATScout")
	_expect(scout_definition is UnitDefinitionScript, "ATScout must have a Godot-native definition")
	if scout_definition != null:
		_expect(scout_definition.config_id == &"ATScout", "definition identity must match rules.db")
		_expect(scout_definition.cost == 30, "definition cost must match normalized rules data")
		_expect(scout_definition.primary_building_ids == [&"ATBarracks"], "definition must preserve production links")
		_expect(not scout_definition.scene_path.is_empty(), "prepared units must expose their editor scene")

	var scout := catalog.instantiate(&"ATScout", UnitScene)
	_expect(scout is UnitScript, "catalog must instantiate prepared unit scenes")
	_expect(scout != null and scout.config_id == &"ATScout", "prepared scene must retain the requested config id")
	_expect(scout != null and scout.get_node_or_null("VisualRoot/AT_Scout_H0") != null, "prepared scene must contain its authored model without a runtime swap")
	if scout != null:
		scout.free()

	var harvester := catalog.instantiate(&"Harvester", UnitScene)
	_expect(harvester is HarvesterScript, "Harvester must keep its specialized lifecycle scene")
	if harvester != null:
		harvester.free()

	var fallback := catalog.instantiate(&"UnknownMigrationFixture", UnitScene)
	_expect(fallback is UnitScript, "missing catalog entries must safely use the generic unit scene")
	_expect(fallback != null and fallback.config_id == &"UnknownMigrationFixture", "fallback must receive the requested config id")
	if fallback != null:
		fallback.free()

	var first_scene := catalog.scene_for(&"ATScout", UnitScene)
	var second_scene := catalog.scene_for(&"ATScout", UnitScene)
	_expect(first_scene == second_scene and catalog._scene_cache.size() >= 1, "scene loads must be cached by config id")
	_expect(catalog.definition_for(&"ATScout") == scout_definition, "definition loads must be cached by config id")

	if _failures > 0:
		printerr("UnitSceneCatalog tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("UnitSceneCatalog tests: %d assertions passed" % _assertions)
	quit(0)


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s" % message)
