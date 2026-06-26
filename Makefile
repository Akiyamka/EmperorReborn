GODOT_CONTAINER := ./tools/godot-container

.PHONY: godot-image godot-check godot-export-web godot-watch-export godot-shell godot-version

godot-image:
	$(GODOT_CONTAINER) build

godot-check:
	$(GODOT_CONTAINER) check

godot-export-web:
	$(GODOT_CONTAINER) export-web

godot-watch-export:
	$(GODOT_CONTAINER) watch-export

godot-shell:
	$(GODOT_CONTAINER) shell

godot-version:
	$(GODOT_CONTAINER) version
