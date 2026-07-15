extends SceneTree

const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")
const HarvesterScene := preload("res://scenes/units/harvester.tscn")
const ATRefineryScene := preload("res://assets/converted/buildings/ATRefinery/ATRefinery.scn")

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
	await _run_case("units and buildings use authored collision meshes", _test_authored_collision_meshes)
	await _run_case("units follow terrain elevation", _test_units_follow_terrain)
	await _run_case("units turn at their rules rates", _test_unit_turn_rates)
	await _run_case("entity forward directions share one world-space contract", _test_entity_orientation_contract)
	await _run_case("units switch between stationary and movement animations", _test_unit_movement_animations)
	await _run_case("test match roster is non-empty after boot", _test_match_roster_populated)
	await _run_case("rules art configs resolve every test panel icon", _test_match_panel_icons)
	await _run_case("rules sidebar type selects the panel tab", _test_rules_sidebar_tabs)
	await _run_case("upgrade panel only lists buildings with an upgrade defined", _test_upgrade_panel_matches_controller)
	await _run_case("upgrade slot appears after its building is placed later", _test_upgrade_availability_polls)
	await _run_case("unit slots follow prerequisite buildings and their upgrades", _test_unit_roster_availability)
	await _run_case("completed units emerge from primary building toward rally point", _test_unit_production_rally_and_primary)
	await _run_case("real harvester completes a refinery unload trip", _test_real_harvester_unload_trip)
	await _run_case("occupy matrices are Z-mirrored to match converted models", _test_occupy_rows_are_mirrored)

	if _failures > 0:
		printerr("Match integration tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("Match integration tests: %d assertions passed" % _assertions)
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


func _test_authored_collision_meshes() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	await physics_frame
	var navigation := match_instance.get_node_or_null("UnitNavigationSystem")

	for unit_name in [&"ScoutA", &"OrdosAPC", &"NIABTank"]:
		var unit := match_instance.get_node("Units/%s" % unit_name)
		_expect(unit._collision_sources().size() > 0, "%s must expose an authored collision volume" % unit_name)
		var rule_size := float(unit.unit_config.field(&"size", 1.0))
		var rule_radius := maxf(0.35, rule_size * 0.42)
		var navigation_radius := float(unit.navigation_collision_radius(rule_radius))
		_expect(
			navigation_radius > rule_radius * 1.2,
			"%s navigation radius must reflect its authored body width (%.2f, rules-only %.2f)" % [unit_name, navigation_radius, rule_radius]
		)
		var registered_radius := float(navigation.agent_debug(unit).get("radius", 0.0)) if navigation != null else 0.0
		_expect(
			is_equal_approx(registered_radius, navigation_radius),
			"%s navigation agent must use authored radius %.2f (got %.2f)" % [unit_name, navigation_radius, registered_radius]
		)
		_expect(
			_authored_collision_shapes(unit).size() > 0,
			"%s must create a collision shape from its authored volume" % unit_name
		)
		for collision in _authored_collision_shapes(unit):
			_expect(
				collision.shape is ConvexPolygonShape3D,
				"%s must not use a hand-authored box or capsule collision" % unit_name
			)

	for building_name in [&"ATConYard", &"ATSmWindtrap"]:
		var building := match_instance.get_node("Buildings/%s" % building_name)
		var body := building.get_node_or_null("SelectionCollision") as StaticBody3D
		_expect(body != null, "%s must have a selection collision body" % building_name)
		_expect(
			body != null and _authored_collision_shapes(body).size() > 0,
			"%s must create collision from its authored volume" % building_name
		)
		for collision in _authored_collision_shapes(body):
			_expect(
				collision.shape is ConvexPolygonShape3D,
				"%s must not fall back to a generated box collision" % building_name
			)

	match_instance.queue_free()


func _test_units_follow_terrain() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	await physics_frame
	await physics_frame
	await physics_frame

	for unit_name in [&"ScoutA", &"OrdosAPC", &"NIABTank"]:
		var unit := match_instance.get_node("Units/%s" % unit_name) as CharacterBody3D
		_expect(unit.collision_mask == 0, "%s must not physically collide with terrain triangles" % unit_name)
		var terrain_hit := _terrain_hit_below(unit)
		_expect(not terrain_hit.is_empty(), "%s must have terrain beneath it" % unit_name)
		if not terrain_hit.is_empty():
			var terrain_position: Vector3 = terrain_hit["position"]
			_expect(
				is_equal_approx(unit.global_position.y, terrain_position.y),
				"%s must sit on the terrain instead of hovering at its spawn height" % unit_name
			)

	match_instance.queue_free()


func _terrain_hit_below(unit: CharacterBody3D) -> Dictionary:
	if unit == null:
		return {}
	var position := unit.global_position
	var query := PhysicsRayQueryParameters3D.create(
		position + Vector3.UP * 200.0,
		position - Vector3.UP * 200.0,
		1
	)
	query.exclude = [unit.get_rid()]
	return get_root().get_world_3d().direct_space_state.intersect_ray(query)


func _test_unit_turn_rates() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	await physics_frame

	var expected_rates := {
		&"ScoutA": 0.2,
		&"OrdosAPC": 0.05,
		&"NIABTank": 0.3,
	}
	for unit_name in expected_rates:
		var unit := match_instance.get_node("Units/%s" % unit_name) as Unit
		var expected_rate: float = expected_rates[unit_name]
		_expect(
			is_equal_approx(unit.turn_rate, expected_rate),
			"%s must load turn_rate %.3f from its unit rules (got %.3f)" % [unit_name, expected_rate, unit.turn_rate]
		)
		unit.rotation = Vector3.ZERO
		unit.call("_turn_toward", Vector3.RIGHT, 1.0 / Unit.RULE_MOVEMENT_UPDATES_PER_SECOND)
		_expect(
			is_equal_approx(absf(unit.rotation.y), expected_rate),
			"%s must turn by %.3f radians in one rules movement update (got %.3f)" % [unit_name, expected_rate, absf(unit.rotation.y)]
		)

	var omnidirectional := match_instance.get_node("Units/OrdosAPC") as Unit
	_expect(omnidirectional.can_move_any_direction, "ORAPC must load CanMoveAnyDirection=true from its rules")
	omnidirectional.rotation = Vector3.ZERO
	var omnidirectional_start := omnidirectional.global_position
	omnidirectional.navigation_step(Vector3.RIGHT * omnidirectional.move_speed, 1.0 / Unit.RULE_MOVEMENT_UPDATES_PER_SECOND)
	_expect(
		omnidirectional.global_position.x > omnidirectional_start.x,
		"an omnidirectional unit must translate while it is still turning"
	)
	_expect(
		not is_equal_approx(omnidirectional.rotation.y, -PI / 2.0),
		"the omnidirectional unit must still obey its turn-rate limit while translating"
	)

	var sequential := match_instance.get_node("Units/ScoutA") as Unit
	sequential.setup(&"IMTANK")
	_expect(not sequential.can_move_any_direction, "a null CanMoveAnyDirection rule must load as false")
	sequential.rotation = Vector3.ZERO
	var sequential_start := sequential.global_position
	var tick_delta := 1.0 / Unit.RULE_MOVEMENT_UPDATES_PER_SECOND
	sequential.navigation_step(Vector3.RIGHT * sequential.move_speed, tick_delta)
	_expect(
		is_equal_approx(sequential.global_position.x, sequential_start.x)
			and is_equal_approx(sequential.global_position.z, sequential_start.z),
		"a sequential unit must stay in place while turning toward its movement direction"
	)
	_expect(sequential.velocity.is_zero_approx(), "a sequential unit must expose zero velocity while turning in place")
	for _update in 9:
		sequential.navigation_step(Vector3.RIGHT * sequential.move_speed, tick_delta)
	_expect(
		sequential.global_position.x > sequential_start.x,
		"a sequential unit must begin translating after it finishes turning"
	)

	match_instance.queue_free()


func _test_entity_orientation_contract() -> void:
	var building := Building.new()
	var unit := Unit.new()
	for yaw in [0.0, PI / 2.0, PI, -PI / 2.0]:
		building.rotation = Vector3(0.0, yaw, 0.0)
		unit.face_direction(building.exit_direction())
		_expect(
			unit.facing_direction().dot(building.exit_direction()) > 0.999,
			"a unit must face a building's exit at yaw %.3f without knowing either asset's local axis" % yaw
		)
	building.free()
	unit.free()


func _test_unit_movement_animations() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	await physics_frame
	await physics_frame
	await physics_frame

	for unit_name in [&"ScoutA", &"OrdosAPC", &"NIABTank"]:
		var unit := match_instance.get_node("Units/%s" % unit_name) as Unit
		var player := _unit_animation_player(unit)
		_expect(player != null, "%s must expose a model AnimationPlayer" % unit_name)
		_expect(player != null and _is_unit_idle(player), "%s must start with an idle animation" % unit_name)
		if player != null and _idle_animation_count(player) > 0:
			_expect(player.current_animation == &"Stationary", "%s idle sequence must start with Stationary" % unit_name)
			if player.has_animation(&"Idle_0") and player.has_animation(&"Idle_1"):
				_expect(
					unit.call("_idle_animation_weight", &"Idle_0") > unit.call("_idle_animation_weight", &"Idle_1"),
					"%s higher-numbered Idle* clips must have lower selection weight" % unit_name
				)
			var stationary_plays := 0
			while player.current_animation == &"Stationary" and stationary_plays < 16:
				stationary_plays += 1
				player.animation_finished.emit(&"Stationary")
			_expect(stationary_plays >= 5 and stationary_plays <= 15, "%s must play Stationary 5-15 times" % unit_name)
			_expect(String(player.current_animation).begins_with("Idle"), "%s must play a random Idle* after Stationary" % unit_name)
			player.animation_finished.emit(player.current_animation)
			_expect(player.current_animation == &"Stationary", "%s must restart with Stationary after Idle*" % unit_name)
		unit.move_to(unit.global_position + Vector3(3.0, 0.0, 0.0))
		for _frame in 20:
			await physics_frame
			if unit.velocity.length_squared() > 0.01:
				break
		_expect(player != null and player.current_animation == &"Move", "%s must play Move while travelling" % unit_name)
		_expect(
			player != null and is_equal_approx(player.speed_scale, unit.velocity.length() / unit.move_speed),
			"%s Move animation speed must match its physical velocity" % unit_name
		)
		unit.stop_at_current_position()
		_expect(player != null and _is_unit_idle(player), "%s must return to an idle animation when stopped" % unit_name)
		_expect(player != null and is_equal_approx(player.speed_scale, 1.0), "%s must reset its animation speed when stopped" % unit_name)

	match_instance.queue_free()


func _unit_animation_player(unit: Unit) -> AnimationPlayer:
	if unit == null:
		return null
	var players := unit.get_node("VisualRoot").find_children("*", "AnimationPlayer", true, false)
	for node in players:
		var player := node as AnimationPlayer
		if player.has_animation(&"Move") and player.has_animation(&"Stationary"):
			return player
	return null


func _is_unit_idle(player: AnimationPlayer) -> bool:
	if player == null:
		return false
	if _idle_animation_count(player) > 0:
		return player.current_animation == &"Stationary" or String(player.current_animation).begins_with("Idle")
	return player.current_animation == &"Stationary"


func _idle_animation_count(player: AnimationPlayer) -> int:
	var idle_variants := 0
	for animation_name in player.get_animation_list():
		if String(animation_name).begins_with("Idle"):
			idle_variants += 1
	return idle_variants


func _authored_collision_shapes(node: Node) -> Array[CollisionShape3D]:
	var result: Array[CollisionShape3D] = []
	if node == null:
		return result
	for child in node.get_children():
		if child is CollisionShape3D:
			result.append(child)
	return result


func _test_match_roster_populated() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	await process_frame
	await process_frame

	_expect(
		not match_instance._building_option_ids.is_empty(),
		"the local player's building roster must not be empty when a Construction Yard already exists"
	)
	_expect(
		match_instance._building_option_ids.has(&"ATBarracks"),
		"ATBarracks must be available given the fixture's starting ATConYard + ATSmWindtrap"
	)

	var side_panel = match_instance.get_node("HUD/SidePanel")
	_expect(
		side_panel._building_option_ids.has(&"ATBarracks"),
		"the roster must reach the side panel's building grid, not just Match's own state"
	)

	match_instance.queue_free()


func _test_match_panel_icons() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	await process_frame
	await process_frame

	var side_panel = match_instance.get_node("HUD/SidePanel")
	var option_ids: Array[StringName] = side_panel._building_option_ids.duplicate()
	for upgrade_id in side_panel._upgrade_option_ids:
		if not option_ids.has(upgrade_id):
			option_ids.append(upgrade_id)
	for option_id in option_ids:
		var icon_data: Array[Texture2D] = side_panel._building_icon_data(option_id)
		_expect(
			icon_data.size() == 2 and icon_data[0] != null and icon_data[1] != null,
			"Rules art config must resolve colored and grey icons for %s" % String(option_id)
		)

	match_instance.queue_free()


func _test_rules_sidebar_tabs() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	await process_frame
	await process_frame

	var side_panel = match_instance.get_node("HUD/SidePanel")
	_expect(
		side_panel._art_tab_for_entity(&"ATBarracks", SidePanel.Tab.INFANTRY) == SidePanel.Tab.BUILDINGS,
		"Buildings sidebar type must select the Buildings tab"
	)
	_expect(
		side_panel._art_tab_for_entity(&"ATInfantry", SidePanel.Tab.VEHICLES) == SidePanel.Tab.INFANTRY,
		"Infantry sidebar type must select the Infantry tab"
	)
	_expect(
		side_panel._art_tab_for_entity(&"ATAPC", SidePanel.Tab.INFANTRY) == SidePanel.Tab.VEHICLES,
		"Units sidebar type must select the Vehicles tab"
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
	var match_instance := MatchFixtureScene.instantiate()
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
		controller_ids.has(&"ATConYard"),
		"ATConYard is deployed rather than built but its global upgrade must still be an upgrade option"
	)
	_expect(
		side_panel._upgrade_option_ids == controller_ids,
		"the panel's upgrade grid must exactly match the controller's filtered roster, not the raw building roster"
	)

	match_instance.queue_free()


## Regression test: BuildingController.process() polls _is_building_available()
## every frame and diffs it against a cached dict so the BUILDINGS grid
## reacts to buildings appearing/disappearing elsewhere on the map, but
## BuildingUpgradeController had no equivalent poll -- its option states were
## only computed once at setup() and on queue events, so an upgrade slot for
## a building type the player didn't yet own at boot (e.g. ATBarracks, before
## any Barracks is built) stayed hidden forever even after that building was
## placed. _poll_upgrade_availability() fixes this the same way
## BuildingController already does it.
func _test_upgrade_availability_polls() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	await process_frame
	await process_frame

	var side_panel = match_instance.get_node("HUD/SidePanel")
	side_panel._set_active_tab(3) # Tab.UPGRADES
	await process_frame

	var slot_before = side_panel._upgrade_slot(&"ATBarracks")
	_expect(
		slot_before != null and not slot_before.visible,
		"ATBarracks upgrade must start hidden -- the fixture has no Barracks yet"
	)

	var barracks_scene := load("res://assets/converted/buildings/ATBarracks/ATBarracks.scn") as PackedScene
	var barracks := barracks_scene.instantiate()
	match_instance.get_node("Buildings").add_child(barracks)
	barracks.call("setup", &"ATBarracks")
	barracks.call("set_owner_player_id", 1)

	for i in 5:
		await process_frame

	var slot_after = side_panel._upgrade_slot(&"ATBarracks")
	_expect(
		slot_after != null and slot_after.visible,
		"ATBarracks upgrade must become visible once a Barracks is placed, without any manual refresh call"
	)

	# Once purchased, the slot should disappear rather than linger with an
	# "OWNED" label -- there is nothing left to do with a finished
	# global-type upgrade.
	var players = get_root().get_node_or_null("/root/Players")
	var player = players.player(1)
	player.grant_upgrade(&"ATBarracks")

	for i in 5:
		await process_frame

	var slot_purchased = side_panel._upgrade_slot(&"ATBarracks")
	_expect(
		slot_purchased != null and not slot_purchased.visible,
		"a purchased upgrade's slot must be hidden, not left visible with an OWNED label"
	)

	match_instance.queue_free()


## Units share the building grid (docs/mechanics/production.md sections 3 and
## 5): a unit's slot must appear only once its primary production building is
## owned, and units flagged upgraded_primary_required must additionally wait
## for that building's upgrade.
func _test_unit_roster_availability() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	await process_frame
	await process_frame

	var side_panel = match_instance.get_node("HUD/SidePanel")
	_expect(
		match_instance._unit_option_ids.has(&"ATInfantry"),
		"the local player's unit roster must include ATInfantry"
	)
	_expect(
		match_instance._unit_option_ids.has(&"Harvester"),
		"the shared house-less Harvester must be in the unit roster"
	)
	_expect(
		side_panel._building_option_ids.has(&"ATInfantry"),
		"the unit roster must reach the side panel grid"
	)

	# Tab.INFANTRY is the panel's boot default, so both slots are live.
	var infantry_slot = side_panel._building_slot(&"ATInfantry")
	var kindjal_slot = side_panel._building_slot(&"ATKindjal")
	_expect(
		infantry_slot != null and not infantry_slot.visible,
		"ATInfantry must start hidden -- the fixture has no Barracks yet"
	)
	_expect(
		kindjal_slot != null and not kindjal_slot.visible,
		"ATKindjal must start hidden without a Barracks"
	)

	var barracks_scene := load("res://assets/converted/buildings/ATBarracks/ATBarracks.scn") as PackedScene
	var barracks := barracks_scene.instantiate()
	match_instance.get_node("Buildings").add_child(barracks)
	barracks.call("setup", &"ATBarracks")
	barracks.call("set_owner_player_id", 1)

	for i in 5:
		await process_frame

	infantry_slot = side_panel._building_slot(&"ATInfantry")
	kindjal_slot = side_panel._building_slot(&"ATKindjal")
	_expect(
		infantry_slot != null and infantry_slot.visible,
		"ATInfantry must become visible once a Barracks is owned"
	)
	_expect(
		kindjal_slot != null and not kindjal_slot.visible,
		"ATKindjal has upgraded_primary_required and must stay hidden behind an unupgraded Barracks"
	)

	barracks.call("set_upgrade_level", 1)

	for i in 5:
		await process_frame

	kindjal_slot = side_panel._building_slot(&"ATKindjal")
	_expect(
		kindjal_slot != null and kindjal_slot.visible,
		"ATKindjal must become visible once the Barracks is upgraded"
	)

	match_instance.queue_free()


func _test_unit_production_rally_and_primary() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	await process_frame
	await process_frame

	var buildings := match_instance.get_node("Buildings") as Node3D
	var barracks_scene := load("res://assets/converted/buildings/ATBarracks/ATBarracks.scn") as PackedScene
	var first_barracks := barracks_scene.instantiate() as Building
	var primary_barracks := barracks_scene.instantiate() as Building
	buildings.add_child(first_barracks)
	buildings.add_child(primary_barracks)
	first_barracks.global_position = Vector3(80.0, 8.0, 40.0)
	primary_barracks.global_position = Vector3(120.0, 8.0, 40.0)
	primary_barracks.global_rotation.y = PI / 2.0
	first_barracks.setup(&"ATBarracks")
	primary_barracks.setup(&"ATBarracks")
	first_barracks.set_owner_player_id(1)
	primary_barracks.set_owner_player_id(1)
	await process_frame

	_expect(
		first_barracks.rally_point_position().z > first_barracks.global_position.z,
		"a building's default rally point must be directly in front of it"
	)
	var rally_point := Vector3(120.0, 8.0, 28.0)
	primary_barracks.set_rally_point(rally_point)
	var players = get_root().get_node("Players")
	players.designate_primary_building(primary_barracks, 1, "ATBarracks")

	var roster = match_instance.get_node("UnitRosterController") as UnitRosterController
	var units := match_instance.get_node("Units") as Node3D
	var units_before := units.get_children().duplicate()
	roster.handle_unit_intent(&"ATInfantry", MOUSE_BUTTON_LEFT)
	roster.handle_unit_intent(&"ATInfantry", MOUSE_BUTTON_LEFT, 10)
	roster.handle_unit_intent(&"ATInfantry", MOUSE_BUTTON_LEFT)
	_expect(
		roster._unit_queue_size(&"ATBarracks") == 12,
		"left click must add units, while shift+left click adds ten more"
	)
	var infantry_queue: BuildingQueue = roster._production_queues.get(&"ATBarracks")
	roster.handle_unit_intent(&"ATInfantry", MOUSE_BUTTON_RIGHT)
	_expect(
		infantry_queue != null and infantry_queue.current_order().manually_paused,
		"right click must pause the active unit production order"
	)
	roster.process(2.0)
	_expect(
		units.get_children().size() == units_before.size(),
		"a paused unit order must not complete"
	)
	roster.handle_unit_intent(&"ATInfantry", MOUSE_BUTTON_RIGHT)
	_expect(
		roster._unit_queue_size(&"ATBarracks") == 11 and infantry_queue.current_order().manually_paused,
		"a second right click must remove one queued unit without resuming production"
	)
	roster.handle_unit_intent(&"ATInfantry", MOUSE_BUTTON_RIGHT, 10)
	_expect(
		roster._unit_queue_size(&"ATBarracks") == 1 and infantry_queue.current_order().manually_paused,
		"shift+right click must remove ten queued units without resuming production"
	)
	roster.handle_unit_intent(&"ATInfantry", MOUSE_BUTTON_LEFT)
	_expect(
		roster._unit_queue_size(&"ATBarracks") == 1 and not infantry_queue.current_order().manually_paused,
		"left click on a paused unit order must resume it without adding another unit"
	)
	roster.process(2.0)

	var produced: Unit
	for candidate in units.get_children():
		if not units_before.has(candidate) and candidate is Unit:
			produced = candidate as Unit
			break
	_expect(produced != null, "a completed unit order must spawn a unit")
	_expect(
		produced != null and produced.global_position.is_equal_approx(primary_barracks.production_spawn_position()),
		"a completed unit must emerge at the front edge of the designated primary production building"
	)
	var produced_forward := -produced.global_transform.basis.z if produced != null else Vector3.ZERO
	produced_forward.y = 0.0
	produced_forward = produced_forward.normalized()
	var building_forward := primary_barracks.global_transform.basis.z
	building_forward.y = 0.0
	building_forward = building_forward.normalized()
	_expect(
		produced != null and produced_forward.dot(building_forward) > 0.999,
		"a completed unit's front must face out through its production building's front"
	)
	_expect(
		produced != null and produced.target_position.is_equal_approx(rally_point),
		"a produced unit must immediately receive the primary building's rally point"
	)

	# The navigation system registers the fresh unit deferred; the rally order
	# from the spawn frame must survive that handoff instead of being reset to
	# the unit's own position.
	await process_frame
	var navigation = match_instance.get_node("UnitNavigationSystem")
	var agent: Dictionary = navigation.agent_debug(produced)
	var destination: Vector3 = agent.get("destination", Vector3.INF)
	destination.y = rally_point.y
	_expect(
		not agent.is_empty() and destination.distance_to(rally_point) < 1.5,
		"the rally order must survive the deferred navigation registration"
	)
	_expect(
		not agent.is_empty() and bool(agent["route_ready"]),
		"a produced unit must have its route toward the rally point ready"
	)

	roster.handle_unit_intent(&"ATInfantry", MOUSE_BUTTON_LEFT)
	roster.handle_unit_intent(&"ATInfantry", MOUSE_BUTTON_RIGHT)
	roster.handle_unit_intent(&"ATInfantry", MOUSE_BUTTON_RIGHT, 10)
	_expect(
		roster._unit_queue_size(&"ATBarracks") == 0,
		"shift+right click must not reduce the unit queue below zero"
	)

	match_instance.queue_free()


func _test_real_harvester_unload_trip() -> void:
	var match_instance = MatchFixtureScene.instantiate()
	for child in match_instance.get_node("Buildings").get_children():
		child.free()
	for child in match_instance.get_node("Units").get_children():
		child.free()

	var refinery := ATRefineryScene.instantiate() as Building
	refinery.position = Vector3(24.0, 8.0, 12.0)
	refinery.owner_player_id = 1
	match_instance.get_node("Buildings").add_child(refinery)
	var harvester := HarvesterScene.instantiate() as Harvester
	harvester.owner_player_id = 1
	match_instance.get_node("Units").add_child(harvester)
	get_root().add_child(match_instance)
	await physics_frame
	await physics_frame

	var navigation = match_instance.get_node("UnitNavigationSystem")
	navigation.set_physics_process(false)
	harvester.set_process(false)
	harvester.set_physics_process(false)
	navigation.call("_refresh_building_blockers")
	var front := refinery.refinery_front_position()
	harvester.global_position = front + refinery.exit_direction() * 6.0
	harvester.spice = 100.0
	harvester.stop_at_current_position()
	var player = get_root().get_node("Players").player(1)
	var money_before := int(player.money)
	_expect(
		harvester.command_unload(refinery, match_instance.terrain.navigation_grid),
		"the real harvester must accept its real owned refinery"
	)
	_expect(
		harvester.target_position.distance_to(front) > navigation.arrival_tolerance(harvester),
		"navigation must be allowed to assign a collision-safe approach point outside the exact building front"
	)

	var visited_phases := {}
	for _tick in 800:
		visited_phases[harvester.unload_phase()] = true
		navigation.call("_navigation_tick", 0.05)
		harvester.advance_unload_order(0.05)
		if not harvester.has_unload_order():
			break

	for required_phase in [
		Harvester.UnloadPhase.WAIT_DOCK,
		Harvester.UnloadPhase.PARK,
		Harvester.UnloadPhase.START,
		Harvester.UnloadPhase.HOLD,
		Harvester.UnloadPhase.END,
		Harvester.UnloadPhase.RETURN_FRONT,
	]:
		_expect(visited_phases.has(required_phase), "the real unload trip must visit phase %d" % required_phase)
	_expect(not harvester.has_unload_order(), "the real unload trip must complete instead of stalling in front of the refinery")
	_expect(is_zero_approx(harvester.spice), "the real unload trip must empty the harvester")
	_expect(player.money == money_before + 100, "the real unload trip must credit all cargo to the player")

	match_instance.queue_free()


## The model converter negates Z (left-handed source -> Godot), which puts
## every building's low skirt/apron on its +Z side, while the footprint code
## lays occupy row 0 toward -Z. import_rules.gd therefore Z-mirrors the
## occupy matrix at import (rows stored back-to-front relative to Rules.txt).
## This pins the mirror against the real converted data: a reimport that
## drops it would silently turn every footprint 180 degrees away from its
## model again.
func _test_occupy_rows_are_mirrored() -> void:
	var rules := get_root().get_node_or_null("/root/Rules")
	_expect(rules != null, "the Rules autoload must be available")
	if rules == null:
		return

	var con_yard: Resource = rules.call("building", &"ATConYard")
	_expect(con_yard != null, "ATConYard rules config must exist")
	if con_yard == null:
		return

	var occupy_rows: Array = con_yard.list(&"occupy_rows")
	_expect(occupy_rows.size() == 10, "ATConYard must keep its 10-row occupy matrix")
	if occupy_rows.size() != 10:
		return
	_expect(
		String(occupy_rows[0]) != "sssss" and String(occupy_rows[9]) == "sssss",
		"ATConYard's skirt rows must be mirrored to the matrix end (+Z, the converted model's apron side)"
	)
