class_name PlacementContext
extends RefCounted

var camera: Camera3D
var navigation_grid
var buildings_root: Node3D
var arrow_scene: PackedScene
var building_preview_scene: PackedScene
var cant_build_preview_scene: PackedScene
var skirt_preview_scene: PackedScene
var existing_building_occupy_rows: Callable
var existing_building_is_wall: Callable
var build_radius_provider: Callable
var owner_player_id_provider: Callable
