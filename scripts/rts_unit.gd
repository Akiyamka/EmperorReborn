extends CharacterBody3D
class_name RTSUnit

@export var move_speed := 5.0
@export var arrival_radius := 0.2
@export var selection_color := Color(0.2, 0.85, 1.0)
@export var visual_root_path := NodePath("VisualRoot")

@onready var visual_root: Node3D = get_node_or_null(visual_root_path)

var target_position: Vector3
var is_selected := false
var _base_materials := {}
var _selection_material: StandardMaterial3D


func _ready() -> void:
	target_position = global_position
	_capture_base_materials()
	_selection_material = StandardMaterial3D.new()
	_selection_material.albedo_color = selection_color
	_selection_material.emission_enabled = true
	_selection_material.emission = selection_color
	_selection_material.emission_energy_multiplier = 0.4
	_selection_material.roughness = 0.8
	_refresh_selection()


func _physics_process(_delta: float) -> void:
	var offset := target_position - global_position
	offset.y = 0.0

	if offset.length() <= arrival_radius:
		velocity = Vector3.ZERO
	else:
		velocity = offset.normalized() * move_speed
		look_at(global_position + velocity, Vector3.UP)

	move_and_slide()


func move_to(world_position: Vector3) -> void:
	target_position = Vector3(world_position.x, global_position.y, world_position.z)


func set_selected(value: bool) -> void:
	if is_selected == value:
		return

	is_selected = value
	_refresh_selection()


func _refresh_selection() -> void:
	if visual_root == null:
		return

	for mesh_instance in _mesh_instances():
		mesh_instance.material_override = _selection_material if is_selected else _base_materials.get(mesh_instance)


func _capture_base_materials() -> void:
	_base_materials.clear()
	for mesh_instance in _mesh_instances():
		_base_materials[mesh_instance] = mesh_instance.material_override


func _mesh_instances() -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	if visual_root == null:
		return result
	_collect_mesh_instances(visual_root, result)
	return result


func _collect_mesh_instances(node: Node, result: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		result.append(node)
	for child in node.get_children():
		_collect_mesh_instances(child, result)
