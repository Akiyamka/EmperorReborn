class_name SpatialOrientation
extends RefCounted

## Godot's semantic forward axis for Node3D is local -Z. Imported Emperor
## assets are allowed to use another authored axis, but that difference must be
## named at the entity boundary instead of leaking as raw basis.z expressions.
const LOCAL_FORWARD := Vector3.FORWARD
const LOCAL_BACK := Vector3.BACK
const LOCAL_RIGHT := Vector3.RIGHT
const DIRECTION_EPSILON := 0.000001


static func world_horizontal_axis(node: Node3D, local_axis: Vector3) -> Vector3:
	if node == null:
		return Vector3.ZERO
	var basis := node.global_transform.basis if node.is_inside_tree() else node.transform.basis
	var direction: Vector3 = basis * local_axis
	direction.y = 0.0
	if direction.length_squared() <= DIRECTION_EPSILON:
		return Vector3.ZERO
	return direction.normalized()


static func world_forward(node: Node3D) -> Vector3:
	return world_horizontal_axis(node, LOCAL_FORWARD)


static func world_right(node: Node3D) -> Vector3:
	return world_horizontal_axis(node, LOCAL_RIGHT)


## Yaw for a regular Godot Node3D whose semantic front is local -Z.
static func yaw_facing(direction: Vector3, fallback := 0.0) -> float:
	var horizontal := Vector3(direction.x, 0.0, direction.z)
	if horizontal.length_squared() <= DIRECTION_EPSILON:
		return fallback
	horizontal = horizontal.normalized()
	return atan2(-horizontal.x, -horizontal.z)
