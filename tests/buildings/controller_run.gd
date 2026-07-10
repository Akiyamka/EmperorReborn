extends SceneTree

const BuildingControllerScript := preload("res://scripts/buildings/building_controller.gd")

var _assertions := 0
var _failures := 0
var _current_case := ""
var _completion_token := 3000


func _initialize() -> void:
	await process_frame
	var players = root.get_node("Players")
	players.reset_for_match()
	var local_player = players.create_player(1, "Controller Tester", Color.BLUE, &"Atreides", [], 1, 100, 7)
	players.local_player_id = 1

	_run_case("asset-independent setup owns one placement child", _test_asset_independent_setup)
	_run_case("repeated setup forwards resources once", _test_repeated_setup_forwards_resources_once.bind(local_player))
	_run_case("freed controller leaves no resource forwarding", _test_free_disconnects_resource_forwarding.bind(local_player))

	players.reset_for_match()
	if _failures > 0:
		printerr("BuildingController tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("BuildingController tests: %d assertions passed" % _assertions)
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


func _new_controller() -> BuildingController:
	var controller = BuildingControllerScript.new()
	root.add_child(controller)
	return controller


func _setup_without_assets(controller: BuildingController) -> void:
	var no_building_ids: Array[StringName] = []
	controller.setup(null, null, null, no_building_ids, null, null, null, null)


func _test_asset_independent_setup(token: int) -> int:
	var controller := _new_controller()
	_setup_without_assets(controller)
	_expect(controller.get_child_count() == 1, "setup must own exactly one placement child without generated scenes")
	_expect(controller.get_child(0) is BuildingPlacement, "setup must add the placement feature as its child")
	controller.free()
	return token


func _test_repeated_setup_forwards_resources_once(token: int, local_player: PlayerData) -> int:
	var controller := _new_controller()
	var resource_outputs: Array[Vector2i] = []
	controller.resources_changed.connect(func(credits: int, energy: int) -> void:
		resource_outputs.append(Vector2i(credits, energy))
	)
	_setup_without_assets(controller)
	_setup_without_assets(controller)
	_expect(controller.get_child_count() == 1, "repeated setup must retain one owned placement child")
	resource_outputs.clear()
	local_player.add_money(25)
	_expect(resource_outputs.size() == 1, "one player money change must produce one resource output after repeated setup")
	_expect(resource_outputs == [Vector2i(125, 7)], "resource output must preserve the current player values")
	controller.free()
	return token


func _test_free_disconnects_resource_forwarding(token: int, local_player: PlayerData) -> int:
	var controller := _new_controller()
	var resource_outputs: Array[Vector2i] = []
	controller.resources_changed.connect(func(credits: int, energy: int) -> void:
		resource_outputs.append(Vector2i(credits, energy))
	)
	_setup_without_assets(controller)
	controller.free()
	resource_outputs.clear()
	local_player.add_money(1)
	_expect(resource_outputs.is_empty(), "a freed controller must not forward later player resource changes")
	return token


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])
