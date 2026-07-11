extends SceneTree

## Covers docs/mechanics/production.md section 1 ("primary Construction
## Yard" / "main base"): the pure double-click detector, the generic
## per-player/per-group primary registry, and the PlayerRoster main-base API
## that wraps it. Building-level double-click raycasting is exercised
## end-to-end in the running game, not here -- these are unit tests for its
## non-Node-dependent collaborators.

const DoubleClickTrackerScript := preload("res://scripts/buildings/double_click_tracker.gd")
const PrimaryBuildingRegistryScript := preload("res://scripts/buildings/primary_building_registry.gd")
const PlayerRosterScript := preload("res://scripts/players/player_roster.gd")
const BuildingScript := preload("res://scripts/buildings/building.gd")

var _assertions := 0
var _failures := 0
var _current_case := ""
var _completion_token := 4000


func _initialize() -> void:
	await _run_case("double-click tracker detects repeat clicks within threshold", _test_double_click_tracker_detects)
	await _run_case("double-click tracker ignores stale or different clicks", _test_double_click_tracker_ignores)
	await _run_case("registry designates and swaps primary within a group", _test_registry_designate_and_swap)
	await _run_case("registry keeps groups and players independent", _test_registry_group_independence)
	await _run_case("registry clears its entry when the building leaves the tree", _test_registry_clears_on_free)
	await _run_case("player roster exposes a main base per player", _test_roster_main_base_api)

	if _failures > 0:
		printerr("Primary building tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("Primary building tests: %d assertions passed" % _assertions)
	quit(0)


func _run_case(case_name: String, test: Callable) -> void:
	_current_case = case_name
	_completion_token += 1
	var token := _completion_token
	var failures_before := _failures
	# Some cases exercise queue_free() cleanup and need a frame to elapse
	# before tree_exiting fires, so this must tolerate coroutine test bodies.
	var completed: Variant = await test.call(token)
	if completed != token:
		_failures += 1
		printerr("FAIL: %s: case did not return its completion token" % case_name)
		return
	if _failures == failures_before:
		print("PASS: %s" % case_name)


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])


func _test_double_click_tracker_detects(token: int) -> int:
	var tracker = DoubleClickTrackerScript.new()
	var building := BuildingScript.new()
	_expect(not tracker.register_click(building, 0, 350), "the first click must not be a double click")
	_expect(tracker.register_click(building, 200, 350), "a second click within the threshold must be a double click")
	building.free()
	return token


func _test_double_click_tracker_ignores(token: int) -> int:
	var tracker = DoubleClickTrackerScript.new()
	var first_building := BuildingScript.new()
	var second_building := BuildingScript.new()

	tracker.register_click(first_building, 0, 350)
	_expect(not tracker.register_click(second_building, 100, 350), "clicking a different target must not count as a double click")
	_expect(not tracker.register_click(second_building, 460, 350), "clicking the same target after the threshold must not count as a double click")
	_expect(tracker.register_click(second_building, 700, 350), "a fresh click pair within the threshold must count as a double click")

	first_building.free()
	second_building.free()
	return token


func _test_registry_designate_and_swap(token: int) -> int:
	var registry = PrimaryBuildingRegistryScript.new()
	var first_yard := BuildingScript.new()
	var second_yard := BuildingScript.new()
	var changes: Array[Node3D] = []
	registry.primary_changed.connect(func(_player_id: int, _group_key: String, building: Node3D) -> void: changes.append(building))

	registry.designate(first_yard, 1, "ConYard")
	_expect(first_yard.is_primary, "designating a building must set its is_primary flag")
	_expect(registry.primary_for(1, "ConYard") == first_yard, "the registry must report the designated building as primary")

	registry.designate(second_yard, 1, "ConYard")
	_expect(not first_yard.is_primary, "designating a new primary must clear the previous one's flag")
	_expect(second_yard.is_primary, "the newly designated building must become primary")
	_expect(registry.primary_for(1, "ConYard") == second_yard, "the registry must switch to the new primary")
	_expect(changes == [first_yard, second_yard], "primary_changed must fire once per designation, in order")

	first_yard.free()
	second_yard.free()
	return token


func _test_registry_group_independence(token: int) -> int:
	var registry = PrimaryBuildingRegistryScript.new()
	var con_yard := BuildingScript.new()
	var barracks := BuildingScript.new()
	var other_player_yard := BuildingScript.new()

	registry.designate(con_yard, 1, "ConYard")
	registry.designate(barracks, 1, "ATBarracks")
	registry.designate(other_player_yard, 2, "ConYard")

	_expect(registry.primary_for(1, "ConYard") == con_yard, "each group key must keep its own primary")
	_expect(registry.primary_for(1, "ATBarracks") == barracks, "a different group key must not disturb another group's primary")
	_expect(registry.primary_for(2, "ConYard") == other_player_yard, "each player must keep an independent primary")
	_expect(con_yard.is_primary and barracks.is_primary and other_player_yard.is_primary, "independent designations must not clear each other's flags")

	con_yard.free()
	barracks.free()
	other_player_yard.free()
	return token


func _test_registry_clears_on_free(token: int) -> int:
	var registry = PrimaryBuildingRegistryScript.new()
	var root := Node.new()
	get_root().add_child(root)
	var con_yard := BuildingScript.new()
	root.add_child(con_yard)

	registry.designate(con_yard, 1, "ConYard")
	_expect(registry.primary_for(1, "ConYard") == con_yard, "designation must register before destruction")

	# Mirrors Building.take_damage()'s use of queue_free() (see building.gd):
	# tree_exiting only fires once the deferred free actually runs.
	con_yard.queue_free()
	await process_frame
	_expect(registry.primary_for(1, "ConYard") == null, "destroying the primary building must clear the registry entry")

	root.free()
	return token


func _test_roster_main_base_api(token: int) -> int:
	var roster = PlayerRosterScript.new()
	roster.reset_for_match()
	var root := Node.new()
	get_root().add_child(root)
	var con_yard := BuildingScript.new()
	root.add_child(con_yard)

	var main_base_events: Array[Node3D] = []
	roster.primary_building_changed.connect(
		func(_player_id: int, _group_key: String, building: Node3D) -> void: main_base_events.append(building)
	)

	_expect(roster.main_base_for_player(1) == null, "a player with no designated Construction Yard must have no main base")
	roster.set_main_base(1, con_yard)
	_expect(roster.main_base_for_player(1) == con_yard, "set_main_base must become retrievable via main_base_for_player")
	_expect(con_yard.is_primary, "set_main_base must mark the building primary")
	_expect(main_base_events == [con_yard], "the roster must forward the registry's primary_changed signal")

	con_yard.queue_free()
	await process_frame
	_expect(roster.main_base_for_player(1) == null, "losing the primary Construction Yard must clear the main base")

	root.free()
	roster.free()
	return token
