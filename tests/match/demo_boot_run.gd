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
