class_name CombatTarget
extends RefCounted

const CombatRulesScript := preload("res://scripts/combat/combat_rules.gd")


static func entity_of(collider: Object) -> Object:
	var current := collider as Node
	while current != null:
		if current.has_method("combat_armour_type"):
			return current
		current = current.get_parent()
	return null


static func position_of(target: Variant, origin := Vector3.INF) -> Vector3:
	if target is Vector3:
		return target
	if not target is Object or not is_instance_valid(target):
		return Vector3.INF
	var object := target as Object
	if origin.is_finite() and object.has_method("combat_aim_position_from"):
		var aimed: Variant = object.call("combat_aim_position_from", origin)
		if aimed is Vector3:
			return aimed
	if object.has_method("combat_aim_position"):
		var aimed: Variant = object.call("combat_aim_position")
		if aimed is Vector3:
			return aimed
	return (object as Node3D).global_position if object is Node3D else Vector3.INF


static func is_alive(target: Variant) -> bool:
	if not target is Object or not is_instance_valid(target):
		return false
	if target is Node and (target as Node).is_queued_for_deletion():
		return false
	return not target.has_method("combat_is_alive") or bool(target.call("combat_is_alive"))


static func hit_radius(
	target: Object,
	fallback: float = CombatRulesScript.DEFAULT_TARGET_HIT_RADIUS
	) -> float:
	if target != null and target.has_method("combat_hit_radius"):
		return maxf(float(target.call("combat_hit_radius")), fallback)
	return fallback


static func collision_rids(target: Object) -> Array[RID]:
	var result: Array[RID] = []
	_collect_collision_rids(target, result)
	return result


static func _collect_collision_rids(object: Object, result: Array[RID]) -> void:
	if object == null or not is_instance_valid(object):
		return
	if object is CollisionObject3D:
		result.append((object as CollisionObject3D).get_rid())
	if object is Node:
		for child in (object as Node).get_children():
			_collect_collision_rids(child, result)
