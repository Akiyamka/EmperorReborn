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
	_test_budgeted_flow_field(grid)
	_test_slots_and_collision(grid)
	if _failures > 0:
		printerr("Unit navigation tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("Unit navigation tests: %d assertions passed" % _assertions)
	quit(0)


func _test_budgeted_flow_field(grid: MapNavigationGrid) -> void:
	var runtime_map := NavigationMapScript.new()
	_expect(runtime_map.setup(grid), "runtime map must accept a loaded baked grid")
	var wall := {}
	for y in MapNavigationGrid.NAV_SIZE:
		if y < 126 or y > 130:
			wall[Vector2i(30, y)] = true
	_expect(runtime_map.replace_blocked_cells(wall), "dynamic wall must increment the map revision")

	var planner := NavigationPlannerScript.new()
	planner.setup(runtime_map)
	planner.expansion_budget_per_tick = 8
	var field = planner.request_field(Vector2i(40, 128), MapNavigationGrid.PASS_VEHICLE, 0, 1 << MapNavigationGrid.TERRAIN_ROCK)
	planner.process()
	_expect(not field.complete, "a small expansion budget must time-slice field generation")
	planner.expansion_budget_per_tick = 256
	var benchmark_start := Time.get_ticks_usec()
	planner.process()
	var benchmark_ms := float(Time.get_ticks_usec() - benchmark_start) / 1000.0
	print("Navigation benchmark: 256 expansions = %.2f ms" % [benchmark_ms])
	_expect(benchmark_ms < 10.0, "one planner tick must stay below the navigation frame budget")
	for _iteration in 400:
		planner.process()
		if field.complete:
			break
	_expect(field.complete, "the queued field must eventually complete")
	_expect(field.has_route_from(Vector2i(20, 128)), "the field must find the wall opening")
	var cell := Vector2i(20, 128)
	for _step in 128:
		if cell == field.target_cell:
			break
		cell = field.next_cell(cell)
	_expect(cell == field.target_cell, "following decreasing integration cost must reach the target")

	planner.expansion_budget_per_tick = 256
	var query = planner.request_path(
		Vector2i(20, 120), Vector2i(40, 120), MapNavigationGrid.PASS_VEHICLE, 0,
		1 << MapNavigationGrid.TERRAIN_ROCK
	)
	var path_ticks := 0
	while not query.complete and not query.failed and path_ticks < 20:
		planner.process()
		path_ticks += 1
	_expect(query.complete, "individual A* must find an indirect route")
	_expect(path_ticks <= 6, "individual detours must become ready in well under one second")
	var crossed_opening := false
	for path_cell in query.cells:
		if path_cell.x == 30 and path_cell.y >= 126 and path_cell.y <= 130:
			crossed_opening = true
	_expect(crossed_opening, "individual A* must route through the wall opening")


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
	_expect(navigation.planner.pending_count() == 0, "a clear direct order must not build an unused flow field")
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
	for _iteration in 100:
		navigation.planner.process()
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
