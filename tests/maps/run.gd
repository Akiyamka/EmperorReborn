extends SceneTree

const BakedMapDataScript := preload("res://scripts/world/map/baked_map_data.gd")
const MapLoaderScript := preload("res://scripts/world/map/map_loader.gd")
const MapNavigationGridScript := preload("res://scripts/world/map/map_navigation_grid.gd")
const MapSpiceLayerScript := preload("res://scripts/world/map/map_spice_layer.gd")

var _assertions := 0
var _failures := 0
var _current_case := ""
var _completion_token := 1000
var _temporary_paths: Array[String] = []


func _initialize() -> void:
	_run_case("baked grid load and coordinate contract", _test_baked_grid_load_and_coordinates)
	_run_case("cell debug contract", _test_cell_debug_contract)
	_run_case("dynamic spice harvesting and replenishment", _test_dynamic_spice_harvesting_and_replenishment)
	_run_case("spice mound source-grid mapping", _test_spice_mound_source_grid_mapping)
	_run_case("malformed baked data is atomic", _test_malformed_baked_data_is_atomic)
	_run_case("grid reload semantics", _test_grid_reload_semantics)
	_run_case("map loader failed replacement is atomic", _test_map_loader_failed_replacement_is_atomic)
	_run_case("map loader initial failure stays empty", _test_map_loader_initial_failure_stays_empty)
	_run_case("map loader rejects wrong resource types atomically", _test_map_loader_wrong_resource_type_is_atomic)
	_cleanup_temporary_files()

	if _failures > 0:
		printerr("Map runtime tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("Map runtime tests: %d assertions passed" % _assertions)
	quit(0)


func _run_case(case_name: String, test: Callable) -> void:
	_current_case = case_name
	_completion_token += 1
	var token := _completion_token
	var failures_before := _failures
	var completed: Variant = test.call(token)
	if completed != token:
		_failures += 1
		printerr("FAIL: %s: case did not return its completion token" % case_name)
		return
	if _failures == failures_before:
		print("PASS: %s" % case_name)


func _test_baked_grid_load_and_coordinates(token: int) -> int:
	var data = _valid_data("grid-contract", AABB(Vector3(10.0, 7.0, 20.0), Vector3(256.0, 3.0, 512.0)))
	var grid = MapNavigationGridScript.new()
	_expect(grid.load_baked(data), "consistent baked data must load")
	_expect(grid.is_loaded(), "a successful baked load must mark the grid loaded")
	_expect(grid.map_dir == "grid-contract" and grid.world_bounds == data.nav_world_bounds, "loaded grid must expose baked source and bounds")
	_expect(grid.world_to_grid(Vector3(10.0, 0.0, 20.0)) == Vector2i.ZERO, "minimum world edge must map to the first cell")
	_expect(grid.world_to_grid(Vector3(266.0, 0.0, 532.0)) == Vector2i(255, 255), "maximum world edge must map to the last cell")
	_expect(grid.world_to_grid(Vector3(-10.0, 0.0, 1000.0)) == Vector2i(0, 255), "world conversion must clamp outside bounds")
	_expect(grid.grid_to_world(Vector2i.ZERO) == Vector3(10.5, 7.0, 21.0), "centered grid conversion must return the cell center")
	_expect(grid.grid_to_world(Vector2i(255, 255), false) == Vector3(265.0, 7.0, 530.0), "uncentered last cell must return its minimum corner")
	return token


func _test_cell_debug_contract(token: int) -> int:
	var data = _valid_data("cell-debug")
	var cell := Vector2i(3, 4)
	var index := cell.y * MapNavigationGridScript.NAV_SIZE + cell.x
	data.nav_cpf_values[index] = 77
	data.nav_terrain_type[index] = MapNavigationGridScript.TERRAIN_ROCK
	data.nav_source_tile_x[index] = 12
	data.nav_source_tile_y[index] = 34
	data.nav_spice_value[index] = 9
	data.nav_pass_mask[index] = MapNavigationGridScript.PASS_GROUND | MapNavigationGridScript.PASS_AIR
	data.nav_movement_cost[index] = 1.0
	data.nav_buildable[index] = 1
	var grid = MapNavigationGridScript.new()
	_expect(grid.load_baked(data), "debug fixture must load")
	var info: Dictionary = grid.cell_debug(cell)
	_expect(info.get("valid") == true and info.get("grid") == cell and info.get("world_center") == grid.grid_to_world(cell), "valid debug data must identify the requested cell and center")
	_expect(info.get("source_tile") == Vector2i(12, 34) and info.get("cpf_raw") == 77, "debug data must expose baked source tile and CPF value")
	_expect(info.get("terrain_type") == MapNavigationGridScript.TERRAIN_ROCK and info.get("terrain_name") == "rock", "debug data must expose terrain id and name")
	_expect(info.get("spice") == 9 and info.get("pass_mask") == MapNavigationGridScript.PASS_GROUND | MapNavigationGridScript.PASS_AIR, "debug data must expose spice and passability")
	_expect(is_equal_approx(info.get("movement_cost"), 1.0) and info.get("buildable") == true, "debug data must expose movement cost and buildability")
	var outside: Dictionary = grid.cell_debug(Vector2i(-1, 256))
	_expect(outside == {"valid": false, "grid": Vector2i(-1, 256)}, "out-of-bounds debug data must contain only invalid grid identity")
	return token


func _test_dynamic_spice_harvesting_and_replenishment(token: int) -> int:
	var data = _valid_data("dynamic-spice")
	var cell := Vector2i(12, 34)
	data.nav_spice_value[cell.y * MapNavigationGridScript.NAV_SIZE + cell.x] = 200
	var grid = MapNavigationGridScript.new()
	_expect(grid.load_baked(data), "dynamic spice fixture must load its navigation grid")
	var layer = MapSpiceLayerScript.new()
	_expect(layer.load_baked(data, grid), "dynamic spice layer must load from baked initial state")
	_expect(layer.spice_at(cell) == 200, "the runtime layer must preserve initial baked spice density")
	_expect(layer.nearest_spice_cell(Vector2i.ZERO) == cell, "the runtime layer must locate the nearest available spice cell")
	_expect(layer.take_spice(cell, 75) == 75 and layer.spice_at(cell) == 125, "harvesting must return and remove the requested available spice")
	_expect(data.nav_spice_value[cell.y * MapNavigationGridScript.NAV_SIZE + cell.x] == 200, "runtime harvesting must not mutate baked initial state")
	_expect(grid.cell_debug(cell).get("spice") == 125, "harvesting must keep navigation spice lookup synchronized")
	_expect(layer.take_spice(cell, 200) == 125 and layer.spice_at(cell) == 0, "harvesting must stop at an exhausted field")
	_expect(layer.add_spice(cell, 300) == 255 and layer.spice_at(cell) == 255, "regeneration must saturate the cell at byte density")
	_expect(layer.spice_mask_texture() != null, "the dynamic field must expose its visual mask texture")
	_expect(not layer.set_spice(Vector2i(-1, 0), 10), "runtime mutations outside the map must be rejected")
	_expect(layer.add_spice(Vector2i(-1, 0), 10) == 0, "regeneration outside the map must not report added spice")
	return token


func _test_spice_mound_source_grid_mapping(token: int) -> int:
	var data = _valid_data("spice-mounds")
	data.nav_report["source_spice_grid_size"] = Vector2i(128, 128)
	data.spice_mound_cells.append(Vector2i(4, 5))
	var grid = MapNavigationGridScript.new()
	_expect(grid.load_baked(data), "spice mound fixture must load its navigation grid")
	var layer = MapSpiceLayerScript.new()
	_expect(layer.load_baked(data, grid), "spice mound layer must load source cells")
	_expect(layer.has_spice_mound(Vector2i(8, 10)) and layer.has_spice_mound(Vector2i(9, 11)), "one 128-grid mound cell must cover its corresponding 2x2 navigation cells")
	_expect(not layer.has_spice_mound(Vector2i(10, 10)), "a mound mask must not leak into its neighboring source cell")
	_expect(layer.set_spice_mound(Vector2i(8, 10), false) and not layer.has_spice_mound(Vector2i(8, 10)) and not layer.has_spice_mound(Vector2i(9, 11)), "a consumed bloom must remove its complete source-grid footprint")
	return token


func _test_malformed_baked_data_is_atomic(token: int) -> int:
	var grid = MapNavigationGridScript.new()
	var bad_bounds = _valid_data("bad-bounds", AABB(Vector3.ZERO, Vector3(0.0, 1.0, 16.0)))
	_expect(not grid.load_baked(bad_bounds), "zero-width navigation bounds must be rejected")
	_expect(not grid.is_loaded() and grid.cell_debug(Vector2i.ZERO).get("valid") == false, "an initial rejected load must not expose a partial grid")

	var valid = _valid_data("stable", AABB(Vector3(1.0, 2.0, 3.0), Vector3(16.0, 1.0, 16.0)))
	valid.nav_terrain_type[0] = MapNavigationGridScript.TERRAIN_ROCK
	_expect(grid.load_baked(valid), "a valid load after rejection must succeed")
	var original_bounds: AABB = grid.world_bounds
	var original_debug: Dictionary = grid.cell_debug(Vector2i.ZERO)

	var bad_terrain = _valid_data("bad-terrain", AABB(Vector3.ZERO, Vector3(32.0, 1.0, 32.0)))
	bad_terrain.nav_terrain_type.resize(MapNavigationGridScript.NAV_SIZE * MapNavigationGridScript.NAV_SIZE - 1)
	_expect(not grid.load_baked(bad_terrain), "short terrain arrays must be rejected")
	_expect(grid.is_loaded() and grid.world_bounds == original_bounds and grid.cell_debug(Vector2i.ZERO) == original_debug, "rejected array data must preserve the prior loaded grid")

	var bad_cpf = _valid_data("bad-cpf", AABB(Vector3.ZERO, Vector3(32.0, 1.0, 32.0)))
	bad_cpf.nav_cpf_values.resize(MapNavigationGridScript.NAV_SIZE * MapNavigationGridScript.NAV_SIZE - 1)
	_expect(not grid.load_baked(bad_cpf), "short CPF arrays must be rejected")
	_expect(grid.is_loaded() and grid.map_dir == "stable", "all rejected baked arrays must leave the prior grid intact")
	return token


func _test_grid_reload_semantics(token: int) -> int:
	var grid = MapNavigationGridScript.new()
	var first = _valid_data("first", AABB(Vector3.ZERO, Vector3(16.0, 1.0, 16.0)))
	var second = _valid_data("second", AABB(Vector3(20.0, 0.0, 30.0), Vector3(32.0, 1.0, 64.0)))
	_expect(grid.load_baked(first), "the first valid grid load must succeed")
	_expect(grid.load_baked(second), "a valid replacement grid load must succeed")
	_expect(grid.is_loaded() and grid.map_dir == "second" and grid.world_bounds == second.nav_world_bounds, "a successful replacement must atomically replace the loaded grid")
	return token


func _test_map_loader_failed_replacement_is_atomic(token: int) -> int:
	var valid_path := _save_temporary_data(_valid_data("loader-valid", AABB(Vector3(4.0, 5.0, 6.0), Vector3(16.0, 1.0, 16.0))), "valid")
	var malformed = _valid_data("loader-malformed", AABB(Vector3(40.0, 0.0, 60.0), Vector3(32.0, 1.0, 32.0)))
	malformed.nav_buildable.resize(MapNavigationGridScript.NAV_SIZE * MapNavigationGridScript.NAV_SIZE - 1)
	var malformed_path := _save_temporary_data(malformed, "malformed")
	var loader = MapLoaderScript.new()
	loader.sun_path = NodePath("NoSun")
	loader.environment_path = NodePath("NoEnvironment")
	loader.load_map(valid_path)
	_expect(loader.map_data != null and loader.navigation_grid != null and loader.navigation_grid.is_loaded(), "a valid resource must initialize all map loader state")
	var original_data = loader.map_data
	var original_grid = loader.navigation_grid
	var original_spice_layer = loader.spice_layer
	var original_aabb: AABB = loader.terrain_aabb
	loader.load_map(malformed_path)
	_expect(loader.map_data == original_data and loader.navigation_grid == original_grid and loader.spice_layer == original_spice_layer and loader.terrain_aabb == original_aabb, "a malformed replacement must preserve the last valid map state")
	loader.load_map("user://missing-map-contract-fixture.tres")
	_expect(loader.map_data == original_data and loader.navigation_grid == original_grid and loader.terrain_aabb == original_aabb, "a missing replacement must preserve the last valid map state")
	loader.free()
	return token


func _test_map_loader_initial_failure_stays_empty(token: int) -> int:
	var malformed = _valid_data("initial-malformed", AABB(Vector3.ZERO, Vector3(16.0, 1.0, 16.0)))
	malformed.nav_source_tile_y.resize(MapNavigationGridScript.NAV_SIZE * MapNavigationGridScript.NAV_SIZE - 1)
	var malformed_path := _save_temporary_data(malformed, "initial-malformed")
	var recovery_bounds := AABB(Vector3(8.0, 2.0, 12.0), Vector3(24.0, 1.0, 32.0))
	var recovery_path := _save_temporary_data(_valid_data("initial-recovery", recovery_bounds), "initial-recovery")
	var loader = MapLoaderScript.new()
	loader.load_map("user://missing-initial-map-contract-fixture.tres")
	_expect(loader.map_data == null and loader.navigation_grid == null and loader.terrain_aabb == AABB(), "an initial missing map must leave the loader empty")
	loader.load_map(malformed_path)
	_expect(loader.map_data == null and loader.navigation_grid == null and loader.terrain_aabb == AABB(), "an initial malformed map must leave the loader empty")
	loader.load_map(recovery_path)
	_expect(loader.map_data != null and loader.map_data.source_map_dir == "initial-recovery" and loader.navigation_grid != null and loader.navigation_grid.is_loaded() and loader.navigation_grid.world_bounds == recovery_bounds and loader.terrain_aabb == recovery_bounds, "a valid map after initial failures must atomically populate loader data, grid, and bounds")
	loader.free()
	return token


func _test_map_loader_wrong_resource_type_is_atomic(token: int) -> int:
	var wrong_resource_path := _save_temporary_resource(Resource.new(), "wrong-resource")
	var initial_valid_path := _save_temporary_data(_valid_data("wrong-resource-initial"), "wrong-resource-initial")
	var recovery_bounds := AABB(Vector3(32.0, 2.0, 48.0), Vector3(24.0, 1.0, 32.0))
	var recovery_path := _save_temporary_data(_valid_data("wrong-resource-recovery", recovery_bounds), "wrong-resource-recovery")
	var loader = MapLoaderScript.new()
	loader.load_map(wrong_resource_path)
	_expect(loader.map_data == null and loader.navigation_grid == null and loader.terrain_aabb == AABB(), "an initial wrong resource type must leave the loader empty")
	loader.load_map(initial_valid_path)
	_expect(loader.map_data != null and loader.map_data.source_map_dir == "wrong-resource-initial" and loader.navigation_grid != null and loader.navigation_grid.is_loaded(), "a valid map after an initial wrong resource type must initialize the loader")
	var original_data = loader.map_data
	var original_grid = loader.navigation_grid
	var original_aabb: AABB = loader.terrain_aabb
	loader.load_map(wrong_resource_path)
	_expect(loader.map_data == original_data and loader.navigation_grid == original_grid and loader.terrain_aabb == original_aabb, "a wrong resource replacement must preserve the last valid map state")
	loader.load_map(recovery_path)
	_expect(loader.map_data != null and loader.map_data.source_map_dir == "wrong-resource-recovery" and loader.navigation_grid != null and loader.navigation_grid.world_bounds == recovery_bounds and loader.terrain_aabb == recovery_bounds, "a valid replacement after a wrong resource type must recover atomically")
	loader.free()
	return token


func _valid_data(source_dir: String, bounds := AABB(Vector3.ZERO, Vector3(16.0, 1.0, 16.0))) -> BakedMapData:
	var data = BakedMapDataScript.new()
	var total := MapNavigationGridScript.NAV_SIZE * MapNavigationGridScript.NAV_SIZE
	data.source_map_dir = source_dir
	data.world_scale = 0.0625
	data.terrain_aabb = bounds
	data.nav_world_bounds = bounds
	data.nav_cpf_values.resize(total)
	data.nav_terrain_type.resize(total)
	data.nav_source_tile_x.resize(total)
	data.nav_source_tile_y.resize(total)
	data.nav_spice_value.resize(total)
	data.nav_pass_mask.resize(total)
	data.nav_movement_cost.resize(total)
	data.nav_buildable.resize(total)
	return data


func _save_temporary_data(data: BakedMapData, suffix: String) -> String:
	return _save_temporary_resource(data, suffix)


func _save_temporary_resource(resource: Resource, suffix: String) -> String:
	var path := "user://map-runtime-contract-%d-%s.tres" % [Time.get_ticks_usec(), suffix]
	var error := ResourceSaver.save(resource, path)
	_expect(error == OK, "temporary %s resource must save" % suffix)
	_temporary_paths.append(path)
	return path


func _cleanup_temporary_files() -> void:
	for path in _temporary_paths:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_temporary_paths.clear()


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])
