class_name CombatBullet
extends RefCounted

const CombatWarheadScript := preload("res://scripts/combat/combat_warhead.gd")

## BulletConfig describes delivery (range, speed, targeting flags and damage),
## while CombatWarhead resolves that damage against the target's armour.

var config: Resource
var warhead


func _init(bullet_config: Resource = null, warhead_config: Resource = null) -> void:
	config = bullet_config
	warhead = CombatWarheadScript.new(warhead_config)


func base_damage() -> float:
	return maxf(float(config.field(&"damage", 0.0)), 0.0) if config != null else 0.0


func maximum_range() -> float:
	return maxf(float(config.field(&"max_range", 0.0)), 0.0) if config != null else 0.0


func is_hitscan() -> bool:
	if config == null:
		return false
	return bool(config.field(&"is_laser", false)) or float(config.field(&"speed", 0.0)) < 0.0


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


func damage_against(armour_type: StringName) -> float:
	# Leech_B and Contaminator_B intentionally have Damage but no Warhead:
	# their typed infection effect is a bullet property, and Damage is the
	# direct fallback for targets that cannot receive that effect.
	if warhead == null or warhead.config == null:
		return base_damage()
	return warhead.damage_for(base_damage(), armour_type)


func impact(target: Object) -> float:
	if not can_hit(target):
		return 0.0
	if not target.has_method("combat_armour_type") or not target.has_method("take_damage"):
		return 0.0
	var armour_type := StringName(String(target.call("combat_armour_type")))
	var damage := damage_against(armour_type)
	if damage <= 0.0:
		return 0.0
	target.call("take_damage", damage)
	return damage
