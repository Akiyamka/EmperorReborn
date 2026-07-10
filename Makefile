GODOT_CONTAINER := ./tools/godot-container

.PHONY: rules-export godot-image godot-check godot-convert-map godot-convert-building godot-convert-placement godot-export-web godot-watch-export godot-shell godot-version

rules-export:
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://converters/import_rules.gd -- --clean

godot-image:
	$(GODOT_CONTAINER) build

godot-check:
	$(GODOT_CONTAINER) check

godot-convert-map:
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://converters/convert_map.gd -- --source "$(MAP)"

godot-convert-building:
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://converters/convert_building.gd -- --building "$(BUILDING)"

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
