class_name MapNavigationGridBuilder
extends RefCounted

const MapNavigationGridScript := preload("res://scripts/world/map/map_navigation_grid.gd")
const MapXbfScript := preload("res://converters/xbf/map_xbf.gd")
const SOURCE_TILE_XBF_UNITS := 32.0


func build(dir: String, bounds: AABB, source_xbf = null, world_scale := 1.0):
	var cpf_data := _load_cpf(_first_existing_map_path(dir, ["test.CPF", "debug.CPF"]))

	if source_xbf == null:
		var xbf_path := _first_existing_map_path(dir, ["test.xbf", "debug.xbf"])
		if xbf_path.is_empty():
			push_error("MapNavigationGrid: no XBF file found in %s" % dir)
			return null
		source_xbf = MapXbfScript.load_file(xbf_path)
	if source_xbf == null:
		return null
	if not source_xbf.has_tile_grid():
		push_warning("MapNavigationGrid: XBF has no embedded tile grid in %s" % dir)
		return null
	if not source_xbf.has_sized_tile_grid():
		var inferred_size := _infer_tile_grid_size(source_xbf.tile_grid.size(), bounds, world_scale)
		if not source_xbf.set_tile_grid_size(inferred_size):
			push_warning("MapNavigationGrid: cannot infer XBF tile grid dimensions for %s, length=%d" % [dir, source_xbf.tile_grid.size()])
			return null
	if source_xbf.has_spice_grid() and not source_xbf.has_sized_spice_grid():
		if not source_xbf.set_spice_grid_size(source_xbf.tile_grid_size):
			push_warning("MapNavigationGrid: cannot size XBF spice grid for %s, length=%d" % [dir, source_xbf.spice_grid.size()])

	var generated := _build_nav_cells(source_xbf)
	var navigation_grid = MapNavigationGridScript.new()
	if not navigation_grid.load_generated(
		dir,
		bounds,
		world_scale,
		cpf_data["values"],
		generated["terrain_type"],
		generated["source_tile_x"],
		generated["source_tile_y"],
		generated["spice_value"],
		generated["pass_mask"],
		generated["movement_cost"],
		generated["buildable"],
		cpf_data["report"],
		generated["report"],
		dir
	):
		return null
	_print_summary(navigation_grid)
	return navigation_grid


func _infer_tile_grid_size(length: int, bounds: AABB, world_scale: float) -> Vector2i:
	if length <= 0 or bounds.size.x <= 0.0 or bounds.size.z <= 0.0:
		return Vector2i.ZERO

	var source_tile_world_size := SOURCE_TILE_XBF_UNITS * world_scale
	if source_tile_world_size <= 0.0:
		return Vector2i.ZERO
	var size := Vector2i(
		int(round(bounds.size.x / source_tile_world_size)),
		int(round(bounds.size.z / source_tile_world_size))
	)
	if size.x * size.y != length:
		return Vector2i.ZERO
	return size


func _build_nav_cells(source_xbf) -> Dictionary:
	var total := MapNavigationGridScript.NAV_SIZE * MapNavigationGridScript.NAV_SIZE
	var terrain_type := PackedInt32Array()
	var source_tile_x := PackedInt32Array()
	var source_tile_y := PackedInt32Array()
	var spice_value := PackedByteArray()
	var pass_mask := PackedInt32Array()
	var movement_cost := PackedFloat32Array()
	var buildable := PackedByteArray()
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
	for nav_y in MapNavigationGridScript.NAV_SIZE:
		for nav_x in MapNavigationGridScript.NAV_SIZE:
			var i := _idx(nav_x, nav_y)
			var tile_x := _nav_axis_to_source_tile(nav_x, source_xbf.tile_grid_size.x)
			var tile_y := _nav_axis_to_source_tile(nav_y, source_xbf.tile_grid_size.y)
			var type_id: int = source_xbf.tile_at(tile_x, tile_y)
			source_tile_x[i] = tile_x
			source_tile_y[i] = tile_y
			terrain_type[i] = type_id
			_apply_terrain_attrs(pass_mask, movement_cost, buildable, i, type_id)
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

	return {
		"terrain_type": terrain_type,
		"source_tile_x": source_tile_x,
		"source_tile_y": source_tile_y,
		"spice_value": spice_value,
		"pass_mask": pass_mask,
		"movement_cost": movement_cost,
		"buildable": buildable,
		"report": {
			"terrain_top": _top_counts(terrain_hist, 10),
			"spice_top": _top_counts(spice_hist, 4),
			"source_terrain_top": _top_counts(source_hist, 10),
			"source_spice_top": _top_counts(source_spice_hist, 4),
			"source_grid_size": source_xbf.tile_grid_size,
			"source_grid_offset": source_xbf.tile_grid_file_offset,
			"source_spice_grid_size": source_xbf.spice_grid_size,
			"source_spice_grid_offset": source_xbf.spice_grid_file_offset,
		},
	}


func _nav_axis_to_source_tile(nav_coord: int, source_size: int) -> int:
	return clampi(int(floor((float(nav_coord) + 0.5) / float(MapNavigationGridScript.NAV_SIZE) * float(source_size))), 0, source_size - 1)


func _apply_terrain_attrs(
		pass_mask: PackedInt32Array,
		movement_cost: PackedFloat32Array,
		buildable: PackedByteArray,
		index: int,
		type_id: int
	) -> void:
	var attrs := _terrain_attrs(type_id)
	pass_mask[index] = attrs["pass_mask"]
	movement_cost[index] = attrs["movement_cost"]
	buildable[index] = 1 if attrs["buildable"] else 0


func _terrain_attrs(type_id: int) -> Dictionary:
	match type_id:
		MapNavigationGridScript.TERRAIN_SAND:
			return {"pass_mask": MapNavigationGridScript.PASS_GROUND | MapNavigationGridScript.PASS_AIR, "movement_cost": 1.15, "buildable": false}
		MapNavigationGridScript.TERRAIN_ROCK:
			return {"pass_mask": MapNavigationGridScript.PASS_GROUND | MapNavigationGridScript.PASS_AIR, "movement_cost": 1.0, "buildable": true}
		MapNavigationGridScript.TERRAIN_NONBUILDROCK:
			return {"pass_mask": MapNavigationGridScript.PASS_GROUND | MapNavigationGridScript.PASS_AIR, "movement_cost": 1.0, "buildable": false}
		MapNavigationGridScript.TERRAIN_INFANTRYROCK:
			return {"pass_mask": MapNavigationGridScript.PASS_INFANTRY | MapNavigationGridScript.PASS_AIR, "movement_cost": 1.2, "buildable": false}
		MapNavigationGridScript.TERRAIN_DUSTBOWL:
			return {"pass_mask": MapNavigationGridScript.PASS_GROUND | MapNavigationGridScript.PASS_AIR, "movement_cost": 1.35, "buildable": false}
		MapNavigationGridScript.TERRAIN_RAMP:
			return {"pass_mask": MapNavigationGridScript.PASS_GROUND | MapNavigationGridScript.PASS_AIR, "movement_cost": 1.25, "buildable": false}
		MapNavigationGridScript.TERRAIN_CLIFF, MapNavigationGridScript.TERRAIN_MAPEDGE:
			return {"pass_mask": MapNavigationGridScript.PASS_AIR, "movement_cost": 1000000.0, "buildable": false}
		_:
			return {"pass_mask": MapNavigationGridScript.PASS_AIR, "movement_cost": 1000000.0, "buildable": false}


func _load_cpf(path: String) -> Dictionary:
	var total := MapNavigationGridScript.NAV_SIZE * MapNavigationGridScript.NAV_SIZE
	var values := PackedInt32Array()
	if path.is_empty():
		values.resize(total)
		return {"values": values, "report": {"storage": "missing", "min": 0, "max": 0, "unique": 1, "mean": 0.0}}

	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.size() != total * 2:
		push_error("MapNavigationGrid: invalid CPF size at %s: %d" % [path, bytes.size()])
		return {"values": values, "report": {}}

	values.resize(total)
	var min_value := 0x7fffffff
	var max_value := -0x7fffffff
	var bit_and := 0xffff
	var bit_or := 0
	var sum := 0.0
	var unique := {}
	var low_hist := {}
	var high_hist := {}

	for i in values.size():
		var value := _u16_le(bytes, i * 2)
		values[i] = value
		min_value = mini(min_value, value)
		max_value = maxi(max_value, value)
		bit_and = bit_and & value
		bit_or = bit_or | value
		sum += value
		unique[value] = true
		_inc_count(low_hist, value & 0xff)
		_inc_count(high_hist, value >> 8)

	var deltas := PackedInt32Array()
	deltas.resize((MapNavigationGridScript.NAV_SIZE - 1) * MapNavigationGridScript.NAV_SIZE * 2)
	var delta_count := 0
	var delta_sum := 0.0
	var delta_max := 0
	for y in MapNavigationGridScript.NAV_SIZE:
		for x in MapNavigationGridScript.NAV_SIZE - 1:
			var d := absi(values[_idx(x + 1, y)] - values[_idx(x, y)])
			deltas[delta_count] = d
			delta_count += 1
			delta_sum += d
			delta_max = maxi(delta_max, d)
	for y in MapNavigationGridScript.NAV_SIZE - 1:
		for x in MapNavigationGridScript.NAV_SIZE:
			var d := absi(values[_idx(x, y + 1)] - values[_idx(x, y)])
			deltas[delta_count] = d
			delta_count += 1
			delta_sum += d
			delta_max = maxi(delta_max, d)
	deltas.resize(delta_count)
	deltas.sort()

	return {"values": values, "report": {
		"min": min_value,
		"max": max_value,
		"unique": unique.size(),
		"mean": sum / float(values.size()),
		"bit_and": bit_and,
		"bit_or": bit_or,
		"low_top": _top_counts(low_hist, 8),
		"high_top": _top_counts(high_hist, 8),
		"delta_mean": delta_sum / float(delta_count),
		"delta_p95": deltas[int(float(delta_count - 1) * 0.95)],
		"delta_max": delta_max,
	}}


func _first_existing_map_path(dir: String, names: Array[String]) -> String:
	for file_name in names:
		var path := dir.path_join(file_name)
		if FileAccess.file_exists(path):
			return path
	return ""


func _print_summary(navigation_grid) -> void:
	print("MapNavigationGrid: %s" % navigation_grid.map_dir)
	print("  world_bounds=%s nav=%dx%d cell=%.3fx%.3f" % [
		navigation_grid.world_bounds, MapNavigationGridScript.NAV_SIZE, MapNavigationGridScript.NAV_SIZE,
		navigation_grid.world_bounds.size.x / float(MapNavigationGridScript.NAV_SIZE),
		navigation_grid.world_bounds.size.z / float(MapNavigationGridScript.NAV_SIZE),
	])
	print("  XBF tile grid: size=%s offset=%d top=%s" % [
		navigation_grid.nav_report.get("source_grid_size", Vector2i.ZERO),
		navigation_grid.nav_report.get("source_grid_offset", -1),
		_format_terrain_counts(navigation_grid.nav_report.get("source_terrain_top", [])),
	])
	if navigation_grid.nav_report.get("source_spice_grid_size", Vector2i.ZERO) != Vector2i.ZERO:
		print("  XBF spice grid: size=%s offset=%d top=%s" % [
			navigation_grid.nav_report.get("source_spice_grid_size", Vector2i.ZERO),
			navigation_grid.nav_report.get("source_spice_grid_offset", -1),
			_format_top_counts(navigation_grid.nav_report.get("source_spice_top", [])),
		])
		print("  Nav spice top: %s" % _format_top_counts(navigation_grid.nav_report.get("spice_top", [])))
	print("  Nav terrain top: %s" % _format_terrain_counts(navigation_grid.nav_report.get("terrain_top", [])))
	print("  CPF: min=%d max=%d unique=%d mean=%.2f delta_mean=%.2f delta_p95=%d delta_max=%d bit_or=0x%04x bit_and=0x%04x" % [
		navigation_grid.cpf_report.get("min", 0),
		navigation_grid.cpf_report.get("max", 0),
		navigation_grid.cpf_report.get("unique", 0),
		navigation_grid.cpf_report.get("mean", 0.0),
		navigation_grid.cpf_report.get("delta_mean", 0.0),
		navigation_grid.cpf_report.get("delta_p95", 0),
		navigation_grid.cpf_report.get("delta_max", 0),
		navigation_grid.cpf_report.get("bit_or", 0),
		navigation_grid.cpf_report.get("bit_and", 0),
	])


func _idx(x: int, y: int) -> int:
	return y * MapNavigationGridScript.NAV_SIZE + x


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
		parts.append("%s:%s" % [MapNavigationGridScript.terrain_type_name(pair["key"]), str(pair["count"])])
	return ", ".join(parts)
