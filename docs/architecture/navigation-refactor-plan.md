# Навигация юнитов: перф-фиксы + распил + air/ground split + funnel + ORCA

## Context

Текущее движение юнитов (`scripts/units/navigation/`) — грид-A* (AStarGrid2D 256×256, clearance запечён) + самодельный candidate-angle avoidance. По ощущениям близко к оригинальному Emperor, но по современным меркам движение плохое; координатор `unit_navigation_system.gd` разросся до 1813 строк; юнит с недостижимой целью обрушивает FPS. Решение (согласовано): грид-план **оставить** (идеален для тайловых карт Emperor), поднять локальный слой до уровня SC2: ORCA вместо candidate-sampling, funnel-сглаживание вместо `_simplify_path`, распил координатора, отдельные подсистемы для авиации и наземных юнитов (убрать air-ветвления из общей логики), устранить перф-провалы. Каждый этап — зелёный `make godot-test`.

**Найденные корни просадки FPS (проверено по коду):**
1. `unit_navigation_planner.gd:52` — `get_id_path(..., allow_partial_path=true)`: недостижимая цель = flood всей достижимой компоненты (~65k клеток); неудачи не кэшируются.
2. `unit_navigation_system.gd:1695-1761` — каждые 0.5s при изменении блокеров `_replan_after_map_change` синхронно репатит **всех** commanded-агентов.
3. Заблокированный юнит: второй «squeeze»-проход = ~48 оценок кандидатов/тик × (2·obstacles + 2·blockers) свипов; O(N²) в толпе.
4. Spatial hash пересоздаётся каждый тик; окно запроса раздуто радиусом самого крупного юнита на карте; полный sort агентов каждый тик; аллокации в хот-лупе.

**Связанность с тестами (проверено):** `tests/navigation/run.gd` (41 сценарий) создаёт систему как `NavigationSystemScript.new()` + `.setup(grid)`, читает `navigation.runtime_map`, дёргает `navigation.call("_navigation_tick", 0.05)` → фасад обязан остаться Node по пути `scripts/units/navigation/unit_navigation_system.gd` с `setup`, `runtime_map`, `_navigation_tick`. `tests/units/flight_run.gd` преложит `unit_local_avoidance.gd` и зовёт `_resolve_vertical_conflict`/`_decay_vertical_offset`/`VERTICAL_SEPARATION_OFFSET` напрямую — единственный тест, который правится осознанно (на этапе air-split). Ассерты почти все поведенческие (arrival 0.6–3.5, separation ≥ contact−0.01, settle 8s/30s/600 тиков, анти-джиттер счётчики); golden — только `Vector2i`-концы путей планировщика.

**Уточнённый white-box контракт тестов (проверено grep'ом по `tests/`, важно для этапа 2 — распил):** тесты обращаются не только к публичному API, но и напрямую к приватным членам фасада через `Object.call("_method", ...)` и прямой доступ к полям. Это значит: после распила на модули фасад обязан **либо оставить эти методы у себя, либо дать тонкие forwarding-обёртки с тем же именем/сигнатурой** — `Node.call()` не находит методы на вложенных RefCounted-объектах. Полный список того, что дёргается напрямую (`grep -rn 'navigation\.call(\|navigation\._agents\|navigation\.avoidance\|navigation\._blocks_conflict\|navigation\._parking_anchor\|navigation\._navigation_tick_index' tests/`):
- Поля (должны остаться полями на фасаде, не методами): `_agents: Dictionary`, `avoidance` (RefCounted, не трогаем — Stage 5), `_navigation_tick_index: int`.
- Методы, вызываемые через `.call("...")`: `_navigation_tick(delta)`, `_physics_process(delta)`, `_refresh_building_blockers()`, `_replan_after_map_change()`, `_desired_velocity(agent)`, `_has_clear_line(from, to, agent)`, `_path_chord_is_clear(agent, from, to)`, `_request_yield(agent, direction)`.
- Методы, вызываемые напрямую (не через `.call`): `_parking_anchor(destination, span)`, `_blocks_conflict(anchor_a, span_a, anchor_b, span_b)`.
- Источники: `tests/navigation/run.gd` (основная масса), `tests/navigation/jitter_probe.gd` (ручной проб, не в `godot-test`, но не должен ломаться), `tests/units/harvester_run.gd:416`, `tests/match/demo_boot_run.gd:1060,1081`.

## Целевая структура модулей (`scripts/units/navigation/`)

Фасад — единственный Node; новые модули — RefCounted (как нынешние planner/avoidance). Агент остаётся Dictionary (duck-typing в тестах и unit.gd), поля зафиксировать комментом в фасаде; добавляется поле `domain` (GROUND | AIR).

| Файл | Роль | ~строк |
|---|---|---|
| `unit_navigation_system.gd` | Фасад: весь публичный API (`register_unit/unregister_unit`, `command_move/depart/dock`, `stop`, `set_hold_position`, `can_move_to`, `arrival_tolerance`, `agent_debug`, `command_log`, `MoveMode`, сигналы), `setup()`, `runtime_map`/`planner`, 20Hz тик, `_navigation_tick` → диспетчеризация ground/air | ~300 |
| `unit_navigation_map.gd`, `unit_flight_controller.gd`, debug-ноды | Без изменений | — |
| `unit_navigation_planner.gd` | AStarGrid2D + region-labels + кэш редиректов (этап 1); после этапа 3 — только ground | ~300 |
| `shared/nav_agent_registry.gd` | Создание агентов, `_profile_for`, probes, prune, rotation envelope, вычисление `domain` | ~260 |
| `shared/nav_spatial_hash.gd` | Spatial hash (этап 5: пер-бакет max-radius, переиспользуемые массивы) | ~130 |
| `shared/nav_blocker_tracker.gd` | Скан блокеров зданий, diff клеток, бюджетная очередь репланов | ~170 |
| `ground/ground_navigation.gd` | Наземный тик: desired velocity, вызов avoidance, blocked/enemy, yielding, vacate-no-stop, `_route_agent` | ~330 |
| `ground/ground_path_follower.gd` | `_path_steering_target`, `_advanced_path_index`, `_path_lane_target`, `_path_chord_is_clear`, `_has_clear_line`, passable/stoppable, departure access | ~380 |
| `ground/ground_slot_allocator.gd` | Слоты/парковка/lanes (строки 1104–1566 сегодня) | ~520 |
| `ground/path_funnel.gd` | Radius-aware funnel по коридору A*-клеток (замена `_simplify_path`) | ~180 |
| `ground/orca_avoidance.gd` | ORCA-солвер, контракт как у `resolve_velocity(agent, desired, delta, nearby, resolved) -> {velocity, enemies, friends}` | ~400 |
| `ground/steering_stabilizer.gd` | Сохраняемое из старого avoidance: `stabilize_velocity`, `separation_velocity`, terrain sweep/pressure, `motion_is_passable`, `enemy_sweep_fraction` | ~250 |
| `air/air_navigation.gd` | Прямолинейный полёт к цели с clamp по границам карты (**без A\*** — здания/террейн для авиации открыты), arrival, вертикальный конфликт-сплит (перенос `_resolve_vertical_conflict`), латеральный spacing, спред целей для групп. Без слотов/lanes/yield/планировщика | ~220 |

Удаляется в конце: `unit_local_avoidance.gd` (783 строки).

## Этапы (каждый — зелёный `make godot-test`, отдельные коммиты)

### Этап 0 — Baseline
`make godot-test`, зафиксировать время сьютов. Ручной проб `tests/navigation/jitter_probe.gd` — прогнать для справки.

### Этап 1 — Перф quick wins (независимые, без структурных изменений)
1. **Region labels + guard недостижимости** (`unit_navigation_planner.gd`). Пер-профиль `region: PackedInt32Array` (65k), ленивый BFS-flood по eroded `solid` при bump'е revision (4-связность корректна: диагонали ONLY_IF_NO_OBSTACLES требуют обе кардинали). В `find_path`: `region[start] != region[target]` → кольцевой Chebyshev-поиск ближайшей клетки региона старта вокруг цели (cap 64 колец, паттерн `_nearest_open`), A* к заменителю — flood исчезает, UX «идти к ближайшей точке» сохраняется. Кэш редиректов `{target_index×8+profile_slot: {start_region: substitute}}`, сброс по revision. На уровне системы: `agent["route_block"] = {target_index, revision}` — не пересчитывать тот же недостижимый заказ до смены revision/приказа.
2. **Diff блокеров + адресный реплан + бюджет** (`unit_navigation_system.gd:1695-1761`, `unit_navigation_map.gd`). `replace_blocked_cells` возвращает список изменённых индексов; хранить у агента `corridor: PackedInt32Array` (сырые клетки A*); реплан только агентам, чей коридор (от `path_index`) или блок назначения пересекает изменённые клетки; очередь с бюджетом K=8 `find_path`/тик (приоритет: dirty-corridor, потом shortcut-refresh); агенты в очереди продолжают ехать по старому пути. Event-driven: `building_placement.gd:4` `signal building_placed` уже есть; на снос — подключать `tree_exiting` зданий при первом появлении (`_on_tree_node_added`:1802); поллинг 0.5s демотировать до страховки в 5s.
3. **Троттлинг squeeze-прохода** (`unit_local_avoidance.gd:126-146`): второй проход на первом blocked-тике, дальше каждый 3-й тик, пока blocked. (Временная мера — на этапе 5 squeeze удаляется совсем.)

Тест-риск: следить за `_test_blocked_target_uses_unit_approach_side`, `_test_interior_escape`. Откат: три независимых коммита.

### Этап 2 — Механический распил (поведение не меняется)
Извлечение кластеров verbatim, по одному коммиту, сьют зелёный после каждого, порядок:
1. `shared/nav_agent_registry.gd` (строки 87-165, 1600-1694, 1802-1813);
2. `shared/nav_spatial_hash.gd` (1567-1599);
3. `ground/ground_slot_allocator.gd` (1104-1566);
4. `ground/ground_path_follower.gd` (723-1062);
5. `shared/nav_blocker_tracker.gd` (1695-1761, уже diff-based после этапа 1);
6. `ground/ground_navigation.gd` (тик 508-663 + `_route_agent`/`_simplify_path`); `_navigation_tick` фасада: prune → claims → hash → `ground.tick(...)`.

Модули получают зависимости через `setup()` от фасада. Критично: сохранить порядок итерации агентов (`resolved_positions` порядкозависим). Любой красный тест здесь = ошибка пересадки, не решение.

### Этап 3 — Air/ground split
**Важно:** после этапа 2 весь код перенесён в `shared/`/`ground/` модули, координатор — 849 строк. Все номера строк ниже и в предыдущих ревизиях плана — **устарели**, ссылаются на структуру до этапа 2. Перед реализацией нужно заново прогрепать точные места (`_agent_cell_passable`/`_agent_cell_stoppable` теперь в `ground/ground_path_follower.gd`, `_profile_for` — в `shared/nav_agent_registry.gd`, `_cell_is_solid`/`_resolve_vertical_conflict`/`_decay_vertical_offset` — по-прежнему в `unit_local_avoidance.gd`, planner-гейты — в `unit_navigation_planner.gd`, не тронутом этапом 2).

- **Предикат домена** (в registry, пересчёт каждый тик — дёшево, переходы взлёта/посадки длятся ~1.5s): `AIR` если `pass_mask == PASS_AIR` и (нет метода `flight_is_airborne_phase` — покрывает FakeUnit — или он true); иначе `GROUND`. Устраняет нынешнюю несогласованность (планировщик судил по маске, runtime — по фазе).
- **Севший летун** = GROUND-домен как hold-препятствие (участвует в avoidance, не управляется). `Unit.move_to` севшего → `begin_takeoff_toward`; по завершении взлёта `unit_flight_controller.gd` сам re-issues `move_to` → предикат уже AIR → воздушный pipeline. Посадка: air летит точно в цель, flight controller снижает, домен становится GROUND-hold по `flight_is_landed()`. `unit_flight_controller.gd` не меняется.
- **Найденный реальный пробел (проверено чтением кода, не в тестах):** групповые приказы на движение (`unit_command_controller.gd`, `_command_move` → `_navigation.command_move(moving_entities, target, move_mode)`) вызывают фасад **напрямую**, минуя `Unit.move_to()` — а именно в `move_to()` (unit.gd:251-254) живёт проверка `flight_is_landed()` → `begin_takeoff_toward(...)`. Значит если в выделенную группу попадает севший летун, `command_move` получает его без какого-либо взлётного редиректа. Ни один тест это не покрывает (`grep` по `tests/units/flight_run.gd` и `tests/match/unit_command_run.gd` — пусто). **Это входит в объём этапа 3**, а не отдельный баг-фикс: сам этап уже обязывает `command_move` разделять юнитов по домену, и посадка этого случая — естественная часть той же развилки. Исправление: в `command_move`, до основного цикла назначения слотов, отфильтровать юнитов, у которых `unit.has_method("flight_is_landed")` и `unit.call("flight_is_landed")` истинно и `unit.has_method("move_to")` — для них вызвать `unit.call("move_to", world_target, exit_point)` (переиспользует существующую логику взлёта) и исключить их из этой команды (не назначать слот/путь сейчас); остальных юнитов обрабатывать как раньше. Добавить регрессионный тест: групповой приказ, включающий севший летун + обычный наземный юнит — летун должен начать взлёт, наземный — обычное движение.
- **Диспетчеризация фасада:** `command_move` делит оставшийся (не взлетающий) список по домену (air: цель + спред-офсеты, но эмитит те же `destination_slots_assigned`); `command_dock`/`command_depart` — по-юнитно; `can_move_to` для air = in-bounds.
- **Удаления (актуальные пути после этапа 2):** air-гейты в `ground/ground_path_follower.gd` (`agent_cell_passable`/`agent_cell_stoppable`), `unit_local_avoidance.gd` (`_cell_is_solid`, `_agent_cell_passable`), `unit_navigation_planner.gd` (`find_path`/`_build_profile`/`_solid_map` air-ветки), `shared/nav_agent_registry.gd` (`profile_for` air-ветки).
- **Перенос** `_resolve_vertical_conflict`/`_decay_vertical_offset`/`VERTICAL_SEPARATION_OFFSET` из `unit_local_avoidance.gd` → `air/air_navigation.gd`.
- **Осознанные правки тестов в `tests/units/flight_run.gd` (проверено чтением файла)**:
  - `_test_vertical_avoidance` (строки ~198-233) вызывает `UnitLocalAvoidanceScript.new()` и напрямую `._resolve_vertical_conflict(...)`/`._decay_vertical_offset(...)`/`.VERTICAL_SEPARATION_OFFSET` — перенацелить на новый `air_navigation.gd` (те же имена методов/константы, механическая правка).
  - `_test_buildings_ignored_at_cruise` (строки ~236-266) тестирует именно ту air-ветку `avoidance._cell_is_solid`/`planner.is_open(..., PASS_AIR, ...)`, которая по этому этапу удаляется (авиация больше не спрашивает у ground-планировщика/avoidance проходимость зданий вообще — она их не видит в принципе, только границы карты). Тест нужно переписать под новую реальность: воздушный модуль обязан беспрепятственно лететь через клетку, заблокированную для наземного профиля (проверять через `air_navigation`, а не через `planner.is_open`/`avoidance._cell_is_solid`), а `planner.is_open` с `PASS_AIR` может быть либо удалён, либо тоже пересмотрен, если авиация вообще перестаёт создавать grid-профиль.
- Опциональная страховка: фасадный `FORCE_GROUND_PIPELINE := false` на один этап.

Тест-риск: `flight_run.gd` (обе правки выше — осознанные, не случайные красные), `demo_boot_run.gd`, новый regression-тест на групповой взлёт; все 45 навигационных сценариев — ground, должны остаться зелёными без правок.

### Этап 4 — Funnel вместо `_simplify_path`
`ground/path_funnel.gd`, за флагом `USE_FUNNEL := true` (старый `_simplify_path` остаётся на один этап как откат).

Алгоритм (corridor-of-cells funnel):
- **Порталы** из последовательности A*-клеток: кардинальный шаг → общее ребро (углы, порядок left/right по направлению); диагональный шаг (стороны гарантированно открыты режимом диагоналей) → анти-диагональ открытого 2×2-блока.
- **Radius shrink только у солидных углов**: если хоть одна клетка, инцидентная углу портала, солидна для агента (agent-aware: pass mask, blocked overlay, `allowed_cells`, terrain mask) — сдвинуть конец на `m = max(0, terrain_radius − 0.2·cs)` внутрь; `2m ≥ длины` → схлопнуть в середину (деградация к сегодняшнему поведению, безопасно). Открытые углы не сжимать (clearance уже гарантирует диск).
- **Funnel** (simple stupid funnel): [текущая позиция] + порталы + [финальная точка = `destination`, если в последней клетке, иначе центр последней клетки — сохраняет UX partial-path]. Тай-брейк `cross ≈ 0` = «внутри». Выход: `PackedVector3Array` мировых точек (y=0).
- **Интеграция:** `agent["path"]` → `agent["path_points"]: PackedVector3Array`; `_path_steering_target`/`_advanced_path_index`/`_path_lane_target`/debug переходят с `grid_to_world(path[i])` на точки — механически; chord binary-search, corridor gates и lane-офсеты не меняются. `corridor` (сырые клетки) хранится параллельно для diff-репланов этапа 1. Пути ≤ 2 клеток → [финальная точка]; `direct_path` без изменений; `_has_clear_line` остаётся для прочих вызовов.

Выигрыш плана: O(P) вместо O(turns²)·clearance² — ~50-100× на реплан, умножается с бюджетной очередью. Тест-риск (легитимные изменения геометрии): corner/lookahead/lane сценарии (`_test_large_unit_steers_smoothly_around_corner`, `_test_jagged_boundary_steering_stays_smooth`, `_test_continuous_corner_steering`, `_test_path_lookahead_smooths_waypoint_corner`, `_test_path_chord_uses_rounded_geometry`, `_test_missed_waypoint_advances_through_route_gate`, `_test_group_rounds_sharp_corner`, `_test_large_pair_keeps_lanes_at_shared_corner`). Анти-джиттер должен улучшиться; ретюн порогов — только осознанным комментированным коммитом. Golden-концы путей планировщика не затронуты (funnel — постобработка).

### Этап 5 — ORCA (самое крупное изменение поведения — последним)
За флагом `USE_ORCA := true`; кандидатный путь остаётся на один этап.

- **Перестройка тика на две фазы** (пререквизит взаимности ORCA), обе в порядке возрастания id (детерминизм):
  - Фаза 1 (compute): `v_pref = _desired_velocity` (слоты/lanes/exit/yield не трогаем) → соседи → ORCA-линии от позиций начала тика и `orca_velocity` прошлого тика → LP → `agent["new_velocity"]`.
  - Фаза 2 (apply): существующие `separation_velocity` / passability clamp / `stabilize_velocity` / `navigation_step`; затем `orca_velocity = (pos_now − pos_start)/delta` (устойчиво к turn-in-place). Позиции начала тика — в переиспользуемом `PackedVector3Array` по `agent["slot"]`.
- **Agent-agent линии**: стандартный RVO2 (truncated cone apex `p/tau`, cutoff-disc/leg-ветки verbatim; overlap → `w = v − p/delta`). **Доли ответственности** (SC2-приоритет движущихся): MOVING/MOVING 0.5; MOVING/IDLE 0.25/0.75 (эмерджентный «толчок» стоящих — после смещения idle-агента снапить `destination` через существующий `_snapped_parking`); HOLD — не толкается никогда (его линии для соседей hard, сам линий не строит; докнутый харвестер); ENEMY — взаимно hard, доля 1.0 (сохраняет `enemy_stays_solid_under_separation`); IDLE/IDLE 0.5.
- **Террейн как диск-препятствия** (не сегменты): солидная клетка = вписанный диск (уже так в `_terrain_context`:533, переиспользуем bucketed-кэш `_obstacle_profile`:597); только boundary-клетки (бит в бейке профиля); ближайшие ≤ `MAX_OBST_LINES = 10` по dist², тай-брейк по индексу; `escape`-исключение сохранить. Terrain-линии hard + один страховочный `terrain_sweep_fraction` в фазе 2 (вместо ~96 сегодня) + `enemy_sweep_fraction`.
- **LP детерминированный**: RVO2 linearProgram1/2/3 без random shuffle — фиксированный порядок: hard (террейн по индексу клетки, потом enemy/HOLD по id), затем soft-friendly по id; LP3 минимизирует нарушение только soft-линий. n ≤ ~18. Scratch — модульные PackedArray'и, без Dictionary в хот-лупе.
- **Squeeze-замена**: если после LP `|result| < 0.25·|v_pref|` и был вход в LP3 (заперт друзьями) → повторный LP2 только по hard-линиям, вернуть `0.5×result`; оверлап растворяет нетронутый `separation_velocity`. Старый squeeze-проход удаляется. **Reverse suppression**: результат против `route_direction` более чем на 90° и без овердлапа → стоп (сохраняет поведение харвестера без 180°-разворотов).
- **Не-holonomic**: как сегодня — ORCA решает holonomic, `stabilize_velocity` + `_turn_toward`/turn-in-place остаются байт-в-байт. Сначала без course damping; если flicker в corner-тестах — вернуть только damping (0.35 к прошлому курсу при активных terrain-линиях).
- **`friends`/`enemies` в выходном контракте** сохранить (yield-таймеры и `enemy_blocked` не трогаем): friends = дружественные соседи, чья линия нарушена `v_pref`; enemies — аналогично.
- **Параметры**: `tau = 0.75s` (15 тиков), `tau_obst = 0.4s` (= нынешний lookahead), `maxNeighbors = 8` (ближайшие, тай-брейк id), запрос = `radius_A + bucket_max_radius + max_speed·tau`.
- **Хвост перфа здесь же**: spatial hash — persistent-бакеты с `resize(0)`, пер-бакет max-radius вместо глобального; `_ordered_agents` — persistent id-ordered массив вместо сортировки каждый тик; idle-gate (агент с `v_pref == 0`, без оверлапа и без движущихся соседей в радиусе — пропускает ORCA/separation; детерминировано, база «спит» бесплатно).
- Создание `ground/steering_stabilizer.gd` (перенос stabilize/separation/terrain sweep из `unit_local_avoidance.gd`) — отдельным коммитом перед свапом.

Бюджет: ~1-2k VM-ops/агент/тик против 3-7k свипов сейчас (~10-30× дешевле в толпе/у стен), open-field почти бесплатно. Тест-риск (легитимный ретюн): avoidance/crowd сценарии (`_test_rounded_local_avoidance_field`, `_test_local_avoidance_preserves_route_half_plane`, orbit/arc/corridor/crossing/circle-convergence, yield-пара). **Не ретюнить**: separation ≥ contact−0.01, `_test_enemy_stays_solid_under_separation`, `_test_hold_position_resists_separation`, arrival tolerances, `harvester_run.gd` (лучший интеграционный гейт). Откат: `USE_ORCA = false`.

### Этап 6 — Зачистка
Удалить `unit_local_avoidance.gd`, `_simplify_path`, флаги `USE_FUNNEL`/`USE_ORCA`/`FORCE_GROUND_PIPELINE`; убедиться, что никакой тест не преложит удалённый файл; полный сьют; повторить замеры этапа 0 + сценарий «юнит с недостижимой целью в толпе» для подтверждения фикса FPS.

## Verification

- Гейт каждого этапа/коммита: `make godot-test`; точечно:
  `./tools/godot-container godot --headless --path /workspace --script res://tests/navigation/run.gd` (+ `tests/units/flight_run.gd`, `tests/units/harvester_run.gd`, `tests/match/demo_boot_run.gd`).
- Smoke: `timeout 30s ./tools/godot-container godot --headless --path /workspace --quit-after 10`.
- Перф-подтверждение: до/после этапа 1 — сцена с юнитом, посланным в недостижимую точку (замуровать клетку зданиями) + 20-30 юнитов: FPS не должен проседать; после этапа 5 — `_test_circle_convergence_metrics` (20 юнитов) по времени сьюта + `jitter_probe.gd` вручную.
- Поведенческое качество: анти-джиттер счётчики в тестах должны не деградировать; любые ретюны порогов — отдельными комментированными коммитами (список допустимых сценариев по этапам выше).

## Ключевые файлы

- `scripts/units/navigation/unit_navigation_system.gd` (фасад, распил)
- `scripts/units/navigation/unit_navigation_planner.gd` (region labels, ground-only)
- `scripts/units/navigation/unit_local_avoidance.gd` (донор: stabilize/separation/vertical → удаление)
- `scripts/units/navigation/unit_navigation_map.gd` (diff изменённых клеток)
- `scripts/buildings/building_placement.gd` (`building_placed` сигнал — уже есть)
- `tests/navigation/run.gd`, `tests/units/flight_run.gd` (единственный осознанно правимый тест)

Переиспользуется существующее: `_snapped_parking` (парковка после nudge), `_obstacle_profile` bucketed-кэш (диски террейна для ORCA), `_nearest_open` ring-паттерн (component-aware поиск), slot claiming/`_uncross_assignments` (анти-orbiting у общей цели), yield-таймеры, `stabilize_velocity`/`separation_velocity`.
