class_name WallConnectivity
extends RefCounted

## Orthogonal wall-neighbour mask in occupy-grid coordinates.
## North is -Y in the grid (-Z in world space).
const NORTH := 1
const EAST := 2
const SOUTH := 4
const WEST := 8
const ALL := NORTH | EAST | SOUTH | WEST

const SINGLE := &"single"
const END := &"end"
const MIDDLE := &"middle"
const CORNER := &"corner"
const TJOIN := &"tjoin"
const CROSS := &"cross"

## One authored mesh per family covers every directional permutation, so each
## family has a canonical arm layout that the other permutations are rotations
## of. These are the layouts the meshes were actually baked in -- they are not
## free choices, and they are why the rotation column below reads the way it
## does:
##
##   END     EAST                 single arm points east
##   MIDDLE  EAST | WEST          horizontal bar
##   CORNER  EAST | NORTH         XBF conversion reflects source +Z to Godot
##                                -Z, so the baked corner's arms come out east
##                                and north, not east and south
##   TJOIN   NORTH | EAST | WEST  horizontal bar plus its north half-arm
##
## SINGLE and CROSS are rotation-invariant, hence quarter turn 0.
##
## _SELECTIONS is that derivation precomputed: indexed by the four-bit
## neighbour mask, it is the single source of truth for topology family,
## baked-model rotation and scene variant name. tests/buildings/
## wall_connectivity_run.gd keeps its own copy of the canonical masks above and
## re-derives all sixteen rows through rotated_mask(), so a wrong row here
## fails there rather than shipping silently.
const _SELECTIONS := [
	[SINGLE, 0, &""],
	[END, 1, &"End"],
	[END, 0, &"End"],
	[CORNER, 0, &"Corner"],
	[END, 3, &"End"],
	[MIDDLE, 1, &"Middle"],
	[CORNER, 3, &"Corner"],
	[TJOIN, 3, &"TJoin"],
	[END, 2, &"End"],
	[CORNER, 1, &"Corner"],
	[MIDDLE, 0, &"Middle"],
	[TJOIN, 0, &"TJoin"],
	[CORNER, 2, &"Corner"],
	[TJOIN, 1, &"TJoin"],
	[TJOIN, 2, &"TJoin"],
	[CROSS, 0, &"Cross"],
]


## Returns the canonical model family and its positive-Y quarter-turn count.
## A single source model per family covers every directional permutation.
static func selection_for_mask(raw_mask: int) -> Dictionary:
	var mask := raw_mask & ALL
	var selection: Array = _SELECTIONS[mask]
	return {
		"topology": selection[0],
		"rotation_quarters": selection[1],
	}


static func topology_for_mask(raw_mask: int) -> StringName:
	return _SELECTIONS[raw_mask & ALL][0]


## Positive rotation around Godot's Y axis maps east → north.
## Nothing in scripts/ calls this any more -- _SELECTIONS has the rotations
## precomputed. It stays because it is the engine of the independent oracle in
## tests/buildings/wall_connectivity_run.gd, which rebuilds every row of that
## table from the canonical masks. Deleting it as "unused" would delete the
## only thing keeping the table honest.
static func rotated_mask(raw_mask: int, quarter_turns: int) -> int:
	var mask := raw_mask & ALL
	for _turn in posmod(quarter_turns, 4):
		var rotated := 0
		if mask & NORTH:
			rotated |= WEST
		if mask & WEST:
			rotated |= SOUTH
		if mask & SOUTH:
			rotated |= EAST
		if mask & EAST:
			rotated |= NORTH
		mask = rotated
	return mask


static func variant_node_name(topology: StringName) -> StringName:
	for selection in _SELECTIONS:
		if selection[0] == topology:
			return selection[2]
	return &""
