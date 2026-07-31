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

### Harkonnen Trooper muzzle flash has a misspelled object name

**Observed data:** `HK_Trooper_H0.xbf` stores its embedded muzzle-flash
geometry in an object named `flah~?`. Other unit models use names containing
`bigflash`, which is the normal marker recognized by the model converter.
The `flah~?` transform remains at a tiny scale during stationary and idle
clips, then expands during `Fire_0`.

**Original-engine quirk:** The shipped Harkonnen Trooper model uses this
misspelled, model-specific name for authored muzzle-flash geometry. Treating
it as ordinary geometry leaves its mesh visible during idle animations.

**EmperorReborn compatibility decision:** `ModelBakeBuilder` recognizes
`flah~?` as embedded muzzle-flash geometry only when converting
`HK_Trooper_H0.xbf`. Its mesh is hidden by default and in non-fire clips, and
is enabled for `Fire_0`, matching the existing handling of `bigflash`
objects without broadening the typo to unrelated models.

### Harkonnen Flamer has corrupt static transforms and trailing frames

**Observed data:** `HK_Flamer_H0.xbf` declares 592 object-animation frames,
but its final named clip (`Stationary`) ends at frame 583. Several object
transforms in frames 584..591 contain `Inf`, while `!#box11` contains finite
but implausible values around `2.9e8`. No animation-table entry references
these eight trailing frames. The stored static transforms for `!#box04` through
`!#box11` (including `gunbone`) are corrupted in the same way: three contain
`Inf`, and the remaining matrices contain values as large as roughly `1e33`.
Their animation timelines all begin with valid authored transforms.

**Original-engine quirk:** The unused tail is malformed source data rather
than part of an authored action. The original engine also replaced the bad
static matrices from animation before rendering. Baking them verbatim makes
Godot's 3D editor instantiate the invalid static pose before autoplay can
apply `Stationary`, producing non-finite renderer transforms.

**EmperorReborn compatibility decision:** For the nine affected nodes,
`ModelBakeBuilder` uses the first valid animation frame as the static pose and
omits object-transform keys after frame 583. Named clips, vertex animation,
and FX timing remain unchanged. As a general safety invariant, any other
non-finite source transform holds the preceding valid pose instead of being
serialized into a converted scene.

## Units

### Advanced Sardaukar knife is flagged as a deployed-only weapon

**Observed data:** `Rules.txt` marks `IMADVSardaukarKnife` as
`turret_disable_if_unit_undeployed = yes` and `IMADVSardaukarGun` as
`turret_disable_if_unit_deployed = yes`. Read literally, this is a deploy
pair: gun active while undeployed, knife active only while deployed — the
same shape as `ATKindjal` / `ORMortar` / `ORKobra`'s real travel/deployed
turret pairs.

**Original-engine quirk:** The Advanced Sardaukar has no deploy ability at
all. The knife is a melee weapon the original engine selects by attack
range against an adjacent target, not a mode unlocked by a deploy state.
The `turret_disable_if_unit_*` flags on this unit are stale or mis-set data
left over from copying a deployable unit's turret rows.

**EmperorReborn compatibility decision:** `tools/generate_unit_definitions.py`
applies a `TURRET_DEPLOY_GATE_OVERRIDES` table that clears both flags when
generating `IMADVSardaukarGun.tres` / `IMADVSardaukarKnife.tres`, so both
turrets are always active and the unit is excluded from the (otherwise
data-driven) combat-deploy eligibility rule — "has at least one turret
gated `disabled_when_deployed` and at least one gated
`disabled_when_undeployed`" — which would otherwise spuriously match it
alongside the three real combat-deployable units.

### OR Mortar ships a static duplicate gun barrel

**Observed data:** `OR_Mortar_H0.xbf` defines two top-level gun objects with
identical geometry (`Mortorgun` and `Mortorgun01`, same 8-vertex/12-triangle
box, same local bounding size). `Mortorgun` carries object-animation keys
across the full 971-frame timeline and matches every clip. `Mortorgun01`
carries 426 keys, but every one of them holds the exact same transform - it
never actually moves. Its children `gunleg03`/`gunleg04` duplicate
`Mortorgun`'s `gunleg1`/`gunleg2`. Clips authored past frame 425 (`Stationary`,
`Shot_1/2`, `Blow_Up_1/2`, `Deployed_Death_1/2`, `Undeploy_Gun`, `Win`,
`Gassed_1`, `Run_Over_1`) have zero keys at all on `Mortorgun01`'s track. Its
only real purpose is carrying the `::1gun#`/`>>1gun#` attachment markers,
which the FX event table uses to anchor the `Fire_1` muzzle bank
(`913E0570#497`/`#498`, frames 422-429).

**Original-engine quirk:** `Mortorgun01` is authoring scaffolding for the
`1gun` attachment point, not a second visible barrel. The original engine
apparently never rendered it; EmperorReborn's converter had no signal to
distinguish it from real geometry, so it rendered as a motionless, oversized
duplicate of the real barrel sitting near the mount point in every clip.

**EmperorReborn compatibility decision:** `ModelBakeBuilder` hides
`Mortorgun01`'s mesh (and its `gunleg03`/`gunleg04` children) via
`HIDDEN_SOURCE_MESH_COMPONENTS`, tagged `source_asset_quirk =
"unrendered_duplicate"`, the same mechanism used for the Atreides Refinery's
broken geometry. The node, its transform, and the `::1gun#`/`>>1gun#`
attachment markers are kept so the `Fire_1` muzzle FX still anchors correctly.

## Explosions

### `chained_explosion_type_id` was speculative schema, not lost data

**Observed data:** `explosion_configs.chained_explosion_type_id` was NULL for
all 11 rows in `assets/converted/rules.db`. `tools/rules_editor/parse_rules.py`
never populated it (the file does not contain the string "chain" at all), and
`assets/raw_original_content/MODEL/*.txt` (`Rules.txt`, `ArtIni.txt`, etc.)
have no "chain" hits either, case-insensitively. Explosion sections in the
source only ever carry `FaceCamera` and `DamageToTile`, matching the table's
other two real columns (`face_camera`, `damage_to_tile`).

**Original-engine quirk:** There is no distinction here to record — unlike
the `Shot` bullet flag (fixed in `44fb405`), where the source data genuinely
had the value and the parser dropped it, `chained_explosion_type_id` was
never backed by anything in the source. It was added to the schema alongside
a foreign-key mapping entry in `converters/import_rules.gd` in anticipation of
a "chained/secondary explosion" concept that the original engine's data does
not express. Do not read "chained explosions are unimplemented" out of this;
the concept simply does not exist in the source to implement.

**EmperorReborn compatibility decision:** The column, its schema declarations
(`assets/converted/schema.sql`, `tools/rules_editor/schema.sql`), and its
`FK_TARGETS` mapping entry were removed, with a comment left in the schema
files so the column is not reintroduced. `assets/converted/rules.db` had the
column dropped in place (not reparsed, to preserve unrelated manual
convert-stage fixes such as the per-house MCV split).

Contrast with `explosion_configs.face_camera`: also unread by any runtime
code today, but it *is* real data — set for `DHBigExplosion`, `ATHawk`, and
`VetLevelFX`, all super-weapon effects that are simply not implemented yet.
That one stays; it is pending, not dead.

## Audio

### ImportedSfx.txt shadows several death hooks with unconverted localized names

**Observed data:** `tools/generate_voice_feedback.py`'s `parse_sources()` keys
SFX sections by `section_name.casefold()` and lets the last source file (in
casefold-sorted filename order) that defines a given name win.
`ImportedSfx.txt` sorts after `AtreidesSFX.txt`, `GeneralSFX.txt`, and
`HarkonnenSFX.txt`, but before `ORDOSSFX.TXT`. Six death hooks are genuinely
shadowed by this: `AtreidesSFX.txt`/`HarkonnenSFX.txt` define real,
multi-sample per-house hooks — `[atnormalmandying]`/`[hknormalmandying]`
(22-sample `normal_dying_1..22`), `[atburningmandying]`/`[hkburningmandying]`
(8-sample `burn_dying_1..8`), `[atchoking]`/`[hkchoking]`
(`choke_dying_1..6`) — and `GeneralSFX.txt` defines a real `[YakDying]`
(`yak_death_1`/`yak_death_2`). `ImportedSfx.txt` redefines the same
casefolded names (`[ATNORMALMANDYING]`, `[ATBURNINGMANDYING]`,
`[ATCHOKING]`, `[HKNORMALMANDYING]`, `[HKBURNINGMANDYING]`, `[HKCHOKING]`,
`[YAKDYING]`), each pointing at a single localized sample name
(`$ATKillguy1`, `$ATburningManDying`, `$ATChoking1`, `$HKKillguy1`,
`$HKburningManDying`, `$HKChoking2`, `$YakDying`) that does not exist
anywhere in the converted WAV archive (`assets/converted/audio/sfx/`).
Ordos's equivalent hooks are unaffected: `ORDOSSFX.TXT` sorts after
`ImportedSfx.txt` and re-wins with its own real samples. A further eight
death-hook ids (`CONTAMDYING`, `ENDWORMDYING`, `FLESHVATDYING`,
`LEECHDYING`, `TLWALKERDYING`, `AT`/`HK`/`ORDICEDMANDYING`) are *not*
shadowing cases — `ImportedSfx.txt` is their only definition, and it always
pointed at an unconverted localized name — but they resolve to zero samples
for the same underlying reason.

**Original-engine quirk:** Not verified whether the original engine actually
played these hooks silently, or whether the `$`-prefixed localized names
resolved through a per-language string/audio table the shipped `SFX/*.txt`
files don't describe on their own.

**Why this is a correctness bug, not just missing polish:** `Unit`'s death
sound resolution (death-animation plan §6) walks an ordered candidate list —
per-house hook, then generic fallback — and stops at the first id *present*
in the generated `DEATH_EVENT_PATHS` manifest. Before this was fixed, the
shadowed per-house ids were still emitted as valid-looking `SoundEvent`
resources with empty `sample_paths`, so they counted as "present": the
resolution picked `atnormalmandying`/`hknormalmandying` and never reached the
real 22-sample generic `normalmandying` hook. Atreides and Harkonnen infantry
— by far the most common death in the game — would have died in total
silence, while Ordos worked only by accident of `ORDOSSFX.TXT` sorting last.

**EmperorReborn compatibility decision:** Fixed at the convert stage, per
this project's rule that wrong source data is corrected where it is
converted rather than papered over with a runtime special case.
`tools/generate_voice_feedback.py`'s `main()` now drops any death/explosion
event whose referenced samples are *all* unresolved against the WAV archive
entirely — it is not written to `resources/audio/events/`, not added to
`expected_events` (so a stale file from a previous run would be removed, not
kept), and not added to `DEATH_EVENT_PATHS`. With the shadowed ids simply
absent from the manifest, `Unit`'s existing candidate-list resolution falls
through to the generic hook on its own, with no runtime "present but empty"
check needed. The generator prints a distinct warning
("N death/explosion events dropped entirely") so this is visible in
`voice-feedback`/`voice-feedback-check` output rather than silent. Voice
(Selection/Move/Attack) events are deliberately left on the old
always-write behavior in this pass — none currently resolve to zero
samples, so there was nothing to change, and applying the same drop rule to
voice events would need `tests/audio/voice_feedback_run.gd`'s expectations
revisited first.

### Vehicle death explosions: the "personal hook" theory was falsified; size tiers are hand-picked instead

**Observed data (the now-abandoned theory):** `HarkonnenSFX.txt` contains four
death-sound sections whose names were renamed away from a per-unit label that
survives only as a commented-out line directly above each one:

| section | commented-out original label | unit |
| --- | --- | --- |
| `[hkmedium1]` | `;dko[HarkAssaultTankDie]` | `HKAssault` |
| `[hkmedium2]` | `;dko[HarkInkvineDie]` | `HKInkVine` |
| `[hksmall1]` | `;dko[HarkBuzzsawDie]` | `HKBuzzsaw` |
| `[explode]` | `;dko[HarkDevastatorDie]` | `HKDevastator` |

An earlier design (commit `105928f`) took this at face value: each of these
four units plays its "personal hook" concurrently with a generic
`GeneralSFX.txt` `[Small]`/`[Medium]`/`[Large]` size-tier boom.

**This was falsified by testing against the reference build.** `HKAssault`
empirically played `explosion_large_3.wav` + `explosion_medium_5.wav` —
*neither* of which is in `[hkmedium1]`'s own sample list
(`bigxplosion04`/`explosion_vehicle_1`/`explosion_vehicle_2`). `HKBuzzsaw`
played `explosion_large_5.wav` + `explosion_vehicle_2.wav`, and
`explosion_vehicle_2` is not even in `[hksmall1]`, its own supposed personal
hook. Further investigation (grepping every `SFX/*.txt` file and every
converted XBF model's embedded `sound_names` strings) found that essentially
every unit's model references *some* personal-hook-shaped name, but almost
all of them are dead, `$`-prefixed localized stubs in `ImportedSfx.txt` with
zero real samples behind them — these four just happen to be the only ones
that survived with real English samples, which is a fact about which stubs
got localized, not evidence that these four units are audio-special.
**Conclusion: the original engine's actual per-unit death-sample selection is
hardcoded in the shipped binary and is not recoverable from any available
source data.** `explode` is still specifically `HarkDevastatorDie`, not a
generic id (so it must never be handed to an arbitrary vehicle or to
infantry) — that grep fact stands — but "personal hook + generic tier, both
concurrent" as a *selection mechanism* does not.

**EmperorReborn compatibility decision:** abandon precision. `VehicleDeathStrategy`
drops `PERSONAL_DEATH_HOOKS` and the whole `GeneratedVoiceManifest`
indirection for this mechanism entirely, replaced by a hand-specified
three-pool system (`ExplosionTierPools`: `small`/`medium`/`large`, each a
pool of `explosion_{small,medium,large}_*.wav` referenced directly, bypassing
`SoundEvent`/the generated manifest) confirmed by ear-testing several units
against the reference build. `TIER_OVERRIDES` lists every unit the user
specified by ear; everything else defaults to `medium` — an **approximation,
not sourced data**, since the per-unit tier itself is still hardcoded in the
binary and `explosion_type_id` (the visual VFX bank) does not correlate with
it at all (`HKDevastator` and `ATMongoose` share the same generic `Explosion`
bank). Current overrides: Harkonnen vehicles are all `medium` except
`HKDevastator` (`large`); Atreides `ATTrike`/`ATAPC` are `small`,
`ATMinotaurus` is `large`; Ordos `ORDustScout` is `small`, `ORKobra` is
`large`; the shared `Harvester`/`FakeHarvester` and the Guild `GUNIABTank`
are `large`.

**Separately, an unconditional per-house layer:** every Harkonnen vehicle
additionally plays one of `explosion_vehicle_1.wav`/`explosion_vehicle_2.wav`,
and every Ordos vehicle plays one of `explosionordos01..06.wav`, both at the
start of the death animation regardless of size tier (`VehicleDeathStrategy.
death_start_sound_paths`, keyed off `house_id` rather than a per-unit list, so
it covers every vehicle in those houses automatically). Atreides and every
other faction get no such layer. This approximates the doubled-boom behavior
the original falsified theory was trying to explain, without claiming it is
the same mechanism.

`explosion_medium_1.wav` is deliberately excluded from the `medium` pool: it
was renamed to `explosion_fire.wav` at convert time
(`converters/convert_audio_bag.gd`'s `RENAMED_ENTRIES`) because that sample is
actually used in-game for the (not yet implemented) Inkvine special ability,
not for generic medium explosions.

### Infantry `Blow_Up` has no corpse sound of its own

**Observed data:** `Blow_Up_1`/`Blow_Up_2` (present on every converted infantry
model) is purely a "corpse gets launched by an explosion" animation. There is
no per-house or generic `*ManDying`-family hook for a physical blow-up at all —
the `[explode]` family it appears to want is `HarkDevastatorDie` (above), a
vehicle's personal hook.

**EmperorReborn compatibility decision:** `InfantryDeathStrategy` proposes no
sound layer for `Blow_Up`. The boom the player hears in the original belongs to
the *weapon's* detonation, a separate system (`combat_impact_resolver.gd` /
`combat_projectile.gd`) that has no SFX wiring yet; giving the corpse its own
boom would double it up once weapon-impact SFX lands. `Burn`/`Shot`/`Gassed`
keep their unrelated per-house/generic hooks unchanged.

**`HKFlamer` is the one exception:** user-confirmed, it emits a `small`-tier
boom *regardless of what killed it*, because its own fuel tank ruptures as part
of dying. Its converted model carries only the ordinary infantry clip set (no
bespoke "tank explodes" clip), so this is modelled as an extra sound layer
alongside whatever the cause resolved to — not a forced `Blow_Up` cause — and
no visual effect (`HKFlamer.explosion_type_id` is already `None`). Scoped to
this one unit: no equivalent hook or comment exists for any other infantry, so
this is a recorded observation, not an extrapolated "special payload" rule.
Same `ExplosionTierPools` direct-WAV pool the vehicle size tiers use
(`InfantryDeathStrategy.death_start_sound_paths`), not the manifest, and it
plays immediately alongside its per-cause scream — infantry has no separate
VFX-spawn call site to time against the way vehicles do, and the user
confirmed no artificial delay/sync attempt is wanted here.

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

### AT Pillbox's Idle 0 range is nested inside Fire 0

**Observed data:** Every shipped `AT_MGT` H/M/L state uses the same clip
table: `Stationary` is frames 104..133, `Idle 0` is 200..240, and `Fire 0` is
193..275. The only moving gun transforms occupy frames 194..230, while the
short-burst sound and firing events occupy frames 194..257. `Idle 0` therefore
contains the machine-gun recoil instead of an idle motion.

**Original-engine quirk:** This overlap is present verbatim in each original
XBF; it is not an animation-table parsing error. Buildings use `Stationary` as
their resting state, so the mislabeled optional idle clip did not affect the
original building state.

**EmperorReborn compatibility decision:** `ModelXbf` preserves the authored
table for lossless inspection. `ModelBakeBuilder` repairs only the converted
`AT_MGT` `Idle_0` clip by assigning it that file's `Stationary` frame range,
while retaining frames 200..240 as `source_start_frame`/`source_end_frame`
metadata. `Fire_0` and its event schedule remain unchanged.

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

### Move, Attack, and Deploy cursor blue rings omit their screen marker

**Observed data:** Most cursor surfaces that require screen composition mark
their texture name with the original `!` prefix. The blue-ring surfaces in
`CU_Move_H0.xbf`, `CU_attack_H0.xbf`, and `CU_Deploy_H0.xbf` instead reference
the unmarked shared texture `whitering2.tga`, even though the rings are rendered
as screen effects in the original cursor appearance. The same texture is also
used as an ordinary surface by other cursor models, so the texture itself
cannot be classified globally as a screen texture.

**Original-engine quirk:** For these three surfaces, the shipped texture-name
marker does not fully describe the render mode. The additional state used by
the original renderer has not been identified in the converted material
data.

**EmperorReborn compatibility decision:** `convert_cursor_models.gd` records
source-specific `SCREEN_SURFACE_QUIRKS` for `cu_move_h0.xbf`,
`cu_attack_h0.xbf`, and `cu_deploy_h0.xbf`: only their `whitering2.tga`
surfaces are moved to the Screen pass. Other uses of this shared texture
retain ordinary alpha composition.

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
