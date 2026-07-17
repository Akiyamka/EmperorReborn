extends SceneTree

const UnitDeploymentControllerScript := preload("res://scripts/units/unit_deployment_controller.gd")
const UnitRosterControllerScript := preload("res://scripts/units/unit_roster_controller.gd")
const UnitScene := preload("res://scenes/units/unit.tscn")
const MCVModelScene := preload("res://assets/converted/models/G_MCV_h0/G_MCV_h0.scn")
const ORFactoryScene := preload("res://assets/converted/buildings/ORFactory/ORFactory.scn")

var _assertions := 0
var _failures := 0
var _current_case := ""


class FakeGrid extends RefCounted:
	var buildable := true

	func is_loaded() -> bool:
		return true

	func grid_to_world(cell: Vector2i, centered: bool = true) -> Vector3:
		var offset := 0.5 if centered else 0.0
		return Vector3(float(cell.x) + offset, 0.0, float(cell.y) + offset)

	func world_to_grid(position: Vector3) -> Vector2i:
		return Vector2i(floori(position.x), floori(position.z))

	func cell_debug(_cell: Vector2i) -> Dictionary:
		return {"valid": true, "buildable": buildable}


class FakeMCV extends Node3D:
	signal deployment_animation_finished

	var config_id: StringName = &"ATMCV"
	var owner_player_id := -1
	var unit_config: Resource
	var deploying := false
	var deployment_calls := 0
	var finished_consumed = null

	func deploy() -> bool:
		if deploying:
			return false
		deploying = true
		deployment_calls += 1
		return true

	func is_deploying() -> bool:
		return deploying

	func finish_deployment(consumed: bool) -> void:
		deploying = false
		finished_consumed = consumed

	func owner_player():
		return get_node("/root/Players").player(owner_player_id)


func _initialize() -> void:
	await process_frame
	await _run_case("rules define three concrete MCV units", _test_three_mcv_rules)
	await _run_case("MCV uses its authored stop transition", _test_unit_deployment_animation)
	await _run_case("each MCV deploys its directly linked Construction Yard", _test_house_construction_yards)
	await _run_case("captured factory produces its own concrete MCV", _test_captured_factory_mcv)
	await _run_case("invalid terrain rejects deployment before locking the MCV", _test_invalid_site)
	if _failures > 0:
		printerr("UnitDeployment tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("UnitDeployment tests: %d assertions passed" % _assertions)
	quit(0)


func _run_case(case_name: String, test: Callable) -> void:
	_current_case = case_name
	var failures_before := _failures
	await test.call()
	if _failures == failures_before:
		print("PASS: %s" % case_name)


func _test_three_mcv_rules() -> void:
	var rules = root.get_node("Rules")
	_expect(rules.unit(&"MCV") == null, "the old shared MCV rules entry must not exist")
	var cases := [
		[&"ATMCV", &"Atreides", &"ATFactory", &"ATConYard"],
		[&"HKMCV", &"Harkonnen", &"HKFactory", &"HKConYard"],
		[&"ORMCV", &"Ordos", &"ORFactory", &"ORConYard"],
	]
	for house_case in cases:
		var config: Resource = rules.unit(house_case[0])
		_expect(config != null, "%s must have its own rules entry" % house_case[0])
		if config == null:
			continue
		_expect(
			StringName(String(config.field(&"house", ""))) == house_case[1],
			"%s must carry its factory technology house" % house_case[0]
		)
		var primary_buildings: Array = config.list(&"primary_buildings")
		_expect(
			primary_buildings.size() == 1
				and StringName(String(primary_buildings[0])) == house_case[2],
			"%s must be produced only by %s" % [house_case[0], house_case[2]]
		)
		var resources: Array = config.link(&"resources", [])
		_expect(
			resources.size() == 1
				and StringName(String((resources[0] as Dictionary).get("target", ""))) == house_case[3],
			"%s must deploy only %s" % [house_case[0], house_case[3]]
		)


func _test_unit_deployment_animation() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var unit := UnitScene.instantiate() as Unit
	unit.config_id = &"ATMCV"
	var visual_root := unit.get_node("VisualRoot") as Node3D
	for child in visual_root.get_children():
		visual_root.remove_child(child)
		child.free()
	visual_root.add_child(MCVModelScene.instantiate())
	world.add_child(unit)

	var finished := [0]
	unit.deployment_animation_finished.connect(func() -> void: finished[0] += 1)
	_expect(unit.deploy(), "a stationary MCV must accept the shared deploy command")
	_expect(unit.is_deploying(), "deploy must lock the unit until strategy handoff")
	var player := unit.get_node("VisualRoot").find_child("AnimationPlayer", true, false) as AnimationPlayer
	_expect(player != null and player.current_animation == &"Move_Stop", "the source-backed Move_Stop transition must play")
	_expect(not unit.prepare_navigation_order(Vector3(20.0, 0.0, 20.0)), "a deploying unit must reject new movement orders")
	if player != null:
		player.animation_finished.emit(&"Move_Stop")
	_expect(finished[0] == 1, "the strategy handoff must wait for the authored transition to finish")
	unit.finish_deployment(false)
	_expect(not unit.is_deploying(), "a failed handoff must release the MCV")
	world.queue_free()
	await process_frame


func _test_house_construction_yards() -> void:
	var players = root.get_node("Players")
	players.reset_for_match()
	var rules = root.get_node("Rules")
	var cases := [
		[1, &"Atreides", &"ATMCV", &"ATConYard", Vector3(20.0, 0.0, 20.0), deg_to_rad(20.0), PI],
		[2, &"Harkonnen", &"HKMCV", &"HKConYard", Vector3(100.0, 0.0, 20.0), deg_to_rad(70.0), -PI * 0.5],
		[3, &"Ordos", &"ORMCV", &"ORConYard", Vector3(180.0, 0.0, 20.0), deg_to_rad(160.0), 0.0],
		# An Atreides player can own an Ordos-produced MCV after capturing
		# ORFactory; the unit remains ORMCV regardless of its current owner.
		[4, &"Atreides", &"ORMCV", &"ORConYard", Vector3(260.0, 0.0, 20.0), deg_to_rad(-110.0), PI * 0.5],
	]
	for house_case in cases:
		players.create_player(house_case[0], String(house_case[1]), Color.WHITE, house_case[1])

	var world := Node3D.new()
	root.add_child(world)
	var buildings := Node3D.new()
	buildings.name = "Buildings"
	world.add_child(buildings)
	var controller = UnitDeploymentControllerScript.new()
	world.add_child(controller)
	controller.setup(FakeGrid.new(), buildings)

	for case_index in cases.size():
		var house_case: Array = cases[case_index]
		var mcv := FakeMCV.new()
		mcv.name = "MCV_%s_%s" % [String(house_case[1]), String(house_case[2])]
		mcv.config_id = house_case[2]
		mcv.owner_player_id = house_case[0]
		mcv.unit_config = rules.unit(house_case[2])
		mcv.position = house_case[4]
		mcv.rotation.y = house_case[5]
		mcv.add_to_group("units")
		world.add_child(mcv)

		var result: Dictionary = controller.try_deploy(mcv)
		_expect(bool(result.get("started", false)), "%s MCV must pass its valid site check" % house_case[1])
		_expect(buildings.get_child_count() == case_index, "the building must not appear before the unit animation finishes")
		mcv.deployment_animation_finished.emit()
		_expect(mcv.finished_consumed == true, "the MCV must be consumed only after a successful handoff")
		var con_yard := buildings.get_child(buildings.get_child_count() - 1) as Building
		_expect(
			con_yard.config_id == house_case[3],
			"%s-owned %s must deploy %s" % [house_case[1], house_case[2], house_case[3]]
		)
		_expect(
			absf(angle_difference(con_yard.global_rotation.y, house_case[6])) < 0.0001,
			"%s must inherit %s's direction rounded to 90 degrees" % [house_case[3], house_case[2]]
		)
		_expect(con_yard.owner_player_id == house_case[0], "the Construction Yard must preserve MCV ownership")
		_expect(not con_yard.is_construction_complete(), "the new Construction Yard must remain under construction")
		var state_player := con_yard.get_node("StatePlayer") as AnimationPlayer
		_expect(state_player.current_animation == &"build", "the building handoff must start its authored build clip")
		_expect(players.main_base_for_player(house_case[0]) == null, "an incomplete Construction Yard must not become the main base")
		state_player.animation_finished.emit(&"build")
		_expect(con_yard.is_construction_complete(), "the authored build clip must finish construction")
		_expect(players.main_base_for_player(house_case[0]) == con_yard, "the completed Construction Yard must become the player's main base")
		await process_frame

	world.queue_free()
	await process_frame


func _test_captured_factory_mcv() -> void:
	var players = root.get_node("Players")
	players.reset_for_match()
	players.create_player(1, "Atreides captor", Color.BLUE, &"Atreides")
	players.local_player_id = 1
	var world := Node3D.new()
	root.add_child(world)
	var buildings := Node3D.new()
	buildings.name = "Buildings"
	world.add_child(buildings)
	var units := Node3D.new()
	units.name = "Units"
	world.add_child(units)

	var factory := ORFactoryScene.instantiate() as Building
	factory.owner_player_id = 1
	buildings.add_child(factory)
	var parent_marker := FakeMCV.new()
	parent_marker.owner_player_id = 99
	parent_marker.add_to_group("units")
	units.add_child(parent_marker)
	var roster = UnitRosterControllerScript.new()
	world.add_child(roster)
	roster.setup([&"ORMCV"])
	_expect(
		roster._spawn_completed_unit(&"ORMCV", &"ORFactory"),
		"the captured ORFactory must be able to produce ORMCV"
	)
	var produced: Unit
	for candidate in units.get_children():
		if candidate is Unit and candidate.config_id == &"ORMCV":
			produced = candidate
			break
	_expect(produced != null, "captured-factory production must create ORMCV")
	_expect(
		produced != null and produced.owner_player_id == 1,
		"ORMCV must belong to the player that owns the captured ORFactory"
	)
	if produced == null:
		world.queue_free()
		await process_frame
		return
	produced.global_position = Vector3(200.0, 0.0, 120.0)
	produced.stop_at_current_position()

	var deployment = UnitDeploymentControllerScript.new()
	world.add_child(deployment)
	deployment.setup(FakeGrid.new(), buildings)
	var result: Dictionary = deployment.try_deploy(produced)
	_expect(bool(result.get("started", false)), "the Ordos MCV must start deployment under Atreides ownership")
	var animation_player := produced.get_node("VisualRoot").find_child(
		"AnimationPlayer", true, false
	) as AnimationPlayer
	animation_player.animation_finished.emit(&"Move_Stop")
	var con_yard := buildings.get_child(buildings.get_child_count() - 1) as Building
	_expect(con_yard.config_id == &"ORConYard", "the captured ORFactory MCV must deploy ORConYard")
	_expect(con_yard.owner_player_id == 1, "the deployed ORConYard must still belong to the Atreides player")
	world.queue_free()
	await process_frame


func _test_invalid_site() -> void:
	var players = root.get_node("Players")
	players.reset_for_match()
	players.create_player(1, "Atreides", Color.BLUE, &"Atreides")
	var rules = root.get_node("Rules")
	var world := Node3D.new()
	root.add_child(world)
	var buildings := Node3D.new()
	world.add_child(buildings)
	var grid := FakeGrid.new()
	grid.buildable = false
	var controller = UnitDeploymentControllerScript.new()
	world.add_child(controller)
	controller.setup(grid, buildings)
	var mcv := FakeMCV.new()
	mcv.config_id = &"ATMCV"
	mcv.owner_player_id = 1
	mcv.unit_config = rules.unit(&"ATMCV")
	mcv.add_to_group("units")
	world.add_child(mcv)

	var result: Dictionary = controller.try_deploy(mcv)
	_expect(bool(result.get("handled", false)) and not bool(result.get("started", false)), "an invalid MCV site must be handled as a rejected deployment")
	_expect(mcv.deployment_calls == 0 and not mcv.deploying, "site validation must happen before the MCV is locked")
	_expect(buildings.get_child_count() == 0, "a rejected deployment must not spawn a building")
	world.queue_free()
	await process_frame


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])
