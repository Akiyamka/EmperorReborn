extends SceneTree

## Diagnostic: compares each converted building's Idle-state mesh bounds with
## its occupy_rows footprint extents (both in the building's local space).

const OCCUPY_CELL_WORLD_SPAN := 2.0


func _initialize() -> void:
	var names := [
		"ATConYard", "ATBarracks", "ATFactory", "ATRefinery", "HKRefinery",
		"ATStarport", "ORStarport", "GUPalace", "ATFactoryFrigate", "HKConYard",
		"ATPillbox", "ATSmWindtrap", "ATHelipad", "ATPalace", "TLFleshVat",
	]
	for building_name in names:
		_probe(building_name)
	quit(0)


func _probe(building_name: String) -> void:
	var scene_path := "res://assets/converted/buildings/%s/%s.scn" % [building_name, building_name]
	var rules_path := "res://assets/converted/rules/buildings/%s.tres" % building_name
	if not ResourceLoader.exists(scene_path) or not ResourceLoader.exists(rules_path):
		print("%s: missing scene or rules" % building_name)
		return
	var scene := load(scene_path) as PackedScene
	var config := load(rules_path)
	var building := scene.instantiate() as Node3D

	var rows: Array = config.get("lists").get("occupy_rows", [])
	var width := 0
	for row in rows:
		width = maxi(width, String(row).length())
	var half_x := float(width) * OCCUPY_CELL_WORLD_SPAN * 0.5
	var half_z := float(rows.size()) * OCCUPY_CELL_WORLD_SPAN * 0.5

	var idle := building.get_node_or_null("States/Idle")
	var target: Node = idle if idle != null else building
	var bounds := AABB()
	var has_bounds := false
	var stack: Array = [target]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.push_back(child)
		if node is MeshInstance3D and node.visible and node.mesh != null:
			var mesh_instance := node as MeshInstance3D
			var to_building := _relative_transform(mesh_instance, building)
			for surface_index in mesh_instance.mesh.get_surface_count():
				var arrays := mesh_instance.mesh.surface_get_arrays(surface_index)
				var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				for vertex in vertices:
					var point := to_building * vertex
					if point.y > 0.5:
						continue
					if has_bounds:
						bounds = bounds.expand(point)
					else:
						bounds = AABB(point, Vector3.ZERO)
						has_bounds = true

	if not has_bounds:
		print("%s: no meshes found" % building_name)
		building.free()
		return

	var mesh_center := bounds.get_center()
	print("%s: rows=%dx%d  footprint x[%.1f..%.1f] z[%.1f..%.1f]" % [
		building_name, width, rows.size(), -half_x, half_x, -half_z, half_z])
	print("    mesh x[%.2f..%.2f] z[%.2f..%.2f]  center=(%.2f, %.2f)  z-offset=%.2f (occupy cells: %.2f)" % [
		bounds.position.x, bounds.end.x, bounds.position.z, bounds.end.z,
		mesh_center.x, mesh_center.z, mesh_center.z, mesh_center.z / OCCUPY_CELL_WORLD_SPAN])
	building.free()


func _relative_transform(node: Node3D, ancestor: Node3D) -> Transform3D:
	var result := Transform3D.IDENTITY
	var current: Node = node
	while current != null and current != ancestor:
		if current is Node3D:
			result = (current as Node3D).transform * result
		current = current.get_parent()
	return result
