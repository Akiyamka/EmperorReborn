class_name BuildingController
extends Node3D

signal status_changed(status: String)
signal building_option_state_changed(option_state: BuildingOptionState)
signal resources_changed(credits: int, energy: int)
signal sell_mode_changed(active: bool)
signal wall_mode_changed(active: bool)

const BuildingQueueScript := preload("res://scripts/buildings/building_queue.gd")
const BuildingPlacementScript := preload("res://scripts/buildings/building_placement.gd")
const TechnologyTreeScript := preload("res://scripts/buildings/technology_tree.gd")
const BuildingOptionStateScript := preload("res://scripts/buildings/building_option_state.gd")
const WallChainScript := preload("res://scripts/buildings/wall_chain.gd")
const WallLineScript := preload("res://scripts/buildings/wall_line.gd")
const DoubleClickTrackerScript := preload("res://scripts/buildings/double_click_tracker.gd")
const CursorManagerScript := preload("res://scripts/ui/cursor_manager.gd")
const BuildingDefinitionCatalogScript := preload("res://scripts/buildings/building_definition_catalog.gd")
const GameSettingsCatalogScript := preload("res://scripts/rules/game_settings_catalog.gd")

const DEFAULT_BUILD_RADIUS_TILES := 6
const WALL_BUILDING_GROUP := "Wall"
const DOUBLE_CLICK_THRESHOLD_MS := 350
const PLACEMENT_ROTATION_DRAG_THRESHOLD := 8.0
const BUILDING_MODE_CURSOR_OVERRIDE := &"building_mode"

var camera: Camera3D
## docs/mechanics/production.md section 5 "map tech level": extension point
## for a future map/mission tech-level cap (see TechnologyTree.UNLIMITED_
## TECH_LEVEL for why it defaults to unlimited -- no map data source exists
## yet to set this from).
var max_tech_level: int = TechnologyTreeScript.UNLIMITED_TECH_LEVEL

var _building_configs: Dictionary = {}
var _building_ids: Array[StringName] = []
var _technology_tree: TechnologyTree = TechnologyTreeScript.new()
var _definition_catalog := BuildingDefinitionCatalogScript.new()
var _game_settings_catalog := GameSettingsCatalogScript.new()
var _building_availability: Dictionary = {}
var _building_queue: BuildingQueue = BuildingQueueScript.new()
var _building_placement: BuildingPlacement = BuildingPlacementScript.new()
var _local_player_resource: PlayerData
var _sell_mode := false
var _selling_building: Node3D
var _wall_line_mode := false
var _wall_line_start_cell = null
var _wall_line_building_id: StringName = &""
var _wall_chain: WallChain
var _building_double_click := DoubleClickTrackerScript.new()
var _placement_pointer_down := false
var _placement_press_position := Vector2.ZERO
var _placement_rotated_during_press := false


func setup(
		map_loader: MapLoader,
		placement_camera: Camera3D,
		building_parent: Node3D,
		building_ids: Array[StringName],
		arrow_scene: PackedScene,
		building_preview_scene: PackedScene,
		cant_build_preview_scene: PackedScene,
		skirt_preview_scene: PackedScene
) -> void:
	camera = placement_camera
	_building_ids = building_ids.duplicate()
	if _building_placement.get_parent() != self:
		add_child(_building_placement)
	var navigation_grid = map_loader.navigation_grid if map_loader != null else null
	_building_placement.setup(
		placement_camera,
		navigation_grid,
		building_parent,
		arrow_scene,
		building_preview_scene,
		cant_build_preview_scene,
		skirt_preview_scene,
		Callable(self, "_occupy_rows_for_existing_building"),
		Callable(self, "_is_wall_building"),
		Callable(self, "_build_radius_tiles"),
		Callable(self, "_local_player_id")
	)
	if not _building_queue.order_ready.is_connected(_on_building_queue_ready):
		_building_queue.order_ready.connect(_on_building_queue_ready)

	_bind_local_player_roster()
	_load_building_configs()
	_refresh_player_resources()
	_refresh_building_option_states()
	sell_mode_changed.emit(_sell_mode)
	wall_mode_changed.emit(_wall_line_mode)


func process(delta: float) -> void:
	_update_mode_cursor()
	for building_id in _building_ids:
		var building_available := _is_building_available(building_id)
		if building_available != _building_availability.get(building_id, false):
			_building_availability[building_id] = building_available
			_refresh_building_option_states()
	_process_building_order(delta)
	if _building_placement.is_active():
		var pointer_position := (
			_placement_press_position
			if _placement_pointer_down
			else get_viewport().get_mouse_position()
		)
		_building_placement.process(pointer_position)


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

	if _wall_line_mode:
		if not (event is InputEventMouseButton and event.pressed):
			return false
		if event.button_index == MOUSE_BUTTON_LEFT:
			_on_wall_line_click(event.position)
			return true
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_set_wall_line_mode(false)
			return true
		return false

	if _wall_chain != null:
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
			_cancel_building_order()
			return true
		return false

	if not _building_placement.is_active():
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			if _try_handle_building_double_click(event.position):
				return true
		return false
	if event is InputEventMouseMotion:
		if not _placement_pointer_down:
			return false
		_update_placement_rotation(event.position)
		return true
	if not event is InputEventMouseButton:
		return false

	match event.button_index:
		MOUSE_BUTTON_LEFT:
			if event.pressed:
				_begin_placement_pointer_action(event.position)
			else:
				_finish_placement_pointer_action(event.position)
			return true
		MOUSE_BUTTON_RIGHT:
			if event.pressed:
				_reset_placement_pointer_action()
				_cancel_building_placement()
				return true
	return false


func _begin_placement_pointer_action(screen_position: Vector2) -> void:
	_placement_pointer_down = true
	_placement_press_position = screen_position
	_placement_rotated_during_press = false
	_building_placement.process(screen_position)


func _update_placement_rotation(screen_position: Vector2) -> void:
	if not _placement_pointer_down:
		return
	if _placement_press_position.distance_to(screen_position) < PLACEMENT_ROTATION_DRAG_THRESHOLD:
		return
	if _building_placement.face_toward_pointer(_placement_press_position, screen_position):
		_placement_rotated_during_press = true
	_building_placement.process(_placement_press_position)


func _finish_placement_pointer_action(screen_position: Vector2) -> void:
	if not _placement_pointer_down:
		return
	_update_placement_rotation(screen_position)
	var placement_position := _placement_press_position
	var rotated := _placement_rotated_during_press
	_reset_placement_pointer_action()
	if rotated:
		status_changed.emit("%s rotated; click to place" % _building_placement.display_name())
		return
	_try_place_ready_building(placement_position)


func _reset_placement_pointer_action() -> void:
	_placement_pointer_down = false
	_placement_press_position = Vector2.ZERO
	_placement_rotated_during_press = false


func handle_command(command: StringName) -> bool:
	match command:
		&"Sell":
			_set_sell_mode(not _sell_mode)
			return true
		&"Repair":
			status_changed.emit("Command: Repair (not implemented)")
			return true
	return false


func handle_building_intent(building_id: StringName, button_index: int) -> bool:
	if not _building_ids.has(building_id):
		return false
	match button_index:
		MOUSE_BUTTON_LEFT:
			_on_building_slot_left_pressed(building_id)
			return true
		MOUSE_BUTTON_RIGHT:
			_on_building_slot_right_pressed(building_id)
			return true
	return false


func _set_sell_mode(active: bool) -> void:
	_sell_mode = active
	_update_mode_cursor()
	sell_mode_changed.emit(active)
	if active:
		_set_wall_line_mode(false)
		_cancel_building_placement()
		status_changed.emit("Sell mode: select one of your buildings")
	else:
		status_changed.emit("Sell mode canceled")


func _set_wall_line_mode(active: bool, building_id: StringName = &"") -> void:
	_wall_line_mode = active
	_wall_line_start_cell = null
	_wall_line_building_id = building_id if active else &""
	wall_mode_changed.emit(active)
	if active:
		_set_sell_mode(false)
		_cancel_building_placement()
		status_changed.emit("Wall mode: click the line start, then the line end")
	else:
		status_changed.emit("Wall mode canceled")
	_refresh_building_option_states()


func _on_wall_line_click(screen_position: Vector2) -> void:
	var cell = _building_placement.hover_cell_from_pointer(screen_position)
	if cell == null:
		status_changed.emit("Wall placement needs terrain")
		return
	if _wall_line_start_cell == null:
		_wall_line_start_cell = cell
		status_changed.emit("Wall start set; click the line end")
		_refresh_building_option_states()
		return

	var start_cell: Vector2i = _wall_line_start_cell
	var building_id := _wall_line_building_id
	_set_wall_line_mode(false)
	_start_wall_chain(start_cell, cell, building_id)


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
	if player != null and player.has_animation(&"sell"):
		var sell_animation := player.get_animation(&"sell")
		if sell_animation != null:
			sell_animation.loop_mode = Animation.LOOP_NONE
		player.animation_finished.connect(_on_sold_building_animation_finished.bind(building), CONNECT_ONE_SHOT)
		_play_building_state(building, &"sell")
		return

	_finish_selling_building(building)


func _exit_tree() -> void:
	var cursors: Variant = _cursor_manager()
	if cursors != null:
		cursors.clear_override(BUILDING_MODE_CURSOR_OVERRIDE)


func _update_mode_cursor() -> void:
	var cursors: Variant = _cursor_manager()
	if cursors == null:
		return
	if _sell_mode:
		var hit := _raycast(get_viewport().get_mouse_position(), 2)
		var building := _find_building(hit.get("collider") as Node)
		var cursor := (
			CursorManagerScript.CursorType.SELL
			if _can_sell_building(building)
			else CursorManagerScript.CursorType.CANT_SELL
		)
		cursors.set_override(BUILDING_MODE_CURSOR_OVERRIDE, cursor, 50)
		return
	if _building_placement.is_active() or _wall_line_mode or _wall_chain != null:
		cursors.set_override(
			BUILDING_MODE_CURSOR_OVERRIDE, CursorManagerScript.CursorType.POINTER, 50
		)
		return
	cursors.clear_override(BUILDING_MODE_CURSOR_OVERRIDE)


func _can_sell_building(building: Node3D) -> bool:
	var players = _players()
	return (
		building != null
		and players != null
		and building.has_method("is_owned_by")
		and building.call("is_owned_by", players.local_player_id)
	)


func _cursor_manager() -> Variant:
	if not is_inside_tree():
		return null
	return get_node_or_null("/root/Cursors")


func _on_sold_building_animation_finished(animation_name: StringName, building: Node3D) -> void:
	if animation_name != &"sell":
		return
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
	var cost := int(config.cost) if config != null else 0
	return maxi(cost / 2, 0)


func _try_handle_building_double_click(screen_position: Vector2) -> bool:
	var hit := _raycast(screen_position, 2)
	var building := _find_building(hit.get("collider") as Node)
	if building == null:
		return false

	var players = _players()
	if players == null or not building.has_method("is_owned_by") or not building.call("is_owned_by", players.local_player_id):
		return false

	var now := Time.get_ticks_msec()
	if not _building_double_click.register_click(building, now, DOUBLE_CLICK_THRESHOLD_MS):
		return false

	return _designate_primary_building(building, players.local_player_id)


func _designate_primary_building(building: Node3D, player_id: int) -> bool:
	var config = building.get("building_config") as Resource
	if config == null:
		config = _building_config(StringName(String(building.get("config_id"))))
	if config == null or not config.can_be_primary:
		return false

	var players = _players()
	if players == null:
		return false

	if config.is_construction_yard:
		players.set_main_base(player_id, building)
		status_changed.emit("%s designated as primary Construction Yard (main base)" % String(building.get("config_id")))
		return true

	# Unit queues are shared by building type; the primary instance is the one
	# that releases completed units and owns that queue's rally point.
	var group_key := String(building.get("config_id"))
	if group_key.is_empty():
		return false
	players.designate_primary_building(building, player_id, group_key)
	status_changed.emit("%s designated as primary production building" % group_key)
	return true


func _find_building(node: Node) -> Node3D:
	var current := node
	while current != null:
		if current.is_in_group("buildings") and current is Node3D:
			return current as Node3D
		current = current.get_parent()
	return null


func _bind_local_player_roster() -> void:
	var players = _players()
	if players == null:
		_refresh_player_resources()
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
	_local_player_resource = _local_player()

	if _local_player_resource != null and not _local_player_resource.resources_changed.is_connected(callback):
		_local_player_resource.resources_changed.connect(callback)

	_refresh_player_resources()


func _on_local_player_changed(_player_id: int) -> void:
	_bind_local_player_resource()
	_refresh_building_option_states()


func _on_local_player_resources_changed(_player_id: int, _money: int, _energy: int) -> void:
	_refresh_player_resources()
	_refresh_building_option_states()


func _refresh_player_resources() -> void:
	var player = _local_player()
	resources_changed.emit(player.money if player != null else 0, player.energy if player != null else 0)


func _load_building_configs() -> void:
	for building_id in _building_ids:
		var config: Resource = _definition_catalog.definition(building_id)
		if config == null:
			push_warning("Building definition not found: %s" % String(building_id))
			continue
		_building_configs[building_id] = config


func _on_building_slot_left_pressed(building_id: StringName) -> void:
	if _is_wall_building_id(building_id):
		_on_wall_slot_left_pressed(building_id)
		return

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

	_refresh_building_option_states()


## Wall's own entry point (docs/mechanics/production.md section 2 "walls"):
## a fresh click starts the interactive line-picking mode instead of the
## plain "queue then place" flow _start_building_order() uses, but once a
## chain/order for this wall id is already in flight, clicking the same slot
## again falls back to the normal pause/resume/ready-to-place handling below.
func _on_wall_slot_left_pressed(building_id: StringName) -> void:
	var order := _building_queue.current_order()
	var chain_active := _wall_chain != null and _wall_chain.building_id == building_id

	if order == null and not chain_active:
		_set_wall_line_mode(true, building_id)
	elif order != null and order.building_id == building_id:
		if order.ready:
			_begin_ready_building_placement()
		elif order.manually_paused:
			_building_queue.resume()
			status_changed.emit("%s construction resumed" % order.display_name)
		else:
			var status := "%s construction is waiting for credits" if _building_queue.lacks_funds() else "%s construction is already running"
			status_changed.emit(status % order.display_name)
	else:
		status_changed.emit("Building queue is busy")

	_refresh_building_option_states()


func _on_building_slot_right_pressed(building_id: StringName) -> void:
	if _is_wall_building_id(building_id) and _wall_line_mode and _wall_line_building_id == building_id:
		_set_wall_line_mode(false)
		return

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
		_refresh_building_option_states()


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
		_refresh_building_option_states()
		return

	if not _building_queue.start(
		building_id,
		_building_display_name(building_id),
		maxi(config.cost, 0),
		maxf(config.build_time_ticks, 1.0)
	):
		return
	_building_placement.cancel()

	status_changed.emit("%s ordered" % _building_queue.current_order().display_name)
	_refresh_building_option_states()


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
		_refresh_building_option_states()


func _on_building_queue_ready(order: BuildingOrder) -> void:
	if _wall_chain != null:
		_place_wall_chain_segment()
		return
	status_changed.emit("%s ready" % order.display_name)
	_refresh_building_option_states()


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
	# The wall chain only ever auto-orders its next cell once the current one
	# succeeds (docs/mechanics/production.md section 2 "walls"), so cancelling
	# the in-flight cell's order is enough to stop the whole chain.
	_wall_chain = null
	status_changed.emit("%s canceled; refunded %d" % [display_name, refunded])
	_refresh_building_option_states()


func _begin_ready_building_placement() -> void:
	var order := _building_queue.current_order()
	if order == null or not order.ready:
		return

	var config := _building_config(order.building_id)
	var occupy_rows := _building_occupy_rows(config)
	if not _building_placement.begin(order.building_id, order.display_name, occupy_rows, _is_wall_building_id(order.building_id)):
		status_changed.emit("%s has no occupy_rows" % order.display_name)
		return

	_building_placement.process(get_viewport().get_mouse_position())
	status_changed.emit("%s placement ready" % order.display_name)
	_refresh_building_option_states()


func _start_wall_chain(from_nav_cell: Vector2i, to_nav_cell: Vector2i, building_id: StringName = &"ATWall") -> void:
	if String(building_id).is_empty():
		building_id = &"ATWall"
	if _building_queue.has_order() or _wall_chain != null:
		status_changed.emit("Building queue is busy")
		return

	var config := _building_config(building_id)
	if config == null:
		status_changed.emit("Wall rules are not loaded")
		return

	var cell_span := BuildingPlacementScript.NAV_CELLS_PER_OCCUPY_CELL
	var from_occupy_cell := Vector2i(
		int(floor(float(from_nav_cell.x) / float(cell_span))),
		int(floor(float(from_nav_cell.y) / float(cell_span)))
	)
	var to_occupy_cell := Vector2i(
		int(floor(float(to_nav_cell.x) / float(cell_span))),
		int(floor(float(to_nav_cell.y) / float(cell_span)))
	)
	var occupy_cells := WallLineScript.occupy_cells_between(from_occupy_cell, to_occupy_cell)
	var nav_cells: Array[Vector2i] = []
	for occupy_cell in occupy_cells:
		nav_cells.append(occupy_cell * cell_span)

	var players = _players()
	var owner_player_id = players.local_player_id if players != null else null
	_wall_chain = WallChainScript.new(
		building_id,
		_building_display_name(building_id),
		maxi(config.cost, 0),
		maxf(config.build_time_ticks, 1.0),
		nav_cells,
		owner_player_id
	)
	_advance_wall_chain()


func _advance_wall_chain() -> void:
	if _wall_chain == null:
		return
	if not _building_queue.start(_wall_chain.building_id, _wall_chain.display_name, _wall_chain.cost, _wall_chain.build_time_ticks):
		status_changed.emit("%s segment could not be queued" % _wall_chain.display_name)
		_wall_chain = null
		return
	status_changed.emit(
		"%s segment %d/%d ordered" % [_wall_chain.display_name, _wall_chain.segment_index(), _wall_chain.segment_count()]
	)
	_refresh_building_option_states()


func _place_wall_chain_segment() -> void:
	var chain := _wall_chain
	var completed_order := _building_queue.take_ready()

	var config := _building_config(chain.building_id)
	var occupy_rows := _building_occupy_rows(config)
	if not _building_placement.begin(chain.building_id, chain.display_name, occupy_rows, true):
		_refund_completed_wall_segment(completed_order)
		status_changed.emit("%s has no occupy_rows" % chain.display_name)
		_wall_chain = null
		_refresh_building_option_states()
		return

	var scene_path := _building_scene_path(chain.building_id)
	if not ResourceLoader.exists(scene_path):
		_refund_completed_wall_segment(completed_order)
		status_changed.emit("%s placement valid; missing scene %s" % [chain.display_name, scene_path])
		_building_placement.cancel()
		_wall_chain = null
		_refresh_building_option_states()
		return

	var scene := load(scene_path) as PackedScene
	var placed := _building_placement.try_place_at_hover_cell(chain.current_cell(), scene, chain.owner_player_id)
	if placed != BuildingPlacementScript.PlaceResult.PLACED:
		_refund_completed_wall_segment(completed_order)
		status_changed.emit("%s segment could not be placed; wall chain stopped" % chain.display_name)
		_wall_chain = null
		_refresh_building_option_states()
		return

	if chain.advance():
		status_changed.emit(
			"%s segment %d/%d placed" % [chain.display_name, chain.segment_index() - 1, chain.segment_count()]
		)
		_advance_wall_chain()
	else:
		status_changed.emit("%s wall complete" % chain.display_name)
		_wall_chain = null
		_refresh_building_option_states()


func _refund_completed_wall_segment(order: BuildingOrder) -> void:
	if order == null or order.paid_cost <= 0:
		return
	var player = _local_player()
	if player != null:
		player.add_money(order.paid_cost)


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
			_refresh_building_option_states()
		BuildingPlacementScript.PlaceResult.INVALID_SCENE:
			status_changed.emit("%s scene is not a Node3D" % order.display_name)
		BuildingPlacementScript.PlaceResult.MISSING_BUILDINGS_ROOT:
			status_changed.emit("Buildings root is missing")


func _cancel_building_placement() -> void:
	_reset_placement_pointer_action()
	if not _building_placement.is_active():
		return
	var display_name := _building_placement.cancel()
	status_changed.emit("%s placement canceled" % display_name)
	_refresh_building_option_states()


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

	for row in config.occupy_rows:
		var row_text := String(row)
		if not row_text.is_empty():
			rows.append(row_text)
	return rows


func _occupy_rows_for_existing_building(building: Node3D) -> Array[String]:
	var config = building.get("building_config") as Resource
	if config == null:
		config = _building_config(StringName(String(building.get("config_id"))))
	return _building_occupy_rows(config)


func _is_wall_building(building: Node3D) -> bool:
	var config = building.get("building_config") as Resource
	if config == null:
		config = _building_config(StringName(String(building.get("config_id"))))
	return _is_wall_config(config)


func _is_wall_building_id(building_id: StringName) -> bool:
	return _is_wall_config(_building_config(building_id))


func _is_wall_config(config: Resource) -> bool:
	return config != null and String(config.building_group_id) == WALL_BUILDING_GROUP


func _build_radius_tiles() -> int:
	var settings := _game_settings_catalog.settings()
	return settings.max_building_placement_tile_dist if settings != null else DEFAULT_BUILD_RADIUS_TILES


func _building_config(building_id: StringName) -> Resource:
	# Guards against teardown-order signal cascades: a freed building's
	# _exit_tree() can still trigger _refresh_building_option_states() (via
	# the energy/resources signal chain) after this controller has left the
	# tree, at which point absolute-path autoload lookups are invalid.
	return _definition_catalog.definition(building_id)


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
	var definition := _definition_catalog.definition(building_id)
	return definition.model_name if definition != null else ""


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
	return _technology_tree.is_available(config, player, buildings, max_tech_level)


func _refresh_building_option_states() -> void:
	var order := _building_queue.current_order()
	for building_id in _building_ids:
		var tooltip := _building_tooltip(building_id)

		if _is_wall_building_id(building_id) and _wall_line_mode and _wall_line_building_id == building_id:
			var picking_status := "Pick line end" if _wall_line_start_cell != null else "Pick line start"
			building_option_state_changed.emit(BuildingOptionStateScript.new(
				building_id, BuildingOptionStateScript.State.PROGRESS, 0.0, picking_status, tooltip
			))
			continue

		if order == null:
			var state := BuildingOptionStateScript.State.AVAILABLE if _is_building_available(building_id) else BuildingOptionStateScript.State.DISABLED
			building_option_state_changed.emit(BuildingOptionStateScript.new(building_id, state, 0.0, "", tooltip))
			continue

		if order.building_id != building_id:
			var state := BuildingOptionStateScript.State.BLOCKED if _is_building_available(building_id) else BuildingOptionStateScript.State.DISABLED
			building_option_state_changed.emit(BuildingOptionStateScript.new(building_id, state, 0.0, "", tooltip))
			continue

		if order.ready:
			var ready_status_text := "PLACE" if _building_placement.is_active() else "READY"
			building_option_state_changed.emit(BuildingOptionStateScript.new(
				building_id, BuildingOptionStateScript.State.READY, 100.0, ready_status_text, tooltip
			))
			continue

		var status_text := ""
		if order.manually_paused:
			status_text = "PAUSED"
		building_option_state_changed.emit(BuildingOptionStateScript.new(
			building_id,
			BuildingOptionStateScript.State.PROGRESS,
			order.progress_percent(),
			status_text,
			tooltip
		))


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

	var cost: int = int(config.cost)
	var build_time_ticks: float = float(config.build_time_ticks)
	var build_seconds: float = build_time_ticks / BuildingQueueScript.BUILD_TICKS_PER_SECOND
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


func _local_player() -> PlayerData:
	var players = _players()
	if players == null:
		return null
	return players.local_player() as PlayerData


func _local_player_id() -> int:
	var player := _local_player()
	return player.player_id if player != null else -1
