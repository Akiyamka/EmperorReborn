class_name Xbf
extends RefCounted
## Parser for Emperor: Battle for Dune XBF meshes (see specs/emperor-map-file-format.md §6).
##
## A terrain XBF contains a header area with map metadata/logical layers plus
## a tree of objects (terrain chunks for map meshes), each with position+normal
## vertices and triangles carrying a texture index, smoothing group and per-corner
## UVs. Reference implementation for the mesh part: CorrinoEngine/LibEmperor/Xbf.cs.

const _FLAG_VERTEX_COLORS := 1
const _FLAG_TRIANGLE_EXTRA := 2
const _FLAG_VERTEX_ANIMATION := 4
const _FLAG_OBJECT_ANIMATION := 8

var textures: PackedStringArray = []
var objects: Array[Dictionary] = []
var tile_grid := PackedByteArray()
var tile_grid_size := Vector2i.ZERO
var tile_grid_file_offset := -1


static func load_file(path: String) -> Xbf:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		push_error("Xbf: cannot read %s (%s)" % [path, error_string(FileAccess.get_open_error())])
		return null
	var xbf := Xbf.new()
	if not xbf._parse(bytes):
		return null
	return xbf


func _parse(bytes: PackedByteArray) -> bool:
	var buffer := StreamPeerBuffer.new()
	buffer.data_array = bytes

	var version := buffer.get_32()
	if version != 1:
		push_error("Xbf: unsupported version %d" % version)
		return false

	# Header block: the reference parser skipped it, but terrain XBFs embed
	# the logical CHUNKTILE grid here as [uint32 length][uint8 tile[length]].
	var unknown_block_size := buffer.get_32()
	var unknown_block := buffer.get_data(unknown_block_size)[1] as PackedByteArray
	_parse_embedded_tile_grid(unknown_block, 8)

	# Blob layout: null-terminated names, some prefixed with a 0x02 flag byte
	# (render-flag marker). Split at byte level: Godot Strings choke on NULs.
	var texture_blob := buffer.get_data(buffer.get_32())[1] as PackedByteArray
	var current_name := PackedByteArray()
	for byte in texture_blob:
		if byte == 0:
			if not current_name.is_empty():
				textures.append(current_name.get_string_from_ascii())
			current_name = PackedByteArray()
		elif byte != 2:
			current_name.append(byte)
	if not current_name.is_empty():
		textures.append(current_name.get_string_from_ascii())

	while true:
		if buffer.get_position() + 4 > buffer.get_size():
			push_error("Xbf: unexpected end of file (misparsed data?)")
			return false
		var marker := buffer.get_32()
		if marker == -1:
			break
		buffer.seek(buffer.get_position() - 4)
		objects.append(_parse_object(buffer))

	return true


func has_tile_grid() -> bool:
	return not tile_grid.is_empty()


func has_sized_tile_grid() -> bool:
	return tile_grid.size() == tile_grid_size.x * tile_grid_size.y and tile_grid_size.x > 0 and tile_grid_size.y > 0


func tile_at(x: int, y: int) -> int:
	if not has_sized_tile_grid() or x < 0 or y < 0 or x >= tile_grid_size.x or y >= tile_grid_size.y:
		return -1
	return tile_grid[y * tile_grid_size.x + x]


func set_tile_grid_size(size: Vector2i) -> bool:
	if size.x <= 0 or size.y <= 0 or size.x * size.y != tile_grid.size():
		return false
	tile_grid_size = size
	return true


func _parse_embedded_tile_grid(header: PackedByteArray, file_offset_base: int) -> void:
	tile_grid = PackedByteArray()
	tile_grid_size = Vector2i.ZERO
	tile_grid_file_offset = -1

	var best_offset := -1
	var best_length := 0
	var best_score := -1
	for offset in range(0, header.size() - 4):
		var length := _u32_le(header, offset)
		if offset + 4 + length > header.size():
			continue
		if length < 1024 or length > 262144:
			continue
		var valid := true
		var non_sand := 0
		for i in length:
			var value := header[offset + 4 + i]
			if value > 7:
				valid = false
				break
			if value != 0:
				non_sand += 1
		if not valid:
			continue
		if non_sand > best_score:
			best_score = non_sand
			best_offset = offset
			best_length = length

	if best_offset == -1:
		return

	tile_grid = header.slice(best_offset + 4, best_offset + 4 + best_length)
	tile_grid_file_offset = file_offset_base + best_offset + 4


func _parse_object(buffer: StreamPeerBuffer) -> Dictionary:
	var vertex_count := buffer.get_32()
	var flags := buffer.get_32()
	var triangle_count := buffer.get_32()
	var child_count := buffer.get_32()

	# 4x4 matrix of doubles, D3D row-vector convention: rows become basis columns.
	var m: Array[float] = []
	for i in 16:
		m.append(buffer.get_double())
	var transform := Transform3D(
		Vector3(m[0], m[1], m[2]),
		Vector3(m[4], m[5], m[6]),
		Vector3(m[8], m[9], m[10]),
		Vector3(m[12], m[13], m[14])
	)

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

	# Per triangle: 3 vertex indices, texture index, smoothing group, 3 UV pairs.
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
		buffer.get_32() # smoothing group, unused
		for corner in 3:
			triangle_uvs[i * 3 + corner] = Vector2(buffer.get_float(), buffer.get_float())

	if flags & _FLAG_VERTEX_COLORS:
		buffer.seek(buffer.get_position() + vertex_count * 3)
	if flags & _FLAG_TRIANGLE_EXTRA:
		buffer.seek(buffer.get_position() + triangle_count * 4)
	if flags & (_FLAG_VERTEX_ANIMATION | _FLAG_OBJECT_ANIMATION):
		# Map terrain meshes never carry animations; parsing them is out of scope.
		push_error("Xbf: animated object '%s' is not supported" % name)

	return {
		"name": name,
		"transform": transform,
		"positions": positions,
		"normals": normals,
		"triangle_indices": triangle_indices,
		"triangle_textures": triangle_textures,
		"triangle_uvs": triangle_uvs,
		"children": children,
	}


## Flattens all objects into one ArrayMesh with a surface per texture index.
## XBF uses the D3D left-handed convention; Z is negated to convert to
## Godot's right-handed space (otherwise the map renders mirrored). The
## mirror also flips triangle orientation, which exactly compensates the
## CCW->CW winding difference between the formats, so the original vertex
## order is kept.
func build_mesh() -> ArrayMesh:
	var surfaces: Dictionary = {} # texture index -> {positions, normals, uvs}
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


static func _u32_le(bytes: PackedByteArray, offset: int) -> int:
	return bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24)
