class_name BuildingUpgradeController
extends Node3D

## docs/mechanics/production.md section 4 "Upgrades". Deliberately a sibling
## of BuildingController rather than more code stuffed into it: it owns a
## second, independent RefCounted queue (UpgradeQueue, "one per player" just
## like BuildingQueue but for a different kind of order) and a second
## "select a target on the map" input mode (dock placement) analogous to
## Sell/Wall, so it needs the same camera/placement plumbing BuildingController
## has, just pointed at a different queue and a different click handler.
##
## Two upgrade shapes share this one queue (docs section 4 "binding"):
## - GLOBAL_TYPE: any building config with upgrade_cost > 0. Purchase is
##   player state (PlayerData.grant_upgrade), applied to every currently
##   owned building of that type via UpgradeEffects and picked up by future
##   ones via Building._sync_purchased_upgrade(). Completes instantly, no
##   placement step -- there is nothing to place.
## - REFINERY_DOCK: instance-bound to the Refinery clicked while dock mode is
##   active (docs: "refinery docks are an upgrade of a specific instance").
##   Auto-placed next to that refinery via RefineryDockLayout once paid for,
##   since its position is fully determined by the refinery's own footprint
##   (see RefineryDockLayout) -- no manual placement UI needed.

signal status_changed(status: String)
signal upgrade_option_state_changed(option_state: BuildingOptionState)
signal dock_mode_changed(active: bool)
## TODO(§3 unit production / economy.md §2.3): a completed dock should spawn
## one harvester (no carryall, no replacement on loss) at the refinery. Unit
## spawning is out of scope here; this signal is the hook for that to attach
## to once it exists.
signal dock_completed(refinery: Node3D)

const UpgradeQueueScript := preload("res://scripts/buildings/upgrade_queue.gd")
const UpgradeOrderScript := preload("res://scripts/buildings/upgrade_order.gd")
const UpgradeEffectsScript := preload("res://scripts/buildings/upgrade_effects.gd")
const RefineryDockLayoutScript := preload("res://scripts/buildings/refinery_dock_layout.gd")
const BuildingPlacementScript := preload("res://scripts/buildings/building_placement.gd")
const BuildingOptionStateScript := preload("res://scripts/buildings/building_option_state.gd")

const REFINERY_ROLE := "Refinery"
const DEFAULT_BUILD_RADIUS_TILES := 6

var camera: Camera3D

var _building_configs: Dictionary = {}
var _upgrade_option_ids: Array[StringName] = []
var _upgrade_queue: UpgradeQueue = UpgradeQueueScript.new()
var _dock_placement: BuildingPlacement = BuildingPlacementScript.new()
var _dock_mode := false
var _dock_mode_building_id: StringName = &""


func setup(
		map_loader: MapLoader,
		placement_camera: Camera3D,
		building_parent: Node3D,
		building_ids: Array[StringName],
		building_preview_scene: PackedScene,
		cant_build_preview_scene: PackedScene,
		skirt_preview_scene: PackedScene
) -> void:
	camera = placement_camera
	if _dock_placement.get_parent() != self:
		add_child(_dock_placement)
	var navigation_grid = map_loader.navigation_grid if map_loader != null else null
	_dock_placement.setup(
		placement_camera,
		navigation_grid,
		building_parent,
		null,
		building_preview_scene,
		cant_build_preview_scene,
		skirt_preview_scene,
		Callable(self, "_occupy_rows_for_existing_building"),
		Callable(),
		Callable(self, "_build_radius_tiles")
	)
	if not _upgrade_queue.order_ready.is_connected(_on_upgrade_queue_ready):
		_upgrade_queue.order_ready.connect(_on_upgrade_queue_ready)

	_load_building_configs(building_ids)
	_refresh_upgrade_option_states()
	dock_mode_changed.emit(_dock_mode)


func process(delta: float) -> void:
	_process_upgrade_order(delta)


func handle_command(command: StringName) -> bool:
	return false


func handle_unhandled_input(event: InputEvent) -> bool:
	if not _dock_mode:
		return false
	if not (event is InputEventMouseButton and event.pressed):
		return false
	if event.button_index == MOUSE_BUTTON_LEFT:
		_on_dock_mode_click(event.position)
		return true
	if event.button_index == MOUSE_BUTTON_RIGHT:
		_set_dock_mode(false)
		return true
	return false


func handle_upgrade_intent(building_id: StringName, button_index: int) -> bool:
	if not _upgrade_option_ids.has(building_id):
		return false
	match button_index:
		MOUSE_BUTTON_LEFT:
			_on_upgrade_slot_left_pressed(building_id)
			return true
		MOUSE_BUTTON_RIGHT:
			_on_upgrade_slot_right_pressed(building_id)
			return true
	return false


func _set_dock_mode(active: bool, building_id: StringName = &"") -> void:
	_dock_mode = active
	_dock_mode_building_id = building_id if active else &""
	dock_mode_changed.emit(active)
	if active:
		status_changed.emit("Upgrade Dock mode: select one of your refineries")
	else:
		status_changed.emit("Upgrade Dock mode canceled")
	_refresh_upgrade_option_states()


func _on_dock_mode_click(screen_position: Vector2) -> void:
	var hit := _raycast(screen_position, 2)
	var building := _find_building(hit.get("collider") as Node)
	if building == null or not _is_refinery(building):
		status_changed.emit("Select one of your refineries to add a dock")
		return

	var players = _players()
	if players == null or not building.has_method("is_owned_by") or not building.call("is_owned_by", players.local_player_id):
		status_changed.emit("You can only upgrade your own refinery")
		return

	_set_dock_mode(false)
	_try_start_dock_upgrade(building)


func _try_start_dock_upgrade(refinery: Node3D) -> void:
	if _upgrade_queue.has_order():
		status_changed.emit("Upgrade queue is busy")
		return
	if not bool(refinery.call("can_add_dock")):
		status_changed.emit("This refinery already has the maximum number of docks")
		return

	var dock_building_id := _dock_building_id_for(refinery)
	var config := _building_config(dock_building_id)
	if config == null:
		status_changed.emit("Refinery dock rules are not loaded")
		return

	if not _upgrade_queue.start(
		dock_building_id,
		_upgrade_display_name(dock_building_id),
		maxi(int(config.field(&"upgrade_cost", 0)), 0),
		maxf(float(config.field(&"build_time", 0.0)), 1.0),
		UpgradeOrderScript.Kind.REFINERY_DOCK,
		refinery
	):
		status_changed.emit("Refinery dock could not be queued")
		return

	status_changed.emit("%s ordered" % _upgrade_queue.current_order().display_name)
	_refresh_upgrade_option_states()


func _on_upgrade_slot_left_pressed(building_id: StringName) -> void:
	if _is_refinery_dock_id(building_id):
		_on_dock_slot_left_pressed(building_id)
		return

	var order := _upgrade_queue.current_order()
	if order == null:
		_start_global_upgrade_order(building_id)
	elif order.kind != UpgradeOrderScript.Kind.GLOBAL_TYPE or order.upgrade_id != building_id:
		status_changed.emit("Upgrade queue is busy")
	elif order.manually_paused:
		_upgrade_queue.resume()
		status_changed.emit("%s upgrade resumed" % order.display_name)
	else:
		var status := "%s upgrade is waiting for credits" if _upgrade_queue.lacks_funds() else "%s upgrade is already running"
		status_changed.emit(status % order.display_name)

	_refresh_upgrade_option_states()


## Dock's own entry point (docs section 4 "instance-bound"): a fresh click
## starts refinery-picking mode instead of the plain global-purchase flow
## _start_global_upgrade_order() uses; once an order for this dock id is
## already in flight it falls back to the normal pause/resume handling.
func _on_dock_slot_left_pressed(building_id: StringName) -> void:
	var order := _upgrade_queue.current_order()
	var dock_order_active := order != null and order.kind == UpgradeOrderScript.Kind.REFINERY_DOCK and order.upgrade_id == building_id

	if order == null:
		_set_dock_mode(true, building_id)
	elif dock_order_active:
		if order.manually_paused:
			_upgrade_queue.resume()
			status_changed.emit("%s upgrade resumed" % order.display_name)
		else:
			var status := "%s upgrade is waiting for credits" if _upgrade_queue.lacks_funds() else "%s upgrade is already running"
			status_changed.emit(status % order.display_name)
	else:
		status_changed.emit("Upgrade queue is busy")

	_refresh_upgrade_option_states()


func _on_upgrade_slot_right_pressed(building_id: StringName) -> void:
	if _is_refinery_dock_id(building_id):
		_on_dock_slot_right_pressed(building_id)
		return

	var order := _upgrade_queue.current_order()
	if order == null or order.kind != UpgradeOrderScript.Kind.GLOBAL_TYPE or order.upgrade_id != building_id:
		return

	if order.manually_paused:
		_cancel_upgrade_order()
	else:
		_upgrade_queue.pause()
		status_changed.emit("%s upgrade paused" % order.display_name)
		_refresh_upgrade_option_states()


func _on_dock_slot_right_pressed(building_id: StringName) -> void:
	if _dock_mode and _dock_mode_building_id == building_id:
		_set_dock_mode(false)
		return

	var order := _upgrade_queue.current_order()
	if order == null or order.kind != UpgradeOrderScript.Kind.REFINERY_DOCK or order.upgrade_id != building_id:
		return

	if order.manually_paused:
		_cancel_upgrade_order()
	else:
		_upgrade_queue.pause()
		status_changed.emit("%s upgrade paused" % order.display_name)
		_refresh_upgrade_option_states()


func _start_global_upgrade_order(building_id: StringName) -> void:
	var config: Resource = _building_configs.get(building_id)
	if config == null:
		status_changed.emit("Upgrade rules are not loaded")
		return
	if _upgrade_queue.has_order():
		status_changed.emit("Upgrade queue is busy")
		return
	if not _is_upgrade_available(building_id):
		status_changed.emit("%s upgrade is not available" % _upgrade_display_name(building_id))
		_refresh_upgrade_option_states()
		return

	# Rules has no separate "upgrade build time" field -- global upgrades
	# reuse the building's own build_time as their construction time
	# (docs/mechanics/production.md section 4).
	if not _upgrade_queue.start(
		building_id,
		_upgrade_display_name(building_id),
		maxi(int(config.field(&"upgrade_cost", 0)), 0),
		maxf(float(config.field(&"build_time", 0.0)), 1.0)
	):
		return

	status_changed.emit("%s ordered" % _upgrade_queue.current_order().display_name)
	_refresh_upgrade_option_states()


func _cancel_upgrade_order() -> void:
	var order := _upgrade_queue.current_order()
	if order == null:
		return

	var display_name := order.display_name
	var refunded := _upgrade_queue.cancel()
	var player := _local_player()
	if player != null and refunded > 0:
		player.add_money(refunded)
	status_changed.emit("%s canceled; refunded %d" % [display_name, refunded])
	_refresh_upgrade_option_states()


func _process_upgrade_order(delta: float) -> void:
	var order := _upgrade_queue.current_order()
	if order == null:
		return
	if order.kind == UpgradeOrderScript.Kind.REFINERY_DOCK and not is_instance_valid(order.target_refinery):
		_cancel_upgrade_order()
		return

	var player := _local_player()
	var available_credits: int = player.money if player != null else 0
	var spend_credits: Callable = Callable(player, &"spend_money") if player != null else Callable()
	if _upgrade_queue.tick(delta, available_credits, spend_credits):
		_refresh_upgrade_option_states()


func _on_upgrade_queue_ready(order: UpgradeOrder) -> void:
	match order.kind:
		UpgradeOrderScript.Kind.GLOBAL_TYPE:
			_complete_global_upgrade(order)
		UpgradeOrderScript.Kind.REFINERY_DOCK:
			_complete_dock_upgrade(order)


func _complete_global_upgrade(order: UpgradeOrder) -> void:
	_upgrade_queue.take_ready()
	var player := _local_player()
	if player != null:
		player.grant_upgrade(order.upgrade_id)
		var buildings: Array = []
		if is_inside_tree():
			buildings.assign(get_tree().get_nodes_in_group("buildings"))
		UpgradeEffectsScript.apply_to_existing_buildings(buildings, player.player_id, order.upgrade_id)
	status_changed.emit("%s upgraded" % order.display_name)
	_refresh_upgrade_option_states()


func _complete_dock_upgrade(order: UpgradeOrder) -> void:
	_upgrade_queue.take_ready()

	var refinery := order.target_refinery
	if not is_instance_valid(refinery):
		status_changed.emit("%s lost its refinery before it could be built" % order.display_name)
		_refresh_upgrade_option_states()
		return

	var dock_building_id := order.upgrade_id
	var config := _building_config(dock_building_id)
	var occupy_rows := _occupy_rows(config)
	if config == null or not _dock_placement.begin(dock_building_id, order.display_name, occupy_rows):
		_refund_and_fail(order, "%s could not be placed" % order.display_name)
		return

	var anchor_cell = _dock_anchor_cell(refinery, occupy_rows, int(refinery.call("dock_count")))
	if anchor_cell == null:
		_dock_placement.cancel()
		_refund_and_fail(order, "%s has no room near this refinery" % order.display_name)
		return

	var scene_path := _building_scene_path(dock_building_id)
	if not ResourceLoader.exists(scene_path):
		_dock_placement.cancel()
		_refund_and_fail(order, "%s placement valid; missing scene %s" % [order.display_name, scene_path])
		return

	var scene := load(scene_path) as PackedScene
	var players = _players()
	var owner_player_id = players.local_player_id if players != null else null
	var hover_cell: Vector2i = RefineryDockLayoutScript.hover_cell_for_anchor(anchor_cell, occupy_rows)
	var result := _dock_placement.try_place_at_hover_cell(hover_cell, scene, owner_player_id)
	if result != BuildingPlacementScript.PlaceResult.PLACED:
		_refund_and_fail(order, "%s could not be placed near the refinery" % order.display_name)
		return

	var dock := _dock_placement.last_placed_building()
	if dock != null:
		refinery.call("register_dock", dock)
	dock_completed.emit(refinery)
	status_changed.emit("%s completed" % order.display_name)
	_refresh_upgrade_option_states()


func _refund_and_fail(order: UpgradeOrder, message: String) -> void:
	var player := _local_player()
	if player != null and order.cost > 0:
		player.add_money(order.cost)
	status_changed.emit(message)
	_refresh_upgrade_option_states()


func _dock_anchor_cell(refinery: Node3D, dock_occupy_rows: Array[String], existing_dock_count: int):
	var refinery_anchor = refinery.get_meta(&"placement_anchor_cell", null)
	if not (refinery_anchor is Vector2i):
		return null

	var refinery_config = refinery.get("building_config") as Resource
	if refinery_config == null:
		refinery_config = _building_config(StringName(String(refinery.get("config_id"))))
	var refinery_rows := _occupy_rows(refinery_config)
	if refinery_rows.is_empty():
		return null

	return RefineryDockLayoutScript.dock_anchor_nav_cell(
		refinery_anchor, refinery_rows, dock_occupy_rows, existing_dock_count
	)


func _dock_building_id_for(refinery: Node3D) -> StringName:
	var refinery_id := String(refinery.get("config_id"))
	# Refinery ids follow the "<house prefix><Name>" convention (ATRefinery,
	# HKRefinery, ORRefinery -- see assets/converted/rules/buildings/); docks
	# are the same prefix + "RefineryDock" (ATRefineryDock, ...).
	return StringName(refinery_id.substr(0, 2) + "RefineryDock")


func _is_refinery(building: Node3D) -> bool:
	var config = building.get("building_config") as Resource
	if config == null:
		config = _building_config(StringName(String(building.get("config_id"))))
	return config != null and config.list(&"roles").has(REFINERY_ROLE)


func _is_refinery_dock_id(building_id: StringName) -> bool:
	var config: Resource = _building_configs.get(building_id)
	return config != null and String(config.field(&"building_group", "")) == "RefineryDock"


## A dock has no player-wide "owned" flag to check availability against --
## unlike GLOBAL_TYPE it can be bought again and again, capped per instance
## by Refinery.can_add_dock() (docs section 4 "up to 2 docks per refinery").
func _any_refinery_can_add_dock() -> bool:
	if not is_inside_tree():
		return false
	var player := _local_player()
	if player == null:
		return false
	for node in get_tree().get_nodes_in_group("buildings"):
		var building := node as Node3D
		if building == null:
			continue
		if int(building.get("owner_player_id")) != player.player_id:
			continue
		if not _is_refinery(building):
			continue
		if building.has_method("can_add_dock") and bool(building.call("can_add_dock")):
			return true
	return false


func _is_upgrade_available(building_id: StringName) -> bool:
	var config: Resource = _building_configs.get(building_id)
	if config == null or float(config.field(&"upgrade_cost", 0)) <= 0.0:
		return false
	var player := _local_player()
	if player == null or player.has_purchased_upgrade(building_id):
		return false
	return _player_owns_building_type(player.player_id, building_id)


func _player_owns_building_type(player_id: int, building_id: StringName) -> bool:
	if not is_inside_tree():
		return false
	for node in get_tree().get_nodes_in_group("buildings"):
		var building := node as Node3D
		if building == null:
			continue
		if int(building.get("owner_player_id")) == player_id and StringName(String(building.get("config_id"))) == building_id:
			return true
	return false


func _load_building_configs(building_ids: Array[StringName]) -> void:
	var rules := get_node_or_null("/root/Rules")
	if rules == null:
		push_warning("Rules autoload is not available; upgrades use no rules")
		return

	for building_id in building_ids:
		var config: Resource = rules.call("building", building_id)
		if config == null:
			continue
		_building_configs[building_id] = config
		if float(config.field(&"upgrade_cost", 0)) > 0.0:
			_upgrade_option_ids.append(building_id)


func _refresh_upgrade_option_states() -> void:
	var order := _upgrade_queue.current_order()
	var player := _local_player()
	for building_id in _upgrade_option_ids:
		var tooltip := _upgrade_tooltip(building_id)

		if _is_refinery_dock_id(building_id):
			_emit_dock_option_state(building_id, order, tooltip)
			continue

		if player != null and player.has_purchased_upgrade(building_id):
			upgrade_option_state_changed.emit(BuildingOptionStateScript.new(
				building_id, BuildingOptionStateScript.State.READY, 100.0, "OWNED", tooltip
			))
			continue

		if order == null or order.kind != UpgradeOrderScript.Kind.GLOBAL_TYPE or order.upgrade_id != building_id:
			var available := _is_upgrade_available(building_id)
			var state := BuildingOptionStateScript.State.DISABLED
			if available:
				state = BuildingOptionStateScript.State.BLOCKED if order != null else BuildingOptionStateScript.State.AVAILABLE
			upgrade_option_state_changed.emit(BuildingOptionStateScript.new(building_id, state, 0.0, "", tooltip))
			continue

		var status_text := "PAUSED" if order.manually_paused else ""
		upgrade_option_state_changed.emit(BuildingOptionStateScript.new(
			building_id, BuildingOptionStateScript.State.PROGRESS, order.progress_percent(), status_text, tooltip
		))


## Refinery docks have neither the GLOBAL_TYPE "purchased once, forever"
## state (docs section 4 "binding": instance-bound, capped per refinery via
## can_add_dock()) nor its plain queue-then-place flow (docks auto-place, no
## manual placement click), so their grid state is derived separately here
## instead of falling through the branches above.
func _emit_dock_option_state(building_id: StringName, order: UpgradeOrder, tooltip: String) -> void:
	if order != null and order.kind == UpgradeOrderScript.Kind.REFINERY_DOCK and order.upgrade_id == building_id:
		var status_text := "PAUSED" if order.manually_paused else ""
		upgrade_option_state_changed.emit(BuildingOptionStateScript.new(
			building_id, BuildingOptionStateScript.State.PROGRESS, order.progress_percent(), status_text, tooltip
		))
		return

	if _dock_mode and _dock_mode_building_id == building_id and order == null:
		upgrade_option_state_changed.emit(BuildingOptionStateScript.new(
			building_id, BuildingOptionStateScript.State.PROGRESS, 0.0, "Select a refinery", tooltip
		))
		return

	var available := _any_refinery_can_add_dock()
	var state := BuildingOptionStateScript.State.DISABLED
	if available:
		state = BuildingOptionStateScript.State.BLOCKED if order != null else BuildingOptionStateScript.State.AVAILABLE
	upgrade_option_state_changed.emit(BuildingOptionStateScript.new(building_id, state, 0.0, "", tooltip))


func _upgrade_display_name(building_id: StringName) -> String:
	return "%s upgrade" % String(building_id)


func _upgrade_tooltip(building_id: StringName) -> String:
	var config: Resource = _building_configs.get(building_id)
	if config == null:
		return _upgrade_display_name(building_id)

	var cost := int(config.field(&"upgrade_cost", 0))
	var build_time_ticks := float(config.field(&"build_time", 0.0))
	var build_seconds := build_time_ticks / UpgradeQueueScript.BUILD_TICKS_PER_SECOND
	return "%s\nCost: %d\nBuild: %.1fs" % [_upgrade_display_name(building_id), cost, build_seconds]


func _occupy_rows_for_existing_building(building: Node3D) -> Array[String]:
	var config = building.get("building_config") as Resource
	if config == null:
		config = _building_config(StringName(String(building.get("config_id"))))
	return _occupy_rows(config)


func _occupy_rows(config: Resource) -> Array[String]:
	var rows: Array[String] = []
	if config == null:
		return rows
	for row in config.list(&"occupy_rows"):
		var row_text := String(row)
		if not row_text.is_empty():
			rows.append(row_text)
	return rows


func _build_radius_tiles() -> int:
	var rules := get_node_or_null("/root/Rules")
	if rules == null or not rules.has_method("general_rules"):
		return DEFAULT_BUILD_RADIUS_TILES
	var general_config: Resource = rules.call("general_rules")
	if general_config == null:
		return DEFAULT_BUILD_RADIUS_TILES
	return int(general_config.field(&"max_building_placement_tile_dist", DEFAULT_BUILD_RADIUS_TILES))


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
	var rules := get_node_or_null("/root/Rules")
	if rules == null or not rules.has_method("get_entity"):
		return ""
	var art_config: Resource = rules.call("get_entity", &"art_config", building_id)
	if art_config == null:
		return ""
	return String(art_config.field(&"xaf", ""))


func _find_building(node: Node) -> Node3D:
	var current := node
	while current != null:
		if current.is_in_group("buildings") and current is Node3D:
			return current as Node3D
		current = current.get_parent()
	return null


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
