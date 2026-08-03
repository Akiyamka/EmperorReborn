class_name SelectionHaloBinding
extends RefCounted

const AuthoredModelScript := preload("res://scripts/world/authored_model.gd")


static func anchor(root: Node) -> Node3D:
	if root == null:
		return null
	if root is Node3D and root.has_meta("halo_anchor"):
		return root
	for child in root.get_children():
		var result := anchor(child)
		if result != null:
			return result
	return null


static func radius(search_root: Node, coordinate_root: Node3D) -> float:
	var bounds := anchor_bounds(search_root, coordinate_root)
	if bounds.size.x > 0.0 or bounds.size.z > 0.0:
		return maxf(bounds.size.x, bounds.size.z) * 0.5
	bounds = AuthoredModelScript.selection_bounds(search_root, coordinate_root)
	return minf(bounds.size.x, bounds.size.z) * 0.5


static func position(search_root: Node, coordinate_root: Node3D) -> Vector3:
	var halo_anchor := anchor(search_root)
	if halo_anchor != null:
		return coordinate_root.to_local(halo_anchor.to_global(Vector3.ZERO))
	return Vector3(0.0, AuthoredModelScript.selection_bounds(search_root, coordinate_root).end.y + 0.05, 0.0)


static func anchor_bounds(search_root: Node, coordinate_root: Node3D) -> AABB:
	var halo_anchor := anchor(search_root)
	if halo_anchor == null or not halo_anchor.has_meta("halo_anchor_bounds"):
		return AABB()
	var source_bounds: AABB = halo_anchor.get_meta("halo_anchor_bounds")
	var source_to_global := halo_anchor.global_transform
	var reference_basis: Variant = halo_anchor.get_meta("halo_anchor_reference_basis", null)
	var anchor_parent := halo_anchor.get_parent() as Node3D
	if reference_basis is Basis and anchor_parent != null:
		source_to_global.basis = anchor_parent.global_transform.basis * (reference_basis as Basis)
	var bounds := AABB()
	var has_bounds := false
	for corner in _aabb_corners(source_bounds):
		var point := coordinate_root.to_local(source_to_global * corner)
		if has_bounds:
			bounds = bounds.expand(point)
		else:
			bounds = AABB(point, Vector3.ZERO)
			has_bounds = true
	return bounds


static func _aabb_corners(bounds: AABB) -> Array[Vector3]:
	var result: Array[Vector3] = []
	for x in [bounds.position.x, bounds.end.x]:
		for y in [bounds.position.y, bounds.end.y]:
			for z in [bounds.position.z, bounds.end.z]:
				result.append(Vector3(x, y, z))
	return result
