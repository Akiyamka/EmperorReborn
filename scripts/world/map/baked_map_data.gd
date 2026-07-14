class_name BakedMapData
extends Resource

@export var source_map_dir := ""
@export var source_xbf := ""
@export var world_scale := 0.0625
@export var terrain_aabb := AABB()
@export var lit_direction := Vector3.ZERO
@export var lit_colors: Array[Color] = []
@export var map_size := Vector2i.ZERO
@export var texture_count := 0
@export var surface_count := 0
@export var xbf_summary := ""
@export var spice_mound_cells: Array[Vector2i] = []

@export var nav_world_bounds := AABB()
@export var nav_cpf_values := PackedInt32Array()
@export var nav_terrain_type := PackedInt32Array()
@export var nav_source_tile_x := PackedInt32Array()
@export var nav_source_tile_y := PackedInt32Array()
@export var nav_spice_value := PackedByteArray()
@export var nav_pass_mask := PackedInt32Array()
@export var nav_movement_cost := PackedFloat32Array()
@export var nav_buildable := PackedByteArray()
@export var nav_cpf_report := {}
@export var nav_report := {}
