extends SceneTree

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")

const CombatBulletScript := preload("res://scripts/combat/combat_bullet.gd")
const CombatImpactResolverScript := preload("res://scripts/combat/combat_impact_resolver.gd")
const CombatProjectileScript := preload("res://scripts/combat/combat_projectile.gd")
const CombatTurretScript := preload("res://scripts/combat/combat_turret.gd")
const CombatDefinitionCatalogScript := preload("res://scripts/combat/combat_definition_catalog.gd")
const UnitScript := preload("res://scripts/units/unit.gd")
const UnitScene := preload("res://scenes/units/unit.tscn")
const ATAPCModelScene := preload("res://assets/converted/models/AT_APC_H0/AT_APC_H0.scn")
const ATInfantryModelScene := preload("res://assets/converted/models/AT_inf_H0/AT_inf_H0.scn")
const ATSniperModelScene := preload(
	"res://assets/converted/models/AT_Sniper_H0/AT_Sniper_H0.scn"
)
const ATTrikeModelScene := preload(
	"res://assets/converted/models/AT_Trike_H0/AT_Trike_H0.scn"
)
const ATMongooseModelScene := preload(
	"res://assets/converted/models/AT_mongoose_H0/AT_mongoose_H0.scn"
)
const ATMinotaurusModelScene := preload(
	"res://assets/converted/models/AT_minotaurus_H0/AT_minotaurus_H0.scn"
)
const HKMissileModelScene := preload(
	"res://assets/converted/models/HK_missile_H0/HK_missile_H0.scn"
)
const HKDevastatorModelScene := preload(
	"res://assets/converted/models/HK_devastator_H0/HK_devastator_H0.scn"
)
const ORAPCModelScene := preload("res://assets/converted/models/Or_apc_H0/Or_apc_H0.scn")
const ORLaserTankModelScene := preload(
	"res://assets/converted/models/OR_Lasertank_H0/OR_Lasertank_H0.scn"
)
const HKGunTurretScene := preload(
	"res://assets/converted/buildings/HKGunTurret/HKGunTurret.scn"
)
const ATWallScene := preload(
	"res://assets/converted/buildings/ATWall/ATWall.scn"
)

var _assertions := 0
var _failures := 0
var _current_case := ""
var _combat_catalog := CombatDefinitionCatalogScript.new()


class CombatTarget extends RefCounted:
	var armour_type: StringName
	var airborne := false
	var damage_taken := 0.0
	var position := Vector3.ZERO
	var alive := true
	var hit_radius := 0.25
	var owner_player_id := 2
	var accepted_effects: Array[StringName] = []
	var received_effects: Array[StringName] = []
	var received_effect_contexts: Array[Dictionary] = []

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

	func combat_owner_player_id() -> int:
		return owner_player_id

	func combat_apply_bullet_effect(effect: StringName, context: Dictionary) -> bool:
		received_effects.append(effect)
		received_effect_contexts.append(context)
		return effect in accepted_effects


class PhysicsCombatTarget extends StaticBody3D:
	var armour_type: StringName = &"None"
	var damage_taken := 0.0
	var owner_player_id := 2
	var alive := true
	var hit_radius := 0.5

	func _init(world_position: Vector3, radius := 0.5) -> void:
		position = world_position
		hit_radius = radius
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
		return alive

	func combat_hit_radius() -> float:
		return hit_radius

	func combat_owner_player_id() -> int:
		return owner_player_id

	func take_damage(amount: float) -> void:
		damage_taken += amount


class CombatSource extends RefCounted:
	var owner_player_id := 1

	func combat_owner_player_id() -> int:
		return owner_player_id


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await process_frame
	_run_case("warhead matrix scales bullet damage by target armour", _test_armour_matrix)
	_run_case("bullet targeting distinguishes ground and aircraft", _test_target_domains)
	_run_case("bullet rules expose physical delivery parameters", _test_bullet_delivery_rules)
	_run_case("impact effects use typed acceptance and fallback damage", _test_impact_effect_contract)
	_run_case("hitscan resolves at launch without travel", _test_hitscan_projectile)
	_run_case("non-homing bullets keep the sampled aim point", _test_linear_projectile_no_lead)
	_run_case("attack-ground missiles descend to the sampled point", _test_attack_ground_missile)
	_run_case("homing respects delay, turn rate and target lifetime", _test_homing_projectile)
	_run_case("trajectory bullets follow a gravity arc", _test_trajectory_projectile)
	await _run_async_case("projectiles collide and Sonic pierces in 3D", _test_projectile_world_collision)
	await _run_async_case("impact resolution applies splash falloff and friendly fire", _test_impact_resolution)
	_run_case("turret emits bursts and reloads in rule ticks", _test_turret_reload)
	await _run_async_case(
		"muzzle FX banks emit authored rising barrel smoke",
		_test_muzzle_fx_bank_smoke
	)
	await _run_async_case(
		"model FX banks emit authored casing counts and sizes",
		_test_model_fx_bank_casings
	)
	await _run_async_case(
		"turret launches projectiles and composes the authored impact FX",
		_test_turret_projectile_launch
	)
	await _run_async_case(
		"Mongoose composes launch backblast and missile impact FX",
		_test_mongoose_launch_and_impact_fx
	)
	_run_case("compound turret binds authored pivots and muzzle", _test_compound_turret)
	_run_case("single-axis turret turns without changing pitch", _test_single_axis_turret)
	_run_case("fixed weapon keeps its authored direction", _test_fixed_turret)
	_run_case("multi-barrel turret cycles authored muzzles", _test_multi_barrel_turret)
	_run_case("trajectory barrels fire a parallel salvo", _test_parallel_trajectory_salvo)
	_run_case("limited turret turns its hull toward rear targets", _test_limited_turret_hull_turn)
	_run_case("turret recenters smoothly after attack is replaced by move", _test_turret_recenter_after_move)
	_run_case("unit model replacement rebinds its turret", _test_unit_turret_rebind)
	_run_case("unit attack orders validate targets, fire, and pursue", _test_unit_attack_order)
	_run_case("launcher fire clips schedule every projectile before reload", _test_launcher_fire_sequences)
	_run_case("pursuit enters a stable firing range", _test_far_attack_pursuit)
	_run_case("building state replacement rebinds its turret", _test_building_turret_rebind)
	_run_case("building damage visuals use equal health bands", _test_building_damage_visual_states)
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


func _horizontal_angle_between(a: Vector3, b: Vector3) -> float:
	var a_horizontal := Vector2(a.x, a.z)
	var b_horizontal := Vector2(b.x, b.z)
	if a_horizontal.is_zero_approx() or b_horizontal.is_zero_approx():
		return 0.0
	return absf(angle_difference(a_horizontal.angle(), b_horizontal.angle()))


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])


func _muzzle_effects(kind: StringName, emission_index := -1) -> Array[Node3D]:
	var result: Array[Node3D] = []
	for child in root.get_children():
		if not child is Node3D or child.get_meta("combat_muzzle_fx", &"") != kind:
			continue
		if emission_index >= 0 and int(child.get_meta("emission_index", -1)) != emission_index:
			continue
		result.append(child as Node3D)
	return result


func _free_muzzle_effects() -> void:
	for child in root.get_children():
		if child.has_meta("combat_muzzle_fx"):
			child.free()


func _impact_effects(effect_id: StringName) -> Array[Node3D]:
	var result: Array[Node3D] = []
	for child in root.get_children():
		if child is Node3D \
		and child.get_meta("combat_impact_fx", &"") == effect_id:
			result.append(child as Node3D)
	return result


func _free_impact_effects() -> void:
	for child in root.get_children():
		if child.has_meta("combat_impact_fx"):
			child.free()


func _test_armour_matrix() -> void:
	var bullet = CombatBulletScript.new(_combat_catalog.bullet(&"LMG_B"), _combat_catalog.warhead(&"LMG_W"))
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
	_expect(bullet.warhead.id() == &"LMG_W", "the runtime Warhead must retain its rules id")
	var copied_matrix: Dictionary = bullet.warhead.armour_damage_matrix()
	copied_matrix["Heavy"] = 0.0
	_expect(
		is_equal_approx(bullet.warhead.damage_percent_for(&"Heavy"), 40.0),
		"callers must receive a copy rather than mutate the immutable armour matrix"
	)
	_expect(
		is_zero_approx(bullet.warhead.damage_percent_for(&"UnknownArmour")),
		"a missing warhead/armour pair must resolve to zero"
	)
	_expect(
		is_zero_approx(bullet.damage_against(&"Invulnerable")),
		"the zero matrix pair must deal no damage"
	)

	var heavy_target := CombatTarget.new(&"Heavy")
	var resolver = CombatImpactResolverScript.new()
	var results: Array[Dictionary] = resolver.resolve(
		bullet, null, Vector3.ZERO, heavy_target
	)
	_expect(
		results.size() == 1 and is_equal_approx(float(results[0]["damage"]), 87.6),
		"the impact resolver must report resolved post-armour damage"
	)
	_expect(
		is_equal_approx(heavy_target.damage_taken, 87.6),
		"impact must deliver the same resolved damage to the target"
	)

	var leech = CombatBulletScript.new(_combat_catalog.bullet(&"Leech_B"), null)
	_expect(
		is_equal_approx(leech.damage_against(&"Heavy"), 100.0),
		"a special-effect bullet without a warhead must retain its direct fallback damage"
	)


func _test_target_domains() -> void:
	var lmg = CombatBulletScript.new(_combat_catalog.bullet(&"LMG_B"), _combat_catalog.warhead(&"LMG_W"))
	var aircraft := CombatTarget.new(&"Aircraft", true)
	_expect(not lmg.can_hit(aircraft), "a bullet without AntiAircraft must reject aircraft")
	_expect(lmg.can_hit_ground(), "an ordinary ground weapon must accept attack-ground")
	_expect(
		CombatImpactResolverScript.new().resolve(lmg, null, Vector3.ZERO, aircraft).is_empty(),
		"a rejected aircraft impact must resolve no target"
	)

	var adp_config: Resource = _combat_catalog.bullet(&"ATHEATADP_B")
	var adp = CombatBulletScript.new(
		adp_config,
		_combat_catalog.warhead(adp_config.warhead_id)
	)
	_expect(adp.can_hit(aircraft), "ATHEATADP_B must accept aircraft")
	_expect(
		not adp.can_hit(CombatTarget.new(&"Heavy")),
		"ATHEATADP_B's explicit AntiGround=false must reject ground targets"
	)
	_expect(not adp.can_hit_ground(), "an air-only weapon must reject attack-ground coordinates")
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
	var kobra_shell = _runtime_bullet(rules, &"KobraHowitzer_B")
	_expect(
		kobra_shell.has_missile_trail()
		and kobra_shell.missile_trail_style() == 6
		and is_equal_approx(kobra_shell.missile_trail_size(), 2.0)
		and kobra_shell.missile_trail_length() == 8
		and is_equal_approx(kobra_shell.missile_trail_delta(), 0.7),
		"KobraHowitzer_B must expose its complete authored trail dimensions"
	)
	_expect(_runtime_bullet(rules, &"Leech_B").effect_flags().has("leech"), "special delivery flags must remain owned by Bullet")
	_expect(
		_runtime_bullet(rules, &"BarrelBomb").reduces_damage_with_distance(),
		"omitted ReduceDamageWithDistance must keep the source default falloff"
	)
	_expect(
		not mortar.reduces_damage_with_distance(),
		"an explicit ReduceDamageWithDistance=False must disable falloff"
	)


func _test_impact_effect_contract() -> void:
	var rules = root.get_node("Rules")
	var leech = _runtime_bullet(rules, &"Leech_B")
	var resolver = CombatImpactResolverScript.new()
	var vehicle := CombatTarget.new(&"Heavy")
	vehicle.accepted_effects.append(&"leech")
	var accepted: Array[Dictionary] = resolver.resolve(
		leech, null, Vector3.ZERO, vehicle, CombatSource.new()
	)
	_expect(accepted.size() == 1, "an effect-capable direct target must resolve")
	_expect(&"leech" in accepted[0]["effects"], "the target must acknowledge its typed effect")
	_expect(
		is_zero_approx(vehicle.damage_taken),
		"an accepted infection must suppress the no-warhead fallback damage"
	)
	_expect(
		vehicle.received_effect_contexts.size() == 1
		and is_equal_approx(float(vehicle.received_effect_contexts[0]["effect_health"]), 200.0)
		and is_equal_approx(float(vehicle.received_effect_contexts[0]["effect_damage_per_tick"]), 2.0),
		"the resolver must pass infection parameters to the typed effect receiver"
	)

	var rejected := CombatTarget.new(&"Heavy")
	var fallback: Array[Dictionary] = resolver.resolve(
		leech, null, Vector3.ZERO, rejected, CombatSource.new()
	)
	_expect(fallback.size() == 1 and fallback[0]["effects"].is_empty(), "a rejected effect must be reported")
	_expect(
		is_equal_approx(rejected.damage_taken, 100.0),
		"Leech_B Damage must be used when the target cannot receive infection"
	)


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


func _test_attack_ground_missile() -> void:
	var rules = root.get_node("Rules")
	var launch_position := Vector3(0.0, 2.0, 0.0)
	var ground_position := Vector3(0.0, 0.0, -10.0)
	var projectile = CombatProjectileScript.new()
	root.add_child(projectile)
	_expect(
		projectile.launch(
			_runtime_bullet(rules, &"HEAT_B"),
			_emission(launch_position, Vector3.FORWARD),
			ground_position
		),
		"the Mongoose missile must accept an in-range attack-ground point"
	)
	_expect(
		projectile.direction().is_equal_approx(
			launch_position.direction_to(ground_position)
		),
		"a yaw-only launcher must include the downward component in a coordinate shot"
	)
	projectile.advance(1.0)
	_expect(
		projectile.finish_reason == &"impact_ground",
		"the attack-ground missile must resolve as a ground impact"
	)
	_expect(
		projectile.global_position.is_equal_approx(ground_position),
		"a large simulation step must not carry the missile past its sampled point"
	)
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
	var launch_direction: Vector3 = projectile.direction()
	var launch_pitch := rad_to_deg(atan2(
		launch_direction.y, Vector2(launch_direction.x, launch_direction.z).length()
	))
	_expect(
		launch_pitch > 15.0 and launch_pitch < 30.0,
		"a target below MaxRange must use the flatter low ballistic solution instead of a fixed 45-degree arc"
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


func _test_impact_resolution() -> void:
	var rules = root.get_node("Rules")
	var source := CombatSource.new()
	var direct := PhysicsCombatTarget.new(Vector3.ZERO)
	var ally := PhysicsCombatTarget.new(Vector3(2.0, 0.0, 0.0))
	ally.owner_player_id = source.owner_player_id
	var enemy := PhysicsCombatTarget.new(Vector3(3.5, 0.0, 0.0))
	var outside := PhysicsCombatTarget.new(Vector3(5.0, 0.0, 0.0))
	root.add_child(direct)
	root.add_child(ally)
	root.add_child(enemy)
	root.add_child(outside)
	await physics_frame

	var resolver = CombatImpactResolverScript.new()
	var mortar = _runtime_bullet(rules, &"Mortar_B")
	var results: Array[Dictionary] = resolver.resolve(
		mortar, direct, Vector3.ZERO, direct, source
	)
	_expect(results.size() == 3, "the direct target and two colliders inside four world units must resolve")
	_expect(
		is_equal_approx(direct.damage_taken, mortar.damage_against(&"None")),
		"a direct target must receive full post-armour damage exactly once"
	)
	_expect(
		is_equal_approx(ally.damage_taken, mortar.damage_against(&"None") * 0.5),
		"FriendlyDamageAmount=50 must halve allied splash"
	)
	_expect(
		is_equal_approx(enemy.damage_taken, mortar.damage_against(&"None")),
		"explicitly disabled distance reduction must keep enemy splash at full damage"
	)
	_expect(is_zero_approx(outside.damage_taken), "a collider outside BlastRadius must remain untouched")

	ally.damage_taken = 0.0
	var heat = _runtime_bullet(rules, &"HEAT_B")
	var direct_friendly_results: Array[Dictionary] = resolver.resolve(
		heat, ally, ally.global_position, ally, source
	)
	_expect(
		is_equal_approx(ally.damage_taken, heat.damage_against(&"None")),
		"an explicitly selected allied direct target must receive full weapon damage"
	)
	_expect(
		direct_friendly_results.size() == 1 \
			and is_equal_approx(float(direct_friendly_results[0]["friendly_multiplier"]), 1.0),
		"FriendlyDamageAmount must not suppress a deliberate direct hit"
	)

	direct.damage_taken = 0.0
	ally.damage_taken = 0.0
	enemy.damage_taken = 0.0
	outside.damage_taken = 0.0
	var barrel_bomb = _runtime_bullet(rules, &"BarrelBomb")
	resolver.resolve(barrel_bomb, direct, Vector3.ZERO, null, null)
	var enemy_surface_distance: float = enemy.global_position.length() - enemy.hit_radius
	var expected_falloff: float = (
		1.0 - enemy_surface_distance / float(barrel_bomb.blast_radius_world())
	)
	_expect(
		is_equal_approx(
			enemy.damage_taken,
			barrel_bomb.damage_against(&"None") * expected_falloff
		),
		"default radial damage must fall linearly from collider surface to blast edge"
	)

	direct.free()
	ally.free()
	enemy.free()
	outside.free()


func _test_turret_reload() -> void:
	var rules = root.get_node("Rules")
	var turret = CombatTurretScript.new()
	_expect(
		turret.configure(&"ATInfGun"),
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
		burst_turret.configure(&"ATOrnithopterGun"),
		"the Ornithopter turret must resolve through the rules catalog"
	)
	_expect(
		burst_turret.try_fire().size() == 10,
		"TurretBulletCount=10 must emit a ten-bullet burst"
	)


func _test_muzzle_fx_bank_smoke() -> void:
	var rules = root.get_node("Rules")
	var cases := [
		[&"ATTrikeGun", &"Muzzle1", 0.5, 7.5],
		[&"ATAPCBase", &"Muzzle1", 0.5, 7.5],
		[&"ATMongooseMissile", &"Muzzle3", 0.625, 5.0],
		[&"ATMinotaurusBase", &"Muzzle3", 0.625, 5.0],
	]
	for case_index in cases.size():
		var smoke_case: Array = cases[case_index]
		var turret = CombatTurretScript.new()
		_expect(
			turret.configure(StringName(smoke_case[0])),
			"%s must configure for muzzle-bank smoke" % String(smoke_case[0])
		)
		_expect(
			turret.muzzle_flash_id == smoke_case[1]
			and turret.muzzle_flash_scene != null,
			"%s must resolve %s" % [smoke_case[0], smoke_case[1]]
		)
		var emission_index := 10 + case_index
		turret._spawn_muzzle_flash(root, {
			"index": emission_index,
			"position": Vector3(4.0 + case_index, 1.0, 3.0),
			"direction": Vector3.FORWARD,
		})
		await create_timer(0.28).timeout
		var smoke_particles := _muzzle_effects(&"barrel_smoke", emission_index)
		_expect(
			smoke_particles.size() == 2,
			"%s must emit two particles between its authored start/stop frames"
				% String(smoke_case[1])
		)
		var bank_driven := smoke_particles.size() == 2
		for particle in smoke_particles:
			var visual := particle.get_node_or_null("Visual") as MeshInstance3D
			var quad := visual.mesh as QuadMesh if visual != null else null
			var start := Vector3(particle.get_meta(
				"combat_muzzle_start_position", particle.global_position
			))
			var acceleration := Vector3(particle.get_meta(
				"combat_muzzle_acceleration", Vector3.ZERO
			))
			bank_driven = bank_driven \
				and particle.get_meta("combat_fx_texture", &"") == &"!%Bru" \
				and quad != null \
				and quad.size.is_equal_approx(
					Vector2.ONE * float(smoke_case[2])
				) \
				and is_equal_approx(acceleration.y, float(smoke_case[3])) \
				and particle.global_position.y > start.y
		_expect(
			bank_driven,
			"%s smoke must use bank texture, size, and negative-gravity buoyancy"
				% String(smoke_case[1])
		)
		_free_muzzle_effects()

	var no_smoke_turret = CombatTurretScript.new()
	_expect(
		no_smoke_turret.configure(&"ATSniperGun"),
		"the Sniper muzzle flash must configure for the negative smoke case"
	)
	no_smoke_turret._spawn_muzzle_flash(root, {
		"index": 20,
		"position": Vector3.ZERO,
		"direction": Vector3.FORWARD,
	})
	await create_timer(0.28).timeout
	_expect(
		_muzzle_effects(&"barrel_smoke", 20).is_empty(),
		"Smuzz2 without an !%Bru bank must not acquire barrel smoke"
	)
	_free_muzzle_effects()


func _test_model_fx_bank_casings() -> void:
	var cases := [
		[ATMinotaurusModelScene, &"ATMinotaurusBase", 4, 0.625, 12.5, 1.27,
			["#muzzle06", "#muzzle05", "#muzzle08", "#muzzle07"]],
		[ATTrikeModelScene, &"ATTrikeGun", 2, 0.375, 7.5, 0.22,
			["Gun", "Gun"]],
		[ATInfantryModelScene, &"ATInfGun", 7, 0.1875, 7.5, 1.37,
			["gun", "gun", "gun", "gun", "gun", "gun", "gun"]],
		[ATSniperModelScene, &"ATSniperGun", 1, 0.1875, 0.75, 1.02,
			["Agunbone"]],
		[ATAPCModelScene, &"ATAPCBase", 3, 0.25, 7.5, 0.37,
			["::1turret#", "::1turret#", "::1turret#"]],
		[ATMongooseModelScene, &"ATMongooseMissile", 0, 0.0, 0.0, 0.0, []],
	]
	for casing_case: Array in cases:
		_free_muzzle_effects()
		var model := (casing_case[0] as PackedScene).instantiate() as Node3D
		root.add_child(model)
		var turret = CombatTurretScript.new()
		_expect(
			turret.configure(StringName(casing_case[1]))
			and turret.bind_model(model, 0),
			"%s must bind for casing-bank playback" % String(casing_case[1])
		)
		var observed: Array[Dictionary] = []
		var observe_casing := func(child: Node) -> void:
			if child.get_meta("combat_muzzle_fx", &"") != &"casing":
				return
			observed.append({
				"texture": child.get_meta("combat_fx_texture", &""),
				"size": float(child.get_meta("combat_fx_particle_size", 0.0)),
				"acceleration": Vector3(child.get_meta(
					"combat_muzzle_acceleration", Vector3.ZERO
				)),
				"velocity": Vector3(child.get_meta(
					"combat_muzzle_velocity", Vector3.ZERO
				)),
				"attachment": String(child.get_meta("combat_fx_attachment", "")),
			})
		root.child_entered_tree.connect(observe_casing)
		var started := turret.start_authored_fire_fx(&"Fire_0", root)
		_expect(
			started == (int(casing_case[2]) > 0),
			"%s casing timeline presence must come from its !%%shel bank"
				% String(casing_case[1])
		)
		if started:
			await create_timer(float(casing_case[5])).timeout
		root.child_entered_tree.disconnect(observe_casing)
		_expect(
			observed.size() == int(casing_case[2]),
			"%s must emit %d authored casings, found %d"
				% [casing_case[1], casing_case[2], observed.size()]
		)
		var bank_driven := observed.size() == int(casing_case[2])
		var attachments: Array[String] = []
		for casing: Dictionary in observed:
			var acceleration := Vector3(casing["acceleration"])
			bank_driven = bank_driven \
				and casing["texture"] == &"!%shel" \
				and is_equal_approx(float(casing["size"]), float(casing_case[3])) \
				and is_equal_approx(-acceleration.y, float(casing_case[4])) \
				and not Vector3(casing["velocity"]).is_zero_approx()
			attachments.append(String(casing["attachment"]))
		_expect(
			bank_driven and attachments == casing_case[6],
			"%s casings must retain bank size, gravity, and authored attachments"
				% String(casing_case[1])
		)
		turret.cancel_authored_fire_fx()
		_free_muzzle_effects()
		model.free()


func _test_turret_projectile_launch() -> void:
	var rules = root.get_node("Rules")
	var model := ATMinotaurusModelScene.instantiate() as Node3D
	root.add_child(model)
	var turret = CombatTurretScript.new()
	turret.configure(&"ATMinotaurusBase")
	turret.bind_model(model, 0)
	_expect(
		turret.muzzle_flash_id == &"Muzzle3" and turret.muzzle_flash_scene != null,
		"ATMinotaurusGun must resolve TurretMuzzleFlash=Muzzle3 through ArtIni"
	)
	_expect(
		turret.impact_visual_scenes.has(&"ShellHit"),
		"KobraHowitzer_B must resolve ExplosionType=ShellHit through ArtIni"
	)
	var emission := turret.peek_emission()
	var direction: Vector3 = emission["direction"]
	_expect(
		turret.try_fire_at(Vector3(emission["position"]) + direction * 100.0, model, root).is_empty(),
		"an out-of-range request must not emit a projectile"
	)
	_expect(is_zero_approx(turret.reload_ticks_remaining), "a rejected request must not consume reload")
	var target_position: Vector3 = Vector3(emission["position"]) + direction * 10.0
	_expect(
		turret.try_fire_at(target_position, model, root).is_empty(),
		"a trajectory weapon must not fire while its barrel still points along the direct line"
	)
	var trajectory_aimed := false
	for frame in 120:
		trajectory_aimed = turret.aim_at(target_position, 1.0 / 60.0)
		if trajectory_aimed:
			break
	_expect(trajectory_aimed, "the Minotaurus gun must elevate to its ballistic solution")
	_expect(
		turret.current_pitch_degrees() < -1.0,
		"the Minotaurus pitch joint must visibly raise the barrels for trajectory fire"
	)
	var aimed_emission := turret.peek_emission()
	var projectiles: Array = turret.try_fire_at(target_position, model, root)
	_expect(projectiles.size() == 1, "an in-range request must create one physical projectile")
	if not projectiles.is_empty():
		var projectile = projectiles[0]
		var muzzle_flash := root.get_node_or_null("MuzzleFlash_Muzzle3") as Node3D
		var rear_flashes := _muzzle_effects(&"rear_flash", 0)
		var rear_flash: Node3D = rear_flashes.front() \
			if not rear_flashes.is_empty() else null
		var shot_lights := _muzzle_effects(&"shot_light", 0)
		var shot_light := shot_lights.front() as OmniLight3D \
			if not shot_lights.is_empty() else null
		_expect(
			muzzle_flash != null
			and muzzle_flash.global_position.is_equal_approx(
				Vector3(aimed_emission["position"])
			),
			"the authored Muzzle3 effect must spawn on the active >> muzzle"
		)
		_expect(
			muzzle_flash != null
			and muzzle_flash.find_child("_flashl_0", true, false) != null,
			"the runtime muzzle flash must use the original Explosion/Muzzle3.xbf model"
		)
		var flash_player := muzzle_flash.find_child(
			"AnimationPlayer", true, false
		) as AnimationPlayer if muzzle_flash != null else null
		_expect(
			flash_player != null
			and flash_player.get_animation(&"Stationary").loop_mode == Animation.LOOP_NONE,
			"one projectile event must play exactly one muzzle flash without wrapping"
		)
		_expect(
			aimed_emission.has("rear_position")
			and rear_flash != null
			and rear_flash.global_position.is_equal_approx(
				Vector3(aimed_emission["rear_position"])
			),
			"the paired #muzzle marker must emit the original rear cannon flash"
		)
		var expected_light_position := Vector3(aimed_emission["rear_position"]) \
			+ Vector3(aimed_emission["rear_direction"]) \
			* CombatTurretScript.SHOT_LIGHT_REAR_OFFSET
		_expect(
			shot_lights.size() == 1
			and shot_light != null
			and shot_light.global_position.is_equal_approx(expected_light_position)
			and shot_light.light_color.is_equal_approx(
				CombatTurretScript.SHOT_LIGHT_COLOR
			)
			and shot_light.light_energy > 0.0,
			"each projectile event must briefly light the area behind its active barrel"
		)
		_expect(projectile.bullet.id() == &"KobraHowitzer_B", "the projectile must carry the turret's configured bullet")
		_expect(
			projectile.global_position.is_equal_approx(Vector3(aimed_emission["position"])),
			"the projectile must start at the authored >> muzzle"
		)
		_expect(
			projectile.direction().angle_to(Vector3(aimed_emission["direction"]))
				<= deg_to_rad(1.1),
			"the shell trajectory must leave along the elevated barrel direction"
		)
		_expect(
			projectile.global_basis.z.normalized().dot(projectile.direction()) > 0.999,
			"the converted projectile model's +Z nose must face along its flight direction"
		)
		_expect(
			projectile.state == CombatProjectileScript.State.FLYING,
			"a non-hitscan turret shot must remain as a world-space node"
		)
		var visual := projectile.get_node_or_null("Visual") as Node3D
		_expect(visual != null, "a physical projectile must expose visible runtime geometry")
		_expect(
			visual != null and visual.find_child("shell_0", true, false) != null,
			"KobraHowitzer_B must instantiate the original ArtIni shell.xaf model"
		)
		var source_flash := visual.find_child("*flashl*", true, false) as Node3D \
			if visual != null else null
		_expect(
			source_flash != null and not source_flash.visible,
			"the shell helper flash must not render as permanent rocket exhaust"
		)
		projectile.advance(0.1)
		var trail := projectile.get_node_or_null("MissileTrail") as MeshInstance3D
		_expect(
			trail != null
			and trail.mesh is ImmediateMesh
			and (trail.mesh as ImmediateMesh).get_surface_count() == 1,
			"KobraHowitzer_B must draw a rules-sized fading aerodynamic trail"
		)
		var expected_impact_position: Vector3 = projectile.trajectory_impact_position()
		projectile.advance(10.0)
		var shell_hits := _impact_effects(&"ShellHit")
		var shell_hit: Node3D = shell_hits.front() if not shell_hits.is_empty() else null
		var impact_visual := shell_hit.get_node_or_null("Visual") as Node3D \
			if shell_hit != null else null
		var impact_player := impact_visual.find_child(
			"AnimationPlayer", true, false
		) as AnimationPlayer if impact_visual != null else null
		var active_animation := impact_player.get_animation(
			impact_player.current_animation
		) if impact_player != null else null
		_expect(
			projectile.finish_reason == &"impact_ground"
			and shell_hits.size() == 1
			and shell_hit.global_position.is_equal_approx(expected_impact_position),
			"one ShellHit visual must spawn at the resolved shell impact position"
		)
		var emitter_meshes := impact_visual.find_children(
			"*", "MeshInstance3D", true, false
		) if impact_visual != null else []
		var emitter_geometry_hidden := false
		for emitter_mesh in emitter_meshes:
			var current: Node = emitter_mesh
			var belongs_to_particle := false
			while current != null and current != impact_visual:
				if current.has_meta("combat_impact_particle"):
					belongs_to_particle = true
					break
				current = current.get_parent()
			if not belongs_to_particle:
				emitter_geometry_hidden = true
				if (emitter_mesh as MeshInstance3D).visible:
					emitter_geometry_hidden = false
					break
		_expect(
			emitter_geometry_hidden,
			"ShellHit's blue #bing cubes must remain invisible particle emitters"
		)
		_expect(
			active_animation != null
			and active_animation.loop_mode == Animation.LOOP_NONE,
			"the impact source animation must play once without looping"
		)
		await process_frame
		var particle_counts := {
			&"!%Bru": 0,
			&"!cexp": 0,
			&"!@sm": 0,
		}
		var particle_nodes := shell_hit.find_children(
			"ImpactParticle_*", "Node3D", true, false
		) if shell_hit != null else []
		for child in particle_nodes:
			var sequence := StringName(String(child.get_meta("combat_impact_particle", "")))
			if particle_counts.has(sequence):
				particle_counts[sequence] += 1
		_expect(
			particle_counts[&"!%Bru"] == 1
			and particle_counts[&"!cexp"] == 0
			and particle_counts[&"!@sm"] == 16,
			"ShellHit must start one central burst and sixteen independent shrapnel particles"
		)
		var shrapnel_velocities: Array[Vector3] = []
		for child in particle_nodes:
			if child.get_meta("combat_impact_particle", &"") == &"!@sm":
				shrapnel_velocities.append(Vector3(
					child.get_meta("combat_impact_velocity", Vector3.ZERO)
				))
		var shrapnel_is_independent := shrapnel_velocities.size() == 16
		for velocity_index in range(1, shrapnel_velocities.size()):
			shrapnel_is_independent = shrapnel_is_independent \
				and not shrapnel_velocities[velocity_index].is_equal_approx(
					shrapnel_velocities[velocity_index - 1]
				)
		_expect(
			shrapnel_is_independent,
			"each ShellHit shrapnel particle must receive its own randomized velocity"
		)
		var impact_light := shell_hit.get_node_or_null("ImpactLight") as OmniLight3D \
			if shell_hit != null else null
		_expect(
			impact_light != null
			and impact_light.light_color.is_equal_approx(Color(1.0, 0.43, 0.12))
			and impact_light.light_energy > 0.0,
			"ShellHit must briefly illuminate the impact area with an orange point light"
		)
		await create_timer(1.1).timeout
		_expect(
			is_instance_valid(shell_hit) and not shell_hit.is_processing(),
			"finished follow particles must leave no stale object references in the impact effect"
		)
		if is_instance_valid(projectile):
			projectile.free()
		if muzzle_flash != null and is_instance_valid(muzzle_flash):
			muzzle_flash.free()
		_free_muzzle_effects()
		_free_impact_effects()
	model.free()


func _test_mongoose_launch_and_impact_fx() -> void:
	var rules = root.get_node("Rules")
	var model := ATMongooseModelScene.instantiate() as Node3D
	root.add_child(model)
	var turret = CombatTurretScript.new()
	_expect(
		turret.configure(&"ATMongooseMissile"),
		"ATMongooseMissile must resolve its rules-backed presentation"
	)
	_expect(turret.bind_model(model, 0), "the Mongoose launcher must bind its authored markers")
	_expect(
		turret.muzzle_flash_id == &"Muzzle3" and turret.muzzle_flash_scene != null,
		"the Mongoose must resolve its authored Muzzle3 front flash"
	)
	_expect(
		turret.impact_visual_scenes.has(&"MissileHit"),
		"HEAT_B must resolve ExplosionType=MissileHit through ArtIni"
	)

	var emission := turret.peek_emission()
	var smoke_node := emission.get("smoke_node") as Node3D
	_expect(
		smoke_node != null
		and String(smoke_node.get_meta("original_name", "")) == "#smoke",
		"the >>0#flame launcher must pair with its sibling #smoke backblast marker"
	)
	var target_position := Vector3(emission["position"]) \
		+ Vector3(emission["direction"]) * 10.0
	target_position.y = 0.0
	_expect(
		turret.aim_at(target_position, 1.0 / 60.0),
		"the yaw-only Mongoose launcher must accept a ground point ahead"
	)
	var projectiles: Array = turret.try_fire_at(target_position, model, root)
	_expect(projectiles.size() == 1, "the Mongoose launch must emit one HEAT_B missile")
	if projectiles.is_empty():
		model.free()
		return
	var fired_emission: Dictionary = turret.last_emissions()[0]

	var front_flashes := _muzzle_effects(&"front_flash")
	var launch_smokes := _muzzle_effects(&"launch_smoke", 0)
	var shot_lights := _muzzle_effects(&"shot_light", 0)
	_expect(
		front_flashes.size() == 1
		and front_flashes[0].global_position.is_equal_approx(
			Vector3(fired_emission["position"])
		),
		"one Muzzle3 flash must spawn at the Mongoose's >>0#flame marker"
	)
	var muzzle3_mesh := front_flashes[0].find_child(
		"Mesh_00_Visual", true, false
	) as MeshInstance3D if front_flashes.size() == 1 else null
	_expect(
		muzzle3_mesh != null
		and muzzle3_mesh.scale.is_equal_approx(Vector3.ONE * 0.5),
		"Muzzle3 must render its oversized Mesh_00 at half scale"
	)
	_expect(
		launch_smokes.size() == 1
		and launch_smokes[0].global_position.is_equal_approx(
			Vector3(fired_emission["smoke_position"])
		),
		"the original !cexp launch backblast must spawn at #smoke"
	)
	_expect(
		launch_smokes.size() == 1
		and launch_smokes[0].get_node_or_null("Visual") is MeshInstance3D,
		"the Mongoose backblast must render as an additive animated billboard"
	)
	_expect(
		shot_lights.size() == 1
		and (shot_lights[0] as OmniLight3D).light_energy > 0.0,
		"the launch event must briefly illuminate the launcher"
	)

	var projectile = projectiles[0]
	projectile.advance(1.0)
	var missile_hits := _impact_effects(&"MissileHit")
	var missile_hit: Node3D = missile_hits.front() if not missile_hits.is_empty() else null
	_expect(
		projectile.finish_reason == &"impact_ground"
		and missile_hits.size() == 1
		and missile_hit.global_position.is_equal_approx(target_position),
		"one MissileHit composition must spawn at the resolved ground impact"
	)
	var impact_visual := missile_hit.get_node_or_null("Visual") as Node3D \
		if missile_hit != null else null
	var emitter_meshes := impact_visual.find_children(
		"*", "MeshInstance3D", true, false
	) if impact_visual != null else []
	var emitter_geometry_hidden := not emitter_meshes.is_empty()
	for emitter_mesh in emitter_meshes:
		emitter_geometry_hidden = emitter_geometry_hidden \
			and not (emitter_mesh as MeshInstance3D).visible
	_expect(
		emitter_geometry_hidden,
		"MissileHit's #bing cubes must remain hidden emitter helpers"
	)
	await process_frame
	var particle_counts := {
		&"!%Bru": 0,
		&"!cexp": 0,
		&"!@sm": 0,
	}
	var particle_nodes := missile_hit.find_children(
		"ImpactParticle_*", "Node3D", true, false
	) if missile_hit != null else []
	for child in particle_nodes:
		var sequence := StringName(String(child.get_meta("combat_impact_particle", "")))
		if particle_counts.has(sequence):
			particle_counts[sequence] += 1
	_expect(
		particle_counts[&"!%Bru"] == 1
		and particle_counts[&"!cexp"] == 0
		and particle_counts[&"!@sm"] == 32,
		"MissileHit must retain its loose shrapnel spray and add one particle ring"
	)
	var ring_velocities: Array[Vector3] = []
	var loose_shrapnel_count := 0
	for child in particle_nodes:
		if child.get_meta("combat_impact_ring", false):
			ring_velocities.append(Vector3(
				child.get_meta("combat_impact_velocity", Vector3.ZERO)
			))
		elif child.get_meta("combat_impact_particle", &"") == &"!@sm":
			loose_shrapnel_count += 1
	var ring_is_randomized := ring_velocities.size() == 16
	var differs_from_even_spacing := false
	for velocity_index in ring_velocities.size():
		var expected_angle := TAU * float(velocity_index) / float(ring_velocities.size())
		var expected_direction := Vector3(sin(expected_angle), 0.0, cos(expected_angle))
		var horizontal_velocity := ring_velocities[velocity_index]
		horizontal_velocity.y = 0.0
		differs_from_even_spacing = differs_from_even_spacing \
			or horizontal_velocity.normalized().dot(expected_direction) < 0.99
		ring_is_randomized = (
			ring_is_randomized
			and not horizontal_velocity.is_zero_approx()
			and is_equal_approx(
				ring_velocities[velocity_index].y, ring_velocities[0].y
			)
		)
	_expect(
		loose_shrapnel_count == 16,
		"MissileHit must preserve the original independent shrapnel spray"
	)
	_expect(
		ring_is_randomized and differs_from_even_spacing,
		"MissileHit ring points must share one radius but use randomized angles"
	)
	var impact_light := missile_hit.get_node_or_null("ImpactLight") as OmniLight3D \
		if missile_hit != null else null
	_expect(
		impact_light != null and impact_light.light_energy > 0.0,
		"MissileHit must briefly illuminate the impact area"
	)

	if is_instance_valid(projectile):
		projectile.free()
	_free_muzzle_effects()
	_free_impact_effects()
	model.free()


func _test_compound_turret() -> void:
	var rules = root.get_node("Rules")
	var model := ATAPCModelScene.instantiate() as Node3D
	root.add_child(model)
	var turret = CombatTurretScript.new()
	_expect(
		turret.configure(&"ATAPCBase"),
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
	_free_muzzle_effects()
	_free_impact_effects()
	var turret = CombatTurretScript.new()
	_expect(
		turret.configure(&"ATInfGun"),
		"ATInfGun must remain a configured fixed weapon"
	)
	_expect(
		turret.muzzle_flash_id == &"Smuzz2" and turret.muzzle_flash_scene != null,
		"ATInfGun must retain its rules TurretMuzzleFlash for models without an embedded flash"
	)
	_expect(
		turret.impact_visual_scenes.has(&"Mghit"),
		"LMG_B must resolve its rules ExplosionType=mghit through ArtIni"
	)
	_expect(turret.bind_model(model, 0), "the infantry weapon marker must bind")
	_expect(turret.is_fixed(), "a turret without X/Y rotation speeds must be fixed")
	_expect(turret.requires_hull_turn(), "a fixed weapon must require owner-body alignment")
	var emission := turret.peek_emission()
	var side_target: Vector3 = emission["position"] + Vector3.RIGHT * 100.0
	_expect(not turret.aim_at(side_target, 10.0), "a fixed weapon must not rotate to a side target")
	_expect(is_zero_approx(turret.current_yaw_degrees()), "a fixed weapon's yaw must stay at rest")
	_expect(is_zero_approx(turret.current_pitch_degrees()), "a fixed weapon's pitch must stay at rest")

	var target_position: Vector3 = Vector3(emission["position"]) \
		+ Vector3(emission["direction"]) * 5.0
	var projectiles: Array = turret.try_fire_at(target_position, model, root)
	_expect(projectiles.size() == 1, "ATInfGun must emit its conceptual LMG_B shot")
	_expect(
		root.get_node_or_null("MuzzleFlash_Smuzz2") == null
		and _muzzle_effects(&"shot_light").is_empty(),
		"AT Infantry Fire_0 must use only its embedded muzzle flash"
	)
	var impacts := _impact_effects(&"Mghit")
	_expect(
		impacts.size() == 1
		and impacts[0].global_position.is_equal_approx(target_position),
		"AT Infantry must spawn the rules-backed Mghit at its hit position"
	)
	for projectile in projectiles:
		if is_instance_valid(projectile) and not projectile.is_queued_for_deletion():
			projectile.free()
	_free_muzzle_effects()
	_free_impact_effects()
	model.free()


func _test_single_axis_turret() -> void:
	var rules = root.get_node("Rules")
	var model := ORLaserTankModelScene.instantiate() as Node3D
	root.add_child(model)
	var turret = CombatTurretScript.new()
	_expect(
		turret.configure(&"ORLaserTankBase"),
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
	turret.configure(&"ATMinotaurusBase")
	_expect(turret.bind_model(model, 0), "the Minotaurus turret root must bind")
	_expect(turret.muzzle_count() == 4, "all four descendant >> markers must be collected")
	_expect(
		turret.rear_muzzle_count() == 4,
		"all four rear #muzzle markers must pair with their sibling projectile markers"
	)
	for emission in turret.emission_points():
		_expect(
			emission.has("rear_position")
			and Vector3(emission["direction"]).dot(
				Vector3(emission["rear_direction"])
			) < -0.999,
			"a paired #muzzle emitter must point backward from its barrel"
		)
	var observed: Array[int] = []
	for index in 5:
		observed.append(int(turret.next_emission().get("index", -1)))
	_expect(observed == [0, 1, 2, 3, 0], "muzzles must cycle in marker order and wrap")
	model.free()


func _test_parallel_trajectory_salvo() -> void:
	var rules = root.get_node("Rules")
	var model := ATMinotaurusModelScene.instantiate() as Node3D
	root.add_child(model)
	var turret = CombatTurretScript.new()
	turret.configure(&"ATMinotaurusBase")
	_expect(turret.bind_model(model, 0), "the Minotaurus turret root must bind")
	var first_emission := turret.peek_emission()
	var level_forward := Vector3(first_emission["direction"])
	level_forward.y = 0.0
	level_forward = level_forward.normalized()
	var target_position := model.global_position + level_forward * 10.0
	target_position.y = Vector3(first_emission["position"]).y
	var aimed := false
	for frame in 120:
		aimed = turret.aim_at(target_position, 1.0 / 60.0)
		if aimed:
			break
	_expect(aimed, "the complete barrel group must acquire the central target")

	var emissions: Array[Dictionary] = []
	var projectiles: Array = []
	for shot in 4:
		emissions.append(turret.peek_emission())
		var fired: Array = turret.try_fire_at(
			target_position, model, root, Vector3.ZERO, false
		)
		if not fired.is_empty():
			projectiles.append(fired.front())
	_expect(
		projectiles.size() == 4,
		"all four side-by-side barrels must accept the same rigid aim pose"
	)
	if projectiles.size() == 4:
		var first_direction := Vector3(projectiles[0].direction())
		first_direction.y = 0.0
		first_direction = first_direction.normalized()
		var visible_lateral_separation := false
		for index in range(1, projectiles.size()):
			var shot_direction := Vector3(projectiles[index].direction())
			shot_direction.y = 0.0
			shot_direction = shot_direction.normalized()
			_expect(
				first_direction.dot(shot_direction) > 0.99999,
				"trajectory shells must not steer horizontally toward one point"
			)
			var muzzle_delta := (
				Vector3(emissions[index]["position"])
				- Vector3(emissions[0]["position"])
			)
			muzzle_delta.y = 0.0
			var impact_delta := (
				Vector3(projectiles[index].trajectory_impact_position())
				- Vector3(projectiles[0].trajectory_impact_position())
			)
			impact_delta.y = 0.0
			var muzzle_lateral := muzzle_delta - first_direction * muzzle_delta.dot(first_direction)
			var impact_lateral := impact_delta - first_direction * impact_delta.dot(first_direction)
			visible_lateral_separation = visible_lateral_separation \
				or muzzle_lateral.length() > 0.01
			_expect(
				muzzle_lateral.distance_to(impact_lateral) <= 0.001,
				"each shell must preserve its muzzle's lateral offset through impact"
			)
		_expect(
			visible_lateral_separation,
			"the authored Minotaurus muzzle spacing must create a lateral impact pattern"
		)
	for projectile in projectiles:
		projectile.free()
	_free_muzzle_effects()
	model.free()


func _test_limited_turret_hull_turn() -> void:
	var unit = UnitScene.instantiate()
	unit.config_id = &"ATMinotaurus"
	root.add_child(unit)
	unit.replace_visual_scene(ATMinotaurusModelScene)
	var turret = unit.combat_turrets[0]
	var emission: Dictionary = turret.peek_emission()
	var initial_hull_yaw: float = unit.global_rotation.y
	var initial_forward: Vector3 = unit.facing_direction()
	var target := CombatTarget.new(&"None")
	target.position = unit.global_position - initial_forward * 10.0
	target.position.y = Vector3(emission["position"]).y
	_expect(
		turret.requires_hull_turn_for(target.position),
		"a rear target must be outside the Minotaurus +/-45 degree turret sector"
	)

	var fired: Array = []
	unit.weapon_fired.connect(func(projectiles: Array, _target: Variant, _weapon_index: int) -> void:
		fired.append_array(projectiles)
	)
	_expect(unit.command_attack(target), "the Minotaurus must accept an in-range rear target")
	for frame in 360:
		unit._process(1.0 / 60.0)
		if not fired.is_empty():
			break
	var hull_turn := absf(angle_difference(initial_hull_yaw, unit.global_rotation.y))
	_expect(
		hull_turn > deg_to_rad(90.0),
		"the Minotaurus hull must keep turning after its turret reaches the sector limit"
	)
	_expect(
		absf(turret.current_yaw_degrees()) <= 45.01,
		"supplemental hull rotation must not push the turret beyond its authored limits"
	)
	_expect(not fired.is_empty(), "the Minotaurus must fire after hull-assisted aiming")
	for projectile in fired:
		if is_instance_valid(projectile) and not projectile.is_queued_for_deletion():
			projectile.free()
	unit.free()


func _test_turret_recenter_after_move() -> void:
	var unit = UnitScene.instantiate()
	unit.config_id = &"ATMinotaurus"
	root.add_child(unit)
	unit.replace_visual_scene(ATMinotaurusModelScene)
	var turret = unit.combat_turrets[0]
	var rest_emission: Dictionary = turret.peek_emission()
	var rest_direction: Vector3 = rest_emission["direction"]
	rest_direction.y = 0.0
	rest_direction = rest_direction.normalized()
	var target := CombatTarget.new(&"None")
	target.position = Vector3(rest_emission["position"]) \
		+ rest_direction.rotated(Vector3.UP, deg_to_rad(30.0)) * 10.0

	_expect(unit.command_attack(target), "the Minotaurus must accept the side target")
	for frame in 4:
		unit._process(1.0 / 20.0)
	var attack_yaw := absf(turret.current_yaw_degrees())
	_expect(
		is_equal_approx(attack_yaw, 20.0),
		"four rule updates must turn the Minotaurus turret by four 5-degree steps"
	)

	unit.move_to(unit.global_position + rest_direction * 10.0)
	_expect(not unit.has_attack_order(), "a move order must replace the attack order")
	var player := unit.get_node("VisualRoot").find_child(
		"AnimationPlayer", true, false
	) as AnimationPlayer
	if player != null:
		# Reproduce the normal frame order: authored Move pose first, then Unit
		# combat logic restores its continuously changing servo pose.
		player.advance(1.0 / 60.0)
	unit._process(1.0 / 60.0)
	var returning_yaw := absf(turret.current_yaw_degrees())
	_expect(
		returning_yaw < attack_yaw and returning_yaw > 0.0,
		"the first movement frame must begin returning the turret instead of snapping or caching it"
	)
	_expect(
		absf(returning_yaw - (attack_yaw - 5.0 / 3.0)) < 0.01,
		"recentring must use the Minotaurus authored 5 degrees per 20 Hz update"
	)
	var returning_direction: Vector3 = turret.peek_emission()["direction"]
	_expect(
		absf(
			rad_to_deg(_horizontal_angle_between(rest_direction, returning_direction))
			- returning_yaw
		) < 0.1,
		"the visible turret pose and its logical servo angle must remain synchronized"
	)

	_expect(unit.command_attack(target), "the side target must remain attackable after moving")
	unit._process(1.0 / 60.0)
	var reacquired_direction: Vector3 = turret.peek_emission()["direction"]
	_expect(
		rad_to_deg(_horizontal_angle_between(returning_direction, reacquired_direction))
			<= 5.0 / 3.0 + 0.1,
		"a repeated attack order must resume from the visible pose without restoring a cached yaw"
	)
	unit.free()


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


func _test_unit_attack_order() -> void:
	var unit = UnitScene.instantiate()
	unit.config_id = &"ATAPC"
	root.add_child(unit)
	unit.replace_visual_scene(ATAPCModelScene)
	var emission: Dictionary = unit.turret_emission_points()[0]
	var direction: Vector3 = emission["direction"]
	var target := CombatTarget.new(&"None")
	target.position = Vector3(emission["position"]) + direction * 5.0
	var aircraft := CombatTarget.new(&"Aircraft", true)
	aircraft.position = target.position
	_expect(unit.can_attack(target), "an armed APC must accept a compatible ground target")
	_expect(not unit.can_attack(aircraft), "the APC must reject a target its bullet cannot hit")
	_expect(not unit.command_attack(aircraft), "an incompatible target must not create an attack order")
	_expect(
		unit.combat_turrets[0].target_range(target) == CombatTurretScript.TargetRange.IN_RANGE,
		"the compatible target must start inside the APC weapon range"
	)

	var fired_batches: Array = []
	unit.weapon_fired.connect(func(projectiles: Array, fired_target: Variant, weapon_index: int) -> void:
		fired_batches.append({
			"projectiles": projectiles,
			"target": fired_target,
			"weapon_index": weapon_index,
		})
	)
	_expect(unit.command_attack(target), "a compatible target must create an attack order")
	_expect(unit.has_attack_order() and unit.attack_order_target() == target, "the live target must remain attached to the order")
	for frame in 240:
		unit._process(1.0 / 60.0)
		if not fired_batches.is_empty():
			break
	_expect(fired_batches.size() == 1, "an aimed in-range order must fire the compatible weapon")
	if not fired_batches.is_empty():
		_expect(fired_batches[0]["target"] == target, "the fired batch must retain the ordered target")
		_expect(fired_batches[0]["weapon_index"] == 0, "the primary APC weapon must execute the order")

	unit.cancel_attack_order()
	var far_ground := Vector3(emission["position"]) + direction * 30.0
	_expect(unit.command_attack(far_ground), "attack-ground validity must not depend on current range")
	unit._process(0.01)
	_expect(
		Vector2(unit.target_position.x, unit.target_position.z).is_equal_approx(
			Vector2(far_ground.x, far_ground.z)
		),
		"an out-of-range attack order must pursue its target coordinate"
	)
	unit.move_to(unit.global_position + Vector3.RIGHT)
	_expect(not unit.has_attack_order(), "a later ordinary movement order must cancel attack")

	var mongoose = UnitScene.instantiate()
	mongoose.config_id = &"ATMongoose"
	root.add_child(mongoose)
	mongoose.replace_visual_scene(ATMongooseModelScene)
	var mongoose_emission: Dictionary = mongoose.turret_emission_points()[0]
	var mongoose_forward: Vector3 = Vector3(mongoose_emission["direction"])
	mongoose_forward.y = 0.0
	var mongoose_side := mongoose_forward.normalized().rotated(Vector3.UP, PI * 0.5)
	unit.global_position = mongoose.global_position + mongoose_side * 25.0
	_expect(
		unit.combat_aim_position().y > unit.global_position.y,
		"a real unit target must expose an aim point inside its body rather than at ground level"
	)
	var mongoose_fired: Array = []
	mongoose.weapon_fired.connect(func(projectiles: Array, _target: Variant, _weapon_index: int) -> void:
		mongoose_fired.append_array(projectiles)
	)
	_expect(mongoose.command_attack(unit), "a Mongoose must accept a real allied ground unit as a forced target")
	_expect(
		mongoose.combat_turrets[0].target_range(unit) == CombatTurretScript.TargetRange.TOO_FAR,
		"the real-unit regression must begin outside the Mongoose weapon range"
	)
	for frame in 240:
		mongoose._process(1.0 / 60.0)
		mongoose._physics_process(1.0 / 60.0)
		if not mongoose_fired.is_empty():
			break
	_expect(
		not mongoose_fired.is_empty(),
		"a pursuing Mongoose must stop at range and fire its yaw-only turret at a real unit"
	)
	var mongoose_player := mongoose.get_node("VisualRoot").find_child(
		"AnimationPlayer", true, false
	) as AnimationPlayer
	_expect(
		mongoose_player != null and mongoose_player.current_animation == &"Fire_0",
		"the Mongoose shot must occur inside its authored Fire_0 animation"
	)
	_expect(
		mongoose.combat_turrets[0].reload_ticks_remaining > 0.0
		and mongoose.combat_turrets[0].reload_ticks_remaining < 30.0,
		"Mongoose ReloadCount must advance alongside Fire_0"
	)
	var mongoose_refire_elapsed := 0.0
	for frame in 60:
		mongoose._process(1.0 / 60.0)
		mongoose_refire_elapsed += 1.0 / 60.0
	_expect(
		mongoose_fired.size() == 1,
		"the Mongoose must not fire again while its first Fire_0 animation is active"
	)
	for frame in 60:
		mongoose._process(1.0 / 60.0)
		mongoose_refire_elapsed += 1.0 / 60.0
		if mongoose_fired.size() >= 2:
			break
	_expect(
		mongoose_fired.size() == 2
		and absf(mongoose_refire_elapsed - 30.0 / UnitScript.RULE_COMBAT_TICKS_PER_SECOND) \
			<= 1.0 / 30.0,
		"Mongoose shots must be separated by ReloadCount, not Fire_0 plus ReloadCount"
	)

	var infantry = UnitScene.instantiate()
	infantry.config_id = &"ATInfantry"
	root.add_child(infantry)
	infantry.replace_visual_scene(ATInfantryModelScene)
	var infantry_emission: Dictionary = infantry.turret_emission_points()[0]
	var infantry_forward: Vector3 = Vector3(infantry_emission["direction"])
	var infantry_target: Vector3 = Vector3(infantry_emission["position"]) \
		+ infantry_forward.normalized() * 5.0
	var infantry_fired: Array = []
	infantry.weapon_fired.connect(func(projectiles: Array, _target: Variant, _weapon_index: int) -> void:
		infantry_fired.append_array(projectiles)
	)
	_expect(
		infantry.command_attack(infantry_target),
		"Atreides Infantry must accept an in-range ground target"
	)
	for frame in 240:
		infantry._process(1.0 / 60.0)
		if not infantry_fired.is_empty():
			break
	_expect(not infantry_fired.is_empty(), "Atreides Infantry must emit its authored shot")
	_expect(
		infantry.combat_turrets[0].has_authored_fire_fx(),
		"Fire_0 must start its casing timeline even with an embedded muzzle flash"
	)
	_expect(
		is_zero_approx(infantry.combat_turrets[0].reload_ticks_remaining),
		"infantry ReloadCount must remain deferred during its full-body Fire_0 action"
	)
	var infantry_refire_elapsed := 0.0
	for frame in 240:
		infantry._process(1.0 / 60.0)
		infantry_refire_elapsed += 1.0 / 60.0
		if not infantry._fire_sequence_active:
			break
	_expect(
		is_equal_approx(infantry.combat_turrets[0].reload_ticks_remaining, 30.0),
		"infantry ReloadCount must begin after its full-body Fire_0 action"
	)
	for frame in 120:
		infantry._process(1.0 / 60.0)
		infantry_refire_elapsed += 1.0 / 60.0
		if infantry_fired.size() >= 2:
			break
	_expect(
		infantry_fired.size() == 2
		and absf(
			infantry_refire_elapsed
			- (45.0 + 30.0) / UnitScript.RULE_COMBAT_TICKS_PER_SECOND
		) <= 1.0 / 30.0,
		"Atreides Infantry shots must combine its 45-frame action and 30-tick reload"
	)

	var minotaurus = UnitScene.instantiate()
	minotaurus.config_id = &"ATMinotaurus"
	root.add_child(minotaurus)
	minotaurus.replace_visual_scene(ATMinotaurusModelScene)
	var minotaurus_emission: Dictionary = minotaurus.turret_emission_points()[0]
	var minotaurus_forward: Vector3 = Vector3(minotaurus_emission["direction"])
	minotaurus_forward.y = 0.0
	unit.global_position = minotaurus.global_position \
		+ minotaurus_forward.normalized().rotated(Vector3.UP, deg_to_rad(30.0)) * 10.0
	var minotaurus_fired: Array = []
	var minotaurus_fire_animations: Array[StringName] = []
	var minotaurus_player := minotaurus.get_node("VisualRoot").find_child(
		"AnimationPlayer", true, false
	) as AnimationPlayer
	minotaurus.weapon_fired.connect(func(projectiles: Array, _target: Variant, _weapon_index: int) -> void:
		minotaurus_fired.append_array(projectiles)
		minotaurus_fire_animations.append(minotaurus_player.current_animation)
	)
	_expect(
		minotaurus.command_attack(unit),
		"a Minotaurus must accept a real allied ground unit as a forced target"
	)
	for frame in 240:
		minotaurus._process(1.0 / 60.0)
		if not minotaurus_fired.is_empty():
			break
	_expect(
		absf(minotaurus.combat_turrets[0].current_yaw_degrees()) > 1.0,
		"a Minotaurus attack order against a real unit must turn its compound turret"
	)
	_expect(
		not minotaurus_fired.is_empty(),
		"a compound Minotaurus turret must fire at a real unit after completing its aim"
	)
	var minotaurus_visible_yaw := rad_to_deg(_horizontal_angle_between(
		minotaurus_forward,
		Vector3(minotaurus.combat_turrets[0].peek_emission()["direction"])
	))
	_expect(
		absf(minotaurus_visible_yaw - absf(
			minotaurus.combat_turrets[0].current_yaw_degrees()
		)) < 0.1,
		"starting Fire_0 must preserve the Minotaurus visual turret yaw"
	)
	_expect(
		minotaurus.combat_turrets[0].reload_ticks_remaining > 0.0
		and minotaurus.combat_turrets[0].reload_ticks_remaining < 120.0,
		"Minotaurus ReloadCount must advance during its four-shot Fire_0 animation"
	)
	for frame in 120:
		minotaurus._process(1.0 / 60.0)
		if not minotaurus._fire_sequence_active:
			break
	_expect(
		minotaurus_fired.size() == 4,
		"the Minotaurus Fire_0 animation must emit one shell from each of its four muzzles"
	)
	_expect(
		minotaurus_fire_animations == [&"Fire_0", &"Fire_0", &"Fire_0", &"Fire_0"],
		"all four Minotaurus shells must belong to one authored firing animation"
	)
	_expect(
		absf(
			minotaurus.combat_turrets[0].reload_ticks_remaining
			- (120.0 - minotaurus_player.get_animation(&"Fire_0").length \
				* UnitScript.BAKED_MODEL_FRAMES_PER_SECOND)
		) <= 0.5,
		"the Minotaurus salvo animation must consume the matching part of ReloadCount"
	)
	minotaurus_visible_yaw = rad_to_deg(_horizontal_angle_between(
		minotaurus_forward,
		Vector3(minotaurus.combat_turrets[0].peek_emission()["direction"])
	))
	_expect(
		absf(minotaurus_visible_yaw - absf(
			minotaurus.combat_turrets[0].current_yaw_degrees()
		)) < 0.1,
		"returning to Stationary after Fire_0 must preserve the Minotaurus visual turret yaw"
	)

	for batch in fired_batches:
		for projectile in batch["projectiles"]:
			if is_instance_valid(projectile) and not projectile.is_queued_for_deletion():
				projectile.free()
	for projectile in mongoose_fired:
		if is_instance_valid(projectile) and not projectile.is_queued_for_deletion():
			projectile.free()
	for projectile in infantry_fired:
		if is_instance_valid(projectile) and not projectile.is_queued_for_deletion():
			projectile.free()
	for projectile in minotaurus_fired:
		if is_instance_valid(projectile) and not projectile.is_queued_for_deletion():
			projectile.free()
	mongoose.free()
	infantry.free()
	minotaurus.free()
	unit.free()


func _test_launcher_fire_sequences() -> void:
	var definitions := [
		[&"HKMissile", HKMissileModelScene],
		[&"ORAPC", ORAPCModelScene],
		[&"HKDevastator", HKDevastatorModelScene],
	]
	for definition in definitions:
		var launcher = UnitScene.instantiate()
		launcher.config_id = definition[0]
		root.add_child(launcher)
		launcher.replace_visual_scene(definition[1])
		var player := launcher.get_node("VisualRoot").find_child(
			"AnimationPlayer", true, false
		) as AnimationPlayer
		var animation := player.get_animation(&"Fire_0")
		for turret in launcher.combat_turrets:
			var shot_times: Array[float] = launcher._authored_fire_shot_times(player, animation, turret)
			var configured_count := int(turret.firing_config.burst_shot_count)
			_expect(
				configured_count == turret.muzzle_count(),
				"%s weapon %d must explicitly configure every launcher projectile" % [
					definition[0], turret.weapon_index()
				]
			)
			_expect(
				shot_times.size() == configured_count,
				"%s weapon %d must schedule every configured burst shot" % [
					definition[0], turret.weapon_index()
				]
			)
			if shot_times.size() >= 2:
				_expect(
					is_equal_approx(
						shot_times[1] - shot_times[0],
						float(turret.firing_config.burst_interval_ticks) \
							/ UnitScript.RULE_COMBAT_TICKS_PER_SECOND
					),
					"%s weapon %d must use its configured burst interval" % [
						definition[0], turret.weapon_index()
					]
				)
			_expect(
				shot_times.back() <= animation.length,
				"%s weapon %d must complete its burst inside Fire_0" % [
					definition[0], turret.weapon_index()
				]
			)
		launcher.free()


func _test_far_attack_pursuit() -> void:
	var attacker = UnitScene.instantiate()
	attacker.config_id = &"ATMinotaurus"
	root.add_child(attacker)
	attacker.replace_visual_scene(ATMinotaurusModelScene)
	var target = UnitScene.instantiate()
	target.config_id = &"ATAPC"
	root.add_child(target)
	target.replace_visual_scene(ATAPCModelScene)
	var emission: Dictionary = attacker.combat_turrets[0].peek_emission()
	var forward: Vector3 = Vector3(emission["direction"])
	forward.y = 0.0
	target.global_position = attacker.global_position + forward.normalized() * 45.0

	var fired: Array = []
	attacker.weapon_fired.connect(func(projectiles: Array, _target: Variant, _weapon_index: int) -> void:
		fired.append_array(projectiles)
	)
	_expect(
		attacker.combat_turrets[0].target_range(target)
			== CombatTurretScript.TargetRange.TOO_FAR,
		"the pursuit regression must begin beyond the Minotaurus maximum range"
	)
	_expect(attacker.command_attack(target), "the Minotaurus must accept the distant target")
	for frame in 1200:
		attacker._process(1.0 / 60.0)
		attacker._physics_process(1.0 / 60.0)
		if not fired.is_empty():
			break
	_expect(
		not fired.is_empty(),
		"a Minotaurus that pursued a distant target must eventually emit its salvo"
	)

	for projectile in fired:
		if is_instance_valid(projectile) and not projectile.is_queued_for_deletion():
			projectile.free()
	attacker.free()
	target.free()


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


func _test_building_damage_visual_states() -> void:
	var turret = HKGunTurretScene.instantiate() as Building
	root.add_child(turret)
	_expect(turret.current_state == &"idle", "a healthy building must use Idle")
	turret.health = turret.max_health * (2.0 / 3.0)
	_expect(turret.current_state == &"damage1", "the second of three equal health bands must use Damage1")
	turret.health = turret.max_health * (1.0 / 3.0)
	_expect(turret.current_state == &"damage2", "the final health band must use Damage2")
	turret.health = turret.max_health
	_expect(turret.current_state == &"idle", "restoring full health must return to Idle")
	turret.free()

	var wall = ATWallScene.instantiate() as Building
	root.add_child(wall)
	_expect(wall.get_node_or_null("States/Damage1") == null, "fixture must cover a missing Damage1 state")
	wall.health = wall.max_health * 0.5
	_expect(
		wall.current_state == &"damage2",
		"a sole Damage2 state must be the damaged band rather than requiring Damage1"
	)
	wall.free()


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


func _runtime_bullet(_rules: Object, bullet_id: StringName):
	var config: Resource = _combat_catalog.bullet(bullet_id)
	var warhead_id: StringName = config.warhead_id if config != null else &""
	var warhead_config: Resource = _combat_catalog.warhead(warhead_id) if warhead_id != &"" else null
	return CombatBulletScript.new(config, warhead_config)


func _emission(position: Vector3, direction: Vector3) -> Dictionary:
	return {
		"position": position,
		"direction": direction.normalized(),
	}
