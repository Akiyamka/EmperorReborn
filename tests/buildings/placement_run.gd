extends SceneTree

const BuildingPlacementScript := preload("res://scripts/buildings/building_placement.gd")

var _assertions := 0
var _failures := 0
var _current_case := ""
var _completion_token := 2000


class FakeGrid extends RefCounted:
	func is_loaded() -> bool:
		return true

	func grid_to_world(cell: Vector2i, _center: bool) -> Vector3:
		return Vector3(cell.x, 0.0, cell.y)

	func world_to_grid(position: Vector3) -> Vector2i:
		return Vector2i(floori(position.x), floori(position.z))

	func cell_debug(_cell: Vector2i) -> Dictionary:
		return {"valid": true, "buildable": true}


class FootprintConfig extends Resource:
	var rows: Array[String]

	func _init(new_rows: Array[String]) -> void:
		rows = new_rows

	func list(field_name: StringName) -> Array[String]:
		return rows if field_name == &"occupy_rows" else []


class ExistingBuilding extends Node3D:
	var building_config: Resource
	var config_id: StringName


func _initialize() -> void:
	_run_case("begin validation and cancel", _test_begin_and_cancel)
	_run_case("failed placement keeps active state", _test_failed_placement_keeps_active)
	_run_case("footprint occupancy and single spawn handoff", _test_occupancy_and_single_spawn)
	_run_case("resolver fallback occupancy", _test_resolver_fallback_occupancy)
	_run_case("out-of-radius cells preview as blocked", _test_out_of_radius_preview_is_blocked)

	if _failures > 0:
		printerr("BuildingPlacement tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("BuildingPlacement tests: %d assertions passed" % _assertions)
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


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])


func _new_placement(existing_building_occupy_rows: Callable = Callable()) -> Array:
	var buildings_root := Node3D.new()
	get_root().add_child(buildings_root)
	var placement = BuildingPlacementScript.new()
	get_root().add_child(placement)
	placement.setup(null, FakeGrid.new(), buildings_root, null, null, null, null, existing_building_occupy_rows)
	return [placement, buildings_root]


func _free_pair(pair: Array) -> void:
	pair[0].queue_free()
	pair[1].queue_free()


func _rows(values: Array) -> Array[String]:
	var rows: Array[String] = []
	for value in values:
		rows.append(String(value))
	return rows


func _direct_config_rows(building: Node3D) -> Array[String]:
	var config = building.get("building_config") as Resource
	if config == null:
		return []
	return config.list(&"occupy_rows")


func _fallback_config_id_rows(building: Node3D) -> Array[String]:
	if building.config_id == &"Fallback":
		return _rows(["X"])
	return _direct_config_rows(building)


func _test_begin_and_cancel(token: int) -> int:
	var pair := _new_placement()
	var placement = pair[0]
	_expect(not placement.begin(&"", "Invalid", _rows(["X"])), "an empty building id must be rejected")
	_expect(not placement.begin(&"Invalid", "Invalid", _rows([".."])), "a footprint without occupied cells must be rejected")
	_expect(not placement.is_active(), "rejected footprints must leave placement inactive")
	_expect(placement.begin(&"Valid", "Valid", _rows(["X"])), "an occupied footprint must begin placement")
	_expect(placement.is_active(), "a valid begin must activate placement")
	_expect(placement.cancel() == "Valid", "cancel must return the active display name")
	_expect(not placement.is_active(), "cancel must clear active placement state")
	_free_pair(pair)
	return token


func _test_failed_placement_keeps_active(token: int) -> int:
	var pair := _new_placement()
	var placement = pair[0]
	placement.begin(&"Failure", "Failure", _rows(["X"]))
	var result = placement.try_place_at_hover_cell(Vector2i(2, 4), null)
	_expect(result == BuildingPlacementScript.PlaceResult.INVALID_SCENE, "a missing scene must fail explicitly")
	_expect(placement.is_active(), "a failed scene must preserve active placement")
	placement.cancel()
	_free_pair(pair)
	return token


func _test_occupancy_and_single_spawn(token: int) -> int:
	var pair := _new_placement(Callable(self, "_direct_config_rows"))
	var placement = pair[0]
	var buildings_root = pair[1]
	var existing = ExistingBuilding.new()
	existing.building_config = FootprintConfig.new(_rows(["X"]))
	existing.set_meta(&"placement_anchor_cell", Vector2i(2, 4))
	existing.add_to_group("buildings")
	buildings_root.add_child(existing)

	placement.begin(&"Blocked", "Blocked", _rows(["X"]))
	var blocked = placement.try_place_at_hover_cell(Vector2i(2, 4), null)
	_expect(blocked == BuildingPlacementScript.PlaceResult.CANNOT_BUILD, "occupied footprint cells must reject placement")
	_expect(placement.is_active(), "an occupied footprint must keep placement active")
	placement.cancel()
	buildings_root.remove_child(existing)
	existing.free()

	placement.begin(&"Spawn", "Spawn", _rows(["XX", "XX"]))
	var template := Node3D.new()
	var scene := PackedScene.new()
	_expect(scene.pack(template) == OK, "an in-memory scene must pack")
	template.free()
	var placed = placement.try_place_at_hover_cell(Vector2i(5, 7), scene, 4)
	_expect(placed == BuildingPlacementScript.PlaceResult.PLACED, "a valid footprint and injected scene must spawn")
	_expect(not placement.is_active(), "a successful placement must consume active placement once")
	_expect(buildings_root.get_child_count() == 1, "spawn must add exactly one building to the injected root")
	var spawned := buildings_root.get_child(0) as Node3D
	_expect(spawned.get_meta(&"placement_anchor_cell") == Vector2i(2, 4), "footprint orientation must center its anchor")
	_expect(spawned.position == Vector3(4.0, 0.0, 6.0), "spawn position must use the footprint center")
	_expect(
		placement.try_place_at_hover_cell(Vector2i(5, 7), scene, 4) == BuildingPlacementScript.PlaceResult.INACTIVE,
		"a successful placement handoff must not spawn twice"
	)
	_free_pair(pair)
	return token


## Regression test: the per-cell preview material must reflect the build
## radius check, not just the aggregate _can_build flag used by
## try_place_at_hover_cell() -- otherwise the grid stays green while
## placement is silently blocked by radius.
func _test_out_of_radius_preview_is_blocked(token: int) -> int:
	var buildings_root := Node3D.new()
	get_root().add_child(buildings_root)

	var available_template := Node3D.new()
	available_template.set_meta(&"kind", "available")
	var available_scene := PackedScene.new()
	_expect(available_scene.pack(available_template) == OK, "available preview template must pack")
	available_template.free()

	var blocked_template := Node3D.new()
	blocked_template.set_meta(&"kind", "blocked")
	var blocked_scene := PackedScene.new()
	_expect(blocked_scene.pack(blocked_template) == OK, "blocked preview template must pack")
	blocked_template.free()

	var placement = BuildingPlacementScript.new()
	get_root().add_child(placement)
	placement.setup(
		null, FakeGrid.new(), buildings_root, null,
		available_scene, blocked_scene, null,
		Callable(), Callable(), Callable(self, "_always_out_of_radius")
	)

	placement.begin(&"Valid", "Valid", _rows(["X"]))
	var result = placement.try_place_at_hover_cell(Vector2i(2, 4), null)
	_expect(result == BuildingPlacementScript.PlaceResult.CANNOT_BUILD, "an out-of-radius footprint must reject placement")

	var blocked_cells := 0
	var available_cells := 0
	for child in placement.get_children():
		if not child.has_meta(&"kind"):
			continue
		if String(child.get_meta(&"kind")) == "blocked":
			blocked_cells += 1
		else:
			available_cells += 1
	_expect(blocked_cells == 1, "an out-of-radius cell must render with the blocked preview")
	_expect(available_cells == 0, "an out-of-radius cell must not render with the available preview")

	placement.cancel()
	placement.queue_free()
	buildings_root.queue_free()
	return token


func _always_out_of_radius() -> int:
	return 5


func _test_resolver_fallback_occupancy(token: int) -> int:
	var pair := _new_placement(Callable(self, "_fallback_config_id_rows"))
	var placement = pair[0]
	var buildings_root = pair[1]
	var existing = ExistingBuilding.new()
	existing.config_id = &"Fallback"
	existing.set_meta(&"placement_anchor_cell", Vector2i(2, 4))
	existing.add_to_group("buildings")
	buildings_root.add_child(existing)
	placement.begin(&"FallbackBlocked", "FallbackBlocked", _rows(["X"]))
	var result = placement.try_place_at_hover_cell(Vector2i(2, 4), null)
	_expect(result == BuildingPlacementScript.PlaceResult.CANNOT_BUILD, "resolver footprint must block an existing config-id building")
	_expect(placement.is_active(), "resolver occupancy rejection must preserve active placement")
	placement.cancel()
	_free_pair(pair)
	return token
