class_name BuildingController
extends Node3D

signal status_changed(status: String)

const BuildingQueueScript := preload("res://scripts/buildings/building_queue.gd")
const BuildingPlacementScript := preload("res://scripts/buildings/building_placement.gd")
const TechnologyTreeScript := preload("res://scripts/buildings/technology_tree.gd")
const PLACEMENT_ARROW_SCENE := preload("res://assets/converted/placement/build_arrow.scn")
const PLACEMENT_BUILDING_SCENE := preload("res://assets/converted/placement/build_building.scn")
const PLACEMENT_CANT_BUILD_SCENE := preload("res://assets/converted/placement/build_cantbuild.scn")
const PLACEMENT_SKIRT_SCENE := preload("res://assets/converted/placement/build_skirt.scn")

var side_panel: SidePanel
var camera: Camera3D

var _building_configs: Dictionary = {}
var _technology_tree = TechnologyTreeScript.new()
var _building_availability: Dictionary = {}
var _building_queue = BuildingQueueScript.new()
var _building_placement = BuildingPlacementScript.new()
var _local_player_resource = null
var _sell_mode := false
var _selling_building: Node3D


func setup(panel: SidePanel, map_loader: MapLoader, placement_camera: Camera3D, building_parent: Node3D) -> void:
	side_panel = panel
	camera = placement_camera
	if _building_placement.get_parent() != self:
		add_child(_building_placement)
	var navigation_grid = map_loader.navigation_grid if map_loader != null else null
	_building_placement.setup(
		placement_camera,
		navigation_grid,
		building_parent,
		PLACEMENT_ARROW_SCENE,
		PLACEMENT_BUILDING_SCENE,
		PLACEMENT_CANT_BUILD_SCENE,
		PLACEMENT_SKIRT_SCENE,
		Callable(self, "_occupy_rows_for_existing_building")
	)
	if not _building_queue.order_ready.is_connected(_on_building_queue_ready):
		_building_queue.order_ready.connect(_on_building_queue_ready)

	_bind_local_player_roster()
	_load_building_configs()

	if side_panel != null:
		side_panel.queue_slot_pressed.connect(_on_panel_queue_slot)
		side_panel.tab_changed.connect(_on_panel_tab_changed)
		side_panel.command_pressed.connect(_on_panel_command)

	_refresh_player_credits()
	_refresh_building_queue_slot()


func process(delta: float) -> void:
	for building_id in SidePanel.BUILDING_IDS:
		var building_available := _is_building_available(building_id)
		if building_available != _building_availability.get(building_id, false):
			_building_availability[building_id] = building_available
			_refresh_building_queue_slot()
	_process_building_order(delta)
	if _building_placement.is_active():
		_building_placement.process(get_viewport().get_mouse_position())


func handle_unhandled_input(event: InputEvent) -> bool:
	if _sell_mode:
		if not (event is InputEventMouseButton and event.pressed):
			return false
		if event.button_index == MOUSE_BUTTON_LEFT:
			_try_sell_building(event.position)
			return true
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_set_sell_mode(false)
			return true
		return false

	if not _building_placement.is_active():
		return false
	if not (event is InputEventMouseButton and event.pressed):
		return false

	match event.button_index:
		MOUSE_BUTTON_LEFT:
			_try_place_ready_building(event.position)
			return true
		MOUSE_BUTTON_RIGHT:
			_cancel_building_placement()
			return true
	return false


func _on_panel_command(command: StringName) -> void:
	if command == &"Sell":
		_set_sell_mode(not _sell_mode)


func _set_sell_mode(active: bool) -> void:
	_sell_mode = active
	if side_panel != null:
		side_panel.set_sell_mode(active)
	if active:
		_cancel_building_placement()
		status_changed.emit("Sell mode: select one of your buildings")
	else:
		status_changed.emit("Sell mode canceled")


func _try_sell_building(screen_position: Vector2) -> void:
	if _selling_building != null:
		return

	var hit := _raycast(screen_position, 2)
	var building := _find_building(hit.get("collider") as Node)
	if building == null:
		status_changed.emit("Select one of your buildings to sell")
		return

	var players = _players()
	if players == null or not building.has_method("is_owned_by") or not building.call("is_owned_by", players.local_player_id):
		status_changed.emit("You can only sell your own buildings")
		return

	_selling_building = building
	_set_sell_mode(false)
	var player := building.get_node_or_null("StatePlayer") as AnimationPlayer
	if player != null and player.has_animation(&"build"):
		var build_animation := player.get_animation(&"build")
		if build_animation != null:
			build_animation.loop_mode = Animation.LOOP_NONE
			_play_building_state(building, &"build")
			player.seek(build_animation.length, true)
		player.animation_finished.connect(_on_sold_building_animation_finished.bind(building), CONNECT_ONE_SHOT)
		player.play_backwards(&"build")
		return

	_finish_selling_building(building)


func _on_sold_building_animation_finished(_animation_name: StringName, building: Node3D) -> void:
	_finish_selling_building(building)


func _finish_selling_building(building: Node3D) -> void:
	if building != _selling_building:
		return

	var refund := _building_sale_refund(building)
	var player = _local_player()
	if player != null and refund > 0:
		player.add_money(refund)
	var display_name := String(building.get("config_id"))
	if display_name.is_empty():
		display_name = building.name
	_selling_building = null
	building.queue_free()
	status_changed.emit("%s sold; refunded %d" % [display_name, refund])


func _building_sale_refund(building: Node3D) -> int:
	var config = building.get("building_config")
	if config == null:
		config = _building_config(StringName(String(building.get("config_id"))))
	var cost := int(config.field(&"cost", 0)) if config != null else 0
	return maxi(cost / 2, 0)


func _find_building(node: Node) -> Node3D:
	var current := node
	while current != null:
		if current.is_in_group("buildings") and current is Node3D:
			return current as Node3D
		current = current.get_parent()
	return null


func _on_panel_queue_slot(tab: SidePanel.Tab, slot_index: int, button_index: int) -> void:
	if tab != SidePanel.Tab.BUILDINGS or slot_index < 0 or slot_index >= SidePanel.BUILDING_IDS.size():
		return
	var building_id: StringName = SidePanel.BUILDING_IDS[slot_index]

	match button_index:
		MOUSE_BUTTON_LEFT:
			_on_building_slot_left_pressed(building_id)
		MOUSE_BUTTON_RIGHT:
			_on_building_slot_right_pressed(building_id)


func _on_panel_tab_changed(_tab: SidePanel.Tab) -> void:
	_refresh_building_queue_slot()


func _bind_local_player_roster() -> void:
	var players = _players()
	if players == null:
		_refresh_player_credits()
		return

	var callback := Callable(self, "_on_local_player_changed")
	if not players.local_player_changed.is_connected(callback):
		players.local_player_changed.connect(callback)

	_bind_local_player_resource()


func _bind_local_player_resource() -> void:
	var callback := Callable(self, "_on_local_player_resources_changed")
	if _local_player_resource != null and _local_player_resource.resources_changed.is_connected(callback):
		_local_player_resource.resources_changed.disconnect(callback)

	_local_player_resource = null
	var players = _players()
	if players != null:
		_local_player_resource = players.local_player()

	if _local_player_resource != null and not _local_player_resource.resources_changed.is_connected(callback):
		_local_player_resource.resources_changed.connect(callback)

	_refresh_player_credits()


func _on_local_player_changed(_player_id: int) -> void:
	_bind_local_player_resource()
	_refresh_building_queue_slot()


func _on_local_player_resources_changed(_player_id: int, _money: int, _energy: int) -> void:
	_refresh_player_credits()
	_refresh_building_queue_slot()


func _refresh_player_credits() -> void:
	if side_panel == null:
		return

	var player = _local_player()
	side_panel.set_credits(player.money if player != null else 0)
	side_panel.set_energy(player.energy if player != null else 0)


func _load_building_configs() -> void:
	var rules := get_node_or_null("/root/Rules")
	if rules == null:
		push_warning("Rules autoload is not available; building production uses no rules")
		return

	for building_id in SidePanel.BUILDING_IDS:
		var config: Resource = rules.call("building", building_id)
		if config == null:
			push_warning("Building rules config not found: %s" % String(building_id))
			continue
		_building_configs[building_id] = config


func _on_building_slot_left_pressed(building_id: StringName) -> void:
	var order := _building_queue.current_order()
	if order == null:
		_start_building_order(building_id)
	elif order.building_id != building_id:
		status_changed.emit("Building queue is busy")
	elif order.ready:
		_begin_ready_building_placement()
	elif order.manually_paused:
		_building_queue.resume()
		status_changed.emit("%s construction resumed" % order.display_name)
	else:
		var status := "%s construction is waiting for credits" if _building_queue.lacks_funds() else "%s construction is already running"
		status_changed.emit(status % order.display_name)

	_refresh_building_queue_slot()


func _on_building_slot_right_pressed(building_id: StringName) -> void:
	var order := _building_queue.current_order()
	if order == null or order.building_id != building_id:
		return

	if _building_placement.is_active():
		_cancel_building_placement()
		return

	if order.ready or order.manually_paused:
		_cancel_building_order()
	else:
		_building_queue.pause()
		status_changed.emit("%s construction paused" % order.display_name)
		_refresh_building_queue_slot()


func _start_building_order(building_id: StringName) -> void:
	var config: Resource = _building_configs.get(building_id)
	if config == null:
		status_changed.emit("Building rules are not loaded")
		return
	if _building_queue.has_order():
		status_changed.emit("Building queue is busy")
		return
	if not _is_building_available(building_id):
		status_changed.emit("%s is not available" % _building_display_name(building_id))
		_refresh_building_queue_slot()
		return

	if not _building_queue.start(
		building_id,
		_building_display_name(building_id),
		maxi(int(config.field(&"cost", 0)), 0),
		maxf(float(config.field(&"build_time", 0.0)), 1.0)
	):
		return
	_building_placement.cancel()

	status_changed.emit("%s ordered" % _building_queue.current_order().display_name)
	_refresh_building_queue_slot()


func _process_building_order(delta: float) -> void:
	var order := _building_queue.current_order()
	if order == null:
		return
	if not order.ready and not _is_building_available(order.building_id):
		_cancel_building_order()
		return
	var player = _local_player()
	var available_credits: int = player.money if player != null else 0
	var spend_credits: Callable = Callable(player, &"spend_money") if player != null else Callable()
	if _building_queue.tick(delta, available_credits, spend_credits):
		_refresh_building_queue_slot()


func _on_building_queue_ready(order: BuildingOrder) -> void:
	status_changed.emit("%s ready" % order.display_name)
	_refresh_building_queue_slot()


func _cancel_building_order() -> void:
	var order := _building_queue.current_order()
	if order == null:
		return

	var display_name := String(order.display_name)
	var refunded := _building_queue.cancel()
	var player = _local_player()
	if player != null and refunded > 0:
		player.add_money(refunded)

	_building_placement.cancel()
	status_changed.emit("%s canceled; refunded %d" % [display_name, refunded])
	_refresh_building_queue_slot()


func _begin_ready_building_placement() -> void:
	var order := _building_queue.current_order()
	if order == null or not order.ready:
		return

	var config := _building_config(order.building_id)
	var occupy_rows := _building_occupy_rows(config)
	if not _building_placement.begin(order.building_id, order.display_name, occupy_rows):
		status_changed.emit("%s has no occupy_rows" % order.display_name)
		return

	_building_placement.process(get_viewport().get_mouse_position())
	status_changed.emit("%s placement ready" % order.display_name)
	_refresh_building_queue_slot()


func _try_place_ready_building(screen_position: Vector2) -> void:
	var order := _building_queue.current_order()
	if order == null or not _building_placement.is_active():
		return

	var players = _players()
	var owner_player_id = players.local_player_id if players != null else null
	match _building_placement.try_place(screen_position, null, owner_player_id):
		BuildingPlacementScript.PlaceResult.NEEDS_TERRAIN:
			status_changed.emit("%s placement needs terrain" % order.display_name)
			return
		BuildingPlacementScript.PlaceResult.CANNOT_BUILD:
			status_changed.emit("%s cannot be placed there" % order.display_name)
			return
		BuildingPlacementScript.PlaceResult.INACTIVE:
			return

	var scene_path := _building_scene_path(order.building_id)
	if not ResourceLoader.exists(scene_path):
		status_changed.emit(
			"%s placement valid; missing scene %s" % [order.display_name, scene_path]
		)
		return
	var scene := load(scene_path) as PackedScene
	match _building_placement.try_place(screen_position, scene, owner_player_id):
		BuildingPlacementScript.PlaceResult.PLACED:
			_building_queue.take_ready()
			status_changed.emit("%s placed" % order.display_name)
			_refresh_building_queue_slot()
		BuildingPlacementScript.PlaceResult.INVALID_SCENE:
			status_changed.emit("%s scene is not a Node3D" % order.display_name)
		BuildingPlacementScript.PlaceResult.MISSING_BUILDINGS_ROOT:
			status_changed.emit("Buildings root is missing")


func _cancel_building_placement() -> void:
	if not _building_placement.is_active():
		return
	var display_name := _building_placement.cancel()
	status_changed.emit("%s placement canceled" % display_name)
	_refresh_building_queue_slot()


func _play_building_state(building: Node3D, state: StringName) -> void:
	if building.has_method("play_state"):
		building.call("play_state", state)
		return

	var player := building.get_node_or_null("StatePlayer") as AnimationPlayer
	if player != null and player.has_animation(state):
		player.play(state)


func _building_occupy_rows(config: Resource) -> Array[String]:
	var rows: Array[String] = []
	if config == null:
		return rows

	for row in config.list(&"occupy_rows"):
		var row_text := String(row)
		if not row_text.is_empty():
			rows.append(row_text)
	return rows


func _occupy_rows_for_existing_building(building: Node3D) -> Array[String]:
	var config = building.get("building_config") as Resource
	if config == null:
		config = _building_config(StringName(String(building.get("config_id"))))
	return _building_occupy_rows(config)


func _building_config(building_id: StringName) -> Resource:
	var rules := get_node_or_null("/root/Rules")
	if rules == null:
		return null
	return rules.call("building", building_id)


func _building_scene_path(building_id: StringName) -> String:
	var id_text := String(building_id)
	var id_path := _building_scene_path_for_name(id_text)
	if ResourceLoader.exists(id_path):
		return id_path

	var model_name := _building_model_name(building_id)
	if not model_name.is_empty() and model_name != id_text:
		var model_path := _building_scene_path_for_name(model_name)
		if ResourceLoader.exists(model_path):
			return model_path

	return id_path


func _building_scene_path_for_name(scene_name: String) -> String:
	return "res://assets/converted/buildings/%s/%s.scn" % [scene_name, scene_name]


func _building_model_name(building_id: StringName) -> String:
	var art_config := _building_art_config(building_id)
	if art_config == null:
		return ""
	return String(art_config.field(&"xaf", ""))


func _building_art_config(building_id: StringName) -> Resource:
	var rules := get_node_or_null("/root/Rules")
	if rules == null or not rules.has_method("get_entity"):
		return null
	return rules.call("get_entity", &"art_config", building_id)


func _is_building_available(building_id: StringName) -> bool:
	if not is_inside_tree():
		return false
	var config := _building_config(building_id)
	if config == null:
		return false
	var player = _local_player()
	if player == null:
		return false
	var buildings: Array[Node] = []
	buildings.assign(get_tree().get_nodes_in_group("buildings"))
	return _technology_tree.is_available(config, player, buildings)


func _refresh_building_queue_slot() -> void:
	if side_panel == null:
		return

	var order := _building_queue.current_order()
	for slot_index in SidePanel.BUILDING_IDS.size():
		var building_id: StringName = SidePanel.BUILDING_IDS[slot_index]
		var tooltip := _building_tooltip(building_id)
		if order == null:
			var state := QueueSlot.State.AVAILABLE if _is_building_available(building_id) else QueueSlot.State.DISABLED
			side_panel.set_building_slot_state(slot_index, state, 0.0, "", tooltip)
			continue

		if order.building_id != building_id:
			var state := QueueSlot.State.BLOCKED if _is_building_available(building_id) else QueueSlot.State.DISABLED
			side_panel.set_building_slot_state(slot_index, state, 0.0, "", tooltip)
			continue

		if order.ready:
			var ready_status_text := "PLACE" if _building_placement.is_active() else "READY"
			side_panel.set_building_slot_state(
				slot_index, QueueSlot.State.READY, 100.0, ready_status_text, tooltip
			)
			continue

		var status_text := ""
		if order.manually_paused:
			status_text = "PAUSED"
		side_panel.set_building_slot_state(
			slot_index,
			QueueSlot.State.PROGRESS,
			order.progress_percent(),
			status_text,
			tooltip
		)


func _building_display_name(building_id: StringName) -> String:
	match building_id:
		&"ATSmWindtrap":
			return "Windtrap"
		&"ATBarracks":
			return "Barracks"
	return String(building_id)


func _building_tooltip(building_id: StringName) -> String:
	var config: Resource = _building_configs.get(building_id)
	if config == null:
		return _building_display_name(building_id)

	var cost := int(config.field(&"cost", 0))
	var build_time_ticks := float(config.field(&"build_time", 0.0))
	var build_seconds := build_time_ticks / BuildingQueueScript.BUILD_TICKS_PER_SECOND
	return "%s\nCost: %d\nBuild: %.1fs" % [
		_building_display_name(building_id),
		cost,
		build_seconds,
	]


func _raycast(screen_position: Vector2, collision_mask: int = 0xffffffff) -> Dictionary:
	if camera == null:
		return {}

	var ray_origin := camera.project_ray_origin(screen_position)
	var ray_end := ray_origin + camera.project_ray_normal(screen_position) * 1000.0
	var query := PhysicsRayQueryParameters3D.create(ray_origin, ray_end)
	query.collision_mask = collision_mask
	query.collide_with_areas = false
	return get_world_3d().direct_space_state.intersect_ray(query)


func _players():
	if not is_inside_tree():
		return null
	return get_node_or_null("/root/Players")


func _local_player():
	var players = _players()
	if players == null:
		return null
	return players.local_player()
