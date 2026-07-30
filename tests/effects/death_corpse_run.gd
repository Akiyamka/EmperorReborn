extends SceneTree
## Standalone tests for DeathCorpse.spawn(): a stand-in model with a fake
## AnimationPlayer stands in for the real converted model subtree Unit hands
## off, since nothing here needs the actual death-animation content, only the
## contract DeathCorpse offers around it.

const DeathCorpseScript := preload("res://scripts/effects/death_corpse.gd")
const SoundEventScript := preload("res://scripts/audio/sound_event.gd")
const DeathSoundPlayerScript := preload("res://scripts/audio/death_sound_player.gd")

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
	await _run_case("death sound is tuned to be audible at this game's real camera distances, not Godot's point-blank defaults", _test_death_sound_attenuation_tuned)
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


## Regression for the reported "vehicle death plays no sound" bug: at
## Godot's stock AudioStreamPlayer3D defaults (unit_size=10, unbounded
## max_distance), the inverse-distance falloff at this game's real camera
## distances (RTSCameraConfig puts the camera 17.5-300 world units from a
## dying unit across its zoom range — see death_sound_player.gd's derivation)
## is quiet enough to read as silence, not merely "a bit quiet". This checks
## the actual node both infantry and vehicle deaths share (DeathSoundPlayer)
## carries the widened tuning, so nothing can silently regress it back to
## the point-blank stock defaults. Not gated behind DeathCorpse's manifest
## lookup: both death paths construct exactly this class, so testing the
## class directly covers both without needing a real resolvable sound id.
func _test_death_sound_attenuation_tuned() -> void:
	var player := DeathSoundPlayerScript.new()
	_expect(
		player.unit_size > 10.0,
		"unit_size must be widened well past Godot's stock 10.0, or the sound is inaudible at normal play zoom, got %s" % player.unit_size
	)
	_expect(
		player.max_distance > 300.0,
		"max_distance must reach past the camera's farthest real distance (~300 units at max_zoom) so the sound never hard-cuts mid-falloff, got %s" % player.max_distance
	)
	_expect(
		player.attenuation_model == AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE,
		"attenuation model must stay inverse-distance (a real, if gentler, distance cue), not disabled or squared, got %s" % player.attenuation_model
	)

	# playing an event must not reset the tuning back to class/script defaults.
	var world := Node3D.new()
	root.add_child(world)
	world.add_child(player)
	await process_frame
	var event := SoundEventScript.new()
	event.sample_paths = ["res://assets/converted/audio/sfx/explosion_vehicle_2.wav"]
	event.volume = 80
	player.play_event(event)
	_expect(
		player.unit_size > 10.0 and player.max_distance > 300.0,
		"play_event() must not disturb the attenuation tuning set at construction"
	)
	world.queue_free()
	await process_frame


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])
