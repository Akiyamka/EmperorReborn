extends SceneTree

const PlayerDataScript := preload("res://scripts/players/player_data.gd")
const PlayerRosterScript := preload("res://scripts/players/player_roster.gd")
const BuildingOrderScript := preload("res://scripts/buildings/building_order.gd")
const TechnologyTreeScript := preload("res://scripts/buildings/technology_tree.gd")
const RuleEntityConfigScript := preload("res://scripts/rules/rule_entity_config.gd")

var _assertions := 0
var _failures := 0
var _current_case := ""


class BuildingStub extends Node:
	var owner_player_id: int
	var config_id: StringName
	var upgrade_level: int

	func _init(new_config_id: StringName, new_owner_player_id: int, new_upgrade_level := 0) -> void:
		config_id = new_config_id
		owner_player_id = new_owner_player_id
		upgrade_level = new_upgrade_level


func _initialize() -> void:
	_run_case("PlayerData money, energy, and signals", _test_player_data_resources)
	_run_case("PlayerRoster reset lifecycle", _test_player_roster_reset_lifecycle)
	_run_case("PlayerRoster rebind and removal", _test_player_roster_rebind_and_removal)
	_run_case("PlayerRoster relations", _test_player_roster_relations)
	_run_case("BuildingOrder progress state", _test_building_order_progress)
	_run_case("TechnologyTree house and subhouse", _test_technology_tree_houses)
	_run_case("TechnologyTree building requirements", _test_technology_tree_building_requirements)
	_run_case("TechnologyTree unit requirements", _test_technology_tree_unit_requirements)

	if _failures > 0:
		printerr("Characterization tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return

	print("Characterization tests: %d assertions passed" % _assertions)
	quit(0)


func _run_case(case_name: String, test: Callable) -> void:
	_current_case = case_name
	var failures_before := _failures
	var completed: Variant = test.call()
	if completed != true:
		_failures += 1
		printerr("FAIL: %s: case aborted before normal completion" % case_name)
		return
	if _failures == failures_before:
		print("PASS: %s" % case_name)


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])


func _test_player_data_resources() -> bool:
	var player = PlayerDataScript.new()
	var events: Array[Array] = []
	player.resources_changed.connect(
		func(player_id: int, money: int, energy: int) -> void:
			events.append([player_id, money, energy])
	)
	player.configure(7, "Tester", Color.WHITE, &"Atreides", [&"Fremen", &"Fremen", &""], 3, 100, -5)

	_expect(player.player_id == 7, "configure must assign the player id")
	_expect(player.money == 100, "configure must assign starting money")
	_expect(player.energy == -5, "energy currently permits a negative balance")
	_expect(player.subhouse_ids == [&"Fremen"], "configure must remove empty and duplicate subhouses")
	_expect(not player.is_neutral, "a regular player must not be neutral")

	events.clear()
	player.add_money(-150)
	player.add_money(40)
	player.money = 40
	_expect(player.money == 40, "money must clamp at zero before later additions")
	_expect(not player.spend_money(-1), "negative spending must be rejected")
	_expect(not player.spend_money(50), "spending above the balance must be rejected")
	_expect(player.spend_money(15), "affordable spending must succeed")
	player.add_energy(-3)

	_expect(player.money == 25, "successful spending must reduce money")
	_expect(player.energy == -8, "add_energy must apply signed deltas")
	_expect(events.size() == 4, "only effective resource changes must emit signals")
	if events.size() == 4:
		_expect(events[0] == [7, 0, -5], "money clamping must emit the clamped balance")
		_expect(events[1] == [7, 40, -5], "adding money must emit the new balance")
		_expect(events[2] == [7, 25, -5], "spending must emit the new balance")
		_expect(events[3] == [7, 25, -8], "energy changes must emit both current resources")
	return true


func _test_player_roster_reset_lifecycle() -> bool:
	var roster = PlayerRosterScript.new()
	roster.reset_for_match()
	_expect(roster.player_count() == 0, "a reset match must contain no regular players")
	_expect(roster.player_count(true) == 1, "a reset match must contain exactly one neutral player")
	_expect(roster.neutral_player() != null, "the neutral player must exist after reset")

	var changed_ids: Array[int] = []
	roster.player_changed.connect(func(player_id: int) -> void: changed_ids.append(player_id))
	var old_player = roster.create_player(1, "Old", Color.WHITE, &"Atreides", [], 1, 50, 0)
	roster.local_player_id = 1
	roster.set_relation(1, 2, PlayerDataScript.Relation.ALLY)

	changed_ids.clear()
	roster.reset_for_match()
	changed_ids.clear()
	old_player.add_money(1)
	_expect(changed_ids.is_empty(), "players removed by reset must no longer notify the roster")
	_expect(roster.local_player_id == PlayerDataScript.NEUTRAL_PLAYER_ID, "reset must select neutral locally")
	_expect(roster.player_count() == 0, "reset must remove prior regular players")
	_expect(roster.player_count(true) == 1, "reset must recreate only one neutral player")
	_expect(
		roster.relation_between(1, 2) == PlayerDataScript.Relation.NEUTRAL,
		"reset must clear explicit relations"
	)
	roster.free()
	return true


func _test_player_roster_rebind_and_removal() -> bool:
	var roster = PlayerRosterScript.new()
	roster.reset_for_match()
	var changed_ids: Array[int] = []
	roster.player_changed.connect(func(player_id: int) -> void: changed_ids.append(player_id))

	var replaced_player = roster.create_player(1, "First", Color.WHITE)
	var current_player = roster.create_player(1, "Replacement", Color.WHITE)
	changed_ids.clear()
	replaced_player.add_money(5)
	_expect(changed_ids.is_empty(), "replaced players must be disconnected")
	current_player.add_money(5)
	_expect(changed_ids == [1], "the replacement player must notify exactly once")

	roster.add_player(current_player)
	changed_ids.clear()
	current_player.add_money(5)
	_expect(changed_ids == [1], "rebinding the same resource must not duplicate its signal")

	roster.create_player(2, "Other", Color.WHITE)
	roster.local_player_id = 1
	roster.set_relation(1, 2, PlayerDataScript.Relation.ALLY)
	roster.remove_player(1)
	changed_ids.clear()
	current_player.add_money(5)
	_expect(changed_ids.is_empty(), "removed players must be disconnected")
	_expect(roster.local_player_id == PlayerDataScript.NEUTRAL_PLAYER_ID, "removing local player must select neutral")
	_expect(not roster.has_player(1), "removed players must leave the roster")
	_expect(
		roster.relation_between(1, 2) == PlayerDataScript.Relation.NEUTRAL,
		"removal must clear that player's explicit relations"
	)
	roster.free()
	return true


func _test_player_roster_relations() -> bool:
	var roster = PlayerRosterScript.new()
	roster.reset_for_match()
	roster.create_player(1, "One", Color.WHITE, &"Atreides", [], 9)
	roster.create_player(2, "Two", Color.WHITE, &"Atreides", [], 9)
	roster.create_player(3, "Three", Color.WHITE, &"Ordos", [], 8)

	_expect(roster.are_allied(1, 1), "a player must be allied with itself")
	_expect(roster.are_allied(1, 2), "players on the same non-neutral team must default to allies")
	_expect(roster.are_enemies(1, 3), "players on different teams must default to enemies")
	_expect(
		roster.relation_between(1, PlayerDataScript.NEUTRAL_PLAYER_ID) == PlayerDataScript.Relation.NEUTRAL,
		"relations with neutral must be neutral"
	)

	roster.set_relation(3, 1, PlayerDataScript.Relation.NEUTRAL)
	_expect(
		roster.relation_between(1, 3) == PlayerDataScript.Relation.NEUTRAL,
		"explicit relations must be symmetric"
	)
	roster.clear_relation(1, 3)
	_expect(roster.are_enemies(3, 1), "clearing an explicit relation must restore the default")
	_expect(roster.shared_vision_player_ids(1) == [1, 2], "shared vision must include self and allies in id order")
	roster.free()
	return true


func _test_building_order_progress() -> bool:
	var order = BuildingOrderScript.new()
	_expect(not order.ready, "a new order must not be ready")
	_expect(not order.manually_paused, "a new order must not be paused")
	_expect(is_equal_approx(order.progress_percent(), 100.0), "an empty order currently reports complete")

	order.cost = 100
	order.paid_cost = 25
	_expect(is_equal_approx(order.progress_percent(), 25.0), "paid cost must define paid-order progress")
	order.manually_paused = true
	_expect(is_equal_approx(order.progress_percent(), 25.0), "pausing must preserve progress")
	order.paid_cost = 150
	_expect(is_equal_approx(order.progress_percent(), 100.0), "paid-order progress must clamp to 100")

	order.cost = 0
	order.build_time_ticks = 120.0
	order.elapsed_ticks = 30.0
	order.manually_paused = false
	_expect(is_equal_approx(order.progress_percent(), 25.0), "elapsed ticks must define free-order progress")
	order.ready = true
	order.elapsed_ticks = 0.0
	_expect(is_equal_approx(order.progress_percent(), 100.0), "ready state must always report complete")
	return true


func _test_technology_tree_houses() -> bool:
	var tree = TechnologyTreeScript.new()
	var player = PlayerDataScript.new()
	player.configure(1, "Atreides", Color.WHITE, &"Atreides", [&"Fremen"], 1)
	var no_buildings: Array[Node] = []

	_expect(not tree.is_available(null, player, no_buildings), "null config must be unavailable")
	_expect(not tree.is_available(_config(&"building"), null, no_buildings), "null player must be unavailable")
	_expect(tree.is_available(_config(&"building"), player, no_buildings), "a config without house must be available")
	_expect(
		tree.is_available(_config(&"building", &"Atreides"), player, no_buildings),
		"the player's primary house must be accepted"
	)
	_expect(
		tree.is_available(_config(&"building", &"Fremen"), player, no_buildings),
		"the player's subhouses must be accepted"
	)
	_expect(
		not tree.is_available(_config(&"building", &"Ix"), player, no_buildings),
		"an unrelated house must be rejected"
	)
	return true


func _test_technology_tree_building_requirements() -> bool:
	var tree = TechnologyTreeScript.new()
	var player = PlayerDataScript.new()
	player.configure(1, "Builder", Color.WHITE, &"Atreides")
	var primary := BuildingStub.new(&"ConYard", 1)
	var secondary := BuildingStub.new(&"Windtrap", 1)
	var enemy_primary := BuildingStub.new(&"ConYard", 2, 1)
	var buildings: Array[Node] = [primary, secondary]

	var config = _config(&"building", &"Atreides", [&"ConYard"], [&"Windtrap"])
	_expect(tree.is_available(config, player, buildings), "owned primary and secondary requirements must pass")
	_expect(
		not tree.is_available(config, player, [secondary]),
		"a missing primary requirement must fail"
	)
	_expect(
		not tree.is_available(config, player, [primary]),
		"a missing secondary requirement must fail"
	)
	_expect(
		not tree.is_available(config, player, [enemy_primary, secondary]),
		"another player's buildings must not satisfy requirements"
	)

	config = _config(&"building", &"Atreides", [&"ConYard"], [], true)
	_expect(not tree.is_available(config, player, buildings), "an upgraded requirement must reject level zero")
	primary.upgrade_level = 1
	_expect(tree.is_available(config, player, buildings), "an upgraded matching building must pass")

	config = _config(&"building", &"Atreides", [&"ConYard"], [&"Windtrap"], false, 4)
	_expect(
		tree.is_available(config, player, buildings),
		"max_tech_level defaulting to unlimited must not gate an entry"
	)
	_expect(
		not tree.is_available(config, player, buildings, 3),
		"a map tech level below the entry's tech_level must reject it"
	)
	_expect(
		tree.is_available(config, player, buildings, 4),
		"a map tech level at or above the entry's tech_level must accept it"
	)

	primary.free()
	secondary.free()
	enemy_primary.free()
	return true


func _test_technology_tree_unit_requirements() -> bool:
	var tree = TechnologyTreeScript.new()
	var player = PlayerDataScript.new()
	player.configure(1, "Trainer", Color.WHITE, &"Atreides")
	var barracks := BuildingStub.new(&"Barracks", 1)
	var windtrap := BuildingStub.new(&"Windtrap", 1)
	var buildings: Array[Node] = [barracks, windtrap]
	var config = _config(&"unit", &"Atreides", [&"Barracks", &"Factory"], [&"Windtrap"])

	_expect(tree.is_available(config, player, buildings), "unit lists must use primary_buildings/secondary_buildings")
	barracks.config_id = &"Unrelated"
	_expect(not tree.is_available(config, player, buildings), "unit primary requirements must be enforced")

	barracks.free()
	windtrap.free()
	return true


func _config(
		entity_type: StringName,
		house: StringName = &"",
		primary: Array = [],
		secondary: Array = [],
		upgraded_primary_required := false,
		tech_level := 0
):
	var config = RuleEntityConfigScript.new()
	config.entity_type = entity_type
	config.fields = {
		"house": String(house),
		"upgraded_primary_required": upgraded_primary_required,
		"tech_level": tech_level,
	}
	if entity_type == &"building":
		config.lists = {
			"requires_primary": primary,
			"requires_secondary": secondary,
		}
	else:
		config.lists = {
			"primary_buildings": primary,
			"secondary_buildings": secondary,
		}
	return config
