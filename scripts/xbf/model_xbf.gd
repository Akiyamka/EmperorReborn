class_name ModelXbf
extends RefCounted

const XbfMeshScript := preload("res://scripts/xbf/xbf_mesh.gd")

const FX_HEADER := "FXDataHeader"
const ANIMATION_ENTRY_SIZE := 60

var version := 0
var fx_section_end := 0
var fx_header := ""
var fx_bank_count := 0
var fx_animation_count := 0
var animation_table_offset := -1
var animation_entries: Array[Dictionary] = []
var fx_strings: Array[Dictionary] = []
var attachment_names := PackedStringArray()
var sound_names := PackedStringArray()
var textures := PackedStringArray()
var objects: Array[Dictionary] = []
var mesh_data


static func load_file(path: String):
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		push_error("ModelXbf: cannot read %s (%s)" % [path, error_string(FileAccess.get_open_error())])
		return null
	var xbf = load("res://scripts/xbf/model_xbf.gd").new()
	if not xbf._parse(bytes):
		return null
	return xbf


func _parse(bytes: PackedByteArray) -> bool:
	if bytes.size() < 16:
		push_error("ModelXbf: file is too small (%d bytes)" % bytes.size())
		return false

	var buffer := StreamPeerBuffer.new()
	buffer.data_array = bytes
	version = buffer.get_32()
	if version != 1:
		push_error("ModelXbf: unsupported version %d" % version)
		return false

	var fx_section_size := buffer.get_32()
	fx_section_end = 8 + fx_section_size
	if fx_section_end + 4 > bytes.size():
		push_error("ModelXbf: invalid FX section size %d for %d byte file" % [fx_section_size, bytes.size()])
		return false

	var fx_bytes := bytes.slice(8, fx_section_end)
	_parse_fx_section(fx_bytes)

	buffer.seek(fx_section_end)
	mesh_data = XbfMeshScript.parse_from_buffer(buffer)
	if mesh_data == null:
		return false
	textures = mesh_data.textures
	objects = mesh_data.objects
	_collect_attachment_names()
	return true


func _parse_fx_section(bytes: PackedByteArray) -> void:
	fx_header = _read_c_string(bytes, 0, min(bytes.size(), 64))
	if fx_header != FX_HEADER:
		push_warning("ModelXbf: unexpected FX header '%s'" % fx_header)

	# File offsets 28 and 32, relative offsets 20 and 24 inside this section.
	if bytes.size() >= 28:
		fx_bank_count = _i32_le(bytes, 20)
		fx_animation_count = _i32_le(bytes, 24)

	fx_strings = _find_printable_strings(bytes)
	animation_entries = _parse_animation_entries(bytes)
	sound_names = _collect_sound_names()


func _parse_animation_entries(bytes: PackedByteArray) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	var start := _find_animation_table_start(bytes)
	if start < 0:
		return entries
	animation_table_offset = start

	for i in fx_animation_count:
		var offset := start + i * ANIMATION_ENTRY_SIZE
		if offset + ANIMATION_ENTRY_SIZE > bytes.size():
			push_warning("ModelXbf: animation entry %d overruns FX section" % i)
			break
		var name := _read_c_string(bytes, offset, 32)
		entries.append({
			"index": i,
			"offset": offset,
			"name": name,
			"flag1": _i32_le(bytes, offset + 32),
			"flag2": _i32_le(bytes, offset + 36),
			"zero1": _i32_le(bytes, offset + 40),
			"zero2": _i32_le(bytes, offset + 44),
			"flag3": bytes[offset + 48],
			"pad": bytes.slice(offset + 49, offset + 52),
			"start_frame": _i32_le(bytes, offset + 52),
			"end_frame": _i32_le(bytes, offset + 56),
		})
	return entries


func _find_animation_table_start(bytes: PackedByteArray) -> int:
	if fx_animation_count <= 0:
		return -1

	for i in fx_strings.size():
		var record: Dictionary = fx_strings[i]
		var offset := int(record["offset"])
		if offset + fx_animation_count * ANIMATION_ENTRY_SIZE > bytes.size():
			continue
		if _looks_like_animation_entry(bytes, offset):
			var valid := true
			for entry_index in fx_animation_count:
				if not _looks_like_animation_entry(bytes, offset + entry_index * ANIMATION_ENTRY_SIZE):
					valid = false
					break
			if valid:
				return offset
	return -1


func _looks_like_animation_entry(bytes: PackedByteArray, offset: int) -> bool:
	if offset < 0 or offset + ANIMATION_ENTRY_SIZE > bytes.size():
		return false
	var name := _read_c_string(bytes, offset, 32)
	if name.is_empty():
		return false
	return _i32_le(bytes, offset + 32) == 1 \
		and _i32_le(bytes, offset + 36) == 1 \
		and _i32_le(bytes, offset + 40) == 0 \
		and _i32_le(bytes, offset + 44) == 0 \
		and bytes[offset + 48] == 1


func _find_printable_strings(bytes: PackedByteArray) -> Array[Dictionary]:
	var strings: Array[Dictionary] = []
	var offset := 0
	while offset < bytes.size():
		while offset < bytes.size() and not _is_printable_ascii(bytes[offset]):
			offset += 1
		var start := offset
		while offset < bytes.size() and _is_printable_ascii(bytes[offset]):
			offset += 1
		if offset - start >= 3:
			strings.append({
				"offset": start,
				"value": bytes.slice(start, offset).get_string_from_ascii(),
			})
	return strings


func _collect_sound_names() -> PackedStringArray:
	var names := PackedStringArray()
	var seen := {}
	var animation_table_end := animation_table_offset + fx_animation_count * ANIMATION_ENTRY_SIZE
	for record in fx_strings:
		var offset := int(record["offset"])
		if animation_table_offset >= 0 and offset >= animation_table_offset and offset < animation_table_end:
			continue
		var value := String(record["value"])
		if value == FX_HEADER or value == "MASTER" or value.contains("#") or value.begins_with("#") or value.begins_with("!") or _is_animation_name(value):
			continue
		if not seen.has(value):
			seen[value] = true
			names.append(value)
	return names


func _collect_attachment_names() -> void:
	var names := PackedStringArray()
	var seen := {}
	_collect_attachment_names_from_objects(objects, names, seen)
	attachment_names = names


func _collect_attachment_names_from_objects(items: Array[Dictionary], names: PackedStringArray, seen: Dictionary) -> void:
	for object in items:
		var name := String(object.name)
		if _is_attachment_name(name) and not seen.has(name):
			seen[name] = true
			names.append(name)
		_collect_attachment_names_from_objects(object.children, names, seen)


func _is_attachment_name(value: String) -> bool:
	return value.begins_with("~~") or value.begins_with("::") or value.begins_with(">>")


func _is_animation_name(value: String) -> bool:
	for entry in animation_entries:
		if String(entry["name"]) == value:
			return true
	return false


func _read_c_string(bytes: PackedByteArray, offset: int, max_length: int) -> String:
	var end := offset
	var limit = mini(bytes.size(), offset + max_length)
	while end < limit and bytes[end] != 0:
		end += 1
	if end <= offset:
		return ""
	return bytes.slice(offset, end).get_string_from_ascii()


static func _is_printable_ascii(byte: int) -> bool:
	return byte >= 0x20 and byte <= 0x7E


static func _i32_le(bytes: PackedByteArray, offset: int) -> int:
	var value := bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24)
	return value - 0x100000000 if value >= 0x80000000 else value
