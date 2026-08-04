class_name UnitAttackOrder
extends RefCounted

## The mobile shooter's explicit attack order: what was ordered, and the
## pursuit that closes the distance to it. A Node target is tracked until it
## dies; a Vector3 stays a fixed attack-ground coordinate.
##
## Deliberately not shared with Building, which has its own static driver:
## everything below is about moving — repath cadence, perch selection, backing
## a rejected route toward the unit. Only target *acquisition* is common, and
## that already lives in CombatTargetAcquisition.
##
## Holds no model nodes: the target is a weak reference to another entity.

const ATTACK_REPATH_INTERVAL_SECONDS := 0.25
const ATTACK_REPATH_DISTANCE := 0.5

var _unit: CharacterBody3D
var _active := false
var _is_ground := false
var _ground_position := Vector3.INF
var _target_ref: WeakRef
var _is_pursuing := false
var _repath_remaining := 0.0
var _last_path_position := Vector3.INF
var _pursuit_destination := Vector3.INF
var _pursuit_rejected := false


func configure(unit: CharacterBody3D) -> void:
	_unit = unit


func dispose() -> void:
	clear()
	_unit = null


func is_active() -> bool:
	return _active


func is_ground() -> bool:
	return _is_ground


func is_pursuing() -> bool:
	return _is_pursuing


func target() -> Variant:
	if not _active:
		return null
	if _is_ground:
		return _ground_position
	return _target_ref.get_ref() if _target_ref != null else null


## Records the order. The eligibility gate (can any active turret target this?)
## and the weapon bookkeeping around it belong to the facade; this is the
## state the order itself consists of.
func begin(target_or_position: Variant) -> void:
	_active = true
	_is_ground = target_or_position is Vector3
	_ground_position = target_or_position if _is_ground else Vector3.INF
	_target_ref = null if _is_ground else weakref(target_or_position as Object)
	_reset_pursuit()


## Returns true when there was an order to drop, so the caller knows whether
## to announce the change.
func clear() -> bool:
	var had_order := _active
	_active = false
	_is_ground = false
	_ground_position = Vector3.INF
	_target_ref = null
	_reset_pursuit()
	return had_order


## Called when the unit is close enough to shoot: it stops where it stands
## rather than continuing to the perch it was walking to.
func stop_pursuit() -> void:
	if not _is_pursuing:
		return
	_unit.stop_at_current_position()
	_is_pursuing = false


## Walks toward a position from which the ordered target can actually be hit,
## re-planning at most every ATTACK_REPATH_INTERVAL_SECONDS and whenever the
## target has moved far enough to invalidate the last route.
func advance_pursuit(
	target_world_position: Vector3, primary_turret, delta: float
) -> void:
	_repath_remaining = maxf(_repath_remaining - delta, 0.0)
	var target_moved := not _last_path_position.is_finite() \
		or _last_path_position.distance_to(target_world_position) >= ATTACK_REPATH_DISTANCE
	var route_unreachable: bool = _unit.navigation_route_is_unreachable()
	if target_moved:
		_pursuit_destination = Vector3.INF
		_pursuit_rejected = false
		route_unreachable = false
	if _repath_remaining > 0.0 \
	or (
		_is_pursuing
		and not target_moved
		and not route_unreachable
		and _unit.has_active_move_order()
	):
		return
	_is_pursuing = true
	_last_path_position = target_world_position
	_repath_remaining = ATTACK_REPATH_INTERVAL_SECONDS
	var pursuit_position := target_world_position
	var horizontal_offset := target_world_position - _unit.global_position
	horizontal_offset.y = 0.0
	var preferred_range := float(primary_turret.maximum_range_world()) * 0.8 \
		if primary_turret != null else 0.0
	var reachable_position := Vector3.INF
	if primary_turret != null:
		var maximum_range := float(primary_turret.maximum_range_world())
		reachable_position = _unit.navigation_reachable_attack_position(
			target_world_position, maximum_range, _line_of_fire_probe(primary_turret)
		)
		if not reachable_position.is_finite():
			var any_perch: Vector3 = _unit.navigation_reachable_attack_position(
				target_world_position, maximum_range
			)
			if any_perch.is_finite():
				# The search covered every reachable cell within weapon range and
				# none of them can see the target: the obstacle shields it from
				# this side entirely. Hold instead of grinding into it.
				_unit.stop_at_current_position()
				_is_pursuing = false
				_pursuit_destination = Vector3.INF
				return
	if reachable_position.is_finite():
		pursuit_position = reachable_position
	elif preferred_range > 0.0:
		# Navigate to a firing position rather than the target coordinate itself.
		# An attack-ground point on top of a cliff may be unreachable to a ground
		# unit even though a position in front of it is a valid artillery perch.
		# If that first perch still cannot satisfy the elevation limits, halve
		# the remaining distance on the next arrival and continue approaching.
		var remaining_distance := minf(preferred_range, horizontal_offset.length() * 0.5)
		pursuit_position = target_world_position \
			- horizontal_offset.normalized() * remaining_distance
	if (
		not reachable_position.is_finite()
		and (route_unreachable or _pursuit_rejected)
		and _pursuit_destination.is_finite()
	):
		# The requested perch landed on disconnected terrain (commonly the red
		# face or the separately connected top of a cliff). Back it toward the
		# unit until the navigation grid accepts a firing position on this side.
		pursuit_position = _unit.global_position.lerp(_pursuit_destination, 0.5)
	_pursuit_destination = pursuit_position
	var move_issued: bool = _unit.issue_attack_move(pursuit_position)
	_pursuit_rejected = not move_issued
	_is_pursuing = move_issued


## Accepts only perches whose muzzle would see the ordered target. The probe
## samples terrain height at the candidate because navigation cells carry the
## map floor rather than the elevation the unit will actually stand at.
func _line_of_fire_probe(primary_turret) -> Callable:
	var attack_target: Variant = target()
	if primary_turret == null or attack_target == null:
		return Callable()
	var muzzle_origin: Vector3 = primary_turret.muzzle_origin()
	var muzzle_height := maxf(muzzle_origin.y - _unit.global_position.y, 0.0) \
		if muzzle_origin.is_finite() else 0.0
	var unit := _unit
	return func(candidate: Vector3) -> bool:
		var hit: Dictionary = unit.flight_terrain_hit_at(candidate)
		var ground: Vector3 = hit["position"] if not hit.is_empty() else candidate
		return primary_turret.has_line_of_fire_from(
			ground + Vector3.UP * muzzle_height, attack_target, unit
		)


func _reset_pursuit() -> void:
	_is_pursuing = false
	_repath_remaining = 0.0
	_last_path_position = Vector3.INF
	_pursuit_destination = Vector3.INF
	_pursuit_rejected = false
