extends SceneTree

const CombatBulletScript := preload("res://scripts/combat/combat_bullet.gd")
const CombatProjectileScript := preload("res://scripts/combat/combat_projectile.gd")
const CombatTurretScript := preload("res://scripts/combat/combat_turret.gd")
const UnitScript := preload("res://scripts/units/unit.gd")
const UnitScene := preload("res://scenes/units/unit.tscn")
const ATAPCModelScene := preload("res://assets/converted/models/AT_APC_H0/AT_APC_H0.scn")
const ATInfantryModelScene := preload("res://assets/converted/models/AT_inf_H0/AT_inf_H0.scn")
const ATMinotaurusModelScene := preload(
	"res://assets/converted/models/AT_minotaurus_H0/AT_minotaurus_H0.scn"
)
const ORLaserTankModelScene := preload(
	"res://assets/converted/models/OR_Lasertank_H0/OR_Lasertank_H0.scn"
)
const HKGunTurretScene := preload(
	"res://assets/converted/buildings/HKGunTurret/HKGunTurret.scn"
)

var _assertions := 0
var _failures := 0
var _current_case := ""


class CombatTarget extends RefCounted:
	var armour_type: StringName
	var airborne := false
	var damage_taken := 0.0
	var position := Vector3.ZERO
	var alive := true
	var hit_radius := 0.25

	func _init(target_armour: StringName, target_airborne := false) -> void:
		armour_type = target_armour
		airborne = target_airborne

	func combat_armour_type() -> StringName:
		return armour_type

	func combat_is_airborne() -> bool:
		return airborne

	func combat_aim_position() -> Vector3:
		return position

	func combat_is_alive() -> bool:
		return alive

	func combat_hit_radius() -> float:
		return hit_radius

	func take_damage(amount: float) -> void:
		damage_taken += amount


class PhysicsCombatTarget extends StaticBody3D:
	var armour_type: StringName = &"None"
	var damage_taken := 0.0

	func _init(world_position: Vector3, radius := 0.5) -> void:
		position = world_position
		collision_layer = 2
		collision_mask = 0
		var collision := CollisionShape3D.new()
		var sphere := SphereShape3D.new()
		sphere.radius = radius
		collision.shape = sphere
		add_child(collision)

	func combat_armour_type() -> StringName:
		return armour_type

	func combat_is_airborne() -> bool:
		return false

	func combat_aim_position() -> Vector3:
		return global_position

	func combat_is_alive() -> bool:
		return true

	func take_damage(amount: float) -> void:
		damage_taken += amount


func _initialize() -> void:
	await process_frame
	_run_case("warhead matrix scales bullet damage by target armour", _test_armour_matrix)
	_run_case("bullet targeting distinguishes ground and aircraft", _test_target_domains)
	_run_case("bullet rules expose physical delivery parameters", _test_bullet_delivery_rules)
	_run_case("hitscan resolves at launch without travel", _test_hitscan_projectile)
	_run_case("non-homing bullets keep the sampled aim point", _test_linear_projectile_no_lead)
	_run_case("homing respects delay, turn rate and target lifetime", _test_homing_projectile)
	_run_case("trajectory bullets follow a gravity arc", _test_trajectory_projectile)
	await _run_async_case("projectiles collide and Sonic pierces in 3D", _test_projectile_world_collision)
	_run_case("turret emits bursts and reloads in rule ticks", _test_turret_reload)
	_run_case("turret launches projectiles from its authored muzzle", _test_turret_projectile_launch)
	_run_case("compound turret binds authored pivots and muzzle", _test_compound_turret)
	_run_case("single-axis turret turns without changing pitch", _test_single_axis_turret)
	_run_case("fixed weapon keeps its authored direction", _test_fixed_turret)
	_run_case("multi-barrel turret cycles authored muzzles", _test_multi_barrel_turret)
	_run_case("unit model replacement rebinds its turret", _test_unit_turret_rebind)
	_run_case("building state replacement rebinds its turret", _test_building_turret_rebind)
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


func _run_async_case(case_name: String, test: Callable) -> void:
	_current_case = case_name
	var failures_before := _failures
	await test.call()
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
	var rejected_projectile = CombatProjectileScript.new()
	root.add_child(rejected_projectile)
	_expect(
		not rejected_projectile.launch(
			lmg, _emission(Vector3.ZERO, Vector3.FORWARD), aircraft
		),
		"a projectile must reject an incompatible target before entering flight"
	)
	rejected_projectile.free()


func _test_bullet_delivery_rules() -> void:
	var rules = root.get_node("Rules")
	var lmg = _runtime_bullet(rules, &"LMG_B")
	_expect(is_equal_approx(lmg.maximum_range(), 5.0), "LMG_B must retain its five-tile rule range")
	_expect(
		is_equal_approx(lmg.maximum_range_world(), 10.0),
		"five source range tiles must convert to ten world units"
	)
	_expect(lmg.is_hitscan(), "negative Speed, rather than IsLaser, must define hitscan")
	_expect(not lmg.is_laser(), "an ordinary conceptual firearm must not become a laser")

	var adp = _runtime_bullet(rules, &"HEATADP_B")
	_expect(adp.is_homing(), "HEATADP_B must expose its Homing flag")
	_expect(is_equal_approx(adp.homing_delay_ticks(), 5.0), "HomingDelay must remain in rule ticks")
	_expect(is_equal_approx(adp.turn_rate(), 0.9), "TurnRate must remain radians per update")
	_expect(not adp.can_reach(Vector3.ZERO, Vector3.FORWARD * 19.9), "MinRange=10 tiles must reject a nearer launch")
	_expect(adp.can_reach(Vector3.ZERO, Vector3.FORWARD * 20.0), "the exact minimum range must be accepted")
	_expect(adp.can_reach(Vector3.ZERO, Vector3.FORWARD * 30.0), "the exact maximum range must be accepted")
	_expect(not adp.can_reach(Vector3.ZERO, Vector3.FORWARD * 30.1), "a target beyond MaxRange must be rejected")

	var sonic = _runtime_bullet(rules, &"Sound_B")
	var flame = _runtime_bullet(rules, &"Flame_B")
	_expect(sonic.is_continuous() and sonic.is_piercing(), "the Sonic wave must retain continuous piercing delivery")
	_expect(flame.is_continuous() and not flame.is_piercing(), "Continuous alone must not make flame pass through walls")
	var mortar = _runtime_bullet(rules, &"Mortar_B")
	_expect(is_equal_approx(mortar.blast_radius_world(), 4.0), "BlastRadius=64 must convert from XBF to four world units")
	_expect(is_equal_approx(mortar.friendly_damage_amount(), 50.0), "friendly splash amount must remain a percentage")
	_expect(mortar.explosion_type() == &"ShellHit", "the bullet must retain its explosion presentation id")
	_expect(mortar.explosion_effects() == ["ShellHit"], "all normalized explosion effects must stay available")
	_expect(_runtime_bullet(rules, &"Leech_B").effect_flags().has("leech"), "special delivery flags must remain owned by Bullet")


func _test_hitscan_projectile() -> void:
	var rules = root.get_node("Rules")
	var target := CombatTarget.new(&"None")
	target.position = Vector3(0.0, 0.0, -5.0)
	var projectile = CombatProjectileScript.new()
	root.add_child(projectile)
	var launched: bool = projectile.launch(
		_runtime_bullet(rules, &"LMG_B"),
		_emission(Vector3.ZERO, Vector3.FORWARD),
		target
	)
	_expect(launched, "an in-range conceptual bullet must launch")
	_expect(projectile.is_finished(), "hitscan must finish in the launch call")
	_expect(projectile.finish_reason == &"impact_target", "hitscan must resolve against its live target")
	_expect(is_zero_approx(projectile.traveled_distance), "hitscan must accumulate no physical travel")
	_expect(is_equal_approx(target.damage_taken, 219.0), "hitscan must deliver its payload exactly once")
	projectile.free()


func _test_linear_projectile_no_lead() -> void:
	var rules = root.get_node("Rules")
	var target := CombatTarget.new(&"Heavy")
	target.position = Vector3(0.0, 0.0, -12.0)
	var projectile = CombatProjectileScript.new()
	root.add_child(projectile)
	_expect(
		projectile.launch(
			_runtime_bullet(rules, &"StraightBomb"),
			_emission(Vector3.ZERO, Vector3.FORWARD),
			target
		),
		"StraightBomb must launch toward an in-range target"
	)
	target.position = Vector3(5.0, 0.0, -12.0)
	projectile.advance(0.25)
	_expect(
		projectile.state == CombatProjectileScript.State.FLYING,
		"a 24-unit/s bullet must still be flying halfway to a point twelve units away"
	)
	_expect(
		projectile.global_position.is_equal_approx(Vector3(0.0, 0.0, -6.0)),
		"linear movement must use Speed in world units per second"
	)
	projectile.advance(0.25)
	_expect(projectile.finish_reason == &"impact_ground", "a sidestepping target must escape a non-homing shot")
	_expect(is_zero_approx(target.damage_taken), "a missed non-homing shot must not damage its former target")
	projectile.free()


func _test_homing_projectile() -> void:
	var rules = root.get_node("Rules")
	var target := CombatTarget.new(&"Aircraft", true)
	target.position = Vector3(0.0, 0.0, -20.0)
	var projectile = CombatProjectileScript.new()
	root.add_child(projectile)
	_expect(
		projectile.launch(
			_runtime_bullet(rules, &"HEATADP_B"),
			_emission(Vector3.ZERO, Vector3.FORWARD),
			target
		),
		"the AA missile must launch at its exact minimum range"
	)
	target.position = Vector3(20.0, 0.0, 0.0)
	projectile.advance(0.25)
	_expect(
		projectile.direction().is_equal_approx(Vector3.FORWARD),
		"the missile must keep its launch heading for five HomingDelay ticks"
	)
	projectile.advance(0.05)
	_expect(projectile.direction().x > 0.5, "after the delay, TurnRate must bend the missile toward the live target")
	target.alive = false
	projectile.advance(0.05)
	_expect(projectile.finish_reason == &"target_lost", "a homing missile must self-destruct when its target dies")
	_expect(is_zero_approx(target.damage_taken), "target loss must not apply an impact payload")
	projectile.free()


func _test_trajectory_projectile() -> void:
	var rules = root.get_node("Rules")
	var projectile = CombatProjectileScript.new()
	root.add_child(projectile)
	_expect(
		projectile.launch(
			_runtime_bullet(rules, &"Mortar_B"),
			_emission(Vector3.ZERO, Vector3.FORWARD),
			Vector3(0.0, 0.0, -20.0),
			null,
			float(rules.general_rules().field(&"bullet_gravity", 1.0))
		),
		"a trajectory bullet without Speed must derive a gravity arc"
	)
	projectile.advance(0.5)
	_expect(projectile.global_position.y > 1.0, "the mortar shell must rise above the direct line")
	_expect(projectile.state == CombatProjectileScript.State.FLYING, "the shell must remain alive before its arc completes")
	projectile.advance(2.0)
	_expect(projectile.finish_reason == &"impact_ground", "an attack-ground arc must burst at its sampled point")
	_expect(
		projectile.global_position.is_equal_approx(Vector3(0.0, 0.0, -20.0)),
		"the analytic arc must finish exactly at its aim position"
	)
	projectile.free()


func _test_projectile_world_collision() -> void:
	var rules = root.get_node("Rules")
	var blocker := PhysicsCombatTarget.new(Vector3(0.0, 0.0, -4.0), 0.75)
	var target := PhysicsCombatTarget.new(Vector3(0.0, 0.0, -8.0), 0.75)
	root.add_child(blocker)
	root.add_child(target)
	await physics_frame

	var shell = CombatProjectileScript.new()
	root.add_child(shell)
	shell.launch(
		_runtime_bullet(rules, &"StraightBomb"),
		_emission(Vector3.ZERO, Vector3.FORWARD),
		target
	)
	shell.advance(0.5)
	_expect(shell.finish_reason == &"impact_target", "a direct shell must stop at the first combat collider")
	_expect(blocker.damage_taken > 0.0, "the first entity on the ray must receive the shell payload")
	_expect(is_zero_approx(target.damage_taken), "an intercepted non-piercing shell must not reach its intended target")
	shell.free()

	blocker.damage_taken = 0.0
	target.damage_taken = 0.0
	var wave = CombatProjectileScript.new()
	root.add_child(wave)
	wave.launch(
		_runtime_bullet(rules, &"Sound_B"),
		_emission(Vector3.ZERO, Vector3.FORWARD),
		target
	)
	wave.advance(0.5)
	_expect(blocker.damage_taken > 0.0, "the Sonic wave must damage the first intersected entity")
	_expect(target.damage_taken > 0.0, "the Sonic wave must continue through to the entity behind it")
	_expect(wave.traveled_distance >= 8.0, "piercing must not end the wave at the first collision")
	wave.free()
	blocker.free()
	target.free()


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


func _test_turret_projectile_launch() -> void:
	var rules = root.get_node("Rules")
	var model := ATMinotaurusModelScene.instantiate() as Node3D
	root.add_child(model)
	var turret = CombatTurretScript.new()
	turret.configure_from_rules(rules.turret(&"ATMinotaurusBase"), rules)
	turret.bind_model(model, 0)
	var emission := turret.peek_emission()
	var direction: Vector3 = emission["direction"]
	_expect(
		turret.try_fire_at(Vector3(emission["position"]) + direction * 100.0, model, root).is_empty(),
		"an out-of-range request must not emit a projectile"
	)
	_expect(is_zero_approx(turret.reload_ticks_remaining), "a rejected request must not consume reload")
	var projectiles: Array = turret.try_fire_at(
		Vector3(emission["position"]) + direction * 10.0, model, root
	)
	_expect(projectiles.size() == 1, "an in-range request must create one physical projectile")
	if not projectiles.is_empty():
		var projectile = projectiles[0]
		_expect(projectile.bullet.id() == &"KobraHowitzer_B", "the projectile must carry the turret's configured bullet")
		_expect(
			projectile.global_position.is_equal_approx(Vector3(emission["position"])),
			"the projectile must start at the authored >> muzzle"
		)
		_expect(
			projectile.state == CombatProjectileScript.State.FLYING,
			"a non-hitscan turret shot must remain as a world-space node"
		)
		projectile.free()
	model.free()


func _test_compound_turret() -> void:
	var rules = root.get_node("Rules")
	var model := ATAPCModelScene.instantiate() as Node3D
	root.add_child(model)
	var turret = CombatTurretScript.new()
	_expect(
		turret.configure_from_rules(rules.turret(&"ATAPCBase"), rules),
		"ATAPCBase must resolve its ATAPCGun joint"
	)
	_expect(turret.bind_model(model, 0), "the APC's ::0 pivot must bind")
	_expect(turret.joint_count() == 2, "TurretNextJoint must produce a two-joint chain")
	_expect(turret.muzzle_count() == 1, "the nested >>0 marker must be the muzzle")
	_expect(not turret.is_fixed(), "the APC turret must expose moving axes")

	var emission := turret.peek_emission()
	_expect(not emission.is_empty(), "a bound turret must expose a world-space emission")
	_expect(
		String((emission.get("node") as Node).get_meta("original_name", "")).contains(">>0"),
		"the emission node must retain the original >>0 marker"
	)
	var target: Vector3 = emission["position"] + Vector3.RIGHT * 10000.0
	turret.aim_at(target, 0.05)
	_expect(
		is_equal_approx(turret.current_yaw_degrees(), 2.5),
		"one 20 Hz aim update must turn by TurretYRotationAngle"
	)
	turret.aim_at(target, 10.0)
	_expect(
		absf(turret.current_yaw_degrees() - 90.0) < 1.0,
		"an unrestricted base must eventually face a target to its right"
	)

	var down_target: Vector3 = turret.peek_emission()["position"] + Vector3.DOWN * 100.0
	turret.aim_at(down_target, 10.0)
	_expect(
		absf(turret.current_pitch_degrees() - 5.0) < 0.1,
		"the gun joint must stop at TurretMaxXRotation"
	)
	model.free()


func _test_fixed_turret() -> void:
	var rules = root.get_node("Rules")
	var model := ATInfantryModelScene.instantiate() as Node3D
	root.add_child(model)
	var turret = CombatTurretScript.new()
	_expect(
		turret.configure_from_rules(rules.turret(&"ATInfGun"), rules),
		"ATInfGun must remain a configured fixed weapon"
	)
	_expect(turret.bind_model(model, 0), "the infantry weapon marker must bind")
	_expect(turret.is_fixed(), "a turret without X/Y rotation speeds must be fixed")
	_expect(turret.requires_hull_turn(), "a fixed weapon must require owner-body alignment")
	var emission := turret.peek_emission()
	var side_target: Vector3 = emission["position"] + Vector3.RIGHT * 100.0
	_expect(not turret.aim_at(side_target, 10.0), "a fixed weapon must not rotate to a side target")
	_expect(is_zero_approx(turret.current_yaw_degrees()), "a fixed weapon's yaw must stay at rest")
	_expect(is_zero_approx(turret.current_pitch_degrees()), "a fixed weapon's pitch must stay at rest")
	model.free()


func _test_single_axis_turret() -> void:
	var rules = root.get_node("Rules")
	var model := ORLaserTankModelScene.instantiate() as Node3D
	root.add_child(model)
	var turret = CombatTurretScript.new()
	_expect(
		turret.configure_from_rules(rules.turret(&"ORLaserTankBase"), rules),
		"ORLaserTankBase must resolve its laser bullet"
	)
	_expect(turret.bind_model(model, 0), "the Laser Tank's ::0 pivot must bind")
	_expect(not turret.is_fixed(), "a Y-only turret must not be classified as fixed")
	_expect(not turret.requires_hull_turn(), "a Y-only turret can align without turning its hull")
	var emission := turret.peek_emission()
	var side_target: Vector3 = emission["position"] + Vector3.RIGHT * 10000.0
	turret.aim_at(side_target, 0.05)
	_expect(
		is_equal_approx(turret.current_yaw_degrees(), 16.0),
		"the Laser Tank must turn by its 16-degree Y step"
	)
	_expect(is_zero_approx(turret.current_pitch_degrees()), "a Y-only turret must keep pitch at rest")
	model.free()


func _test_multi_barrel_turret() -> void:
	var rules = root.get_node("Rules")
	var model := ATMinotaurusModelScene.instantiate() as Node3D
	root.add_child(model)
	var turret = CombatTurretScript.new()
	turret.configure_from_rules(rules.turret(&"ATMinotaurusBase"), rules)
	_expect(turret.bind_model(model, 0), "the Minotaurus turret root must bind")
	_expect(turret.muzzle_count() == 4, "all four descendant >> markers must be collected")
	var observed: Array[int] = []
	for index in 5:
		observed.append(int(turret.next_emission().get("index", -1)))
	_expect(observed == [0, 1, 2, 3, 0], "muzzles must cycle in marker order and wrap")
	model.free()


func _test_unit_turret_rebind() -> void:
	var unit = UnitScene.instantiate()
	unit.config_id = &"ATAPC"
	root.add_child(unit)
	unit.replace_visual_scene(ATAPCModelScene)
	_expect(unit.combat_turrets.size() == 1, "ATAPC must create one runtime turret")
	_expect(unit.turret_emission_points().size() == 1, "the replacement APC model must expose >>0")
	var emission: Dictionary = unit.next_turret_emission()
	_expect(not emission.is_empty(), "Unit must forward its next world-space muzzle")
	_expect(
		unit.aim_turrets_at(Vector3(emission["position"]) + Vector3.RIGHT * 100.0, 0.05) == false,
		"Unit must forward incremental aiming before the target is reached"
	)
	var launch_emission: Dictionary = unit.turret_emission_points()[0]
	var projectiles: Array = unit.fire_weapon_at(
		Vector3(launch_emission["position"]) + Vector3(launch_emission["direction"]) * 5.0,
		0,
		root
	)
	_expect(projectiles.size() == 1, "Unit must launch its configured weapon through the turret")
	if not projectiles.is_empty():
		_expect(projectiles[0].bullet.id() == &"LMG_B", "the APC Unit API must emit LMG_B")
		projectiles[0].free()
	unit.free()


func _test_building_turret_rebind() -> void:
	var building = HKGunTurretScene.instantiate()
	root.add_child(building)
	_expect(building.combat_turrets.size() == 1, "HKGunTurret must create one runtime turret")
	var idle_emission: Dictionary = building.next_turret_emission()
	_expect(not idle_emission.is_empty(), "the idle building state must expose its >>0 muzzle")
	_expect(
		String((idle_emission.get("node") as Node).get_path()).contains("/Idle/"),
		"the turret must bind the visible Idle model copy"
	)
	building.play_state(&"damage1")
	var damage_emission: Dictionary = building.next_turret_emission()
	_expect(not damage_emission.is_empty(), "the damage state must retain a muzzle")
	_expect(
		String((damage_emission.get("node") as Node).get_path()).contains("/Damage1/"),
		"state changes must rebind the turret to the visible Damage1 copy"
	)
	var projectiles: Array = building.fire_weapon_at(
		Vector3(damage_emission["position"]) + Vector3(damage_emission["direction"]) * 5.0,
		0,
		root
	)
	_expect(projectiles.size() == 1, "Building must launch from the active damage-state muzzle")
	if not projectiles.is_empty():
		_expect(projectiles[0].bullet.id() == &"HKGunTurret_B", "the building API must use its rules bullet")
		projectiles[0].free()
	building.free()


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


func _runtime_bullet(rules: Object, bullet_id: StringName):
	var config: Resource = rules.call("bullet", bullet_id)
	var warhead_id := StringName(String(config.field(&"warhead", ""))) if config != null else &""
	var warhead_config: Resource = rules.call("warhead", warhead_id) if warhead_id != &"" else null
	return CombatBulletScript.new(config, warhead_config)


func _emission(position: Vector3, direction: Vector3) -> Dictionary:
	return {
		"position": position,
		"direction": direction.normalized(),
	}
