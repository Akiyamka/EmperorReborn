extends SceneTree

const SidePanelScene := preload("res://scenes/ui/side_panel.tscn")
const BuildingDefinitionCatalogScript := preload("res://scripts/buildings/building_definition_catalog.gd")
const BuildingOptionStateScript := preload("res://scripts/buildings/building_option_state.gd")

var _assertions := 0
var _failures := 0


func _initialize() -> void:
	var panel = SidePanelScene.instantiate()
	root.add_child(panel)
	await process_frame

	var catalog = BuildingDefinitionCatalogScript.new()
	var ids := catalog.buildable_ids_for_house(&"Atreides", [&"Fremen"])
	ids.append_array(catalog.wall_ids_for_house(&"Atreides", [&"Fremen"]))
	panel.configure_building_options(ids)
	panel._set_active_tab(SidePanel.Tab.BUILDINGS)

	var building_ids: Array = panel._building_ids_for_tab(SidePanel.Tab.BUILDINGS)
	_expect(building_ids.has(&"HKBarracks"), "the panel retains the Harkonnen tree")
	_expect(building_ids.has(&"ORBarracks"), "the panel retains the Ordos tree")
	_expect(building_ids.size() > SidePanel.QUEUE_PAGE_SIZE, "the combined roster spans multiple pages")
	_expect(panel._page_previous.visible and panel._page_next.visible, "page controls appear for a long roster")

	var target_index := building_ids.find(&"ORBarracks")
	var target_page := floori(float(target_index) / float(SidePanel.QUEUE_PAGE_SIZE))
	panel._pages_by_tab[SidePanel.Tab.BUILDINGS] = target_page
	panel._rebuild_queue_grid()
	_expect(panel._building_slot(&"ORBarracks") != null, "an Ordos option is reachable on its page")

	panel.configure_ordered_roster(ids, [&"Atreides"], [&"Fremen"])
	building_ids = panel._building_ids_for_tab(SidePanel.Tab.BUILDINGS)
	_expect(
		building_ids.slice(0, 3) == [&"ATSmWindtrap", &"ATBarracks", &"ATWall"],
		"the first building row follows Rules.txt: Windtrap, Barracks, Wall"
	)
	_expect(
		building_ids.slice(12, 15).has(&"FRCamp"),
		"selected sub-house buildings occupy the dynamic final row"
	)

	panel.configure_ordered_roster(ids, [&"Atreides", &"Harkonnen"], [&"Fremen"])
	building_ids = panel._building_ids_for_tab(SidePanel.Tab.BUILDINGS)
	_expect(
		building_ids.slice(SidePanel.QUEUE_PAGE_SIZE, SidePanel.QUEUE_PAGE_SIZE + 3)
		== [&"", &"HKBarracks", &""],
		"a captured House keeps authored cells while grouped duplicates stay hidden"
	)

	var upgrade_ids: Array[StringName] = []
	for index in SidePanel.QUEUE_PAGE_SIZE + 1:
		upgrade_ids.append(&"ATBarracks" if index == SidePanel.QUEUE_PAGE_SIZE else StringName("Upgrade%d" % index))
	panel.configure_upgrade_options(upgrade_ids)
	panel._set_active_tab(SidePanel.Tab.UPGRADES)
	_expect(panel._page_previous.visible and panel._page_next.visible, "upgrade options paginate independently")
	panel._pages_by_tab[SidePanel.Tab.UPGRADES] = 1
	panel._rebuild_queue_grid()
	var upgrade_slot = panel._upgrade_slot(&"ATBarracks")
	_expect(upgrade_slot != null, "an upgrade on the second page is reachable")
	var disabled_state = BuildingOptionStateScript.new(
		&"ATBarracks", BuildingOptionStateScript.State.DISABLED, 0.0, "", "Unavailable"
	)
	panel.set_upgrade_option_state(disabled_state)
	_expect(not upgrade_slot.visible, "a disabled upgrade slot is hidden")
	var emitted_upgrades: Array[StringName] = []
	panel.upgrade_intent_pressed.connect(
		func(upgrade_id: StringName, _button_index: int): emitted_upgrades.append(upgrade_id)
	)
	panel._on_slot_pressed(MOUSE_BUTTON_LEFT, 1, 0)
	_expect(emitted_upgrades == [&"ATBarracks"], "an upgrade click emits the paged upgrade id")

	panel.free()
	if _failures > 0:
		printerr("SidePanel pagination tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("SidePanel pagination tests: %d assertions passed" % _assertions)
	quit(0)


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s" % message)
