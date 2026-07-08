GODOT_CONTAINER := ./tools/godot-container

.PHONY: rules-export godot-image godot-check godot-convert-map godot-export-web godot-watch-export godot-shell godot-version

rules-export:
	python3 tools/rules/export_rules_to_tres.py --db tools/rules/rules.db --out data/rules --clean

godot-image:
	$(GODOT_CONTAINER) build

godot-check:
	$(GODOT_CONTAINER) check

godot-convert-map:
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://scripts/convert_map.gd -- --source "$(MAP)"

godot-export-web:
	$(GODOT_CONTAINER) export-web

godot-watch-export:
	$(GODOT_CONTAINER) watch-export

godot-shell:
	$(GODOT_CONTAINER) shell

godot-version:
	$(GODOT_CONTAINER) version
