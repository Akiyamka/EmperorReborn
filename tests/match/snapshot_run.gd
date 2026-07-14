extends SceneTree

const MatchSnapshotScript := preload("res://scripts/match/match_snapshot.gd")
const SnapshotFixtureScene := preload("res://tests/fixtures/snapshot_fixture.tscn")
const ATRefineryScene := preload("res://assets/converted/buildings/ATRefinery/ATRefinery.scn")
const TEST_SNAPSHOT_PATH := "user://match_snapshot_test.json"

var _failures := 0


func _initialize() -> void:
	await process_frame
	_configure_players()
	var snapshot = MatchSnapshotScript.new(TEST_SNAPSHOT_PATH)
	snapshot.erase()
	var source = SnapshotFixtureScene.instantiate()
	get_root().add_child(source)
	await physics_frame
	await physics_frame

	var source_building := source.get_node("Buildings/ATSmWindtrap") as Node3D
	var source_unit := source.get_node("Units/OrdosAPC") as Node3D
	var source_refinery := ATRefineryScene.instantiate() as Building
	source_refinery.name = "SnapshotRefinery"
	source_refinery.owner_player_id = 1
	source.get_node("Buildings").add_child(source_refinery)
	source_refinery.set_refinery_upgrade_state(2)
	var building_transform := Transform3D(Basis(Vector3.UP, 0.4), Vector3(84.0, 0.0, 96.0))
	var unit_transform := Transform3D(Basis(Vector3.UP, -0.7), Vector3(145.0, 0.0, 72.0))
	source_building.global_transform = building_transform
	source_unit.global_transform = unit_transform
	var save_result: Dictionary = snapshot.save(source.get_node("Buildings"), source.get_node("Units"))
	_expect(bool(save_result.get("ok", false)), "snapshot should be written")
	source.queue_free()
	await process_frame

	var restored = SnapshotFixtureScene.instantiate()
	get_root().add_child(restored)
	await physics_frame
	await physics_frame
	var restore_result: Dictionary = snapshot.restore(restored.get_node("Buildings"), restored.get_node("Units"))
	_expect(bool(restore_result.get("ok", false)), "snapshot should be restored")
	await physics_frame

	var restored_building := restored.get_node_or_null("Buildings/ATSmWindtrap") as Node3D
	var restored_refinery := restored.get_node_or_null("Buildings/SnapshotRefinery") as Building
	var restored_unit := restored.get_node_or_null("Units/OrdosAPC") as Unit
	_expect(restored_building != null, "saved building should exist after restore")
	_expect(restored_unit != null, "saved unit should exist after restore")
	_expect(
		restored_refinery != null and restored_refinery.refinery_upgrade_state == 2,
		"refinery dock state should be restored without separate dock buildings"
	)
	_expect(restored_building != null and restored_building.global_position.is_equal_approx(building_transform.origin), "building position should be restored")
	_expect(restored_unit != null and restored_unit.global_position.is_equal_approx(unit_transform.origin), "unit position should be restored")
	_expect(restored_building != null and restored_building.global_transform.basis.is_equal_approx(building_transform.basis), "building rotation should be restored")
	_expect(restored_unit != null and restored_unit.global_transform.basis.is_equal_approx(unit_transform.basis), "unit rotation should be restored")
	var shield_meshes := _shield_meshes(restored_unit)
	_expect(shield_meshes.size() == 1, "restored OrdosAPC should retain its shield mesh")
	_expect(not shield_meshes.is_empty() and shield_meshes[0].visible, "restored OrdosAPC should show its charged shield")
	_expect(
		not shield_meshes.is_empty()
			and _mesh_team_color(shield_meshes[0]).is_equal_approx(restored_unit.owner_player().team_color),
		"restored OrdosAPC visual should retain its owner's team color"
	)

	snapshot.erase()
	restored.queue_free()
	if _failures > 0:
		printerr("Match snapshot tests: %d failures" % _failures)
		quit(1)
		return
	print("Match snapshot tests passed")
	quit(0)


func _configure_players() -> void:
	var players = get_root().get_node("Players")
	players.reset_for_match()
	players.create_player(1, "Snapshot Atreides", Color(0.12, 0.44, 1.0), &"Atreides", [], 1)
	players.create_player(2, "Snapshot Ordos", Color(0.16, 0.75, 0.34), &"Ordos", [], 2)
	players.local_player_id = 1


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s" % message)


func _shield_meshes(unit: Unit) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	if unit == null:
		return result
	for node in unit.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		if String(mesh.get_parent().name).to_lower().contains("shield"):
			result.append(mesh)
	return result


func _mesh_team_color(mesh: MeshInstance3D) -> Color:
	var value: Variant = mesh.get_instance_shader_parameter("team_color")
	return value as Color if value is Color else Color.TRANSPARENT
