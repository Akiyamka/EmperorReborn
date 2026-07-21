class_name SpiceDefinitionCatalog
extends RefCounted

const DEFINITION_PATH := "res://resources/world/spice_mound.tres"
var _definition: Resource


func mound() -> Resource:
	if _definition == null and ResourceLoader.exists(DEFINITION_PATH):
		_definition = load(DEFINITION_PATH) as Resource
	return _definition
