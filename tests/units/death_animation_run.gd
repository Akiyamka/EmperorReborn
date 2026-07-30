extends SceneTree
## Integration coverage for Unit._begin_death_sequence(): killing a real unit
## through take_damage() must still free it the same frame (today's
## contract, unchanged), while handing a corpse carrying its model subtree to
## a sibling of the unit's own parent when — and only when — the death
## strategy actually proposes a clip the model owns.

const UnitScene := preload("res://scenes/units/unit.tscn")
const OrApcModelScene := preload("res://assets/converted/models/Or_apc_H0/Or_apc_H0.scn")
const DeathCorpseScript := preload("res://scripts/effects/death_corpse.gd")

var _assertions := 0
var _failures := 0
var _current_case := ""


func _initialize() -> void:
	await _run_case("a shot infantry unit is freed immediately and leaves exactly one corpse", _test_infantry_death)
	await _run_case("an exploded vehicle is freed immediately and leaves an Explode corpse", _test_vehicle_death)
	await _run_case("an unmatched death cause frees the unit with no corpse at all", _test_no_matching_clip)
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


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])
