# EmperorReborn

EmperorReborn is a Godot 4 project whose goal is to make a browser-playable version
of *Emperor: Battle for Dune*.

This repository does not include original game assets. Shipping those files
would violate the original game's license. Instead, the project provides tools
for converting resources from a legally owned copy of the original game into
Godot-native formats that can be loaded by the browser build.

## Run Locally

Open this folder with Godot 4.4+ and press Play, or run:

```sh
godot4 --path .
```

If your Godot executable is named `godot`, use:

```sh
godot --path .
```

## Web Export

The project uses `gl_compatibility`, which is the browser-friendly renderer for Godot 4 Web exports.

1. Install Godot Web export templates from `Editor > Manage Export Templates`.
2. Open `Project > Export`.
3. Select the included `Web` preset.
4. Export to `exports/web/index.html`.
5. Serve `exports/web/` through a local web server. Do not open `index.html` directly from the filesystem.

For easiest hosting, keep Web export threads disabled unless your host serves the required `Cross-Origin-Opener-Policy` and `Cross-Origin-Embedder-Policy` headers.

## Using Godot via podman

The repository includes a Podman image definition with Godot 4.7 and Web export templates installed. The project code is mounted into the container at `/workspace`, so the image does not need to be rebuilt when source files change.

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
./tools/godot-container godot --headless --path /workspace --script res://scripts/convert_map.gd -- --source "res://assets/unpacked_rfd/MAPS/#M70 Claw Rock"
```

The converter writes `assets/converted_maps/<map>/map_data.tres` and
`terrain.tscn`. Runtime loading only uses these converted Godot resources; it
does not parse XBF/CPF/CPT files in-game. Select another converted map by
instancing that map's generated `terrain.tscn` in the scene.

Convert an unpacked Emperor building into a Godot-native scene:

```sh
./tools/godot-container godot --headless --path /workspace --script res://scripts/convert_building.gd -- --building ATBarracks
```

Building conversion uses only `H*` model variants from `assets/unpacked_rfd/3DDATA/Buildings`.
The generated scene is written to `assets/converted_buildings/<building>/<building>.scn`.

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
