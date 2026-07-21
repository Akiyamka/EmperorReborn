extends SceneTree

const PlayerDataScript := preload("res://scripts/players/player_data.gd")
const PlayerRosterScript := preload("res://scripts/players/player_roster.gd")
const BuildingOrderScript := preload("res://scripts/buildings/building_order.gd")
const TechnologyTreeScript := preload("res://scripts/buildings/technology_tree.gd")
const BuildingDefinitionScript := preload("res://scripts/buildings/building_definition.gd")
const UnitDefinitionScript := preload("res://scripts/units/unit_definition.gd")
const ModelXbfScript := preload("res://converters/xbf/model_xbf.gd")
const ModelBakeBuilderScript := preload("res://converters/model_bake_builder.gd")
const BuildingBakeBuilderScript := preload("res://converters/building_bake_builder.gd")

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
	_run_case("XBF vertex animation fixed-point scale", _test_xbf_vertex_animation_scale)
	_run_case("XBF animation table variants", _test_xbf_animation_table_variants)
	_run_case("XBF FX banks retain parameters and event frames", _test_xbf_fx_banks)
	_run_case("building transition clips retain authored action names", _test_building_transition_clips)
	_run_case("XBF mirrored object animations use rotation-safe tracks", _test_mirrored_object_animation_handedness)
	_run_case("XBF mirrored inside-out meshes are re-oriented", _test_mirrored_mesh_orientation)
	_run_case("AT Refinery independent pads and mesh components", _test_at_refinery_partitioning)
	_run_case("Muzzle flash clip visibility", _test_muzzle_flash_clip_visibility)

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


func _test_xbf_vertex_animation_scale() -> bool:
	var cases := [
		["res://assets/raw_original_content/3DDATA/Units/AT_Scout_H0.XBF", "scout", 6, 19],
		["res://assets/raw_original_content/3DDATA/Units/AT_Sniper_H0.XBF", "sniper", 6, 20],
		["res://assets/raw_original_content/3DDATA/Units/AT_inf_H0.xbf", "LtINF", 9, 25],
	]
	for model_case: Array in cases:
		var xbf = ModelXbfScript.load_file(String(model_case[0]))
		_expect(xbf != null, "%s must parse" % String(model_case[0]).get_file())
		if xbf == null:
			continue
		_expect(xbf.animation_entries.size() == int(model_case[3]), "%s must expose all named animation clips" % String(model_case[0]).get_file())
		var object := _find_xbf_object(xbf.objects, String(model_case[1]))
		_expect(not object.is_empty(), "%s must contain its animated body" % String(model_case[0]).get_file())
		if object.is_empty():
			continue
		var animation: Dictionary = object.vertex_animation
		_expect(int(animation.get("kind", -1)) == int(model_case[2]), "%s must retain its fixed-point kind" % String(model_case[0]).get_file())
		var frames: Dictionary = animation.get("frames", {})
		var frame_ids := frames.keys()
		frame_ids.sort()
		_expect(not frame_ids.is_empty(), "%s must contain decoded vertex frames" % String(model_case[0]).get_file())
		if frame_ids.is_empty():
			continue
		var static_bounds := _points_bounds(object.positions as PackedVector3Array)
		var animated_bounds := _points_bounds(frames[frame_ids[0]] as PackedVector3Array)
		var relative_error := animated_bounds.size.distance_to(static_bounds.size) / maxf(static_bounds.size.length(), 0.0001)
		_expect(relative_error < 0.02, "%s animated body must preserve the authored scale" % String(model_case[0]).get_file())
	return true


func _find_xbf_object(objects: Array[Dictionary], expected_name: String) -> Dictionary:
	for object: Dictionary in objects:
		if String(object.name) == expected_name:
			return object
		var child := _find_xbf_object(object.children, expected_name)
		if not child.is_empty():
			return child
	return {}


func _points_bounds(points: PackedVector3Array) -> AABB:
	if points.is_empty():
		return AABB()
	var bounds := AABB(points[0], Vector3.ZERO)
	for point: Vector3 in points:
		bounds = bounds.expand(point)
	return bounds


func _test_xbf_animation_table_variants() -> bool:
	var cases := [
		["AT_Sniper_H0.XBF", 20],
		["G_harvester_h0.XbF", 13],
		["AT_General_H0.XBF", 22],
		["GU_Maker_H0.xbf", 5],
		["HK_ltinf_H0.xbf", 22],
		["IN_SurfaceWorm_H0.xbf", 13],
	]
	for model_case: Array in cases:
		var file_name := String(model_case[0])
		var path := "res://assets/raw_original_content/3DDATA/Units".path_join(file_name)
		var xbf = ModelXbfScript.load_file(path)
		_expect(xbf != null, "%s must parse" % file_name)
		if xbf == null:
			continue
		_expect(xbf.animation_entries.size() == int(model_case[1]), "%s must expose its complete animation table" % file_name)
		var names: Array[String] = []
		for entry: Dictionary in xbf.animation_entries:
			names.append(String(entry.get("name", "")))
		_expect(names.has("Stationary"), "%s must expose Stationary" % file_name)
	return true


func _test_xbf_fx_banks() -> bool:
	var cases := [
		[
			"AT_minotaurus_H0.xbf", 10.0,
			[170, 176, 184, 192], [171, 177, 185, 193], 4,
		],
		["AT_Trike_H0.xbf", 6.0, [106], [109], 2],
		["AT_inf_H0.xbf", 3.0, [215, 221, 229], [218, 223, 234], 7],
		["AT_Sniper_H0.XBF", 3.0, [232, 292], [233, 293], 1],
		["AT_APC_H0.xbf", 4.0, [111], [115], 3],
	]
	for model_case: Array in cases:
		var file_name := String(model_case[0])
		var path := "res://assets/raw_original_content/3DDATA/Units".path_join(file_name)
		var xbf = ModelXbfScript.load_file(path)
		_expect(xbf != null, "%s must parse for FX characterization" % file_name)
		if xbf == null:
			continue
		var shell_bank := _fx_bank_by_texture(xbf.fx_banks, "!%shel")
		_expect(not shell_bank.is_empty(), "%s must retain its !%%shel bank" % file_name)
		if shell_bank.is_empty():
			continue
		_expect(
			is_equal_approx(float(shell_bank.particle_size), float(model_case[1])),
			"%s must decode parameter 06 as source particle size" % file_name
		)
		_expect(
			int(shell_bank.texture_frame_count) == 10
			and (shell_bank.parameter_words as PackedInt32Array).size() == 16
			and (shell_bank.trailing_words as PackedInt32Array).size() == 8,
			"%s must preserve every typed and trailing FX-bank word" % file_name
		)
		_expect(xbf.fx_events_complete, "%s must expose its complete FX event table" % file_name)
		var bank_id := String(shell_bank.id)
		_expect(
			_fx_event_frames(xbf.fx_events, bank_id, "start") == model_case[2]
			and _fx_event_frames(xbf.fx_events, bank_id, "stop") == model_case[3],
			"%s must retain !%%shel start/stop frames" % file_name
		)
		var fire_entry := _xbf_animation_entry(xbf.animation_entries, "Fire 0")
		_expect(not fire_entry.is_empty(), "%s must retain Fire 0" % file_name)
		if not fire_entry.is_empty():
			_expect(
				_fx_emissions_during(
					xbf.fx_events, bank_id,
					int(fire_entry.start_frame), int(fire_entry.end_frame)
				) == int(model_case[4]),
				"%s must retain the authored Fire 0 casing count" % file_name
			)

	var mongoose_path := (
		"res://assets/raw_original_content/3DDATA/Units/AT_mongoose_H0.xbf"
	)
	var mongoose = ModelXbfScript.load_file(mongoose_path)
	_expect(
		mongoose != null and _fx_bank_by_texture(mongoose.fx_banks, "!%shel").is_empty(),
		"the Mongoose must not acquire a casing bank from its !cexp backblast"
	)

	var muzzle_cases := [
		["Muzzle1.xbf", 8.0, -0.3, [2], [5]],
		["Muzzle3.xbf", 10.0, -0.2, [3], [6]],
	]
	for muzzle_case: Array in muzzle_cases:
		var file_name := String(muzzle_case[0])
		var muzzle = ModelXbfScript.load_file(
			"res://assets/raw_original_content/3DDATA/Explosion".path_join(file_name)
		)
		_expect(muzzle != null, "%s must parse for muzzle smoke" % file_name)
		if muzzle == null:
			continue
		var smoke_bank := _fx_bank_by_texture(muzzle.fx_banks, "!%Bru")
		_expect(not smoke_bank.is_empty(), "%s must retain its !%%Bru bank" % file_name)
		if smoke_bank.is_empty():
			continue
		_expect(
			is_equal_approx(float(smoke_bank.particle_size), float(muzzle_case[1]))
			and is_equal_approx(float(smoke_bank.gravity), float(muzzle_case[2]))
			and int(smoke_bank.texture_frame_count) == 21,
			"%s must retain smoke size, signed gravity, and texture lifetime" % file_name
		)
		var smoke_bank_id := String(smoke_bank.id)
		_expect(
			_fx_event_frames(muzzle.fx_events, smoke_bank_id, "start") == muzzle_case[3]
			and _fx_event_frames(muzzle.fx_events, smoke_bank_id, "stop") == muzzle_case[4],
			"%s must retain its authored smoke emission interval" % file_name
		)

	var muzzle_builder = ModelBakeBuilderScript.new()
	var muzzle_scene: PackedScene = muzzle_builder.build(
		"res://assets/raw_original_content/3DDATA/Explosion/Muzzle1.xbf"
	)
	_expect(muzzle_scene != null, "Muzzle1 with FX metadata must build")
	if muzzle_scene != null:
		var muzzle_root := muzzle_scene.instantiate()
		var baked_smoke := _fx_bank_by_texture(
			muzzle_root.get_meta("xbf_fx_banks", []) as Array, "!%Bru"
		)
		_expect(
			not baked_smoke.is_empty()
			and is_equal_approx(float(baked_smoke.world_particle_size), 0.5)
			and is_equal_approx(float(baked_smoke.world_gravity), -7.5),
			"Muzzle1 must bake source smoke size and signed gravity into world units"
		)
		muzzle_root.free()

	var builder = ModelBakeBuilderScript.new()
	var scene: PackedScene = builder.build(
		"res://assets/raw_original_content/3DDATA/Units/AT_inf_H0.xbf"
	)
	_expect(scene != null, "the infantry model with FX metadata must build")
	if scene != null:
		var root := scene.instantiate()
		var baked_shell := _fx_bank_by_texture(
			root.get_meta("xbf_fx_banks", []) as Array, "!%shel"
		)
		_expect(
			not baked_shell.is_empty()
			and is_equal_approx(float(baked_shell.world_particle_size), 3.0 / 16.0),
			"the packed scene must retain source and world-space particle sizes"
		)
		var baked_events := root.get_meta("xbf_fx_events", []) as Array
		_expect(
			bool(root.get_meta("xbf_fx_events_complete", false))
			and _fx_event_frames(
				baked_events, String(baked_shell.get("id", "")), "start"
			) == [215, 221, 229]
			and not (root.get_meta(
				"xbf_fx_event_raw_data", PackedByteArray()
			) as PackedByteArray).is_empty(),
			"the packed scene must retain the infantry FX event table"
		)
		root.free()
	return true


func _fx_bank_by_texture(banks: Array, texture: String) -> Dictionary:
	for bank_value: Variant in banks:
		var bank := bank_value as Dictionary
		if String(bank.get("texture", "")).nocasecmp_to(texture) == 0:
			return bank
	return {}


func _fx_event_frames(events: Array, bank_id: String, action: String) -> Array[int]:
	var result: Array[int] = []
	for event_value: Variant in events:
		var event := event_value as Dictionary
		if String(event.get("bank_id", "")) == bank_id \
		and String(event.get("action", "")) == action:
			result.append(int(event.get("frame", -1)))
	return result


func _xbf_animation_entry(entries: Array, name: String) -> Dictionary:
	for entry_value: Variant in entries:
		var entry := entry_value as Dictionary
		if String(entry.get("name", "")) == name:
			return entry
	return {}


func _fx_emissions_during(
		events: Array, bank_id: String, start_frame: int, end_frame: int
	) -> int:
	var active_frames := {}
	var result := 0
	for event_value: Variant in events:
		var event := event_value as Dictionary
		var frame := int(event.get("frame", -1))
		if String(event.get("bank_id", "")) != bank_id \
		or frame < start_frame or frame > end_frame:
			continue
		var attachment := String(event.get("attachment", ""))
		if String(event.get("action", "")) == "start":
			active_frames[attachment] = frame
		elif String(event.get("action", "")) == "stop" \
		and active_frames.has(attachment):
			# Start/stop are control frames. Particles occupy the intervening
			# frames; a one-frame pulse still emits one particle.
			result += maxi(frame - int(active_frames[attachment]) - 1, 1)
			active_frames.erase(attachment)
	return result


func _test_building_transition_clips() -> bool:
	var builder = BuildingBakeBuilderScript.new()
	var scene: PackedScene = builder.build(&"ATConYard")
	_expect(scene != null, "ATConYard wrapper must build")
	if scene == null:
		return true
	var root := scene.instantiate()
	var player := root.get_node_or_null("StatePlayer") as AnimationPlayer
	_expect(player != null, "ATConYard wrapper must expose its state player")
	if player != null:
		var names := Array(player.get_animation_list())
		_expect(names.has(&"construct"), "HC Construct must be exported as construct")
		_expect(names.has(&"deconstruct"), "HC Deconstruct must be exported as deconstruct")
		_expect(names.has(&"sell"), "HC Sell must be exported as sell")
		_expect(not names.has(&"build"), "the obsolete build transition name must not be exported")
		var source_player := root.get_node_or_null("States/Build/AnimationPlayer") as AnimationPlayer
		_expect(source_player != null, "the HC source player must remain available")
		if source_player != null:
			for action_case in [
				[&"construct", &"Construct"],
				[&"deconstruct", &"Deconstruct"],
				[&"sell", &"Sell"],
			]:
				var exported := player.get_animation(action_case[0])
				var authored := source_player.get_animation(action_case[1])
				_expect(
					exported != null and authored != null
						and is_equal_approx(exported.length, authored.length),
					"%s must retain the authored %s duration" % action_case
				)
	root.free()
	return true


func _test_mirrored_object_animation_handedness() -> bool:
	var path := "res://assets/raw_original_content/3DDATA/Buildings/AT_Conyard_HC.XBF"
	var xbf = ModelXbfScript.load_file(path)
	_expect(xbf != null, "AT ConYard construction model must parse")
	if xbf == null:
		return true

	var builder = ModelBakeBuilderScript.new()
	var scene: PackedScene = builder.build(path)
	_expect(scene != null, "AT ConYard construction model must build")
	if scene == null:
		return true
	var root := scene.instantiate()
	var player := root.get_node("AnimationPlayer") as AnimationPlayer
	var construct := player.get_animation(&"Construct") if player != null else null
	_expect(construct != null, "AT ConYard must expose its Construct clip")
	if construct == null:
		root.free()
		return true
	for track_index in construct.get_track_count():
		if construct.track_get_type(track_index) != Animation.TYPE_VALUE:
			continue
		var track_path := String(construct.track_get_path(track_index))
		if not track_path.ends_with(":transform"):
			continue
		var rotation_safe := true
		for key_index in construct.track_get_key_count(track_index):
			var key_transform := construct.track_get_key_value(track_index, key_index) as Transform3D
			if key_transform.basis.determinant() <= 0.0:
				rotation_safe = false
				break
		_expect(rotation_safe, "%s must contain only rotation-safe Transform3D keys" % track_path)

	for object_name in [&"clonetread01", &"clonetread02"]:
		var object := _find_xbf_object(xbf.objects, String(object_name))
		_expect(not object.is_empty(), "%s must exist in the source model" % object_name)
		if object.is_empty():
			continue
		var track := _animation_track_containing(construct, String(object_name))
		_expect(track >= 0, "%s must retain its transform track" % object_name)
		if track < 0:
			continue

		var source_center := _points_bounds(object.positions as PackedVector3Array).get_center()
		var converted_center := Vector3(source_center.x, source_center.y, -source_center.z)
		var track_node_path := String(construct.track_get_path(track)).trim_suffix(":transform")
		var mirrored_content := root.get_node_or_null("%s/MirroredContent" % track_node_path) as Node3D
		_expect(mirrored_content != null, "%s must factor its reflection into static content" % object_name)
		if mirrored_content == null:
			continue
		var source_frames: Dictionary = object.object_animation.frames
		for frame_id in [0, 77, 92, 191]:
			var source_transform := _source_to_godot_transform(source_frames[frame_id])
			var converted_transform: Transform3D = construct.track_get_key_value(track, frame_id)
			_expect(
				converted_transform.basis.determinant() > 0.0,
				"%s frame %d animation key must be rotation-safe" % [object_name, frame_id]
			)
			var effective_transform := converted_transform * mirrored_content.transform
			_expect(
				effective_transform.basis.determinant() < 0.0,
				"%s frame %d effective transform must remain mirrored" % [object_name, frame_id]
			)
			_expect(
				(effective_transform * converted_center).distance_to(
					source_transform * converted_center
				) < 0.001,
				"%s frame %d must preserve its authored Z placement" % [object_name, frame_id]
			)

	root.free()
	return true


## clonetread01/02 are authored inside-out for their always-mirrored placement
## and must be re-oriented at bake; girderbox06 is equally mirrored but
## authored outward and must keep its authored orientation.
func _test_mirrored_mesh_orientation() -> bool:
	var builder = ModelBakeBuilderScript.new()
	var scene: PackedScene = builder.build("res://assets/raw_original_content/3DDATA/Buildings/AT_Conyard_HC.XBF")
	_expect(scene != null, "AT ConYard construction model must build")
	if scene == null:
		return true
	var root := scene.instantiate()
	for object_name in ["clonetread01", "clonetread02", "girderbox06"]:
		var node := root.find_child(object_name, true, false) as Node3D
		_expect(node != null, "%s must exist in the converted scene" % object_name)
		if node == null:
			continue
		var content: Node = node.get_node_or_null("MirroredContent")
		if content == null:
			content = node
		var checked := 0
		# Flat split-off components are direction-neutral around their own
		# centroid, so outwardness is judged once per object as a magnitude-
		# weighted sum instead of per triangle.
		var outward_sum := 0.0
		for child in content.get_children():
			if child is MeshInstance3D:
				var mesh := (child as MeshInstance3D).mesh as ArrayMesh
				if mesh != null:
					outward_sum += _expect_outward_mesh(mesh, object_name)
					checked += 1
		_expect(checked > 0, "%s must carry mesh geometry" % object_name)
		_expect(outward_sum > 0.0, "%s normals must point outward (weighted sum %f)" % [object_name, outward_sum])
	root.free()
	return true


func _expect_outward_mesh(mesh: ArrayMesh, object_name: String) -> float:
	var centroid := Vector3.ZERO
	var vertex_count := 0
	for surface_index in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface_index)
		for vertex: Vector3 in arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array:
			centroid += vertex
			vertex_count += 1
	if vertex_count == 0:
		return 0.0
	centroid /= vertex_count
	var outward_sum := 0.0
	for surface_index in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface_index)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var triangle_count := indices.size() / 3
		var winding_front := 0
		for i in range(0, indices.size(), 3):
			var v0 := vertices[indices[i]]
			var v1 := vertices[indices[i + 1]]
			var v2 := vertices[indices[i + 2]]
			var normal_sum := normals[indices[i]] + normals[indices[i + 1]] + normals[indices[i + 2]]
			outward_sum += ((v0 + v1 + v2) / 3.0 - centroid).dot(normal_sum)
			# Godot treats clockwise-wound faces as front, so a front face's
			# right-handed winding normal points against the shading normal.
			if (v1 - v0).cross(v2 - v0).dot(normal_sum) < 0.0:
				winding_front += 1
		_expect(
			winding_front == triangle_count,
			"%s surface %d winding must face outward (%d/%d)" % [object_name, surface_index, winding_front, triangle_count]
		)
	return outward_sum


func _animation_track_containing(animation: Animation, object_name: String) -> int:
	for track_index in animation.get_track_count():
		var path := String(animation.track_get_path(track_index))
		if path.contains(object_name) and path.ends_with(":transform"):
			return track_index
	return -1


func _source_to_godot_transform(source: Transform3D) -> Transform3D:
	var transform := source
	transform.basis.x = Vector3(source.basis.x.x, source.basis.x.y, -source.basis.x.z)
	transform.basis.y = Vector3(source.basis.y.x, source.basis.y.y, -source.basis.y.z)
	transform.basis.z = Vector3(-source.basis.z.x, -source.basis.z.y, source.basis.z.z)
	transform.origin = Vector3(source.origin.x, source.origin.y, -source.origin.z)
	return transform


func _test_at_refinery_partitioning() -> bool:
	var path := "res://assets/raw_original_content/3DDATA/Buildings/at_refinery_h0.xbf"
	var xbf = ModelXbfScript.load_file(path)
	_expect(xbf != null, "AT Refinery H0 must parse")
	if xbf == null:
		return true
	var target_ids: Array[int] = []
	for entry: Dictionary in xbf.animation_entries:
		target_ids.append(int(entry.get("target_object_id", 0)))
	_expect(target_ids == [0, 3, 4], "AT Refinery clips must retain their Stationary/left-pad/right-pad targets")

	var builder = ModelBakeBuilderScript.new()
	var scene: PackedScene = builder.build(path)
	_expect(scene != null, "AT Refinery H0 must build")
	if scene == null:
		return true
	var root: Node = scene.instantiate()
	var player := root.find_child("AnimationPlayer", true, false) as AnimationPlayer
	_expect(player != null, "AT Refinery must contain an AnimationPlayer")
	if player != null:
		var stationary_paths := _transform_track_paths(player.get_animation(&"Stationary"))
		var left_pad_paths := _transform_track_paths(player.get_animation(&"Refinery_Pad_1"))
		var right_pad_paths := _transform_track_paths(player.get_animation(&"Refinery_Pad_2"))
		_expect(stationary_paths.all(func(value: String) -> bool: return not value.contains("SmallPad")), "Stationary must not move either SmallPad")
		_expect(left_pad_paths.size() == 1 and left_pad_paths[0].contains("_3SmallPad01"), "Refinery Pad 1 must move only the left SmallPad")
		_expect(right_pad_paths.size() == 1 and right_pad_paths[0].contains("_4SmallPad02"), "Refinery Pad 2 must move only the right SmallPad")

	var shell := root.find_child("at_refinery", true, false)
	var shell_meshes: Array[MeshInstance3D] = []
	if shell != null:
		for child in shell.get_children():
			if child is MeshInstance3D:
				shell_meshes.append(child as MeshInstance3D)
	_expect(shell_meshes.size() > 1, "the disconnected idle shell must not remain one giant MeshInstance")
	var triangle_count := 0
	var maximum_surfaces := 0
	for mesh_instance in shell_meshes:
		maximum_surfaces = maxi(maximum_surfaces, mesh_instance.mesh.get_surface_count())
		for surface_index in mesh_instance.mesh.get_surface_count():
			var arrays := mesh_instance.mesh.surface_get_arrays(surface_index)
			triangle_count += (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
	_expect(triangle_count == 373, "splitting the idle shell must preserve all 373 authored triangles")
	_expect(maximum_surfaces < 16, "build/material groups must no longer collapse into one 16-surface idle mesh")
	var broken_mesh_03 := shell.get_node_or_null("Mesh_03") as MeshInstance3D if shell != null else null
	var broken_mesh_10 := shell.get_node_or_null("Mesh_10") as MeshInstance3D if shell != null else null
	_expect(broken_mesh_03 != null and not broken_mesh_03.visible, "the shipped broken AT Refinery Mesh_03 must stay hidden")
	_expect(broken_mesh_10 != null and not broken_mesh_10.visible, "the shipped broken AT Refinery Mesh_10 must stay hidden")
	_expect(
		broken_mesh_03 != null and broken_mesh_03.get_meta("source_asset_quirk", "") == "broken_geometry",
		"hidden Mesh_03 must document why it is suppressed in the converted scene"
	)
	_expect(
		broken_mesh_10 != null and broken_mesh_10.get_meta("source_asset_quirk", "") == "broken_geometry",
		"hidden Mesh_10 must document why it is suppressed in the converted scene"
	)
	root.free()
	return true


func _transform_track_paths(animation: Animation) -> Array[String]:
	var paths: Array[String] = []
	if animation == null:
		return paths
	for track_index in animation.get_track_count():
		if animation.track_get_type(track_index) != Animation.TYPE_VALUE:
			continue
		var path := String(animation.track_get_path(track_index))
		if path.ends_with(":transform"):
			paths.append(path)
	return paths


func _test_muzzle_flash_clip_visibility() -> bool:
	var cases := [
		["res://assets/raw_original_content/3DDATA/Units/AT_Kindjal_H0.xbf", 2],
		["res://assets/raw_original_content/3DDATA/Units/AT_Sniper_H0.XBF", 1],
	]
	for model_case: Array in cases:
		var builder = ModelBakeBuilderScript.new()
		var scene: PackedScene = builder.build(String(model_case[0]))
		_expect(scene != null, "%s must build" % String(model_case[0]).get_file())
		if scene == null:
			continue
		var root: Node = scene.instantiate()
		var player := root.find_child("AnimationPlayer", true, false) as AnimationPlayer
		_expect(player != null, "%s must contain an AnimationPlayer" % String(model_case[0]).get_file())
		if player != null:
			var stationary_values := _muzzle_flash_visibility_values(player.get_animation(&"Stationary"))
			var fire_values := _muzzle_flash_visibility_values(player.get_animation(&"Fire_0"))
			_expect(stationary_values.size() == int(model_case[1]), "%s must track every muzzle flash in Stationary" % String(model_case[0]).get_file())
			_expect(stationary_values.all(func(value: bool) -> bool: return not value), "%s must hide muzzle flashes in Stationary" % String(model_case[0]).get_file())
			_expect(fire_values.count(true) == 1, "%s Fire_0 must show only its active muzzle flash" % String(model_case[0]).get_file())
		root.free()
	return true


func _muzzle_flash_visibility_values(animation: Animation) -> Array[bool]:
	var result: Array[bool] = []
	if animation == null:
		return result
	for track_index in animation.get_track_count():
		var track_path := String(animation.track_get_path(track_index))
		if track_path.to_lower().contains("bigflash") and track_path.ends_with(":visible"):
			result.append(bool(animation.track_get_key_value(track_index, 0)))
	return result


func _config(
		entity_type: StringName,
		house: StringName = &"",
		primary: Array = [],
		secondary: Array = [],
		upgraded_primary_required := false,
		tech_level := 0
):
	var config = BuildingDefinitionScript.new() if entity_type == &"building" else UnitDefinitionScript.new()
	config.house_id = house
	config.upgraded_primary_required = upgraded_primary_required
	config.tech_level = tech_level
	var typed_primary: Array[StringName] = []
	var typed_secondary: Array[StringName] = []
	typed_primary.assign(primary)
	typed_secondary.assign(secondary)
	if entity_type == &"building":
		config.primary_building_ids = typed_primary
		config.secondary_building_ids = typed_secondary
	else:
		config.primary_building_ids = typed_primary
		config.secondary_building_ids = typed_secondary
	return config
