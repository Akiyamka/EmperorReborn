class_name GameSettings
extends Resource

@export var max_building_placement_tile_dist: int = 6
## [General] RepairRate restores this much building health every ten rules
## simulation ticks (Rules.txt documents the cadence beside the value).
@export var building_repair_rate: float = 12.0
