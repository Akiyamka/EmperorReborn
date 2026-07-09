class_name BuildingController
extends Node3D

signal status_changed(status: String)

const BuildingOrderScript := preload("res://scripts/buildings/building_order.gd")
const BUILD_TICKS_PER_SECOND := 60.0
const PLACEMENT_ARROW_SCENE := preload("res://assets/converted_placement/build_arrow.scn")
const PLACEMENT_BUILDING_SCENE := preload("res://assets/converted_placement/build_building.scn")
const PLACEMENT_CANT_BUILD_SCENE := preload("res://assets/converted_placement/build_cantbuild.scn")
const PLACEMENT_SKIRT_SCENE := preload("res://assets/converted_placement/build_skirt.scn")
const PLACEMENT_NAV_CELLS_PER_OCCUPY_CELL := 2
const PLACEMENT_CELL_SURFACE_OFFSET := 0.06
const PLACEMENT_CELL_EMISSION_ENERGY := 1.8
const INVALID_PLACEMENT_ANCHOR := Vector2i(-999999, -999999)

var side_panel: SidePanel
var terrain: MapLoader
var camera: Camera3D
var buildings_root: Node3D

var _hardcoded_building_config: Resource
var _building_order
var _building_lack_funds := false
var _local_player_resource = null
var _placing_building_id: StringName = &""
var _sell_mode := false
var _selling_building: Node3D
var _placement_preview_root: Node3D
var _placement_occupy_rows: Array[String] = []
var _placement_anchor_cell := INVALID_PLACEMENT_ANCHOR
var _placement_has_anchor := false
var _placement_can_build := false


func setup(panel: SidePanel, map_loader: MapLoader, placement_camera: Camera3D, building_parent: Node3D) -> void:
	side_panel = panel
	terrain = map_loader
	camera = placement_camera
	buildings_root = building_parent

	_bind_local_player_roster()
	_load_hardcoded_building()

	if side_panel != null:
		side_panel.queue_slot_pressed.connect(_on_panel_queue_slot)
		side_panel.tab_changed.connect(_on_panel_tab_changed)
		side_panel.command_pressed.connect(_on_panel_command)

	_refresh_player_credits()
	_refresh_building_queue_slot()


func process(delta: float) -> void:
	_process_building_order(delta)
	_process_building_placement()


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

	if not _is_placing_building():
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
	if tab != SidePanel.Tab.BUILDINGS or slot_index != SidePanel.HARDCODED_BUILDING_SLOT:
		return

	match button_index:
		MOUSE_BUTTON_LEFT:
			_on_building_slot_left_pressed()
		MOUSE_BUTTON_RIGHT:
			_on_building_slot_right_pressed()


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


func _load_hardcoded_building() -> void:
	var rules := get_node_or_null("/root/Rules")
	if rules == null:
		push_warning("Rules autoload is not available; building production uses no rules")
		return

	_hardcoded_building_config = rules.call("building", SidePanel.HARDCODED_BUILDING_ID)
	if _hardcoded_building_config == null:
		push_warning("Building rules config not found: %s" % String(SidePanel.HARDCODED_BUILDING_ID))


func _on_building_slot_left_pressed() -> void:
	if _building_order == null:
		_start_building_order()
	elif _building_order.ready:
		_begin_ready_building_placement()
	elif _building_order.manually_paused:
		_building_order.manually_paused = false
		_building_lack_funds = false
		status_changed.emit("%s construction resumed" % _building_order.display_name)
	else:
		var status := "%s construction is waiting for credits" if _building_lack_funds else "%s construction is already running"
		status_changed.emit(status % _building_order.display_name)

	_refresh_building_queue_slot()


func _on_building_slot_right_pressed() -> void:
	if _building_order == null:
		return

	if _is_placing_building():
		_cancel_building_placement()
		return

	if _building_order.ready or _building_order.manually_paused:
		_cancel_building_order()
	else:
		_building_order.manually_paused = true
		_building_lack_funds = false
		status_changed.emit("%s construction paused" % _building_order.display_name)
		_refresh_building_queue_slot()


func _start_building_order() -> void:
	if _hardcoded_building_config == null:
		status_changed.emit("Building rules are not loaded")
		return
	if _building_order != null:
		status_changed.emit("Building queue is busy")
		return

	var order := BuildingOrderScript.new()
	order.building_id = SidePanel.HARDCODED_BUILDING_ID
	order.display_name = _hardcoded_building_display_name()
	order.cost = maxi(int(_hardcoded_building_config.field(&"cost", 0)), 0)
	order.build_time_ticks = maxf(float(_hardcoded_building_config.field(&"build_time", 0.0)), 1.0)
	_building_order = order
	_building_lack_funds = false
	_clear_building_placement()

	status_changed.emit("%s ordered" % order.display_name)
	_refresh_building_queue_slot()


func _process_building_order(delta: float) -> void:
	if _building_order == null or _building_order.ready or _building_order.manually_paused:
		return

	if _building_order.cost <= 0:
		_building_order.elapsed_ticks += delta * BUILD_TICKS_PER_SECOND
		if _building_order.elapsed_ticks >= _building_order.build_time_ticks:
			_mark_building_order_ready()
		_refresh_building_queue_slot()
		return

	var player = _local_player()
	if player == null:
		_set_building_lack_funds(true)
		return

	if player.money <= 0:
		_set_building_lack_funds(true)
		return

	_set_building_lack_funds(false)
	var remaining_cost: int = int(_building_order.cost) - int(_building_order.paid_cost)
	if remaining_cost <= 0:
		_mark_building_order_ready()
		return

	var build_seconds: float = float(_building_order.build_time_ticks) / BUILD_TICKS_PER_SECOND
	var credits_per_second: float = float(_building_order.cost) / build_seconds
	_building_order.charge_accumulator += delta * credits_per_second

	var credits_due: int = mini(int(floor(_building_order.charge_accumulator)), remaining_cost)
	if credits_due <= 0:
		return

	var credits_paid: int = mini(credits_due, player.money)
	_building_order.charge_accumulator -= float(credits_due)
	if credits_paid <= 0:
		_set_building_lack_funds(true)
		return

	if not player.spend_money(credits_paid):
		_set_building_lack_funds(true)
		return

	_building_order.paid_cost += credits_paid
	if credits_paid < credits_due:
		_set_building_lack_funds(true)

	if _building_order.paid_cost >= _building_order.cost:
		_mark_building_order_ready()
	else:
		_refresh_building_queue_slot()


func _mark_building_order_ready() -> void:
	if _building_order == null:
		return

	_building_order.ready = true
	_building_order.manually_paused = false
	_building_lack_funds = false
	status_changed.emit("%s ready" % _building_order.display_name)
	_refresh_building_queue_slot()


func _cancel_building_order() -> void:
	if _building_order == null:
		return

	var refunded: int = int(_building_order.paid_cost)
	var display_name := String(_building_order.display_name)
	var player = _local_player()
	if player != null and refunded > 0:
		player.add_money(refunded)

	_building_order = null
	_building_lack_funds = false
	_clear_building_placement()
	status_changed.emit("%s canceled; refunded %d" % [display_name, refunded])
	_refresh_building_queue_slot()


func _begin_ready_building_placement() -> void:
	if _building_order == null or not _building_order.ready:
		return

	var config := _building_config(_building_order.building_id)
	var occupy_rows := _building_occupy_rows(config)
	if occupy_rows.is_empty():
		status_changed.emit("%s has no occupy_rows" % _building_order.display_name)
		return

	_placing_building_id = _building_order.building_id
	_placement_occupy_rows = occupy_rows
	_placement_anchor_cell = INVALID_PLACEMENT_ANCHOR
	_placement_has_anchor = false
	_placement_can_build = false
	_ensure_placement_preview_root()
	_update_building_placement_preview(get_viewport().get_mouse_position())
	status_changed.emit("%s placement ready" % _building_order.display_name)
	_refresh_building_queue_slot()


func _process_building_placement() -> void:
	if not _is_placing_building():
		return

	_update_building_placement_preview(get_viewport().get_mouse_position())


func _try_place_ready_building(screen_position: Vector2) -> void:
	if _building_order == null or not _is_placing_building():
		return

	_update_building_placement_preview(screen_position)
	if not _placement_has_anchor:
		status_changed.emit("%s placement needs terrain" % _building_order.display_name)
		return
	if not _placement_can_build:
		status_changed.emit("%s cannot be placed there" % _building_order.display_name)
		return

	var scene_path := _building_scene_path(_placing_building_id)
	if not ResourceLoader.exists(scene_path):
		status_changed.emit(
			"%s placement valid; missing scene %s" % [_building_order.display_name, scene_path]
		)
		return

	var scene := load(scene_path) as PackedScene
	var building := scene.instantiate() as Node3D if scene != null else null
	if building == null:
		status_changed.emit("%s scene is not a Node3D" % _building_order.display_name)
		return
	if buildings_root == null:
		status_changed.emit("Buildings root is missing")
		return

	var display_name := String(_building_order.display_name)
	if building.has_method("setup"):
		building.call("setup", _placing_building_id)
	buildings_root.add_child(building)
	building.global_position = _snap_to_ground(_placement_world_center(_placement_anchor_cell))

	var players = _players()
	if players != null and building.has_method("set_owner_player_id"):
		building.call("set_owner_player_id", players.local_player_id)

	_play_placed_building_animation(building)

	_building_order = null
	_building_lack_funds = false
	_clear_building_placement()
	status_changed.emit("%s placed" % display_name)
	_refresh_building_queue_slot()


func _cancel_building_placement() -> void:
	if not _is_placing_building():
		return

	var display_name: String = (
		String(_building_order.display_name)
		if _building_order != null
		else String(_placing_building_id)
	)
	_clear_building_placement()
	status_changed.emit("%s placement canceled" % display_name)
	_refresh_building_queue_slot()


func _play_placed_building_animation(building: Node3D) -> void:
	var player := building.get_node_or_null("StatePlayer") as AnimationPlayer
	if player != null and player.has_animation(&"build"):
		var build_animation := player.get_animation(&"build")
		if build_animation != null:
			build_animation.loop_mode = Animation.LOOP_NONE
		var callback := Callable(self, "_on_placed_building_animation_finished").bind(building)
		player.animation_finished.connect(callback, CONNECT_ONE_SHOT)
		_play_building_state(building, &"build")
		return

	_play_building_state(building, &"idle")


func _on_placed_building_animation_finished(_animation_name: StringName, building: Node3D) -> void:
	if not is_instance_valid(building):
		return

	_play_building_state(building, &"idle")


func _play_building_state(building: Node3D, state: StringName) -> void:
	if building.has_method("play_state"):
		building.call("play_state", state)
		return

	var player := building.get_node_or_null("StatePlayer") as AnimationPlayer
	if player != null and player.has_animation(state):
		player.play(state)


func _clear_building_placement() -> void:
	_placing_building_id = &""
	_placement_occupy_rows.clear()
	_placement_anchor_cell = INVALID_PLACEMENT_ANCHOR
	_placement_has_anchor = false
	_placement_can_build = false

	if _placement_preview_root != null:
		_clear_placement_preview_cells()
		_placement_preview_root.queue_free()
		_placement_preview_root = null


func _update_building_placement_preview(screen_position: Vector2) -> void:
	if not _is_placing_building():
		return
	if terrain == null or terrain.navigation_grid == null or not terrain.navigation_grid.is_loaded():
		_hide_placement_preview()
		return

	var hit := _raycast(screen_position, 1)
	if hit.is_empty():
		_hide_placement_preview()
		return

	var hover_cell: Vector2i = terrain.navigation_grid.world_to_grid(hit["position"])
	var anchor_cell := _placement_anchor_for_hover_cell(hover_cell)
	_ensure_placement_preview_root()
	if _placement_has_anchor and _placement_anchor_cell == anchor_cell and _placement_preview_root.visible:
		return

	_placement_preview_root.visible = true
	_placement_anchor_cell = anchor_cell
	_placement_has_anchor = true
	_rebuild_placement_preview(anchor_cell)


func _rebuild_placement_preview(anchor_cell: Vector2i) -> void:
	_clear_placement_preview_cells()

	var has_cells := false
	var can_build := true
	for row_index in _placement_occupy_rows.size():
		var row := _placement_occupy_rows[row_index]
		for column_index in row.length():
			var marker := row.substr(column_index, 1)
			if _is_empty_occupy_marker(marker):
				continue

			has_cells = true
			var grid_cell := anchor_cell + _occupy_offset_to_nav_cell(column_index, row_index)
			var cell_buildable := _is_occupy_cell_buildable(grid_cell)
			can_build = can_build and cell_buildable

			var placement_scene := _placement_scene_for_marker(marker, cell_buildable)
			var preview_cell := placement_scene.instantiate() as Node3D
			if preview_cell == null:
				continue

			preview_cell.name = "Cell_%d_%d_%s" % [column_index, row_index, marker]
			_configure_placement_preview_cell(preview_cell)
			_placement_preview_root.add_child(preview_cell)
			var cell_center: Vector3 = _occupy_cell_world_center(grid_cell)
			preview_cell.global_position = (
				_snap_to_ground(cell_center)
				+ Vector3.UP * PLACEMENT_CELL_SURFACE_OFFSET
			)

	_placement_can_build = has_cells and can_build
	if has_cells:
		_add_placement_arrow(anchor_cell)


func _clear_placement_preview_cells() -> void:
	if _placement_preview_root == null:
		return

	for child in _placement_preview_root.get_children():
		_placement_preview_root.remove_child(child)
		child.queue_free()


func _add_placement_arrow(anchor_cell: Vector2i) -> void:
	var arrow := PLACEMENT_ARROW_SCENE.instantiate() as Node3D
	if arrow == null:
		return

	arrow.name = "CenterArrow"
	_configure_placement_arrow_visuals(arrow)
	_placement_preview_root.add_child(arrow)
	arrow.global_position = (
		_snap_to_ground(_placement_world_center(anchor_cell))
		+ Vector3.UP * PLACEMENT_CELL_SURFACE_OFFSET
	)


func _configure_placement_preview_cell(cell: Node3D) -> void:
	_configure_placement_preview_visuals(cell)


func _configure_placement_arrow_visuals(node: Node) -> void:
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_restore_arrow_fill_materials(mesh_instance)

	for child in node.get_children():
		_configure_placement_arrow_visuals(child)


func _restore_arrow_fill_materials(mesh_instance: MeshInstance3D) -> void:
	if mesh_instance.mesh == null:
		return

	for surface_index in mesh_instance.mesh.get_surface_count():
		var material := mesh_instance.get_active_material(surface_index)
		if not _is_fully_transparent_albedo_material(material):
			continue

		var fill_material := StandardMaterial3D.new()
		fill_material.albedo_color = Color.WHITE
		fill_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		fill_material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
		fill_material.disable_receive_shadows = true
		fill_material.emission_enabled = true
		fill_material.emission = Color.WHITE
		fill_material.emission_energy_multiplier = PLACEMENT_CELL_EMISSION_ENERGY
		mesh_instance.set_surface_override_material(surface_index, fill_material)


func _is_fully_transparent_albedo_material(material: Material) -> bool:
	if not (material is BaseMaterial3D):
		return false

	var base_material := material as BaseMaterial3D
	if base_material.albedo_texture == null:
		return false

	var image := base_material.albedo_texture.get_image()
	if image == null:
		return false

	for y in image.get_height():
		for x in image.get_width():
			if image.get_pixel(x, y).a > 0.0:
				return false
	return true


func _configure_placement_preview_visuals(node: Node) -> void:
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_configure_placement_preview_materials(mesh_instance)

	for child in node.get_children():
		_configure_placement_preview_visuals(child)


func _configure_placement_preview_materials(mesh_instance: MeshInstance3D) -> void:
	mesh_instance.material_override = null
	if mesh_instance.mesh == null:
		return

	for surface_index in mesh_instance.mesh.get_surface_count():
		var material := _placement_blend_material(mesh_instance.get_active_material(surface_index))
		if material != null:
			mesh_instance.set_surface_override_material(surface_index, material)


func _placement_blend_material(source_material: Material) -> Material:
	if source_material == null:
		return null

	var material := source_material.duplicate() as Material
	if material is BaseMaterial3D:
		var base_material := material as BaseMaterial3D
		base_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		base_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		base_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		base_material.disable_receive_shadows = true
		base_material.emission_enabled = true
		base_material.emission = base_material.albedo_color
		base_material.emission_energy_multiplier = PLACEMENT_CELL_EMISSION_ENERGY
		if base_material.albedo_texture != null:
			base_material.emission_texture = base_material.albedo_texture
	return material


func _hide_placement_preview() -> void:
	_placement_anchor_cell = INVALID_PLACEMENT_ANCHOR
	_placement_has_anchor = false
	_placement_can_build = false
	if _placement_preview_root != null:
		_placement_preview_root.visible = false


func _ensure_placement_preview_root() -> void:
	if _placement_preview_root != null:
		return

	_placement_preview_root = Node3D.new()
	_placement_preview_root.name = "BuildingPlacementPreview"
	add_child(_placement_preview_root)


func _placement_anchor_for_hover_cell(hover_cell: Vector2i) -> Vector2i:
	var footprint_size := _placement_occupy_size()
	var hover_occupy_cell := _nav_cell_to_occupy_cell(hover_cell)
	var anchor_occupy_cell := hover_occupy_cell - Vector2i(
		int(floor(float(footprint_size.x) * 0.5)),
		int(floor(float(footprint_size.y) * 0.5))
	)
	return _occupy_cell_to_nav_cell(anchor_occupy_cell)


func _placement_occupy_size() -> Vector2i:
	var width := 0
	for row in _placement_occupy_rows:
		width = maxi(width, row.length())
	return Vector2i(width, _placement_occupy_rows.size())


func _placement_world_center(anchor_cell: Vector2i) -> Vector3:
	var footprint_size := _placement_nav_size()
	var start: Vector3 = terrain.navigation_grid.grid_to_world(anchor_cell, false)
	var end: Vector3 = terrain.navigation_grid.grid_to_world(anchor_cell + footprint_size, false)
	return (start + end) * 0.5


func _placement_nav_size() -> Vector2i:
	var occupy_size := _placement_occupy_size()
	return Vector2i(
		occupy_size.x * PLACEMENT_NAV_CELLS_PER_OCCUPY_CELL,
		occupy_size.y * PLACEMENT_NAV_CELLS_PER_OCCUPY_CELL
	)


func _occupy_offset_to_nav_cell(column_index: int, row_index: int) -> Vector2i:
	return Vector2i(
		column_index * PLACEMENT_NAV_CELLS_PER_OCCUPY_CELL,
		row_index * PLACEMENT_NAV_CELLS_PER_OCCUPY_CELL
	)


func _nav_cell_to_occupy_cell(nav_cell: Vector2i) -> Vector2i:
	return Vector2i(
		int(floor(float(nav_cell.x) / float(PLACEMENT_NAV_CELLS_PER_OCCUPY_CELL))),
		int(floor(float(nav_cell.y) / float(PLACEMENT_NAV_CELLS_PER_OCCUPY_CELL)))
	)


func _occupy_cell_to_nav_cell(occupy_cell: Vector2i) -> Vector2i:
	return Vector2i(
		occupy_cell.x * PLACEMENT_NAV_CELLS_PER_OCCUPY_CELL,
		occupy_cell.y * PLACEMENT_NAV_CELLS_PER_OCCUPY_CELL
	)


func _occupy_cell_world_center(nav_cell: Vector2i) -> Vector3:
	var start: Vector3 = terrain.navigation_grid.grid_to_world(nav_cell, false)
	var end: Vector3 = terrain.navigation_grid.grid_to_world(
		nav_cell + Vector2i(
			PLACEMENT_NAV_CELLS_PER_OCCUPY_CELL,
			PLACEMENT_NAV_CELLS_PER_OCCUPY_CELL
		),
		false
	)
	return (start + end) * 0.5


func _is_occupy_cell_buildable(nav_cell: Vector2i) -> bool:
	for y in PLACEMENT_NAV_CELLS_PER_OCCUPY_CELL:
		for x in PLACEMENT_NAV_CELLS_PER_OCCUPY_CELL:
			if not _is_nav_cell_buildable(nav_cell + Vector2i(x, y)):
				return false
	return true


func _is_nav_cell_buildable(grid_cell: Vector2i) -> bool:
	var debug: Dictionary = terrain.navigation_grid.cell_debug(grid_cell)
	return bool(debug.get("valid", false)) and bool(debug.get("buildable", false))


func _placement_scene_for_marker(marker: String, buildable: bool) -> PackedScene:
	if not buildable:
		return PLACEMENT_CANT_BUILD_SCENE
	if marker.to_lower() == "s":
		return PLACEMENT_SKIRT_SCENE
	return PLACEMENT_BUILDING_SCENE


func _is_empty_occupy_marker(marker: String) -> bool:
	return marker.is_empty() or marker == " " or marker == "." or marker == "_" or marker.to_lower() == "n"


func _building_occupy_rows(config: Resource) -> Array[String]:
	var rows: Array[String] = []
	if config == null:
		return rows

	for row in config.list(&"occupy_rows"):
		var row_text := String(row)
		if not row_text.is_empty():
			rows.append(row_text)
	return rows


func _is_placing_building() -> bool:
	return _placing_building_id != &"" and not _placement_occupy_rows.is_empty()


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
	return "res://assets/converted_buildings/%s/%s.scn" % [scene_name, scene_name]


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


func _set_building_lack_funds(value: bool) -> void:
	if _building_lack_funds == value:
		return
	_building_lack_funds = value
	_refresh_building_queue_slot()


func _refresh_building_queue_slot() -> void:
	if side_panel == null:
		return

	var tooltip := _hardcoded_building_tooltip()
	if _building_order == null:
		side_panel.set_building_slot_state(QueueSlot.State.AVAILABLE, 0.0, "", tooltip)
		return

	if _building_order.ready:
		var ready_status_text := "PLACE" if _is_placing_building() else "READY"
		side_panel.set_building_slot_state(QueueSlot.State.READY, 100.0, ready_status_text, tooltip)
		return

	var status_text := ""
	if _building_order.manually_paused:
		status_text = "PAUSED"

	side_panel.set_building_slot_state(
		QueueSlot.State.PROGRESS,
		_building_order.progress_percent(),
		status_text,
		tooltip
	)


func _hardcoded_building_display_name() -> String:
	return "Windtrap"


func _hardcoded_building_tooltip() -> String:
	if _hardcoded_building_config == null:
		return _hardcoded_building_display_name()

	var cost := int(_hardcoded_building_config.field(&"cost", 0))
	var build_time_ticks := float(_hardcoded_building_config.field(&"build_time", 0.0))
	var build_seconds := build_time_ticks / BUILD_TICKS_PER_SECOND
	return "%s\nCost: %d\nBuild: %.1fs" % [
		_hardcoded_building_display_name(),
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


func _snap_to_ground(point: Vector3) -> Vector3:
	var query := PhysicsRayQueryParameters3D.create(
		Vector3(point.x, 200.0, point.z), Vector3(point.x, -200.0, point.z), 1
	)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return Vector3(point.x, 0.0, point.z)
	return hit["position"]


func _players():
	if not is_inside_tree():
		return null
	return get_node_or_null("/root/Players")


func _local_player():
	var players = _players()
	if players == null:
		return null
	return players.local_player()
