class_name BuildingCombat
extends RefCounted

const CombatTargetScript := preload("res://scripts/combat/combat_target.gd")
const CombatTurretScript := preload("res://scripts/combat/combat_turret.gd")

enum PopupState { RETRACTED, DEPLOYING, DEPLOYED, UNDEPLOYING }

const AUTO_TARGET_REFRESH_SECONDS := 0.25
const POPUP_TURRET_ROLE := &"PopupTurret"
const POPUP_DEPLOY_ANIMATION := &"Deploy_Gun"
const POPUP_HOLD_ANIMATION := &"Deploy_Gun_Hold"
const POPUP_UNDEPLOY_ANIMATION := &"Undeploy_Gun"
const DEFENSIVE_TURRET_IDS: Array[StringName] = [
	&"HKFlameTurret", &"TLTurret", &"HKGunTurret", &"ORGasTurret",
	&"ORPopUpTurret", &"ATPillbox", &"ATRocketTurret",
]

var _owner: Node3D
var _fire_controller
var _has_order := false
var _is_ground := false
var _ground_position := Vector3.INF
var _target_ref: WeakRef
var _automatic_ref: WeakRef
var _automatic_cooldown := 0.0
var _popup_state := PopupState.RETRACTED
var _transition_player: AnimationPlayer
var _transition_animation: StringName = &""
var _transition_elapsed := 0.0
var _transition_duration := 0.0


func configure(owner: Node3D, fire_controller) -> void:
	_owner = owner
	_fire_controller = fire_controller


func advance(delta: float) -> void:
	_automatic_cooldown = maxf(_automatic_cooldown - maxf(delta, 0.0), 0.0)
	_advance_popup_transition(delta)
	restore_popup_hold_pose()
	_advance_engagement(delta)
	# The engagement and authored animation may both alter the active model.
	# Restore once on each side so aiming sees the hold pose and the rendered
	# frame retains it after the authored controller advances on the facade.


func after_authored_advance() -> void:
	restore_popup_hold_pose()


func can_attack(target_or_position: Variant) -> bool:
	if not _is_operational():
		return false
	for turret in _owner.combat_turrets:
		if turret.can_target(target_or_position):
			return true
	return false


func command_attack(target_or_position: Variant) -> bool:
	if not can_attack(target_or_position):
		return false
	_fire_controller.cancel()
	_has_order = true
	_is_ground = target_or_position is Vector3
	_ground_position = target_or_position if _is_ground else Vector3.INF
	_target_ref = null if _is_ground else weakref(target_or_position as Object)
	_automatic_ref = null
	_automatic_cooldown = 0.0
	_owner.call("_emit_attack_order_changed", true, target_or_position)
	return true


func cancel_order() -> void:
	if _fire_controller != null:
		_fire_controller.cancel()
	_automatic_ref = null
	_automatic_cooldown = 0.0
	if not _has_order:
		return
	_has_order = false
	_is_ground = false
	_ground_position = Vector3.INF
	_target_ref = null
	_owner.call("_emit_attack_order_changed", false, null)


func cancel_all_orders() -> bool:
	if not _has_order:
		return false
	cancel_order()
	return true


func has_order() -> bool:
	return _has_order


func order_target() -> Variant:
	if not _has_order:
		return null
	if _is_ground:
		return _ground_position
	return _target_ref.get_ref() if _target_ref != null else null


func popup_state() -> int:
	return _popup_state


func active_animation_player(animation_name: StringName) -> AnimationPlayer:
	return _active_animation_player(animation_name)


func reset_popup_transition() -> void:
	_popup_state = PopupState.RETRACTED
	_transition_player = null
	_transition_animation = &""
	_transition_elapsed = 0.0
	_transition_duration = 0.0


func bind_model(model_root: Node3D) -> void:
	_fire_controller.cancel()
	reset_popup_transition()
	for turret in _owner.combat_turrets:
		turret.bind_model(model_root, turret.weapon_index())
		if model_root != null:
			for node in model_root.find_children("*", "AnimationPlayer", true, false):
				var player := node as AnimationPlayer
				player.process_priority = mini(player.process_priority, _owner.process_priority - 1)
	if not _owner.combat_turrets.is_empty():
		_fire_controller.configure(_owner, _owner.combat_turrets.front(), model_root)


func restore_popup_hold_pose() -> void:
	if not _uses_popup_turret() or _popup_state != PopupState.DEPLOYED \
		or _fire_controller.is_active():
		return
	var player := _active_animation_player(POPUP_HOLD_ANIMATION)
	if player == null:
		return
	player.stop(true)
	player.play(POPUP_HOLD_ANIMATION)
	player.advance(0.0)
	player.pause()
	for turret in _owner.combat_turrets:
		turret.restore_aim_pose()


func _advance_engagement(delta: float) -> void:
	if not _is_operational() or _owner.combat_turrets.is_empty():
		return
	var turret = _owner.combat_turrets.front()
	var target: Variant = order_target()
	if _has_order and ((not _is_ground and not CombatTargetScript.is_alive(target)) \
		or not _target_position(target).is_finite()):
		cancel_order()
		target = null
	if target == null or not turret.has_line_of_fire(target, _owner):
		target = _automatic_target_for(turret)

	var target_in_range: bool = target != null and turret.target_range(target) \
		== CombatTurretScript.TargetRange.IN_RANGE
	var target_position := _target_position(target) if target_in_range else Vector3.INF
	if target_in_range and turret.requires_hull_turn_for(target_position):
		target_in_range = false

	if _uses_popup_turret():
		if _popup_state in [PopupState.DEPLOYING, PopupState.UNDEPLOYING]:
			return
		if target_in_range and _popup_state == PopupState.RETRACTED:
			_begin_popup_transition(true)
			return
		if not target_in_range and _popup_state == PopupState.DEPLOYED \
			and not _fire_controller.is_active():
			if turret.recenter(delta):
				_begin_popup_transition(false)
			return
		if _popup_state != PopupState.DEPLOYED:
			return

	if not target_in_range:
		if not _fire_controller.is_active():
			turret.recenter(delta)
		return
	var aimed := bool(turret.aim_at(target_position, delta))
	if _owner.config_id == &"ATRocketTurret":
		aimed = bool(turret.is_group_yaw_aimed_at(target_position))
	if not aimed or _fire_controller.is_active():
		return
	if _fire_controller.try_start(target) or _fire_controller.has_fire_animation():
		return
	var projectiles: Array = turret.try_fire_at(target, _owner)
	if not projectiles.is_empty():
		_owner.call("_emit_weapon_fired", projectiles, target, turret.weapon_index())


func _automatic_target_for(turret) -> Variant:
	var cached: Variant = _automatic_ref.get_ref() if _automatic_ref != null else null
	if _automatic_target_is_usable(turret, cached):
		return cached
	if _automatic_cooldown > 0.0:
		return null
	_automatic_cooldown = AUTO_TARGET_REFRESH_SECONDS
	var tree := _owner.get_tree()
	if tree == null:
		return null
	var best_target: Node3D
	var best_distance := INF
	var candidates: Array[Node] = []
	candidates.append_array(tree.get_nodes_in_group(&"units"))
	candidates.append_array(tree.get_nodes_in_group(&"buildings"))
	for candidate_node in candidates:
		if not candidate_node is Node3D or candidate_node == _owner:
			continue
		var candidate := candidate_node as Node3D
		if not _automatic_target_is_usable(turret, candidate):
			continue
		var distance := _owner.global_position.distance_squared_to(candidate.global_position)
		if distance < best_distance or (is_equal_approx(distance, best_distance) \
			and best_target != null \
			and candidate.get_instance_id() < best_target.get_instance_id()):
			best_distance = distance
			best_target = candidate
	_automatic_ref = weakref(best_target) if best_target != null else null
	return best_target


func _automatic_target_is_usable(turret, target: Variant) -> bool:
	if not target is Node3D or not is_instance_valid(target):
		return false
	var candidate := target as Node3D
	if not CombatTargetScript.is_alive(candidate) or not candidate.has_method("is_enemy_of") \
		or not bool(candidate.call("is_enemy_of", _owner.owner_player_id)):
		return false
	if turret.target_range(candidate) != CombatTurretScript.TargetRange.IN_RANGE:
		return false
	var target_position := _target_position(candidate)
	return target_position.is_finite() \
		and not turret.requires_hull_turn_for(target_position) \
		and turret.has_line_of_fire(candidate, _owner)


func _target_position(target: Variant) -> Vector3:
	return CombatTargetScript.position_of(target, _owner.global_position)


func _is_operational() -> bool:
	return _owner.config_id in DEFENSIVE_TURRET_IDS \
		and _owner.is_construction_complete() and _owner.health > 0.0 \
		and not _owner.is_queued_for_deletion() and not _owner.combat_turrets.is_empty()


func _uses_popup_turret() -> bool:
	return _owner.building_definition != null \
		and POPUP_TURRET_ROLE in _owner.building_definition.roles


func _begin_popup_transition(deploying: bool) -> void:
	var animation_name := POPUP_DEPLOY_ANIMATION if deploying else POPUP_UNDEPLOY_ANIMATION
	var player := _active_animation_player(animation_name)
	if player == null:
		_popup_state = PopupState.DEPLOYED if deploying else PopupState.RETRACTED
		return
	var animation := player.get_animation(animation_name)
	if animation == null:
		return
	_fire_controller.cancel()
	_popup_state = PopupState.DEPLOYING if deploying else PopupState.UNDEPLOYING
	_transition_player = player
	_transition_animation = animation_name
	_transition_elapsed = 0.0
	_transition_duration = animation.length
	player.speed_scale = 1.0
	player.stop(true)
	player.play(animation_name)


func _advance_popup_transition(delta: float) -> void:
	if _popup_state not in [PopupState.DEPLOYING, PopupState.UNDEPLOYING]:
		return
	if _transition_player == null or not is_instance_valid(_transition_player):
		_finish_popup_transition()
		return
	_transition_elapsed = minf(_transition_elapsed + maxf(delta, 0.0), _transition_duration)
	if _transition_elapsed + 0.0001 < _transition_duration:
		return
	var animation := _transition_player.get_animation(_transition_animation)
	if animation != null:
		_transition_player.seek(animation.length, true)
	_transition_player.pause()
	_finish_popup_transition()


func _finish_popup_transition() -> void:
	var was_deploying := _popup_state == PopupState.DEPLOYING
	var player := _transition_player
	_popup_state = PopupState.DEPLOYED if was_deploying else PopupState.RETRACTED
	_transition_player = null
	_transition_animation = &""
	_transition_elapsed = 0.0
	_transition_duration = 0.0
	if was_deploying and player != null and player.has_animation(POPUP_HOLD_ANIMATION):
		player.stop(true)
		player.play(POPUP_HOLD_ANIMATION)
		player.advance(0.0)
		player.pause()
	for turret in _owner.combat_turrets:
		turret.capture_current_rest_pose()


func _active_animation_player(animation_name: StringName) -> AnimationPlayer:
	var state_root: Node3D = _owner.call("state_root", _owner.current_state)
	if state_root == null:
		return null
	for node in state_root.find_children("*", "AnimationPlayer", true, false):
		var player := node as AnimationPlayer
		if player.has_animation(animation_name):
			return player
	return null
