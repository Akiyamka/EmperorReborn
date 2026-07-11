class_name BuildingSurvivors
extends RefCounted

## docs/mechanics/production.md §2.1 "Building destruction": on death a building
## spawns a fixed number of the owning House's basic infantry at 70% HP, briefly
## immune to the splash that finished the building. No debris/ruins remain.

const UnitScene := preload("res://scenes/units/unit.tscn")

## Verified against assets/raw_original_content/MODEL/Rules.txt: each House's
## barracks-produced, lowest-tier infantry (PrimaryBuilding=<House>Barracks,
## UnitGroup=FromBarracks). Atreides/Harkonnen have a clear Tech1 entry;
## Ordos only ever lists ORAATrooper as a barracks unit, so it is the basic
## infantryman by elimination. Other Houses are omitted: their barracks/basic
## infantry configs are not converted under assets/converted/rules yet, and
## spawn_for_destroyed_building() must degrade to a no-op for them rather than
## guessing or crashing.
const BASIC_INFANTRY_BY_HOUSE := {
	&"Atreides": &"ATInfantry",
	&"Harkonnen": &"HKLightInf",
	&"Ordos": &"ORAATrooper",
}

## [Rules] docs/mechanics/production.md §2.1: per-building NumInfantryWhenGone
## in Rules.txt (e.g. ATConYard/ATBarracks = 3, ATSmWindtrap = 1). Used as
## "num_infantry_when_gone" on building_config. An absent field means Rules
## defines no survivors for that building (not an implicit one survivor).
const DEFAULT_SURVIVOR_COUNT := 0

const SURVIVOR_HEALTH_FRACTION := 0.7
const SURVIVOR_INVULNERABILITY_SECONDS := 1.0
const SPAWN_SCATTER_MARGIN := 0.6
const DEFAULT_HALF_EXTENTS := Vector3(1.0, 0.0, 1.0)


static func spawn_for_destroyed_building(building: Building) -> void:
	var unit_id := _basic_infantry_id(building)
	if String(unit_id).is_empty():
		return

	var rules := building.get_node_or_null("/root/Rules")
	if rules == null or rules.call("unit", unit_id) == null:
		return

	var parent := _survivors_parent(building)
	if parent == null:
		return

	var half_extents := _footprint_half_extents(building)
	var origin := building.global_position
	for i in _survivor_count(building):
		_spawn_survivor(parent, unit_id, building.owner_player_id, origin, half_extents)


static func _survivor_count(building: Building) -> int:
	if building.building_config == null:
		return DEFAULT_SURVIVOR_COUNT
	return maxi(int(building.building_config.field(&"num_infantry_when_gone", DEFAULT_SURVIVOR_COUNT)), 0)


static func _spawn_survivor(
		parent: Node, unit_id: StringName, owner_player_id: int, origin: Vector3, half_extents: Vector3
	) -> void:
	var survivor := UnitScene.instantiate()
	if survivor == null:
		return

	parent.add_child(survivor)
	survivor.call("setup", unit_id)
	survivor.call("set_owner_player_id", owner_player_id)
	survivor.global_position = origin + Vector3(
		randf_range(-half_extents.x, half_extents.x),
		0.7,
		randf_range(-half_extents.z, half_extents.z)
	)
	if survivor.has_method("stop_at_current_position"):
		survivor.call("stop_at_current_position")
	if "max_health" in survivor:
		survivor.health = survivor.max_health * SURVIVOR_HEALTH_FRACTION
	if survivor.has_method("grant_temporary_invulnerability"):
		survivor.call("grant_temporary_invulnerability", SURVIVOR_INVULNERABILITY_SECONDS)


static func _basic_infantry_id(building: Building) -> StringName:
	return BASIC_INFANTRY_BY_HOUSE.get(_owner_house_id(building), &"")


static func _owner_house_id(building: Building) -> StringName:
	var player = building.owner_player()
	if player == null:
		return &""
	return player.house_id


static func _survivors_parent(building: Building) -> Node:
	var tree := building.get_tree()
	if tree == null:
		return building.get_parent()

	# Mirrors the scene convention (see scenes/match/demo_match.tscn): every
	# Unit self-registers in group "units" under a sibling "Units" container.
	# Falling back to the building's own parent keeps this robust when no
	# other unit exists yet to anchor that lookup.
	var existing_unit := tree.get_first_node_in_group("units")
	if existing_unit != null and existing_unit.get_parent() != null:
		return existing_unit.get_parent()
	return building.get_parent()


static func _footprint_half_extents(building: Building) -> Vector3:
	var shape_node := building.get_node_or_null("SelectionCollision/CollisionShape3D") as CollisionShape3D
	if shape_node == null or not (shape_node.shape is BoxShape3D):
		return DEFAULT_HALF_EXTENTS

	var box := shape_node.shape as BoxShape3D
	return Vector3(
		box.size.x * 0.5 + SPAWN_SCATTER_MARGIN,
		0.0,
		box.size.z * 0.5 + SPAWN_SCATTER_MARGIN
	)
