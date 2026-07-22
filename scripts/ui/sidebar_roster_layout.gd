class_name SidebarRosterLayout
extends RefCounted

## Recreates the authored sidebar sequence from Rules.txt.  Each Great House
## owns the first twelve cells of a page; the final row is reserved for the
## selected sub-houses' additions.

const RULES_PATH := "res://assets/raw_original_content/MODEL/Rules.txt"
const STATIC_SLOTS_PER_PAGE := 12
const DYNAMIC_SLOTS_PER_PAGE := 3

var _building_order: Array[StringName] = []
var _unit_order: Array[StringName] = []


func _init() -> void:
	_load_source_order()


func arrange_by_tab(
		candidate_ids: Array[StringName], house_pages: Array, subhouse_ids: Array,
		art_tab_for: Callable, definition_for: Callable
	) -> Dictionary:
	var candidates: Dictionary = {}
	for id in candidate_ids:
		candidates[id] = true

	var result_by_tab: Dictionary = {}
	for tab in [0, 1, 2]:
		result_by_tab[tab] = _arrange_tab(
			tab, candidates, house_pages, subhouse_ids, art_tab_for, definition_for
		)

	return result_by_tab


func _arrange_tab(
		tab: int, candidates: Dictionary, house_pages: Array, subhouse_ids: Array,
		art_tab_for: Callable, definition_for: Callable
	) -> Array[StringName]:
	var static_by_house: Dictionary = {}
	var dynamic: Array[StringName] = []
	var home_house: StringName = StringName(house_pages[0]) if not house_pages.is_empty() else &""
	for house_id in house_pages:
		static_by_house[house_id] = []

	for id in _source_ordered_candidates(candidates):
		if int(art_tab_for.call(id)) != tab:
			continue
		var definition: Resource = definition_for.call(id)
		var house_id: StringName = definition.house_id if definition != null else &""
		if house_id in static_by_house:
			static_by_house[house_id].append(id)
		elif house_id == &"" and not home_house.is_empty():
			static_by_house[home_house].append(id)
		elif house_id in subhouse_ids:
			dynamic.append(id)

	var pages := maxi(house_pages.size(), ceili(float(dynamic.size()) / DYNAMIC_SLOTS_PER_PAGE))
	var result: Array[StringName] = []
	for page in pages:
		var page_house: StringName = StringName(house_pages[page]) if page < house_pages.size() else &""
		var static_ids: Array = static_by_house.get(page_house, [])
		var source_ids := _source_ids_for_house(page_house, home_house, tab, art_tab_for, definition_for)
		for slot in STATIC_SLOTS_PER_PAGE:
			var source_id: StringName = source_ids[slot] if slot < source_ids.size() else &""
			result.append(source_id if source_id in static_ids else &"")
		for slot in DYNAMIC_SLOTS_PER_PAGE:
			var dynamic_index := page * DYNAMIC_SLOTS_PER_PAGE + slot
			result.append(dynamic[dynamic_index] if dynamic_index < dynamic.size() else &"")
	return result


func _source_ids_for_house(
		house_id: StringName, home_house: StringName, tab: int, art_tab_for: Callable, definition_for: Callable
	) -> Array[StringName]:
	var result: Array[StringName] = []
	for id in _building_order + _unit_order:
		if int(art_tab_for.call(id)) != tab:
			continue
		var definition: Resource = definition_for.call(id)
		if definition == null:
			continue
		if definition.cost <= 0 or definition.primary_building_ids.is_empty() \
		or definition.get("is_construction_yard") == true:
			continue
		var id_house: StringName = definition.house_id
		if id_house == house_id or (id_house == &"" and house_id == home_house):
			result.append(id)
	return result


func _source_ordered_candidates(candidates: Dictionary) -> Array[StringName]:
	var result: Array[StringName] = []
	var seen: Dictionary = {}
	for id in _building_order + _unit_order:
		if candidates.has(id) and not seen.has(id):
			seen[id] = true
			result.append(id)
	var remaining: Array[StringName] = []
	for value in candidates.keys():
		var id := StringName(String(value))
		if not seen.has(id):
			remaining.append(id)
	remaining.sort()
	result.append_array(remaining)
	return result


func _load_source_order() -> void:
	var file := FileAccess.open(RULES_PATH, FileAccess.READ)
	if file == null:
		push_warning("Sidebar order source is unavailable: %s" % RULES_PATH)
		return
	var section := ""
	for line in file.get_as_text().split("\n"):
		var comment_start := line.find("//")
		var value := line.left(comment_start).strip_edges() if comment_start >= 0 else line.strip_edges()
		if value.begins_with("[") and value.ends_with("]"):
			section = value.substr(1, value.length() - 2)
			continue
		if value.is_empty() or value.begins_with("["):
			continue
		if section == "BuildingTypes":
			_building_order.append(StringName(value))
		elif section == "UnitTypes":
			_unit_order.append(StringName(value))
