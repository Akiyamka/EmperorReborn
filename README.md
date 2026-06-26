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
- `scripts/main.gd` - Selection and command controller.
- `scripts/rts_camera.gd` - RTS camera movement.
- `scripts/rts_unit.gd` - Basic unit movement and selection state.
- `assets/` - Art, audio, fonts, and imported source assets.
- `addons/` - Godot plugins.
