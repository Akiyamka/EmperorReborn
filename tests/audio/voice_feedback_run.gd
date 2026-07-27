extends SceneTree

const UnitVoiceCatalogScript := preload("res://scripts/audio/unit_voice_catalog.gd")
const SoundEventPlayerScript := preload("res://scripts/audio/sound_event_player.gd")

var failures := 0


func _init() -> void:
	var infantry = load("res://resources/units/definitions/ATInfantry.tres")
	_expect(infantry != null, "ATInfantry definition must load")
	_expect(
		infantry.voice_profile_path == "res://resources/audio/voices/ATInfantry.tres",
		"ATInfantry must reference its voice profile",
	)

	var profile = load(infantry.voice_profile_path)
	_expect(profile != null, "ATInfantry voice profile must load")
	_expect(
		profile.selection_event_path == "res://resources/audio/events/ATInfantrySelection.tres",
		"selection hook must reference the converted event",
	)

	var selection = load(profile.selection_event_path)
	_expect(selection != null, "selection event must load")
	_expect(selection.controls == [&"random"], "LocalDefaults control must be inherited")
	_expect(selection.sample_paths.size() == 4, "all selection samples must be preserved")
	_expect(selection.localized_samples == [true, true, true, true], "localized markers must be preserved")

	var carryall_attack = load("res://resources/audio/events/ATADVCarryallAttack.tres")
	_expect(carryall_attack.attack_count == 2, "attack sample count must be preserved")
	_expect(carryall_attack.decay_count == 2, "decay sample count must be preserved")
	var event_player = SoundEventPlayerScript.new()
	var radio_sequence: Array = event_player._playback_sequence(carryall_attack)
	_expect(radio_sequence.size() == 3, "radio feedback must queue attack, voice and decay")
	_expect(
		radio_sequence.front() in carryall_attack.sample_paths.slice(0, 2),
		"radio attack must come from the attack partition",
	)
	_expect(
		radio_sequence.back() in carryall_attack.sample_paths.slice(-2),
		"radio decay must come from the decay partition",
	)
	var selection_sequence: Array = event_player._playback_sequence(selection)
	_expect(selection_sequence.size() == 1, "ordinary random feedback must choose one line")
	event_player.free()

	var maker = load("res://resources/audio/voices/GUMaker.tres")
	_expect(maker != null, "event matching must be case-insensitive")
	_expect(not maker.attack_event_path.is_empty(), "lowercase attack hook must be linked")

	var catalog = UnitVoiceCatalogScript.new()
	var harvester = load("res://resources/units/definitions/Harvester.tres")
	var atreides_harvester = catalog.profile_for_unit(harvester, &"Atreides")
	var ordos_harvester = catalog.profile_for_unit(harvester, &"Ordos")
	_expect(atreides_harvester.profile_id == &"ATHarvester", "shared units must use owner house voice")
	_expect(ordos_harvester.profile_id == &"ORHarvester", "house choice must change shared unit voice")

	var harkonnen_group = catalog.group_profile_for_house(&"Harkonnen")
	var fremen_group = catalog.group_profile_for_house(&"Fremen")
	_expect(harkonnen_group.profile_id == &"HKGroup", "great-house groups must resolve by house")
	_expect(fremen_group.profile_id == &"FRGroup", "subhouse groups must resolve by house")
	_expect(catalog.group_profile_for_house(&"Tleilaxu") == null, "missing group hooks must resolve safely")

	var silent_stream = load("res://assets/converted/audio/sfx/silent.wav")
	_expect(silent_stream != null, "silent placeholder WAV must load")
	_expect(silent_stream.instantiate_playback() != null, "silent placeholder WAV must be playable")

	if failures == 0:
		print("voice feedback tests passed")
	quit(1 if failures else 0)


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	failures += 1
	push_error(message)
