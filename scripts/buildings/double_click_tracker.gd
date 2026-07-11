class_name DoubleClickTracker
extends RefCounted

## Pure double-click detection, decoupled from raycasting/input so it can be
## unit tested without a scene tree. Two clicks on the same (equality-
## comparable) target within `threshold_ms` count as a double click.

var _last_target: Variant
var _last_click_ms := -1


func register_click(target: Variant, now_ms: int, threshold_ms: int) -> bool:
	var is_double: bool = (
		_last_target == target
		and _last_click_ms >= 0
		and now_ms - _last_click_ms <= threshold_ms
	)
	if is_double:
		_last_target = null
		_last_click_ms = -1
	else:
		_last_target = target
		_last_click_ms = now_ms
	return is_double
