#!/usr/bin/env python3
"""Generate transitional Godot UnitDefinition resources and their path manifest.

The normalized local rules.db remains the input during migration. Generated
.tres files are deliberately ordinary Godot resources: once Rules is retired,
the generator can be removed and those resources become authored game data.
"""

from __future__ import annotations

import argparse
import re
import sqlite3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DB = ROOT / "assets/converted/rules.db"
DEFINITION_DIR = ROOT / "resources/units/definitions"
MANIFEST_PATH = ROOT / "resources/units/generated_unit_manifest.gd"
SCENE_DIR = ROOT / "scenes/units"
MODEL_DIR = ROOT / "assets/converted/models"
VETERANCY_DIR = ROOT / "resources/units/veterancy"
COMBAT_DIR = ROOT / "resources/combat"
TURRET_DIR = COMBAT_DIR / "turrets"
BULLET_DIR = COMBAT_DIR / "bullets"
WARHEAD_DIR = COMBAT_DIR / "warheads"
COMBAT_MANIFEST_PATH = COMBAT_DIR / "generated_combat_manifest.gd"
COMBAT_SETTINGS_PATH = COMBAT_DIR / "combat_settings.tres"
BUILDING_DEFINITION_DIR = ROOT / "resources/buildings/definitions"
BUILDING_MANIFEST_PATH = ROOT / "resources/buildings/generated_building_manifest.gd"
GAME_SETTINGS_PATH = ROOT / "resources/rules/game_settings.tres"
SPICE_DEFINITION_PATH = ROOT / "resources/world/spice_mound.tres"
CONFIG_RE = re.compile(r'^config_id = &"([^"]+)"$', re.MULTILINE)
MODEL_RE = re.compile(r'path="(res://assets/converted/models/[^"]+\.(?:scn|tscn))"')


def godot_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def string_name(value: str | None) -> str:
    return "&" + godot_string(value or "")


def bool_text(value: object) -> str:
    return "true" if bool(value) else "false"


def array_text(values: list[str]) -> str:
    return "[" + ", ".join(string_name(value) for value in values) + "]"


def string_array_text(values: list[str]) -> str:
    return "[" + ", ".join(godot_string(value) for value in values) + "]"


def dictionary_text(values: dict[str, object]) -> str:
    entries = []
    for key in sorted(values):
        value = values[key]
        rendered = bool_text(value) if isinstance(value, bool) else f"{float(value):.6g}"
        entries.append(f"{godot_string(key)}: {rendered}")
    return "{" + ", ".join(entries) + "}"


def resource_text(script_class: str, script_path: str, properties: list[str]) -> str:
    return "\n".join([
        f'[gd_resource type="Resource" script_class="{script_class}" load_steps=2 format=3]',
        "",
        f'[ext_resource type="Script" path="{script_path}" id="1_definition"]',
        "",
        "[resource]",
        'script = ExtResource("1_definition")',
        *properties,
        "",
    ])


def discover_scenes() -> tuple[dict[str, str], dict[str, str]]:
    scenes: dict[str, str] = {}
    models: dict[str, str] = {}
    for path in sorted(SCENE_DIR.glob("*.tscn")):
        text = path.read_text(encoding="utf-8")
        config = CONFIG_RE.search(text)
        if config is None:
            continue
        config_id = config.group(1)
        relative = path.relative_to(ROOT).as_posix()
        # unit.tscn is the prepared ATInfantry scene as well as the fallback.
        scenes[config_id] = f"res://{relative}"
        model = MODEL_RE.search(text)
        if model is not None:
            models[config_id] = model.group(1)
    return scenes, models


def model_paths_by_xaf() -> dict[str, str]:
    result: dict[str, str] = {}
    for directory in sorted(path for path in MODEL_DIR.iterdir() if path.is_dir()):
        scene = directory / f"{directory.name}.scn"
        if scene.exists():
            result[directory.name.casefold()] = "res://" + scene.relative_to(ROOT).as_posix()
    return result


def rows(connection: sqlite3.Connection) -> list[sqlite3.Row]:
    connection.row_factory = sqlite3.Row
    return connection.execute(
        """
        SELECT u.*, h.name AS house_name, ug.name AS unit_group_name,
               armour.name AS armour_name, art.xaf AS xaf, art.icon AS icon,
               art.icon_grey AS icon_grey, art.sidebar_type AS sidebar_type,
               chaos.name AS chaos_effect_name, hawk.name AS hawk_effect_name,
               damage_fx.name AS damage_effect_name, explosion.name AS explosion_type_name
          FROM units AS u
          LEFT JOIN houses AS h ON h.id = u.house_id
          LEFT JOIN unit_groups AS ug ON ug.id = u.unit_group_id
          LEFT JOIN armour_types AS armour ON armour.id = u.armour_type_id
          LEFT JOIN art_configs AS art
            ON art.entity_type = 'unit' AND art.entity_id = u.id
          LEFT JOIN explosion_types AS chaos ON chaos.id = u.chaos_effect_id
          LEFT JOIN explosion_types AS hawk ON hawk.id = u.hawk_effect_id
          LEFT JOIN explosion_types AS damage_fx ON damage_fx.id = u.damage_effect_id
          LEFT JOIN explosion_types AS explosion ON explosion.id = u.explosion_type_id
         ORDER BY u.id
        """
    ).fetchall()


def linked_names(connection: sqlite3.Connection, table: str, unit_id: int) -> list[str]:
    return [
        row[0]
        for row in connection.execute(
            f"SELECT b.name FROM {table} AS link JOIN buildings AS b ON b.id = link.building_id WHERE link.unit_id = ? ORDER BY link.rowid",
            (unit_id,),
        )
    ]


def turret_names(connection: sqlite3.Connection, unit_id: int) -> list[str]:
    return [
        row[0]
        for row in connection.execute(
            "SELECT t.name FROM unit_turrets AS link JOIN turrets AS t ON t.id = link.turret_id WHERE link.unit_id = ? ORDER BY link.seq",
            (unit_id,),
        )
    ]


def unit_list(connection: sqlite3.Connection, query: str, unit_id: int) -> list[str]:
    return [row[0] for row in connection.execute(query, (unit_id,))]


def visual_path(xaf: str | None, output_root: str) -> str:
    if not xaf:
        return ""
    name = Path(str(xaf).replace("\\", "/")).stem.lower()
    relative = ROOT / output_root / name / f"{name}.scn"
    return "res://" + relative.relative_to(ROOT).as_posix() if relative.exists() else ""


def definition_text(row: sqlite3.Row, scene_path: str, model_path: str,
                    primary: list[str], secondary: list[str], turrets: list[str],
                    terrain: list[str], resources: list[str], effects: list[str],
                    veterancy_paths: list[str]) -> str:
    properties = [
        f"config_id = {string_name(row['name'])}",
        f"legacy_name = {string_name(row['legacy_name'])}",
        f"house_id = {string_name(row['house_name'])}",
        f"unit_group_id = {string_name(row['unit_group_name'])}",
        f"scene_path = {godot_string(scene_path)}",
        f"model_scene_path = {godot_string(model_path)}",
        f"icon_path = {godot_string(str(row['icon'] or ''))}",
        f"icon_grey_path = {godot_string(str(row['icon_grey'] or ''))}",
        f"sidebar_type = {string_name(row['sidebar_type'])}",
        f"cost = {int(row['cost'] or 0)}",
        f"build_time_ticks = {int(row['build_time'] or 0)}",
        f"tech_level = {int(row['tech_level'] or 0)}",
        f"upgraded_primary_required = {bool_text(row['upgraded_primary_required'])}",
        f"primary_building_ids = {array_text(primary)}",
        f"secondary_building_ids = {array_text(secondary)}",
        f"size = {int(row['size'] or 0)}",
        f"health = {int(row['health'] or 0)}",
        f"shield_health = {float(row['shield_health'] or 0.0):.6g}",
        f"armour_type = {string_name(row['armour_name'])}",
        f"speed = {float(row['speed'] or 0.0):.6g}",
        f"mech_speed = {float(row['mech_speed'] or 0.0):.6g}",
        f"mech = {bool_text(row['mech'])}",
        f"turn_rate = {float(row['turn_rate'] or 0.0):.6g}",
        f"infantry = {bool_text(row['infantry'])}",
        f"can_fly = {bool_text(row['can_fly'])}",
        f"can_move_any_direction = {bool_text(row['can_move_any_direction'])}",
        f"terrain_ids = {array_text(terrain)}",
        f"can_be_deviated = {bool_text(row['can_be_deviated'])}",
        f"can_self_repair = {bool_text(row['can_self_repair'])}",
        f"can_be_repaired = {bool_text(row['can_be_repaired'])}",
        f"crushable = {bool_text(row['crushable'])}",
        f"crushes = {bool_text(row['crushes'])}",
        f"starportable = {bool_text(row['starportable'])}",
        f"tasty_to_worms = {bool_text(row['tasty_to_worms'])}",
        f"worm_attraction = {int(row['worm_attraction'] or 0)}",
        f"can_be_suppressed = {bool_text(row['can_be_suppressed'])}",
        f"can_die = {bool_text(row['can_die'])}",
        f"cant_be_leeched = {bool_text(row['cant_be_leeched'])}",
        f"selectable = {bool_text(row['selectable'])}",
        f"stealthed_when_still = {bool_text(row['stealthed_when_still'])}",
        f"height_offset = {float(row['height_offset'] or 0.0):.6g}",
        f"roof_height = {int(row['roof_height'] or 0)}",
        # These two Harvester fields are present in the local Rules.txt but the
        # normalized schema currently has no unit columns for them. Keep the
        # explicit, source-checked compatibility values until schema migration.
        f"spice_capacity = {700 if row['name'] == 'Harvester' else 0}",
        f"unload_rate = {2 if row['name'] == 'Harvester' else 0}",
        f"resource_ids = {array_text(resources)}",
        f"explosion_effect_ids = {array_text(effects)}",
        f"chaos_effect_id = {string_name(row['chaos_effect_name'])}",
        f"hawk_effect_id = {string_name(row['hawk_effect_name'])}",
        f"damage_effect_id = {string_name(row['damage_effect_name'])}",
        f"explosion_type_id = {string_name(row['explosion_type_name'])}",
        f"veterancy_level_paths = {string_array_text(veterancy_paths)}",
        f"turret_ids = {array_text(turrets)}",
    ]
    return resource_text("UnitDefinition", "res://scripts/units/unit_definition.gd", properties)


def veterancy_text(row: sqlite3.Row) -> str:
    properties = [
        f"level = {int(row['level_order'])}",
        f"score = {int(row['veterancy_score'])}",
        f"extra_damage_percent = {float(row['extra_damage_percent'] or 0.0):.6g}",
        f"extra_armour_percent = {float(row['extra_armour_percent'] or 0.0):.6g}",
        f"extra_range_percent = {float(row['extra_range_percent'] or 0.0):.6g}",
        f"can_self_repair = {bool_text(row['can_self_repair'])}",
        f"elite = {bool_text(row['elite'])}",
        f"stealthed_when_still = {bool_text(row['stealthed_when_still'])}",
    ]
    if row["speed_override"] is not None:
        properties.append(f"speed_override = {float(row['speed_override']):.6g}")
    if row["health_override"] is not None:
        properties.append(f"health_override = {int(row['health_override'])}")
    return resource_text(
        "UnitVeterancyDefinition",
        "res://scripts/units/unit_veterancy_definition.gd",
        properties,
    )


def art_xaf(connection: sqlite3.Connection, art_name: str | None) -> str:
    if not art_name:
        return ""
    row = connection.execute(
        "SELECT xaf FROM art_configs WHERE lower(art_name)=lower(?) ORDER BY id LIMIT 1",
        (art_name,),
    ).fetchone()
    return str(row[0] or "") if row else ""


def turret_text(row: sqlite3.Row, muzzle_scene_path: str) -> str:
    properties = [
        f"config_id = {string_name(row['name'])}",
        f"bullet_id = {string_name(row['bullet_name'])}",
        f"next_joint_id = {string_name(row['next_joint_name'])}",
        f"reload_count = {float(row['reload_count'] or 0.0):.6g}",
        f"muzzle_flash_id = {string_name(row['turret_muzzle_flash'])}",
        f"muzzle_flash_scene_path = {godot_string(muzzle_scene_path)}",
        f"yaw_speed = {float(row['turret_y_rotation_angle'] or 0.0):.6g}",
        f"pitch_speed = {float(row['turret_x_rotation_angle'] or 0.0):.6g}",
        f"acceptable_yaw = {float(row['turret_y_acceptable_aim'] or 1.0):.6g}",
        f"acceptable_pitch = {float(row['turret_x_acceptable_aim'] or 1.0):.6g}",
        f"bullet_count = {int(row['turret_bullet_count'] or 1)}",
        f"disabled_when_deployed = {bool_text(row['turret_disable_if_unit_deployed'])}",
        f"disabled_when_undeployed = {bool_text(row['turret_disable_if_unit_undeployed'])}",
    ]
    for prop, column in [
        ("minimum_yaw", "turret_min_y_rotation"),
        ("maximum_yaw", "turret_max_y_rotation"),
        ("minimum_pitch", "turret_min_x_rotation"),
        ("maximum_pitch", "turret_max_x_rotation"),
    ]:
        if row[column] is not None:
            properties.append(f"{prop} = {float(row[column]):.6g}")
    return resource_text("TurretDefinition", "res://scripts/combat/turret_definition.gd", properties)


def bullet_text(row: sqlite3.Row, effects: list[str], projectile_path: str,
                impact_paths: dict[str, str]) -> str:
    properties = [
        f"config_id = {string_name(row['name'])}",
        f"warhead_id = {string_name(row['warhead_name'])}",
        f"damage = {float(row['damage'] or 0.0):.6g}",
        f"maximum_range = {float(row['max_range'] or 0.0):.6g}",
        f"minimum_range = {float(row['min_range'] or 0.0):.6g}",
        f"speed = {float(row['speed'] or 0.0):.6g}",
        f"blast_radius = {float(row['blast_radius'] or 0.0):.6g}",
        f"friendly_damage_amount = {float(row['friendly_damage_amount'] or 0.0):.6g}",
        f"reduce_damage_with_distance = {bool_text(row['reduce_damage_with_distance'] != 0)}",
        f"anti_aircraft = {bool_text(row['anti_aircraft'])}",
        f"anti_ground = {bool_text(row['anti_ground'] != 0)}",
        f"homing = {bool_text(row['homing'])}",
        f"homing_delay = {float(row['homing_delay'] or 0.0):.6g}",
        f"turn_rate = {float(row['turn_rate'] or 0.0):.6g}",
        f"continuous = {bool_text(row['continuous'])}",
        f"trajectory = {bool_text(row['trajectory'])}",
        f"is_laser = {bool_text(row['is_laser'])}",
        f"missile_trail_present = {bool_text(row['missile_trail'] is not None)}",
        f"missile_trail = {int(row['missile_trail'] or 0)}",
        f"missile_trail_size = {float(row['missile_trail_size'] or 0.0):.6g}",
        f"missile_trail_wiggle_frequency = {float(row['missile_trail_wiggle_freq'] or 0.0):.6g}",
        f"missile_trail_wiggle_scale = {float(row['missile_trail_wiggle_scale'] or 0.0):.6g}",
        f"missile_trail_length = {int(row['missile_trail_length'] or 0)}",
        f"missile_trail_delta = {float(row['missile_trail_delta'] or 0.0):.6g}",
        *[f"{field} = {bool_text(row[field])}" for field in [
            "burnt", "ignites", "gassed", "leech", "infantry", "damage_column",
            "deviate", "beserk", "retreat",
        ]],
        f"effect_health = {float(row['health'] or 0.0):.6g}",
        f"effect_damage_per_tick = {float(row['shield_health'] or 0.0):.6g}",
        f"linger_duration = {float(row['linger_duration'] or 0.0):.6g}",
        f"linger_damage = {float(row['linger_damage'] or 0.0):.6g}",
        f"explosion_type_id = {string_name(row['explosion_name'])}",
        f"explosion_effect_ids = {array_text(effects)}",
        f"projectile_scene_path = {godot_string(projectile_path)}",
        "impact_scene_paths = " + "{" + ", ".join(
            f"{string_name(key)}: {godot_string(impact_paths[key])}" for key in sorted(impact_paths)
        ) + "}",
    ]
    return resource_text("BulletDefinition", "res://scripts/combat/bullet_definition.gd", properties)


def warhead_text(config_id: str, matrix: dict[str, float]) -> str:
    return resource_text("WarheadDefinition", "res://scripts/combat/warhead_definition.gd", [
        f"config_id = {string_name(config_id)}",
        f"armour_damage = {dictionary_text(matrix)}",
    ])


def combat_manifest_text(turrets: dict[str, str], bullets: dict[str, str],
                         warheads: dict[str, str]) -> str:
    def dictionary(name: str, entries: dict[str, str]) -> list[str]:
        return [f"const {name}: Dictionary = {{"] + [
            f"\t{string_name(key)}: {godot_string(entries[key])}," for key in sorted(entries)
        ] + ["}"]
    return "\n".join([
        "# Generated by tools/generate_unit_definitions.py; do not hand-edit during migration.",
        "extends RefCounted", "",
        *dictionary("TURRET_PATHS", turrets), "",
        *dictionary("BULLET_PATHS", bullets), "",
        *dictionary("WARHEAD_PATHS", warheads), "",
        f"const SETTINGS_PATH := {godot_string('res://' + COMBAT_SETTINGS_PATH.relative_to(ROOT).as_posix())}", "",
    ])


def deploy_points_text(points: list[sqlite3.Row]) -> str:
    return "[" + ", ".join(
        "{" + f'"tile_x": {int(point["tile_x"])}, "tile_y": {int(point["tile_y"])}, '
        + f'"angle": {float(point["angle"] or 0.0):.6g}' + "}"
        for point in points
    ) + "]"


def building_definition_text(row: sqlite3.Row, occupy_rows: list[str], links: list[str],
                             primary: list[str], secondary: list[str], roles: list[str],
                             deploy_points: list[sqlite3.Row]) -> str:
    return resource_text(
        "BuildingDefinition",
        "res://scripts/buildings/building_definition.gd",
        [
            f"config_id = {string_name(row['name'])}",
            f"legacy_name = {string_name(row['legacy_name'])}",
            f"house_id = {string_name(row['house_name'])}",
            f"building_group_id = {string_name(row['building_group_name'])}",
            f"cost = {int(row['cost'] or 0)}",
            f"build_time_ticks = {float(row['build_time'] or 0.0):.6g}",
            f"health = {float(row['health'] or 0.0):.6g}",
            "shield_health = 0",
            f"armour_type = {string_name(row['armour_name'])}",
            f"tech_level = {int(row['tech_level'] or 0)}",
            f"power_used = {int(row['power_used'] or 0)}",
            f"power_generated = {int(row['power_generated'] or 0)}",
            f"can_be_primary = {bool_text(row['can_be_primary'])}",
            f"is_construction_yard = {bool_text(row['is_con_yard'])}",
            f"upgraded_primary_required = {bool_text(row['upgraded_primary_required'])}",
            f"primary_building_ids = {array_text(primary)}",
            f"secondary_building_ids = {array_text(secondary)}",
            f"roles = {array_text(roles)}",
            f"occupy_rows = {string_array_text(occupy_rows)}",
            f"deploy_points = {deploy_points_text(deploy_points)}",
            f"linked_unit_ids = {array_text(links)}",
            f"survivor_count = {int(row['num_infantry_when_gone'] or 0)}",
            f"turret_id = {string_name(row['turret_name'])}",
            f"upgrade_tech_level = {int(row['upgrade_tech_level'] or 0)}",
            f"upgrade_cost = {int(row['upgrade_cost'] or 0)}",
            f"upgrade_build_time_ticks = {720 if row['building_group_name'] == 'RefineryDock' else 0}",
            f"model_name = {godot_string(str(row['xaf'] or ''))}",
            f"icon_path = {godot_string(str(row['icon'] or ''))}",
            f"icon_grey_path = {godot_string(str(row['icon_grey'] or ''))}",
            f"sidebar_type = {string_name(row['sidebar_type'])}",
        ],
    )


def spice_definition_text(row: sqlite3.Row) -> str:
    return resource_text("SpiceMoundDefinition", "res://scripts/world/map/spice_mound_definition.gd", [
        f"config_id = {string_name(row['name'])}",
        f"health = {int(row['health'] or 0)}",
        f"maturity_minimum_ticks = {float(row['size'] or 0.0):.6g}",
        f"maturity_random_ticks = {float(row['cost'] or 0.0):.6g}",
        f"blast_radius = {float(row['blast_radius'] or 0.0):.6g}",
        f"spice_capacity = {int(row['spice_capacity'] or 0)}",
        f"build_time_ticks = {float(row['build_time'] or 0.0):.6g}",
        f"explosion_type_id = {string_name(row['explosion_name'])}",
        f"resource_id = {string_name(row['resource'])}",
    ])


def manifest_text(definition_paths: dict[str, str], scene_paths: dict[str, str]) -> str:
    def dictionary(name: str, entries: dict[str, str]) -> list[str]:
        lines = [f"const {name}: Dictionary = {{"]
        for key in sorted(entries):
            lines.append(f"\t{string_name(key)}: {godot_string(entries[key])},")
        lines.append("}")
        return lines

    return "\n".join([
        "# Generated by tools/generate_unit_definitions.py; do not hand-edit during migration.",
        "extends RefCounted",
        "",
        *dictionary("DEFINITION_PATHS", definition_paths),
        "",
        *dictionary("SCENE_PATHS", scene_paths),
        "",
    ])


def write_or_check(path: Path, content: str, check: bool) -> bool:
    current = path.read_text(encoding="utf-8") if path.exists() else None
    if current == content:
        return True
    if check:
        print(f"out of date: {path.relative_to(ROOT)}")
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    scene_paths, scene_models = discover_scenes()
    xaf_models = model_paths_by_xaf()
    definition_paths: dict[str, str] = {}
    expected_files: set[Path] = set()
    expected_veterancy: set[Path] = set()
    ok = True
    with sqlite3.connect(args.db) as connection:
        for row in rows(connection):
            config_id = str(row["name"])
            output = DEFINITION_DIR / f"{config_id}.tres"
            expected_files.add(output)
            definition_paths[config_id] = "res://" + output.relative_to(ROOT).as_posix()
            xaf = str(row["xaf"] or "")
            model_path = scene_models.get(config_id, xaf_models.get(f"{xaf}_h0".casefold(), ""))
            veterancy_paths: list[str] = []
            for level in connection.execute(
                "SELECT * FROM unit_veterancy_levels WHERE unit_id=? ORDER BY level_order",
                (int(row["id"]),),
            ):
                level_path = VETERANCY_DIR / f"{config_id}_{int(level['level_order'])}.tres"
                expected_veterancy.add(level_path)
                veterancy_paths.append("res://" + level_path.relative_to(ROOT).as_posix())
                ok = write_or_check(level_path, veterancy_text(level), args.check) and ok
            content = definition_text(
                row,
                scene_paths.get(config_id, ""),
                model_path,
                linked_names(connection, "unit_primary_buildings", int(row["id"])),
                linked_names(connection, "unit_secondary_buildings", int(row["id"])),
                turret_names(connection, int(row["id"])),
                unit_list(connection, "SELECT t.name FROM unit_terrain link JOIN terrain_types t ON t.id=link.terrain_type_id WHERE link.unit_id=? ORDER BY t.sort_order", int(row["id"])),
                unit_list(connection, "SELECT target_name FROM entity_resource_links WHERE entity_type='unit' AND entity_id=? ORDER BY seq", int(row["id"])),
                unit_list(connection, "SELECT e.name FROM entity_explosion_effects link JOIN explosion_types e ON e.id=link.explosion_type_id WHERE link.entity_type='unit' AND link.entity_id=? ORDER BY link.seq", int(row["id"])),
                veterancy_paths,
            )
            ok = write_or_check(output, content, args.check) and ok

        turret_paths: dict[str, str] = {}
        for row in connection.execute("""
            SELECT t.*, b.name AS bullet_name, next.name AS next_joint_name
              FROM turrets t LEFT JOIN bullets b ON b.id=t.bullet_id
              LEFT JOIN turrets next ON next.id=t.turret_next_joint_id ORDER BY t.id
        """):
            output = TURRET_DIR / f"{row['name']}.tres"
            turret_paths[str(row["name"])] = "res://" + output.relative_to(ROOT).as_posix()
            muzzle = visual_path(art_xaf(connection, row["turret_muzzle_flash"]), "assets/converted/muzzle_flashes")
            ok = write_or_check(output, turret_text(row, muzzle), args.check) and ok

        bullet_paths: dict[str, str] = {}
        for row in connection.execute("""
            SELECT b.*, w.name AS warhead_name, e.name AS explosion_name, art.xaf AS xaf
              FROM bullets b LEFT JOIN warheads w ON w.id=b.warhead_id
              LEFT JOIN explosion_types e ON e.id=b.explosion_type_id
              LEFT JOIN art_configs art ON art.entity_type='bullet' AND art.entity_id=b.id
             ORDER BY b.id
        """):
            output = BULLET_DIR / f"{row['name']}.tres"
            bullet_paths[str(row["name"])] = "res://" + output.relative_to(ROOT).as_posix()
            effects = unit_list(connection, "SELECT e.name FROM entity_explosion_effects link JOIN explosion_types e ON e.id=link.explosion_type_id WHERE link.entity_type='bullet' AND link.entity_id=? ORDER BY link.seq", int(row["id"]))
            if not effects and row["explosion_name"]:
                effects = [str(row["explosion_name"])]
            impacts = {
                effect: path for effect in effects
                if (path := visual_path(art_xaf(connection, effect), "assets/converted/impact_effects"))
            }
            ok = write_or_check(output, bullet_text(
                row, effects,
                visual_path(str(row["xaf"] or ""), "assets/converted/projectiles"),
                impacts,
            ), args.check) and ok

        warhead_paths: dict[str, str] = {}
        for warhead in connection.execute("SELECT id,name FROM warheads ORDER BY id"):
            output = WARHEAD_DIR / f"{warhead['name']}.tres"
            warhead_paths[str(warhead["name"])] = "res://" + output.relative_to(ROOT).as_posix()
            matrix = {str(item[0]): float(item[1]) for item in connection.execute(
                "SELECT a.name, d.damage_percent FROM warhead_armour_damage d JOIN armour_types a ON a.id=d.armour_type_id WHERE d.warhead_id=? ORDER BY a.sort_order",
                (int(warhead["id"]),),
            )}
            ok = write_or_check(output, warhead_text(str(warhead["name"]), matrix), args.check) and ok

        gravity = connection.execute("SELECT bullet_gravity FROM general_settings WHERE id=1").fetchone()[0]
        ok = write_or_check(COMBAT_SETTINGS_PATH, resource_text(
            "CombatSettings", "res://scripts/combat/combat_settings.gd",
            [f"bullet_gravity = {float(gravity or 1.0):.6g}"],
        ), args.check) and ok
        ok = write_or_check(
            COMBAT_MANIFEST_PATH,
            combat_manifest_text(turret_paths, bullet_paths, warhead_paths),
            args.check,
        ) and ok

        building_paths: dict[str, str] = {}
        for building in connection.execute("""
            SELECT b.*, t.name AS turret_name, h.name AS house_name,
                   bg.name AS building_group_name, armour.name AS armour_name,
                   art.xaf AS xaf, art.icon AS icon, art.icon_grey AS icon_grey,
                   art.sidebar_type AS sidebar_type
              FROM buildings b
              LEFT JOIN turrets t ON t.id=b.turret_attach_id
              LEFT JOIN houses h ON h.id=b.house_id
              LEFT JOIN building_groups bg ON bg.id=b.building_group_id
              LEFT JOIN armour_types armour ON armour.id=b.armour_type_id
              LEFT JOIN art_configs art ON art.entity_type='building' AND art.entity_id=b.id
             ORDER BY b.id
        """):
            output = BUILDING_DEFINITION_DIR / f"{building['name']}.tres"
            building_paths[str(building["name"])] = "res://" + output.relative_to(ROOT).as_posix()
            occupy = unit_list(connection, "SELECT pattern FROM building_occupy_rows WHERE building_id=? ORDER BY row_index", int(building["id"]))
            links = unit_list(connection, "SELECT target_name FROM entity_resource_links WHERE entity_type='building' AND entity_id=? ORDER BY seq", int(building["id"]))
            primary = unit_list(connection, "SELECT b.name FROM building_requires_primary link JOIN buildings b ON b.id=link.required_building_id WHERE link.building_id=? ORDER BY link.rowid", int(building["id"]))
            secondary = unit_list(connection, "SELECT b.name FROM building_requires_secondary link JOIN buildings b ON b.id=link.required_building_id WHERE link.building_id=? ORDER BY link.rowid", int(building["id"]))
            roles = unit_list(connection, "SELECT r.name FROM building_role_tags link JOIN building_roles r ON r.id=link.role_id WHERE link.building_id=? ORDER BY r.id", int(building["id"]))
            deploy_points = list(connection.execute("SELECT tile_x,tile_y,angle FROM building_deploy_points WHERE building_id=? ORDER BY seq", (int(building["id"]),)))
            ok = write_or_check(output, building_definition_text(building, occupy, links, primary, secondary, roles, deploy_points), args.check) and ok
        ok = write_or_check(
            BUILDING_MANIFEST_PATH,
            manifest_text(building_paths, {}),
            args.check,
        ) and ok

        placement_distance = connection.execute("SELECT max_building_placement_tile_dist FROM general_settings WHERE id=1").fetchone()[0]
        ok = write_or_check(GAME_SETTINGS_PATH, resource_text(
            "GameSettings", "res://scripts/rules/game_settings.gd",
            [f"max_building_placement_tile_dist = {int(placement_distance or 6)}"],
        ), args.check) and ok
        spice = connection.execute("""
            SELECT s.*, e.name AS explosion_name FROM spice_mound_types s
              LEFT JOIN explosion_types e ON e.id=s.explosion_type_id
             WHERE s.name='SpiceMound' LIMIT 1
        """).fetchone()
        if spice is not None:
            ok = write_or_check(SPICE_DEFINITION_PATH, spice_definition_text(spice), args.check) and ok

    if not args.check and DEFINITION_DIR.exists():
        for stale in DEFINITION_DIR.glob("*.tres"):
            if stale not in expected_files:
                stale.unlink()
    if not args.check and VETERANCY_DIR.exists():
        for stale in VETERANCY_DIR.glob("*.tres"):
            if stale not in expected_veterancy:
                stale.unlink()
    ok = write_or_check(MANIFEST_PATH, manifest_text(definition_paths, scene_paths), args.check) and ok
    if not args.check:
        print(
            f"generated {len(definition_paths)} units, {len(turret_paths)} turrets, "
            f"{len(bullet_paths)} bullets, {len(warhead_paths)} warheads and "
            f"{len(scene_paths)} scene mappings"
        )
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
