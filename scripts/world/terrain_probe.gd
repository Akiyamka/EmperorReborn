class_name TerrainProbe
extends RefCounted

const DEFAULT_RAY_DISTANCE := 1000.0
const DEFAULT_GROUND_HEIGHT := 200.0
const TERRAIN_COLLISION_MASK := 1


static func cast(
	world: World3D,
	from: Vector3,
	to: Vector3,
	mask: int,
	exclude: Array[RID] = []
	) -> Dictionary:
	if world == null:
		return {}
	var query := PhysicsRayQueryParameters3D.create(from, to, mask, exclude)
	query.collide_with_areas = false
	return world.direct_space_state.intersect_ray(query)


static func height_hit(
	world: World3D,
	position: Vector3,
	mask: int = TERRAIN_COLLISION_MASK,
	exclude: Array[RID] = [],
	height: float = DEFAULT_GROUND_HEIGHT
	) -> Dictionary:
	return cast(world, position + Vector3.UP * height, position - Vector3.UP * height, mask, exclude)


static func snap_to_ground(world: World3D, point: Vector3) -> Vector3:
	var hit := height_hit(world, point)
	if hit.is_empty():
		return Vector3(point.x, 0.0, point.z)
	return hit["position"]


static func screen_pick(
	camera: Camera3D,
	world: World3D,
	screen_position: Vector2,
	mask: int
	) -> Dictionary:
	if camera == null:
		return {}
	var ray_origin := camera.project_ray_origin(screen_position)
	var ray_end := ray_origin + camera.project_ray_normal(screen_position) * DEFAULT_RAY_DISTANCE
	return cast(world, ray_origin, ray_end, mask)
