class_name ModelBakeBuilder
extends RefCounted

const ModelXbfScript := preload("res://converters/xbf/model_xbf.gd")

# Effect submeshes the original game toggles from gameplay code rather than
# from the baked animation: the leech parasite overlay and the energy shield
# (Unit shows it while `shields` > 0). They are baked hidden; gameplay code
# flips `visible` on the matching "Mesh" instance when the effect applies.
# Other FX (flashes, lightning, ...) are already driven by the animation
# tracks and must stay visible.
const EFFECT_NAME_MARKERS: PackedStringArray = ["leech", "shield"]
const COLLISION_OBJECT_NAME := "#~~0"
const MODEL_TEXTURE_DIR := "res://assets/raw_original_content/3DDATA/Textures"

var source_texture_dir := MODEL_TEXTURE_DIR
var texture_output_dir := ""
var fps := 20.0
var world_scale := 0.0625

# Frame rate of the baked animated-texture sequences (frames of the atlas
# advanced per second by the fx_frame animation tracks).
const TEXTURE_FX_FPS := 4.0
const MIN_ANIMATION_AXIS_SCALE := 0.0001
const TEXTURE_PREFIX_MARKERS := "=@!%&"
const SUPPRESSED_MISSING_TEXTURES := {
	"at_wt_front64.tga": true,
}

var missing_textures: PackedStringArray = []
var copied_textures: PackedStringArray = []
var _material_cache := {}
var _animated_texture_sequences := {}
var _animated_material_frames := {}
var _scrolling_materials := {}
var _pending_frame_tracks: Array[Dictionary] = []
var _animated_frame_shader_add: Shader
var _animated_frame_shader_mix: Shader
var _model_texture_shaders := {}
var _scrolling_texture_shaders := {}
var _shield_shader: Shader
var _has_shield_fx_marker := false


func build(xbf_path: String) -> PackedScene:
	missing_textures = PackedStringArray()
	copied_textures = PackedStringArray()
	_material_cache.clear()
	_animated_texture_sequences.clear()
	_animated_material_frames.clear()
	_scrolling_materials.clear()
	_pending_frame_tracks.clear()
	_model_texture_shaders.clear()
	_scrolling_texture_shaders.clear()
	_has_shield_fx_marker = false

	var xbf = ModelXbfScript.load_file(xbf_path)
	if xbf == null:
		return null
	_prepare_animated_texture_sequences(xbf.fx_strings)

	var root := Node3D.new()
	root.name = _scene_name_from_path(xbf_path)
	root.scale = Vector3.ONE * world_scale

	var anim := Animation.new()
	anim.resource_name = "idle"
	anim.loop_mode = Animation.LOOP_LINEAR
	var max_frame := 1

	for object in xbf.objects:
		var child := _build_object_node(object, xbf.textures, ".", anim)
		root.add_child(child)
		max_frame = maxi(max_frame, _object_animation_length(object))

	# Build the library even when nothing produced a track: the FX table can
	# still declare a named entry (e.g. H3's "Explode", 50 frames) purely as a
	# duration/timing cue with no baked per-object motion, and dropping the
	# AnimationPlayer here would silently throw that duration away, collapsing
	# the state to ~1 frame downstream in BuildingBakeBuilder.
	if anim.get_track_count() > 0 or not _pending_frame_tracks.is_empty() or not xbf.animation_entries.is_empty():
		anim.length = maxf(max_frame / fps, 1.0 / fps)
		_add_shader_fx_tracks(anim)
		var library := AnimationLibrary.new()
		library.add_animation("timeline", anim)
		for entry: Dictionary in xbf.animation_entries:
			var clip := _slice_animation(anim, entry)
			if clip != null:
				library.add_animation(_clip_name(String(entry["name"])), clip)
		var player := AnimationPlayer.new()
		player.name = "AnimationPlayer"
		player.add_animation_library("", library)
		player.autoplay = "Stationary" if library.has_animation("Stationary") else "timeline"
		root.add_child(player)

	_assign_scene_owner(root, root)

	var scene := PackedScene.new()
	var err := scene.pack(root)
	root.free()
	if err != OK:
		push_error("ModelBakeBuilder: could not pack model scene (%s)" % error_string(err))
		return null
	return scene


func _build_object_node(object: Dictionary, texture_names: PackedStringArray, node_path: String, anim: Animation) -> Node3D:
	var node := Node3D.new()
	var raw_name := String(object.name)
	node.name = _safe_node_name(raw_name)
	node.set_meta("original_name", raw_name)
	if raw_name == COLLISION_OBJECT_NAME:
		node.set_meta("collision_mesh", true)
		# #~~0 is the root of the authored collision hierarchy. It commonly has
		# no vertices itself: its child objects contain the actual volume.
		node.set_meta("collision_points", _collision_points_from_hierarchy(object))
	node.transform = _to_godot_transform(object.transform)
	# Selection volumes and halo anchors are authored as vertex-only XBF
	# objects.  They have no triangles, so no MeshInstance3D is generated for
	# them; retain the data as metadata for gameplay visuals instead.
	if raw_name.to_lower().begins_with("slct"):
		node.set_meta("selection_bounds", _object_bounds(object.positions))
		# A few source models have no #~~0 root. Their SLCT object is still an
		# authored selection/collision volume, and is the runtime fallback.
		node.set_meta("collision_points", _collision_points(object.positions))
	elif raw_name == "#^^0":
		node.set_meta("halo_anchor", true)
		node.set_meta("halo_anchor_bounds", _object_bounds(object.positions))
	var child_path: String = "%s/%s" % [node_path, node.name] if node_path != "." else node.name
	_add_animation_track(anim, child_path, object)

	var mesh := _build_object_mesh(object, texture_names)
	if mesh.get_surface_count() > 0:
		var mesh_instance := MeshInstance3D.new()
		mesh_instance.name = "Mesh"
		mesh_instance.mesh = mesh
		# #~~0 is an authored collision volume, not visible model geometry.
		# Keep its mesh in the converted scene so Unit and Building can make
		# the matching physics shape at runtime.
		mesh_instance.visible = not (_is_effect_object(raw_name) or raw_name == COLLISION_OBJECT_NAME)
		if raw_name == COLLISION_OBJECT_NAME:
			mesh_instance.set_meta("collision_mesh", true)
		node.add_child(mesh_instance)
		_add_vertex_animation_track(anim, "%s/Mesh" % child_path, object, texture_names)
		var atlas_frames := _mesh_animated_frame_count(mesh)
		if atlas_frames > 1:
			_pending_frame_tracks.append({"path": "%s/Mesh" % child_path, "frames": atlas_frames})
		if _mesh_has_scrolling_texture(mesh):
			# A scrolling UV phase has to keep advancing continuously while the
			# model is on screen; a baked animation track would snap back to 0
			# every time the (often sub-second) clip loops. So we only tag the
			# mesh here (as metadata - PackedScene.pack() does not persist
			# set_instance_shader_parameter overrides) and let the owning
			# Unit/Building drive fx_time every frame at runtime (mirrors
			# the energy-shield fx_time driver). Mirrored parts sharing one
			# scrolling texture (the two front spotlights, the two wind
			# blades) don't need an artificial direction flip here: their
			# source vertex positions are already authored as true mirror
			# images of each other, so one shared, uniform scroll direction
			# converges/diverges on its own from that geometry.
			mesh_instance.set_meta("scroll_fx", true)

	for child_object: Dictionary in object.children:
		var child := _build_object_node(child_object, texture_names, child_path, anim)
		node.add_child(child)

	return node


func _object_bounds(positions: PackedVector3Array) -> AABB:
	if positions.is_empty():
		return AABB()
	var bounds := AABB(positions[0], Vector3.ZERO)
	for point in positions:
		bounds = bounds.expand(point)
	return bounds


func _collision_points(positions: PackedVector3Array) -> PackedVector3Array:
	var result := PackedVector3Array()
	for point in positions:
		result.append(Vector3(point.x, point.y, -point.z))
	return result


func _collision_points_from_hierarchy(root_object: Dictionary) -> PackedVector3Array:
	var result := _collision_points(root_object.positions)
	for child: Dictionary in root_object.children:
		_append_collision_points(child, Transform3D.IDENTITY, result)
	return result


func _append_collision_points(object: Dictionary, parent_transform: Transform3D, result: PackedVector3Array) -> void:
	var transform: Transform3D = parent_transform * object.transform
	for point in object.positions:
		var transformed: Vector3 = transform * point
		result.append(Vector3(transformed.x, transformed.y, -transformed.z))
	for child: Dictionary in object.children:
		_append_collision_points(child, transform, result)


func _assign_scene_owner(node: Node, scene_root: Node) -> void:
	for child in node.get_children():
		child.owner = scene_root
		_assign_scene_owner(child, scene_root)


func _build_object_mesh(object: Dictionary, texture_names: PackedStringArray, animated_positions := PackedVector3Array()) -> ArrayMesh:
	var surfaces := {}
	var positions: PackedVector3Array = animated_positions if not animated_positions.is_empty() else object.positions
	var normals: PackedVector3Array = object.normals
	var indices: PackedInt32Array = object.triangle_indices
	var triangle_textures: PackedInt32Array = object.triangle_textures
	var uvs: PackedVector2Array = object.triangle_uvs

	for i in triangle_textures.size():
		var texture_index := triangle_textures[i]
		if texture_index == -1:
			continue
		if not surfaces.has(texture_index):
			surfaces[texture_index] = {
				"positions": PackedVector3Array(),
				"normals": PackedVector3Array(),
				"uvs": PackedVector2Array(),
				"indices": PackedInt32Array(),
				"corner_lookup": {},
			}
		var surface: Dictionary = surfaces[texture_index]
		for corner in 3:
			var vertex_index := indices[i * 3 + corner]
			var uv: Vector2 = uvs[i * 3 + corner]
			# Deduplicate corners sharing the same source vertex and UV so the
			# surface is indexed. The key must not depend on position, so the
			# layout stays identical across vertex animation frames.
			var corner_key := [vertex_index, uv]
			var lookup: Dictionary = surface.corner_lookup
			var packed_index: int = lookup.get(corner_key, -1)
			if packed_index == -1:
				packed_index = surface.positions.size()
				lookup[corner_key] = packed_index
				var position: Vector3 = positions[vertex_index]
				position.z = -position.z
				var normal: Vector3 = normals[vertex_index]
				normal.z = -normal.z
				surface.positions.append(position)
				surface.normals.append(normal.normalized())
				surface.uvs.append(uv)
			surface.indices.append(packed_index)

	var mesh := ArrayMesh.new()
	var texture_indices := surfaces.keys()
	texture_indices.sort()
	for texture_index: int in texture_indices:
		var surface: Dictionary = surfaces[texture_index]
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = surface.positions
		arrays[Mesh.ARRAY_NORMAL] = surface.normals
		arrays[Mesh.ARRAY_TEX_UV] = surface.uvs
		arrays[Mesh.ARRAY_INDEX] = surface.indices
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var surface_index := mesh.get_surface_count() - 1
		var texture_name := texture_names[texture_index] if texture_index < texture_names.size() else ""
		mesh.surface_set_name(surface_index, texture_name)
		mesh.surface_set_material(surface_index, _model_material(texture_name))
	return mesh


func _model_material(texture_name: String) -> Material:
	if _material_cache.has(texture_name):
		return _material_cache[texture_name]

	var texture_path := _ensure_model_texture(texture_name)
	var texture: Texture2D = null
	var animated_frames := _animated_texture_frames(texture_name)
	var additive := _is_additive_texture(texture_name)
	var team_colored := _uses_team_color(texture_name)
	if not animated_frames.is_empty():
		var animated_texture := _load_animated_texture_atlas(animated_frames)
		if animated_texture != null:
			var animated_material := ShaderMaterial.new()
			animated_material.shader = _animated_frame_shader(additive)
			animated_material.set_shader_parameter("albedo_atlas", animated_texture)
			animated_material.set_shader_parameter("frame_count", float(animated_frames.size()))
			animated_material.set_shader_parameter("use_team_color", team_colored)
			_animated_material_frames[animated_material] = animated_frames.size()
			_material_cache[texture_name] = animated_material
			return animated_material
	if not texture_path.is_empty():
		texture = _load_png_texture(texture_path)
	if _is_animated_shield_texture(texture_name) and texture != null:
		var shield_material := ShaderMaterial.new()
		shield_material.shader = _animated_shield_shader()
		shield_material.set_shader_parameter("albedo_tex", texture)
		shield_material.set_shader_parameter("use_team_color", team_colored)
		# Not added to _scrolling_materials: Unit already drives the
		# shield's fx_time by name match (and only while shields are up), so
		# tagging it here too would double-write the same parameter.
		_material_cache[texture_name] = shield_material
		return shield_material
	if _is_scrolling_texture(texture_name) and texture != null:
		var scrolling_material := ShaderMaterial.new()
		scrolling_material.shader = _scrolling_texture_shader(additive)
		scrolling_material.set_shader_parameter("albedo_tex", texture)
		scrolling_material.set_shader_parameter("use_team_color", team_colored)
		_scrolling_materials[scrolling_material] = true
		_material_cache[texture_name] = scrolling_material
		return scrolling_material
	if team_colored and texture != null:
		var team_material := ShaderMaterial.new()
		team_material.shader = _model_texture_shader(additive, _uses_alpha_channel(texture_name), _texture_has_alpha(texture))
		team_material.set_shader_parameter("albedo_tex", texture)
		team_material.set_shader_parameter("use_team_color", true)
		_material_cache[texture_name] = team_material
		return team_material

	var material := StandardMaterial3D.new()
	material.roughness = 0.85
	material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	if additive:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	elif _uses_alpha_channel(texture_name) and _texture_has_alpha(texture):
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
	elif _texture_has_alpha(texture):
		# Magenta colour key is a 1-bit mask in the original TGA loader.
		# Alpha scissor keeps these textures in the opaque pass.
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		material.alpha_scissor_threshold = 0.5

	if texture != null:
		material.albedo_texture = texture
	else:
		material.albedo_color = Color.from_hsv(float(texture_name.hash() % 360) / 360.0, 0.45, 0.85)
	_material_cache[texture_name] = material
	return material


func _prepare_animated_texture_sequences(fx_strings: Array[Dictionary]) -> void:
	var groups := {}
	var group_bases := {}
	for record: Dictionary in fx_strings:
		var value := String(record.get("value", ""))
		if value.contains("{SHIELD}"):
			_has_shield_fx_marker = true
		var file_name := value.get_file()
		if not file_name.to_lower().ends_with(".tga"):
			continue
		for digit_range: Vector2i in _digit_ranges(file_name):
			var prefix := file_name.substr(0, digit_range.x)
			var suffix := file_name.substr(digit_range.y)
			if prefix.is_empty() or suffix.is_empty():
				continue
			var key := "%s#%s" % [_texture_sequence_key(prefix), _texture_sequence_key(suffix)]
			if not groups.has(key):
				groups[key] = {}
				group_bases[key] = "%s%s" % [prefix, suffix]
			var frame_number := int(file_name.substr(digit_range.x, digit_range.y - digit_range.x))
			groups[key][frame_number] = file_name

	for key in groups.keys():
		var group: Dictionary = groups[key]
		var frame_numbers: Array = group.keys()
		frame_numbers.sort()
		if frame_numbers.size() < 1:
			continue
		var first_frame := int(frame_numbers[0])
		var last_frame := int(frame_numbers[-1])
		if last_frame - first_frame + 1 != frame_numbers.size():
			continue

		var frames := PackedStringArray()
		if first_frame == 1:
			var base_name := String(group_bases[key])
			if _fx_texture_name_exists(base_name, fx_strings):
				frames.append(base_name)
		for frame_number in frame_numbers:
			frames.append(String(group[frame_number]))
		if frames.size() < 2:
			continue
		for frame_name in frames:
			_animated_texture_sequences[_texture_sequence_key(String(frame_name))] = frames


func _digit_ranges(value: String) -> Array[Vector2i]:
	var ranges: Array[Vector2i] = []
	var index := 0
	while index < value.length():
		var code := value.unicode_at(index)
		if code < 48 or code > 57:
			index += 1
			continue
		var start := index
		while index < value.length():
			code = value.unicode_at(index)
			if code < 48 or code > 57:
				break
			index += 1
		ranges.append(Vector2i(start, index))
	return ranges


func _fx_texture_name_exists(texture_name: String, fx_strings: Array[Dictionary]) -> bool:
	var expected := _texture_sequence_key(texture_name)
	for record: Dictionary in fx_strings:
		if _texture_sequence_key(String(record.get("value", "")).get_file()) == expected:
			return true
	return false


func _animated_texture_frames(texture_name: String) -> PackedStringArray:
	if not _is_animated_texture(texture_name):
		return PackedStringArray()
	return _animated_texture_sequences.get(_texture_sequence_key(texture_name.get_file()), PackedStringArray())


func _load_animated_texture_atlas(frame_names: PackedStringArray) -> Texture2D:
	var images: Array[Image] = []
	for frame_name in frame_names:
		var frame_path := _ensure_model_texture(frame_name)
		if frame_path.is_empty():
			return null
		var image := _load_png_image(frame_path)
		if image == null:
			return null
		if not images.is_empty() and image.get_size() != images[0].get_size():
			push_warning("ModelBakeBuilder: animated texture frame %s has mismatched size" % frame_name)
			return null
		images.append(image)
	if images.is_empty():
		return null

	var width := images[0].get_width()
	var height := images[0].get_height()
	var atlas := Image.create_empty(width, height * images.size(), false, Image.FORMAT_RGBA8)
	for i in images.size():
		atlas.blit_rect(images[i], Rect2i(Vector2i.ZERO, images[i].get_size()), Vector2i(0, i * height))
	return ImageTexture.create_from_image(atlas)


func _animated_frame_shader(additive: bool) -> Shader:
	if additive and _animated_frame_shader_add != null:
		return _animated_frame_shader_add
	if not additive and _animated_frame_shader_mix != null:
		return _animated_frame_shader_mix

	var shader := Shader.new()
	# The frame index comes from an AnimationPlayer track instead of TIME:
	# TIME in a shader forces the editor 3D viewport to redraw continuously,
	# which starves the GPU while the editor is open next to a running game.
	shader.code = """
shader_type spatial;
render_mode %s unshaded, cull_disabled, depth_draw_never;

instance uniform float fx_frame : instance_index(1) = 0.0;
instance uniform vec4 team_color : instance_index(0) = vec4(0.12, 0.44, 1.0, 1.0);
uniform sampler2D albedo_atlas : source_color;
uniform bool use_team_color = false;
uniform float frame_count = 1.0;
uniform float alpha_floor = 0.32;
uniform float alpha_softness = 0.16;

vec3 apply_team_color(vec3 rgb) {
	if (!use_team_color) {
		return rgb;
	}
	float blue_dominance = rgb.b - max(rgb.r, rgb.g);
	float mask = smoothstep(0.08, 0.35, blue_dominance) * smoothstep(0.10, 0.35, rgb.b);
	float shade = max(max(rgb.r, rgb.g), rgb.b);
	return mix(rgb, team_color.rgb * shade, mask * team_color.a);
}

void fragment() {
	float frame = mod(floor(fx_frame + 0.5), frame_count);
	vec2 atlas_uv = vec2(UV.x, (UV.y + frame) / frame_count);
	vec4 color = texture(albedo_atlas, atlas_uv);
	float alpha = smoothstep(alpha_floor, alpha_floor + alpha_softness, color.a);
	if (alpha <= 0.01) {
		discard;
	}
	ALBEDO = apply_team_color(color.rgb) * alpha;
	ALPHA = alpha;
}
""" % ("blend_add," if additive else "")
	if additive:
		_animated_frame_shader_add = shader
	else:
		_animated_frame_shader_mix = shader
	return shader


func _animated_shield_shader() -> Shader:
	if _shield_shader != null:
		return _shield_shader
	_shield_shader = Shader.new()
	# fx_time is driven by Unit while the shield is up (a continuous phase
	# cannot come from sliced animation tracks — it would snap on clip loops),
	# and must not be TIME: TIME in a shader forces the editor 3D viewport to
	# redraw continuously (see the animated-frame shader above).
	_shield_shader.code = """
shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never;

instance uniform float fx_time : instance_index(1) = 0.0;
instance uniform vec4 team_color : instance_index(0) = vec4(0.12, 0.44, 1.0, 1.0);
uniform sampler2D albedo_tex : source_color;
uniform bool use_team_color = false;
uniform float scroll_speed = 0.225;
uniform float secondary_scroll_speed = -0.11;
uniform float pulse_speed = 1.3;
uniform float pulse_amount = 0.25;

vec3 apply_team_color(vec3 rgb) {
	if (!use_team_color) {
		return rgb;
	}
	float blue_dominance = rgb.b - max(rgb.r, rgb.g);
	float mask = smoothstep(0.08, 0.35, blue_dominance) * smoothstep(0.10, 0.35, rgb.b);
	float shade = max(max(rgb.r, rgb.g), rgb.b);
	return mix(rgb, team_color.rgb * shade, mask * team_color.a);
}

void fragment() {
	vec2 uv_a = UV + vec2(0.0, fx_time * scroll_speed);
	vec2 uv_b = UV.yx + vec2(fx_time * secondary_scroll_speed, 0.0);
	vec4 primary = texture(albedo_tex, uv_a);
	vec4 secondary = texture(albedo_tex, uv_b);
	vec3 color = max(primary.rgb, secondary.rgb * 0.65);
	float alpha = max(primary.a, secondary.a * 0.7);
	float pulse = 1.0 + sin(fx_time * pulse_speed) * pulse_amount;
	ALBEDO = apply_team_color(color) * pulse;
	ALPHA = alpha;
}
"""
	return _shield_shader


func _model_texture_shader(additive: bool, alpha_blend: bool, has_alpha: bool) -> Shader:
	var key := "%s:%s:%s" % [additive, alpha_blend, has_alpha]
	if _model_texture_shaders.has(key):
		return _model_texture_shaders[key]

	var render_modes := PackedStringArray()
	if additive:
		render_modes.append("blend_add")
		render_modes.append("unshaded")
		render_modes.append("cull_disabled")
		render_modes.append("depth_draw_never")
	elif alpha_blend:
		render_modes.append("blend_mix")
		render_modes.append("cull_disabled")
	elif has_alpha:
		render_modes.append("cull_disabled")

	var render_line := ""
	if not render_modes.is_empty():
		render_line = "render_mode %s;\n" % ", ".join(render_modes)

	var fragment_alpha := ""
	if additive or alpha_blend:
		fragment_alpha = "\tif (color.a <= 0.01) {\n\t\tdiscard;\n\t}\n\tALBEDO = apply_team_color(color.rgb) * color.a;\n\tALPHA = color.a;\n"
	else:
		var discard_threshold := 0.5 if has_alpha else 0.01
		fragment_alpha = "\tif (color.a <= %.2f) {\n\t\tdiscard;\n\t}\n\tALBEDO = apply_team_color(color.rgb);\n" % discard_threshold

	var shader := Shader.new()
	shader.code = """
shader_type spatial;
%s
instance uniform vec4 team_color : instance_index(0) = vec4(0.12, 0.44, 1.0, 1.0);
uniform sampler2D albedo_tex : source_color;
uniform bool use_team_color = false;

vec3 apply_team_color(vec3 rgb) {
	if (!use_team_color) {
		return rgb;
	}
	float blue_dominance = rgb.b - max(rgb.r, rgb.g);
	float mask = smoothstep(0.08, 0.35, blue_dominance) * smoothstep(0.10, 0.35, rgb.b);
	float shade = max(max(rgb.r, rgb.g), rgb.b);
	return mix(rgb, team_color.rgb * shade, mask * team_color.a);
}

void fragment() {
	vec4 color = texture(albedo_tex, UV);
%s}
""" % [render_line, fragment_alpha]
	_model_texture_shaders[key] = shader
	return shader


func _scrolling_texture_shader(additive: bool) -> Shader:
	if _scrolling_texture_shaders.has(additive):
		return _scrolling_texture_shaders[additive]

	var shader := Shader.new()
	var render_mode := "blend_add, unshaded, cull_disabled, depth_draw_never" if additive else "blend_mix, cull_disabled"
	shader.code = """
shader_type spatial;
render_mode %s;

instance uniform float fx_time : instance_index(1) = 0.0;
instance uniform vec4 team_color : instance_index(0) = vec4(0.12, 0.44, 1.0, 1.0);
uniform sampler2D albedo_tex : source_color;
uniform bool use_team_color = false;
uniform vec2 scroll_speed = vec2(0.18, 0.0);

vec3 apply_team_color(vec3 rgb) {
	if (!use_team_color) {
		return rgb;
	}
	float blue_dominance = rgb.b - max(rgb.r, rgb.g);
	float mask = smoothstep(0.08, 0.35, blue_dominance) * smoothstep(0.10, 0.35, rgb.b);
	float shade = max(max(rgb.r, rgb.g), rgb.b);
	return mix(rgb, team_color.rgb * shade, mask * team_color.a);
}

void fragment() {
	vec4 color = texture(albedo_tex, UV + scroll_speed * fx_time);
	if (color.a <= 0.01) {
		discard;
	}
	ALBEDO = apply_team_color(color.rgb) * color.a;
	ALPHA = color.a;
}
""" % render_mode
	_scrolling_texture_shaders[additive] = shader
	return shader


func _ensure_model_texture(texture_name: String) -> String:
	if texture_name.is_empty():
		return ""

	var clean_file := texture_name.get_file()
	if clean_file.get_extension().is_empty():
		clean_file += ".tga"

	var output_path := ""
	if not texture_output_dir.is_empty():
		output_path = texture_output_dir.path_join(clean_file)
		if ResourceLoader.exists(output_path) or FileAccess.file_exists(ProjectSettings.globalize_path(output_path)):
			return output_path

	if source_texture_dir.is_empty():
		missing_textures.append(texture_name)
		return ""

	var source_path := source_texture_dir.path_join(clean_file)
	if not ResourceLoader.exists(source_path) and not FileAccess.file_exists(source_path):
		source_path = _find_source_texture_case_insensitive(clean_file)
	if not FileAccess.file_exists(source_path):
		if not _is_suppressed_missing_texture(texture_name):
			missing_textures.append(texture_name)
		return ""
	if texture_output_dir.is_empty():
		return source_path

	var output_abs := ProjectSettings.globalize_path(output_path)
	var err := DirAccess.make_dir_recursive_absolute(output_abs.get_base_dir())
	if err != OK:
		push_error("ModelBakeBuilder: could not create %s (%s)" % [output_abs.get_base_dir(), error_string(err)])
		return ""
	err = DirAccess.copy_absolute(source_path, output_abs)
	if err != OK:
		push_error("ModelBakeBuilder: could not copy %s to %s (%s)" % [source_path, output_abs, error_string(err)])
		return ""
	copied_textures.append(output_path)
	return output_path


func _find_source_texture_case_insensitive(clean_file: String) -> String:
	if source_texture_dir.is_empty():
		return ""

	var expected := clean_file.to_lower()
	var dir := DirAccess.open(source_texture_dir)
	if dir == null:
		return ""

	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if not dir.current_is_dir() and file_name.to_lower() == expected:
			dir.list_dir_end()
			return source_texture_dir.path_join(file_name)
		file_name = dir.get_next()
	dir.list_dir_end()
	return ""


func _load_png_texture(path: String) -> Texture2D:
	var image := _load_png_image(path)
	if image == null:
		return null
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)


func _load_png_image(path: String) -> Image:
	var absolute_path := ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(absolute_path):
		return null
	var image := Image.new()
	var err := image.load(absolute_path)
	if err != OK:
		push_warning("ModelBakeBuilder: could not load texture image %s (%s)" % [path, error_string(err)])
		return null
	_apply_magenta_to_alpha(image)
	return image


func _apply_magenta_to_alpha(image: Image) -> void:
	image.convert(Image.FORMAT_RGBA8)
	var keyed := []
	keyed.resize(image.get_width() * image.get_height())
	for y in image.get_height():
		for x in image.get_width():
			var color := image.get_pixel(x, y)
			if color.r > 0.92 and color.g < 0.12 and color.b > 0.92:
				color.a = 0.0
				image.set_pixel(x, y, color)
				keyed[y * image.get_width() + x] = true

	for y in image.get_height():
		for x in image.get_width():
			if not keyed[y * image.get_width() + x]:
				continue
			var fill := _nearest_opaque_color(image, keyed, Vector2i(x, y), 4)
			fill.a = 0.0
			image.set_pixel(x, y, fill)


func _nearest_opaque_color(image: Image, keyed: Array, pixel: Vector2i, radius: int) -> Color:
	var width := image.get_width()
	var height := image.get_height()
	for distance in range(1, radius + 1):
		for y in range(maxi(0, pixel.y - distance), mini(height, pixel.y + distance + 1)):
			for x in range(maxi(0, pixel.x - distance), mini(width, pixel.x + distance + 1)):
				if abs(pixel.x - x) != distance and abs(pixel.y - y) != distance:
					continue
				if keyed[y * width + x]:
					continue
				var color := image.get_pixel(x, y)
				if color.a > 0.5:
					return Color(color.r, color.g, color.b, 0.0)
	return Color(0.0, 0.0, 0.0, 0.0)


func _is_additive_texture(texture_name: String) -> bool:
	return _texture_has_prefix(texture_name, "!")


func _uses_team_color(texture_name: String) -> bool:
	return _texture_has_prefix(texture_name, "=")


func _uses_alpha_channel(texture_name: String) -> bool:
	return _texture_has_prefix(texture_name, "@")


func _is_animated_texture(texture_name: String) -> bool:
	return _texture_has_prefix(texture_name, "%")


func _is_scrolling_texture(texture_name: String) -> bool:
	var file_name := texture_name.get_file().to_lower()
	# The Buzzsaw's tread texture has no "%" marker, but its UVs need to
	# scroll continuously to show the vehicle moving.
	if file_name == "hk_buzzsawtread_64.tga":
		return true
	# The windtrap's "front2" texture ("AT_WT_Front2_64.tga",
	# "%HK_WT_Front2_128.tga", "or_wt_front2_128.tga", ...) is what the
	# spotlight beam meshes use and is meant to scroll, but only AT/OR carry
	# no "%" marker on it in the source data (HK's copy happens to have one).
	# The base building shell also references a *different*, unmarked
	# "front" texture without the "2" (e.g. "AT_WT_Front64.tga",
	# "hk_wt_front128.tga") that must stay static, so match specifically on
	# "front2" rather than "front".
	if file_name.contains("front2"):
		return true
	if not _is_animated_texture(texture_name):
		return false
	# "spotlight.tga" carries the "%" marker but is a static light-cone
	# cutout, not a panning texture - "%" on a lone (non-sequence) file
	# is evidently reused for more than one purpose in the source data,
	# so this one is excluded rather than assumed to scroll.
	if file_name.contains("spotlight"):
		return false
	return true


func _is_suppressed_missing_texture(texture_name: String) -> bool:
	return bool(SUPPRESSED_MISSING_TEXTURES.get(_texture_sequence_key(texture_name), false))


func _texture_has_prefix(texture_name: String, marker: String) -> bool:
	return _texture_prefixes(texture_name).contains(marker)


func _texture_prefixes(texture_name: String) -> String:
	var file_name := texture_name.get_file()
	var prefixes := ""
	for i in file_name.length():
		var marker := file_name.substr(i, 1)
		if not TEXTURE_PREFIX_MARKERS.contains(marker):
			break
		prefixes += marker
	return prefixes


func _texture_sequence_key(texture_name: String) -> String:
	var file_name := texture_name.get_file()
	var index := 0
	while index < file_name.length() and TEXTURE_PREFIX_MARKERS.contains(file_name.substr(index, 1)):
		index += 1
	return file_name.substr(index).to_lower()


func _texture_has_alpha(texture: Texture2D) -> bool:
	if texture == null:
		return false
	var image := texture.get_image()
	if image == null:
		return true
	return image.detect_alpha() != Image.ALPHA_NONE


func _is_effect_object(object_name: String) -> bool:
	var lower := object_name.to_lower()
	for marker in EFFECT_NAME_MARKERS:
		if lower.contains(marker):
			return true
	return false


func _is_animated_shield_texture(texture_name: String) -> bool:
	return _is_animated_texture(texture_name) and _has_shield_fx_marker and texture_name.get_file().to_lower().contains("shield")


func _add_animation_track(anim: Animation, node_path: String, object: Dictionary) -> void:
	var object_animation: Dictionary = object.object_animation
	if object_animation.is_empty():
		return

	var frames := _dense_object_animation_frames(object_animation)
	if frames.is_empty():
		return

	var track := anim.add_track(Animation.TYPE_VALUE)
	anim.track_set_path(track, NodePath("%s:transform" % node_path))
	anim.track_set_interpolation_type(track, Animation.INTERPOLATION_LINEAR)

	var frame_ids := frames.keys()
	frame_ids.sort()
	for frame_id: int in frame_ids:
		var transform := _sanitize_animation_transform(_to_godot_transform(frames[frame_id]))
		anim.track_insert_key(track, frame_id / fps, transform)


func _dense_object_animation_frames(object_animation: Dictionary) -> Dictionary:
	var source_frames: Dictionary = object_animation.frames
	if source_frames.is_empty():
		return {}

	var length := int(object_animation.get("length", 1))
	if length <= 0:
		length = 1

	var frame_ids := source_frames.keys()
	frame_ids.sort()
	var first_frame := int(frame_ids[0])
	var last_frame := int(frame_ids[-1])
	var dense := {}

	for frame in length:
		if source_frames.has(frame):
			dense[frame] = source_frames[frame]
		elif frame < first_frame:
			dense[frame] = source_frames[first_frame]
		elif frame > last_frame:
			dense[frame] = source_frames[last_frame]
		else:
			var previous_frame := first_frame
			var next_frame := last_frame
			for frame_id: int in frame_ids:
				if frame_id < frame:
					previous_frame = frame_id
				elif frame_id > frame:
					next_frame = frame_id
					break
			var span := maxf(1.0, float(next_frame - previous_frame))
			var weight := float(frame - previous_frame) / span
			dense[frame] = _lerp_transform(source_frames[previous_frame], source_frames[next_frame], weight)
	return dense


func _lerp_transform(a: Transform3D, b: Transform3D, weight: float) -> Transform3D:
	return Transform3D(
		a.basis.x.lerp(b.basis.x, weight),
		a.basis.y.lerp(b.basis.y, weight),
		a.basis.z.lerp(b.basis.z, weight),
		a.origin.lerp(b.origin, weight)
	)


func _sanitize_animation_transform(transform: Transform3D) -> Transform3D:
	var x := transform.basis.x
	var y := transform.basis.y
	var z := transform.basis.z
	var x_scale := maxf(x.length(), MIN_ANIMATION_AXIS_SCALE)
	var y_scale := maxf(y.length(), MIN_ANIMATION_AXIS_SCALE)
	var z_scale := maxf(z.length(), MIN_ANIMATION_AXIS_SCALE)

	var nx := x.normalized() if x.length() >= MIN_ANIMATION_AXIS_SCALE else Vector3.RIGHT
	var ny := y.normalized() if y.length() >= MIN_ANIMATION_AXIS_SCALE else Vector3.UP
	ny = ny - nx * nx.dot(ny)
	if ny.length() < MIN_ANIMATION_AXIS_SCALE:
		ny = _perpendicular_axis(nx)
	else:
		ny = ny.normalized()

	var nz := z.normalized() if z.length() >= MIN_ANIMATION_AXIS_SCALE else nx.cross(ny)
	nz = nz - nx * nx.dot(nz) - ny * ny.dot(nz)
	if nz.length() < MIN_ANIMATION_AXIS_SCALE:
		nz = nx.cross(ny).normalized()
	else:
		nz = nz.normalized()

	if transform.basis.determinant() < 0.0:
		nz = -nz

	transform.basis = Basis(nx * x_scale, ny * y_scale, nz * z_scale)
	return transform


func _perpendicular_axis(axis: Vector3) -> Vector3:
	var reference := Vector3.UP if absf(axis.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	return (reference - axis * axis.dot(reference)).normalized()


func _add_vertex_animation_track(anim: Animation, mesh_path: String, object: Dictionary, texture_names: PackedStringArray) -> void:
	var vertex_animation: Dictionary = object.vertex_animation
	if vertex_animation.is_empty():
		return

	var frames: Dictionary = vertex_animation.frames
	if frames.is_empty():
		return

	var track := anim.add_track(Animation.TYPE_VALUE)
	anim.track_set_path(track, NodePath("%s:mesh" % mesh_path))
	anim.track_set_interpolation_type(track, Animation.INTERPOLATION_NEAREST)
	anim.value_track_set_update_mode(track, Animation.UPDATE_DISCRETE)

	var frame_ids := frames.keys()
	frame_ids.sort()
	var mesh_cache := {}
	for frame_id: int in frame_ids:
		var positions: PackedVector3Array = frames[frame_id]
		if positions.size() != (object.positions as PackedVector3Array).size():
			continue
		# Identical poses share one baked mesh instead of duplicating it per frame.
		var mesh: ArrayMesh = mesh_cache.get(positions)
		if mesh == null:
			mesh = _build_object_mesh(object, texture_names, positions)
			mesh_cache[positions] = mesh
		anim.track_insert_key(track, frame_id / fps, mesh)


func _mesh_animated_frame_count(mesh: ArrayMesh) -> int:
	var frames := 0
	for surface_index in mesh.get_surface_count():
		frames = maxi(frames, int(_animated_material_frames.get(mesh.surface_get_material(surface_index), 0)))
	return frames


func _mesh_has_scrolling_texture(mesh: ArrayMesh) -> bool:
	for surface_index in mesh.get_surface_count():
		if _scrolling_materials.has(mesh.surface_get_material(surface_index)):
			return true
	return false


func _add_shader_fx_tracks(anim: Animation) -> void:
	var key_count := int(ceilf(anim.length * TEXTURE_FX_FPS))
	for entry: Dictionary in _pending_frame_tracks:
		var frame_count := int(entry["frames"])
		var track := anim.add_track(Animation.TYPE_VALUE)
		anim.track_set_path(track, NodePath("%s:instance_shader_parameters/fx_frame" % String(entry["path"])))
		anim.track_set_interpolation_type(track, Animation.INTERPOLATION_NEAREST)
		anim.value_track_set_update_mode(track, Animation.UPDATE_DISCRETE)
		for i in key_count + 1:
			anim.track_insert_key(track, i / TEXTURE_FX_FPS, float(i % frame_count))


func _slice_animation(source: Animation, entry: Dictionary) -> Animation:
	var start_frame := int(entry.get("start_frame", 0))
	var end_frame := int(entry.get("end_frame", 0))
	if end_frame < start_frame:
		return null

	var start_time := start_frame / fps
	var end_time := end_frame / fps
	var clip := Animation.new()
	clip.resource_name = _clip_name(String(entry["name"]))
	clip.length = maxf((end_frame - start_frame + 1) / fps, 1.0 / fps)
	clip.loop_mode = Animation.LOOP_LINEAR if _is_looping_clip(clip.resource_name) else Animation.LOOP_NONE

	for source_track in source.get_track_count():
		var track := clip.add_track(source.track_get_type(source_track))
		clip.track_set_path(track, source.track_get_path(source_track))
		clip.track_set_interpolation_type(track, source.track_get_interpolation_type(source_track))
		if source.track_get_type(source_track) == Animation.TYPE_VALUE:
			clip.value_track_set_update_mode(track, source.value_track_get_update_mode(source_track))

		for key_index in source.track_get_key_count(source_track):
			var key_time := source.track_get_key_time(source_track, key_index)
			if key_time < start_time or key_time > end_time:
				continue
			clip.track_insert_key(
				track,
				key_time - start_time,
				source.track_get_key_value(source_track, key_index),
				source.track_get_key_transition(source_track, key_index)
			)
	return clip


func _clip_name(value: String) -> String:
	return value.strip_edges().replace(" ", "_")


func _is_looping_clip(value: String) -> bool:
	return value in ["Stationary", "Idle_0", "Idle_1", "Move", "Crawl", "Crouch"]


func _object_animation_length(object: Dictionary) -> int:
	var length := 1
	var object_animation: Dictionary = object.object_animation
	if not object_animation.is_empty():
		length = maxi(length, int(object_animation.get("length", 1)))
	var vertex_animation: Dictionary = object.vertex_animation
	if not vertex_animation.is_empty():
		length = maxi(length, int(vertex_animation.get("length", 1)))
	for child: Dictionary in object.children:
		length = maxi(length, _object_animation_length(child))
	return length


func _to_godot_transform(source: Transform3D) -> Transform3D:
	var transform := source
	transform.basis.x = Vector3(source.basis.x.x, source.basis.x.y, -source.basis.x.z)
	transform.basis.y = Vector3(source.basis.y.x, source.basis.y.y, -source.basis.y.z)
	transform.basis.z = Vector3(-source.basis.z.x, -source.basis.z.y, source.basis.z.z)
	transform.origin = Vector3(source.origin.x, source.origin.y, -source.origin.z)
	return transform


func _safe_node_name(value: String) -> String:
	if value.is_empty():
		return "Object"
	var result := ""
	for i in value.length():
		var code := value.unicode_at(i)
		var is_digit := code >= 48 and code <= 57
		var is_upper := code >= 65 and code <= 90
		var is_lower := code >= 97 and code <= 122
		result += value.substr(i, 1) if is_digit or is_upper or is_lower or code == 95 else "_"
	result = result.strip_edges()
	while result.contains("__"):
		result = result.replace("__", "_")
	if result.is_empty() or (result.unicode_at(0) >= 48 and result.unicode_at(0) <= 57):
		result = "Object_%s" % result
	return result


func _scene_name_from_path(path: String) -> String:
	return path.get_file().get_basename().replace(" ", "_")
