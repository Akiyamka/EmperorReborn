class_name MapNavigationGrid
extends RefCounted

const NAV_SIZE := 256

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


func load_baked(data: BakedMapData) -> bool:
	if data == null:
		push_error("MapNavigationGrid: baked map data is missing")
		return false
	return load_generated(
		data.source_map_dir,
		data.nav_world_bounds,
		data.world_scale,
		data.nav_cpf_values,
		data.nav_terrain_type,
		data.nav_source_tile_x,
		data.nav_source_tile_y,
		data.nav_spice_value,
		data.nav_pass_mask,
		data.nav_movement_cost,
		data.nav_buildable,
		data.nav_cpf_report,
		data.nav_report,
		data.resource_path
	)


func load_generated(
		generated_map_dir: String,
		generated_world_bounds: AABB,
		_generated_world_scale: float,
		generated_cpf_values: PackedInt32Array,
		generated_terrain_type: PackedInt32Array,
		generated_source_tile_x: PackedInt32Array,
		generated_source_tile_y: PackedInt32Array,
		generated_spice_value: PackedByteArray,
		generated_pass_mask: PackedInt32Array,
		generated_movement_cost: PackedFloat32Array,
		generated_buildable: PackedByteArray,
		generated_cpf_report: Dictionary,
		generated_nav_report: Dictionary,
		error_context := ""
	) -> bool:
	var total := NAV_SIZE * NAV_SIZE
	if generated_world_bounds.size.x <= 0.0 or generated_world_bounds.size.z <= 0.0:
		push_error("MapNavigationGrid: baked navigation bounds are invalid in %s" % error_context)
		return false
	if generated_cpf_values.size() != total or generated_terrain_type.size() != total or generated_source_tile_x.size() != total or generated_source_tile_y.size() != total:
		push_error("MapNavigationGrid: baked nav arrays have invalid size in %s" % error_context)
		return false
	if generated_spice_value.size() != total or generated_pass_mask.size() != total or generated_movement_cost.size() != total or generated_buildable.size() != total:
		push_error("MapNavigationGrid: baked nav attributes have invalid size in %s" % error_context)
		return false

	map_dir = generated_map_dir
	world_bounds = generated_world_bounds
	cpf_values = generated_cpf_values
	terrain_type = generated_terrain_type
	source_tile_x = generated_source_tile_x
	source_tile_y = generated_source_tile_y
	spice_value = generated_spice_value
	pass_mask = generated_pass_mask
	movement_cost = generated_movement_cost
	buildable = generated_buildable
	cpf_report = generated_cpf_report
	nav_report = generated_nav_report
	_is_loaded = true
	return true


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
	if not _is_loaded or not _in_bounds(grid_position.x, grid_position.y):
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
	if not _is_loaded:
		return ERR_UNCONFIGURED
	var image := Image.create(NAV_SIZE, NAV_SIZE, false, Image.FORMAT_RGBA8)
	for y in NAV_SIZE:
		for x in NAV_SIZE:
			image.set_pixel(x, y, _terrain_debug_color(terrain_type[_idx(x, y)]))
	if pixel_scale > 1:
		image.resize(NAV_SIZE * pixel_scale, NAV_SIZE * pixel_scale, Image.INTERPOLATE_NEAREST)
	return image.save_png(path)


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
