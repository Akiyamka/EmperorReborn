class_name BuildingOrder
extends RefCounted

var building_id: StringName
var display_name := ""
var cost := 0
var build_time_ticks := 0.0
var paid_cost := 0
var elapsed_ticks := 0.0
var charge_accumulator := 0.0
var manually_paused := false
var ready := false


func progress_percent() -> float:
	if ready:
		return 100.0
	if cost > 0:
		return clampf(float(paid_cost) * 100.0 / float(cost), 0.0, 100.0)
	if build_time_ticks > 0.0:
		return clampf(elapsed_ticks * 100.0 / build_time_ticks, 0.0, 100.0)
	return 100.0
