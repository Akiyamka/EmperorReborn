extends SceneTree

const BuildingControllerScript := preload("res://scripts/buildings/building_controller.gd")
const UpgradeEffectsScript := preload("res://scripts/buildings/upgrade_effects.gd")
const BuildingOptionStateScript := preload("res://scripts/buildings/building_option_state.gd")

var _assertions := 0
var _failures := 0
var _current_case := ""
var _completion_token := 3000


## Minimal group-member stand-in for TechnologyTree/UpgradeEffects lookups
## (config_id/owner_player_id/upgrade_level), the same shape as the stubs in
## tests/characterization/run.gd and tests/buildings/upgrade_run.gd, sized
## for BuildingController's own "buildings" group polling instead.
class BuildingStub extends Node:
	var owner_player_id: int
	var config_id: StringName
	var upgrade_level := 0

	func _init(new_config_id: StringName, new_owner_player_id: int) -> void:
		config_id = new_config_id
		owner_player_id = new_owner_player_id
		add_to_group("buildings")

	func set_upgrade_level(level: int) -> void:
		upgrade_level = level


func _initialize() -> void:
	await process_frame
	var players = root.get_node("Players")
	players.reset_for_match()
	var local_player = players.create_player(1, "Controller Tester", Color.BLUE, &"Atreides", [], 1, 100, 7)
	players.local_player_id = 1

	_run_case("asset-independent setup owns one placement child", _test_asset_independent_setup)
	_run_case("repeated setup forwards resources once", _test_repeated_setup_forwards_resources_once.bind(local_player))
	_run_case("freed controller leaves no resource forwarding", _test_free_disconnects_resource_forwarding.bind(local_player))
	_run_case(
		"losing and restoring a prerequisite building toggles menu availability",
		_test_availability_reacts_to_prerequisite_loss.bind(local_player)
	)
	_run_case(
		"completing a global upgrade unlocks an upgraded_primary_required entry without restarting the controller",
		_test_availability_reacts_to_upgrade_purchase.bind(local_player)
	)

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


## docs/mechanics/production.md section 5: "loss of a prerequisite building
## (verified): ... new entries disappear from menus until the prerequisite
## is restored". BuildingController.process() re-evaluates
## _is_building_available() every tick and only re-emits state when it
## changes (see building_controller.gd process()/_refresh_building_option_
## states()), so this drives that polling loop directly against real Rules
## data (ATBarracks requires a primary ATConYard + a secondary Windtrap;
## assets/converted/rules/buildings/ATBarracks.tres) instead of re-testing
## TechnologyTree in isolation (already covered in
## tests/characterization/run.gd).
func _test_availability_reacts_to_prerequisite_loss(token: int, local_player: PlayerData) -> int:
	var controller := _new_controller()
	var latest_states: Dictionary = {}
	controller.building_option_state_changed.connect(func(option_state: BuildingOptionState) -> void:
		latest_states[option_state.building_id] = option_state.state
	)

	var building_ids: Array[StringName] = [&"ATBarracks"]
	controller.setup(null, null, null, building_ids, null, null, null, null)

	var con_yard := BuildingStub.new(&"ATConYard", local_player.player_id)
	var windtrap := BuildingStub.new(&"ATSmWindtrap", local_player.player_id)
	root.add_child(con_yard)
	root.add_child(windtrap)

	controller.process(0.0)
	_expect(
		latest_states.get(&"ATBarracks") == BuildingOptionStateScript.State.AVAILABLE,
		"ATBarracks must be available once its primary and secondary prerequisites are owned"
	)

	root.remove_child(con_yard)
	con_yard.free()
	controller.process(0.0)
	_expect(
		latest_states.get(&"ATBarracks") == BuildingOptionStateScript.State.DISABLED,
		"losing the primary prerequisite must disable the entry on the next poll, with nothing already built lost"
	)

	var restored_con_yard := BuildingStub.new(&"ATConYard", local_player.player_id)
	root.add_child(restored_con_yard)
	controller.process(0.0)
	_expect(
		latest_states.get(&"ATBarracks") == BuildingOptionStateScript.State.AVAILABLE,
		"restoring the prerequisite must re-enable the entry on the next poll"
	)

	restored_con_yard.free()
	windtrap.free()
	controller.free()
	return token


## docs/mechanics/production.md section 5: "roster expansion (verified):
## every production building and the Construction Yard has an upgrade that
## unlocks next-tech-level entries". ATRocketTurret requires an upgraded
## ATConYard plus any house's Barracks (upgraded_primary_required: true,
## assets/converted/rules/buildings/ATRocketTurret.tres) -- this drives a
## purchase through the same PlayerData.grant_upgrade + UpgradeEffects path
## BuildingUpgradeController._complete_global_upgrade() uses and checks that
## BuildingController's own polling loop (not a re-setup) picks it up.
func _test_availability_reacts_to_upgrade_purchase(token: int, local_player: PlayerData) -> int:
	var controller := _new_controller()
	var latest_states: Dictionary = {}
	controller.building_option_state_changed.connect(func(option_state: BuildingOptionState) -> void:
		latest_states[option_state.building_id] = option_state.state
	)

	var building_ids: Array[StringName] = [&"ATRocketTurret"]
	controller.setup(null, null, null, building_ids, null, null, null, null)

	var con_yard := BuildingStub.new(&"ATConYard", local_player.player_id)
	var barracks := BuildingStub.new(&"ATBarracks", local_player.player_id)
	root.add_child(con_yard)
	root.add_child(barracks)

	controller.process(0.0)
	_expect(
		latest_states.get(&"ATRocketTurret") == BuildingOptionStateScript.State.DISABLED,
		"an upgraded_primary_required entry must stay disabled while the primary is not yet upgraded"
	)

	local_player.grant_upgrade(&"ATConYard")
	UpgradeEffectsScript.apply_to_existing_buildings(get_nodes_in_group("buildings"), local_player.player_id, &"ATConYard")
	controller.process(0.0)
	_expect(
		latest_states.get(&"ATRocketTurret") == BuildingOptionStateScript.State.AVAILABLE,
		"the very next poll after a completed upgrade must unlock the entry, no controller restart needed"
	)

	con_yard.free()
	barracks.free()
	controller.free()
	return token
