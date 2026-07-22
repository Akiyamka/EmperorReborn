class_name SidePanel
extends Control
## Right-side command panel skeleton (C&C style).
## Top block (radar + command buttons) sticks to the top, the production
## block sticks to the bottom; on tall screens the gap between them stays
## empty and clicks pass through to the game world.

const QUEUE_GRID_COLUMNS := 3
const QUEUE_GRID_ROWS := 5
const QUEUE_PAGE_SIZE := QUEUE_GRID_COLUMNS * QUEUE_GRID_ROWS
const QUEUE_SLOT_SIZE := Vector2(64, 64)
const ICON_TEXTURE_ROOT := "res://assets/raw_original_content/3DDATA/Textures"
const BuildingOptionStateScript := preload("res://scripts/buildings/building_option_state.gd")
const UnitSceneCatalogScript := preload("res://scripts/units/unit_scene_catalog.gd")
const BuildingDefinitionCatalogScript := preload("res://scripts/buildings/building_definition_catalog.gd")
const SidebarRosterLayoutScript := preload("res://scripts/ui/sidebar_roster_layout.gd")

## All five tabs switch the content of the same production grid,
## so exactly one of them is active at a time.
enum Tab { INFANTRY, VEHICLES, BUILDINGS, UPGRADES, STARPORT }

const ART_SIDEBAR_TABS := {
	"Infantry": Tab.INFANTRY,
	"Units": Tab.VEHICLES,
	"Buildings": Tab.BUILDINGS,
}

signal command_pressed(command: StringName)
signal tab_changed(tab: Tab)
signal building_intent_pressed(building_id: StringName, button_index: int, quantity: int)
signal upgrade_intent_pressed(upgrade_id: StringName, button_index: int)

@onready var _credits_label: Label = %CreditsLabel
@onready var _energy_label: Label = %EnergyLabel
@onready var _queue_grid: GridContainer = %QueueGrid
@onready var _queue_tabs: VBoxContainer = %QueueTabs
@onready var _secondary_tabs: HBoxContainer = %SecondaryTabs
@onready var _commands: HBoxContainer = %CommandButtons
@onready var _page_previous: Button = %PagePrevious
@onready var _page_next: Button = %PageNext

var active_tab: Tab = Tab.INFANTRY
## Indexed by Tab enum: Infantry, Vehicles, Buildings, Upgrades, Starport.
var _tabs: Array[PanelTab] = []
## Ordered UI mapping from building-grid slots to the IDs supplied by composition.
var _building_option_ids: Array[StringName] = []
var _building_option_ids_by_tab: Dictionary = {}
var _building_option_states: Dictionary = {}
## Same grid, different tab (Tab.UPGRADES) -- see docs/mechanics/production.md
## section 4. IDs are building_ids: GLOBAL_TYPE upgrades are keyed by the
## building type they upgrade (reuses that building's icon/tooltip).
var _upgrade_option_ids: Array[StringName] = []
var _upgrade_option_states: Dictionary = {}
var _icon_paths_by_filename: Dictionary = {}
var _icon_textures: Dictionary = {}
var _entity_tabs: Dictionary = {}
var _pages_by_tab: Dictionary = {}
var _unit_definition_catalog := UnitSceneCatalogScript.new()
var _building_definition_catalog := BuildingDefinitionCatalogScript.new()
var _roster_layout := SidebarRosterLayoutScript.new()
var _credits_amount := 0
var _energy_amount := 0
var _sell_mode_active := false


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
	_page_previous.pressed.connect(_change_page.bind(-1))
	_page_next.pressed.connect(_change_page.bind(1))

	_set_active_tab(Tab.INFANTRY)
	_apply_resources()
	_apply_sell_mode()


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


func _apply_sell_mode() -> void:
	var sell_button := _commands.get_node_or_null("Sell") as Button
	if sell_button != null:
		sell_button.button_pressed = _sell_mode_active


func configure_building_options(building_ids: Array[StringName]) -> void:
	_building_option_ids = building_ids.duplicate()
	_building_option_ids_by_tab.clear()
	_entity_tabs.clear()
	for building_id in _building_option_ids:
		var tab := _art_tab_for_entity(building_id, Tab.BUILDINGS)
		var tab_ids: Array = _building_option_ids_by_tab.get(tab, [])
		tab_ids.append(building_id)
		_building_option_ids_by_tab[tab] = tab_ids
	if is_node_ready():
		_rebuild_queue_grid()


func configure_ordered_roster(
		candidate_ids: Array[StringName], house_pages: Array, subhouse_ids: Array
) -> void:
	var ordered_ids_by_tab: Dictionary = _roster_layout.arrange_by_tab(
		candidate_ids, house_pages, subhouse_ids,
		func(entity_id: StringName) -> Tab: return _art_tab_for_entity(entity_id, Tab.BUILDINGS),
		func(entity_id: StringName) -> Resource:
			var unit := _unit_definition_catalog.definition_for(entity_id)
			return unit if unit != null else _building_definition_catalog.definition(entity_id)
	)
	_building_option_ids = candidate_ids.duplicate()
	_building_option_ids_by_tab.clear()
	_entity_tabs.clear()
	for tab in [Tab.INFANTRY, Tab.VEHICLES, Tab.BUILDINGS]:
		var tab_ids: Array = ordered_ids_by_tab.get(tab, [])
		_building_option_ids_by_tab[tab] = tab_ids
	if is_node_ready():
		_rebuild_queue_grid()


func set_building_option_state(option_state: BuildingOptionState) -> void:
	_building_option_states[option_state.building_id] = option_state
	if is_node_ready():
		_apply_building_option_state(option_state)


## Global per-type upgrades (docs/mechanics/production.md section 4). Mirrors
## configure_building_options()/set_building_option_state() one tab over.
## Refinery docks are instance-bound rather than global, but still appear as
## an ordinary slot here. BuildingUpgradeController automatically targets any
## owned refinery that has a remaining dock state; with none, the slot hides.
func configure_upgrade_options(upgrade_ids: Array[StringName]) -> void:
	_upgrade_option_ids = upgrade_ids.duplicate()
	if is_node_ready():
		_rebuild_queue_grid()


func set_upgrade_option_state(option_state: BuildingOptionState) -> void:
	_upgrade_option_states[option_state.building_id] = option_state
	if is_node_ready():
		_apply_upgrade_option_state(option_state)


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


func _change_page(direction: int) -> void:
	var page_count := _active_page_count()
	var page := clampi(_active_page() + direction, 0, maxi(page_count - 1, 0))
	_pages_by_tab[active_tab] = page
	_rebuild_queue_grid()


func _on_command_pressed(command: StringName) -> void:
	command_pressed.emit(command)


func get_slot(index: int) -> QueueSlot:
	if index < 0 or index >= _queue_grid.get_child_count():
		return null
	return _queue_grid.get_child(index) as QueueSlot


func _apply_building_option_state(option_state: BuildingOptionState) -> void:
	if active_tab != _art_tab_for_entity(option_state.building_id, Tab.BUILDINGS):
		return

	var slot := _building_slot(option_state.building_id)
	if slot == null:
		return

	# Technology prerequisites remove unavailable options from the panel;
	# grey icons remain reserved for queue-specific blocking states.
	# A roster position is an address, not a compact list item.  Keep disabled
	# slots in GridContainer so later icons cannot slide into their cell.
	slot.visible = true
	slot.state = _queue_slot_state(option_state.state)
	slot.progress = option_state.progress
	slot.status_text = option_state.status_text
	slot.quantity = option_state.quantity
	if not option_state.tooltip.is_empty():
		slot.tooltip_text = option_state.tooltip


func _apply_upgrade_option_state(option_state: BuildingOptionState) -> void:
	if active_tab != Tab.UPGRADES:
		return

	var slot := _upgrade_slot(option_state.building_id)
	if slot == null:
		return

	slot.visible = option_state.state != BuildingOptionStateScript.State.DISABLED
	slot.state = _queue_slot_state(option_state.state)
	slot.progress = option_state.progress
	slot.status_text = option_state.status_text
	slot.quantity = option_state.quantity
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

	for index in QUEUE_PAGE_SIZE:
		var slot := QueueSlot.new()
		slot.custom_minimum_size = QUEUE_SLOT_SIZE
		slot.tooltip_text = "Slot %d (empty)" % index
		slot.intent_pressed.connect(_on_slot_pressed.bind(index))
		_queue_grid.add_child(slot)

	_clamp_active_page()
	if active_tab == Tab.UPGRADES:
		var page_ids := _page_slice(_upgrade_option_ids)
		for slot_index in page_ids.size():
			_configure_upgrade_slot(slot_index, page_ids[slot_index])
	else:
		var page_ids := _page_slice(_building_ids_for_tab(active_tab))
		for slot_index in page_ids.size():
			_configure_building_slot(slot_index, page_ids[slot_index])
	_update_page_buttons()


func _page_slice(ids: Array) -> Array:
	var first := _active_page() * QUEUE_PAGE_SIZE
	return ids.slice(first, mini(first + QUEUE_PAGE_SIZE, ids.size()))


func _active_page() -> int:
	return int(_pages_by_tab.get(active_tab, 0))


func _active_page_count() -> int:
	var option_count := (
		_upgrade_option_ids.size()
		if active_tab == Tab.UPGRADES
		else _building_ids_for_tab(active_tab).size()
	)
	return maxi(1, ceili(float(option_count) / float(QUEUE_PAGE_SIZE)))


func _clamp_active_page() -> void:
	_pages_by_tab[active_tab] = clampi(_active_page(), 0, _active_page_count() - 1)


func _update_page_buttons() -> void:
	var page_count := _active_page_count()
	var page := _active_page()
	_page_previous.visible = page_count > 1
	_page_next.visible = page_count > 1
	_page_previous.disabled = page <= 0
	_page_next.disabled = page >= page_count - 1
	_page_previous.tooltip_text = "Previous production page (%d/%d)" % [page + 1, page_count]
	_page_next.tooltip_text = "Next production page (%d/%d)" % [page + 1, page_count]


func _configure_building_slot(
		slot_index: int, building_id: StringName
) -> void:
	var slot := get_slot(slot_index)
	if slot == null:
		return
	var icon_data := _building_icon_data(building_id)
	if icon_data.size() == 2:
		slot.icon_colored = icon_data[0] as Texture2D
		slot.icon_grey = icon_data[1] as Texture2D
	slot.state = QueueSlot.State.AVAILABLE
	slot.tooltip_text = String(building_id)
	var option_state = _building_option_states.get(building_id) as BuildingOptionState
	if option_state != null:
		_apply_building_option_state(option_state)


## GLOBAL_TYPE upgrade ids are the building type they upgrade, so their art
## config supplies this slot's icon as well.
func _configure_upgrade_slot(slot_index: int, upgrade_id: StringName) -> void:
	var slot := get_slot(slot_index)
	if slot == null:
		return
	var icon_data := _building_icon_data(upgrade_id)
	if icon_data.size() == 2:
		slot.icon_colored = icon_data[0] as Texture2D
		slot.icon_grey = icon_data[1] as Texture2D
	slot.tooltip_text = String(upgrade_id)
	slot.state = QueueSlot.State.AVAILABLE
	var option_state = _upgrade_option_states.get(upgrade_id) as BuildingOptionState
	if option_state != null:
		_apply_upgrade_option_state(option_state)


func _building_icon_data(building_id: StringName) -> Array[Texture2D]:
	var unit_definition := _unit_definition_catalog.definition_for(building_id)
	if unit_definition != null:
		var unit_colored := _icon_texture(unit_definition.icon_path)
		var unit_grey := _icon_texture(unit_definition.icon_grey_path)
		var unit_icons: Array[Texture2D] = []
		if unit_colored != null and unit_grey != null:
			unit_icons.assign([unit_colored, unit_grey])
		return unit_icons
	var building_definition := _building_definition_catalog.definition(building_id)
	if building_definition == null:
		return []
	var colored := _icon_texture(building_definition.icon_path)
	var grey := _icon_texture(building_definition.icon_grey_path)
	if colored == null or grey == null:
		return []
	return [colored, grey]


func _icon_texture(rules_path: String) -> Texture2D:
	var filename := rules_path.replace("\\", "/").get_file().to_lower()
	if filename.is_empty():
		return null
	if _icon_textures.has(filename):
		return _icon_textures[filename] as Texture2D
	_index_icon_paths()
	var resource_path := String(_icon_paths_by_filename.get(filename, ""))
	if resource_path.is_empty():
		return null
	var texture := load(resource_path) as Texture2D
	if texture != null:
		_icon_textures[filename] = texture
	return texture


func _index_icon_paths() -> void:
	if not _icon_paths_by_filename.is_empty():
		return
	var directory := DirAccess.open(ICON_TEXTURE_ROOT)
	if directory == null:
		return
	for filename in directory.get_files():
		if filename.get_extension().to_lower() != "tga":
			continue
		_icon_paths_by_filename[filename.to_lower()] = ICON_TEXTURE_ROOT.path_join(filename)


func _building_slot(building_id: StringName) -> QueueSlot:
	var tab := _art_tab_for_entity(building_id, Tab.BUILDINGS)
	if tab != active_tab:
		return null
	var slot_index := _building_ids_for_tab(tab).find(building_id) - _active_page() * QUEUE_PAGE_SIZE
	return get_slot(slot_index)


func _upgrade_slot(upgrade_id: StringName) -> QueueSlot:
	var slot_index := _upgrade_option_ids.find(upgrade_id) - _active_page() * QUEUE_PAGE_SIZE
	return get_slot(slot_index)


func _on_slot_pressed(button_index: int, quantity: int, slot_index: int) -> void:
	if active_tab == Tab.UPGRADES:
		var paged_index := _active_page() * QUEUE_PAGE_SIZE + slot_index
		if paged_index < 0 or paged_index >= _upgrade_option_ids.size():
			return
		upgrade_intent_pressed.emit(_upgrade_option_ids[paged_index], button_index)
		return
	var tab_ids := _building_ids_for_tab(active_tab)
	var paged_index := _active_page() * QUEUE_PAGE_SIZE + slot_index
	if paged_index < 0 or paged_index >= tab_ids.size() or StringName(tab_ids[paged_index]) == &"":
		return
	building_intent_pressed.emit(tab_ids[paged_index], button_index, quantity)


func _building_ids_for_tab(tab: Tab) -> Array:
	return _building_option_ids_by_tab.get(tab, [])


func _art_tab_for_entity(entity_id: StringName, fallback: Tab) -> Tab:
	if _entity_tabs.has(entity_id):
		return int(_entity_tabs[entity_id]) as Tab
	if not is_inside_tree():
		return fallback
	var unit_definition := _unit_definition_catalog.definition_for(entity_id)
	if unit_definition != null:
		var unit_tab := int(ART_SIDEBAR_TABS.get(String(unit_definition.sidebar_type), fallback)) as Tab
		_entity_tabs[entity_id] = unit_tab
		return unit_tab
	var building_definition := _building_definition_catalog.definition(entity_id)
	if building_definition == null:
		return fallback
	var sidebar_type := String(building_definition.sidebar_type)
	var tab := int(ART_SIDEBAR_TABS.get(sidebar_type, fallback)) as Tab
	_entity_tabs[entity_id] = tab
	return tab
