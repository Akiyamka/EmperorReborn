extends SceneTree

const NavigationMapScript := preload("res://scripts/units/navigation/unit_navigation_map.gd")
const NavigationPlannerScript := preload("res://scripts/units/navigation/unit_navigation_planner.gd")
const NavigationSystemScript := preload("res://scripts/units/navigation/unit_navigation_system.gd")
const BuildingFootprintScript := preload("res://scripts/buildings/building_footprint.gd")

var _assertions := 0
var _failures := 0


class FakeUnit extends Node3D:
	var move_speed := 6.0
	var arrival_radius := 0.2
	var unit_config := RuleEntityConfig.new()
	var managed := false
	var destination := Vector3.ZERO
	var owner_player_id := 1
	var defer_navigation_orders := false
	var prepared_navigation_targets: Array[Vector3] = []

	func _init(size := 1.0, infantry := false) -> void:
		unit_config.fields = {"size": size, "infantry": infantry, "can_fly": false}
		unit_config.lists = {"terrain": [&"Rock"]}

	func set_navigation_managed(active: bool) -> void:
		managed = active

	func set_navigation_destination(value: Vector3) -> void:
		destination = value

	func prepare_navigation_order(target: Vector3, _exit_point := Vector3.INF, _move_mode := 0) -> bool:
		prepared_navigation_targets.append(target)
		return not defer_navigation_orders

	func navigation_step(value: Vector3, delta: float) -> void:
		global_position += value * delta

	func is_enemy_of(player_id: int) -> bool:
		return owner_player_id != player_id


class FakeBuilding extends Node3D:
	var building_config := RuleEntityConfig.new()

	func _init(rows: Array[String]) -> void:
		building_config.lists = {&"occupy_rows": rows}


func _initialize() -> void:
	await process_frame
	var grid := _make_grid()
	_test_synchronous_paths(grid)
	_test_no_stop_cells(grid)
	_test_unit_navigation_order_api(grid)
	_test_dock_order_has_per_unit_building_access(grid)
	_test_building_marker_navigation_semantics(grid)
	_test_blocked_target_uses_unit_approach_side(grid)
	_test_rotated_building_blockers(grid)
	_test_interior_escape(grid)
	_test_immediate_movement(grid)
	_test_navigation_catch_up_budget(grid)
	_test_slots_and_collision(grid)
	_test_slide_around_stopped_friend(grid)
	_test_group_convergence(grid)
	_test_group_rounds_sharp_corner(grid)
	_test_yield_behaviour(grid)
	_test_command_overrides_yield(grid)
	_test_grid_aligned_slots(grid)
	_test_lane_through_standing_formation(grid)
	_test_overlap_is_squeezed_out(grid)
	_test_large_overlap_spans_spatial_buckets(grid)
	_test_enemy_stays_solid_under_separation(grid)
	_test_elastic_corridor_pass(grid)
	_test_circle_convergence_metrics(grid)
	_test_group_shift_keeps_shape(grid)
	if _failures > 0:
		printerr("Unit navigation tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("Unit navigation tests: %d assertions passed" % _assertions)
	quit(0)


func _test_unit_navigation_order_api(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	navigation.set_physics_process(false)
	_expect(navigation.setup(grid), "navigation system must initialize for the unit order API")
	var unit := FakeUnit.new()
	root.add_child(unit)
	unit.global_position = Vector3(90.5, 0.0, 100.5)
	unit.defer_navigation_orders = true
	var target := Vector3(100.5, 0.0, 100.5)
	var deferred := navigation.command_move([unit], target)
	_expect(deferred.is_empty(), "a unit must be able to defer a route before navigation mutates its agent")
	_expect(unit.prepared_navigation_targets == [target], "navigation must pass the assigned destination through the unit API")
	for _iteration in 20:
		navigation.call("_navigation_tick", 0.05)
	_expect(unit.global_position == Vector3(90.5, 0.0, 100.5), "a deferred navigation order must not move the unit")

	unit.defer_navigation_orders = false
	var accepted := navigation.command_move([unit], target)
	_expect(accepted.size() == 1, "the same unit must be able to accept a later route")
	for _iteration in 100:
		navigation.call("_navigation_tick", 0.05)
	_expect(unit.global_position.distance_to(target) < 1.0, "an accepted route must move after unit preparation")

	navigation.queue_free()
	unit.queue_free()


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
	_expect(
		not exit_path.is_empty() and exit_path[0] == Vector2i(103, 103) and exit_path.back() == Vector2i(103, 120),
		"a route may start on and leave a no-stop cell normally"
	)
	var through: Array[Vector2i] = planner.find_path(
		Vector2i(103, 95), Vector2i(103, 112), MapNavigationGrid.PASS_VEHICLE, 0, rock_mask
	)
	var crossed_apron := false
	for path_cell in through:
		crossed_apron = crossed_apron or apron.has(path_cell)
	_expect(not through.is_empty() and through.back() == Vector2i(103, 112) and crossed_apron, "routes must freely cross a no-stop apron")
	var into_apron: Array[Vector2i] = planner.find_path(
		Vector2i(103, 120), Vector2i(103, 103), MapNavigationGrid.PASS_VEHICLE, 0, rock_mask
	)
	_expect(not into_apron.is_empty() and not apron.has(into_apron[into_apron.size() - 1]), "a destination on the apron must snap to the nearest stoppable cell")
	var explicit_into_apron: Array[Vector2i] = planner.find_path(
		Vector2i(103, 120), Vector2i(103, 103), MapNavigationGrid.PASS_VEHICLE, 0, rock_mask,
		{Vector2i(103, 103): true}
	)
	_expect(
		not explicit_into_apron.is_empty() and explicit_into_apron.back() == Vector2i(103, 103),
		"an explicit no-stop command leg must be able to end on its selected cell"
	)


	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	navigation.set_physics_process(false)
	_expect(navigation.setup(grid), "navigation system must initialize")
	navigation.runtime_map.replace_blocked_cells({}, apron)
	var passer := FakeUnit.new()
	root.add_child(passer)
	passer.global_position = Vector3(103.5, 0.0, 95.5)
	navigation.command_move([passer], Vector3(103.5, 0.0, 112.5), NavigationSystemScript.MoveMode.FREE)
	for _iteration in 100:
		navigation.call("_navigation_tick", 0.05)
	_expect(passer.global_position.distance_to(Vector3(103.5, 0.0, 112.5)) < 2.0, "local steering must drive straight through a no-stop apron")

	var clicker := FakeUnit.new()
	root.add_child(clicker)
	clicker.global_position = Vector3(103.5, 0.0, 120.5)
	var assignments := navigation.command_move([clicker], Vector3(103.5, 0.0, 103.5), NavigationSystemScript.MoveMode.FREE)
	var slot_cell: Vector2i = grid.world_to_grid(assignments[0]["position"])
	_expect(apron.has(slot_cell), "an explicit movement order must retain its selected no-stop destination")
	_expect(bool(navigation.agent_debug(clicker)["vacate_no_stop"]), "the no-stop leg must be marked for automatic evacuation on arrival")
	var entered_apron := false
	for _iteration in 200:
		navigation.call("_navigation_tick", 0.05)
		entered_apron = entered_apron or apron.has(grid.world_to_grid(clicker.global_position))
	var parked_cell: Vector2i = grid.world_to_grid(navigation.agent_debug(clicker)["destination"])
	_expect(entered_apron, "the unit must actually enter the ordered no-stop area before leaving it")
	_expect(
		not apron.has(parked_cell) and clicker.global_position.distance_to(navigation.agent_debug(clicker)["destination"]) < 1.0,
		"arrival on no-stop space must immediately auto-route the unit to the nearest legal parking cell"
	)
	_expect(
		bool(navigation.command_log().back().get("auto_vacate_no_stop", false)),
		"the automatic evacuation must be recorded as a navigation order"
	)

	var produced := FakeUnit.new()
	root.add_child(produced)
	produced.global_position = Vector3(103.5, 0.0, 103.5)
	navigation.command_move([produced], Vector3(103.5, 0.0, 120.5), NavigationSystemScript.MoveMode.FREE)
	_expect(bool(navigation.agent_debug(produced)["route_ready"]), "a unit inside the apron must still get a route immediately")
	for _iteration in 200:
		navigation.call("_navigation_tick", 0.05)
	_expect(produced.global_position.distance_to(Vector3(103.5, 0.0, 120.5)) < 2.0, "a unit produced inside the apron must walk out and reach its destination")

	navigation.queue_free()
	passer.queue_free()
	clicker.queue_free()
	produced.queue_free()


func _test_dock_order_has_per_unit_building_access(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	navigation.set_physics_process(false)
	_expect(navigation.setup(grid), "navigation system must initialize for docking")
	var building_body := {}
	var dock_cells := {}
	for y in range(100, 108):
		for x in range(100, 108):
			var cell := Vector2i(x, y)
			if x >= 103 and x <= 105 and y >= 103:
				dock_cells[cell] = true
			else:
				building_body[cell] = true
	for y in range(108, 112):
		for x in range(103, 106):
			dock_cells[Vector2i(x, y)] = true
	navigation.runtime_map.replace_blocked_cells(building_body, dock_cells)

	var harvester := FakeUnit.new(3.0)
	root.add_child(harvester)
	harvester.global_position = Vector3(96.5, 0.0, 104.5)
	var dock := Vector3(104.5, 0.0, 104.5)
	_expect(navigation.command_dock(harvester, dock, dock_cells), "a reserved harvester must receive a d/p stopping exception")
	_expect(navigation.arrival_tolerance(harvester) > 0.35, "a size-three harvester must use its larger navigation arrival tolerance")
	var crossed_building_body := false
	for _iteration in 200:
		navigation.call("_navigation_tick", 0.05)
		crossed_building_body = crossed_building_body or building_body.has(
			grid.world_to_grid(harvester.global_position)
		)
	_expect(harvester.global_position.distance_to(dock) < 0.6, "the docking harvester must enter and stop on d/p cells")
	_expect(not crossed_building_body, "a docking route from the side must go around b cells")
	var followup := navigation.command_move([harvester], dock)
	_expect(
		bool(followup[0]["vacate_no_stop"]) and bool(navigation.agent_debug(harvester)["vacate_no_stop"]),
		"a normal follow-up order must clear the harvester's old permanent dock exception"
	)

	var ordinary := FakeUnit.new()
	root.add_child(ordinary)
	ordinary.global_position = Vector3(110.5, 0.0, 103.5)
	var assignments := navigation.command_move([ordinary], dock)
	var ordinary_cell: Vector2i = grid.world_to_grid(assignments[0]["position"])
	_expect(
		dock_cells.has(ordinary_cell) and bool(navigation.agent_debug(ordinary)["vacate_no_stop"]),
		"an ordinary order may enter the same d/p cells but must auto-vacate them after arrival"
	)

	navigation.queue_free()
	harvester.queue_free()
	ordinary.queue_free()


func _test_building_marker_navigation_semantics(grid: MapNavigationGrid) -> void:
	var match_root := Node3D.new()
	root.add_child(match_root)
	var building := FakeBuilding.new(["BDPS"])
	building.position = Vector3(100.0, 0.0, 100.0)
	building.add_to_group("buildings")
	match_root.add_child(building)
	var navigation := NavigationSystemScript.new()
	match_root.add_child(navigation)
	navigation.set_physics_process(false)
	_expect(navigation.setup(grid), "navigation must initialize for occupy marker semantics")
	navigation.call("_refresh_building_blockers")
	var footprint: Dictionary = BuildingFootprintScript.nav_cells_by_marker(
		building, building.building_config.list(&"occupy_rows"), grid, 2
	)
	for cell in footprint:
		var marker := String(footprint[cell]).to_lower()
		if marker == "b":
			_expect(navigation.runtime_map.is_blocked(cell), "b occupy cells must remain solid")
		else:
			_expect(
				navigation.runtime_map.is_passable(cell, MapNavigationGrid.PASS_VEHICLE)
					and not navigation.runtime_map.is_stoppable(cell, MapNavigationGrid.PASS_VEHICLE),
				"s/d/p occupy cells must be passable no-stop space"
			)
	match_root.free()


func _test_blocked_target_uses_unit_approach_side(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	navigation.set_physics_process(false)
	_expect(navigation.setup(grid), "navigation must initialize for blocked target approach selection")
	var building_body := {}
	for y in range(100, 108):
		for x in range(100, 108):
			building_body[Vector2i(x, y)] = true
	navigation.runtime_map.replace_blocked_cells(building_body)
	var target := Vector3(103.5, 0.0, 103.5)

	var front_unit := FakeUnit.new(3.0)
	root.add_child(front_unit)
	front_unit.global_position = Vector3(103.5, 0.0, 114.5)
	var front_assignment := navigation.command_move([front_unit], target)[0] as Dictionary
	var front_destination: Vector3 = front_assignment["position"]
	_expect(
		front_destination.z > 108.0 and absf(front_destination.x - target.x) < 2.0,
		"a unit already in front of a blocked target must approach on the front side (got %.1f, %.1f)" % [
			front_destination.x, front_destination.z
		]
	)

	var left_unit := FakeUnit.new(3.0)
	root.add_child(left_unit)
	left_unit.global_position = Vector3(90.5, 0.0, 103.5)
	var left_assignment := navigation.command_move([left_unit], target)[0] as Dictionary
	var left_destination: Vector3 = left_assignment["position"]
	_expect(
		left_destination.x < 99.5 and absf(left_destination.z - target.z) < 2.0,
		"a unit left of a blocked target must approach on the left side (got %.1f, %.1f)" % [
			left_destination.x, left_destination.z
		]
	)

	navigation.queue_free()
	front_unit.queue_free()
	left_unit.queue_free()


func _test_rotated_building_blockers(grid: MapNavigationGrid) -> void:
	var match_root := Node3D.new()
	root.add_child(match_root)
	var building := FakeBuilding.new(["X.", "XS"])
	building.position = Vector3(10.0, 0.0, 10.0)
	building.rotation.y = PI / 2.0
	building.add_to_group("buildings")
	match_root.add_child(building)
	var navigation := NavigationSystemScript.new()
	match_root.add_child(navigation)
	navigation.set_physics_process(false)
	_expect(navigation.setup(grid), "navigation system must initialize with a rotated building")
	_expect(navigation.runtime_map.is_blocked(Vector2i(8, 10)), "rotated solid occupy cells must block their transformed location")
	_expect(
		navigation.runtime_map.is_passable(Vector2i(10, 8), MapNavigationGrid.PASS_VEHICLE)
			and not navigation.runtime_map.is_stoppable(Vector2i(10, 8), MapNavigationGrid.PASS_VEHICLE),
		"the rotated skirt must remain a passable no-stop exit"
	)
	_expect(not navigation.runtime_map.is_blocked(Vector2i(8, 8)), "the stale unrotated blocker location must remain free")
	match_root.queue_free()


## A building footprint: blocked interior at x/y 100..107 with a no-stop apron
## strip in front of it (y 108..111). A unit produced inside gets the
## building's exit point as a mandatory first waypoint and must walk straight
## out through the apron, never through a side or back wall.
func _test_interior_escape(grid: MapNavigationGrid) -> void:
	var interior := {}
	var apron := {}
	for x in range(100, 108):
		for y in range(100, 108):
			interior[Vector2i(x, y)] = true
		for y in range(108, 112):
			apron[Vector2i(x, y)] = true

	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	navigation.set_physics_process(false)
	_expect(navigation.setup(grid), "navigation system must initialize")
	navigation.runtime_map.replace_blocked_cells(interior, apron)
	var produced := FakeUnit.new()
	root.add_child(produced)
	produced.global_position = Vector3(103.5, 0.0, 103.5)
	var destination := Vector3(103.5, 0.0, 120.5)
	var exit_point := Vector3(103.5, 0.0, 113.0)
	navigation.command_move([produced], destination, NavigationSystemScript.MoveMode.FREE, exit_point)
	_expect(bool(navigation.agent_debug(produced)["route_ready"]), "a unit inside the interior must still get a route immediately")
	var first_open_cell := Vector2i(-1, -1)
	for _iteration in 300:
		navigation.call("_navigation_tick", 0.05)
		var cell: Vector2i = grid.world_to_grid(produced.global_position)
		if first_open_cell.x < 0 and not interior.has(cell) and not apron.has(cell):
			first_open_cell = cell
	_expect(first_open_cell.y >= 112, "the unit must emerge in front of the apron, not through a wall")
	_expect(produced.global_position.distance_to(destination) < 2.0, "a unit produced inside the building must walk out and reach its destination")

	navigation.queue_free()
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
	var agent: Dictionary = navigation._agents[unit.get_instance_id()]
	var compact_path: Array = agent["path"]
	_expect(compact_path.size() <= 6,
		"an A* cell route must be simplified to stable corner waypoints (got %d)" % compact_path.size())
	var start_position := unit.global_position
	for _iteration in 10:
		navigation.call("_navigation_tick", 0.05)
	_expect(unit.global_position.distance_to(start_position) > 1.0, "the unit must start moving within half a second of the order")

	navigation.queue_free()
	unit.queue_free()


func _test_navigation_catch_up_budget(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	navigation.set_physics_process(false)
	_expect(navigation.setup(grid), "navigation system must initialize")
	var before: int = navigation._navigation_tick_index
	navigation.call("_physics_process", 1.0)
	_expect(navigation._navigation_tick_index - before == NavigationSystemScript.MAX_CATCH_UP_TICKS,
		"a delayed physics frame must execute only the bounded navigation catch-up budget")
	navigation.queue_free()


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
	var assignments := navigation.command_move(units, Vector3(30.5, 0.0, 30.5), NavigationSystemScript.MoveMode.FREE)
	_expect(assignments.size() == units.size(), "a group command must synchronously assign every destination")
	_expect(navigation.command_log().size() == 1, "movement commands must be recorded for bug-report replay")
	for unit in units:
		_expect(bool(navigation.agent_debug(unit)["route_ready"]), "every unit in a group must have a route immediately")
	for _iteration in 240:
		navigation.call("_navigation_tick", 0.05)
	var claimed: Array[Dictionary] = []
	for unit in units:
		var destination: Vector3 = navigation.agent_debug(unit)["destination"]
		_expect(unit.global_position.distance_to(destination) < 0.6, "every free-move unit must settle on its claimed block")
		claimed.append({"anchor": navigation._parking_anchor(destination, 1), "span": 1})
	for a in claimed.size():
		for b in range(a + 1, claimed.size()):
			_expect(
				not navigation._blocks_conflict(claimed[a]["anchor"], 1, claimed[b]["anchor"], 1),
				"claimed parking blocks must keep a one-cell gap"
			)
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
	var closest_approach := INF
	var largest_detour := 0.0
	for _iteration in 80:
		navigation.call("_navigation_tick", 0.05)
		closest_approach = minf(closest_approach, left.global_position.distance_to(right.global_position))
		largest_detour = maxf(largest_detour, maxf(
			absf(left.global_position.z - 100.0),
			absf(right.global_position.z - 100.0)
		))
	# In the open, counter-movers steer around each other; either way a head-on
	# pair must swap sides cleanly and on time.
	_expect(left.global_position.distance_to(Vector3(110.0, 0.0, 100.0)) < 1.0, "a head-on mover must pass a friendly counter-mover and arrive")
	_expect(right.global_position.distance_to(Vector3(90.0, 0.0, 100.0)) < 1.0, "the opposing mover must arrive as well")
	var open_contact := float(navigation._agents[left.get_instance_id()]["radius"]) \
		+ float(navigation._agents[right.get_instance_id()]["radius"])
	_expect(closest_approach >= open_contact - 0.02,
		"counter-movers in open space must steer instead of squeezing (closest %.2f, contact %.2f)" % [closest_approach, open_contact])
	_expect(largest_detour > open_contact * 0.4,
		"an open-space pass must contain a visible lateral detour (only %.2f)" % largest_detour)

	navigation.queue_free()
	for unit in units:
		unit.queue_free()
	left.queue_free()
	right.queue_free()


## A stationary friend sitting exactly on the route must be flowed around, not
## treated as a dead end: contact quantizing every candidate to zero used to
## freeze both units at their first touch.
func _test_slide_around_stopped_friend(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	navigation.set_physics_process(false)
	_expect(navigation.setup(grid), "navigation system must initialize")

	var blocker := FakeUnit.new()
	var runner := FakeUnit.new()
	root.add_child(blocker)
	root.add_child(runner)
	blocker.global_position = Vector3(105.0, 0.0, 100.0)
	runner.global_position = Vector3(100.0, 0.0, 100.0)
	navigation.register_unit(blocker)
	var destination := Vector3(110.0, 0.0, 100.0)
	navigation.command_move([runner], destination)
	for _iteration in 100:
		navigation.call("_navigation_tick", 0.05)
	_expect(runner.global_position.distance_to(destination) < 1.0, "a unit must slide around a stopped friend on its route")

	navigation.queue_free()
	blocker.queue_free()
	runner.queue_free()


## The reported field failure: a group ordered to one point jams at its first
## internal contact. Every unit must keep flowing and settle on its own slot.
func _test_group_convergence(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	navigation.set_physics_process(false)
	_expect(navigation.setup(grid), "navigation system must initialize")
	var units: Array[FakeUnit] = []
	for index in 6:
		var unit := FakeUnit.new()
		root.add_child(unit)
		unit.global_position = Vector3(40.0 + float(index % 3), 0.0, 40.0 + float(index / 3))
		units.append(unit)
	var assignments := navigation.command_move(units, Vector3(60.0, 0.0, 60.0), NavigationSystemScript.MoveMode.FREE)
	for _iteration in 400:
		navigation.call("_navigation_tick", 0.05)
	for assignment in assignments:
		var unit: Node3D = assignment["unit"]
		var slot: Vector3 = assignment["position"]
		_expect(unit.global_position.distance_to(slot) < 3.5, "every unit of a converging group must reach its slot instead of jamming on contact")

	navigation.queue_free()
	for unit in units:
		unit.queue_free()


## A packed square moved ten cells sideways — the everyday group move. The
## pack must slide over as a shape: no scrum, and no squeezing through the
## target point (the mid-flight spread must stay near the resting spread).
func _test_group_shift_keeps_shape(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	navigation.set_physics_process(false)
	_expect(navigation.setup(grid), "navigation system must initialize")

	var units: Array[FakeUnit] = []
	for index in 25:
		var unit := FakeUnit.new()
		root.add_child(unit)
		unit.global_position = Vector3(100.5 + float(index % 5), 0.0, 100.5 + float(index / 5))
		units.append(unit)
	navigation.command_move(units, Vector3(112.5, 0.0, 102.5), NavigationSystemScript.MoveMode.FREE)

	const TICK := 0.05
	const MAX_TICKS := 1200
	const IDLE_TICKS_TO_FINISH := 100
	var previous: Array[Vector3] = []
	for unit in units:
		previous.append(unit.global_position)
	var last_active_tick := 0
	var elapsed_ticks := MAX_TICKS
	var minimum_spread := INF
	for tick in range(1, MAX_TICKS + 1):
		navigation.call("_navigation_tick", TICK)
		var moved := false
		var centroid := Vector3.ZERO
		for index in units.size():
			if units[index].global_position.distance_to(previous[index]) > 0.005:
				moved = true
			previous[index] = units[index].global_position
			centroid += units[index].global_position
		centroid /= float(units.size())
		var spread := 0.0
		for unit in units:
			spread = maxf(spread, unit.global_position.distance_to(centroid))
		minimum_spread = minf(minimum_spread, spread)
		if moved:
			last_active_tick = tick
		elif tick - last_active_tick >= IDLE_TICKS_TO_FINISH:
			elapsed_ticks = tick
			break
	print("Group shift: settled in %.1f s, min mid-flight spread %.1f (gapped resting ~5.7)" % [
		float(last_active_tick) * TICK, minimum_spread])
	_expect(elapsed_ticks < MAX_TICKS, "a shifted pack must settle, not churn forever")
	_expect(float(last_active_tick) * TICK < 8.0, "a ten-cell group shift must settle within 8 seconds")
	_expect(minimum_spread > 1.8, "the pack must translate as a shape, not squeeze through the target point")

	navigation.queue_free()
	for unit in units:
		unit.queue_free()


## An idle unit displaced off a choke point parks nearby on the grid and stays
## (returning would displace the passer forever). A commanded unit owns a
## unique reserved block, so it walks back once the passer is through.
func _test_yield_behaviour(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	navigation.set_physics_process(false)
	_expect(navigation.setup(grid), "navigation system must initialize")

	var idle := FakeUnit.new()
	root.add_child(idle)
	idle.global_position = Vector3(120.5, 0.0, 120.5)
	navigation.register_unit(idle)
	navigation.call("_request_yield", idle, Vector3.RIGHT)
	for _iteration in 20:
		navigation.call("_navigation_tick", 0.05)
	var displaced_position := idle.global_position
	_expect(displaced_position.x > 121.5, "a yielded idle unit must move aside")
	var parked: Vector3 = navigation.agent_debug(idle)["destination"]
	_expect(
		absf(fposmod(parked.x, 1.0) - 0.5) < 0.001 and absf(fposmod(parked.z, 1.0) - 0.5) < 0.001,
		"a yielded idle unit must park on a grid cell center (got %.2f, %.2f)" % [parked.x, parked.z]
	)
	for _iteration in 40:
		navigation.call("_navigation_tick", 0.05)
	_expect(idle.global_position.distance_to(displaced_position) < 0.01, "a yielded idle unit must not return to the choke point")

	var owner := FakeUnit.new()
	root.add_child(owner)
	owner.global_position = Vector3(140.5, 0.0, 120.5)
	var home := owner.global_position
	navigation.command_move([owner], home)
	navigation.call("_navigation_tick", 0.05)
	var prepared_order_count := owner.prepared_navigation_targets.size()
	navigation.call("_request_yield", owner, Vector3.RIGHT)
	_expect(owner.prepared_navigation_targets.size() == prepared_order_count, "an internal yield must not enter the player-order preparation API")
	for _iteration in 8:
		navigation.call("_navigation_tick", 0.05)
	_expect(owner.global_position.x > 141.5, "a yielded commanded unit must move aside first")
	for _iteration in 60:
		navigation.call("_navigation_tick", 0.05)
	_expect(owner.global_position.distance_to(home) < 0.3, "a commanded unit must return to its reserved block after yielding")
	_expect(owner.prepared_navigation_targets.size() == prepared_order_count, "resuming after yield must preserve the original order instead of issuing a replacement")

	navigation.queue_free()
	idle.queue_free()
	owner.queue_free()


## A packed group routed around a sharp wall tip: every unit's A* path runs
## through the same corridor, so raw cell-by-cell waypoints land inside the
## moving crowd. Pre-simplifying those paths to stable corner waypoints must
## keep the whole group flowing without runtime line-of-sight skipping.
func _test_group_rounds_sharp_corner(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	navigation.set_physics_process(false)
	_expect(navigation.setup(grid), "navigation system must initialize")
	var walls := {}
	for x in range(40, 121):
		walls[Vector2i(x, 100)] = true
	navigation.runtime_map.replace_blocked_cells(walls)

	var units: Array[FakeUnit] = []
	for index in 20:
		var unit := FakeUnit.new()
		root.add_child(unit)
		unit.global_position = Vector3(60.0 + float(index % 5), 0.0, 90.0 + float(index / 5))
		units.append(unit)
	var assignments := navigation.command_move(units, Vector3(60.5, 0.0, 140.5), NavigationSystemScript.MoveMode.FREE)
	for _iteration in 1200:
		navigation.call("_navigation_tick", 0.05)
	for assignment in assignments:
		var unit: Node3D = assignment["unit"]
		var slot: Vector3 = assignment["position"]
		# One-way yields may nudge an arrived unit a few cells off its exact
		# slot; the guarded failure mode leaves units ~40+ cells behind.
		_expect(unit.global_position.distance_to(slot) < 10.0,
			"no unit of a group rounding a sharp corner may be left behind in a jam (dist %.1f, pos %.1f,%.1f slot %.1f,%.1f)" % [
				unit.global_position.distance_to(slot), unit.global_position.x, unit.global_position.z, slot.x, slot.z])

	navigation.queue_free()
	for unit in units:
		unit.queue_free()


## Destinations are always the center of a free `size x size` cell block: odd
## footprints center on a cell, even footprints on a shared cell corner, and
## the blocks of one command never overlap.
func _test_grid_aligned_slots(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	navigation.set_physics_process(false)
	_expect(navigation.setup(grid), "navigation system must initialize")

	var units: Array[Node3D] = []
	for index in 3:
		var small := FakeUnit.new(1.0)
		root.add_child(small)
		small.global_position = Vector3(140.0 + float(index), 0.0, 140.0)
		units.append(small)
	for index in 2:
		var large := FakeUnit.new(2.0)
		root.add_child(large)
		large.global_position = Vector3(140.0 + float(index) * 2.0, 0.0, 143.0)
		units.append(large)
	navigation.command_move(units, Vector3(150.7, 0.0, 150.2), NavigationSystemScript.MoveMode.FREE)
	for _iteration in 300:
		navigation.call("_navigation_tick", 0.05)

	var blocks: Array[Dictionary] = []
	for unit in units:
		var span := int(navigation._agents[unit.get_instance_id()]["footprint"])
		var position: Vector3 = navigation.agent_debug(unit)["destination"]
		var expected := 0.5 if span % 2 == 1 else 0.0
		_expect(
			absf(fposmod(position.x, 1.0) - expected) < 0.001 and absf(fposmod(position.z, 1.0) - expected) < 0.001,
			"a claimed block for footprint %d must be a grid block center (got %.2f, %.2f)" % [span, position.x, position.z]
		)
		_expect(unit.global_position.distance_to(position) < 0.6, "every unit must settle on its claimed block")
		blocks.append({"anchor": navigation._parking_anchor(position, span), "span": span})
	for a in blocks.size():
		for b in range(a + 1, blocks.size()):
			_expect(
				not navigation._blocks_conflict(blocks[a]["anchor"], blocks[a]["span"], blocks[b]["anchor"], blocks[b]["span"]),
				"claimed footprint blocks must keep a one-cell gap"
			)

	navigation.queue_free()
	for unit in units:
		unit.queue_free()


## Collision is elastic: two units dropped on top of each other must be pushed
## apart by the separation force until they no longer overlap.
func _test_overlap_is_squeezed_out(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	navigation.set_physics_process(false)
	_expect(navigation.setup(grid), "navigation system must initialize")

	var first := FakeUnit.new()
	var second := FakeUnit.new()
	root.add_child(first)
	root.add_child(second)
	first.global_position = Vector3(200.5, 0.0, 200.5)
	second.global_position = Vector3(200.6, 0.0, 200.5)
	navigation.register_unit(first)
	navigation.register_unit(second)
	for _iteration in 60:
		navigation.call("_navigation_tick", 0.05)
	var contact := float(navigation._agents[first.get_instance_id()]["radius"]) \
		+ float(navigation._agents[second.get_instance_id()]["radius"])
	_expect(first.global_position.distance_to(second.global_position) >= contact - 0.01,
		"overlapping units must be squeezed apart (ended %.2f apart)" % first.global_position.distance_to(second.global_position))

	navigation.queue_free()
	first.queue_free()
	second.queue_free()


## Large unit discs can overlap while their centres are more than one spatial
## bucket apart; neighbour lookup must expand with their collision radii.
func _test_large_overlap_spans_spatial_buckets(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	navigation.set_physics_process(false)
	_expect(navigation.setup(grid), "navigation system must initialize")

	var first := FakeUnit.new(5.0)
	var second := FakeUnit.new(5.0)
	root.add_child(first)
	root.add_child(second)
	first.global_position = Vector3(39.9, 0.0, 220.5)
	second.global_position = Vector3(44.0, 0.0, 220.5)
	navigation.register_unit(first)
	navigation.register_unit(second)
	var contact := float(navigation._agents[first.get_instance_id()]["radius"]) \
		+ float(navigation._agents[second.get_instance_id()]["radius"])
	_expect(first.global_position.distance_to(second.global_position) < contact,
		"large-unit fixture must begin overlapped across non-adjacent buckets")
	for _iteration in 80:
		navigation.call("_navigation_tick", 0.05)
	_expect(first.global_position.distance_to(second.global_position) >= contact - 0.01,
		"large overlapping units in distant buckets must still separate")

	navigation.queue_free()
	first.queue_free()
	second.queue_free()


## A third unit may push a friend toward an enemy, but the post-steering
## separation velocity must still respect the enemy's solid swept disc.
func _test_enemy_stays_solid_under_separation(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	navigation.set_physics_process(false)
	_expect(navigation.setup(grid), "navigation system must initialize")

	var pusher := FakeUnit.new()
	var squeezed := FakeUnit.new()
	var enemy := FakeUnit.new()
	enemy.owner_player_id = 2
	root.add_child(pusher)
	root.add_child(squeezed)
	root.add_child(enemy)
	pusher.global_position = Vector3(179.5, 0.0, 180.5)
	squeezed.global_position = Vector3(180.0, 0.0, 180.5)
	enemy.global_position = Vector3(180.9, 0.0, 180.5)
	navigation.register_unit(pusher)
	navigation.register_unit(squeezed)
	navigation.register_unit(enemy)
	var contact := float(navigation._agents[squeezed.get_instance_id()]["radius"]) \
		+ float(navigation._agents[enemy.get_instance_id()]["radius"])
	var closest_approach := squeezed.global_position.distance_to(enemy.global_position)
	for _iteration in 80:
		navigation.call("_navigation_tick", 0.05)
		closest_approach = minf(closest_approach, squeezed.global_position.distance_to(enemy.global_position))
	_expect(closest_approach >= contact - 0.01,
		"friendly separation must not push a unit through an enemy (closest %.2f, contact %.2f)" % [closest_approach, contact])
	_expect(squeezed.global_position.x < enemy.global_position.x,
		"a friend pushed toward an enemy must remain on its original side")

	navigation.queue_free()
	pusher.queue_free()
	squeezed.queue_free()
	enemy.queue_free()


## Elastic crowding in a corridor one cell wide: two units meeting head-on
## cannot steer around each other, so they compress, slide through, and get
## expelled on the far side — a hard-collision model deadlocks here.
func _test_elastic_corridor_pass(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	navigation.set_physics_process(false)
	_expect(navigation.setup(grid), "navigation system must initialize")
	var walls := {}
	for x in range(60, 71):
		walls[Vector2i(x, 199)] = true
		walls[Vector2i(x, 201)] = true
	navigation.runtime_map.replace_blocked_cells(walls)

	var east_bound := FakeUnit.new()
	var west_bound := FakeUnit.new()
	root.add_child(east_bound)
	root.add_child(west_bound)
	east_bound.global_position = Vector3(58.5, 0.0, 200.5)
	west_bound.global_position = Vector3(72.5, 0.0, 200.5)
	var east_target := Vector3(72.5, 0.0, 200.5)
	var west_target := Vector3(58.5, 0.0, 200.5)
	navigation.command_move([east_bound], east_target)
	navigation.command_move([west_bound], west_target)
	var closest_approach := INF
	var fastest_step := 0.0
	var previous_east := east_bound.global_position
	var previous_west := west_bound.global_position
	for _iteration in 240:
		navigation.call("_navigation_tick", 0.05)
		closest_approach = minf(closest_approach, east_bound.global_position.distance_to(west_bound.global_position))
		fastest_step = maxf(fastest_step, maxf(
			previous_east.distance_to(east_bound.global_position) / 0.05,
			previous_west.distance_to(west_bound.global_position) / 0.05
		))
		previous_east = east_bound.global_position
		previous_west = west_bound.global_position
	_expect(east_bound.global_position.distance_to(east_target) < 1.5,
		"the east-bound unit must squeeze past in the corridor (ended %.1f,%.1f)" % [east_bound.global_position.x, east_bound.global_position.z])
	_expect(west_bound.global_position.distance_to(west_target) < 1.5,
		"the west-bound unit must squeeze past in the corridor (ended %.1f,%.1f)" % [west_bound.global_position.x, west_bound.global_position.z])
	var corridor_contact := float(navigation._agents[east_bound.get_instance_id()]["radius"]) \
		+ float(navigation._agents[west_bound.get_instance_id()]["radius"])
	_expect(closest_approach < corridor_contact * 0.75,
		"corridor pass must use soft overlap, not an accidental detour (closest %.2f)" % closest_approach)
	_expect(fastest_step <= east_bound.move_speed + 0.01,
		"steering plus separation must not exceed unit speed (observed %.2f)" % fastest_step)

	navigation.queue_free()
	east_bound.queue_free()
	west_bound.queue_free()


## The point of the parking gap: a single unit ordered to the far side of a
## standing formation threads the free lanes between parked blocks instead of
## being walled out.
func _test_lane_through_standing_formation(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	navigation.set_physics_process(false)
	_expect(navigation.setup(grid), "navigation system must initialize")

	var formation: Array[FakeUnit] = []
	for index in 9:
		var unit := FakeUnit.new()
		root.add_child(unit)
		unit.global_position = Vector3(148.5 + float(index % 3), 0.0, 148.5 + float(index / 3))
		formation.append(unit)
	navigation.command_move(formation, Vector3(150.5, 0.0, 150.5), NavigationSystemScript.MoveMode.FREE)
	for _iteration in 200:
		navigation.call("_navigation_tick", 0.05)

	var runner := FakeUnit.new()
	root.add_child(runner)
	runner.global_position = Vector3(150.5, 0.0, 140.5)
	var far_side := Vector3(150.5, 0.0, 160.5)
	navigation.command_move([runner], far_side)
	for _iteration in 200:
		navigation.call("_navigation_tick", 0.05)
	_expect(runner.global_position.distance_to(far_side) < 1.5,
		"a single unit must cross a standing formation through its parking lanes (ended %.1f,%.1f)" % [
			runner.global_position.x, runner.global_position.z])

	navigation.queue_free()
	for unit in formation:
		unit.queue_free()
	runner.queue_free()


## 21 units ringed around a point are all ordered into its center — the worst
## head-on convergence. Reports how long the scrum lasts and how many of the
## originally planned slots end up empty; the group must settle, not churn.
func _test_circle_convergence_metrics(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	navigation.set_physics_process(false)
	_expect(navigation.setup(grid), "navigation system must initialize")

	var center := Vector3(100.5, 0.0, 100.5)
	var units: Array[FakeUnit] = []
	for index in 21:
		var unit := FakeUnit.new()
		root.add_child(unit)
		var angle := TAU * float(index) / 21.0
		unit.global_position = center + Vector3(cos(angle), 0.0, sin(angle)) * 12.0
		units.append(unit)
	navigation.command_move(units, center, NavigationSystemScript.MoveMode.FREE)

	const TICK := 0.05
	const MAX_TICKS := 2400
	const IDLE_TICKS_TO_FINISH := 100
	var previous: Array[Vector3] = []
	for unit in units:
		previous.append(unit.global_position)
	var last_active_tick := 0
	var elapsed_ticks := MAX_TICKS
	for tick in range(1, MAX_TICKS + 1):
		navigation.call("_navigation_tick", TICK)
		var moved := false
		for index in units.size():
			if units[index].global_position.distance_to(previous[index]) > 0.005:
				moved = true
			previous[index] = units[index].global_position
		if moved:
			last_active_tick = tick
		elif tick - last_active_tick >= IDLE_TICKS_TO_FINISH:
			elapsed_ticks = tick
			break

	var crowd_radius := 0.0
	for unit in units:
		var destination: Vector3 = navigation.agent_debug(unit)["destination"]
		_expect(unit.global_position.distance_to(destination) < 0.6, "every converging unit must settle on its claimed block")
		crowd_radius = maxf(crowd_radius, unit.global_position.distance_to(center))
	var holes := 0
	var center_cell: Vector2i = grid.world_to_grid(center)
	var scan := int(ceil(crowd_radius)) + 1
	for y in range(-scan, scan + 1):
		for x in range(-scan, scan + 1):
			var point: Vector3 = grid.grid_to_world(center_cell + Vector2i(x, y))
			if point.distance_to(center) >= crowd_radius:
				continue
			var covered := false
			for unit in units:
				if unit.global_position.distance_to(point) < 0.71:
					covered = true
					break
			if not covered:
				holes += 1
	print("Circle convergence: settled in %.1f s, crowd radius %.1f (gapped ideal ~5.2), %d empty cells inside the crowd" % [
		float(last_active_tick) * TICK, crowd_radius, holes])
	_expect(elapsed_ticks < MAX_TICKS, "the convergence scrum must settle, not churn forever")
	_expect(float(last_active_tick) * TICK < 30.0, "21 units converging on one point must settle within 30 seconds")
	_expect(crowd_radius < 7.0, "21 units must pack near the target on the gapped lattice")

	navigation.queue_free()
	for unit in units:
		unit.queue_free()


## Jostling units carry a constantly refreshed yield. A fresh move order must
## cancel it: a stale yield steers the unit aside and, on expiry, replaces the
## ordered destination with wherever the unit stands — the order is ignored.
func _test_command_overrides_yield(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	navigation.set_physics_process(false)
	_expect(navigation.setup(grid), "navigation system must initialize")

	var unit := FakeUnit.new()
	root.add_child(unit)
	unit.global_position = Vector3(120.5, 0.0, 120.5)
	navigation.command_move([unit], unit.global_position)
	navigation.call("_request_yield", unit, Vector3.RIGHT)
	for _iteration in 4:
		navigation.call("_navigation_tick", 0.05)
	var destination := Vector3(130.5, 0.0, 130.5)
	navigation.command_move([unit], destination)
	for _iteration in 100:
		navigation.call("_navigation_tick", 0.05)
	_expect(unit.global_position.distance_to(destination) < 1.0, "an order issued mid-yield must still be executed")

	navigation.queue_free()
	unit.queue_free()


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
