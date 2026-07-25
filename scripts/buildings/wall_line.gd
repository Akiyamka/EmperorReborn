class_name WallLine
extends RefCounted

## Four-connected line of footprint (occupy-grid) cells from A to B,
## inclusive. Sloped lines alternate horizontal and vertical steps so wall
## segments always share a side; a corner-only diagonal connection is never
## emitted.


static func occupy_cells_between(from_cell: Vector2i, to_cell: Vector2i) -> Array[Vector2i]:
	var reversed := _precedes(to_cell, from_cell)
	var start := to_cell if reversed else from_cell
	var finish := from_cell if reversed else to_cell
	var cells := _four_connected_cells(start, finish)
	if reversed:
		cells.reverse()
	return cells


static func _four_connected_cells(
		from_cell: Vector2i, to_cell: Vector2i
	) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var x0 := from_cell.x
	var y0 := from_cell.y
	var x_steps := absi(to_cell.x - x0)
	var y_steps := absi(to_cell.y - y0)
	var x_direction := signi(to_cell.x - x0)
	var y_direction := signi(to_cell.y - y0)
	var x_taken := 0
	var y_taken := 0

	while true:
		cells.append(Vector2i(x0, y0))
		if x_taken == x_steps and y_taken == y_steps:
			break
		# Compare the midpoint progress of the next X/Y step. Only one axis is
		# advanced per iteration, preserving four-way adjacency while keeping
		# the staircase close to the ideal straight line.
		var take_x := (
			x_taken < x_steps
			and (
				y_taken >= y_steps
				or (2 * x_taken + 1) * y_steps
					<= (2 * y_taken + 1) * x_steps
			)
		)
		if take_x:
			x0 += x_direction
			x_taken += 1
		else:
			y0 += y_direction
			y_taken += 1

	return cells


static func _precedes(first: Vector2i, second: Vector2i) -> bool:
	return first.x < second.x or (first.x == second.x and first.y < second.y)
