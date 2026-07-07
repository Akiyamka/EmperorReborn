class_name MapNavigationGrid
extends RefCounted

const MapXbfScript := preload("res://scripts/xbf/map_xbf.gd")
const NAV_SIZE := 256
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
var terrain_type := PackedInt32Array()
var source_tile_x := PackedInt32Array()
var source_tile_y := PackedInt32Array()
var spice_value := PackedByteArray()
var pass_mask := PackedInt32Array()
var movement_cost := PackedFloat32Array()
var buildable := PackedByteArray()
var cpf_report := {}
var nav_report := {}

var _is_loaded := false
var _xbf_to_world_scale := 1.0


func load(dir: String, bounds: AABB, source_xbf = null, _world_scale := 1.0) -> bool:
	map_dir = dir
	world_bounds = bounds
	_xbf_to_world_scale = _world_scale
	_is_loaded = false

	_load_cpf(_first_existing_map_path(dir, ["test.CPF", "debug.CPF"]))

	if source_xbf == null:
		var xbf_path := _first_existing_map_path(dir, ["test.xbf", "debug.xbf"])
		if xbf_path.is_empty():
			push_error("MapNavigationGrid: no XBF file found in %s" % dir)
			return false
		source_xbf = MapXbfScript.load_file(xbf_path)
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
	if source_xbf.has_spice_grid() and not source_xbf.has_sized_spice_grid():
		if not source_xbf.set_spice_grid_size(source_xbf.tile_grid_size):
			push_warning("MapNavigationGrid: cannot size XBF spice grid for %s, length=%d" % [dir, source_xbf.spice_grid.size()])

	_build_nav_cells(source_xbf)
	_is_loaded = true
	print_summary()
	return true


func load_baked(data: Resource) -> bool:
	map_dir = data.source_map_dir
	world_bounds = data.nav_world_bounds
	_xbf_to_world_scale = data.world_scale
	_is_loaded = false

	cpf_values = data.nav_cpf_values
	terrain_type = data.nav_terrain_type
	source_tile_x = data.nav_source_tile_x
	source_tile_y = data.nav_source_tile_y
	spice_value = data.nav_spice_value
	pass_mask = data.nav_pass_mask
	movement_cost = data.nav_movement_cost
	buildable = data.nav_buildable
	cpf_report = data.nav_cpf_report
	nav_report = data.nav_report

	var total := NAV_SIZE * NAV_SIZE
	if terrain_type.size() != total or source_tile_x.size() != total or source_tile_y.size() != total:
		push_error("MapNavigationGrid: baked nav arrays have invalid size in %s" % data.resource_path)
		return false
	if spice_value.size() != total or pass_mask.size() != total or movement_cost.size() != total or buildable.size() != total:
		push_error("MapNavigationGrid: baked nav attributes have invalid size in %s" % data.resource_path)
		return false
	if cpf_values.size() != total:
		cpf_values = _zero_i32_grid()

	_is_loaded = true
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
		"terrain_type": terrain_type[i],
		"terrain_name": terrain_type_name(terrain_type[i]),
		"spice": spice_value[i],
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
	if nav_report.get("source_spice_grid_size", Vector2i.ZERO) != Vector2i.ZERO:
		print("  XBF spice grid: size=%s offset=%d top=%s" % [
			nav_report.get("source_spice_grid_size", Vector2i.ZERO),
			nav_report.get("source_spice_grid_offset", -1),
			_format_top_counts(nav_report.get("source_spice_top", [])),
		])
		print("  Nav spice top: %s" % _format_top_counts(nav_report.get("spice_top", [])))
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


func _build_nav_cells(source_xbf) -> void:
	var total := NAV_SIZE * NAV_SIZE
	terrain_type.resize(total)
	source_tile_x.resize(total)
	source_tile_y.resize(total)
	spice_value.resize(total)
	pass_mask.resize(total)
	movement_cost.resize(total)
	buildable.resize(total)

	var terrain_hist := {}
	var spice_hist := {}
	var has_spice_grid: bool = source_xbf.has_sized_spice_grid()
	for nav_y in NAV_SIZE:
		for nav_x in NAV_SIZE:
			var i := _idx(nav_x, nav_y)
			var tile_x := _nav_axis_to_source_tile(nav_x, source_xbf.tile_grid_size.x)
			var tile_y := _nav_axis_to_source_tile(nav_y, source_xbf.tile_grid_size.y)
			var type_id: int = source_xbf.tile_at(tile_x, tile_y)
			source_tile_x[i] = tile_x
			source_tile_y[i] = tile_y
			terrain_type[i] = type_id
			_apply_terrain_attrs(i, type_id)
			_inc_count(terrain_hist, type_id)
			var spice: int = source_xbf.spice_at(tile_x, tile_y) if has_spice_grid else 0
			spice_value[i] = spice if spice >= 0 else 0
			_inc_count(spice_hist, spice_value[i])

	var source_hist := {}
	for value in source_xbf.tile_grid:
		_inc_count(source_hist, value)
	var source_spice_hist := {}
	if source_xbf.has_spice_grid():
		for value in source_xbf.spice_grid:
			_inc_count(source_spice_hist, value)

	nav_report = {
		"terrain_top": _top_counts(terrain_hist, 10),
		"spice_top": _top_counts(spice_hist, 4),
		"source_terrain_top": _top_counts(source_hist, 10),
		"source_spice_top": _top_counts(source_spice_hist, 4),
		"source_grid_size": source_xbf.tile_grid_size,
		"source_grid_offset": source_xbf.tile_grid_file_offset,
		"source_spice_grid_size": source_xbf.spice_grid_size,
		"source_spice_grid_offset": source_xbf.spice_grid_file_offset,
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
