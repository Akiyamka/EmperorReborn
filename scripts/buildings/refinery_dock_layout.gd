class_name RefineryDockLayout
extends RefCounted

## Pure placement math for docs/mechanics/production.md section 4's refinery
## dock upgrade: where the Nth dock should sit next to a given refinery
## footprint, and how to phrase that anchor as the "hover cell"
## BuildingPlacement.try_place_at_hover_cell() expects.
##
## BuildingPlacement always re-centers whatever cell it is handed by the
## footprint size before treating it as the placement anchor (see
## BuildingPlacement._anchor_for_hover_cell()) -- true for mouse hover, and
## also for the wall chain's auto-continuation, which is the existing
## precedent for feeding it a computed cell instead of a live pointer
## position. hover_cell_for_anchor() exists to invert that centering so an
## exact anchor cell computed here still lands on the anchor it names.

const NAV_CELLS_PER_OCCUPY_CELL := 2


static func occupy_size(occupy_rows: Array) -> Vector2i:
	var width := 0
	for row in occupy_rows:
		width = maxi(width, String(row).length())
	return Vector2i(width, occupy_rows.size())


## Lays docks out in a column immediately beside the refinery footprint, one
## occupy-cell gap from it and from each other, so a second dock never
## overlaps the first regardless of arrival order.
static func dock_anchor_nav_cell(
		refinery_anchor_nav_cell: Vector2i,
		refinery_occupy_rows: Array,
		dock_occupy_rows: Array,
		existing_dock_count: int
) -> Vector2i:
	var refinery_nav_size := occupy_size(refinery_occupy_rows) * NAV_CELLS_PER_OCCUPY_CELL
	var dock_nav_size := occupy_size(dock_occupy_rows) * NAV_CELLS_PER_OCCUPY_CELL
	var gap := NAV_CELLS_PER_OCCUPY_CELL
	return refinery_anchor_nav_cell + Vector2i(
		refinery_nav_size.x + gap,
		existing_dock_count * (dock_nav_size.y + gap)
	)


static func hover_cell_for_anchor(anchor_nav_cell: Vector2i, occupy_rows: Array) -> Vector2i:
	var footprint_size := occupy_size(occupy_rows)
	var anchor_occupy_cell := Vector2i(
		int(floor(float(anchor_nav_cell.x) / float(NAV_CELLS_PER_OCCUPY_CELL))),
		int(floor(float(anchor_nav_cell.y) / float(NAV_CELLS_PER_OCCUPY_CELL)))
	)
	var hover_occupy_cell := anchor_occupy_cell + Vector2i(
		int(floor(float(footprint_size.x) * 0.5)), int(floor(float(footprint_size.y) * 0.5))
	)
	return hover_occupy_cell * NAV_CELLS_PER_OCCUPY_CELL
