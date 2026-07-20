# EmperorReborn

[![YouTube](https://github.com/user-attachments/assets/fec4164b-53c1-42d0-aa93-70f831997e1d
)](https://www.youtube.com/embed/LaDFqT5M1Qs?si=5mcVpGYw0ymfJIeK)



EmperorReborn is a Godot 4 project whose goal is to make a native and browser-playable version
of *Emperor: Battle for Dune*.

This repository does not include original game assets. Shipping those files
would violate the original game's license. Instead, the project provides tools
for converting resources from a legally owned copy of the original game into
Godot-native formats that can be loaded by the game.

## Development prerequisites

The authoritative engine version is **Godot 4.7**.
You can download it from original page [godotengine.org](https://godotengine.org/download/) then open this project from it.

If you are an AI agent, use Podman and the included container wrapper; it mounts this checkout at `/workspace` and includes Godot
and Web export templates:

```sh
make godot-image  # once, or after changing Containerfile
./tools/godot-container godot --version
```

The helper uses rootless-friendly `--userns=keep-id` and a SELinux `:Z` mount.

## Runtime layout

- `scripts/buildings/` owns building queue, placement and controller behavior;
  `scripts/match/` is the demo composition root and injects presentation scenes.
- `scripts/world/camera/` and `scripts/world/map/` own runtime camera and baked-map
  loading/navigation. Map parsing and baking remain converter-only.
- `scripts/ui/` owns widgets and presentation adaptation; `scripts/players/` and
  `scripts/rules/` own player state and the rules-resource schema.
- `converters/` reads original formats and writes Godot resources. Runtime code
  does not parse XBF/CPF/CPT files.

## Assets and conversion

Original inputs and generated outputs under `assets/` are ignored and local;
never hand-edit a
generated `.tres` or `.scn`. The authoritative original-content root for maps,
models, placement and textures is `res://assets/raw_original_content/`; rules
export additionally requires the local `res://assets/rules.db` database.

With those legal local inputs present, regenerate the resources used by the demo
with these commands:

```sh
make rules-export
make godot-convert-placement
make godot-convert-cursors
make godot-convert-building BUILDING=ATConYard
make godot-convert-building BUILDING=ATSmWindtrap
make godot-convert-building BUILDING=ATBarracks
make godot-convert-all-buildings  # every rules-defined building with an H0 model
make godot-convert-all-units      # every H0 model referenced by a unit rule
make godot-convert-projectiles    # bullet models and turret muzzle flashes referenced by Rules/ArtIni
make godot-convert-spice-mound
MAP="res://assets/raw_original_content/MAPS/#M70 Claw Rock" make godot-convert-map
```

The tracked demo unit wrappers require these per-model conversions:

```sh
./tools/godot-container godot --headless --path /workspace --script res://converters/convert_model.gd -- --source res://assets/raw_original_content/3DDATA/Units/AT_inf_H0.xbf
./tools/godot-container godot --headless --path /workspace --script res://converters/convert_model.gd -- --source res://assets/raw_original_content/3DDATA/Units/Or_apc_H0.xbf
./tools/godot-container godot --headless --path /workspace --script res://converters/convert_model.gd -- --source res://assets/raw_original_content/3DDATA/Units/GU_NIABTank_H0.xbf
```

There is deliberately no one-command bootstrap for every original asset or for
the complete demo. A fresh clone needs the legal raw inputs and the applicable
individual conversions above before generated scene references can load.

`make godot-convert-cursors` converts the original `UI0001/CURSORS/CU_*.xbf`
models used at runtime. Every cursor state uses a model scene; there is no
rendered-PNG cursor pipeline or raster fallback. The isolated 3D viewport is
composited normally, while only XBF surfaces whose texture names carry the
original `!` marker use screen blending over the game.

## Verify and run

Permanent asset-independent tests run sequentially and stop on the first
failure (malformed-map diagnostics are expected by their assertions):

```sh
make godot-test
make godot-check
timeout 30s ./tools/godot-container godot --headless --path /workspace --quit-after 10
```

`make godot-check` and demo startup require the local generated assets. For a
clean-cache check, mount the checkout read-only with an empty temporary
`/workspace/.godot` rather than deleting or trusting a user's existing `.godot`;
stale editor cache paths are not source-of-truth.

Export the browser build with `make godot-export-web`; use
`make godot-watch-export` for repeated exports. Serve `exports/web/` through a
web server rather than opening `index.html` directly.

## Credits
- Thanks to the [CorrinoEngine](https://github.com/cookgreen/CorrinoEngine) project, I didn’t have to figure out from scratch how the format of models and animations in the game works. 
- Many thanks to Westwood studio for creating this legendary game
