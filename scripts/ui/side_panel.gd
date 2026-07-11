class_name SidePanel
extends Control
## Right-side command panel skeleton (C&C style).
## Top block (radar + command buttons) sticks to the top, the production
## block sticks to the bottom; on tall screens the gap between them stays
## empty and clicks pass through to the game world.

const QUEUE_GRID_COLUMNS := 3
const QUEUE_GRID_ROWS := 5
const QUEUE_SLOT_SIZE := Vector2(64, 64)
const BuildingOptionStateScript := preload("res://scripts/buildings/building_option_state.gd")

const AT_WINDTRAP_ICON := preload("res://assets/raw_original_content/3DDATA/Textures/AT_Windtrap.tga")
const AT_WINDTRAP_ICON_GREY := preload("res://assets/raw_original_content/3DDATA/Textures/Grey_AT_Windtrap.tga")
const AT_BARRACKS_ICON := preload("res://assets/raw_original_content/3DDATA/Textures/AT_Barracks.tga")
const AT_BARRACKS_ICON_GREY := preload("res://assets/raw_original_content/3DDATA/Textures/Grey_AT_Barracks.tga")
const BUILDING_ICONS := {
	&"ATSmWindtrap": [AT_WINDTRAP_ICON, AT_WINDTRAP_ICON_GREY, "Windtrap"],
	&"ATBarracks": [AT_BARRACKS_ICON, AT_BARRACKS_ICON_GREY, "Barracks"],
}

## All five tabs switch the content of the same production grid,
## so exactly one of them is active at a time.
enum Tab { INFANTRY, VEHICLES, BUILDINGS, UPGRADES, STARPORT }

signal command_pressed(command: StringName)
signal tab_changed(tab: Tab)
signal building_intent_pressed(building_id: StringName, button_index: int)

@onready var _credits_label: Label = %CreditsLabel
@onready var _energy_label: Label = %EnergyLabel
@onready var _queue_grid: GridContainer = %QueueGrid
@onready var _queue_tabs: VBoxContainer = %QueueTabs
@onready var _secondary_tabs: HBoxContainer = %SecondaryTabs
@onready var _commands: HBoxContainer = %CommandButtons

var active_tab: Tab = Tab.INFANTRY
## Indexed by Tab enum: Infantry, Vehicles, Buildings, Upgrades, Starport.
var _tabs: Array[PanelTab] = []
## Ordered UI mapping from building-grid slots to the IDs supplied by composition.
var _building_option_ids: Array[StringName] = []
var _building_option_states: Dictionary = {}
var _credits_amount := 0
var _energy_amount := 0
var _sell_mode_active := false
var _wall_mode_active := false


func _ready() -> void:
	var group := ButtonGroup.new()
	for container: Container in [_queue_tabs, _secondary_tabs]:
		for child in container.get_children():
			if child is PanelTab:
				_tabs.append(child)
	for i in _tabs.size():
		_tabs[i].button_group = group
		_tabs[i].toggled.connect(_on_tab_toggled.bind(i))

	for button in _commands.get_children():
		if button is Button:
			button.pressed.connect(_on_command_pressed.bind(StringName(button.name)))

	_set_active_tab(Tab.INFANTRY)
	_apply_resources()
	_apply_sell_mode()
	_apply_wall_mode()


## Fits up to 999 999 999, grouped by thousands.
func set_credits(amount: int) -> void:
	_credits_amount = amount
	if is_node_ready():
		_credits_label.text = _format_resource_amount(_credits_amount)


func set_energy(amount: int) -> void:
	_energy_amount = amount
	if is_node_ready():
		_energy_label.text = _format_resource_amount(_energy_amount)


func set_sell_mode(active: bool) -> void:
	_sell_mode_active = active
	if is_node_ready():
		_apply_sell_mode()


func set_wall_mode(active: bool) -> void:
	_wall_mode_active = active
	if is_node_ready():
		_apply_wall_mode()


func _apply_sell_mode() -> void:
	var sell_button := _commands.get_node_or_null("Sell") as Button
	if sell_button != null:
		sell_button.button_pressed = _sell_mode_active


func _apply_wall_mode() -> void:
	var wall_button := _commands.get_node_or_null("BuildWall") as Button
	if wall_button != null:
		wall_button.button_pressed = _wall_mode_active


func configure_building_options(building_ids: Array[StringName]) -> void:
	_building_option_ids = building_ids.duplicate()
	if is_node_ready():
		_rebuild_queue_grid()


func set_building_option_state(option_state: BuildingOptionState) -> void:
	_building_option_states[option_state.building_id] = option_state
	if is_node_ready():
		_apply_building_option_state(option_state)


func _format_resource_amount(amount: int) -> String:
	var digits := str(absi(amount))
	var grouped := ""
	for i in digits.length():
		if i > 0 and (digits.length() - i) % 3 == 0:
			grouped += " "
		grouped += digits[i]
	return ("-" if amount < 0 else "") + grouped


## External API for future game logic, e.g. blinking when production is done.
func set_tab_state(tab: Tab, state: PanelTab.State) -> void:
	_tabs[tab].state = state


func _on_tab_toggled(pressed: bool, index: int) -> void:
	if not pressed:
		return
	_set_active_tab(index as Tab)
	tab_changed.emit(active_tab)


func _set_active_tab(tab: Tab) -> void:
	active_tab = tab
	for i in _tabs.size():
		if _tabs[i].state == PanelTab.State.DISABLED and i != tab:
			continue
		_tabs[i].state = PanelTab.State.ACTIVE if i == tab else PanelTab.State.REGULAR
	_rebuild_queue_grid()


func _on_command_pressed(command: StringName) -> void:
	command_pressed.emit(command)


func get_slot(index: int) -> QueueSlot:
	if index < 0 or index >= _queue_grid.get_child_count():
		return null
	return _queue_grid.get_child(index) as QueueSlot


func _apply_building_option_state(option_state: BuildingOptionState) -> void:
	if active_tab != Tab.BUILDINGS:
		return

	var slot := _building_slot(option_state.building_id)
	if slot == null:
		return

	# Technology prerequisites remove unavailable options from the panel;
	# grey icons remain reserved for queue-specific blocking states.
	slot.visible = option_state.state != BuildingOptionStateScript.State.DISABLED
	slot.state = _queue_slot_state(option_state.state)
	slot.progress = option_state.progress
	slot.status_text = option_state.status_text
	if not option_state.tooltip.is_empty():
		slot.tooltip_text = option_state.tooltip


func _queue_slot_state(state: BuildingOptionState.State) -> QueueSlot.State:
	match state:
		BuildingOptionStateScript.State.AVAILABLE:
			return QueueSlot.State.AVAILABLE
		BuildingOptionStateScript.State.BLOCKED:
			return QueueSlot.State.BLOCKED
		BuildingOptionStateScript.State.PROGRESS:
			return QueueSlot.State.PROGRESS
		BuildingOptionStateScript.State.READY:
			return QueueSlot.State.READY
	return QueueSlot.State.DISABLED


func _apply_resources() -> void:
	_credits_label.text = _format_resource_amount(_credits_amount)
	_energy_label.text = _format_resource_amount(_energy_amount)


func _rebuild_queue_grid() -> void:
	for child in _queue_grid.get_children():
		_queue_grid.remove_child(child)
		child.queue_free()

	for index in QUEUE_GRID_COLUMNS * QUEUE_GRID_ROWS:
		var slot := QueueSlot.new()
		slot.custom_minimum_size = QUEUE_SLOT_SIZE
		slot.tooltip_text = "Slot %d (empty)" % index
		slot.pressed.connect(_on_slot_pressed.bind(index, MOUSE_BUTTON_LEFT))
		slot.right_pressed.connect(_on_slot_pressed.bind(index, MOUSE_BUTTON_RIGHT))
		_queue_grid.add_child(slot)

	if active_tab == Tab.BUILDINGS:
		for slot_index in _building_option_ids.size():
			_configure_building_slot(slot_index, _building_option_ids[slot_index])


func _configure_building_slot(
		slot_index: int, building_id: StringName
) -> void:
	var slot := get_slot(slot_index)
	if slot == null:
		return
	var icon_data: Array = BUILDING_ICONS.get(building_id, [])
	if icon_data.size() != 3:
		return
	slot.icon_colored = icon_data[0] as Texture2D
	slot.icon_grey = icon_data[1] as Texture2D
	slot.state = QueueSlot.State.AVAILABLE
	slot.tooltip_text = String(icon_data[2])
	var option_state = _building_option_states.get(building_id) as BuildingOptionState
	if option_state != null:
		_apply_building_option_state(option_state)


func _building_slot(building_id: StringName) -> QueueSlot:
	var slot_index := _building_option_ids.find(building_id)
	return get_slot(slot_index)


func _on_slot_pressed(slot_index: int, button_index: int) -> void:
	if active_tab != Tab.BUILDINGS or slot_index < 0 or slot_index >= _building_option_ids.size():
		return
	building_intent_pressed.emit(_building_option_ids[slot_index], button_index)
