extends SceneTree

const BuildingScript := preload("res://scripts/buildings/building.gd")
const BuildingDefinitionCatalogScript := preload(
	"res://scripts/buildings/building_definition_catalog.gd"
)

var _assertions := 0
var _failures := 0


func _initialize() -> void:
	var catalog := BuildingDefinitionCatalogScript.new()
	var ids := catalog.all_ids()
	_expect(ids.size() == 152, "catalog must retain every rules-defined building")
	for config_id in ids:
		_expect(catalog.has_scene(config_id), "%s must have an editor scene" % config_id)
		_expect(
			ResourceLoader.exists(catalog.scene_path(config_id)),
			"%s editor scene path must exist" % config_id
		)

	var factory := catalog.instantiate(&"ATFactory")
	_expect(factory is BuildingScript, "building scenes must instantiate Building roots")
	_expect(
		factory != null and factory.get("config_id") == &"ATFactory",
		"building scenes must retain their rules identity"
	)
	_expect(
		factory != null and factory.get_node_or_null("States/Idle") != null,
		"building scenes must inherit the converted model states"
	)
	if factory != null:
		factory.free()

	var first_scene := catalog.scene(&"ATFactory")
	var second_scene := catalog.scene(&"ATFactory")
	_expect(
		first_scene != null and first_scene == second_scene,
		"building scene loads must be cached by config id"
	)

	if _failures > 0:
		printerr(
			"BuildingSceneCatalog tests: %d failures after %d assertions"
			% [_failures, _assertions]
		)
		quit(1)
		return
	print("BuildingSceneCatalog tests: %d assertions passed" % _assertions)
	quit(0)


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s" % message)
