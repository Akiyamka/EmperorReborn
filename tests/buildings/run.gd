extends SceneTree

const BuildingQueueScript := preload("res://scripts/buildings/building_queue.gd")

var _assertions := 0
var _failures := 0
var _current_case := ""
var _completion_token := 1000


class Credits:
	var money: int

	func _init(starting_money: int) -> void:
		money = starting_money

	func spend(amount: int) -> bool:
		if amount < 0 or amount > money:
			return false
		money -= amount
		return true

	func refund(amount: int) -> void:
		money += amount


func _initialize() -> void:
	_run_case("paid and free progress", _test_paid_and_free_progress)
	_run_case("incremental charging and insufficient credits", _test_incremental_charging)
	_run_case("no catch-up while credits are absent", _test_no_catch_up_without_credits)
	_run_case("pause and resume", _test_pause_and_resume)
	_run_case("cancel refunds exactly paid credits", _test_cancel_refund)
	_run_case("ready signal and consume handoff", _test_ready_and_consume)
	_run_case("start contract", _test_start_contract)

	if _failures > 0:
		printerr("BuildingQueue tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("BuildingQueue tests: %d assertions passed" % _assertions)
	quit(0)


func _run_case(case_name: String, test: Callable) -> void:
	_current_case = case_name
	_completion_token += 1
	var token := _completion_token
	var failures_before := _failures
	var completed: Variant = test.call(token)
	if completed != token:
		_failures += 1
		printerr("FAIL: %s: case did not return its completion token" % case_name)
		return
	if _failures == failures_before:
		print("PASS: %s" % case_name)


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])


func _test_paid_and_free_progress(token: int) -> int:
	var credits = Credits.new(100)
	var paid_queue = BuildingQueueScript.new()
	_expect(paid_queue.start(&"Paid", "Paid", 60, 60.0), "a valid paid order must start")
	paid_queue.tick(0.5, credits.money, credits.spend)
	_expect(credits.money == 70, "paid construction must charge at 60 ticks per second")
	_expect(is_equal_approx(paid_queue.current_order().progress_percent(), 50.0), "paid progress must equal paid credits")

	var free_queue = BuildingQueueScript.new()
	_expect(free_queue.start(&"Free", "Free", 0, 120.0), "a valid free order must start")
	free_queue.tick(1.0, 0)
	_expect(is_equal_approx(free_queue.current_order().progress_percent(), 50.0), "free progress must use elapsed ticks")
	free_queue.tick(1.0, 0)
	_expect(free_queue.current_order().ready, "free construction must become ready at its tick duration")
	return token


func _test_incremental_charging(token: int) -> int:
	var credits = Credits.new(25)
	var queue = BuildingQueueScript.new()
	queue.start(&"Incremental", "Incremental", 100, 60.0)
	queue.tick(0.5, credits.money, credits.spend)
	_expect(queue.current_order().paid_cost == 25, "partial funds must pay only the available credits")
	_expect(credits.money == 0, "the payer must lose exactly the paid credits")
	_expect(queue.lacks_funds(), "partial payment must leave the order waiting for credits")
	_expect(is_equal_approx(queue.current_order().charge_accumulator, 0.0), "unpaid whole credits must not stay due")
	credits.refund(75)
	queue.tick(0.25, credits.money, credits.spend)
	_expect(queue.current_order().paid_cost == 50, "charging must resume incrementally after funds return")
	queue.tick(0.5, credits.money, credits.spend)
	_expect(queue.current_order().ready, "paying the full cost must make the order ready")
	_expect(credits.money == 0, "all charged credits must be spent exactly once")
	return token


func _test_no_catch_up_without_credits(token: int) -> int:
	var credits = Credits.new(0)
	var queue = BuildingQueueScript.new()
	_expect(queue.start(&"NoCatchUp", "NoCatchUp", 100, 60.0), "a paid order must start without credits")
	queue.tick(0.75, credits.money, credits.spend)
	_expect(queue.lacks_funds(), "a zero-credit tick must enter the waiting-for-credits state")
	_expect(is_equal_approx(queue.current_order().progress_percent(), 0.0), "absent credits must not advance paid progress")
	credits.refund(100)
	queue.tick(0.25, credits.money, credits.spend)
	_expect(queue.current_order().paid_cost == 25, "returning credits must charge only the current tick")
	_expect(credits.money == 75, "the missed zero-credit duration must not be charged later")
	_expect(not queue.lacks_funds(), "a successful current charge must leave waiting-for-credits state")
	_expect(is_equal_approx(queue.current_order().progress_percent(), 25.0), "progress must reflect only the current tick payment")
	return token


func _test_pause_and_resume(token: int) -> int:
	var credits = Credits.new(100)
	var queue = BuildingQueueScript.new()
	queue.start(&"Paused", "Paused", 0, 60.0)
	_expect(queue.pause(), "a running order must pause")
	queue.tick(1.0, credits.money, credits.spend)
	_expect(is_equal_approx(queue.current_order().progress_percent(), 0.0), "paused construction must not advance")
	_expect(queue.resume(), "a paused order must resume")
	queue.tick(1.0, credits.money, credits.spend)
	_expect(queue.current_order().ready, "resumed construction must advance normally")
	_expect(not queue.pause(), "a ready order must not pause")
	return token


func _test_cancel_refund(token: int) -> int:
	var credits = Credits.new(100)
	var queue = BuildingQueueScript.new()
	queue.start(&"Canceled", "Canceled", 100, 60.0)
	queue.tick(0.25, credits.money, credits.spend)
	var refund := queue.cancel()
	credits.refund(refund)
	_expect(refund == 25, "cancel must return exactly the paid amount")
	_expect(credits.money == 100, "refunding the returned amount must restore only paid credits")
	_expect(not queue.has_order(), "cancel must clear the order")
	_expect(queue.cancel() == 0, "cancel without an order must refund nothing")
	return token


func _test_ready_and_consume(token: int) -> int:
	var queue = BuildingQueueScript.new()
	var ready_events := [0]
	queue.order_ready.connect(func(_order) -> void: ready_events[0] += 1)
	queue.start(&"Ready", "Ready", 0, 60.0)
	queue.tick(1.0, 0)
	queue.tick(1.0, 0)
	_expect(ready_events[0] == 1, "ready must emit exactly once")
	var ready_order = queue.take_ready()
	_expect(ready_order != null and ready_order.building_id == &"Ready", "take_ready must hand off the ready order")
	_expect(not queue.has_order(), "take_ready must consume the queue order")
	_expect(queue.take_ready() == null, "a ready order must be consumed only once")
	return token


func _test_start_contract(token: int) -> int:
	var queue = BuildingQueueScript.new()
	_expect(not queue.start(&"", "Missing id", 0, 60.0), "an empty building id must be rejected")
	_expect(not queue.start(&"InvalidCost", "Invalid", -1, 60.0), "a negative cost must be rejected")
	_expect(not queue.start(&"InvalidTime", "Invalid", 0, 0.0), "a non-positive build duration must be rejected")
	_expect(queue.start(&"First", "First", 0, 60.0), "a valid order must start after rejected inputs")
	_expect(not queue.start(&"Second", "Second", 0, 60.0), "a duplicate queue start must be rejected")
	return token
