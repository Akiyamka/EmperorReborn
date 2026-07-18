class_name UnitCommandController
extends Node

signal status_changed(status: String)

const PlayerDataScript := preload("res://scripts/players/player_data.gd")
const UnitNavigationSystemScript := preload("res://scripts/units/navigation/unit_navigation_system.gd")

var _camera: Camera3D
var _terrain: MapLoader
var _selection_rectangle = null
var _navigation
var _deployment_controller
# Units and buildings are protocol-compatible group members in runtime and
# tests, not one concrete class. Both expose ownership and selection methods.
var _selected_entities: Array[Node] = []
var _hovered_entity = null
var _drag_start: Vector2 = Vector2.INF
var _formation_modifier_down := false

const DRAG_SELECTION_THRESHOLD := 8.0
const TERRAIN_COLLISION_MASK := 1
const ENTITY_SELECTION_COLLISION_MASK := 2


func setup(
		command_camera: Camera3D,
		command_terrain: MapLoader,
		navigation = null,
		selection_rectangle = null,
		deployment_controller = null
	) -> void:
	_camera = command_camera
	_terrain = command_terrain
	_navigation = navigation
	_selection_rectangle = selection_rectangle
	_deployment_controller = deployment_controller


func handle_unhandled_input(event: InputEvent) -> bool:
	if event is InputEventKey and _is_formation_modifier(event):
		_formation_modifier_down = event.pressed
		return false
	if event is InputEventMouseMotion:
		if _is_dragging():
			_update_drag_selection(event.position)
			return true
		_update_hover(event.position)
		return false
	if not event is InputEventMouseButton:
		return false
	match event.button_index:
		MOUSE_BUTTON_LEFT:
			if event.pressed:
				_begin_drag_selection(event.position)
			else:
				_finish_drag_selection(event.position)
			return true
		MOUSE_BUTTON_RIGHT:
			if event.pressed:
				_command_move(event.position)
				return true
	return false


func selection_text(status := "") -> String:
	if _selected_entities.is_empty():
		return status if not status.is_empty() else "No entity selected"

	var text := ""
	if _selected_entities.size() == 1:
		var entity: Node = _selected_entities.front()
		text = "%s selected | %s" % [entity.name, _owner_status(entity)]
	else:
		text = "%d units selected" % _selected_entities.size()
	if not status.is_empty():
		text += " | %s" % status
	return text


func _begin_drag_selection(screen_position: Vector2) -> void:
	_drag_start = screen_position
	# Keep click selection responsive and preserve the established press-based
	# input behaviour. A real drag replaces this temporary selection on release.
	_select_at(screen_position)


func _update_drag_selection(screen_position: Vector2) -> void:
	if _selection_rectangle != null:
		_selection_rectangle.show_between(_drag_start, screen_position)


func _finish_drag_selection(screen_position: Vector2) -> void:
	if not _is_dragging():
		return
	var drag_distance := _drag_start.distance_to(screen_position)
	if _selection_rectangle != null:
		_selection_rectangle.clear()
	if drag_distance >= DRAG_SELECTION_THRESHOLD:
		_select_units_in_rectangle(Rect2(_drag_start, screen_position - _drag_start).abs())
	_drag_start = Vector2.INF


func _is_dragging() -> bool:
	return _drag_start != Vector2.INF


func _select_at(screen_position: Vector2) -> void:
	var selected: Array[Node] = []

	var hit := _raycast(screen_position)
	if not hit.is_empty():
		var entity = _find_selectable_entity(hit.get("collider") as Node)
		if entity != null and _can_control(entity):
			if _is_repeated_single_selection(entity) and _try_deploy(entity):
				return
			selected.append(entity)
	_set_selection(selected)
	status_changed.emit("")


func _is_repeated_single_selection(entity: Node) -> bool:
	return _selected_entities.size() == 1 and _selected_entities.front() == entity


func _try_deploy(entity: Node) -> bool:
	if _deployment_controller == null or not entity.is_in_group("units"):
		return false
	var result: Dictionary = _deployment_controller.call("try_deploy", entity)
	if not bool(result.get("handled", false)):
		return false
	status_changed.emit(String(result.get("message", "")))
	return true


func _select_units_in_rectangle(rectangle: Rect2) -> void:
	var selected: Array[Node] = []
	for unit in get_tree().get_nodes_in_group("units"):
		if not _can_control(unit):
			continue
		var screen_position = _screen_position_for_entity(unit)
		if screen_position is Vector2 and rectangle.has_point(screen_position):
			selected.append(unit)
	_set_selection(selected)
	status_changed.emit("")


func _command_move(screen_position: Vector2) -> void:
	if _selected_entities.is_empty():
		return

	var movable_entities: Array[Node] = []
	var rally_buildings: Array[Node] = []
	var deploying_entities := 0
	for entity in _selected_entities:
		if not _can_control(entity):
			status_changed.emit("Cannot command this player")
			return
		if entity.has_method("is_deploying") and bool(entity.call("is_deploying")):
			deploying_entities += 1
			continue
		if entity.has_method("move_to"):
			movable_entities.append(entity)
		elif entity.has_method("set_rally_point"):
			rally_buildings.append(entity)
	if movable_entities.is_empty() and rally_buildings.is_empty():
		if deploying_entities > 0:
			status_changed.emit("MCV cannot move while deploying")
		return

	# Buildings and units expose their selectable collision on layer 2, while
	# movement positions come from terrain layer 1. Keep the queries separate:
	# otherwise a refinery click resolves only to the ground below it and loses
	# the entity required by the dedicated unload command.
	var target_entity = null
	for entity in movable_entities:
		if not entity.has_method("can_unload_at"):
			continue
		var entity_hit := _raycast(screen_position, ENTITY_SELECTION_COLLISION_MASK)
		if not entity_hit.is_empty():
			target_entity = _find_selectable_entity(entity_hit.get("collider") as Node)
		break

	var hit := _raycast(screen_position, TERRAIN_COLLISION_MASK)
	if hit.is_empty():
		return

	var target: Vector3 = hit["position"]
	var move_mode := (
		UnitNavigationSystemScript.MoveMode.FORMATION
		if _formation_modifier_down
		else UnitNavigationSystemScript.MoveMode.FREE
	)
	var ordinary_rally_buildings: Array[Node] = []
	var undeployment_messages: Array[String] = []
	for building in rally_buildings:
		var undeployment := _request_undeployment(building, target, move_mode)
		if undeployment.is_empty():
			ordinary_rally_buildings.append(building)
			continue
		undeployment_messages.append(String(undeployment.get("message", "")))
	rally_buildings = ordinary_rally_buildings
	if movable_entities.is_empty():
		for building in rally_buildings:
			building.call("set_rally_point", target)
		var labels: Array[String] = []
		if not rally_buildings.is_empty():
			var rally_label := "Rally point set to %.1f, %.1f" % [target.x, target.z]
			if rally_buildings.size() > 1:
				rally_label = "Rally point set for %d buildings" % rally_buildings.size()
			labels.append(rally_label)
		labels.append_array(undeployment_messages)
		if not labels.is_empty():
			status_changed.emit(" | ".join(labels))
		return

	var target_cell := Vector2i(-1, -1)
	var spice_target := false
	if _terrain != null and _terrain.navigation_grid != null and _terrain.navigation_grid.is_loaded():
		target_cell = _terrain.navigation_grid.world_to_grid(target)
		spice_target = _terrain.spice_layer != null and bool(_terrain.spice_layer.call("has_spice", target_cell))

	var harvesting_entities: Array[Node] = []
	var unloading_entities: Array[Node] = []
	var moving_entities: Array[Node] = []
	for entity in movable_entities:
		var can_unload := target_entity != null \
			and entity.has_method("can_unload_at") \
			and bool(entity.call("can_unload_at", target_entity)) \
			and entity.has_method("command_unload")
		if can_unload and _terrain != null and _terrain.navigation_grid != null \
		and bool(entity.call(
			"command_unload", target_entity, _terrain.navigation_grid, _terrain.spice_layer
		)):
			unloading_entities.append(entity)
			continue
		var can_harvest := entity.has_method("can_harvest_spice") \
			and bool(entity.call("can_harvest_spice")) \
			and entity.has_method("command_harvest")
		if spice_target and can_harvest \
		and bool(entity.call("command_harvest", _terrain.spice_layer, _terrain.navigation_grid, target_cell)):
			harvesting_entities.append(entity)
			continue
		moving_entities.append(entity)

	if not moving_entities.is_empty():
		if _navigation != null:
			_navigation.command_move(moving_entities, target, move_mode)
		else:
			for entity in moving_entities:
				entity.move_to(target)
	var nav_status := ""
	if target_cell.x >= 0:
		var debug: Dictionary = _terrain.navigation_grid.cell_debug(target_cell)
		nav_status = " | nav %s tile %s terrain %s" % [
			str(target_cell),
			str(debug.get("source_tile", "?")),
			str(debug.get("terrain_name", "?")),
		]
	var movement_label := ""
	if not unloading_entities.is_empty():
		movement_label = "Unloading at %s" % String(target_entity.name)
		if unloading_entities.size() > 1:
			movement_label = "Unloading %d harvesters at %s" % [
				unloading_entities.size(), String(target_entity.name)
			]
		if not moving_entities.is_empty():
			movement_label += " | moving %d other units" % moving_entities.size()
	elif not harvesting_entities.is_empty():
		movement_label = "Harvesting spice at %.1f, %.1f" % [target.x, target.z]
		if harvesting_entities.size() > 1:
			movement_label = "Harvesting spice with %d units at %.1f, %.1f" % [harvesting_entities.size(), target.x, target.z]
		if not moving_entities.is_empty():
			movement_label += " | moving %d other units" % moving_entities.size()
	else:
		movement_label = "Moving to %.1f, %.1f" % [target.x, target.z]
		if moving_entities.size() > 1:
			movement_label = "Moving %d units to %.1f, %.1f" % [moving_entities.size(), target.x, target.z]
	var formation_status := " | formation" \
		if not moving_entities.is_empty() and move_mode == UnitNavigationSystemScript.MoveMode.FORMATION else ""
	var deployment_status := " | %d unit(s) deploying" % deploying_entities \
		if deploying_entities > 0 else ""
	var undeployment_status := " | %s" % " | ".join(undeployment_messages) \
		if not undeployment_messages.is_empty() else ""
	status_changed.emit("%s%s%s%s%s" % [
		movement_label, nav_status, formation_status, deployment_status, undeployment_status
	])


func _request_undeployment(entity: Node, target: Vector3, move_mode: int) -> Dictionary:
	if _deployment_controller == null or not entity.is_in_group("buildings") \
	or not _deployment_controller.has_method("try_undeploy"):
		return {}
	var result: Dictionary = _deployment_controller.call(
		"try_undeploy", entity, target, move_mode
	)
	return result if bool(result.get("handled", false)) else {}


func _is_formation_modifier(event: InputEventKey) -> bool:
	return event.keycode == KEY_J or event.physical_keycode == KEY_J


func _clear_selection() -> void:
	for entity in _selected_entities:
		if is_instance_valid(entity):
			var callback := Callable(self, "_on_selected_entity_exiting").bind(entity)
			if entity.tree_exiting.is_connected(callback):
				entity.tree_exiting.disconnect(callback)
			entity.set_selected(false)
	_selected_entities.clear()


func _set_selection(entities: Array[Node]) -> void:
	_clear_selection()
	for entity in entities:
		if entity == null or not is_instance_valid(entity):
			continue
		_selected_entities.append(entity)
		entity.set_selected(true)
		var callback := Callable(self, "_on_selected_entity_exiting").bind(entity)
		if not entity.tree_exiting.is_connected(callback):
			entity.tree_exiting.connect(callback, CONNECT_ONE_SHOT)


func _on_selected_entity_exiting(entity: Node) -> void:
	_selected_entities.erase(entity)
	status_changed.emit("")


func _update_hover(screen_position: Vector2) -> void:
	var hovered = null
	var hit := _raycast(screen_position)
	if not hit.is_empty():
		hovered = _find_selectable_entity(hit.get("collider") as Node)
	if hovered == _hovered_entity:
		return
	if _hovered_entity != null and _hovered_entity.has_method("set_hovered"):
		_hovered_entity.set_hovered(false)
	_hovered_entity = hovered
	if _hovered_entity != null and _hovered_entity.has_method("set_hovered"):
		_hovered_entity.set_hovered(true)


func _find_selectable_entity(node: Node):
	var current := node
	while current != null:
		if current.is_in_group("units") or current.is_in_group("buildings"):
			return current
		current = current.get_parent()
	return null


func _screen_position_for_entity(entity):
	if _camera == null or not entity is Node3D:
		return null
	if _camera.is_position_behind(entity.global_position):
		return null
	return _camera.unproject_position(entity.global_position)


func _raycast(screen_position: Vector2, collision_mask: int = 0xffffffff) -> Dictionary:
	if _camera == null:
		return {}

	var ray_origin := _camera.project_ray_origin(screen_position)
	var ray_end := ray_origin + _camera.project_ray_normal(screen_position) * 1000.0
	var query := PhysicsRayQueryParameters3D.create(ray_origin, ray_end)
	query.collision_mask = collision_mask
	query.collide_with_areas = false
	return get_viewport().get_world_3d().direct_space_state.intersect_ray(query)


func _can_control(unit) -> bool:
	var players = _players()
	return players != null and unit.is_owned_by(players.local_player_id)


func _owner_status(unit) -> String:
	var unit_owner = unit.owner_player()
	if unit_owner == null:
		return "owner: missing"
	if unit_owner.is_neutral:
		return "owner: neutral"

	var players = _players()
	var relation := "unknown"
	if players != null:
		match players.relation_between(players.local_player_id, unit_owner.player_id):
			PlayerDataScript.Relation.ALLY:
				relation = "ally"
			PlayerDataScript.Relation.ENEMY:
				relation = "enemy"
			_:
				relation = "neutral"

	var faction := String(unit_owner.house_id)
	if unit_owner.has_subhouses():
		var subhouses := []
		for subhouse_id in unit_owner.subhouse_ids:
			subhouses.append(String(subhouse_id))
		faction += "/%s" % ", ".join(subhouses)
	return "owner: %s (%s, %s)" % [unit_owner.nickname, faction, relation]


func _players():
	if not is_inside_tree():
		return null
	return get_node_or_null("/root/Players")
