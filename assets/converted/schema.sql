-- =============================================================================
-- Emperor: Battle for Dune — Rules.txt → SQLite
-- Нормализованная схема, строгая типизация по сущностям (units/buildings/
-- turrets/bullets/warheads/debris/crates/splats/spice mounds).
--
-- Источник правды — эта БД. Экспорт в движок (Godot) делается отдельным
-- шагом (SQLite -> JSON/Resource), эта схема сюда не завязана.
--
-- Дизайн-принципы:
--   1. Частые поля (>=~20 вхождений в категории) -> отдельные типизированные
--      колонки.
--   2. Составные/списковые поля (Terrain=, PrimaryBuilding=, Occupy=,
--      VeterancyLevel=, Armour=..,N,Terrain) -> дочерние/junction-таблицы.
--   3. Редкие one-off поля (встречаются 1-3 раза во всём файле) -> не
--      получают персональную колонку, а идут в overflow-таблицу
--      `custom_fields` (entity_type, entity_id, key, value) — иначе схема
--      разрастётся на сотни в основном NULL-колонок. Это не нарушает
--      "строгую типизацию по сущностям": просто garbage-collector для
--      длинного хвоста редких флагов, не сама схема.
--   4. Все ссылки на другие сущности по имени (TurretAttach, Bullet,
--      Warhead, ExplosionType, ChaosEffect...) резолвятся в FK на этапе
--      импорта, а не хранятся как TEXT.
-- =============================================================================

PRAGMA foreign_keys = ON;

-- =============================================================================
-- 1. СПРАВОЧНИКИ / ENUM-ТАБЛИЦЫ
-- =============================================================================

-- [TerrainTypes] — фиксированный список, порядок = числовой ID в движке
-- (совпадает с TYPE в tiledef.dat из terrain-contour-system.md).
CREATE TABLE terrain_types (
    id          INTEGER PRIMARY KEY,   -- совпадает с исходным TYPE-индексом (0..7)
    name        TEXT NOT NULL UNIQUE,  -- Sand, Rock, Cliff, NBRock, InfRock, DustBowl, MapEdge, Ramp
    sort_order  INTEGER NOT NULL
);

-- [ArmourTypes] — тоже фиксированный enum, используется как FK почти
-- отовсюду (Armour у юнитов/зданий, столбцы в warhead_armour_damage).
CREATE TABLE armour_types (
    id          INTEGER PRIMARY KEY,
    name        TEXT NOT NULL UNIQUE,  -- None, BPV, Light, Medium, Heavy, Concrete, Walls, Building, CY, Harvester, Invulnerable, Aircraft
    sort_order  INTEGER NOT NULL
);

-- Полный реестр имён из ВСЕХ [ExplosionTypes]-деклараций по файлу.
-- Часть из них — просто имена FX-хуков без своих параметров (Muzzle1,
-- LargeChaosFX...), часть — полноценные сущности с DamageToTile/FaceCamera
-- (расширяются в explosion_configs). Единый реестр нужен, потому что
-- ChaosEffect/HawkEffect/DamageEffect/ExplosionType на юнитах/зданиях/
-- пулях ссылаются на одно и то же пространство имён.
CREATE TABLE explosion_types (
    id          INTEGER PRIMARY KEY,
    name        TEXT NOT NULL UNIQUE,
    source_line INTEGER                -- строка первого упоминания в Rules.txt (диагностика)
);

-- [BuildingGroupTypes] — используется для схлопывания дублей иконок
-- (SmWindtrap, Outpost, Refinery...).
CREATE TABLE building_groups (
    id   INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE
);

-- [UnitGroupTypes] — категория юнита для группировки в производстве.
CREATE TABLE unit_groups (
    id   INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE
);

-- [HouseTypes] + данные из секций [Atreides]/[Ordos]/... (SubHouse, SoundFile).
-- Не чистый enum — есть собственные данные, поэтому полноценная таблица.
-- ПРОВЕРЕНО НА ДАННЫХ: SubHouse/Subhouse — это булев флаг ("TRUE" всегда),
-- а не имя родительской фракции. Изначальное предположение про
-- self-reference ("Imperial = Sardaukar") было неверным домыслом без
-- проверки — реальных данных о иерархии House->House в файле нет вообще.
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

-- [WarheadTypes] — сама секция warhead'а не имеет "обычных" полей: её тело
-- это построчно "ИмяТипаБрони = процент урона" (None/BPV/Light/Medium/...).
--
-- Проверено на данных: в [WarheadTypes] попадают и настоящие warhead'ы
-- бомб/пуль (тело = таблица урона по броне, на них есть ссылки Warhead=),
-- и пара "хвостов" без чёткой роли — AntiPersonnel (нет тела вообще, нет
-- ни одной ссылки Warhead=) и AntiTank (тело ЕСТЬ, структурно как у
-- обычного warhead'а, но тоже ни разу не встречается в Warhead=).
-- Чистого структурного деления "категория vs реальный warhead" в данных
-- нет, поэтому отдельного флага-признака здесь намеренно нет — вопрос
-- "используется ли этот warhead хоть одной пулей/юнитом" считается
-- запросом (JOIN на bullets.warhead_id), а не хранимым состоянием.
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

-- [DebrisTypes]: DebrisLarge/Medium/Small — одинаковый набор из 6 визуальных
-- полей траектории обломков.
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
    blow_up                     INTEGER,  -- bool (проверено: только TRUE в данных)
    blast_radius                REAL,
    shot                        INTEGER,
    reduce_damage_with_distance INTEGER,  -- bool
    missile_trail                INTEGER,
    missile_trail_size           INTEGER,
    missile_trail_wiggle_freq    INTEGER,
    missile_trail_wiggle_scale   INTEGER,
    missile_trail_length         INTEGER,
    missile_trail_delta          REAL,
    -- DamageFriendly (bool) и FriendlyDamageAmount (число) в исходнике
    -- НИКОГДА не встречаются в одной секции одновременно (проверено по
    -- всем 19 вхождениям) — это два разных способа задать одно и то же
    -- в разные периоды разработки. При импорте: DamageFriendly=TRUE -> 100,
    -- DamageFriendly=FALSE -> 0, FriendlyDamageAmount=N -> N как есть.
    friendly_damage_amount      REAL,
    anti_aircraft                INTEGER,  -- bool
    anti_ground                  INTEGER,  -- bool
    homing                       INTEGER,  -- bool
    homing_delay                 REAL,
    turn_rate                    REAL,
    continuous                   INTEGER,  -- bool
    trajectory                   INTEGER,  -- bool (проверено: только true в данных)
    burnt                         INTEGER,  -- bool
    ignites                       INTEGER,  -- bool
    gassed                        INTEGER,  -- bool
    is_laser                      INTEGER,  -- bool
    leech                         INTEGER,  -- bool
    infantry                      INTEGER,  -- bool ("работает по пехоте" — контекст уточнить при импорте)
    health                        REAL,
    shield_health                 REAL,
    damage_column                 INTEGER,  -- bool (проверено: только TRUE в данных)
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
    turret_next_joint_id             INTEGER REFERENCES turrets(id),  -- составные турели база+ствол (напр. ORGasTurretBase -> ORGasTurretGun)
    turret_disable_if_unit_deployed  INTEGER,  -- bool
    turret_disable_if_unit_undeployed INTEGER, -- bool
    turret_y_acceptable_aim          REAL,
    turret_x_acceptable_aim          REAL,
    turret_bullet_count              INTEGER
);

-- =============================================================================
-- 6. EXPLOSIONS (расширение explosion_types для тех, у кого есть параметры)
-- =============================================================================

CREATE TABLE explosion_configs (
    explosion_type_id        INTEGER PRIMARY KEY REFERENCES explosion_types(id) ON DELETE CASCADE,
    damage_to_tile           REAL,
    face_camera               INTEGER,  -- bool
    chained_explosion_type_id INTEGER REFERENCES explosion_types(id)
);

-- ExplosionType = в исходнике иногда встречается НЕСКОЛЬКО раз в одной
-- секции с РАЗНЫМИ значениями (проверено: у DevPlasma_B — ShellHit и
-- DevImpact, т.е. разные эффекты для разных событий пули), а не просто
-- задвоенное значение по ошибке. Основные таблицы (units/buildings/
-- bullets/splat_types/spice_mound_types) хранят "главный"/первый эффект
-- в explosion_type_id для удобных запросов, а этот реестр — полный
-- упорядоченный список, если он длиннее одного значения.
CREATE TABLE entity_explosion_effects (
    id                 INTEGER PRIMARY KEY,
    entity_type        TEXT NOT NULL,   -- 'unit' | 'building' | 'bullet' | 'splat_type' | 'spice_mound_type'
    entity_id          INTEGER NOT NULL,
    seq                INTEGER NOT NULL,  -- порядок появления в исходнике, с 0
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
    -- PowerGenerated — ОТДЕЛЬНОЕ от power_used поле (ветряки/windtrap'ы
    -- производят, остальные здания потребляют). Пропустил на первом
    -- проходе по частоте полей, нашлось при прогоне парсера.
    power_generated             INTEGER,
    storm_damage                INTEGER,
    roof_height                 INTEGER,
    score                       INTEGER,
    num_infantry_when_gone      INTEGER,
    can_be_engineered           INTEGER,  -- bool
    can_be_primary              INTEGER,  -- bool
    is_con_yard                 INTEGER NOT NULL DEFAULT 0, -- ConYard = true
    ai_exit                     INTEGER,  -- bool (проверено: только true/false в данных)
    upgrade_tech_level          INTEGER,
    upgrade_cost                INTEGER,
    ai_manufacturing            INTEGER,  -- bool (проверено: только true/false)
    selectable                  INTEGER,  -- bool
    ai_defence                  INTEGER,  -- bool (проверено: только true/false)
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
    range_indicator             INTEGER,  -- радиус визуального индикатора дальности (у турелей-зданий)
    range_mask                  INTEGER,
    get_unit_when_built_id      INTEGER REFERENCES units(id),      -- forward ref, ок для SQLite (FK резолвится не при CREATE)
    -- ObjectTypeWhenGone: полиморфное поле — проверено, что значениями
    -- бывают и крейты (CashCrate, MoneyCrate), и юнит (FRADVFremen), и
    -- FX-маркер (WormSign0), т.е. НЕ только другое здание. Раньше здесь
    -- был FK на buildings(id), это было неверно — оставляю сырым именем,
    -- разрешение по типу делает GUI/парсер, а не строгий FK.
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
    source_line                  INTEGER   -- строка в исходном Rules.txt (для диффа/трассировки)
);

-- Occupy = построчная маска footprint'а здания (символ на клетку:
-- s/n/b и т.п.), одна строка Occupy= в исходнике = одна строка маски.
CREATE TABLE building_occupy_rows (
    id           INTEGER PRIMARY KEY,
    building_id  INTEGER NOT NULL REFERENCES buildings(id) ON DELETE CASCADE,
    row_index    INTEGER NOT NULL,   -- порядок строки сверху вниз, с 0
    pattern      TEXT NOT NULL,      -- напр. "nbbbn"
    UNIQUE (building_id, row_index)
);

CREATE TABLE building_terrain (
    building_id     INTEGER NOT NULL REFERENCES buildings(id) ON DELETE CASCADE,
    terrain_type_id INTEGER NOT NULL REFERENCES terrain_types(id),
    PRIMARY KEY (building_id, terrain_type_id)
);

-- PrimaryBuilding/SecondaryBuilding у зданий — список "нужно одно из этих
-- уже построенных зданий" (напр. HKSmWindtrap требует ATConYard|ORConYard|HKConYard).
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

-- DeployTile/DeployAngle — точки доковки/выхода юнитов у здания. Формат в
-- исходнике неоднородный:
--   а) Refinery-стиль: несколько ОТДЕЛЬНЫХ строк "DeployTile = x,y", у
--      каждой сразу следом своя "DeployAngle = угол" (доки харвестера
--      с направлением подъезда);
--   б) Factory/Starport-стиль: ОДНА строка с несколькими парами координат
--      через пробел/запятую ("DeployTile = 3,7, 3,1"), без угла вообще —
--      просто точки выхода юнитов.
-- Таблица покрывает оба случая: angle NULL для варианта (б).
CREATE TABLE building_deploy_points (
    id          INTEGER PRIMARY KEY,
    building_id INTEGER NOT NULL REFERENCES buildings(id) ON DELETE CASCADE,
    seq         INTEGER NOT NULL,   -- порядок точки, с 0
    tile_x      INTEGER NOT NULL,
    tile_y      INTEGER NOT NULL,
    angle       REAL,               -- NULL, если угол не задан в исходнике
    UNIQUE (building_id, seq)
);

-- Factory/Wall/Refinery/Barracks/Hanger/Dockable/Outpost/Starport/
-- PopupTurret — булевы самомаркеры роли здания. Изначально выглядели как
-- дубль building_group_id, но проверка на данных показала обратное:
-- [BuildingGroupTypes] (список для дедупа иконок миникарты) вообще НЕ
-- содержит 'Factory'/'Barracks'/'Hanger' — этим ролям физически некуда
-- деться в Group. Значит это независимая от Group классификация (роль
-- здания для другой игровой логики — что производит юнитов, что можно
-- обстроить стеной и т.п.), просто пересекающаяся с Group там, где обе
-- системы существуют (Wall, Refinery, Outpost, Starport, Helipad).
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
    turn_rate                    REAL,
    armour_type_id               INTEGER REFERENCES armour_types(id),
    armour_modifier_percent      REAL,     -- напр. "Armour = None, 50, InfRock" -> 50
    armour_modifier_terrain_id   INTEGER REFERENCES terrain_types(id), -- условие модификатора (InfRock)
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
    can_self_repair                 INTEGER,  -- bool (базовое, не veterancy-уровень)
    can_be_repaired                 INTEGER,  -- bool
    infantry                        INTEGER,  -- bool
    crushable                       INTEGER,  -- bool
    crushes                         INTEGER,  -- bool
    starportable                    INTEGER,  -- bool
    ai_special                      INTEGER,  -- bool (проверено: только TRUE в данных)
    ai_tank                         INTEGER,  -- bool
    ai_foot                         INTEGER,  -- bool
    ai_air                           INTEGER,  -- bool
    ai_uncontrolled                  INTEGER,  -- bool
    ai_critical                      INTEGER,  -- bool
    gets_height_advantage            INTEGER,  -- bool
    upgraded_primary_required        INTEGER,  -- bool
    crate_gift                      INTEGER,  -- bool (проверено: только TRUE в данных)
    can_be_suppressed                INTEGER,  -- bool
    can_fly                          INTEGER,  -- bool
    can_die                          INTEGER,  -- bool
    cant_be_leeched                   INTEGER,  -- bool
    advanced_carryall                 INTEGER,  -- bool
    projectable                       INTEGER,  -- bool
    circles                           INTEGER,  -- bool
    selectable                        INTEGER,  -- bool
    hit_slow_down_amount              INTEGER,  -- % от Speed при попадании
    hit_slow_down_duration            INTEGER,  -- тиков
    -- SpecialGround — ссылка на terrain_types (проверено: значения Sand,
    -- DustBowl — реальные имена типов рельефа, не свободный текст).
    special_ground_terrain_id         INTEGER REFERENCES terrain_types(id),
    -- StealthedWhenStill встречается и как БАЗОВЫЙ атрибут юнита (не
    -- только внутри VeterancyLevel-блока, где есть своя копия в
    -- unit_veterancy_levels.stealthed_when_still).
    stealthed_when_still              INTEGER,  -- bool
    roof_height                       INTEGER,  -- есть у части летающих юнитов
    view_range_base                  REAL,
    view_range_bonus                 REAL,
    view_range_bonus_terrain_id     INTEGER REFERENCES terrain_types(id),
    height_offset                    REAL,
    exclude_from_skirmish_lose       INTEGER,  -- bool
    can_be_engineered                INTEGER,  -- bool
    -- часть юнитов (напр. с дымовым следом) задают MissileTrail-параметры
    -- напрямую, а не только через Debris.
    missile_trail                     INTEGER,
    missile_trail_size                INTEGER,
    missile_trail_wiggle_freq         INTEGER,
    missile_trail_wiggle_scale        INTEGER,
    missile_trail_length              INTEGER,
    missile_trail_delta               REAL,
    -- ShieldHealth — энергощит ОТДЕЛЬНО от health (проверено: ORLaserTank/
    -- ORAPC/ORDeviator имеют оба поля одновременно с разными значениями).
    shield_health                     REAL,
    source_line                      INTEGER
);

-- TurretAttach у юнитов — НЕ всегда одно значение: у части юнитов
-- (ATKindjal, HKDevastator, HKBuzzsaw, ORKobra и т.п.) две башни/орудия
-- сразу ("ATKindjalGun, ATKindjalBigGun"). У зданий такого не встречено —
-- там TurretAttach остаётся одиночной колонкой buildings.turret_attach_id.
-- seq=0 — основное орудие, seq=1 — второе (напр. undeployed/deployed
-- пара у ORKobra, left/right у HKBuzzsaw).
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

-- VeterancyLevel-блоки: в исходнике 2-3 повторения ключа VeterancyLevel
-- в одной секции, каждый со своим "хвостом" бонусов до следующего
-- VeterancyLevel/конца секции. level_order = порядковый номер (1,2,3...),
-- veterancy_score = сам порог (Score required).
--
-- Полный набор полей, реально встречающихся внутри VeterancyLevel-блоков
-- по всему файлу (проверено по всем секциям, а не по одному примеру):
--   ExtraDamage (61), ExtraArmour (54), CanSelfRepair (31), ExtraRange (8),
--   Speed (6), Elite (3), Health (2), StealthedWhenStill (1).
-- Важно: Speed и Health внутри VeterancyLevel — это АБСОЛЮТНЫЕ перезаписи
-- базового значения юнита (напр. "Speed = 20.0", как и в units.speed), а
-- НЕ проценты — в отличие от ExtraDamage/ExtraArmour/ExtraRange, которые
-- проценты. Поэтому speed_override/health_override, а не *_percent.
CREATE TABLE unit_veterancy_levels (
    id                    INTEGER PRIMARY KEY,
    unit_id               INTEGER NOT NULL REFERENCES units(id) ON DELETE CASCADE,
    level_order           INTEGER NOT NULL,   -- 1, 2, 3...
    veterancy_score       INTEGER NOT NULL,   -- значение VeterancyLevel=
    extra_damage_percent  REAL,    -- ExtraDamage
    extra_armour_percent  REAL,    -- ExtraArmour
    extra_range_percent   REAL,    -- ExtraRange
    speed_override        REAL,    -- Speed (абсолютное новое значение, не бонус)
    health_override        INTEGER, -- Health (абсолютное новое значение, не бонус)
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
-- 12. GENERAL — глобальный баланс-конфиг, секция [General] встречается
-- ровно один раз -> singleton-таблица с CHECK(id=1), а не EAV.
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
-- 13. ARTINI — визуальные ресурсы и глобальные UI/recolor настройки.
--
-- ArtIni.txt покрывает разные пространства имён сразу: units, buildings,
-- bullets, explosion_types, crates, debris, splats. Поэтому art-данные
-- лежат отдельным слоем с полиморфной привязкой entity_type/entity_id, а не
-- дублируют одинаковые визуальные колонки во всех основных таблицах.
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
-- 14. OVERFLOW — редкие one-off поля, не получившие персональной колонки.
-- Сохраняет round-trip fidelity (парсер Rules.txt -> SQLite ничего не
-- теряет), не раздувая основные таблицы NULL-полями ради полей вида
-- "AlertString"/"AlertTimeOut", встречающихся 1 раз на весь файл.
-- entity_type — имя целевой таблицы (units/buildings/bullets/...),
-- entity_id — её id.
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

-- Resource = — поле без единого смысла в зависимости от типа сущности:
--   Harvester (юнит)      -> список зданий-рефайнери для сдачи спайса
--   MCV (юнит)             -> список ConYard, во что разворачивается
--   *ConYard (здание)      -> "MCV" (какой юнит из него выезжает)
--   ATHawkWeapon/ORBeamWeapon (здание) -> (здание-источник эффекта, пуля)
--   WormRider <-> FRADVFremen (юнит)   -> взаимная ссылка наездник/маунт
--   *Splat (сплэт)          -> связанная пуля
--   SurfaceWorm (юнит)      -> список WormSign-маркеров (не сущности с
--                              собственными атрибутами, просто FX-имена)
-- Семантика меняется от типа к типу — загонять в один типизированный FK
-- значит либо соврать о смысле связи, либо городить 5 узкоспециальных
-- колонок ради одного ключа. Поэтому — сырая упорядоченная связь "как
-- есть"; интерпретация (юнит/здание/пуля/FX-имя) — на стороне парсера/
-- GUI при разрешении target_name в конкретную таблицу.
CREATE TABLE entity_resource_links (
    id           INTEGER PRIMARY KEY,
    entity_type  TEXT NOT NULL,   -- 'unit' | 'building' | 'splat_type' | ...
    entity_id    INTEGER NOT NULL,
    seq          INTEGER NOT NULL,   -- порядок значения в исходной строке, с 0
    target_name  TEXT NOT NULL,      -- имя как в исходнике, до резолва
    source_line  INTEGER,
    UNIQUE (entity_type, entity_id, seq)
);

CREATE INDEX idx_entity_resource_links ON entity_resource_links (entity_type, entity_id);

-- =============================================================================
-- 15. Полезные индексы под GUI-редактор (поиск/фильтрация)
-- =============================================================================

CREATE INDEX idx_units_house       ON units (house_id);
CREATE INDEX idx_units_name        ON units (name);
CREATE INDEX idx_buildings_house   ON buildings (house_id);
CREATE INDEX idx_buildings_name    ON buildings (name);
CREATE INDEX idx_bullets_warhead   ON bullets (warhead_id);
CREATE INDEX idx_turrets_bullet    ON turrets (bullet_id);
