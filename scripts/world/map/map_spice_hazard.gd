class_name MapSpiceHazard
extends RefCounted

## The damage field a spice bloom leaves behind when it goes off. For
## DURATION_SECONDS the cells the bloom seeded hurt any infantry standing in
## them, on a fixed tick; vehicles are unaffected.
##
## The rate is authored data, not a constant here: it is the damage of the
## SpicePuff bullet in the rules catalog.
##
## Owns the Timer nodes it parents under the layer's mounds root, so it follows
## the detach protocol -- cancel() and cancel_all() are idempotent, and the
## layer calls cancel_all() when it drops its visuals.

const CombatDefinitionCatalogScript := preload("res://scripts/combat/combat_definition_catalog.gd")

const DURATION_SECONDS := 10.0
const TICK_SECONDS := 0.25
const TICK_COUNT := int(DURATION_SECONDS / TICK_SECONDS)
const SPICE_PUFF_ID := &"SpicePuff"
const DEFAULT_DAMAGE := 10.0

static var _combat_definition_catalog := CombatDefinitionCatalogScript.new()

var _layer: MapSpiceLayer
var _active: Dictionary = {}


func configure(layer: MapSpiceLayer) -> void:
	_layer = layer


## Raises the hazard over the cells a spread job seeded. Silently does nothing
## when the bloom's mound is already gone -- the visual is anchored to it.
func start(source_cell: Vector2i, spread_cells: Array) -> void:
	cancel(source_cell)
	var mound: Variant = _layer.mound_node(source_cell)
	var mounds_root := _layer.mounds_root()
	if not is_instance_valid(mound) or not is_instance_valid(mounds_root):
		return
	var navigation_grid := _layer.nav_grid()
	var affected_cells := {}
	var local_points := PackedVector3Array()
	for entry: Dictionary in spread_cells:
		if int(entry.get("amount", 0)) <= 0:
			continue
		var cell := entry.get("cell", Vector2i(-1, -1)) as Vector2i
		if not _layer.cell_is_valid(cell):
			continue
		affected_cells[cell] = true
		var point := navigation_grid.grid_to_world(cell)
		point.y = _layer.terrain_height_at(Vector2(point.x, point.z))
		local_points.append(point - mound.global_position)
	if affected_cells.is_empty():
		return

	var cell_size := navigation_grid.cell_size()
	mound.start_spread_hazard(local_points, maxf(minf(cell_size.x, cell_size.y) * 1.35, 0.25))
	var damage_timer := Timer.new()
	damage_timer.name = "SpiceHazardDamage_%d_%d" % [source_cell.x, source_cell.y]
	damage_timer.wait_time = TICK_SECONDS
	var end_timer := Timer.new()
	end_timer.name = "SpiceHazardEnd_%d_%d" % [source_cell.x, source_cell.y]
	end_timer.one_shot = true
	end_timer.wait_time = DURATION_SECONDS
	mounds_root.add_child(damage_timer)
	mounds_root.add_child(end_timer)
	_active[source_cell] = {
		"cells": affected_cells,
		"damage": damage_per_second() * TICK_SECONDS,
		"damage_timer": damage_timer,
		"end_timer": end_timer,
		"remaining_delayed_ticks": TICK_COUNT - 1,
	}
	damage_timer.timeout.connect(_on_damage_timeout.bind(source_cell))
	end_timer.timeout.connect(cancel.bind(source_cell))
	# The first tick lands with the bloom rather than a quarter second later.
	_apply_damage(source_cell)
	damage_timer.start()
	end_timer.start()


func cancel(source_cell: Vector2i) -> void:
	var hazard := _active.get(source_cell, {}) as Dictionary
	_active.erase(source_cell)
	for key in [&"damage_timer", &"end_timer"]:
		var timer := hazard.get(key) as Timer
		if is_instance_valid(timer):
			timer.stop()
			timer.queue_free()
	var mound: Variant = _layer.mound_node(source_cell)
	if is_instance_valid(mound):
		mound.stop_spread_hazard()


func cancel_all() -> void:
	for source_cell: Vector2i in _active.keys():
		cancel(source_cell)


## Damage per second, read from the SpicePuff bullet the original game uses for
## this effect. Falls back to DEFAULT_DAMAGE when the rules catalog has no such
## bullet, so a partial rules set still produces a hazard rather than a no-op.
func damage_per_second() -> float:
	var spice_puff := _combat_definition_catalog.bullet(SPICE_PUFF_ID)
	return maxf(
		spice_puff.damage if spice_puff != null else DEFAULT_DAMAGE,
		0.0
	)


## Returns how many units were hit, which is what the maps suite asserts on.
func damage_infantry_in_cells(cells: Dictionary, damage: float, units: Array) -> int:
	var navigation_grid := _layer.nav_grid() if _layer != null else null
	if cells.is_empty() or damage <= 0.0 or navigation_grid == null:
		return 0
	var damaged := 0
	for unit: Variant in units:
		if not is_instance_valid(unit) or not unit.has_method("take_damage"):
			continue
		var unit_definition: Resource = unit.get("unit_definition")
		if unit_definition == null or not unit_definition.infantry:
			continue
		var world_position: Vector3 = unit.global_position if unit.is_inside_tree() else unit.position
		if not cells.has(navigation_grid.world_to_grid(world_position)):
			continue
		unit.take_damage(damage)
		damaged += 1
	return damaged


func _on_damage_timeout(source_cell: Vector2i) -> void:
	var hazard := _active.get(source_cell, {}) as Dictionary
	if hazard.is_empty():
		return
	var remaining := int(hazard.get("remaining_delayed_ticks", 0))
	if remaining <= 0:
		return
	_apply_damage(source_cell)
	remaining -= 1
	hazard["remaining_delayed_ticks"] = remaining
	_active[source_cell] = hazard
	if remaining == 0:
		var damage_timer := hazard.get("damage_timer") as Timer
		if is_instance_valid(damage_timer):
			damage_timer.stop()


func _apply_damage(source_cell: Vector2i) -> int:
	var hazard := _active.get(source_cell, {}) as Dictionary
	if hazard.is_empty():
		return 0
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return 0
	return damage_infantry_in_cells(
		hazard.get("cells", {}) as Dictionary,
		float(hazard.get("damage", DEFAULT_DAMAGE * TICK_SECONDS)),
		tree.get_nodes_in_group(&"units")
	)
