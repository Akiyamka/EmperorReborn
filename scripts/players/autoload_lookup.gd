class_name AutoloadLookup
extends RefCounted


static func roster(node: Node) -> Node:
	if node == null or not node.is_inside_tree():
		return null
	return node.get_node_or_null("/root/Players")


static func cursors(node: Node) -> Node:
	if node == null or not node.is_inside_tree():
		return null
	return node.get_node_or_null("/root/Cursors")


static func player_of(node: Node, player_id: int):
	var players := roster(node)
	if players == null:
		return null
	return players.player(player_id)
