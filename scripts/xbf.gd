class_name Xbf
extends RefCounted
## Parser for Emperor: Battle for Dune XBF meshes (see specs/emperor-xbf-tlv-format.md).
##
## A terrain XBF contains a TLV meta-section with map metadata/logical layers,
## followed by a mesh blob with a tree of objects (terrain chunks for map meshes),
## each with position+normal vertices and triangles carrying a texture index,
## smoothing group and per-corner UVs. Reference implementation for the mesh
## part: CorrinoEngine/LibEmperor/Xbf.cs.

const _FLAG_VERTEX_COLORS := 1
const _FLAG_TRIANGLE_EXTRA := 2
const _FLAG_VERTEX_ANIMATION := 4
const _FLAG_OBJECT_ANIMATION := 8
const _MESH_PREFIX_BYTES := 8
const _TLV_TAG_PREFIX := 0xA0000000
const _TAG_ZONES_OR_MATERIALS := 0x01
const _TAG_MAP_SIZE := 0x02
const _TAG_TILES := 0x03
const _TAG_SPICE := 0x04
const _TAG_GAME_ELEMENTS := 0x05
const _TAG_BUILDINGS := 0x07
const _TAG_SPICE_MOUND := 0x09
const _TAG_UNKNOWN_0A := 0x0A
const _TAG_BUILD_TIMESTAMP := 0x0B

var version := 0
var meta_end := 0
var map_size := Vector2i.ZERO
var build_timestamp := 0
var has_build_timestamp := false
var checksum_values := Vector2i.ZERO
var has_checksum_values := false
var tlv_records: Array[Dictionary] = []
var textures: PackedStringArray = []
var objects: Array[Dictionary] = []
var tile_grid := PackedByteArray()
var tile_grid_size := Vector2i.ZERO
var tile_grid_file_offset := -1
var spice_grid := PackedByteArray()
var spice_grid_size := Vector2i.ZERO
var spice_grid_file_offset := -1
var spice_mounds: Array[Vector2i] = []
var buildings: Array[Dictionary] = []


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
	_reset()
	if bytes.size() < 16:
		push_error("Xbf: file is too small (%d bytes)" % bytes.size())
		return false

	var buffer := StreamPeerBuffer.new()
	buffer.data_array = bytes

	version = buffer.get_32()
	if version != 1:
		push_error("Xbf: unsupported version %d" % version)
		return false

	meta_end = buffer.get_32()
	if meta_end < 8 or meta_end + _MESH_PREFIX_BYTES + 4 > bytes.size():
		push_error("Xbf: invalid TLV meta_end %d for %d byte file" % [meta_end, bytes.size()])
		return false
	if not _parse_tlv_meta(bytes):
		return false

	# Blob layout: null-terminated names, some prefixed with a 0x02 flag byte
	# (render-flag marker). Split at byte level: Godot Strings choke on NULs.
	if _u32_le(bytes, meta_end) != _TLV_TAG_PREFIX or _u32_le(bytes, meta_end + 4) != 0:
		push_warning("Xbf: unexpected mesh prefix at offset %d" % meta_end)
	buffer.seek(meta_end + _MESH_PREFIX_BYTES)
	var texture_blob_length := buffer.get_32()
	if texture_blob_length < 0 or buffer.get_position() + texture_blob_length > buffer.get_size():
		push_error("Xbf: invalid texture blob length %d at offset %d" % [texture_blob_length, buffer.get_position() - 4])
		return false
	var texture_blob := buffer.get_data(texture_blob_length)[1] as PackedByteArray
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


func has_tlv_meta() -> bool:
	return not tlv_records.is_empty()


func has_tile_grid() -> bool:
	return not tile_grid.is_empty()


func has_sized_tile_grid() -> bool:
	return tile_grid.size() == tile_grid_size.x * tile_grid_size.y and tile_grid_size.x > 0 and tile_grid_size.y > 0


func has_spice_grid() -> bool:
	return not spice_grid.is_empty()


func has_sized_spice_grid() -> bool:
	return spice_grid.size() == spice_grid_size.x * spice_grid_size.y and spice_grid_size.x > 0 and spice_grid_size.y > 0


func tile_at(x: int, y: int) -> int:
	if not has_sized_tile_grid() or x < 0 or y < 0 or x >= tile_grid_size.x or y >= tile_grid_size.y:
		return -1
	return tile_grid[y * tile_grid_size.x + x]


func spice_at(x: int, y: int) -> int:
	if not has_sized_spice_grid() or x < 0 or y < 0 or x >= spice_grid_size.x or y >= spice_grid_size.y:
		return -1
	return spice_grid[y * spice_grid_size.x + x]


func set_tile_grid_size(size: Vector2i) -> bool:
	if size.x <= 0 or size.y <= 0 or size.x * size.y != tile_grid.size():
		return false
	tile_grid_size = size
	if spice_grid.size() == tile_grid.size():
		spice_grid_size = size
	return true


func set_spice_grid_size(size: Vector2i) -> bool:
	if size.x <= 0 or size.y <= 0 or size.x * size.y != spice_grid.size():
		return false
	spice_grid_size = size
	return true


func logical_layer_summary() -> String:
	var parts := PackedStringArray()
	for record in tlv_records:
		var tag_id := int(record["tag_id"])
		match tag_id:
			_TAG_MAP_SIZE:
				if map_size != Vector2i.ZERO:
					parts.append("%s=%dx%d" % [tlv_tag_name(tag_id), map_size.x, map_size.y])
				else:
					parts.append("%s=%d" % [tlv_tag_name(tag_id), int(record["length"])])
			_TAG_TILES:
				parts.append("%s=%s" % [tlv_tag_name(tag_id), _grid_summary(tile_grid, tile_grid_size)])
			_TAG_SPICE:
				parts.append("%s=%s" % [tlv_tag_name(tag_id), _grid_summary(spice_grid, spice_grid_size)])
			_TAG_SPICE_MOUND:
				parts.append("%s=%d" % [tlv_tag_name(tag_id), spice_mounds.size()])
			_TAG_BUILDINGS:
				parts.append("%s=%d" % [tlv_tag_name(tag_id), buildings.size()])
			_:
				parts.append("%s=%d" % [tlv_tag_name(tag_id), int(record["length"])])
	return ", ".join(parts)


static func tlv_tag_name(tag_id: int) -> String:
	match tag_id:
		_TAG_ZONES_OR_MATERIALS:
			return "ZonesOrMaterials"
		_TAG_MAP_SIZE:
			return "MapSize"
		_TAG_TILES:
			return "Tiles"
		_TAG_SPICE:
			return "Spice"
		_TAG_GAME_ELEMENTS:
			return "GameElements"
		_TAG_BUILDINGS:
			return "Buildings"
		_TAG_SPICE_MOUND:
			return "SpiceMound"
		_TAG_UNKNOWN_0A:
			return "Unknown0A"
		_TAG_BUILD_TIMESTAMP:
			return "BuildTimestamp"
		_:
			return "unknown_0x%02X" % tag_id


func _reset() -> void:
	version = 0
	meta_end = 0
	map_size = Vector2i.ZERO
	build_timestamp = 0
	has_build_timestamp = false
	checksum_values = Vector2i.ZERO
	has_checksum_values = false
	tlv_records = []
	textures = PackedStringArray()
	objects = []
	tile_grid = PackedByteArray()
	tile_grid_size = Vector2i.ZERO
	tile_grid_file_offset = -1
	spice_grid = PackedByteArray()
	spice_grid_size = Vector2i.ZERO
	spice_grid_file_offset = -1
	spice_mounds = []
	buildings = []


func _parse_tlv_meta(bytes: PackedByteArray) -> bool:
	var offset := 8
	while offset < meta_end:
		if offset + 8 > meta_end:
			push_error("Xbf: truncated TLV record header at offset %d" % offset)
			return false

		var tag := _u32_le(bytes, offset)
		var length := _u32_le(bytes, offset + 4)
		var payload_offset := offset + 8
		var payload_end := payload_offset + length
		if (tag & 0xFFFFFF00) != _TLV_TAG_PREFIX:
			push_error("Xbf: invalid TLV tag 0x%08X at offset %d" % [tag, offset])
			return false
		if payload_end > meta_end:
			push_error("Xbf: TLV tag 0x%02X overruns meta-section at offset %d" % [tag & 0xFF, offset])
			return false

		var tag_id := tag & 0xFF
		tlv_records.append({
			"offset": offset,
			"tag": tag,
			"tag_id": tag_id,
			"length": length,
			"payload_offset": payload_offset,
		})
		_parse_tlv_record(tag_id, bytes, payload_offset, length)
		offset = payload_end

	_apply_tlv_map_size()
	return true


func _parse_tlv_record(tag_id: int, bytes: PackedByteArray, payload_offset: int, length: int) -> void:
	match tag_id:
		_TAG_MAP_SIZE:
			if length != 8:
				push_warning("Xbf: MapSize length is %d, expected 8" % length)
				return
			map_size = Vector2i(_i32_le(bytes, payload_offset), _i32_le(bytes, payload_offset + 4))
		_TAG_UNKNOWN_0A:
			if length != 8:
				push_warning("Xbf: Unknown0A length is %d, expected 8" % length)
				return
			checksum_values = Vector2i(_i32_le(bytes, payload_offset), _i32_le(bytes, payload_offset + 4))
			has_checksum_values = true
		_TAG_BUILD_TIMESTAMP:
			if length != 4:
				push_warning("Xbf: BuildTimestamp length is %d, expected 4" % length)
				return
			build_timestamp = _i32_le(bytes, payload_offset)
			has_build_timestamp = true
		_TAG_TILES:
			tile_grid = bytes.slice(payload_offset, payload_offset + length)
			tile_grid_file_offset = payload_offset
		_TAG_SPICE:
			spice_grid = bytes.slice(payload_offset, payload_offset + length)
			spice_grid_file_offset = payload_offset
		_TAG_SPICE_MOUND:
			_parse_spice_mounds(bytes, payload_offset, length)
		_TAG_BUILDINGS:
			_parse_buildings(bytes, payload_offset, length)


func _apply_tlv_map_size() -> void:
	if map_size.x <= 0 or map_size.y <= 0:
		return
	if tile_grid.size() == map_size.x * map_size.y:
		tile_grid_size = map_size
	elif not tile_grid.is_empty():
		push_warning("Xbf: Tiles length %d does not match MapSize %s" % [tile_grid.size(), map_size])
	if spice_grid.size() == map_size.x * map_size.y:
		spice_grid_size = map_size
	elif not spice_grid.is_empty():
		push_warning("Xbf: Spice length %d does not match MapSize %s" % [spice_grid.size(), map_size])


func _parse_spice_mounds(bytes: PackedByteArray, payload_offset: int, length: int) -> void:
	if length % 8 != 0:
		push_warning("Xbf: SpiceMound length is %d, expected multiple of 8" % length)
		return
	for offset in range(payload_offset, payload_offset + length, 8):
		spice_mounds.append(Vector2i(_i32_le(bytes, offset), _i32_le(bytes, offset + 4)))


func _parse_buildings(bytes: PackedByteArray, payload_offset: int, length: int) -> void:
	if length < 4:
		push_warning("Xbf: Buildings length is %d, expected at least 4" % length)
		return

	var payload_end := payload_offset + length
	var count := _u32_le(bytes, payload_offset)
	var cursor := payload_offset + 4
	for i in count:
		var name_end := cursor
		while name_end < payload_end and bytes[name_end] != 0:
			name_end += 1
		if name_end >= payload_end:
			push_warning("Xbf: unterminated building name at entry %d" % i)
			return

		var name := bytes.slice(cursor, name_end).get_string_from_ascii()
		cursor = name_end + 1
		if cursor + 12 > payload_end:
			push_warning("Xbf: truncated building entry %d" % i)
			return

		buildings.append({
			"name": name,
			"x": _i16_le(bytes, cursor),
			"owner": _i16_le(bytes, cursor + 2),
			"y": _i16_le(bytes, cursor + 4),
			"padding": _i16_le(bytes, cursor + 6),
			"reserved": _i32_le(bytes, cursor + 8),
		})
		cursor += 12

	if cursor != payload_end:
		push_warning("Xbf: Buildings payload has %d trailing bytes" % (payload_end - cursor))


func _grid_summary(grid: PackedByteArray, size: Vector2i) -> String:
	if grid.is_empty():
		return "empty"
	if size != Vector2i.ZERO:
		return "%dx%d" % [size.x, size.y]
	return "%d bytes" % grid.size()


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


static func _i32_le(bytes: PackedByteArray, offset: int) -> int:
	var value := _u32_le(bytes, offset)
	return value - 0x100000000 if value >= 0x80000000 else value


static func _i16_le(bytes: PackedByteArray, offset: int) -> int:
	var value := bytes[offset] | (bytes[offset + 1] << 8)
	return value - 0x10000 if value >= 0x8000 else value
