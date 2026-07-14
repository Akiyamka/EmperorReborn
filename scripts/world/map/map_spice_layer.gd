class_name MapSpiceLayer
extends RefCounted
## Mutable runtime state for the map's resource fields. Values are byte-density
## units from the XBF map, not player credits or harvester cargo units.

signal spice_changed(cell: Vector2i, previous: int, current: int)
signal spice_mound_changed(cell: Vector2i, present: bool)

const TERRAIN_SHADER := preload("res://scripts/world/map/terrain.gdshader")
const SPICE_COMPOSITE_SHADER := preload("res://scripts/world/map/spice_composite.gdshader")
const SPICE_TEXTURE := preload("res://assets/raw_original_content/3DDATA/Textures/spicetga_32.tga")
const SPICE_MOUND_TEXTURE := preload("res://assets/raw_original_content/3DDATA/Textures/@Spicemound.tga")
const MapNavigationGridScript := preload("res://scripts/world/map/map_navigation_grid.gd")
const COMPOSITE_TEXTURE_SIZE := 1024

var world_bounds := AABB()

var _navigation_grid: MapNavigationGrid
var _spice_values := PackedByteArray()
var _spice_mounds := PackedByteArray()
var _spice_image: Image
var _spice_mound_image: Image
var _spice_texture: ImageTexture
var _spice_mound_texture: ImageTexture
var _source_grid_size := Vector2i.ZERO
var _composite_viewport: SubViewport


func load_baked(data: BakedMapData, navigation_grid: MapNavigationGrid, terrain_mesh: MeshInstance3D = null) -> bool:
	var total := MapNavigationGridScript.NAV_SIZE * MapNavigationGridScript.NAV_SIZE
	if data == null or navigation_grid == null or not navigation_grid.is_loaded():
		push_error("MapSpiceLayer: baked map and a loaded navigation grid are required")
		return false
	if data.nav_spice_value.size() != total:
		push_error("MapSpiceLayer: baked spice grid has invalid size in %s" % data.resource_path)
		return false

	_navigation_grid = navigation_grid
	world_bounds = navigation_grid.world_bounds
	_spice_values = data.nav_spice_value.duplicate()
	_navigation_grid.spice_value = _spice_values

	_spice_mounds.resize(total)
	_spice_mounds.fill(0)
	_source_grid_size = data.nav_report.get("source_spice_grid_size", Vector2i.ZERO)
	if _source_grid_size.x <= 0 or _source_grid_size.y <= 0:
		_source_grid_size = data.nav_report.get("source_grid_size", Vector2i.ZERO)
	_load_spice_mounds(data.spice_mound_cells)
	_build_textures()
	_bind_terrain_materials(terrain_mesh)
	return true


func spice_at(cell: Vector2i) -> int:
	var index := _cell_index(cell)
	return _spice_values[index] if index >= 0 else 0


func has_spice(cell: Vector2i) -> bool:
	return spice_at(cell) > 0


func nearest_spice_cell(origin: Vector2i, minimum_amount := 1) -> Vector2i:
	var best := Vector2i(-1, -1)
	var best_distance_squared := 0x7fffffff
	var size := MapNavigationGridScript.NAV_SIZE
	for y in size:
		for x in size:
			var cell := Vector2i(x, y)
			if _spice_values[y * size + x] < maxi(minimum_amount, 1):
				continue
			var distance_squared := origin.distance_squared_to(cell)
			if distance_squared < best_distance_squared:
				best = cell
				best_distance_squared = distance_squared
	return best


func set_spice(cell: Vector2i, amount: int) -> bool:
	var index := _cell_index(cell)
	if index < 0:
		return false
	var clamped := clampi(amount, 0, 255)
	var previous := int(_spice_values[index])
	if previous == clamped:
		return true
	_spice_values[index] = clamped
	_navigation_grid.spice_value[index] = clamped
	_spice_image.set_pixel(cell.x, cell.y, Color(float(clamped) / 255.0, 0.0, 0.0))
	_spice_texture.update(_spice_image)
	_request_composite_update()
	spice_changed.emit(cell, previous, clamped)
	return true


func take_spice(cell: Vector2i, requested: int) -> int:
	if requested <= 0:
		return 0
	var available := spice_at(cell)
	var taken := mini(available, requested)
	if taken > 0:
		set_spice(cell, available - taken)
	return taken


func add_spice(cell: Vector2i, amount: int) -> int:
	if amount <= 0 or _cell_index(cell) < 0:
		return 0
	var previous := spice_at(cell)
	var current := mini(previous + amount, 255)
	if current > previous:
		set_spice(cell, current)
	return current - previous


func has_spice_mound(cell: Vector2i) -> bool:
	var index := _cell_index(cell)
	return index >= 0 and _spice_mounds[index] != 0


func set_spice_mound(cell: Vector2i, present: bool) -> bool:
	if _cell_index(cell) < 0:
		return false
	var value := 255 if present else 0
	var rect := _mound_nav_rect(cell)
	var changed := false
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var index := _cell_index(Vector2i(x, y))
			if _spice_mounds[index] == value:
				continue
			_spice_mounds[index] = value
			_spice_mound_image.set_pixel(x, y, Color(float(value) / 255.0, 0.0, 0.0))
			changed = true
	if not changed:
		return true
	_spice_mound_texture.update(_spice_mound_image)
	spice_mound_changed.emit(rect.position, present)
	return true


func spice_mask_texture() -> ImageTexture:
	return _spice_texture


func spice_mound_mask_texture() -> ImageTexture:
	return _spice_mound_texture


func detach_visuals() -> void:
	if is_instance_valid(_composite_viewport):
		_composite_viewport.free()
	_composite_viewport = null


func _load_spice_mounds(source_cells: Array[Vector2i]) -> void:
	if _source_grid_size.x <= 0 or _source_grid_size.y <= 0:
		return
	for source_cell in source_cells:
		if source_cell.x < 0 or source_cell.y < 0 or source_cell.x >= _source_grid_size.x or source_cell.y >= _source_grid_size.y:
			push_warning("MapSpiceLayer: spice mound cell %s is outside source grid %s" % [source_cell, _source_grid_size])
			continue
		var nav_cell := Vector2i(
			int(float(source_cell.x) / float(_source_grid_size.x) * MapNavigationGridScript.NAV_SIZE),
			int(float(source_cell.y) / float(_source_grid_size.y) * MapNavigationGridScript.NAV_SIZE)
		)
		var rect := _mound_nav_rect(nav_cell)
		for y in range(rect.position.y, rect.end.y):
			for x in range(rect.position.x, rect.end.x):
				_spice_mounds[y * MapNavigationGridScript.NAV_SIZE + x] = 255


func _build_textures() -> void:
	var size := MapNavigationGridScript.NAV_SIZE
	_spice_image = Image.create_from_data(size, size, false, Image.FORMAT_R8, _spice_values)
	_spice_mound_image = Image.create_from_data(size, size, false, Image.FORMAT_R8, _spice_mounds)
	_spice_texture = ImageTexture.create_from_image(_spice_image)
	_spice_mound_texture = ImageTexture.create_from_image(_spice_mound_image)


func _bind_terrain_materials(terrain_mesh: MeshInstance3D) -> void:
	if terrain_mesh == null or terrain_mesh.mesh == null:
		return
	_build_composite_viewport(terrain_mesh)
	var pattern_size := Vector2(
		world_bounds.size.x / float(_source_grid_size.x),
		world_bounds.size.z / float(_source_grid_size.y)
	) if _source_grid_size.x > 0 and _source_grid_size.y > 0 else Vector2.ONE
	for surface_index in terrain_mesh.mesh.get_surface_count():
		var source_material := terrain_mesh.mesh.surface_get_material(surface_index) as ShaderMaterial
		if source_material == null or source_material.shader != TERRAIN_SHADER:
			continue
		var material := source_material.duplicate() as ShaderMaterial
		material.set_shader_parameter(&"spice_mound_mask", _spice_mound_texture)
		material.set_shader_parameter(&"spice_field_overlay", _composite_viewport.get_texture())
		material.set_shader_parameter(&"spice_mound_tex", SPICE_MOUND_TEXTURE)
		material.set_shader_parameter(&"spice_world_rect", Vector4(
			world_bounds.position.x,
			world_bounds.position.z,
			world_bounds.size.x,
			world_bounds.size.z
		))
		material.set_shader_parameter(&"spice_pattern_world_size", pattern_size)
		terrain_mesh.set_surface_override_material(surface_index, material)


func _build_composite_viewport(terrain_mesh: MeshInstance3D) -> void:
	_composite_viewport = SubViewport.new()
	_composite_viewport.name = "SpiceCompositeViewport"
	_composite_viewport.size = Vector2i(COMPOSITE_TEXTURE_SIZE, COMPOSITE_TEXTURE_SIZE)
	_composite_viewport.disable_3d = true
	_composite_viewport.transparent_bg = true
	_composite_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	_composite_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	terrain_mesh.add_child(_composite_viewport)

	var composite_material := ShaderMaterial.new()
	composite_material.shader = SPICE_COMPOSITE_SHADER
	composite_material.set_shader_parameter(&"spice_field_mask", _spice_texture)
	composite_material.set_shader_parameter(&"spice_field_tex", SPICE_TEXTURE)
	var composite_rect := ColorRect.new()
	composite_rect.name = "SpiceComposite"
	composite_rect.size = Vector2(COMPOSITE_TEXTURE_SIZE, COMPOSITE_TEXTURE_SIZE)
	composite_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	composite_rect.material = composite_material
	_composite_viewport.add_child(composite_rect)


func _request_composite_update() -> void:
	if is_instance_valid(_composite_viewport):
		_composite_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


func _mound_nav_rect(cell: Vector2i) -> Rect2i:
	if _source_grid_size.x <= 0 or _source_grid_size.y <= 0:
		return Rect2i(cell, Vector2i.ONE)
	var nav_size := MapNavigationGridScript.NAV_SIZE
	var source_cell := Vector2i(
		clampi(int(float(cell.x) / nav_size * _source_grid_size.x), 0, _source_grid_size.x - 1),
		clampi(int(float(cell.y) / nav_size * _source_grid_size.y), 0, _source_grid_size.y - 1)
	)
	var start := Vector2i(
		int(floor(float(source_cell.x) / float(_source_grid_size.x) * nav_size)),
		int(floor(float(source_cell.y) / float(_source_grid_size.y) * nav_size))
	)
	var end := Vector2i(
		int(ceil(float(source_cell.x + 1) / float(_source_grid_size.x) * nav_size)),
		int(ceil(float(source_cell.y + 1) / float(_source_grid_size.y) * nav_size))
	)
	return Rect2i(start, end - start)


func _cell_index(cell: Vector2i) -> int:
	var size := MapNavigationGridScript.NAV_SIZE
	if cell.x < 0 or cell.y < 0 or cell.x >= size or cell.y >= size:
		return -1
	return cell.y * size + cell.x
