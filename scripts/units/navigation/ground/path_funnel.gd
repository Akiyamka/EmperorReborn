class_name PathFunnel
extends RefCounted
## Corridor-of-cells funnel: turns a raw A* cell-by-cell route into a handful
## of world-space apex points a body can walk between in straight lines,
## replacing the per-tick square-cell steering geometry
## (`_path_steering_target`/`_advanced_path_index`) had to work around.

var _runtime_map
var _path_follower


func setup(runtime_map, path_follower) -> void:
	_runtime_map = runtime_map
	_path_follower = path_follower


## `raw_path` is the uncompacted cell-by-cell A* route (before waypoint
## simplification). `start` is the agent's actual world position, which may
## sit off-centre in its starting cell. Returns world-space apex points from
## `start` to the final destination (or, if the target cell could not be
## reached, the centre of the last routed cell — preserving the "walk as far
## as possible" UX of a redirected/partial path).
func build(raw_path: Array[Vector2i], agent: Dictionary, start: Vector3, destination: Vector3) -> Array[Vector3]:
	var grid = _runtime_map.grid
	var final_point := destination
	final_point.y = 0.0
	if not raw_path.is_empty() and grid.world_to_grid(destination) != raw_path.back():
		final_point = grid.grid_to_world(raw_path.back())
		final_point.y = 0.0
	if raw_path.size() <= 2:
		return [final_point]

	var cell_size: Vector2 = grid.cell_size()
	var cell_width := maxf(minf(cell_size.x, cell_size.y), 0.001)
	var terrain_radius := float(agent.get("terrain_radius", agent.get("radius", 0.0)))
	var shrink := maxf(0.0, terrain_radius - 0.2 * cell_width)

	var portals: Array = []
	for index in range(1, raw_path.size()):
		var portal := _portal_for(grid, raw_path[index - 1], raw_path[index])
		_shrink_portal(portal, agent, shrink)
		portals.append(portal)
	var start_flat := start
	start_flat.y = 0.0
	return _run_funnel(portals, start_flat, final_point)


## Portal (left/right pair) between two adjacent path cells. A cardinal step's
## portal is the shared cell edge; a diagonal step's portal is the
## anti-diagonal of the open 2x2 block the diagonal crosses (both cardinal
## neighbours are guaranteed open — `DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES`).
## Endpoints are ordered left/right by a cross-product test against the local
## direction of travel, which is all the funnel algorithm needs even though
## that direction changes from one portal to the next.
func _portal_for(grid, a_cell: Vector2i, d_cell: Vector2i) -> Array:
	var cell_size: Vector2 = grid.cell_size()
	var a_world: Vector3 = grid.grid_to_world(a_cell)
	var d_world: Vector3 = grid.grid_to_world(d_cell)
	a_world.y = 0.0
	d_world.y = 0.0
	var dx := d_cell.x - a_cell.x
	var dz := d_cell.y - a_cell.y
	var p1: Vector3
	var p2: Vector3
	if dx == 0 or dz == 0:
		if dx != 0:
			var boundary_x := a_world.x + float(dx) * cell_size.x * 0.5
			p1 = Vector3(boundary_x, 0.0, a_world.z - cell_size.y * 0.5)
			p2 = Vector3(boundary_x, 0.0, a_world.z + cell_size.y * 0.5)
		else:
			var boundary_z := a_world.z + float(dz) * cell_size.y * 0.5
			p1 = Vector3(a_world.x - cell_size.x * 0.5, 0.0, boundary_z)
			p2 = Vector3(a_world.x + cell_size.x * 0.5, 0.0, boundary_z)
	else:
		var a_outer_x := a_world.x - signf(dx) * cell_size.x * 0.5
		var d_outer_x := d_world.x + signf(dx) * cell_size.x * 0.5
		var a_outer_z := a_world.z - signf(dz) * cell_size.y * 0.5
		var d_outer_z := d_world.z + signf(dz) * cell_size.y * 0.5
		p1 = Vector3(d_outer_x, 0.0, a_outer_z)
		p2 = Vector3(a_outer_x, 0.0, d_outer_z)
	var cross := (d_world.x - a_world.x) * (p1.z - a_world.z) - (d_world.z - a_world.z) * (p1.x - a_world.x)
	return [p1, p2] if cross >= 0.0 else [p2, p1]


## Portal endpoints touching a corner solid for the agent get pulled toward
## the opposite endpoint by `shrink` (derived from the agent's terrain
## radius), matching the clearance disc the runtime swept-disc checks already
## enforce. A corner narrow enough that both endpoints would have to move
## past each other collapses the whole portal to its midpoint instead — a
## safe degradation to the old corner-hugging behaviour.
func _shrink_portal(portal: Array, agent: Dictionary, shrink: float) -> void:
	if shrink <= 0.0:
		return
	var left: Vector3 = portal[0]
	var right: Vector3 = portal[1]
	var length := left.distance_to(right)
	if length <= 0.001:
		return
	var left_solid := _corner_solid(agent, left)
	var right_solid := _corner_solid(agent, right)
	if not left_solid and not right_solid:
		return
	if shrink * 2.0 >= length:
		var mid := (left + right) * 0.5
		portal[0] = mid
		portal[1] = mid
		return
	if left_solid:
		portal[0] = left + (right - left) / length * shrink
	if right_solid:
		portal[1] = right + (left - right) / length * shrink


## A portal endpoint sits exactly on a grid vertex shared by four cells;
## probing a short diagonal offset in each quadrant samples all four without
## needing to know whether this endpoint came from a cardinal or a diagonal
## step.
func _corner_solid(agent: Dictionary, point: Vector3) -> bool:
	var grid = _runtime_map.grid
	var cell_size: Vector2 = grid.cell_size()
	var eps_x := cell_size.x * 0.25
	var eps_z := cell_size.y * 0.25
	for signs in [Vector2(1.0, 1.0), Vector2(1.0, -1.0), Vector2(-1.0, 1.0), Vector2(-1.0, -1.0)]:
		var probe := point + Vector3(signs.x * eps_x, 0.0, signs.y * eps_z)
		var cell: Vector2i = grid.world_to_grid(probe)
		if not _path_follower.agent_cell_passable(agent, cell, 0):
			return true
	return false


## Simple Stupid Funnel Algorithm: walks the portal corridor keeping a
## triangular funnel between a left and right bound anchored at the last
## committed apex; a bound that would cross to the wrong side of the other
## bound commits that other bound as a new apex and restarts the scan from
## there. Ties (`triarea2` ~= 0) count as inside the funnel.
func _run_funnel(portals: Array, start: Vector3, final_point: Vector3) -> Array[Vector3]:
	var full_portals: Array = [[start, start]]
	full_portals.append_array(portals)
	full_portals.append([final_point, final_point])

	var points: Array[Vector3] = [start]
	var apex := start
	var apex_index := 0
	var left_index := 0
	var right_index := 0
	var portal_left := start
	var portal_right := start

	var i := 1
	while i < full_portals.size():
		var left: Vector3 = full_portals[i][0]
		var right: Vector3 = full_portals[i][1]
		var restarted := false
		if _triarea2(apex, portal_right, right) <= 0.0:
			if apex.is_equal_approx(portal_right) or _triarea2(apex, portal_left, right) > 0.0:
				portal_right = right
				right_index = i
			else:
				points.append(portal_left)
				apex = portal_left
				apex_index = left_index
				portal_left = apex
				portal_right = apex
				left_index = apex_index
				right_index = apex_index
				i = apex_index
				restarted = true
		if not restarted and _triarea2(apex, portal_left, left) >= 0.0:
			if apex.is_equal_approx(portal_left) or _triarea2(apex, portal_right, left) < 0.0:
				portal_left = left
				left_index = i
			else:
				points.append(portal_right)
				apex = portal_right
				apex_index = right_index
				portal_left = apex
				portal_right = apex
				left_index = apex_index
				right_index = apex_index
				i = apex_index
				restarted = true
		i += 1
	if points.back().distance_squared_to(final_point) > 0.0001:
		points.append(final_point)
	return points


static func _triarea2(a: Vector3, b: Vector3, c: Vector3) -> float:
	return (c.x - a.x) * (b.z - a.z) - (b.x - a.x) * (c.z - a.z)
