#!/usr/bin/env python3
"""Export the normalized Emperor rules SQLite database to Godot .tres files."""

from __future__ import annotations

import argparse
import json
import re
import sqlite3
from collections.abc import Iterable
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_DB_PATH = Path(__file__).resolve().with_name("rules.db")
DEFAULT_OUT_DIR = PROJECT_ROOT / "data" / "rules"


ENTITY_EXPORTS = [
    {
        "table": "terrain_types",
        "folder": "terrain_types",
        "entity_type": "terrain_type",
        "class_name": "TerrainTypeConfig",
        "script": "res://scripts/rules/terrain_type_config.gd",
    },
    {
        "table": "armour_types",
        "folder": "armour_types",
        "entity_type": "armour_type",
        "class_name": "ArmourTypeConfig",
        "script": "res://scripts/rules/armour_type_config.gd",
    },
    {
        "table": "houses",
        "folder": "houses",
        "entity_type": "house",
        "class_name": "HouseConfig",
        "script": "res://scripts/rules/house_config.gd",
    },
    {
        "table": "building_groups",
        "folder": "building_groups",
        "entity_type": "building_group",
        "class_name": "BuildingGroupConfig",
        "script": "res://scripts/rules/building_group_config.gd",
    },
    {
        "table": "unit_groups",
        "folder": "unit_groups",
        "entity_type": "unit_group",
        "class_name": "UnitGroupConfig",
        "script": "res://scripts/rules/unit_group_config.gd",
    },
    {
        "table": "debris_types",
        "folder": "debris",
        "entity_type": "debris",
        "class_name": "DebrisConfig",
        "script": "res://scripts/rules/debris_config.gd",
    },
    {
        "table": "warheads",
        "folder": "warheads",
        "entity_type": "warhead",
        "class_name": "WarheadConfig",
        "script": "res://scripts/rules/warhead_config.gd",
    },
    {
        "table": "bullets",
        "folder": "bullets",
        "entity_type": "bullet",
        "class_name": "BulletConfig",
        "script": "res://scripts/rules/bullet_config.gd",
    },
    {
        "table": "turrets",
        "folder": "turrets",
        "entity_type": "turret",
        "class_name": "TurretConfig",
        "script": "res://scripts/rules/turret_config.gd",
    },
    {
        "table": "explosion_types",
        "folder": "explosions",
        "entity_type": "explosion",
        "class_name": "ExplosionConfig",
        "script": "res://scripts/rules/explosion_config.gd",
    },
    {
        "table": "crate_types",
        "folder": "crates",
        "entity_type": "crate",
        "class_name": "CrateConfig",
        "script": "res://scripts/rules/crate_config.gd",
    },
    {
        "table": "splat_types",
        "folder": "splats",
        "entity_type": "splat",
        "class_name": "SplatConfig",
        "script": "res://scripts/rules/splat_config.gd",
    },
    {
        "table": "spice_mound_types",
        "folder": "spice_mounds",
        "entity_type": "spice_mound",
        "class_name": "SpiceMoundConfig",
        "script": "res://scripts/rules/spice_mound_config.gd",
    },
    {
        "table": "buildings",
        "folder": "buildings",
        "entity_type": "building",
        "class_name": "BuildingConfig",
        "script": "res://scripts/rules/building_config.gd",
    },
    {
        "table": "units",
        "folder": "units",
        "entity_type": "unit",
        "class_name": "UnitConfig",
        "script": "res://scripts/rules/unit_config.gd",
    },
]

GENERAL_EXPORT = {
    "table": "general_settings",
    "folder": "general",
    "entity_type": "general",
    "class_name": "GeneralRulesConfig",
    "script": "res://scripts/rules/general_rules_config.gd",
}

FK_TARGETS = {
    "house_id": "houses",
    "unit_group_id": "unit_groups",
    "building_group_id": "building_groups",
    "armour_type_id": "armour_types",
    "armour_modifier_terrain_id": "terrain_types",
    "debris_id": "debris_types",
    "chaos_effect_id": "explosion_types",
    "hawk_effect_id": "explosion_types",
    "damage_effect_id": "explosion_types",
    "explosion_type_id": "explosion_types",
    "chained_explosion_type_id": "explosion_types",
    "view_range_bonus_terrain_id": "terrain_types",
    "special_ground_terrain_id": "terrain_types",
    "turret_attach_id": "turrets",
    "turret_next_joint_id": "turrets",
    "get_unit_when_built_id": "units",
    "bullet_id": "bullets",
    "warhead_id": "warheads",
    "terrain_type_id": "terrain_types",
    "required_building_id": "buildings",
    "building_id": "buildings",
    "unit_id": "units",
    "turret_id": "turrets",
    "role_id": "building_roles",
    "crate_type_id": "crate_types",
    "warhead_id": "warheads",
    "armour_type_id": "armour_types",
}

BOOL_COLUMNS = {
    "houses": {"is_sub_house"},
    "buildings": {
        "can_be_engineered",
        "can_be_primary",
        "is_con_yard",
        "ai_exit",
        "ai_manufacturing",
        "selectable",
        "ai_defence",
        "ai_critical",
        "ai_core",
        "ai_resource",
        "exclude_from_skirmish_lose",
        "exclude_from_campaign_lose",
        "upgraded_primary_required",
        "disable_with_low_power",
        "disable_if_no_spice_on_map",
        "hide_unit_on_radar",
        "counts_for_stats",
        "gets_height_advantage",
    },
    "units": {
        "tasty_to_worms",
        "can_move_any_direction",
        "can_be_deviated",
        "can_self_repair",
        "can_be_repaired",
        "infantry",
        "crushable",
        "crushes",
        "starportable",
        "ai_special",
        "ai_tank",
        "ai_foot",
        "ai_air",
        "ai_uncontrolled",
        "ai_critical",
        "gets_height_advantage",
        "upgraded_primary_required",
        "crate_gift",
        "can_be_suppressed",
        "can_fly",
        "can_die",
        "cant_be_leeched",
        "advanced_carryall",
        "projectable",
        "circles",
        "selectable",
        "stealthed_when_still",
        "exclude_from_skirmish_lose",
        "can_be_engineered",
    },
    "bullets": {
        "blow_up",
        "reduce_damage_with_distance",
        "anti_aircraft",
        "anti_ground",
        "homing",
        "continuous",
        "trajectory",
        "burnt",
        "ignites",
        "gassed",
        "is_laser",
        "leech",
        "infantry",
        "damage_column",
        "deviate",
        "beserk",
        "retreat",
    },
    "turrets": {
        "turret_disable_if_unit_deployed",
        "turret_disable_if_unit_undeployed",
    },
    "explosion_configs": {"face_camera"},
    "unit_veterancy_levels": {"can_self_repair", "elite", "stealthed_when_still"},
    "general_settings": {"replica_should_fire"},
}

ENTITY_ALIASES = {
    "units": ["unit", "units"],
    "buildings": ["building", "buildings"],
    "bullets": ["bullet", "bullets"],
    "splat_types": ["splat_type", "splat_types"],
    "spice_mound_types": ["spice_mound_type", "spice_mound_types"],
}

EXPLOSION_EFFECT_ENTITY_TYPES = {
    "units": "unit",
    "buildings": "building",
    "bullets": "bullet",
    "splat_types": "splat_type",
    "spice_mound_types": "spice_mound_type",
}

RESOURCE_LINK_ENTITY_TYPES = {
    "units": "unit",
    "buildings": "building",
    "splat_types": "splat_type",
    "spice_mound_types": "spice_mound_type",
}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=DEFAULT_DB_PATH)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT_DIR)
    parser.add_argument(
        "--clean",
        action="store_true",
        help="Remove existing generated .tres files under --out before exporting.",
    )
    args = parser.parse_args()

    if not args.db.exists():
        raise SystemExit(f"Rules database does not exist: {args.db}")

    con = sqlite3.connect(args.db)
    con.row_factory = sqlite3.Row

    if args.clean and args.out.exists():
        for path in args.out.rglob("*.tres"):
            path.unlink()

    args.out.mkdir(parents=True, exist_ok=True)
    lookups = load_name_lookups(con)

    written = 0
    used_names_by_folder: dict[str, set[str]] = {}
    for export in ENTITY_EXPORTS:
        folder = args.out / export["folder"]
        rows = con.execute(f"SELECT * FROM {export['table']} ORDER BY id").fetchall()
        for row in rows:
            config = build_entity_config(con, lookups, export, row)
            filename = unique_filename(folder, str(config["id"]), used_names_by_folder)
            write_config(folder / filename, export, config)
            written += 1

    general_row = con.execute("SELECT * FROM general_settings WHERE id = 1").fetchone()
    if general_row is not None:
        config = build_general_config(lookups, general_row)
        write_config(args.out / GENERAL_EXPORT["folder"] / "general.tres", GENERAL_EXPORT, config)
        written += 1

    print(f"Exported {written} rules resources to {args.out}")


def load_name_lookups(con: sqlite3.Connection) -> dict[str, dict[int, str]]:
    result: dict[str, dict[int, str]] = {}
    for table in [
        "terrain_types",
        "armour_types",
        "houses",
        "building_groups",
        "unit_groups",
        "debris_types",
        "warheads",
        "bullets",
        "turrets",
        "explosion_types",
        "crate_types",
        "splat_types",
        "spice_mound_types",
        "buildings",
        "units",
        "building_roles",
    ]:
        result[table] = {row["id"]: row["name"] for row in con.execute(f"SELECT id, name FROM {table}")}
    return result


def build_entity_config(
    con: sqlite3.Connection,
    lookups: dict[str, dict[int, str]],
    export: dict[str, str],
    row: sqlite3.Row,
) -> dict[str, Any]:
    table = export["table"]
    fields = row_fields(lookups, table, row, skip={"id", "name"})
    fields.update(extra_fields(con, lookups, table, row["id"]))
    lists = child_lists(con, lookups, table, row["id"])
    links = child_links(con, table, row["id"])

    return {
        "id": row["name"],
        "entity_type": export["entity_type"],
        "source_table": table,
        "source_id": row["id"],
        "fields": fields,
        "lists": lists,
        "links": links,
    }


def build_general_config(
    lookups: dict[str, dict[int, str]],
    row: sqlite3.Row,
) -> dict[str, Any]:
    return {
        "id": "general",
        "entity_type": "general",
        "source_table": "general_settings",
        "source_id": row["id"],
        "fields": row_fields(lookups, "general_settings", row, skip={"id"}),
        "lists": {},
        "links": {},
    }


def extra_fields(
    con: sqlite3.Connection,
    lookups: dict[str, dict[int, str]],
    table: str,
    source_id: int,
) -> dict[str, Any]:
    fields: dict[str, Any] = {}

    if table == "warheads":
        armour_damage = {
            row["name"]: row["damage_percent"]
            for row in con.execute(
                "SELECT a.name, wd.damage_percent FROM warhead_armour_damage wd JOIN armour_types a ON a.id = wd.armour_type_id WHERE wd.warhead_id = ? ORDER BY a.sort_order, a.id",
                [source_id],
            )
        }
        if armour_damage:
            fields["armour_damage"] = armour_damage

    elif table == "explosion_types":
        config = con.execute(
            "SELECT * FROM explosion_configs WHERE explosion_type_id = ?",
            [source_id],
        ).fetchone()
        if config is not None:
            fields.update(row_fields(lookups, "explosion_configs", config, skip={"explosion_type_id"}))

    return fields


def row_fields(
    lookups: dict[str, dict[int, str]],
    table: str,
    row: sqlite3.Row,
    skip: set[str],
) -> dict[str, Any]:
    fields: dict[str, Any] = {}
    for column in row.keys():
        if column in skip:
            continue
        value = convert_value(lookups, table, column, row[column])
        if value is not None:
            fields[field_key(column)] = value
    return fields


def child_lists(
    con: sqlite3.Connection,
    lookups: dict[str, dict[int, str]],
    table: str,
    source_id: int,
) -> dict[str, Any]:
    lists: dict[str, Any] = {}

    if table == "units":
        set_if_any(
            lists,
            "turrets",
            names(con, "SELECT t.name FROM unit_turrets ut JOIN turrets t ON t.id = ut.turret_id WHERE ut.unit_id = ? ORDER BY ut.seq", [source_id]),
        )
        set_if_any(
            lists,
            "terrain",
            names(con, "SELECT t.name FROM unit_terrain ut JOIN terrain_types t ON t.id = ut.terrain_type_id WHERE ut.unit_id = ? ORDER BY t.sort_order, t.id", [source_id]),
        )
        set_if_any(
            lists,
            "primary_buildings",
            names(con, "SELECT b.name FROM unit_primary_buildings up JOIN buildings b ON b.id = up.building_id WHERE up.unit_id = ? ORDER BY b.id", [source_id]),
        )
        set_if_any(
            lists,
            "secondary_buildings",
            names(con, "SELECT b.name FROM unit_secondary_buildings us JOIN buildings b ON b.id = us.building_id WHERE us.unit_id = ? ORDER BY b.id", [source_id]),
        )
        veterancy = [
            row_fields(lookups, "unit_veterancy_levels", row, skip={"id", "unit_id"})
            for row in con.execute(
                "SELECT * FROM unit_veterancy_levels WHERE unit_id = ? ORDER BY level_order",
                [source_id],
            )
        ]
        set_if_any(lists, "veterancy_levels", veterancy)

    elif table == "buildings":
        set_if_any(
            lists,
            "occupy_rows",
            [row["pattern"] for row in con.execute("SELECT pattern FROM building_occupy_rows WHERE building_id = ? ORDER BY row_index", [source_id])],
        )
        set_if_any(
            lists,
            "terrain",
            names(con, "SELECT t.name FROM building_terrain bt JOIN terrain_types t ON t.id = bt.terrain_type_id WHERE bt.building_id = ? ORDER BY t.sort_order, t.id", [source_id]),
        )
        set_if_any(
            lists,
            "requires_primary",
            names(con, "SELECT b.name FROM building_requires_primary bp JOIN buildings b ON b.id = bp.required_building_id WHERE bp.building_id = ? ORDER BY b.id", [source_id]),
        )
        set_if_any(
            lists,
            "requires_secondary",
            names(con, "SELECT b.name FROM building_requires_secondary bs JOIN buildings b ON b.id = bs.required_building_id WHERE bs.building_id = ? ORDER BY b.id", [source_id]),
        )
        deploy_points = [
            compact_dict(
                {
                    "seq": row["seq"],
                    "tile_x": row["tile_x"],
                    "tile_y": row["tile_y"],
                    "angle": row["angle"],
                }
            )
            for row in con.execute(
                "SELECT seq, tile_x, tile_y, angle FROM building_deploy_points WHERE building_id = ? ORDER BY seq",
                [source_id],
            )
        ]
        set_if_any(lists, "deploy_points", deploy_points)
        set_if_any(
            lists,
            "roles",
            names(con, "SELECT r.name FROM building_role_tags bt JOIN building_roles r ON r.id = bt.role_id WHERE bt.building_id = ? ORDER BY r.name", [source_id]),
        )

    elif table == "crate_types":
        set_if_any(
            lists,
            "terrain",
            names(con, "SELECT t.name FROM crate_terrain ct JOIN terrain_types t ON t.id = ct.terrain_type_id WHERE ct.crate_type_id = ? ORDER BY t.sort_order, t.id", [source_id]),
        )

    effect_type = EXPLOSION_EFFECT_ENTITY_TYPES.get(table)
    if effect_type is not None:
        set_if_any(
            lists,
            "explosion_effects",
            names(
                con,
                "SELECT e.name FROM entity_explosion_effects ee JOIN explosion_types e ON e.id = ee.explosion_type_id WHERE ee.entity_type = ? AND ee.entity_id = ? ORDER BY ee.seq",
                [effect_type, source_id],
            ),
        )

    return lists


def child_links(
    con: sqlite3.Connection,
    table: str,
    source_id: int,
) -> dict[str, Any]:
    links: dict[str, Any] = {}

    resource_type = RESOURCE_LINK_ENTITY_TYPES.get(table)
    if resource_type is not None:
        resources = [
            compact_dict(
                {
                    "seq": row["seq"],
                    "target": row["target_name"],
                    "source_line": row["source_line"],
                }
            )
            for row in con.execute(
                "SELECT seq, target_name, source_line FROM entity_resource_links WHERE entity_type = ? AND entity_id = ? ORDER BY seq",
                [resource_type, source_id],
            )
        ]
        set_if_any(links, "resources", resources)

    aliases = ENTITY_ALIASES.get(table, [table])
    custom_fields = []
    for alias in aliases:
        custom_fields.extend(
            compact_dict(
                {
                    "entity_type": row["entity_type"],
                    "key": row["key"],
                    "value": row["value"],
                    "source_line": row["source_line"],
                }
            )
            for row in con.execute(
                "SELECT entity_type, key, value, source_line FROM custom_fields WHERE entity_type = ? AND entity_id = ? ORDER BY id",
                [alias, source_id],
            )
        )
    set_if_any(links, "custom_fields", custom_fields)

    return links


def convert_value(
    lookups: dict[str, dict[int, str]],
    table: str,
    column: str,
    value: Any,
) -> Any:
    if value is None:
        return None

    target_table = FK_TARGETS.get(column)
    if target_table is not None:
        resolved = lookups[target_table].get(value)
        if resolved is None:
            raise ValueError(f"Could not resolve {table}.{column}={value} via {target_table}")
        return resolved

    if column in BOOL_COLUMNS.get(table, set()):
        return bool(value)

    return value


def field_key(column: str) -> str:
    if column.endswith("_id"):
        return column[:-3]
    return column


def names(con: sqlite3.Connection, query: str, params: Iterable[Any]) -> list[str]:
    return [row["name"] for row in con.execute(query, list(params))]


def set_if_any(target: dict[str, Any], key: str, value: Any) -> None:
    if value:
        target[key] = value


def compact_dict(value: dict[str, Any]) -> dict[str, Any]:
    return {key: item for key, item in value.items() if item is not None}


def unique_filename(folder: Path, raw_name: str, used_names_by_folder: dict[str, set[str]]) -> str:
    folder_key = str(folder)
    used = used_names_by_folder.setdefault(folder_key, set())
    stem = sanitize_filename(raw_name)
    filename = f"{stem}.tres"
    if filename not in used:
        used.add(filename)
        return filename

    suffix = 2
    while True:
        filename = f"{stem}_{suffix}.tres"
        if filename not in used:
            used.add(filename)
            return filename
        suffix += 1


def sanitize_filename(value: str) -> str:
    result = re.sub(r"[^A-Za-z0-9_.-]+", "_", value.strip())
    result = result.strip("._")
    return result or "unnamed"


def write_config(path: Path, export: dict[str, str], config: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        f'[gd_resource type="Resource" script_class="{export["class_name"]}" load_steps=2 format=3]',
        "",
        f'[ext_resource type="Script" path="{export["script"]}" id="rules_script"]',
        "",
        "[resource]",
        'script = ExtResource("rules_script")',
        f'id = {string_name(config["id"])}',
        f'entity_type = {string_name(config["entity_type"])}',
        f'source_table = {string_name(config["source_table"])}',
        f'source_id = {config["source_id"]}',
        f'fields = {variant(config["fields"])}',
        f'lists = {variant(config["lists"])}',
        f'links = {variant(config["links"])}',
        "",
    ]
    path.write_text("\n".join(lines), encoding="utf-8")


def string_name(value: Any) -> str:
    return "&" + string(value)


def string(value: Any) -> str:
    return json.dumps(str(value), ensure_ascii=False)


def variant(value: Any, indent: int = 0) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return repr(value)
    if isinstance(value, str):
        return string(value)
    if isinstance(value, list):
        if not value:
            return "[]"
        child_indent = "\t" * (indent + 1)
        closing_indent = "\t" * indent
        items = [f"{child_indent}{variant(item, indent + 1)}" for item in value]
        return "[\n" + ",\n".join(items) + f"\n{closing_indent}]"
    if isinstance(value, dict):
        if not value:
            return "{}"
        child_indent = "\t" * (indent + 1)
        closing_indent = "\t" * indent
        items = [
            f"{child_indent}{string(key)}: {variant(item, indent + 1)}"
            for key, item in value.items()
        ]
        return "{\n" + ",\n".join(items) + f"\n{closing_indent}}}"

    raise TypeError(f"Unsupported Variant value: {value!r}")


if __name__ == "__main__":
    main()
