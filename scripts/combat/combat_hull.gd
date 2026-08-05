class_name CombatHull
extends RefCounted

const MAX_VERTICES := 8

var _owner: Node3D
var _points := PackedVector2Array()
var _minimum_y := 0.0
var _maximum_y := 0.0


func configure(owner: Node3D) -> void:
	_owner = owner
	_points = owner.get_meta("combat_hull", PackedVector2Array())
	_minimum_y = float(owner.get_meta("combat_hull_minimum_y", 0.0))
	_maximum_y = float(owner.get_meta("combat_hull_maximum_y", 0.0))


func aim_position_from(world_origin: Vector3, fallback_aim: Vector3) -> Vector3:
	if _points.size() >= 3:
		var local_origin := _owner.to_local(world_origin)
		var nearest := _nearest_point(Vector2(local_origin.x, local_origin.z))
		var local_aim := _owner.to_local(fallback_aim)
		local_aim.x = nearest.x
		local_aim.y = clampf(local_origin.y, _minimum_y, _maximum_y)
		local_aim.z = nearest.y
		return _owner.to_global(local_aim)
	var collision_body := _owner.get_node_or_null("SelectionCollision") as StaticBody3D
	if collision_body == null or not collision_body.has_meta("collision_bounds"):
		return fallback_aim
	var bounds: AABB = collision_body.get_meta("collision_bounds")
	var local_origin := _owner.to_local(world_origin)
	var local_aim := _owner.to_local(fallback_aim)
	local_aim.x = clampf(local_origin.x, bounds.position.x, bounds.end.x)
	local_aim.z = clampf(local_origin.z, bounds.position.z, bounds.end.z)
	return _owner.to_global(local_aim)


func points() -> PackedVector2Array:
	return _points.duplicate()


func contains_impact_position(world_position: Vector3) -> bool:
	if _points.size() < 3:
		return false
	var local_position := _owner.to_local(world_position)
	var footprint_position := Vector2(local_position.x, local_position.z)
	return Geometry2D.is_point_in_polygon(footprint_position, _points) \
		or footprint_position.distance_to(_nearest_point(footprint_position)) <= 0.001


func _nearest_point(point: Vector2) -> Vector2:
	if Geometry2D.is_point_in_polygon(point, _points):
		return point
	var nearest := _points[0]
	var nearest_distance := INF
	for index in _points.size():
		var candidate := Geometry2D.get_closest_point_to_segment(
			point,
			_points[index],
			_points[(index + 1) % _points.size()]
		)
		var distance := point.distance_squared_to(candidate)
		if distance < nearest_distance:
			nearest = candidate
			nearest_distance = distance
	return nearest
