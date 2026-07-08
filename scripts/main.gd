extends Node3D

@onready var camera: Camera3D = $CameraRig/Camera3D
@onready var camera_rig: Node3D = $CameraRig
@onready var terrain: MapLoader = $Terrain
@onready var selection_label: Label = $HUD/Selection
@onready var fps_label: Label = $HUD/FPS

var selected_unit = null
var _fps_update_time := 0.0


func _ready() -> void:
	_update_selection_label()
	_update_fps_label()
	_place_on_map()


func _place_on_map() -> void:
	var center := terrain.map_center()
	camera_rig.set_map_view(center, terrain.map_bounds())

	# Terrain collision is not queryable until the first physics frame.
	await get_tree().physics_frame
	await get_tree().physics_frame
	for building in get_tree().get_nodes_in_group("rts_buildings"):
		if building is Node3D:
			var spot: Vector3 = building.global_position
			building.global_position = _snap_to_ground(spot)

	for unit in get_tree().get_nodes_in_group("rts_units"):
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
	_fps_update_time += delta
	if _fps_update_time >= 0.25:
		_fps_update_time = 0.0
		_update_fps_label()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				_select_at(event.position)
				get_viewport().set_input_as_handled()
			MOUSE_BUTTON_RIGHT:
				_command_move(event.position)
				get_viewport().set_input_as_handled()


func _select_at(screen_position: Vector2) -> void:
	_clear_selection()

	var hit := _raycast(screen_position)
	if hit.is_empty():
		_update_selection_label()
		return

	var unit = _find_unit(hit.get("collider") as Node)
	if unit == null:
		_update_selection_label()
		return

	selected_unit = unit
	selected_unit.set_selected(true)
	_update_selection_label()


func _command_move(screen_position: Vector2) -> void:
	if selected_unit == null:
		return

	var hit := _raycast(screen_position, 1)
	if hit.is_empty():
		return

	var target: Vector3 = hit["position"]
	selected_unit.move_to(target)
	var nav_status := ""
	if terrain.navigation_grid != null and terrain.navigation_grid.is_loaded():
		var cell: Vector2i = terrain.navigation_grid.world_to_grid(target)
		var debug: Dictionary = terrain.navigation_grid.cell_debug(cell)
		nav_status = " | nav %s tile %s terrain %s" % [
			str(cell),
			str(debug.get("source_tile", "?")),
			str(debug.get("terrain_name", "?")),
		]
	_update_selection_label("Moving to %.1f, %.1f%s" % [target.x, target.z, nav_status])


func _clear_selection() -> void:
	if selected_unit != null:
		selected_unit.set_selected(false)
		selected_unit = null


func _find_unit(node: Node):
	var current := node
	while current != null:
		if current.is_in_group("rts_units"):
			return current
		current = current.get_parent()
	return null


func _raycast(screen_position: Vector2, collision_mask: int = 0xffffffff) -> Dictionary:
	var ray_origin := camera.project_ray_origin(screen_position)
	var ray_end := ray_origin + camera.project_ray_normal(screen_position) * 1000.0
	var query := PhysicsRayQueryParameters3D.create(ray_origin, ray_end)
	query.collision_mask = collision_mask
	query.collide_with_areas = false
	return get_world_3d().direct_space_state.intersect_ray(query)


func _update_selection_label(status := "") -> void:
	if selected_unit == null:
		selection_label.text = "No unit selected"
		return

	selection_label.text = "%s selected" % selected_unit.name
	if not status.is_empty():
		selection_label.text += " | %s" % status


func _update_fps_label() -> void:
	fps_label.text = "FPS: %d" % Engine.get_frames_per_second()
