extends SceneTree

const SidePanelScene := preload("res://scenes/ui/side_panel.tscn")
const BuildingDefinitionCatalogScript := preload("res://scripts/buildings/building_definition_catalog.gd")

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
