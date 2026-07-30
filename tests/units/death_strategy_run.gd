extends SceneTree

const InfantryDeathStrategyScript := preload("res://scripts/units/infantry_death_strategy.gd")
const VehicleDeathStrategyScript := preload("res://scripts/units/vehicle_death_strategy.gd")

var _assertions := 0
var _failures := 0
var _current_case := ""


func _initialize() -> void:
	_run_case("infantry candidates match cause, travel", _test_infantry_candidates_travel)
	_run_case("infantry candidates prepend deployed variants", _test_infantry_candidates_deployed)
	_run_case("infantry candidates for an unmapped cause", _test_infantry_candidates_unknown_cause)
	_run_case("vehicle candidates are always Explode", _test_vehicle_candidates)
	_run_case("infantry sound id: Blow_Up", _test_infantry_sound_blow_up)
	_run_case("infantry sound id: Burn", _test_infantry_sound_burn)
	_run_case("infantry sound id: Shot/Gassed generic fallback", _test_infantry_sound_generic_fallback)
	_run_case("infantry sound id: mapped houses use their two-letter dying hook", _test_infantry_sound_mapped_houses)
	_run_case("infantry sound id: unmapped house falls back to the generic hook", _test_infantry_sound_unmapped_house)
	_run_case("infantry sound id: empty house_id falls back to the generic hook", _test_infantry_sound_empty_house)
	_run_case("vehicle sound id is always explode", _test_vehicle_sound)
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


func _test_infantry_sound_blow_up() -> void:
	var strategy := InfantryDeathStrategyScript.new()
	_expect(
		strategy.death_sound_event_id(&"Blow_Up", &"") == &"explode",
		"Blow_Up must resolve to the explosion sound group regardless of faction"
	)
	_expect(
		strategy.death_sound_event_id(&"Blow_Up", &"Atreides") == &"explode",
		"Blow_Up sound must not vary by faction"
	)


func _test_infantry_sound_burn() -> void:
	var strategy := InfantryDeathStrategyScript.new()
	_expect(
		strategy.death_sound_event_id(&"Burn", &"") == &"burningsmall",
		"Burn must resolve to the burning sound group"
	)


func _test_infantry_sound_generic_fallback() -> void:
	var strategy := InfantryDeathStrategyScript.new()
	for cause in [&"Shot", &"Gassed", &""]:
		_expect(
			strategy.death_sound_event_id(cause, &"") == &"normalmandying",
			"%s with no faction must fall back to the generic dying hook" % cause
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
			strategy.death_sound_event_id(&"Shot", house_id) == cases[house_id],
			"%s must compose %s, got %s" % [
				house_id, cases[house_id], strategy.death_sound_event_id(&"Shot", house_id)
			]
		)


## Fremen/Guild/Imperial/Ix/Tleilaxu/Incidental have no per-house dying hook
## in the source data at all, so an unmapped house must fall back to the
## generic hook rather than composing a prefix nothing defines.
func _test_infantry_sound_unmapped_house() -> void:
	var strategy := InfantryDeathStrategyScript.new()
	_expect(
		strategy.death_sound_event_id(&"Gassed", &"Fremen") == &"normalmandying",
		"an unmapped house must fall back to the generic dying hook"
	)


func _test_infantry_sound_empty_house() -> void:
	var strategy := InfantryDeathStrategyScript.new()
	_expect(
		strategy.death_sound_event_id(&"Shot", &"") == &"normalmandying",
		"an empty house_id must fall back to the generic dying hook"
	)


func _test_vehicle_sound() -> void:
	var strategy := VehicleDeathStrategyScript.new()
	_expect(strategy.death_sound_event_id(&"Explode", &"") == &"explode", "vehicle sound id must be explode")
	_expect(strategy.death_sound_event_id(&"Explode", &"Atreides") == &"explode", "vehicle sound id must ignore faction")


func _test_infantry_launch_impulse() -> void:
	var strategy := InfantryDeathStrategyScript.new()
	var blow_up_impulse := strategy.death_launch_impulse(&"Blow_Up")
	_expect(blow_up_impulse.y > 0.0, "Blow_Up must add a positive-Y launch impulse")
	for cause in [&"Shot", &"Burn", &"Gassed", &""]:
		_expect(
			strategy.death_launch_impulse(cause).is_zero_approx(),
			"%s must add no launch impulse; the clip is authored in place" % cause
		)


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
