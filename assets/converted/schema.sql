-- =============================================================================
-- Emperor: Battle for Dune — Rules.txt → SQLite
-- Normalized schema with strict per-entity typing (units/buildings/
-- turrets/bullets/warheads/debris/crates/splats/spice mounds).
--
-- This database is the source of truth. Export to the engine (Godot) is a
-- separate SQLite -> JSON/Resource step and is not coupled to this schema.
--
-- Design principles:
--   1. Frequent fields (>=~20 occurrences in a category) get dedicated
--      typed columns.
--   2. Composite/list fields (Terrain=, PrimaryBuilding=, Occupy=,
--      VeterancyLevel=, Armour=..,N,Terrain) use child/junction tables.
--   3. Rare one-off fields (1-3 occurrences in the entire file) do not get
--      dedicated columns. They go into the `custom_fields` overflow table
--      (entity_type, entity_id, key, value), avoiding hundreds of mostly-NULL
--      columns. This does not weaken per-entity typing; it is a collector for
--      the long tail of rare flags, not the schema itself.
--   4. Named references to other entities (TurretAttach, Bullet, Warhead,
--      ExplosionType, ChaosEffect...) are resolved to FKs during import
--      instead of being stored as TEXT.
-- =============================================================================

PRAGMA foreign_keys = ON;

-- =============================================================================
-- 1. LOOKUP / ENUM TABLES
-- =============================================================================

-- [TerrainTypes] is a fixed list whose order is the numeric engine ID
-- (matching TYPE in tiledef.dat as documented by terrain-contour-system.md).
CREATE TABLE terrain_types (
    id          INTEGER PRIMARY KEY,   -- matches the original TYPE index (0..7)
    name        TEXT NOT NULL UNIQUE,  -- Sand, Rock, Cliff, NBRock, InfRock, DustBowl, MapEdge, Ramp
    sort_order  INTEGER NOT NULL
);

-- [ArmourTypes] is another fixed enum, used as an FK nearly everywhere
-- (unit/building Armour and the warhead_armour_damage columns).
CREATE TABLE armour_types (
    id          INTEGER PRIMARY KEY,
    name        TEXT NOT NULL UNIQUE,  -- None, BPV, Light, Medium, Heavy, Concrete, Walls, Building, CY, Harvester, Invulnerable, Aircraft
    sort_order  INTEGER NOT NULL
);

-- Complete name registry from every [ExplosionTypes] declaration in the file.
-- Some entries are parameterless FX hook names (Muzzle1, LargeChaosFX...);
-- others are full entities with DamageToTile/FaceCamera properties and are
-- extended by explosion_configs. A shared registry is required because
-- ChaosEffect/HawkEffect/DamageEffect/ExplosionType on units, buildings, and
-- bullets all reference the same namespace.
CREATE TABLE explosion_types (
    id          INTEGER PRIMARY KEY,
    name        TEXT NOT NULL UNIQUE,
    source_line INTEGER                -- line of first occurrence in Rules.txt (diagnostics)
);

-- [BuildingGroupTypes] is used to collapse duplicate icons
-- (SmWindtrap, Outpost, Refinery...).
CREATE TABLE building_groups (
    id   INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE
);

-- [UnitGroupTypes] categorizes units for production grouping.
CREATE TABLE unit_groups (
    id   INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE
);

-- [HouseTypes] plus data from [Atreides]/[Ordos]/... sections (SubHouse,
-- SoundFile). This is a full table rather than a plain enum because houses
-- have their own data. Data validation shows that SubHouse/Subhouse is a
-- boolean flag (always "TRUE"), not the name of a parent faction. The earlier
-- self-reference assumption ("Imperial = Sardaukar") was unsupported; the
-- source contains no House->House hierarchy data.
CREATE TABLE houses (
    id           INTEGER PRIMARY KEY,
    name         TEXT NOT NULL UNIQUE,   -- Atreides, Ordos, Harkonnen, Ix, Tleilaxu, Fremen, Imperial, Guild, Incidental
    is_sub_house INTEGER,                -- bool
    sound_file   TEXT,
    sort_order   INTEGER NOT NULL
);

-- =============================================================================
-- 2. WARHEADS
-- =============================================================================

-- A [WarheadTypes] section has no conventional fields. Its body consists of
-- "ArmourTypeName = damage percentage" lines (None/BPV/Light/Medium/...).
--
-- Data validation shows that [WarheadTypes] contains both real bomb/bullet
-- warheads (an armour damage table referenced by Warhead=) and two entries
-- without a clear role: AntiPersonnel (no body and no Warhead= references)
-- and AntiTank (a normal-looking body but no Warhead= references). The data
-- has no structural "category vs real warhead" distinction, so no dedicated
-- flag is stored. Whether a warhead is used is a query (JOIN against
-- bullets.warhead_id), not persisted state.
CREATE TABLE warheads (
    id         INTEGER PRIMARY KEY,
    name       TEXT NOT NULL UNIQUE     -- AntiPersonnel, AntiTank, Pistol_W, ...
);

CREATE TABLE warhead_armour_damage (
    id             INTEGER PRIMARY KEY,
    warhead_id     INTEGER NOT NULL REFERENCES warheads(id) ON DELETE CASCADE,
    armour_type_id INTEGER NOT NULL REFERENCES armour_types(id),
    damage_percent REAL NOT NULL,
    UNIQUE (warhead_id, armour_type_id)
);

-- =============================================================================
-- 3. DEBRIS
-- =============================================================================

-- [DebrisTypes]: DebrisLarge/Medium/Small share the same six visual debris
-- trajectory fields.
CREATE TABLE debris_types (
    id                          INTEGER PRIMARY KEY,
    name                        TEXT NOT NULL UNIQUE,
    missile_trail                INTEGER,
    missile_trail_size           INTEGER,
    missile_trail_wiggle_freq    INTEGER,
    missile_trail_wiggle_scale   INTEGER,
    missile_trail_length         INTEGER,
    missile_trail_delta          REAL
);

-- =============================================================================
-- 4. BULLETS
-- =============================================================================

-- [BulletTypes]
CREATE TABLE bullets (
    id                          INTEGER PRIMARY KEY,
    name                        TEXT NOT NULL UNIQUE,
    damage                      REAL,
    max_range                   REAL,
    min_range                   REAL,
    warhead_id                  INTEGER REFERENCES warheads(id),
    debris_id                   INTEGER REFERENCES debris_types(id),
    speed                       REAL,
    explosion_type_id           INTEGER REFERENCES explosion_types(id),
    blow_up                     INTEGER,  -- bool (only TRUE occurs in source data)
    blast_radius                REAL,
    shot                        INTEGER,
    reduce_damage_with_distance INTEGER,  -- bool
    missile_trail                INTEGER,
    missile_trail_size           INTEGER,
    missile_trail_wiggle_freq    INTEGER,
    missile_trail_wiggle_scale   INTEGER,
    missile_trail_length         INTEGER,
    missile_trail_delta          REAL,
    -- DamageFriendly (bool) and FriendlyDamageAmount (numeric) never occur
    -- together in one source section (verified across all 19 occurrences).
    -- They are two historical representations of the same setting. Import:
    -- DamageFriendly=TRUE -> 100, DamageFriendly=FALSE -> 0, and
    -- FriendlyDamageAmount=N -> N unchanged.
    friendly_damage_amount      REAL,
    anti_aircraft                INTEGER,  -- bool
    anti_ground                  INTEGER,  -- bool
    homing                       INTEGER,  -- bool
    homing_delay                 REAL,
    turn_rate                    REAL,
    continuous                   INTEGER,  -- bool
    trajectory                   INTEGER,  -- bool (only true occurs in source data)
    burnt                         INTEGER,  -- bool
    ignites                       INTEGER,  -- bool
    gassed                        INTEGER,  -- bool
    is_laser                      INTEGER,  -- bool
    leech                         INTEGER,  -- bool
    infantry                      INTEGER,  -- bool ("affects infantry"; confirm context during import)
    health                        REAL,
    shield_health                 REAL,
    damage_column                 INTEGER,  -- bool (only TRUE occurs in source data)
    linger_duration                REAL,
    linger_damage                  REAL,
    deviate                        INTEGER,  -- bool
    beserk                         INTEGER,  -- bool
    retreat                        INTEGER   -- bool
);

-- =============================================================================
-- 5. TURRETS
-- =============================================================================

-- [TurretTypes]
CREATE TABLE turrets (
    id                               INTEGER PRIMARY KEY,
    name                             TEXT NOT NULL UNIQUE,
    bullet_id                        INTEGER REFERENCES bullets(id),
    reload_count                     INTEGER,
    turret_muzzle_flash              TEXT,
    turret_y_rotation_angle          REAL,
    turret_min_y_rotation            REAL,
    turret_max_y_rotation            REAL,
    turret_min_x_rotation            REAL,
    turret_max_x_rotation            REAL,
    turret_x_rotation_angle          REAL,
    turret_next_joint_id             INTEGER REFERENCES turrets(id),  -- compound base+barrel turrets (e.g. ORGasTurretBase -> ORGasTurretGun)
    turret_disable_if_unit_deployed  INTEGER,  -- bool
    turret_disable_if_unit_undeployed INTEGER, -- bool
    turret_y_acceptable_aim          REAL,
    turret_x_acceptable_aim          REAL,
    turret_bullet_count              INTEGER
);

-- =============================================================================
-- 6. EXPLOSIONS (extends parameterized explosion_types entries)
-- =============================================================================

CREATE TABLE explosion_configs (
    explosion_type_id        INTEGER PRIMARY KEY REFERENCES explosion_types(id) ON DELETE CASCADE,
    damage_to_tile           REAL,
    face_camera               INTEGER,  -- bool
    chained_explosion_type_id INTEGER REFERENCES explosion_types(id)
);

-- ExplosionType= can occur several times in one source section with different
-- values. DevPlasma_B, for example, uses ShellHit and DevImpact for different
-- bullet events; this is not an accidental duplicate. Primary tables
-- (units/buildings/bullets/splat_types/spice_mound_types) keep the first/main
-- effect in explosion_type_id for convenient queries, while this registry
-- preserves the complete ordered list when multiple values exist.
CREATE TABLE entity_explosion_effects (
    id                 INTEGER PRIMARY KEY,
    entity_type        TEXT NOT NULL,   -- 'unit' | 'building' | 'bullet' | 'splat_type' | 'spice_mound_type'
    entity_id          INTEGER NOT NULL,
    seq                INTEGER NOT NULL,  -- zero-based source occurrence order
    explosion_type_id  INTEGER NOT NULL REFERENCES explosion_types(id),
    UNIQUE (entity_type, entity_id, seq)
);

CREATE INDEX idx_entity_explosion_effects ON entity_explosion_effects (entity_type, entity_id);

-- =============================================================================
-- 7. BUILDINGS
-- =============================================================================

-- [BuildingTypes]
CREATE TABLE buildings (
    id                          INTEGER PRIMARY KEY,
    name                        TEXT NOT NULL UNIQUE,
    legacy_name                 TEXT NOT NULL UNIQUE,
    house_id                    INTEGER REFERENCES houses(id),
    building_group_id           INTEGER REFERENCES building_groups(id),
    cost                        INTEGER,
    build_time                  INTEGER,
    health                      INTEGER,
    armour_type_id              INTEGER REFERENCES armour_types(id),
    tech_level                  INTEGER,
    power_used                  INTEGER,
    -- PowerGenerated is distinct from power_used: windtraps generate power,
    -- while other buildings consume it. The field was found during parser
    -- validation after being missed by the initial frequency pass.
    power_generated             INTEGER,
    storm_damage                INTEGER,
    roof_height                 INTEGER,
    score                       INTEGER,
    num_infantry_when_gone      INTEGER,
    can_be_engineered           INTEGER,  -- bool
    can_be_primary              INTEGER,  -- bool
    is_con_yard                 INTEGER NOT NULL DEFAULT 0, -- ConYard = true
    ai_exit                     INTEGER,  -- bool (only true/false occur in source data)
    upgrade_tech_level          INTEGER,
    upgrade_cost                INTEGER,
    ai_manufacturing            INTEGER,  -- bool (only true/false occur)
    selectable                  INTEGER,  -- bool
    ai_defence                  INTEGER,  -- bool (only true/false occur)
    ai_critical                 INTEGER,  -- bool
    ai_core                     INTEGER,  -- bool
    ai_resource                 INTEGER,  -- bool
    ai_threat                   INTEGER,
    unstealth_range             REAL,
    turret_attach_id            INTEGER REFERENCES turrets(id),
    exclude_from_skirmish_lose  INTEGER,  -- bool
    exclude_from_campaign_lose  INTEGER,  -- bool
    upgraded_primary_required   INTEGER,  -- bool
    disable_with_low_power      INTEGER,  -- bool
    disable_if_no_spice_on_map  INTEGER,  -- bool
    hide_unit_on_radar          INTEGER,  -- bool
    range_indicator             INTEGER,  -- visual range indicator radius (building turrets)
    range_mask                  INTEGER,
    get_unit_when_built_id      INTEGER REFERENCES units(id),      -- forward reference; SQLite resolves FKs after CREATE
    -- ObjectTypeWhenGone is polymorphic. Values include crates (CashCrate,
    -- MoneyCrate), a unit (FRADVFremen), and an FX marker (WormSign0), not
    -- only other buildings. The previous buildings(id) FK was incorrect, so
    -- the raw name is retained and the GUI/parser resolves its entity type.
    object_type_when_gone       TEXT,
    chaos_effect_id             INTEGER REFERENCES explosion_types(id),
    hawk_effect_id               INTEGER REFERENCES explosion_types(id),
    damage_effect_id             INTEGER REFERENCES explosion_types(id),
    explosion_type_id           INTEGER REFERENCES explosion_types(id),
    debris_id                   INTEGER REFERENCES debris_types(id),
    counts_for_stats             INTEGER,  -- bool
    view_range_base              REAL,
    view_range_bonus             REAL,
    view_range_bonus_terrain_id INTEGER REFERENCES terrain_types(id),
    gets_height_advantage        INTEGER,  -- bool
    source_line                  INTEGER   -- source Rules.txt line (diffing/tracing)
);

-- Occupy= is a row-based building footprint mask (one character per cell,
-- such as s/n/b). Each source Occupy= line is one mask row.
CREATE TABLE building_occupy_rows (
    id           INTEGER PRIMARY KEY,
    building_id  INTEGER NOT NULL REFERENCES buildings(id) ON DELETE CASCADE,
    row_index    INTEGER NOT NULL,   -- zero-based top-to-bottom row order
    pattern      TEXT NOT NULL,      -- e.g. "nbbbn"
    UNIQUE (building_id, row_index)
);

CREATE TABLE building_terrain (
    building_id     INTEGER NOT NULL REFERENCES buildings(id) ON DELETE CASCADE,
    terrain_type_id INTEGER NOT NULL REFERENCES terrain_types(id),
    PRIMARY KEY (building_id, terrain_type_id)
);

-- Building PrimaryBuilding/SecondaryBuilding values mean "one of these
-- buildings must already exist" (e.g. HKSmWindtrap requires
-- ATConYard|ORConYard|HKConYard).
CREATE TABLE building_requires_primary (
    building_id          INTEGER NOT NULL REFERENCES buildings(id) ON DELETE CASCADE,
    required_building_id INTEGER NOT NULL REFERENCES buildings(id),
    PRIMARY KEY (building_id, required_building_id)
);

CREATE TABLE building_requires_secondary (
    building_id          INTEGER NOT NULL REFERENCES buildings(id) ON DELETE CASCADE,
    required_building_id INTEGER NOT NULL REFERENCES buildings(id),
    PRIMARY KEY (building_id, required_building_id)
);

-- DeployTile/DeployAngle describe building docking or unit exit points. The
-- source format is inconsistent:
--   a) Refinery style: several separate "DeployTile = x,y" lines, each
--      immediately followed by its own "DeployAngle = angle" (harvester
--      docks with an approach direction).
--   b) Factory/Starport style: one line containing several coordinate pairs
--      separated by spaces/commas ("DeployTile = 3,7, 3,1"), with no angle;
--      these are plain unit exit points.
-- This table covers both forms; angle is NULL for form (b).
CREATE TABLE building_deploy_points (
    id          INTEGER PRIMARY KEY,
    building_id INTEGER NOT NULL REFERENCES buildings(id) ON DELETE CASCADE,
    seq         INTEGER NOT NULL,   -- zero-based point order
    tile_x      INTEGER NOT NULL,
    tile_y      INTEGER NOT NULL,
    angle       REAL,               -- NULL when the source does not specify an angle
    UNIQUE (building_id, seq)
);

-- Factory/Wall/Refinery/Barracks/Hanger/Dockable/Outpost/Starport/
-- PopupTurret and the preceding names are boolean building-role markers.
-- They initially appeared redundant with building_group_id, but validation
-- showed otherwise: [BuildingGroupTypes], which deduplicates minimap icons,
-- does not contain Factory/Barracks/Hanger at all. Roles are therefore an
-- independent classification used by other game logic (unit production,
-- wall adjacency, etc.), overlapping Group only where both systems define
-- an entry (Wall, Refinery, Outpost, Starport, Helipad).
CREATE TABLE building_roles (
    id   INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE
);

CREATE TABLE building_role_tags (
    building_id INTEGER NOT NULL REFERENCES buildings(id) ON DELETE CASCADE,
    role_id     INTEGER NOT NULL REFERENCES building_roles(id),
    PRIMARY KEY (building_id, role_id)
);

-- =============================================================================
-- 8. UNITS
-- =============================================================================

-- [UnitTypes]
CREATE TABLE units (
    id                           INTEGER PRIMARY KEY,
    name                         TEXT NOT NULL UNIQUE,
    legacy_name                  TEXT NOT NULL UNIQUE,
    house_id                     INTEGER REFERENCES houses(id),
    unit_group_id                INTEGER REFERENCES unit_groups(id),
    cost                         INTEGER,
    build_time                   INTEGER,
    size                         INTEGER,
    speed                        REAL,
    mech_speed                   REAL,     -- walker speed from MechSpeed, in game coordinates per update
    mech                         INTEGER,  -- bool: legged chassis; the whole body does not tilt with terrain slope
    turn_rate                    REAL,
    armour_type_id               INTEGER REFERENCES armour_types(id),
    armour_modifier_percent      REAL,     -- e.g. "Armour = None, 50, InfRock" -> 50
    armour_modifier_terrain_id   INTEGER REFERENCES terrain_types(id), -- modifier condition (InfRock)
    health                       INTEGER,
    tech_level                   INTEGER,
    storm_damage                 INTEGER,
    tasty_to_worms                INTEGER,  -- bool
    worm_attraction               INTEGER,
    ai_threat                    INTEGER,
    score                         INTEGER,
    reinforcement_value           INTEGER,
    debris_id                    INTEGER REFERENCES debris_types(id),
    chaos_effect_id               INTEGER REFERENCES explosion_types(id),
    hawk_effect_id                 INTEGER REFERENCES explosion_types(id),
    damage_effect_id               INTEGER REFERENCES explosion_types(id),
    explosion_type_id             INTEGER REFERENCES explosion_types(id),
    can_move_any_direction         INTEGER,  -- bool
    can_be_deviated                INTEGER,  -- bool
    can_self_repair                 INTEGER,  -- bool (base attribute, not a veterancy level)
    can_be_repaired                 INTEGER,  -- bool
    infantry                        INTEGER,  -- bool
    crushable                       INTEGER,  -- bool
    crushes                         INTEGER,  -- bool
    starportable                    INTEGER,  -- bool
    ai_special                      INTEGER,  -- bool (only TRUE occurs in source data)
    ai_tank                         INTEGER,  -- bool
    ai_foot                         INTEGER,  -- bool
    ai_air                           INTEGER,  -- bool
    ai_uncontrolled                  INTEGER,  -- bool
    ai_critical                      INTEGER,  -- bool
    gets_height_advantage            INTEGER,  -- bool
    upgraded_primary_required        INTEGER,  -- bool
    crate_gift                      INTEGER,  -- bool (only TRUE occurs in source data)
    can_be_suppressed                INTEGER,  -- bool
    can_fly                          INTEGER,  -- bool
    can_die                          INTEGER,  -- bool
    cant_be_leeched                   INTEGER,  -- bool
    advanced_carryall                 INTEGER,  -- bool
    projectable                       INTEGER,  -- bool
    circles                           INTEGER,  -- bool
    selectable                        INTEGER,  -- bool
    hit_slow_down_amount              INTEGER,  -- percentage of Speed on hit
    hit_slow_down_duration            INTEGER,  -- ticks
    -- SpecialGround references terrain_types. Sand and DustBowl are actual
    -- terrain type names rather than free-form text.
    special_ground_terrain_id         INTEGER REFERENCES terrain_types(id),
    -- StealthedWhenStill also occurs as a base unit attribute, not only
    -- inside VeterancyLevel blocks, which have their own copy in
    -- unit_veterancy_levels.stealthed_when_still).
    stealthed_when_still              INTEGER,  -- bool
    roof_height                       INTEGER,  -- present on some flying units
    view_range_base                  REAL,
    view_range_bonus                 REAL,
    view_range_bonus_terrain_id     INTEGER REFERENCES terrain_types(id),
    height_offset                    REAL,
    exclude_from_skirmish_lose       INTEGER,  -- bool
    can_be_engineered                INTEGER,  -- bool
    -- Some units (for example, those with smoke trails) define MissileTrail
    -- parameters directly instead of only through Debris.
    missile_trail                     INTEGER,
    missile_trail_size                INTEGER,
    missile_trail_wiggle_freq         INTEGER,
    missile_trail_wiggle_scale        INTEGER,
    missile_trail_length              INTEGER,
    missile_trail_delta               REAL,
    -- ShieldHealth is an energy shield separate from health. ORLaserTank,
    -- ORAPC, and ORDeviator define both fields with different values.
    shield_health                     REAL,
    source_line                      INTEGER
);

-- Unit TurretAttach is not always singular. Some units (ATKindjal,
-- HKDevastator, HKBuzzsaw, ORKobra, etc.) attach two turrets/weapons at once
-- ("ATKindjalGun, ATKindjalBigGun"). Buildings do not do this, so their
-- TurretAttach remains the singular buildings.turret_attach_id column.
-- seq=0 is the primary weapon and seq=1 the secondary weapon (for example,
-- ORKobra undeployed/deployed or HKBuzzsaw left/right pairs).
CREATE TABLE unit_turrets (
    id        INTEGER PRIMARY KEY,
    unit_id   INTEGER NOT NULL REFERENCES units(id) ON DELETE CASCADE,
    seq       INTEGER NOT NULL,
    turret_id INTEGER NOT NULL REFERENCES turrets(id),
    UNIQUE (unit_id, seq)
);

CREATE TABLE unit_terrain (
    unit_id         INTEGER NOT NULL REFERENCES units(id) ON DELETE CASCADE,
    terrain_type_id INTEGER NOT NULL REFERENCES terrain_types(id),
    PRIMARY KEY (unit_id, terrain_type_id)
);

CREATE TABLE unit_primary_buildings (
    unit_id     INTEGER NOT NULL REFERENCES units(id) ON DELETE CASCADE,
    building_id INTEGER NOT NULL REFERENCES buildings(id),
    PRIMARY KEY (unit_id, building_id)
);

CREATE TABLE unit_secondary_buildings (
    unit_id     INTEGER NOT NULL REFERENCES units(id) ON DELETE CASCADE,
    building_id INTEGER NOT NULL REFERENCES buildings(id),
    PRIMARY KEY (unit_id, building_id)
);

-- VeterancyLevel blocks: a source section repeats the VeterancyLevel key two
-- or three times, each followed by bonuses up to the next VeterancyLevel or
-- section end. level_order is the ordinal (1,2,3...), and veterancy_score is
-- the actual required score threshold.
--
-- Complete set of fields found inside VeterancyLevel blocks across the full
-- source (validated across all sections, not a single example):
--   ExtraDamage (61), ExtraArmour (54), CanSelfRepair (31), ExtraRange (8),
--   Speed (6), Elite (3), Health (2), StealthedWhenStill (1).
-- Speed and Health inside VeterancyLevel are absolute overrides of the base
-- unit value (e.g. "Speed = 20.0", matching units.speed), not percentages.
-- ExtraDamage/ExtraArmour/ExtraRange are percentages, hence the names
-- speed_override/health_override rather than *_percent.
CREATE TABLE unit_veterancy_levels (
    id                    INTEGER PRIMARY KEY,
    unit_id               INTEGER NOT NULL REFERENCES units(id) ON DELETE CASCADE,
    level_order           INTEGER NOT NULL,   -- 1, 2, 3...
    veterancy_score       INTEGER NOT NULL,   -- VeterancyLevel= value
    extra_damage_percent  REAL,    -- ExtraDamage
    extra_armour_percent  REAL,    -- ExtraArmour
    extra_range_percent   REAL,    -- ExtraRange
    speed_override        REAL,    -- Speed (absolute replacement, not a bonus)
    health_override        INTEGER, -- Health (absolute replacement, not a bonus)
    can_self_repair        INTEGER, -- bool
    elite                   INTEGER, -- bool
    stealthed_when_still     INTEGER, -- bool
    UNIQUE (unit_id, level_order)
);

-- =============================================================================
-- 9. CRATES
-- =============================================================================

-- [CrateTypes]
CREATE TABLE crate_types (
    id                 INTEGER PRIMARY KEY,
    name               TEXT NOT NULL UNIQUE,
    size               INTEGER,
    health             INTEGER,
    crate_gift_object  TEXT,
    lifespan           INTEGER
);

CREATE TABLE crate_terrain (
    crate_type_id   INTEGER NOT NULL REFERENCES crate_types(id) ON DELETE CASCADE,
    terrain_type_id INTEGER NOT NULL REFERENCES terrain_types(id),
    PRIMARY KEY (crate_type_id, terrain_type_id)
);

-- =============================================================================
-- 10. SPLATS
-- =============================================================================

-- [SplatTypes]
CREATE TABLE splat_types (
    id                 INTEGER PRIMARY KEY,
    name               TEXT NOT NULL UNIQUE,
    size               INTEGER,
    lifespan           INTEGER,
    homing_delay       REAL,
    resource           TEXT,
    damage             REAL,
    explosion_type_id  INTEGER REFERENCES explosion_types(id)
);

-- =============================================================================
-- 11. SPICE MOUNDS
-- =============================================================================

-- [SpiceMoundTypes]
CREATE TABLE spice_mound_types (
    id                 INTEGER PRIMARY KEY,
    name               TEXT NOT NULL UNIQUE,
    health             INTEGER,
    size               INTEGER,
    cost               INTEGER,
    blast_radius       REAL,
    spice_capacity     INTEGER,
    explosion_type_id  INTEGER REFERENCES explosion_types(id),
    resource           TEXT,
    build_time         INTEGER,
    min_range          REAL,
    max_range          REAL
);

-- =============================================================================
-- 12. GENERAL — global balance configuration. The [General] section occurs
-- exactly once, so this is a singleton table with CHECK(id=1), not EAV.
-- =============================================================================

CREATE TABLE general_settings (
    id                                          INTEGER PRIMARY KEY CHECK (id = 1),
    version                                     TEXT,
    spice_value                                 INTEGER,
    fog_regrow_rate                             INTEGER,
    repair_rate                                 INTEGER,
    rearm_rate                                  INTEGER,
    starport_cost_update_delay                  INTEGER,
    starport_cost_variation_percent             INTEGER,
    starport_stock_increase_prob                INTEGER,
    starport_stock_increase_delay               INTEGER,
    starport_max_delivery_single                INTEGER,
    frigate_countdown                           INTEGER,
    harv_replacement_delay                      INTEGER,
    hawk_strike_duration                        INTEGER,
    lightning_duration                          INTEGER,
    deviate_duration                            INTEGER,
    sound_stealth_on                            TEXT,
    sound_stealth_off                           TEXT,
    sound_shield_on                             TEXT,
    sound_shield_off                            TEXT,
    sound_radar_on                              TEXT,
    sound_radar_off                             TEXT,
    adv_carryall_pickup_enemy_delay             INTEGER,
    stealth_delay                               INTEGER,
    stealth_delay_after_firing                  INTEGER,
    guard_tile_range                            INTEGER,
    min_worm_ride_wait_delay                    INTEGER,
    max_worm_ride_wait_delay                    INTEGER,
    frigate_timeout                             INTEGER,
    repair_tile_range                           INTEGER,
    worm_rider_lifespan                         INTEGER,
    max_building_placement_tile_dist            INTEGER,
    min_carry_tile_dist                         INTEGER,
    bullet_gravity                              REAL,
    suppression_delay                           INTEGER,
    suppression_prob                            INTEGER,
    inf_rock_range_bonus                        INTEGER,
    height_range_bonus                          INTEGER,
    inf_damage_range_bonus                      INTEGER,
    maximum_surface_worms                       INTEGER,
    chance_of_surface_worm                      INTEGER,
    chance_of_vertical_worm                     INTEGER,
    surface_worm_min_life                       INTEGER,
    surface_worm_max_life                       INTEGER,
    surface_worm_disappear_health               INTEGER,
    minimum_ticks_worm_can_appear               INTEGER,
    worm_attraction_radius                      INTEGER,
    unit_value_attacker                         INTEGER,
    unit_value_defender                         INTEGER,
    unit_value_reserves                         INTEGER,
    unit_value_initial_reinforcements           INTEGER,
    unit_value_subsequent_reinforcements        INTEGER,
    ticks_between_reinforcements                INTEGER,
    ticks_between_reinforcements_variation      INTEGER,
    ticks_before_reinforcements_for_message     INTEGER,
    storm_kill_chance                           INTEGER,
    storm_min_wait                              INTEGER,
    storm_max_wait                              INTEGER,
    storm_max_life                              INTEGER,
    storm_min_life                              INTEGER,
    cash_delivery_when_no_spice_amount_max      INTEGER,
    cash_delivery_when_no_spice_amount_min      INTEGER,
    cash_delivery_when_no_spice_frequency_max   INTEGER,
    cash_delivery_when_no_spice_frequency_min   INTEGER,
    campaign_attack_money                       INTEGER,
    campaign_defend_money                       INTEGER,
    replica_should_fire                         INTEGER,  -- bool
    replica_flicker_chance_when_moving          REAL,
    replica_flicker_chance_when_still           REAL,
    replica_projection_time                     INTEGER,
    replica_vanish_time                         INTEGER,
    easy_build_time                             INTEGER,
    normal_build_time                           INTEGER,
    hard_build_time                             INTEGER,
    easy_build_cost                             INTEGER,
    normal_build_cost                           INTEGER,
    hard_build_cost                             INTEGER
);

-- =============================================================================
-- 13. ARTINI — visual resources and global UI/recolor settings.
--
-- ArtIni.txt spans several namespaces at once: units, buildings, bullets,
-- explosion_types, crates, debris, and splats. Art data therefore lives in a
-- separate layer with a polymorphic entity_type/entity_id association rather
-- than duplicating the same visual columns across every primary table.
-- =============================================================================

CREATE TABLE art_sidebar_types (
    seq   INTEGER PRIMARY KEY,
    name  TEXT NOT NULL UNIQUE
);

CREATE TABLE art_side_recolors (
    side_id  INTEGER PRIMARY KEY,
    red      INTEGER NOT NULL CHECK (red BETWEEN 0 AND 255),
    green    INTEGER NOT NULL CHECK (green BETWEEN 0 AND 255),
    blue     INTEGER NOT NULL CHECK (blue BETWEEN 0 AND 255)
);

CREATE TABLE art_configs (
    id                       INTEGER PRIMARY KEY,
    entity_type              TEXT NOT NULL,
    entity_id                INTEGER,
    art_name                 TEXT NOT NULL UNIQUE,
    icon                     TEXT,
    icon_grey                TEXT,
    xaf                      TEXT,
    xaf_construction         TEXT,
    sidebar_type             TEXT,
    clip_sphere              REAL,
    crap_shadow_size         REAL,
    load_flag_only_preplaced INTEGER NOT NULL DEFAULT 0,
    source_line              INTEGER
);

CREATE INDEX idx_art_configs_entity ON art_configs (entity_type, entity_id);

-- =============================================================================
-- 14. OVERFLOW — rare one-off fields without dedicated columns.
-- This preserves round-trip fidelity (the Rules.txt -> SQLite parser loses
-- nothing) without bloating primary tables with NULL columns for fields such
-- as AlertString/AlertTimeOut that occur once in the entire source.
-- entity_type is the target table name (units/buildings/bullets/...);
-- entity_id is its row ID.
-- =============================================================================

CREATE TABLE custom_fields (
    id           INTEGER PRIMARY KEY,
    entity_type  TEXT NOT NULL,
    entity_id    INTEGER NOT NULL,
    key          TEXT NOT NULL,
    value        TEXT,
    source_line  INTEGER
);

CREATE INDEX idx_custom_fields_entity ON custom_fields (entity_type, entity_id);

-- Resource= has no single meaning; its semantics depend on entity type:
--   Harvester (unit)              -> refinery buildings that accept spice
--   *MCV (unit)                   -> the ConYard it deploys into
--   *ConYard (building)           -> matching ATMCV/HKMCV/ORMCV
--   ATHawkWeapon/ORBeamWeapon     -> (effect-source building, bullet)
--   WormRider <-> FRADVFremen     -> reciprocal rider/mount unit link
--   *Splat                        -> associated bullet
--   SurfaceWorm                   -> WormSign markers (plain FX names rather
--                                    than entities with their own attributes)
-- Forcing these changing semantics into one typed FK would either misstate
-- the relationship or require five narrow columns for a single source key.
-- This table therefore preserves the raw ordered links. The parser/GUI
-- interprets unit/building/bullet/FX-name targets while resolving target_name.
CREATE TABLE entity_resource_links (
    id           INTEGER PRIMARY KEY,
    entity_type  TEXT NOT NULL,   -- 'unit' | 'building' | 'splat_type' | ...
    entity_id    INTEGER NOT NULL,
    seq          INTEGER NOT NULL,   -- zero-based value order in the source line
    target_name  TEXT NOT NULL,      -- source name before resolution
    source_line  INTEGER,
    UNIQUE (entity_type, entity_id, seq)
);

CREATE INDEX idx_entity_resource_links ON entity_resource_links (entity_type, entity_id);

-- =============================================================================
-- 15. USEFUL GUI EDITOR INDEXES (SEARCH/FILTERING)
-- =============================================================================

CREATE INDEX idx_units_house       ON units (house_id);
CREATE INDEX idx_units_name        ON units (name);
CREATE INDEX idx_buildings_house   ON buildings (house_id);
CREATE INDEX idx_buildings_name    ON buildings (name);
CREATE INDEX idx_bullets_warhead   ON bullets (warhead_id);
CREATE INDEX idx_turrets_bullet    ON turrets (bullet_id);
