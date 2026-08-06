extends SceneTree
## Tests for AuthoredDeathVoice: picking an infantry unit's dying scream out of
## the FX event table baked into its own model.
##
## Every fixture below is transcribed from the real XBF it names
## (assets/raw_original_content/3DDATA/Units/*.XBF, FX event type 9 plus the
## animation frame table) rather than invented, so a case failing means either
## the resolver or the bake changed, not that a made-up expectation drifted.

const AuthoredDeathVoiceScript := preload("res://scripts/units/authored_death_voice.gd")
const GeneratedVoiceManifest := preload("res://resources/audio/generated_voice_manifest.gd")
const SoundEventScript := preload("res://scripts/audio/sound_event.gd")

var _assertions := 0
var _failures := 0
var _current_case := ""


func _initialize() -> void:
	_run_case("TL_Contaminator Burnt_1: burn scream plus its own gurgle, at their authored frames", _test_contaminator_burnt)
	_run_case("TL_Contaminator Gassed_1: the contaminator-specific choking hook alone", _test_contaminator_gassed)
	_run_case("TL_Contaminator Shot_1: the weapon's own impact sound is not a voice", _test_contaminator_shot)
	_run_case("IN_FemaleCiv screams female_death_*, IN_MaleCiv does not", _test_female_civ)
	_run_case("IM_Sardaukar Blow_Up_1 is not silent", _test_sardaukar_blow_up)
	_run_case("HK_Flamer: an enclosing clip must not steal Run_Over_1's events", _test_flamer_overlapping_ranges)
	_run_case("GU_Man: a crush scream authored outside its own clip stays out of Shot_1", _test_guild_man_stray_crush)
	_run_case("per-house hooks resolve to a generated event with real samples", _test_house_hooks_resolve)
	_run_case("an unknown clip, missing meta or incomplete table yields no voice", _test_degenerate_inputs)
	if _failures > 0:
		printerr("AuthoredDeathVoice tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("AuthoredDeathVoice tests: %d assertions passed" % _assertions)
	quit(0)


func _run_case(case_name: String, test: Callable) -> void:
	_current_case = case_name
	var failures_before := _failures
	test.call()
	if _failures == failures_before:
		print("PASS: %s" % case_name)


## Stands in for a baked model root: the two metas
## converters/model_bake_builder.gd writes, on a bare Node the resolver has to
## walk down to exactly as it would in a real corpse subtree.
func _make_model(entries: Array, events: Array, complete := true) -> Node:
	var wrapper := Node3D.new()
	var model_root := Node3D.new()
	wrapper.add_child(model_root)
	model_root.set_meta("xbf_animation_entries", entries)
	model_root.set_meta("xbf_fx_events", events)
	model_root.set_meta("xbf_fx_events_complete", complete)
	return wrapper


func _entry(name: String, start_frame: int, end_frame: int) -> Dictionary:
	return {"name": name, "start_frame": start_frame, "end_frame": end_frame}


func _sound(frame: int, id: String) -> Dictionary:
	return {"frame": frame, "type": 9, "strings": [id]}


func _ids(schedule: Array[Dictionary]) -> Array:
	var result := []
	for entry in schedule:
		result.append(entry["event_id"])
	return result


## TL_Contaminator_H0.XBF. `Burnt 1` [454..507] authors three sounds:
## BurningSmall @455 and HKburningManDying @457 are the *same* eight
## burn_dying_* samples under two names, so only the first may play, and
## ContaminatorDying @485 is a different family entirely — the contaminator's
## own gurgle — so it plays too, 30 frames (1.5s at 20fps) later.
func _test_contaminator_burnt() -> void:
	var model := _make_model(_contaminator_entries(), _contaminator_events())
	var schedule := AuthoredDeathVoiceScript.schedule(model, &"Burnt_1")
	_expect(
		_ids(schedule) == [&"burningsmall", &"contaminatordying"],
		"Burnt_1 must play the burn scream then the contaminator's own, got %s" % [_ids(schedule)]
	)
	if schedule.size() == 2:
		_expect(
			is_equal_approx(float(schedule[0]["delay"]), 0.05),
			"BurningSmall is authored on frame 455 of [454..507], i.e. 0.05s in, got %s" % schedule[0]["delay"]
		)
		_expect(
			is_equal_approx(float(schedule[1]["delay"]), 1.55),
			"ContaminatorDying is authored on frame 485, i.e. 1.55s in, got %s" % schedule[1]["delay"]
		)
	model.free()


## The contaminator is the whole reason this is data-driven: its Gassed clip
## authors ContamChoking and nothing else, so it must not also pick up the
## generic choking hook or its own dying gurgle.
func _test_contaminator_gassed() -> void:
	var model := _make_model(_contaminator_entries(), _contaminator_events())
	_expect(
		_ids(AuthoredDeathVoiceScript.schedule(model, &"Gassed_1")) == [&"contamchoking"],
		"Gassed_1 must play only ContamChoking, got %s" % [
			_ids(AuthoredDeathVoiceScript.schedule(model, &"Gassed_1"))
		]
	)
	model.free()


## `Shot 1` authors GunHit1 alongside ContaminatorDying. GunHit1 belongs to the
## weapon-impact system, which fires it from its own call site — replaying it
## here would double it up.
func _test_contaminator_shot() -> void:
	var model := _make_model(_contaminator_entries(), _contaminator_events())
	_expect(
		_ids(AuthoredDeathVoiceScript.schedule(model, &"Shot_1")) == [&"contaminatordying"],
		"Shot_1 must keep only the voice, not the weapon's GunHit1, got %s" % [
			_ids(AuthoredDeathVoiceScript.schedule(model, &"Shot_1"))
		]
	)
	model.free()


## IN_FemaleCiv_H0.XBF vs IN_MaleCiv_H0.XBF: the same clip name, a different
## authored scream. This is the case a per-cause table in code cannot express
## without a per-unit branch.
func _test_female_civ() -> void:
	var female := _make_model(
		[_entry("Shot 1", 601, 636)],
		[_sound(602, "GunHit"), _sound(604, "RifleHit"), _sound(610, "FemaleCivDying")]
	)
	_expect(
		_ids(AuthoredDeathVoiceScript.schedule(female, &"Shot_1")) == [&"femalecivdying"],
		"INFemaleCiv must scream female_death_*, got %s" % [
			_ids(AuthoredDeathVoiceScript.schedule(female, &"Shot_1"))
		]
	)
	female.free()

	var male := _make_model(
		[_entry("Shot 1", 381, 422)],
		[_sound(382, "MachineGunHit1"), _sound(390, "ATNormalManDying")]
	)
	_expect(
		_ids(AuthoredDeathVoiceScript.schedule(male, &"Shot_1")) == [&"atnormalmandying"],
		"INMaleCiv must keep the ordinary Atreides dying hook, got %s" % [
			_ids(AuthoredDeathVoiceScript.schedule(male, &"Shot_1"))
		]
	)
	male.free()


## Regression for the behaviour this replaced: the old table asserted outright
## that Blow_Up carries no corpse voice. Every infantry model contradicts it —
## IM_Sardaukar_H0 authors SardaukarDying on frame 730 of `Blow Up 1`
## [717..733], after the explosion itself.
func _test_sardaukar_blow_up() -> void:
	var model := _make_model(
		[_entry("Blow Up 1", 717, 733)],
		[_sound(718, "Small"), _sound(730, "SardaukarDying")]
	)
	var schedule := AuthoredDeathVoiceScript.schedule(model, &"Blow_Up_1")
	_expect(
		_ids(schedule) == [&"sardaukardying"],
		"a blown-up Sardaukar must still cry out, got %s" % [_ids(schedule)]
	)
	if schedule.size() == 1:
		_expect(
			is_equal_approx(float(schedule[0]["delay"]), 0.65),
			"the cry is authored 13 frames into the clip, i.e. 0.65s, got %s" % schedule[0]["delay"]
		)
	model.free()


## HK_Flamer_H0.XBF authors `Run Over 1` [328..338] wholly inside `Shot 1`
## [332..356], so plain range containment would hand the crush sounds to
## Shot_1 as well. The tighter range owns the frame.
func _test_flamer_overlapping_ranges() -> void:
	var model := _make_model(
		[_entry("Run Over 1", 328, 338), _entry("Shot 1", 332, 356)],
		[
			_sound(331, "HKNormalManDying"), _sound(331, "HKExplodeFlame"),
			_sound(333, "HKCrush"), _sound(334, "Medium"),
		]
	)
	_expect(
		_ids(AuthoredDeathVoiceScript.schedule(model, &"Run_Over_1")) == [&"hknormalmandying", &"hkcrush"],
		"Run_Over_1 owns the frames inside its own tighter range, got %s" % [
			_ids(AuthoredDeathVoiceScript.schedule(model, &"Run_Over_1"))
		]
	)
	_expect(
		AuthoredDeathVoiceScript.schedule(model, &"Shot_1").is_empty(),
		"the enclosing Shot_1 must not steal its neighbour's crush sounds, got %s" % [
			_ids(AuthoredDeathVoiceScript.schedule(model, &"Shot_1"))
		]
	)
	model.free()


## GU_Man_H0.XBF authors ATCrush on frame 281, one frame *before* its own
## `Run Over 1` [282..292] begins, which leaves it inside `Shot 1` [270..307]
## where no range rule can dislodge it. A shot man must not make the sound of
## being run over.
func _test_guild_man_stray_crush() -> void:
	var model := _make_model(
		[_entry("Shot 1", 270, 307), _entry("Run Over 1", 282, 292)],
		[
			_sound(271, "MachineGunHit1"), _sound(274, "ATNormalManDying"),
			_sound(281, "ATCrush"), _sound(284, "ATNormalManDying"),
		]
	)
	_expect(
		_ids(AuthoredDeathVoiceScript.schedule(model, &"Shot_1")) == [&"atnormalmandying"],
		"Shot_1 must keep only its dying hook, got %s" % [
			_ids(AuthoredDeathVoiceScript.schedule(model, &"Shot_1"))
		]
	)
	model.free()


## Every per-house voice an infantry model can name must land on a generated
## event that has real samples — this is the regression for the ImportedSfx.txt
## shadowing bug (docs/quirks.md), which used to leave every Atreides and
## Harkonnen infantry hook unresolvable.
func _test_house_hooks_resolve() -> void:
	var authored := [
		"ATNormalManDying", "HKNormalManDying", "ORNormalManDying",
		"ATburningManDying", "HKburningManDying", "ORburningManDying",
		"ATChoking", "HKChoking", "ORChoking",
		"ATCrush", "HKCrush", "ORCrush", "Crush",
		"BurningSmall", "Choking", "ContamChoking", "ContaminatorDying",
		"FemaleCivDying", "SardaukarDying", "FremenDying",
	]
	for id in authored:
		# The crush family only ever counts on the clip it belongs to.
		var clip_name := "Run Over 1" if id.to_lower().ends_with("crush") else "Shot 1"
		var model := _make_model([_entry(clip_name, 0, 10)], [_sound(5, id)])
		var schedule := AuthoredDeathVoiceScript.schedule(
			model, StringName(clip_name.replace(" ", "_"))
		)
		_expect(schedule.size() == 1, "%s must resolve to exactly one voice" % id)
		if schedule.size() == 1:
			var path := String(GeneratedVoiceManifest.DEATH_EVENT_PATHS.get(
				schedule[0]["event_id"], ""
			))
			var event := load(path) as SoundEventScript
			_expect(
				event != null and not event.sample_paths.is_empty(),
				"%s resolved to %s, which must carry real samples" % [id, path]
			)
		model.free()


func _test_degenerate_inputs() -> void:
	var model := _make_model(_contaminator_entries(), _contaminator_events())
	_expect(
		AuthoredDeathVoiceScript.schedule(model, &"Deployed_Death_1").is_empty(),
		"a clip this model never authored must yield no voice"
	)
	_expect(
		AuthoredDeathVoiceScript.schedule(model, &"").is_empty(),
		"an empty clip name must yield no voice"
	)
	_expect(
		AuthoredDeathVoiceScript.schedule(null, &"Shot_1").is_empty(),
		"a null model must yield no voice rather than erroring"
	)
	model.free()

	var bare := Node3D.new()
	_expect(
		AuthoredDeathVoiceScript.schedule(bare, &"Shot_1").is_empty(),
		"a model with no baked FX meta at all (a test stand-in, a stripped model) must yield no voice"
	)
	bare.free()

	# A partial event table cannot tell "no sound authored" from "sound not
	# decoded", so it must yield nothing rather than a half-guess.
	var partial := _make_model(_contaminator_entries(), _contaminator_events(), false)
	_expect(
		AuthoredDeathVoiceScript.schedule(partial, &"Burnt_1").is_empty(),
		"an incomplete FX event table must yield no voice"
	)
	partial.free()


func _contaminator_entries() -> Array:
	return [
		_entry("Shot 1", 424, 453),
		_entry("Burnt 1", 454, 507),
		_entry("Gassed 1", 508, 566),
		_entry("Blow Up 1", 567, 594),
		_entry("Blow Up 2", 595, 610),
		_entry("Run Over 1", 611, 625),
	]


func _contaminator_events() -> Array:
	return [
		_sound(424, "GunHit1"), _sound(427, "ContaminatorDying"),
		_sound(455, "BurningSmall"), _sound(457, "HKburningManDying"),
		_sound(485, "ContaminatorDying"),
		_sound(515, "ContamChoking"),
		_sound(567, "RocketDetonation2"), _sound(580, "ContaminatorDying"),
		_sound(596, "RocketDetonation1"), _sound(607, "ContaminatorDying"),
		_sound(619, "HKCrush"), _sound(622, "ContaminatorDying"),
	]


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])
