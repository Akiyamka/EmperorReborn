class_name CombatBullet
extends RefCounted

const CombatWarheadScript := preload("res://scripts/combat/combat_warhead.gd")

## One Rules.txt map tile is 32 source-model units. Converted models/maps use
## the repository-wide 1/16 scale, making a combat range tile 2 world units.
const RULE_TILE_WORLD_SPAN := 2.0
const PIERCING_BULLET_IDS: Array[StringName] = [&"Sound_B", &"SoundInf_B"]

## BulletConfig describes delivery (range, speed, targeting flags and damage),
## while CombatWarhead resolves that damage against the target's armour.

var config: Resource
var warhead
var visual_scene: PackedScene
var impact_visual_scenes: Dictionary


func _init(
		bullet_config: Resource = null,
		warhead_config: Resource = null,
		projectile_visual_scene: PackedScene = null,
		impact_effect_scenes := {}
	) -> void:
	config = bullet_config
	warhead = CombatWarheadScript.new(warhead_config)
	visual_scene = projectile_visual_scene
	impact_visual_scenes = impact_effect_scenes.duplicate()


func base_damage() -> float:
	return maxf(float(config.field(&"damage", 0.0)), 0.0) if config != null else 0.0


func maximum_range() -> float:
	return maxf(float(config.field(&"max_range", 0.0)), 0.0) if config != null else 0.0


func minimum_range() -> float:
	return maxf(float(config.field(&"min_range", 0.0)), 0.0) if config != null else 0.0


func maximum_range_world() -> float:
	return maximum_range() * RULE_TILE_WORLD_SPAN


func minimum_range_world() -> float:
	return minimum_range() * RULE_TILE_WORLD_SPAN


func speed() -> float:
	return float(config.field(&"speed", 0.0)) if config != null else 0.0


func blast_radius() -> float:
	return maxf(float(config.field(&"blast_radius", 0.0)), 0.0) if config != null else 0.0


func blast_radius_world() -> float:
	# BlastRadius is authored in source XBF units (32 is one tile), unlike
	# MaxRange/MinRange which are already expressed as tile counts.
	return blast_radius() / 16.0


func explosion_type() -> StringName:
	return StringName(String(config.field(&"explosion_type", ""))) \
		if config != null else &""


func explosion_effects() -> Array:
	return config.list(&"explosion_effects") if config != null else []


func explosion_effect_ids() -> Array[StringName]:
	var result: Array[StringName] = []
	for value in explosion_effects():
		var effect_id := StringName(String(value))
		if effect_id != &"" and effect_id not in result:
			result.append(effect_id)
	var primary_id := explosion_type()
	if result.is_empty() and primary_id != &"":
		result.append(primary_id)
	return result


func explosion_visual_scene(effect_id: StringName) -> PackedScene:
	return impact_visual_scenes.get(effect_id) as PackedScene


func friendly_damage_amount() -> float:
	return clampf(float(config.field(&"friendly_damage_amount", 0.0)), 0.0, 100.0) \
		if config != null else 0.0


func reduces_damage_with_distance() -> bool:
	# Rules.txt only spells this field out to opt out (`False`). Its absence is
	# the engine default: radial damage falls off toward the blast edge.
	return config != null and bool(config.field(&"reduce_damage_with_distance", true))


func is_hitscan() -> bool:
	# IsLaser controls presentation/accuracy; Speed=-1 is the actual source
	# representation of every conceptual (instant) bullet.
	return config != null and speed() < 0.0


func is_laser() -> bool:
	return config != null and bool(config.field(&"is_laser", false))


func is_homing() -> bool:
	return config != null and bool(config.field(&"homing", false))


func homing_delay_ticks() -> float:
	return maxf(float(config.field(&"homing_delay", 0.0)), 0.0) if config != null else 0.0


func turn_rate() -> float:
	return maxf(float(config.field(&"turn_rate", 0.0)), 0.0) if config != null else 0.0


func has_trajectory() -> bool:
	return config != null and bool(config.field(&"trajectory", false))


func has_missile_trail() -> bool:
	# Trail style zero is a valid authored value, so presence rather than
	# truthiness decides whether the engine-generated trail exists.
	return config != null and config.field(&"missile_trail", null) != null


func missile_trail_style() -> int:
	return int(config.field(&"missile_trail", 0)) if config != null else 0


func missile_trail_size() -> float:
	return maxf(float(config.field(&"missile_trail_size", 0.0)), 0.0) \
		if config != null else 0.0


func missile_trail_length() -> int:
	return maxi(int(config.field(&"missile_trail_length", 0)), 0) \
		if config != null else 0


func missile_trail_delta() -> float:
	return maxf(float(config.field(&"missile_trail_delta", 0.0)), 0.0) \
		if config != null else 0.0


func missile_trail_wiggle_frequency() -> float:
	return maxf(float(config.field(&"missile_trail_wiggle_freq", 0.0)), 0.0) \
		if config != null else 0.0


func missile_trail_wiggle_scale() -> float:
	return maxf(float(config.field(&"missile_trail_wiggle_scale", 0.0)), 0.0) \
		if config != null else 0.0


func is_continuous() -> bool:
	return config != null and bool(config.field(&"continuous", false))


func is_piercing() -> bool:
	# Rules.txt has no generic Piercing flag. Its two Sonic Tank wave entries
	# are the verified projectiles that pass through units/buildings/walls.
	return id() in PIERCING_BULLET_IDS


func effect_flags() -> Dictionary:
	var result := {}
	if config == null:
		return result
	for field_name in [
		&"burnt", &"ignites", &"gassed", &"leech", &"infantry",
		&"damage_column", &"deviate", &"beserk", &"retreat",
	]:
		var value: Variant = config.field(field_name, null)
		if value != null:
			result[String(field_name)] = bool(value)
	return result


func active_effect_flags() -> Array[StringName]:
	var result: Array[StringName] = []
	var flags := effect_flags()
	for field_name in flags:
		if bool(flags[field_name]):
			result.append(StringName(field_name))
	return result


func effect_targets_infantry() -> bool:
	return config != null and bool(config.field(&"infantry", false))


func effect_health() -> float:
	return maxf(float(config.field(&"health", 0.0)), 0.0) if config != null else 0.0


func effect_damage_per_tick() -> float:
	# Leech_B/Contaminator_B call this source field ShieldHealth. It is not the
	# projectile's shield; Rules.txt documents it as damage to the infected unit.
	return maxf(float(config.field(&"shield_health", 0.0)), 0.0) \
		if config != null else 0.0


func linger_duration_ticks() -> float:
	return maxf(float(config.field(&"linger_duration", 0.0)), 0.0) \
		if config != null else 0.0


func linger_damage() -> float:
	return maxf(float(config.field(&"linger_damage", 0.0)), 0.0) \
		if config != null else 0.0


func id() -> StringName:
	return StringName(String(config.get("id"))) if config != null else &""


func can_reach(from: Vector3, to: Vector3) -> bool:
	var offset := to - from
	var horizontal_distance := Vector2(offset.x, offset.z).length()
	return horizontal_distance + 0.0001 >= minimum_range_world() \
		and horizontal_distance <= maximum_range_world() + 0.0001


func can_hit(target: Object) -> bool:
	if config == null or target == null or not is_instance_valid(target):
		return false
	var airborne := target.has_method("combat_is_airborne") \
		and bool(target.call("combat_is_airborne"))
	if airborne:
		return bool(config.field(&"anti_aircraft", false))
	# AntiGround is opt-out in Rules.txt: almost every bullet omits it, while
	# ATHEATADP_B explicitly sets it to false for an air-only weapon.
	return bool(config.field(&"anti_ground", true))


func can_hit_ground() -> bool:
	# Attack-ground has no target object from which can_hit() could infer the
	# domain. Preserve the same opt-out semantics for coordinate targets.
	return config != null and bool(config.field(&"anti_ground", true))


func damage_against(armour_type: StringName) -> float:
	# Leech_B and Contaminator_B intentionally have Damage but no Warhead:
	# their typed infection effect is a bullet property, and Damage is the
	# direct fallback for targets that cannot receive that effect.
	if warhead == null or warhead.config == null:
		return base_damage()
	return warhead.damage_for(base_damage(), armour_type)
