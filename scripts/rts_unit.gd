extends CharacterBody3D
class_name RTSUnit

signal owner_changed(player_id: int)

const PlayerDataScript := preload("res://scripts/players/player_data.gd")

@export var config_id: StringName
@export var owner_player_id := PlayerDataScript.NEUTRAL_PLAYER_ID:
	set(value):
		if owner_player_id == value:
			return
		owner_player_id = value
		if is_inside_tree():
			_refresh_owner_visuals()
		owner_changed.emit(owner_player_id)
@export var move_speed := 5.0
@export var arrival_radius := 0.2
@export var selection_color := Color(0.2, 0.85, 1.0)
@export var visual_root_path := NodePath("VisualRoot")
@export var max_health := 0.0
@export var max_shields := 0.0

@onready var visual_root: Node3D = get_node_or_null(visual_root_path)

var unit_config: Resource
var target_position: Vector3
var is_selected := false
var health := 0.0:
	set(value):
		health = clampf(value, 0.0, max_health)
var shields := 0.0:
	set(value):
		shields = clampf(value, 0.0, max_shields)
		_refresh_shield_visibility()
var _base_materials := {}
var _selection_material: StandardMaterial3D
var _shield_meshes: Array[MeshInstance3D] = []
var _shield_time := 0.0
var _scroll_fx_meshes: Array[MeshInstance3D] = []
var _scroll_fx_time := 0.0


func _ready() -> void:
	_apply_rules_config()
	target_position = global_position
	_capture_base_materials()
	_shield_meshes = _collect_shield_meshes()
	_scroll_fx_meshes = _collect_scroll_fx_meshes()
	health = max_health
	shields = max_shields
	_selection_material = StandardMaterial3D.new()
	_selection_material.roughness = 0.8
	_refresh_owner_visuals()


func _process(delta: float) -> void:
	# These shaders take their scroll/pulse phase from here: a continuous
	# phase cannot come from animation tracks (it would snap on clip loops),
	# and TIME in the shader would keep the editor viewport redrawing.
	if shields > 0.0 and not _shield_meshes.is_empty():
		_shield_time += delta
		for mesh_instance in _shield_meshes:
			mesh_instance.set_instance_shader_parameter("fx_time", _shield_time)
	if not _scroll_fx_meshes.is_empty():
		_scroll_fx_time += delta
		for mesh_instance in _scroll_fx_meshes:
			mesh_instance.set_instance_shader_parameter("fx_time", _scroll_fx_time)


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


func setup(unit_id: StringName) -> void:
	config_id = unit_id
	if not is_inside_tree():
		return

	_apply_rules_config()
	health = max_health
	shields = max_shields


func stop_at_current_position() -> void:
	target_position = global_position
	velocity = Vector3.ZERO


func set_selected(value: bool) -> void:
	if is_selected == value:
		return

	is_selected = value
	_refresh_selection()


func set_owner_player_id(player_id: int) -> void:
	owner_player_id = player_id


func owner_player():
	var players = _players()
	if players == null:
		return null
	return players.player(owner_player_id)


func is_neutral_owner() -> bool:
	return owner_player_id == PlayerDataScript.NEUTRAL_PLAYER_ID


func is_owned_by(player_id: int) -> bool:
	return owner_player_id == player_id


func is_allied_with(player_id: int) -> bool:
	var players = _players()
	return players != null and players.are_allied(owner_player_id, player_id)


func is_enemy_of(player_id: int) -> bool:
	var players = _players()
	return players != null and players.are_enemies(owner_player_id, player_id)


func _refresh_shield_visibility() -> void:
	for mesh_instance in _shield_meshes:
		mesh_instance.visible = shields > 0.0


func _apply_rules_config() -> void:
	if String(config_id).is_empty():
		return

	var rules := get_node_or_null("/root/Rules")
	if rules == null:
		push_warning("Rules autoload is not available; using scene defaults for %s" % name)
		return

	unit_config = rules.call("unit", config_id)
	if unit_config == null:
		push_warning("Unit rules config not found: %s" % String(config_id))
		return

	move_speed = float(unit_config.field(&"speed", move_speed))
	max_health = float(unit_config.field(&"health", max_health))
	max_shields = float(unit_config.field(&"shield_health", 0.0))


func _collect_shield_meshes() -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	for mesh_instance in _mesh_instances():
		if String(mesh_instance.get_parent().name).to_lower().contains("shield"):
			result.append(mesh_instance)
	return result


func _collect_scroll_fx_meshes() -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	for mesh_instance in _mesh_instances():
		if mesh_instance.has_meta("scroll_fx"):
			result.append(mesh_instance)
	return result


func _refresh_selection() -> void:
	if visual_root == null:
		return

	for mesh_instance in _mesh_instances():
		mesh_instance.material_override = _selection_material if is_selected else _base_materials.get(mesh_instance)


func _refresh_owner_visuals() -> void:
	var color := _owner_team_color()
	if _selection_material != null:
		_selection_material.albedo_color = color
		_selection_material.emission_enabled = true
		_selection_material.emission = color
		_selection_material.emission_energy_multiplier = 0.4

	for mesh_instance in _mesh_instances():
		mesh_instance.set_instance_shader_parameter("team_color", color)

	_refresh_selection()


func _owner_team_color() -> Color:
	var roster_player = owner_player()
	if roster_player == null or roster_player.is_neutral:
		return selection_color
	return roster_player.team_color


func _players():
	if not is_inside_tree():
		return null
	return get_node_or_null("/root/Players")


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
