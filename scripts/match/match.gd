extends Node3D

const PlayerDataScript := preload("res://scripts/players/player_data.gd")
const BuildingControllerScript := preload("res://scripts/buildings/building_controller.gd")
const UnitCommandControllerScript := preload("res://scripts/match/unit_command_controller.gd")
const LOCAL_PLAYER_ID := 1
const ENEMY_PLAYER_ID := 2
## Temporary match composition data until building options come from the feature/rules catalog.
const DEMO_BUILDING_OPTION_IDS: Array[StringName] = [&"ATSmWindtrap", &"ATBarracks"]

@onready var camera: Camera3D = $CameraRig/Camera3D
@onready var camera_rig: Node3D = $CameraRig
@onready var terrain: MapLoader = $Terrain
@onready var selection_label: Label = $HUD/Selection
@onready var fps_label: Label = $HUD/FPS
@onready var side_panel: SidePanel = $HUD/SidePanel

var _fps_update_time := 0.0
var _building_controller
var _unit_command_controller


func _enter_tree() -> void:
	# Children initialize their owner visuals in _ready(), so the roster must
	# exist before buildings and units enter the scene tree.
	_configure_demo_players()


func _ready() -> void:
	_setup_unit_command_controller()
	_setup_building_controller()
	_update_selection_label()
	_update_fps_label()
	_place_on_map()


func _on_panel_command(command: StringName) -> void:
	if _building_controller != null and _building_controller.handle_command(command):
		return
	_update_selection_label("Command: %s (not implemented)" % command)


func _on_panel_building_intent(building_id: StringName, button_index: int) -> void:
	if _building_controller != null:
		_building_controller.handle_building_intent(building_id, button_index)


func _on_building_resources_changed(credits: int, energy: int) -> void:
	side_panel.set_credits(credits)
	side_panel.set_energy(energy)


func _setup_building_controller() -> void:
	side_panel.configure_building_options(DEMO_BUILDING_OPTION_IDS)
	_building_controller = BuildingControllerScript.new()
	_building_controller.name = "BuildingController"
	add_child(_building_controller)
	side_panel.building_intent_pressed.connect(_on_panel_building_intent)
	side_panel.command_pressed.connect(_on_panel_command)
	_building_controller.status_changed.connect(_update_selection_label)
	_building_controller.resources_changed.connect(_on_building_resources_changed)
	_building_controller.sell_mode_changed.connect(side_panel.set_sell_mode)
	_building_controller.building_option_state_changed.connect(side_panel.set_building_option_state)
	_building_controller.setup(terrain, camera, $Buildings, DEMO_BUILDING_OPTION_IDS)


func _setup_unit_command_controller() -> void:
	_unit_command_controller = UnitCommandControllerScript.new()
	_unit_command_controller.name = "UnitCommandController"
	add_child(_unit_command_controller)
	_unit_command_controller.status_changed.connect(_update_selection_label)
	_unit_command_controller.setup(camera, terrain)


func _place_on_map() -> void:
	var center := terrain.map_center()
	camera_rig.set_map_view(center, terrain.map_bounds())

	# Terrain collision is not queryable until the first physics frame.
	await get_tree().physics_frame
	await get_tree().physics_frame
	for building in get_tree().get_nodes_in_group("buildings"):
		if building is Node3D:
			var spot: Vector3 = building.global_position
			building.global_position = _snap_to_ground(spot)

	for unit in get_tree().get_nodes_in_group("units"):
		var spot: Vector3 = unit.global_position
		unit.global_position = _snap_to_ground(spot) + Vector3.UP * 0.7
		unit.stop_at_current_position()


func _snap_to_ground(point: Vector3) -> Vector3:
	var query := PhysicsRayQueryParameters3D.create(
		Vector3(point.x, 200.0, point.z), Vector3(point.x, -200.0, point.z), 1
	)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return Vector3(point.x, 0.0, point.z)
	return hit["position"]


func _process(delta: float) -> void:
	if _building_controller != null:
		_building_controller.process(delta)

	_fps_update_time += delta
	if _fps_update_time >= 0.25:
		_fps_update_time = 0.0
		_update_fps_label()


func _unhandled_input(event: InputEvent) -> void:
	if _building_controller != null and _building_controller.handle_unhandled_input(event):
		get_viewport().set_input_as_handled()
		return

	if _unit_command_controller != null and _unit_command_controller.handle_unhandled_input(event):
		get_viewport().set_input_as_handled()


func _update_selection_label(status := "") -> void:
	selection_label.text = _unit_command_controller.selection_text(status)


func _update_fps_label() -> void:
	fps_label.text = "FPS: %d" % Engine.get_frames_per_second()


func _configure_demo_players() -> void:
	var players = _players()
	if players == null:
		push_warning("Players autoload is not available; units and buildings will stay neutral")
		return

	players.reset_for_match()
	players.create_player(
		LOCAL_PLAYER_ID,
		"Atreides Commander",
		Color(0.12, 0.44, 1.0),
		&"Atreides",
		[&"Fremen"],
		1,
		5000,
		0
	)
	players.create_player(
		ENEMY_PLAYER_ID,
		"Ordos Rival",
		Color(0.16, 0.75, 0.34),
		&"Ordos",
		[&"Ix"],
		2,
		5000,
		0
	)
	players.local_player_id = LOCAL_PLAYER_ID
	players.set_relation(LOCAL_PLAYER_ID, ENEMY_PLAYER_ID, PlayerDataScript.Relation.ENEMY)


func _players():
	return get_node_or_null("/root/Players")
