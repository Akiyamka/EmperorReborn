class_name UnitCommandController
extends Node

signal status_changed(status: String)

const PlayerDataScript := preload("res://scripts/players/player_data.gd")
const UnitNavigationSystemScript := preload("res://scripts/units/navigation/unit_navigation_system.gd")

var _camera: Camera3D
var _terrain: MapLoader
var _selection_rectangle = null
var _navigation
# Units and buildings are protocol-compatible group members in runtime and
# tests, not one concrete class. Both expose ownership and selection methods.
var _selected_entities: Array[Node] = []
var _hovered_entity = null
var _drag_start: Vector2 = Vector2.INF
var _formation_modifier_down := false

const DRAG_SELECTION_THRESHOLD := 8.0


func setup(command_camera: Camera3D, command_terrain: MapLoader, navigation = null, selection_rectangle = null) -> void:
	_camera = command_camera
	_terrain = command_terrain
	_navigation = navigation
	_selection_rectangle = selection_rectangle


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
			selected.append(entity)
	_set_selection(selected)
	status_changed.emit("")


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
	for entity in _selected_entities:
		if not _can_control(entity):
			status_changed.emit("Cannot command this player")
			return
		if entity.has_method("move_to"):
			movable_entities.append(entity)
		elif entity.has_method("set_rally_point"):
			rally_buildings.append(entity)
	if movable_entities.is_empty() and rally_buildings.is_empty():
		return

	var hit := _raycast(screen_position, 1)
	if hit.is_empty():
		return

	var target: Vector3 = hit["position"]
	if movable_entities.is_empty():
		for building in rally_buildings:
			building.call("set_rally_point", target)
		var rally_label := "Rally point set to %.1f, %.1f" % [target.x, target.z]
		if rally_buildings.size() > 1:
			rally_label = "Rally point set for %d buildings" % rally_buildings.size()
		status_changed.emit(rally_label)
		return

	var move_mode := (
		UnitNavigationSystemScript.MoveMode.FORMATION
		if _formation_modifier_down
		else UnitNavigationSystemScript.MoveMode.FREE
	)
	if _navigation != null:
		_navigation.command_move(movable_entities, target, move_mode)
	else:
		for entity in movable_entities:
			entity.move_to(target)
	var nav_status := ""
	if _terrain != null and _terrain.navigation_grid != null and _terrain.navigation_grid.is_loaded():
		var cell: Vector2i = _terrain.navigation_grid.world_to_grid(target)
		var debug: Dictionary = _terrain.navigation_grid.cell_debug(cell)
		nav_status = " | nav %s tile %s terrain %s" % [
			str(cell),
			str(debug.get("source_tile", "?")),
			str(debug.get("terrain_name", "?")),
		]
	var movement_label := "Moving to %.1f, %.1f" % [target.x, target.z]
	if movable_entities.size() > 1:
		movement_label = "Moving %d units to %.1f, %.1f" % [movable_entities.size(), target.x, target.z]
	var formation_status := " | formation" if move_mode == UnitNavigationSystemScript.MoveMode.FORMATION else ""
	status_changed.emit("%s%s%s" % [movement_label, nav_status, formation_status])


func _is_formation_modifier(event: InputEventKey) -> bool:
	return event.keycode == KEY_J or event.physical_keycode == KEY_J


func _clear_selection() -> void:
	for entity in _selected_entities:
		if is_instance_valid(entity):
			entity.set_selected(false)
	_selected_entities.clear()


func _set_selection(entities: Array[Node]) -> void:
	_clear_selection()
	for entity in entities:
		if entity == null or not is_instance_valid(entity):
			continue
		_selected_entities.append(entity)
		entity.set_selected(true)


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
