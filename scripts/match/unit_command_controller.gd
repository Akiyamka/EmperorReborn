class_name UnitCommandController
extends Node

signal status_changed(status: String)

const PlayerDataScript := preload("res://scripts/players/player_data.gd")

var _camera: Camera3D
var _terrain: MapLoader
var _selected_unit = null


func setup(command_camera: Camera3D, command_terrain: MapLoader) -> void:
	_camera = command_camera
	_terrain = command_terrain


func handle_unhandled_input(event: InputEvent) -> bool:
	if not (event is InputEventMouseButton and event.pressed):
		return false
	match event.button_index:
		MOUSE_BUTTON_LEFT:
			_select_at(event.position)
			return true
		MOUSE_BUTTON_RIGHT:
			_command_move(event.position)
			return true
	return false


func selection_text(status := "") -> String:
	if _selected_unit == null:
		return status if not status.is_empty() else "No unit selected"

	var text := "%s selected | %s" % [_selected_unit.name, _owner_status(_selected_unit)]
	if not status.is_empty():
		text += " | %s" % status
	return text


func _select_at(screen_position: Vector2) -> void:
	_clear_selection()

	var hit := _raycast(screen_position)
	if not hit.is_empty():
		var unit = _find_unit(hit.get("collider") as Node)
		if unit != null:
			_selected_unit = unit
			_selected_unit.set_selected(true)
	status_changed.emit("")


func _command_move(screen_position: Vector2) -> void:
	if _selected_unit == null:
		return

	if not _can_control(_selected_unit):
		status_changed.emit("Cannot command this player")
		return

	var hit := _raycast(screen_position, 1)
	if hit.is_empty():
		return

	var target: Vector3 = hit["position"]
	_selected_unit.move_to(target)
	var nav_status := ""
	if _terrain != null and _terrain.navigation_grid != null and _terrain.navigation_grid.is_loaded():
		var cell: Vector2i = _terrain.navigation_grid.world_to_grid(target)
		var debug: Dictionary = _terrain.navigation_grid.cell_debug(cell)
		nav_status = " | nav %s tile %s terrain %s" % [
			str(cell),
			str(debug.get("source_tile", "?")),
			str(debug.get("terrain_name", "?")),
		]
	status_changed.emit("Moving to %.1f, %.1f%s" % [target.x, target.z, nav_status])


func _clear_selection() -> void:
	if _selected_unit != null:
		_selected_unit.set_selected(false)
		_selected_unit = null


func _find_unit(node: Node):
	var current := node
	while current != null:
		if current.is_in_group("units"):
			return current
		current = current.get_parent()
	return null


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
