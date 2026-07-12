extends SceneTree

const MatchSnapshotScript := preload("res://scripts/match/match_snapshot.gd")
const DemoMatchScene := preload("res://scenes/match/demo_match.tscn")
const TEST_SNAPSHOT_PATH := "user://match_snapshot_test.json"

var _failures := 0


func _initialize() -> void:
	var snapshot = MatchSnapshotScript.new(TEST_SNAPSHOT_PATH)
	snapshot.erase()
	var source = DemoMatchScene.instantiate()
	get_root().add_child(source)
	await physics_frame
	await physics_frame

	var source_building := source.get_node("Buildings/ATSmWindtrap") as Node3D
	var source_unit := source.get_node("Units/OrdosAPC") as Node3D
	var building_transform := Transform3D(Basis(Vector3.UP, 0.4), Vector3(84.0, 0.0, 96.0))
	var unit_transform := Transform3D(Basis(Vector3.UP, -0.7), Vector3(145.0, 0.0, 72.0))
	source_building.global_transform = building_transform
	source_unit.global_transform = unit_transform
	var save_result: Dictionary = snapshot.save(source.get_node("Buildings"), source.get_node("Units"))
	_expect(bool(save_result.get("ok", false)), "snapshot should be written")
	source.queue_free()
	await process_frame

	var restored = DemoMatchScene.instantiate()
	get_root().add_child(restored)
	await physics_frame
	await physics_frame
	var restore_result: Dictionary = snapshot.restore(restored.get_node("Buildings"), restored.get_node("Units"))
	_expect(bool(restore_result.get("ok", false)), "snapshot should be restored")
	await physics_frame

	var restored_building := restored.get_node_or_null("Buildings/ATSmWindtrap") as Node3D
	var restored_unit := restored.get_node_or_null("Units/OrdosAPC") as Node3D
	_expect(restored_building != null, "saved building should exist after restore")
	_expect(restored_unit != null, "saved unit should exist after restore")
	_expect(restored_building != null and restored_building.global_position.is_equal_approx(building_transform.origin), "building position should be restored")
	_expect(restored_unit != null and restored_unit.global_position.is_equal_approx(unit_transform.origin), "unit position should be restored")
	_expect(restored_building != null and restored_building.global_transform.basis.is_equal_approx(building_transform.basis), "building rotation should be restored")
	_expect(restored_unit != null and restored_unit.global_transform.basis.is_equal_approx(unit_transform.basis), "unit rotation should be restored")

	snapshot.erase()
	restored.queue_free()
	if _failures > 0:
		printerr("Match snapshot tests: %d failures" % _failures)
		quit(1)
		return
	print("Match snapshot tests passed")
	quit(0)


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s" % message)
