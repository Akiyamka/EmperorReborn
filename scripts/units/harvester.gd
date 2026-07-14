class_name Harvester
extends Unit

## Dedicated resource-unit behaviour. Unit owns only shared movement,
## navigation, damage and presentation; the harvesting/refinery loop grows here.

const HARVEST_START_ANIMATION := &"Harv_Eat_Start"
const HARVEST_HOLD_ANIMATION := &"Harv_Eat_Hold"
const HARVEST_END_ANIMATION := &"Harv_Eat_End"
const HARVEST_HOLD_SECONDS := 0.3
const HARVEST_CARGO_FRACTION_PER_CYCLE := 0.2
const HARVEST_SEARCH_RADIUS_CELLS := 8
const HARVEST_APPROACH_RADIUS_CELLS := 2.0
## Rules.txt [Harvester] has SpiceCapacity=700. The normalized database
## currently preserves this legacy special-unit field as an orphan custom row,
## so retain the authoritative value as a compatibility fallback until that
## converter representation gains a typed unit column.
const ORIGINAL_SPICE_CAPACITY := 700.0

enum HarvestPhase { NONE, TRAVEL, START, HOLD, END }

@export var max_spice := 0.0

var spice := 0.0:
	set(value):
		spice = clampf(value, 0.0, max_spice)

var _harvest_phase := HarvestPhase.NONE
var _harvest_phase_remaining := 0.0
var _harvest_spice_layer = null
var _harvest_grid = null
var _harvest_target_cell := Vector2i(-1, -1)
var _issuing_harvest_move := false


func _process(delta: float) -> void:
	super._process(delta)
	advance_harvest_order(delta)


func move_to(world_position: Vector3, exit_point := Vector3.INF) -> void:
	if not _issuing_harvest_move:
		cancel_harvest_order()
	super.move_to(world_position, exit_point)


func set_navigation_controller(controller) -> void:
	_issuing_harvest_move = has_harvest_order()
	super.set_navigation_controller(controller)
	_issuing_harvest_move = false


func can_harvest_spice() -> bool:
	return max_spice > 0.0


func command_harvest(spice_layer, navigation_grid, cell: Vector2i) -> bool:
	if not can_harvest_spice() or spice_layer == null or navigation_grid == null:
		return false
	cancel_harvest_order()
	_harvest_spice_layer = spice_layer
	_harvest_grid = navigation_grid
	_harvest_target_cell = cell
	_harvest_phase = HarvestPhase.TRAVEL
	_move_to_harvest_cell(cell)
	return true


func cancel_harvest_order() -> void:
	var was_animating := _harvest_phase in [HarvestPhase.START, HarvestPhase.HOLD, HarvestPhase.END]
	_harvest_phase = HarvestPhase.NONE
	_harvest_phase_remaining = 0.0
	_harvest_spice_layer = null
	_harvest_grid = null
	_harvest_target_cell = Vector2i(-1, -1)
	if was_animating:
		_set_movement_animation(false)


func has_harvest_order() -> bool:
	return _harvest_phase != HarvestPhase.NONE


func harvest_target_cell() -> Vector2i:
	return _harvest_target_cell


## Public for deterministic fixed-delta feature tests; runtime calls it from
## _process so harvesting remains independent of the navigation tick rate.
func advance_harvest_order(delta: float) -> void:
	if _harvest_phase == HarvestPhase.NONE:
		return
	if _harvest_spice_layer == null or _harvest_grid == null or max_spice <= 0.0:
		_finish_harvest_order()
		return
	if spice >= max_spice:
		_finish_harvest_order()
		return
	if _harvest_phase == HarvestPhase.TRAVEL:
		if not _is_close_to_harvest_cell(_harvest_target_cell):
			return
		if int(_harvest_spice_layer.call("spice_at", _harvest_target_cell)) <= 0:
			_retarget_or_finish_harvest()
			return
		stop_at_current_position()
		_begin_harvest_phase(HarvestPhase.START)

	var remaining_delta := maxf(delta, 0.0)
	var transitions := 0
	while _harvest_phase in [HarvestPhase.START, HarvestPhase.HOLD, HarvestPhase.END] and transitions < 4:
		if _harvest_phase_remaining > remaining_delta:
			_harvest_phase_remaining -= remaining_delta
			break
		remaining_delta -= _harvest_phase_remaining
		_harvest_phase_remaining = 0.0
		_advance_harvest_phase()
		transitions += 1


func _advance_harvest_phase() -> void:
	match _harvest_phase:
		HarvestPhase.START:
			_begin_harvest_phase(HarvestPhase.HOLD)
		HarvestPhase.HOLD:
			_collect_harvest_cycle()
			_begin_harvest_phase(HarvestPhase.END)
		HarvestPhase.END:
			if spice >= max_spice:
				_finish_harvest_order()
			elif int(_harvest_spice_layer.call("spice_at", _harvest_target_cell)) <= 0:
				_retarget_or_finish_harvest()
			else:
				_begin_harvest_phase(HarvestPhase.START)


func _begin_harvest_phase(phase: HarvestPhase) -> void:
	_harvest_phase = phase
	match phase:
		HarvestPhase.START:
			_harvest_phase_remaining = _start_harvest_animation(HARVEST_START_ANIMATION)
		HarvestPhase.HOLD:
			_start_harvest_animation(HARVEST_HOLD_ANIMATION)
			_harvest_phase_remaining = HARVEST_HOLD_SECONDS
		HarvestPhase.END:
			_harvest_phase_remaining = _start_harvest_animation(HARVEST_END_ANIMATION)


func _collect_harvest_cycle() -> void:
	var remaining_capacity := maxi(floori(max_spice - spice), 0)
	var cycle_capacity := maxi(ceili(max_spice * HARVEST_CARGO_FRACTION_PER_CYCLE), 1)
	var requested := mini(remaining_capacity, cycle_capacity)
	if requested <= 0:
		return
	var collected := int(_harvest_spice_layer.call("take_spice", _harvest_target_cell, requested))
	spice += float(collected)


func _retarget_or_finish_harvest() -> void:
	var next_cell: Vector2i = _harvest_spice_layer.call(
		"nearest_spice_cell", _harvest_target_cell, 1, HARVEST_SEARCH_RADIUS_CELLS
	)
	if next_cell.x < 0 or next_cell.y < 0:
		_finish_harvest_order()
		return
	_harvest_target_cell = next_cell
	_harvest_phase = HarvestPhase.TRAVEL
	_harvest_phase_remaining = 0.0
	_move_to_harvest_cell(next_cell)


func _move_to_harvest_cell(cell: Vector2i) -> void:
	_issuing_harvest_move = true
	move_to(_harvest_grid.call("grid_to_world", cell))
	_issuing_harvest_move = false


func _is_close_to_harvest_cell(cell: Vector2i) -> bool:
	var target: Vector3 = _harvest_grid.call("grid_to_world", cell)
	var cell_dimensions: Vector2 = _harvest_grid.call("cell_size")
	var approach_radius := maxf(cell_dimensions.x, cell_dimensions.y) * HARVEST_APPROACH_RADIUS_CELLS
	var offset := target - global_position
	offset.y = 0.0
	return offset.length() <= maxf(approach_radius, arrival_radius)


func _finish_harvest_order() -> void:
	var was_animating := _harvest_phase in [HarvestPhase.START, HarvestPhase.HOLD, HarvestPhase.END]
	stop_at_current_position()
	_harvest_phase = HarvestPhase.NONE
	_harvest_phase_remaining = 0.0
	_harvest_spice_layer = null
	_harvest_grid = null
	_harvest_target_cell = Vector2i(-1, -1)
	if was_animating:
		_set_movement_animation(false)


## Returns the clip duration so start/end complete before the state advances.
## Missing clips intentionally have zero duration and keep gameplay functional.
func _start_harvest_animation(animation_name: StringName) -> float:
	var duration := 0.0
	for player in _animation_players:
		if not player.has_animation(animation_name):
			continue
		var animation := player.get_animation(animation_name)
		if animation != null:
			animation.loop_mode = Animation.LOOP_NONE
			duration = maxf(duration, animation.length)
		player.speed_scale = 1.0
		_play_animation_from_start(player, animation_name)
	return duration


func _apply_rules_config() -> void:
	super._apply_rules_config()
	if unit_config == null:
		return
	max_spice = maxf(float(unit_config.field(&"spice_capacity", max_spice)), 0.0)
	if max_spice <= 0.0:
		max_spice = ORIGINAL_SPICE_CAPACITY
	spice = spice


func _set_movement_animation(is_moving: bool, speed_scale := 1.0) -> void:
	if _harvest_phase in [HarvestPhase.START, HarvestPhase.HOLD, HarvestPhase.END]:
		return
	super._set_movement_animation(is_moving, speed_scale)


func _on_animation_finished(animation_name: StringName, player: AnimationPlayer) -> void:
	if _harvest_phase in [HarvestPhase.START, HarvestPhase.HOLD, HarvestPhase.END]:
		return
	super._on_animation_finished(animation_name, player)
