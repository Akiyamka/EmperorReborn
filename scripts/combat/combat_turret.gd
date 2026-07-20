class_name CombatTurret
extends RefCounted

const CombatBulletScript := preload("res://scripts/combat/combat_bullet.gd")
const CombatProjectileScript := preload("res://scripts/combat/combat_projectile.gd")

## Converted XBF models preserve the original Emperor attachment markers:
##   ::N...  pivot of weapon/turret N
##   >>N...  projectile emission point
## A TurretNextJoint chain maps onto the nested :: pivots between a weapon's
## root marker and its muzzle markers.

## Turret rotation angles are authored as per-update steps. Use the same 20 Hz
## rules cadence as unit movement while keeping interpolation frame-rate safe.
const AIM_UPDATES_PER_SECOND := 20.0
const DEFAULT_ACCEPTABLE_AIM_DEGREES := 1.0
const DEFAULT_MUZZLE_FLASH_DURATION := 0.2
const TURRET_MARKER := "::"
const MUZZLE_MARKER := ">>"
const AUTHORED_MUZZLE_FORWARD := Vector3.BACK

enum TargetRange {
	INVALID,
	TOO_CLOSE,
	IN_RANGE,
	TOO_FAR,
}

var config: Resource
var firing_config: Resource
var bullet_config: Resource
var warhead_config: Resource
var projectile_visual_scene: PackedScene
var muzzle_flash_id: StringName = &""
var muzzle_flash_scene: PackedScene
var joint_configs: Array[Resource] = []
var reload_ticks_remaining := 0.0
var bullet_gravity := 1.0

var current_yaw := 0.0
var current_pitch := 0.0

var _model_root: Node3D
var _weapon_index := -1
var _root_pivot: Node3D
var _yaw_pivot: Node3D
var _pitch_pivot: Node3D
var _reference_pivot: Node3D
var _pivot_rest_transforms: Dictionary = {}
var _muzzles: Array[Node3D] = []
var _next_muzzle_index := 0
var _last_emissions: Array[Dictionary] = []


func configure_from_rules(turret_config: Resource, rules: Object) -> bool:
	unbind_model()
	_weapon_index = -1
	config = turret_config
	joint_configs = _joint_chain(turret_config, rules)
	firing_config = _last_firing_joint(joint_configs)
	bullet_config = null
	warhead_config = null
	projectile_visual_scene = null
	muzzle_flash_id = &""
	muzzle_flash_scene = null
	reload_ticks_remaining = 0.0
	bullet_gravity = 1.0
	if firing_config == null or rules == null:
		return false
	var general_config: Resource = rules.call("general_rules") \
		if rules.has_method("general_rules") else null
	if general_config != null:
		bullet_gravity = maxf(float(general_config.field(&"bullet_gravity", 1.0)), 0.0)

	var bullet_id := StringName(String(firing_config.field(&"bullet", "")))
	if bullet_id == &"":
		return false
	bullet_config = rules.call("bullet", bullet_id)
	if bullet_config == null:
		return false
	projectile_visual_scene = _resolve_projectile_visual_scene(rules, bullet_id)
	muzzle_flash_id = StringName(String(firing_config.field(&"turret_muzzle_flash", "")))
	if muzzle_flash_id != &"":
		muzzle_flash_scene = _resolve_muzzle_flash_scene(rules, muzzle_flash_id)

	var warhead_id := StringName(String(bullet_config.field(&"warhead", "")))
	if warhead_id != &"":
		warhead_config = rules.call("warhead", warhead_id)
	return true


func bind_model(model_root: Node3D, weapon_index: int) -> bool:
	unbind_model()
	_weapon_index = weapon_index
	if model_root == null or weapon_index < 0:
		return false
	_model_root = model_root

	var pivot_candidates: Array[Node3D] = []
	_collect_markers(model_root, TURRET_MARKER, weapon_index, pivot_candidates)
	_root_pivot = _pivot_with_muzzles(pivot_candidates)
	if _root_pivot == null and not pivot_candidates.is_empty():
		_root_pivot = pivot_candidates.front()

	if _root_pivot != null:
		_collect_markers(_root_pivot, MUZZLE_MARKER, -1, _muzzles)
	if _muzzles.is_empty():
		_collect_markers(model_root, MUZZLE_MARKER, weapon_index, _muzzles)
	if _muzzles.is_empty():
		_collect_visual_muzzle_fallbacks(_root_pivot if _root_pivot != null else model_root, _muzzles)
	_muzzles.sort_custom(_muzzle_less)

	var pivot_chain := _pivot_chain_to(_muzzles.front() if not _muzzles.is_empty() else null)
	if pivot_chain.is_empty() and _root_pivot != null:
		pivot_chain.append(_root_pivot)
	_reference_pivot = _root_pivot
	if _reference_pivot == null and not _muzzles.is_empty():
		_reference_pivot = _nearest_node3d_parent(_muzzles.front())

	for joint_index in joint_configs.size():
		var joint_config: Resource = joint_configs[joint_index]
		var pivot: Node3D = pivot_chain[mini(joint_index, pivot_chain.size() - 1)] \
			if not pivot_chain.is_empty() else null
		if pivot == null:
			continue
		if _yaw_pivot == null and _axis_speed(joint_config, &"turret_y_rotation_angle") > 0.0:
			_yaw_pivot = pivot
		if _pitch_pivot == null and _axis_speed(joint_config, &"turret_x_rotation_angle") > 0.0:
			_pitch_pivot = pivot

	for pivot in [_root_pivot, _yaw_pivot, _pitch_pivot, _reference_pivot]:
		_store_rest_transform(pivot)
	current_yaw = 0.0
	current_pitch = 0.0
	_next_muzzle_index = 0
	_apply_aim_transforms()
	return _reference_pivot != null or not _muzzles.is_empty()


func unbind_model() -> void:
	_restore_pivot_transforms()
	_model_root = null
	_root_pivot = null
	_yaw_pivot = null
	_pitch_pivot = null
	_reference_pivot = null
	_pivot_rest_transforms.clear()
	_muzzles.clear()
	_next_muzzle_index = 0
	_last_emissions.clear()
	current_yaw = 0.0
	current_pitch = 0.0


func is_configured() -> bool:
	return config != null and firing_config != null and bullet_config != null


func is_bound() -> bool:
	return _model_root != null and is_instance_valid(_model_root) \
		and (_reference_pivot != null or not _muzzles.is_empty())


func is_fixed() -> bool:
	return _yaw_pivot == null and _pitch_pivot == null


func weapon_index() -> int:
	return _weapon_index


func requires_hull_turn() -> bool:
	return _yaw_pivot == null


func requires_hull_turn_for(world_position: Vector3) -> bool:
	if _yaw_pivot == null:
		return true
	var yaw_config := _yaw_config()
	if yaw_config == null:
		return true
	_apply_aim_transforms()
	var desired_yaw := _desired_yaw(world_position)
	var reachable_yaw := _clamp_rule_angle(
		desired_yaw, yaw_config,
		&"turret_min_y_rotation", &"turret_max_y_rotation"
	)
	return absf(angle_difference(desired_yaw, reachable_yaw)) \
		> deg_to_rad(_acceptable_yaw_degrees())


func joint_count() -> int:
	return joint_configs.size()


func muzzle_count() -> int:
	return _muzzles.size()


func current_yaw_degrees() -> float:
	return rad_to_deg(current_yaw)


func current_pitch_degrees() -> float:
	return rad_to_deg(current_pitch)


## Reapplies the combat-owned yaw and pitch after an AnimationPlayer changes
## clips. Converted animations key the authored turret pivots as part of the
## full model pose, so stop()/play() can otherwise expose their straight-ahead
## transform for one rendered frame without changing the logical aim angles.
func restore_aim_pose() -> void:
	_apply_aim_transforms()


func aim_at(world_position: Vector3, delta: float) -> bool:
	if not is_bound():
		return false
	# Authored Stationary/Move tracks can key a turret ancestor back to its
	# animation pose before Unit combat runs. Restore the combat-owned angles
	# first, otherwise the muzzle servo observes the rest direction every frame
	# while current_yaw/current_pitch drift independently without converging.
	_apply_aim_transforms()
	if _yaw_pivot != null:
		var yaw_config := _yaw_config()
		var desired_yaw := _clamp_rule_angle(
			_desired_yaw(world_position), yaw_config,
			&"turret_min_y_rotation", &"turret_max_y_rotation"
		)
		current_yaw = _turn_axis(
			current_yaw,
			desired_yaw,
			_axis_speed(yaw_config, &"turret_y_rotation_angle"),
			delta
		)
		_apply_aim_transforms()
	if _pitch_pivot != null:
		var pitch_config := _pitch_config()
		var desired_pitch := _clamp_rule_angle(
			_desired_firing_pitch(world_position), pitch_config,
			&"turret_min_x_rotation", &"turret_max_x_rotation"
		)
		current_pitch = _turn_axis(
			current_pitch,
			desired_pitch,
			_axis_speed(pitch_config, &"turret_x_rotation_angle"),
			delta
		)
		_apply_aim_transforms()
	return is_aimed_at(world_position)


func recenter(delta: float) -> bool:
	current_yaw = _turn_axis(current_yaw, 0.0, _axis_speed(_yaw_config(), &"turret_y_rotation_angle"), delta)
	current_pitch = _turn_axis(current_pitch, 0.0, _axis_speed(_pitch_config(), &"turret_x_rotation_angle"), delta)
	_apply_aim_transforms()
	return is_zero_approx(current_yaw) and is_zero_approx(current_pitch)


func is_aimed_at(world_position: Vector3) -> bool:
	var emission := peek_emission()
	if emission.is_empty():
		return false
	var offset: Vector3 = world_position - Vector3(emission["position"])
	if offset.length_squared() <= 0.000001:
		return true
	var direction: Vector3 = emission["direction"]
	var target_direction := _desired_firing_direction(world_position)
	if target_direction.is_zero_approx():
		target_direction = offset.normalized()
	var horizontal_direction := Vector2(direction.x, direction.z)
	var horizontal_target := Vector2(target_direction.x, target_direction.z)
	var yaw_error := 0.0
	if not horizontal_direction.is_zero_approx() and not horizontal_target.is_zero_approx():
		yaw_error = absf(
			angle_difference(horizontal_direction.angle(), horizontal_target.angle())
		)
	var direction_pitch := atan2(direction.y, horizontal_direction.length())
	var target_pitch := atan2(target_direction.y, horizontal_target.length())
	var pitch_error := absf(angle_difference(direction_pitch, target_pitch))
	return yaw_error <= deg_to_rad(_acceptable_yaw_degrees()) \
		and (_pitch_pivot == null \
			or pitch_error <= deg_to_rad(_acceptable_pitch_degrees()))


func emission_points() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for muzzle_index in _muzzles.size():
		var muzzle := _muzzles[muzzle_index]
		if muzzle == null or not is_instance_valid(muzzle):
			continue
		var transform := muzzle.global_transform
		var direction := transform.basis * AUTHORED_MUZZLE_FORWARD
		if direction.length_squared() <= 0.000001:
			continue
		result.append({
			"index": muzzle_index,
			"node": muzzle,
			"transform": transform,
			"position": transform.origin,
			"direction": direction.normalized(),
		})
	if result.is_empty() and _reference_pivot != null and is_instance_valid(_reference_pivot):
		var transform := _reference_pivot.global_transform
		var direction := transform.basis * AUTHORED_MUZZLE_FORWARD
		if direction.length_squared() > 0.000001:
			result.append({
				"index": 0,
				"node": _reference_pivot,
				"transform": transform,
				"position": transform.origin,
				"direction": direction.normalized(),
			})
	return result


func peek_emission() -> Dictionary:
	var points := emission_points()
	if points.is_empty():
		return {}
	return points[_next_muzzle_index % points.size()]


func next_emission() -> Dictionary:
	var points := emission_points()
	if points.is_empty():
		return {}
	var emission := points[_next_muzzle_index % points.size()]
	_next_muzzle_index = (_next_muzzle_index + 1) % points.size()
	return emission


func last_emissions() -> Array[Dictionary]:
	return _last_emissions.duplicate()


func is_ready() -> bool:
	return is_configured() and reload_ticks_remaining <= 0.0


func reload_count() -> float:
	return maxf(float(firing_config.field(&"reload_count", 0.0)), 0.0) \
		if firing_config != null else 0.0


func begin_reload() -> void:
	reload_ticks_remaining = reload_count()


func advance_ticks(ticks: float) -> void:
	if ticks <= 0.0 or reload_ticks_remaining <= 0.0:
		return
	reload_ticks_remaining = maxf(reload_ticks_remaining - ticks, 0.0)


func can_target(target_or_position: Variant) -> bool:
	if not is_configured() or not is_bound():
		return false
	var target_position := _bullet_target_position(target_or_position)
	if not target_position.is_finite() or peek_emission().is_empty():
		return false
	var bullet = CombatBulletScript.new(
		bullet_config, warhead_config, projectile_visual_scene
	)
	if target_or_position is Vector3:
		return bullet.can_hit_ground()
	if not target_or_position is Object:
		return false
	return _bullet_target_is_alive(target_or_position as Object) \
		and bullet.can_hit(target_or_position as Object)


func target_range(target_or_position: Variant, aim_offset := Vector3.ZERO) -> int:
	if not can_target(target_or_position):
		return TargetRange.INVALID
	var target_position := _bullet_target_position(target_or_position) + aim_offset
	var range_origin := _range_origin()
	if not range_origin.is_finite():
		return TargetRange.INVALID
	var offset: Vector3 = target_position - range_origin
	var horizontal_distance := Vector2(offset.x, offset.z).length()
	var bullet = CombatBulletScript.new(
		bullet_config, warhead_config, projectile_visual_scene
	)
	if horizontal_distance + 0.0001 < bullet.minimum_range_world():
		return TargetRange.TOO_CLOSE
	if horizontal_distance > bullet.maximum_range_world() + 0.0001:
		return TargetRange.TOO_FAR
	return TargetRange.IN_RANGE


func try_fire(begin_reload_after_shot := true) -> Array:
	var result: Array = []
	if not is_ready():
		return result

	_last_emissions.clear()
	var bullet_count := maxi(int(firing_config.field(&"turret_bullet_count", 1)), 1)
	for index in bullet_count:
		result.append(CombatBulletScript.new(
			bullet_config, warhead_config, projectile_visual_scene
		))
		_last_emissions.append(next_emission())
	if begin_reload_after_shot:
		begin_reload()
	return result


## Emits fully configured world-space projectile nodes toward either a live
## target or an attack-ground position. Range is checked before reload/muzzle
## state is consumed; the target position is sampled now (there is no lead).
func try_fire_at(
		target_or_position: Variant,
		source: Object = null,
		projectile_parent: Node = null,
		aim_offset := Vector3.ZERO,
		begin_reload_after_shot := true,
		require_aim := true
	) -> Array:
	var result: Array = []
	if not is_ready() or not is_bound():
		return result
	var target_position := _bullet_target_position(target_or_position)
	var preview_emission := peek_emission()
	if not target_position.is_finite() or preview_emission.is_empty():
		return result
	if require_aim and not is_aimed_at(target_position + aim_offset):
		return result
	var preview_bullet = CombatBulletScript.new(
		bullet_config, warhead_config, projectile_visual_scene
	)
	if target_or_position is Vector3 and not preview_bullet.can_hit_ground():
		return result
	if target_or_position is Object \
	and not preview_bullet.can_hit(target_or_position as Object):
		return result
	if target_or_position is Object \
	and not _bullet_target_is_alive(target_or_position as Object):
		return result
	var range_origin := _range_origin()
	if not range_origin.is_finite() \
	or not preview_bullet.can_reach(range_origin, target_position + aim_offset):
		return result

	var parent := projectile_parent if projectile_parent != null else _default_projectile_parent()
	if parent == null or not parent.is_inside_tree():
		return result
	var payloads := try_fire(begin_reload_after_shot)
	for index in payloads.size():
		var projectile = CombatProjectileScript.new()
		parent.add_child(projectile)
		var emission: Dictionary = _last_emissions[index] \
			if index < _last_emissions.size() else preview_emission
		if not projectile.launch(
			payloads[index], emission, target_or_position,
			source if source != null else _model_root, bullet_gravity, aim_offset,
			range_origin
		):
			projectile.free()
			continue
		_spawn_muzzle_flash(parent, emission)
		result.append(projectile)
	return result


func _bullet_target_position(target_or_position: Variant) -> Vector3:
	if target_or_position is Vector3:
		return target_or_position
	if target_or_position is Object and is_instance_valid(target_or_position):
		var target_object := target_or_position as Object
		if target_object.has_method("combat_aim_position"):
			var value: Variant = target_object.call("combat_aim_position")
			if value is Vector3:
				return value
		if target_object is Node3D:
			return (target_object as Node3D).global_position
	return Vector3.INF


func _bullet_target_is_alive(target: Object) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	if target is Node and (target as Node).is_queued_for_deletion():
		return false
	return not target.has_method("combat_is_alive") or bool(target.call("combat_is_alive"))


func _default_projectile_parent() -> Node:
	if _model_root == null or not is_instance_valid(_model_root) or not _model_root.is_inside_tree():
		return null
	var tree := _model_root.get_tree()
	return tree.current_scene if tree.current_scene != null else tree.root


func _joint_chain(turret_config: Resource, rules: Object) -> Array[Resource]:
	var result: Array[Resource] = []
	var current := turret_config
	var visited: Dictionary = {}
	while current != null:
		var current_id := String(current.get("id"))
		if not current_id.is_empty() and visited.has(current_id):
			return []
		if not current_id.is_empty():
			visited[current_id] = true
		result.append(current)
		var next_joint := StringName(String(current.field(&"turret_next_joint", "")))
		if next_joint == &"" or rules == null:
			break
		current = rules.call("turret", next_joint)
	return result


func _last_firing_joint(configs: Array[Resource]) -> Resource:
	for index in range(configs.size() - 1, -1, -1):
		if not String(configs[index].field(&"bullet", "")).is_empty():
			return configs[index]
	return null


func _collect_markers(
		node: Node, marker: String, wanted_index: int, result: Array[Node3D]
	) -> void:
	if node is Node3D:
		var index := _marker_index(_original_name(node), marker)
		if index >= 0 and (wanted_index < 0 or index == wanted_index):
			result.append(node as Node3D)
	for child in node.get_children():
		_collect_markers(child, marker, wanted_index, result)


func _collect_visual_muzzle_fallbacks(node: Node, result: Array[Node3D]) -> void:
	if node is Node3D:
		var lower_name := _original_name(node).to_lower()
		if lower_name.contains("bigflash") or lower_name.contains("bflash"):
			result.append(node as Node3D)
	for child in node.get_children():
		_collect_visual_muzzle_fallbacks(child, result)


func _pivot_with_muzzles(candidates: Array[Node3D]) -> Node3D:
	for candidate in candidates:
		var descendant_muzzles: Array[Node3D] = []
		_collect_markers(candidate, MUZZLE_MARKER, -1, descendant_muzzles)
		if not descendant_muzzles.is_empty():
			return candidate
	return null


func _pivot_chain_to(muzzle: Node3D) -> Array[Node3D]:
	var result: Array[Node3D] = []
	if muzzle == null:
		return result
	var current: Node = muzzle.get_parent()
	var stop: Node = _root_pivot.get_parent() if _root_pivot != null else _model_root.get_parent()
	while current != null and current != stop:
		if current is Node3D and _marker_index(_original_name(current), TURRET_MARKER) >= 0:
			result.push_front(current as Node3D)
		current = current.get_parent()
	return result


func _marker_index(original_name: String, marker: String) -> int:
	var marker_position := original_name.find(marker)
	if marker_position < 0:
		return -1
	var digit_position := marker_position + marker.length()
	var end := digit_position
	while end < original_name.length():
		var code := original_name.unicode_at(end)
		if code < 48 or code > 57:
			break
		end += 1
	return int(original_name.substr(digit_position, end - digit_position)) \
		if end > digit_position else -1


func _muzzle_less(a: Node3D, b: Node3D) -> bool:
	var a_index := _marker_index(_original_name(a), MUZZLE_MARKER)
	var b_index := _marker_index(_original_name(b), MUZZLE_MARKER)
	if a_index != b_index:
		return a_index < b_index
	return String(a.get_path()) < String(b.get_path())


func _original_name(node: Node) -> String:
	if node == null:
		return ""
	return String(node.get_meta("original_name", node.name))


func _nearest_node3d_parent(node: Node) -> Node3D:
	var current := node.get_parent() if node != null else null
	while current != null:
		if current is Node3D:
			return current as Node3D
		current = current.get_parent()
	return null


func _store_rest_transform(pivot: Node3D) -> void:
	if pivot != null and is_instance_valid(pivot) and not _pivot_rest_transforms.has(pivot):
		_pivot_rest_transforms[pivot] = pivot.transform


func _restore_pivot_transforms() -> void:
	for pivot in _pivot_rest_transforms:
		if pivot != null and is_instance_valid(pivot):
			(pivot as Node3D).transform = _pivot_rest_transforms[pivot]


func _apply_aim_transforms() -> void:
	if _yaw_pivot != null and _yaw_pivot == _pitch_pivot:
		_apply_pivot_rotation(_yaw_pivot, current_yaw, current_pitch)
		return
	if _yaw_pivot != null:
		_apply_pivot_rotation(_yaw_pivot, current_yaw, 0.0)
	if _pitch_pivot != null:
		_apply_pivot_rotation(_pitch_pivot, 0.0, current_pitch)


func _apply_pivot_rotation(pivot: Node3D, yaw: float, pitch: float) -> void:
	if pivot == null or not is_instance_valid(pivot) or not _pivot_rest_transforms.has(pivot):
		return
	var rest: Transform3D = _pivot_rest_transforms[pivot]
	var rotation := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, pitch)
	pivot.transform = Transform3D(rest.basis * rotation, rest.origin)


func _desired_yaw(world_position: Vector3) -> float:
	var emission := peek_emission()
	if emission.is_empty():
		return current_yaw
	var direction: Vector3 = emission["direction"]
	var target_direction: Vector3 = world_position - Vector3(emission["position"])
	var horizontal_direction := Vector2(direction.x, direction.z)
	var horizontal_target := Vector2(target_direction.x, target_direction.z)
	if horizontal_direction.is_zero_approx() or horizontal_target.is_zero_approx():
		return current_yaw
	var direction_heading := atan2(horizontal_direction.x, horizontal_direction.y)
	var target_heading := atan2(horizontal_target.x, horizontal_target.y)
	return current_yaw + angle_difference(direction_heading, target_heading)


func _desired_firing_pitch(world_position: Vector3) -> float:
	return _desired_pitch_for_direction(_desired_firing_direction(world_position))


func _desired_firing_direction(world_position: Vector3) -> Vector3:
	var emission := peek_emission()
	if emission.is_empty():
		return Vector3.ZERO
	var target_direction: Vector3 = world_position - Vector3(emission["position"])
	if target_direction.is_zero_approx():
		return Vector3(emission["direction"]).normalized()
	var bullet = CombatBulletScript.new(
		bullet_config, warhead_config, projectile_visual_scene
	)
	if not bullet.has_trajectory():
		return target_direction.normalized()
	var velocities: Array[Vector3] = CombatProjectileScript.trajectory_launch_velocities(
		bullet,
		Vector3(emission["position"]),
		world_position,
		CombatProjectileScript.trajectory_gravity_world(bullet_gravity),
		_projectile_flight_range(Vector3(emission["position"]), bullet)
	)
	if velocities.is_empty():
		return target_direction.normalized()

	var directions: Array[Vector3] = []
	for velocity in velocities:
		directions.append(velocity.normalized())
	if _pitch_pivot == null or directions.size() == 1:
		return directions.front()

	# Prefer the low ballistic solution when both arcs fit. Weapons whose rule
	# limits impose a minimum elevation (for example the deployed mortar) select
	# the high solution because its joint angle is the reachable one.
	var pitch_config := _pitch_config()
	var best_direction: Vector3 = directions.front()
	var best_limit_error: float = INF
	for candidate in directions:
		var candidate_pitch := _desired_pitch_for_direction(candidate)
		var reachable_pitch := _clamp_rule_angle(
			candidate_pitch, pitch_config,
			&"turret_min_x_rotation", &"turret_max_x_rotation"
		)
		var limit_error := absf(angle_difference(candidate_pitch, reachable_pitch))
		if limit_error < best_limit_error:
			best_limit_error = limit_error
			best_direction = candidate
	return best_direction


func _desired_pitch_for_direction(target_direction: Vector3) -> float:
	var emission := peek_emission()
	if emission.is_empty() or target_direction.is_zero_approx():
		return current_pitch
	var direction: Vector3 = emission["direction"]
	var direction_pitch := atan2(direction.y, Vector2(direction.x, direction.z).length())
	var target_pitch := atan2(
		target_direction.y, Vector2(target_direction.x, target_direction.z).length()
	)
	# Positive authored X rotation lowers a BACK-facing muzzle, hence the
	# subtraction when converting world-space pitch error into joint rotation.
	return current_pitch - angle_difference(direction_pitch, target_pitch)


func _resolve_projectile_visual_scene(rules: Object, bullet_id: StringName) -> PackedScene:
	return _resolve_art_visual_scene(
		rules, bullet_id, "res://assets/converted/projectiles"
	)


func _resolve_muzzle_flash_scene(rules: Object, flash_id: StringName) -> PackedScene:
	return _resolve_art_visual_scene(
		rules, flash_id, "res://assets/converted/muzzle_flashes"
	)


func _resolve_art_visual_scene(
		rules: Object,
		art_id: StringName,
		output_root: String
	) -> PackedScene:
	if rules == null or not rules.has_method("get_entity"):
		return null
	var art_config := rules.call("get_entity", &"art_config", art_id) as Resource
	if art_config == null and rules.has_method("all"):
		for candidate: Resource in rules.call("all", &"art_config"):
			if String(candidate.id).nocasecmp_to(String(art_id)) == 0:
				art_config = candidate
				break
	if art_config == null:
		return null
	var xaf := String(art_config.field(&"xaf", ""))
	if xaf.is_empty():
		return null
	var visual_name := xaf.get_file().get_basename().to_lower()
	var scene_path := "%s/%s/%s.scn" % [
		output_root, visual_name, visual_name,
	]
	if not ResourceLoader.exists(scene_path, "PackedScene"):
		return null
	return load(scene_path) as PackedScene


func _spawn_muzzle_flash(parent: Node, emission: Dictionary) -> void:
	if muzzle_flash_scene == null or parent == null or not parent.is_inside_tree():
		return
	var authored_visual := muzzle_flash_scene.instantiate() as Node3D
	if authored_visual == null:
		return
	var effect := Node3D.new()
	effect.name = "MuzzleFlash_%s" % String(muzzle_flash_id)
	parent.add_child(effect)
	effect.top_level = true
	effect.global_position = Vector3(emission.get("position", Vector3.ZERO))
	var direction := Vector3(emission.get("direction", Vector3.FORWARD)).normalized()
	if direction.is_zero_approx():
		direction = Vector3.FORWARD
	var up := Vector3.FORWARD if absf(direction.dot(Vector3.UP)) > 0.999 \
		else Vector3.UP
	effect.global_basis = Basis.looking_at(direction, up, true)
	authored_visual.name = "Visual"
	effect.add_child(authored_visual)

	var lifetime := DEFAULT_MUZZLE_FLASH_DURATION
	var player := authored_visual.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if player != null:
		var animation_name := &"Stationary" if player.has_animation(&"Stationary") \
			else &"timeline"
		if player.has_animation(animation_name):
			player.play(animation_name)
			var animation := player.get_animation(animation_name)
			if animation != null:
				# Standalone muzzle effects use a source clip named Stationary, but
				# unlike a unit idle it is a one-shot. Prevent a last-frame wrap to
				# the bright first frame before the cleanup timer removes the effect.
				animation.loop_mode = Animation.LOOP_NONE
				lifetime = maxf(animation.length, 1.0 / AIM_UPDATES_PER_SECOND)
	var cleanup := Timer.new()
	cleanup.name = "Cleanup"
	cleanup.one_shot = true
	cleanup.wait_time = lifetime
	effect.add_child(cleanup)
	cleanup.timeout.connect(effect.queue_free)
	cleanup.start()


## Rules ranges belong to the gameplay entity, not to an animated muzzle.
## Using a muzzle here makes entering range depend on whether Move, Fire or an
## elevated trajectory pose happened to run on that frame.
func _range_origin() -> Vector3:
	if _model_root == null or not is_instance_valid(_model_root):
		return Vector3.INF
	return _model_root.global_position


func _projectile_flight_range(emission_position: Vector3, bullet) -> float:
	var range_origin := _range_origin()
	if not range_origin.is_finite():
		return bullet.maximum_range_world()
	var muzzle_offset := Vector2(
		emission_position.x - range_origin.x,
		emission_position.z - range_origin.z
	).length()
	return bullet.maximum_range_world() + muzzle_offset


func _turn_axis(current: float, target: float, speed_degrees: float, delta: float) -> float:
	if speed_degrees <= 0.0 or delta <= 0.0:
		return current
	var maximum_step := deg_to_rad(speed_degrees) * AIM_UPDATES_PER_SECOND * delta
	return rotate_toward(current, target, maximum_step)


func _clamp_rule_angle(
		angle: float, joint_config: Resource, minimum_field: StringName, maximum_field: StringName
	) -> float:
	if joint_config == null:
		return 0.0
	var minimum_value: Variant = joint_config.field(minimum_field, null)
	var maximum_value: Variant = joint_config.field(maximum_field, null)
	if minimum_value == null and maximum_value == null:
		return wrapf(angle, -PI, PI)
	var minimum := float(minimum_value) if minimum_value != null else -180.0
	var maximum := float(maximum_value) if maximum_value != null else 180.0
	if maximum - minimum >= 360.0:
		return wrapf(angle, -PI, PI)
	return clampf(angle, deg_to_rad(minimum), deg_to_rad(maximum))


func _axis_speed(joint_config: Resource, field_name: StringName) -> float:
	return maxf(float(joint_config.field(field_name, 0.0)), 0.0) \
		if joint_config != null else 0.0


func _yaw_config() -> Resource:
	for joint_config in joint_configs:
		if _axis_speed(joint_config, &"turret_y_rotation_angle") > 0.0:
			return joint_config
	return null


func _pitch_config() -> Resource:
	for joint_config in joint_configs:
		if _axis_speed(joint_config, &"turret_x_rotation_angle") > 0.0:
			return joint_config
	return null


func _acceptable_yaw_degrees() -> float:
	var yaw_config := _yaw_config()
	if yaw_config != null:
		return maxf(
			float(yaw_config.field(&"turret_y_acceptable_aim", DEFAULT_ACCEPTABLE_AIM_DEGREES)),
			DEFAULT_ACCEPTABLE_AIM_DEGREES
		)
	return DEFAULT_ACCEPTABLE_AIM_DEGREES


func _acceptable_pitch_degrees() -> float:
	var pitch_config := _pitch_config()
	if pitch_config != null:
		return maxf(
			float(pitch_config.field(&"turret_x_acceptable_aim", DEFAULT_ACCEPTABLE_AIM_DEGREES)),
			DEFAULT_ACCEPTABLE_AIM_DEGREES
		)
	return DEFAULT_ACCEPTABLE_AIM_DEGREES
