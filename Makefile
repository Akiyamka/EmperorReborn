GODOT_CONTAINER := ./tools/godot-container
RULES_EDITOR_DIR := ./tools/rules_editor
RULES_DB ?= $(CURDIR)/assets/converted/rules.db

.PHONY: rules-editor rules-export unit-definitions unit-definitions-check godot-image godot-check godot-test godot-convert-map godot-convert-building godot-convert-all-buildings godot-convert-all-units godot-convert-projectiles godot-convert-placement godot-convert-cursors godot-convert-spice-mound godot-export-web godot-watch-export godot-shell godot-version

rules-editor:
	cd $(RULES_EDITOR_DIR) && RULES_DB="$(RULES_DB)" npm start

rules-export:
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://converters/import_rules.gd -- --db res://assets/converted/rules.db --clean

unit-definitions:
	python3 tools/generate_unit_definitions.py --db "$(RULES_DB)"

unit-definitions-check:
	python3 tools/generate_unit_definitions.py --db "$(RULES_DB)" --check

godot-image:
	$(GODOT_CONTAINER) build

godot-check:
	$(GODOT_CONTAINER) check

godot-test:
	$(MAKE) unit-definitions-check
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://tests/characterization/run.gd
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://tests/camera/run.gd
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://tests/ui/cursor_run.gd
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://tests/ui/side_panel_pagination_run.gd
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://tests/buildings/run.gd
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://tests/buildings/placement_run.gd
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://tests/buildings/controller_run.gd
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://tests/buildings/techtree_multiple_conyards_run.gd
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://tests/buildings/primary_building_run.gd
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://tests/buildings/upgrade_run.gd
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://tests/rules/run.gd
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://tests/combat/run.gd
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://tests/match/unit_command_run.gd
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://tests/units/deployment_run.gd
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://tests/units/unit_scene_catalog_run.gd
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://tests/units/harvester_run.gd
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://tests/match/demo_boot_run.gd
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://tests/match/snapshot_run.gd
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

godot-convert-projectiles:
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://converters/convert_all_projectiles.gd

godot-convert-placement:
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://converters/convert_placement.gd

godot-convert-cursors:
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://converters/convert_cursor_models.gd

godot-convert-spice-mound:
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://converters/convert_model.gd -- --source res://assets/raw_original_content/3DDATA/spice/Spicemound.xbf --output res://assets/converted/models/Spicemound/Spicemound.scn

godot-export-web:
	$(GODOT_CONTAINER) export-web

godot-watch-export:
	$(GODOT_CONTAINER) watch-export

godot-shell:
	$(GODOT_CONTAINER) shell

godot-version:
	$(GODOT_CONTAINER) version
