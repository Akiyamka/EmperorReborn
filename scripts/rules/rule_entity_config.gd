class_name RuleEntityConfig
extends Resource

@export var id: StringName
@export var entity_type: StringName
@export var source_table: StringName
@export var source_id := -1
@export var fields: Dictionary = {}
@export var lists: Dictionary = {}
@export var links: Dictionary = {}


func field(field_name: StringName, default_value: Variant = null) -> Variant:
	return fields.get(String(field_name), default_value)


func list(list_name: StringName) -> Array:
	var value: Variant = lists.get(String(list_name), [])
	return value if value is Array else []


func collection(collection_name: StringName, default_value: Variant = null) -> Variant:
	return lists.get(String(collection_name), default_value)


func link(link_name: StringName, default_value: Variant = null) -> Variant:
	return links.get(String(link_name), default_value)
