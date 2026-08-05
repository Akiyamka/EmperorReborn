class_name BuildingRepairService
extends RefCounted

const RULE_TICKS_PER_SECOND := 25.0
const TICK_INTERVAL_SECONDS := 10.0 / RULE_TICKS_PER_SECOND
const COST_FRACTION := 1.0 / 3.0

var _credit_carry: Dictionary = {}
var _tick_elapsed := 0.0


func process(
		delta: float,
		buildings: Array[Node],
		repair_health: float,
		player,
		config_of: Callable
) -> void:
	_tick_elapsed += delta
	if _tick_elapsed < TICK_INTERVAL_SECONDS:
		return
	var ticks := floori(_tick_elapsed / TICK_INTERVAL_SECONDS)
	_tick_elapsed -= float(ticks) * TICK_INTERVAL_SECONDS
	for _tick in ticks:
		_process_tick(buildings, repair_health, player, config_of)


func set_repairing(building: Node3D, active: bool) -> void:
	if &"is_repairing" in building:
		building.set("is_repairing", active)
	if not active:
		_credit_carry.erase(building.get_instance_id())


func _process_tick(
		buildings: Array[Node], repair_health: float, player, config_of: Callable
) -> void:
	for node in buildings:
		var building := node as Node3D
		if building == null or not (&"is_repairing" in building \
			and bool(building.get("is_repairing"))):
			continue
		var max_health := float(building.get("max_health")) \
			if &"max_health" in building else 0.0
		var missing_health := maxf(max_health - float(building.get("health")), 0.0) \
			if &"health" in building else 0.0
		if max_health <= 0.0 or missing_health <= 0.0:
			set_repairing(building, false)
			continue
		var restored := minf(repair_health, missing_health)
		var config = config_of.call(building)
		var building_cost := float(config.cost) if config != null else 0.0
		var repair_cost := restored / max_health * building_cost * COST_FRACTION
		var carry := float(_credit_carry.get(building.get_instance_id(), 0.0)) + repair_cost
		var charge := floori(carry)
		if charge > 0 and (player == null or not player.spend_money(charge)):
			continue
		_credit_carry[building.get_instance_id()] = carry - float(charge)
		building.set("health", float(building.get("health")) + restored)
		if float(building.get("health")) >= max_health:
			set_repairing(building, false)
