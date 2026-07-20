class_name CombatWarhead
extends RefCounted

## Runtime view of the armour matrix stored by WarheadConfig. A warhead does
## not own the base damage: that value belongs to the bullet which delivers it.

var config: Resource


func _init(warhead_config: Resource = null) -> void:
	config = warhead_config


func damage_percent_for(armour_type: StringName) -> float:
	if config == null or String(armour_type).is_empty():
		return 0.0
	var matrix: Variant = config.field(&"armour_damage", {})
	if not matrix is Dictionary:
		return 0.0
	return maxf(float((matrix as Dictionary).get(String(armour_type), 0.0)), 0.0)


func damage_for(base_damage: float, armour_type: StringName) -> float:
	return maxf(base_damage, 0.0) * damage_percent_for(armour_type) / 100.0
