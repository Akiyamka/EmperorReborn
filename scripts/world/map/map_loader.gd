class_name MapLoader
extends Node3D
## Loads a converted Godot-native Emperor map. Run converters/convert_map.gd first
## to bake the original XBF/CPF/CPT files into map_data.tres + terrain.tscn.

@export_file("*.tres") var map_data_path := "res://assets/converted/maps/#M70 Claw Rock/map_data.tres"
@export var sun_path: NodePath
@export var environment_path: NodePath

const MapNavigationGridScript := preload("res://scripts/world/map/map_navigation_grid.gd")

var terrain_aabb := AABB()
var navigation_grid: MapNavigationGrid
var map_data: BakedMapData


func _ready() -> void:
	load_map(map_data_path)


func load_map(path: String) -> void:
	if path.is_empty() or not ResourceLoader.exists(path):
		push_error("MapLoader: converted map data not found at %s" % path)
		return

	var loaded_resource: Resource = load(path)
	if loaded_resource == null:
		push_error("MapLoader: could not load %s" % path)
		return
	var candidate_data := loaded_resource as BakedMapData
	if candidate_data == null:
		push_error("MapLoader: expected BakedMapData at %s, got %s" % [path, loaded_resource.get_class()])
		return

	var candidate_grid: MapNavigationGrid = MapNavigationGridScript.new()
	if not candidate_grid.load_baked(candidate_data):
		push_error("MapLoader: invalid baked navigation in %s" % path)
		return

	map_data = candidate_data
	terrain_aabb = candidate_data.terrain_aabb
	navigation_grid = candidate_grid

	_apply_lighting()
	print("MapLoader: %s - %d surfaces, %d textures, map %s, aabb %s" % [
		path,
		map_data.surface_count,
		map_data.texture_count,
		str(map_data.map_size),
		terrain_aabb,
	])
	if not map_data.xbf_summary.is_empty():
		print("  Baked XBF TLV: %s" % map_data.xbf_summary)


func map_center() -> Vector3:
	return terrain_aabb.get_center()


func map_bounds() -> Rect2:
	return Rect2(terrain_aabb.position.x, terrain_aabb.position.z, terrain_aabb.size.x, terrain_aabb.size.z)


func _apply_lighting() -> void:
	var sun := get_node_or_null(sun_path) as DirectionalLight3D
	if sun != null and map_data.lit_direction != Vector3.ZERO:
		var direction: Vector3 = map_data.lit_direction
		direction.z = -direction.z  # same D3D->Godot Z mirror as the mesh
		sun.global_transform = Transform3D.IDENTITY.looking_at(-direction.normalized())
		if map_data.lit_colors.size() >= 2:
			sun.light_color = _desaturated(map_data.lit_colors[1], 1.0)
		sun.light_energy = 1.0

	var world_environment := get_node_or_null(environment_path) as WorldEnvironment
	if world_environment != null and map_data.lit_colors.size() >= 1:
		world_environment.environment.ambient_light_color = _desaturated(map_data.lit_colors[0], 1.0)
		world_environment.environment.ambient_light_energy = 1.0


func _desaturated(color: Color, keep_saturation: float) -> Color:
	var luminance := color.r * 0.299 + color.g * 0.587 + color.b * 0.114
	return Color(luminance, luminance, luminance).lerp(color, keep_saturation)
