class_name UnitNavigationPlanner
extends RefCounted
## Synchronous path provider backed by the native AStarGrid2D. One grid is kept
## per movement profile (pass mask, clearance, terrain mask); clearance is
## folded into the grid once as an eroded solidity map so queries stay O(1) per
## cell instead of scanning a (2c+1)^2 window.

const UnitNavigationMapScript := preload("res://scripts/units/navigation/unit_navigation_map.gd")

var _map
var _profiles: Dictionary = {}


func setup(runtime_map) -> void:
	_map = runtime_map
	_profiles.clear()


## Builds the profile grid ahead of time so the first movement order does not
## pay the one-off solidity bake.
func prewarm(pass_mask: int, clearance_cells: int, allowed_terrain_mask := 0) -> void:
	_profile(pass_mask, clearance_cells, allowed_terrain_mask)


## Cells around a redirected target are searched for a substitute within this
## many Chebyshev rings before giving up and falling back to the (expensive)
## allow_partial_path flood.
const UNREACHABLE_REDIRECT_RADIUS := 64

## Returns grid cells from start to target inclusive. When the target is
## unreachable the path leads to the closest reachable cell, matching the
## original game's "walk as far as possible" behaviour. Empty when no start
## cell is available.
func find_path(
		start_cell: Vector2i,
		target_cell: Vector2i,
		pass_mask: int,
		clearance_cells: int,
		allowed_terrain_mask := 0,
		stoppable_no_stop_cells: Dictionary = {}
	) -> Array[Vector2i]:
	var profile := _profile(pass_mask, clearance_cells, allowed_terrain_mask)
	if profile.is_empty():
		return []
	var solid: PackedByteArray = profile["solid"]
	var snapped_start := _nearest_open(solid, start_cell, 8)
	if snapped_start.x < 0:
		return []
	# No-stop cells are open for transit, but the final path cell must still be
	# a legal place to park. Air agents never call find_path at all — they fly
	# a straight line clamped to the map bounds (see air/air_navigation.gd).
	var snapped_target := _nearest_stoppable(solid, target_cell, 24, stoppable_no_stop_cells)
	if snapped_target.x < 0:
		snapped_target = snapped_start
	var astar: AStarGrid2D = profile["astar"]
	var region: PackedInt32Array = profile["region"]
	var start_index := _index_of(snapped_start)
	var target_index := _index_of(snapped_target)
	if start_index >= 0 and target_index >= 0 and region[start_index] != region[target_index]:
		# The target sits in a different connected component: get_id_path with
		# allow_partial_path=true would flood the whole reachable component
		# (tens of thousands of cells) before giving up. Redirect to the
		# nearest cell that shares the start's region instead — same "walk as
		# far as possible" UX, without the flood.
		var substitute := _cached_redirect(profile, snapped_target, region[start_index])
		if substitute.x >= 0:
			return astar.get_id_path(snapped_start, substitute, false)
		# Nothing reachable within the capped search radius — safety net:
		# fall back to the original flooding behaviour rather than returning
		# an empty/wrong path.
		return astar.get_id_path(snapped_start, snapped_target, true)
	return astar.get_id_path(snapped_start, snapped_target, false)


## Redirects for a given (target cell, start region) pair are cached on the
## profile so repeated orders to the same unreachable target do not re-run the
## ring search every time. The cache is reset whenever the profile's solid map
## (and therefore its region labels) is rebuilt.
func _cached_redirect(profile: Dictionary, target_cell: Vector2i, start_region: int) -> Vector2i:
	var cache: Dictionary = profile["redirect_cache"]
	var key := "%d:%d" % [_index_of(target_cell), start_region]
	if cache.has(key):
		return cache[key]
	var substitute := _nearest_region(
		profile["solid"], profile["region"], target_cell, start_region, UNREACHABLE_REDIRECT_RADIUS
	)
	cache[key] = substitute
	return substitute


func is_open(cell: Vector2i, pass_mask: int, clearance_cells: int, allowed_terrain_mask := 0) -> bool:
	var profile := _profile(pass_mask, clearance_cells, allowed_terrain_mask)
	if profile.is_empty():
		return false
	var index := _index_of(cell)
	return index >= 0 and (profile["solid"] as PackedByteArray)[index] == 0


func nearest_open(cell: Vector2i, pass_mask: int, clearance_cells: int, max_radius: int, allowed_terrain_mask := 0) -> Vector2i:
	var profile := _profile(pass_mask, clearance_cells, allowed_terrain_mask)
	if profile.is_empty():
		return Vector2i(-1, -1)
	return _nearest_open(profile["solid"], cell, max_radius)


func _profile(pass_mask: int, clearance_cells: int, allowed_terrain_mask: int) -> Dictionary:
	if _map == null or _map.grid == null:
		return {}
	var key := "%d:%d:%d" % [pass_mask, clearance_cells, allowed_terrain_mask]
	var profile: Dictionary = _profiles.get(key, {})
	if profile.is_empty():
		profile = _build_profile(pass_mask, clearance_cells, allowed_terrain_mask)
		_profiles[key] = profile
	elif int(profile["revision"]) != _map.revision:
		_refresh_profile(profile, pass_mask, clearance_cells, allowed_terrain_mask)
	return profile


func _build_profile(pass_mask: int, clearance_cells: int, allowed_terrain_mask: int) -> Dictionary:
	var astar := AStarGrid2D.new()
	astar.region = Rect2i(0, 0, MapNavigationGrid.NAV_SIZE, MapNavigationGrid.NAV_SIZE)
	astar.cell_size = _map.grid.cell_size()
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.update()
	# Movement cost is a ground-surface concept (e.g. ramps are weighted to
	# steer wheeled/tracked traffic). Only ground pass masks ever build a
	# profile at all — air agents fly a straight line and never call find_path
	# (see air/air_navigation.gd) — so no per-pass-mask branch is needed here.
	var movement_cost: PackedFloat32Array = _map.grid.movement_cost
	for index in movement_cost.size():
		var weight := movement_cost[index]
		if weight > 0.0 and not is_equal_approx(weight, 1.0):
			astar.set_point_weight_scale(_cell_of(index), weight)
	var solid := _solid_map(pass_mask, clearance_cells, allowed_terrain_mask)
	for index in solid.size():
		if solid[index] != 0:
			astar.set_point_solid(_cell_of(index), true)
	return {
		"astar": astar,
		"solid": solid,
		"region": _compute_regions(solid),
		"redirect_cache": {},
		"revision": _map.revision,
	}


func _refresh_profile(profile: Dictionary, pass_mask: int, clearance_cells: int, allowed_terrain_mask: int) -> void:
	var astar: AStarGrid2D = profile["astar"]
	var previous: PackedByteArray = profile["solid"]
	var solid := _solid_map(pass_mask, clearance_cells, allowed_terrain_mask)
	for index in solid.size():
		if solid[index] != previous[index]:
			astar.set_point_solid(_cell_of(index), solid[index] != 0)
	profile["solid"] = solid
	# Region labels and the ring-search redirect cache are only valid for the
	# solid map they were derived from; a changed solid map invalidates both.
	profile["region"] = _compute_regions(solid)
	(profile["redirect_cache"] as Dictionary).clear()
	profile["revision"] = _map.revision


func _solid_map(pass_mask: int, clearance_cells: int, allowed_terrain_mask: int) -> PackedByteArray:
	var size := MapNavigationGrid.NAV_SIZE
	var total := size * size
	var static_pass: PackedInt32Array = _map.grid.pass_mask
	var terrain: PackedInt32Array = _map.grid.terrain_type
	var blocked: PackedByteArray = _map.blocked_cells()
	var solid := PackedByteArray()
	solid.resize(total)
	for index in total:
		if (static_pass[index] & pass_mask) == 0 or blocked[index] != 0:
			solid[index] = 1
		elif allowed_terrain_mask != 0 and (allowed_terrain_mask & (1 << terrain[index])) == 0:
			solid[index] = 1
	if clearance_cells > 0:
		solid = _erode(solid, clearance_cells)
	return solid


## Chebyshev erosion via two separable running-window passes: a cell stays open
## only when every cell within `radius` is open. Cells outside the map count as
## solid, so clearance keeps units off the border.
func _erode(solid: PackedByteArray, radius: int) -> PackedByteArray:
	var size := MapNavigationGrid.NAV_SIZE
	var horizontal := PackedByteArray()
	horizontal.resize(solid.size())
	for y in size:
		var row := y * size
		var window := radius
		for x in range(0, radius + 1):
			window += solid[row + x] if x < size else 1
		for x in size:
			horizontal[row + x] = 1 if window > 0 else 0
			var leaving := x - radius
			window -= solid[row + leaving] if leaving >= 0 else 1
			var entering := x + radius + 1
			window += solid[row + entering] if entering < size else 1
	var result := PackedByteArray()
	result.resize(solid.size())
	for x in size:
		var window := radius
		for y in range(0, radius + 1):
			window += horizontal[y * size + x] if y < size else 1
		for y in size:
			result[y * size + x] = 1 if window > 0 else 0
			var leaving := y - radius
			window -= horizontal[leaving * size + x] if leaving >= 0 else 1
			var entering := y + radius + 1
			window += horizontal[entering * size + x] if entering < size else 1
	return result


func _nearest_open(solid: PackedByteArray, origin: Vector2i, max_radius: int) -> Vector2i:
	var origin_index := _index_of(origin)
	if origin_index >= 0 and solid[origin_index] == 0:
		return origin
	for radius in range(1, max_radius + 1):
		for x in range(-radius, radius + 1):
			for y in [-radius, radius]:
				var candidate := origin + Vector2i(x, y)
				var index := _index_of(candidate)
				if index >= 0 and solid[index] == 0:
					return candidate
		for y in range(-radius + 1, radius):
			for x in [-radius, radius]:
				var candidate := origin + Vector2i(x, y)
				var index := _index_of(candidate)
				if index >= 0 and solid[index] == 0:
					return candidate
	return Vector2i(-1, -1)


func _nearest_stoppable(
		solid: PackedByteArray,
		origin: Vector2i,
		max_radius: int,
		stoppable_no_stop_cells: Dictionary = {},
		ignore_no_stop := false
	) -> Vector2i:
	var no_stop: PackedByteArray = _map.no_stop_cells()
	var origin_index := _index_of(origin)
	if origin_index >= 0 and solid[origin_index] == 0 \
	and (ignore_no_stop or no_stop[origin_index] == 0 or stoppable_no_stop_cells.has(origin)):
		return origin
	for radius in range(1, max_radius + 1):
		for x in range(-radius, radius + 1):
			for y in [-radius, radius]:
				var candidate := origin + Vector2i(x, y)
				var index := _index_of(candidate)
				if index >= 0 and solid[index] == 0 \
				and (ignore_no_stop or no_stop[index] == 0 or stoppable_no_stop_cells.has(candidate)):
					return candidate
		for y in range(-radius + 1, radius):
			for x in [-radius, radius]:
				var candidate := origin + Vector2i(x, y)
				var index := _index_of(candidate)
				if index >= 0 and solid[index] == 0 \
				and (ignore_no_stop or no_stop[index] == 0 or stoppable_no_stop_cells.has(candidate)):
					return candidate
	return Vector2i(-1, -1)


## Nearest cell (Chebyshev ring search) whose connected-component label
## matches `target_region`. Used to redirect an unreachable target to the
## closest point actually reachable from the querying start cell, instead of
## flooding the whole reachable component to discover that the same thing.
func _nearest_region(
		solid: PackedByteArray,
		region: PackedInt32Array,
		origin: Vector2i,
		target_region: int,
		max_radius: int
	) -> Vector2i:
	var origin_index := _index_of(origin)
	if origin_index >= 0 and solid[origin_index] == 0 and region[origin_index] == target_region:
		return origin
	for radius in range(1, max_radius + 1):
		for x in range(-radius, radius + 1):
			for y in [-radius, radius]:
				var candidate := origin + Vector2i(x, y)
				var index := _index_of(candidate)
				if index >= 0 and region[index] == target_region:
					return candidate
		for y in range(-radius + 1, radius):
			for x in [-radius, radius]:
				var candidate := origin + Vector2i(x, y)
				var index := _index_of(candidate)
				if index >= 0 and region[index] == target_region:
					return candidate
	return Vector2i(-1, -1)


## Labels every open cell with a connected-component id via iterative 4-way
## flood fill (0 = solid/unlabeled). 4-connectivity is sufficient even though
## the A* grid also allows diagonal steps: DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
## only takes a diagonal when both adjacent cardinal cells are open, so any
## cell reachable diagonally is already reachable through those same two
## cardinal neighbours.
func _compute_regions(solid: PackedByteArray) -> PackedInt32Array:
	var size := MapNavigationGrid.NAV_SIZE
	var total := size * size
	var region := PackedInt32Array()
	region.resize(total)
	region.fill(0)
	var label := 0
	var stack: Array[int] = []
	for start_index in total:
		if solid[start_index] != 0 or region[start_index] != 0:
			continue
		label += 1
		region[start_index] = label
		stack.append(start_index)
		while not stack.is_empty():
			var index: int = stack.pop_back()
			var x := index % size
			var y := index / size
			if x > 0:
				var left := index - 1
				if solid[left] == 0 and region[left] == 0:
					region[left] = label
					stack.append(left)
			if x < size - 1:
				var right := index + 1
				if solid[right] == 0 and region[right] == 0:
					region[right] = label
					stack.append(right)
			if y > 0:
				var up := index - size
				if solid[up] == 0 and region[up] == 0:
					region[up] = label
					stack.append(up)
			if y < size - 1:
				var down := index + size
				if solid[down] == 0 and region[down] == 0:
					region[down] = label
					stack.append(down)
	return region


func _index_of(cell: Vector2i) -> int:
	if cell.x < 0 or cell.y < 0 or cell.x >= MapNavigationGrid.NAV_SIZE or cell.y >= MapNavigationGrid.NAV_SIZE:
		return -1
	return cell.y * MapNavigationGrid.NAV_SIZE + cell.x


func _cell_of(index: int) -> Vector2i:
	return Vector2i(index % MapNavigationGrid.NAV_SIZE, int(index / MapNavigationGrid.NAV_SIZE))
