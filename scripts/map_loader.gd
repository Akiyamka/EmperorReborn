class_name MapLoader
extends StaticBody3D
## Loads a baked Emperor map folder (test.xbf mesh + test.lit lighting) and
## builds the terrain mesh with collision. One original map cell is 16 XBF
## units; world_scale = 1/16 makes one cell = 1 Godot unit.

@export_dir var map_dir := "res://assets/maps/#M70 Claw Rock"
@export var world_scale := 0.0625
@export var sun_path: NodePath
@export var environment_path: NodePath

const TERRAIN_SHADER := preload("res://scripts/terrain.gdshader")

## texture.dat covers 8192x8192 XBF units (2048 texels x 4 units).
const GROUND_TONE_WORLD_UNITS := 8192.0

## Legacy planet-globe multiply layer, superseded by the test.lit gradient
## colorization of texture.dat. Kept for comparison.
@export var mottle_strength := 0.7
@export var mottle_world_size := 48.0
@export var mottle_full_map := false

var terrain_aabb := AABB()
var _ground_color: ImageTexture
var _lit_direction := Vector3.ZERO
var _lit_colors: Array[Color] = []
var _mottle: Texture2D
var _mottle_mean := Color.WHITE


func _ready() -> void:
	var override := OS.get_environment("EMPEROR_MAP")
	if not override.is_empty():
		map_dir = "res://assets/maps".path_join(override)
	load_map(map_dir)


func load_map(dir: String) -> void:
	var xbf := Xbf.load_file(dir.path_join("test.xbf"))
	if xbf == null:
		return

	for child in get_children():
		child.queue_free()

	_parse_lit(dir.path_join("test.lit"))
	_load_ground_color(dir.path_join("test.CPT"))
	if mottle_full_map:
		_load_mottle(xbf.textures)
	else:
		_mottle = null

	var mesh := xbf.build_mesh()
	terrain_aabb = mesh.get_aabb()
	for surface_index in mesh.get_surface_count():
		var material := _terrain_material(mesh.surface_get_name(surface_index))
		if material is ShaderMaterial:
			var uvs: PackedVector2Array = mesh.surface_get_arrays(surface_index)[Mesh.ARRAY_TEX_UV]
			var bounds := _uv_bounds(uvs)
			material.set_shader_parameter("clamp_u", bounds.position.x >= -0.05 and bounds.end.x <= 1.05)
			material.set_shader_parameter("clamp_v", bounds.position.y >= -0.05 and bounds.end.y <= 1.05)
		mesh.surface_set_material(surface_index, material)

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "TerrainMesh"
	mesh_instance.mesh = mesh
	add_child(mesh_instance)

	var collision := CollisionShape3D.new()
	collision.name = "TerrainCollision"
	collision.shape = mesh.create_trimesh_shape()
	add_child(collision)

	scale = Vector3.ONE * world_scale
	terrain_aabb.position *= world_scale
	terrain_aabb.size *= world_scale

	_apply_lighting()
	print("MapLoader: %s — %d surfaces, %d textures, aabb %s" % [dir, mesh.get_surface_count(), xbf.textures.size(), terrain_aabb])


func map_center() -> Vector3:
	return terrain_aabb.get_center()


func _uv_bounds(uvs: PackedVector2Array) -> Rect2:
	if uvs.is_empty():
		return Rect2()
	var bounds := Rect2(uvs[0], Vector2.ZERO)
	for uv in uvs:
		bounds = bounds.expand(uv)
	return bounds


## test.CPT is the map's baked ground COLOR texture: 8-byte header
## (width, height = 2048) + DXT3 data stored as 256x256 tiles, 8 tiles per
## row. It covers the same virtual 8192x8192 XBF units as texture.dat
## (4 units per texel) and already contains the mottling, detail patches
## and baked shading seen in the original game.
func _load_ground_color(cpt_path: String) -> void:
	_ground_color = null
	var bytes := FileAccess.get_file_as_bytes(cpt_path)
	if bytes.size() != 2048 * 2048 + 8:
		push_warning("MapLoader: no usable test.CPT at %s" % cpt_path)
		return

	# Reorder DXT3 blocks from tile order into a linear 2048-wide image.
	# 16 bytes per 4x4 block; a tile is 64x64 blocks; 8 tiles per row.
	var src := bytes.slice(8)
	var linear := PackedByteArray()
	linear.resize(src.size())
	var dst_offset := 0
	for block_y in 512:
		var tile_row := block_y >> 6
		var row_in_tile := block_y & 63
		for tile_col in 8:
			var src_offset := ((tile_row * 8 + tile_col) * 4096 + row_in_tile * 64) * 16
			for i in 1024:  # 64 blocks x 16 bytes
				linear[dst_offset + i] = src[src_offset + i]
			dst_offset += 1024

	var image := Image.create_from_data(2048, 2048, false, Image.FORMAT_DXT3, linear)
	image.decompress()  # keep it portable (web S3TC support varies)
	_ground_color = ImageTexture.create_from_image(image)


## Picks a low-frequency color layer by looking at the map's texture names.
## Arrakistexture.TGA is actually the Arrakis planet-globe texture from the
## FRONTEND menus, but stretched over the map and multiplied it reproduces
## the original's baked ground palette almost exactly (the real palette
## lives in texture.dat indices whose color table was never found in the
## data files). Giedi Prime maps get nothing — their globe is a night-side
## city texture, unusable for this.
func _load_mottle(texture_names: PackedStringArray) -> void:
	_mottle = null
	for name in texture_names:
		if name.to_lower().begins_with("geidi") or name.to_lower().begins_with("giedi"):
			return
	var path := "res://assets/textures/arrakistexture.png"
	if not ResourceLoader.exists(path):
		return
	_mottle = load(path)
	var image: Image = _mottle.get_image()
	image = image.duplicate()
	image.decompress()
	image.resize(1, 1, Image.INTERPOLATE_LANCZOS)
	_mottle_mean = image.get_pixel(0, 0)


## Theme textures extracted from the game's 3DDATA archives live in
## assets/textures/ as lowercase PNGs. Missing ones fall back to a stable
## placeholder color derived from the texture name.
func _terrain_material(texture_name: String) -> Material:
	var texture_path := "res://assets/textures".path_join(
		texture_name.to_lower().replace(".tga", ".png")
	)
	if not ResourceLoader.exists(texture_path):
		push_warning("MapLoader: no texture %s, using placeholder color" % texture_path)
		var fallback := StandardMaterial3D.new()
		fallback.roughness = 1.0
		fallback.albedo_color = Color.from_hsv(float(texture_name.hash() % 360) / 360.0, 0.3, 0.75)
		return fallback

	if _ground_color == null:
		var plain := StandardMaterial3D.new()
		plain.roughness = 1.0
		plain.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
		plain.albedo_texture = load(texture_path)
		return plain

	var material := ShaderMaterial.new()
	material.shader = TERRAIN_SHADER
	material.set_shader_parameter("albedo_tex", load(texture_path))
	material.set_shader_parameter("ground_color", _ground_color)
	material.set_shader_parameter("ground_world_size", GROUND_TONE_WORLD_UNITS * world_scale)
	if _mottle != null:
		material.set_shader_parameter("mottle_tex", _mottle)
		if mottle_full_map:
			# Raw multiply (mean = white disables normalization), one texture
			# stretched over the map extent — the original's baked light layer.
			material.set_shader_parameter("mottle_mean", Vector3.ONE)
			material.set_shader_parameter("mottle_strength", 1.0)
			material.set_shader_parameter("mottle_world_size",
				maxf(terrain_aabb.size.x, terrain_aabb.size.z) * world_scale)
		else:
			material.set_shader_parameter("mottle_mean", Vector3(_mottle_mean.r, _mottle_mean.g, _mottle_mean.b))
			material.set_shader_parameter("mottle_strength", mottle_strength)
			material.set_shader_parameter("mottle_world_size", mottle_world_size)
	return material


## test.lit: line 1 is the sun direction (pointing at the sun), then RGB
## colors in (dark, bright) pairs: [0]/[1] drive the runtime ambient/sun,
## [2]/[3] are the gradient that colorizes the texture.dat ground mask.
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


func _apply_lighting() -> void:
	var sun := get_node_or_null(sun_path) as DirectionalLight3D
	if sun != null and _lit_direction != Vector3.ZERO:
		var direction := _lit_direction
		direction.z = -direction.z  # same D3D->Godot Z mirror as the mesh
		sun.global_transform = Transform3D.IDENTITY.looking_at(-direction.normalized())
		# The CPT ground texture already carries the planet's color grading,
		# so the runtime lights are desaturated (luminance preserved) to
		# avoid tinting twice.
		if _lit_colors.size() >= 2:
			sun.light_color = _desaturated(_lit_colors[1], 1.0)
		sun.light_energy = 1.0

	var world_environment := get_node_or_null(environment_path) as WorldEnvironment
	if world_environment != null and _lit_colors.size() >= 1:
		world_environment.environment.ambient_light_color = _desaturated(_lit_colors[0], 1.0)
		world_environment.environment.ambient_light_energy = 1.0


func _desaturated(color: Color, keep_saturation: float) -> Color:
	var luminance := color.r * 0.299 + color.g * 0.587 + color.b * 0.114
	return Color(luminance, luminance, luminance).lerp(color, keep_saturation)
