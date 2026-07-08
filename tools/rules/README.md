# Rules Export

`rules.db` is the source SQLite database for gameplay rules. Godot runtime does
not read SQLite directly; generated resources live under `res://data/rules`.

```sh
make rules-export
```

The exporter resolves SQLite foreign keys to stable rule names and writes one
`.tres` resource per entity:

- `data/rules/units/ORAPC.tres`
- `data/rules/buildings/ATConYard.tres`
- `data/rules/turrets/ORAPCBase.tres`
- `data/rules/bullets/Pistol_B.tres`
- `data/rules/warheads/Pistol_W.tres`

In Godot, use the `Rules` autoload:

```gdscript
var config := Rules.unit(&"ORAPC")
var speed := config.field(&"speed", 0.0)
var turrets := config.list(&"turrets")
```
