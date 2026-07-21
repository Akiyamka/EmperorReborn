# Unit data migration

Runtime game data has moved from the legacy `Rules` API to ordinary Godot
resources. `Rules.txt`, `assets/converted/rules.db`, and the exported legacy
configs remain as conversion inputs and characterization fixtures, but
`Rules` is no longer a project autoload and gameplay does not query it.

## Current ownership

- `resources/units/definitions/*.tres` contains typed `UnitDefinition`
  resources. Identity, production links, body/movement flags, terrain,
  effects, UI art, scene/model paths, special behavior fields, and veterancy
  paths are represented as Inspector-editable fields.
- `resources/units/veterancy/*.tres` contains typed veterancy levels.
- `resources/combat/{turrets,bullets,warheads}/*.tres` contains the typed weapon
  graph. Bullet definitions also own projectile/impact scene paths; turret
  definitions own muzzle-flash paths. `CombatDefinitionCatalog` loads and
  caches this graph without the `Rules` autoload.
- `resources/buildings/definitions/*.tres` contains production/economy,
  durability, power, technology requirements, footprints/deploy points,
  upgrade, art, survivor, and turret data for buildings.
- `resources/rules/game_settings.tres` owns the currently consumed global
  placement setting, and `resources/world/spice_mound.tres` owns spice mound
  timing, spread, capacity, and effect data.
- `scenes/units/*.tscn` contains editor-placeable units. A scene owns node
  structure, the concrete model, collision, preview behavior, and any special
  script such as `Harvester`.
- `resources/units/generated_unit_manifest.gd` maps `config_id` to definition
  and scene paths. It stores paths rather than preloaded resources.
- `UnitSceneCatalog` lazily loads and caches the requested definition, scene,
  or model. Production, Construction Yard packing, and building survivors use
  this catalog. If a prepared scene is missing, it instantiates `unit.tscn` and
  applies the definition's converted model as a compatibility fallback.

Because mission scenes instance the same files under `scenes/units`, the unit
scenes remain directly reusable by Godot's editor for campaign placement. The
runtime catalog is only a lookup layer and does not create a second scene
format.

## Transitional generation

Run:

```sh
make unit-definitions
make unit-definitions-check
```

The generator reads only the repository-local normalized
`assets/converted/rules.db`, discovers prepared scenes and converted models,
and writes deterministic `.tres` definitions plus path manifests. It covers
units, veterancy, turrets, bullets, warhead armour matrices, combat settings,
buildings, game settings, and spice. The schema contract for the queried lookup,
warhead, bullet, turret, explosion-effect, building, unit, general, art,
custom-field, and resource-link tables is documented in
`assets/converted/schema.sql` sections 1–8 and 12–14.

During migration these generated files must not be hand-edited because the
next generator run overwrites them. Once all runtime consumers have moved off
`Rules`, generation will be retired and the `.tres`/`.tscn` files can be
promoted to authored source of truth. Keeping the same resource paths means
existing campaign scenes continue to reference them without changes.

## Runtime boundary

Every gameplay script outside `scripts/rules` has zero `Rules`, dynamic
`field/list/link`, and `get_entity` calls. The legacy implementation remains
available only for converter/characterization coverage and is installed
explicitly by the few tests that exercise it.

Keep the database and generator while converted rules remain authoritative.
When the generated resources are reviewed and promoted to hand-authored Godot
data, remove the generation step and legacy runtime/config exports; retain the
original rules data as archive/reference for fidelity checks.
