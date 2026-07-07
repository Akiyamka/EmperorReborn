# EmperorJS

Browser-targeted 3D RTS prototype built with Godot 4.

## Run Locally

Open this folder with Godot 4.4+ and press Play, or run:

```sh
godot4 --path .
```

If your Godot executable is named `godot`, use:

```sh
godot --path .
```

## Controls

- `WASD` or arrow keys - move camera.
- `Q` / `E` - rotate camera.
- Mouse wheel - zoom.
- Left click - select a unit.
- Right click - move selected unit.

## Web Export

The project uses `gl_compatibility`, which is the browser-friendly renderer for Godot 4 Web exports.

1. Install Godot Web export templates from `Editor > Manage Export Templates`.
2. Open `Project > Export`.
3. Select the included `Web` preset.
4. Export to `exports/web/index.html`.
5. Serve `exports/web/` through a local web server. Do not open `index.html` directly from the filesystem.

For easiest hosting, keep Web export threads disabled unless your host serves the required `Cross-Origin-Opener-Policy` and `Cross-Origin-Embedder-Policy` headers.

## Podman Godot Container

The repository includes a Podman image definition with Godot 4.4.1 and Web export templates installed. The project code is mounted into the container at `/workspace`, so the image does not need to be rebuilt when source files change.

Build the image:

```sh
make godot-image
```

Validate/import the project in headless mode:

```sh
make godot-check
```

Convert an unpacked Emperor map into Godot-native resources:

```sh
./tools/godot-container godot --headless --path /workspace --script res://scripts/convert_map.gd -- --source "res://assets/maps/#M70 Claw Rock"
```

The converter writes `assets/converted_maps/<map>/map_data.tres` and
`terrain.tscn`. Runtime loading only uses these converted Godot resources; it
does not parse XBF/CPF/CPT files in-game. Select another converted map by
instancing that map's generated `terrain.tscn` in the scene.

Export the browser build to `exports/web/index.html`:

```sh
make godot-export-web
```

Re-export automatically when files change:

```sh
make godot-watch-export
```

Run arbitrary Godot commands:

```sh
./tools/godot-container godot --headless --path /workspace --quit
```

Open a shell inside the mounted project container:

```sh
make godot-shell
```

The helper uses rootless-friendly Podman flags: `--userns=keep-id` and `-v <project>:/workspace:Z`.

## Structure

- `project.godot` - Godot project settings.
- `export_presets.cfg` - Web export preset.
- `Containerfile` - Podman image with Godot and Web templates.
- `tools/godot-container` - Helper for running Godot against the mounted project.
- `scenes/main.tscn` - Main RTS test map.
- `scenes/units/unit.tscn` - Placeholder selectable unit.
- `scenes/debug/screenshot.tscn` - Headless screenshot helper for visual checks.
- `scripts/main.gd` - Selection and command controller.
- `scripts/xbf.gd` - Parser for Emperor: Battle for Dune XBF terrain meshes.
- `scripts/convert_map.gd` - Headless converter from unpacked Emperor map folders into Godot resources.
- `scripts/map_bake_builder.gd` - Shared conversion builder for terrain, materials, collision, lighting, and nav data.
- `scripts/baked_map_data.gd` - Resource format consumed by runtime map loading.
- `scripts/map_loader.gd` - Loads converted `map_data.tres` terrain with collision and nav data.
- `scripts/terrain.gdshader` - Tiled theme texture modulated by the map's baked ground-tone layer.
- `scripts/rts_camera.gd` - RTS camera movement.
- `scripts/rts_unit.gd` - Basic unit movement and selection state.
- `assets/maps/` - Unpacked Emperor map folders (see `../specs/emperor-map-file-format.md`). These are converter inputs.
- `assets/converted_maps/` - Godot-native converted map resources used by runtime.
- `assets/` - Art, audio, fonts, and imported source assets.
- `addons/` - Godot plugins.
