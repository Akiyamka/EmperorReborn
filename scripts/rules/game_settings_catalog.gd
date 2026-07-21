class_name GameSettingsCatalog
extends RefCounted

const SETTINGS_PATH := "res://resources/rules/game_settings.tres"
var _settings: Resource


func settings() -> Resource:
	if _settings == null and ResourceLoader.exists(SETTINGS_PATH):
		_settings = load(SETTINGS_PATH) as Resource
	return _settings
