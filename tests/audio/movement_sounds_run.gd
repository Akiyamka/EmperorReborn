extends SceneTree

## Movement sounds: the generated SFX section table, the baked
## `<UnitId>MoveFxStart` ids, and UnitMovementSounds' step schedule/playback.

const SfxSectionCatalogScript := preload("res://scripts/audio/sfx_section_catalog.gd")
const UnitMovementSoundsScript := preload("res://scripts/units/unit_movement_sounds.gd")
const DeathSoundPlayerScript := preload("res://scripts/audio/death_sound_player.gd")

const DEFINITION_DIR := "res://resources/units/definitions"
const MONGOOSE_MODEL := "res://assets/converted/models/AT_mongoose_H0/AT_mongoose_H0.scn"
const DEVASTATOR_MODEL := "res://assets/converted/models/HK_devastator_H0/HK_devastator_H0.scn"

var failures := 0


class StubUnit:
	extends CharacterBody3D

	var visual_root: Node3D


func _initialize() -> void:
	_test_manifest()
	_test_move_start_ids()
	await _test_step_schedule()
	await _test_crossing_detection()
	await _test_limit()
	await _test_move_start_playback()

	if failures == 0:
		print("movement sound tests passed")
	quit(1 if failures else 0)


func _test_manifest() -> void:
	var thump := SfxSectionCatalogScript.section(&"ATThumpStep")
	_expect(not thump.is_empty(), "the Mongoose footstep section must resolve")
	_expect(Array(thump["paths"]).size() == 1, "ATThumpStep authors one sample")
	_expect(int(thump["volume"]) == 35, "ATThumpStep keeps its authored Volume")
	_expect(int(thump["limit"]) == 3, "ATThumpStep keeps its authored Limit")
	_expect(Array(thump["controls"]) == [&"random"], "GlobalDefaults Control must apply")

	var hollow := SfxSectionCatalogScript.section(&"athollowstep")
	_expect(int(hollow.get("volume", 0)) == 50, "lookup must be case-insensitive and keep Volume")

	var apc := SfxSectionCatalogScript.section(&"orapcmovefxstart")
	_expect(Array(apc.get("paths", [])).size() == 3, "the APC start has three variants")
	_expect(int(apc.get("limit", 0)) == 1, "the APC start authors Limit = 1")

	# Names the models author but the SFX data never defines: silent by data.
	_expect(
		not SfxSectionCatalogScript.has_section(&"HKDevastatorFootsteps"),
		"the Devastator footstep event has no section",
	)
	_expect(
		not SfxSectionCatalogScript.has_section(&"ATengineerFootsteps"),
		"infantry footstep events have no section",
	)
	_expect(
		not SfxSectionCatalogScript.has_section(&"TrackStartMove"),
		"track movement events have no section",
	)


func _test_move_start_ids() -> void:
	var apc = load("%s/ORAPC.tres" % DEFINITION_DIR)
	_expect(
		apc.move_start_sound_id == &"orapcmovefxstart",
		"ORAPC must carry its synthesised MoveFxStart section",
	)
	var infantry = load("%s/ATInfantry.tres" % DEFINITION_DIR)
	_expect(
		String(infantry.move_start_sound_id).is_empty(),
		"a unit without a MoveFxStart section must carry none",
	)

	var with_sound := 0
	for file_name in DirAccess.get_files_at(DEFINITION_DIR):
		if not file_name.ends_with(".tres"):
			continue
		var definition = load("%s/%s" % [DEFINITION_DIR, file_name])
		if definition != null and not String(definition.move_start_sound_id).is_empty():
			with_sound += 1
	_expect(with_sound == 19, "exactly 19 units resolve a MoveFxStart section, got %d" % with_sound)


func _test_step_schedule() -> void:
	var unit := await _spawn_unit(MONGOOSE_MODEL, load("%s/ATMongoose.tres" % DEFINITION_DIR))
	var sounds = unit.get_meta("movement_sounds")

	var move: Array = sounds.step_schedule_for(&"Move")
	_expect(move.size() == 2, "the Mongoose authors two steps per Move cycle, got %d" % move.size())
	if move.size() == 2:
		# Absolute frames 9 and 21 of a Move clip starting at frame 3, at 20 Hz.
		_expect(is_equal_approx(float(move[0]["time"]), 0.3), "first step lands at 0.30s")
		_expect(is_equal_approx(float(move[1]["time"]), 0.9), "second step lands at 0.90s")
		_expect(move[0]["section"] == &"ATThumpStep", "steps must name the authored section")

	_expect(
		not sounds.step_schedule_for(&"Turn_Left").is_empty(),
		"the turn clips author a step too",
	)
	# Fire and death clips carry sound events of the same type; scoping to the
	# movement clips is what keeps them out without a name blacklist.
	_expect(sounds.step_schedule_for(&"Fire_0").is_empty(), "fire clips must not schedule steps")
	_expect(sounds.step_schedule_for(&"Explode").is_empty(), "death clips must not schedule steps")
	_free_unit(unit)

	var devastator := await _spawn_unit(DEVASTATOR_MODEL, load("%s/HKDevastator.tres" % DEFINITION_DIR))
	var devastator_sounds = devastator.get_meta("movement_sounds")
	var devastator_move: Array = devastator_sounds.step_schedule_for(&"Move")
	_expect(not devastator_move.is_empty(), "the Devastator authors steps in its Move clip")
	var all_fallback := true
	for entry in devastator_move:
		all_fallback = all_fallback and entry["section"] == &"hkdevastatormovefxstart"
	_expect(all_fallback, "unresolved mech steps must fall back to the unit's move-start section")
	_free_unit(devastator)


func _test_crossing_detection() -> void:
	var unit := await _spawn_unit(MONGOOSE_MODEL, load("%s/ATMongoose.tres" % DEFINITION_DIR))
	var sounds = unit.get_meta("movement_sounds")
	var player: AnimationPlayer = unit.get_meta("animation_player")
	var length := player.get_animation(&"Move").length
	player.get_animation(&"Move").loop_mode = Animation.LOOP_LINEAR
	player.play(&"Move")
	player.seek(0.0, true)

	# One full cycle in small steps: both authored steps, once each.
	var plain := _run_cycle(sounds, unit, player, length, 24)
	_expect(plain == 2, "a Move cycle must play both authored steps, got %d" % plain)
	# Same clip at 2.5x: the crossing test reads real playback positions, so
	# the count is unchanged even though each frame covers more of the clip.
	player.speed_scale = 2.5
	var fast := _run_cycle(sounds, unit, player, length, 24)
	_expect(fast == 2, "a faster gait must not add or drop steps, got %d" % fast)
	player.speed_scale = 1.0

	# A single frame that straddles the loop point must play the step before
	# the wrap and the one after it, not twice and not none.
	player.seek(length - 0.05, true)
	sounds.advance(0.0)
	_drain(unit)
	player.advance(0.4)
	sounds.advance(0.4)
	_expect(_drain(unit) == 1, "a frame straddling the loop must not double-count")
	_free_unit(unit)


func _test_limit() -> void:
	SfxSectionCatalogScript.reset_active_counts()
	var parent := Node3D.new()
	root.add_child(parent)
	# Nodes added from a SceneTree script are only really in the tree once a
	# frame has been processed, and play_pool() refuses a parent that is not.
	await process_frame
	var played: Array = []
	for index in 4:
		played.append(
			SfxSectionCatalogScript.play_at(parent, Vector3.ZERO, &"ATThumpStep")
		)
	_expect(played[0] != null and played[2] != null, "Limit = 3 must allow three instances")
	_expect(played[3] == null, "a fourth instance must be refused while three play")
	for player in played:
		if player != null:
			player.free()
	_expect(
		SfxSectionCatalogScript.play_at(parent, Vector3.ZERO, &"ATThumpStep") != null,
		"freeing the players must release their Limit slots",
	)
	parent.free()
	SfxSectionCatalogScript.reset_active_counts()


func _test_move_start_playback() -> void:
	SfxSectionCatalogScript.reset_active_counts()
	var unit := await _spawn_unit("", load("%s/ORAPC.tres" % DEFINITION_DIR))
	var sounds = unit.get_meta("movement_sounds")
	sounds.notify_movement_state(true)
	_expect(_drain(unit) == 1, "a vehicle must sound its engine when it starts moving")
	sounds.notify_movement_state(true)
	_expect(_drain(unit) == 0, "staying in motion must not repeat the engine start")
	sounds.notify_movement_state(false)
	sounds.notify_movement_state(true)
	_expect(_drain(unit) == 1, "stopping and starting again must sound it once more")
	_free_unit(unit)

	var devastator := await _spawn_unit("", load("%s/HKDevastator.tres" % DEFINITION_DIR))
	var devastator_sounds = devastator.get_meta("movement_sounds")
	devastator_sounds.notify_movement_state(true)
	_expect(
		_drain(devastator) == 0,
		"a mech's move-start section belongs to its steps, not to its departure",
	)
	_free_unit(devastator)
	SfxSectionCatalogScript.reset_active_counts()


## Builds a stub unit under a container node, with `model_path` (when given)
## instantiated as its visual root, and a configured UnitMovementSounds bound
## through metadata so the caller can drive it.
func _spawn_unit(model_path: String, definition: Resource) -> Node3D:
	var container := Node3D.new()
	root.add_child(container)
	var unit := StubUnit.new()
	container.add_child(unit)
	var sounds = UnitMovementSoundsScript.new()
	sounds.configure(unit)
	sounds.adopt_definition(definition)
	if not model_path.is_empty():
		var visual_root := Node3D.new()
		unit.add_child(visual_root)
		unit.visual_root = visual_root
		visual_root.add_child((load(model_path) as PackedScene).instantiate())
		var players: Array[AnimationPlayer] = []
		var player := _find_animation_player(visual_root)
		if player != null:
			players.append(player)
			unit.set_meta("animation_player", player)
		sounds.attach_model(players)
		sounds.refresh_step_schedule()
	unit.set_meta("movement_sounds", sounds)
	await process_frame
	return unit


func _free_unit(unit: Node3D) -> void:
	unit.get_parent().free()
	SfxSectionCatalogScript.reset_active_counts()


## Advances `player` and the module across exactly one clip cycle, in `steps`
## equal slices of real time, returning how many sounds were played. The slice
## is scaled by the player's speed so the covered clip time stays one cycle
## whatever the gait cadence is.
func _run_cycle(sounds, unit: Node3D, player: AnimationPlayer, length: float, steps: int) -> int:
	player.seek(0.0, true)
	sounds.advance(0.0)
	_drain(unit)
	var delta := length / (float(steps) * maxf(player.speed_scale, 0.001))
	var played := 0
	for index in steps:
		player.advance(delta)
		sounds.advance(delta)
		played += _drain(unit)
	return played


## Counts and removes the one-shot players spawned beside `unit`, so the next
## assertion starts from a clean slate and the Limit slots are released.
func _drain(unit: Node3D) -> int:
	var parent := unit.get_parent()
	var count := 0
	for child in parent.get_children():
		if child.get_script() == DeathSoundPlayerScript:
			count += 1
			child.free()
	return count


func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node as AnimationPlayer
	for child in node.get_children():
		var found := _find_animation_player(child)
		if found != null:
			return found
	return null


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	failures += 1
	push_error(message)
