class_name EntityQuery
extends RefCounted

const SpatialOrientationScript := preload("res://scripts/world/spatial_orientation.gd")


static func is_live(node) -> bool:
	return node != null \
		and is_instance_valid(node) \
		and (not node is Node or not (node as Node).is_queued_for_deletion())


static func owner_id_of(node, fallback: int = -1) -> int:
	if not is_live(node) or not &"owner_player_id" in node:
		return fallback
	return int(node.get("owner_player_id"))


static func is_owned_by(node, player_id: int) -> bool:
	return owner_id_of(node) == player_id


static func is_operational(node) -> bool:
	return is_live(node) and (
		not node.has_method("is_construction_complete")
		or bool(node.call("is_construction_complete"))
	)


static func exit_direction(node: Node3D) -> Vector3:
	if node != null and node.has_method("exit_direction"):
		return node.call("exit_direction") as Vector3
	return SpatialOrientationScript.world_horizontal_axis(node, Vector3.BACK)


static func units_parent(tree: SceneTree, fallback: Node = null) -> Node:
	if tree == null:
		return fallback
	var existing_unit := tree.get_first_node_in_group("units")
	if existing_unit != null and existing_unit.get_parent() != null:
		return existing_unit.get_parent()
	var scene_root := tree.current_scene
	var units := scene_root.get_node_or_null("Units") if scene_root != null else null
	return units if units != null else fallback


static func owned_live_in_group(tree: SceneTree, group: StringName, player_id: int) -> Array[Node]:
	var result: Array[Node] = []
	if tree == null:
		return result
	for node in tree.get_nodes_in_group(group):
		if is_live(node) and is_owned_by(node, player_id):
			result.append(node)
	return result


static func owner_player(node: Node, roster: Node):
	if roster == null:
		return null
	return roster.player(owner_id_of(node))


static func is_allied_with(node: Node, player_id: int, roster: Node) -> bool:
	return roster != null and roster.are_allied(owner_id_of(node), player_id)


static func is_enemy_of(node: Node, player_id: int, roster: Node) -> bool:
	return roster != null and roster.are_enemies(owner_id_of(node), player_id)
