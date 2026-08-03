extends RefCounted

## Per-shot mutable data. The referenced CombatBullet is an immutable,
## turret-cached definition view shared by targeting and projectile delivery.
var definition
var damage_scale := 1.0
var config: Resource:
	get:
		return definition.config if definition != null else null


func _init(bullet_definition = null, scale := 1.0) -> void:
	definition = bullet_definition
	damage_scale = scale


func damage_against(armour_type: StringName) -> float:
	return definition.damage_against(armour_type) * damage_scale \
		if definition != null else 0.0
