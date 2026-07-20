extends SceneTree

const CombatBulletScript := preload("res://scripts/combat/combat_bullet.gd")
const CombatTurretScript := preload("res://scripts/combat/combat_turret.gd")
const UnitScript := preload("res://scripts/units/unit.gd")

var _assertions := 0
var _failures := 0
var _current_case := ""


class CombatTarget extends RefCounted:
	var armour_type: StringName
	var airborne := false
	var damage_taken := 0.0

	func _init(target_armour: StringName, target_airborne := false) -> void:
		armour_type = target_armour
		airborne = target_airborne

	func combat_armour_type() -> StringName:
		return armour_type

	func combat_is_airborne() -> bool:
		return airborne

	func take_damage(amount: float) -> void:
		damage_taken += amount


func _initialize() -> void:
	await process_frame
	_run_case("warhead matrix scales bullet damage by target armour", _test_armour_matrix)
	_run_case("bullet targeting distinguishes ground and aircraft", _test_target_domains)
	_run_case("turret emits bursts and reloads in rule ticks", _test_turret_reload)
	_run_case("units and buildings expose rules-backed combat armour", _test_combat_targets)
	_run_case("shields absorb resolved combat damage before health", _test_shield_absorption)

	if _failures > 0:
		printerr("Combat tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("Combat tests: %d assertions passed" % _assertions)
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


func _test_armour_matrix() -> void:
	var rules = root.get_node("Rules")
	var bullet = CombatBulletScript.new(rules.bullet(&"LMG_B"), rules.warhead(&"LMG_W"))
	_expect(bullet.is_hitscan(), "LMG_B's negative conceptual speed must make it hitscan")
	_expect(is_equal_approx(bullet.base_damage(), 219.0), "LMG_B must retain its rules damage")
	_expect(
		is_equal_approx(bullet.damage_against(&"None"), 219.0),
		"LMG_W must deal 100% damage to None armour"
	)
	_expect(
		is_equal_approx(bullet.damage_against(&"Heavy"), 87.6),
		"LMG_W must deal 40% damage to Heavy armour"
	)
	_expect(
		is_zero_approx(bullet.damage_against(&"Invulnerable")),
		"the zero matrix pair must deal no damage"
	)

	var heavy_target := CombatTarget.new(&"Heavy")
	_expect(
		is_equal_approx(bullet.impact(heavy_target), 87.6),
		"impact must report resolved post-armour damage"
	)
	_expect(
		is_equal_approx(heavy_target.damage_taken, 87.6),
		"impact must deliver the same resolved damage to the target"
	)

	var leech = CombatBulletScript.new(rules.bullet(&"Leech_B"), null)
	_expect(
		is_equal_approx(leech.damage_against(&"Heavy"), 100.0),
		"a special-effect bullet without a warhead must retain its direct fallback damage"
	)


func _test_target_domains() -> void:
	var rules = root.get_node("Rules")
	var lmg = CombatBulletScript.new(rules.bullet(&"LMG_B"), rules.warhead(&"LMG_W"))
	var aircraft := CombatTarget.new(&"Aircraft", true)
	_expect(not lmg.can_hit(aircraft), "a bullet without AntiAircraft must reject aircraft")
	_expect(is_zero_approx(lmg.impact(aircraft)), "a rejected aircraft hit must deal no damage")

	var adp_config: Resource = rules.bullet(&"ATHEATADP_B")
	var adp = CombatBulletScript.new(
		adp_config,
		rules.warhead(StringName(String(adp_config.field(&"warhead", ""))))
	)
	_expect(adp.can_hit(aircraft), "ATHEATADP_B must accept aircraft")
	_expect(
		not adp.can_hit(CombatTarget.new(&"Heavy")),
		"ATHEATADP_B's explicit AntiGround=false must reject ground targets"
	)


func _test_turret_reload() -> void:
	var rules = root.get_node("Rules")
	var turret = CombatTurretScript.new()
	_expect(
		turret.configure_from_rules(rules.turret(&"ATInfGun"), rules),
		"ATInfGun must resolve Turret -> LMG_B -> LMG_W"
	)
	var first_shot: Array = turret.try_fire()
	_expect(first_shot.size() == 1, "a normal turret must emit one bullet")
	_expect(is_equal_approx(turret.reload_ticks_remaining, 30.0), "ATInfGun ReloadCount must be 30 ticks")
	_expect(turret.try_fire().is_empty(), "a turret must not fire again during reload")
	turret.advance_ticks(29.0)
	_expect(not turret.is_ready(), "the turret must remain locked one tick before reload completes")
	turret.advance_ticks(1.0)
	_expect(turret.is_ready(), "the turret must become ready on the final reload tick")

	var burst_turret = CombatTurretScript.new()
	_expect(
		burst_turret.configure_from_rules(rules.turret(&"ATOrnithopterGun"), rules),
		"the Ornithopter turret must resolve through the rules catalog"
	)
	_expect(
		burst_turret.try_fire().size() == 10,
		"TurretBulletCount=10 must emit a ten-bullet burst"
	)


func _test_combat_targets() -> void:
	var rules = root.get_node("Rules")
	_expect(
		StringName(String(rules.unit(&"ATInfantry").field(&"armour_type", ""))) == &"None",
		"unit armour must remain available to combat"
	)
	_expect(
		StringName(String(rules.building(&"ATConYard").field(&"armour_type", ""))) == &"CY",
		"Construction Yard armour must be exported from Rules.txt"
	)
	_expect(
		StringName(String(rules.building(&"ATBarracks").field(&"armour_type", ""))) == &"Building",
		"ordinary building armour must be exported from Rules.txt"
	)
	for config in rules.all(&"building"):
		_expect(
			not String(config.field(&"armour_type", "")).is_empty(),
			"every building must expose an armour type (%s)" % String(config.id)
		)


func _test_shield_absorption() -> void:
	var unit = UnitScript.new()
	unit.max_health = 500.0
	unit.max_shields = 100.0
	unit.health = 500.0
	unit.shields = 100.0
	unit.take_damage(60.0)
	_expect(is_equal_approx(unit.shields, 40.0), "shields must absorb incoming damage first")
	_expect(is_equal_approx(unit.health, 500.0), "fully absorbed damage must not reach health")
	unit.take_damage(100.0)
	_expect(is_zero_approx(unit.shields), "a larger hit must deplete the remaining shield")
	_expect(is_equal_approx(unit.health, 440.0), "only spillover damage must reduce health")
	unit.free()
