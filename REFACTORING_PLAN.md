# План архитектурного рефакторинга EmperorReborn

Этот файл является durable source of truth: перед продолжением работы сверять с ним состояние репозитория и дополнять журнал после каждого завершенного этапа.

## Цель и принципы

Цель: постепенно привести Godot RTS к feature-first структуре, в которой камера, игроки, юниты, здания, карта и UI имеют явные границы, а runtime-код не зависит от конвертеров и конкретных виджетов.

- Делать минимальные проверяемые изменения, по одному архитектурному риску за этап.
- Сохранять поведение до его изменения отдельной задачей; перед разделением покрывать критичные сценарии characterization tests.
- Не вводить ECS, глобальный EventBus или ServiceLocator. Существующие autoload `Players` и `Rules` не расширять новыми обязанностями без отдельного обоснования.
- Предпочитать прямые типизированные зависимости, сигналы владельца feature и небольшие объекты состояния.
- Не смешивать механическое перемещение файлов с изменением поведения.

## Исходные hotspots и ограничения

- `scenes/match/demo_match.tscn` вручную поддерживается, но ссылается на generated scenes из `assets/converted/`; запуск demo match зависит от локально сконвертированных оригинальных assets.
- `scripts/match/match.gd` является composition root demo match: создает demo players, координирует карту/камеру и HUD wiring.
- `scripts/buildings/building_controller.gd` остается orchestration shell для availability, queue/placement/sell, scene-path/rules lookup и feature presentation signals; production queue и placement вынесены в отдельные feature objects, UI contract адаптируется только в match composition root.
- `scripts/ui/side_panel.gd` хранит UI-only icons/layout и cached feature presentation state; gameplay IDs принадлежат match composition data.
- Runtime map находится в `scripts/world/map/`; `converters/map_navigation_grid_builder.gd` владеет чтением original map formats и source-grid construction, передавая в runtime только complete generated navigation arrays. Generated map output пока остается устаревшим до отдельной 5C regeneration.
- `scripts/players/player_roster.gd`, `scripts/players/player_data.gd`, `scripts/buildings/building.gd` и `scripts/units/unit.gd` используют изменяемые Resources и сигналы жизненного цикла; до структурных правок нужны проверки reset/rebind/removal/ownership.
- Есть asset-independent runners `tests/characterization/run.gd`, `tests/buildings/run.gd`, `tests/buildings/placement_run.gd`, `tests/match/unit_command_run.gd` и `tests/maps/run.gd`; авторитетная версия движка указана в `project.godot` как Godot 4.7, основной воспроизводимый запуск идет через `tools/godot-container`.
- `assets/` и `.godot/` игнорируются в `.gitignore`. Нельзя считать локальный `.godot` доказательством корректности путей или коммитить generated/original assets.

## Обязательное правило перемещений

Перемещать каждый `.gd` и `.gdshader` вместе с соответствующим `.uid`, сохраняя UID. После изменения путей обновлять все `res://` ссылки в hand-authored `.tscn`, `.tres`, `.gd` и `project.godot`; generated assets регенерировать штатными converters, а не редактировать вручную. Проверять проект без опоры на существующий `.godot` cache; пользовательский cache не удалять.

## Правило исполнения этапов

Для каждого нового номерного этапа основной агент создает нового subagent. Один и тот же subagent может переиспользоваться только между буквенными подэтапами этого номерного этапа (например, 3A--3C); после перехода к следующему номерному этапу он не продолжается.

## Этапы

### [x] Этап 0. Baseline камеры (завершен 2026-07-10)

Scope: исправить fallback path `RTSCameraConfig.tres` в `scenes/main.tscn`, не меняя UID; типизировать `RTSCamera.config` как `RTSCameraConfig`; сохранить создание default config при `null` и все camera tuning.

Критерии приемки: после этапа 2A сцена ссылается на текущий `res://configs/camera/rts_camera_config.tres` с прежним `uid://nj40xd0p0abq`; GDScript парсится; проект импортируется; main scene запускается headless без ошибок камеры. Если generated assets блокируют main, допустима узкая parse/load-проверка камеры с зафиксированным blocker.

Проверка:

```sh
./tools/godot-container godot --version
make godot-check
timeout 30s ./tools/godot-container godot --headless --path /workspace --quit-after 10
```

Результат: Godot 4.7 `--check-only` для `scripts/rts_camera.gd` прошел. Временная camera-only сцена на отдельном чистом `.godot` cache прошла headless run с назначенным `.tres` и с `null` fallback. Полный main на том же чистом cache не сообщает ошибок камеры, но блокируется generated `assets/converted/maps/#M70 Claw Rock/terrain.tscn`: он ссылается на отсутствующие `res://assets/unpacked_rfd/3DDATA/Textures/*.tga`. Обычный `make godot-check` дополнительно использует stale пользовательский cache (старый camera path и дублированный global class `MapXbf`); этот cache не удалялся и не использовался как доказательство успешности этапа.

### [ ] Этап 1. Lifecycle/data bugs и characterization tests (1A завершен, 1B deferred)

Исходный scope разделен, чтобы asset-independent data tests не загружали `BuildingController`, raw textures, generated placement/map scenes или converter-код.

#### [x] Этап 1A. Asset-independent lifecycle/data baseline (завершен 2026-07-10)

Scope: минимальный runner `tests/characterization/run.gd`; observable behavior `PlayerData`, `PlayerRoster`, `BuildingOrder` и `TechnologyTree`; reset demo roster до создания игроков. Никаких перемещений или новых архитектурных слоев.

Покрыто 60 assertions:

- `PlayerData`: configure, дедупликация subhouses, clamp money, spend validation, signed energy и payload/count resource signals.
- `PlayerRoster`: neutral/reset, отключение старых ресурсов, replacement/rebind без дублей, removal, local player, очистка relations, default/explicit/symmetric relations и shared vision.
- `BuildingOrder`: default/paid/free progress, clamp, сохранение progress при pause и ready = 100%. Cancel/refund/readiness transitions остаются в controller и не тестируются через private API.
- `TechnologyTree`: primary house и subhouses, building/unit requirement lists, ownership, secondary и upgraded-primary requirements.

Исправлены только воспроизведенные bugs: `PlayerRoster.reset_for_match()` отключает signals всех прежних `PlayerData`; `TechnologyTree` учитывает `PlayerData.subhouse_ids`; `scripts/main.gd` всегда вызывает reset перед настройкой нового demo match вместо сохранения autoload state прошлого матча.

Критерии приемки: runner не зависит от assets/editor cache, освобождает созданные Nodes, печатает имена cases и завершает процесс кодом 1 при failure; все assertions проходят; измененные независимые runtime scripts проходят `--check-only`.

Проверка и результат:

```sh
./tools/godot-container godot --headless --path /workspace --script res://tests/characterization/run.gd
# PASS: 8 cases, 60 assertions
./tools/godot-container godot --headless --path /workspace --script res://scripts/players/player_roster.gd --check-only
# PASS
./tools/godot-container godot --headless --path /workspace --script res://scripts/buildings/technology_tree.gd --check-only
# PASS
```

#### [ ] Этап 1B. Scene-bound lifecycle characterization (queue transitions closed in 3A; map failure closed in 5A)

Scope: ownership внутри scene tree, повторный setup controller и очистка состояния при неуспешной `MapLoader.load_map()`. Полные asset-independent building-order transitions (charge/pause/resume/cancel/refund/ready/consume) закрыты публичным `BuildingQueue` runner в этапе 3A; deferred map failure semantics закрыты asset-independent `tests/maps/run.gd` в этапе 5A. Не тащить private controller API или converter dependency в runner 1A.

Критерии приемки: отдельные asset-independent seams существуют после соответствующего разделения; tests проверяют transitions через public API, signal connections не дублируются, failed map load не оставляет смешанное старое/новое состояние.

Текущие blockers: `scripts/match/match.gd --check-only` и `make godot-check` загружают `SidePanel`/`BuildingController`/map dependencies и сообщают отсутствующие imported raw icons, stale global class `MapXbf` и ссылки generated terrain на `assets/unpacked_rfd`. Эти команды не считаются зелеными, даже если Godot возвращает zero exit code.

### [x] Этап 2. Безопасные механические перемещения (завершен 2026-07-10 в пределах подтвержденных safe moves)

Scope: механическими небольшими batches собрать camera, players, units, buildings, map и UI в явные feature-каталоги; сохранить отдельный `converters/`. Не менять API или поведение одновременно с путями.

#### [x] Этап 2A. Camera feature (завершен 2026-07-10)

Scope: перемещены без изменения логики/API/tuning:

- `scripts/rts_camera.gd(.uid)` -> `scripts/world/camera/rts_camera.gd(.uid)`, сохранен `uid://xoynnrvxuq2p`.
- `scripts/rts_camera_config.gd(.uid)` -> `scripts/world/camera/rts_camera_config.gd(.uid)`, сохранен `uid://gvuv8dd1xwfl`.
- `configs/RTSCameraConfig.tres` -> `configs/camera/rts_camera_config.tres`, сохранен resource UID `uid://nj40xd0p0abq`.

Критерии приемки и результат: все hand-authored `res://` references обновлены, старые файлы/paths отсутствуют, каждый script UID встречается ровно в одном `.uid`, resource UID объявлен ровно в одном `.tres`. Ignored `assets/` старых ссылок не содержали. В пользовательском `.godot` найдены семь stale path-записей; они не менялись и не использовались при проверке. Characterization runner сохранил 60/60 assertions; clean-cache import, `rts_camera.gd --check-only` и camera-only run с assigned/fallback config прошли.

Проверка:

```sh
rg 'res://(scripts/rts_camera(_config)?\.gd|configs/RTSCameraConfig\.tres)' --glob '!REFACTORING_PLAN.md' --glob '!.godot/**' --glob '!assets/**'
./tools/godot-container godot --headless --path /workspace --script res://tests/characterization/run.gd
# PASS: 60 assertions
# Camera parse/load проверены в минимальном Godot 4.7 project с read-only mounts новых каталогов и отдельным cache.
```

#### [x] Этап 2B. Players/rules audit и TechnologyTree move (завершен 2026-07-10)

Scope и результат:

- `scripts/players/` уже является feature-папкой; `player_data.gd(.uid)` и `player_roster.gd(.uid)` осознанно оставлены на месте.
- `scripts/rules/` уже является feature-папкой. Move `*_config.gd(.uid)` в дополнительный `types/` отложен до восстановления воспроизводимой rules generation: 937 ignored generated `.tres` напрямую ссылаются на 19 текущих config script paths, а редактировать generated output вручную нельзя.
- `scripts/technology_tree.gd(.uid)` -> `scripts/buildings/technology_tree.gd(.uid)`; сохранен `uid://c47ew38llxitx`, логика/API не менялись. Generated coupling для этого файла не найден; tracked paths обновлены в `building_controller.gd`, characterization runner и командах этого плана.

Критерии приемки и результат: старый path отсутствует вне move history и одной stale записи пользовательского `.godot`; UID встречается ровно в одном `.uid`; characterization runner прошел 60/60 assertions; новый script прошел `--check-only` с отдельным bind-cache. `players/`, `rules/`, 2C и 2D не перемещались.

Проверка:

```sh
rg 'res://scripts/technology_tree\.gd' --glob '!REFACTORING_PLAN.md' --glob '!.godot/**' --glob '!assets/**'
./tools/godot-container godot --headless --path /workspace --script res://tests/characterization/run.gd
# PASS: 60 assertions
./tools/godot-container godot --headless --path /workspace --script res://scripts/buildings/technology_tree.gd --check-only
# PASS с отдельным чистым bind-cache
```

#### [x] Этап 2C. Units/buildings/UI audit и Unit move (завершен 2026-07-10)

Scope и результат:

- `scripts/ui/` уже является feature-папкой; UI-файлы осознанно оставлены на месте.
- На момент 2C `scripts/buildings/` уже содержал controller/order/technology tree, а `scripts/building.gd(.uid)` не перемещался из-за прямого converter/generated coupling; это defer закрыт воспроизводимой regeneration в 3C. Generated output вручную не редактируется.
- `scripts/unit.gd(.uid)` -> `scripts/units/unit.gd(.uid)`; сохранен `uid://b8jny81h54ryp`, логика/API не менялись. Gameplay script был прикреплен только к трем hand-authored wrapper scenes; их paths обновлены, а ignored converted models остаются visual-only children.

Критерии приемки и результат: старый Unit path отсутствует вне move history/stale cache; UID встречается ровно в одном `.uid`; characterization runner прошел 60/60 assertions в отдельном clean bind-cache. Moved script прошел `--check-only`, а `unit.tscn`, `or_apc.tscn` и `niab_tank.tscn` загрузились с точным новым script path в минимальном внешнем project с временными binary visual stubs. Stale user cache ожидаемо отклонил новый script с exit code 1 и не использовался как green. UI/building files и этап 2D не перемещались.

Проверка:

```sh
rg 'res://scripts/unit\.gd' --glob '!REFACTORING_PLAN.md' --glob '!.godot/**' --glob '!assets/**'
./tools/godot-container godot --headless --path /workspace --script res://tests/characterization/run.gd
# PASS: 60 assertions с отдельным чистым bind-cache
./tools/godot-container godot --headless --path /workspace --script res://scripts/units/unit.gd --check-only
# PASS с отдельным минимальным project/cache; три wrapper scenes также загружены
```

#### [x] Этап 2D. Map runtime coupling audit/defer (завершен 2026-07-10)

Ни один map-файл не перемещен: частичный move потребовал бы ручной правки ignored generated outputs или оставил бы map feature еще сильнее разделенным между runtime и converters.

| Пара, сохраненный UID | Tracked runtime readers | Converters/tools | Ignored generated outputs (stale до 5C) |
| --- | --- | --- | --- |
| `scripts/world/map/map_loader.gd(.uid)`, `uid://cqiexq260wh44` | `match.gd` и `BuildingController` используют `MapLoader`; loader preload-ит moved navigation grid и загружает Godot-native `map_data.tres` | `map_bake_builder.gd` preload-ит moved script и назначает его root через `set_script()` | `terrain.tscn` еще содержит old ext_resource path; не редактируется вручную |
| `scripts/world/map/map_navigation_grid.gd(.uid)`, `uid://bj5g580fdqsw8` | `map_loader.gd` создает grid; `match.gd` и `BuildingController` вызывают runtime queries через `terrain.navigation_grid` | `map_navigation_grid_builder.gd` создает complete grid через typed `load_generated`; `map_bake_builder.gd` и `nav_grid_check.gd` вызывают builder | Прямого script ext_resource нет, baked nav arrays записываются в `map_data.tres` |
| `scripts/world/map/baked_map_data.gd(.uid)`, `uid://dadroggstib3b` | `MapLoader` читает serialized data contract | `map_bake_builder.gd` создает и заполняет resource | `map_data.tres` еще содержит old script path; не редактируется вручную |
| `scripts/world/map/terrain.gdshader(.uid)`, `uid://bbdgfua3yqgke` | Runtime получает shader через generated terrain materials | `map_bake_builder.gd` preload-ит moved shader при построении материалов | `terrain.tscn` еще содержит old shader path; не редактируется вручную |
| `converters/map_navigation_grid_builder.gd(.uid)`, `uid://b0euq7dc7dfg0` | Нет runtime readers | Единственный owner raw map navigation input, terrain attrs, source resampling, reports и debug summary | Не сериализуется |

Read/write path: `convert_map.gd` вызывает `MapBakeBuilder`; converter-only `MapNavigationGridBuilder` читает XBF/CPF, строит source-derived navigation arrays/reports и atomically передает их runtime `MapNavigationGrid.load_generated(...)`. `MapBakeBuilder` serializes these arrays in `BakedMapData` and writes `map_data.tres` plus `terrain.tscn`. Текущий generated output устарел: `terrain.tscn` содержит 16 texture references на `res://assets/unpacked_rfd`, а `map_data.tres` еще 2 metadata paths туда же.

Порядок будущего этапа 5:

1. [x] Зафиксировать tests текущего Godot-native baked contract, runtime queries и failed-load semantics.
2. [x] Отделить runtime baked-grid/query API от XBF/CPF parsing/building под `converters/`; runtime `scripts/` не импортирует `converters/`.
3. [x] Одним batch переместить четыре пары в `scripts/world/map/`, сохранив UID, и обновить все tracked runtime/converter references.
4. [ ] Исправить converter source/texture fallback paths, затем штатно пересоздать `map_data.tres` и `terrain.tscn`; generated файлы вручную не редактировать.
5. [ ] Проверить regenerated output и загрузить карту с отдельным clean cache.

Этап 2 закрыт без заявления, что вся целевая структура уже достигнута. На момент закрытия сознательно оставлялись `scripts/main.gd` до decouple composition root в этапе 4 и четыре map-пары до этапа 5; эти defer затем закрыты в 4C и 5B соответственно. `scripts/rules/*_config.gd(.uid)` остается отложенным до восстановления воспроизводимого `rules-export` и финального path/type cleanup этапа 6. Building script move/regeneration закрыт в 3C.

### [x] Этап 3. Разделение BuildingController (завершен 2026-07-10)

Продажу и orchestration оставить тонкому feature-controller, пока для них нет отдельной переиспользуемой границы.

#### [x] Этап 3A. Production queue/state/charging (завершен 2026-07-10)

Scope: извлечь lifecycle одного building order в asset-independent `RefCounted` `BuildingQueue`; controller остается владельцем availability, player resource binding, `SidePanel`/`QueueSlot` mapping и placement handoff. Queue API: `start(building_id, display_name, cost, build_time_ticks)`, `tick(delta, available_credits, spend_credits)`, `pause`, `resume`, `cancel`, `take_ready`, `has_order`, `current_order`, `lacks_funds` и single-fire `order_ready`.

Сохраненная семантика: `BUILD_TICKS_PER_SECOND = 60`; positive-cost order advances only through paid credits at `cost / (build_time_ticks / 60)`, its displayed progress is `paid_cost / cost`; zero-cost order advances elapsed ticks. There is no catch-up while money is absent. For a partial charge, whole `credits_due` is removed from the accumulator before only available credits are spent, so unpaid whole credits are not retried; cancel returns exactly `paid_cost`; ready clears manual pause and is emitted once; placement cancellation keeps the ready order, while successful placement consumes it once through `take_ready`.

Contract: queue rejects an empty building id, negative cost, non-positive tick duration and a start while an order exists. Controller preserves its prior config normalization (cost clamped to zero, build duration floored to one tick) before calling queue. `tests/buildings/run.gd` must load only queue/order and exercise this API, with completion-token failure protection and exit 1 on failure. Mark this substage complete only after controller integration, a newly generated Godot `.uid` for each new script, clean isolated import/class-cache validation, queue tests and characterization tests all pass.

Результат: добавлены `building_queue.gd`, UID `uid://bnxdqdhqk57t8`, и asset-independent runner с UID `uid://dejbjnbhoql1o`. `BuildingController` делегирует lifecycle/math/refund queue, передавая только текущий balance и `PlayerData.spend_money`; он сохраняет availability, player/UI binding и placement, а успешный spawn вызывает `take_ready`. Чистый минимальный Godot 4.7 project с копиями только queue/order/test sources зарегистрировал оба global classes без diagnostics; source runner прошел 38 assertions, characterization сохранил 60/60; queue и controller прошли `--check-only`. Controller check не потребовал generated placement/map assets, но полный main по-прежнему не является проверкой из-за известного missing generated/raw map blocker.

#### [x] Этап 3B. Placement preview/validation/spawn (завершен 2026-07-10)

Scope и результат: `BuildingPlacement` владеет active id/display name/footprint, preview nodes/materials, anchor/buildability, grid occupancy, raycast, spawn и placed-building animation. Его explicit dependencies через `setup` — camera, navigation grid, buildings root, четыре injected preview `PackedScene` и `Callable` resolver occupy rows existing building; script не preload-ит generated assets и не знает UI, queue, players, technology или rules catalog. Controller resolver сохраняет legacy order: `building_config`, затем rules lookup по `config_id`. Public API: `setup`, `begin`, `process`, `try_place`, deterministic `try_place_at_hover_cell`, `cancel`, `is_active`, `display_name`; `PlaceResult` отличает inactive, terrain, validation, scene/root и successful spawn.

Controller сохраняет input routing, `SidePanel` mapping/status text, ready queue и rules-derived footprint/scene path/local owner id. Он предварительно валидирует pointer/grid до lookup scene path, поэтому precedence observable statuses сохранен: terrain, cannot-build, missing scene, invalid scene/root, placed. Right-click/sell-mode cancel очищает только placement и оставляет ready order; only `PlaceResult.PLACED` вызывает `BuildingQueue.take_ready()` и refresh ровно один раз. Failures оставляют order и active placement.

`tests/buildings/placement_run.gd` (20 assertions, completion token, no controller/assets/maps/converters) covers invalid begin, cancel, failed injected scene retaining active state, fake-grid footprint anchor/center, direct-config and resolver-fallback occupancy rejection, and single successful injected-scene spawn handoff. Physics camera raycast and generated preview/material visuals remain integration gaps; their behavior was mechanically moved and controller parse is checked with existing ignored dependencies.

#### [x] Этап 3C. Building script move/regeneration (завершен 2026-07-10)

Результат: `scripts/building.gd(.uid)` механически moved to `scripts/buildings/building.gd(.uid)` with unchanged UID `uid://bqgxj7lpphjo0`; logic/API unchanged. `converters/building_bake_builder.gd` now preloads the moved path. The standard converter regenerated ignored local outputs (never hand-edited):

```sh
./tools/godot-container godot --headless --path /workspace --script res://converters/convert_building.gd -- --building ATConYard
./tools/godot-container godot --headless --path /workspace --script res://converters/convert_building.gd -- --building ATSmWindtrap
./tools/godot-container godot --headless --path /workspace --script res://converters/convert_building.gd -- --building ATBarracks
```

Each command wrote its corresponding `assets/converted/buildings/<ID>/<ID>.scn` and imported five H-state XBF files. A separate clean-cache minimal project copied only the moved Building/PlayerData scripts and three regenerated scenes: Godot registered `Building` from the new path; dependency inspection, load and `Node3D` instantiate passed for all three scenes. Generated ignored outputs remain local and are not commit inputs.

Критерии приемки: queue тестируется без scene tree/UI; placement получает явные map/camera/buildings dependencies; ни queue, ни placement не обращаются к `SidePanel`; pause/cancel/refund/readiness и placement feedback сохраняют characterization behavior; controller заметно уменьшается и только координирует части. Все 3A--3C batches завершены.

Критерии последнего batch: старый `res://scripts/building.gd` отсутствует; script/UID и converter reference указывают на новый path; regenerated ConYard/Windtrap (или фактически используемые building scenes) загружаются с отдельным clean cache.

Проверка:

```sh
make godot-check
./tools/godot-container godot --headless --path /workspace --script res://tests/characterization/run.gd
./tools/godot-container godot --headless --path /workspace --script res://tests/buildings/run.gd
./tools/godot-container godot --headless --path /workspace --script res://tests/buildings/placement_run.gd
timeout 30s ./tools/godot-container godot --headless --path /workspace --quit-after 10
```

### [x] Этап 4. Decouple gameplay от UI (завершен 2026-07-10)

#### [x] Этап 4A. ID intents и ownership build options (завершен 2026-07-10)

Scope: `SidePanel` больше не содержит gameplay catalog `BUILDING_IDS`. Текущий composition root `scripts/match/match.gd` временно владеет ordered demo IDs `ATSmWindtrap`, `ATBarracks` и передает тот же список UI и `BuildingController`. UI хранит только slot-to-ID display mapping, отправляет intent с `building_id` и mouse button, а его icons/layout остаются UI concern. Controller принимает IDs в setup, держит private typed copy, загружает/проверяет/refresh-ит только их и не знает tab или slot index в queue intent handler; прямые `SidePanel`/`QueueSlot` presentation calls сознательно остаются до 4B.

Проверка и результат: UI gameplay catalog удален; `building_intent_pressed(building_id, button_index)` и `set_building_slot_state(building_id, ...)` не передают внешний slot/tab contract; один `DEMO_BUILDING_OPTION_IDS` передан обоим получателям. Сохранены порядок, icons, tabs и left/right queue semantics. Existing asset-independent runners remain the coverage for unchanged queue/placement/data behavior; ID-to-slot/UI signal path needs raw icon imports and SceneTree, so it was checked through the local UI fixture rather than a new asset-independent abstraction. Следующий шаг — 4B: убрать direct controller-to-`SidePanel`/`QueueSlot` presentation dependency.

#### [x] Этап 4B. Controller presentation decoupling (завершен 2026-07-10)

Результат: добавлен feature-owned `BuildingOptionState` (`RefCounted`, UID `uid://c5fkodvshlk7d`) с `AVAILABLE`/`DISABLED`/`BLOCKED`/`PROGRESS`/`READY`, ID, progress, status и tooltip. `BuildingController` больше не упоминает UI и принимает только map/camera/buildings/options в `setup`; public `handle_building_intent(building_id, button_index)` безопасно отклоняет чужой ID/unsupported button, а `handle_command(command)` обрабатывает Sell и Repair, возвращая `false` для composition-root fallback. Outputs: `building_option_state_changed(BuildingOptionState)`, `resources_changed(credits, energy)`, `sell_mode_changed(active)` и existing `status_changed`.

`match.gd` — единственный wiring: сначала configures options и connects panel intents/commands plus all controller outputs, затем calls setup so initial resources/options/sell emissions не теряются. Repair сохраняет status `Command: Repair (not implemented)` через controller, unknown command сохраняет прежний match fallback; panel command имеет одного consumer. `SidePanel` preload-ит feature state, cache-ит latest states по ID и resources/sell, maps enum исключительно в internal `QueueSlot.State` и reapplies cached state после building tab/grid rebuild. Поэтому скрытие/recreation UI не требует controller tab callback и не теряет READY/PROGRESS/DISABLED.

Проверка и результат: forbidden search `SidePanel|QueueSlot|PanelTab|scripts/ui|scenes/ui` в controller пуст; changed scripts `--check-only` прошли. Local clean-cache UI fixture прошел 16 assertions (resources, sell, enum mapping, cached progress/blocked state after tab rebuild, left/right ID intents); controller-without-UI smoke прошел 9 assertions, включая initial outputs, input validation и Repair/Sell routing. Existing runners: placement 20/20, queue 38/38, characterization 60/60. Clean UI fixture also confirms class registration of the new model; full main remains blocked only by ignored generated terrain references to missing `assets/unpacked_rfd` textures. Следующий шаг — только 4C composition-root cleanup/move.

#### [x] Этап 4C. Composition root cleanup/move (завершен 2026-07-10)

Результат: `UnitCommandController` (`scripts/match/unit_command_controller.gd`, UID `uid://c6542mna0xvf5`) владеет selected unit state, left-select/right-move input, owner/relation presentation, raycasts, ownership check и nav debug suffix. Его API — `setup(camera, terrain)`, `handle_unhandled_input(event) -> bool`, `selection_text(status)` и `status_changed`; он не знает HUD, building UI/controller или demo roster. `match.gd` остается lifecycle/composition root: demo players, SidePanel--BuildingController wiring, controller creation, priority building before unit input, initial map/entity snapping и FPS/HUD adapters. Building statuses проходят через `selection_text`, сохраняя selected-unit prefix.

Механические moves: `scripts/main.gd(.uid)` -> `scripts/match/match.gd(.uid)` с preserved `uid://3psqgxv6e2ys`; `scenes/main.tscn` -> `scenes/match/demo_match.tscn` с preserved scene UID `uid://b3s2wqci2m81v`. Scene ext_resource и `project.godot` main scene обновлены; compatibility copies отсутствуют. Ignored local `scenes/debug/screenshot.gd` сознательно остается со старой ссылкой `res://scenes/main.tscn` и не входит в tracked refactor/commit. `tests/match/unit_command_run.gd` (UID `uid://cg5kwprkutaq`) добавляет 13 asset-independent assertions for ancestor selection/clear, owner text, enemy rejection before terrain raycast, movement mask/status and no-selection right click.

Проверка и результат: changed scripts parse; new controller and moved match script registered on clean cache; placement 20/20, queue 38/38, characterization 60/60 and unit-command 13/13 passed. Tracked old `res://scripts/main.gd`/`res://scenes/main.tscn` references are absent and UIDs unique. Full new main scene remains blocked by the known ignored generated terrain references to missing `assets/unpacked_rfd` textures; ignored `.godot` still contains stale old paths and was not edited.

Критерии номерного этапа: building gameplay запускается и тестируется без `SidePanel`; raw icon paths и layout остаются UI concerns; команды преобразуются в feature API в одном composition root.

Проверка:

```sh
rg 'SidePanel|scripts/ui|scenes/ui' scripts/buildings
make godot-check
./tools/godot-container godot --headless --path /workspace --script res://tests/characterization/run.gd
./tools/godot-container godot --headless --path /workspace --script res://tests/buildings/run.gd
./tools/godot-container godot --headless --path /workspace --script res://tests/buildings/placement_run.gd
./tools/godot-container godot --headless --path /workspace --script res://tests/match/unit_command_run.gd
timeout 30s ./tools/godot-container godot --headless --path /workspace --quit-after 10
```

### [ ] Этап 5. Разделение runtime map и converters

Scope: определить стабильный формат baked map data; оставить `converters/` ответственным за XBF/CPF/CPT parsing и генерацию, а map feature runtime — только за загрузку Godot-native `.tres`/`.tscn`, навигационные запросы и освещение. Подэтапы не смешивают behavioral fix, split/move и regeneration.

#### [x] Этап 5A. Runtime contract и атомарная загрузка (завершен 2026-07-10)

Добавлен asset-independent `tests/maps/run.gd` (Godot-generated UID `uid://bukip8we7p1of`): 6 cases, 35 assertions, completion-token protection и exit 1. Runner создает только in-memory `BakedMapData` с полными `Packed*` arrays и временные `user://` `.tres`; он не читает raw/generated map assets и не вызывает XBF/CPF/CPT parser. Временные ресурсы удаляются в конце процесса.

Зафиксированный runtime-only contract для сохранения в 5B:

- `BakedMapData` передает `source_map_dir`, `world_scale`, `nav_world_bounds`, reports и все восемь 256×256 navigation arrays (`cpf`, terrain, source X/Y, spice, pass mask, movement cost, buildable). `MapNavigationGrid.load_baked(Resource)` требует positive X/Z bounds и ровно 65,536 элементов в каждом array.
- Успешный `load_baked` одновременно публикует source/bounds/arrays/reports и `is_loaded() == true`. Rejection не изменяет уже loaded grid; initial rejection оставляет его unloaded, а `cell_debug` возвращает invalid result без обращения к partial arrays. Следующий valid load после rejection полностью заменяет grid.
- `world_to_grid` clamp-ит X/Z world bounds, включая max edge в cell `(255,255)`; `grid_to_world(cell, true)` возвращает center, `false` — minimum corner. `cell_debug` для valid cell сохраняет grid/world center/source tile/CPF/terrain id+name/spice/pass mask/movement cost/buildable, а out-of-bounds/unloaded result — только `valid: false` и `grid`.
- `MapLoader.load_map` строит candidate data/grid и commit-ит `map_data`, `terrain_aabb` и `navigation_grid` только после successful baked-grid validation; lighting и logging выполняются только после этого commit. Missing/unloadable/malformed replacement сохраняет последнюю valid map и ее AABB/grid; initial failure оставляет все три fields empty/default, а subsequent valid load atomically заполняет все три fields. Это закрывает deferred map-failure часть 1B.

Воспроизведенный bug: прежний `MapNavigationGrid.load_baked` записывал fields до validation, а `MapLoader.load_map` заменял `map_data`/AABB и обнулял navigation grid при failure. Минимальный fix — validate-before-commit в grid и candidate commit-on-success в loader. Runner покрывает successful grid load, edge/center conversions, valid/out-of-bounds debug fields, invalid bounds and short terrain/CPF arrays, success after failure, valid replacement, malformed/missing loader replacement, initial missing/malformed state и successful loader recovery after initial failures.

Проверка:

```sh
./tools/godot-container godot --headless --path /workspace --script res://tests/maps/run.gd
# PASS: 35 assertions (intentional malformed fixtures emit validation diagnostics)
```

#### [x] Этап 5B. Converter boundary split и mechanical map move (завершен 2026-07-10)

Новый converter-only `MapNavigationGridBuilder` (`converters/map_navigation_grid_builder.gd`, Godot UID `uid://b0euq7dc7dfg0`) предоставляет `build(dir, bounds, source_xbf = null, world_scale = 1.0) -> MapNavigationGrid?`. Он владеет XBF/CPF file loading, tile-grid sizing, spice sizing, source-to-256² resampling, terrain passability/movement/buildability rules, histograms/reports и прежним navigation summary. Builder использует public runtime constants и передает полный typed набор arrays/reports через narrow `MapNavigationGrid.load_generated(...)`; runtime validates and atomically commits this data without accepting parser types.

`MapBakeBuilder` и `nav_grid_check` теперь вызывают builder. Raw algorithm сохранен: same source tile formula, terrain attributes, spice normalization, CPF statistics/deltas/top-count reports, source reports и diagnostics; terrain rules не дублируются в runtime. Runtime `MapNavigationGrid` сохраняет 5A `load_baked`, state atomicity, conversions, debug fields, terrain naming и safe unloaded `save_debug_image`, но не содержит converter preload, raw parser, file read или source-grid construction.

Mechanical moves с сохранением UID:

- `scripts/map_loader.gd(.uid)` -> `scripts/world/map/map_loader.gd(.uid)`, `uid://cqiexq260wh44`.
- `scripts/map_navigation_grid.gd(.uid)` -> `scripts/world/map/map_navigation_grid.gd(.uid)`, `uid://bj5g580fdqsw8`.
- `scripts/baked_map_data.gd(.uid)` -> `scripts/world/map/baked_map_data.gd(.uid)`, `uid://dadroggstib3b`.
- `scripts/terrain.gdshader(.uid)` -> `scripts/world/map/terrain.gdshader(.uid)`, `uid://bbdgfua3yqgke`.

Tracked runtime, converter and map runner preloads обновлены. Ignored generated `map_data.tres`/`terrain.tscn` сознательно не изменялись и еще содержат old paths/source texture references; это единственный 5C gap, не map-load claim.

Проверка: forbidden actual runtime-dependency search (`res://converters`, converter preload/parser symbols/calls) пуст; raw-format terms допустимы только в comments/diagnostic text, не в imports, file parsing или runtime construction. Old tracked paths отсутствуют вне plan/history; Godot зарегистрировал moved classes и builder, moved/runtime/converter `--check-only` прошли; maps 35/35, unit 13/13, placement 20/20, queue 38/38 и characterization 60/60 прошли. Конверсия карты не запускалась.

#### [ ] Этап 5C. Regenerate и clean load

Scope: исправить converter source/texture fallback paths и штатно regenerate `map_data.tres`/`terrain.tscn`, не редактируя generated files вручную. Проверить отсутствующие `assets/unpacked_rfd` references, актуальные script/shader paths, clean-cache load map data/terrain и отдельно converter плюс `nav_grid_check.gd`.

Критерии номерного этапа после 5C:

- Runtime map не читает original formats и не импортирует `converters/`; XBF/CPF/CPT parsing и raw navigation build остаются converter-only.
- Четыре `.gd/.gdshader` пары перемещены вместе с прежними UID; все runtime и converter references обновлены, старые paths отсутствуют.
- `convert_map.gd` воспроизводимо регенерирует `map_data.tres` и `terrain.tscn`; generated output не содержит `res://assets/unpacked_rfd`, включая terrain texture fallback paths и source metadata.
- Regenerated `terrain.tscn` использует актуальные MapLoader/shader paths, `map_data.tres` использует актуальный data script, а `demo_match.tscn` инстанцирует существующий output.
- Отдельный clean-cache test загружает `map_data.tres` и `terrain.tscn`, подтверждает loaded navigation grid/runtime queries и согласованное 5A failed-load state.
- Converter и `nav_grid_check.gd` запускаются headless отдельно; ошибки версии/формы baked data валидируются понятной диагностикой.

Проверка после 5C:

```sh
rg 'res://converters|MapXbf|MapXbfScript|_load_cpf|_build_nav_cells|_first_existing_map_path' scripts/world/map
make godot-check
./tools/godot-container godot --headless --path /workspace --script res://tests/maps/run.gd
./tools/godot-container godot --headless --path /workspace --script res://converters/nav_grid_check.gd
```

### [ ] Этап 6. Финальная типизация, валидация и документация

Scope: заменить оставшиеся необоснованные `Resource`/Variant/dynamic `call` на feature-типы, добавить валидацию обязательных exports/resources и документировать итоговые feature boundaries, generated-assets workflow и команды разработки. Не делать массовую косметическую переработку.

Критерии приемки: headless parse не сообщает ошибок; public feature API типизированы; некорректные config/baked data завершаются понятной диагностикой; README и этот план отражают фактические пути и workflow; characterization и feature tests проходят.

Проверка:

```sh
make godot-check
./tools/godot-container godot --headless --path /workspace --script res://tests/characterization/run.gd
timeout 30s ./tools/godot-container godot --headless --path /workspace --quit-after 10
git status --short
```

## Журнал прогресса

- 2026-07-10: создан план. Этап 0 завершен: исправлен path camera config с сохранением UID, export `config` типизирован; узкие parse/runtime проверки камеры на чистом внешнем cache прошли. Полный main заблокирован устаревшими generated map assets, точная диагностика записана в результате этапа 0. Этап 1 не начат.
- 2026-07-10: этап 1 разделен на 1A/1B. Этап 1A завершен: добавлен asset-independent runner (60 assertions), исправлены stale roster connections, subhouse availability и reset demo match. Scene-bound controller/ownership/map cases явно deferred в 1B к этапам 3/5; этап 2 не начат.
- 2026-07-10: этап 2 разделен на batches. Этап 2A завершен механическим move camera feature с сохранением трех UID и проверкой на отдельном чистом cache; этапы 2B-2D pending, другие features не перемещались.
- 2026-07-10: этап 2B завершен: `players/` и `rules/` признаны уже корректными feature-папками, rules config move отложен до воспроизводимой регенерации 937 generated resources; `TechnologyTree` механически перемещен в `scripts/buildings/` с прежним UID. Этапы 2C-2D не начаты.
- 2026-07-10: этап 2C завершен: UI/buildings audit оставил уже сгруппированные файлы на месте, `building.gd` отложен до воспроизводимой регенерации binary scenes; Unit механически перемещен в `scripts/units/` с прежним UID, три wrapper scenes проверены изолированно. Этап 2D не начат.
- 2026-07-10: этап 2D и механический этап 2 завершены audit/defer решением: map runtime files не перемещались из-за прямого converter/generated coupling; атомарное разделение, move и регенерация запланированы в этапе 5.
- 2026-07-10: этап 3A завершен: lifecycle одного building order извлечен в asset-independent `BuildingQueue` с созданными Godot UID и 38-assertion runner; controller теперь только передает player spending и оркестрирует availability/UI/placement handoff. Чистый isolated class-cache import, queue runner, characterization 60/60 и оба `--check-only` прошли.
- 2026-07-10: этап 3B завершен: `BuildingPlacement` получил injected camera/grid/root/preview dependencies, spatial state, validation, preview, spawn и animation; controller оставил input/UI/status/queue/rules orchestration. Asset-independent fake-grid runner прошел 20 assertions, включая resolver-fallback occupancy regression; camera physics and generated preview visuals остаются integration gap.
- 2026-07-10: этап 3C и номерной этап 3 завершены: `Building` moved with preserved `uid://bqgxj7lpphjo0`, converter preload обновлен, а ignored `ATConYard`, `ATSmWindtrap` и `ATBarracks` scenes штатно regenerated (five H-state XBF each). Separate clean-cache dependency/load/instantiate check подтвердил новый script path для всех трех; generated output local-only и не входит в commit.
- 2026-07-10: этап 4 разделен на 4A--4C. 4A завершен: demo option IDs временно принадлежат `main.gd` и одним ordered list передаются `SidePanel` и `BuildingController`; SidePanel sends ID-based building intents and resolves its own slot mapping, controller no longer reads UI catalog or accepts tab/slot queue input. Direct presentation dependency остается следующим scope 4B; main move — только 4C.
- 2026-07-10: этап 4B завершен: controller publishes feature-owned option/resource/sell presentation and handles feature commands without loading UI; `match.gd` owns all UI adaptation and SidePanel caches typed option states across tab rebuilds. Clean local UI fixture, no-UI controller smoke and existing feature runners passed; generated terrain texture references remain the unrelated full-main blocker. 4C pending.
- 2026-07-10: этап 4C и номерной этап 4 завершены: selection/move/ownership presentation extracted to `UnitCommandController`; composition root and demo scene moved with preserved UIDs, tracked entry-point references updated, and an asset-independent unit-command runner added. Full demo scene remains blocked only by ignored stale generated terrain texture paths; ignored editor cache old paths were not edited.
- 2026-07-10: этап 5 разделен на 5A--5C. 5A завершен: runner без map assets/parser покрывает 35 assertions runtime baked-grid/map-loader contract, включая recovery `MapLoader` после initial failures; воспроизведенные partial-state failures исправлены validate-before-commit в `MapNavigationGrid` и candidate commit-on-success в `MapLoader`. 5B split/move и 5C regeneration/load не начаты.
- 2026-07-10: этап 5B завершен: raw navigation conversion перенесена в converter-only `MapNavigationGridBuilder`, runtime grid получил narrow atomic generated-data seam, а четыре map runtime/shader пары moved в `scripts/world/map/` с сохраненными UID. Converter users и asset-independent map runner используют новые paths; generated output не трогался, поэтому 5C regeneration/load остается pending.
