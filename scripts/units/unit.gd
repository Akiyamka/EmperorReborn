extends CharacterBody3D
class_name Unit

signal owner_changed(player_id: int)

const PlayerDataScript := preload("res://scripts/players/player_data.gd")
const SelectionHaloScript := preload("res://scripts/ui/selection_halo.gd")

const COLLISION_OBJECT_NAME := "#~~0"
const TERRAIN_COLLISION_MASK := 1
const TERRAIN_RAY_HEIGHT := 200.0
const MIN_SLOPE_SPEED_MULTIPLIER := 0.65
const MAX_SLOPE_SPEED_MULTIPLIER := 1.50
const SLOPE_PROBE_DISTANCE := 0.5

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
@export var visual_root_path := NodePath("VisualRoot")
@export var max_health := 0.0
@export var max_shields := 0.0
@export var max_spice := 0.0
@export var max_passengers := 0.0

@onready var visual_root: Node3D = get_node_or_null(visual_root_path)

var unit_config: Resource
var target_position: Vector3
var is_selected := false
var is_hovered := false
var invulnerable := false
var health := 0.0:
	set(value):
		health = clampf(value, 0.0, max_health)
var shields := 0.0:
	set(value):
		shields = clampf(value, 0.0, max_shields)
		_refresh_shield_visibility()
var spice := 0.0
var passengers := 0.0
var _shield_meshes: Array[MeshInstance3D] = []
var _shield_time := 0.0
var _scroll_fx_meshes: Array[MeshInstance3D] = []
var _scroll_fx_time := 0.0
var _selection_halo


func _ready() -> void:
	_apply_rules_config()
	target_position = global_position
	# Terrain height is sampled explicitly below. Letting CharacterBody collide
	# with the terrain mesh makes each triangle edge behave like a small wall,
	# which prevents units from climbing otherwise traversable slopes. The
	# collision layer remains enabled, so mouse rays can still select this unit.
	collision_mask = 0
	_add_authored_collision()
	_shield_meshes = _collect_shield_meshes()
	_scroll_fx_meshes = _collect_scroll_fx_meshes()
	health = max_health
	shields = max_shields
	_add_selection_halo()
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


func _physics_process(delta: float) -> void:
	var offset := target_position - global_position
	offset.y = 0.0

	if offset.length() <= arrival_radius:
		velocity = Vector3.ZERO
	else:
		var direction := offset.normalized()
		velocity = direction * move_speed * _slope_speed_multiplier(direction, delta)
		look_at(global_position + velocity, Vector3.UP)

	move_and_slide()
	_snap_to_terrain()


func move_to(world_position: Vector3) -> void:
	target_position = Vector3(world_position.x, global_position.y, world_position.z)


func _snap_to_terrain() -> void:
	# Units are moved horizontally, then projected back onto the terrain mesh.
	# Keeping this independent of CharacterBody's floor state lets authored unit
	# collision volumes remain usable for selection while the unit follows every
	# height change in the map instead of retaining its spawn elevation.
	var hit := _terrain_hit_at(global_position)
	if hit.is_empty():
		return

	global_position.y = (hit["position"] as Vector3).y


func _slope_speed_multiplier(direction: Vector3, delta: float) -> float:
	var current_hit := _terrain_hit_at(global_position)
	if current_hit.is_empty():
		return 1.0

	var probe_distance := maxf(move_speed * delta, SLOPE_PROBE_DISTANCE)
	var ahead := global_position + direction * probe_distance
	var ahead_hit := _terrain_hit_at(ahead)
	if ahead_hit.is_empty():
		return 1.0

	var current_position: Vector3 = current_hit["position"]
	var ahead_position: Vector3 = ahead_hit["position"]
	var slope := (ahead_position.y - current_position.y) / probe_distance
	if slope > 0.0:
		return maxf(1.0 - slope * 0.65, MIN_SLOPE_SPEED_MULTIPLIER)
	return minf(1.0 - slope * 0.75, MAX_SLOPE_SPEED_MULTIPLIER)


func _terrain_hit_at(position: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(
		position + Vector3.UP * TERRAIN_RAY_HEIGHT,
		position - Vector3.UP * TERRAIN_RAY_HEIGHT,
		TERRAIN_COLLISION_MASK
	)
	query.exclude = [get_rid()]
	return get_world_3d().direct_space_state.intersect_ray(query)


func setup(unit_id: StringName) -> void:
	config_id = unit_id
	if not is_inside_tree():
		return

	_apply_rules_config()
	health = max_health
	shields = max_shields


func set_invulnerable(value: bool) -> void:
	invulnerable = value


func grant_temporary_invulnerability(duration: float) -> void:
	# Mirrors Building.set_invulnerable/take_damage; used e.g. by
	# BuildingSurvivors for the 1s post-spawn splash immunity from §2.1.
	invulnerable = true
	get_tree().create_timer(duration).timeout.connect(_clear_invulnerability)


func take_damage(amount: float) -> void:
	if invulnerable or amount <= 0.0 or health <= 0.0:
		return

	health -= amount
	if health <= 0.0:
		queue_free()


func stop_at_current_position() -> void:
	target_position = global_position
	velocity = Vector3.ZERO


func set_selected(value: bool) -> void:
	if is_selected == value:
		return

	is_selected = value
	if _selection_halo != null:
		_selection_halo.set_selected(value)


func set_hovered(value: bool) -> void:
	if is_hovered == value:
		return
	is_hovered = value
	if _selection_halo != null:
		_selection_halo.set_hovered(value)


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


func _refresh_owner_visuals() -> void:
	var color := _owner_team_color()
	for mesh_instance in _mesh_instances():
		mesh_instance.set_instance_shader_parameter("team_color", color)


func _owner_team_color() -> Color:
	var roster_player = owner_player()
	if roster_player == null or roster_player.is_neutral:
		return Color(0.2, 0.85, 1.0)
	return roster_player.team_color


func _players():
	if not is_inside_tree():
		return null
	return get_node_or_null("/root/Players")


func _clear_invulnerability() -> void:
	invulnerable = false


func _add_authored_collision() -> void:
	for source in _collision_sources():
		var shape := _collision_shape(source)
		if shape == null:
			push_warning("Unit: collision mesh %s has no usable convex shape" % source.get_path())
			continue

		var collision := CollisionShape3D.new()
		collision.name = "AuthoredCollision"
		collision.shape = shape
		add_child(collision)
		# The source mesh is nested beneath VisualRoot and model-space nodes;
		# copying its global transform preserves its authored position and scale.
		collision.global_transform = source.global_transform


func _collision_sources() -> Array[Node3D]:
	var result: Array[Node3D] = []
	_collect_collision_sources(visual_root, COLLISION_OBJECT_NAME, result)
	if result.is_empty():
		_collect_collision_sources(visual_root, "slct", result, true)
	return result


func _collect_collision_sources(node: Node, original_name: String, result: Array[Node3D], prefix_match := false) -> void:
	if node is Node3D and _is_collision_source(node, original_name, prefix_match):
		_hide_collision_meshes(node)
		result.append(node)
		return
	for child in node.get_children():
		_collect_collision_sources(child, original_name, result, prefix_match)


func _is_collision_source(node: Node3D, original_name: String, prefix_match: bool) -> bool:
	var source_name := String(node.get_meta("original_name", ""))
	var matches := source_name.to_lower().begins_with(original_name) if prefix_match else source_name == original_name
	var points: PackedVector3Array = node.get_meta("collision_points", PackedVector3Array())
	return matches and points.size() >= 4


func _collision_shape(source: Node3D) -> Shape3D:
	var points: PackedVector3Array = source.get_meta("collision_points", PackedVector3Array())
	if points.size() >= 4:
		var shape := ConvexPolygonShape3D.new()
		shape.points = points
		return shape
	for child in source.get_children():
		if child is MeshInstance3D and child.mesh != null:
			return child.mesh.create_convex_shape(true, false)
	return null


func _hide_collision_meshes(node: Node) -> void:
	for child in node.get_children():
		if child is MeshInstance3D and child.has_meta("collision_mesh"):
			child.visible = false


func _add_selection_halo() -> void:
	_selection_halo = SelectionHaloScript.new()
	_selection_halo.name = "SelectionHalo"
	add_child(_selection_halo)
	_selection_halo.configure(self, _selection_radius(), _selection_elevation())


func _selection_radius() -> float:
	var anchor_bounds := _halo_anchor_bounds()
	if anchor_bounds.size.x > 0.0 or anchor_bounds.size.z > 0.0:
		return maxf(anchor_bounds.size.x, anchor_bounds.size.z) * 0.5

	var bounds := _selection_bounds()
	# A halo is circular: its diameter follows the authored selection volume's
	# narrow horizontal axis, not its length.  This keeps long vehicles and
	# buildings from receiving an oversized circle.
	return minf(bounds.size.x, bounds.size.z) * 0.5


func _selection_elevation() -> float:
	var anchor: Node3D = _halo_anchor_node(visual_root)
	if anchor != null:
		return to_local(anchor.to_global(Vector3.ZERO)).y

	return _selection_bounds().end.y + 0.05


func _halo_anchor_bounds() -> AABB:
	var anchor: Node3D = _halo_anchor_node(visual_root)
	if anchor == null or not anchor.has_meta("halo_anchor_bounds"):
		return AABB()
	var source_bounds: AABB = anchor.get_meta("halo_anchor_bounds")
	var bounds := AABB()
	var has_bounds := false
	for corner in _aabb_corners(source_bounds):
		var point := to_local(anchor.to_global(corner))
		if has_bounds:
			bounds = bounds.expand(point)
		else:
			bounds = AABB(point, Vector3.ZERO)
			has_bounds = true
	return bounds


func _selection_bounds() -> AABB:
	var highest := 0.0
	var bounds := AABB()
	var has_bounds := false
	for marker in _selection_marker_nodes(visual_root):
		var marker_bounds: AABB = marker.get_meta("selection_bounds")
		for corner in _aabb_corners(marker_bounds):
			var point := to_local(marker.to_global(corner))
			if has_bounds:
				bounds = bounds.expand(point)
			else:
				bounds = AABB(point, Vector3.ZERO)
				has_bounds = true
	if has_bounds:
		return bounds
	return AABB(Vector3.ZERO, Vector3(1.0, 1.0, 1.0))


func _selection_marker_nodes(node: Node) -> Array[Node3D]:
	var result: Array[Node3D] = []
	_collect_selection_marker_nodes(node, result)
	return result


func _collect_selection_marker_nodes(node: Node, result: Array[Node3D]) -> void:
	if node is Node3D and node.has_meta("selection_bounds"):
		result.append(node)
	for child in node.get_children():
		_collect_selection_marker_nodes(child, result)


func _halo_anchor_node(node: Node) -> Node3D:
	if node is Node3D and node.has_meta("halo_anchor"):
		return node
	for child in node.get_children():
		var anchor: Node3D = _halo_anchor_node(child)
		if anchor != null:
			return anchor
	return null


func _aabb_corners(bounds: AABB) -> Array[Vector3]:
	var corners: Array[Vector3] = []
	for x in [bounds.position.x, bounds.end.x]:
		for y in [bounds.position.y, bounds.end.y]:
			for z in [bounds.position.z, bounds.end.z]:
				corners.append(Vector3(x, y, z))
	return corners


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
