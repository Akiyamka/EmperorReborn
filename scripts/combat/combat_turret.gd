class_name CombatTurret
extends RefCounted

const CombatBulletScript := preload("res://scripts/combat/combat_bullet.gd")

## A turret owns readiness/reload state and emits one or more configured
## bullets. Aiming and physical projectile travel are deliberately outside this
## first combat slice; they can consume the emitted CombatBullet instances.

var config: Resource
var firing_config: Resource
var bullet_config: Resource
var warhead_config: Resource
var reload_ticks_remaining := 0.0


func configure_from_rules(turret_config: Resource, rules: Object) -> bool:
	config = turret_config
	firing_config = _firing_joint(turret_config, rules)
	bullet_config = null
	warhead_config = null
	reload_ticks_remaining = 0.0
	if firing_config == null or rules == null:
		return false

	var bullet_id := StringName(String(firing_config.field(&"bullet", "")))
	if bullet_id == &"":
		return false
	bullet_config = rules.call("bullet", bullet_id)
	if bullet_config == null:
		return false

	var warhead_id := StringName(String(bullet_config.field(&"warhead", "")))
	if warhead_id != &"":
		warhead_config = rules.call("warhead", warhead_id)
	return true


func is_configured() -> bool:
	return config != null and firing_config != null and bullet_config != null


func is_ready() -> bool:
	return is_configured() and reload_ticks_remaining <= 0.0


func reload_count() -> float:
	return maxf(float(firing_config.field(&"reload_count", 0.0)), 0.0) \
		if firing_config != null else 0.0


func advance_ticks(ticks: float) -> void:
	if ticks <= 0.0 or reload_ticks_remaining <= 0.0:
		return
	reload_ticks_remaining = maxf(reload_ticks_remaining - ticks, 0.0)


func try_fire() -> Array:
	var result: Array = []
	if not is_ready():
		return result

	var bullet_count := maxi(int(firing_config.field(&"turret_bullet_count", 1)), 1)
	for index in bullet_count:
		result.append(CombatBulletScript.new(bullet_config, warhead_config))
	reload_ticks_remaining = reload_count()
	return result


func _firing_joint(turret_config: Resource, rules: Object) -> Resource:
	var current := turret_config
	var visited: Dictionary = {}
	while current != null:
		var current_id := String(current.get("id"))
		if not current_id.is_empty():
			if visited.has(current_id):
				return null
			visited[current_id] = true
		if not String(current.field(&"bullet", "")).is_empty():
			return current
		var next_joint := StringName(String(current.field(&"turret_next_joint", "")))
		if next_joint == &"" or rules == null:
			return null
		current = rules.call("turret", next_joint)
	return null
