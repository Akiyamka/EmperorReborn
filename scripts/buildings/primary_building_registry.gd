class_name PrimaryBuildingRegistry
extends RefCounted

## Generic "double-click designates the primary building of a group"
## bookkeeping. Shared by the Construction Yard/main base rule
## (docs/mechanics/production.md section 1: "Double-clicking a Construction
## Yard designates it as the primary one, and it becomes the main base") and,
## later, per-type production buildings (section 3: "primary building" ->
## completed units emerge from it). A "group" is whatever the caller wants
## exclusivity within for one player — e.g. all of a player's Construction
## Yards (regardless of house-specific building id) share a single primary,
## while production buildings are expected to group by building id.
##
## The designated building is the sole source of truth for its own
## `is_primary` flag (see Building.set_primary); this registry only tracks
## which instance currently holds that flag per (player, group) and clears
## itself when the building leaves the tree (destroyed/sold).

signal primary_changed(player_id: int, group_key: String, building: Node3D)

var _primaries: Dictionary = {}


func designate(building: Node3D, player_id: int, group_key: String) -> void:
	if building == null:
		return

	var key := _key(player_id, group_key)
	var previous: Node3D = _primaries.get(key)
	if previous == building:
		return

	_clear_flag(previous)
	_primaries[key] = building
	if building.has_method("set_primary"):
		building.call("set_primary", true)
	if not building.tree_exiting.is_connected(_on_building_freed):
		building.tree_exiting.connect(_on_building_freed.bind(key, building), CONNECT_ONE_SHOT)
	primary_changed.emit(player_id, group_key, building)


func primary_for(player_id: int, group_key: String) -> Node3D:
	var key := _key(player_id, group_key)
	var building: Node3D = _primaries.get(key)
	if building != null and not is_instance_valid(building):
		_primaries.erase(key)
		return null
	return building


func clear(player_id: int, group_key: String) -> void:
	var key := _key(player_id, group_key)
	var previous: Node3D = _primaries.get(key)
	if previous == null:
		return
	_clear_flag(previous)
	_primaries.erase(key)
	primary_changed.emit(player_id, group_key, null)


func _clear_flag(building: Node3D) -> void:
	if building != null and is_instance_valid(building) and building.has_method("set_primary"):
		building.call("set_primary", false)


func _on_building_freed(key: String, building: Node3D) -> void:
	if _primaries.get(key) != building:
		return
	_primaries.erase(key)
	var separator := key.find(":")
	var player_id := int(key.substr(0, separator))
	var group_key := key.substr(separator + 1)
	primary_changed.emit(player_id, group_key, null)


func _key(player_id: int, group_key: String) -> String:
	return "%d:%s" % [player_id, group_key]
