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

- `scenes/main.tscn` вручную поддерживается, но ссылается на generated scenes из `assets/converted/`; запуск main зависит от локально сконвертированных оригинальных assets.
- `scripts/main.gd` одновременно создает demo players, координирует карту/камеру, selection, команды и HUD.
- `scripts/buildings/building_controller.gd` (более 1000 строк) объединяет production queue, списание денег, availability, placement preview/raycast, создание и продажу зданий и напрямую знает API/константы `scripts/ui/side_panel.gd`.
- `scripts/ui/side_panel.gd` содержит gameplay-идентификаторы зданий и preload raw icons, поэтому gameplay зависит от состава конкретного UI.
- `scripts/map_loader.gd`, `scripts/map_navigation_grid.gd` и `scripts/baked_map_data.gd` являются runtime-частью карты, но `converters/map_bake_builder.gd` напрямую preload-ит и создает runtime-типы; граница generated data/conversion/runtime размыта.
- `scripts/players/player_roster.gd`, `scripts/players/player_data.gd`, `scripts/building.gd` и `scripts/unit.gd` используют изменяемые Resources и сигналы жизненного цикла; до структурных правок нужны проверки reset/rebind/removal/ownership.
- Автотестов сейчас нет. Авторитетная версия движка указана в `project.godot` как Godot 4.7; основной воспроизводимый запуск идет через `tools/godot-container`.
- `assets/` и `.godot/` игнорируются в `.gitignore`. Нельзя считать локальный `.godot` доказательством корректности путей или коммитить generated/original assets.

## Обязательное правило перемещений

Перемещать каждый `.gd` и `.gdshader` вместе с соответствующим `.uid`, сохраняя UID. После изменения путей обновлять все `res://` ссылки в hand-authored `.tscn`, `.tres`, `.gd` и `project.godot`; generated assets регенерировать штатными converters, а не редактировать вручную. Проверять проект без опоры на существующий `.godot` cache; пользовательский cache не удалять.

## Этапы

### [x] Этап 0. Baseline камеры (завершен 2026-07-10)

Scope: исправить fallback path `RTSCameraConfig.tres` в `scenes/main.tscn`, не меняя UID; типизировать `RTSCamera.config` как `RTSCameraConfig`; сохранить создание default config при `null` и все camera tuning.

Критерии приемки: сцена ссылается на `res://configs/RTSCameraConfig.tres` и прежний `uid://nj40xd0p0abq`; GDScript парсится; проект импортируется; main scene запускается headless без ошибок камеры. Если generated assets блокируют main, допустима узкая parse/load-проверка камеры с зафиксированным blocker.

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
./tools/godot-container godot --headless --path /workspace --script res://scripts/technology_tree.gd --check-only
# PASS
```

#### [ ] Этап 1B. Scene-bound lifecycle characterization (deferred)

Scope: ownership внутри scene tree, повторный setup controller, полные building-order transitions (charge/pause/resume/cancel/refund/ready) и очистка состояния при неуспешной `MapLoader.load_map()`. Queue transitions выполнять при выделении queue в этапе 3; map failure semantics - вместе с runtime/converter boundary в этапе 5. Не тащить private controller API или converter dependency в runner 1A.

Критерии приемки: отдельные asset-independent seams существуют после соответствующего разделения; tests проверяют transitions через public API, signal connections не дублируются, failed map load не оставляет смешанное старое/новое состояние.

Текущие blockers: `scripts/main.gd --check-only` и `make godot-check` загружают `SidePanel`/`BuildingController`/map dependencies и сообщают отсутствующие imported raw icons, stale global class `MapXbf` и ссылки generated terrain на `assets/unpacked_rfd`. Эти команды не считаются зелеными, даже если Godot возвращает zero exit code.

### [ ] Этап 2. Безопасное перемещение по feature-папкам

Scope: механическими небольшими batches собрать camera, players, units, buildings, map и UI в явные feature-каталоги; сохранить отдельный `converters/`. Начать с leaf-файлов камеры и data/config, затем сцены и orchestration. Не менять API или поведение одновременно с путями.

Критерии приемки: все `.uid` перемещены с исходниками; `res://` ссылки обновлены; отсутствуют ссылки на старые пути; generated scenes пересозданы converters после path changes; проект проходит проверки без существующего `.godot` cache в отдельном чистом checkout/container mount.

Проверка:

```sh
rg 'res://scripts/(rts_camera|players|buildings|ui|map_)' --glob '!REFACTORING_PLAN.md'
make godot-check
./tools/godot-container godot --headless --path /workspace --script res://tests/characterization/run.gd
timeout 30s ./tools/godot-container godot --headless --path /workspace --quit-after 10
```

### [ ] Этап 3. Разделение BuildingController

Scope: первым шагом извлечь production queue/state/charging из `scripts/buildings/building_controller.gd` в независимый от UI объект; только после стабилизации queue извлечь placement preview/validation/spawn. Продажу и orchestration оставить тонкому feature-controller, пока для них нет отдельной переиспользуемой границы.

Критерии приемки: queue тестируется без scene tree/UI; placement получает явные map/camera/buildings dependencies; ни queue, ни placement не обращаются к `SidePanel`; pause/cancel/refund/readiness и placement feedback сохраняют characterization behavior; controller заметно уменьшается и только координирует части.

Проверка:

```sh
make godot-check
./tools/godot-container godot --headless --path /workspace --script res://tests/characterization/run.gd
./tools/godot-container godot --headless --path /workspace --script res://tests/buildings/run.gd
timeout 30s ./tools/godot-container godot --headless --path /workspace --quit-after 10
```

### [ ] Этап 4. Decouple gameplay от UI

Scope: убрать `SidePanel.BUILDING_IDS`, tab/slot details и вызовы `set_*` из gameplay. UI должен отображать типизированные presentation/state данные и посылать пользовательские intents; состав build options приходит из rules/building feature. Убрать gameplay orchestration статусов из HUD-кода `scripts/main.gd`.

Критерии приемки: building gameplay запускается и тестируется без `SidePanel`; UI можно пересоздать/скрыть без потери gameplay state; raw icon paths и layout остаются UI concerns; команды преобразуются в feature API в одном composition root.

Проверка:

```sh
rg 'SidePanel|scripts/ui|scenes/ui' scripts/buildings
make godot-check
./tools/godot-container godot --headless --path /workspace --script res://tests/characterization/run.gd
timeout 30s ./tools/godot-container godot --headless --path /workspace --quit-after 10
```

### [ ] Этап 5. Разделение runtime map и converters

Scope: определить стабильный формат baked map data; оставить `converters/` ответственным за XBF/CPF/CPT parsing и генерацию, а map feature runtime - только за загрузку Godot-native `.tres`/`.tscn`, навигационные запросы и освещение. Устранить обратную зависимость converter builder на runtime scene construction через явный формат/adapter.

Критерии приемки: runtime map не читает original formats и не зависит от `converters/`; converter можно запускать headless отдельно; свежесгенерированная карта загружается runtime; ошибки версии/формы baked data валидируются явно.

Проверка:

```sh
rg 'res://converters|XBF|CPF|CPT' scripts scenes
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
