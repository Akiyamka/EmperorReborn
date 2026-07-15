extends SceneTree

const UnitScript := preload("res://scripts/units/unit.gd")
const HarvesterScript := preload("res://scripts/units/harvester.gd")
const HarvesterScene := preload("res://scenes/units/harvester.tscn")
const UnitRosterControllerScript := preload("res://scripts/units/unit_roster_controller.gd")
const SelectionHaloScript := preload("res://scripts/ui/selection_halo.gd")
const MatchSnapshotScript := preload("res://scripts/match/match_snapshot.gd")

var _assertions := 0
var _failures := 0
var _current_case := ""
var _completion_token := 1000


class FakeGrid extends RefCounted:
	func grid_to_world(cell: Vector2i, _centered := true) -> Vector3:
		return Vector3(float(cell.x) + 0.5, 0.0, float(cell.y) + 0.5)

	func cell_size() -> Vector2:
		return Vector2.ONE


class FakeSpiceLayer extends RefCounted:
	var values: Dictionary = {}

	func spice_at(cell: Vector2i) -> int:
		return int(values.get(cell, 0))

	func take_spice(cell: Vector2i, requested: int) -> int:
		var taken := mini(spice_at(cell), requested)
		values[cell] = spice_at(cell) - taken
		return taken

	func nearest_spice_cell(origin: Vector2i, minimum_amount := 1, maximum_distance := -1) -> Vector2i:
		var best := Vector2i(-1, -1)
		var best_distance := 0x7fffffff
		for candidate_variant in values:
			var candidate: Vector2i = candidate_variant
			if spice_at(candidate) < minimum_amount:
				continue
			var distance := origin.distance_squared_to(candidate)
			if maximum_distance >= 0 and distance > maximum_distance * maximum_distance:
				continue
			if distance < best_distance:
				best = candidate
				best_distance = distance
		return best


class TestHarvester extends HarvesterScript:
	var move_targets: Array[Vector3] = []
	var animation_log: Array[StringName] = []
	var stop_count := 0

	func _ready() -> void:
		pass

	func move_to(world_position: Vector3, _exit_point := Vector3.INF) -> void:
		move_targets.append(world_position)
		super.move_to(world_position, _exit_point)

	func stop_at_current_position() -> void:
		stop_count += 1
		target_position = global_position

	func _start_harvest_animation(animation_name: StringName) -> float:
		animation_log.append(animation_name)
		return 0.1 if animation_name != HARVEST_HOLD_ANIMATION else 0.0

	func _start_unload_animation(animation_name: StringName) -> float:
		animation_log.append(animation_name)
		return 0.5 if animation_name == UNLOAD_HOLD_ANIMATION else 0.1


class FakeNavigation extends RefCounted:
	enum MoveMode { FREE, FORMATION }

	func command_move(_units: Array, _target: Vector3, _mode: int, _exit_point := Vector3.INF) -> Array[Dictionary]:
		for unit in _units:
			unit.set_navigation_destination(_target + Vector3(0.0, 0.0, 2.0))
		return []

	func command_dock(_unit: Node3D, _target: Vector3, _allowed_cells: Dictionary) -> bool:
		return true

	func stop(_unit: Node3D) -> void:
		pass

	func arrival_tolerance(_unit: Node3D) -> float:
		return 0.5


class FakeRefinery extends Node3D:
	var owner_player_id := 1
	var available := true
	var reserved_by: Node = null
	var release_delays: Array[float] = []
	var abandoned := 0
	var front := Vector3.ZERO
	var dock := Vector3(2.0, 0.0, 0.0)

	func is_refinery() -> bool:
		return true

	func is_owned_by(player_id: int) -> bool:
		return owner_player_id == player_id

	func refinery_front_position() -> Vector3:
		return front

	func try_reserve_refinery_dock(harvester: Node) -> int:
		if not available or reserved_by != null:
			return -1
		reserved_by = harvester
		return 0

	func refinery_dock_reserved_by(_dock_index: int, harvester: Node) -> bool:
		return reserved_by == harvester

	func refinery_dock_world_position(_dock_index: int) -> Vector3:
		return dock

	func refinery_dock_facing_direction(_dock_index: int) -> Vector3:
		return Vector3.BACK

	func refinery_dock_navigation_cells(_grid) -> Dictionary:
		return {Vector2i(1, 1): "d"}

	func release_refinery_dock(harvester: Node, cooldown_seconds := 3.0) -> void:
		if reserved_by == harvester:
			reserved_by = null
		release_delays.append(cooldown_seconds)

	func abandon_refinery_dock(harvester: Node) -> void:
		if reserved_by == harvester:
			reserved_by = null
		abandoned += 1


class FakeCargoEntity extends Node3D:
	var health := 1.0
	var max_health := 1.0
	var shields := 0.0
	var max_shields := 0.0
	var spice := 350.0
	var max_spice := 700.0
	var passengers := 0.0
	var max_passengers := 0.0


func _initialize() -> void:
	await process_frame
	var players = root.get_node("Players")
	players.reset_for_match()
	var local_player = players.create_player(1, "Harvester Tester", Color.BLUE, &"Atreides", [], 1, 0, 0)
	_run_case("rules capacity and @!Harv halo", _test_rules_capacity_and_halo)
	_run_case("cycle timing, extraction cap, and nearby retarget", _test_cycle_and_retarget)
	_run_case("empty arrival and bounded search", _test_empty_arrival)
	_run_case("remaining bunker capacity limits extraction", _test_remaining_capacity)
	_run_case("unload rate transfers a full bunker in 17.5 seconds", _test_full_unload.bind(local_player))
	_run_case("unload waits for a free reserved dock", _test_unload_waits_for_dock.bind(local_player))
	_run_case("unload arrival uses the navigation tolerance", _test_unload_navigation_arrival.bind(local_player))
	_run_case("direct orders finish unload animations before moving", _test_unload_interruption.bind(local_player))
	_run_case("refinery capture gracefully cancels unloading", _test_unload_refinery_capture.bind(local_player))
	players.reset_for_match()
	if _failures > 0:
		printerr("Harvester tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("Harvester tests: %d assertions passed" % _assertions)
	quit(0)


func _test_rules_capacity_and_halo(token: int) -> int:
	var harvester := TestHarvester.new()
	root.add_child(harvester)
	harvester.setup(&"Harvester")
	_expect(is_equal_approx(harvester.max_spice, 700.0), "runtime Harvester capacity must match local Rules.txt")
	var scene_harvester := HarvesterScene.instantiate()
	_expect(scene_harvester is HarvesterScript and scene_harvester is UnitScript, "the dedicated Harvester scene must remain a Unit subtype")
	root.add_child(scene_harvester)
	var has_unload_clips := false
	for node in scene_harvester.find_children("*", "AnimationPlayer", true, false):
		var player := node as AnimationPlayer
		if player.has_animation(HarvesterScript.UNLOAD_START_ANIMATION) \
		and player.has_animation(HarvesterScript.UNLOAD_HOLD_ANIMATION) \
		and player.has_animation(HarvesterScript.UNLOAD_END_ANIMATION):
			has_unload_clips = true
			break
	_expect(has_unload_clips, "the converted harvester model must retain all three unload clips")
	scene_harvester.free()
	var roster := UnitRosterControllerScript.new()
	var produced := roster._scene_for_unit(&"Harvester").instantiate()
	var ordinary := roster._scene_for_unit(&"ATInfantry").instantiate()
	_expect(produced is HarvesterScript and ordinary is UnitScript and not ordinary is HarvesterScript, "unit production must choose the specialized scene only for Harvester")
	produced.free()
	ordinary.free()
	roster.free()
	harvester.spice = 210.0
	var snapshot := MatchSnapshotScript.new()
	var record: Dictionary = snapshot._capture_entity(harvester)
	harvester.spice = 0.0
	snapshot._restore_entity_details(harvester, record)
	_expect(is_equal_approx(harvester.spice, 210.0), "match snapshots must preserve collected harvester cargo")

	var cargo := FakeCargoEntity.new()
	root.add_child(cargo)
	var halo := SelectionHaloScript.new()
	cargo.add_child(halo)
	halo.configure(cargo, 1.0, 0.0)
	halo.set_selected(true)
	halo._process(0.0)
	var harvester_layer := halo.get_node("Transport") as MeshInstance3D
	var spice_layer := halo.get_node("Spice") as MeshInstance3D
	var material := harvester_layer.material_override as ShaderMaterial
	_expect(harvester_layer.visible and not spice_layer.visible, "harvester cargo must use the authored @!Harv ring without a duplicate @!Spice ring")
	_expect(is_equal_approx(float(material.get_shader_parameter("fill")), 0.5), "@!Harv fill must track spice divided by bunker capacity")
	harvester.queue_free()
	cargo.queue_free()
	return token


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


func _test_cycle_and_retarget(token: int) -> int:
	var grid := FakeGrid.new()
	var layer := FakeSpiceLayer.new()
	var first := Vector2i(10, 10)
	var second := Vector2i(13, 10)
	layer.values[first] = 140
	layer.values[second] = 200
	var harvester := TestHarvester.new()
	harvester.max_spice = 700.0
	root.add_child(harvester)
	harvester.global_position = grid.grid_to_world(first)

	_expect(harvester.command_harvest(layer, grid, first), "a configured harvester must accept a harvesting order")
	harvester.advance_harvest_order(0.0)
	_expect(harvester.animation_log == [HarvesterScript.HARVEST_START_ANIMATION], "arrival must begin with Harv_Eat_Start")
	harvester.advance_harvest_order(0.1)
	_expect(harvester.animation_log.back() == HarvesterScript.HARVEST_HOLD_ANIMATION, "start completion must enter Harv_Eat_Hold")
	harvester.advance_harvest_order(0.29)
	_expect(is_zero_approx(harvester.spice), "cargo must not change before the hold interval completes")
	harvester.advance_harvest_order(0.02)
	_expect(is_equal_approx(harvester.spice, 140.0) and layer.spice_at(first) == 0, "one cycle may collect exactly one fifth of the 700-unit bunker")
	_expect(harvester.animation_log.back() == HarvesterScript.HARVEST_END_ANIMATION, "collection must be followed by Harv_Eat_End")
	harvester.advance_harvest_order(0.1)
	_expect(harvester.harvest_target_cell() == second, "an exhausted cell must switch to nearby spice")
	_expect(harvester.move_targets.back() == grid.grid_to_world(second), "retargeting must issue movement to the next cell")
	_expect(harvester.has_harvest_order(), "nearby spice must keep the autonomous order alive")
	harvester.queue_free()
	return token


func _test_empty_arrival(token: int) -> int:
	var grid := FakeGrid.new()
	var layer := FakeSpiceLayer.new()
	var empty := Vector2i(20, 20)
	var nearby := Vector2i(27, 20)
	layer.values[nearby] = 50
	var harvester := TestHarvester.new()
	harvester.max_spice = 700.0
	root.add_child(harvester)
	harvester.global_position = grid.grid_to_world(empty)
	harvester.command_harvest(layer, grid, empty)
	harvester.advance_harvest_order(0.0)
	_expect(harvester.harvest_target_cell() == nearby and harvester.animation_log.is_empty(), "an empty arrival must retarget before starting the collection animation")

	layer.values[nearby] = 0
	var distant := Vector2i(36, 20)
	layer.values[distant] = 100
	harvester.global_position = grid.grid_to_world(nearby)
	harvester.advance_harvest_order(0.0)
	_expect(not harvester.has_harvest_order(), "the order must stop when no spice exists in the eight-cell search radius")
	_expect(harvester.harvest_target_cell() == Vector2i(-1, -1), "a completed order must clear its target")
	harvester.queue_free()
	return token


func _test_remaining_capacity(token: int) -> int:
	var grid := FakeGrid.new()
	var layer := FakeSpiceLayer.new()
	var cell := Vector2i(4, 4)
	layer.values[cell] = 100
	var harvester := TestHarvester.new()
	harvester.max_spice = 100.0
	harvester.spice = 85.0
	root.add_child(harvester)
	harvester.global_position = grid.grid_to_world(cell)
	harvester.command_harvest(layer, grid, cell)
	harvester.advance_harvest_order(0.41)
	_expect(is_equal_approx(harvester.spice, 100.0), "a cycle must stop at the remaining bunker capacity")
	_expect(layer.spice_at(cell) == 85, "only the cargo actually loaded may be removed from the map cell")
	harvester.advance_harvest_order(0.1)
	_expect(not harvester.has_harvest_order(), "a full bunker must complete the harvesting order")
	harvester.queue_free()
	return token


func _test_full_unload(token: int, player: PlayerData) -> int:
	player.money = 0
	var grid := FakeGrid.new()
	var refinery := FakeRefinery.new()
	root.add_child(refinery)
	var harvester := TestHarvester.new()
	harvester.owner_player_id = player.player_id
	harvester.max_spice = 700.0
	harvester.spice = 700.0
	harvester.unload_rate_per_update = 2.0
	root.add_child(harvester)
	_park_for_unload(harvester, refinery, grid)
	_expect(harvester.animation_log.back() == HarvesterScript.UNLOAD_START_ANIMATION, "parking must start Harv_Unload_Start")
	harvester.advance_unload_order(0.1)
	_expect(harvester.animation_log.back() == HarvesterScript.UNLOAD_HOLD_ANIMATION, "UnloadStart must be followed by UnloadHold")
	for cycle in 35:
		harvester.advance_unload_order(0.5)
	_expect(is_zero_approx(harvester.spice), "35 half-second hold cycles must empty the 700-credit bunker")
	_expect(player.money == 700, "every removed cargo credit must be added to the owning player")
	_expect(harvester.animation_log.back() == HarvesterScript.UNLOAD_END_ANIMATION, "an empty bunker must enter Harv_Unload_End")
	harvester.advance_unload_order(0.1)
	_expect(refinery.release_delays == [3.0], "UnloadEnd completion must release the pad with a three-second delay")
	_expect(harvester.unload_phase() == HarvesterScript.UnloadPhase.RETURN_FRONT, "normal completion must return the harvester to the refinery front")
	harvester.global_position = refinery.front
	harvester.advance_unload_order(0.0)
	_expect(not harvester.has_unload_order(), "arrival at the front must complete the unloading order")

	harvester.queue_free()
	refinery.queue_free()
	return token


func _test_unload_waits_for_dock(token: int, player: PlayerData) -> int:
	var grid := FakeGrid.new()
	var refinery := FakeRefinery.new()
	refinery.available = false
	root.add_child(refinery)
	var harvester := TestHarvester.new()
	harvester.owner_player_id = player.player_id
	harvester.max_spice = 700.0
	harvester.spice = 100.0
	root.add_child(harvester)
	harvester.global_position = refinery.front
	_expect(harvester.command_unload(refinery, grid), "an owned refinery must accept an unloading order")
	harvester.advance_unload_order(0.0)
	harvester.advance_unload_order(0.0)
	_expect(harvester.unload_phase() == HarvesterScript.UnloadPhase.WAIT_DOCK, "an occupied refinery must leave the harvester waiting at its front")
	_expect(harvester.unload_dock() == -1 and refinery.reserved_by == null, "waiting must not claim an unavailable pad")
	refinery.available = true
	harvester.advance_unload_order(0.0)
	_expect(harvester.unload_phase() == HarvesterScript.UnloadPhase.PARK, "a newly free pad must be reserved on the next update")
	_expect(harvester.unload_dock() == 0 and refinery.reserved_by == harvester, "the selected pad must be exclusively reserved")

	harvester.cancel_unload_order()
	harvester.queue_free()
	refinery.queue_free()
	return token


func _test_unload_navigation_arrival(token: int, player: PlayerData) -> int:
	var grid := FakeGrid.new()
	var navigation := FakeNavigation.new()
	var refinery := FakeRefinery.new()
	root.add_child(refinery)
	var harvester := TestHarvester.new()
	harvester.owner_player_id = player.player_id
	harvester.max_spice = 700.0
	harvester.spice = 100.0
	root.add_child(harvester)
	harvester.set_navigation_managed(true)
	harvester.set_navigation_controller(navigation)

	_expect(harvester.command_unload(refinery, grid), "the managed harvester must accept the unloading order")
	harvester.global_position = harvester.target_position + Vector3(0.0, 0.0, 0.45)
	harvester.advance_unload_order(0.0)
	_expect(harvester.unload_phase() == HarvesterScript.UnloadPhase.WAIT_DOCK, "the unload state must follow the feasible destination assigned by navigation")
	harvester.advance_unload_order(0.0)
	_expect(harvester.unload_phase() == HarvesterScript.UnloadPhase.PARK, "arrival at the refinery front must proceed to dock reservation")
	harvester.global_position = refinery.dock + Vector3(0.0, 0.0, 0.45)
	harvester.advance_unload_order(0.0)
	_expect(harvester.unload_phase() == HarvesterScript.UnloadPhase.START, "parking must use the shared navigation arrival distance too")

	harvester.queue_free()
	refinery.queue_free()
	return token


func _test_unload_interruption(token: int, player: PlayerData) -> int:
	var grid := FakeGrid.new()
	var start_refinery := FakeRefinery.new()
	root.add_child(start_refinery)
	var start_harvester := TestHarvester.new()
	start_harvester.owner_player_id = player.player_id
	start_harvester.max_spice = 700.0
	start_harvester.spice = 100.0
	root.add_child(start_harvester)
	_park_for_unload(start_harvester, start_refinery, grid)
	var start_move := Vector3(10.0, 0.0, 0.0)
	start_harvester.move_to(start_move)
	_expect(start_harvester.target_position != start_move, "a direct order during UnloadStart must wait")
	start_harvester.advance_unload_order(0.1)
	_expect(start_harvester.animation_log == [
		HarvesterScript.UNLOAD_START_ANIMATION,
		HarvesterScript.UNLOAD_END_ANIMATION,
	], "interrupting UnloadStart must skip UnloadHold and play UnloadEnd")
	start_harvester.advance_unload_order(0.1)
	_expect(start_harvester.target_position == start_move, "the pending move may start only after UnloadEnd finishes")
	_expect(is_equal_approx(start_harvester.spice, 100.0), "UnloadStart interruption must transfer no cargo")

	player.money = 0
	var hold_refinery := FakeRefinery.new()
	root.add_child(hold_refinery)
	var hold_harvester := TestHarvester.new()
	hold_harvester.owner_player_id = player.player_id
	hold_harvester.max_spice = 700.0
	hold_harvester.spice = 100.0
	hold_harvester.unload_rate_per_update = 2.0
	root.add_child(hold_harvester)
	_park_for_unload(hold_harvester, hold_refinery, grid)
	hold_harvester.advance_unload_order(0.1)
	hold_harvester.advance_unload_order(0.25)
	_expect(player.money == 10 and is_equal_approx(hold_harvester.spice, 90.0), "UnloadHold must transfer at 40 credits per second")
	var hold_move := Vector3(12.0, 0.0, 0.0)
	hold_harvester.move_to(hold_move)
	hold_harvester.advance_unload_order(0.25)
	_expect(player.money == 10 and is_equal_approx(hold_harvester.spice, 90.0), "cargo transfer must stop immediately after an interrupt")
	_expect(hold_harvester.animation_log.back() == HarvesterScript.UNLOAD_END_ANIMATION, "the interrupted hold cycle must finish before UnloadEnd")
	hold_harvester.advance_unload_order(0.1)
	_expect(hold_harvester.target_position == hold_move, "the hold interruption's pending move must start after UnloadEnd")

	start_harvester.queue_free()
	start_refinery.queue_free()
	hold_harvester.queue_free()
	hold_refinery.queue_free()
	return token


func _test_unload_refinery_capture(token: int, player: PlayerData) -> int:
	player.money = 0
	var grid := FakeGrid.new()
	var refinery := FakeRefinery.new()
	root.add_child(refinery)
	var harvester := TestHarvester.new()
	harvester.owner_player_id = player.player_id
	harvester.max_spice = 700.0
	harvester.spice = 100.0
	harvester.unload_rate_per_update = 2.0
	root.add_child(harvester)
	_park_for_unload(harvester, refinery, grid)
	harvester.advance_unload_order(0.1)
	harvester.advance_unload_order(0.25)
	_expect(player.money == 10, "UnloadHold must transfer cargo before the refinery is captured")

	refinery.owner_player_id = player.player_id + 1
	harvester.advance_unload_order(0.25)
	_expect(player.money == 10 and is_equal_approx(harvester.spice, 90.0), "capture must stop cargo transfer immediately")
	_expect(harvester.animation_log.back() == HarvesterScript.UNLOAD_END_ANIMATION, "capture during UnloadHold must finish the current clip and play UnloadEnd")
	harvester.advance_unload_order(0.1)
	_expect(not harvester.has_unload_order(), "captured refinery must not receive a return-to-front movement")
	_expect(refinery.release_delays == [3.0], "capture must still release the occupied pad after UnloadEnd")

	harvester.queue_free()
	refinery.queue_free()
	return token


func _park_for_unload(harvester: TestHarvester, refinery: FakeRefinery, grid: FakeGrid) -> void:
	harvester.global_position = refinery.front
	harvester.command_unload(refinery, grid)
	harvester.advance_unload_order(0.0)
	harvester.advance_unload_order(0.0)
	harvester.global_position = refinery.dock
	harvester.advance_unload_order(0.0)


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])
