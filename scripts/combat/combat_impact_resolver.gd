class_name CombatImpactResolver
extends RefCounted

## Converts one delivered CombatBullet into target mutations. CombatWarhead
## only supplies the armour percentage; Bullet owns damage, radius, falloff,
## friendly-fire and special-effect fields.

const COMBAT_COLLISION_MASK := 3
const MAX_SPLASH_COLLIDERS := 256
const DEFAULT_TARGET_HIT_RADIUS := 0.25


func resolve(
		bullet,
		world_context: Node,
		world_position: Vector3,
		direct_target: Object = null,
		source: Object = null
	) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if bullet == null or bullet.config == null:
		return results

	var candidates: Array[Object] = []
	var direct_instance_id := 0
	if _is_valid_target(direct_target):
		candidates.append(direct_target)
		direct_instance_id = direct_target.get_instance_id()

	if bullet.blast_radius_world() > 0.0:
		for candidate in _splash_targets(world_context, world_position, bullet.blast_radius_world()):
			if not _contains_object(candidates, candidate):
				candidates.append(candidate)

	for target in candidates:
		if not _can_resolve_target(bullet, target):
			continue
		var direct := target.get_instance_id() == direct_instance_id
		var result := _resolve_target(bullet, target, source, world_position, direct)
		if not result.is_empty():
			results.append(result)
	return results


func _resolve_target(
		bullet,
		target: Object,
		source: Object,
		world_position: Vector3,
		direct: bool
	) -> Dictionary:
	var armour_type := StringName(String(target.call("combat_armour_type")))
	var radius: float = float(bullet.blast_radius_world())
	var distance := 0.0 if direct else _surface_distance(target, world_position)
	if not direct and (radius <= 0.0 or distance > radius + 0.0001):
		return {}

	var distance_multiplier := 1.0
	if not direct and radius > 0.0 and bullet.reduces_damage_with_distance():
		distance_multiplier = clampf(1.0 - distance / radius, 0.0, 1.0)
	# FriendlyDamageAmount governs incidental friendly fire (splash/piercing
	# intersections). A deliberately selected direct target still receives the
	# weapon payload; otherwise Ctrl-force-fire with ordinary bullets such as
	# HEAT_B successfully launches and hits but can never damage its target.
	var friendly_multiplier := 1.0 if direct else _friendly_multiplier(bullet, source, target)
	var total_multiplier := distance_multiplier * friendly_multiplier

	var effect_context := {
		"bullet": bullet,
		"bullet_id": bullet.id(),
		"source": source,
		"world_position": world_position,
		"direct": direct,
		"distance": distance,
		"distance_multiplier": distance_multiplier,
		"friendly_multiplier": friendly_multiplier,
		"effect_health": bullet.effect_health(),
		"effect_damage_per_tick": bullet.effect_damage_per_tick(),
		"linger_duration_ticks": bullet.linger_duration_ticks(),
		"linger_damage": bullet.linger_damage(),
		"targets_infantry": bullet.effect_targets_infantry(),
	}
	var applied_effects := _apply_effects(
		target, bullet.active_effect_flags(), effect_context, total_multiplier > 0.0
	)

	var damage := 0.0
	# Infection bullets deliberately have no Warhead. Their Damage is a direct
	# fallback only when the typed Leech/Contaminator effect was rejected.
	var infection_was_applied := bullet.warhead != null \
		and bullet.warhead.config == null and &"leech" in applied_effects
	if not infection_was_applied:
		damage = bullet.damage_against(armour_type) * total_multiplier
		if damage > 0.0:
			target.call("take_damage", damage)

	return {
		"target": target,
		"damage": damage,
		"armour_type": armour_type,
		"direct": direct,
		"distance": distance,
		"distance_multiplier": distance_multiplier,
		"friendly_multiplier": friendly_multiplier,
		"effects": applied_effects,
	}


func _splash_targets(world_context: Node, world_position: Vector3, radius: float) -> Array[Object]:
	var result: Array[Object] = []
	if world_context == null or not is_instance_valid(world_context) \
		or not world_context.is_inside_tree() or not world_context is Node3D:
		return result
	var world := (world_context as Node3D).get_world_3d()
	if world == null:
		return result

	var sphere := SphereShape3D.new()
	sphere.radius = radius
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = sphere
	query.transform = Transform3D(Basis.IDENTITY, world_position)
	query.collision_mask = COMBAT_COLLISION_MASK
	query.collide_with_areas = true
	query.collide_with_bodies = true
	for hit in world.direct_space_state.intersect_shape(query, MAX_SPLASH_COLLIDERS):
		var collider: Object = hit.get("collider") as Object
		var entity := _combat_entity(collider)
		if entity != null and not _contains_object(result, entity):
			result.append(entity)
	return result


func _apply_effects(
		target: Object,
		effects: Array[StringName],
		context: Dictionary,
		allowed: bool
	) -> Array[StringName]:
	var applied: Array[StringName] = []
	# Status ownership stays with the receiver. Returning true is an explicit
	# acknowledgement that it accepted this typed Bullet effect; the resolver
	# never stores effect lifetime/state on the Warhead or projectile.
	if not allowed or not target.has_method("combat_apply_bullet_effect"):
		return applied
	for effect in effects:
		if bool(target.call("combat_apply_bullet_effect", effect, context)):
			applied.append(effect)
	return applied


func _friendly_multiplier(bullet, source: Object, target: Object) -> float:
	if not _are_friendly(source, target):
		return 1.0
	return bullet.friendly_damage_amount() / 100.0


func _are_friendly(source: Object, target: Object) -> bool:
	if source == null or not is_instance_valid(source) or target == null:
		return false
	if source == target:
		return true
	var source_owner: Variant = _owner_player_id(source)
	var target_owner: Variant = _owner_player_id(target)
	if source_owner == null or target_owner == null:
		return false
	if source.has_method("is_allied_with"):
		return bool(source.call("is_allied_with", int(target_owner)))
	# -1 is the neutral owner. Distinct neutral objects are not an allied team.
	return int(source_owner) >= 0 and int(source_owner) == int(target_owner)


func _owner_player_id(object: Object) -> Variant:
	if object.has_method("combat_owner_player_id"):
		return object.call("combat_owner_player_id")
	for property in object.get_property_list():
		if StringName(String(property.get("name", ""))) == &"owner_player_id":
			return object.get("owner_player_id")
	return null


func _can_resolve_target(bullet, target: Object) -> bool:
	return _is_valid_target(target) and _target_is_alive(target) \
		and bullet.can_hit(target) and target.has_method("combat_armour_type") \
		and target.has_method("take_damage")


func _is_valid_target(target: Object) -> bool:
	return target != null and is_instance_valid(target) \
		and (not target is Node or not (target as Node).is_queued_for_deletion())


func _target_is_alive(target: Object) -> bool:
	return not target.has_method("combat_is_alive") or bool(target.call("combat_is_alive"))


func _surface_distance(target: Object, world_position: Vector3) -> float:
	var target_position := _object_position(target)
	if not target_position.is_finite():
		return INF
	return maxf(target_position.distance_to(world_position) - _target_hit_radius(target), 0.0)


func _object_position(object: Object) -> Vector3:
	if object.has_method("combat_aim_position"):
		var value: Variant = object.call("combat_aim_position")
		if value is Vector3:
			return value
	if object is Node3D:
		return (object as Node3D).global_position
	return Vector3.INF


func _target_hit_radius(target: Object) -> float:
	if target.has_method("combat_hit_radius"):
		return maxf(float(target.call("combat_hit_radius")), DEFAULT_TARGET_HIT_RADIUS)
	return DEFAULT_TARGET_HIT_RADIUS


func _combat_entity(collider: Object) -> Object:
	var current := collider as Node
	while current != null:
		if current.has_method("combat_armour_type"):
			return current
		current = current.get_parent()
	return null


func _contains_object(objects: Array, candidate: Object) -> bool:
	for object in objects:
		if object == candidate:
			return true
	return false
