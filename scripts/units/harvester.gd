class_name Harvester
extends Unit

## Dedicated resource-unit behaviour. Unit owns only shared movement,
## navigation, damage and presentation; the harvesting/refinery loop grows here.

const HARVEST_START_ANIMATION := &"Harv_Eat_Start"
const HARVEST_HOLD_ANIMATION := &"Harv_Eat_Hold"
const HARVEST_END_ANIMATION := &"Harv_Eat_End"
const UNLOAD_START_ANIMATION := &"Harv_Unload_Start"
const UNLOAD_HOLD_ANIMATION := &"Harv_Unload_Hold"
const UNLOAD_END_ANIMATION := &"Harv_Unload_End"
const HARVEST_HOLD_SECONDS := 0.3
const HARVEST_CARGO_FRACTION_PER_CYCLE := 0.2
const HARVEST_APPROACH_RADIUS_CELLS := 2.0
const UNLOAD_UPDATES_PER_SECOND := 20.0
const ORIGINAL_UNLOAD_RATE_PER_UPDATE := 2.0
const UNLOAD_HOLD_FALLBACK_SECONDS := 0.05
const AUTO_SEARCH_RETRY_SECONDS := 1.0
const INVALID_DOCK := -1
## Rules.txt [Harvester] has SpiceCapacity=700. The normalized database
## currently preserves this legacy special-unit field as an orphan custom row,
## so retain the authoritative value as a compatibility fallback until that
## converter representation gains a typed unit column.
const ORIGINAL_SPICE_CAPACITY := 700.0

enum HarvestPhase { NONE, TRAVEL, START, HOLD, END }
enum UnloadPhase { NONE, APPROACH, WAIT_DOCK, PARK, START, HOLD, END, RETURN_FRONT }
enum PendingOrder { NONE, MOVE, HARVEST, UNLOAD }

@export var max_spice := 0.0
@export var unload_rate_per_update := ORIGINAL_UNLOAD_RATE_PER_UPDATE

var spice := 0.0:
	set(value):
		spice = clampf(value, 0.0, max_spice)

var _harvest_phase := HarvestPhase.NONE
var _harvest_phase_remaining := 0.0
var _harvest_spice_layer = null
var _harvest_grid = null
var _harvest_target_cell := Vector2i(-1, -1)
var _issuing_harvest_move := false
var _unload_phase := UnloadPhase.NONE
var _unload_phase_remaining := 0.0
var _unload_refinery: Node = null
var _unload_grid = null
var _unload_dock := INVALID_DOCK
var _unload_interrupted := false
var _unload_credit_accumulator := 0.0
var _issuing_unload_move := false
var _issuing_main_base_move := false
var _pending_order := PendingOrder.NONE
var _pending_order_data: Dictionary = {}
var _harvest_cycle_enabled := false
var _cycle_spice_layer = null
var _cycle_grid = null
var _assigned_refinery: Node = null
var _return_main_base: Node3D = null
var _auto_spice_cell_filter := Callable()
var _auto_search_cooldown := 0.0


func _process(delta: float) -> void:
	super._process(delta)
	advance_harvest_order(delta)
	advance_unload_order(delta)
	advance_harvest_cycle(delta)


func prepare_navigation_order(
		world_position: Vector3, exit_point := Vector3.INF, move_mode := 0
	) -> bool:
	if _issuing_harvest_move or _issuing_unload_move or _issuing_main_base_move:
		return true
	_harvest_cycle_enabled = false
	_return_main_base = null
	if _unload_phase in [UnloadPhase.START, UnloadPhase.HOLD, UnloadPhase.END]:
		_queue_pending_order(PendingOrder.MOVE, {
			"position": world_position,
			"exit_point": exit_point,
			"move_mode": move_mode,
		})
		_interrupt_unload_animation()
		return false
	_cancel_unload_immediately()
	cancel_harvest_order()
	return true


func set_navigation_controller(controller) -> void:
	_issuing_harvest_move = has_harvest_order()
	_issuing_unload_move = has_unload_order()
	_issuing_main_base_move = _return_main_base != null
	super.set_navigation_controller(controller)
	_issuing_harvest_move = false
	_issuing_unload_move = false
	_issuing_main_base_move = false


func can_harvest_spice() -> bool:
	return max_spice > 0.0


func command_harvest(spice_layer, navigation_grid, cell: Vector2i) -> bool:
	if not can_harvest_spice() or spice_layer == null or navigation_grid == null:
		return false
	_enable_harvest_cycle(spice_layer, navigation_grid)
	if _unload_phase in [UnloadPhase.START, UnloadPhase.HOLD, UnloadPhase.END]:
		_queue_pending_order(PendingOrder.HARVEST, {
			"spice_layer": spice_layer,
			"grid": navigation_grid,
			"cell": cell,
		})
		_interrupt_unload_animation()
		return true
	_cancel_unload_immediately()
	if spice >= max_spice:
		advance_harvest_cycle()
		return true
	_start_harvest_order(spice_layer, navigation_grid, cell)
	return true


func _start_harvest_order(spice_layer, navigation_grid, cell: Vector2i) -> void:
	cancel_harvest_order()
	_harvest_spice_layer = spice_layer
	_harvest_grid = navigation_grid
	_harvest_target_cell = cell
	_harvest_phase = HarvestPhase.TRAVEL
	_move_to_harvest_cell(cell)


func can_unload_at(refinery: Node) -> bool:
	return _is_valid_owned_refinery(refinery)


func command_unload(refinery: Node, navigation_grid, spice_layer = null) -> bool:
	if navigation_grid == null or not can_unload_at(refinery):
		return false
	_assigned_refinery = refinery
	_return_main_base = null
	if spice_layer != null:
		_enable_harvest_cycle(spice_layer, navigation_grid)
	if _unload_phase in [UnloadPhase.START, UnloadPhase.HOLD, UnloadPhase.END]:
		_queue_pending_order(PendingOrder.UNLOAD, {
			"refinery": refinery,
			"grid": navigation_grid,
		})
		_interrupt_unload_animation()
		return true
	cancel_harvest_order()
	_cancel_unload_immediately()
	_start_unload_order(refinery, navigation_grid)
	return true


## A manual unload order and every later automatic trip use this refinery
## until it is destroyed, captured, or explicitly replaced by another manual
## unload order.
func assigned_refinery() -> Node:
	if not _is_valid_owned_refinery(_assigned_refinery):
		_assigned_refinery = null
	return _assigned_refinery


## The future fog-of-war layer can install a player-specific predicate here.
## Explicitly clicked harvest cells remain valid manual targets; the predicate
## applies only when the harvester autonomously chooses its next field.
func set_auto_spice_cell_filter(candidate_filter: Callable) -> void:
	_auto_spice_cell_filter = candidate_filter
	_auto_search_cooldown = 0.0


## Public for deterministic feature tests. The runtime advances this after
## both action state machines, closing the harvest -> unload -> harvest loop.
func advance_harvest_cycle(delta := 0.0) -> void:
	if not _harvest_cycle_enabled:
		return
	if _assigned_refinery != null and not _is_valid_owned_refinery(_assigned_refinery):
		_assigned_refinery = null
	if has_harvest_order() or has_unload_order() or _pending_order != PendingOrder.NONE:
		return
	if _cycle_spice_layer == null or _cycle_grid == null or max_spice <= 0.0:
		return
	_auto_search_cooldown = maxf(_auto_search_cooldown - maxf(float(delta), 0.0), 0.0)
	if _auto_search_cooldown > 0.0:
		return
	if spice >= max_spice:
		var refinery := assigned_refinery()
		if refinery == null:
			refinery = _nearest_owned_refinery()
			_assigned_refinery = refinery
		if refinery == null:
			if _return_to_primary_main_base():
				# Returning to the main base is the terminal fallback for this
				# cycle. A refinery built later must not pull the harvester away
				# without a new player order.
				_harvest_cycle_enabled = false
			else:
				_auto_search_cooldown = AUTO_SEARCH_RETRY_SECONDS
			return
		_return_main_base = null
		_start_unload_order(refinery, _cycle_grid)
		return
	var origin: Vector2i = _cycle_grid.call("world_to_grid", global_position)
	var next_cell: Vector2i = _cycle_spice_layer.call(
		"nearest_spice_cell", origin, 1, -1, _auto_spice_cell_filter
	)
	if next_cell.x < 0 or next_cell.y < 0:
		_auto_search_cooldown = AUTO_SEARCH_RETRY_SECONDS
		return
	_start_harvest_order(_cycle_spice_layer, _cycle_grid, next_cell)


func _start_unload_order(refinery: Node, navigation_grid) -> void:
	_unload_refinery = refinery
	_unload_grid = navigation_grid
	_unload_dock = INVALID_DOCK
	_unload_interrupted = false
	_unload_credit_accumulator = 0.0
	_unload_phase = UnloadPhase.APPROACH
	_unload_phase_remaining = 0.0
	_issue_unload_move((refinery as Node3D).global_position)


func has_unload_order() -> bool:
	return _unload_phase != UnloadPhase.NONE


func unload_phase() -> int:
	return _unload_phase


func unload_dock() -> int:
	return _unload_dock


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


## Public for deterministic feature tests. Runtime calls this from _process;
## fixed-rate credit conversion is accumulated independently of render frames.
func advance_unload_order(delta: float) -> void:
	if _unload_phase == UnloadPhase.NONE:
		return
	if not _is_valid_owned_refinery(_unload_refinery):
		_interrupt_invalid_refinery()
		if _unload_phase == UnloadPhase.NONE:
			return

	match _unload_phase:
		UnloadPhase.APPROACH:
			if not _is_close_to_world(target_position):
				return
			stop_at_current_position()
			_unload_phase = UnloadPhase.WAIT_DOCK
		UnloadPhase.WAIT_DOCK:
			var reserved := int(_unload_refinery.call("try_reserve_refinery_dock", self))
			if reserved == INVALID_DOCK:
				return
			_unload_dock = reserved
			var dock_position := _unload_refinery.call("refinery_dock_world_position", reserved) as Vector3
			if not dock_position.is_finite():
				_cancel_unload_immediately()
				return
			_unload_phase = UnloadPhase.PARK
			_issue_dock_move(dock_position)
			return
		UnloadPhase.PARK:
			if not bool(_unload_refinery.call("refinery_dock_reserved_by", _unload_dock, self)):
				_unload_dock = INVALID_DOCK
				_unload_phase = UnloadPhase.APPROACH
				_issue_unload_move((_unload_refinery as Node3D).global_position)
				return
			var dock_position := _unload_refinery.call("refinery_dock_world_position", _unload_dock) as Vector3
			if not _is_close_to_world(dock_position):
				return
			stop_at_current_position()
			var dock_facing := _unload_refinery.call(
				"refinery_dock_facing_direction", _unload_dock
			) as Vector3
			if not _turn_toward(dock_facing, delta):
				return
			_begin_unload_phase(UnloadPhase.START)
		UnloadPhase.RETURN_FRONT:
			if _is_close_to_world(target_position):
				_finish_unload_order()
			return

	var remaining_delta := maxf(delta, 0.0)
	var transitions := 0
	while _unload_phase in [UnloadPhase.START, UnloadPhase.HOLD, UnloadPhase.END] and transitions < 256:
		var segment := minf(_unload_phase_remaining, remaining_delta)
		if _unload_phase == UnloadPhase.HOLD and not _unload_interrupted:
			_transfer_unload_credits(segment)
		_unload_phase_remaining -= segment
		remaining_delta -= segment
		if _unload_phase_remaining > 0.0:
			break
		_advance_unload_phase()
		transitions += 1
		if remaining_delta <= 0.0:
			break


func _advance_unload_phase() -> void:
	match _unload_phase:
		UnloadPhase.START:
			_begin_unload_phase(UnloadPhase.END if _unload_interrupted else UnloadPhase.HOLD)
		UnloadPhase.HOLD:
			if _unload_interrupted or spice <= 0.0:
				_begin_unload_phase(UnloadPhase.END)
			else:
				_begin_unload_phase(UnloadPhase.HOLD)
		UnloadPhase.END:
			_release_unload_dock()
			if _pending_order != PendingOrder.NONE:
				_finish_unload_order(false)
				_execute_pending_order()
			elif not _is_valid_owned_refinery(_unload_refinery):
				_finish_unload_order(false)
			else:
				_unload_phase = UnloadPhase.RETURN_FRONT
				_unload_phase_remaining = 0.0
				_issue_unload_move(_unload_refinery.call("refinery_front_position") as Vector3)


func _begin_unload_phase(phase: UnloadPhase) -> void:
	_unload_phase = phase
	match phase:
		UnloadPhase.START:
			_unload_phase_remaining = _start_unload_animation(UNLOAD_START_ANIMATION)
		UnloadPhase.HOLD:
			_unload_phase_remaining = maxf(
				_start_unload_animation(UNLOAD_HOLD_ANIMATION), UNLOAD_HOLD_FALLBACK_SECONDS
			)
		UnloadPhase.END:
			_unload_phase_remaining = _start_unload_animation(UNLOAD_END_ANIMATION)


func _transfer_unload_credits(delta: float) -> void:
	if delta <= 0.0 or spice <= 0.0:
		return
	var player = owner_player()
	if player == null:
		_interrupt_unload_animation()
		return
	_unload_credit_accumulator += delta * unload_rate_per_update * UNLOAD_UPDATES_PER_SECOND
	var credits := mini(floori(_unload_credit_accumulator), floori(spice))
	if credits <= 0:
		return
	_unload_credit_accumulator -= float(credits)
	spice -= float(credits)
	player.add_money(credits)


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
		"nearest_spice_cell", _harvest_target_cell, 1, -1, _auto_spice_cell_filter
	)
	if next_cell.x < 0 or next_cell.y < 0:
		_finish_harvest_order()
		return
	_harvest_target_cell = next_cell
	_harvest_phase = HarvestPhase.TRAVEL
	_harvest_phase_remaining = 0.0
	_move_to_harvest_cell(next_cell)


func _enable_harvest_cycle(spice_layer, navigation_grid) -> void:
	_harvest_cycle_enabled = true
	_cycle_spice_layer = spice_layer
	_cycle_grid = navigation_grid
	_return_main_base = null
	_auto_search_cooldown = 0.0


func _nearest_owned_refinery() -> Node:
	if not is_inside_tree():
		return null
	var nearest: Node = null
	var nearest_distance_squared := INF
	for candidate_variant in get_tree().get_nodes_in_group("buildings"):
		var candidate := candidate_variant as Node
		if not _is_valid_owned_refinery(candidate) or not candidate is Node3D:
			continue
		var offset := (candidate as Node3D).global_position - global_position
		offset.y = 0.0
		var distance_squared := offset.length_squared()
		if distance_squared < nearest_distance_squared:
			nearest = candidate
			nearest_distance_squared = distance_squared
	return nearest


func _return_to_primary_main_base() -> bool:
	var players = _players()
	var main_base: Node3D = players.call("main_base_for_player", owner_player_id) \
		if players != null and players.has_method("main_base_for_player") else null
	if not _is_valid_owned_main_base(main_base):
		_return_main_base = null
		return false
	if _return_main_base == main_base:
		return true
	_return_main_base = main_base
	_issuing_main_base_move = true
	move_to(main_base.global_position)
	_issuing_main_base_move = false
	return true


func _is_valid_owned_main_base(main_base: Node) -> bool:
	if main_base == null or not is_instance_valid(main_base) \
	or main_base.is_queued_for_deletion() or not main_base is Node3D:
		return false
	if main_base.has_method("is_owned_by"):
		return bool(main_base.call("is_owned_by", owner_player_id))
	var base_owner = main_base.get("owner_player_id")
	return base_owner != null and int(base_owner) == owner_player_id


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
	return _start_action_animation(animation_name)


func _start_unload_animation(animation_name: StringName) -> float:
	return _start_action_animation(animation_name)


func _start_action_animation(animation_name: StringName) -> float:
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


func _issue_unload_move(position: Vector3) -> void:
	_issuing_unload_move = true
	move_to(position)
	_issuing_unload_move = false


func _issue_dock_move(position: Vector3) -> void:
	if _navigation_managed and _navigation_system != null and _navigation_system.has_method("command_dock"):
		var cells := _unload_refinery.call("refinery_dock_navigation_cells", _unload_grid) as Dictionary
		_issuing_unload_move = true
		_navigation_system.call("command_dock", self, position, cells)
		_issuing_unload_move = false
		return
	_issue_unload_move(position)


func _is_close_to_world(target: Vector3) -> bool:
	var offset := target - global_position
	offset.y = 0.0
	var tolerance := maxf(arrival_radius, 0.35)
	if _navigation_managed and _navigation_system != null \
	and _navigation_system.has_method("arrival_tolerance"):
		tolerance = maxf(tolerance, float(_navigation_system.call("arrival_tolerance", self)) + 0.01)
	return offset.length() <= tolerance


func _is_valid_owned_refinery(refinery: Node) -> bool:
	if refinery == null or not is_instance_valid(refinery) or refinery.is_queued_for_deletion():
		return false
	if not refinery.has_method("is_refinery") or not bool(refinery.call("is_refinery")):
		return false
	if refinery.has_method("is_owned_by"):
		return bool(refinery.call("is_owned_by", owner_player_id))
	var refinery_owner = refinery.get("owner_player_id")
	return refinery_owner != null and int(refinery_owner) == owner_player_id


func _interrupt_invalid_refinery() -> void:
	_pending_order = PendingOrder.NONE
	_pending_order_data.clear()
	if _unload_phase in [UnloadPhase.START, UnloadPhase.HOLD, UnloadPhase.END]:
		_interrupt_unload_animation()
		return
	_cancel_unload_immediately()


func _interrupt_unload_animation() -> void:
	if _unload_phase not in [UnloadPhase.START, UnloadPhase.HOLD, UnloadPhase.END]:
		return
	_unload_interrupted = true


func _cancel_unload_immediately() -> void:
	if _unload_phase == UnloadPhase.NONE:
		return
	if is_instance_valid(_unload_refinery) and _unload_dock != INVALID_DOCK:
		if _unload_phase == UnloadPhase.PARK:
			_unload_refinery.call("release_refinery_dock", self)
		else:
			_unload_refinery.call("abandon_refinery_dock", self)
	_finish_unload_order(false)


func cancel_unload_order() -> void:
	_pending_order = PendingOrder.NONE
	_pending_order_data.clear()
	if _unload_phase in [UnloadPhase.START, UnloadPhase.HOLD, UnloadPhase.END]:
		_interrupt_unload_animation()
	else:
		_cancel_unload_immediately()


func _release_unload_dock() -> void:
	if is_instance_valid(_unload_refinery) and _unload_dock != INVALID_DOCK:
		_unload_refinery.call("release_refinery_dock", self)
	_unload_dock = INVALID_DOCK


func _finish_unload_order(stop_unit := true) -> void:
	if stop_unit:
		stop_at_current_position()
	_unload_phase = UnloadPhase.NONE
	_unload_phase_remaining = 0.0
	_unload_refinery = null
	_unload_grid = null
	_unload_dock = INVALID_DOCK
	_unload_interrupted = false
	_unload_credit_accumulator = 0.0


func _queue_pending_order(kind: PendingOrder, data: Dictionary) -> void:
	_pending_order = kind
	_pending_order_data = data.duplicate()


func _execute_pending_order() -> void:
	var kind := _pending_order
	var data := _pending_order_data.duplicate()
	_pending_order = PendingOrder.NONE
	_pending_order_data.clear()
	match kind:
		PendingOrder.MOVE:
			var position := data.get("position", global_position) as Vector3
			var exit_point := data.get("exit_point", Vector3.INF) as Vector3
			var move_mode := int(data.get("move_mode", 0))
			if _navigation_managed and _navigation_system != null:
				_navigation_system.call("command_move", [self], position, move_mode, exit_point)
			else:
				super.move_to(position, exit_point)
		PendingOrder.HARVEST:
			if spice >= max_spice:
				advance_harvest_cycle()
			else:
				_start_harvest_order(data.get("spice_layer"), data.get("grid"), data.get("cell", Vector2i(-1, -1)))
		PendingOrder.UNLOAD:
			var refinery := data.get("refinery") as Node
			if _is_valid_owned_refinery(refinery):
				_start_unload_order(refinery, data.get("grid"))


func _apply_rules_config() -> void:
	super._apply_rules_config()
	if unit_config == null:
		return
	max_spice = maxf(float(unit_config.field(&"spice_capacity", max_spice)), 0.0)
	if max_spice <= 0.0:
		max_spice = ORIGINAL_SPICE_CAPACITY
	unload_rate_per_update = maxf(float(
		unit_config.field(&"unload_rate", ORIGINAL_UNLOAD_RATE_PER_UPDATE)
	), 0.0)
	spice = spice


func _set_movement_animation(is_moving: bool, speed_scale := 1.0) -> void:
	if _harvest_phase in [HarvestPhase.START, HarvestPhase.HOLD, HarvestPhase.END] \
	or _unload_phase in [UnloadPhase.START, UnloadPhase.HOLD, UnloadPhase.END]:
		return
	super._set_movement_animation(is_moving, speed_scale)


func _on_animation_finished(animation_name: StringName, player: AnimationPlayer) -> void:
	if _harvest_phase in [HarvestPhase.START, HarvestPhase.HOLD, HarvestPhase.END] \
	or _unload_phase in [UnloadPhase.START, UnloadPhase.HOLD, UnloadPhase.END]:
		return
	super._on_animation_finished(animation_name, player)
