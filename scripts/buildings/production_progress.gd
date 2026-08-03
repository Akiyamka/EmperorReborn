class_name ProductionProgress
extends RefCounted


static func percent(
		ready: bool,
		cost: int,
		paid_cost: int,
		build_time_ticks: float,
		elapsed_ticks: float
) -> float:
	if ready:
		return 100.0
	if cost > 0:
		return clampf(float(paid_cost) * 100.0 / float(cost), 0.0, 100.0)
	if build_time_ticks > 0.0:
		return clampf(elapsed_ticks * 100.0 / build_time_ticks, 0.0, 100.0)
	return 100.0
