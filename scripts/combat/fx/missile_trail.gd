class_name MissileTrail
extends RefCounted

## The smoke wake behind a missile: a tube of triangles threaded through the
## projectile's own recent positions, fading out from the tail.
##
## The history is kept in seconds rather than as a fixed point count, which is
## what lets the wake follow a ballistic arc -- Rules Length is an authored
## history count and Delta its fractional spacing in rule ticks, so the two
## together are a duration.
##
## Owns the MeshInstance3D it adds to the projectile, so it follows the
## attach/detach protocol; detach() is idempotent, and a projectile that is
## freed mid-flight takes the mesh with it either way.

const BallisticsScript := preload("res://scripts/combat/ballistics.gd")

const SIDES := 6
const MAX_POINTS := 128
const RADIUS_SCALE := BallisticsScript.SOURCE_MODEL_WORLD_SCALE * 0.65

var _projectile: Node3D
var _mesh: ImmediateMesh
var _material: StandardMaterial3D
var _visual: MeshInstance3D
var _points: Array[Dictionary] = []
var _duration := 0.0
var _radius := 0.0
var _color := Color.WHITE


func configure(projectile: Node3D) -> void:
	_projectile = projectile


## Builds the wake for a bullet that has one, and reports whether it did. A
## bullet with no authored MissileTrail, or a zero-length one, simply has no
## wake and this module then does nothing for the rest of the flight.
func build(bullet, start_position: Vector3, elapsed_seconds: float) -> bool:
	if (
		bullet == null
		or bullet.is_hitscan()
		or not bullet.has_missile_trail()
		or bullet.missile_trail_size() <= 0.0
		or bullet.missile_trail_length() <= 0
	):
		return false

	_duration = maxf(
		float(bullet.missile_trail_length())
			* maxf(bullet.missile_trail_delta(), 0.05)
			/ BallisticsScript.RULE_UPDATES_PER_SECOND,
		1.0 / BallisticsScript.RULE_UPDATES_PER_SECOND
	)
	_radius = float(bullet.missile_trail_size()) * RADIUS_SCALE
	_color = _style_color(bullet.missile_trail_style())
	_mesh = ImmediateMesh.new()
	_material = StandardMaterial3D.new()
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.vertex_color_use_as_albedo = true
	_material.albedo_color = Color.WHITE
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED

	_visual = MeshInstance3D.new()
	_visual.name = "MissileTrail"
	_visual.mesh = _mesh
	_visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_projectile.add_child(_visual)
	_points.append({"position": start_position, "time": elapsed_seconds})
	return true


## Records where the shot is now and redraws. `fallback_direction` orients the
## first and last rings, which have no neighbour on one side to take a tangent
## from.
func sample(
	world_position: Vector3, elapsed_seconds: float, fallback_direction: Vector3
) -> void:
	if _mesh == null:
		return
	var point := {"position": world_position, "time": elapsed_seconds}
	if _points.is_empty():
		_points.append(point)
	else:
		var previous_position := Vector3(_points.back()["position"])
		if previous_position.distance_squared_to(world_position) > 0.000001:
			_points.append(point)

	var oldest_time := elapsed_seconds - _duration
	while _points.size() > 2 and float(_points[1]["time"]) < oldest_time:
		_points.pop_front()
	while _points.size() > MAX_POINTS:
		_points.pop_front()
	_rebuild(elapsed_seconds, fallback_direction)


func detach() -> void:
	if is_instance_valid(_visual):
		_visual.queue_free()
	_visual = null
	_mesh = null
	_points.clear()


func _rebuild(elapsed_seconds: float, fallback_direction: Vector3) -> void:
	_mesh.clear_surfaces()
	if _points.size() < 2 or _duration <= 0.0:
		return
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, _material)
	for point_index in _points.size() - 1:
		var first_ring := _ring(point_index, elapsed_seconds, fallback_direction)
		var second_ring := _ring(point_index + 1, elapsed_seconds, fallback_direction)
		for side in SIDES:
			var next_side := (side + 1) % SIDES
			_add_vertex(first_ring[side])
			_add_vertex(second_ring[side])
			_add_vertex(second_ring[next_side])
			_add_vertex(first_ring[side])
			_add_vertex(second_ring[next_side])
			_add_vertex(first_ring[next_side])
	_mesh.surface_end()


## One cross-section of the tube, perpendicular to the path through that point.
## Older rings are both thinner and more transparent, so the wake tapers away
## instead of ending in a hard disc.
func _ring(
	point_index: int, elapsed_seconds: float, fallback_direction: Vector3
) -> Array[Dictionary]:
	var world_position := Vector3(_points[point_index]["position"])
	var previous_position := Vector3(_points[maxi(point_index - 1, 0)]["position"])
	var next_position := Vector3(
		_points[mini(point_index + 1, _points.size() - 1)]["position"]
	)
	var tangent := previous_position.direction_to(next_position)
	if tangent.is_zero_approx():
		tangent = fallback_direction if not fallback_direction.is_zero_approx() \
			else Vector3.FORWARD
	var reference := Vector3.RIGHT if absf(tangent.dot(Vector3.UP)) > 0.9 else Vector3.UP
	var axis_a := tangent.cross(reference).normalized()
	var axis_b := tangent.cross(axis_a).normalized()
	var age := maxf(elapsed_seconds - float(_points[point_index]["time"]), 0.0)
	var remaining := clampf(1.0 - age / _duration, 0.0, 1.0)
	var radius := _radius * lerpf(0.08, 1.0, remaining)
	var color := _color
	color.a *= remaining * remaining

	var ring: Array[Dictionary] = []
	for side in SIDES:
		var angle := TAU * float(side) / float(SIDES)
		var offset := (axis_a * cos(angle) + axis_b * sin(angle)) * radius
		ring.append({
			"position": _projectile.to_local(world_position + offset),
			"color": color,
		})
	return ring


func _add_vertex(vertex: Dictionary) -> void:
	_mesh.surface_set_color(Color(vertex["color"]))
	_mesh.surface_add_vertex(Vector3(vertex["position"]))


## Style 6 is KobraHowitzer_B's pale aerodynamic wake. The remaining styles
## retain a neutral smoke presentation until their original palettes are
## characterized independently.
static func _style_color(style: int) -> Color:
	if style == 6:
		return Color(0.58, 0.65, 0.68, 0.48)
	return Color(0.62, 0.62, 0.60, 0.56)
