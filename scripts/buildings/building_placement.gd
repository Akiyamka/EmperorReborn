class_name BuildingPlacement
extends Node3D

enum PlaceResult {
	PLACED,
	INACTIVE,
	NEEDS_TERRAIN,
	CANNOT_BUILD,
	INVALID_SCENE,
	MISSING_BUILDINGS_ROOT,
}

const NAV_CELLS_PER_OCCUPY_CELL := 2
const CELL_SURFACE_OFFSET := 0.06
const CELL_EMISSION_ENERGY := 1.8
const INVALID_ANCHOR := Vector2i(-999999, -999999)

const UnitPushAsideScript := preload("res://scripts/buildings/unit_push_aside.gd")
const BuildRadiusScript := preload("res://scripts/buildings/build_radius.gd")
const BuildingFootprintScript := preload("res://scripts/buildings/building_footprint.gd")

var _camera: Camera3D
var _navigation_grid
var _buildings_root: Node3D
var _arrow_scene: PackedScene
var _building_preview_scene: PackedScene
var _cant_build_preview_scene: PackedScene
var _skirt_preview_scene: PackedScene
var _existing_building_occupy_rows: Callable
var _existing_building_is_wall: Callable
var _build_radius_provider: Callable
var _placement_owner_player_id_provider: Callable

var _building_id: StringName = &""
var _display_name := ""
var _occupy_rows: Array[String] = []
var _anchor_cell := INVALID_ANCHOR
var _has_anchor := false
var _can_build := false
var _is_wall_candidate := false
var _skip_build_radius_check := false


func setup(
		placement_camera: Camera3D,
		navigation_grid,
		building_parent: Node3D,
		arrow_scene: PackedScene,
		building_preview_scene: PackedScene,
		cant_build_preview_scene: PackedScene,
		skirt_preview_scene: PackedScene,
		existing_building_occupy_rows: Callable,
		existing_building_is_wall: Callable = Callable(),
		build_radius_provider: Callable = Callable(),
		placement_owner_player_id_provider: Callable = Callable()
	) -> void:
	_camera = placement_camera
	_navigation_grid = navigation_grid
	_buildings_root = building_parent
	_arrow_scene = arrow_scene
	_building_preview_scene = building_preview_scene
	_cant_build_preview_scene = cant_build_preview_scene
	_skirt_preview_scene = skirt_preview_scene
	_existing_building_occupy_rows = existing_building_occupy_rows
	_existing_building_is_wall = existing_building_is_wall
	_build_radius_provider = build_radius_provider
	_placement_owner_player_id_provider = placement_owner_player_id_provider
	name = "BuildingPlacementPreview"


## skip_build_radius_check exists for the future MCV deploy flow (docs/mechanics/production.md
## section 1 "MCV"): deploying an MCV into a Construction Yard is the one case that must bypass
## the build radius check. Every other call site (the normal building/wall order flow) leaves it
## at the default and is subject to the check.
func begin(
		building_id: StringName,
		display_name: String,
		occupy_rows: Array[String],
		is_wall: bool = false,
		skip_build_radius_check: bool = false
	) -> bool:
	if building_id == &"" or not _has_occupy_cells(occupy_rows):
		return false

	_clear()
	_building_id = building_id
	_display_name = display_name
	_occupy_rows = occupy_rows.duplicate()
	_is_wall_candidate = is_wall
	_skip_build_radius_check = skip_build_radius_check
	visible = false
	return true


func process(pointer_position: Vector2) -> void:
	if not is_active():
		return
	var hover_cell = _hover_cell_from_pointer(pointer_position)
	if hover_cell == null:
		_hide_preview()
		return
	_update_for_hover_cell(hover_cell)


func try_place(pointer_position: Vector2, building_scene: PackedScene, owner_player_id = null) -> PlaceResult:
	if not is_active():
		return PlaceResult.INACTIVE
	var hover_cell = _hover_cell_from_pointer(pointer_position)
	if hover_cell == null:
		_hide_preview()
		return PlaceResult.NEEDS_TERRAIN
	return try_place_at_hover_cell(hover_cell, building_scene, owner_player_id)


func try_place_at_hover_cell(
		hover_cell: Vector2i, building_scene: PackedScene, owner_player_id = null
	) -> PlaceResult:
	if not is_active():
		return PlaceResult.INACTIVE
	_update_for_hover_cell(hover_cell)
	if not _has_anchor:
		return PlaceResult.NEEDS_TERRAIN
	if not _can_build:
		return PlaceResult.CANNOT_BUILD
	if building_scene == null:
		return PlaceResult.INVALID_SCENE
	var building := building_scene.instantiate() as Node3D
	if building == null:
		return PlaceResult.INVALID_SCENE
	if _buildings_root == null:
		building.free()
		return PlaceResult.MISSING_BUILDINGS_ROOT

	if building.has_method("setup"):
		building.call("setup", _building_id)
	_buildings_root.add_child(building)
	var placement_position := _snap_to_ground(_world_center(_anchor_cell))
	if building.is_inside_tree():
		building.global_position = placement_position
	else:
		building.position = placement_position
	building.set_meta(&"placement_anchor_cell", _anchor_cell)
	if owner_player_id != null and building.has_method("set_owner_player_id"):
		building.call("set_owner_player_id", owner_player_id)
	_push_units_out_of_footprint(_anchor_cell)
	_play_placed_building_animation(building)
	_clear()
	return PlaceResult.PLACED


func cancel() -> String:
	var canceled_name := _display_name
	_clear()
	return canceled_name


func is_active() -> bool:
	return _building_id != &"" and not _occupy_rows.is_empty()


func display_name() -> String:
	return _display_name


## Public so callers that need a raw grid cell from a click without an active
## placement (e.g. the wall line A/B picker) can reuse the same raycast path.
func hover_cell_from_pointer(pointer_position: Vector2):
	return _hover_cell_from_pointer(pointer_position)


func _hover_cell_from_pointer(pointer_position: Vector2):
	if _navigation_grid == null or not _navigation_grid.is_loaded():
		return null
	var hit := _raycast(pointer_position, 1)
	if hit.is_empty():
		return null
	return _navigation_grid.world_to_grid(hit["position"])


func _push_units_out_of_footprint(anchor_cell: Vector2i) -> void:
	if not is_inside_tree() or _navigation_grid == null:
		return
	var units := get_tree().get_nodes_in_group("units")
	if units.is_empty():
		return

	var footprint_size := _nav_size()
	var start: Vector3 = _navigation_grid.grid_to_world(anchor_cell, false)
	var end: Vector3 = _navigation_grid.grid_to_world(anchor_cell + footprint_size, false)
	var cell_step: Vector3 = (
		_navigation_grid.grid_to_world(Vector2i(1, 0), false)
		- _navigation_grid.grid_to_world(Vector2i.ZERO, false)
	)
	var margin := maxf(cell_step.length(), 0.1)
	UnitPushAsideScript.push_units_out_of_footprint(units, start, end, margin)


func _update_for_hover_cell(hover_cell: Vector2i) -> void:
	if _navigation_grid == null or not _navigation_grid.is_loaded():
		_hide_preview()
		return
	var anchor_cell := _anchor_for_hover_cell(hover_cell)
	if _has_anchor and _anchor_cell == anchor_cell and visible:
		return

	visible = true
	_anchor_cell = anchor_cell
	_has_anchor = true
	_rebuild_preview(anchor_cell)


func _rebuild_preview(anchor_cell: Vector2i) -> void:
	_clear_preview_cells()

	var has_cells := false
	var can_build := true
	# Checked once per anchor rather than per cell: it does not depend on the
	# individual occupy cell, and every cell's preview material must reflect
	# it, not just the aggregate _can_build result (otherwise the grid stays
	# green while placement is silently blocked by radius).
	var within_radius := _skip_build_radius_check or _is_within_build_radius(anchor_cell)
	var occupied_cells := _occupied_building_nav_cells()
	for row_index in _occupy_rows.size():
		var row := _occupy_rows[row_index]
		for column_index in row.length():
			var marker := row.substr(column_index, 1)
			if _is_empty_occupy_marker(marker):
				continue

			has_cells = true
			var grid_cell := anchor_cell + _occupy_offset_to_nav_cell(column_index, row_index)
			var cell_available := (
				_is_occupy_cell_buildable(grid_cell)
				and _is_occupy_cell_unoccupied(grid_cell, occupied_cells)
				and within_radius
			)
			can_build = can_build and cell_available

			var preview_scene := _preview_scene_for_marker(marker, cell_available)
			if preview_scene == null:
				continue
			var preview_cell := preview_scene.instantiate() as Node3D
			if preview_cell == null:
				continue

			preview_cell.name = "Cell_%d_%d_%s" % [column_index, row_index, marker]
			_configure_preview_visuals(preview_cell)
			add_child(preview_cell)
			var preview_position := (
				_snap_to_ground(_occupy_cell_world_center(grid_cell))
				+ Vector3.UP * CELL_SURFACE_OFFSET
			)
			if preview_cell.is_inside_tree():
				preview_cell.global_position = preview_position
			else:
				preview_cell.position = preview_position

	_can_build = has_cells and can_build
	if has_cells:
		_add_arrow(anchor_cell)


func _is_within_build_radius(anchor_cell: Vector2i) -> bool:
	if _build_radius_provider.is_null():
		return true
	var radius_tiles := int(_build_radius_provider.call())
	if radius_tiles <= 0:
		return true
	var candidate_cells := _footprint_nav_cells(anchor_cell)
	var existing_footprints := _existing_building_footprints()
	return BuildRadiusScript.is_within_radius(
		candidate_cells, _is_wall_candidate, existing_footprints, radius_tiles
	)


func _footprint_nav_cells(anchor_cell: Vector2i) -> Array[Vector2i]:
	return _occupy_rows_nav_cells(anchor_cell, _occupy_rows)


func _existing_building_footprints() -> Array:
	var footprints: Array = []
	if _navigation_grid == null or not _navigation_grid.is_loaded():
		return footprints

	var buildings: Array = []
	if is_inside_tree():
		buildings = get_tree().get_nodes_in_group("buildings")
	elif _buildings_root != null:
		buildings = _buildings_root.get_children()

	for node in buildings:
		var building := node as Node3D
		if building == null:
			continue
		if not _placement_owner_player_id_provider.is_null():
			var player_id := int(_placement_owner_player_id_provider.call())
			if int(building.get("owner_player_id")) != player_id:
				continue
		var occupy_rows: Array[String] = []
		if not _existing_building_occupy_rows.is_null():
			occupy_rows.assign(_existing_building_occupy_rows.call(building))
		if occupy_rows.is_empty():
			continue
		var is_wall := false
		if not _existing_building_is_wall.is_null():
			is_wall = bool(_existing_building_is_wall.call(building))
		footprints.append({
			"cells": BuildingFootprintScript.nav_cells_by_marker(
				building, occupy_rows, _navigation_grid, NAV_CELLS_PER_OCCUPY_CELL
			).keys(),
			"is_wall": is_wall,
		})
	return footprints


func _occupy_rows_nav_cells(anchor_cell: Vector2i, occupy_rows: Array[String]) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for row_index in occupy_rows.size():
		var row := occupy_rows[row_index]
		for column_index in row.length():
			if _is_empty_occupy_marker(row.substr(column_index, 1)):
				continue
			var occupy_cell := anchor_cell + _occupy_offset_to_nav_cell(column_index, row_index)
			for y in NAV_CELLS_PER_OCCUPY_CELL:
				for x in NAV_CELLS_PER_OCCUPY_CELL:
					cells.append(occupy_cell + Vector2i(x, y))
	return cells


func _clear() -> void:
	_building_id = &""
	_display_name = ""
	_occupy_rows.clear()
	_is_wall_candidate = false
	_skip_build_radius_check = false
	_anchor_cell = INVALID_ANCHOR
	_has_anchor = false
	_can_build = false
	visible = false
	_clear_preview_cells()


func _clear_preview_cells() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()


func _hide_preview() -> void:
	_anchor_cell = INVALID_ANCHOR
	_has_anchor = false
	_can_build = false
	visible = false


func _add_arrow(anchor_cell: Vector2i) -> void:
	if _arrow_scene == null:
		return
	var arrow := _arrow_scene.instantiate() as Node3D
	if arrow == null:
		return
	arrow.name = "CenterArrow"
	_configure_arrow_visuals(arrow)
	add_child(arrow)
	arrow.global_position = _snap_to_ground(_world_center(anchor_cell)) + Vector3.UP * CELL_SURFACE_OFFSET


func _configure_arrow_visuals(node: Node) -> void:
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_restore_arrow_fill_materials(mesh_instance)
	for child in node.get_children():
		_configure_arrow_visuals(child)


func _restore_arrow_fill_materials(mesh_instance: MeshInstance3D) -> void:
	if mesh_instance.mesh == null:
		return
	for surface_index in mesh_instance.mesh.get_surface_count():
		var material := _surface_material(mesh_instance, surface_index)
		if _is_fully_transparent_albedo_material(material):
			var fill_material := StandardMaterial3D.new()
			fill_material.albedo_color = Color.WHITE
			fill_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			fill_material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
			fill_material.disable_receive_shadows = true
			fill_material.emission_enabled = true
			fill_material.emission = Color.WHITE
			fill_material.emission_energy_multiplier = CELL_EMISSION_ENERGY
			mesh_instance.set_surface_override_material(surface_index, fill_material)
		elif material == null:
			mesh_instance.set_surface_override_material(surface_index, _placement_fallback_material())


func _is_fully_transparent_albedo_material(material: Material) -> bool:
	if not (material is BaseMaterial3D):
		return false
	var base_material := material as BaseMaterial3D
	if base_material.albedo_texture == null:
		return false
	var image := base_material.albedo_texture.get_image()
	if image == null:
		return false
	for y in image.get_height():
		for x in image.get_width():
			if image.get_pixel(x, y).a > 0.0:
				return false
	return true


func _configure_preview_visuals(node: Node) -> void:
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_configure_preview_materials(mesh_instance)
	for child in node.get_children():
		_configure_preview_visuals(child)


func _configure_preview_materials(mesh_instance: MeshInstance3D) -> void:
	if mesh_instance.mesh == null:
		return
	for surface_index in mesh_instance.mesh.get_surface_count():
		if _surface_material(mesh_instance, surface_index) == null:
			# A per-surface override is still too late for GLES's shadow/material
			# bookkeeping on a mesh whose source surface has no material. A mesh
			# override is resolved before that query and covers every surface.
			mesh_instance.material_override = _placement_fallback_material()
			return

	mesh_instance.material_override = null
	for surface_index in mesh_instance.mesh.get_surface_count():
		var material := _placement_blend_material(_surface_material(mesh_instance, surface_index))
		mesh_instance.set_surface_override_material(surface_index, material)


func _surface_material(mesh_instance: MeshInstance3D, surface_index: int) -> Material:
	var override_material := mesh_instance.get_surface_override_material(surface_index)
	if override_material != null:
		return override_material
	return mesh_instance.mesh.surface_get_material(surface_index)


func _placement_blend_material(source_material: Material) -> Material:
	if source_material == null:
		return null
	var material := source_material.duplicate() as Material
	if material is BaseMaterial3D:
		var base_material := material as BaseMaterial3D
		base_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		base_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		base_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		base_material.disable_receive_shadows = true
		base_material.emission_enabled = true
		base_material.emission = base_material.albedo_color
		base_material.emission_energy_multiplier = CELL_EMISSION_ENERGY
		if base_material.albedo_texture != null:
			base_material.emission_texture = base_material.albedo_texture
	return material


func _placement_fallback_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(1.0, 1.0, 1.0, 0.45)
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.disable_receive_shadows = true
	material.emission_enabled = true
	material.emission = Color.WHITE
	material.emission_energy_multiplier = CELL_EMISSION_ENERGY
	return material


func _anchor_for_hover_cell(hover_cell: Vector2i) -> Vector2i:
	var footprint_size := _occupy_size()
	var hover_occupy_cell := _nav_cell_to_occupy_cell(hover_cell)
	var anchor_occupy_cell := hover_occupy_cell - Vector2i(
		int(floor(float(footprint_size.x) * 0.5)), int(floor(float(footprint_size.y) * 0.5))
	)
	return _occupy_cell_to_nav_cell(anchor_occupy_cell)


func _occupy_size() -> Vector2i:
	var width := 0
	for row in _occupy_rows:
		width = maxi(width, row.length())
	return Vector2i(width, _occupy_rows.size())


func _world_center(anchor_cell: Vector2i) -> Vector3:
	var footprint_size := _nav_size()
	var start: Vector3 = _navigation_grid.grid_to_world(anchor_cell, false)
	var end: Vector3 = _navigation_grid.grid_to_world(anchor_cell + footprint_size, false)
	return (start + end) * 0.5


func _nav_size() -> Vector2i:
	var occupy_size := _occupy_size()
	return Vector2i(
		occupy_size.x * NAV_CELLS_PER_OCCUPY_CELL, occupy_size.y * NAV_CELLS_PER_OCCUPY_CELL
	)


func _occupy_offset_to_nav_cell(column_index: int, row_index: int) -> Vector2i:
	return Vector2i(
		column_index * NAV_CELLS_PER_OCCUPY_CELL, row_index * NAV_CELLS_PER_OCCUPY_CELL
	)


func _nav_cell_to_occupy_cell(nav_cell: Vector2i) -> Vector2i:
	return Vector2i(
		int(floor(float(nav_cell.x) / float(NAV_CELLS_PER_OCCUPY_CELL))),
		int(floor(float(nav_cell.y) / float(NAV_CELLS_PER_OCCUPY_CELL)))
	)


func _occupy_cell_to_nav_cell(occupy_cell: Vector2i) -> Vector2i:
	return Vector2i(
		occupy_cell.x * NAV_CELLS_PER_OCCUPY_CELL, occupy_cell.y * NAV_CELLS_PER_OCCUPY_CELL
	)


func _occupy_cell_world_center(nav_cell: Vector2i) -> Vector3:
	var start: Vector3 = _navigation_grid.grid_to_world(nav_cell, false)
	var end: Vector3 = _navigation_grid.grid_to_world(
		nav_cell + Vector2i(NAV_CELLS_PER_OCCUPY_CELL, NAV_CELLS_PER_OCCUPY_CELL), false
	)
	return (start + end) * 0.5


func _is_occupy_cell_buildable(nav_cell: Vector2i) -> bool:
	for y in NAV_CELLS_PER_OCCUPY_CELL:
		for x in NAV_CELLS_PER_OCCUPY_CELL:
			if not _is_nav_cell_buildable(nav_cell + Vector2i(x, y)):
				return false
	return true


func _is_occupy_cell_unoccupied(nav_cell: Vector2i, occupied_cells: Dictionary) -> bool:
	for y in NAV_CELLS_PER_OCCUPY_CELL:
		for x in NAV_CELLS_PER_OCCUPY_CELL:
			if occupied_cells.has(nav_cell + Vector2i(x, y)):
				return false
	return true


func _occupied_building_nav_cells() -> Dictionary:
	var cells := {}
	if _navigation_grid == null or not _navigation_grid.is_loaded():
		return cells
	var buildings: Array = []
	if is_inside_tree():
		buildings = get_tree().get_nodes_in_group("buildings")
	elif _buildings_root != null:
		buildings = _buildings_root.get_children()
	for node in buildings:
		var building := node as Node3D
		if building == null:
			continue
		var occupy_rows: Array[String] = []
		if not _existing_building_occupy_rows.is_null():
			occupy_rows.assign(_existing_building_occupy_rows.call(building))
		if occupy_rows.is_empty():
			continue
		for cell in BuildingFootprintScript.nav_cells_by_marker(
			building, occupy_rows, _navigation_grid, NAV_CELLS_PER_OCCUPY_CELL
		):
			cells[cell] = true
	return cells


func _is_nav_cell_buildable(grid_cell: Vector2i) -> bool:
	var debug: Dictionary = _navigation_grid.cell_debug(grid_cell)
	return bool(debug.get("valid", false)) and bool(debug.get("buildable", false))


func _preview_scene_for_marker(marker: String, buildable: bool) -> PackedScene:
	if not buildable:
		return _cant_build_preview_scene
	if marker.to_lower() == "s":
		return _skirt_preview_scene
	return _building_preview_scene


func _is_empty_occupy_marker(marker: String) -> bool:
	return marker.is_empty() or marker == " " or marker == "." or marker == "_" or marker.to_lower() == "n"


func _has_occupy_cells(occupy_rows: Array[String]) -> bool:
	for row in occupy_rows:
		for column_index in row.length():
			if not _is_empty_occupy_marker(row.substr(column_index, 1)):
				return true
	return false


func _raycast(screen_position: Vector2, collision_mask: int) -> Dictionary:
	if _camera == null or not is_inside_tree():
		return {}
	var ray_origin := _camera.project_ray_origin(screen_position)
	var ray_end := ray_origin + _camera.project_ray_normal(screen_position) * 1000.0
	var query := PhysicsRayQueryParameters3D.create(ray_origin, ray_end)
	query.collision_mask = collision_mask
	query.collide_with_areas = false
	return get_world_3d().direct_space_state.intersect_ray(query)


func _snap_to_ground(point: Vector3) -> Vector3:
	if not is_inside_tree():
		return Vector3(point.x, 0.0, point.z)
	var query := PhysicsRayQueryParameters3D.create(
		Vector3(point.x, 200.0, point.z), Vector3(point.x, -200.0, point.z), 1
	)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return Vector3(point.x, 0.0, point.z)
	return hit["position"]


func _play_placed_building_animation(building: Node3D) -> void:
	_set_building_invulnerable(building, true)
	var player := building.get_node_or_null("StatePlayer") as AnimationPlayer
	if player != null and player.has_animation(&"build"):
		var build_animation := player.get_animation(&"build")
		if build_animation != null:
			build_animation.loop_mode = Animation.LOOP_NONE
		player.animation_finished.connect(_on_placed_building_animation_finished.bind(building), CONNECT_ONE_SHOT)
		_play_building_state(building, &"build")
		return
	# No build clip means the building pops in instantly - there is no vulnerable
	# transition window to protect, so invulnerability is skipped rather than timed.
	_play_building_state(building, &"idle")
	_set_building_invulnerable(building, false)


func _on_placed_building_animation_finished(_animation_name: StringName, building: Node3D) -> void:
	if is_instance_valid(building):
		_play_building_state(building, &"idle")
		_set_building_invulnerable(building, false)


func _set_building_invulnerable(building: Node3D, value: bool) -> void:
	if building.has_method("set_invulnerable"):
		building.call("set_invulnerable", value)


func _play_building_state(building: Node3D, state: StringName) -> void:
	if building.has_method("play_state"):
		building.call("play_state", state)
		return
	var player := building.get_node_or_null("StatePlayer") as AnimationPlayer
	if player != null and player.has_animation(state):
		player.play(state)
