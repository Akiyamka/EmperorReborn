class_name CombatTargetAcquisition
extends RefCounted

## Picks what an idle turret shoots at on its own: the nearest live enemy in
## range with a line of fire, cached per weapon and re-picked at most every
## AUTO_TARGET_REFRESH_SECONDS.
##
## Shared by Unit and BuildingCombat — this is the one part of their combat
## drivers that was byte-identical, everything around it (pursuit and repath
## for a mobile shooter, the popup transition for a static one) is not.
##
## Holds no model nodes: the cache is weak references to other entities, so a
## target freed between two ticks simply reads back as null.

const CombatTargetScript := preload("res://scripts/combat/combat_target.gd")
const CombatTurretScript := preload("res://scripts/combat/combat_turret.gd")

const AUTO_TARGET_REFRESH_SECONDS := 0.25

var _shooter: Node3D
var _targets: Dictionary = {}
var _cooldowns: Dictionary = {}


func configure(shooter: Node3D) -> void:
	_shooter = shooter


func dispose() -> void:
	clear()
	_shooter = null


func clear() -> void:
	_targets.clear()
	_cooldowns.clear()


func forget(weapon_index: int) -> void:
	_targets.erase(weapon_index)
	_cooldowns.erase(weapon_index)


func advance(delta: float) -> void:
	for weapon_index: Variant in _cooldowns.keys():
		var remaining := maxf(float(_cooldowns[weapon_index]) - maxf(delta, 0.0), 0.0)
		if remaining <= 0.0:
			_cooldowns.erase(weapon_index)
		else:
			_cooldowns[weapon_index] = remaining


## The cached target while it stays usable, otherwise a fresh scan — but only
## once the per-weapon cooldown has expired, so a shooter with nothing to
## shoot at does not walk both entity groups every frame.
func target_for(turret) -> Variant:
	if turret == null or _shooter == null:
		return null
	var weapon_index: int = turret.weapon_index()
	var cached_ref: WeakRef = _targets.get(weapon_index) as WeakRef
	var cached: Variant = cached_ref.get_ref() if cached_ref != null else null
	if is_usable(turret, cached):
		return cached
	if float(_cooldowns.get(weapon_index, 0.0)) > 0.0:
		return null
	_cooldowns[weapon_index] = AUTO_TARGET_REFRESH_SECONDS
	var tree := _shooter.get_tree()
	if tree == null:
		return null

	var best_target: Node3D = null
	var best_distance := INF
	var candidates: Array[Node] = []
	candidates.append_array(tree.get_nodes_in_group(&"units"))
	candidates.append_array(tree.get_nodes_in_group(&"buildings"))
	for candidate_node in candidates:
		if not candidate_node is Node3D or candidate_node == _shooter:
			continue
		var candidate := candidate_node as Node3D
		if not is_usable(turret, candidate):
			continue
		var distance := _shooter.global_position.distance_squared_to(candidate.global_position)
		# Instance id breaks ties so two equidistant candidates resolve the
		# same way on every shooter, instead of by group iteration order.
		if distance < best_distance \
		or (
			is_equal_approx(distance, best_distance)
			and best_target != null
			and candidate.get_instance_id() < best_target.get_instance_id()
		):
			best_distance = distance
			best_target = candidate
	if best_target == null:
		_targets.erase(weapon_index)
		return null
	_targets[weapon_index] = weakref(best_target)
	return best_target


func is_usable(turret, target: Variant) -> bool:
	if not target is Node3D or not is_instance_valid(target):
		return false
	var candidate := target as Node3D
	if not CombatTargetScript.is_alive(candidate) \
	or not candidate.has_method("is_enemy_of") \
	or not bool(candidate.call("is_enemy_of", _shooter.owner_player_id)):
		return false
	if turret.target_range(candidate) != CombatTurretScript.TargetRange.IN_RANGE:
		return false
	var target_world_position := CombatTargetScript.position_of(
		candidate, _shooter.global_position
	)
	return target_world_position.is_finite() \
		and not turret.requires_hull_turn_for(target_world_position) \
		and turret.has_line_of_fire(candidate, _shooter)
