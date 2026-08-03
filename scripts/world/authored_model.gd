class_name AuthoredModel
extends RefCounted


static func animation_players(root: Node) -> Array[AnimationPlayer]:
	var result: Array[AnimationPlayer] = []
	if root == null:
		return result
	if root is AnimationPlayer:
		result.append(root as AnimationPlayer)
	for node in root.find_children("*", "AnimationPlayer", true, false):
		result.append(node as AnimationPlayer)
	return result


static func find_clip(players: Array[AnimationPlayer], candidates: Array[StringName]) -> Dictionary:
	for candidate in candidates:
		for player in players:
			if player.has_animation(candidate):
				return {"player": player, "name": candidate}
	return {"player": null, "name": &""}


static func clip_length(clip: Dictionary) -> float:
	var player := clip.get("player") as AnimationPlayer
	var name := StringName(clip.get("name", &""))
	if player == null or name == &"" or not player.has_animation(name):
		return 0.0
	var animation := player.get_animation(name)
	return animation.length if animation != null else 0.0


static func play_clip(clip: Dictionary) -> bool:
	var player := clip.get("player") as AnimationPlayer
	var name := StringName(clip.get("name", &""))
	if player == null or name == &"" or not player.has_animation(name):
		return false
	player.play(name)
	return true


static func play_one_shot(root: Node, clip: StringName, on_finished: Callable = Callable()) -> bool:
	var found := find_clip(animation_players(root), [clip])
	var player := found.get("player") as AnimationPlayer
	if player == null:
		return false
	var animation := player.get_animation(clip)
	if animation != null:
		animation.loop_mode = Animation.LOOP_NONE
	if on_finished.is_valid() and not player.animation_finished.is_connected(on_finished):
		player.animation_finished.connect(on_finished, CONNECT_ONE_SHOT)
	if root.has_method("play_state"):
		root.call("play_state", clip)
		return true
	return play_clip(found)


static func play_state(node: Node, state: StringName) -> void:
	if node == null:
		return
	if node.has_method("play_state"):
		node.call("play_state", state)
		return
	var player := node.get_node_or_null("StatePlayer") as AnimationPlayer
	if player != null and player.has_animation(state):
		player.play(state)


static func collision_sources(
	root: Node,
	prefix_order: Array,
	hide_source_meshes := true
	) -> Array[Node3D]:
	for descriptor in prefix_order:
		var result: Array[Node3D] = []
		var name := String(descriptor.get("name", ""))
		var prefix := bool(descriptor.get("prefix", false))
		_collect_collision_sources(root, name, prefix, hide_source_meshes, result)
		if not result.is_empty():
			return result
	return []


static func selection_bounds(root: Node, coordinate_root: Node3D) -> AABB:
	var markers: Array[Node3D] = []
	_collect_meta_nodes(root, &"selection_bounds", markers)
	var bounds := AABB()
	var has_bounds := false
	for marker in markers:
		var marker_bounds: AABB = marker.get_meta("selection_bounds")
		for corner in _aabb_corners(marker_bounds):
			var point := coordinate_root.to_local(marker.to_global(corner))
			if has_bounds:
				bounds = bounds.expand(point)
			else:
				bounds = AABB(point, Vector3.ZERO)
				has_bounds = true
	return bounds if has_bounds else AABB(Vector3.ZERO, Vector3.ONE)


static func _collect_collision_sources(
	node: Node,
	name: String,
	prefix: bool,
	hide_source_meshes: bool,
	result: Array[Node3D]
	) -> void:
	if node == null:
		return
	if node is Node3D:
		var source_name := String(node.get_meta("original_name", ""))
		var matches := source_name.to_lower().begins_with(name) if prefix else source_name == name
		var points: PackedVector3Array = node.get_meta("collision_points", PackedVector3Array())
		if matches and points.size() >= 4:
			if hide_source_meshes:
				for child in node.get_children():
					if child is MeshInstance3D and child.has_meta("collision_mesh"):
						child.visible = false
			result.append(node)
			return
	for child in node.get_children():
		_collect_collision_sources(child, name, prefix, hide_source_meshes, result)


static func _collect_meta_nodes(node: Node, meta_name: StringName, result: Array[Node3D]) -> void:
	if node == null:
		return
	if node is Node3D and node.has_meta(meta_name):
		result.append(node)
	for child in node.get_children():
		_collect_meta_nodes(child, meta_name, result)


static func _aabb_corners(bounds: AABB) -> Array[Vector3]:
	var result: Array[Vector3] = []
	for x in [bounds.position.x, bounds.end.x]:
		for y in [bounds.position.y, bounds.end.y]:
			for z in [bounds.position.z, bounds.end.z]:
				result.append(Vector3(x, y, z))
	return result
