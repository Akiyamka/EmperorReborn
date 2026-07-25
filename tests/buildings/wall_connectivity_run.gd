extends SceneTree

const WallConnectivityScript := preload("res://scripts/buildings/wall_connectivity.gd")

const WALL_IDS: Array[StringName] = [&"ATWall", &"HKWall", &"ORWall", &"IXWall"]
const VARIANT_NAMES := [&"End", &"Middle", &"Corner", &"TJoin", &"Cross"]

var _assertions := 0
var _failures := 0
var _current_case := ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_run_case("all 16 neighbour masks select a canonical family and rotation", _test_all_masks)
	_run_case("every House scene carries the shared topology families", _test_house_assets)
	await _run_runtime_case()

	if _failures > 0:
		printerr(
			"WallConnectivity tests: %d failures after %d assertions"
			% [_failures, _assertions]
		)
		quit(1)
		return
	print("WallConnectivity tests: %d assertions passed" % _assertions)
	quit(0)


func _run_case(case_name: String, test: Callable) -> void:
	_current_case = case_name
	var failures_before := _failures
	test.call()
	if _failures == failures_before:
		print("PASS: %s" % case_name)


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])


func _test_all_masks() -> void:
	for mask in 16:
		var selection: Dictionary = WallConnectivityScript.selection_for_mask(mask)
		var topology: StringName = selection["topology"]
		var quarters := int(selection["rotation_quarters"])
		var count := _bit_count(mask)
		var expected := WallConnectivityScript.CROSS
		match count:
			0:
				expected = WallConnectivityScript.SINGLE
			1:
				expected = WallConnectivityScript.END
			2:
				expected = WallConnectivityScript.MIDDLE \
					if mask == (
						WallConnectivityScript.NORTH | WallConnectivityScript.SOUTH
					) or mask == (
						WallConnectivityScript.EAST | WallConnectivityScript.WEST
					) else WallConnectivityScript.CORNER
			3:
				expected = WallConnectivityScript.TJOIN
		_expect(topology == expected, "mask %d must select %s, got %s" % [mask, expected, topology])
		_expect(quarters >= 0 and quarters < 4, "mask %d rotation must be a quarter turn" % mask)
		if topology in [WallConnectivityScript.SINGLE, WallConnectivityScript.CROSS]:
			_expect(quarters == 0, "rotation-invariant mask %d must use zero rotation" % mask)
			continue
		var canonical: Dictionary = {
			WallConnectivityScript.END: WallConnectivityScript.EAST,
			WallConnectivityScript.MIDDLE:
				WallConnectivityScript.EAST | WallConnectivityScript.WEST,
			WallConnectivityScript.CORNER:
				WallConnectivityScript.EAST | WallConnectivityScript.NORTH,
			WallConnectivityScript.TJOIN:
				WallConnectivityScript.NORTH
				| WallConnectivityScript.EAST
				| WallConnectivityScript.WEST
		}
		_expect(
			WallConnectivityScript.rotated_mask(int(canonical[topology]), quarters) == mask,
			"mask %d must be reproduced by the selected model rotation" % mask
		)


func _test_house_assets() -> void:
	for wall_id in WALL_IDS:
		var path := "res://assets/converted/buildings/%s/%s.scn" % [wall_id, wall_id]
		var scene := load(path) as PackedScene
		_expect(scene != null, "%s must load" % path)
		if scene == null:
			continue
		var wall := scene.instantiate() as Building
		_expect(wall != null, "%s must instantiate as Building" % wall_id)
		if wall == null:
			continue
		for variant_name in VARIANT_NAMES:
			_expect(
				wall.get_node_or_null("WallVariants/%s/Idle" % variant_name) != null,
				"%s must import the shared %s H0 family" % [wall_id, variant_name]
			)
		_expect_all_mesh_surfaces_materialized(wall, wall_id)
		wall.free()


func _expect_all_mesh_surfaces_materialized(wall: Building, wall_id: StringName) -> void:
	for value in wall.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := value as MeshInstance3D
		if mesh_instance.mesh == null:
			continue
		for surface_index in mesh_instance.mesh.get_surface_count():
			var material := mesh_instance.get_surface_override_material(surface_index)
			if material == null:
				material = mesh_instance.mesh.surface_get_material(surface_index)
			_expect(
				material != null,
				"%s surface %s[%d] must have a material"
				% [wall_id, wall.get_path_to(mesh_instance), surface_index]
			)
		var shadow_mesh: ArrayMesh = mesh_instance.mesh.shadow_mesh
		if shadow_mesh == null:
			continue
		for surface_index in shadow_mesh.get_surface_count():
			_expect(
				shadow_mesh.surface_get_material(surface_index) != null,
				"%s shadow surface %s[%d] must have a material"
				% [wall_id, wall.get_path_to(mesh_instance), surface_index]
			)


func _run_runtime_case() -> void:
	_current_case = "placement, damage, and destruction refresh joined visuals"
	var failures_before := _failures
	var root := Node3D.new()
	get_root().add_child(root)

	var center := _spawn_wall(&"ATWall", Vector2i(0, 0), root)
	var east := _spawn_wall(&"ATWall", Vector2i(2, 0), root)
	await process_frame
	_expect(center.wall_connection_mask() == WallConnectivityScript.EAST, "new east neighbour must update the center")
	_expect(center.wall_topology() == WallConnectivityScript.END, "one neighbour must show End")
	_expect(String(center.active_wall_variant_path()).ends_with("End/Idle"), "End H0 must be visible")
	_expect(
		_wall_has_visible_mesh(center),
		"the selected idle End variant must contain a mesh visible in the scene tree"
	)
	center.play_state(&"construct")
	center.play_state(&"idle")
	_expect(
		_wall_has_visible_mesh(center),
		"returning from construct to idle must leave the selected wall variant visible"
	)

	var north := _spawn_wall(&"ATWall", Vector2i(0, -2), root)
	await process_frame
	_expect(
		center.wall_connection_mask()
		== (WallConnectivityScript.NORTH | WallConnectivityScript.EAST),
		"second neighbour must update the mask"
	)
	_expect(center.wall_topology() == WallConnectivityScript.CORNER, "adjacent pair must show Corner")
	_expect(center.wall_rotation_quarters() == 0, "north-east Corner must use canonical baked orientation")

	var west := _spawn_wall(&"ATWall", Vector2i(-2, 0), root)
	var south := _spawn_wall(&"ATWall", Vector2i(0, 2), root)
	await process_frame
	_expect(center.wall_topology() == WallConnectivityScript.CROSS, "four neighbours must show Cross")
	center.health = center.max_health * 0.25
	_expect(
		String(center.active_wall_variant_path()).ends_with("Cross/Damage2"),
		"damage must retain Cross topology and select its H2 art"
	)

	east.take_damage(east.max_health)
	await process_frame
	await process_frame
	_expect(center.wall_topology() == WallConnectivityScript.TJOIN, "destroying one arm must refresh Cross to TJoin")
	_expect(
		center.wall_rotation_quarters() == 1,
		"north-south-west TJoin must turn the baked horizontal bar toward north-west"
	)
	_expect(
		center.wall_connection_mask()
		== (
			WallConnectivityScript.NORTH
			| WallConnectivityScript.SOUTH
			| WallConnectivityScript.WEST
		),
		"destroyed east arm must disappear from the neighbour mask"
	)

	var ix_center := _spawn_wall(&"IXWall", Vector2i(20, 20), root)
	_spawn_wall(&"IXWall", Vector2i(18, 20), root)
	_spawn_wall(&"IXWall", Vector2i(22, 20), root)
	await process_frame
	ix_center.health = ix_center.max_health * 0.25
	_expect(ix_center.wall_topology() == WallConnectivityScript.MIDDLE, "IX must use shared Middle topology")
	_expect(
		String(ix_center.active_wall_variant_path()).ends_with("Middle/Idle"),
		"missing IX Middle H2 must fall back to joined H0 rather than base Single"
	)

	var preplaced_center := _spawn_preplaced_wall(
		&"ORWall", Vector3(100.0, 0.0, 100.0), root, PI * 0.5
	)
	_spawn_preplaced_wall(&"ORWall", Vector3(102.0, 0.0, 100.0), root)
	await process_frame
	_expect(
		preplaced_center.wall_connection_mask() == WallConnectivityScript.EAST,
		"legacy walls without placement metadata must join by world-space pitch"
	)
	var preplaced_end := preplaced_center.get_node("WallVariants/End") as Node3D
	_expect(
		is_zero_approx(wrapf(preplaced_end.global_rotation.y, -PI, PI)),
		"pre-placed parent yaw must not rotate the selected arms away from neighbours"
	)

	root.queue_free()
	await process_frame
	if _failures == failures_before:
		print("PASS: %s" % _current_case)


func _spawn_wall(wall_id: StringName, anchor: Vector2i, parent: Node3D) -> Building:
	var path := "res://assets/converted/buildings/%s/%s.scn" % [wall_id, wall_id]
	var wall := (load(path) as PackedScene).instantiate() as Building
	wall.set_meta(&"placement_anchor_cell", anchor)
	parent.add_child(wall)
	return wall


func _wall_has_visible_mesh(wall: Building) -> bool:
	for value in wall.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := value as MeshInstance3D
		if mesh_instance.mesh != null and mesh_instance.is_visible_in_tree():
			return true
	return false


func _spawn_preplaced_wall(
		wall_id: StringName,
		position: Vector3,
		parent: Node3D,
		yaw := 0.0
	) -> Building:
	var path := "res://assets/converted/buildings/%s/%s.scn" % [wall_id, wall_id]
	var wall := (load(path) as PackedScene).instantiate() as Building
	wall.position = position
	wall.rotation.y = yaw
	parent.add_child(wall)
	return wall


func _bit_count(mask: int) -> int:
	var count := 0
	for bit in [
		WallConnectivityScript.NORTH,
		WallConnectivityScript.EAST,
		WallConnectivityScript.SOUTH,
		WallConnectivityScript.WEST,
	]:
		if mask & bit:
			count += 1
	return count
