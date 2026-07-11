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
