class_name MapBakeBuilder
extends RefCounted

const TERRAIN_SHADER := preload("res://scripts/world/map/terrain.gdshader")
const BakedMapDataScript := preload("res://scripts/world/map/baked_map_data.gd")
const MapLoaderScript := preload("res://scripts/world/map/map_loader.gd")
const MapNavigationGridBuilderScript := preload("res://converters/map_navigation_grid_builder.gd")
const MapXbfScript := preload("res://converters/xbf/map_xbf.gd")
const TextureImageUtilsScript := preload("res://converters/texture_image_utils.gd")

const GROUND_TONE_WORLD_UNITS := 8192.0
const GROUND_LIGHT_SIZE := 2048
const TERRAIN_TEXTURE_DIR := "res://assets/raw_original_content/3DDATA/Textures"

var world_scale := 0.0625
var ground_strength := 0.70
var tone_alpha_gain := 1.40
var ground_light_strength := 0.80
var ground_light_scale := 0.60
var terrain_direct_light_strength := 0.50
var mottle_strength := 0.7
var mottle_world_size := 48.0
var mottle_full_map := false

var _ground_color: ImageTexture
var _ground_light: ImageTexture
var _lit_direction := Vector3.ZERO
var _lit_colors: Array[Color] = []
var _mottle: Texture2D
var _mottle_mean := Color.WHITE
var _terrain_aabb := AABB()
var _terrain_texture_cache := {}
var terrain_scene: PackedScene


func build(dir: String) -> Resource:
	terrain_scene = null
	_terrain_texture_cache.clear()
	var xbf_path := _first_existing_map_path(dir, ["test.xbf", "debug.xbf"])
	if xbf_path.is_empty():
		push_error("MapBakeBuilder: no XBF file found in %s" % dir)
		return null

	var xbf = MapXbfScript.load_file(xbf_path)
	if xbf == null:
		return null

	_parse_lit(dir.path_join("test.lit"))
	_load_ground_color(dir.path_join("test.CPT"))
	_load_ground_light(dir.path_join("texture.dat"))
	if mottle_full_map:
		_load_mottle(xbf.textures)
	else:
		_mottle = null

	var mesh: ArrayMesh = xbf.build_mesh()
	_terrain_aabb = mesh.get_aabb()
	for surface_index in mesh.get_surface_count():
		var material := _terrain_material(mesh.surface_get_name(surface_index))
		if material is ShaderMaterial:
			var uvs: PackedVector2Array = mesh.surface_get_arrays(surface_index)[Mesh.ARRAY_TEX_UV]
			var bounds := _uv_bounds(uvs)
			material.set_shader_parameter("clamp_u", bounds.position.x >= -0.05 and bounds.end.x <= 1.05)
			material.set_shader_parameter("clamp_v", bounds.position.y >= -0.05 and bounds.end.y <= 1.05)
		mesh.surface_set_material(surface_index, material)

	var scaled_aabb := _terrain_aabb
	scaled_aabb.position *= world_scale
	scaled_aabb.size *= world_scale
	terrain_scene = _build_terrain_scene(mesh, mesh.create_trimesh_shape())
	if terrain_scene == null:
		return null

	var nav = MapNavigationGridBuilderScript.new().build(dir, scaled_aabb, xbf, world_scale)
	if nav == null or not nav.is_loaded():
		push_error("MapBakeBuilder: could not build a valid navigation grid for %s" % dir)
		return null

	var data: Resource = BakedMapDataScript.new()
	data.source_map_dir = dir
	data.source_xbf = xbf_path
	data.world_scale = world_scale
	data.terrain_aabb = scaled_aabb
	data.lit_direction = _lit_direction
	data.lit_colors = _lit_colors
	data.map_size = xbf.map_size
	data.texture_count = xbf.textures.size()
	data.surface_count = mesh.get_surface_count()
	data.spice_mound_cells.assign(xbf.spice_mounds)
	if xbf.has_tlv_meta():
		data.xbf_summary = "meta_end=%d, %s" % [xbf.meta_end, xbf.logical_layer_summary()]

	data.nav_world_bounds = nav.world_bounds
	data.nav_cpf_values = nav.cpf_values
	data.nav_terrain_type = nav.terrain_type
	data.nav_source_tile_x = nav.source_tile_x
	data.nav_source_tile_y = nav.source_tile_y
	data.nav_spice_value = nav.spice_value
	data.nav_pass_mask = nav.pass_mask
	data.nav_movement_cost = nav.movement_cost
	data.nav_buildable = nav.buildable
	data.nav_cpf_report = nav.cpf_report
	data.nav_report = nav.nav_report

	return data


func _build_terrain_scene(mesh: ArrayMesh, collision_shape: Shape3D, map_data_path := "") -> PackedScene:
	var body := StaticBody3D.new()
	body.name = "Terrain"
	body.set_script(MapLoaderScript)
	body.map_data_path = map_data_path
	body.sun_path = NodePath("../Sun")
	body.environment_path = NodePath("../WorldEnvironment")
	body.scale = Vector3.ONE * world_scale

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "TerrainMesh"
	mesh_instance.mesh = mesh
	# texture.dat already contains the authored terrain relief shadows. Prevent
	# the terrain from casting a second, slightly offset copy of those shadows;
	# it still receives runtime shadows cast by units and buildings.
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	body.add_child(mesh_instance)
	mesh_instance.owner = body

	var collision := CollisionShape3D.new()
	collision.name = "TerrainCollision"
	collision.shape = collision_shape
	body.add_child(collision)
	collision.owner = body

	var scene := PackedScene.new()
	var err := scene.pack(body)
	body.free()
	if err != OK:
		push_error("MapBakeBuilder: could not pack terrain scene (%s)" % error_string(err))
		return null
	return scene


func set_terrain_scene_map_data_path(map_data_path: String) -> PackedScene:
	if terrain_scene == null:
		return null
	var root := terrain_scene.instantiate()
	root.map_data_path = map_data_path
	var scene := PackedScene.new()
	var err := scene.pack(root)
	root.free()
	if err != OK:
		push_error("MapBakeBuilder: could not repack terrain scene (%s)" % error_string(err))
		return null
	terrain_scene = scene
	return terrain_scene


func _uv_bounds(uvs: PackedVector2Array) -> Rect2:
	if uvs.is_empty():
		return Rect2()
	var bounds := Rect2(uvs[0], Vector2.ZERO)
	for uv in uvs:
		bounds = bounds.expand(uv)
	return bounds


func _load_ground_color(cpt_path: String) -> void:
	_ground_color = null
	var bytes := FileAccess.get_file_as_bytes(cpt_path)
	if bytes.size() != 2048 * 2048 + 8:
		push_warning("MapBakeBuilder: no usable test.CPT at %s" % cpt_path)
		return

	var src := bytes.slice(8)
	var linear := PackedByteArray()
	linear.resize(src.size())
	var dst_offset := 0
	for block_y in 512:
		var tile_row := block_y >> 6
		var row_in_tile := block_y & 63
		for tile_col in 8:
			var src_offset := ((tile_row * 8 + tile_col) * 4096 + row_in_tile * 64) * 16
			for i in 1024:
				linear[dst_offset + i] = src[src_offset + i]
			dst_offset += 1024

	var image := Image.create_from_data(2048, 2048, false, Image.FORMAT_DXT3, linear)
	image.decompress()
	_ground_color = ImageTexture.create_from_image(image)


func _load_ground_light(path: String) -> void:
	_ground_light = null
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.size() != GROUND_LIGHT_SIZE * GROUND_LIGHT_SIZE:
		push_warning("MapBakeBuilder: no usable 2048x2048 texture.dat at %s" % path)
		return
	var image := Image.create_from_data(
		GROUND_LIGHT_SIZE,
		GROUND_LIGHT_SIZE,
		false,
		Image.FORMAT_L8,
		bytes
	)
	_ground_light = ImageTexture.create_from_image(image)


func _load_mottle(texture_names: PackedStringArray) -> void:
	_mottle = null
	for name in texture_names:
		if name.to_lower().begins_with("geidi") or name.to_lower().begins_with("giedi"):
			return
	var path := _find_terrain_texture_path("arrakistexture.tga")
	if path.is_empty():
		return
	_mottle = load(path)
	var image: Image = _mottle.get_image()
	image = image.duplicate()
	image.decompress()
	image.resize(1, 1, Image.INTERPOLATE_LANCZOS)
	_mottle_mean = image.get_pixel(0, 0)


func _terrain_material(texture_name: String) -> Material:
	var texture_path := _find_terrain_texture_path(texture_name.get_file())
	if texture_path.is_empty():
		push_warning("MapBakeBuilder: no texture %s in %s, using placeholder color" % [texture_name, TERRAIN_TEXTURE_DIR])
		var fallback := StandardMaterial3D.new()
		fallback.roughness = 1.0
		fallback.albedo_color = Color.from_hsv(float(texture_name.hash() % 360) / 360.0, 0.3, 0.75)
		return fallback
	var loaded_texture := _load_terrain_texture(texture_path)
	var texture: Texture2D = loaded_texture.get("texture")
	var use_alpha_cutout := bool(loaded_texture.get("use_alpha_cutout", false))
	if texture == null:
		push_warning("MapBakeBuilder: could not load texture %s, using placeholder color" % texture_path)
		var fallback := StandardMaterial3D.new()
		fallback.roughness = 1.0
		fallback.albedo_color = Color.from_hsv(float(texture_name.hash() % 360) / 360.0, 0.3, 0.75)
		return fallback

	if _ground_color == null and _ground_light == null:
		var plain := StandardMaterial3D.new()
		plain.roughness = 1.0
		plain.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
		plain.albedo_texture = texture
		if use_alpha_cutout:
			plain.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
			plain.alpha_scissor_threshold = 0.5
		return plain

	var material := ShaderMaterial.new()
	material.shader = TERRAIN_SHADER
	material.set_shader_parameter("albedo_tex", texture)
	material.set_shader_parameter("use_alpha_cutout", use_alpha_cutout)
	if _ground_color != null:
		material.set_shader_parameter("ground_color", _ground_color)
		material.set_shader_parameter("ground_strength", ground_strength)
		material.set_shader_parameter("tone_alpha_gain", tone_alpha_gain)
	if _ground_light != null:
		material.set_shader_parameter("ground_light", _ground_light)
		material.set_shader_parameter("ground_light_strength", ground_light_strength)
		material.set_shader_parameter("ground_light_scale", ground_light_scale)
	material.set_shader_parameter("terrain_direct_light_strength", terrain_direct_light_strength)
	material.set_shader_parameter("ground_world_size", GROUND_TONE_WORLD_UNITS * world_scale)
	if _mottle != null:
		material.set_shader_parameter("mottle_tex", _mottle)
		if mottle_full_map:
			material.set_shader_parameter("mottle_mean", Vector3.ONE)
			material.set_shader_parameter("mottle_strength", 1.0)
			material.set_shader_parameter("mottle_world_size",
				maxf(_terrain_aabb.size.x, _terrain_aabb.size.z) * world_scale)
		else:
			material.set_shader_parameter("mottle_mean", Vector3(_mottle_mean.r, _mottle_mean.g, _mottle_mean.b))
			material.set_shader_parameter("mottle_strength", mottle_strength)
			material.set_shader_parameter("mottle_world_size", mottle_world_size)
	return material


func _load_terrain_texture(path: String) -> Dictionary:
	if _terrain_texture_cache.has(path):
		return _terrain_texture_cache[path]

	var image: Image = TextureImageUtilsScript.load_image(path)
	if image == null:
		var failed := {"texture": null, "use_alpha_cutout": false}
		_terrain_texture_cache[path] = failed
		return failed

	var use_alpha_cutout := TextureImageUtilsScript.apply_magenta_to_alpha(image)
	var texture: Texture2D
	if use_alpha_cutout:
		image.generate_mipmaps()
		texture = ImageTexture.create_from_image(image)
	else:
		texture = load(path)
	var loaded := {"texture": texture, "use_alpha_cutout": use_alpha_cutout}
	_terrain_texture_cache[path] = loaded
	return loaded


func _find_terrain_texture_path(file_name: String) -> String:
	if file_name.is_empty():
		return ""

	var wanted := file_name.get_file()
	if wanted.get_extension().is_empty():
		wanted += ".tga"

	var direct_path := TERRAIN_TEXTURE_DIR.path_join(wanted)
	if ResourceLoader.exists(direct_path) or FileAccess.file_exists(direct_path):
		return direct_path

	var expected := wanted.to_lower()
	var dir := DirAccess.open(TERRAIN_TEXTURE_DIR)
	if dir == null:
		return ""

	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		if not dir.current_is_dir() and entry.to_lower() == expected:
			dir.list_dir_end()
			return TERRAIN_TEXTURE_DIR.path_join(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	return ""


func _parse_lit(lit_path: String) -> void:
	_lit_direction = Vector3.ZERO
	_lit_colors = []
	var text := FileAccess.get_file_as_string(lit_path)
	if text.is_empty():
		return
	for line in text.split("\n", false):
		var parts := line.split_floats(" ", false)
		if parts.size() < 3:
			continue
		if _lit_direction == Vector3.ZERO and _lit_colors.is_empty():
			_lit_direction = Vector3(parts[0], parts[1], parts[2])
		else:
			_lit_colors.append(Color8(int(parts[0]), int(parts[1]), int(parts[2])))


func _first_existing_map_path(dir: String, names: Array[String]) -> String:
	for file_name in names:
		var path := dir.path_join(file_name)
		if FileAccess.file_exists(path):
			return path
	return ""
