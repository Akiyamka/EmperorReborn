# Original Engine Quirks

This document records gaps, contradictions, and implicit behavior in the
original game's data and engine. Each entry separates facts visible in the
shipped data from compatibility decisions made by EmperorReborn.

## Production

### Construction Yard upgrades have no build-time field

**Observed data:** The `ATConYard`, `HKConYard`, and `ORConYard` sections in
`Rules.txt` define `UpgradeTechLevel = 4` and `UpgradeCost = 600`, but define
neither `BuildTime` nor `UpgradeBuildTime`. They do contain `Resource = MCV`.
The `MCV` unit has `BuildTime = 864`.

**Original-engine quirk:** Construction Yard upgrades are not instantaneous,
so their duration must be derived or hardcoded outside the visible ConYard
fields. The exact original derivation has not been verified.

**EmperorReborn compatibility decision:** When a global upgrade has no
`BuildTime`, follow its `Resource` link and use the linked entity's build time.
Construction Yard upgrades therefore use the MCV's 864 ticks. A 60-tick
fallback is reserved for malformed configs with neither a direct time nor a
usable resource link.

## Animation timing

### Infantry base movement animation is too slow

**Observed behavior:** At its configured normal movement speed, infantry's
`Move` animation plays noticeably slower than the unit travels across the
ground. Dynamic scaling still follows changes in the actual movement speed,
but the clip's base rate is too low.

**EmperorReborn compatibility status:** No per-model base-rate correction has
been established yet. The infantry `Move` clip needs a tuned baseline speed
multiplier.

### Wind-blown flag animation is too fast

**Observed behavior:** Building flags animated as if blown by wind cycle at an
anomalously high speed relative to the rest of the scene.

**EmperorReborn compatibility status:** No correction is applied yet. The
flag animation rate needs separate tuning so it is not affected by unrelated
unit movement animation scaling.

## Unit models

### Three unit rules have no convertible H0 model

**Observed data:** `ATHawkWeapon` and `ORBeamWeapon` have art-config entries
but no `xaf` model field. Their rules only reference effect resources
(`ATPalaceBeam`/`Hawk_B` and `ORPalaceLightning`/`Beserk_B`, respectively).
`GUWormCatcher` has `xaf = GU_WormCatcher`, but no matching
`GU_WormCatcher_H0.xbf` exists in `3DDATA/Units`.

**Original-engine quirk:** These unit definitions do not provide a standalone
H0 model through the shipped rules and unit-model files.

**EmperorReborn compatibility decision:** `convert_all_units.gd` reports and
skips these three definitions. It generates scenes for every unit with a
resolvable H0 source model; effect-only units remain represented by their
referenced effects rather than placeholder meshes.

## Building models

### Atreides Refinery H0 contains two broken geometry components

**Observed data:** The shipped `at_refinery_h0.xbf` contains two disconnected
geometry components inside the merged `at_refinery` object that are not part
of the intended refinery model. After the converter deterministically splits
that object by triangle connectivity, these components are `Mesh_03` and
`Mesh_10`.

**Original-engine quirk:** The erroneous components are present in the
original model asset. They are an asset defect rather than geometry from a
valid refinery state.

**EmperorReborn compatibility decision:** Preserve both components in the
converted scene for source fidelity, but mark them with the
`source_asset_quirk = "broken_geometry"` metadata and keep them hidden. The
remaining idle geometry and the independently controlled left and right
SmallPad animations are unaffected.

### Mirrored objects are often authored inside-out

**Observed data:** Objects placed under a consistently mirrored transform
(negative basis determinant, either static or across every object-animation
frame) frequently have their geometry authored inside-out: vertex normals
point into the volume and triangle winding agrees with those inward normals.
Examples: `clonetread01`/`clonetread02` and `girderbox02/04/05` in
`AT_Conyard_HC.XBF`, `OrigTreadR03` in `OR_ConYard_HC.XBF`,
`lfrontpaw`/`lbackleg` in the `IM_Barracks` states, `wormhead` in
`GU_wormhead_H0.xbf`. A signed-volume scan of `3DDATA/Buildings` finds 67
such meshes. The data is inconsistent: 38 other mirrored meshes (for example
`girderbox06` and `Box06` in the same AT ConYard file) are authored with
outward orientation.

**Original-engine quirk:** The original renderer draws without back-face
culling (CorrinoEngine reproduces this), so an inside-out mesh under a mirror
still shows solid geometry - the mirror turns the winding right side out on
screen. Its world-space lighting normals remain inward, which the original
simply displays as slightly wrong shading. Nothing in the shipped data marks
which mirrored meshes are pre-compensated this way.

**EmperorReborn compatibility decision:** Godot flips face culling for
instances with a negative world determinant, which renders exactly the
pre-compensated meshes inside out while the correctly authored mirrored
meshes need no help. `ModelBakeBuilder` therefore tracks the net mirror
parity down the object tree and, inside mirrored subtrees only, detects
inside-out meshes by normalized signed volume (`_mesh_is_inside_out`,
threshold 0.001) and re-orients them at bake time by reversing triangle
winding and negating normals. This also corrects their lighting relative to
the original. The detection is deliberately not applied outside mirrored
subtrees: an unrestricted signed-volume sweep also flags concave debris
meshes (H3 rubble) that must keep their authored orientation.

### Two building art names differ from their H0 filenames

**Observed data:** The `INGUCyclopseHouse` art entry names its model
`IN_GU_CyclopsHouse`, while the source file is
`IN_GU_CyclopseHouse_H0.xbf`. The `PenguinRock` entry names `PenguinRock`,
but its source model is `OR_IN_Penguins_H0.xbf`.

**Original-engine quirk:** The art-table XAF names are not a one-to-one match
for these shipped building XBF filenames.

**EmperorReborn compatibility decision:** `convert_all_buildings.gd` maps
these two building IDs to their actual H0 prefixes before conversion. All 152
rules-defined buildings therefore produce scenes without placeholder models.

### Destroy (H3) debris motion is procedural, marked by a "%" name suffix

**Observed data:** Atreides H3 models (`AT_conyard_H3.XBF`,
`at_barracks_h3.xbf`, `at_Hanger_H3.xbf`, ...) contain no baked animation at
all: every object has animation flags 0, and each visible debris object's
name carries a `%` suffix (`Mesh140%`, `at_fac_flag%`, `conbelt01%`) that its
H0/H1/H2 counterpart does not. Their FX table's `Explode` entry is only a
frame window (0..50 for the ConYard, even 0..0 for Barracks and Hanger) plus
a `MASTER` bank referencing a bang effect (`ATLargeBuildingBang`). In
contrast, `HK_conyard_H3.XBF` names its pieces without `%` and bakes real
per-piece matrix animation (~30 unique matrices per debris object).

**Original-engine quirk:** The engine scattered `%`-suffixed debris pieces
procedurally during the explode window; the XBF carries only the assembled
ruin pose. Generic flying-debris projectiles (`[DebrisTypes]`,
`3DDATA/Debris*.XAF`) are a separate system layered on top.

**EmperorReborn compatibility status:** The converter preserves the `%`
marker in each node's `original_name` metadata and correctly bakes the HK
style keyframed variant. No procedural scatter is implemented yet, so
`%`-style destroy states currently show the static assembled ruin for the
clip's duration.

### Damage states may author whole sub-trees rotated

**Observed data:** In `AT_conyard_H2.XBF` the entire `foyer` object's vertex
data is authored rotated -90° around X relative to H0, with the compensating
+90° rotation stored in the `foyer` node transform. World-space geometry is
identical in placement to H0.

**Original-engine quirk:** State files are independent exports; the exporter
was free to reparent or rebake local spaces between them, and only the
composed transform is meaningful.

**EmperorReborn compatibility decision:** No special handling is needed - the
converter carries node transforms through, and baked scenes render
correctly. Be aware that the Godot editor's mesh-resource preview shows the
mesh in local space without the node transform, so such meshes look lying
down or edge-on in the Inspector while being correct in the scene.

## Textures

### Move and Deploy cursor blue rings omit their screen marker

**Observed data:** Most cursor surfaces that require screen composition mark
their texture name with the original `!` prefix. The blue-ring surface in
`CU_Move_H0.xbf` and `CU_Deploy_H0.xbf` instead references the unmarked shared
texture `whitering2.tga`, even though the ring is rendered as a screen effect
in the original cursor appearance. The same texture is also used as an
ordinary surface by other cursor models, so the texture itself cannot be
classified globally as a screen texture.

**Original-engine quirk:** For these two surfaces, the shipped texture-name
marker does not fully describe the render mode. The additional state used by
the original renderer has not been identified in the converted material
data.

**EmperorReborn compatibility decision:** `convert_cursor_models.gd` records
source-specific `SCREEN_SURFACE_QUIRKS` for `cu_move_h0.xbf` and
`cu_deploy_h0.xbf`: only their `whitering2.tga` surfaces are moved to the
Screen pass. Other uses of this shared texture retain ordinary alpha
composition.

### 16-bit TGAs carry a garbage alpha bit

**Observed data:** 323 of 2462 TGA files in `3DDATA/Textures` are 16bpp
(A1R5G5B5), including damage-state wall textures (`=AT_overhangwall_D_128.tga`,
`at_eagleface_D_128.tga`) and most explosion/flash frames (`!cexp*`,
`!Debriscexp*`, `!%boom*`). Their per-pixel attribute bit is 0, which a
spec-conforming decoder reads as alpha 0 - fully transparent. Several names
exist both with and without the `=` team-colour prefix as separate files of
different bit depths (`=AT_overhangwall_D_128.tga` is 16bpp while
`AT_overhangwall_D_128.tga` is 24bpp); the XBF texture name, prefix included,
selects which file is used.

**Original-engine quirk:** The original loader ignores the 16bpp alpha bit
and treats these pixels as opaque (CorrinoEngine `LibEmperor/Tga.cs` documents
this: "It seems the alpha value is not used here"). Transparency in these
assets comes only from the magenta colour key.

**EmperorReborn compatibility decision:** Godot's TGA decoder honours the
alpha bit, which made every 16bpp texture fully transparent - materials with
alpha-scissor or discard rendered their meshes invisible (e.g. the ConYard
Damage2 wall block). `TextureImageUtils.load_image` detects 16bpp in the TGA
header and forces alpha to 255 after decoding; the magenta colour key is
applied afterwards as before.
