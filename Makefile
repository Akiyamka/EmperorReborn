GODOT_CONTAINER := ./tools/godot-container

.PHONY: rules-export godot-image godot-check godot-test godot-convert-map godot-convert-building godot-convert-all-buildings godot-convert-all-units godot-convert-placement godot-export-web godot-watch-export godot-shell godot-version

rules-export:
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://converters/import_rules.gd -- --clean

godot-image:
	$(GODOT_CONTAINER) build

godot-check:
	$(GODOT_CONTAINER) check

godot-test:
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://tests/characterization/run.gd
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://tests/buildings/run.gd
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://tests/buildings/placement_run.gd
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://tests/buildings/controller_run.gd
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://tests/buildings/primary_building_run.gd
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://tests/buildings/upgrade_run.gd
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://tests/rules/run.gd
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://tests/match/unit_command_run.gd
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://tests/match/demo_boot_run.gd
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://tests/maps/run.gd
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://tests/navigation/run.gd

godot-convert-map:
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://converters/convert_map.gd -- --source "$(MAP)"

godot-convert-building:
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://converters/convert_building.gd -- --building "$(BUILDING)"

godot-convert-all-buildings:
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://converters/convert_all_buildings.gd

godot-convert-all-units:
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://converters/convert_all_units.gd

godot-convert-placement:
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://converters/convert_placement.gd

godot-export-web:
	$(GODOT_CONTAINER) export-web

godot-watch-export:
	$(GODOT_CONTAINER) watch-export

godot-shell:
	$(GODOT_CONTAINER) shell

godot-version:
	$(GODOT_CONTAINER) version
