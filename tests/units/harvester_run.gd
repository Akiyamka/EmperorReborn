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
		target_position = world_position

	func stop_at_current_position() -> void:
		stop_count += 1
		target_position = global_position

	func _start_harvest_animation(animation_name: StringName) -> float:
		animation_log.append(animation_name)
		return 0.1 if animation_name != HARVEST_HOLD_ANIMATION else 0.0


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
	_run_case("rules capacity and @!Harv halo", _test_rules_capacity_and_halo)
	_run_case("cycle timing, extraction cap, and nearby retarget", _test_cycle_and_retarget)
	_run_case("empty arrival and bounded search", _test_empty_arrival)
	_run_case("remaining bunker capacity limits extraction", _test_remaining_capacity)
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


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])
