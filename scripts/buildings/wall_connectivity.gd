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

const _CANONICAL_MASKS := {
	END: EAST,
	MIDDLE: EAST | WEST,
	# XBF conversion reflects source +Z to Godot -Z, so the baked corner's
	# canonical arms point east and north.
	CORNER: EAST | NORTH,
	# The two authored meshes form a horizontal bar plus its north half-arm.
	TJOIN: NORTH | EAST | WEST,
}


## Returns the canonical model family and its positive-Y quarter-turn count.
## A single source model per family covers every directional permutation.
static func selection_for_mask(raw_mask: int) -> Dictionary:
	var mask := raw_mask & ALL
	var topology := topology_for_mask(mask)
	if topology == SINGLE or topology == CROSS:
		return {"topology": topology, "rotation_quarters": 0}

	var canonical := int(_CANONICAL_MASKS[topology])
	for quarters in 4:
		if rotated_mask(canonical, quarters) == mask:
			return {"topology": topology, "rotation_quarters": quarters}
	return {"topology": topology, "rotation_quarters": 0}


static func topology_for_mask(raw_mask: int) -> StringName:
	var mask := raw_mask & ALL
	var count := _connection_count(mask)
	match count:
		0:
			return SINGLE
		1:
			return END
		2:
			if mask == (NORTH | SOUTH) or mask == (EAST | WEST):
				return MIDDLE
			return CORNER
		3:
			return TJOIN
		_:
			return CROSS


## Positive rotation around Godot's Y axis maps east → north.
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
	match topology:
		END:
			return &"End"
		MIDDLE:
			return &"Middle"
		CORNER:
			return &"Corner"
		TJOIN:
			return &"TJoin"
		CROSS:
			return &"Cross"
		_:
			return &""


static func _connection_count(mask: int) -> int:
	var count := 0
	for bit in [NORTH, EAST, SOUTH, WEST]:
		if mask & bit:
			count += 1
	return count
