class_name MapSpiceLayer
extends RefCounted
## Mutable runtime state for the map's resource fields. Values are byte-density
## units from the XBF map, not player credits or harvester cargo units.

signal spice_changed(cell: Vector2i, previous: int, current: int)
signal spice_mound_changed(cell: Vector2i, present: bool)
signal spice_mound_activated(source_cell: Vector2i, early_activation: bool, world_position: Vector3)
signal spice_spread_stage(source_cell: Vector2i, stage: int, stage_count: int, changed_cells: int)
signal spice_spread_finished(source_cell: Vector2i)

const TERRAIN_SHADER := preload("res://scripts/world/map/terrain.gdshader")
const SPICE_COMPOSITE_SHADER := preload("res://scripts/world/map/spice_composite.gdshader")
const SPICE_TEXTURE := preload("res://assets/raw_original_content/3DDATA/Textures/spicetga_32.tga")
const SPICE_MOUND_SCENE := preload("res://scenes/world/spice_mound.tscn")
const MapNavigationGridScript := preload("res://scripts/world/map/map_navigation_grid.gd")
const COMPOSITE_TEXTURE_SIZE := 1024
const RULE_TICKS_PER_SECOND := 60.0
const MIN_SPREAD_INTERVAL_SECONDS := 0.001
const SPREAD_INTERVAL_MULTIPLIER := 3.0
const SPICE_HAZARD_DURATION_SECONDS := 5.0
const SPICE_HAZARD_TICK_SECONDS := 0.25
const SPICE_HAZARD_TICK_COUNT := int(SPICE_HAZARD_DURATION_SECONDS / SPICE_HAZARD_TICK_SECONDS)
const SPICE_PUFF_ID := &"SpicePuff"
const DEFAULT_SPICE_HAZARD_DAMAGE := 10.0

var world_bounds := AABB()

var _navigation_grid: MapNavigationGrid
var _spice_values := PackedByteArray()
var _spice_mounds := PackedByteArray()
var _spice_image: Image
var _spice_mound_image: Image
var _spice_texture: ImageTexture
var _spice_mound_texture: ImageTexture
var _source_grid_size := Vector2i.ZERO
var _terrain_grid_size := Vector2i.ZERO
var _composite_viewport: SubViewport
var _terrain_mesh: MeshInstance3D
var _spice_mounds_root: Node3D
var _spice_mound_nodes: Dictionary = {}
var _active_spice_spreads: Dictionary = {}
var _active_spice_hazards: Dictionary = {}


func load_baked(data: BakedMapData, navigation_grid: MapNavigationGrid, terrain_mesh: MeshInstance3D = null) -> bool:
	var total := MapNavigationGridScript.NAV_SIZE * MapNavigationGridScript.NAV_SIZE
	if data == null or navigation_grid == null or not navigation_grid.is_loaded():
		push_error("MapSpiceLayer: baked map and a loaded navigation grid are required")
		return false
	if data.nav_spice_value.size() != total:
		push_error("MapSpiceLayer: baked spice grid has invalid size in %s" % data.resource_path)
		return false

	_navigation_grid = navigation_grid
	world_bounds = navigation_grid.world_bounds
	_spice_values = data.nav_spice_value.duplicate()
	_navigation_grid.spice_value = _spice_values

	_spice_mounds.resize(total)
	_spice_mounds.fill(0)
	_source_grid_size = data.nav_report.get("source_spice_grid_size", Vector2i.ZERO)
	if _source_grid_size.x <= 0 or _source_grid_size.y <= 0:
		_source_grid_size = data.nav_report.get("source_grid_size", Vector2i.ZERO)
	_terrain_grid_size = data.nav_report.get("source_grid_size", _source_grid_size)
	if _terrain_grid_size.x <= 0 or _terrain_grid_size.y <= 0:
		_terrain_grid_size = _source_grid_size
	_load_spice_mounds(data.spice_mound_cells)
	_build_textures()
	_terrain_mesh = terrain_mesh
	_bind_terrain_materials(terrain_mesh)
	_spawn_spice_mounds(data.spice_mound_cells)
	return true


func spice_at(cell: Vector2i) -> int:
	var index := _cell_index(cell)
	return _spice_values[index] if index >= 0 else 0


func has_spice(cell: Vector2i) -> bool:
	return spice_at(cell) > 0


func nearest_spice_cell(origin: Vector2i, minimum_amount := 1, maximum_distance := -1) -> Vector2i:
	var best := Vector2i(-1, -1)
	var best_distance_squared := 0x7fffffff
	var maximum_distance_squared := maximum_distance * maximum_distance
	var size := MapNavigationGridScript.NAV_SIZE
	var minimum_x := 0
	var minimum_y := 0
	var maximum_x := size - 1
	var maximum_y := size - 1
	if maximum_distance >= 0:
		minimum_x = maxi(origin.x - maximum_distance, 0)
		minimum_y = maxi(origin.y - maximum_distance, 0)
		maximum_x = mini(origin.x + maximum_distance, size - 1)
		maximum_y = mini(origin.y + maximum_distance, size - 1)
	for y in range(minimum_y, maximum_y + 1):
		for x in range(minimum_x, maximum_x + 1):
			var cell := Vector2i(x, y)
			if _spice_values[y * size + x] < maxi(minimum_amount, 1):
				continue
			var distance_squared := origin.distance_squared_to(cell)
			if maximum_distance >= 0 and distance_squared > maximum_distance_squared:
				continue
			if distance_squared < best_distance_squared:
				best = cell
				best_distance_squared = distance_squared
	return best


func set_spice(cell: Vector2i, amount: int) -> bool:
	var index := _cell_index(cell)
	if index < 0:
		return false
	var clamped := clampi(amount, 0, 255)
	var previous := int(_spice_values[index])
	if previous == clamped:
		return true
	_spice_values[index] = clamped
	_navigation_grid.spice_value[index] = clamped
	_spice_image.set_pixel(cell.x, cell.y, Color(float(clamped) / 255.0, 0.0, 0.0))
	_spice_texture.update(_spice_image)
	_request_composite_update()
	spice_changed.emit(cell, previous, clamped)
	return true


func take_spice(cell: Vector2i, requested: int) -> int:
	if requested <= 0:
		return 0
	var available := spice_at(cell)
	var taken := mini(available, requested)
	if taken > 0:
		set_spice(cell, available - taken)
	return taken


func add_spice(cell: Vector2i, amount: int) -> int:
	if amount <= 0 or _cell_index(cell) < 0:
		return 0
	var previous := spice_at(cell)
	var current := mini(previous + amount, 255)
	if current > previous:
		set_spice(cell, current)
	return current - previous


func has_spice_mound(cell: Vector2i) -> bool:
	var index := _cell_index(cell)
	return index >= 0 and _spice_mounds[index] != 0


func set_spice_mound(cell: Vector2i, present: bool) -> bool:
	if _cell_index(cell) < 0:
		return false
	return _set_source_spice_mound(_nav_to_source_cell(cell), present)


func _set_source_spice_mound(source_cell: Vector2i, present: bool) -> bool:
	if not _source_cell_is_valid(source_cell):
		return false
	var value := 255 if present else 0
	var rect := _source_cell_nav_rect(source_cell)
	var changed := false
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var index := _cell_index(Vector2i(x, y))
			if _spice_mounds[index] == value:
				continue
			_spice_mounds[index] = value
			_spice_mound_image.set_pixel(x, y, Color(float(value) / 255.0, 0.0, 0.0))
			changed = true
	if not changed:
		return true
	_spice_mound_texture.update(_spice_mound_image)
	if present:
		_spawn_spice_mound(source_cell)
	else:
		_remove_spice_mound(source_cell)
	spice_mound_changed.emit(rect.position, present)
	return true


func spice_mask_texture() -> ImageTexture:
	return _spice_texture


func spice_mound_mask_texture() -> ImageTexture:
	return _spice_mound_texture


func detach_visuals() -> void:
	for spread: Dictionary in _active_spice_spreads.values():
		var timer := spread.get("timer") as Timer
		if is_instance_valid(timer):
			timer.free()
	_active_spice_spreads.clear()
	for source_cell: Vector2i in _active_spice_hazards.keys():
		_cancel_spice_hazard(source_cell)
	if is_instance_valid(_composite_viewport):
		_composite_viewport.free()
	_composite_viewport = null
	if is_instance_valid(_spice_mounds_root):
		_spice_mounds_root.free()
	_spice_mounds_root = null
	_spice_mound_nodes.clear()


func _load_spice_mounds(source_cells: Array[Vector2i]) -> void:
	if _source_grid_size.x <= 0 or _source_grid_size.y <= 0:
		return
	for source_cell in source_cells:
		if source_cell.x < 0 or source_cell.y < 0 or source_cell.x >= _source_grid_size.x or source_cell.y >= _source_grid_size.y:
			push_warning("MapSpiceLayer: spice mound cell %s is outside source grid %s" % [source_cell, _source_grid_size])
			continue
		var rect := _source_cell_nav_rect(source_cell)
		for y in range(rect.position.y, rect.end.y):
			for x in range(rect.position.x, rect.end.x):
				_spice_mounds[y * MapNavigationGridScript.NAV_SIZE + x] = 255


func _build_textures() -> void:
	var size := MapNavigationGridScript.NAV_SIZE
	_spice_image = Image.create_from_data(size, size, false, Image.FORMAT_R8, _spice_values)
	_spice_mound_image = Image.create_from_data(size, size, false, Image.FORMAT_R8, _spice_mounds)
	_spice_texture = ImageTexture.create_from_image(_spice_image)
	_spice_mound_texture = ImageTexture.create_from_image(_spice_mound_image)


func _bind_terrain_materials(terrain_mesh: MeshInstance3D) -> void:
	if terrain_mesh == null or terrain_mesh.mesh == null:
		return
	_build_composite_viewport(terrain_mesh)
	for surface_index in terrain_mesh.mesh.get_surface_count():
		var source_material := terrain_mesh.mesh.surface_get_material(surface_index) as ShaderMaterial
		if source_material == null or source_material.shader != TERRAIN_SHADER:
			continue
		var material := source_material.duplicate() as ShaderMaterial
		material.set_shader_parameter(&"spice_field_overlay", _composite_viewport.get_texture())
		material.set_shader_parameter(&"spice_world_rect", Vector4(
			world_bounds.position.x,
			world_bounds.position.z,
			world_bounds.size.x,
			world_bounds.size.z
		))
		terrain_mesh.set_surface_override_material(surface_index, material)


func _spawn_spice_mounds(source_cells: Array[Vector2i]) -> void:
	if _terrain_mesh == null or source_cells.is_empty():
		return
	_ensure_spice_mounds_root()
	for source_cell in source_cells:
		_spawn_spice_mound(source_cell)


func _spawn_spice_mound(source_cell: Vector2i) -> void:
	if _terrain_mesh == null or not _source_cell_is_valid(source_cell) or _spice_mound_nodes.has(source_cell):
		return
	_ensure_spice_mounds_root()
	var world_rect := _source_cell_world_rect(source_cell)
	var center := world_rect.get_center()
	var mound: Variant = SPICE_MOUND_SCENE.instantiate()
	mound.name = "SpiceMound_%d_%d" % [source_cell.x, source_cell.y]
	mound.configure(source_cell, world_rect.size)
	mound.activated.connect(_on_spice_mound_activated.bind(source_cell))
	_spice_mounds_root.add_child(mound)
	mound.global_position = Vector3(center.x, _terrain_height_at(center), center.y)
	_spice_mound_nodes[source_cell] = mound


func _remove_spice_mound(source_cell: Vector2i) -> void:
	_cancel_spice_hazard(source_cell)
	var mound: Variant = _spice_mound_nodes.get(source_cell)
	_spice_mound_nodes.erase(source_cell)
	if is_instance_valid(mound):
		mound.queue_free()


func _ensure_spice_mounds_root() -> void:
	if is_instance_valid(_spice_mounds_root) or _terrain_mesh == null:
		return
	_spice_mounds_root = Node3D.new()
	_spice_mounds_root.name = "SpiceMounds"
	_spice_mounds_root.set_as_top_level(true)
	_terrain_mesh.add_child(_spice_mounds_root)
	_spice_mounds_root.global_transform = Transform3D.IDENTITY


func _on_spice_mound_activated(mound: Variant, early_activation: bool, source_cell: Vector2i) -> void:
	if _spice_mound_nodes.get(source_cell) != mound:
		return
	spice_mound_activated.emit(source_cell, early_activation, mound.global_position)
	_start_spice_spread(source_cell, mound.config)


func _start_spice_spread(source_cell: Vector2i, config: Resource) -> void:
	_cancel_spice_spread(source_cell)
	_cancel_spice_hazard(source_cell)
	var spread := _create_spice_spread_job(source_cell, config)
	var cells := spread.get("cells", []) as Array
	if cells.is_empty() or not is_instance_valid(_spice_mounds_root):
		spice_spread_finished.emit(source_cell)
		return
	_start_spice_hazard(source_cell, spread)

	var timer := Timer.new()
	timer.name = "SpiceSpread_%d_%d" % [source_cell.x, source_cell.y]
	timer.one_shot = false
	timer.wait_time = _spread_interval_seconds(config)
	_spice_mounds_root.add_child(timer)
	spread["timer"] = timer
	_active_spice_spreads[source_cell] = spread
	timer.timeout.connect(_advance_spice_spread.bind(source_cell))
	timer.start()


func _spread_interval_seconds(config: Resource) -> float:
	var build_time_ticks := float(config.field(&"build_time", 0.0)) if config != null else 0.0
	return maxf(
		build_time_ticks / RULE_TICKS_PER_SECOND * SPREAD_INTERVAL_MULTIPLIER,
		MIN_SPREAD_INTERVAL_SECONDS
	)


func _create_spice_spread_job(source_cell: Vector2i, config: Resource) -> Dictionary:
	var blast_radius := maxf(float(config.field(&"blast_radius", 0.0)), 0.0) if config != null else 0.0
	var spice_capacity := maxi(int(config.field(&"spice_capacity", 0)), 0) if config != null else 0
	var stage_count := maxi(int(ceil(blast_radius)), 1)
	var spread := {
		"source_cell": source_cell,
		"stage": 0,
		"stage_count": stage_count,
		"blast_radius": blast_radius,
		"cells": [],
	}
	if blast_radius <= 0.0 or spice_capacity <= 0 or not _source_cell_is_valid(source_cell):
		return spread

	var center_normalized := (Vector2(source_cell) + Vector2(0.5, 0.5)) / Vector2(_source_grid_size)
	var center_nav := center_normalized * float(MapNavigationGridScript.NAV_SIZE)
	var nav_radius := Vector2(
		blast_radius / float(_terrain_grid_size.x) * float(MapNavigationGridScript.NAV_SIZE),
		blast_radius / float(_terrain_grid_size.y) * float(MapNavigationGridScript.NAV_SIZE)
	)
	var min_cell := Vector2i(
		clampi(int(floor(center_nav.x - nav_radius.x - 0.5)), 0, MapNavigationGridScript.NAV_SIZE - 1),
		clampi(int(floor(center_nav.y - nav_radius.y - 0.5)), 0, MapNavigationGridScript.NAV_SIZE - 1)
	)
	var max_cell := Vector2i(
		clampi(int(ceil(center_nav.x + nav_radius.x - 0.5)), 0, MapNavigationGridScript.NAV_SIZE - 1),
		clampi(int(ceil(center_nav.y + nav_radius.y - 0.5)), 0, MapNavigationGridScript.NAV_SIZE - 1)
	)

	var candidates: Array[Dictionary] = []
	for y in range(min_cell.y, max_cell.y + 1):
		for x in range(min_cell.x, max_cell.x + 1):
			var cell := Vector2i(x, y)
			if not _is_passable_sand(cell):
				continue
			var normalized := (Vector2(cell) + Vector2(0.5, 0.5)) / float(MapNavigationGridScript.NAV_SIZE)
			var distance_tiles := ((normalized - center_normalized) * Vector2(_terrain_grid_size)).length()
			if distance_tiles > blast_radius:
				continue
			candidates.append({
				"cell": cell,
				"distance_tiles": distance_tiles,
				"stage": clampi(int(ceil(distance_tiles / blast_radius * float(stage_count))), 1, stage_count),
			})

	candidates.sort_custom(_spread_candidate_less)
	if candidates.is_empty():
		return spread
	var amount_per_cell := spice_capacity / candidates.size()
	var extra_cells := spice_capacity % candidates.size()
	for index in candidates.size():
		candidates[index]["amount"] = mini(amount_per_cell + (1 if index < extra_cells else 0), 255)
	spread["cells"] = candidates
	return spread


func _advance_spice_spread(source_cell: Vector2i) -> void:
	var spread := _active_spice_spreads.get(source_cell, {}) as Dictionary
	if spread.is_empty():
		return
	var stage := int(spread.get("stage", 0)) + 1
	spread["stage"] = stage
	_active_spice_spreads[source_cell] = spread
	_apply_spice_spread_stage(spread, stage)
	if stage >= int(spread.get("stage_count", 1)):
		_cancel_spice_spread(source_cell)
		spice_spread_finished.emit(source_cell)


func _apply_spice_spread_stage(spread: Dictionary, stage: int) -> int:
	var changes: Array[Dictionary] = []
	for entry: Dictionary in spread.get("cells", []):
		if int(entry.get("stage", 0)) != stage:
			continue
		var cell := entry.get("cell", Vector2i(-1, -1)) as Vector2i
		var index := _cell_index(cell)
		var amount := int(entry.get("amount", 0))
		if index < 0 or amount <= 0:
			continue
		var previous := int(_spice_values[index])
		var current := mini(previous + amount, 255)
		if current == previous:
			continue
		_spice_values[index] = current
		_navigation_grid.spice_value[index] = current
		_spice_image.set_pixel(cell.x, cell.y, Color(float(current) / 255.0, 0.0, 0.0))
		changes.append({"cell": cell, "previous": previous, "current": current})

	if not changes.is_empty():
		_spice_texture.update(_spice_image)
		_request_composite_update()
		for change: Dictionary in changes:
			spice_changed.emit(change["cell"], change["previous"], change["current"])
	var source_cell := spread.get("source_cell", Vector2i(-1, -1)) as Vector2i
	spice_spread_stage.emit(source_cell, stage, int(spread.get("stage_count", 1)), changes.size())
	return changes.size()


func _cancel_spice_spread(source_cell: Vector2i) -> void:
	var spread := _active_spice_spreads.get(source_cell, {}) as Dictionary
	_active_spice_spreads.erase(source_cell)
	var timer := spread.get("timer") as Timer
	if is_instance_valid(timer):
		timer.stop()
		timer.queue_free()


func _start_spice_hazard(source_cell: Vector2i, spread: Dictionary) -> void:
	_cancel_spice_hazard(source_cell)
	var mound: Variant = _spice_mound_nodes.get(source_cell)
	if not is_instance_valid(mound) or not is_instance_valid(_spice_mounds_root):
		return
	var affected_cells := {}
	var local_points := PackedVector3Array()
	for entry: Dictionary in spread.get("cells", []):
		if int(entry.get("amount", 0)) <= 0:
			continue
		var cell := entry.get("cell", Vector2i(-1, -1)) as Vector2i
		if _cell_index(cell) < 0:
			continue
		affected_cells[cell] = true
		var point := _navigation_grid.grid_to_world(cell)
		point.y = _terrain_height_at(Vector2(point.x, point.z))
		local_points.append(point - mound.global_position)
	if affected_cells.is_empty():
		return

	var cell_size := _navigation_grid.cell_size()
	mound.start_spread_hazard(local_points, maxf(minf(cell_size.x, cell_size.y) * 1.35, 0.25))
	var damage_timer := Timer.new()
	damage_timer.name = "SpiceHazardDamage_%d_%d" % [source_cell.x, source_cell.y]
	damage_timer.wait_time = SPICE_HAZARD_TICK_SECONDS
	var end_timer := Timer.new()
	end_timer.name = "SpiceHazardEnd_%d_%d" % [source_cell.x, source_cell.y]
	end_timer.one_shot = true
	end_timer.wait_time = SPICE_HAZARD_DURATION_SECONDS
	_spice_mounds_root.add_child(damage_timer)
	_spice_mounds_root.add_child(end_timer)
	_active_spice_hazards[source_cell] = {
		"cells": affected_cells,
		"damage": _spice_hazard_damage_per_second() * SPICE_HAZARD_TICK_SECONDS,
		"damage_timer": damage_timer,
		"end_timer": end_timer,
		"remaining_delayed_ticks": SPICE_HAZARD_TICK_COUNT - 1,
	}
	damage_timer.timeout.connect(_on_spice_hazard_damage_timeout.bind(source_cell))
	end_timer.timeout.connect(_cancel_spice_hazard.bind(source_cell))
	_apply_spice_hazard_damage(source_cell)
	damage_timer.start()
	end_timer.start()


func _on_spice_hazard_damage_timeout(source_cell: Vector2i) -> void:
	var hazard := _active_spice_hazards.get(source_cell, {}) as Dictionary
	if hazard.is_empty():
		return
	var remaining := int(hazard.get("remaining_delayed_ticks", 0))
	if remaining <= 0:
		return
	_apply_spice_hazard_damage(source_cell)
	remaining -= 1
	hazard["remaining_delayed_ticks"] = remaining
	_active_spice_hazards[source_cell] = hazard
	if remaining == 0:
		var damage_timer := hazard.get("damage_timer") as Timer
		if is_instance_valid(damage_timer):
			damage_timer.stop()


func _apply_spice_hazard_damage(source_cell: Vector2i) -> int:
	var hazard := _active_spice_hazards.get(source_cell, {}) as Dictionary
	if hazard.is_empty():
		return 0
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return 0
	return _damage_infantry_in_cells(
		hazard.get("cells", {}) as Dictionary,
		float(hazard.get("damage", DEFAULT_SPICE_HAZARD_DAMAGE * SPICE_HAZARD_TICK_SECONDS)),
		tree.get_nodes_in_group(&"units")
	)


func _damage_infantry_in_cells(cells: Dictionary, damage: float, units: Array) -> int:
	if cells.is_empty() or damage <= 0.0 or _navigation_grid == null:
		return 0
	var damaged := 0
	for unit: Variant in units:
		if not is_instance_valid(unit) or not unit.has_method("take_damage"):
			continue
		var unit_config: Resource = unit.get("unit_config")
		if unit_config == null or not bool(unit_config.field(&"infantry", false)):
			continue
		var world_position: Vector3 = unit.global_position if unit.is_inside_tree() else unit.position
		if not cells.has(_navigation_grid.world_to_grid(world_position)):
			continue
		unit.take_damage(damage)
		damaged += 1
	return damaged


func _spice_hazard_damage_per_second() -> float:
	var tree := Engine.get_main_loop() as SceneTree
	var rules := tree.root.get_node_or_null("Rules") if tree != null else null
	var spice_puff: Resource = rules.bullet(SPICE_PUFF_ID) if rules != null else null
	return maxf(
		float(spice_puff.field(&"damage", DEFAULT_SPICE_HAZARD_DAMAGE)) if spice_puff != null \
		else DEFAULT_SPICE_HAZARD_DAMAGE,
		0.0
	)


func _cancel_spice_hazard(source_cell: Vector2i) -> void:
	var hazard := _active_spice_hazards.get(source_cell, {}) as Dictionary
	_active_spice_hazards.erase(source_cell)
	for key in [&"damage_timer", &"end_timer"]:
		var timer := hazard.get(key) as Timer
		if is_instance_valid(timer):
			timer.stop()
			timer.queue_free()
	var mound: Variant = _spice_mound_nodes.get(source_cell)
	if is_instance_valid(mound):
		mound.stop_spread_hazard()


func _is_passable_sand(cell: Vector2i) -> bool:
	return _navigation_grid != null \
		and _navigation_grid.terrain_at(cell) == MapNavigationGridScript.TERRAIN_SAND \
		and _navigation_grid.is_passable(cell, MapNavigationGridScript.PASS_GROUND)


static func _spread_candidate_less(left: Dictionary, right: Dictionary) -> bool:
	var left_distance := float(left.get("distance_tiles", 0.0))
	var right_distance := float(right.get("distance_tiles", 0.0))
	if not is_equal_approx(left_distance, right_distance):
		return left_distance < right_distance
	var left_cell := left.get("cell", Vector2i.ZERO) as Vector2i
	var right_cell := right.get("cell", Vector2i.ZERO) as Vector2i
	return left_cell.y < right_cell.y or (left_cell.y == right_cell.y and left_cell.x < right_cell.x)


func _source_cell_world_rect(source_cell: Vector2i) -> Rect2:
	var start := Vector2(
		world_bounds.position.x + float(source_cell.x) / float(_source_grid_size.x) * world_bounds.size.x,
		world_bounds.position.z + float(source_cell.y) / float(_source_grid_size.y) * world_bounds.size.z
	)
	var end := Vector2(
		world_bounds.position.x + float(source_cell.x + 1) / float(_source_grid_size.x) * world_bounds.size.x,
		world_bounds.position.z + float(source_cell.y + 1) / float(_source_grid_size.y) * world_bounds.size.z
	)
	return Rect2(start, end - start)


func _terrain_height_at(world_xz: Vector2) -> float:
	if _terrain_mesh == null or not _terrain_mesh.is_inside_tree():
		return world_bounds.position.y
	var top := world_bounds.end.y + 200.0
	var bottom := world_bounds.position.y - 200.0
	var query := PhysicsRayQueryParameters3D.create(
		Vector3(world_xz.x, top, world_xz.y), Vector3(world_xz.x, bottom, world_xz.y), 1
	)
	var hit := _terrain_mesh.get_world_3d().direct_space_state.intersect_ray(query)
	return (hit.get("position", Vector3(0.0, world_bounds.position.y, 0.0)) as Vector3).y


func _build_composite_viewport(terrain_mesh: MeshInstance3D) -> void:
	_composite_viewport = SubViewport.new()
	_composite_viewport.name = "SpiceCompositeViewport"
	_composite_viewport.size = Vector2i(COMPOSITE_TEXTURE_SIZE, COMPOSITE_TEXTURE_SIZE)
	_composite_viewport.disable_3d = true
	_composite_viewport.transparent_bg = true
	_composite_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	_composite_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	terrain_mesh.add_child(_composite_viewport)

	var composite_material := ShaderMaterial.new()
	composite_material.shader = SPICE_COMPOSITE_SHADER
	composite_material.set_shader_parameter(&"spice_field_mask", _spice_texture)
	composite_material.set_shader_parameter(&"spice_field_tex", SPICE_TEXTURE)
	var composite_rect := ColorRect.new()
	composite_rect.name = "SpiceComposite"
	composite_rect.size = Vector2(COMPOSITE_TEXTURE_SIZE, COMPOSITE_TEXTURE_SIZE)
	composite_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	composite_rect.material = composite_material
	_composite_viewport.add_child(composite_rect)


func _request_composite_update() -> void:
	if is_instance_valid(_composite_viewport):
		_composite_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


func _mound_nav_rect(cell: Vector2i) -> Rect2i:
	if _source_grid_size.x <= 0 or _source_grid_size.y <= 0:
		return Rect2i(cell, Vector2i.ONE)
	return _source_cell_nav_rect(_nav_to_source_cell(cell))


func _nav_to_source_cell(cell: Vector2i) -> Vector2i:
	var nav_size := MapNavigationGridScript.NAV_SIZE
	return Vector2i(
		clampi(int(float(cell.x) / nav_size * _source_grid_size.x), 0, _source_grid_size.x - 1),
		clampi(int(float(cell.y) / nav_size * _source_grid_size.y), 0, _source_grid_size.y - 1)
	)


func _source_cell_nav_rect(source_cell: Vector2i) -> Rect2i:
	var nav_size := MapNavigationGridScript.NAV_SIZE
	var start := Vector2i(
		int(floor(float(source_cell.x) / float(_source_grid_size.x) * nav_size)),
		int(floor(float(source_cell.y) / float(_source_grid_size.y) * nav_size))
	)
	var end := Vector2i(
		int(ceil(float(source_cell.x + 1) / float(_source_grid_size.x) * nav_size)),
		int(ceil(float(source_cell.y + 1) / float(_source_grid_size.y) * nav_size))
	)
	return Rect2i(start, end - start)


func _source_cell_is_valid(source_cell: Vector2i) -> bool:
	return source_cell.x >= 0 and source_cell.y >= 0 \
		and source_cell.x < _source_grid_size.x and source_cell.y < _source_grid_size.y


func _cell_index(cell: Vector2i) -> int:
	var size := MapNavigationGridScript.NAV_SIZE
	if cell.x < 0 or cell.y < 0 or cell.x >= size or cell.y >= size:
		return -1
	return cell.y * size + cell.x
