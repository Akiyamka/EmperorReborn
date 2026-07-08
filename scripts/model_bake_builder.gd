class_name ModelBakeBuilder
extends RefCounted

const ModelXbfScript := preload("res://scripts/xbf/model_xbf.gd")

# Effect submeshes the original game toggles from gameplay code rather than
# from the baked animation: the leech parasite overlay and the energy shield
# (RTSUnit shows it while `shields` > 0). They are baked hidden; gameplay code
# flips `visible` on the matching "Mesh" instance when the effect applies.
# Other FX (flashes, lightning, ...) are already driven by the animation
# tracks and must stay visible.
const EFFECT_NAME_MARKERS: PackedStringArray = ["leech", "shield"]
const MODEL_TEXTURE_DIR := "res://assets/unpacked_rfd/3DDATA/Textures"

var source_texture_dir := MODEL_TEXTURE_DIR
var texture_output_dir := ""
var fps := 20.0
var world_scale := 0.0625

# Frame rate of the baked animated-texture sequences (frames of the atlas
# advanced per second by the fx_frame animation tracks).
const TEXTURE_FX_FPS := 4.0

var missing_textures: PackedStringArray = []
var copied_textures: PackedStringArray = []
var _material_cache := {}
var _animated_texture_sequences := {}
var _animated_material_frames := {}
var _pending_frame_tracks: Array[Dictionary] = []
var _animated_frame_shader_add: Shader
var _animated_frame_shader_mix: Shader
var _shield_shader: Shader
var _has_shield_fx_marker := false


func build(xbf_path: String) -> PackedScene:
	missing_textures = PackedStringArray()
	copied_textures = PackedStringArray()
	_material_cache.clear()
	_animated_texture_sequences.clear()
	_animated_material_frames.clear()
	_pending_frame_tracks.clear()
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

	if anim.get_track_count() > 0:
		anim.length = max_frame / fps
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
	node.name = _safe_node_name(String(object.name))
	node.transform = _to_godot_transform(object.transform)
	var child_path: String = "%s/%s" % [node_path, node.name] if node_path != "." else node.name
	_add_animation_track(anim, child_path, object)

	var mesh := _build_object_mesh(object, texture_names)
	if mesh.get_surface_count() > 0:
		var mesh_instance := MeshInstance3D.new()
		mesh_instance.name = "Mesh"
		mesh_instance.mesh = mesh
		mesh_instance.visible = not _is_effect_object(String(object.name))
		node.add_child(mesh_instance)
		_add_vertex_animation_track(anim, "%s/Mesh" % child_path, object, texture_names)
		var atlas_frames := _mesh_animated_frame_count(mesh)
		if atlas_frames > 1:
			_pending_frame_tracks.append({"path": "%s/Mesh" % child_path, "frames": atlas_frames})

	for child_object: Dictionary in object.children:
		var child := _build_object_node(child_object, texture_names, child_path, anim)
		node.add_child(child)

	return node


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
	if not animated_frames.is_empty():
		var animated_texture := _load_animated_texture_atlas(animated_frames, _texture_alpha_mode(texture_name))
		if animated_texture != null:
			var animated_material := ShaderMaterial.new()
			animated_material.shader = _animated_frame_shader(_is_additive_texture(texture_name))
			animated_material.set_shader_parameter("albedo_atlas", animated_texture)
			animated_material.set_shader_parameter("frame_count", float(animated_frames.size()))
			_animated_material_frames[animated_material] = animated_frames.size()
			_material_cache[texture_name] = animated_material
			return animated_material
	if not texture_path.is_empty():
		texture = _load_png_texture(texture_path, _texture_alpha_mode(texture_name))
	if _is_animated_shield_texture(texture_name) and texture != null:
		var shield_material := ShaderMaterial.new()
		shield_material.shader = _animated_shield_shader()
		shield_material.set_shader_parameter("albedo_tex", texture)
		_material_cache[texture_name] = shield_material
		return shield_material

	var material := StandardMaterial3D.new()
	material.roughness = 0.85
	material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	if _uses_black_to_alpha(texture_name):
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
		if _is_additive_texture(texture_name):
			material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	elif _uses_magenta_to_alpha(texture_name) and _texture_has_alpha(texture):
		# Magenta colour key is a 1-bit mask: alpha scissor keeps the material
		# in the opaque pass (depth write + early-Z) instead of alpha blending.
		# Textures without any keyed pixel stay fully opaque (no discard cost).
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
			var key := "%s#%s" % [prefix.to_lower(), suffix.to_lower()]
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
			_animated_texture_sequences[String(frame_name).to_lower()] = frames


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
	var expected := texture_name.to_lower()
	for record: Dictionary in fx_strings:
		if String(record.get("value", "")).get_file().to_lower() == expected:
			return true
	return false


func _animated_texture_frames(texture_name: String) -> PackedStringArray:
	return _animated_texture_sequences.get(texture_name.get_file().to_lower(), PackedStringArray())


func _load_animated_texture_atlas(frame_names: PackedStringArray, alpha_mode: int) -> Texture2D:
	var images: Array[Image] = []
	for frame_name in frame_names:
		var frame_path := _ensure_model_texture(frame_name)
		if frame_path.is_empty():
			return null
		var image := _load_png_image(frame_path, alpha_mode)
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

instance uniform float fx_frame = 0.0;
uniform sampler2D albedo_atlas : source_color;
uniform float frame_count = 1.0;
uniform float alpha_floor = 0.32;
uniform float alpha_softness = 0.16;

void fragment() {
	float frame = mod(floor(fx_frame + 0.5), frame_count);
	vec2 atlas_uv = vec2(UV.x, (UV.y + frame) / frame_count);
	vec4 color = texture(albedo_atlas, atlas_uv);
	float alpha = smoothstep(alpha_floor, alpha_floor + alpha_softness, color.a);
	if (alpha <= 0.01) {
		discard;
	}
	ALBEDO = color.rgb * alpha;
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
	# fx_time is driven by RTSUnit while the shield is up (a continuous phase
	# cannot come from sliced animation tracks — it would snap on clip loops),
	# and must not be TIME: TIME in a shader forces the editor 3D viewport to
	# redraw continuously (see the animated-frame shader above).
	_shield_shader.code = """
shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never;

instance uniform float fx_time = 0.0;
uniform sampler2D albedo_tex : source_color;
uniform float scroll_speed = 0.225;
uniform float secondary_scroll_speed = -0.11;
uniform float pulse_speed = 1.3;
uniform float pulse_amount = 0.25;

void fragment() {
	vec2 uv_a = UV + vec2(0.0, fx_time * scroll_speed);
	vec2 uv_b = UV.yx + vec2(fx_time * secondary_scroll_speed, 0.0);
	vec4 primary = texture(albedo_tex, uv_a);
	vec4 secondary = texture(albedo_tex, uv_b);
	vec3 color = max(primary.rgb, secondary.rgb * 0.65);
	float alpha = max(primary.a, secondary.a * 0.7);
	float pulse = 1.0 + sin(fx_time * pulse_speed) * pulse_amount;
	ALBEDO = color * pulse;
	ALPHA = alpha;
}
"""
	return _shield_shader


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


func _load_png_texture(path: String, alpha_mode := 0) -> Texture2D:
	if alpha_mode == 0 and ResourceLoader.exists(path):
		return load(path)

	var image := _load_png_image(path, alpha_mode)
	if image == null:
		return null
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)


func _load_png_image(path: String, alpha_mode := 0) -> Image:
	var absolute_path := ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(absolute_path):
		return null
	var image := Image.new()
	var err := image.load(absolute_path)
	if err != OK:
		push_warning("ModelBakeBuilder: could not load texture image %s (%s)" % [path, error_string(err)])
		return null
	if alpha_mode == 1:
		_apply_black_to_alpha(image)
	elif alpha_mode == 2:
		_apply_magenta_to_alpha(image)
	return image


func _apply_black_to_alpha(image: Image) -> void:
	image.convert(Image.FORMAT_RGBA8)
	for y in image.get_height():
		for x in image.get_width():
			var color := image.get_pixel(x, y)
			color.a = maxf(color.r, maxf(color.g, color.b))
			image.set_pixel(x, y, color)


func _apply_magenta_to_alpha(image: Image) -> void:
	image.convert(Image.FORMAT_RGBA8)
	for y in image.get_height():
		for x in image.get_width():
			var color := image.get_pixel(x, y)
			if color.r > 0.92 and color.g < 0.12 and color.b > 0.92:
				color.a = 0.0
				image.set_pixel(x, y, color)


func _is_additive_texture(texture_name: String) -> bool:
	return texture_name.get_file().begins_with("!")


func _uses_black_to_alpha(texture_name: String) -> bool:
	var file_name := texture_name.get_file()
	return file_name.begins_with("!") or file_name.begins_with("@")


func _uses_magenta_to_alpha(texture_name: String) -> bool:
	return texture_name.get_file().begins_with("=")


func _texture_has_alpha(texture: Texture2D) -> bool:
	if texture == null:
		return false
	var image := texture.get_image()
	if image == null:
		return true
	return image.detect_alpha() != Image.ALPHA_NONE


func _texture_alpha_mode(texture_name: String) -> int:
	if _uses_black_to_alpha(texture_name):
		return 1
	if _uses_magenta_to_alpha(texture_name):
		return 2
	return 0


func _is_effect_object(object_name: String) -> bool:
	var lower := object_name.to_lower()
	for marker in EFFECT_NAME_MARKERS:
		if lower.contains(marker):
			return true
	return false


func _is_animated_shield_texture(texture_name: String) -> bool:
	return _has_shield_fx_marker and texture_name.get_file().to_lower().contains("shield")


func _add_animation_track(anim: Animation, node_path: String, object: Dictionary) -> void:
	var object_animation: Dictionary = object.object_animation
	if object_animation.is_empty():
		return

	var frames: Dictionary = object_animation.frames
	if frames.is_empty():
		return

	var track := anim.add_track(Animation.TYPE_VALUE)
	anim.track_set_path(track, NodePath("%s:transform" % node_path))
	anim.track_set_interpolation_type(track, Animation.INTERPOLATION_LINEAR)

	var frame_ids := frames.keys()
	frame_ids.sort()
	for frame_id: int in frame_ids:
		anim.track_insert_key(track, frame_id / fps, _to_godot_transform(frames[frame_id]))


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
