class_name UnitRosterController
extends Node

## docs/mechanics/production.md section 3 "unit production": the roster half
## only. The Infantry/Vehicles panel tabs list the units the technology tree
## currently unlocks -- primary production building owned, its upgrade
## purchased when the unit demands one (upgraded_primary_required), and the
## map tech level cap -- all via the same TechnologyTree.is_available() the
## building grid uses. A queue belongs to a production-building type; its
## primary instance supplies the spawn location and rally point.

signal status_changed(status: String)
signal unit_option_state_changed(option_state: BuildingOptionState)

const TechnologyTreeScript := preload("res://scripts/buildings/technology_tree.gd")
const BuildingOptionStateScript := preload("res://scripts/buildings/building_option_state.gd")
const BuildingQueueScript := preload("res://scripts/buildings/building_queue.gd")
const UnitScene := preload("res://scenes/units/unit.tscn")

const UNIT_MODEL_ROOT := "res://assets/converted/models"
const UNIT_POPULATION_LIMIT := 1000

## Same extension point as BuildingController.max_tech_level -- a future
## map/mission tech-level cap (see TechnologyTree.UNLIMITED_TECH_LEVEL).
var max_tech_level: int = TechnologyTreeScript.UNLIMITED_TECH_LEVEL

var _unit_ids: Array[StringName] = []
var _unit_configs: Dictionary = {}
var _technology_tree: TechnologyTree = TechnologyTreeScript.new()
var _unit_availability: Dictionary = {}
var _production_queues: Dictionary = {}
var _unit_model_scene_paths: Dictionary = {}


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
	changed = _process_unit_orders(_delta) or changed
	if changed:
		_refresh_unit_option_states()


func handle_unit_intent(unit_id: StringName, button_index: int) -> bool:
	if not _unit_ids.has(unit_id):
		return false
	match button_index:
		MOUSE_BUTTON_LEFT:
			_on_unit_slot_left_pressed(unit_id)
		MOUSE_BUTTON_RIGHT:
			_on_unit_slot_right_pressed(unit_id)
	return true


func _on_unit_slot_left_pressed(unit_id: StringName) -> void:
	if not _is_unit_available(unit_id):
		status_changed.emit("%s is not available" % String(unit_id))
		return
	var config: Resource = _unit_configs.get(unit_id)
	var production_building_id := _production_building_id(config)
	if production_building_id == &"":
		status_changed.emit("No production building is available for %s" % String(unit_id))
		return
	var queue := _queue_for(production_building_id)
	var order = queue.current_order()
	if order != null:
		if order.building_id != unit_id:
			status_changed.emit("%s is already producing %s" % [production_building_id, order.display_name])
			return
		if order.manually_paused:
			queue.resume()
			status_changed.emit("%s production resumed" % order.display_name)
		else:
			queue.pause()
			status_changed.emit("%s production paused" % order.display_name)
		_refresh_unit_option_states()
		return

	var player := _local_player()
	if player == null:
		return
	var cost := maxi(int(config.field(&"cost", 0)), 0)
	var build_time := float(config.field(&"build_time", 0.0))
	if not queue.start(unit_id, String(unit_id), cost, build_time):
		status_changed.emit("%s cannot be queued" % String(unit_id))
		return
	status_changed.emit("%s production started" % String(unit_id))
	_refresh_unit_option_states()


func _on_unit_slot_right_pressed(unit_id: StringName) -> void:
	var config: Resource = _unit_configs.get(unit_id)
	var production_building_id := _production_building_id(config)
	if production_building_id == &"":
		return
	var queue := _queue_for(production_building_id)
	var order = queue.current_order()
	if order == null or order.building_id != unit_id:
		return
	var refund := queue.cancel()
	var player := _local_player()
	if player != null and refund > 0:
		player.add_money(refund)
	status_changed.emit("%s production canceled; refunded %d" % [String(unit_id), refund])
	_refresh_unit_option_states()


func _process_unit_orders(delta: float) -> bool:
	var player := _local_player()
	if player == null:
		return false
	var changed := false
	for production_building_id in _production_queues.keys():
		var queue: BuildingQueue = _production_queues[production_building_id]
		var order = queue.current_order()
		if order == null:
			continue
		if not order.ready:
			changed = queue.tick(delta, player.money, Callable(player, "spend_money")) or changed
			order = queue.current_order()
		if order != null and order.ready and _spawn_completed_unit(order.building_id, StringName(production_building_id)):
			queue.take_ready()
			status_changed.emit("%s completed" % order.display_name)
			changed = true
	return changed


func _spawn_completed_unit(unit_id: StringName, production_building_id: StringName) -> bool:
	var player := _local_player()
	var building := _production_building_for(production_building_id, player.player_id if player != null else -1)
	if building == null:
		return false
	var parent := _units_parent(building)
	if parent == null or _owned_unit_count(player.player_id) >= UNIT_POPULATION_LIMIT:
		return false

	var unit := UnitScene.instantiate() as Unit
	if unit == null:
		return false
	unit.name = String(unit_id)
	unit.config_id = unit_id
	_configure_unit_visual(unit, unit_id)
	parent.add_child(unit)
	# Units begin just inside the producer's front edge, then immediately move
	# toward that building's own rally point.
	var spawn_position = building.call("production_spawn_position") if building.has_method("production_spawn_position") else building.global_position
	unit.global_position = spawn_position
	unit.set_owner_player_id(player.player_id)
	var rally_point = building.call("rally_point_position") if building.has_method("rally_point_position") else _default_rally_point(building)
	# The exit point walks the unit straight out through the building's front
	# before regular routing toward the rally point takes over.
	var exit_point: Vector3 = building.call("production_exit_position") if building.has_method("production_exit_position") else Vector3.INF
	unit.move_to(rally_point, exit_point)
	return true


func _production_building_id(config: Resource) -> StringName:
	if config == null:
		return &""
	var primary_buildings: Array[StringName] = []
	primary_buildings.assign(config.list(&"primary_buildings"))
	var player := _local_player()
	var player_id := player.player_id if player != null else -1
	for building_id in primary_buildings:
		if _production_building_for(building_id, player_id) != null:
			return building_id
	return &""


func _production_building_for(building_id: StringName, player_id: int) -> Node3D:
	if building_id == &"" or not is_inside_tree():
		return null
	var players = get_node_or_null("/root/Players")
	if players != null:
		var primary = players.primary_building(player_id, String(building_id)) as Node3D
		if _is_owned_production_building(primary, building_id, player_id):
			return primary

	for node in get_tree().get_nodes_in_group("buildings"):
		var candidate := node as Node3D
		if not _is_owned_production_building(candidate, building_id, player_id):
			continue
		if players != null:
			players.designate_primary_building(candidate, player_id, String(building_id))
		return candidate
	return null


func _is_owned_production_building(building: Node3D, building_id: StringName, player_id: int) -> bool:
	return (
		building != null
		and is_instance_valid(building)
		and not building.is_queued_for_deletion()
		and StringName(String(building.get("config_id"))) == building_id
		and int(building.get("owner_player_id")) == player_id
	)


func _queue_for(production_building_id: StringName) -> BuildingQueue:
	var queue: BuildingQueue = _production_queues.get(production_building_id)
	if queue == null:
		queue = BuildingQueueScript.new()
		_production_queues[production_building_id] = queue
	return queue


func _units_parent(building: Node3D) -> Node:
	var existing_unit = get_tree().get_first_node_in_group("units")
	if existing_unit != null and existing_unit.get_parent() != null:
		return existing_unit.get_parent()
	var scene_root := get_tree().current_scene
	var units_root := scene_root.get_node_or_null("Units") if scene_root != null else null
	return units_root if units_root != null else building.get_parent()


func _owned_unit_count(player_id: int) -> int:
	var count := 0
	for node in get_tree().get_nodes_in_group("units"):
		if int(node.get("owner_player_id")) == player_id:
			count += 1
	return count


func _configure_unit_visual(unit: Unit, unit_id: StringName) -> void:
	var rules := get_node_or_null("/root/Rules")
	if rules == null:
		return
	var art_config: Resource = rules.call("get_entity", &"art_config", unit_id)
	var xaf := String(art_config.field(&"xaf", "")) if art_config != null else ""
	if xaf.is_empty():
		return
	var model_name := "%s_H0" % xaf
	var scene_path := _unit_model_scene_path(model_name)
	if not ResourceLoader.exists(scene_path):
		push_warning("Unit model scene is unavailable: %s" % scene_path)
		return
	var visual_root := unit.get_node_or_null("VisualRoot") as Node3D
	var model_scene := load(scene_path) as PackedScene
	if visual_root == null or model_scene == null:
		return
	for child in visual_root.get_children():
		visual_root.remove_child(child)
		child.queue_free()
	visual_root.add_child(model_scene.instantiate())


func _unit_model_scene_path(model_name: String) -> String:
	var key := model_name.to_lower()
	if _unit_model_scene_paths.has(key):
		return String(_unit_model_scene_paths[key])
	var directory := DirAccess.open(UNIT_MODEL_ROOT)
	if directory == null:
		return ""
	directory.list_dir_begin()
	var directory_name := directory.get_next()
	while not directory_name.is_empty():
		if directory.current_is_dir() and directory_name.to_lower() == key:
			var scene_path := UNIT_MODEL_ROOT.path_join(directory_name).path_join("%s.scn" % directory_name)
			_unit_model_scene_paths[key] = scene_path
			directory.list_dir_end()
			return scene_path
		directory_name = directory.get_next()
	directory.list_dir_end()
	return ""


func _default_rally_point(building: Node3D) -> Vector3:
	var forward := building.global_transform.basis.z
	return building.global_position + forward.normalized() * 2.0


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
		var state := BuildingOptionStateScript.State.DISABLED
		var progress := 0.0
		var status_text := ""
		if _is_unit_available(unit_id):
			state = BuildingOptionStateScript.State.AVAILABLE
			var production_building_id := _production_building_id(_unit_configs.get(unit_id))
			var queue: BuildingQueue = _production_queues.get(production_building_id)
			var order = queue.current_order() if queue != null else null
			if order != null:
				if order.building_id != unit_id:
					state = BuildingOptionStateScript.State.BLOCKED
				else:
					state = BuildingOptionStateScript.State.READY if order.ready else BuildingOptionStateScript.State.PROGRESS
					progress = order.progress_percent()
					status_text = "PAUSED" if order.manually_paused else ""
		unit_option_state_changed.emit(BuildingOptionStateScript.new(
			unit_id, state, progress, status_text, _unit_tooltip(unit_id)
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
