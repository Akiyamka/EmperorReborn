class_name ModelXbf
extends RefCounted

const XbfMeshScript := preload("res://converters/xbf/xbf_mesh.gd")

const FX_HEADER := "FXDataHeader"
const ANIMATION_ENTRY_SIZE := 60
const FX_BANK_PARAMETER_WORD_COUNT := 16
const FX_BANK_TRAILING_WORD_COUNT := 8
const FX_EVENT_HEADER_SIZE := 12

var version := 0
var fx_section_end := 0
var fx_header := ""
var fx_format_version := 0
var fx_bank_count := 0
var fx_bank_table_version := 0
var fx_bank_table_marker := 0
var fx_bank_data_end := -1
var fx_banks: Array[Dictionary] = []
var fx_animation_count := 0
var fx_event_section_size := 0
var fx_event_format_version := 0
var fx_event_frame_count := 0
var fx_event_object_count := 0
var fx_event_master := ""
var fx_event_counts := PackedInt32Array()
var fx_events: Array[Dictionary] = []
var fx_events_complete := false
var fx_event_raw_data := PackedByteArray()
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
	var xbf = load("res://converters/xbf/model_xbf.gd").new()
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

	# Static props (e.g. 3DDATA/Placement markers) have an empty FX section.
	var fx_bytes := bytes.slice(8, fx_section_end)
	if not fx_bytes.is_empty():
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
	# The first value is the FX format version (5 in the original content), not
	# the number of banks. Bank count is the second byte of the table signature
	# at relative offset 28: 01 NN 00 00.
	if bytes.size() >= 28:
		fx_format_version = _i32_le(bytes, 20)
		fx_animation_count = _i32_le(bytes, 24)

	fx_strings = _find_printable_strings(bytes)
	animation_entries = _parse_animation_entries(bytes)
	_parse_fx_banks(bytes)
	_parse_fx_events(bytes)
	sound_names = _collect_sound_names()


func _parse_fx_banks(bytes: PackedByteArray) -> void:
	fx_bank_count = 0
	fx_bank_table_version = 0
	fx_bank_table_marker = 0
	fx_bank_data_end = -1
	fx_banks.clear()
	# Some static XBF files stop after the common header and place unrelated
	# source-path data here. Only the 01 NN 00 00 signature introduces a bank
	# table; treating arbitrary following bytes as a count produces millions of
	# phantom records.
	if bytes.size() < 33 \
	or bytes[28] != 1 or bytes[30] != 0 or bytes[31] != 0:
		return
	fx_bank_table_version = bytes[28]
	fx_bank_count = bytes[29]
	fx_bank_table_marker = bytes[32]
	var offset := 33
	for bank_index in fx_bank_count:
		var record_start := offset
		if offset + 4 > bytes.size():
			_reset_fx_banks()
			return
		var id_length := _u32_le(bytes, offset)
		offset += 4
		if id_length <= 0 or id_length > 256 or offset + id_length > bytes.size():
			_reset_fx_banks()
			return
		var bank_id := _read_c_string(bytes, offset, id_length)
		offset += id_length
		var parameter_size := FX_BANK_PARAMETER_WORD_COUNT * 4
		if offset + parameter_size + 4 > bytes.size():
			_reset_fx_banks()
			return
		var parameter_words := PackedInt32Array()
		for parameter_index in FX_BANK_PARAMETER_WORD_COUNT:
			parameter_words.append(_i32_le(bytes, offset + parameter_index * 4))
		var int_parameters_0_3 := PackedInt32Array()
		for parameter_index in 4:
			int_parameters_0_3.append(parameter_words[parameter_index])
		var float_parameters_4_6 := PackedFloat32Array()
		for parameter_index in range(4, 7):
			float_parameters_4_6.append(_f32_le(bytes, offset + parameter_index * 4))
		var int_parameters_7_11 := PackedInt32Array()
		for parameter_index in range(7, 12):
			int_parameters_7_11.append(parameter_words[parameter_index])
		var float_parameters_12_14 := PackedFloat32Array()
		for parameter_index in range(12, 15):
			float_parameters_12_14.append(_f32_le(bytes, offset + parameter_index * 4))
		var particle_size := _f32_le(bytes, offset + 6 * 4)
		var texture_frame_count := parameter_words[15]
		offset += parameter_size
		var texture_length := _u32_le(bytes, offset)
		offset += 4
		if texture_length <= 0 or texture_length > 256 \
		or offset + texture_length > bytes.size():
			_reset_fx_banks()
			return
		var texture_name := _read_c_string(bytes, offset, texture_length)
		offset += texture_length
		var trailing_size := FX_BANK_TRAILING_WORD_COUNT * 4
		if offset + trailing_size > bytes.size():
			_reset_fx_banks()
			return
		var trailing_words := PackedInt32Array()
		for trailing_index in FX_BANK_TRAILING_WORD_COUNT:
			trailing_words.append(_i32_le(bytes, offset + trailing_index * 4))
		offset += trailing_size
		fx_banks.append({
			"index": bank_index,
			"offset": record_start,
			"id": bank_id,
			# Keep every uninterpreted word losslessly. The grouped typed views
			# document only the stable int/float layout; unknown semantics stay
			# neutral until corroborated by original behavior.
			"parameter_words": parameter_words,
			"int_parameters_0_3": int_parameters_0_3,
			"float_parameters_4_6": float_parameters_4_6,
			"int_parameters_7_11": int_parameters_7_11,
			"float_parameters_12_14": float_parameters_12_14,
			# Parameter 06 is particle size in source model coordinates. For
			# example ShellHit's !%Bru value 32 becomes 2 world units at 1/16.
			"particle_size": particle_size,
			"texture_frame_count": texture_frame_count,
			"texture": texture_name,
			"trailing_words": trailing_words,
			"raw_data": bytes.slice(record_start, offset),
		})
	fx_bank_data_end = offset


func _reset_fx_banks() -> void:
	fx_bank_count = 0
	fx_bank_data_end = -1
	fx_banks.clear()


func _parse_fx_events(bytes: PackedByteArray) -> void:
	fx_event_section_size = 0
	fx_event_format_version = 0
	fx_event_frame_count = 0
	fx_event_object_count = 0
	fx_event_master = ""
	fx_event_counts.clear()
	fx_events.clear()
	fx_events_complete = false
	fx_event_raw_data.clear()
	if fx_bank_data_end < 0 or fx_bank_data_end + 16 > bytes.size():
		return
	var event_limit := animation_table_offset \
		if animation_table_offset > fx_bank_data_end else bytes.size()
	fx_event_raw_data = bytes.slice(fx_bank_data_end, event_limit)
	fx_event_section_size = _u32_le(bytes, fx_bank_data_end)
	fx_event_format_version = _u32_le(bytes, fx_bank_data_end + 4)
	fx_event_frame_count = _u32_le(bytes, fx_bank_data_end + 8)
	fx_event_object_count = _u32_le(bytes, fx_bank_data_end + 12)
	if fx_event_frame_count < 0 \
	or fx_bank_data_end + 16 + fx_event_frame_count * 4 > event_limit:
		return
	var offset := fx_bank_data_end + 16
	for frame in fx_event_frame_count:
		fx_event_counts.append(_u32_le(bytes, offset + frame * 4))
	offset += fx_event_frame_count * 4
	var master_end := _c_string_end(bytes, offset, event_limit)
	if master_end < 0:
		return
	fx_event_master = _read_c_string(bytes, offset, master_end - offset)
	offset = master_end

	var parsed_events: Array[Dictionary] = []
	for frame in fx_event_frame_count:
		for event_index in fx_event_counts[frame]:
			var parsed := _parse_fx_event(bytes, offset, event_limit)
			if parsed.is_empty():
				return
			offset = int(parsed["next_offset"])
			var event: Dictionary = parsed["event"]
			event["frame"] = frame
			event["frame_event_index"] = event_index
			parsed_events.append(event)
	fx_events = parsed_events
	fx_events_complete = true


func _parse_fx_event(
		bytes: PackedByteArray, offset: int, event_limit: int
	) -> Dictionary:
	var event_start := offset
	if offset + FX_EVENT_HEADER_SIZE > event_limit:
		return {}
	var event_type := _u32_le(bytes, offset)
	var probability := _u32_le(bytes, offset + 4)
	var payload_type := _u32_le(bytes, offset + 8)
	offset += FX_EVENT_HEADER_SIZE
	var payload_start := offset
	var strings: Array[String] = []
	var value: Variant = null
	match event_type:
		1, 2, 8, 9:
			if payload_type != 4:
				return {}
			var string_end := _c_string_end(bytes, offset, event_limit)
			if string_end < 0:
				return {}
			strings.append(_read_c_string(bytes, offset, string_end - offset))
			offset = string_end
		3, 4, 6:
			var expected_payload_type := 20 if event_type == 6 else 6
			if payload_type != expected_payload_type:
				return {}
			for string_index in 2:
				var string_end := _c_string_end(bytes, offset, event_limit)
				if string_end < 0:
					return {}
				strings.append(_read_c_string(bytes, offset, string_end - offset))
				offset = string_end
		7:
			if payload_type != 12:
				return {}
			var string_end := _c_string_end(bytes, offset, event_limit)
			if string_end < 0 or string_end + 8 > event_limit:
				return {}
			strings.append(_read_c_string(bytes, offset, string_end - offset))
			offset = string_end + 8
		10:
			if payload_type != 32 or offset + 4 > event_limit:
				return {}
			value = _i32_le(bytes, offset)
			offset += 4
		11:
			if payload_type != 64 or offset + 8 > event_limit:
				return {}
			offset += 8
		12:
			# The original light-event record uses payload tag 388 but carries
			# a fixed 119-byte packed payload in every characterized XBF.
			if payload_type != 388 or offset + 119 > event_limit:
				return {}
			offset += 119
		_:
			return {}

	var event := {
		"offset": event_start,
		"type": event_type,
		"probability": probability,
		"payload_type": payload_type,
		"strings": strings,
		"raw_payload": bytes.slice(payload_start, offset),
		"raw_data": bytes.slice(event_start, offset),
	}
	if value != null:
		event["value"] = value
	if (event_type == 3 or event_type == 4) and strings.size() == 2:
		event["action"] = "start" if event_type == 3 else "stop"
		event["bank_id"] = strings[0]
		event["attachment"] = strings[1]
	return {"event": event, "next_offset": offset}


func _parse_animation_entries(bytes: PackedByteArray) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	var entry_offsets := _find_animation_entry_offsets(bytes)
	if entry_offsets.is_empty():
		return entries
	animation_table_offset = entry_offsets[0]

	for i in entry_offsets.size():
		var offset: int = entry_offsets[i]
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
			"unknown1": _i32_le(bytes, offset + 40),
			# Non-zero values select an independently animated top-level object.
			# AT Refinery uses 3/4 for ~~3SmallPad01/~~4SmallPad02, so its two
			# pad clips must not inherit each other's transform tracks.
			"target_object_id": _i32_le(bytes, offset + 44),
			"zero2": _i32_le(bytes, offset + 44),
			"flag3": bytes[offset + 48],
			"pad": bytes.slice(offset + 49, offset + 52),
			"start_frame": _i32_le(bytes, offset + 52),
			"end_frame": _i32_le(bytes, offset + 56),
		})
	return entries


func _find_animation_entry_offsets(bytes: PackedByteArray) -> PackedInt32Array:
	var offsets := PackedInt32Array()
	if fx_animation_count <= 0:
		return offsets

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
				for entry_index in fx_animation_count:
					offsets.append(offset + entry_index * ANIMATION_ENTRY_SIZE)
				return offsets

	for i in fx_strings.size():
		var record: Dictionary = fx_strings[i]
		var offset := int(record["offset"])
		if _looks_like_animation_entry(bytes, offset):
			offsets.append(offset)
			if offsets.size() == fx_animation_count:
				return offsets

	offsets.clear()
	return offsets


func _looks_like_animation_entry(bytes: PackedByteArray, offset: int) -> bool:
	if offset < 0 or offset + ANIMATION_ENTRY_SIZE > bytes.size():
		return false
	var name := _read_c_string(bytes, offset, 32)
	if name.is_empty():
		return false
	# Offset +40 is per-entry metadata, not a structural zero: AT_Sniper stores
	# the table count there and Harvester stores 4 on its "Harv Eat Hold"
	# entry. The surrounding flags and valid frame range are the reliable table
	# signature, so this field must not reject an otherwise valid entry.
	return _i32_le(bytes, offset + 32) == 1 \
		and _i32_le(bytes, offset + 36) == 1 \
		and _i32_le(bytes, offset + 44) >= 0 \
		and _i32_le(bytes, offset + 44) <= 8 \
		and bytes[offset + 48] <= 1 \
		and _i32_le(bytes, offset + 52) >= 0 \
		and _i32_le(bytes, offset + 56) >= _i32_le(bytes, offset + 52)


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
	return value.begins_with("~~") \
		or value.begins_with("::") \
		or value.begins_with(">>") \
		or value.to_lower().begins_with("#muzzle")


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


func _c_string_end(bytes: PackedByteArray, offset: int, limit: int) -> int:
	var end := offset
	var safe_limit := mini(bytes.size(), limit)
	while end < safe_limit and bytes[end] != 0:
		end += 1
	return end + 1 if end < safe_limit else -1


static func _is_printable_ascii(byte: int) -> bool:
	return byte >= 0x20 and byte <= 0x7E


static func _u32_le(bytes: PackedByteArray, offset: int) -> int:
	return bytes[offset] | (bytes[offset + 1] << 8) \
		| (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24)


static func _i32_le(bytes: PackedByteArray, offset: int) -> int:
	var value := _u32_le(bytes, offset)
	return value - 0x100000000 if value >= 0x80000000 else value


static func _f32_le(bytes: PackedByteArray, offset: int) -> float:
	var buffer := StreamPeerBuffer.new()
	buffer.data_array = bytes.slice(offset, offset + 4)
	return buffer.get_float()
