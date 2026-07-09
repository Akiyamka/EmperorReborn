class_name XbfMesh
extends RefCounted

const FLAG_VERTEX_COLORS := 1
const FLAG_TRIANGLE_EXTRA := 2
const FLAG_VERTEX_ANIMATION := 4
const FLAG_OBJECT_ANIMATION := 8

var textures := PackedStringArray()
var objects: Array[Dictionary] = []


static func parse_from_buffer(buffer: StreamPeerBuffer):
	var mesh = load("res://importers/xbf/xbf_mesh.gd").new()
	if not mesh._parse(buffer):
		return null
	return mesh


func build_mesh() -> ArrayMesh:
	var surfaces: Dictionary = {}
	for object in objects:
		_collect_surfaces(object, Transform3D.IDENTITY, surfaces)

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
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var surface_index := mesh.get_surface_count() - 1
		var texture_name := textures[texture_index] if texture_index < textures.size() else ""
		mesh.surface_set_name(surface_index, texture_name)
	return mesh


func _parse(buffer: StreamPeerBuffer) -> bool:
	var texture_blob_length := buffer.get_32()
	if texture_blob_length < 0 or buffer.get_position() + texture_blob_length > buffer.get_size():
		push_error("XbfMesh: invalid texture blob length %d at offset %d" % [texture_blob_length, buffer.get_position() - 4])
		return false

	textures = _parse_texture_blob(buffer.get_data(texture_blob_length)[1] as PackedByteArray)
	while true:
		if buffer.get_position() + 4 > buffer.get_size():
			push_error("XbfMesh: unexpected end of file while reading object tree")
			return false
		var marker := buffer.get_32()
		if marker == -1:
			break
		buffer.seek(buffer.get_position() - 4)
		objects.append(_parse_object(buffer))
	return true


func _parse_texture_blob(texture_blob: PackedByteArray) -> PackedStringArray:
	var parsed := PackedStringArray()
	var current_name := PackedByteArray()
	for byte in texture_blob:
		if byte == 0:
			if not current_name.is_empty():
				parsed.append(current_name.get_string_from_ascii())
			current_name = PackedByteArray()
		elif byte != 2:
			current_name.append(byte)
	if not current_name.is_empty():
		parsed.append(current_name.get_string_from_ascii())
	return parsed


func _parse_object(buffer: StreamPeerBuffer) -> Dictionary:
	var vertex_count := buffer.get_32()
	var flags := buffer.get_32()
	var triangle_count := buffer.get_32()
	var child_count := buffer.get_32()
	var transform := _read_transform_16d(buffer)

	var name_bytes := buffer.get_data(buffer.get_32())[1] as PackedByteArray
	var name := name_bytes.get_string_from_ascii()

	var children: Array[Dictionary] = []
	for i in child_count:
		children.append(_parse_object(buffer))

	var positions := PackedVector3Array()
	var normals := PackedVector3Array()
	positions.resize(vertex_count)
	normals.resize(vertex_count)
	for i in vertex_count:
		positions[i] = Vector3(buffer.get_float(), buffer.get_float(), buffer.get_float())
		normals[i] = Vector3(buffer.get_float(), buffer.get_float(), buffer.get_float())

	var triangle_indices := PackedInt32Array()
	var triangle_textures := PackedInt32Array()
	var triangle_uvs := PackedVector2Array()
	triangle_indices.resize(triangle_count * 3)
	triangle_textures.resize(triangle_count)
	triangle_uvs.resize(triangle_count * 3)
	for i in triangle_count:
		triangle_indices[i * 3] = buffer.get_32()
		triangle_indices[i * 3 + 1] = buffer.get_32()
		triangle_indices[i * 3 + 2] = buffer.get_32()
		triangle_textures[i] = buffer.get_32()
		buffer.get_32()
		for corner in 3:
			triangle_uvs[i * 3 + corner] = Vector2(buffer.get_float(), buffer.get_float())

	if flags & FLAG_VERTEX_COLORS:
		buffer.seek(buffer.get_position() + vertex_count * 3)
	if flags & FLAG_TRIANGLE_EXTRA:
		buffer.seek(buffer.get_position() + triangle_count * 4)

	var vertex_animation := {}
	var object_animation := {}
	if flags & FLAG_VERTEX_ANIMATION:
		vertex_animation = _parse_vertex_animation(buffer)
	if flags & FLAG_OBJECT_ANIMATION:
		object_animation = _parse_object_animation(buffer)

	return {
		"name": name,
		"flags": flags,
		"transform": transform,
		"vertex_animation": vertex_animation,
		"object_animation": object_animation,
		"positions": positions,
		"normals": normals,
		"triangle_indices": triangle_indices,
		"triangle_textures": triangle_textures,
		"triangle_uvs": triangle_uvs,
		"children": children,
	}


func _parse_vertex_animation(buffer: StreamPeerBuffer) -> Dictionary:
	var length := buffer.get_32()
	var entries_negative := buffer.get_32()
	var used_frames := buffer.get_32()
	var frame_ids := PackedInt32Array()
	frame_ids.resize(used_frames)
	for i in used_frames:
		frame_ids[i] = buffer.get_32()
	if entries_negative >= 0:
		return {"length": length, "frame_ids": frame_ids, "frames": {}}

	var kind := buffer.get_16()
	var flags := buffer.get_u16()
	var entries := buffer.get_32()
	var animated_vertex_count := int(entries / float(used_frames))
	var used_positions: Array[PackedVector3Array] = []
	for frame_index in used_frames:
		var positions := PackedVector3Array()
		positions.resize(animated_vertex_count)
		for vertex_index in animated_vertex_count:
			var x := float(buffer.get_16()) / 512.0
			var y := float(buffer.get_16()) / 512.0
			var z := float(buffer.get_16()) / 512.0
			buffer.get_16()
			positions[vertex_index] = Vector3(x, y, z)
		used_positions.append(positions)

	var frames := {}
	if flags != 0:
		for timeline_frame in length:
			var frame_offset := buffer.get_32()
			if frame_offset <= 0:
				continue
			var used_index := int(float(frame_offset - 1) / (animated_vertex_count * 4))
			if used_index >= 0 and used_index < used_positions.size():
				frames[timeline_frame] = used_positions[used_index]
	else:
		for frame_index in used_frames:
			frames[frame_ids[frame_index]] = used_positions[frame_index]

	return {
		"length": length,
		"frame_ids": frame_ids,
		"frames": frames,
		"kind": kind,
		"flags": flags,
		"entries": entries,
		"vertex_count": animated_vertex_count,
	}


func _parse_object_animation(buffer: StreamPeerBuffer) -> Dictionary:
	var length := buffer.get_32() + 1
	var used_frames := buffer.get_32()
	var frames := {}

	if used_frames == -1:
		for i in length:
			frames[i] = _read_transform_16f(buffer)
	elif used_frames == -2:
		for i in length:
			frames[i] = _read_transform_12f(buffer)
	elif used_frames == -3:
		var matrices: Array[Transform3D] = []
		matrices.resize(buffer.get_32())
		var frame_indices := PackedInt32Array()
		frame_indices.resize(length)
		for i in length:
			frame_indices[i] = buffer.get_16()
		for i in matrices.size():
			matrices[i] = _read_transform_12f(buffer)
		for i in length:
			frames[i] = matrices[frame_indices[i]]
	else:
		for i in used_frames:
			var frame_id := buffer.get_16()
			var flags := buffer.get_u16()
			if (flags & 0x8FFF) != 0:
				push_warning("XbfMesh: object animation has unknown flags 0x%04X" % flags)
			var frame := Transform3D.IDENTITY
			if ((flags >> 12) & 0x1) != 0:
				var q := Quaternion(buffer.get_float(), buffer.get_float(), buffer.get_float(), buffer.get_float())
				frame *= Transform3D(Basis(q), Vector3.ZERO)
			if ((flags >> 12) & 0x2) != 0:
				frame *= Transform3D(Basis.from_scale(Vector3(buffer.get_float(), buffer.get_float(), buffer.get_float())), Vector3.ZERO)
			if ((flags >> 12) & 0x4) != 0:
				frame *= Transform3D(Basis.IDENTITY, Vector3(buffer.get_float(), buffer.get_float(), buffer.get_float()))
			frames[frame_id] = frame

	return {"length": length, "used_frames": used_frames, "frames": frames}


func _collect_surfaces(object: Dictionary, parent_transform: Transform3D, surfaces: Dictionary) -> void:
	var transform: Transform3D = parent_transform * object.transform
	var positions: PackedVector3Array = object.positions
	var normals: PackedVector3Array = object.normals
	var indices: PackedInt32Array = object.triangle_indices
	var triangle_textures: PackedInt32Array = object.triangle_textures
	var uvs: PackedVector2Array = object.triangle_uvs
	var normal_basis := transform.basis.inverse().transposed()

	for i in triangle_textures.size():
		var texture_index := triangle_textures[i]
		if texture_index == -1:
			continue
		if not surfaces.has(texture_index):
			surfaces[texture_index] = {
				"positions": PackedVector3Array(),
				"normals": PackedVector3Array(),
				"uvs": PackedVector2Array(),
			}
		var surface: Dictionary = surfaces[texture_index]
		for corner in 3:
			var vertex_index := indices[i * 3 + corner]
			var position := transform * positions[vertex_index]
			position.z = -position.z
			var normal := (normal_basis * normals[vertex_index]).normalized()
			normal.z = -normal.z
			surface.positions.append(position)
			surface.normals.append(normal)
			surface.uvs.append(uvs[i * 3 + corner])

	for child: Dictionary in object.children:
		_collect_surfaces(child, transform, surfaces)


func _read_transform_16d(buffer: StreamPeerBuffer) -> Transform3D:
	var m: Array[float] = []
	for i in 16:
		m.append(buffer.get_double())
	return _transform_from_matrix_values(m)


func _read_transform_16f(buffer: StreamPeerBuffer) -> Transform3D:
	var m: Array[float] = []
	for i in 16:
		m.append(buffer.get_float())
	return _transform_from_matrix_values(m)


func _read_transform_12f(buffer: StreamPeerBuffer) -> Transform3D:
	return _transform_from_matrix_values([
		buffer.get_float(), buffer.get_float(), buffer.get_float(), 0.0,
		buffer.get_float(), buffer.get_float(), buffer.get_float(), 0.0,
		buffer.get_float(), buffer.get_float(), buffer.get_float(), 0.0,
		buffer.get_float(), buffer.get_float(), buffer.get_float(), 1.0,
	])


func _transform_from_matrix_values(m: Array[float]) -> Transform3D:
	return Transform3D(
		Vector3(m[0], m[1], m[2]),
		Vector3(m[4], m[5], m[6]),
		Vector3(m[8], m[9], m[10]),
		Vector3(m[12], m[13], m[14])
	)
