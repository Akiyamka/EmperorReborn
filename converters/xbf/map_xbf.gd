class_name MapXbf
extends RefCounted

const XbfMeshScript := preload("res://converters/xbf/xbf_mesh.gd")

const MESH_PREFIX_BYTES := 8
const TLV_TAG_PREFIX := 0xA0000000
const TAG_ZONES_OR_MATERIALS := 0x01
const TAG_MAP_SIZE := 0x02
const TAG_TILES := 0x03
const TAG_SPICE := 0x04
const TAG_GAME_ELEMENTS := 0x05
const TAG_BUILDINGS := 0x07
const TAG_SPICE_MOUND := 0x09
const TAG_UNKNOWN_0A := 0x0A
const TAG_BUILD_TIMESTAMP := 0x0B

var version := 0
var meta_end := 0
var map_size := Vector2i.ZERO
var build_timestamp := 0
var has_build_timestamp := false
var checksum_values := Vector2i.ZERO
var has_checksum_values := false
var tlv_records: Array[Dictionary] = []
var textures := PackedStringArray()
var objects: Array[Dictionary] = []
var mesh_data
var tile_grid := PackedByteArray()
var tile_grid_size := Vector2i.ZERO
var tile_grid_file_offset := -1
var spice_grid := PackedByteArray()
var spice_grid_size := Vector2i.ZERO
var spice_grid_file_offset := -1
var spice_mounds: Array[Vector2i] = []
var buildings: Array[Dictionary] = []


static func load_file(path: String):
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		push_error("MapXbf: cannot read %s (%s)" % [path, error_string(FileAccess.get_open_error())])
		return null
	var xbf = load("res://converters/xbf/map_xbf.gd").new()
	if not xbf._parse(bytes):
		return null
	return xbf


func build_mesh() -> ArrayMesh:
	return mesh_data.build_mesh()


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
			TAG_MAP_SIZE:
				if map_size != Vector2i.ZERO:
					parts.append("%s=%dx%d" % [tlv_tag_name(tag_id), map_size.x, map_size.y])
				else:
					parts.append("%s=%d" % [tlv_tag_name(tag_id), int(record["length"])])
			TAG_TILES:
				parts.append("%s=%s" % [tlv_tag_name(tag_id), _grid_summary(tile_grid, tile_grid_size)])
			TAG_SPICE:
				parts.append("%s=%s" % [tlv_tag_name(tag_id), _grid_summary(spice_grid, spice_grid_size)])
			TAG_SPICE_MOUND:
				parts.append("%s=%d" % [tlv_tag_name(tag_id), spice_mounds.size()])
			TAG_BUILDINGS:
				parts.append("%s=%d" % [tlv_tag_name(tag_id), buildings.size()])
			_:
				parts.append("%s=%d" % [tlv_tag_name(tag_id), int(record["length"])])
	return ", ".join(parts)


static func tlv_tag_name(tag_id: int) -> String:
	match tag_id:
		TAG_ZONES_OR_MATERIALS:
			return "ZonesOrMaterials"
		TAG_MAP_SIZE:
			return "MapSize"
		TAG_TILES:
			return "Tiles"
		TAG_SPICE:
			return "Spice"
		TAG_GAME_ELEMENTS:
			return "GameElements"
		TAG_BUILDINGS:
			return "Buildings"
		TAG_SPICE_MOUND:
			return "SpiceMound"
		TAG_UNKNOWN_0A:
			return "Unknown0A"
		TAG_BUILD_TIMESTAMP:
			return "BuildTimestamp"
		_:
			return "unknown_0x%02X" % tag_id


func _parse(bytes: PackedByteArray) -> bool:
	if bytes.size() < 16:
		push_error("MapXbf: file is too small (%d bytes)" % bytes.size())
		return false

	var buffer := StreamPeerBuffer.new()
	buffer.data_array = bytes
	version = buffer.get_32()
	if version != 1:
		push_error("MapXbf: unsupported version %d" % version)
		return false

	meta_end = buffer.get_32()
	if meta_end < 8 or meta_end + MESH_PREFIX_BYTES + 4 > bytes.size():
		push_error("MapXbf: invalid TLV meta_end %d for %d byte file" % [meta_end, bytes.size()])
		return false
	if not _parse_tlv_meta(bytes):
		return false
	if _u32_le(bytes, meta_end) != TLV_TAG_PREFIX or _u32_le(bytes, meta_end + 4) != 0:
		push_warning("MapXbf: unexpected mesh prefix at offset %d" % meta_end)

	buffer.seek(meta_end + MESH_PREFIX_BYTES)
	mesh_data = XbfMeshScript.parse_from_buffer(buffer)
	if mesh_data == null:
		return false
	textures = mesh_data.textures
	objects = mesh_data.objects
	return true


func _parse_tlv_meta(bytes: PackedByteArray) -> bool:
	var offset := 8
	while offset < meta_end:
		if offset + 8 > meta_end:
			push_error("MapXbf: truncated TLV record header at offset %d" % offset)
			return false

		var tag := _u32_le(bytes, offset)
		var length := _u32_le(bytes, offset + 4)
		var payload_offset := offset + 8
		var payload_end := payload_offset + length
		if (tag & 0xFFFFFF00) != TLV_TAG_PREFIX:
			push_error("MapXbf: invalid TLV tag 0x%08X at offset %d" % [tag, offset])
			return false
		if payload_end > meta_end:
			push_error("MapXbf: TLV tag 0x%02X overruns meta-section at offset %d" % [tag & 0xFF, offset])
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
		TAG_MAP_SIZE:
			if length != 8:
				push_warning("MapXbf: MapSize length is %d, expected 8" % length)
				return
			map_size = Vector2i(_i32_le(bytes, payload_offset), _i32_le(bytes, payload_offset + 4))
		TAG_UNKNOWN_0A:
			if length != 8:
				push_warning("MapXbf: Unknown0A length is %d, expected 8" % length)
				return
			checksum_values = Vector2i(_i32_le(bytes, payload_offset), _i32_le(bytes, payload_offset + 4))
			has_checksum_values = true
		TAG_BUILD_TIMESTAMP:
			if length != 4:
				push_warning("MapXbf: BuildTimestamp length is %d, expected 4" % length)
				return
			build_timestamp = _i32_le(bytes, payload_offset)
			has_build_timestamp = true
		TAG_TILES:
			tile_grid = bytes.slice(payload_offset, payload_offset + length)
			tile_grid_file_offset = payload_offset
		TAG_SPICE:
			spice_grid = bytes.slice(payload_offset, payload_offset + length)
			spice_grid_file_offset = payload_offset
		TAG_SPICE_MOUND:
			_parse_spice_mounds(bytes, payload_offset, length)
		TAG_BUILDINGS:
			_parse_buildings(bytes, payload_offset, length)


func _apply_tlv_map_size() -> void:
	if map_size.x <= 0 or map_size.y <= 0:
		return
	if tile_grid.size() == map_size.x * map_size.y:
		tile_grid_size = map_size
	elif not tile_grid.is_empty():
		push_warning("MapXbf: Tiles length %d does not match MapSize %s" % [tile_grid.size(), map_size])
	if spice_grid.size() == map_size.x * map_size.y:
		spice_grid_size = map_size
	elif not spice_grid.is_empty():
		push_warning("MapXbf: Spice length %d does not match MapSize %s" % [spice_grid.size(), map_size])


func _parse_spice_mounds(bytes: PackedByteArray, payload_offset: int, length: int) -> void:
	if length % 8 != 0:
		push_warning("MapXbf: SpiceMound length is %d, expected multiple of 8" % length)
		return
	for offset in range(payload_offset, payload_offset + length, 8):
		spice_mounds.append(Vector2i(_i32_le(bytes, offset), _i32_le(bytes, offset + 4)))


func _parse_buildings(bytes: PackedByteArray, payload_offset: int, length: int) -> void:
	if length < 4:
		push_warning("MapXbf: Buildings length is %d, expected at least 4" % length)
		return

	var payload_end := payload_offset + length
	var count := _u32_le(bytes, payload_offset)
	var cursor := payload_offset + 4
	for i in count:
		var name_end := cursor
		while name_end < payload_end and bytes[name_end] != 0:
			name_end += 1
		if name_end >= payload_end:
			push_warning("MapXbf: unterminated building name at entry %d" % i)
			return
		var name := bytes.slice(cursor, name_end).get_string_from_ascii()
		cursor = name_end + 1
		if cursor + 12 > payload_end:
			push_warning("MapXbf: truncated building entry %d" % i)
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
		push_warning("MapXbf: Buildings payload has %d trailing bytes" % (payload_end - cursor))


func _grid_summary(grid: PackedByteArray, size: Vector2i) -> String:
	if grid.is_empty():
		return "empty"
	if size != Vector2i.ZERO:
		return "%dx%d" % [size.x, size.y]
	return "%d bytes" % grid.size()


static func _u32_le(bytes: PackedByteArray, offset: int) -> int:
	return bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24)


static func _i32_le(bytes: PackedByteArray, offset: int) -> int:
	var value := _u32_le(bytes, offset)
	return value - 0x100000000 if value >= 0x80000000 else value


static func _i16_le(bytes: PackedByteArray, offset: int) -> int:
	var value := bytes[offset] | (bytes[offset + 1] << 8)
	return value - 0x10000 if value >= 0x8000 else value
