class_name MapSpiceSpread
extends RefCounted

## What happens after a spice mound blooms: the field it lays down, ring by
## ring, outward from the source cell.
##
## The whole pattern is planned once at activation time -- which cells, how
## much each gets, and which ring (stage) it belongs to -- and then released one
## ring per timer tick. Planning up front is what lets a mound that activates
## early spread proportionally less spice without changing its shape, and lets
## the hazard know its full footprint before the first ring lands.
##
## Owns the Timer nodes it parents under the layer's mounds root, so it follows
## the detach protocol: cancel() and cancel_all() are idempotent.

const MapNavigationGridScript := preload("res://scripts/world/map/map_navigation_grid.gd")

const RULE_TICKS_PER_SECOND := 60.0
const MIN_INTERVAL_SECONDS := 0.001
## Rings advance three times slower than the mound's own BuildTime cycle. The
## original game does not expose this rate; the multiplier is the value that
## matches its observed spread speed.
const INTERVAL_MULTIPLIER := 3.0

var _layer: MapSpiceLayer
var _active: Dictionary = {}


func configure(layer: MapSpiceLayer) -> void:
	_layer = layer


## Plans the bloom and starts releasing it. Reports completion immediately when
## there is nothing to spread, so a caller waiting on spice_spread_finished is
## never left hanging on a barren mound.
func start(source_cell: Vector2i, config: Resource, maturity_fraction := 1.0) -> void:
	cancel(source_cell)
	_layer.hazard().cancel(source_cell)
	var spread := create_job(source_cell, config, maturity_fraction)
	var cells := spread.get("cells", []) as Array
	var mounds_root := _layer.mounds_root()
	if cells.is_empty() or not is_instance_valid(mounds_root):
		_layer.emit_spread_finished(source_cell)
		return
	_layer.hazard().start(source_cell, cells)

	var timer := Timer.new()
	timer.name = "SpiceSpread_%d_%d" % [source_cell.x, source_cell.y]
	timer.one_shot = false
	timer.wait_time = interval_seconds(config)
	mounds_root.add_child(timer)
	spread["timer"] = timer
	_active[source_cell] = spread
	timer.timeout.connect(_advance.bind(source_cell))
	timer.start()


func cancel(source_cell: Vector2i) -> void:
	var spread := _active.get(source_cell, {}) as Dictionary
	_active.erase(source_cell)
	var timer := spread.get("timer") as Timer
	if is_instance_valid(timer):
		timer.stop()
		timer.queue_free()


## Frees the timers without stopping through cancel()'s per-entry bookkeeping;
## the layer calls this when it drops every visual at once.
func cancel_all() -> void:
	for spread: Dictionary in _active.values():
		var timer := spread.get("timer") as Timer
		if is_instance_valid(timer):
			timer.free()
	_active.clear()


func interval_seconds(config: Resource) -> float:
	var build_time_ticks: float = float(config.build_time_ticks) if config != null else 0.0
	return maxf(
		build_time_ticks / RULE_TICKS_PER_SECOND * INTERVAL_MULTIPLIER,
		MIN_INTERVAL_SECONDS
	)


## Plans the whole bloom: every passable sand cell inside the blast radius, the
## ring it belongs to, and its share of the mound's spice. `maturity_fraction`
## scales the capacity only -- an early activation covers the same ground with
## a thinner field rather than a smaller one.
func create_job(
	source_cell: Vector2i,
	config: Resource,
	maturity_fraction := 1.0
) -> Dictionary:
	var blast_radius := maxf(config.blast_radius, 0.0) if config != null else 0.0
	var full_spice_capacity := maxi(config.spice_capacity, 0) if config != null else 0
	var spice_capacity := floori(float(full_spice_capacity) * clampf(maturity_fraction, 0.0, 1.0))
	var stage_count := maxi(int(ceil(blast_radius)), 1)
	var spread := {
		"source_cell": source_cell,
		"stage": 0,
		"stage_count": stage_count,
		"blast_radius": blast_radius,
		"cells": [],
	}
	if blast_radius <= 0.0 or spice_capacity <= 0 or not _layer.source_cell_is_valid(source_cell):
		return spread

	var source_grid_size := _layer.source_grid_size()
	var terrain_grid_size := _layer.terrain_grid_size()
	var nav_size := MapNavigationGridScript.NAV_SIZE
	var center_normalized := (Vector2(source_cell) + Vector2(0.5, 0.5)) / Vector2(source_grid_size)
	var center_nav := center_normalized * float(nav_size)
	var nav_radius := Vector2(
		blast_radius / float(terrain_grid_size.x) * float(nav_size),
		blast_radius / float(terrain_grid_size.y) * float(nav_size)
	)
	var min_cell := Vector2i(
		clampi(int(floor(center_nav.x - nav_radius.x - 0.5)), 0, nav_size - 1),
		clampi(int(floor(center_nav.y - nav_radius.y - 0.5)), 0, nav_size - 1)
	)
	var max_cell := Vector2i(
		clampi(int(ceil(center_nav.x + nav_radius.x - 0.5)), 0, nav_size - 1),
		clampi(int(ceil(center_nav.y + nav_radius.y - 0.5)), 0, nav_size - 1)
	)

	var candidates: Array[Dictionary] = []
	for y in range(min_cell.y, max_cell.y + 1):
		for x in range(min_cell.x, max_cell.x + 1):
			var cell := Vector2i(x, y)
			if not _layer.is_passable_sand(cell):
				continue
			var normalized := (Vector2(cell) + Vector2(0.5, 0.5)) / float(nav_size)
			var distance_tiles := ((normalized - center_normalized) * Vector2(terrain_grid_size)).length()
			if distance_tiles > blast_radius:
				continue
			candidates.append({
				"cell": cell,
				"distance_tiles": distance_tiles,
				"stage": clampi(int(ceil(distance_tiles / blast_radius * float(stage_count))), 1, stage_count),
			})

	candidates.sort_custom(_candidate_less)
	if candidates.is_empty():
		return spread
	var amount_per_cell := spice_capacity / candidates.size()
	var extra_cells := spice_capacity % candidates.size()
	for index in candidates.size():
		candidates[index]["amount"] = mini(amount_per_cell + (1 if index < extra_cells else 0), 255)
	spread["cells"] = candidates
	return spread


## Lays down one ring. Returns how many cells actually gained spice, which is
## what the maps suite asserts on and what the stage signal reports.
func apply_stage(spread: Dictionary, stage: int) -> int:
	var ring: Array[Dictionary] = []
	for entry: Dictionary in spread.get("cells", []):
		if int(entry.get("stage", 0)) == stage:
			ring.append(entry)
	var changed := _layer.add_spice_batch(ring)
	var source_cell := spread.get("source_cell", Vector2i(-1, -1)) as Vector2i
	_layer.emit_spread_stage(source_cell, stage, int(spread.get("stage_count", 1)), changed)
	return changed


func _advance(source_cell: Vector2i) -> void:
	var spread := _active.get(source_cell, {}) as Dictionary
	if spread.is_empty():
		return
	var stage := int(spread.get("stage", 0)) + 1
	spread["stage"] = stage
	_active[source_cell] = spread
	apply_stage(spread, stage)
	if stage >= int(spread.get("stage_count", 1)):
		cancel(source_cell)
		_layer.emit_spread_finished(source_cell)


## Nearest ring first, then row-major inside a ring, so the remainder of an
## uneven capacity split lands on the cells closest to the mound.
static func _candidate_less(left: Dictionary, right: Dictionary) -> bool:
	var left_distance := float(left.get("distance_tiles", 0.0))
	var right_distance := float(right.get("distance_tiles", 0.0))
	if not is_equal_approx(left_distance, right_distance):
		return left_distance < right_distance
	var left_cell := left.get("cell", Vector2i.ZERO) as Vector2i
	var right_cell := right.get("cell", Vector2i.ZERO) as Vector2i
	return left_cell.y < right_cell.y or (left_cell.y == right_cell.y and left_cell.x < right_cell.x)
