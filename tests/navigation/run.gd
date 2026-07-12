extends SceneTree

const NavigationMapScript := preload("res://scripts/units/navigation/unit_navigation_map.gd")
const NavigationPlannerScript := preload("res://scripts/units/navigation/unit_navigation_planner.gd")
const NavigationSystemScript := preload("res://scripts/units/navigation/unit_navigation_system.gd")

var _assertions := 0
var _failures := 0


class FakeUnit extends Node3D:
	var move_speed := 6.0
	var arrival_radius := 0.2
	var unit_config := RuleEntityConfig.new()
	var managed := false
	var destination := Vector3.ZERO

	func _init(size := 1.0, infantry := false) -> void:
		unit_config.fields = {"size": size, "infantry": infantry, "can_fly": false}
		unit_config.lists = {"terrain": [&"Rock"]}

	func set_navigation_managed(active: bool) -> void:
		managed = active

	func set_navigation_destination(value: Vector3) -> void:
		destination = value

	func navigation_step(value: Vector3, delta: float) -> void:
		global_position += value * delta

	func is_enemy_of(_player_id: int) -> bool:
		return false


func _initialize() -> void:
	await process_frame
	var grid := _make_grid()
	_test_synchronous_paths(grid)
	_test_no_stop_cells(grid)
	_test_immediate_movement(grid)
	_test_slots_and_collision(grid)
	if _failures > 0:
		printerr("Unit navigation tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("Unit navigation tests: %d assertions passed" % _assertions)
	quit(0)


func _test_synchronous_paths(grid: MapNavigationGrid) -> void:
	var runtime_map := NavigationMapScript.new()
	_expect(runtime_map.setup(grid), "runtime map must accept a loaded baked grid")
	_expect(runtime_map.replace_blocked_cells(_wall_cells()), "dynamic walls must increment the map revision")

	var planner := NavigationPlannerScript.new()
	planner.setup(runtime_map)
	var rock_mask := 1 << MapNavigationGrid.TERRAIN_ROCK

	var cold_start := Time.get_ticks_usec()
	planner.prewarm(MapNavigationGrid.PASS_VEHICLE, 0, rock_mask)
	var cold_ms := float(Time.get_ticks_usec() - cold_start) / 1000.0
	var warm_start := Time.get_ticks_usec()
	var path: Array[Vector2i] = planner.find_path(
		Vector2i(20, 128), Vector2i(40, 100), MapNavigationGrid.PASS_VEHICLE, 0, rock_mask
	)
	var warm_ms := float(Time.get_ticks_usec() - warm_start) / 1000.0
	print("Navigation benchmark: profile bake %.2f ms, detour path %.2f ms" % [cold_ms, warm_ms])
	_expect(cold_ms < 50.0, "the one-off profile bake must stay within a loading hitch")
	_expect(warm_ms < 5.0, "a detour path must compute within one frame")
	_expect(not path.is_empty() and path[path.size() - 1] == Vector2i(40, 100), "synchronous A* must find an indirect route")
	var crossed_opening := false
	for path_cell in path:
		if path_cell.x == 30 and path_cell.y >= 126 and path_cell.y <= 130:
			crossed_opening = true
	_expect(crossed_opening, "synchronous A* must route through the wall opening")

	var narrow: Array[Vector2i] = planner.find_path(
		Vector2i(55, 128), Vector2i(70, 128), MapNavigationGrid.PASS_VEHICLE, 0, rock_mask
	)
	_expect(not narrow.is_empty() and narrow[narrow.size() - 1] == Vector2i(70, 128), "a single-cell gap must pass clearance zero")
	var wide: Array[Vector2i] = planner.find_path(
		Vector2i(55, 128), Vector2i(70, 128), MapNavigationGrid.PASS_VEHICLE, 1, rock_mask
	)
	_expect(not wide.is_empty() and wide[wide.size() - 1].x < 60, "clearance one must stop before a single-cell gap and go as close as possible")


func _test_no_stop_cells(grid: MapNavigationGrid) -> void:
	var apron := {}
	for y in range(100, 108):
		for x in range(100, 108):
			apron[Vector2i(x, y)] = true

	var runtime_map := NavigationMapScript.new()
	runtime_map.setup(grid)
	_expect(runtime_map.replace_blocked_cells({}, apron), "a no-stop overlay must increment the map revision")
	_expect(runtime_map.is_passable(Vector2i(103, 103), MapNavigationGrid.PASS_VEHICLE), "no-stop cells must stay traversable")
	_expect(not runtime_map.is_stoppable(Vector2i(103, 103), MapNavigationGrid.PASS_VEHICLE), "no-stop cells must not be valid stops")

	var planner := NavigationPlannerScript.new()
	planner.setup(runtime_map)
	var rock_mask := 1 << MapNavigationGrid.TERRAIN_ROCK
	var exit_path: Array[Vector2i] = planner.find_path(
		Vector2i(103, 103), Vector2i(103, 120), MapNavigationGrid.PASS_VEHICLE, 0, rock_mask
	)
	var exit_touches_apron := false
	for path_cell in exit_path:
		exit_touches_apron = exit_touches_apron or apron.has(path_cell)
	_expect(not exit_path.is_empty() and not exit_touches_apron, "a unit spawned on the apron must get a route that starts outside it")
	var through: Array[Vector2i] = planner.find_path(
		Vector2i(103, 95), Vector2i(103, 112), MapNavigationGrid.PASS_VEHICLE, 0, rock_mask
	)
	var crossed_apron := false
	for path_cell in through:
		crossed_apron = crossed_apron or apron.has(path_cell)
	_expect(not through.is_empty() and through[through.size() - 1] == Vector2i(103, 112) and not crossed_apron, "routes must go around the apron, never through it")
	var into_apron: Array[Vector2i] = planner.find_path(
		Vector2i(103, 120), Vector2i(103, 103), MapNavigationGrid.PASS_VEHICLE, 0, rock_mask
	)
	_expect(not into_apron.is_empty() and not apron.has(into_apron[into_apron.size() - 1]), "a destination on the apron must snap to the nearest stoppable cell")

	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	navigation.set_physics_process(false)
	_expect(navigation.setup(grid), "navigation system must initialize")
	navigation.runtime_map.replace_blocked_cells({}, apron)
	var clicker := FakeUnit.new()
	root.add_child(clicker)
	clicker.global_position = Vector3(103.5, 0.0, 120.5)
	var assignments := navigation.command_move([clicker], Vector3(103.5, 0.0, 103.5), NavigationSystemScript.MoveMode.FREE)
	var slot_cell: Vector2i = grid.world_to_grid(assignments[0]["position"])
	_expect(not apron.has(slot_cell), "a movement slot must never land on a no-stop cell")

	var produced := FakeUnit.new()
	root.add_child(produced)
	produced.global_position = Vector3(103.5, 0.0, 103.5)
	navigation.command_move([produced], Vector3(103.5, 0.0, 120.5), NavigationSystemScript.MoveMode.FREE)
	_expect(bool(navigation.agent_debug(produced)["route_ready"]), "a unit inside the apron must still get a route immediately")
	for _iteration in 200:
		navigation.call("_navigation_tick", 0.05)
	_expect(produced.global_position.distance_to(Vector3(103.5, 0.0, 120.5)) < 2.0, "a unit produced inside the apron must walk out and reach its destination")

	navigation.queue_free()
	clicker.queue_free()
	produced.queue_free()


func _test_immediate_movement(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	navigation.set_physics_process(false)
	_expect(navigation.setup(grid), "navigation system must initialize")
	_expect(navigation.runtime_map.replace_blocked_cells(_wall_cells()), "walls must apply to the match runtime map")

	var unit := FakeUnit.new()
	root.add_child(unit)
	unit.global_position = Vector3(20.5, 0.0, 128.5)
	navigation.command_move([unit], Vector3(40.5, 0.0, 100.5), NavigationSystemScript.MoveMode.FREE)
	_expect(bool(navigation.agent_debug(unit)["route_ready"]), "an obstructed order must have its route ready in the same frame")
	var start_position := unit.global_position
	for _iteration in 10:
		navigation.call("_navigation_tick", 0.05)
	_expect(unit.global_position.distance_to(start_position) > 1.0, "the unit must start moving within half a second of the order")

	navigation.queue_free()
	unit.queue_free()


func _test_slots_and_collision(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	navigation.set_physics_process(false)
	_expect(navigation.setup(grid), "navigation system must initialize")
	var units: Array[FakeUnit] = []
	for index in 8:
		var unit := FakeUnit.new()
		root.add_child(unit)
		unit.global_position = Vector3(10.0 + float(index), 0.0, 10.0)
		units.append(unit)
	var assignments := navigation.command_move(units, Vector3(80.0, 0.0, 80.0), NavigationSystemScript.MoveMode.FREE)
	_expect(assignments.size() == units.size(), "a group command must synchronously assign every destination")
	_expect(navigation.command_log().size() == 1, "movement commands must be recorded for bug-report replay")
	for unit in units:
		_expect(bool(navigation.agent_debug(unit)["route_ready"]), "every unit in a group must have a route immediately")
	var unique_slots := {}
	for assignment in assignments:
		unique_slots[assignment["position"]] = true
	_expect(unique_slots.size() == units.size(), "free-crowd destinations must not overlap")
	units[0].move_speed = 9.0
	units[1].move_speed = 3.0
	navigation.command_move([units[0], units[1]], Vector3(90.0, 0.0, 90.0), NavigationSystemScript.MoveMode.FORMATION)
	_expect(is_equal_approx(float(navigation.agent_debug(units[0])["group_speed"]), 3.0), "formation speed must match its slowest member")

	var left := FakeUnit.new()
	var right := FakeUnit.new()
	root.add_child(left)
	root.add_child(right)
	left.global_position = Vector3(100.0, 0.0, 100.0)
	right.global_position = Vector3(102.0, 0.0, 100.0)
	navigation.command_move([left], Vector3(110.0, 0.0, 100.0))
	navigation.command_move([right], Vector3(90.0, 0.0, 100.0))
	var minimum_distance := INF
	for _iteration in 80:
		navigation.call("_navigation_tick", 0.05)
		minimum_distance = minf(minimum_distance, left.global_position.distance_to(right.global_position))
	_expect(minimum_distance >= 0.82, "opposing swept-disc agents must never pass through each other")

	navigation.queue_free()
	for unit in units:
		unit.queue_free()
	left.queue_free()
	right.queue_free()


## A vertical wall at x=30 with an opening at y 126..130, plus a wall at x=60
## with a single-cell gap at y=128 for clearance checks.
func _wall_cells() -> Dictionary:
	var walls := {}
	for y in MapNavigationGrid.NAV_SIZE:
		if y < 126 or y > 130:
			walls[Vector2i(30, y)] = true
		if y != 128:
			walls[Vector2i(60, y)] = true
	return walls


func _make_grid() -> MapNavigationGrid:
	var total := MapNavigationGrid.NAV_SIZE * MapNavigationGrid.NAV_SIZE
	var cpf := PackedInt32Array()
	var terrain := PackedInt32Array()
	var source_x := PackedInt32Array()
	var source_y := PackedInt32Array()
	var spice := PackedByteArray()
	var pass_mask := PackedInt32Array()
	var movement_cost := PackedFloat32Array()
	var buildable := PackedByteArray()
	for array in [cpf, terrain, source_x, source_y, spice, pass_mask, movement_cost, buildable]:
		array.resize(total)
	terrain.fill(MapNavigationGrid.TERRAIN_ROCK)
	pass_mask.fill(MapNavigationGrid.PASS_GROUND | MapNavigationGrid.PASS_AIR)
	movement_cost.fill(1.0)
	buildable.fill(1)
	var grid := MapNavigationGrid.new()
	grid.load_generated(
		"test", AABB(Vector3.ZERO, Vector3(256.0, 1.0, 256.0)), 1.0,
		cpf, terrain, source_x, source_y, spice, pass_mask, movement_cost, buildable, {}, {}
	)
	return grid


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s" % message)
