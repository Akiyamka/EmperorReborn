class_name CombatTurret
extends RefCounted

const CombatBulletScript := preload("res://scripts/combat/combat_bullet.gd")
const CombatProjectileScript := preload("res://scripts/combat/combat_projectile.gd")

## Converted XBF models preserve the original Emperor attachment markers:
##   ::N...  pivot of weapon/turret N
##   >>N...  projectile emission point
##   #muzzleNN  paired rear blast / shell-casing emitter
##   #smoke  paired launcher backblast emitter
## A TurretNextJoint chain maps onto the nested :: pivots between a weapon's
## root marker and its muzzle markers.

## Turret rotation angles are authored as per-update steps. Use the same 20 Hz
## rules cadence as unit movement while keeping interpolation frame-rate safe.
const AIM_UPDATES_PER_SECOND := 20.0
const DEFAULT_ACCEPTABLE_AIM_DEGREES := 1.0
const DEFAULT_MUZZLE_FLASH_DURATION := 0.2
const MUZZLE3_PRIMARY_MESH := "Mesh_00"
const MUZZLE3_PRIMARY_SCALE := 0.5
const TURRET_MARKER := "::"
const MUZZLE_MARKER := ">>"
const REAR_MUZZLE_MARKER := "#muzzle"
const AUTHORED_MUZZLE_FORWARD := Vector3.BACK
const INLINE_FX_TEXTURE_DIR := "res://assets/raw_original_content/3DDATA/Textures"
const INLINE_FX_FRAME_SECONDS := 1.0 / AIM_UPDATES_PER_SECOND
const BARREL_SMOKE_SEQUENCE := "!%Bru"
const REAR_FLASH_FRAME_COUNT := 16
const REAR_FLASH_SIZE := 2.2
const SHOT_LIGHT_COLOR := Color(1.0, 0.34, 0.08)
const SHOT_LIGHT_ENERGY := 3.0
const SHOT_LIGHT_RANGE := 4.0
const SHOT_LIGHT_REAR_OFFSET := 0.35
const SHOT_LIGHT_HOLD_DURATION := 0.04
const SHOT_LIGHT_FADE_DURATION := 0.16
const CASING_FRAME_COUNT := 10
const CASINGS_PER_SHOT := 1
const CASING_SIZE := 0.56
const CASING_LIFETIME := 1.0
const CASING_GRAVITY := 5.5
const LAUNCH_SMOKE_MARKER := "#smoke"
const LAUNCH_SMOKE_SEQUENCE := "!cexp"
const LAUNCH_SMOKE_FRAME_COUNT := 16
const LAUNCH_SMOKE_SIZE := 1.25

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
var impact_visual_scenes: Dictionary = {}
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
var _rear_muzzles: Dictionary = {}
var _launch_smokes: Dictionary = {}
var _uses_embedded_muzzle_flash := false
var _next_muzzle_index := 0
var _last_emissions: Array[Dictionary] = []
var _rear_flash_textures: Array[Texture2D] = []
var _casing_textures: Array[Texture2D] = []
var _launch_smoke_textures: Array[Texture2D] = []
static var _muzzle_bank_texture_cache: Dictionary = {}
var _muzzle_bank_particle_index := 0


func configure_from_rules(turret_config: Resource, rules: Object) -> bool:
	unbind_model()
	_weapon_index = -1
	config = turret_config
	joint_configs = _joint_chain(turret_config, rules)
	firing_config = _last_firing_joint(joint_configs)
	bullet_config = null
	warhead_config = null
	projectile_visual_scene = null
	impact_visual_scenes.clear()
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
	var explosion_effect_ids: Array = bullet_config.list(&"explosion_effects")
	if explosion_effect_ids.is_empty():
		var primary_explosion_id := String(bullet_config.field(&"explosion_type", ""))
		if not primary_explosion_id.is_empty():
			explosion_effect_ids.append(primary_explosion_id)
	for value in explosion_effect_ids:
		var effect_id := StringName(String(value))
		var effect_scene := _resolve_impact_visual_scene(rules, effect_id)
		if effect_scene != null:
			impact_visual_scenes[effect_id] = effect_scene
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
	_uses_embedded_muzzle_flash = _has_embedded_muzzle_flash(model_root)

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
	var effect_root := _root_pivot if _root_pivot != null else model_root
	_bind_rear_muzzles(effect_root)
	_bind_launch_smokes(effect_root)

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
	_rear_muzzles.clear()
	_launch_smokes.clear()
	_uses_embedded_muzzle_flash = false
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


func rear_muzzle_count() -> int:
	return _rear_muzzles.size()


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
		var emission := {
			"index": muzzle_index,
			"node": muzzle,
			"transform": transform,
			"position": transform.origin,
			"direction": direction.normalized(),
		}
		var rear_muzzle := _rear_muzzles.get(muzzle) as Node3D
		if rear_muzzle != null and is_instance_valid(rear_muzzle):
			var rear_transform := rear_muzzle.global_transform
			emission["rear_node"] = rear_muzzle
			emission["rear_transform"] = rear_transform
			emission["rear_position"] = rear_transform.origin
			# The rear marker supplies the animated position but its empty-node
			# basis is not authored as an exhaust vector. Direction is explicitly
			# opposite the paired barrel's projectile heading.
			emission["rear_direction"] = -direction.normalized()
		var launch_smoke := _launch_smokes.get(muzzle) as Node3D
		if launch_smoke != null and is_instance_valid(launch_smoke):
			emission["smoke_node"] = launch_smoke
			emission["smoke_position"] = launch_smoke.global_position
		result.append(emission)
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
		bullet_config, warhead_config, projectile_visual_scene, impact_visual_scenes
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
		bullet_config, warhead_config, projectile_visual_scene, impact_visual_scenes
	)
	if horizontal_distance + 0.0001 < bullet.minimum_range_world():
		return TargetRange.TOO_CLOSE
	if horizontal_distance > bullet.maximum_range_world() + 0.0001:
		return TargetRange.TOO_FAR
	return TargetRange.IN_RANGE


func try_fire(begin_reload_after_shot := true, committed_sequence := false) -> Array:
	var result: Array = []
	if not is_configured() or (not committed_sequence and not is_ready()):
		return result

	_last_emissions.clear()
	var bullet_count := maxi(int(firing_config.field(&"turret_bullet_count", 1)), 1)
	for index in bullet_count:
		result.append(CombatBulletScript.new(
			bullet_config, warhead_config, projectile_visual_scene, impact_visual_scenes
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
		require_aim := true,
		committed_sequence := false
	) -> Array:
	var result: Array = []
	if not is_configured() or not is_bound() \
	or (not committed_sequence and not is_ready()):
		return result
	var target_position := _bullet_target_position(target_or_position)
	var preview_emission := peek_emission()
	if not target_position.is_finite() or preview_emission.is_empty():
		return result
	if require_aim and not is_aimed_at(target_position + aim_offset):
		return result
	var preview_bullet = CombatBulletScript.new(
		bullet_config, warhead_config, projectile_visual_scene, impact_visual_scenes
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
	var payloads := try_fire(begin_reload_after_shot, committed_sequence)
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
		# Some infantry models use their animated bigflash geometry as the only
		# available muzzle marker. Fire clips already reveal that embedded flash,
		# so adding the rules TurretMuzzleFlash and runtime light would duplicate it.
		if not _uses_embedded_muzzle_flash:
			_spawn_muzzle_flash(parent, emission)
			_spawn_shot_light(parent, emission)
			_spawn_auxiliary_muzzle_effects(parent, emission)
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


func _has_embedded_muzzle_flash(node: Node) -> bool:
	if node is Node3D:
		var lower_name := _original_name(node).to_lower()
		if lower_name.contains("bigflash") or lower_name.contains("bflash"):
			return true
	for child in node.get_children():
		if _has_embedded_muzzle_flash(child):
			return true
	return false


func _bind_rear_muzzles(node: Node) -> void:
	var candidates: Array[Node3D] = []
	_collect_rear_muzzles(node, candidates)
	for muzzle in _muzzles:
		for candidate in candidates:
			# Minotaurus pairs each >> marker and its rear #muzzle marker as
			# siblings under the same animated gun object. Pair by hierarchy,
			# not by the unrelated source number ranges 01-04 and 05-08.
			if candidate.get_parent() == muzzle.get_parent():
				_rear_muzzles[muzzle] = candidate
				break


func _bind_launch_smokes(node: Node) -> void:
	var candidates: Array[Node3D] = []
	_collect_named_markers(node, LAUNCH_SMOKE_MARKER, candidates)
	for muzzle in _muzzles:
		for candidate in candidates:
			# The Mongoose's >>0#flame and #smoke markers are siblings on the
			# launcher. Pair by hierarchy so unrelated smoke emitters elsewhere
			# in a model cannot become weapon backblast.
			if candidate.get_parent() == muzzle.get_parent():
				_launch_smokes[muzzle] = candidate
				break


func _collect_rear_muzzles(node: Node, result: Array[Node3D]) -> void:
	if node is Node3D \
	and _original_name(node).to_lower().begins_with(REAR_MUZZLE_MARKER):
		result.append(node as Node3D)
	for child in node.get_children():
		_collect_rear_muzzles(child, result)


func _collect_named_markers(node: Node, marker: String, result: Array[Node3D]) -> void:
	if node is Node3D and _original_name(node).nocasecmp_to(marker) == 0:
		result.append(node as Node3D)
	for child in node.get_children():
		_collect_named_markers(child, marker, result)


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
	# Aim the rigid barrel group from its pivot. Aiming separately from the
	# active side muzzle would turn the whole group a little toward the centre
	# and make consecutive Minotaurus shells converge.
	var target_direction: Vector3 = world_position - _aim_origin()
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
	var emission_position := Vector3(emission["position"])
	var target_direction: Vector3 = world_position - emission_position
	if target_direction.is_zero_approx():
		return Vector3(emission["direction"]).normalized()
	var bullet = CombatBulletScript.new(
		bullet_config, warhead_config, projectile_visual_scene, impact_visual_scenes
	)
	if not bullet.has_trajectory():
		return target_direction.normalized()
	# A rigid multi-barrel mount has one shared elevation. Solve that elevation
	# from the centre of the muzzle group rather than changing it whenever the
	# active >> marker advances to the next barrel.
	var trajectory_origin := _muzzle_group_origin()
	if not trajectory_origin.is_finite():
		trajectory_origin = emission_position
	var target_heading := world_position - _aim_origin()
	target_heading.y = 0.0
	if target_heading.is_zero_approx():
		target_heading = target_direction
	var trajectory_impact_position: Vector3 = (
		CombatProjectileScript.parallel_trajectory_impact_position(
			trajectory_origin, world_position, target_heading
		)
	)
	var trajectory_direction := trajectory_impact_position - trajectory_origin
	var velocities: Array[Vector3] = CombatProjectileScript.trajectory_launch_velocities(
		bullet,
		trajectory_origin,
		trajectory_impact_position,
		CombatProjectileScript.trajectory_gravity_world(bullet_gravity),
		bullet.maximum_range_world()
	)
	if velocities.is_empty():
		return trajectory_direction.normalized()

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


func _resolve_impact_visual_scene(rules: Object, effect_id: StringName) -> PackedScene:
	return _resolve_art_visual_scene(
		rules, effect_id, "res://assets/converted/impact_effects"
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
	if muzzle_flash_id == &"Muzzle3":
		_scale_muzzle3_primary_mesh(authored_visual)
	var effect := Node3D.new()
	effect.name = "MuzzleFlash_%s" % String(muzzle_flash_id)
	effect.set_meta("combat_muzzle_fx", &"front_flash")
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
	var bank_emission_lifetime := _start_barrel_smoke_bank(
		parent, effect, authored_visual, emission
	)

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
	lifetime = maxf(lifetime, bank_emission_lifetime)
	var cleanup := Timer.new()
	cleanup.name = "Cleanup"
	cleanup.one_shot = true
	cleanup.wait_time = lifetime
	effect.add_child(cleanup)
	cleanup.timeout.connect(effect.queue_free)
	cleanup.start()


func _start_barrel_smoke_bank(
		parent: Node,
		effect: Node3D,
		authored_visual: Node3D,
		emission: Dictionary
	) -> float:
	if not bool(authored_visual.get_meta("xbf_fx_events_complete", false)):
		return 0.0
	var banks := authored_visual.get_meta("xbf_fx_banks", []) as Array
	var smoke_bank := _fx_bank_by_texture(banks, BARREL_SMOKE_SEQUENCE)
	if smoke_bank.is_empty():
		return 0.0
	var frame_count := int(smoke_bank.get("texture_frame_count", 0))
	var textures := _muzzle_bank_textures(BARREL_SMOKE_SEQUENCE, frame_count)
	if textures.size() != frame_count:
		return 0.0

	var bank_id := String(smoke_bank.get("id", ""))
	var active_frames := {}
	var scheduled: Array[Dictionary] = []
	var events := authored_visual.get_meta("xbf_fx_events", []) as Array
	for event_value: Variant in events:
		var event := event_value as Dictionary
		if String(event.get("bank_id", "")) != bank_id:
			continue
		var attachment := String(event.get("attachment", ""))
		var action := String(event.get("action", ""))
		var frame := int(event.get("frame", -1))
		if action == "start":
			active_frames[attachment] = frame
		elif action == "stop" and active_frames.has(attachment):
			var start_frame := int(active_frames[attachment])
			# Start/stop are control frames. Emit on each intervening frame;
			# adjacent controls still represent one authored particle pulse.
			var first_particle_frame := start_frame + 1 \
				if frame - start_frame > 1 else start_frame
			var particle_count := maxi(frame - start_frame - 1, 1)
			for particle_offset in particle_count:
				scheduled.append({
					"frame": first_particle_frame + particle_offset,
					"attachment": attachment,
				})
			active_frames.erase(attachment)
	if scheduled.is_empty():
		return 0.0

	var world_scale := float(authored_visual.get_meta("xbf_world_scale", 1.0))
	var timeline := effect.create_tween()
	var previous_time := 0.0
	var emitted_index := int(emission.get("index", 0))
	for scheduled_value: Dictionary in scheduled:
		var marker := _find_original_node(
			authored_visual, String(scheduled_value["attachment"])
		)
		if marker == null:
			continue
		var emission_time := float(scheduled_value["frame"]) \
			* INLINE_FX_FRAME_SECONDS
		if emission_time > previous_time:
			timeline.tween_interval(emission_time - previous_time)
		timeline.tween_callback(
			_emit_barrel_smoke_particle.bind(
				parent, marker, smoke_bank, textures, world_scale, emitted_index
			)
		)
		previous_time = emission_time
	return previous_time + INLINE_FX_FRAME_SECONDS


func _emit_barrel_smoke_particle(
		parent: Node,
		marker: Node3D,
		bank: Dictionary,
		textures: Array[Texture2D],
		world_scale: float,
		emission_index: int
	) -> void:
	if parent == null or not parent.is_inside_tree() \
	or marker == null or not is_instance_valid(marker) or textures.is_empty():
		return
	var particle := Node3D.new()
	particle.name = "BarrelSmoke_%d_%d" % [
		emission_index, _muzzle_bank_particle_index,
	]
	particle.set_meta("combat_muzzle_fx", &"barrel_smoke")
	particle.set_meta("emission_index", emission_index)
	particle.set_meta("combat_fx_bank_id", StringName(String(bank.get("id", ""))))
	particle.set_meta("combat_fx_texture", StringName(String(bank.get("texture", ""))))
	_muzzle_bank_particle_index += 1
	parent.add_child(particle)
	particle.top_level = true
	var start := marker.global_position
	particle.global_position = start
	particle.set_meta("combat_muzzle_start_position", start)

	var particle_size := float(bank.get(
		"world_particle_size",
		float(bank.get("particle_size", 0.0)) * world_scale
	))
	var material := _barrel_smoke_material(bank, textures.front())
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE * particle_size
	quad.material = material
	var visual := MeshInstance3D.new()
	visual.name = "Visual"
	visual.mesh = quad
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	particle.add_child(visual)
	particle.set_meta("combat_fx_particle_size", particle_size)

	var source_gravity := float(bank.get("gravity", _fx_bank_gravity(bank)))
	var world_gravity := float(bank.get(
		"world_gravity",
		source_gravity * world_scale \
			* AIM_UPDATES_PER_SECOND * AIM_UPDATES_PER_SECOND
	))
	var acceleration := Vector3.DOWN * world_gravity
	particle.set_meta("combat_fx_source_gravity", source_gravity)
	particle.set_meta("combat_muzzle_acceleration", acceleration)
	var duration := float(textures.size()) * INLINE_FX_FRAME_SECONDS
	if not is_zero_approx(world_gravity):
		var motion := particle.create_tween().set_process_mode(
			Tween.TWEEN_PROCESS_PHYSICS
		)
		motion.tween_method(
			_update_fx_bank_particle.bind(particle, start, acceleration),
			0.0, duration, duration
		)

	var tint := material.albedo_color
	var frame_animation := particle.create_tween()
	for frame_index in textures.size():
		frame_animation.tween_callback(
			_set_fx_bank_frame.bind(
				material, textures[frame_index], tint,
				_fx_bank_frame_opacity(bank, frame_index)
			)
		)
		frame_animation.tween_interval(INLINE_FX_FRAME_SECONDS)
	frame_animation.finished.connect(particle.queue_free)


func _fx_bank_by_texture(banks: Array, texture_name: String) -> Dictionary:
	for bank_value: Variant in banks:
		var bank := bank_value as Dictionary
		if String(bank.get("texture", "")).nocasecmp_to(texture_name) == 0:
			return bank
	return {}


func _find_original_node(node: Node, original_name: String) -> Node3D:
	if node is Node3D \
	and String(node.get_meta("original_name", "")) == original_name:
		return node as Node3D
	for child in node.get_children():
		var result := _find_original_node(child, original_name)
		if result != null:
			return result
	return null


func _muzzle_bank_textures(base_name: String, count: int) -> Array[Texture2D]:
	if count <= 0:
		return []
	var cache_key := "%s:%d" % [base_name, count]
	if _muzzle_bank_texture_cache.has(cache_key):
		var cached: Array[Texture2D] = []
		cached.assign(_muzzle_bank_texture_cache[cache_key])
		return cached
	var textures := _load_fx_texture_sequence(base_name, count)
	if textures.size() == count:
		_muzzle_bank_texture_cache[cache_key] = textures
	return textures


func _barrel_smoke_material(
		bank: Dictionary, texture: Texture2D
	) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_texture = texture
	var colors := bank.get("int_parameters_7_11", PackedInt32Array()) \
		as PackedInt32Array
	if colors.size() >= 3:
		material.albedo_color = Color(
			clampf(float(colors[0]) / 255.0, 0.0, 1.0),
			clampf(float(colors[1]) / 255.0, 0.0, 1.0),
			clampf(float(colors[2]) / 255.0, 0.0, 1.0),
			_fx_bank_frame_opacity(bank, 0)
		)
	return material


func _fx_bank_gravity(bank: Dictionary) -> float:
	var parameters := bank.get("float_parameters_4_6", PackedFloat32Array()) \
		as PackedFloat32Array
	if parameters.size() < 2:
		return 0.0
	return parameters[1]


func _fx_bank_frame_opacity(bank: Dictionary, frame_index: int) -> float:
	var trailing := bank.get("trailing_words", PackedInt32Array()) \
		as PackedInt32Array
	if trailing.size() < 2:
		return 1.0
	return clampf(
		float(trailing[0] + trailing[1] * frame_index) / 255.0,
		0.0, 1.0
	)


func _set_fx_bank_frame(
		material: StandardMaterial3D,
		texture: Texture2D,
		tint: Color,
		opacity: float
	) -> void:
	if material == null:
		return
	material.albedo_texture = texture
	var color := tint
	color.a = opacity
	material.albedo_color = color


func _update_fx_bank_particle(
		elapsed: float,
		particle: Node3D,
		start: Vector3,
		acceleration: Vector3
	) -> void:
	if particle == null or not is_instance_valid(particle):
		return
	particle.global_position = start + 0.5 * acceleration * elapsed * elapsed


func _scale_muzzle3_primary_mesh(authored_visual: Node3D) -> void:
	var primary_mesh := authored_visual.find_child(
		MUZZLE3_PRIMARY_MESH, true, false
	) as MeshInstance3D
	if primary_mesh == null:
		return
	var mesh_parent := primary_mesh.get_parent() as Node3D
	if mesh_parent == null:
		return

	# Muzzle3 animates Mesh_00's transform. Keep that authored track targeting
	# a proxy while the actual mesh remains at half size beneath it.
	var authored_transform := primary_mesh.transform
	var sibling_index := primary_mesh.get_index()
	primary_mesh.name = "%s_Visual" % MUZZLE3_PRIMARY_MESH
	var animated_transform := Node3D.new()
	animated_transform.name = MUZZLE3_PRIMARY_MESH
	mesh_parent.add_child(animated_transform)
	mesh_parent.move_child(animated_transform, sibling_index)
	animated_transform.transform = authored_transform
	primary_mesh.reparent(animated_transform, false)
	primary_mesh.transform = Transform3D(
		Basis.from_scale(Vector3.ONE * MUZZLE3_PRIMARY_SCALE), Vector3.ZERO
	)


func _spawn_auxiliary_muzzle_effects(parent: Node, emission: Dictionary) -> void:
	if parent == null or not parent.is_inside_tree():
		return
	if emission.has("smoke_position"):
		_ensure_launch_smoke_textures()
		if _launch_smoke_textures.size() == LAUNCH_SMOKE_FRAME_COUNT:
			_spawn_launch_smoke(parent, emission)
	if not emission.has("rear_position"):
		return
	_ensure_inline_fx_textures()
	if _rear_flash_textures.size() == REAR_FLASH_FRAME_COUNT:
		_spawn_rear_flash(parent, emission)
	if _casing_textures.size() == CASING_FRAME_COUNT:
		for casing_index in CASINGS_PER_SHOT:
			_spawn_casing(parent, emission, casing_index)


func _spawn_launch_smoke(parent: Node, emission: Dictionary) -> void:
	var effect := Node3D.new()
	effect.name = "LaunchSmoke_%d" % int(emission.get("index", 0))
	effect.set_meta("combat_muzzle_fx", &"launch_smoke")
	effect.set_meta("emission_index", int(emission.get("index", 0)))
	parent.add_child(effect)
	effect.top_level = true
	effect.global_position = Vector3(emission["smoke_position"])
	var visual := _fx_quad(_launch_smoke_textures.front(), LAUNCH_SMOKE_SIZE)
	visual.name = "Visual"
	effect.add_child(visual)
	var material := (visual.mesh as QuadMesh).material as StandardMaterial3D
	var animation := effect.create_tween()
	for texture in _launch_smoke_textures:
		animation.tween_callback(_set_fx_texture.bind(material, texture))
		animation.tween_interval(INLINE_FX_FRAME_SECONDS)
	animation.finished.connect(effect.queue_free)


func _spawn_shot_light(parent: Node, emission: Dictionary) -> void:
	if parent == null or not parent.is_inside_tree():
		return
	var shot_direction := Vector3(
		emission.get("direction", Vector3.FORWARD)
	).normalized()
	if shot_direction.is_zero_approx():
		shot_direction = Vector3.FORWARD
	var rear_direction := Vector3(
		emission.get("rear_direction", -shot_direction)
	).normalized()
	if rear_direction.is_zero_approx():
		rear_direction = -shot_direction
	var origin := Vector3(
		emission.get(
			"rear_position",
			emission.get("smoke_position", emission.get("position", Vector3.ZERO))
		)
	)

	var light := OmniLight3D.new()
	light.name = "ShotLight_%d" % int(emission.get("index", 0))
	light.set_meta("combat_muzzle_fx", &"shot_light")
	light.set_meta("emission_index", int(emission.get("index", 0)))
	light.light_color = SHOT_LIGHT_COLOR
	light.light_energy = SHOT_LIGHT_ENERGY
	light.omni_range = SHOT_LIGHT_RANGE
	light.shadow_enabled = false
	parent.add_child(light)
	light.top_level = true
	light.global_position = origin + rear_direction * SHOT_LIGHT_REAR_OFFSET

	var flash := light.create_tween()
	flash.tween_interval(SHOT_LIGHT_HOLD_DURATION)
	flash.tween_property(
		light, "light_energy", 0.0, SHOT_LIGHT_FADE_DURATION
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	flash.finished.connect(light.queue_free)


func _spawn_rear_flash(parent: Node, emission: Dictionary) -> void:
	var effect := Node3D.new()
	effect.name = "RearMuzzleFlash_%d" % int(emission.get("index", 0))
	effect.set_meta("combat_muzzle_fx", &"rear_flash")
	effect.set_meta("emission_index", int(emission.get("index", 0)))
	parent.add_child(effect)
	effect.top_level = true
	effect.global_position = Vector3(emission["rear_position"])
	var visual := _fx_quad(_rear_flash_textures.front(), REAR_FLASH_SIZE)
	visual.name = "Visual"
	effect.add_child(visual)
	var material := (visual.mesh as QuadMesh).material as StandardMaterial3D
	var animation := effect.create_tween()
	for texture in _rear_flash_textures:
		animation.tween_callback(_set_fx_texture.bind(material, texture))
		animation.tween_interval(INLINE_FX_FRAME_SECONDS)
	animation.finished.connect(effect.queue_free)


func _spawn_casing(parent: Node, emission: Dictionary, casing_index: int) -> void:
	var effect := Node3D.new()
	effect.name = "Casing_%d_%d" % [int(emission.get("index", 0)), casing_index]
	effect.set_meta("combat_muzzle_fx", &"casing")
	effect.set_meta("emission_index", int(emission.get("index", 0)))
	parent.add_child(effect)
	effect.top_level = true
	var start := Vector3(emission["rear_position"])
	effect.global_position = start
	var visual := _fx_quad(_casing_textures.front(), CASING_SIZE)
	visual.name = "Visual"
	effect.add_child(visual)
	var material := (visual.mesh as QuadMesh).material as StandardMaterial3D

	var eject_direction := Vector3(
		emission.get("rear_direction", -Vector3(emission.get("direction", Vector3.FORWARD)))
	).normalized()
	if eject_direction.is_zero_approx():
		eject_direction = Vector3.BACK
	var side := eject_direction.cross(Vector3.UP).normalized()
	if side.is_zero_approx():
		side = Vector3.RIGHT
	var side_sign := -1.0 if casing_index % 2 == 0 else 1.0
	var velocity := (
		eject_direction * (1.4 + 0.25 * casing_index)
		+ Vector3.UP * (1.55 + 0.2 * casing_index)
		+ side * (0.35 * side_sign)
	)
	var motion := effect.create_tween().set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	motion.tween_method(
		_update_casing.bind(effect, start, velocity),
		0.0,
		CASING_LIFETIME,
		CASING_LIFETIME
	)
	motion.finished.connect(effect.queue_free)
	var animation := effect.create_tween().set_loops()
	for texture in _casing_textures:
		animation.tween_callback(_set_fx_texture.bind(material, texture))
		animation.tween_interval(INLINE_FX_FRAME_SECONDS)


func _fx_quad(texture: Texture2D, size: float) -> MeshInstance3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_texture = texture
	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	quad.material = material
	var visual := MeshInstance3D.new()
	visual.mesh = quad
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return visual


func _ensure_inline_fx_textures() -> void:
	if _rear_flash_textures.is_empty():
		_rear_flash_textures = _load_fx_texture_sequence("!cexp", REAR_FLASH_FRAME_COUNT)
	if _casing_textures.is_empty():
		_casing_textures = _load_fx_texture_sequence("!%shel", CASING_FRAME_COUNT)


func _ensure_launch_smoke_textures() -> void:
	if _launch_smoke_textures.is_empty():
		_launch_smoke_textures = _load_fx_texture_sequence(
			LAUNCH_SMOKE_SEQUENCE, LAUNCH_SMOKE_FRAME_COUNT
		)


func _load_fx_texture_sequence(base_name: String, count: int) -> Array[Texture2D]:
	var result: Array[Texture2D] = []
	for frame in count:
		# Concatenate instead of %-formatting: the literal `%` in `!%shel`
		# would otherwise be interpreted as another format placeholder.
		var path := INLINE_FX_TEXTURE_DIR + "/" + base_name + str(frame) + ".tga"
		var source_texture := load(path) as Texture2D
		if source_texture == null:
			return []
		result.append(_opaque_additive_texture(source_texture))
	return result


func _opaque_additive_texture(source: Texture2D) -> Texture2D:
	var image := source.get_image()
	if image == null or image.is_empty():
		return source
	# The attribute bit in these original 16-bpp TGAs is not transparency;
	# cexp happens to decode with alpha=0 for every pixel. Their `!` prefix
	# means additive rendering, where opaque black is already invisible.
	image.convert(Image.FORMAT_RGBA8)
	var data := image.get_data()
	for alpha_index in range(3, data.size(), 4):
		data[alpha_index] = 255
	image.set_data(
		image.get_width(), image.get_height(), image.has_mipmaps(),
		Image.FORMAT_RGBA8, data
	)
	return ImageTexture.create_from_image(image)


func _set_fx_texture(material: StandardMaterial3D, texture: Texture2D) -> void:
	if material != null:
		material.albedo_texture = texture


func _update_casing(
		elapsed: float,
		effect: Node3D,
		start: Vector3,
		initial_velocity: Vector3
	) -> void:
	if effect == null or not is_instance_valid(effect):
		return
	effect.global_position = (
		start + initial_velocity * elapsed
		+ Vector3.DOWN * (0.5 * CASING_GRAVITY * elapsed * elapsed)
	)


## Rules ranges belong to the gameplay entity, not to an animated muzzle.
## Using a muzzle here makes entering range depend on whether Move, Fire or an
## elevated trajectory pose happened to run on that frame.
func _range_origin() -> Vector3:
	if _model_root == null or not is_instance_valid(_model_root):
		return Vector3.INF
	return _model_root.global_position


func _aim_origin() -> Vector3:
	for pivot in [_yaw_pivot, _root_pivot, _reference_pivot]:
		if pivot != null and is_instance_valid(pivot):
			return (pivot as Node3D).global_position
	return _range_origin()


func _muzzle_group_origin() -> Vector3:
	var points := emission_points()
	if points.is_empty():
		return Vector3.INF
	var result := Vector3.ZERO
	for point in points:
		result += Vector3(point["position"])
	return result / float(points.size())


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
