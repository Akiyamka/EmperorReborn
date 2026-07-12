class_name UnitRosterController
extends Node

## docs/mechanics/production.md section 3 "unit production": the roster half
## only. The Infantry/Vehicles panel tabs list the units the technology tree
## currently unlocks -- primary production building owned, its upgrade
## purchased when the unit demands one (upgraded_primary_required), and the
## map tech level cap -- all via the same TechnologyTree.is_available() the
## building grid uses. Production queues, credit deduction, and unit spawning
## are not implemented yet; clicking an available unit only reports that.

signal status_changed(status: String)
signal unit_option_state_changed(option_state: BuildingOptionState)

const TechnologyTreeScript := preload("res://scripts/buildings/technology_tree.gd")
const BuildingOptionStateScript := preload("res://scripts/buildings/building_option_state.gd")
const BuildingQueueScript := preload("res://scripts/buildings/building_queue.gd")

## Same extension point as BuildingController.max_tech_level -- a future
## map/mission tech-level cap (see TechnologyTree.UNLIMITED_TECH_LEVEL).
var max_tech_level: int = TechnologyTreeScript.UNLIMITED_TECH_LEVEL

var _unit_ids: Array[StringName] = []
var _unit_configs: Dictionary = {}
var _technology_tree: TechnologyTree = TechnologyTreeScript.new()
var _unit_availability: Dictionary = {}


func setup(unit_ids: Array[StringName]) -> void:
	_unit_ids = unit_ids.duplicate()
	_load_unit_configs()
	_refresh_unit_option_states()


## Mirrors BuildingController.process()'s availability poll: unit availability
## depends on which buildings the player currently owns and whether they are
## upgraded, both of which change as buildings are placed, upgraded, or lost
## elsewhere on the map.
func process(_delta: float) -> void:
	var changed := false
	for unit_id in _unit_ids:
		var available := _is_unit_available(unit_id)
		if available != _unit_availability.get(unit_id, false):
			_unit_availability[unit_id] = available
			changed = true
	if changed:
		_refresh_unit_option_states()


func handle_unit_intent(unit_id: StringName, button_index: int) -> bool:
	if not _unit_ids.has(unit_id):
		return false
	if button_index == MOUSE_BUTTON_LEFT:
		if _is_unit_available(unit_id):
			status_changed.emit("%s production is not implemented yet" % String(unit_id))
		else:
			status_changed.emit("%s is not available" % String(unit_id))
	return true


func _load_unit_configs() -> void:
	var rules := get_node_or_null("/root/Rules")
	if rules == null:
		push_warning("Rules autoload is not available; unit roster uses no rules")
		return

	for unit_id in _unit_ids:
		var config: Resource = rules.call("unit", unit_id)
		if config == null:
			push_warning("Unit rules config not found: %s" % String(unit_id))
			continue
		_unit_configs[unit_id] = config


func _is_unit_available(unit_id: StringName) -> bool:
	if not is_inside_tree():
		return false
	var config: Resource = _unit_configs.get(unit_id)
	if config == null:
		return false
	var player = _local_player()
	if player == null:
		return false
	var buildings: Array[Node] = []
	buildings.assign(get_tree().get_nodes_in_group("buildings"))
	return _technology_tree.is_available(config, player, buildings, max_tech_level)


func _refresh_unit_option_states() -> void:
	for unit_id in _unit_ids:
		var state := BuildingOptionStateScript.State.AVAILABLE if _is_unit_available(unit_id) else BuildingOptionStateScript.State.DISABLED
		unit_option_state_changed.emit(BuildingOptionStateScript.new(
			unit_id, state, 0.0, "", _unit_tooltip(unit_id)
		))


func _unit_tooltip(unit_id: StringName) -> String:
	var config: Resource = _unit_configs.get(unit_id)
	if config == null:
		return String(unit_id)

	var cost := int(config.field(&"cost", 0))
	var build_time_ticks := float(config.field(&"build_time", 0.0))
	var build_seconds := build_time_ticks / BuildingQueueScript.BUILD_TICKS_PER_SECOND
	return "%s\nCost: %d\nBuild: %.1fs" % [String(unit_id), cost, build_seconds]


func _local_player() -> PlayerData:
	if not is_inside_tree():
		return null
	var players = get_node_or_null("/root/Players")
	if players == null:
		return null
	return players.local_player() as PlayerData
