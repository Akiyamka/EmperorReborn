class_name UnitNavigationPlanner
extends RefCounted
## Owns and time-slices shared flow fields. Completion order is stable because
## one FIFO queue is advanced with a fixed expansion budget.

const UnitNavigationMapScript := preload("res://scripts/units/navigation/unit_navigation_map.gd")
const NavigationFlowFieldScript := preload("res://scripts/units/navigation/navigation_flow_field.gd")
const NavigationPathQueryScript := preload("res://scripts/units/navigation/navigation_path_query.gd")

# 256 costs about 2-3 ms for a clearance-zero field on the reference map.
# Direct unobstructed orders do not enqueue a field at all.
var expansion_budget_per_tick := 256

var _map
var _cache: Dictionary = {}
var _queue: Array = []
var _path_queue: Array = []


func setup(runtime_map) -> void:
	_map = runtime_map


func request_field(target_cell: Vector2i, pass_mask: int, clearance_cells: int, allowed_terrain_mask := 0):
	var key := _key(target_cell, pass_mask, clearance_cells, allowed_terrain_mask)
	var cached = _cache.get(key)
	if cached is NavigationFlowFieldScript:
		return cached
	var field = NavigationFlowFieldScript.new()
	field.setup(_map, target_cell, pass_mask, clearance_cells, allowed_terrain_mask)
	_cache[key] = field
	if not field.failed:
		_queue.append(field)
	return field


func request_path(start_cell: Vector2i, target_cell: Vector2i, pass_mask: int, clearance_cells: int, allowed_terrain_mask := 0):
	var query = NavigationPathQueryScript.new()
	query.setup(_map, start_cell, target_cell, pass_mask, clearance_cells, allowed_terrain_mask)
	if not query.failed:
		_path_queue.append(query)
	return query


func process() -> void:
	var remaining := expansion_budget_per_tick
	while remaining > 0 and not _path_queue.is_empty():
		var query = _path_queue.pop_front()
		if query.map_revision != _map.revision:
			continue
		var used: int = query.step(mini(remaining, 64))
		remaining -= used
		if not query.complete and not query.failed and used > 0:
			_path_queue.append(query)
	while remaining > 0 and not _queue.is_empty():
		var field = _queue.pop_front()
		if field.map_revision != _map.revision:
			continue
		var used: int = field.step(mini(remaining, 256))
		remaining -= used
		if not field.complete and not field.failed and used > 0:
			_queue.append(field)


func invalidate_dynamic_fields() -> void:
	_cache.clear()
	_queue.clear()
	_path_queue.clear()


func pending_count() -> int:
	return _queue.size() + _path_queue.size()


func _key(target_cell: Vector2i, pass_mask: int, clearance_cells: int, allowed_terrain_mask: int) -> String:
	return "%d:%d:%d:%d:%d:%d" % [target_cell.x, target_cell.y, pass_mask, clearance_cells, allowed_terrain_mask, _map.revision]
