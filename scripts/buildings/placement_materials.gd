class_name PlacementMaterials
extends RefCounted

const EMISSION_ENERGY := 1.8
static var _transparent_texture_cache: Dictionary = {}


static func configure_arrow(node: Node) -> void:
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_restore_arrow_fill_materials(mesh_instance)
	for child in node.get_children():
		configure_arrow(child)


static func configure_preview(node: Node) -> void:
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_configure_preview_materials(mesh_instance)
	for child in node.get_children():
		configure_preview(child)


static func _restore_arrow_fill_materials(mesh_instance: MeshInstance3D) -> void:
	if mesh_instance.mesh == null:
		return
	for surface_index in mesh_instance.mesh.get_surface_count():
		var material := _surface_material(mesh_instance, surface_index)
		var surface_name := String(mesh_instance.mesh.surface_get_name(surface_index)).to_lower()
		if surface_name == "white.tga" or _is_fully_transparent(material):
			mesh_instance.set_surface_override_material(surface_index, _opaque_fill_material())
		elif material == null:
			mesh_instance.set_surface_override_material(surface_index, _fallback_material())


static func _configure_preview_materials(mesh_instance: MeshInstance3D) -> void:
	if mesh_instance.mesh == null:
		return
	var source: Material
	if mesh_instance.mesh.get_surface_count() > 0:
		source = _surface_material(mesh_instance, 0)
	var preview := _blend_material(source)
	mesh_instance.material_override = preview if preview != null else _fallback_material()


static func _surface_material(mesh_instance: MeshInstance3D, index: int) -> Material:
	var override := mesh_instance.get_surface_override_material(index)
	return override if override != null else mesh_instance.mesh.surface_get_material(index)


static func _is_fully_transparent(material: Material) -> bool:
	if not material is BaseMaterial3D:
		return false
	var texture := (material as BaseMaterial3D).albedo_texture
	if texture == null:
		return false
	var key := texture.get_rid()
	if _transparent_texture_cache.has(key):
		return bool(_transparent_texture_cache[key])
	var image := texture.get_image()
	var transparent := image != null
	if image != null:
		for y in image.get_height():
			for x in image.get_width():
				if image.get_pixel(x, y).a > 0.0:
					transparent = false
					break
			if not transparent:
				break
	_transparent_texture_cache[key] = transparent
	return transparent


static func _blend_material(source: Material) -> Material:
	if source == null:
		return null
	var material := source.duplicate() as Material
	if material is BaseMaterial3D:
		var base := material as BaseMaterial3D
		base.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		base.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		base.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		base.disable_receive_shadows = true
		base.emission_enabled = true
		base.emission = base.albedo_color
		base.emission_energy_multiplier = EMISSION_ENERGY
		if base.albedo_texture != null:
			base.emission_texture = base.albedo_texture
	return material


static func _opaque_fill_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color.WHITE
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.disable_receive_shadows = true
	material.emission_enabled = true
	material.emission = Color.WHITE
	material.emission_energy_multiplier = EMISSION_ENERGY
	return material


static func _fallback_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(1.0, 1.0, 1.0, 0.45)
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.disable_receive_shadows = true
	material.emission_enabled = true
	material.emission = Color.WHITE
	material.emission_energy_multiplier = EMISSION_ENERGY
	return material
