extends SceneTree

## Diagnostic: compares each building's authored collision volume (#~~0,
## collision_points meta) with candidate occupy-matrix regions, both expressed
## in raw model space (relative to the Idle state node), to find which region
## the collision was authored against.


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
	var building := (load(scene_path) as PackedScene).instantiate() as Node3D
	var config := load(rules_path)
	var rows: Array = config.call("list", &"occupy_rows")
	var idle := building.get_node_or_null("States/Idle") as Node3D
	if idle == null:
		print("%s: no idle state" % building_name)
		building.free()
		return

	var bounds := AABB()
	var has_bounds := false
	var stack: Array = [idle]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.push_back(child)
		if node is Node3D and String(node.get_meta("original_name", "")) == "#~~0":
			var points: PackedVector3Array = node.get_meta("collision_points", PackedVector3Array())
			var to_idle := _relative_transform(node, idle)
			for point in points:
				var local := to_idle * point
				if has_bounds:
					bounds = bounds.expand(local)
				else:
					bounds = AABB(local, Vector3.ZERO)
					has_bounds = true

	var width := 0
	for row in rows:
		width = maxi(width, String(row).length())
	var depth := rows.size()
	print("%s: matrix %dx%d  x[%.1f..%.1f] z[%.1f..%.1f]" % [
		building_name, width, depth, -float(width), float(width), -float(depth), float(depth)])
	if not has_bounds:
		print("    no #~~0 collision volume")
		building.free()
		return
	print("    collision x[%6.2f..%6.2f] z[%6.2f..%6.2f]  center=(%5.2f, %5.2f)" % [
		bounds.position.x, bounds.end.x, bounds.position.z, bounds.end.z,
		bounds.get_center().x, bounds.get_center().z])
	for markers in ["b", "bp", "bpd"]:
		var region := _marker_bounds(rows, width, depth, markers)
		if region == Rect2():
			continue
		print("    region '%s' x[%5.1f..%5.1f] z[%5.1f..%5.1f]  center=(%5.2f, %5.2f)  implied dz=%.2f" % [
			markers, region.position.x, region.end.x, region.position.y, region.end.y,
			region.get_center().x, region.get_center().y,
			region.get_center().y - bounds.get_center().z])
	building.free()


## Returns the world-unit bounding box (x, z) of cells whose marker is in
## `markers`, in matrix-local coordinates (matrix centred on the origin).
func _marker_bounds(rows: Array, width: int, depth: int, markers: String) -> Rect2:
	var min_c := width
	var max_c := -1
	var min_r := depth
	var max_r := -1
	for row_index in rows.size():
		var row := String(rows[row_index]).to_lower()
		for column in row.length():
			if not markers.contains(row.substr(column, 1)):
				continue
			min_c = mini(min_c, column)
			max_c = maxi(max_c, column)
			min_r = mini(min_r, row_index)
			max_r = maxi(max_r, row_index)
	if max_c < 0:
		return Rect2()
	return Rect2(
		Vector2(-width + 2.0 * min_c, -depth + 2.0 * min_r),
		Vector2(2.0 * (max_c - min_c + 1), 2.0 * (max_r - min_r + 1))
	)


func _relative_transform(node: Node3D, ancestor: Node3D) -> Transform3D:
	var result := Transform3D.IDENTITY
	var current: Node = node
	while current != null and current != ancestor:
		if current is Node3D:
			result = (current as Node3D).transform * result
		current = current.get_parent()
	return result
