class_name NavigationPathQuery
extends RefCounted
## Incremental weighted A* for individual units and small groups. Unlike a
## destination-centred flow field it explores only a narrow start-goal corridor.

const UnitNavigationMapScript := preload("res://scripts/units/navigation/unit_navigation_map.gd")

const ORTHOGONAL_COST := 10
const DIAGONAL_COST := 14
const UNREACHABLE := 0x7fffffff
const NEIGHBORS: Array[Vector2i] = [
	Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0),
	Vector2i(1, -1), Vector2i(1, 1), Vector2i(-1, 1), Vector2i(-1, -1),
]

var start_cell := Vector2i(-1, -1)
var target_cell := Vector2i(-1, -1)
var map_revision := 0
var complete := false
var failed := false
var cells: Array[Vector2i] = []

var _map
var _pass_mask := 0
var _clearance := 0
var _terrain_mask := 0
var _g_score := PackedInt32Array()
var _came_from := PackedInt32Array()
var _closed := PackedByteArray()
var _heap_indices: Array[int] = []
var _heap_priorities: Array[int] = []
var _static_pass := PackedInt32Array()
var _terrain := PackedInt32Array()
var _movement_cost := PackedFloat32Array()
var _blocked := PackedByteArray()


func setup(runtime_map, requested_start: Vector2i, requested_target: Vector2i, pass_mask: int, clearance: int, terrain_mask := 0) -> bool:
	_map = runtime_map
	_pass_mask = pass_mask
	_clearance = clearance
	_terrain_mask = terrain_mask
	map_revision = runtime_map.revision if runtime_map != null else 0
	if _map == null or _map.grid == null:
		failed = true
		return false
	start_cell = _map.nearest_passable(requested_start, pass_mask, clearance, 8, terrain_mask)
	target_cell = _map.nearest_passable(requested_target, pass_mask, clearance, 24, terrain_mask)
	if start_cell.x < 0 or target_cell.x < 0:
		failed = true
		return false
	_static_pass = _map.grid.pass_mask
	_terrain = _map.grid.terrain_type
	_movement_cost = _map.grid.movement_cost
	_blocked = _map.blocked_cells()
	var total := MapNavigationGrid.NAV_SIZE * MapNavigationGrid.NAV_SIZE
	_g_score.resize(total)
	_g_score.fill(UNREACHABLE)
	_came_from.resize(total)
	_came_from.fill(-1)
	_closed.resize(total)
	var start_index := _index(start_cell)
	_g_score[start_index] = 0
	_heap_push(start_index, _heuristic(start_cell))
	return true


func step(expansion_budget: int) -> int:
	if complete or failed or expansion_budget <= 0:
		return 0
	var expanded := 0
	while expanded < expansion_budget and not _heap_indices.is_empty():
		var current_index := _heap_pop()
		if _closed[current_index] != 0:
			continue
		_closed[current_index] = 1
		var current := _cell(current_index)
		if current == target_cell:
			_reconstruct(current_index)
			complete = true
			return expanded + 1
		for offset in NEIGHBORS:
			var neighbor := current + offset
			if not _can_cross(current, neighbor, offset):
				continue
			var neighbor_index := _index(neighbor)
			if _closed[neighbor_index] != 0:
				continue
			var base_cost := DIAGONAL_COST if offset.x != 0 and offset.y != 0 else ORTHOGONAL_COST
			var edge_cost := maxi(1, roundi(float(base_cost) * _movement_cost[neighbor_index]))
			var candidate := _g_score[current_index] + edge_cost
			if candidate >= _g_score[neighbor_index]:
				continue
			_g_score[neighbor_index] = candidate
			_came_from[neighbor_index] = current_index
			_heap_push(neighbor_index, candidate + _heuristic(neighbor))
		expanded += 1
	if _heap_indices.is_empty():
		failed = true
	return expanded


func _reconstruct(target_index: int) -> void:
	var reverse: Array[Vector2i] = []
	var current := target_index
	while current >= 0:
		reverse.append(_cell(current))
		current = _came_from[current]
	reverse.reverse()
	cells = reverse


func _heuristic(cell: Vector2i) -> int:
	var dx := absi(target_cell.x - cell.x)
	var dy := absi(target_cell.y - cell.y)
	return DIAGONAL_COST * mini(dx, dy) + ORTHOGONAL_COST * absi(dx - dy)


func _can_cross(from: Vector2i, to: Vector2i, offset: Vector2i) -> bool:
	if not _cell_passable(to):
		return false
	if offset.x == 0 or offset.y == 0:
		return true
	return _cell_passable(from + Vector2i(offset.x, 0)) and _cell_passable(from + Vector2i(0, offset.y))


func _cell_passable(cell: Vector2i) -> bool:
	if cell.x < 0 or cell.y < 0 or cell.x >= MapNavigationGrid.NAV_SIZE or cell.y >= MapNavigationGrid.NAV_SIZE:
		return false
	if _clearance > 0:
		return _map.is_passable(cell, _pass_mask, _clearance, _terrain_mask)
	var index := _index(cell)
	if (_static_pass[index] & _pass_mask) == 0 or _blocked[index] != 0:
		return false
	return _terrain_mask == 0 or (_terrain_mask & (1 << _terrain[index])) != 0


func _heap_push(index: int, priority: int) -> void:
	_heap_indices.append(index)
	_heap_priorities.append(priority)
	var child := _heap_indices.size() - 1
	while child > 0:
		var parent := int((child - 1) / 2)
		if not _heap_less(child, parent):
			break
		_heap_swap(child, parent)
		child = parent


func _heap_pop() -> int:
	var result := _heap_indices[0]
	var last_index: int = _heap_indices.pop_back()
	var last_priority: int = _heap_priorities.pop_back()
	if _heap_indices.is_empty():
		return result
	_heap_indices[0] = last_index
	_heap_priorities[0] = last_priority
	var parent := 0
	while true:
		var left := parent * 2 + 1
		if left >= _heap_indices.size():
			break
		var right := left + 1
		var child := right if right < _heap_indices.size() and _heap_less(right, left) else left
		if not _heap_less(child, parent):
			break
		_heap_swap(child, parent)
		parent = child
	return result


func _heap_less(a: int, b: int) -> bool:
	if _heap_priorities[a] != _heap_priorities[b]:
		return _heap_priorities[a] < _heap_priorities[b]
	return _heap_indices[a] < _heap_indices[b]


func _heap_swap(a: int, b: int) -> void:
	var index := _heap_indices[a]
	_heap_indices[a] = _heap_indices[b]
	_heap_indices[b] = index
	var priority := _heap_priorities[a]
	_heap_priorities[a] = _heap_priorities[b]
	_heap_priorities[b] = priority


func _index(cell: Vector2i) -> int:
	return cell.y * MapNavigationGrid.NAV_SIZE + cell.x


func _cell(index: int) -> Vector2i:
	return Vector2i(index % MapNavigationGrid.NAV_SIZE, int(index / MapNavigationGrid.NAV_SIZE))
