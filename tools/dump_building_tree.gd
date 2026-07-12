extends SceneTree

## Dumps the node tree of production building scenes so mesh node names
## can be inspected without opening the editor.
## Usage: godot --headless --path . --script res://tools/dump_building_tree.gd

const BUILDINGS := ["ATFactory", "ATHanger", "ATBarracks"]


func _init() -> void:
	for building in BUILDINGS:
		var path := "res://assets/converted/buildings/%s/%s.scn" % [building, building]
		var packed: PackedScene = load(path)
		if packed == null:
			push_error("Failed to load %s" % path)
			continue
		var root := packed.instantiate()
		print("\n=== %s ===" % building)
		_dump(root, 0)
		root.free()
	quit()


func _dump(node: Node, depth: int) -> void:
	var line := "%s%s (%s)" % ["  ".repeat(depth), node.name, node.get_class()]
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		var aabb := mi.get_aabb()
		line += "  pos=%s aabb_pos=%s aabb_size=%s" % [
			mi.position, aabb.position, aabb.size,
		]
	elif node is Node3D:
		line += "  pos=%s" % (node as Node3D).position
	print(line)
	for child in node.get_children():
		_dump(child, depth + 1)
