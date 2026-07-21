class_name UnitSceneCatalog
extends RefCounted

## Lazy bridge between rules config ids, editor-friendly per-unit scenes and
## Godot-native UnitDefinition resources. The generated manifest contains only
## paths, so constructing a catalog does not load all unit models into memory.

const GeneratedManifest := preload("res://resources/units/generated_unit_manifest.gd")
const UnitDefinitionScript := preload("res://scripts/units/unit_definition.gd")

var _scene_cache: Dictionary = {}
var _definition_cache: Dictionary = {}
var _model_cache: Dictionary = {}


func has_scene(config_id: StringName) -> bool:
	return GeneratedManifest.SCENE_PATHS.has(config_id)


func scene_path(config_id: StringName) -> String:
	return String(GeneratedManifest.SCENE_PATHS.get(config_id, ""))


func definition_path(config_id: StringName) -> String:
	return String(GeneratedManifest.DEFINITION_PATHS.get(config_id, ""))


func scene_for(config_id: StringName, fallback: PackedScene = null) -> PackedScene:
	if _scene_cache.has(config_id):
		return _scene_cache[config_id] as PackedScene
	var path := scene_path(config_id)
	var scene := load(path) as PackedScene if not path.is_empty() and ResourceLoader.exists(path) else null
	if scene != null:
		_scene_cache[config_id] = scene
		return scene
	# Do not cache a caller-owned fallback: another subsystem may provide a
	# different specialized fallback for the same missing config id.
	return fallback


func definition_for(config_id: StringName) -> Resource:
	if _definition_cache.has(config_id):
		return _definition_cache[config_id] as Resource
	var path := definition_path(config_id)
	var definition: Resource = load(path) as Resource if not path.is_empty() and ResourceLoader.exists(path) else null
	_definition_cache[config_id] = definition
	return definition


func model_scene_for(config_id: StringName) -> PackedScene:
	if _model_cache.has(config_id):
		return _model_cache[config_id] as PackedScene
	var definition: Resource = definition_for(config_id)
	var path: String = definition.get("model_scene_path") if definition != null else ""
	var model := load(path) as PackedScene if not path.is_empty() and ResourceLoader.exists(path) else null
	_model_cache[config_id] = model
	return model


## Instantiates the prepared scene when one exists. Missing entries preserve
## the old generic-scene behavior and receive the converted model when the
## generated definition can resolve it.
func instantiate(config_id: StringName, fallback: PackedScene = null) -> Node:
	var scene := scene_for(config_id, fallback)
	if scene == null:
		return null
	var prepared: bool = _scene_cache.has(config_id) and _scene_cache[config_id] == scene
	var instance := scene.instantiate()
	if instance == null:
		return null
	instance.set("config_id", config_id)
	if not prepared and instance.has_method("replace_visual_scene"):
		var model := model_scene_for(config_id)
		if model != null:
			instance.call("replace_visual_scene", model)
	return instance


func clear_cache() -> void:
	_scene_cache.clear()
	_definition_cache.clear()
	_model_cache.clear()


func producible_unit_ids(house_id: StringName, subhouse_ids: Array[StringName]) -> Array[StringName]:
	var result: Array[StringName] = []
	for value in GeneratedManifest.DEFINITION_PATHS.keys():
		var config_id := StringName(String(value))
		var definition := definition_for(config_id)
		if definition == null or definition.cost <= 0 or definition.primary_building_ids.is_empty():
			continue
		if definition.house_id != &"" \
		and definition.house_id != house_id \
		and definition.house_id not in subhouse_ids:
			continue
		result.append(config_id)
	result.sort()
	return result
