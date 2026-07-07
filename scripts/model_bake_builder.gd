class_name ModelBakeBuilder
extends RefCounted

const ModelXbfScript := preload("res://scripts/xbf/model_xbf.gd")

var source_texture_dir := ""
var texture_output_dir := "res://assets/model_textures/3DDATA0001"
var fps := 20.0
var world_scale := 0.0625

var missing_textures: PackedStringArray = []
var copied_textures: PackedStringArray = []
var _material_cache := {}


func build(xbf_path: String) -> PackedScene:
	missing_textures = PackedStringArray()
	copied_textures = PackedStringArray()
	_material_cache.clear()

	var xbf = ModelXbfScript.load_file(xbf_path)
	if xbf == null:
		return null

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
		node.add_child(mesh_instance)
		_add_vertex_animation_track(anim, "%s/Mesh" % child_path, object, texture_names)

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

	var material := StandardMaterial3D.new()
	material.roughness = 0.85
	material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	if _is_additive_texture(texture_name):
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED

	var texture_path := _ensure_model_texture(texture_name)
	if not texture_path.is_empty():
		var texture := _load_png_texture(texture_path, _is_additive_texture(texture_name))
		if texture != null:
			material.albedo_texture = texture
	else:
		material.albedo_color = Color.from_hsv(float(texture_name.hash() % 360) / 360.0, 0.45, 0.85)
	_material_cache[texture_name] = material
	return material


func _ensure_model_texture(texture_name: String) -> String:
	if texture_name.is_empty():
		return ""

	var clean_file := texture_name.get_file().replace(".tga", ".png").replace(".TGA", ".png")
	var output_path := texture_output_dir.path_join(clean_file)
	if ResourceLoader.exists(output_path) or FileAccess.file_exists(ProjectSettings.globalize_path(output_path)):
		return output_path

	if source_texture_dir.is_empty():
		missing_textures.append(texture_name)
		return ""

	var source_path := source_texture_dir.path_join("3DDATA0001__Textures__%s" % clean_file)
	if not FileAccess.file_exists(source_path):
		missing_textures.append(texture_name)
		return ""

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


func _load_png_texture(path: String, black_to_alpha := false) -> Texture2D:
	if not black_to_alpha and ResourceLoader.exists(path):
		return load(path)

	var absolute_path := ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(absolute_path):
		return null
	var image := Image.new()
	var err := image.load(absolute_path)
	if err != OK:
		push_warning("ModelBakeBuilder: could not load texture image %s (%s)" % [path, error_string(err)])
		return null
	if black_to_alpha:
		_apply_black_to_alpha(image)
	return ImageTexture.create_from_image(image)


func _apply_black_to_alpha(image: Image) -> void:
	image.convert(Image.FORMAT_RGBA8)
	for y in image.get_height():
		for x in image.get_width():
			var color := image.get_pixel(x, y)
			color.a = maxf(color.r, maxf(color.g, color.b))
			image.set_pixel(x, y, color)


func _is_additive_texture(texture_name: String) -> bool:
	return texture_name.get_file().begins_with("!")


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
		if source.track_get_path(source_track).get_concatenated_names().ends_with(":mesh"):
			clip.value_track_set_update_mode(track, Animation.UPDATE_DISCRETE)

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
