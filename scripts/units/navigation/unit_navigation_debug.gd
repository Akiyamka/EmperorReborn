class_name UnitNavigationDebug
extends Node3D
## Visual-only diagnostic overlay for selected units.
##
## Cyan is the remaining compact A* route, orange is its current waypoint,
## yellow is the radius/TurnRate look-ahead target, and green is the reserved
## destination. The magenta final steering arrow is drawn by SelectionHalo.

const ROUTE_COLOR := Color(0.05, 0.78, 1.0, 0.88)
const WAYPOINT_COLOR := Color(1.0, 0.42, 0.05, 0.95)
const LOOK_AHEAD_COLOR := Color(1.0, 0.92, 0.05, 0.95)
const DESTINATION_COLOR := Color(0.12, 1.0, 0.28, 0.95)
const ROUTE_MIN_WIDTH := 0.07
const MARKER_MIN_RADIUS := 0.28
const MARKER_SEGMENTS := 20

var _mesh_instance: MeshInstance3D
var _has_geometry := false
var _enabled := false


func _ready() -> void:
	set_as_top_level(true)
	global_transform = Transform3D.IDENTITY
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "Geometry"
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mesh_instance.extra_cull_margin = 1000.0
	add_child(_mesh_instance)
	visible = _enabled


func set_enabled(value: bool) -> void:
	_enabled = value
	visible = value
	if not value:
		_clear_geometry()


func is_enabled() -> bool:
	return _enabled


func update_agents(snapshots: Array[Dictionary]) -> void:
	if _mesh_instance == null:
		return
	if not _enabled:
		_clear_geometry()
		return
	var route_vertices := PackedVector3Array()
	var waypoint_vertices := PackedVector3Array()
	var look_ahead_vertices := PackedVector3Array()
	var destination_vertices := PackedVector3Array()
	for snapshot in snapshots:
		var radius := maxf(float(snapshot.get("radius", 0.5)), 0.1)
		var width := maxf(radius * 0.10, ROUTE_MIN_WIDTH)
		var route: Array = snapshot.get("route", [])
		for index in range(1, route.size()):
			_append_ribbon(route_vertices, route[index - 1], route[index], width)
		var marker_radius := maxf(radius * 0.34, MARKER_MIN_RADIUS)
		var waypoint: Vector3 = snapshot.get("waypoint", Vector3.INF)
		if waypoint.is_finite():
			_append_diamond(waypoint_vertices, waypoint, marker_radius * 0.72)
		var look_ahead: Vector3 = snapshot.get("look_ahead", Vector3.INF)
		if look_ahead.is_finite():
			_append_cross(look_ahead_vertices, look_ahead, marker_radius, width * 1.4)
		var destination: Vector3 = snapshot.get("destination", Vector3.INF)
		if destination.is_finite():
			_append_ring(destination_vertices, destination, marker_radius * 1.25, width * 1.5)
			_append_cross(destination_vertices, destination, marker_radius * 0.72, width * 1.25)
	var mesh := ImmediateMesh.new()
	_append_surface(mesh, route_vertices, ROUTE_COLOR)
	_append_surface(mesh, waypoint_vertices, WAYPOINT_COLOR)
	_append_surface(mesh, look_ahead_vertices, LOOK_AHEAD_COLOR)
	_append_surface(mesh, destination_vertices, DESTINATION_COLOR)
	_has_geometry = mesh.get_surface_count() > 0
	_mesh_instance.mesh = mesh if _has_geometry else null


func has_geometry() -> bool:
	return _has_geometry


func _clear_geometry() -> void:
	_has_geometry = false
	if _mesh_instance != null:
		_mesh_instance.mesh = null


func _append_surface(mesh: ImmediateMesh, vertices: PackedVector3Array, color: Color) -> void:
	if vertices.is_empty():
		return
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.no_depth_test = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.render_priority = 19
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, material)
	for vertex in vertices:
		mesh.surface_add_vertex(vertex)
	mesh.surface_end()


func _append_ribbon(
		vertices: PackedVector3Array,
		from: Vector3,
		to: Vector3,
		width: float
	) -> void:
	var direction := to - from
	direction.y = 0.0
	if direction.length_squared() <= 0.000001:
		return
	direction = direction.normalized()
	var lateral := Vector3(-direction.z, 0.0, direction.x) * width * 0.5
	_append_quad(vertices, from - lateral, to - lateral, to + lateral, from + lateral)


func _append_ring(
		vertices: PackedVector3Array,
		center: Vector3,
		radius: float,
		width: float
	) -> void:
	var inner := maxf(radius - width * 0.5, 0.01)
	var outer := radius + width * 0.5
	for index in MARKER_SEGMENTS:
		var first_angle := TAU * float(index) / float(MARKER_SEGMENTS)
		var second_angle := TAU * float(index + 1) / float(MARKER_SEGMENTS)
		var first_direction := Vector3(cos(first_angle), 0.0, sin(first_angle))
		var second_direction := Vector3(cos(second_angle), 0.0, sin(second_angle))
		_append_quad(
			vertices,
			center + first_direction * inner,
			center + second_direction * inner,
			center + second_direction * outer,
			center + first_direction * outer
		)


func _append_cross(
		vertices: PackedVector3Array,
		center: Vector3,
		radius: float,
		width: float
	) -> void:
	_append_ribbon(
		vertices,
		center + Vector3(-radius, 0.0, -radius),
		center + Vector3(radius, 0.0, radius),
		width
	)
	_append_ribbon(
		vertices,
		center + Vector3(-radius, 0.0, radius),
		center + Vector3(radius, 0.0, -radius),
		width
	)


func _append_diamond(vertices: PackedVector3Array, center: Vector3, radius: float) -> void:
	_append_triangle(
		vertices,
		center + Vector3(-radius, 0.0, 0.0),
		center + Vector3(0.0, 0.0, -radius),
		center + Vector3(radius, 0.0, 0.0)
	)
	_append_triangle(
		vertices,
		center + Vector3(-radius, 0.0, 0.0),
		center + Vector3(radius, 0.0, 0.0),
		center + Vector3(0.0, 0.0, radius)
	)


func _append_quad(
		vertices: PackedVector3Array,
		a: Vector3,
		b: Vector3,
		c: Vector3,
		d: Vector3
	) -> void:
	_append_triangle(vertices, a, b, c)
	_append_triangle(vertices, a, c, d)


func _append_triangle(
		vertices: PackedVector3Array,
		a: Vector3,
		b: Vector3,
		c: Vector3
	) -> void:
	vertices.append(a)
	vertices.append(b)
	vertices.append(c)
