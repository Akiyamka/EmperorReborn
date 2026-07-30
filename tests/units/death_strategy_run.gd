extends SceneTree

const InfantryDeathStrategyScript := preload("res://scripts/units/infantry_death_strategy.gd")
const VehicleDeathStrategyScript := preload("res://scripts/units/vehicle_death_strategy.gd")
const GeneratedVoiceManifest := preload("res://resources/audio/generated_voice_manifest.gd")

var _assertions := 0
var _failures := 0
var _current_case := ""


func _initialize() -> void:
	_run_case("infantry candidates match cause, travel", _test_infantry_candidates_travel)
	_run_case("infantry candidates prepend deployed variants", _test_infantry_candidates_deployed)
	_run_case("infantry candidates for an unmapped cause", _test_infantry_candidates_unknown_cause)
	_run_case("vehicle candidates are always Explode", _test_vehicle_candidates)
	_run_case("infantry sound id: Blow_Up has no per-house candidate", _test_infantry_sound_blow_up)
	_run_case("infantry sound id: Burn per-house stem differs from generic", _test_infantry_sound_burn)
	_run_case("infantry sound id: Gassed maps to the choking family", _test_infantry_sound_gassed)
	_run_case("infantry sound id: Shot generic fallback", _test_infantry_sound_generic_fallback)
	_run_case("infantry sound id: mapped houses use their two-letter dying hook", _test_infantry_sound_mapped_houses)
	_run_case("infantry sound id: mapped houses prepend their burn hook before the generic fallback", _test_infantry_sound_burn_candidates)
	_run_case("infantry sound id: mapped houses prepend their choking hook before the generic fallback", _test_infantry_sound_gassed_candidates)
	_run_case("infantry sound id: unmapped house falls back to the generic hook", _test_infantry_sound_unmapped_house)
	_run_case("infantry sound id: empty house_id falls back to the generic hook", _test_infantry_sound_empty_house)
	_run_case("infantry sound resolution: Atreides/Harkonnen fall through their shadowed per-house hook to a real generic sample", _test_infantry_sound_resolves_to_real_samples)
	_run_case("infantry sound id: HKFlamer adds its own boom on top of every cause", _test_infantry_sound_flamer_extra_layer)
	_run_case("vehicle sound id: personal hooks play alongside the size tier", _test_vehicle_sound_personal_hooks)
	_run_case("vehicle sound id: everyone else gets exactly one size-tier layer", _test_vehicle_sound_tiers)
	_run_case("vehicle sound ids are all really generated, with samples", _test_vehicle_sound_ids_are_generated)
	_run_case("infantry launch impulse: Blow_Up only", _test_infantry_launch_impulse)
	_run_case("vehicle launch impulse is always zero", _test_vehicle_launch_impulse)
	if _failures > 0:
		printerr("Death strategy tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("Death strategy tests: %d assertions passed" % _assertions)
	quit(0)


func _run_case(case_name: String, test: Callable) -> void:
	_current_case = case_name
	var failures_before := _failures
	test.call()
	if _failures == failures_before:
		print("PASS: %s" % case_name)


func _test_infantry_candidates_travel() -> void:
	var strategy := InfantryDeathStrategyScript.new()
	for cause_case in [
		[&"Blow_Up", [&"Blow_Up_1", &"Blow_Up_2"]],
		[&"Burn", [&"Burnt_1"]],
		[&"Gassed", [&"Gassed_1"]],
		[&"Shot", [&"Shot_1", &"Shot_2"]],
	]:
		var cause: StringName = cause_case[0]
		var expected: Array = cause_case[1]
		var candidates := strategy.death_animation_candidates(cause, false)
		_expect(
			candidates.size() == expected.size(),
			"%s (travel) must propose exactly %d candidates, got %d" % [cause, expected.size(), candidates.size()]
		)
		for name in expected:
			_expect(
				candidates.has(name),
				"%s (travel) candidates must include %s" % [cause, name]
			)


func _test_infantry_candidates_deployed() -> void:
	var strategy := InfantryDeathStrategyScript.new()
	var candidates := strategy.death_animation_candidates(&"Shot", true)
	_expect(
		candidates.size() == 4,
		"deployed Shot death must propose both deployed-death variants plus both Shot variants"
	)
	for name in [&"Deployed_Death_1", &"Deployed_Death_2"]:
		_expect(candidates.has(name), "deployed candidates must include %s" % name)
	for name in [&"Shot_1", &"Shot_2"]:
		_expect(candidates.has(name), "deployed candidates must still include the cause's own %s" % name)
	var deployed_index := mini(candidates.find(&"Deployed_Death_1"), candidates.find(&"Deployed_Death_2"))
	var shot_index := mini(candidates.find(&"Shot_1"), candidates.find(&"Shot_2"))
	_expect(
		deployed_index < shot_index,
		"deployed-death variants must be preferred (listed first) over the cause's own clips"
	)


func _test_infantry_candidates_unknown_cause() -> void:
	var strategy := InfantryDeathStrategyScript.new()
	_expect(
		strategy.death_animation_candidates(&"", false).is_empty(),
		"an unrecognized cause with no deployment must propose no candidates"
	)
	var deployed_only := strategy.death_animation_candidates(&"", true)
	_expect(
		deployed_only.size() == 2,
		"an unrecognized cause while deployed must still propose the deployed-death variants"
	)


func _test_vehicle_candidates() -> void:
	var strategy := VehicleDeathStrategyScript.new()
	for cause in [&"", &"Blow_Up", &"Shot", &"Explode"]:
		for deployed in [false, true]:
			var candidates := strategy.death_animation_candidates(cause, deployed)
			_expect(
				candidates.size() == 1 and candidates[0] == &"Explode",
				"vehicle candidates must always be exactly [Explode], got %s (cause=%s, deployed=%s)" % [candidates, cause, deployed]
			)


## An ordinary infantry unit's Blow_Up carries no corpse sound at all: the boom
## belongs to the weapon that detonated (a separate, not-yet-wired system), and
## the `explode` family it used to borrow is HarkDevastatorDie, one vehicle's
## personal hook, never a generic explosion.
func _test_infantry_sound_blow_up() -> void:
	var strategy := InfantryDeathStrategyScript.new()
	for house_id: StringName in [&"", &"Atreides", &"Harkonnen", &"Ordos"]:
		_expect(
			strategy.death_sound_event_layers(&"Blow_Up", house_id, &"ATInfantry").is_empty(),
			"Blow_Up must contribute no corpse sound layer at all (house %s)" % house_id
		)


func _test_infantry_sound_burn() -> void:
	var strategy := InfantryDeathStrategyScript.new()
	_expect(
		_cause_layer(strategy, &"Burn", &"") == [&"burningsmall"],
		"Burn with no faction must resolve to only the generic burning sound group"
	)


## Gassed must map to the choking family (Choking/atchoking/hkchoking/
## orchoking), not to normalmandying: GeneralSFX.txt states these fire
## whenever infantry are hit with poisonous gas.
func _test_infantry_sound_gassed() -> void:
	var strategy := InfantryDeathStrategyScript.new()
	_expect(
		_cause_layer(strategy, &"Gassed", &"") == [&"choking"],
		"Gassed with no faction must resolve to only the generic choking sound group"
	)


func _test_infantry_sound_generic_fallback() -> void:
	var strategy := InfantryDeathStrategyScript.new()
	for cause in [&"Shot", &""]:
		_expect(
			_cause_layer(strategy, cause, &"") == [&"normalmandying"],
			"%s with no faction must fall back to only the generic dying hook" % cause
		)


## Burn's per-house stem ("burningmandying") differs from its generic
## fallback ("burningsmall") — a single composed id could not express this,
## which is exactly why a layer is a candidate list, not one composed id.
func _test_infantry_sound_burn_candidates() -> void:
	var strategy := InfantryDeathStrategyScript.new()
	var cases := {
		&"Atreides": &"atburningmandying",
		&"Harkonnen": &"hkburningmandying",
		&"Ordos": &"orburningmandying",
	}
	for house_id: StringName in cases:
		_expect(
			_cause_layer(strategy, &"Burn", house_id) == [cases[house_id], &"burningsmall"],
			"%s Burn must propose [%s, burningsmall], got %s" % [
				house_id, cases[house_id], _cause_layer(strategy, &"Burn", house_id)
			]
		)


## Gassed's per-house stem happens to equal its generic id ("choking" either
## way), but the per-house hook must still be preferred (listed first).
func _test_infantry_sound_gassed_candidates() -> void:
	var strategy := InfantryDeathStrategyScript.new()
	var cases := {
		&"Atreides": &"atchoking",
		&"Harkonnen": &"hkchoking",
		&"Ordos": &"orchoking",
	}
	for house_id: StringName in cases:
		_expect(
			_cause_layer(strategy, &"Gassed", house_id) == [cases[house_id], &"choking"],
			"%s Gassed must propose [%s, choking], got %s" % [
				house_id, cases[house_id], _cause_layer(strategy, &"Gassed", house_id)
			]
		)


## The SFX source files only ever define at/hk/or two-letter prefixed dying
## hooks (grep-confirmed across every assets/raw_original_content/SFX/*.txt
## file: atnormalmandying, hknormalmandying, ORNORMALMANDYING and their
## burning/diced siblings) — house_id's full names ("Atreides") can never be
## used directly.
func _test_infantry_sound_mapped_houses() -> void:
	var strategy := InfantryDeathStrategyScript.new()
	var cases := {
		&"Atreides": &"atnormalmandying",
		&"Harkonnen": &"hknormalmandying",
		&"Ordos": &"ornormalmandying",
	}
	for house_id: StringName in cases:
		_expect(
			_cause_layer(strategy, &"Shot", house_id) == [cases[house_id], &"normalmandying"],
			"%s must propose [%s, normalmandying], got %s" % [
				house_id, cases[house_id], _cause_layer(strategy, &"Shot", house_id)
			]
		)


## Fremen/Guild/Imperial/Ix/Tleilaxu/Incidental have no per-house dying hook
## in the source data at all, so an unmapped house must fall back to only the
## generic hook rather than composing a prefix nothing defines.
func _test_infantry_sound_unmapped_house() -> void:
	var strategy := InfantryDeathStrategyScript.new()
	_expect(
		_cause_layer(strategy, &"Gassed", &"Fremen") == [&"choking"],
		"an unmapped house must fall back to only the generic choking hook"
	)


func _test_infantry_sound_empty_house() -> void:
	var strategy := InfantryDeathStrategyScript.new()
	_expect(
		_cause_layer(strategy, &"Shot", &"") == [&"normalmandying"],
		"an empty house_id must fall back to only the generic dying hook"
	)


## The cause layer is the first one the infantry strategy proposes; HKFlamer's
## own fuel-tank boom (if any) comes after it, and is asserted separately.
func _cause_layer(strategy, cause: StringName, faction: StringName) -> Array:
	var layers: Array = strategy.death_sound_event_layers(cause, faction, &"ATInfantry")
	return layers[0] if not layers.is_empty() else []


## HKFlamer always adds a small-tier boom on top of whatever its cause resolved
## to, because its own fuel tank ruptures no matter what killed it — including
## Blow_Up, where the cause itself contributes nothing (so the boom is alone).
func _test_infantry_sound_flamer_extra_layer() -> void:
	var strategy := InfantryDeathStrategyScript.new()
	var expected_cause_layers := {
		&"Shot": [&"hknormalmandying", &"normalmandying"],
		&"Burn": [&"hkburningmandying", &"burningsmall"],
		&"Gassed": [&"hkchoking", &"choking"],
		&"Blow_Up": [],
	}
	for cause: StringName in expected_cause_layers:
		var layers: Array = strategy.death_sound_event_layers(cause, &"Harkonnen", &"HKFlamer")
		var expected_cause: Array = expected_cause_layers[cause]
		var expected_size := (1 if expected_cause.is_empty() else 2)
		_expect(
			layers.size() == expected_size,
			"HKFlamer %s must propose %d layer(s), got %s" % [cause, expected_size, layers]
		)
		if layers.size() != expected_size:
			continue
		if not expected_cause.is_empty():
			_expect(
				layers[0] == expected_cause,
				"HKFlamer %s must keep its ordinary cause layer %s, got %s" % [cause, expected_cause, layers[0]]
			)
		_expect(
			layers[-1] == [&"small"],
			"HKFlamer %s must add its own small-tier boom as the last layer, got %s" % [cause, layers[-1]]
		)
	# Scoped to HKFlamer alone: no other infantry unit has such a hook.
	_expect(
		strategy.death_sound_event_layers(&"Shot", &"Harkonnen", &"HKTrooper").size() == 1,
		"an ordinary infantry unit must propose only its cause layer, never a self-destruct boom"
	)


## The four Harkonnen personal hooks play *alongside* the generic size tier —
## the user hears two booms on these units and one on everything else.
func _test_vehicle_sound_personal_hooks() -> void:
	var strategy := VehicleDeathStrategyScript.new()
	var cases := {
		&"HKAssault": [&"hkmedium1", &"medium"],
		&"HKInkVine": [&"hkmedium2", &"medium"],
		&"HKBuzzsaw": [&"hksmall1", &"medium"],
		&"HKDevastator": [&"explode", &"large"],
	}
	for config_id: StringName in cases:
		var layers: Array = strategy.death_sound_event_layers(&"Explode", &"Harkonnen", config_id)
		var expected: Array = cases[config_id]
		_expect(
			layers.size() == 2,
			"%s must propose two concurrent layers (personal hook + size tier), got %s" % [config_id, layers]
		)
		if layers.size() != 2:
			continue
		_expect(
			layers[0] == [expected[0]] and layers[1] == [expected[1]],
			"%s must propose [[%s], [%s]], got %s" % [config_id, expected[0], expected[1], layers]
		)


## Everyone else gets exactly one layer, the size tier — never `explode`, which
## is HKDevastator's personal hook, not a generic explosion id.
func _test_vehicle_sound_tiers() -> void:
	var strategy := VehicleDeathStrategyScript.new()
	var cases := {
		&"ATTrike": &"small",
		&"ORDustScout": &"small",
		&"ORAPC": &"medium",
		&"ATMongoose": &"medium",
	}
	for config_id: StringName in cases:
		var layers: Array = strategy.death_sound_event_layers(&"Explode", &"Atreides", config_id)
		_expect(
			layers.size() == 1 and layers[0] == [cases[config_id]],
			"%s must propose exactly one layer, [%s], got %s" % [config_id, cases[config_id], layers]
		)
	_expect(
		strategy.death_sound_event_layers(&"Explode", &"", &"ORAPC")
			== strategy.death_sound_event_layers(&"Blow_Up", &"Harkonnen", &"ORAPC"),
		"vehicle sound layers must depend on the unit alone, never on faction or cause"
	)


## Every id either strategy can propose must actually exist in the generated
## manifest — a personal hook has no fallback candidate behind it, so a
## shadowed-away id (see tools/generate_voice_feedback.py's
## SHADOW_PROOF_EVENT_IDS, docs/quirks.md) would be silent loss, not a
## graceful degrade.
func _test_vehicle_sound_ids_are_generated() -> void:
	var strategy := VehicleDeathStrategyScript.new()
	var ids: Array[StringName] = []
	for config_id: StringName in strategy.PERSONAL_DEATH_HOOKS:
		ids.append(strategy.PERSONAL_DEATH_HOOKS[config_id])
	for config_id: StringName in strategy.TIER_OVERRIDES:
		ids.append(strategy.TIER_OVERRIDES[config_id])
	ids.append(strategy.DEFAULT_TIER)
	for id: StringName in ids:
		var key := _manifest_key(id)
		_expect(
			GeneratedVoiceManifest.DEATH_EVENT_PATHS.has(key),
			"%s must be present in the generated DEATH_EVENT_PATHS manifest" % id
		)
		if not GeneratedVoiceManifest.DEATH_EVENT_PATHS.has(key):
			continue
		var event := load(String(GeneratedVoiceManifest.DEATH_EVENT_PATHS[key])) as SoundEvent
		_expect(
			event != null and not event.sample_paths.is_empty(),
			"%s must carry at least one real converted sample" % id
		)


func _test_infantry_launch_impulse() -> void:
	var strategy := InfantryDeathStrategyScript.new()
	var blow_up_impulse := strategy.death_launch_impulse(&"Blow_Up")
	_expect(blow_up_impulse.y > 0.0, "Blow_Up must add a positive-Y launch impulse")
	for cause in [&"Shot", &"Burn", &"Gassed", &""]:
		_expect(
			strategy.death_launch_impulse(cause).is_zero_approx(),
			"%s must add no launch impulse; the clip is authored in place" % cause
		)


## This is the regression that would have caught the ImportedSfx.txt
## shadowing bug (docs/quirks.md): AtreidesSFX.txt/HarkonnenSFX.txt's real
## atnormalmandying/atburningmandying/atchoking/hknormalmandying/
## hkburningmandying/hkchoking hooks are redefined by ImportedSfx.txt with
## localized sample names that were never converted. If the generator still
## emitted those ids, they would be "present" in DEATH_EVENT_PATHS with zero
## samples, so Unit._resolve_sound_event_id()'s first-present-wins scan would
## pick them and Atreides/Harkonnen infantry would die in silence. The
## generator (tools/generate_voice_feedback.py's death_events() handling in
## main()) must drop any death event whose samples are all unresolved
## entirely out of DEATH_EVENT_PATHS, so this resolution — mirroring
## Unit._resolve_sound_event_id()/_death_sound_key() exactly — falls through
## to a generic hook that actually has samples.
func _test_infantry_sound_resolves_to_real_samples() -> void:
	var strategy := InfantryDeathStrategyScript.new()
	for house_id: StringName in [&"Atreides", &"Harkonnen", &"Ordos"]:
		# Blow_Up excluded deliberately: it proposes no layer at all now, since
		# the boom belongs to the weapon, not to the corpse.
		for cause in [&"Shot", &"Burn", &"Gassed"]:
			var candidates: Array = _cause_layer(strategy, cause, house_id)
			var resolved_id := _resolve_against_manifest(candidates)
			_expect(
				resolved_id != &"",
				"%s/%s must resolve to some generated death event, candidates were %s" % [house_id, cause, candidates]
			)
			if resolved_id == &"":
				continue
			var path := String(GeneratedVoiceManifest.DEATH_EVENT_PATHS[_manifest_key(resolved_id)])
			var event := load(path) as SoundEvent
			_expect(
				event != null and not event.sample_paths.is_empty(),
				"%s/%s resolved to %s (%s), which must carry at least one real sample, got %s" % [
					house_id, cause, resolved_id, path, (event.sample_paths if event != null else "<failed to load>")
				]
			)


## Mirrors Unit._resolve_sound_event_id(): picks the first candidate id that
## is actually a key in the generated DEATH_EVENT_PATHS manifest.
func _resolve_against_manifest(candidates: Array) -> StringName:
	for candidate in candidates:
		if GeneratedVoiceManifest.DEATH_EVENT_PATHS.has(_manifest_key(candidate)):
			return candidate
	return &""


func _manifest_key(sound_event_id: StringName) -> StringName:
	return StringName(String(sound_event_id).to_lower())


func _test_vehicle_launch_impulse() -> void:
	var strategy := VehicleDeathStrategyScript.new()
	for cause in [&"", &"Explode", &"Blow_Up"]:
		_expect(
			strategy.death_launch_impulse(cause).is_zero_approx(),
			"vehicle death must never add a launch impulse (%s)" % cause
		)


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])
