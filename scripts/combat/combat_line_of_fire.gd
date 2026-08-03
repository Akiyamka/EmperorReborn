class_name CombatLineOfFire
extends RefCounted

## Decides whether a flat-flying shot can reach a point at all. CombatProjectile
## sweeps terrain and building colliders while it travels, so a target that sits
## inside weapon range but behind a cliff shoulder or a building is unhittable
## from the shooter's current position: the shell detonates on the obstacle
## instead. Order handling asks this before firing so the unit repositions.
##
## Units are pierced rather than treated as obstacles. They move on their own,
## and a passing vehicle crossing the line must not make an engaged unit
## abandon a target it can already hit.

const BLOCKER_COLLISION_MASK := 3
const TERRAIN_COLLISION_LAYER := 1
## An attack-ground aim point lies on the terrain surface itself. Stopping the
## probe short of it keeps the destination ground from counting as its own
## obstacle; one rules tile spans 2.0 world units, so this is a quarter tile.
const TARGET_CLEARANCE_WORLD := 0.5
const MAX_PIERCED_COLLIDERS := 8


static func is_clear(
		world: World3D,
		from: Vector3,
		to: Vector3,
		ignored: Array = []
	) -> bool:
	if world == null or not from.is_finite() or not to.is_finite():
		return true
	var offset := to - from
	var distance := offset.length()
	if distance <= TARGET_CLEARANCE_WORLD:
		return true
	var probe_end := from + offset / distance * (distance - TARGET_CLEARANCE_WORLD)
	var excludes: Array[RID] = []
	for candidate: Variant in ignored:
		_collect_collision_rids(candidate as Object, excludes)
	for index in MAX_PIERCED_COLLIDERS:
		var query := PhysicsRayQueryParameters3D.create(
			from, probe_end, BLOCKER_COLLISION_MASK, excludes
		)
		query.collide_with_areas = false
		query.collide_with_bodies = true
		var hit := world.direct_space_state.intersect_ray(query)
		if hit.is_empty():
			return true
		var rid: RID = hit.get("rid", RID())
		if not rid.is_valid():
			return true
		if _obstructs(hit.get("collider") as Object):
			return false
		excludes.append(rid)
	return true


static func _obstructs(collider: Object) -> bool:
	var body := collider as CollisionObject3D
	if body == null or bool(body.get_meta("combat_ignore", false)):
		return false
	if (body.collision_layer & TERRAIN_COLLISION_LAYER) != 0:
		return true
	# Buildings and walls share the entity collision layer with units. The
	# footprint hull they expose identifies them from combat code without
	# depending on the buildings module.
	var entity := _combat_entity(body)
	return entity != null and entity.has_method("combat_hull")


static func _combat_entity(collider: Object) -> Object:
	var current := collider as Node
	while current != null:
		if current.has_method("combat_armour_type"):
			return current
		current = current.get_parent()
	return null


static func _collect_collision_rids(object: Object, result: Array[RID]) -> void:
	if object == null or not is_instance_valid(object):
		return
	if object is CollisionObject3D:
		result.append((object as CollisionObject3D).get_rid())
	if object is Node:
		for child in (object as Node).get_children():
			_collect_collision_rids(child, result)
