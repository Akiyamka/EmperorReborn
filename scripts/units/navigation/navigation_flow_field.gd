class_name NavigationFlowField
extends RefCounted
## Incrementally built integration field shared by every unit with the same
## destination and movement profile.

const UnitNavigationMapScript := preload("res://scripts/units/navigation/unit_navigation_map.gd")

const ORTHOGONAL_COST := 10
const DIAGONAL_COST := 14
const BUCKET_COUNT := 256
const UNREACHABLE := 0x7fffffff
const NEIGHBORS: Array[Vector2i] = [
	Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0),
	Vector2i(1, -1), Vector2i(1, 1), Vector2i(-1, 1), Vector2i(-1, -1),
]

var target_cell := Vector2i(-1, -1)
var pass_mask := 0
var allowed_terrain_mask := 0
var clearance_cells := 0
var map_revision := 0
var complete := false
var failed := false
var integration := PackedInt32Array()

var _map
var _static_pass := PackedInt32Array()
var _terrain := PackedInt32Array()
var _movement_cost := PackedFloat32Array()
var _blocked := PackedByteArray()
var _buckets: Array[Array] = []
var _queued_count := 0
var _current_cost := 0


func setup(runtime_map, requested_target: Vector2i, required_pass_mask: int, required_clearance: int, required_terrain_mask := 0) -> bool:
	_map = runtime_map
	pass_mask = required_pass_mask
	allowed_terrain_mask = required_terrain_mask
	clearance_cells = required_clearance
	map_revision = runtime_map.revision if runtime_map != null else 0
	if _map == null or _map.grid == null:
		failed = true
		return false
	_static_pass = _map.grid.pass_mask
	_terrain = _map.grid.terrain_type
	_movement_cost = _map.grid.movement_cost
	_blocked = _map.blocked_cells()
	target_cell = _map.nearest_passable(requested_target, pass_mask, clearance_cells, 24, allowed_terrain_mask)
	if target_cell.x < 0:
		failed = true
		return false
	integration.resize(MapNavigationGrid.NAV_SIZE * MapNavigationGrid.NAV_SIZE)
	integration.fill(UNREACHABLE)
	_buckets.resize(BUCKET_COUNT)
	for index in BUCKET_COUNT:
		_buckets[index] = []
	var target_index: int = _map.grid.cell_index(target_cell)
	integration[target_index] = 0
	_bucket_push(target_index, 0)
	return true


func step(expansion_budget: int) -> int:
	if complete or failed or expansion_budget <= 0:
		return 0
	var expanded := 0
	while expanded < expansion_budget and _queued_count > 0:
		var item := _bucket_pop()
		var index: int = item.x
		var queued_cost: int = item.y
		if queued_cost != integration[index]:
			continue
		var cell := Vector2i(index % MapNavigationGrid.NAV_SIZE, index / MapNavigationGrid.NAV_SIZE)
		for offset in NEIGHBORS:
			var neighbor := cell + offset
			if not _can_cross(cell, neighbor, offset):
				continue
			var neighbor_index: int = _map.grid.cell_index(neighbor)
			var base_cost := DIAGONAL_COST if offset.x != 0 and offset.y != 0 else ORTHOGONAL_COST
			var edge_cost := clampi(roundi(float(base_cost) * _movement_cost[neighbor_index]), 1, BUCKET_COUNT - 1)
			var candidate := queued_cost + edge_cost
			if candidate >= integration[neighbor_index]:
				continue
			integration[neighbor_index] = candidate
			_bucket_push(neighbor_index, candidate)
		expanded += 1
	if _queued_count == 0:
		complete = true
	return expanded


func has_route_from(cell: Vector2i) -> bool:
	var index: int = _map.grid.cell_index(cell) if _map != null and _map.grid != null else -1
	# Dijkstra expands outwards from the destination. A unit can start following
	# as soon as the wave reaches its cell; the rest of the map may keep building
	# within later budgets.
	return index >= 0 and integration[index] != UNREACHABLE


func next_cell(cell: Vector2i) -> Vector2i:
	if not has_route_from(cell) or cell == target_cell:
		return cell
	var best := cell
	var best_cost := integration[_map.grid.cell_index(cell)]
	for offset in NEIGHBORS:
		var candidate := cell + offset
		if not _can_cross(cell, candidate, offset):
			continue
		var cost := integration[_map.grid.cell_index(candidate)]
		if cost + 0.0001 < best_cost:
			best = candidate
			best_cost = cost
	return best


func world_direction(world_position: Vector3) -> Vector3:
	if _map == null or _map.grid == null:
		return Vector3.ZERO
	var cell: Vector2i = _map.grid.world_to_grid(world_position)
	var next := next_cell(cell)
	if next == cell:
		return Vector3.ZERO
	var point: Vector3 = _map.grid.grid_to_world(next)
	var direction: Vector3 = point - world_position
	direction.y = 0.0
	return direction.normalized()


func _can_cross(from: Vector2i, to: Vector2i, offset: Vector2i) -> bool:
	if not _cell_passable(to):
		return false
	if offset.x == 0 or offset.y == 0:
		return true
	return (
		_cell_passable(from + Vector2i(offset.x, 0))
		and _cell_passable(from + Vector2i(0, offset.y))
	)


func _cell_passable(cell: Vector2i) -> bool:
	if cell.x < 0 or cell.y < 0 or cell.x >= MapNavigationGrid.NAV_SIZE or cell.y >= MapNavigationGrid.NAV_SIZE:
		return false
	if clearance_cells > 0:
		return _map.is_passable(cell, pass_mask, clearance_cells, allowed_terrain_mask)
	var index := cell.y * MapNavigationGrid.NAV_SIZE + cell.x
	if (_static_pass[index] & pass_mask) == 0 or _blocked[index] != 0:
		return false
	return allowed_terrain_mask == 0 or (allowed_terrain_mask & (1 << _terrain[index])) != 0


func _bucket_push(index: int, cost: int) -> void:
	# Encoding cost and cell into one integer avoids allocating a Dictionary or
	# Vector for every frontier entry. BUCKET_COUNT exceeds every quantized edge
	# cost, which is the condition required by Dial's shortest-path algorithm.
	_buckets[cost % BUCKET_COUNT].append(cost * integration.size() + index)
	_queued_count += 1


func _bucket_pop() -> Vector2i:
	while _buckets[_current_cost % BUCKET_COUNT].is_empty():
		_current_cost += 1
	var encoded: int = _buckets[_current_cost % BUCKET_COUNT].pop_back()
	_queued_count -= 1
	var cost := int(encoded / integration.size())
	var index := encoded % integration.size()
	return Vector2i(index, cost)
