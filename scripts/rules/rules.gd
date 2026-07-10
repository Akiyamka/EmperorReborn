extends Node

const RulesCatalogScript := preload("res://scripts/rules/rules_catalog.gd")

@export_dir var rules_root := "res://assets/converted/rules"

var catalog = RulesCatalogScript.new()


func _ready() -> void:
	reload()


func reload() -> void:
	catalog.rules_root = rules_root
	catalog.reload()


func get_entity(entity_type: StringName, entity_id: StringName) -> Resource:
	return catalog.get_entity(entity_type, entity_id)


func all(entity_type: StringName = &"") -> Array:
	return catalog.all(entity_type)


func ids(entity_type: StringName) -> Array:
	return catalog.ids(entity_type)


func unit(entity_id: StringName) -> Resource:
	return catalog.unit(entity_id)


func building(entity_id: StringName) -> Resource:
	return catalog.building(entity_id)


func turret(entity_id: StringName) -> Resource:
	return catalog.turret(entity_id)


func bullet(entity_id: StringName) -> Resource:
	return catalog.bullet(entity_id)


func warhead(entity_id: StringName) -> Resource:
	return catalog.warhead(entity_id)
