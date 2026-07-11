class_name UpgradeQueue
extends RefCounted

## docs/mechanics/production.md section 4 "Upgrades": upgrades have their own
## queue, one per player -- as opposed to BuildingQueue (also one per player,
## but for buildings) and per-building-type unit queues. The gradual-payment
## tick logic is identical to BuildingQueue's, so this is kept as a parallel
## copy rather than sharing a base class: callers get a display API
## (UpgradeOrder) with upgrade-specific fields (kind, target_refinery)
## instead of forcing building- and upgrade-shaped orders through one type.

signal order_ready(order: UpgradeOrder)

const UpgradeOrderScript := preload("res://scripts/buildings/upgrade_order.gd")
const BUILD_TICKS_PER_SECOND := 60.0

var _order: UpgradeOrder
var _lack_funds := false


func has_order() -> bool:
	return _order != null


func current_order() -> UpgradeOrder:
	return _order


func lacks_funds() -> bool:
	return _lack_funds


func start(
		upgrade_id: StringName,
		display_name: String,
		cost: int,
		build_time_ticks: float,
		kind: UpgradeOrder.Kind = UpgradeOrder.Kind.GLOBAL_TYPE,
		target_refinery: Node3D = null
) -> bool:
	if _order != null or upgrade_id == &"" or cost < 0 or build_time_ticks <= 0.0:
		return false

	_order = UpgradeOrderScript.new()
	_order.kind = kind
	_order.upgrade_id = upgrade_id
	_order.display_name = display_name
	_order.cost = cost
	_order.build_time_ticks = build_time_ticks
	_order.target_refinery = target_refinery
	_lack_funds = false
	return true


func tick(delta: float, available_credits: int, spend_credits: Callable = Callable()) -> bool:
	if _order == null or _order.ready or _order.manually_paused:
		return false

	if _order.cost <= 0:
		_order.elapsed_ticks += delta * BUILD_TICKS_PER_SECOND
		if _order.elapsed_ticks >= _order.build_time_ticks:
			_mark_ready()
		return true

	if available_credits <= 0:
		return _set_lack_funds(true)

	var changed := _set_lack_funds(false)
	var remaining_cost := _order.cost - _order.paid_cost
	if remaining_cost <= 0:
		_mark_ready()
		return true

	var build_seconds := _order.build_time_ticks / BUILD_TICKS_PER_SECOND
	var credits_per_second := float(_order.cost) / build_seconds
	_order.charge_accumulator += delta * credits_per_second

	var credits_due := mini(int(floor(_order.charge_accumulator)), remaining_cost)
	if credits_due <= 0:
		return changed

	var credits_paid := mini(credits_due, available_credits)
	_order.charge_accumulator -= float(credits_due)
	if credits_paid <= 0 or spend_credits.is_null() or not bool(spend_credits.call(credits_paid)):
		return _set_lack_funds(true) or changed

	_order.paid_cost += credits_paid
	if credits_paid < credits_due:
		changed = _set_lack_funds(true) or changed

	if _order.paid_cost >= _order.cost:
		_mark_ready()
		return true
	return true


func pause() -> bool:
	if _order == null or _order.ready or _order.manually_paused:
		return false
	_order.manually_paused = true
	_lack_funds = false
	return true


func resume() -> bool:
	if _order == null or _order.ready or not _order.manually_paused:
		return false
	_order.manually_paused = false
	_lack_funds = false
	return true


func cancel() -> int:
	if _order == null:
		return 0
	var refund := _order.paid_cost
	_order = null
	_lack_funds = false
	return refund


func take_ready() -> UpgradeOrder:
	if _order == null or not _order.ready:
		return null
	var ready_order := _order
	_order = null
	_lack_funds = false
	return ready_order


func _set_lack_funds(value: bool) -> bool:
	if _lack_funds == value:
		return false
	_lack_funds = value
	return true


func _mark_ready() -> void:
	if _order == null or _order.ready:
		return
	_order.ready = true
	_order.manually_paused = false
	_lack_funds = false
	order_ready.emit(_order)
