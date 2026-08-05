class_name MapSpiceRender
extends RefCounted

## What the spice field looks like: two R8 masks the terrain shader samples,
## and the offscreen pass that composites the spice artwork through the field
## mask before the terrain reads it.
##
## The masks are write-only mirrors of the layer's byte grids -- the layer
## decides what a cell holds, this decides how it is drawn -- so writes come in
## per cell and the upload is a separate flush. A ring of a spreading bloom
## touches dozens of cells at once and must not re-upload a 512x512 texture per
## cell.
##
## Owns the composite SubViewport it parents under the terrain mesh, so it
## follows the detach protocol: detach() is idempotent.

const TERRAIN_SHADER := preload("res://scripts/world/map/terrain.gdshader")
const SPICE_COMPOSITE_SHADER := preload("res://scripts/world/map/spice_composite.gdshader")
const SPICE_TEXTURE := preload("res://assets/raw_original_content/3DDATA/Textures/spicetga_32.tga")
const MapNavigationGridScript := preload("res://scripts/world/map/map_navigation_grid.gd")

const COMPOSITE_TEXTURE_SIZE := 1024

var _spice_image: Image
var _mound_image: Image
var _spice_texture: ImageTexture
var _mound_texture: ImageTexture
var _composite_viewport: SubViewport


## Snapshots both byte grids into masks. The images are copies from here on:
## every later change arrives through set_spice_cell()/set_mound_cell().
func build(spice_values: PackedByteArray, mound_values: PackedByteArray) -> void:
	var size := MapNavigationGridScript.NAV_SIZE
	_spice_image = Image.create_from_data(size, size, false, Image.FORMAT_R8, spice_values)
	_mound_image = Image.create_from_data(size, size, false, Image.FORMAT_R8, mound_values)
	_spice_texture = ImageTexture.create_from_image(_spice_image)
	_mound_texture = ImageTexture.create_from_image(_mound_image)


func spice_mask_texture() -> ImageTexture:
	return _spice_texture


func mound_mask_texture() -> ImageTexture:
	return _mound_texture


func set_spice_cell(cell: Vector2i, value: int) -> void:
	_spice_image.set_pixel(cell.x, cell.y, Color(float(value) / 255.0, 0.0, 0.0))


## Uploads whatever set_spice_cell() has accumulated and asks the composite for
## a fresh frame.
func flush_spice() -> void:
	_spice_texture.update(_spice_image)
	request_composite_update()


func set_mound_cell(cell: Vector2i, value: int) -> void:
	_mound_image.set_pixel(cell.x, cell.y, Color(float(value) / 255.0, 0.0, 0.0))


## No composite refresh: the mound mask is read by the terrain shader directly
## and is not part of the composited spice field.
func flush_mounds() -> void:
	_mound_texture.update(_mound_image)


## Points every terrain surface using the terrain shader at this field's
## composite, on a duplicated material so the shared mesh resource is left
## alone. Surfaces on another shader are not spice-bearing and are skipped.
func bind_terrain_materials(terrain_mesh: MeshInstance3D, world_bounds: AABB) -> void:
	if terrain_mesh == null or terrain_mesh.mesh == null:
		return
	_build_composite_viewport(terrain_mesh)
	for surface_index in terrain_mesh.mesh.get_surface_count():
		var source_material := terrain_mesh.mesh.surface_get_material(surface_index) as ShaderMaterial
		if source_material == null or source_material.shader != TERRAIN_SHADER:
			continue
		var material := source_material.duplicate() as ShaderMaterial
		material.set_shader_parameter(&"spice_field_overlay", _composite_viewport.get_texture())
		material.set_shader_parameter(&"spice_world_rect", Vector4(
			world_bounds.position.x,
			world_bounds.position.z,
			world_bounds.size.x,
			world_bounds.size.z
		))
		terrain_mesh.set_surface_override_material(surface_index, material)


## The composite renders once per request rather than continuously: the spice
## field only changes when a cell does.
func request_composite_update() -> void:
	if is_instance_valid(_composite_viewport):
		_composite_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


func detach() -> void:
	if is_instance_valid(_composite_viewport):
		_composite_viewport.free()
	_composite_viewport = null


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
