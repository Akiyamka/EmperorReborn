class_name MapNavigationGrid
extends RefCounted

const NAV_SIZE := 256
const CPT_SIZE := 2048
const DXT_BLOCK_BYTES := 16
const DXT_BLOCKS_PER_ROW := 512
const DXT_TILE_BLOCKS := 64
const DXT_TILES_PER_ROW := 8
const SOURCE_TILE_XBF_UNITS := 32.0

const PASS_INFANTRY := 1 << 0
const PASS_VEHICLE := 1 << 1
const PASS_HEAVY := 1 << 2
const PASS_AIR := 1 << 3
const PASS_GROUND := PASS_INFANTRY | PASS_VEHICLE | PASS_HEAVY

const TERRAIN_SAND := 0
const TERRAIN_ROCK := 1
const TERRAIN_CLIFF := 2
const TERRAIN_NONBUILDROCK := 3
const TERRAIN_INFANTRYROCK := 4
const TERRAIN_DUSTBOWL := 5
const TERRAIN_MAPEDGE := 6
const TERRAIN_RAMP := 7
const TERRAIN_UNKNOWN := -1

var map_dir := ""
var world_bounds := AABB()
var cpf_values := PackedInt32Array()
var cpt_raw_majority := PackedInt32Array()
var cpt_alpha_majority := PackedInt32Array()
var terrain_type := PackedInt32Array()
var source_tile_x := PackedInt32Array()
var source_tile_y := PackedInt32Array()
var pass_mask := PackedInt32Array()
var movement_cost := PackedFloat32Array()
var buildable := PackedByteArray()
var cpf_report := {}
var cpt_report := {}
var nav_report := {}

var _cpt_linear_dxt := PackedByteArray()
var _is_loaded := false
var _xbf_to_world_scale := 1.0


func load(dir: String, bounds: AABB, source_xbf: Xbf = null, _world_scale := 1.0) -> bool:
	map_dir = dir
	world_bounds = bounds
	_xbf_to_world_scale = _world_scale
	_is_loaded = false

	_load_cpf(_first_existing_map_path(dir, ["test.CPF", "debug.CPF"]))
	_load_cpt(_first_existing_map_path(dir, ["test.CPT", "debug.CPT"]))

	if source_xbf == null:
		var xbf_path := _first_existing_map_path(dir, ["test.xbf", "debug.xbf"])
		if xbf_path.is_empty():
			push_error("MapNavigationGrid: no XBF file found in %s" % dir)
			return false
		source_xbf = Xbf.load_file(xbf_path)
	if source_xbf == null:
		return false
	if not source_xbf.has_tile_grid():
		push_warning("MapNavigationGrid: XBF has no embedded tile grid in %s" % dir)
		return false
	if not source_xbf.has_sized_tile_grid():
		var inferred_size := _infer_tile_grid_size(source_xbf.tile_grid.size())
		if not source_xbf.set_tile_grid_size(inferred_size):
			push_warning("MapNavigationGrid: cannot infer XBF tile grid dimensions for %s, length=%d" % [dir, source_xbf.tile_grid.size()])
			return false

	_build_nav_cells(source_xbf)
	_is_loaded = true
	print_summary()
	return true


func _infer_tile_grid_size(length: int) -> Vector2i:
	if length <= 0 or world_bounds.size.x <= 0.0 or world_bounds.size.z <= 0.0:
		return Vector2i.ZERO

	var source_tile_world_size := SOURCE_TILE_XBF_UNITS * _xbf_to_world_scale
	if source_tile_world_size <= 0.0:
		return Vector2i.ZERO
	var size := Vector2i(
		int(round(world_bounds.size.x / source_tile_world_size)),
		int(round(world_bounds.size.z / source_tile_world_size))
	)
	if size.x * size.y != length:
		return Vector2i.ZERO
	return size


func is_loaded() -> bool:
	return _is_loaded


func world_to_grid(world_position: Vector3) -> Vector2i:
	if world_bounds.size.x <= 0.0 or world_bounds.size.z <= 0.0:
		return Vector2i.ZERO

	var local_x := clampf((world_position.x - world_bounds.position.x) / world_bounds.size.x, 0.0, 0.999999)
	var local_z := clampf((world_position.z - world_bounds.position.z) / world_bounds.size.z, 0.0, 0.999999)
	return Vector2i(int(floor(local_x * NAV_SIZE)), int(floor(local_z * NAV_SIZE)))


func grid_to_world(grid_position: Vector2i, centered := true) -> Vector3:
	var offset := Vector2(0.5, 0.5) if centered else Vector2.ZERO
	var x := world_bounds.position.x + (float(grid_position.x) + offset.x) / float(NAV_SIZE) * world_bounds.size.x
	var z := world_bounds.position.z + (float(grid_position.y) + offset.y) / float(NAV_SIZE) * world_bounds.size.z
	return Vector3(x, world_bounds.position.y, z)


func cell_debug(grid_position: Vector2i) -> Dictionary:
	if not _in_bounds(grid_position.x, grid_position.y):
		return {"valid": false, "grid": grid_position}

	var i := _idx(grid_position.x, grid_position.y)
	return {
		"valid": true,
		"grid": grid_position,
		"world_center": grid_to_world(grid_position),
		"source_tile": Vector2i(source_tile_x[i], source_tile_y[i]),
		"cpf_raw": cpf_values[i],
		"cpt_raw_majority": cpt_raw_majority[i],
		"cpt_alpha_majority": cpt_alpha_majority[i],
		"terrain_type": terrain_type[i],
		"terrain_name": terrain_type_name(terrain_type[i]),
		"pass_mask": pass_mask[i],
		"movement_cost": movement_cost[i],
		"buildable": buildable[i] != 0,
	}


static func terrain_type_name(type_id: int) -> String:
	match type_id:
		TERRAIN_SAND:
			return "sand"
		TERRAIN_ROCK:
			return "rock"
		TERRAIN_CLIFF:
			return "cliff"
		TERRAIN_NONBUILDROCK:
			return "nonbuildrock"
		TERRAIN_INFANTRYROCK:
			return "infantryrock"
		TERRAIN_DUSTBOWL:
			return "dustbowl"
		TERRAIN_MAPEDGE:
			return "mapedge"
		TERRAIN_RAMP:
			return "ramp"
		_:
			return "unknown"


func save_debug_image(path: String, pixel_scale := 2) -> Error:
	var image := Image.create(NAV_SIZE, NAV_SIZE, false, Image.FORMAT_RGBA8)
	for y in NAV_SIZE:
		for x in NAV_SIZE:
			image.set_pixel(x, y, _terrain_debug_color(terrain_type[_idx(x, y)]))
	if pixel_scale > 1:
		image.resize(NAV_SIZE * pixel_scale, NAV_SIZE * pixel_scale, Image.INTERPOLATE_NEAREST)
	return image.save_png(path)


func print_summary() -> void:
	print("MapNavigationGrid: %s" % map_dir)
	print("  world_bounds=%s nav=%dx%d cell=%.3fx%.3f" % [
		world_bounds, NAV_SIZE, NAV_SIZE,
		world_bounds.size.x / float(NAV_SIZE),
		world_bounds.size.z / float(NAV_SIZE),
	])
	print("  XBF tile grid: size=%s offset=%d top=%s" % [
		nav_report.get("source_grid_size", Vector2i.ZERO),
		nav_report.get("source_grid_offset", -1),
		_format_terrain_counts(nav_report.get("source_terrain_top", [])),
	])
	print("  Nav terrain top: %s" % _format_terrain_counts(nav_report.get("terrain_top", [])))
	print("  CPF: min=%d max=%d unique=%d mean=%.2f delta_mean=%.2f delta_p95=%d delta_max=%d bit_or=0x%04x bit_and=0x%04x" % [
		cpf_report.get("min", 0),
		cpf_report.get("max", 0),
		cpf_report.get("unique", 0),
		cpf_report.get("mean", 0.0),
		cpf_report.get("delta_mean", 0.0),
		cpf_report.get("delta_p95", 0),
		cpf_report.get("delta_max", 0),
		cpf_report.get("bit_or", 0),
		cpf_report.get("bit_and", 0),
	])
	print("  CPT: header=%dx%d raw_unique=%d storage=%s" % [
		cpt_report.get("width", 0),
		cpt_report.get("height", 0),
		cpt_report.get("raw_unique", 0),
		cpt_report.get("storage", "unknown"),
	])
	if cpt_report.get("storage", "") == "tiled_dxt3_color":
		push_warning("MapNavigationGrid: test.CPT validates as tiled DXT3 color data, not a linear terrain-type byte map. Terrain pass/cost/buildable come from the embedded XBF tile grid.")


func _build_nav_cells(source_xbf: Xbf) -> void:
	var total := NAV_SIZE * NAV_SIZE
	cpt_raw_majority.resize(total)
	cpt_alpha_majority.resize(total)
	terrain_type.resize(total)
	source_tile_x.resize(total)
	source_tile_y.resize(total)
	pass_mask.resize(total)
	movement_cost.resize(total)
	buildable.resize(total)

	var alpha_majority_hist := {}
	var terrain_hist := {}
	for nav_y in NAV_SIZE:
		for nav_x in NAV_SIZE:
			var i := _idx(nav_x, nav_y)
			cpt_raw_majority[i] = _raw_majority_for_nav_cell(nav_x, nav_y) if not _cpt_linear_dxt.is_empty() else 0
			cpt_alpha_majority[i] = _alpha_majority_for_nav_cell(nav_x, nav_y) if not _cpt_linear_dxt.is_empty() else 0
			_inc_count(alpha_majority_hist, cpt_alpha_majority[i])

			var tile_x := _nav_axis_to_source_tile(nav_x, source_xbf.tile_grid_size.x)
			var tile_y := _nav_axis_to_source_tile(nav_y, source_xbf.tile_grid_size.y)
			var type_id := source_xbf.tile_at(tile_x, tile_y)
			source_tile_x[i] = tile_x
			source_tile_y[i] = tile_y
			terrain_type[i] = type_id
			_apply_terrain_attrs(i, type_id)
			_inc_count(terrain_hist, type_id)

	var source_hist := {}
	for value in source_xbf.tile_grid:
		_inc_count(source_hist, value)

	nav_report = {
		"alpha_majority_top": _top_counts(alpha_majority_hist, 10),
		"terrain_top": _top_counts(terrain_hist, 10),
		"source_terrain_top": _top_counts(source_hist, 10),
		"source_grid_size": source_xbf.tile_grid_size,
		"source_grid_offset": source_xbf.tile_grid_file_offset,
	}


func _nav_axis_to_source_tile(nav_coord: int, source_size: int) -> int:
	return clampi(int(floor((float(nav_coord) + 0.5) / float(NAV_SIZE) * float(source_size))), 0, source_size - 1)


func _apply_terrain_attrs(index: int, type_id: int) -> void:
	var attrs := _terrain_attrs(type_id)
	pass_mask[index] = attrs["pass_mask"]
	movement_cost[index] = attrs["movement_cost"]
	buildable[index] = 1 if attrs["buildable"] else 0


func _terrain_attrs(type_id: int) -> Dictionary:
	match type_id:
		TERRAIN_SAND:
			return {"pass_mask": PASS_GROUND | PASS_AIR, "movement_cost": 1.15, "buildable": false}
		TERRAIN_ROCK:
			return {"pass_mask": PASS_GROUND | PASS_AIR, "movement_cost": 1.0, "buildable": true}
		TERRAIN_NONBUILDROCK:
			return {"pass_mask": PASS_GROUND | PASS_AIR, "movement_cost": 1.0, "buildable": false}
		TERRAIN_INFANTRYROCK:
			return {"pass_mask": PASS_INFANTRY | PASS_AIR, "movement_cost": 1.2, "buildable": false}
		TERRAIN_DUSTBOWL:
			return {"pass_mask": PASS_GROUND | PASS_AIR, "movement_cost": 1.35, "buildable": false}
		TERRAIN_RAMP:
			return {"pass_mask": PASS_GROUND | PASS_AIR, "movement_cost": 1.25, "buildable": false}
		TERRAIN_CLIFF, TERRAIN_MAPEDGE:
			return {"pass_mask": PASS_AIR, "movement_cost": 1000000.0, "buildable": false}
		_:
			return {"pass_mask": PASS_AIR, "movement_cost": 1000000.0, "buildable": false}


func _load_cpf(path: String) -> bool:
	if path.is_empty():
		cpf_values = _zero_i32_grid()
		cpf_report = {"storage": "missing", "min": 0, "max": 0, "unique": 1, "mean": 0.0}
		return true

	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.size() != NAV_SIZE * NAV_SIZE * 2:
		push_error("MapNavigationGrid: invalid CPF size at %s: %d" % [path, bytes.size()])
		return false

	cpf_values.resize(NAV_SIZE * NAV_SIZE)
	var min_value := 0x7fffffff
	var max_value := -0x7fffffff
	var bit_and := 0xffff
	var bit_or := 0
	var sum := 0.0
	var unique := {}
	var low_hist := {}
	var high_hist := {}

	for i in cpf_values.size():
		var value := _u16_le(bytes, i * 2)
		cpf_values[i] = value
		min_value = mini(min_value, value)
		max_value = maxi(max_value, value)
		bit_and = bit_and & value
		bit_or = bit_or | value
		sum += value
		unique[value] = true
		_inc_count(low_hist, value & 0xff)
		_inc_count(high_hist, value >> 8)

	var deltas := PackedInt32Array()
	deltas.resize((NAV_SIZE - 1) * NAV_SIZE * 2)
	var delta_count := 0
	var delta_sum := 0.0
	var delta_max := 0
	for y in NAV_SIZE:
		for x in NAV_SIZE - 1:
			var d := absi(cpf_values[_idx(x + 1, y)] - cpf_values[_idx(x, y)])
			deltas[delta_count] = d
			delta_count += 1
			delta_sum += d
			delta_max = maxi(delta_max, d)
	for y in NAV_SIZE - 1:
		for x in NAV_SIZE:
			var d := absi(cpf_values[_idx(x, y + 1)] - cpf_values[_idx(x, y)])
			deltas[delta_count] = d
			delta_count += 1
			delta_sum += d
			delta_max = maxi(delta_max, d)
	deltas.resize(delta_count)
	deltas.sort()

	cpf_report = {
		"min": min_value,
		"max": max_value,
		"unique": unique.size(),
		"mean": sum / float(cpf_values.size()),
		"bit_and": bit_and,
		"bit_or": bit_or,
		"low_top": _top_counts(low_hist, 8),
		"high_top": _top_counts(high_hist, 8),
		"delta_mean": delta_sum / float(delta_count),
		"delta_p95": deltas[int(float(delta_count - 1) * 0.95)],
		"delta_max": delta_max,
	}
	return true


func _load_cpt(path: String) -> bool:
	if path.is_empty():
		_cpt_linear_dxt = PackedByteArray()
		cpt_report = {"storage": "missing", "width": 0, "height": 0, "raw_unique": 0}
		return true

	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.size() != CPT_SIZE * CPT_SIZE + 8:
		push_error("MapNavigationGrid: invalid CPT size at %s: %d" % [path, bytes.size()])
		return false

	var width := _u32_le(bytes, 0)
	var height := _u32_le(bytes, 4)
	if width != CPT_SIZE or height != CPT_SIZE:
		push_error("MapNavigationGrid: invalid CPT header at %s: %dx%d" % [path, width, height])
		return false

	var raw_hist := {}
	for i in range(8, bytes.size()):
		_inc_count(raw_hist, bytes[i])

	_cpt_linear_dxt = _reorder_tiled_dxt3(bytes)
	var alpha_hist := {}
	var color0_hist := {}
	var color1_hist := {}
	var index_hist := {}
	for block_offset in range(0, _cpt_linear_dxt.size(), DXT_BLOCK_BYTES):
		var alpha_bits := _u64_le(_cpt_linear_dxt, block_offset)
		for pixel in 16:
			_inc_count(alpha_hist, (alpha_bits >> (pixel * 4)) & 0xf)

		_inc_count(color0_hist, _u16_le(_cpt_linear_dxt, block_offset + 8))
		_inc_count(color1_hist, _u16_le(_cpt_linear_dxt, block_offset + 10))
		var indices := _u32_le(_cpt_linear_dxt, block_offset + 12)
		for pixel in 16:
			_inc_count(index_hist, (indices >> (pixel * 2)) & 0x3)

	cpt_report = {
		"width": width,
		"height": height,
		"raw_unique": raw_hist.size(),
		"raw_top": _top_counts(raw_hist, 10),
		"storage": "tiled_dxt3_color",
		"alpha_top": _top_counts(alpha_hist, 10),
		"color0_unique": color0_hist.size(),
		"color1_unique": color1_hist.size(),
		"color_index_top": _top_counts(index_hist, 4),
	}
	return true


func _raw_majority_for_nav_cell(nav_x: int, nav_y: int) -> int:
	var hist := {}
	var block_x0 := nav_x * 2
	var block_y0 := nav_y * 2
	for by in 2:
		for bx in 2:
			var block_index := (block_y0 + by) * DXT_BLOCKS_PER_ROW + block_x0 + bx
			var block_offset := block_index * DXT_BLOCK_BYTES
			for byte_offset in DXT_BLOCK_BYTES:
				_inc_count(hist, _cpt_linear_dxt[block_offset + byte_offset])
	return _top_counts(hist, 1)[0]["key"]


func _alpha_majority_for_nav_cell(nav_x: int, nav_y: int) -> int:
	var hist := {}
	var block_x0 := nav_x * 2
	var block_y0 := nav_y * 2
	for by in 2:
		for bx in 2:
			var block_index := (block_y0 + by) * DXT_BLOCKS_PER_ROW + block_x0 + bx
			var block_offset := block_index * DXT_BLOCK_BYTES
			var alpha_bits := _u64_le(_cpt_linear_dxt, block_offset)
			for pixel in 16:
				_inc_count(hist, (alpha_bits >> (pixel * 4)) & 0xf)
	return _top_counts(hist, 1)[0]["key"]


func _reorder_tiled_dxt3(bytes: PackedByteArray) -> PackedByteArray:
	var src := bytes.slice(8)
	var linear := PackedByteArray()
	linear.resize(src.size())
	var dst_offset := 0
	for block_y in DXT_BLOCKS_PER_ROW:
		var tile_row := block_y >> 6
		var row_in_tile := block_y & 63
		for tile_col in DXT_TILES_PER_ROW:
			var src_offset := ((tile_row * DXT_TILES_PER_ROW + tile_col) * 4096 + row_in_tile * DXT_TILE_BLOCKS) * DXT_BLOCK_BYTES
			for i in 1024:
				linear[dst_offset + i] = src[src_offset + i]
			dst_offset += 1024
	return linear


func _first_existing_map_path(dir: String, names: Array[String]) -> String:
	for file_name in names:
		var path := dir.path_join(file_name)
		if FileAccess.file_exists(path):
			return path
	return ""


func _zero_i32_grid() -> PackedInt32Array:
	var values := PackedInt32Array()
	values.resize(NAV_SIZE * NAV_SIZE)
	return values


func _terrain_debug_color(type_id: int) -> Color:
	match type_id:
		TERRAIN_SAND:
			return Color8(80, 80, 80)
		TERRAIN_ROCK:
			return Color8(150, 120, 10)
		TERRAIN_CLIFF:
			return Color8(90, 90, 20)
		TERRAIN_NONBUILDROCK:
			return Color8(100, 70, 0)
		TERRAIN_INFANTRYROCK:
			return Color8(0, 255, 255)
		TERRAIN_DUSTBOWL:
			return Color8(255, 0, 0)
		TERRAIN_MAPEDGE:
			return Color8(100, 130, 220)
		TERRAIN_RAMP:
			return Color8(5, 251, 23)
		_:
			return Color8(0, 0, 0)


func _in_bounds(x: int, y: int) -> bool:
	return x >= 0 and y >= 0 and x < NAV_SIZE and y < NAV_SIZE


func _idx(x: int, y: int) -> int:
	return y * NAV_SIZE + x


static func _u16_le(bytes: PackedByteArray, offset: int) -> int:
	return bytes[offset] | (bytes[offset + 1] << 8)


static func _u32_le(bytes: PackedByteArray, offset: int) -> int:
	return bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24)


static func _u64_le(bytes: PackedByteArray, offset: int) -> int:
	var value := 0
	for i in 8:
		value |= bytes[offset + i] << (i * 8)
	return value


static func _inc_count(hist: Dictionary, key: Variant) -> void:
	hist[key] = int(hist.get(key, 0)) + 1


static func _top_counts(hist: Dictionary, limit: int) -> Array:
	var pairs := []
	for key in hist.keys():
		pairs.append({"key": key, "count": hist[key]})
	pairs.sort_custom(func(a, b): return a["count"] > b["count"] if a["count"] != b["count"] else a["key"] < b["key"])
	return pairs.slice(0, limit)


static func _format_top_counts(pairs: Array) -> String:
	var parts := PackedStringArray()
	for pair in pairs:
		parts.append("%s:%s" % [str(pair["key"]), str(pair["count"])])
	return ", ".join(parts)


static func _format_terrain_counts(pairs: Array) -> String:
	var parts := PackedStringArray()
	for pair in pairs:
		parts.append("%s:%s" % [terrain_type_name(pair["key"]), str(pair["count"])])
	return ", ".join(parts)
