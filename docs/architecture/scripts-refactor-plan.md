# Рефакторинг `scripts/`: распил крупных модулей, дедуп, переработка дизайна

## Context

`scripts/` — 120 файлов, 29 384 строки. Распределение резко неравномерное: 6 файлов
(`unit.gd` 3484, `combat_turret.gd` 2785, `building.gd` 1944, `building_controller.gd` 1286,
`combat_projectile.gd` 1045, `unit_navigation_system.gd` 1006) — это 11 550 строк, **39 %
всего кода в 5 % файлов**. `unit.gd` — 196 функций и 81 поле в одном классе;
`combat_turret.gd` — 141 функция и 40 полей.

Проблема не в размере как таковом, а в трёх его следствиях:

1. **Слипшиеся ответственности.** `Unit` — это одновременно движение, terrain-snap и
   slope-alignment, mech-gait, deploy-стейтмашина, attack-order, fire-sequence
   стейтмашина на несколько орудий, death-sequence с handoff'ом модели, owner-визуалы,
   selection halo и shield/scroll FX. Изменение одной из этих подсистем требует читать
   3.5k строк, чтобы понять, что ещё трогает те же поля.
2. **Дубли между Unit и Building.** Это два независимых класса, реализующих один и тот же
   duck-typed контракт (`combat_*`, `owner_player`/`is_owned_by`/`is_enemy_of`,
   `take_damage`, team-color, selection halo) — копипастой.
3. **Разбросанные микро-хелперы.** terrain raycast, `_players()`, поиск AnimationPlayer'ов,
   `_snap_to_ground` копируются по 6–9 раз.

Цель: привести код к структуре, которая уже принята в этом репозитории для навигации
(`docs/architecture/navigation-refactor-plan.md`): **тонкий Node-фасад + `RefCounted`
модули**, извлекаемые поэтапно, с зелёным `make godot-test` после каждого этапа.

Согласовано с пользователем: глубина — **распил + переработка дизайна** (общие
базовые классы/компоненты для Unit и Building, унификация `combat_*` контракта),
допускаются осознанные правки тестов. Порядок: `unit.gd` + `combat_turret.gd` →
`buildings/*` → кросс-модульные дубли.

---

## Установленная в репозитории конвенция извлечения (её и держим)

Проверено по `unit_flight_controller.gd`, `unit_death_strategy.gd`,
`combat_deploy_strategy.gd`, `navigation/shared/*`:

- модуль = `class_name X` + `extends RefCounted`, отдельный файл;
- создаётся владельцем через `.new()`, инициализируется `configure(owner, definition)`
  (или `setup(...)` для навигационных);
- владелец хранится в `var _unit` / `var _owner` **без типа** — иначе циклический
  `preload` с `unit.gd` (`unit_flight_controller.gd:64`, там же комментарий);
- модуль **не кэширует ссылки на узлы модели**, а каждый раз спрашивает владельца
  (`unit_flight_controller.gd:1-7`: «Holds no cached `AnimationPlayer` references … so a
  mid-life `replace_visual_scene()` swap can't leave it stale»). Это не стилистика, а
  инвариант — см. раздел про `_prepare_model_for_corpse` ниже;
  **но этот инвариант выполним не для всех модулей — см. следующий раздел про
  lifecycle-протокол**;
- владелец отдаёт модулю узкий API с префиксом подсистемы (`flight_play_clip`,
  `flight_clip_length`), а не открывает всё наружу;
- зависимость подключается через `const XScript := preload("res://...")`, не через
  bare `class_name` (`AGENTS.MD` → Code Rules, там же описан реальный инцидент).

## Lifecycle-протокол для модулей, владеющих ссылками на модель (блокер)

Правило «модуль не кэширует узлы модели» выполнимо для `UnitFlightController`, потому что
ему нужен *любой* плеер с нужным клипом — он спрашивает владельца каждый раз. Но часть
извлекаемого состояния **по своей природе является кэшем ссылок**, и делать вид, что
правило покрывает всё, нельзя:

| Уезжает в модуль | Что это по факту |
|---|---|
| `_deployment_animation_player` (`unit.gd:191`) | ссылка на конкретный `AnimationPlayer` модели |
| `_weapon_fire_overlays` (`:221`) | **созданные модулем** `AnimationPlayer`-узлы |
| `_shield_meshes`, `_scroll_fx_meshes` (`:152,154`) | списки `MeshInstance3D` модели |
| `_fx_model_root`, `_casing_timeline_tween`, `_particle_timeline_tweens` (`combat_turret.gd:109,133,134`) | корень модели + живые `Tween` |
| `_popup_transition_player` (`building.gd:166`) | ссылка на `AnimationPlayer` модели |

Сегодня всё это вручную обнуляет `_prepare_model_for_corpse()` (`unit.gd:1153-1215`) — и
его doc-коммент (`:1141-1152`) прямо называет себя «THIS IS THE HANDOFF NEUTRALIZATION
STEP» и «the single place that must be extended whenever a new field caches a reference
into `model`'s subtree». Распил ломает именно это свойство: место перестаёт быть
единственным.

Хуже: `_sever_connections_into()` (`:1226-1238`) отключает только те подключения, чей
`callable.get_object() == self`. **Callback, подключённый `RefCounted`-модулем, он не
найдёт** — его объект не `Unit`. То есть после переноса `_prepare_idle_animations`-подобных
подключений в модуль генерическая защита перестаёт работать молча.

**Поэтому вводится явный протокол, обязательный для любого модуля этого класса:**

```gdscript
func attach_model(root: Node3D) -> void   # собрать ссылки/подписки на новую модель
func detach_model() -> void               # kill Tween, disconnect ВСЕ свои подключения,
                                          # обнулить ссылки на узлы, освободить созданные узлы
func dispose() -> void                    # detach_model() + сброс остального состояния
```

Правила:
- **`detach_model()` и `dispose()` обязаны быть идемпотентными.** Это не пожелание:
  смерть юнита вызывает handoff (`_prepare_model_for_corpse`), а затем всё равно
  происходит `_exit_tree()` — то есть **двойной вызов гарантирован на каждой смерти**, а не
  является краевым случаем. Второй вызов обязан быть no-op, а не падением на уже убитом
  `Tween` или уже отключённом сигнале;
- `dispose()` дополнительно **обнуляет `_owner`** — иначе модуль и владелец держат друг
  друга живыми (это то же семейство, что `_flight_controller = null` в
  `unit.gd:1206` и комментарий там же);
- `detach_model()` обязан отключать подключения, сделанные **самим модулем** (модуль знает
  свои — генерический обход в `_sever_connections_into` их не видит);
- владелец вызывает протокол в **пяти** точках, и это исчерпывающий список:
  `_ready()`, `setup()`, `replace_visual_scene()`, `_prepare_model_for_corpse()`,
  `_exit_tree()`. Все пять сегодня уже вызывают `_cancel_all_fire_sequences`/
  `unbind_model` — новые вызовы встают туда же;
- `_prepare_model_for_corpse()` остаётся единственным местом-чеклистом, но его содержимое
  становится циклом по модулям, а не списком полей.

**И тест-инвариант расширяется дважды, не один раз** (см. этап 0): `_value_dangles()`
рекурсирует в script-объекты (иначе поля модулей не видны), а дополнительно нужна проверка
«после смерти на узлах корпса не осталось ни одного подключения, чей `callable.get_object()`
— это `Unit` **или любой из его модулей**». Без второй проверки `_sever_connections_into`
деградирует беззвучно.

## Что защищает рефакторинг

`make godot-test` — 28 headless-сьютов, `tests/` = 19 242 строки (для 29 384 строк
`scripts/`). Покрытие плотное, но **тесты white-box**: они дёргают приватные члены
напрямую. Проверено `grep` по `tests/`:

| Приватный член `Unit` | Кто дёргает |
|---|---|
| `_collision_sources()`, `_active_turrets()` | `demo_boot_run.gd:90`, `deployment_run.gd:565` |
| `_advance_visual_slope_alignment`, `_turn_toward`, `_idle_animation_weight`, `_mech_gait_cadence`, `_movement_animation_speed_scale` (через `.call()`) | `demo_boot_run.gd:160,221,294,341,373` |
| `_process`, `_physics_process` | `combat/run.gd:2513,2828,2844,2864,2930,2941`, `flight_run.gd:326` |
| `_fire_animation_binding`, `_authored_fire_shot_times`, `_finish_fire_sequence_for` | `combat/run.gd:3325,3329,4317` |
| поля `_weapon_fire_sequences`, `_weapon_fire_overlays`, `_has_attack_order`, `_attack_is_ground`, `_attack_target_ref`, `_animation_players`, `_deployment_animation_player` | `death_animation_run.gd:201,202,220,265-269,347-355,369`, `combat/run.gd:4311` |

**Следствие для распила:** `Node.call("_foo")` не находит методы на вложенном
`RefCounted`, а прямой доступ к полю — тем более. Всё из таблицы обязано остаться на
фасаде `Unit`: методы — как тонкие forwarding-обёртки, поля — как **поля** (то есть
эти конкретные словари остаются на `Unit`, даже если логика их обслуживания уезжает
в модуль). Та же дисциплина, что была зафиксирована для навигации.

Таблица выше **неполна** — она покрывает `Unit`. Дополнительно проверено:
`turret._spawn_muzzle_flash(...)` и `_particle_timeline_tweens`
(`tests/combat/run.gd:1565`), `building._popup_turret_state` (`:3967`), поля
pointer-жеста контроллера `_placement_pointer_down`/`_placement_press_position`/
`_placement_rotated_during_press` + `_building_placement` + `_finish_placement_pointer_action`
(`tests/buildings/controller_run.gd:152-155`). То есть white-box-связность есть и в
`combat_turret.gd` (этап 4), и в `building*.gd` (этап 5) — полный аудит выносится в этап 0.5.

### Второй white-box-контракт, который тесты не покрывают: наследование

`Harvester extends Unit` (`harvester.gd:1-2`), и он **переопределяет приватные методы
базового класса**:

| Переопределяет / читает | Строка |
|---|---|
| `_set_movement_animation(...)` + `super._set_movement_animation(...)` | `harvester.gd:820, 826` |
| `_on_animation_finished(...)` + `super._on_animation_finished(...)` | `:829, 833` |
| `_apply_unit_definition()` + `super.` | `:808` |
| вызывает `_turn_toward(...)` | `:376` |
| итерирует `_animation_players` напрямую | `:672` |
| `super._process`, `super.set_navigation_controller`, `super.has_active_order`, `super.cancel_all_orders`, `super.move_to` | `:66, 96, 269, 287, 795` |

Это **жёсткий блокер именно для `units/unit_locomotion.gd`**: как только
`_set_movement_animation` и `_on_animation_finished` уедут в модуль, переопределения
`Harvester` перестанут вызываться — молча, без падения тестов, потому что модуль будет
звать свою реализацию, а не наследника. Ни один тест этого не поймает.

Решения, по убыванию предпочтительности:
1. **эти два метода остаются на фасаде `Unit`** как точки расширения, а модуль получает их
   как hook'и (`driver.on_animation_finished(...)` вызывается *из* `Unit._on_animation_finished`,
   после `super`-цепочки). Безопасно, ничего не ломает, и это отдельная причина не
   извлекать `_on_animation_finished` целиком, помимо уже описанной;
2. перевести `Harvester` с наследования на композицию — правильно по существу (и
   согласуется с общим предпочтением композиции), но это самостоятельная задача
   сравнимого размера, **не** часть этого плана.

Выбираем (1). Пункт 2 расписан в конце файла — «Отдельная задача: `Harvester` — с
наследования на композицию (после этапа 7)»: там замер сцепления (22 точки), два
прочтения «композиции» с явной причиной отказа от одного из них, и обоснование порядка.

### Отдельно: слепое пятно, которое распил создаёт в тесте-инварианте

`tests/units/death_animation_run.gd:449 _find_dangling_references()` — reflection-тест,
единственная защита от класса багов cdc79b6/2b745b2 («мёртвый юнит всё ещё держит ссылку
в отданное корпсу поддерево»). Он обходит `unit.get_property_list()` и рекурсивно
проверяет значения через `_value_dangles()` (`:424`).

`_value_dangles()` рекурсирует **только в `Array` и `Dictionary`**; для валидного
не-`Node` объекта он возвращает `false` (`:425-430`). Значит: как только
`_animation_players` / `_weapon_fire_overlays` / `_deployment_animation_player` уедут
внутрь `RefCounted`-модуля, тест перестанет их видеть и **молча позеленеет навсегда**,
потеряв ровно ту гарантию, ради которой написан.

Поэтому **этап 0 плана — расширить `_value_dangles()` рекурсией в script-объекты**
(`value.get_script() != null` → обойти его `get_property_list()` с
`PROPERTY_USAGE_SCRIPT_VARIABLE`, с защитой от циклов по `get_instance_id()`), и только
потом трогать `unit.gd`. Это единственная правка теста, которую нужно сделать *до*
рефакторинга, а не после.

---

## Кросс-модульные дубли (проверено `diff`/`grep`, не на глаз)

| Дубль | Копии | Статус |
|---|---|---|
| `owner_player()`/`is_neutral_owner()`/`is_owned_by()`/`is_allied_with()`/`is_enemy_of()` | `unit.gd:2654-2678` ≡ `building.gd:1542-1566` | **byte-identical, 25 строк** (`diff` пустой) |
| `_mesh_declares_team_color()` | `unit.gd:3256-3276` ≡ `building.gd:1795-1815` | **byte-identical, 21 строка** |
| `_owner_team_color()` | `unit.gd:3277`, `building.gd:1781` | одинаковая логика |
| `_players()` → `get_node_or_null("/root/Players")` | `unit.gd:3284`, `building.gd:1925`, `building_controller.gd:1271`, `building_upgrade_controller.gd:505`, `unit_command_controller.gd:868`, `match.gd:452` | **6 копий** |
| `_selection_bounds()` + `_selection_radius()`/`_selection_position()` + halo setup | `unit.gd:3352-3472`, `building.gd:1816-1936` | почти идентичны (различие — корень: `visual_root` vs `self`) |
| `take_damage()` (щиты поглощают → смерть) | `unit.gd:975-988`, `building.gd:1130-1151` | идентичны до ветки смерти |
| `_collect_animation_players()` | `unit.gd:2749-2755` ≡ `death_corpse.gd:186-192` | **byte-identical** (различие — имя поля корня) |
| screen-ray pick (`project_ray_origin` + `project_ray_normal * 1000.0` + mask + `collide_with_areas=false`) | `building_placement.gd:870-875`, `building_controller.gd:1263-1268`, `unit_command_controller.gd:828-833` | **3 копии** |
| `_snap_to_ground()` (ray ±200 по Y, mask 1, fallback y=0) | `match.gd:224-231` ≡ `building_placement.gd:878-887` | **идентичны** |
| terrain-height ray | ещё и `unit.gd:913-920`, `combat_ground_decal.gd:103-110`, `map_spice_layer.gd:607-611` | та же форма, 5 вариантов констант высоты |
| разрешение клипа по списку кандидатов (`has_animation` скан) | 15 файлов (`grep -l has_animation scripts/`) | разные формы одного идиома |

Всего по этим пунктам — порядка 700–900 строк копипасты.

### Целевые shared-модули

| Файл | Содержимое |
|---|---|
| `scripts/world/terrain_probe.gd` | `static func cast(world, from: Vector3, to: Vector3, mask, exclude) -> Dictionary` (базовая форма — **`from`/`to` явно**, не `position + высота`), плюс удобные `height_hit(world, position, ...)`, `snap_to_ground(world, point)`, `screen_pick(camera, world, screen_position, mask)` поверх неё. `World3D` передаётся аргументом: у `map_spice_layer.gd` он берётся не у себя, а у `_terrain_mesh` (`:610`), поэтому «взять `get_world_3d()` внутри» не пройдёт |
| `scripts/players/autoload_lookup.gd` | `static func roster(node) -> Node` (единственная реализация `/root/Players`), `static func cursors(node) -> Node` (`/root/Cursors`), `static func player_of(node, player_id)`. Покрывает **оба** автолоада: 9 сайтов `Players` + 3 сайта `Cursors` (`building_controller.gd:567`, `rts_camera.gd:167`, `unit_command_controller.gd:877`) — один модуль, а не два, потому что guard «а есть ли автолоад в headless» у них общий |
| `scripts/world/team_color.gd` | `static func declares_team_color(mesh_instance) -> bool`, `static func apply(root, color)`, `static func color_for(roster_player, neutral_color: Color) -> Color` — нейтральный цвет **параметром**: у здания и юнита он разный (см. ниже) |
| `scripts/world/authored_model.gd` | `static func animation_players(root) -> Array[AnimationPlayer]`, `static func find_clip(players, candidates) -> Dictionary` (`{player, name}` — форма, которую уже возвращает `unit.gd:2540 _find_animation_player`), `static func collision_sources(root, prefix_order: Array)`, `static func selection_bounds(root)`, `static func play_one_shot(root, clip, on_finished)`, `static func play_state(node, state)`. Это «читалка конвертированной модели», единственное место, знающее про `#~~0`, `collision_points`-мету, маркеры выделения |
| `scripts/world/entity_query.gd` | `is_live(node)`, `owner_id_of(node)`, `is_owned_by(node, player_id)`, `is_operational(node)`, `exit_direction(node)`, `units_parent(tree)`, `owned_live_in_group(tree, group, player_id)`, плюс relations (`owner_player`/`is_allied_with`/`is_enemy_of`) |
| `scripts/combat/combat_target.gd` + `combat/combat_rules.gd` | `entity_of(collider)`, `position_of(target, origin)`, `is_alive(target)`, `hit_radius(target)`, `collision_rids(target)`; общие константы тиков/масок |

**Про форму `terrain_probe`:** единой сигнатуры `height_hit(world, position, mask, exclude)`
**недостаточно** — у существующих пяти вариантов рейкаст не симметричен и не всегда
привязан к точке. `combat_ground_decal.gd:103-110` использует разные `RAY_HEIGHT`/`RAY_DEPTH`
(вверх и вниз на разную величину) и ему нужна ещё и нормаль; `map_spice_layer.gd:605-608`
считает концы от `world_bounds.end.y`/`world_bounds.position.y`, то есть от границ карты, а
не от переданной точки. Поэтому базовый примитив принимает `from`/`to`, а «±200 от точки» —
это уже частный хелпер над ним.

**Почему статические, а не `RefCounted`:** у этих операций нет состояния, а вызываются
они из `Node`-ов, `RefCounted`-модулей и статических функций — статика единственная
форма, доступная всем трём без прокидывания владельца.

## Переработка дизайна: общий контракт Unit ↔ Building

Сегодня `Unit extends CharacterBody3D` (`unit.gd:1`) и `Building extends Node3D`
(`building.gd:2`) — независимые классы с разными родителями, реализующие один duck-typed
контракт копипастой. `Building.take_damage()` даже принимает `_death_cause` «for signature
parity with Unit.take_damage()» (`building.gd:1130-1134`) — то есть контракт осознан, но
нигде не выражен.

(Общий базовый класс тут и не нужен — ниже показано, что дедуп достигается без него
вообще; но и был бы он возможен технически или нет, ответ один: композиция.)

Первая версия этого раздела предлагала `CombatBody` — объект, владеющий health/shields,
ownership и таймером неуязвимости. Это была ошибка: такой объект совмещает три
несовместимые роли и неизбежно обзаводится ссылкой на владельца, жизненным циклом таймера
и вопросом «когда его создавать». Разбор ниже показывает, что **дедуп здесь достигается
вообще без экземпляра**.

Что выяснилось при проверке каждой из трёх ролей:

**Роль 1 — арифметика урона.** Единственное, что действительно продублировано
byte-in-byte, и единственное, что не имеет побочных эффектов. Сеттеры владельцев при этом
выполняют entity-specific работу, которую внешний объект пропустил бы:

```gdscript
# building.gd:101-106 — health setter
set(value):
    health = clampf(value, 0.0, max_health)
    health_changed.emit(health, max_health)   # сигнал наружу
    _refresh_generated_energy()               # энергосеть игрока
    _refresh_health_visual_state()            # переключение damage-state модели
```
```gdscript
# unit.gd:146-149 — shields setter
set(value):
    shields = clampf(value, 0.0, max_shields)
    _refresh_shield_visibility()              # видимость shield-мешей
```

Значит `@export`-состояние обязано остаться каноническим на фасаде, а общей может быть
только чистая функция:

```gdscript
# combat/damage_policy.gd — ни полей, ни владельца, ни экземпляра
class_name DamagePolicy
extends RefCounted

## Результат — объявленный класс, не Dictionary.
class Result extends RefCounted:
    var absorbed_by_shields := 0.0
    var health_delta := 0.0
    var is_lethal := false

static func resolve(
        amount: float, health: float, shields: float, invulnerable: bool
    ) -> Result
```

Про форму результата: **объявленный `class Result`, а не `Dictionary`**. У проекта уже есть
три несовместимых dictionary-результата (`{ok, message}` в `match_snapshot.gd`,
`{handled, started, message}` в `unit_deployment_controller.gd:570`,
`{handled, available, message}` в `_deployment_candidate`) — ровно тот случай, который этот
план в другом месте предлагает унифицировать, так что заводить четвёртый было бы странно.
Здесь три поля фиксированной формы, читаются сразу после вызова, и опечатка в имени ключа
у `Dictionary` не диагностируется вообще, а у типизированного поля — диагностируется.
Плюс `progress_percent`-подобные вещи в этом репозитории уже сделаны именно так
(`building_order.gd` — DTO-класс, конвенция C).

Фасад применяет результат через свои сеттеры и сам решает, что делать при `is_lethal`
(`Unit._begin_death_sequence` / `BuildingSurvivors.spawn_for_destroyed_building` +
`queue_free`). Так сохраняются сигналы, `@export`-метаданные, порядок побочных эффектов и
`PROPERTY_USAGE_SCRIPT_VARIABLE` (reflection-тест этапа 0 продолжает видеть поля). Дедуп —
полный: 8 строк арифметики щитов в одном месте. И раз функция статическая, вопрос «создавать
в `_ready()` или в инициализаторе поля» просто исчезает.

**Роль 2 — ownership.** `owner_player`/`is_neutral_owner`/`is_owned_by`/`is_allied_with`/
`is_enemy_of` действительно byte-identical (25 строк, `unit.gd:2654-2678` ≡
`building.gd:1542-1566`) и побочных эффектов не имеют — но это не «боевое тело», это запрос
к ростеру. Их место — `world/entity_query.gd` из этапа 1, рядом с `owner_id_of`/`is_live`.
Само поле `owner_player_id` **остаётся `@export` на фасаде**: у него сеттер с побочными
эффектами (`unit.gd:113-120` — `_refresh_owner_visuals()` + `owner_changed.emit`, у
`Building` дополнительно отмена приказа, энергия и upgrade).

**Роль 3 — временная неуязвимость.** Проверено: `grant_temporary_invulnerability`
существует **только** у `Unit` (`unit.gd:968`) и вызывается дак-тайпед из
`building_survivors.gd:84-85`. Дублирования нет — предыдущая версия плана утверждала
обратное, это была ошибка. Метод остаётся на `Unit`; таскать таймер в общий модуль не за чем.

**Итог:** вместо `CombatBody` — одна `static func` в `combat/damage_policy.gd` плюс
перенос relations в `entity_query.gd`. Никакого экземпляра, ссылки на владельца и
lifecycle не появляется.

Владельцы сохраняют **все** сегодняшние публичные имена (`take_damage`, `health`,
`combat_*`, `is_enemy_of`, …) — контракт наружу не меняется, `combat_impact_resolver.gd` и
тесты не правятся.

Тесты, обязательные для этого этапа: scene round-trip (`match/snapshot_run.gd` читает
`health`/`shields`/`max_health` напрямую), `health_changed`, пересчёт энергии, видимость
щита, смена владельца здания. Перед началом:
`grep -rn "\.health\|\.shields\|max_health" tests/ scripts/` — 40 сайтов только в `tests/`.

---

## `unit.gd` (3484 строки, 196 функций, 81 поле)

### Главная находка: механика authored-fire уже вынесена в модуль — и Unit ей не пользуется

`scripts/combat/authored_fire_controller.gd` (464 строки, `class_name AuthoredFireController`)
— это извлечённая версия ровно тех же двух кластеров, что живут внутри `unit.gd`. Её
использует **только `building.gd`** (`grep`: 17 обращений, `building.gd:8,164,181,…`),
`unit.gd` не ссылается на неё нигде.

Проверено `diff`:
- блок констант `unit.gd:44-50` ≡ `authored_fire_controller.gd:6-12` — **byte-identical**
  (`BAKED_MODEL_FRAMES_PER_SECOND`, `RULE_COMBAT_TICKS_PER_SECOND`,
  `FIRE_ANIMATION_SPEED_SCALE`, `FIRE_ANIMATION_PREFIX`, `FIRE_EVENT_EPSILON`);
- `unit.gd:754-761 _find_xbf_motion_root` ≡ `authored_fire_controller.gd:440-448` —
  идентичны с точностью до пустой строки;
- извлечение времён выстрелов из XBF: `unit.gd:2064-2283` (6 функций:
  `_authored_fire_shot_times`, `_xbf_fire_shot_times`, `_xbf_continuous_fire_shot_times`,
  `_configured_burst_shot_times`, `_animation_transform_peak`, `_transform_difference`) vs
  `authored_fire_controller.gd:208-439` — те же 6 функций, **~73 % строк совпадают
  дословно** (120 различающихся строк на ~450);
- `_encoded_target`/`_decoded_target`, `_animation_track_node`,
  `_play_animation_from_start`, `_apply_animation_start_transforms` — тоже парные копии.

**Это ~450 строк, которые надо не «извлечь», а удалить**, переведя `Unit` на существующий
`AuthoredFireController`. Это и самый крупный единичный выигрыш по строкам, и устранение
реального риска: сейчас любой фикс в разборе XBF FX-событий надо вносить в двух местах,
и они уже разошлись (23 % строк).

**Что для этого нужно и почему это не тривиально:**
`AuthoredFireController` держит **одну** последовательность в одном
`_sequence: Dictionary` (`:14-17`), а `Unit` держит **несколько**, по одной на орудие,
в `_weapon_fire_sequences` (`unit.gd:215`) — многотурельные машины стреляют независимо.
Значит порядок такой:
1. вынести из `unit.gd` в `authored_fire_controller.gd` то, что **не** зависит от
   мультиплексирования — разбор XBF (кластер P, 2064–2283) и `_find_xbf_motion_root` —
   как `static func`. `Unit` и контроллер начинают звать одно и то же. Поведение не
   меняется, тесты `combat/run.gd:3325,3329` (`_fire_animation_binding`,
   `_authored_fire_shot_times`) остаются зелёными через forwarding-обёртки;
2. только потом обобщать сам контроллер до N последовательностей и переводить `Unit` на
   него. Это второй, отдельный шаг, и он затрагивает тесты, которые пишут
   `unit._weapon_fire_sequences[0] = {...}` напрямую (`death_animation_run.gd:202,269,355`,
   `combat/run.gd:4311`) — словарь обязан остаться полем `Unit`.

### Мёртвый вес: 9 полей-зеркал

`unit.gd:203-211` — `_fire_sequence_active`, `_fire_sequence_turret`,
`_fire_sequence_player`, `_fire_sequence_animation`, `_fire_sequence_duration`,
`_fire_sequence_elapsed`, `_fire_sequence_shot_times`, `_fire_sequence_next_shot`,
`_fire_sequence_shots_emitted` — **девять полей, существующих только как зеркало**
`_weapon_fire_sequences`, синхронизируемое `_sync_legacy_fire_sequence` (1942–1963).
Комментарий на `:212-214` признаёт это: «legacy scalar fields … mirror whether any
sequence exists **for tests and older callers**».

Читаются они из `_on_animation_finished` (3165–3167) и из тестов
(`demo_boot_run.gd:1233,1236`, `combat/run.gd:3057,3128` — только `_fire_sequence_active`).
То есть **8 из 9 полей не нужны никому, кроме самой синхронизации.** Удалить восемь,
`_fire_sequence_active` оставить как вычисляемый `get`-геттер
(`not _weapon_fire_sequences.is_empty()`), а `_on_animation_finished` перевести на
`_weapon_fire_sequences` напрямую. Минус ~30 строк и целый класс рассинхрона.

### Извлечения из `unit.gd`

Поля, которые трогает **ровно один** кластер, — готовые границы. **Важная поправка:
формулировка «ровно один» верна не для всех строк таблицы ниже**, и четыре пересечения
установлены точно:

- `_mech_locomotion_state` (`:175`) — gait (F) **и** animation driver (X) **и**
  `_on_animation_finished` (Y) **и** оба цикла `_physics_process`/`navigation_step`
  (346, 581). Вывод: **mech gait и mech-анимация — одна стейтмашина, а не два модуля.**
  Резать их по границе «физика/анимация» значит разрезать состояние пополам.
- `_popup_turret_state` (`building.gd:165`) — пишется popup-модулем, но **читается
  attack-order логикой**: `_advance_building_combat` возвращается раньше времени, если
  состояние `DEPLOYING`/`UNDEPLOYING` (`building.gd:1395-1400`). Значит либо popup и
  building-combat — один модуль, либо между ними явная прямая зависимость (не через фасад).
- `_previous_global_position` (`:187`) — пишется фасадом в начале каждого
  `_physics_process` (300), читается только death sequence (1055). Поле не «принадлежит»
  death-модулю: он его потребитель. Передавать значением в момент смерти, а не отдавать поле.
- fire/attack-словари чистятся не только своими кластерами, но и `_refresh_weapon_runtime()`
  (2763-2770) при обновлении модели, и `command_attack` (1388-1391) сразу по четырём.

**Поэтому этап 0.5 (ниже) — обязательная таблица read/write-зависимостей до начала
этапов 5 и 7.** Иначе модули начнут ходить друг к другу через фасад — то самое, что этот
план запрещает в разделе про навигацию.

Кроме того, `CombatAttackOrder` как **один** общий модуль для `Unit` и `Building` —
скорее всего неверная граница: у них общий только захват цели
(`_automatic_target_for`/`_automatic_target_is_usable` — byte-identical), а драйверы
приказа расходятся принципиально (мобильный с преследованием и репасом vs статический с
popup-турелью). Разрез: `combat/combat_target_acquisition.gd` (общий) + разные
order-драйверы у каждого.

Таблица ниже **уже учитывает** четыре пересечения выше — это итоговый разрез, не
предварительный.

| Целевой модуль | Что уезжает | Собственные поля | Кэширует узлы модели |
|---|---|---|---|
| `units/unit_locomotion.gd` — **gait и анимация локомоции вместе**, потому что `_mech_locomotion_state` неделим (см. выше) | 602–772 (gait, XBF motion profile) + 2872–3158 (движение/idle-анимации) | `_uses_mech_gait`, `_mech_gait_elapsed`, `_mech_motion_profile`, `_mech_authored_average_speed`, `_mech_motion_cycle_seconds`, `_mech_start_remaining`, `_mech_locomotion_state`, `_stationary_repeats_remaining`, `_movement_animation_active` | да → нужен lifecycle-протокол |
| `units/unit_terrain_alignment.gd` | 784–896 (`_terrain_snap_body`, `_set_visual_slope_target`, `_advance_visual_slope_alignment`, `_slope_speed_multiplier`, `_turn_toward`) | `_visual_root_rest_basis`, `_visual_slope_target_basis`, `_last_terrain_normal` | нет |
| `units/unit_deploy_state.gd` | 2464–2614 | `_deploy_state`, `_deployment_aligning`, `_deployment_alignment_direction`, `_deployment_animation_player`, `_deployment_animation_name` | **да** (`_deployment_animation_player`) |
| `combat/combat_target_acquisition.gd` — **только захват цели**, общий с `Building` | 1641–1706 (`_automatic_target_for`, `_automatic_target_is_usable`, `_advance_auto_target_cooldowns`) ≡ `building.gd:1432-1488` | `_weapon_auto_targets`, `_weapon_auto_target_cooldowns` | нет |
| `units/unit_attack_order.gd` — **мобильный** драйвер приказа, свой; `Building` получает свой статический | 1363–1462 + 1465–1639 + 2285–2434 | `_has_attack_order`, `_attack_is_ground`, `_attack_ground_position`, `_attack_target_ref`, `_attack_is_pursuing`, `_attack_repath_remaining`, `_attack_last_path_position`, `_attack_pursuit_destination`, `_attack_pursuit_rejected`, `_issuing_attack_move` | нет |
| `units/unit_fire_overlay.gd` | 2758–2869 (синтез overlay-`AnimationPlayer` для стрельбы на ходу) | `_weapon_can_fire_while_moving`, `_weapon_fire_overlays` | **да** (сам создаёт узлы) |
| `units/unit_shader_fx.gd` | shield/scroll FX (`_ready` сбор + `_process` 284–291) | `_shield_meshes`, `_shield_time`, `_scroll_fx_meshes`, `_scroll_fx_time` | **да** |
| `units/unit_death_sequence.gd` | 999–1269 | `_death_strategy` | нет |

Остаётся на фасаде `Unit`, вопреки тому, что это выглядит извлекаемым:
- **`_on_animation_finished` (3161–3234)** — по двум независимым причинам: его
  переопределяет `Harvester` (`harvester.gd:829`), и он диспетчеризует пять подсистем.
  Становится точкой расширения: фасад по очереди спрашивает модули
  `on_animation_finished(name, player) -> bool` в текущем порядке.
- **`_set_movement_animation`** — тоже переопределён `Harvester` (`:820`).
- **`_previous_global_position` (`:187`)** — пишется фасадом (300), передаётся в
  death-модуль **значением** в момент смерти, полем ему не отдаётся.
- **`_weapon_fire_sequences`** — тесты пишут в него напрямую.

Хабы, которые **нельзя** двигать без аксессора (и которые определяют API фасада):
`_animation_players` (10 кластеров), `combat_turrets` (7), `unit_definition` (7),
`visual_root` (8). Для `_animation_players` фасад уже отдаёт узкий API наружу
(`flight_play_clip`, `flight_clip_length`, `unit.gd:435-464`) — именно эту форму и
расширять для новых модулей, а не открывать поле.

Ориентир по фасаду `unit.gd`: **~500 строк** (lifecycle, публичный API движения/боя,
forwarding-обёртки для white-box-тестов, ownership).

### Дедуп внутри `unit.gd`

- «первый `AnimationPlayer`, у которого есть клип X» — **8 почти одинаковых циклов**
  по `_animation_players`: 441–452, 458–464, 631–637 (**тело идентично 458–464**),
  1988–1991, 1998–2001, 2540–2545, 3014–3018, 3035–3041. Комментарий на `:455` уже это
  признаёт («Same lookup idiom as `_mech_move_cycle_duration()`»). Сводится к 3 функциям
  в shared `world/authored_model.gd`: `find_clip`, `clip_length`, `play_clip`.
- teardown fire-sequence скопирован 3 раза (1875–1891, 1903–1912, 1931–1937) — **вместе с
  одинаковым предупреждающим комментарием**. Один `_teardown_sequence(state)`.
- сброс attack-order скопирован 3 раза (1383–1391, 1408–1415, 1434–1444), по 9 полей.
  Один `_clear_attack_state()`.
- две разные кодировки одного понятия «цель = точка или weakref»: `_set_weapon_target`/
  `_weapon_target` (1721–1740) и `_encoded_target`/`_decoded_target` (1966–1979). Оставить
  одну.
- `_death_explosion_effect_ids` (1122–1133) — третья копия правила разрешения
  explosion-id (свой doc-коммент на `:1118` прямо говорит «Mirrors
  CombatBullet.explosion_effect_ids()», `combat_bullet.gd:93-104`); цикл-потребитель
  (1105–1115) — копия `combat_projectile.gd:775-786`. Плюс идиома
  «`X.new()` → `add_child` → `if not X.configure(...): X.free()`» повторена **4 раза**
  (`unit.gd:1112`, `combat_projectile.gd:770,782,808`). Один общий
  `combat/combat_effect_spawner.gd`.

### Хотспоты `unit.gd`

`_advance_attack_pursuit` 96 строк (2310–2405), `_advance_attack_order` 92 строки и
вложенность 5 (1465–1556), `_begin_death_sequence` 90 (1008–1097),
`_on_animation_finished` 74 (3161–3234), `_authored_fire_shot_times` 73 и **вложенность 6**
(2064–2136), `_prepare_model_for_corpse` 73 (1153–1225), `_physics_process` 61 (294–354).

`_on_animation_finished` — **диспетчер на 6 подсистем** (flight → fire sequence →
deployment → mech STARTING → STOPPING → TURNING → idle batch). Это одна точка, где
решаются стейтмашины пяти разных кластеров. После извлечения модулей она становится
рассылкой: каждый модуль получает `on_animation_finished(name, player) -> bool`
(«я обработал»), фасад проходит по ним в текущем порядке. Порядок обязан сохраниться —
он поведенчески значим.

## `combat_turret.gd` (2785 строк) — почти половина файла это FX

Кластеры B + M + N + O + P + Q + R (константы частиц 49–84 и весь блок 1376–2680) —
**~1341 строка, 48 % файла** — это визуальные эффекты: таймлайны твинов, billboard-частицы
(гильзы, дымы, jet-струи), чтение FX-банков XBF, загрузка текстур. Геймплей (конфиг,
привязка модели, серво наведения, точки эмиссии, перезарядка, баллистика, выстрел) —
~1150 строк.

12 из 31 поля — FX-only: `_fx_model_root`, `_rear_flash_textures`,
`_launch_smoke_textures`, `_model_fx_texture_cache`, `_muzzle_bank_particle_index`,
`_casing_particle_index`, `_casing_timeline_tween`, `_particle_timeline_tweens`,
`_stream_particle_index`, `_authored_fire_fx_active`, `_fx_random`, static
`_fx_texture_paths_by_lowercase`.

**Разрез:** `combat/turret/combat_turret_fx.gd` — модуль по форме
`unit_flight_controller.gd` (`RefCounted`, `configure(turret, model_root)`, не кэширует
узлы модели дольше жизни твина). `CombatTurret` сохраняет наружу
`start_authored_fire_fx`/`has_authored_fire_fx`/`cancel_authored_fire_fx` как обёртки —
`unit.gd:254`, `building.gd` и тесты не правятся.

Внутри FX-части — плотный дедуп (это и есть причина, почему её надо трогать, а не просто
перенести):
- «построить billboard-quad-частицу и прогнать по кадрам» — **3 почти идентичных
  функции**: `_emit_casing_particle` (2083–2173, 91 строка),
  `_emit_model_stream_particle` (1676–1792, 117 строк), `_emit_barrel_smoke_particle`
  (2310–2380, 71 строка). Закрывающий frame-tween в них **byte-identical**
  (2164–2173 / 1774–1783 / 2371–2380);
- три копии скелета «таймлайн твинов из XBF-расписания»: `_start_model_casing_timeline`
  (1415–1480), `_start_model_particle_timelines` (1487–1554), `_start_barrel_smoke_bank`
  (2241–2307);
- два построителя расписания из одного и того же потока start/stop-событий:
  `_fx_bank_schedule` (2052–2080) и `_stream_fx_bank_schedule` (1587–1619) +
  `_append_stream_schedule` (1622–1638); ядро (`first_particle_frame` / `particle_count`
  / цикл `append`) продублировано **третий раз инлайном** в `_start_barrel_smoke_bank`
  (2275–2282);
- `_spawn_launch_smoke` (2515–2531) ≡ `_spawn_rear_flash` (2574–2590) — 17 строк,
  различаются только именем узла, полем текстур и константой размера;
- `_update_casing_particle` (2176–2187) ≡ `_update_model_stream_particle` (1992–2004) ≡
  `_update_fx_bank_particle` (2464–2473) — три копии `start + v*t + 0.5*a*t²`;
- два построителя billboard-материала в одном файле (`_fx_quad` 2593–2607 и
  `_fx_bank_material` 2412–2430) + **третья копия в другом файле**
  (`combat_impact_effect.gd:363-370`);
- загрузка текстур: `_load_fx_texture_sequence` (2622–2638) vs
  `combat_impact_effect.gd:448-465` — тот же цикл и **тот же комментарий** про литеральный
  `%` в `!%Bru`/`!%shel`; `_opaque_additive_texture` (2659–2674) vs
  `combat_impact_effect.gd:467-481` — тела идентичны, различия только в подписи и
  комментарии; `_find_original_node` (2391–2399) ≡ `combat_impact_effect.gd:309-317`;
  `_set_fx_bank_frame` (2450–2461) ≡ `combat_impact_effect.gd:429-439`;
  `INLINE_FX_TEXTURE_DIR` объявлен в обоих.

Отсюда второй shared-модуль: **`combat/fx/authored_fx_bank.gd`** — чтение XBF FX-банков,
расписания, загрузка/кеш текстур, billboard-материал, одна параметризованная
billboard-частица (`spawn_frame_animated_quad(parent, bank, textures, ...)`), одна
интеграция движения. Им пользуются и `combat_turret_fx.gd`, и `combat_impact_effect.gd`.
Ожидаемый эффект: `combat_turret.gd` → ~1100 строк, `combat_turret_fx.gd` → ~450,
`authored_fx_bank.gd` → ~400, `combat_impact_effect.gd` → ~300.

### Перф-дефект в `combat_turret.gd`, который стоит починить здесь же

`CombatBulletScript.new(bullet_config, warhead_config, projectile_visual_scene,
impact_visual_scenes)` конструируется в **9 местах** (709, 752, 770, 816, 849, 883, 1287,
1569, 1581) без мемоизации. `can_target()` создаёт выбрасываемый bullet; `target_range()`
(763) создаёт **второй** сразу после вызова `can_target()`; `_desired_firing_direction()`
(1287) создаёт по одному **на каждую пробу ошибки наведения** — а
`_turn_yaw_toward`/`_turn_pitch_toward` (474, 522) делают по 5 проб каждый, то есть до
10 аллокаций на кадр на турель. **Но кешировать один `_bullet` на турель нельзя** — `CombatBullet` не immutable:
`damage_scale` (`combat_bullet.gd:21`) изменяемое поле, множитель `config.damage`
(`:37`), и каждый выпущенный снаряд несёт **свой** payload. Один общий объект означал бы,
что следующий выстрел меняет урон уже летящего снаряда.

Проверено по всем 9 сайтам — граница проходит ровно посередине:
- **`:849` — единственный сайт, который присваивает `payload.damage_scale = damage_scale`**
  (внутри цикла по `bullet_count`, результат уходит наружу как payload снаряда). Остаётся
  как есть: новый объект на каждый выстрел.
- **остальные 8 — read-only preview/definition-view, `damage_scale` не трогают вообще:**
  `maximum_range_world` (709), `can_target` (752), `target_range` (770),
  `has_line_of_fire_from` (816), `try_fire_at`-превью (883), `_desired_firing_direction`
  (1287), `is_continuous_bullet` (1569), `_continuous_jet_reach_world` (1581).

Значит кешируется **`_definition_bullet`** для этих 8 (инвалидация в `configure()`), а
per-shot payload — нет. Это снимает ровно тот хот-луп, из-за которого всё началось
(`_desired_firing_direction` × 5 проб `_turn_yaw_toward` × 5 проб `_turn_pitch_toward`), и
не трогает семантику урона.

Обязательный регрессионный тест (сейчас такого нет): два одновременно летящих выстрела с
разными `damage_scale` — урон каждого должен остаться своим. Без него эта оптимизация в
работу не берётся.

Строго говоря, корень в том, что `CombatBullet` смешивает две роли: неизменяемое
описание оружия и изменяемый payload одного выстрела. Правильный конечный вид — вынести
`damage_scale` в отдельный `ShotPayload`, после чего definition-часть станет immutable и
кешируемой целиком. Это отдельный коммит **после** кеша definition-view, не вместо него.

Там же: `combat_turret.gd:138` держит `var _definition_catalog := CombatDefinitionCatalogScript.new()`
**на экземпляр**, тогда как остальной код держит каталоги в `static var`
(`unit.gd:15`, `building.gd:12`) — то есть на каждую турель на карте свой каталог.

### Другие дедупы в `combat/`

- `_combat_entity` (подъём по `get_parent()` до узла с `combat_armour_type`) — **3 verbatim
  копии**: `combat_projectile.gd:956-962`, `combat_impact_resolver.gd:227-234`,
  `combat_line_of_fire.gd:70-77`.
- `_combat_target_position` (цепочка `combat_aim_position_from` → `combat_aim_position` →
  `global_position` → `Vector3.INF`) — **5 копий**: `unit.gd:2408`, `building.gd:1491`,
  `combat_turret.gd:965`, `combat_projectile.gd:985`, `combat_impact_resolver.gd:211`.
- проверка живости цели — **6 копий**: `unit.gd:2427`, `building.gd:1514`,
  `combat_turret.gd:987`, `combat_projectile.gd:1007`, `combat_impact_resolver.gd:195`,
  `combat_linger_effect.gd:91`.
- `_target_hit_radius` дважды (`combat_projectile.gd:1018`,
  `combat_impact_resolver.gd:221`), вместе с константами `DEFAULT_TARGET_HIT_RADIUS := 0.25`
  и `COMBAT_COLLISION_MASK := 3`, объявленными в обоих файлах.
- `20.0` обновлений в секунду живёт под **тремя именами**:
  `AIM_UPDATES_PER_SECOND` (`combat_turret.gd:19`), `RULE_UPDATES_PER_SECOND`
  (`combat_projectile.gd:28`), и снова в `combat_impact_effect.gd:10`.

→ `combat/combat_target.gd` (static): `entity_of(collider)`, `position_of(target, origin)`,
`is_alive(target)`, `hit_radius(target)`, `collision_rids(target)`. Плюс единственный
`combat/combat_rules.gd` с общими константами тиков/масок. Это ~150 строк на замену
~300 копипасты в 6 файлах.

### `combat_projectile.gd` (1045) и `combat_impact_effect.gd` (481)

- `launch()` — 103 строки, **7 параметров**, и он ветвится на `target_or_position is Object`
  **пять раз** (117, 131, 165–175) вместо одного, завершаясь 4-веточным диспатчем по виду
  снаряда (178–185). Разрешить тип цели один раз в начале.
- missile-trail (246–378, `ImmediateMesh`-лента) и laser-visual (847–923) — независимые
  визуальные кластеры со своими полями (`_missile_trail_*`) → `combat/fx/projectile_trail.gd`.
  Баллистический солвер (435–602) уже написан как `static func` — он готов к выносу в
  `combat/ballistics.gd` без изменений.
- в `_advance_trajectory` (589–596) и `_advance_direct` (624–629) четвёрка
  `_handle_collisions` / `_fallback_target_collision` / `global_position = to` /
  `_face_direction` повторена дословно.
- `combat_impact_effect.gd` содержит **27 констант, 21 из которых** — `SHELL_HIT_*` /
  `MISSILE_HIT_*`, то есть два эффекта захардкожены в общий класс, и `configure()` (53)
  ветвится по их id. Плюс флаг `_start_shell_hit_fx(shrapnel_ring: bool = false)` (151),
  переключающий один эффект в другой. Это два подкласса (или две записи данных), а не
  ветки.

### Флаговые параметры (переработка сигнатур)

- `combat_turret.try_fire_at(...)` — 5 параметров-флагов со значениями по умолчанию, 7
  последовательных early-return guard'ов до первой полезной работы, и вызывается
  позиционно: `unit.gd:1838` передаёт `null, Vector3.ZERO, false, false, true, damage_scale`.
  Прочитать такой вызов на месте невозможно. Заменить на `FireRequest`-DTO
  (форма `building_order.gd`).
- `_launch_jet_particle` — **15 позиционных параметров** (`combat_turret.gd:1808-1824`).
- `_advance_turret_engagement(..., aimed_override: Variant = null)` (`unit.gd:1589`) —
  трёхзначный `Variant` в роли nullable bool.
- `_cancel_all_fire_sequences(restore_idle := true)` / `_cancel_fire_sequence(restore_idle := true)`
  (`unit.gd:1898`, `:1858`), при этом `_finish_fire_sequence()` (1852) и
  `_clear_fire_sequence()` (1866) существуют только как обёртки-арности.

## `buildings/*`

### `building.gd` (1944 строки, 142 функции, 51 поле)

Проверенная карта даёт 19 кластеров ответственности; после сведения тех, что связаны общим
состоянием (popup + боевой драйвер), получается следующий итоговый разрез:

| Целевой модуль | Что уезжает (текущие строки) | Собственные поля | Кэширует узлы модели |
|---|---|---|---|
| `buildings/building_rally_point.gd` | 242–297, 360–467 (rally point + `ImmediateMesh` линия и маркер) | `_rally_point_line`, `_rally_point_line_mesh`, `_rally_point_line_material`, `_rally_point_marker`, `_has_rally_point`, `_rally_point_is_default` | **да** (сам создаёт узлы) |
| `buildings/building_refinery_docks.gd` | 881–1075 (резервации, кулдауны, геометрия пэдов, анимация) | `_refinery_dock_users`, `_refinery_dock_cooldowns` | нет |
| `buildings/building_wall_visual.gd` | 649–819 (connectivity + выбор варианта модели) | `_wall_connection_mask`, `_wall_topology`, `_wall_rotation_quarters` | нет |
| `buildings/building_combat.gd` — **popup-турель и боевой драйвер вместе**: `_advance_building_combat` читает `_popup_turret_state` и выходит раньше времени на `DEPLOYING`/`UNDEPLOYING` (`building.gd:1395-1400`), то есть состояние неделимо | 1302–1366 (attack-order) + 1368–1539 (боевой драйвер) + 1631–1759 (стейтмашина popup) | `_has_attack_order`, `_attack_is_ground`, `_attack_ground_position`, `_attack_target_ref`, `_automatic_target_ref`, `_automatic_target_cooldown`, `_popup_turret_state`, `_popup_transition_player`, `_popup_transition_animation`, `_popup_transition_elapsed`, `_popup_transition_duration` | **да** (`_popup_transition_player`) |
| `combat/combat_hull.gd` | 1154–1256 (`combat_aim_position_from`, `_nearest_combat_hull_point`, `combat_hull`, `combat_contains_impact_position`) | `_combat_hull`, `_combat_hull_minimum_y`, `_combat_hull_maximum_y` | нет |
| `world/authored_model.gd` (shared) | 498–620 (сборка authored-коллизии) | — | нет (статический) |
| `world/team_color.gd` + `ui/selection_halo_binding.gd` (shared) | 1781–1813, 1816–1922 | `_selection_halo`, `_repair_effect` | **да** |

Захват цели (`building.gd:1432-1488`) уезжает не в `building_combat.gd`, а в общий
`combat/combat_target_acquisition.gd` — это единственная часть, реально совпадающая с
`Unit` byte-in-byte.

Остаётся на фасаде `Building`: lifecycle/`_process`, `setup`/construction, damage/death,
power, definition application, а также:
- **turret-фасад** (`aim_turrets_at`, `turret_emission_points`, `next_turret_emission`,
  `fire_weapon_at`, `_combat_turret_for_weapon` — 1258–1290). Он идентичен
  `unit.gd:1297-1345`, но это **5 однострочных делегаций в `combat_turrets`**: выносить их
  в общий модуль значит добавить хоп ради экономии ~30 строк и завести ровно тот проброс,
  который этот план запрещает в разделе про навигацию. Дедуп здесь не окупается —
  оставляем как есть, осознанно.
- **`_authored_fire_controller`** (поле 164) — единственное реально cross-cutting поле
  (16 обращений из шести мест).

Ориентир по фасаду: **~450 строк**.

**Найденные дефекты, которые фиксируются по ходу (каждый — отдельный коммит, не смешивать
с распилом):**
- `building.gd:605 _mesh_instances(node)` — **мёртвый код**: единственная ссылка на него
  строка 610, то есть он вызывает только сам себя. Удалить.
- `building.gd:226` и `:229` — `_restore_popup_hold_pose()` вызывается в `_process` **дважды**
  вокруг `_advance_building_combat`/`_authored_fire_controller.advance`. Либо это
  осознанный порядок (тогда нужен коммент — сейчас его нет), либо остаток. Проверить и
  зафиксировать.
- `building.gd:1784` возвращает нейтральный цвет `Color(0.58, 0.58, 0.58)`, а
  `unit.gd:3280` — `Color(0.2, 0.85, 1.0)`. При выносе в `team_color.gd` это **не** надо
  «унифицировать»: разные значения, скорее всего, намеренные (серое здание vs голубой
  юнит), поэтому цвет становится параметром, а не константой модуля. Иначе рефакторинг
  тихо поменяет картинку.
- `_collect_collision_sources` идентичен в `building.gd:558` и `unit.gd:3318`, но
  **приоритет источников инвертирован**: building ищет `slct` → fallback `#~~0`
  (`building.gd:550`), unit — `#~~0` → fallback `slct` (`unit.gd:3310`). Общий модуль
  должен принимать порядок префиксов списком, а не хардкодить его.
- `COLLISION_OBJECT_NAME := "#~~0"` объявлен дважды (`building.gd:32`, `unit.gd:26`);
  `RULE_COMBAT_TICKS_PER_SECOND := 25.0` и `AUTO_TARGET_REFRESH_SECONDS := 0.25` — тоже
  (`building.gd:39,40` / `unit.gd:45,85`).

### `building_queue.gd` ≡ `upgrade_queue.gd` — 90 строк, различие в одну строку

Проверено `diff`: `building_queue.gd:38-127` и `upgrade_queue.gd:55-144` различаются
**ровно одной строкой** — типом возврата `take_ready()` (`BuildingOrder` vs
`UpgradeOrder`). Аналогично `building_order.gd:4-22` ≡ `upgrade_order.gd:14-34`.
`upgrade_queue.gd:4-10` документирует это как «намеренную параллельную копию» — но
намеренность не отменяет того, что любой фикс в тике надо вносить дважды.

### Контракт `ProductionQueue` (определить до реализации)

Наивная композиция здесь **не работает**, и это важно зафиксировать заранее: если
`BuildingQueue` держит внутренний `ProductionQueue`, который сам конструирует и эмитит
`ProductionOrder`, то `order as BuildingOrder` даст **`null`** — это два несвязанных класса.

Проверено, что тик очереди читает и пишет **ровно 7 полей** заказа
(`_order.ready`, `.manually_paused`, `.cost`, `.paid_cost`, `.build_time_ticks`,
`.elapsed_ticks`, `.charge_accumulator`) и **не трогает** ни `building_id`/`upgrade_id`, ни
`display_name`, ни `kind`/`target_refinery`. То есть очереди не нужен свой тип заказа вообще.

**Канонический объект — типизированный заказ wrapper'а** (`BuildingOrder` / `UpgradeOrder`).
`ProductionQueue` никогда его не конструирует и не оборачивает: он получает готовый объект и
мутирует эти 7 полей на месте, по duck typing. Значит из очереди выходит **тот же
экземпляр**, что в неё вошёл, и приведение типа перестаёт быть проблемой — приводить нечего.

```gdscript
# production_queue.gd — знает про 7 полей, не знает ни одного типа заказа
signal order_ready(order)                       # untyped: тип принадлежит wrapper'у
func adopt(order) -> bool                       # НЕ создаёт заказ, принимает готовый
func tick(delta, credits, spend := Callable()) -> bool
```
```gdscript
# building_queue.gd — конструирование заказа остаётся здесь
signal order_ready(order: BuildingOrder)        # свой сигнал, типизированный

var _queue := ProductionQueueScript.new()

func _init() -> void:
    # Ретрансляция обязательна: подписчики висят на ВНЕШНЕМ order_ready
    # (building_controller.gd:100-101, upgrade_run.gd:205, run.gd:173).
    # Каст безопасен: это тот же объект, который мы сами и создали в start().
    _queue.order_ready.connect(func(order): order_ready.emit(order as BuildingOrder))

func start(building_id, display_name, cost, build_time_ticks) -> bool:
    var order := BuildingOrderScript.new()
    order.building_id = building_id            # поля, которых очередь не касается
    order.display_name = display_name
    order.cost = cost
    order.build_time_ticks = build_time_ticks
    return _queue.adopt(order)

func take_ready() -> BuildingOrder: return _queue.take_ready() as BuildingOrder
```

Следствие: **общий класс `ProductionOrder` не нужен** — ни как базовый, ни как поле. Из
двух классов заказов извлекается только `progress_percent()` (8 строк, идентичны в
`building_order.gd:16-23` и `upgrade_order.gd:27-34`) — одна `static func` в
`buildings/production_progress.gd`. Вопрос «наследование или композиция для заказов» просто
снимается: остаются два независимых DTO, как сейчас.

**Ретрансляция сигнала — требование, защищённое тестом.** `order_ready` объявлен на обеих
очередях (`building_queue.gd:4`, `upgrade_queue.gd:12`), подписчики —
`building_controller.gd:100-101` и `building_upgrade_controller.gd:50-51`, а
`tests/buildings/upgrade_run.gd:47` — сценарий с буквальным названием «order_ready fires
exactly once per completed order» (`:202-211`), плюс `run.gd:173` считает события. И
«сигнал не дошёл», и «сигнал пришёл дважды» падают на существующих тестах. Эмитить обязан
**только внешний** wrapper, ровно один раз.

Публичные имена и сигналы не меняются, `building_controller.gd` и
`building_upgrade_controller.gd` не правятся вообще.

### `building_controller.gd` (1286 строк) — извлечения

| Целевой модуль | Что уезжает | Собственные поля |
|---|---|---|
| `buildings/building_repair_service.gd` | 303–377 | `_repair_credit_carry`, `_repair_tick_elapsed` |
| `buildings/building_sale_service.gd` | 456–512, 570–599 | `_selling_building` |
| `buildings/wall_line_session.gd` | 380–453, 859–1045 | `_wall_line_*`, `_wall_markers`, `_wall_marker_scene`, `_wall_chain` |
| `buildings/building_catalog_view.gd` | 1101–1252 (конфиги, occupy-rows, scene-path, availability, tooltip/option-state) | `_building_configs`, `_building_availability`, `_building_ids` |
| `buildings/placement_pointer_gesture.gd` | 132–251 pointer-часть | `_placement_pointer_down`, `_placement_press_position`, `_placement_rotated_during_press` |

Плюс дедупы **внутри** контроллера:
- `building.get("building_config")` → fallback на каталог — **5 копий** (361, 595, 620,
  1114, 1121). Один хелпер `_config_of(building)`.
- gate «клик по своему зданию» — 4 копии (310, 467, 609 инлайном + `_can_sell_building:547`).
  Один предикат.
- тройка `_wall_chain = null; _clear_wall_markers(); _refresh_building_option_states()` —
  **7 копий** (927, 941, 954, 982, 1013, 1021, 1034). Один `_end_wall_session()`.
- `_play_building_state` — **3 копии** (`building_controller.gd:1091`,
  `building_placement.gd:932`, инлайн в `unit_deployment_controller.gd:258-266`) →
  в shared `world/authored_model.gd`.
- «проиграть one-shot клип, `loop_mode = LOOP_NONE`, подключить `animation_finished`
  с `CONNECT_ONE_SHOT`» — 4 копии (`building_placement.gd:890`,
  `building_controller.gd:479`, `:489`, `unit_deployment_controller.gd:258`) → один
  хелпер `authored_model.play_one_shot(root, clip, on_finished)`.
- три взаимоисключающих флага режима `_sell_mode`/`_repair_mode`/`_wall_line_mode`
  (49, 50, 58): каждый сеттер обязан гасить два других (258-261, 273-277, 292-297).
  Заменить на `enum Mode { NONE, SELL, REPAIR, WALL_LINE }` — снимает целый класс
  «забыли погасить».

**Перф-дефект, который стоит починить в этом же проходе:** `process()` (112) каждый кадр
делает O(все building_id × все здания в группе) опрос: `_is_building_available` (1176)
вызывает `get_tree().get_nodes_in_group("buildings")` **на каждый id**, а
`_refresh_building_option_states()` вызывается **внутри** цикла (118). Это тот же класс
проблемы, что чинился в навигации: заменить на event-driven инвалидацию + пересчёт по
флагу dirty.

**Но список событий должен быть полным, иначе получим тихо неверный UI** — доступность
зависит не только от появления/исчезновения здания:

| Причина изменения доступности | Источник |
|---|---|
| здание построено | `building_placement.building_placed` |
| здание уничтожено/продано | `tree_exiting` каждого здания |
| **захват** (сменился владелец) | `Building.owner_changed` — **уже есть** (`building.gd:16`), эмитится в сеттере (`:87`) |
| **достройка** (`is_construction_complete`) | `Building.construction_completed` — **уже есть** (`building.gd:20`), эмитится в `finish_construction()` (`:1101`) |
| **изменение `upgrade_level`** | `set_upgrade_level` (`building.gd:873+`), `upgrade_effects.gd` — **единственное, для чего нужен новый сигнал** |
| здание добавлено **не** через `BuildingPlacement` | deploy MCV→ConYard, restore снапшота, стартовая расстановка `match._place_on_map` |

Последняя строка — причина, по которой одной подписки на `building_placed` заведомо
недостаточно: `unit_deployment_controller._on_building_placed` и
`match_snapshot._restore_entities` создают здания своим путём. Поэтому базой остаётся
подписка на `SceneTree.node_added`/`node_removed`, а поверх неё — per-building подписки на
`owner_changed`/`construction_completed`/upgrade.

**Ловушка в `node_added`:** фильтровать по группе `buildings` **сразу в обработчике нельзя** —
`Building` добавляет себя в группу только в `_ready()` (`building.gd:173`), а `node_added`
приходит раньше. То есть наивный `if not node.is_in_group("buildings"): return` молча
пропустит каждое здание. Варианты: проверка через `call_deferred` (тогда `_ready()` уже
прошёл), либо перенести `add_to_group("buildings")` в `_enter_tree()`. Второе чище, но
меняет момент появления в группе для всех, кто её опрашивает (28 сайтов
`get_nodes_in_group`) — поэтому по умолчанию deferred, а перенос в `_enter_tree` — только
если найдётся отдельная причина.

**И тест на каждый переход** — сейчас `controller_run.gd` проверяет доступность только для
статически расставленных зданий, ни один из шести переходов выше не покрыт. Этот пункт
без тестов не берётся: заменить поллинг на события — ровно тот рефакторинг, который ломает
UI бесшумно.

### `building_placement.gd` (938 строк)

- `_rebuild_preview_for_anchors` (328–412) — **85 строк**, вложенность до **7 уровней**
  (`for anchor` → `for row` → `for column` → `if` → `if` → аргументы `_create_preview_cell`
  на 391). Извлечь тело внутреннего цикла в `_preview_cell_for(anchor, row, column)`.
- координатная математика occupy↔nav (705–775) + статический кеш занятых клеток
  (778–844) → `buildings/occupy_grid.gd`. Формула `occupy cell → local offset`
  продублирована в `building.gd:292-297` и `:959-963`; вычисление ширины
  `maxi(width, row.length())` — **6 копий** (`building_footprint.gd:112`,
  `building_placement.gd:586`, `:717`, `building.gd:291`, `:344`, `:954`); предикат
  «пустой occupy-маркер» — 3 verbatim копии (`building_placement.gd:856`,
  `building_footprint.gd:124`, `navigation/shared/nav_blocker_tracker.gd:160`). Всё это —
  один модуль.
- материалы превью/стрелки (597–702) → `buildings/placement_materials.gd`. Там же
  `_is_fully_transparent_albedo_material` (636–639) сканирует изображение **пиксель за
  пикселем** на каждую поверхность — вынести с кешем по `Texture2D.get_rid()`.
- **`static var` + глобальные подписки:** `_occupied_cells_cache`,
  `_occupied_cells_cache_valid`, `_occupied_cells_tracking_started` (60–62) —
  разделяемое мутабельное состояние между всеми экземплярами `BuildingPlacement`, плюс
  подписки на `SceneTree.node_added`/`node_removed` (821), которые **никогда не
  отключаются**. В headless-тестах, где сцена пересоздаётся, это источник утечки и
  межтестовой связности. Перевести в поле экземпляра, отключать в `_exit_tree()`.
- `setup()` на **11 позиционных параметров** (65–77), `building_controller.setup()` — на 9
  (70–80), из них 4 — `Callable`-провайдеры, каждый с `.is_null()`-проверкой в каждой
  точке использования (334, 460, 465, 470, 806). Заменить на один типизированный
  `PlacementContext` (`RefCounted`-DTO): сцены, камера, грид, провайдеры. Снимает и
  позиционность, и разбросанные guard'ы.

### `building_upgrade_controller.gd` (515)

Четыре обработчика слотов (122, 145, 168, 185) различаются **только** предикатом вида
заказа; выбор строки статуса скопирован 4 раза (136, 160) и ещё дважды в
`building_controller.gd` (721, 745). Лестница `DISABLED / BLOCKED if order != null else
AVAILABLE` — 4 копии (`building_upgrade_controller.gd:433-436`, `:457-460`,
`building_controller.gd:1203`, `:1208`). Свести к параметризованной паре
`_on_slot_pressed(kind, id)` + общий `option_state_for(...)`.

### Прочее по `buildings/`

- `wall_connectivity.gd` кодирует **одну** таксономию топологий **тремя** параллельными
  способами: `_CANONICAL_MASKS` dict (19–27), `match count` (48–60), `match topology`
  (81–93). Свести к одной таблице данных.
- `BuildingDefinitionCatalogScript.new()` создаётся **5 раз** независимо (`building.gd:12`
  static, `building_controller.gd:43`, `building_upgrade_controller.gd:45`,
  `technology_tree.gd:19`, `building_survivors.gd:12` static) — 5 копий кеша определений
  в памяти. Один `static var` в самом каталоге.
- `technology_tree.gd:110-115` — две ветки `if config is X` / `if config is Y` с
  **идентичными** телами. Свернуть.
- «Dictionary как запись» вместо типа: `{"node","scene"}`
  (`building_placement.gd:430`), `{"cells","bounds","is_wall"}` (:475-479),
  `{"topology","rotation_quarters"}` (`wall_connectivity.gd:36`), `{"player","name"}`
  (`unit.gd:2540`). Для тех, что живут дольше одного вызова, — маленькие `RefCounted`-DTO
  (конвенция C: `building_order.gd`).

### Какую конвенцию использовать для каких извлечений

В `buildings/` уже сложились 5 разных форм модулей. Не надо изобретать шестую — надо
выбрать по характеру состояния:

- **stateless-математика** (occupy-grid, wall-геометрия, terrain probe) → форма
  `wall_line.gd`/`wall_connectivity.gd`/`building_footprint.gd`: только `static func`,
  владелец передаётся параметром и не хранится;
- **подсистема с собственным состоянием, но без знания о владельце** (production queue,
  repair service) → форма `building_queue.gd`: `RefCounted` + свои `signal`,
  возможности владельца инжектируются **per-call** как `Callable`, мутаторы возвращают
  `bool` «изменилось»;
- **подсистема, которой нужен доступ к узлам модели владельца** (rally point, popup
  turret, refinery docks, attack order) → форма `unit_flight_controller.gd`:
  `RefCounted` + `configure(owner, definition)`, `var _owner` без типа, **никогда не
  кэширует узлы модели**;
- **сессия с курсором** (wall chain) → форма `wall_chain.gd`: `_init(...)` +
  `advance() -> bool`, владелец выбрасывает объект по завершении;
- **значение** → форма `building_order.gd`.

---

## Важно: чего именно НЕ надо повторять из навигационного рефакторинга

Навигация — принятый в репозитории образец распила, и по расположению файлов
(`shared/`, `ground/`, `air/`) и по форме модулей его и надо держать. Но у результата есть
дефект, который нельзя тиражировать: **фасад получился круговым**.

Проверено:
- `unit_navigation_system.gd:637-966` — **50 функций, почти все вида
  `return <delegate>.<то_же_имя>(...)`**, ~330 строк чистого проброса (треть файла);
- модули обращаются к **приватным** членам фасада: `grep -c "_facade\._"` по
  `navigation/` → **57** обращений (`ground_path_follower.gd:291,292,297` →
  `_facade._parking_anchor`/`_block_stoppable`/`_route_agent`; `nav_blocker_tracker.gd:63,127,154`
  → `_facade._agents[...]`; `:72-73,118-123` → `_facade._reroute_queue`);
- `path_funnel.gd:125` идёт через фасад к **соседнему** модулю:
  `_facade.path_follower.agent_cell_passable(...)`;
- модули читают константы фасада **по bare global name** —
  `nav_spatial_hash.gd:18,21,30,31` и `nav_blocker_tracker.gd:31,35,121` используют
  `UnitNavigationSystem.CELL_BUCKET_SIZE`, `UnitNavigationSystem._building_definition_catalog`,
  `UnitNavigationSystem.BuildingFootprintScript`. Это **прямое нарушение правила из
  `AGENTS.MD`** («Prefer explicit `const XScript := preload(...)` over a bare reference to
  another script's `class_name`»), причём именно того рода, который там описан как уже
  однажды выстрелившийся;
- в `unit_navigation_system.gd` есть поля и константы, не нужные ему самому и живущие
  только ради этих обращений: `_reroute_queue` (81) не используется в файле нигде,
  `static var _building_definition_catalog` (21) и `const BuildingFootprintScript` (19) —
  тоже;
- часть обёрток вообще ни кем не вызывается извне файла (`_path_look_ahead_distance` 687,
  `_yield_direction` 720, `_is_en_route` 728, `_assign_route_lanes` 737, `_approach_anchor` 787,
  `_claim_anchor` 795, `_ring_offsets` 841, `_formation_offset` 849, `_bucket_key` 861,
  `_simplify_path` 419).

Причина понятна и уважительна: тесты (`tests/navigation/run.gd`, 2391 строка, 49 сценариев)
дёргают приватные члены фасада, поэтому обёртки пришлось оставить. Но обёртки были
задуманы как временный слой совместимости, а модули стали через них **общаться друг с
другом** — и получилось хуже, чем до распила: те же зависимости, плюс лишний хоп, плюс
нарушенное правило preload.

**Правила для наших извлечений, прямо следующие из этого:**
1. модуль **никогда** не обращается к `_owner._private` — только к публичному API,
   которое владелец добавил специально для него (форма `flight_play_clip`);
2. модуль **никогда** не ходит к соседнему модулю через владельца; если двум модулям нужен
   общий кусок — это третий, shared-модуль, а не проброс;
3. константы и каталоги — через `const XScript := preload(...)` в самом модуле, не через
   `OwnerClass.CONST`;
4. forwarding-обёртка для white-box-теста допустима, но помечается комментарием
   «существует только для `tests/...`», чтобы её нельзя было принять за часть архитектуры;
5. если после извлечения владелец состоит преимущественно из пробросов — извлечение
   выбрано по неверной границе. Признак правильной границы: у модуля **свои** поля
   (см. таблицы выше) и **мало** обращений назад.

### Это входит в объём (этап 2), и вот почему

Соблазнительно оставить навигацию как есть — она только что переработана. Но:
1. это **образец**, по которому будут писаться все новые модули из этого плана; оставив
   круговой фасад, мы гарантированно получим ещё восемь таких же в `unit.gd`;
2. вопреки виду, это **самый защищённый тестами** участок репозитория
   (`tests/navigation/run.gd` — 2391 строка, 49 сценариев), то есть чинить его безопаснее,
   чем `unit.gd`;
3. правка почти целиком механическая и **измеримая**.

Проверено `grep` по `tests/`: из приватных членов фасада тесты называют по имени ровно
**12**: `_agents`, `_navigation_tick`, `_navigation_tick_index`, `_physics_process`,
`_desired_velocity`, `_has_clear_line`, `_path_chord_is_clear`, `_request_yield`,
`_parking_anchor`, `_blocks_conflict`, `_refresh_building_blockers`,
`_replan_after_map_change`. Значит из **50** обёрток блока 637–966 обязаны выжить
**~9** (как явно помеченные test-only шимы), а **~41 удаляется** — как только модули
перестанут ходить друг к другу через фасад.

**Как чинить (по одному коммиту на пункт, сьют зелёный после каждого):**
1. `shared/nav_constants.gd` — вынести туда `CELL_BUCKET_SIZE`, `SWAP_COOLDOWN_TICKS`,
   `ROUTE_LANE_COMFORT_RADIUS_FACTOR`, `OCCUPY_CELL_SPAN`, `REROUTE_BUDGET_PER_TICK`;
   модули подключают его через `const NavConstantsScript := preload(...)`. Убирает все
   bare-`UnitNavigationSystem.X` (`nav_spatial_hash.gd:18,21,30,31`,
   `nav_blocker_tracker.gd:121`) и приводит код в соответствие с `AGENTS.MD`.
2. Перенести `static var _building_definition_catalog` и `const BuildingFootprintScript`
   из фасада (`unit_navigation_system.gd:19-21`, где они **не используются**) в
   `nav_blocker_tracker.gd`, который их и вызывает (`:31,35`).
3. Перенести `_reroute_queue` (`unit_navigation_system.gd:81` — **в файле не используется
   вообще**) в `nav_blocker_tracker.gd`, единственного владельца (`:72-73,118-127`).
4. Явное связывание вместо `_facade.<sibling>`: `path_funnel.setup(path_follower)` вместо
   `_facade.path_follower.agent_cell_passable(...)` (`path_funnel.gd:125`); так же для
   `ground_navigation` → `path_follower`, `ground_slot_allocator` → `path_follower`,
   `nav_blocker_tracker` → `slot_allocator` (`:92,132-141` сейчас зовёт обёртки фасада
   вместо аллокатора напрямую).
5. `_agents` остаётся полем фасада (тесты читают его в 24 местах) и **передаётся
   параметром** — это уже задокументированная конвенция самого проекта
   (`nav_agent_registry.gd:5-7`), просто не применённая к `nav_blocker_tracker.gd:63,127,154`.
6. Удалить обёртки без внешних вызывающих: `_path_look_ahead_distance` (687),
   `_yield_direction` (720), `_is_en_route` (728), `_assign_route_lanes` (737),
   `_approach_anchor` (787), `_claim_anchor` (795), `_claim_passable_anchor` (801),
   `_ring_offsets` (841), `_formation_offset` (849), `_bucket_key` (861),
   `_simplify_path` (419) — и остальные из 41, после того как пункты 1–5 их осиротят.
7. Оставшиеся 9 обёрток снабдить комментарием
   `## Test-only shim: tests/navigation/run.gd calls this by name. Not architecture.`
8. `unit_navigation_system._cell_ring` (504) → `GroundSlotAllocator.ring_offsets` (470),
   которая уже это делает.

Ожидаемо: `unit_navigation_system.gd` 1006 → ~550 строк, 57 обращений к
`_facade._private` → 0.

## Как не повторить это в будущем: автоматическая проверка

Сейчас в проекте **нет ни линтера, ни настроенных предупреждений** — проверено:
`project.godot` не содержит секции `debug/gdscript/warnings/*`, `.gdlintrc`/
`.pre-commit-config.yaml` отсутствуют, `gdtoolkit` не установлен. Ни одно из нарушений
выше не могло быть поймано ничем, кроме ревью.

Три уровня, по возрастанию цены:

**1. Родные предупреждения GDScript (бесплатно, сегодня же).** В `project.godot` включить
`debug/gdscript/warnings/enable=true` и поднять до ошибок (`=2`) то, что здесь реально
болит и не даёт ложных срабатываний:
- `unused_private_class_variable` — поймал бы неиспользуемые `_reroute_queue` и
  `_building_definition_catalog` в навигационном фасаде. **Мёртвый `_mesh_instances`
  (`building.gd:605`) он не поймает** — это метод, а не переменная; неиспользуемых
  приватных *методов* GDScript не диагностирует вообще, такие случаи ловятся только
  grep'ом (и он в чеклисте этапа 5);
- `unused_parameter`, `unused_variable`, `unused_signal`, `unused_local_constant`;
- `return_value_discarded`, `static_called_on_instance`, `shadowed_variable`.

Чего **не** включать: `unsafe_method_access`/`unsafe_property_access`/`untyped_declaration`.
Дак-тайпинг здесь — сознательный интерфейс между боем и сущностями
(`has_method("combat_armour_type")` и т. п.), а `var _unit` без типа — сознательный обход
циклического preload. Эти предупреждения дали бы сотни ложных срабатываний и были бы
отключены на следующий день.

**2. `gdlint` из `gdtoolkit` (внешний, ставится в контейнер).** Умеет то, чего Godot не
умеет: конфигурируемые лимиты размера и сложности — число аргументов функции, число
публичных методов класса, длина функции/файла/строки, соглашения об именах. Именно эти
проверки поймали бы `_launch_jet_particle` с **15** параметрами
(`combat_turret.gd:1808`), `building_placement.setup()` с **11**, `try_fire_at` с 5
флагами, и `unit.gd` на 3484 строки — то есть ровно то, что мы сейчас чиним руками.
Точный список проверок и их пороги — `gdlint --dump-default-config`. Начать с порогов,
которые проходит текущий код после рефакторинга, чтобы линтер не был красным с первого дня.

Конкретика по установке (сейчас её негде взять — проверено): `Containerfile` — это
`debian:bookworm-slim` + скачанный бинарь Godot, **в нём нет ни `python3`, ни `pip`**.
Поэтому: добавить в `apt-get install` пакеты `python3` и `python3-venv`, затем **создать
venv и поставить в него**:

```dockerfile
RUN python3 -m venv /opt/gdtoolkit \
    && /opt/gdtoolkit/bin/pip install --no-cache-dir "gdtoolkit==<pinned>"
ENV PATH="/opt/gdtoolkit/bin:${PATH}"
```

Именно venv, а не системный `pip3 install`: на Bookworm системный Python помечен
PEP 668 как externally-managed, и `pip3 install` там упадёт (обходить через
`--break-system-packages` в образе, который потом собирают все, — плохая идея). Версию
закрепить обязательно, иначе пороги линтера поедут при следующей сборке образа.

Плюс `.gdlintrc` в корень репо и подкоманда `lint` в `tools/godot-container` рядом с
существующей `check` (`tools/godot-container:110-111`), чтобы `make lint` шёл тем же путём,
что и всё остальное.

**3. Проектная проверка архитектурных правил (главное — и её нет ни в одном линтере).**
Правила «модуль не трогает `_owner._private`» и «нет bare-ссылок на `class_name` другого
скрипта» специфичны для этого репозитория, их не выразить ни в `gdlint`, ни в
предупреждениях Godot. Но они выражаются grep'ом на 20 строк — `tools/check_architecture.sh`,
падающий с ненулевым кодом:

```bash
# 1. Модуль не обращается к приватным членам владельца.
grep -rn '_facade\._\|_owner\._\|_unit\._\|_source\._' scripts/ && fail
# 2. Нет bare-ссылок на class_name другого скрипта (AGENTS.MD, Code Rules).
#    Список class_name собирается из scripts/, затем ищутся вхождения "Name." в
#    файлах, где нет соответствующего preload.
# 3. Автолоады не резолвятся по пути.
grep -rn 'get_node_or_null("/root/' scripts/ | grep -v autoload_lookup.gd && fail
```

Пункт 1 в его нынешнем виде **сразу поймал бы все 57 обращений**. Пункт 3 — 12 сайтов из
этапа 1. Добавить вызов в `make godot-test` (или в отдельный `make lint`, который
`godot-test` дёргает первым — так же, как он уже дёргает `unit-definitions-check`).

**Важно: после этапа 2 этот чек всё равно останется красным.** Этап 2 убирает только
`_facade._*`, а `unit_flight_controller.gd` обращается к приватным членам `Unit`
**8 раз** (проверено): `_unit._set_movement_animation` (131, 239),
`_unit._terrain_snap_body` (204, 238), `_unit._set_visual_slope_target` (225, 256),
`_unit._terrain_hit_at` (331, 338). Он лежит в `scripts/units/navigation/`, то есть под тем
же исключением — и это ирония: именно он в своём doc-комменте формулирует правило, которое
сам нарушает.

Значит перед снятием исключения нужно **также** довести flight controller до заявленного
`flight_*` API: добавить на `Unit` публичные `flight_snap_to_terrain()`,
`flight_set_upright()`, `flight_terrain_hit_at(position)`, `flight_set_moving(bool)` —
четыре обёртки, механически. Это входит в определение готовности этапа 2.

Технические требования к самому чеку, иначе он быстро обрастёт случайными исключениями:
- грепать по коду **без комментариев и строковых литералов** (иначе doc-комменты вида
  «`_facade._parking_anchor`» дают ложные срабатывания — а они здесь есть);
- покрыть fixture-тестами: файл-образец с нарушением обязан ронять чек, файл-образец без —
  проходить. Проверка без тестов на саму проверку — это то, чему нельзя доверять при
  массовой правке;
- исключения — только явным списком в самом скрипте, с обязательным `# TODO(этап N)` и
  причиной; безымянных исключений не заводить.

**Почему именно так, а не «договоримся на ревью»:** оба нарушения выше — не небрежность.
Круговой фасад появился как временный слой совместимости с тестами, а bare-`class_name` —
это ровно тот случай, который `AGENTS.MD` уже описывает как однажды выстреливший, с
объяснением почему. Правило, записанное в документ и однажды нарушенное автором самого
документа, — это правило, которому нужна машина, а не ещё один абзац.

---

## `match/`, `units/harvester.gd`, `ui/`, `map_spice_layer.gd`

Здесь распил менее срочен (файлы 400–900 строк), но есть три дешёвых и ценных дедупа.

### Автолоады резолвятся по пути вместо имени

`Players` и `Cursors` объявлены автолоадами (`project.godot:23-24`), то есть доступны как
глобальные имена. При этом `get_node_or_null("/root/Players")` написан в **9 файлах**
(`unit.gd:3287`, `building.gd:1928`, `building_controller.gd:1274`,
`building_upgrade_controller.gd:508`, `unit_roster_controller.gd:216,428`,
`unit_deployment_controller.gd:369`, `match.gd:453`, `unit_command_controller.gd:871`), а
`get_node_or_null("/root/Cursors")` — в 3 (`building_controller.gd:567`,
`rts_camera.gd:167`, `unit_command_controller.gd:877`). Это самый дешёвый дедуп в проекте.
Единственная причина не писать просто `Players` — headless-тесты, где автолоада может не
быть; отсюда `autoload_lookup.gd` с одной реализацией guard'а.

### Определение «свой/живой/достроенный» размножено

- дак-тайпед `int(x.get("owner_player_id"))` — **16 сайтов** (`upgrade_effects.gd:20`,
  `building_upgrade_controller.gd:335,388`, `building_placement.gd:462`,
  `technology_tree.gd:122`, `steering_stabilizer.gd:402`, `harvester.gd:598,719`,
  `unit_roster_controller.gd:238,336`, `unit_deployment_controller.gd:79,247,371`,
  `match_snapshot.gd:85`, `match.gd:391`, `combat_impact_resolver.gd:185`) — при том что
  `Unit.is_owned_by`/`Building.is_owned_by` существуют, но зовутся ровно из одного места
  (`unit_command_controller.gd:838`);
- «враг ли» реализовано **тремя** способами: `unit_command_controller.gd:654-668`,
  `steering_stabilizer.gd:400-404`, `player_roster.are_enemies:238` (последний —
  канонический, зовётся из двух мест);
- гвард `is_construction_complete` переписан вручную **4 раза**
  (`technology_tree.gd:132-134`, `unit_roster_controller.gd:378-384`,
  `unit_deployment_controller.gd:222-223`, `match.gd:393-394`);
- шаблон валидности `x == null or not is_instance_valid(x) or x.is_queued_for_deletion()` —
  `harvester.gd:593,713`, `unit_roster_controller.gd:236,379`, `nav_agent_registry.gd:196`,
  `building.gd:658,703,815,1018`;
- `exit_direction` fallback (`has_method("exit_direction")` → `world_horizontal_axis`) —
  **3 verbatim копии** (`unit_deployment_controller.gd:530`,
  `unit_roster_controller.gd:345`, `building_footprint.gd:99`), при живом
  `Building.exit_direction()` (`building.gd:480`);
- `_units_parent` (трёхшаговый fallback до узла `Units`) — 2 полные копии
  (`unit_roster_controller.gd:324`, `unit_deployment_controller.gd:499`) + частичная в
  `building_survivors.gd:108`.

→ `scripts/world/entity_query.gd` (static): `is_live(node)`, `owner_id_of(node)`,
`is_owned_by(node, player_id)`, `is_operational(node)`, `exit_direction(node)`,
`units_parent(tree)`, `owned_live_in_group(tree, group, player_id)`. Заменяет ~40 сайтов.

### Каталоги определений создаются по 5 раз каждый

`UnitSceneCatalog`/`BuildingDefinitionCatalog` инстанцируются независимо в `match.gd:52-53`,
`side_panel.gd:58-59`, `unit_roster_controller.gd:42-43`,
`unit_deployment_controller.gd:39-40`, `unit_navigation_system.gd:21`, плюс
`building.gd:12` и `building_survivors.gd:12`. Перевести на `static var` внутри самих
каталогов — один кеш определений на процесс.

### Точечные разрезы

- **`harvester.gd` (833)** — две структурно идентичные стейтмашины (harvest/unload) с
  параллельными квинтетами функций: `cancel_harvest_order` (250) ↔
  `_cancel_unload_immediately` (738), `_advance_harvest_phase` (474) ↔
  `_advance_unload_phase` (416), `_begin_harvest_phase` (490) ↔ `_begin_unload_phase` (444),
  `_finish_harvest_order` (642) ↔ `_finish_unload_order` (764), и драйверы
  327–336 ↔ 384–397. Идиома «сейчас идёт анимация» (`_x_phase in [START, HOLD, END]`)
  выписана **13 раз** (79, 110, 151, 251, 329, 386, 643, 726, 733, 752, 823–824, 830–831).
  `_start_harvest_animation` (656) и `_start_unload_animation` (660) — буквальные алиасы
  одного `_start_action_animation` (670). → один `harvester_phase_machine.gd`
  (`RefCounted`, форма `wall_chain.gd`), два экземпляра. Тесты
  (`harvester_run.gd`, 17 сценариев) гоняют публичные
  `advance_harvest_order`/`advance_unload_order`/`advance_harvest_cycle` — они и остаются
  на фасаде.
- **`unit_command_controller._command_move` (332–469, 140 строк)** — три
  классифицирующих прохода по выделению (339–349, 373–378, 403–421) и 45-строчная
  сборка текстовой метки (434–469). Классификация повторена ещё дважды:
  `_can_issue_movement_order` (754–772) и `_has_movement_or_rally_selection` (782–788).
  → один `SelectionPartition` (`RefCounted`-DTO: `movable`, `rally`, `harvesters`,
  `deployed`), считается один раз; сборка метки — в отдельный `_move_status_text(partition)`.
  Гвард `if not is_instance_valid(entity) or not _can_control(entity): continue` повторён
  7 раз (222, 242, 639, 675, 736, 758, 784) — уходит внутрь `SelectionPartition`.
  В `_deployment_cursor_for` (683–721) второй тернарный блок (715–720) — **дословная копия**
  первого (698–703).
- **`match.gd` (453)** — четыре функции `_local_player_*_ids` (357, 414, 426, 440) имеют
  идентичную 8-строчную преамбулу, различаясь только финальным вызовом каталога. →
  один `_with_local_player(callable)`. Плюс `_setup_*`-фабрики (112–204) — шесть почти
  одинаковых блоков.
- **`map_spice_layer.gd` (677)** — три независимых кластера со своими полями:
  spread-планировщик (317–456, `_active_spice_spreads`), hazard-урон (458–572,
  `_active_spice_hazards`, `_combat_definition_catalog`), рендеринг
  (245–262 + 614–638, `_composite_viewport`). Извлекаются как три модуля.
  `_cell_index` (673–677) переизобретает `MapNavigationGrid.cell_index`+`in_bounds`
  (`map_navigation_grid.gd:123-128`) — при том что `_navigation_grid` у класса уже есть.
  **Осторожно:** `tests/maps/run.gd` зовёт по имени 5 приватных методов
  (`_spread_interval_seconds`, `_create_spice_spread_job`, `_apply_spice_spread_stage`,
  `_spice_hazard_damage_per_second`, `_damage_infantry_in_cells`) — нужны forwarding-обёртки.
- **`cursor_manager.gd:_setup_model_viewport` (261–358, 100 строк)** — строит стек
  SubViewport+Environment+WorldEnvironment+DirectionalLight+Camera **дважды**: обычный
  (262–312) и screen-blend (314–358), почти идентично. → один
  `_build_viewport_stack(is_screen_blend)` … точнее, без флага: одна функция, вызываемая
  дважды с разным `Environment`-пресетом. `_activate_model_cursor` (393–445) повторяет
  триплет `_warn_missing_model` + `_refresh_visual_mode` + `return` 4 раза (408, 415, 425).
  Осторожно: `tests/ui/cursor_run.gd` ассертит **топологию** построенного вьюпорта.
- **`side_panel.gd` (457)** — четыре пары близнецов building/upgrade:
  `configure_building_options:112-122` ↔ `configure_ordered_roster:125-142` (хвост
  135–142 дублирует 113–122), `_apply_building_option_state:216` ↔
  `_apply_upgrade_option_state:237`, `_configure_building_slot:329` ↔
  `_configure_upgrade_slot:348`, `_building_slot:410` ↔ `_upgrade_slot:418`.
  Параметризовать по типу слота. **Риск:** `side_panel_pagination_run.gd` — всего ~7
  ассертов и **только** по building-ветке; upgrade-ветка не покрыта, править её вслепую
  нельзя. Сначала дописать тесты на upgrade-ветку, потом объединять.
- **`unit_deployment_controller._deployment_candidate` (124–201, 85 строк)** — шесть
  early-return со словарями одинаковой формы `{handled, available, message}` (126, 128,
  130–134, 135–140, 145–150, 154–158, 175–180, 186–191). Заменить на один
  `_reject(message)`. Заодно унифицировать форму результата: сейчас в проекте три разных
  (`{ok, message}` в `match_snapshot.gd`, `{handled, started, message}` в
  `unit_deployment_controller.gd:570`, `{handled, available, message}` тут же).

---

## Этапы

Каждый этап — отдельный коммит (или серия), после каждого `make godot-test` зелёный.
Порядок выбран так, чтобы дешёвое и безопасное шло первым, а самое рискованное
(`unit.gd`) — после того как под ним появятся общие утилиты.

### Этап 0 — подготовка защиты (обязателен, до любого распила)
1. `make godot-test` — зафиксировать baseline и время сьютов.
2. Расширить `tests/units/death_animation_run.gd:_value_dangles()` рекурсией в
   script-объекты (см. выше). Без этого весь дальнейший распил `unit.gd` идёт вслепую.
3. Включить родные предупреждения GDScript в `project.godot` (список выше), починить то,
   что они найдут.
4. `tools/check_architecture.sh` + `make lint`, вызываемый из `godot-test`. **Пункт 1
   скрипта (`_facade._`) на текущем коде красный — это ожидаемо**, он зеленеет на этапе 2.
   Поэтому вводить его с явным `# TODO(этап 2)`-исключением на `scripts/units/navigation/`,
   которое снимается в конце этапа 2 (и снятие исключения — часть его определения готовности).
5. `gdlint` в контейнер: `python3` + **`python3-venv`** в `Containerfile`, venv в
   `/opt/gdtoolkit` с **закреплённой** версией `gdtoolkit` (не системный `pip3 install` —
   PEP 668, см. выше), `.gdlintrc` в корне, подкоманда `lint` в `tools/godot-container`.
   Пороги — те, которые проходит текущий код (ужесточаются по ходу).
6. Дописать тесты на upgrade-ветку `side_panel.gd` (сейчас не покрыта).
7. Регрессионный тест на `damage_scale`: два одновременно летящих выстрела с разным
   множителем (нужен до кеша `_definition_bullet` на этапе 4).
8. **Общий test-runner с `timeout` на каждый headless-сьют.** `AGENTS.md` требует
   запускать с bounded `timeout` (зависший скрипт = compile-ошибка, а не долгая работа),
   но ни одна из 28 строк `godot-test` в `Makefile` его не использует — то есть при
   parse-ошибке в ходе рефакторинга прогон повиснет навсегда, что при 8 этапах правок
   гарантированно случится. Свести 28 строк в цикл по списку сьютов с `timeout` и
   суммарным отчётом.

### Этап 0.5 — аудит зависимостей и жизненного цикла (без изменений кода)
Чисто аналитический этап, результат — таблицы в этом файле. Без него этапы 4, 5 и 7
разрежут состояние по неверным границам (четыре подтверждённых пересечения уже найдены).
1. **Таблица read/write по полям** для `unit.gd`, `building.gd`, `combat_turret.gd`,
   `building_controller.gd`: поле → функции, которые читают → которые пишут. Механически
   собирается grep'ом. На выходе — окончательные границы модулей, а не предварительные.
2. **Полный white-box-аудит**, четыре категории (сейчас в плане только первая, и не целиком):
   - прямой доступ к приватным членам из `tests/`;
   - методы базового класса, **переопределённые наследниками** (`Harvester extends Unit` —
     единственный такой случай, но он ломает извлечение animation driver);
   - вызовы `super.*`;
   - приватные поля базового класса, читаемые наследником (`harvester.gd:672` —
     `_animation_players`).

   Для каждой позиции заранее решение: shim / остаётся полем фасада / осознанная миграция
   теста. Не «разберёмся по ходу» — иначе на каждом коммите этапа 7 придётся выбирать
   между «поправить тест» и «откатить извлечение», а это решение принимается один раз и
   для всех.

   **Правило, по которому принимается это решение** (выведено на этапе 5, где его не
   было — и получилось 8 property-шимов, принятых по одному, вразнобой):

   - **поле, в которое тест ПИШЕТ, остаётся полем фасада.** Не шимом, а полем: запись —
     это подготовка состояния, и её нельзя перенаправить в модуль, не сделав модулю
     сеттер, который продакшену не нужен. Сюда попадает `_weapon_fire_sequences`
     (`death_animation_run.gd:202,269,355`, `combat/run.gd:4311`) — план и так требует
     оставить его полем, и это ровно та же причина;
   - **поле, которое тест только ЧИТАЕТ, уезжает в модуль вместе с логикой**, а тест
     переходит на аксессор модуля (`controller._wall_session.markers()`, не
     `controller._wall_markers`). Тест остаётся white-box, но адресует то, чем состояние
     на самом деле является;
   - **метод остаётся на фасаде forwarding-обёрткой.** `Node.call("_foo")` не находит
     метод на вложенном `RefCounted`, так что альтернативы нет;
   - **property-шим (`var x: get/set`, делегирующий в модуль) — не вариант по умолчанию.**
     Он допустим только там, где продакшн-код читает это имя тоже (у `enum Mode` на
     этапе 5 — законный случай: три булевых имени поверх одного enum'а нужны самому
     контроллеру). Шим ради одного теста — запрещён: он врёт про то, кому принадлежит
     состояние, и следующий читатель положит рядом настоящее поле.

   Два уже пойманных на этапе 5 отказа шимов, чтобы не повторять: односторонний шим
   (`set` без `get` или наоборот) компилируется и молча теряет данные — у него остаётся
   backing-поле, в которое уходят записи или из которого читаются нули; и шим, вызванный
   до `configure()` своего модуля, уходит в никуда.
3. **Инвентарь ссылок на модель** — какие поля каких модулей являются кэшем узлов/твинов/
   подписок, чтобы `attach_model`/`detach_model`/`dispose` был спроектирован один раз и
   покрывал всё (см. раздел про lifecycle-протокол).

### Этап 1 — shared-утилиты (дедуп без структурных изменений)
Отдельный коммит на каждый модуль, каждый — «создать модуль + перевести все call-сайты».
1. `players/autoload_lookup.gd` — 9 копий `/root/Players` + 3 `/root/Cursors` (оба автолоада, один модуль).
2. `world/terrain_probe.gd` — screen-pick (3 копии), ground-snap (2 идентичные +
   5 вариантов вертикального рейкаста).
3. `world/entity_query.gd` — live/owner/operational/exit_direction/units_parent (~40 сайтов).
4. `world/authored_model.gd` — `animation_players`, `find_clip`, `clip_length`,
   `play_clip`, `play_one_shot`, `collision_sources` (с порядком префиксов параметром!),
   `selection_bounds`, `play_state`. Убирает 8 циклов в `unit.gd` + 4 копии one-shot-клипа
   + 7 сайтов `StatePlayer` + 3 копии `_play_building_state`.
5. `world/team_color.gd` (нейтральный цвет — параметр, не константа) + shared halo-binding.
6. `combat/combat_target.gd` + `combat/combat_rules.gd` — 5 копий `_combat_target_position`,
   6 копий проверки живости, 3 копии `_combat_entity`, дубли констант.
7. Каталоги определений → `static var` (7 независимых инстансов → 2).

Этап полностью механический, поведение не меняется, и он снимает ~700–900 строк, которые
иначе пришлось бы переносить в новые модули как есть.

### Этап 2 — убрать круговой фасад навигации
По пунктам 1–8 из раздела выше. Идёт **до** `unit.gd`, потому что даёт чистый образец для
восьми последующих извлечений и снимает исключение из `check_architecture.sh`.
`unit_navigation_system.gd` 1006 → ~550, `_facade._private` 57 → 0, обёрток 50 → ~9.
Определение готовности: `tools/check_architecture.sh` зелёный **без** исключения на
`scripts/units/navigation/`, `tests/navigation/run.gd` (49 сценариев) зелёный,
`jitter_probe.gd` прогнан вручную.

### Этап 3 — `authored_fire_controller` как единственная реализация
1. Вынести разбор XBF (`unit.gd:2064-2283` + `_find_xbf_motion_root`) в
   `authored_fire_controller.gd` как `static func`; `Unit` зовёт его, forwarding-обёртки
   для `combat/run.gd:3325,3329`. **−~220 строк из `unit.gd`.**
2. Удалить 8 из 9 полей-зеркал `_fire_sequence_*` (`unit.gd:203-211`),
   `_fire_sequence_active` → вычисляемый геттер, `_on_animation_finished` → на
   `_weapon_fire_sequences`. **−~30 строк.**
3. Обобщить `AuthoredFireController` до N последовательностей и перевести `Unit` на него;
   `_weapon_fire_sequences` остаётся полем `Unit` (тесты пишут в него напрямую).
   **−~200 строк.**

### Этап 4 — `combat_turret.gd`: вынести FX
1. `combat/fx/authored_fx_bank.gd` — расписания, текстуры, billboard-материал, одна
   параметризованная frame-animated частица, одна интеграция движения. Перевести на него
   3 копии частиц, 3 копии таймлайнов, 3 построителя расписания, 3 копии интегратора,
   2 построителя материала + `combat_impact_effect.gd`.
2. `combat/turret/combat_turret_fx.gd` — 12 FX-полей + остаток блока 1376–2680.
   `CombatTurret` оставляет `start/has/cancel_authored_fire_fx` обёртками.
3. Кешировать `_definition_bullet` **только для 8 read-only сайтов** (709, 752, 770, 816,
   883, 1287, 1569, 1581); сайт **849 остаётся новым объектом на выстрел** — он единственный
   присваивает `payload.damage_scale`. Требует зелёного теста из этапа 0 п.7.
   `_definition_catalog` (`:138`) → `static var`.
   Отдельным коммитом после: вынести `damage_scale` в `ShotPayload`, чтобы
   definition-часть стала immutable целиком.
4. Дедуп серво: `_turn_yaw_toward` ≡ `_turn_pitch_toward` (одна бисекция по оси),
   4 копии вычисления угловой ошибки (484, 532, 565, 599).

### Этап 5 — `buildings/*`
1. `production_queue.gd` по контракту выше: очередь **не конструирует заказ**, принимает
   готовый через `adopt()`, мутирует 7 duck-typed полей и эмитит **тот же экземпляр**;
   wrapper'ы ретранслируют сигнал в свой типизированный. Плюс `production_progress.gd`
   (одна `static func` вместо двух копий `progress_percent()`). Общего класса заказа нет.
   −~120 строк.
2. Извлечения из `building.gd` **по таблице**: rally point, refinery docks, wall visual,
   combat hull и **единый `building_combat.gd`** (attack-order + боевой драйвер + popup
   вместе — отдельного popup-модуля нет, состояние неделимо).
3. Извлечения из `building_controller.gd` (repair, sale, wall-line session, catalog view,
   pointer gesture) + внутренние дедупы (5 копий config-lookup, 7 копий wall-teardown,
   4 копии ownership-gate); три булевых флага режима → `enum Mode`.
4. `building_placement.gd`: `occupy_grid.gd`, `placement_materials.gd`,
   `PlacementContext` вместо 11 позиционных параметров; `static var` кеш → поле
   экземпляра с отпиской в `_exit_tree`.
5. `building_upgrade_controller.gd`: четыре обработчика слотов → один параметризованный.
6. Мелкие фиксы отдельными коммитами: мёртвый **метод** `_mesh_instances` (`building.gd:605`
   — рекурсирует только в себя, внешних вызывающих нет; линтер его не поймает, см. ниже),
   двойной `_restore_popup_hold_pose` (`:226`/`:229`), 3 кодировки таксономии в
   `wall_connectivity.gd`, `technology_tree.gd:110-115`.
7. Перф: event-driven инвалидация availability вместо O(n×m) опроса каждый кадр
   (`building_controller.gd:112,118,1176`).

### Этап 6 — общая политика урона (без экземпляра и без состояния)
`combat/damage_policy.gd` — **только `static func`**, ни полей, ни владельца:
`static func resolve(amount, health, shields, invulnerable) -> DamagePolicy.Result`
(объявленный класс, не `Dictionary` — см. выше).
`Unit.take_damage`/`Building.take_damage` зовут её и применяют результат через свои
сеттеры. Это весь дедуп, который здесь есть (8 строк арифметики щитов в одном месте), и
больше ничего в этот модуль не входит — см. раздел выше о том, почему.

Отдельно и независимо: relations (`owner_player`/`is_owned_by`/`is_allied_with`/
`is_enemy_of`/`is_neutral_owner`, 25 строк byte-identical) → в `world/entity_query.gd` из
этапа 1. `owner_player_id` остаётся `@export`-полем фасада со своим сеттером;
`grant_temporary_invulnerability` остаётся на `Unit`.

### Этап 7 — `unit.gd`: извлечение кластеров
**По итоговой таблице** (`unit_locomotion` — gait и анимация локомоции вместе;
`unit_terrain_alignment`; `unit_deploy_state`; `combat_target_acquisition` — общий с
`Building`; `unit_attack_order` — свой мобильный драйвер; `unit_fire_overlay`;
`unit_shader_fx`; `unit_death_sequence`). Порядок — от кластеров с наименьшим числом
обращений назад к фасаду; начинать с `unit_terrain_alignment` (ноль кэшированных узлов) и
`unit_death_sequence`. Каждый кластер — свой коммит.

`_on_animation_finished` и `_set_movement_animation` **остаются на фасаде** (переопределяет
`Harvester`) и становятся точками расширения: фасад спрашивает модули
`on_animation_finished(name, player) -> bool` в текущем порядке, после `super`-цепочки.
Модули с кэшем узлов (`unit_locomotion`, `unit_deploy_state`, `unit_fire_overlay`,
`unit_shader_fx`) реализуют lifecycle-протокол с первого коммита, а не «потом».

### Этап 8 — `match/`, `harvester.gd`, `ui/`, `map_spice_layer.gd`
Точечные разрезы по списку выше. Самостоятельны и могут идти параллельно/позже.

**Ожидаемый итог:** `unit.gd` 3484 → ~500, `combat_turret.gd` 2785 → ~1100,
`building.gd` 1944 → ~450, `building_controller.gd` 1286 → ~500,
`building_placement.gd` 938 → ~450, `unit_navigation_system.gd` 1006 → ~550. Суммарно
`scripts/` вырастет в числе файлов и сократится примерно на 1500–2000 строк за счёт
удалённой копипасты. Плюс `make lint`, не дающий этому вернуться.

---

## Проверка

Основной инструмент — `make godot-test` (28 headless-сьютов). Запускать **после каждого
коммита**, не после этапа: любой красный тест при механическом переносе — это ошибка
пересадки, а не «тест устарел».

```
make godot-check      # импорт/валидация проекта (ловит parse-ошибки)
make godot-test       # полный прогон
```

Важно, из `AGENTS.md`: команды `tools/godot-container` запускать **последовательно** —
параллельные прогоны делят контейнер и `/workspace`, из-за чего падают с ошибками,
похожими на тестовые. И: headless-скрипт, который «висит» с ~0 % CPU, — это
parse/compile-ошибка, а не долгая работа; гонять с `timeout` и без `| tail`, чтобы
`SCRIPT ERROR`/`Parse Error` были видны сразу.

Ключевые сьюты по этапам:

| Этап | Что должно остаться зелёным в первую очередь |
|---|---|
| 0 | `tests/units/death_animation_run.gd` — расширенный `_value_dangles` обязан **упасть**, если убрать существующий null-инг в `_prepare_model_for_corpse`; иначе расширение не работает. Проверить это намеренной поломкой перед коммитом. |
| 0.5 | — аналитический, кода не меняет; на выходе три таблицы, без которых этапы 4/5/7 не стартуют |
| 1 | все — этап механический; особенно `combat/run.gd`, `buildings/*`, `maps/run.gd` |
| 2 | `navigation/run.gd` (49 сценариев — главный ассерт этапа), `units/harvester_run.gd:416`, `flight_run.gd`, `demo_boot_run.gd:1060,1081`, вручную `jitter_probe.gd` |
| 3 | `combat/run.gd` (3325, 3329, 4311, 4317), `death_animation_run.gd`, `demo_boot_run.gd` (1110, 1233, 1236) |
| 4 | `combat/run.gd`, `combat/death_category_run.gd`, `effects/death_corpse_run.gd` |
| 5 | `buildings/run.gd`, `placement_run.gd`, `controller_run.gd`, `upgrade_run.gd`, `wall_connectivity_run.gd`, `techtree_multiple_conyards_run.gd`, `primary_building_run.gd` |
| 6 | `combat/run.gd`, `buildings/run.gd` (`health_changed`, энергия), `match/snapshot_run.gd` (читает `health`/`shields`/`max_health` напрямую) |
| 7 | `demo_boot_run.gd` (90, 160, 221, 294, 341, 373), `units/*_run.gd`, `navigation/run.gd` |
| 8 | `match/unit_command_run.gd`, `units/harvester_run.gd`, `maps/run.gd`, `ui/cursor_run.gd`, `ui/side_panel_pagination_run.gd` |

Помимо тестов — визуальная проверка в реальной сцене для того, что тесты не ловят:
цвет нейтральных зданий/юнитов (этап 1, `team_color` — здесь два разных значения
нейтрального цвета, и это единственное, что их различает), превью размещения и стрелка
направления (этап 5), курсоры (этап 8 — топология вьюпорта покрыта `cursor_run.gd`, но не
картинка).

Про FX (этап 4): вопреки первоначальной оценке, `tests/combat/run.gd` покрывает частицы
**довольно подробно** — 56 упоминаний, включая прямой вызов `turret._spawn_muzzle_flash(...)`
и проверку `_particle_timeline_tweens` (`:1565`). Это меняет оценку риска этапа 4 в лучшую
сторону, но добавляет white-box-связность, которую обязан учесть аудит этапа 0.5.

Организационное: для каждого нового `.gd` нужен сгенерированный `.gd.uid` — репозиторий их
отслеживает (180 файлов в индексе, в `.gitignore` не исключены). Они появляются при импорте
проекта, поэтому после создания файлов прогонять `make godot-check` **до** коммита, иначе
получим коммиты без `.uid` и сломанные ссылки в `.tscn` у следующего, кто откроет редактор.

Отдельно: `tests/navigation/jitter_probe.gd` и `tests/buildings/collision_probe.gd`/
`footprint_probe.gd` не входят в `make godot-test` — прогнать вручную после этапов 1, 2, 5 и 7.

И постоянно, начиная с этапа 0: `make lint` (`tools/check_architecture.sh` + `gdlint`).
Он и есть ответ на «как не повторить это в будущем» — правило, которое проверяет только
человек на ревью, этот репозиторий уже один раз потерял.

---

## Отдельная задача: `Harvester` — с наследования на композицию (после этапа 7)

`Harvester extends Unit` (`harvester.gd:1-2`, 830 строк) — единственный наследник `Unit`
в проекте, и он же единственная причина, по которой у `Unit` есть неявный
«protected»-контракт: любой приватный член базового класса может оказаться частью
контракта с наследником, и ни один тест этого не покажет.

Замер сцепления — **22 точки**:

| Что | Сколько | Где |
|---|---|---|
| переопределённых методов `Unit` | 8 | `_process` (:65), `prepare_navigation_order` (:72), `set_navigation_controller` (:92), `has_active_order` (:267), `cancel_all_orders` (:280), `_apply_unit_definition` (:804), `_set_movement_animation` (:817), `_on_animation_finished` (:826) |
| вызовов `super.*` | 8 | те же места |
| приватных членов `Unit`, читаемых напрямую | 6 | `_navigation_system` (14 обращений), `_navigation_managed` (6), `_animation_players`, `_play_animation_from_start`, `_players`, `_turn_toward` (по 1) |

Все шесть приватных — это ровно те хабы, которые этап 7 растаскивает по модулям. То есть
каждое извлечение обязано сохранить аксессор не только для white-box-тестов, но и для
наследника, иначе переопределения перестанут вызываться **молча**.

### Два прочтения «композиции» — и почему берётся только одно

**A — `Harvester` перестаёт быть `Unit`** (владеет юнитом или дублирует его контракт).
**Отвергнуто.** Ломается весь полиморфный код: `get_nodes_in_group("units")`, выделение,
команды, наведение, снапшот, производство. `Harvester` обрастает громадным пробросом — то
есть мы воспроизводим круговой фасад, который этот же план разбирает как антипаттерн в
разделе про навигацию (50 обёрток, ~330 строк чистой делегации). Записано здесь именно
чтобы через полгода это не переигрывалось заново.

**B — класса `Harvester` не остаётся, добыча становится модулем `Unit`.** Принято.
`units/harvester_controller.gd` в форме `unit_flight_controller.gd` (`RefCounted`,
`configure(unit, definition)`, `_owner` без типа), подключаемый когда определение говорит,
что юнит — харвестер. 8 переопределений становятся хуками, которые фасад вызывает по
очереди (для `_set_movement_animation` и `_on_animation_finished` план это уже предписывает
как решение 1 в разделе про наследование); 6 приватных чтений — узким API фасада, тем же,
который этап 7 строит для остальных восьми модулей. У `Unit` пропадает «protected»-контракт,
и харвестер встаёт в один ряд с прочими модулями вместо особого случая.

### Почему после этапа 7, а не до

Соблазн сделать раньше понятен: тогда этап 7 не строит аксессоры под наследника. Но seam
`Unit` ↔ добыча пришлось бы проектировать против `Unit` на 3484 строки, который прямо
сейчас разбирается, — то есть спроектировать дважды. А нужные харвестеру аксессоры этап 7
строит и так: это те же хабы (`_animation_players`, `_navigation_system`), для которых
фасад уже отдаёт узкий API наружу. Пока этап 7 идёт, безопасность держится на уже принятом
решении 1 — `_set_movement_animation` и `_on_animation_finished` остаются на фасаде точками
расширения, и переопределения продолжают вызываться.

### Что это стоит

Проверено `grep`: **в `scripts/` нет ни одного обращения к `Harvester` как к типу** —
ни `is Harvester`, ни `as Harvester`; `unit_scene_catalog.gd` выбирает `harvester.tscn`
по id из манифеста, то есть data-driven. Значит продакшн-кода правка не касается вообще,
и цена — сам модуль плюс тесты:

- `tests/units/harvester_run.gd:263` («the dedicated Harvester scene must remain a Unit
  subtype») и `:283`, `tests/units/unit_scene_catalog_run.gd:34` — три утверждения о
  подтипе; под B они меняют смысл на «у сцены есть модуль добычи»;
- `tests/match/demo_boot_run.gd:1267` — каст `as Harvester`.

### Готовность

`tests/units/harvester_run.gd` зелёный без ослабления сценариев (только переформулировка
трёх утверждений о подтипе), `demo_boot_run.gd` и `navigation/run.gd` зелёные,
`grep -rn "extends Unit" scripts/` пуст, и `Unit` больше не имеет членов, существующих
только ради наследника.

---

## Перф-регрессия рефакторинга: замер, локализация, причина

### Чем меряем

`tests/perf/demo_match_perf_run.gd` (`make godot-perf`) — smoke-замер кадра, воспроизводящий
ручное наблюдение, с которого регрессия и началась: `demo_match.tscn` + фикстура
`tests/perf/fixtures/demo_match_perf_snapshot.json` (49 зданий, выставленных плотно по сетке
footprint), камера-риг в `(197, 0, 63)`, yaw 30°, zoom 160.

Две вещи, без которых замер не воспроизводится:

- **зум решает, куда риг вообще смотрит.** `RTSCamera._apply_zoom()` ставит камеру в
  `(0, zoom·0.75, zoom)` c питчем −35°…−60°, поэтому центр экрана уезжает *назад* от рига на
  `zoom − (0.75·zoom − 8)/tan|pitch|`: при `default_zoom = 70` это 21 юнит и в кадре пустой
  песок, при `zoom = 160` — 95 юнитов, центр падает в `(245, 8, 146)` и застройка в кадре.
  Тест поэтому пишет в отчёт `view_centre` и `buildings_in_view` — «риг стоит там, где
  сказано» ещё не значит «мерим то, что нужно»;
- `Engine.max_fps = 0` (в проекте стоит 60) и `VSYNC_DISABLED` для оконного прогона — иначе
  всё упирается в 16.6 мс и регрессия не видна вообще.

`RTSCamera._process` на время замера выключается: он каждый кадр правит риг по вводу и
зажимает точку взгляда в границы карты, то есть и уводит вид, и ловит случайные нажатия в
сфокусированном окне.

Разброс между прогонами <1 % по p50, так что разница в 3 мс — сигнал, а не шум.

### Что показал замер (p50 кадра, headless, один и тот же хост)

| коммит | | кадр, мс | fps |
| --- | --- | --- | --- |
| `e97448da` | база до рефактора | 9.19 | 108.9 |
| `238b7cc` | preparing for refactor | 9.56–9.87 | ~103 |
| **`5fff41c`** | **consolidate shared gameplay utilities** | **14.02** | **71.3** |
| `8d84624` | decouple navigation modules | 13.93 | 71.8 |
| `1f029e0` | centralize authored fire sequences | 14.19 | 70.5 |
| `3b07b19` | extract combat turret effects | 14.19 | 70.5 |
| `8d2d078` | split buildings into modules | 12.71 | 78.7 |
| `c540a4a` … `07d1d67` | остальные | 12.4–12.8 | ~79 |
| `40cdc70` | HEAD | 12.13 | 82.4 |

Вся регрессия — **один коммит `5fff41c`**: +4.3 мс к кадру (+45 %). Ни один другой коммит
рефактора кадр не портит; `8d2d078` (распил `building.gd`) обратно отыграл 1.4 мс, так что на
HEAD осталось +2.9 мс (−24 % fps). В окне с настоящим рендером: 66.6 → 54.5 fps
(15.0 → 18.4 мс), то есть под штатным кэпом 60 fps игра ушла с ровных 60 на ~54.

### Где именно (замерено отключением путей кадра)

| | база `e97448da` | HEAD `40cdc70` |
| --- | --- | --- |
| кадр целиком | 9.19 | 12.13 |
| без `Building._process` | 9.14 | 12.16 |
| без `Match._process` | — | 6.77 |
| без `_unit_roster_controller.process()` | 6.86 | 6.68 |

`Building._process` при 49 простаивающих зданиях не стоит ничего, и остальной кадр
(6.7–6.9 мс) рефактор не изменил. Вся разница сидит в **`UnitRosterController.process()`:
2.33 мс → 5.45 мс (×2.4)**. Из четырёх вызовов `Match._process` три (`building_controller`,
`building_upgrade_controller`, `_refresh_sidebar_house_pages`) в сумме дают шум.

### Причина

`UnitRosterController.process()` (`:59`) каждый кадр гоняет `_is_unit_available()` по всем
id юнитов, а `_is_unit_available()` (`:354`) **на каждый id заново** собирает
`get_tree().get_nodes_in_group("buildings")` и отдаёт их в
`TechnologyTree.is_available()` → `_owned_buildings()`. То есть кадр стоит
O(id юнитов × зданий на карте) — при 49 зданиях это больше тысячи посещений здания за кадр,
и availability пересчитывается с нуля, хотя техтри между кадрами не меняется.

`5fff41c` эту сложность не вводил, он умножил её константу. Инлайн-проверки заменились на
статические хелперы, и одно посещение здания вместо `int(building.get("owner_player_id")) ==
player_id` + `has_method`/`call` теперь стоит:

- `EntityQuery.is_owned_by` → `owner_id_of` → `is_live` (+`is_instance_valid`
  +`is_queued_for_deletion`) + проверка `&"owner_player_id" in node` + `get`;
- `EntityQuery.is_operational` → **снова** `is_live` + `has_method` + `call`;
- и то же самое отдельно в `_is_building_construction_complete` при сборке массива.

Сами хелперы правильные и дедуп нужен — цена в том, что они встали в горячий O(n·m) цикл, где
раньше стоял инлайн. Поэтому лечился **пересчёт**, а не хелперы: после этого цикл перестаёт
быть горячим и их стоимость становится неважной.

### Что сделано

`BuildingController` уже держал ровно нужный механизм — `_availability_dirty` +
подписки на `node_added`/`node_removed` дерева и на `owner_changed`/
`construction_completed`/`upgrade_level_changed`/`tree_exiting` каждого здания, — но целиком
внутри себя, поэтому `UnitRosterController` вместо него опрашивал техтри каждый кадр.
Механизм вынесен в `scripts/buildings/building_availability_tracker.gd`
(`BuildingAvailabilityTracker`, `RefCounted` по конвенции этого репозитория) и теперь общий
для обеих сеток:

- `bind(host)`/`unbind()` — подписки и симметричный тердаун (тот самый инвариант про
  «не переподписаться поверх живых подписок» из `controller_run.gd`);
- `consume_dirty()` — читает и сбрасывает флаг, чтобы вызывающий не мог забыть сбросить;
- `buildings()` — **один** типизированный массив на пересчёт. Именно сборка этого массива
  заново на каждый id и давала квадратичность.

`UnitRosterController.process()` теперь пересчитывает availability только по грязному флагу,
а `_is_unit_available()` читает кэш — как `_is_building_available()` уже читал
`BuildingCatalogView.is_available()`. В `BuildingController` из тела ушло ~100 строк
подписочной бухгалтерии без изменения поведения.

Белоящичные утверждения в `tests/buildings/controller_run.gd` перенаправлены на трекер
(`Callable(controller._availability_tracker, "mark_dirty")` и т.д.) — иначе проверки
«тердаун отсоединяет подписки» стали бы тавтологией: у контроллера этих коллбеков больше нет.
Это то самое слепое пятно, про которое предупреждает раздел выше.

### Результат

| | кадр | fps |
| --- | --- | --- |
| база `e97448da` | 9.19 мс | 108.9 |
| HEAD до фикса | 12.13 мс | 82.4 |
| **после фикса** | **6.7 мс** | **~149** |

Быстрее не только HEAD, но и базы до рефактора: опрос каждый кадр стоил 2.33 мс и там.
В окне с реальным рендером: 54.5 → **78–83 fps** (база была 66.6), то есть под штатным кэпом
60 fps появился запас. `make godot-test` — 28/28 сюит зелёные.
