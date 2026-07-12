extends SceneTree

const UnitCommandControllerScript := preload("res://scripts/match/unit_command_controller.gd")

var _assertions := 0
var _failures := 0
var _current_case := ""
var _completion_token := 1000


class FakeUnit extends Node3D:
	var player = null
	var selected := false
	var move_targets: Array[Vector3] = []

	func set_selected(active: bool) -> void:
		selected = active

	func move_to(target: Vector3) -> void:
		move_targets.append(target)

	func is_owned_by(player_id: int) -> bool:
		return player != null and player.player_id == player_id

	func owner_player():
		return player


class FakeBuilding extends Node3D:
	var player = null
	var selected := false

	func set_selected(active: bool) -> void:
		selected = active

	func is_owned_by(player_id: int) -> bool:
		return player != null and player.player_id == player_id

	func owner_player():
		return player


class FakeUnitCommandController extends UnitCommandController:
	var raycast_hits: Array[Dictionary] = []
	var raycast_masks: Array[int] = []
	var screen_positions: Dictionary = {}

	func _raycast(_screen_position: Vector2, collision_mask: int = 0xffffffff) -> Dictionary:
		raycast_masks.append(collision_mask)
		return raycast_hits.pop_front() if not raycast_hits.is_empty() else {}

	func _screen_position_for_entity(entity):
		return screen_positions.get(entity, null)


func _initialize() -> void:
	await process_frame
	var players = root.get_node("Players")
	players.reset_for_match()
	var local_player = players.create_player(1, "Atreides Commander", Color.BLUE, &"Atreides", [&"Fremen"])
	var enemy_player = players.create_player(2, "Ordos Rival", Color.GREEN, &"Ordos")
	players.local_player_id = 1
	players.set_relation(1, 2, PlayerData.Relation.ENEMY)

	_run_case("selection ownership and movement", _test_selection_ownership_and_movement.bind(local_player, enemy_player))
	_run_case("rectangle unit selection", _test_rectangle_unit_selection.bind(local_player, enemy_player))
	_run_case("building selection", _test_building_selection.bind(local_player))
	players.reset_for_match()
	if _failures > 0:
		printerr("UnitCommandController tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("UnitCommandController tests: %d assertions passed" % _assertions)
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


func _test_selection_ownership_and_movement(token: int, local_player, enemy_player) -> int:
	var commands := FakeUnitCommandController.new()
	var statuses: Array[String] = []
	commands.status_changed.connect(func(status: String) -> void: statuses.append(status))
	root.add_child(commands)

	var local_unit := _make_unit("Scout", local_player)
	var enemy_unit := _make_unit("Raider", enemy_player)
	root.add_child(local_unit)
	root.add_child(enemy_unit)
	var local_collider := Node.new()
	local_unit.add_child(local_collider)
	var enemy_collider := Node.new()
	enemy_unit.add_child(enemy_collider)

	commands.raycast_hits.append({"collider": local_collider})
	_expect(commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_LEFT)), "left click must be handled")
	_expect(local_unit.selected, "ancestor group unit must be selected")
	_expect(commands.selection_text() == "Scout selected | owner: Atreides Commander (Atreides/Fremen, ally)", "selected owner text must match legacy format")
	_expect(statuses.back().is_empty() and commands.raycast_masks == [0xffffffff], "selection uses the all-layers raycast")

	commands.raycast_hits.append({"collider": enemy_collider})
	commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_LEFT))
	_expect(not local_unit.selected and not enemy_unit.selected, "enemy units must not become selected")
	_expect(commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_RIGHT)), "enemy move click must still be handled")
	_expect(enemy_unit.move_targets.is_empty() and commands.selection_text() == "No entity selected", "enemy click leaves no commandable selection")
	_expect(commands.raycast_masks == [0xffffffff, 0xffffffff], "enemy move must not issue a terrain raycast")

	commands.raycast_hits.append({"collider": local_collider})
	commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_LEFT))
	commands.raycast_hits.append({"position": Vector3(3.0, 7.0, 4.0)})
	commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_RIGHT))
	_expect(enemy_unit.selected == false and local_unit.move_targets == [Vector3(3.0, 7.0, 4.0)], "owned unit moves to terrain hit")
	_expect(commands.raycast_masks.back() == 1, "movement uses terrain mask one")
	_expect(statuses.back() == "Moving to 3.0, 4.0", "movement status keeps legacy text without nav grid")

	commands.raycast_hits.append({})
	commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_LEFT))
	_expect(commands.selection_text() == "No entity selected", "selection miss clears selection")
	_expect(commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_RIGHT)), "right click with no selection is handled")

	commands.queue_free()
	local_unit.queue_free()
	enemy_unit.queue_free()
	return token


func _test_building_selection(token: int, local_player) -> int:
	var commands := FakeUnitCommandController.new()
	root.add_child(commands)

	var building := FakeBuilding.new()
	building.name = "Construction Yard"
	building.player = local_player
	building.add_to_group("buildings")
	root.add_child(building)
	var collider := Node.new()
	building.add_child(collider)

	commands.raycast_hits.append({"collider": collider})
	_expect(commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_LEFT)), "building click must be handled")
	_expect(building.selected, "owned building must use the shared selection flow")
	_expect(commands.selection_text() == "Construction Yard selected | owner: Atreides Commander (Atreides/Fremen, ally)", "building selection must include ownership")

	commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_RIGHT))
	_expect(building.selected, "right click must not clear a stationary building selection")
	_expect(commands.raycast_masks == [0xffffffff], "stationary building must not request a terrain move raycast")

	commands.queue_free()
	building.queue_free()
	return token


func _test_rectangle_unit_selection(token: int, local_player, enemy_player) -> int:
	var commands := FakeUnitCommandController.new()
	root.add_child(commands)
	var scout := _make_unit("Scout", local_player)
	var tank := _make_unit("Tank", local_player)
	var enemy := _make_unit("Raider", enemy_player)
	root.add_child(scout)
	root.add_child(tank)
	root.add_child(enemy)
	commands.screen_positions = {
		scout: Vector2(20.0, 20.0),
		tank: Vector2(70.0, 60.0),
		enemy: Vector2(50.0, 50.0),
	}

	_expect(commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_LEFT, true, Vector2(10.0, 10.0))), "drag start must be handled")
	_expect(commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_LEFT, false, Vector2(100.0, 100.0))), "drag release must be handled")
	_expect(scout.selected and tank.selected and not enemy.selected, "rectangle selects only owned units inside it")
	_expect(commands.selection_text() == "2 units selected", "rectangle selection must describe the group")

	commands.raycast_hits.append({"position": Vector3(4.0, 5.0, 6.0)})
	commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_RIGHT))
	_expect(scout.move_targets == [Vector3(4.0, 5.0, 6.0)] and tank.move_targets == [Vector3(4.0, 5.0, 6.0)], "right click commands every selected unit")

	commands.queue_free()
	scout.queue_free()
	tank.queue_free()
	enemy.queue_free()
	return token


func _make_unit(unit_name: String, player) -> FakeUnit:
	var unit := FakeUnit.new()
	unit.name = unit_name
	unit.player = player
	unit.add_to_group("units")
	return unit


func _mouse_event(button_index: int, pressed := true, position := Vector2(10.0, 10.0)) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = button_index
	event.pressed = pressed
	event.position = position
	return event


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])
