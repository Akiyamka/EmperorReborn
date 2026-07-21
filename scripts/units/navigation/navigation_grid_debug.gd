class_name NavigationGridDebug
extends Node3D
## Visual-only overlay for the immutable 256x256 baked navigation grid plus the
## dynamic obstacle overlay (building blockers) from the match runtime map.
## Match owns its visibility together with the other F3 debug layers.

const GRID_SHADER := preload("res://scripts/units/navigation/navigation_grid_debug.gdshader")
const DYNAMIC_BLOCKED_COLOR := Color(1.0, 0.0, 1.0, 0.8)
const DYNAMIC_NO_STOP_COLOR := Color(1.0, 0.9, 0.1, 0.6)

@export var visible_by_default := false
var _configured := false
var _material: ShaderMaterial
var _runtime_map
var _blocked_revision := -1
var _enabled := false


func setup(map_loader: MapLoader, navigation_system = null) -> bool:
	if map_loader == null or map_loader.navigation_grid == null or not map_loader.navigation_grid.is_loaded():
		push_warning("NavigationGridDebug: navigation grid is unavailable")
		return false
	_clear_overlays()
	_runtime_map = navigation_system.runtime_map if navigation_system != null else null
	_blocked_revision = -1
	var material := ShaderMaterial.new()
	material.shader = GRID_SHADER
	var grid := map_loader.navigation_grid
	material.set_shader_parameter("grid_origin", Vector2(grid.world_bounds.position.x, grid.world_bounds.position.z))
	material.set_shader_parameter("grid_world_size", Vector2(grid.world_bounds.size.x, grid.world_bounds.size.z))
	material.set_shader_parameter("navigation_types", _navigation_type_texture(grid))
	material.render_priority = 10
	_material = material

	for node in map_loader.find_children("*", "MeshInstance3D", true, false):
		var source := node as MeshInstance3D
		if source == null or source.mesh == null:
			continue
		var overlay := MeshInstance3D.new()
		overlay.name = "%sNavigationGrid" % source.name
		overlay.mesh = source.mesh
		overlay.material_override = material
		overlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		overlay.extra_cull_margin = 1.0
		add_child(overlay)
		overlay.global_transform = source.global_transform
	_configured = get_child_count() > 0
	_enabled = visible_by_default
	visible = _enabled and _configured
	return _configured


func _process(_delta: float) -> void:
	if not visible or not _configured or _runtime_map == null or _material == null:
		return
	if int(_runtime_map.revision) == _blocked_revision:
		return
	_blocked_revision = int(_runtime_map.revision)
	_material.set_shader_parameter("dynamic_blocked", _dynamic_blocked_texture())


func _dynamic_blocked_texture() -> ImageTexture:
	var image := Image.create(MapNavigationGrid.NAV_SIZE, MapNavigationGrid.NAV_SIZE, false, Image.FORMAT_RGBA8)
	var blocked: PackedByteArray = _runtime_map.blocked_cells()
	var no_stop: PackedByteArray = _runtime_map.no_stop_cells()
	for index in blocked.size():
		if blocked[index] != 0:
			image.set_pixel(index % MapNavigationGrid.NAV_SIZE, int(index / MapNavigationGrid.NAV_SIZE), DYNAMIC_BLOCKED_COLOR)
		elif no_stop[index] != 0:
			image.set_pixel(index % MapNavigationGrid.NAV_SIZE, int(index / MapNavigationGrid.NAV_SIZE), DYNAMIC_NO_STOP_COLOR)
	return ImageTexture.create_from_image(image)


func _navigation_type_texture(grid: MapNavigationGrid) -> ImageTexture:
	var image := Image.create(MapNavigationGrid.NAV_SIZE, MapNavigationGrid.NAV_SIZE, false, Image.FORMAT_RGBA8)
	for y in MapNavigationGrid.NAV_SIZE:
		for x in MapNavigationGrid.NAV_SIZE:
			var cell := Vector2i(x, y)
			image.set_pixel(x, y, _terrain_color(grid.terrain_at(cell)))
	return ImageTexture.create_from_image(image)


func _terrain_color(terrain_type: int) -> Color:
	match terrain_type:
		MapNavigationGrid.TERRAIN_SAND:
			return Color(0.92, 0.72, 0.20, 0.26)
		MapNavigationGrid.TERRAIN_ROCK:
			return Color(0.20, 0.90, 0.28, 0.28)
		MapNavigationGrid.TERRAIN_CLIFF:
			return Color(1.00, 0.10, 0.08, 0.48)
		MapNavigationGrid.TERRAIN_NONBUILDROCK:
			return Color(1.00, 0.48, 0.08, 0.34)
		MapNavigationGrid.TERRAIN_INFANTRYROCK:
			return Color(0.05, 0.90, 1.00, 0.42)
		MapNavigationGrid.TERRAIN_DUSTBOWL:
			return Color(0.82, 0.18, 1.00, 0.40)
		MapNavigationGrid.TERRAIN_MAPEDGE:
			return Color(0.06, 0.06, 0.08, 0.62)
		MapNavigationGrid.TERRAIN_RAMP:
			return Color(0.15, 0.42, 1.00, 0.38)
		_:
			return Color(1.00, 0.00, 0.70, 0.55)


func set_enabled(value: bool) -> void:
	_enabled = value
	visible = _enabled and _configured
	if visible:
		# Force the dynamic blockers texture to refresh on the first visible frame.
		_blocked_revision = -1


func is_enabled() -> bool:
	return _enabled


func _clear_overlays() -> void:
	for child in get_children():
		child.queue_free()
	_configured = false
