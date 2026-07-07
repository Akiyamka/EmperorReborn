extends SceneTree

const MapNavigationGridScript := preload("res://scripts/map_navigation_grid.gd")
const XbfScript := preload("res://scripts/xbf.gd")
const WORLD_SCALE := 0.0625


func _init() -> void:
	var debug_dir := OS.get_environment("EMPEROR_NAV_DEBUG_MAP")
	if debug_dir.is_empty():
		debug_dir = ProjectSettings.globalize_path("res://../assets/maps/debug")

	var xbf_path := debug_dir.path_join("debug.xbf")
	if not FileAccess.file_exists(xbf_path):
		push_error("nav_grid_check: missing %s" % xbf_path)
		quit(1)
		return

	var xbf = XbfScript.load_file(xbf_path)
	if xbf == null:
		quit(1)
		return
	if not xbf.has_tile_grid():
		push_error("nav_grid_check: XBF has no embedded tile grid")
		quit(1)
		return

	var bounds := xbf.build_mesh().get_aabb()
	bounds.position *= WORLD_SCALE
	bounds.size *= WORLD_SCALE

	var nav = MapNavigationGridScript.new()
	if not nav.load(debug_dir, bounds, xbf, WORLD_SCALE):
		quit(1)
		return

	var output_path := OS.get_environment("EMPEROR_NAV_DEBUG_PNG")
	if output_path.is_empty():
		output_path = debug_dir.path_join("nav-grid-debug.png")
	var err: Error = nav.save_debug_image(output_path, 2)
	if err != OK:
		push_error("nav_grid_check: could not save %s (%s)" % [output_path, error_string(err)])
		quit(1)
		return

	var strip := PackedStringArray()
	for x in 24:
		var cell := Vector2i(x, 0)
		var info: Dictionary = nav.cell_debug(cell)
		strip.append("%d:%s tile=%s" % [
			cell.x,
			info.get("terrain_name", "unknown"),
			str(info.get("source_tile", Vector2i.ZERO)),
		])
	print("nav_grid_check: saved %s" % output_path)
	print("nav_grid_check: top-left nav strip %s" % ", ".join(strip))
	_compare_dme_chunk_tiles(debug_dir, xbf)
	quit()


func _compare_dme_chunk_tiles(debug_dir: String, xbf) -> void:
	var dme_path := debug_dir.path_join("debug.dme")
	if not FileAccess.file_exists(dme_path):
		return

	var tiles := _load_dme_chunk_tiles(dme_path)
	if tiles.is_empty():
		push_warning("nav_grid_check: no CHUNKTILE data in %s" % dme_path)
		return

	var exact := 0
	for row in 96:
		for col in 96:
			if xbf.tile_at(col, row) == tiles[row * 96 + col]:
				exact += 1

	var control := PackedStringArray()
	for col in 12:
		control.append("%d:%s" % [col, _source_type_name(xbf.tile_at(col, 0))])

	print("nav_grid_check: xbf tile grid offset=%d size=%s dme_exact=%d/9216" % [
		xbf.tile_grid_file_offset,
		str(xbf.tile_grid_size),
		exact,
	])
	print("nav_grid_check: xbf tile row0 %s" % ", ".join(control))


func _load_dme_chunk_tiles(path: String) -> PackedInt32Array:
	var values := PackedInt32Array()
	var in_chunk := false
	var text := FileAccess.get_file_as_string(path)
	for line in text.split("\n", false):
		var stripped := line.strip_edges()
		if stripped == "CHUNKTILE":
			in_chunk = true
			continue
		if stripped == "CHUNKTILEEND":
			break
		if not in_chunk or stripped.is_empty():
			continue
		var nums := stripped.split(" ", false)
		for i in range(0, nums.size(), 2):
			values.append(int(nums[i]))
	return values


func _source_type_name(type_id: int) -> String:
	match type_id:
		0:
			return "sand"
		1:
			return "rock"
		2:
			return "cliff"
		3:
			return "nonbuildrock"
		4:
			return "infantryrock"
		5:
			return "dustbowl"
		6:
			return "mapedge"
		7:
			return "ramp"
		_:
			return "unknown"
