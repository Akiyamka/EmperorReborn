class_name BuildRadius
extends RefCounted

## Build radius is a Chebyshev (grid) distance check between the candidate
## building's footprint and existing buildings' footprints, in navigation
## grid cells. Footprints are treated as their bounding rectangle, which is
## exact for the rectangular occupy_rows matrices buildings use.


static func is_within_radius(
		candidate_cells: Array,
		candidate_is_wall: bool,
		existing_footprints: Array,
		radius_tiles: int
	) -> bool:
	if candidate_cells.is_empty() or existing_footprints.is_empty():
		return false

	var candidate_bounds := _bounds(candidate_cells)
	for footprint in existing_footprints:
		var footprint_is_wall: bool = footprint.get("is_wall", false)
		# All buildings extend the radius; walls only do so for other walls.
		if footprint_is_wall and not candidate_is_wall:
			continue
		var other_cells: Array = footprint.get("cells", [])
		if other_cells.is_empty():
			continue
		var other_bounds := _bounds(other_cells)
		if _rect_distance(candidate_bounds, other_bounds) <= radius_tiles:
			return true
	return false


static func _bounds(cells: Array) -> Dictionary:
	var min_cell: Vector2i = cells[0]
	var max_cell: Vector2i = cells[0]
	for cell in cells:
		min_cell.x = mini(min_cell.x, cell.x)
		min_cell.y = mini(min_cell.y, cell.y)
		max_cell.x = maxi(max_cell.x, cell.x)
		max_cell.y = maxi(max_cell.y, cell.y)
	return {"min": min_cell, "max": max_cell}


static func _rect_distance(a: Dictionary, b: Dictionary) -> int:
	var a_min: Vector2i = a["min"]
	var a_max: Vector2i = a["max"]
	var b_min: Vector2i = b["min"]
	var b_max: Vector2i = b["max"]
	var dx := maxi(0, maxi(a_min.x - b_max.x, b_min.x - a_max.x))
	var dy := maxi(0, maxi(a_min.y - b_max.y, b_min.y - a_max.y))
	return maxi(dx, dy)
