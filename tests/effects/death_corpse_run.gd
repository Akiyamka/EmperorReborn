extends SceneTree
## Standalone tests for DeathCorpse.spawn(): a stand-in model with a fake
## AnimationPlayer stands in for the real converted model subtree Unit hands
## off, since nothing here needs the actual death-animation content, only the
## contract DeathCorpse offers around it.

const DeathCorpseScript := preload("res://scripts/effects/death_corpse.gd")

var _assertions := 0
var _failures := 0
var _current_case := ""


func _initialize() -> void:
	await _run_case("plays the resolved clip with LOOP_NONE", _test_plays_clip)
	await _run_case("freezes immediately with zero momentum", _test_freeze_zero_momentum)
	await _run_case("simulates with non-zero momentum", _test_simulate_nonzero_momentum)
	await _run_case("takes its own collision layer/mask", _test_collision_layer_mask)
	await _run_case("never joins the units group", _test_not_in_units_group)
	await _run_case("frees once the death clip finishes", _test_frees_on_animation_finished)
	await _run_case("collision shape is fit from the model's own mesh AABB, not a constant", _test_collision_shape_fits_model)
	if _failures > 0:
		printerr("DeathCorpse tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("DeathCorpse tests: %d assertions passed" % _assertions)
	quit(0)


func _run_case(case_name: String, test: Callable) -> void:
	_current_case = case_name
	var failures_before := _failures
	await test.call()
	if _failures == failures_before:
		print("PASS: %s" % case_name)


## Builds a throwaway Node3D with one AnimationPlayer that owns `clip`, the
## same shape Unit._collect_animation_players() would find inside a real
## converted model. `mesh_size`, when non-zero, adds a MeshInstance3D with a
## BoxMesh of that size so tests can assert the corpse's collider is derived
## from actual model geometry rather than a fixed constant.
func _make_model(clip: StringName, mesh_size := Vector3.ZERO) -> Dictionary:
	var model := Node3D.new()
	var player := AnimationPlayer.new()
	model.add_child(player)
	var animation := Animation.new()
	animation.length = 1.0
	animation.loop_mode = Animation.LOOP_LINEAR
	var library := AnimationLibrary.new()
	library.add_animation(clip, animation)
	player.add_animation_library(&"", library)
	if not mesh_size.is_zero_approx():
		var mesh_instance := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = mesh_size
		mesh_instance.mesh = box
		model.add_child(mesh_instance)
	return {"model": model, "player": player, "animation": animation}


func _test_plays_clip() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var fixture := _make_model(&"Shot_1")
	var corpse := DeathCorpseScript.spawn(
		world, fixture["model"], Transform3D.IDENTITY, &"Shot_1", &"", Vector3.ZERO, 1
	)
	var player: AnimationPlayer = fixture["player"]
	_expect(player.current_animation == &"Shot_1", "the resolved clip must be playing")
	_expect(
		(fixture["animation"] as Animation).loop_mode == Animation.LOOP_NONE,
		"a death clip must never loop, regardless of how it was authored"
	)
	world.queue_free()
	await process_frame


func _test_freeze_zero_momentum() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var fixture := _make_model(&"Shot_1")
	var corpse := DeathCorpseScript.spawn(
		world, fixture["model"], Transform3D.IDENTITY, &"Shot_1", &"", Vector3.ZERO, 1
	)
	_expect(corpse.freeze, "an in-place death (zero momentum) must spawn frozen, never simulated")
	world.queue_free()
	await process_frame


func _test_simulate_nonzero_momentum() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var fixture := _make_model(&"Blow_Up_1")
	var momentum := Vector3(1.0, 6.0, 0.5)
	var corpse := DeathCorpseScript.spawn(
		world, fixture["model"], Transform3D.IDENTITY, &"Blow_Up_1", &"", momentum, 1
	)
	_expect(not corpse.freeze, "a thrown corpse must simulate physics, not spawn frozen")
	_expect(
		corpse.linear_velocity.is_equal_approx(momentum),
		"linear_velocity must start at the handed-off momentum"
	)
	world.queue_free()
	await process_frame


func _test_collision_layer_mask() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var fixture := _make_model(&"Shot_1")
	var corpse := DeathCorpseScript.spawn(
		world, fixture["model"], Transform3D.IDENTITY, &"Shot_1", &"", Vector3.ZERO, 1
	)
	_expect(corpse.collision_layer == 4, "a corpse must sit on its own free bit (layer 4)")
	_expect(corpse.collision_mask == 1, "a corpse must only ever collide with terrain (mask 1)")
	world.queue_free()
	await process_frame


func _test_not_in_units_group() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var fixture := _make_model(&"Shot_1")
	var corpse := DeathCorpseScript.spawn(
		world, fixture["model"], Transform3D.IDENTITY, &"Shot_1", &"", Vector3.ZERO, 1
	)
	_expect(
		not corpse.is_in_group("units"),
		"a corpse must never join the units group: selection and match_snapshot both filter by it"
	)
	world.queue_free()
	await process_frame


func _test_frees_on_animation_finished() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var fixture := _make_model(&"Shot_1")
	var corpse := DeathCorpseScript.spawn(
		world, fixture["model"], Transform3D.IDENTITY, &"Shot_1", &"", Vector3.ZERO, 1
	)
	_expect(not corpse.is_queued_for_deletion(), "a corpse must outlive its own spawn call")
	var player: AnimationPlayer = fixture["player"]
	player.animation_finished.emit(&"Shot_1")
	_expect(
		corpse.is_queued_for_deletion(),
		"a corpse with no sound to wait for must free the instant its death clip finishes"
	)
	world.queue_free()
	await process_frame


func _test_collision_shape_fits_model() -> void:
	var world := Node3D.new()
	root.add_child(world)

	var small_fixture := _make_model(&"Shot_1", Vector3(0.6, 1.8, 0.6))
	var small_corpse := DeathCorpseScript.spawn(
		world, small_fixture["model"], Transform3D.IDENTITY, &"Shot_1", &"", Vector3.ZERO, 1
	)
	var large_fixture := _make_model(&"Explode", Vector3(3.0, 2.5, 5.0))
	var large_corpse := DeathCorpseScript.spawn(
		world, large_fixture["model"], Transform3D.IDENTITY, &"Explode", &"", Vector3.ZERO, 1
	)

	var small_shape := (small_corpse.get_node("CollisionShape3D") as CollisionShape3D).shape as BoxShape3D
	var large_shape := (large_corpse.get_node("CollisionShape3D") as CollisionShape3D).shape as BoxShape3D
	_expect(small_shape != null and large_shape != null, "both corpses must have a box collision shape")
	if small_shape != null and large_shape != null:
		_expect(
			small_shape.size.is_equal_approx(Vector3(0.6, 1.8, 0.6)),
			"an infantry-sized model must produce a matching collider, got %s" % small_shape.size
		)
		_expect(
			large_shape.size.is_equal_approx(Vector3(3.0, 2.5, 5.0)),
			"a vehicle-sized model must produce a matching collider, got %s" % large_shape.size
		)
		_expect(
			not small_shape.size.is_equal_approx(large_shape.size),
			"two differently sized models must not collapse to the same collider"
		)

	world.queue_free()
	await process_frame


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])
