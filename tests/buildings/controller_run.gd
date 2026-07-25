extends SceneTree

const BuildingControllerScript := preload("res://scripts/buildings/building_controller.gd")
const BuildingOrderScript := preload("res://scripts/buildings/building_order.gd")
const UpgradeEffectsScript := preload("res://scripts/buildings/upgrade_effects.gd")
const BuildingOptionStateScript := preload("res://scripts/buildings/building_option_state.gd")
const WallChainScript := preload("res://scripts/buildings/wall_chain.gd")
const ATConYardScene := preload("res://assets/converted/buildings/ATConYard/ATConYard.scn")
const PlacementBuildingScene := preload("res://assets/converted/placement/build_building.scn")
const PlacementWallScene := preload("res://assets/converted/placement/build_wall.scn")

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


class GestureController extends BuildingController:
	var placement_attempts: Array[Vector2] = []

	func _try_place_ready_building(screen_position: Vector2) -> void:
		placement_attempts.append(screen_position)


class SaleController extends BuildingController:
	var raycast_hit: Dictionary = {}

	func _raycast(
			_screen_position: Vector2, _collision_mask: int = 0xffffffff
		) -> Dictionary:
		return raycast_hit


class FakeGrid extends RefCounted:
	func is_loaded() -> bool:
		return true

	func grid_to_world(cell: Vector2i, centered: bool) -> Vector3:
		var offset := 0.5 if centered else 0.0
		return Vector3(float(cell.x) + offset, 0.0, float(cell.y) + offset)

	func cell_debug(_cell: Vector2i) -> Dictionary:
		return {"valid": true, "buildable": true}


class MutableGrid extends FakeGrid:
	var blocked_cells: Dictionary = {}

	func block_occupy_cell(anchor: Vector2i) -> void:
		for y in BuildingPlacement.NAV_CELLS_PER_OCCUPY_CELL:
			for x in BuildingPlacement.NAV_CELLS_PER_OCCUPY_CELL:
				blocked_cells[anchor + Vector2i(x, y)] = true

	func cell_debug(cell: Vector2i) -> Dictionary:
		return {"valid": true, "buildable": not blocked_cells.has(cell)}


func _initialize() -> void:
	await process_frame
	var players = root.get_node("Players")
	players.reset_for_match()
	var local_player = players.create_player(1, "Controller Tester", Color.BLUE, &"Atreides", [], 1, 100, 7)
	players.local_player_id = 1

	_run_case("asset-independent setup owns one placement child", _test_asset_independent_setup)
	_run_case("rotation release requires a later confirmation click", _test_rotation_release_requires_confirmation)
	_run_case("repeated setup forwards resources once", _test_repeated_setup_forwards_resources_once.bind(local_player))
	_run_case("freed controller leaves no resource forwarding", _test_free_disconnects_resource_forwarding.bind(local_player))
	_run_case("failed completed wall segment refunds paid credits", _test_completed_wall_refund.bind(local_player))
	_run_case("wall line preview spans selection and stops before ordering", _test_wall_line_preview_only_during_selection)
	_run_case("wall chain skips initially blocked segments", _test_wall_chain_skips_blocked_segment)
	_run_case("wall chain continues when an ordered segment becomes blocked", _test_wall_chain_continues_after_late_block)
	_run_case("world right click does not cancel a fixed wall line", _test_fixed_wall_line_ignores_world_right_click)
	_run_case("fixed wall markers remain until built or canceled", _test_fixed_wall_marker_lifecycle)
	_run_case("building sale plays the authored sell transition", _test_sale_animation.bind(local_player))
	_run_case("building sale reverses construct without an authored sell transition", _test_sale_construct_fallback.bind(local_player))
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


func _test_rotation_release_requires_confirmation(token: int) -> int:
	var controller := GestureController.new()
	root.add_child(controller)
	_setup_without_assets(controller)
	controller._building_placement.begin(&"Gesture", "Gesture", ["X"])
	controller._placement_pointer_down = true
	controller._placement_press_position = Vector2(10.0, 10.0)
	controller._placement_rotated_during_press = true
	controller._finish_placement_pointer_action(Vector2(10.0, 10.0))
	_expect(
		controller._building_placement.is_active(),
		"releasing a gesture that rotated must not consume the active placement"
	)
	_expect(controller.placement_attempts.is_empty(), "rotation release must not attempt placement")
	_expect(not controller._placement_pointer_down, "rotation release must finish the held-button gesture")

	controller._begin_placement_pointer_action(Vector2(10.0, 10.0))
	controller._finish_placement_pointer_action(Vector2(10.0, 10.0))
	_expect(
		controller.placement_attempts == [Vector2(10.0, 10.0)],
		"the next full click without rotation must attempt placement exactly once"
	)
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


func _test_completed_wall_refund(token: int, local_player: PlayerData) -> int:
	var controller := _new_controller()
	_setup_without_assets(controller)
	var order := BuildingOrderScript.new()
	order.paid_cost = 75
	var money_before := local_player.money
	controller._refund_completed_wall_segment(order)
	_expect(local_player.money == money_before + 75, "a paid wall segment that cannot be placed must be fully refunded")
	order = null
	controller.free()
	return token


func _test_wall_line_preview_only_during_selection(token: int) -> int:
	var controller := _new_controller()
	_setup_without_assets(controller)
	controller._building_placement.setup(
		null,
		FakeGrid.new(),
		null,
		null,
		PlacementBuildingScene,
		null,
		null,
		Callable()
	)
	controller._wall_line_mode = true
	controller._wall_line_start_cell = Vector2i(2, 4)
	controller._building_placement.begin(&"ATWall", "Wall", ["b"], true)
	controller._preview_wall_line_to_hover_cell(Vector2i(6, 4))
	_expect(
		controller._building_placement.get_child_count() == 3,
		"choosing the wall end must preview every segment from the start"
	)

	controller._building_placement.cancel()
	controller._wall_chain = WallChainScript.new(
		&"ATWall", "Wall", 10, 60.0, [Vector2i(6, 8)]
	)
	controller._advance_wall_chain()
	_expect(
		controller._building_queue.has_order(),
		"selecting a wall segment must start its construction order"
	)
	_expect(
		not controller._building_placement.is_active(),
		"ordering the first segment must not preview it or any following segment"
	)
	controller.free()
	return token


func _test_wall_chain_skips_blocked_segment(token: int) -> int:
	var controller := _new_controller()
	_setup_without_assets(controller)
	var grid := MutableGrid.new()
	grid.block_occupy_cell(Vector2i(2, 4))
	controller._building_placement.setup(
		null, grid, null, null, null, null, null, Callable()
	)
	controller._wall_chain = WallChainScript.new(
		&"ATWall", "Wall", 0, 1.0, [Vector2i(2, 4), Vector2i(4, 4)]
	)
	controller._advance_wall_chain()
	_expect(
		controller._building_queue.has_order(),
		"the first buildable segment after a blocked cell must still be ordered"
	)
	_expect(
		controller._wall_chain != null
		and controller._wall_chain.current_cell() == Vector2i(4, 4),
		"an initially blocked wall cell must be skipped without stopping the chain"
	)
	controller.free()
	return token


func _test_wall_chain_continues_after_late_block(token: int) -> int:
	var controller := _new_controller()
	_setup_without_assets(controller)
	var grid := MutableGrid.new()
	controller._building_placement.setup(
		null, grid, null, null, null, null, null, Callable()
	)
	controller._wall_chain = WallChainScript.new(
		&"ATWall", "Wall", 0, 1.0, [Vector2i(2, 4), Vector2i(4, 4)]
	)
	controller._advance_wall_chain()
	grid.block_occupy_cell(Vector2i(2, 4))
	controller._building_queue.tick(1.0, 0)
	_expect(
		controller._building_queue.has_order(),
		"a later segment must be ordered when the completed segment became blocked"
	)
	_expect(
		controller._wall_chain != null
		and controller._wall_chain.current_cell() == Vector2i(4, 4),
		"a wall chain must advance past a segment that became blocked while building"
	)
	controller.free()
	return token


func _test_fixed_wall_line_ignores_world_right_click(token: int) -> int:
	var controller := _new_controller()
	_setup_without_assets(controller)
	controller._building_placement.setup(
		null, FakeGrid.new(), null, null, null, null, null, Callable()
	)
	var world_right_click := InputEventMouseButton.new()
	world_right_click.button_index = MOUSE_BUTTON_RIGHT
	world_right_click.pressed = true

	controller._set_wall_line_mode(true, &"ATWall")
	_expect(
		controller.handle_unhandled_input(world_right_click)
		and not controller._wall_line_mode,
		"a world right click must cancel wall-line drawing before it is fixed"
	)

	controller._wall_chain = WallChainScript.new(
		&"ATWall", "Wall", 0, 60.0, [Vector2i(2, 4), Vector2i(4, 4)]
	)
	controller._advance_wall_chain()

	_expect(
		not controller.handle_unhandled_input(world_right_click),
		"a world right click must remain available to other gameplay controls"
	)
	_expect(
		controller._building_queue.has_order()
		and not controller._building_queue.current_order().manually_paused,
		"a world right click must not pause or cancel a fixed wall order"
	)

	controller._on_building_slot_right_pressed(&"ATWall")
	_expect(
		controller._building_queue.current_order().manually_paused,
		"right-clicking the wall icon must pause its running order"
	)
	controller._on_building_slot_right_pressed(&"ATWall")
	_expect(
		not controller._building_queue.has_order() and controller._wall_chain == null,
		"right-clicking the paused wall icon must cancel the remaining chain"
	)
	controller.free()
	return token


func _test_fixed_wall_marker_lifecycle(token: int) -> int:
	var controller := _new_controller()
	_setup_without_assets(controller)
	var buildings_root := Node3D.new()
	root.add_child(buildings_root)
	controller._building_placement.setup(
		null, FakeGrid.new(), buildings_root, null, null, null, null, Callable()
	)
	controller._wall_marker_scene = PlacementWallScene
	controller._lock_wall_markers([Vector2i(2, 4), Vector2i(4, 4)])
	_expect(
		controller._wall_markers.size() == 2,
		"fixing a wall line must retain one build_wall marker per green segment"
	)
	var marker := controller._wall_markers[Vector2i(2, 4)] as Node3D
	var marker_meshes := marker.find_children("*", "MeshInstance3D", true, false)
	var marker_uses_source_materials := not marker_meshes.is_empty()
	for node in marker_meshes:
		var mesh_instance := node as MeshInstance3D
		marker_uses_source_materials = (
			marker_uses_source_materials and mesh_instance.material_override == null
		)
		for surface_index in mesh_instance.mesh.get_surface_count():
			marker_uses_source_materials = (
				marker_uses_source_materials
				and mesh_instance.get_surface_override_material(surface_index) == null
			)
	_expect(
		marker_uses_source_materials,
		"build_wall markers must keep their ordinary authored materials"
	)

	controller._wall_chain = WallChainScript.new(
		&"ATWall", "Wall", 0, 1.0, [Vector2i(2, 4), Vector2i(4, 4)]
	)
	controller._advance_wall_chain()
	controller._building_queue.tick(1.0, 0)
	_expect(
		not controller._wall_markers.has(Vector2i(2, 4))
		and controller._wall_markers.has(Vector2i(4, 4)),
		"a completed segment must remove only its own fixed marker"
	)

	controller._cancel_building_order()
	_expect(
		controller._wall_markers.is_empty(),
		"canceling wall construction must remove all remaining fixed markers"
	)
	controller.free()
	buildings_root.free()
	return token


func _test_sale_animation(token: int, local_player: PlayerData) -> int:
	var controller := SaleController.new()
	root.add_child(controller)
	_setup_without_assets(controller)
	var building := ATConYardScene.instantiate() as Building
	building.owner_player_id = local_player.player_id
	root.add_child(building)
	var collider := Node.new()
	building.add_child(collider)
	controller.raycast_hit = {"collider": collider}
	var money_before := local_player.money

	controller._try_sell_building(Vector2.ZERO)
	var player := building.get_node_or_null("StatePlayer") as AnimationPlayer
	_expect(player != null and player.current_animation == &"sell", "sale must play the authored sell clip")
	_expect(not building.is_construction_complete(), "a selling building must stop satisfying technology prerequisites immediately")
	_expect(not building.is_queued_for_deletion(), "the building must remain until sell finishes")
	if player != null:
		player.animation_finished.emit(&"sell")
	_expect(building.is_queued_for_deletion(), "sell completion must remove the building")
	_expect(local_player.money == money_before + 1000, "sell completion must retain the half-cost refund")

	controller.free()
	building.free()
	return token


func _test_sale_construct_fallback(token: int, local_player: PlayerData) -> int:
	var controller := SaleController.new()
	root.add_child(controller)
	_setup_without_assets(controller)
	var building := Building.new()
	building.owner_player_id = local_player.player_id
	var player := AnimationPlayer.new()
	player.name = "StatePlayer"
	var library := AnimationLibrary.new()
	var construct := Animation.new()
	construct.length = 1.0
	library.add_animation(&"construct", construct)
	player.add_animation_library(&"", library)
	building.add_child(player)
	root.add_child(building)
	var collider := Node.new()
	building.add_child(collider)
	controller.raycast_hit = {"collider": collider}

	controller._try_sell_building(Vector2.ZERO)
	_expect(player.current_animation == &"construct", "sale fallback must play construct")
	_expect(is_equal_approx(player.current_animation_position, construct.length), "sale fallback must start at the end of construct")
	_expect(player.get_playing_speed() < 0.0, "sale fallback must reverse construct")
	_expect(not building.is_queued_for_deletion(), "the building must remain until reversed construct finishes")
	player.animation_finished.emit(&"construct")
	_expect(building.is_queued_for_deletion(), "reversed construct completion must remove the building")

	controller.free()
	building.free()
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
