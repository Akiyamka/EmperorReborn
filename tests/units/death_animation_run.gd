extends SceneTree
## Integration coverage for Unit._begin_death_sequence(): killing a real unit
## through take_damage() must still free it the same frame (today's
## contract, unchanged), while handing a corpse carrying its model subtree to
## a sibling of the unit's own parent when — and only when — the death
## strategy actually proposes a clip the model owns.

const UnitScene := preload("res://scenes/units/unit.tscn")
const OrApcModelScene := preload("res://assets/converted/models/Or_apc_H0/Or_apc_H0.scn")
const DeathCorpseScript := preload("res://scripts/effects/death_corpse.gd")
const CombatImpactEffectScript := preload("res://scripts/combat/combat_impact_effect.gd")

var _assertions := 0
var _failures := 0
var _current_case := ""


func _initialize() -> void:
	await _run_case("a shot infantry unit is freed immediately and leaves exactly one corpse", _test_infantry_death)
	await _run_case("an exploded vehicle is freed immediately and leaves an Explode corpse", _test_vehicle_death)
	await _run_case("an unmatched death cause frees the unit with no corpse at all", _test_no_matching_clip)
	await _run_case("a vehicle with no Explode clip still spawns its death explosion", _test_vehicle_death_no_clip)
	await _run_case("a unit mid-fire-sequence is freed without casting a freed overlay player", _test_death_mid_fire_sequence)
	if _failures > 0:
		printerr("Death animation tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("Death animation tests: %d assertions passed" % _assertions)
	quit(0)


func _run_case(case_name: String, test: Callable) -> void:
	_current_case = case_name
	var failures_before := _failures
	await test.call()
	if _failures == failures_before:
		print("PASS: %s" % case_name)


func _corpses_in(world: Node3D) -> Array:
	var result: Array = []
	for child in world.get_children():
		if child is DeathCorpseScript:
			result.append(child)
	return result


func _explosion_effects_in(world: Node3D) -> Array:
	var result: Array = []
	for child in world.get_children():
		if child is CombatImpactEffectScript:
			result.append(child)
	return result


func _test_infantry_death() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var unit := UnitScene.instantiate() as Unit
	world.add_child(unit)
	await process_frame

	unit.take_damage(unit.max_health + unit.max_shields + 10.0, &"Shot")

	_expect(unit.is_queued_for_deletion(), "the killing blow must free the unit in the same frame, exactly as before this feature")
	var corpses := _corpses_in(world)
	_expect(corpses.size() == 1, "exactly one corpse must be spawned, got %d" % corpses.size())
	if not corpses.is_empty():
		var corpse := corpses[0] as Node3D
		_expect(corpse.get_child_count() > 0, "the corpse must carry the detached model subtree")
		var player := corpse.find_child("AnimationPlayer", true, false) as AnimationPlayer
		_expect(
			player != null and String(player.current_animation).begins_with("Shot_"),
			"the corpse must be playing one of the Shot_ variants, got %s" % (player.current_animation if player != null else "<no player>")
		)
	# ATInfantry's UnitDefinition carries no explosion_effect_ids and no
	# explosion_type_id (infantry never had a Rules.txt ExplosionType), so no
	# CombatImpactEffect must be spawned — this must fall out naturally from
	# the empty list, not from any infantry-specific check in the spawn code.
	_expect(
		_explosion_effects_in(world).is_empty(),
		"infantry must not gain a death explosion effect it never had"
	)
	world.queue_free()
	await process_frame


func _test_vehicle_death() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var vehicle := UnitScene.instantiate() as Unit
	vehicle.config_id = &"ORAPC"
	var visual_root := vehicle.get_node("VisualRoot") as Node3D
	for child in visual_root.get_children():
		visual_root.remove_child(child)
		child.free()
	visual_root.add_child(OrApcModelScene.instantiate())
	world.add_child(vehicle)
	await process_frame

	vehicle.take_damage(vehicle.max_health + vehicle.max_shields + 10.0, &"")

	_expect(vehicle.is_queued_for_deletion(), "the killing blow must free the vehicle in the same frame")
	var corpses := _corpses_in(world)
	_expect(corpses.size() == 1, "exactly one corpse must be spawned for the vehicle, got %d" % corpses.size())
	if not corpses.is_empty():
		var corpse := corpses[0] as Node3D
		var player := corpse.find_child("AnimationPlayer", true, false) as AnimationPlayer
		_expect(
			player != null and player.current_animation == &"Explode",
			"a vehicle corpse must always play Explode regardless of damage type"
		)
	# ORAPC's UnitDefinition carries explosion_effect_ids = [&"Explosion"], so
	# the death sequence must spawn the same CombatImpactEffect a bullet
	# impact would (see CombatProjectile._spawn_explosion_visuals) — parented
	# as a sibling of the unit, since the unit itself is freed this frame.
	var explosion_effects := _explosion_effects_in(world)
	_expect(
		explosion_effects.size() == 1,
		"exactly one death explosion effect must be spawned for the vehicle, got %d" % explosion_effects.size()
	)
	if not explosion_effects.is_empty():
		var effect := explosion_effects[0] as CombatImpactEffectScript
		_expect(
			effect.effect_id == &"Explosion",
			"the vehicle's death explosion must use its rules-authored effect id, got %s" % effect.effect_id
		)
	world.queue_free()
	await process_frame


func _test_no_matching_clip() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var unit := UnitScene.instantiate() as Unit
	world.add_child(unit)
	await process_frame

	# An empty/unrecognized cause while not deployed proposes no candidates at
	# all (InfantryDeathStrategy.CANDIDATES has no "" entry), so this must
	# degrade byte-for-byte to today's behaviour: freed immediately, no corpse.
	unit.take_damage(unit.max_health + unit.max_shields + 10.0, &"")

	_expect(unit.is_queued_for_deletion(), "the unit must still be freed even with no matching death clip")
	_expect(_corpses_in(world).is_empty(), "no corpse may be spawned when no clip matches")
	world.queue_free()
	await process_frame


## A vehicle with no model at all under VisualRoot (the degenerate case
## _begin_death_sequence's `model == null` branch exists for) must still
## degrade to queue_free() with no corpse — exactly like
## _test_no_matching_clip — but, per work item 3, must NOT also lose its
## rules-authored explosion visual: the ExplosionType/ExplosionEffects data
## and the Explode clip are independent in the original data, so a unit that
## can't produce a corpse must still explode.
func _test_vehicle_death_no_clip() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var vehicle := UnitScene.instantiate() as Unit
	vehicle.config_id = &"ORAPC"
	var visual_root := vehicle.get_node("VisualRoot") as Node3D
	for child in visual_root.get_children():
		visual_root.remove_child(child)
		child.free()
	world.add_child(vehicle)
	await process_frame

	vehicle.take_damage(vehicle.max_health + vehicle.max_shields + 10.0, &"")

	_expect(vehicle.is_queued_for_deletion(), "the vehicle must still be freed even with no matching death clip")
	_expect(_corpses_in(world).is_empty(), "no corpse may be spawned when no clip matches")
	var explosion_effects := _explosion_effects_in(world)
	_expect(
		explosion_effects.size() == 1,
		"a vehicle with no Explode clip must still spawn its death explosion, got %d" % explosion_effects.size()
	)
	world.queue_free()
	await process_frame


## Regression for _prepare_model_for_corpse() freeing a weapon-fire overlay
## AnimationPlayer that _weapon_fire_sequences still references: the killing
## blow must not try to cast that freed player when _exit_tree() cancels
## in-flight fire sequences. Reproduces the real crash by injecting a fake
## fire-while-moving sequence the same way tests/combat/run.gd pokes
## _weapon_fire_sequences directly, since driving a real Mongoose to a
## mid-overlay-fire frame needs a full attack simulation this file otherwise
## has no use for.
func _test_death_mid_fire_sequence() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var unit := UnitScene.instantiate() as Unit
	world.add_child(unit)
	await process_frame

	var overlay := AnimationPlayer.new()
	unit.add_child(overlay)
	unit._weapon_fire_overlays[0] = overlay
	unit._weapon_fire_sequences[0] = {
		"turret": null,
		"target": {},
		"player": overlay,
		"animation": &"",
		"duration": 1.0,
		"elapsed": 0.0,
		"shot_times": [],
		"next_shot": 0,
		"shots_emitted": 0,
		"blocking": false,
	}

	unit.take_damage(unit.max_health + unit.max_shields + 10.0, &"Shot")

	_expect(unit.is_queued_for_deletion(), "a unit killed mid-fire-sequence must still be freed")
	_expect(not is_instance_valid(overlay), "the fire overlay handed to the corpse prep must have been freed")
	_expect(
		unit._weapon_fire_sequences.is_empty(),
		"the fire sequence referencing the freed overlay must be cleared, not left dangling"
	)
	# The actual free (and thus _exit_tree()'s _cancel_all_fire_sequences(false))
	# is deferred until here — this is the frame where the reported crash
	# ("Trying to cast a freed object", unit.gd _cancel_all_fire_sequences)
	# used to happen.
	await process_frame

	world.queue_free()
	await process_frame


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])
