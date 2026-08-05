class_name OccupyGrid
extends RefCounted

## One occupy cell is two world units across. Declared here because every
## consumer of occupy rows needs it and it used to be re-declared per module.
const CELL_WORLD_SPAN := 2.0


static func width(rows: Array) -> int:
	var result := 0
	for row in rows:
		result = maxi(result, String(row).length())
	return result


static func size(rows: Array) -> Vector2i:
	return Vector2i(width(rows), rows.size())


static func occupy_cell_to_nav_cell(
		occupy_cell: Vector2i, nav_cells_per_occupy_cell: int
) -> Vector2i:
	return occupy_cell * nav_cells_per_occupy_cell


static func nav_cell_to_occupy_cell(
		nav_cell: Vector2i, nav_cells_per_occupy_cell: int
) -> Vector2i:
	return Vector2i(
		int(floor(float(nav_cell.x) / float(nav_cells_per_occupy_cell))),
		int(floor(float(nav_cell.y) / float(nav_cells_per_occupy_cell)))
	)


static func nav_cells(
		anchor_cell: Vector2i, rows: Array[String], nav_cells_per_occupy_cell: int
) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for row_index in rows.size():
		for column_index in rows[row_index].length():
			if is_empty_marker(rows[row_index].substr(column_index, 1)):
				continue
			var occupy_cell := anchor_cell + occupy_cell_to_nav_cell(
				Vector2i(column_index, row_index), nav_cells_per_occupy_cell
			)
			for y in nav_cells_per_occupy_cell:
				for x in nav_cells_per_occupy_cell:
					cells.append(occupy_cell + Vector2i(x, y))
	return cells


static func is_empty_marker(marker: String) -> bool:
	return marker.is_empty() or marker == " " or marker == "." or marker == "_" \
		or marker.to_lower() == "n"
