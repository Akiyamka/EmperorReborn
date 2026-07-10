class_name BuildingQueue
extends RefCounted

signal order_ready(order: BuildingOrder)

const BuildingOrderScript := preload("res://scripts/buildings/building_order.gd")
const BUILD_TICKS_PER_SECOND := 60.0

var _order: BuildingOrder
var _lack_funds := false


func has_order() -> bool:
	return _order != null


func current_order() -> BuildingOrder:
	return _order


func lacks_funds() -> bool:
	return _lack_funds


func start(building_id: StringName, display_name: String, cost: int, build_time_ticks: float) -> bool:
	if _order != null or building_id == &"" or cost < 0 or build_time_ticks <= 0.0:
		return false

	_order = BuildingOrderScript.new()
	_order.building_id = building_id
	_order.display_name = display_name
	_order.cost = cost
	_order.build_time_ticks = build_time_ticks
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


func take_ready() -> BuildingOrder:
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
