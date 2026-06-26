extends Node3D

@onready var camera: Camera3D = $CameraRig/Camera3D
@onready var selection_label: Label = $HUD/Selection

var selected_unit = null


func _ready() -> void:
	_update_selection_label()


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
	_update_selection_label("Moving to %.1f, %.1f" % [target.x, target.z])


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
