class_name GameSettings
extends Resource

const DEFAULT_MAXIMUM_GROUND_DECALS := 256

@export var max_building_placement_tile_dist: int = 6
## [General] RepairRate restores this much building health every ten rules
## simulation ticks (Rules.txt documents the cadence beside the value).
@export var building_repair_rate: float = 12.0
## Presentation budget. Zero disables crater decals. This authored default can
## later be overridden by the player's graphics/game settings UI.
@export_range(0, 4096, 1) var maximum_ground_decals: int = \
	DEFAULT_MAXIMUM_GROUND_DECALS
