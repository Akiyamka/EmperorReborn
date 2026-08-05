class_name CombatLingerEffect
extends Node3D

## A delivered bullet may leave a target-bound payload after the projectile
## itself has finished. Rules.txt currently uses this for GasInf_B:
## LingerDuration is measured in combat ticks and LingerDamage is delivered
## once per tick through the bullet's normal warhead/armour matrix.

const CombatTargetScript := preload("res://scripts/combat/combat_target.gd")
const CombatRulesScript := preload("res://scripts/combat/combat_rules.gd")
const RULE_COMBAT_TICKS_PER_SECOND := CombatRulesScript.TICKS_PER_SECOND
const MINIMUM_TICK_SECONDS := 0.0001

var bullet
var remaining_ticks := 0
var delivered_ticks := 0

var _tick_seconds := 1.0 / RULE_COMBAT_TICKS_PER_SECOND
var _tick_accumulator := 0.0
var _target_ref: WeakRef
var _visual: Node3D


func _init() -> void:
	set_physics_process(false)


func configure(
		bullet_payload,
		target: Object,
		world_position: Vector3
	) -> bool:
	if bullet_payload == null \
	or bullet_payload.config == null \
	or bullet_payload.linger_duration_ticks() <= 0.0 \
	or bullet_payload.linger_damage() <= 0.0:
		return false

	bullet = bullet_payload
	remaining_ticks = maxi(int(ceilf(bullet.linger_duration_ticks())), 0)
	if remaining_ticks <= 0:
		return false
	name = "Linger_%s" % String(bullet.id())
	set_meta("combat_linger_effect", bullet.id())
	top_level = true
	global_position = world_position
	if target != null and is_instance_valid(target):
		_target_ref = weakref(target)
		_follow_target()
	_create_visual()
	set_physics_process(true)
	return true


func _physics_process(delta: float) -> void:
	if remaining_ticks <= 0:
		_finish()
		return
	var target := _target()
	if target == null or not _target_is_alive(target):
		_finish()
		return
	_follow_target()
	_tick_accumulator += maxf(delta, 0.0)
	while (
		remaining_ticks > 0
		and _tick_accumulator + MINIMUM_TICK_SECONDS >= _tick_seconds
	):
		_tick_accumulator = maxf(_tick_accumulator - _tick_seconds, 0.0)
		_deliver_tick(target)
		remaining_ticks -= 1
		delivered_ticks += 1
		if not _target_is_alive(target):
			break
	if remaining_ticks <= 0 or not _target_is_alive(target):
		_finish()


func _deliver_tick(target: Object) -> void:
	if not target.has_method("combat_armour_type") \
	or not target.has_method("take_damage"):
		return
	var armour_type := StringName(String(target.call("combat_armour_type")))
	var damage: float = bullet.linger_damage_against(armour_type)
	if damage > 0.0:
		target.call("take_damage", damage, bullet.death_category())


func _target() -> Object:
	return _target_ref.get_ref() if _target_ref != null else null


func _target_is_alive(target: Object) -> bool:
	return CombatTargetScript.is_alive(target)


func _follow_target() -> void:
	var target := _target()
	if target == null:
		return
	if target.has_method("combat_aim_position"):
		var position: Variant = target.call("combat_aim_position")
		if position is Vector3 and (position as Vector3).is_finite():
			global_position = position


func _create_visual() -> void:
	if bullet.visual_scene == null:
		return
	_visual = bullet.visual_scene.instantiate() as Node3D
	if _visual == null:
		return
	_visual.name = "Visual"
	add_child(_visual)
	var player := _visual.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if player == null:
		return
	var animation_name := &"Stationary" if player.has_animation(&"Stationary") \
		else &"idle" if player.has_animation(&"idle") \
		else &"Move" if player.has_animation(&"Move") \
		else &""
	if animation_name != &"":
		player.play(animation_name)


func _finish() -> void:
	set_physics_process(false)
	if is_inside_tree() and not is_queued_for_deletion():
		queue_free()
