extends SceneTree

## Regression test for a startup-ordering bug: Match._enter_tree() used to
## compute the building-panel roster via Rules.buildable_building_ids_for_house(),
## but the Rules autoload only loads its catalog in its own _ready() --
## _enter_tree() fires for the whole tree before any _ready() does, so that
## roster always read an empty catalog and the panel showed nothing buildable
## even with a Construction Yard and Windtrap already on the map. The fix
## moved the roster computation into Match._ready() instead.

var _assertions := 0
var _failures := 0
var _current_case := ""


func _initialize() -> void:
	await _run_case("demo scene roster is non-empty after boot", _test_demo_roster_populated)
	await _run_case("upgrade panel only lists buildings with an upgrade defined", _test_upgrade_panel_matches_controller)

	if _failures > 0:
		printerr("Match demo boot tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("Match demo boot tests: %d assertions passed" % _assertions)
	quit(0)


func _run_case(case_name: String, test: Callable) -> void:
	_current_case = case_name
	var failures_before := _failures
	await test.call()
	if _failures == failures_before:
		print("PASS: %s" % case_name)


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])


func _test_demo_roster_populated() -> void:
	var scene := load("res://scenes/match/demo_match.tscn") as PackedScene
	var match_instance := scene.instantiate()
	get_root().add_child(match_instance)
	await process_frame
	await process_frame

	_expect(
		not match_instance._building_option_ids.is_empty(),
		"the local player's building roster must not be empty when a Construction Yard already exists"
	)
	_expect(
		match_instance._building_option_ids.has(&"ATBarracks"),
		"ATBarracks must be available given the demo scene's starting ATConYard + ATSmWindtrap"
	)

	var side_panel = match_instance.get_node("HUD/SidePanel")
	_expect(
		side_panel._building_option_ids.has(&"ATBarracks"),
		"the roster must reach the side panel's building grid, not just Match's own state"
	)

	match_instance.queue_free()


## Regression test: BuildingUpgradeController.setup() filters its incoming
## roster down to buildings with upgrade_cost/upgrade_tech_level both set
## (see _has_upgrade_definition()), but match.gd used to hand the panel the
## raw unfiltered roster instead of the controller's filtered result. A slot
## with no matching upgrade_option_state_changed signal defaults to QueueSlot's
## normal AVAILABLE look, so every building without a real upgrade still
## rendered as one.
func _test_upgrade_panel_matches_controller() -> void:
	var scene := load("res://scenes/match/demo_match.tscn") as PackedScene
	var match_instance := scene.instantiate()
	get_root().add_child(match_instance)
	await process_frame
	await process_frame

	var upgrade_controller = match_instance.get_node("BuildingUpgradeController")
	var controller_ids: Array[StringName] = upgrade_controller.upgrade_option_ids()
	var side_panel = match_instance.get_node("HUD/SidePanel")

	_expect(
		not controller_ids.has(&"ATSmWindtrap"),
		"ATSmWindtrap has no upgrade_cost/upgrade_tech_level in Rules.txt and must not be an upgrade option"
	)
	_expect(
		controller_ids.has(&"ATBarracks"),
		"ATBarracks has both upgrade_cost and upgrade_tech_level and must be an upgrade option"
	)
	_expect(
		side_panel._upgrade_option_ids == controller_ids,
		"the panel's upgrade grid must exactly match the controller's filtered roster, not the raw building roster"
	)

	match_instance.queue_free()
