class_name UnitNavigationMap
extends RefCounted
## Runtime facade over the baked map. Static terrain stays immutable while
## buildings and other persistent obstacles live in a cheap revisioned overlay.

var grid: MapNavigationGrid
var revision := 0

var _blocked := PackedByteArray()


func setup(source_grid: MapNavigationGrid) -> bool:
	grid = source_grid
	if grid == null or not grid.is_loaded():
		return false
	_blocked.resize(MapNavigationGrid.NAV_SIZE * MapNavigationGrid.NAV_SIZE)
	_blocked.fill(0)
	revision = 1
	return true


func replace_blocked_cells(cells: Dictionary) -> bool:
	if grid == null:
		return false
	var next := PackedByteArray()
	next.resize(_blocked.size())
	for value in cells.keys():
		if value is Vector2i:
			var index := grid.cell_index(value)
			if index >= 0:
				next[index] = 1
	if next == _blocked:
		return false
	_blocked = next
	revision += 1
	return true


func is_blocked(cell: Vector2i) -> bool:
	var index := grid.cell_index(cell) if grid != null else -1
	return index < 0 or _blocked[index] != 0


func blocked_cells() -> PackedByteArray:
	return _blocked


func is_passable(cell: Vector2i, pass_mask: int, clearance_cells := 0, allowed_terrain_mask := 0) -> bool:
	if grid == null or not grid.is_passable(cell, pass_mask):
		return false
	for y in range(-clearance_cells, clearance_cells + 1):
		for x in range(-clearance_cells, clearance_cells + 1):
			var sample := cell + Vector2i(x, y)
			if not grid.is_passable(sample, pass_mask) or is_blocked(sample):
				return false
			if allowed_terrain_mask != 0 and (allowed_terrain_mask & (1 << grid.terrain_at(sample))) == 0:
				return false
	return true


func movement_cost(cell: Vector2i) -> float:
	return grid.cost_at(cell) if grid != null else INF


func nearest_passable(origin: Vector2i, pass_mask: int, clearance_cells: int, max_radius := 24, allowed_terrain_mask := 0) -> Vector2i:
	if is_passable(origin, pass_mask, clearance_cells, allowed_terrain_mask):
		return origin
	for radius in range(1, max_radius + 1):
		for x in range(-radius, radius + 1):
			for y in [-radius, radius]:
				var candidate := origin + Vector2i(x, y)
				if is_passable(candidate, pass_mask, clearance_cells, allowed_terrain_mask):
					return candidate
		for y in range(-radius + 1, radius):
			for x in [-radius, radius]:
				var candidate := origin + Vector2i(x, y)
				if is_passable(candidate, pass_mask, clearance_cells, allowed_terrain_mask):
					return candidate
	return Vector2i(-1, -1)
