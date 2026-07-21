class_name CombatDefinitionCatalog
extends RefCounted

const Manifest := preload("res://resources/combat/generated_combat_manifest.gd")

var _turrets: Dictionary = {}
var _bullets: Dictionary = {}
var _warheads: Dictionary = {}
var _settings: Resource
var _scenes: Dictionary = {}


func turret(config_id: StringName) -> Resource:
	return _load_definition(config_id, Manifest.TURRET_PATHS, _turrets)


func bullet(config_id: StringName) -> Resource:
	return _load_definition(config_id, Manifest.BULLET_PATHS, _bullets)


func warhead(config_id: StringName) -> Resource:
	return _load_definition(config_id, Manifest.WARHEAD_PATHS, _warheads)


func settings() -> Resource:
	if _settings == null and ResourceLoader.exists(Manifest.SETTINGS_PATH):
		_settings = load(Manifest.SETTINGS_PATH) as Resource
	return _settings


func scene(path: String) -> PackedScene:
	if path.is_empty() or not ResourceLoader.exists(path, "PackedScene"):
		return null
	if not _scenes.has(path):
		_scenes[path] = load(path) as PackedScene
	return _scenes[path] as PackedScene


func _load_definition(config_id: StringName, paths: Dictionary, cache: Dictionary) -> Resource:
	if cache.has(config_id):
		return cache[config_id] as Resource
	var path := String(paths.get(config_id, ""))
	var definition := load(path) as Resource if not path.is_empty() and ResourceLoader.exists(path) else null
	cache[config_id] = definition
	return definition

