class_name SidePanel
extends Control
## Right-side command panel skeleton (C&C style).
## Top block (radar + command buttons) sticks to the top, the production
## block sticks to the bottom; on tall screens the gap between them stays
## empty and clicks pass through to the game world.

const QUEUE_GRID_COLUMNS := 3
const QUEUE_GRID_ROWS := 5
const QUEUE_SLOT_SIZE := Vector2(64, 64)
const HARDCODED_BUILDING_SLOT := 0
const HARDCODED_BUILDING_ID := &"ATSmWindtrap"

const AT_WINDTRAP_ICON := preload("res://assets/unpacked_rfd/3DDATA/Textures/AT_Windtrap.tga")
const AT_WINDTRAP_ICON_GREY := preload("res://assets/unpacked_rfd/3DDATA/Textures/Grey_AT_Windtrap.tga")

## All five tabs switch the content of the same production grid,
## so exactly one of them is active at a time.
enum Tab { INFANTRY, VEHICLES, BUILDINGS, UPGRADES, STARPORT }

signal command_pressed(command: StringName)
signal tab_changed(tab: Tab)
signal queue_slot_pressed(tab: Tab, slot: int, button_index: int)

@onready var _credits_label: Label = %CreditsLabel
@onready var _queue_grid: GridContainer = %QueueGrid
@onready var _queue_tabs: VBoxContainer = %QueueTabs
@onready var _secondary_tabs: HBoxContainer = %SecondaryTabs
@onready var _commands: HBoxContainer = %CommandButtons

var active_tab: Tab = Tab.INFANTRY
## Indexed by Tab enum: Infantry, Vehicles, Buildings, Upgrades, Starport.
var _tabs: Array[PanelTab] = []


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
	set_credits(0)


## Fits up to 999 999 999, grouped by thousands.
func set_credits(amount: int) -> void:
	var digits := str(absi(amount))
	var grouped := ""
	for i in digits.length():
		if i > 0 and (digits.length() - i) % 3 == 0:
			grouped += " "
		grouped += digits[i]
	_credits_label.text = ("-" if amount < 0 else "") + grouped


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


func set_building_slot_state(
		state: QueueSlot.State,
		progress := 0.0,
		status_text := "",
		tooltip := ""
) -> void:
	if active_tab != Tab.BUILDINGS:
		return

	var slot := get_slot(HARDCODED_BUILDING_SLOT)
	if slot == null:
		return

	slot.state = state
	slot.progress = progress
	slot.status_text = status_text
	if not tooltip.is_empty():
		slot.tooltip_text = tooltip


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

	# Hardcoded first entry until production queues come from game rules.
	if active_tab == Tab.BUILDINGS:
		var windtrap := get_slot(HARDCODED_BUILDING_SLOT)
		windtrap.icon_colored = AT_WINDTRAP_ICON
		windtrap.icon_grey = AT_WINDTRAP_ICON_GREY
		windtrap.state = QueueSlot.State.AVAILABLE
		windtrap.tooltip_text = "Windtrap"


func _on_slot_pressed(slot: int, button_index: int) -> void:
	queue_slot_pressed.emit(active_tab, slot, button_index)
