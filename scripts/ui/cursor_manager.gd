class_name CursorManager
extends Node

const CursorModelCatalogScript := preload("res://scripts/ui/cursor_model_catalog.gd")
const CURSOR_SCREEN_BLEND_SHADER := preload("res://scripts/ui/cursor_screen_blend.gdshader")

# Indices 0..32 retain the order documented by the original
# UI0001/CURSORS/Cursor Test.txt. Gather and Cant Deploy are remake-specific
# semantic states appended without disturbing that contract.
enum CursorType {
	POINTER,
	MOVE,
	ATTACK,
	CANT_MOVE,
	ENTER,
	OVER_UNIT,
	INFANTRY_ROCK,
	CANT_SELL,
	TARGET_ABILITY,
	DN3,
	SELL,
	REPAIR,
	DEPLOY,
	CANT_EXIT,
	SCROLL_N,
	SCROLL_NE,
	SCROLL_E,
	SCROLL_SE,
	SCROLL_S,
	SCROLL_SW,
	SCROLL_W,
	SCROLL_NW,
	CANT_SCROLL_N,
	CANT_SCROLL_NE,
	CANT_SCROLL_E,
	CANT_SCROLL_SE,
	CANT_SCROLL_S,
	CANT_SCROLL_SW,
	CANT_SCROLL_W,
	CANT_SCROLL_NW,
	DN4,
	DN5,
	DN6,
	GATHER,
	CANT_DEPLOY,
}

const ORIGINAL_CURSOR_COUNT := 33
const CURSOR_COUNT := 35
const EDGE_SCROLL_OVERRIDE := &"edge_scroll"
const CURSOR_CANVAS_LAYER := 128
const CURSOR_NORMAL_RENDER_LAYER := 1
const CURSOR_SCREEN_RENDER_LAYER := 2
const MODEL_VIEWPORT_SIZE := Vector2i(64, 64)
# 3.0 world units are the 48 source pixels from Cursor Test.txt at the XBF
# converter's 1/16 scale; the 50-degree tilt comes from UI0001/CAMERA.INI.
const MODEL_CAMERA_ORTHO_SIZE := 3.0
const MODEL_CAMERA_TILT_DEGREES := 50.0

# All semantic states resolve to 3D scenes. The five original states without a
# uniquely named XBF intentionally reuse the closest shipped model for now:
# Infantry Rock -> Enter, DN3 -> Move Map, DN4 -> Death Hand,
# DN5 -> Pick Up, DN6 -> Teleport.
const CURSOR_MODEL_KEYS := {
	CursorType.POINTER: &"pointer",
	CursorType.MOVE: &"move",
	CursorType.ATTACK: &"attack",
	CursorType.CANT_MOVE: &"cant_move",
	CursorType.ENTER: &"enter",
	CursorType.OVER_UNIT: &"select",
	CursorType.INFANTRY_ROCK: &"infantry_rock",
	CursorType.CANT_SELL: &"cant_sell",
	CursorType.TARGET_ABILITY: &"target_ability",
	CursorType.DN3: &"dn3",
	CursorType.SELL: &"sell",
	CursorType.REPAIR: &"repair",
	CursorType.DEPLOY: &"deploy",
	CursorType.CANT_EXIT: &"cant_enter",
	CursorType.SCROLL_N: &"scroll_n",
	CursorType.SCROLL_NE: &"scroll_ne",
	CursorType.SCROLL_E: &"scroll_e",
	CursorType.SCROLL_SE: &"scroll_se",
	CursorType.SCROLL_S: &"scroll_s",
	CursorType.SCROLL_SW: &"scroll_sw",
	CursorType.SCROLL_W: &"scroll_w",
	CursorType.SCROLL_NW: &"scroll_nw",
	CursorType.CANT_SCROLL_N: &"cant_scroll_n",
	CursorType.CANT_SCROLL_NE: &"cant_scroll_ne",
	CursorType.CANT_SCROLL_E: &"cant_scroll_e",
	CursorType.CANT_SCROLL_SE: &"cant_scroll_se",
	CursorType.CANT_SCROLL_S: &"cant_scroll_s",
	CursorType.CANT_SCROLL_SW: &"cant_scroll_sw",
	CursorType.CANT_SCROLL_W: &"cant_scroll_w",
	CursorType.CANT_SCROLL_NW: &"cant_scroll_nw",
	CursorType.DN4: &"dn4",
	CursorType.DN5: &"dn5",
	CursorType.DN6: &"dn6",
	CursorType.GATHER: &"gather",
	CursorType.CANT_DEPLOY: &"cant_deploy",
}

const SCROLL_CURSORS := {
	Vector2i(0, 1): CursorType.SCROLL_N,
	Vector2i(1, 1): CursorType.SCROLL_NE,
	Vector2i(1, 0): CursorType.SCROLL_E,
	Vector2i(1, -1): CursorType.SCROLL_SE,
	Vector2i(0, -1): CursorType.SCROLL_S,
	Vector2i(-1, -1): CursorType.SCROLL_SW,
	Vector2i(-1, 0): CursorType.SCROLL_W,
	Vector2i(-1, 1): CursorType.SCROLL_NW,
}

const CANT_SCROLL_CURSORS := {
	Vector2i(0, 1): CursorType.CANT_SCROLL_N,
	Vector2i(1, 1): CursorType.CANT_SCROLL_NE,
	Vector2i(1, 0): CursorType.CANT_SCROLL_E,
	Vector2i(1, -1): CursorType.CANT_SCROLL_SE,
	Vector2i(0, -1): CursorType.CANT_SCROLL_S,
	Vector2i(-1, -1): CursorType.CANT_SCROLL_SW,
	Vector2i(-1, 0): CursorType.CANT_SCROLL_W,
	Vector2i(-1, 1): CursorType.CANT_SCROLL_NW,
}

var _base_cursor := CursorType.POINTER
var _active_cursor := CursorType.POINTER
var _overrides: Dictionary = {}
var _override_sequence := 0
var _cursor_layer: CanvasLayer
var _model_sprite: Sprite2D
var _screen_model_sprite: Sprite2D
var _model_viewport: SubViewport
var _screen_model_viewport: SubViewport
var _model_root: Node3D
var _screen_model_root: Node3D
var _model_nodes: Dictionary = {}
var _screen_model_nodes: Dictionary = {}
var _active_model: Node3D
var _active_screen_model: Node3D
var _previous_mouse_mode := Input.MOUSE_MODE_VISIBLE
var _missing_model_warnings: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_setup_cursor_output()
	_setup_model_viewport()
	_activate_model_cursor(_active_cursor)
	_update_cursor_position()


func _process(_delta: float) -> void:
	_update_cursor_position()


func _exit_tree() -> void:
	if Input.mouse_mode == Input.MOUSE_MODE_HIDDEN:
		Input.mouse_mode = _previous_mouse_mode


func set_cursor(cursor: int) -> void:
	if not _is_valid_cursor(cursor) or cursor == _base_cursor:
		return
	_base_cursor = cursor
	_resolve_active_cursor()


func set_override(source: StringName, cursor: int, priority := 0) -> void:
	if source == &"" or not _is_valid_cursor(cursor):
		return
	var previous: Dictionary = _overrides.get(source, {})
	if int(previous.get("cursor", -1)) == cursor and int(previous.get("priority", 0)) == priority:
		return
	_override_sequence += 1
	_overrides[source] = {
		"cursor": cursor,
		"priority": priority,
		"sequence": _override_sequence,
	}
	_resolve_active_cursor()


func clear_override(source: StringName) -> void:
	if not _overrides.erase(source):
		return
	_resolve_active_cursor()


func set_edge_scroll_cursor(direction: Vector2, can_scroll: bool) -> void:
	var discrete_direction := Vector2i(_direction_sign(direction.x), _direction_sign(direction.y))
	if discrete_direction == Vector2i.ZERO:
		clear_override(EDGE_SCROLL_OVERRIDE)
		return
	var cursors := SCROLL_CURSORS if can_scroll else CANT_SCROLL_CURSORS
	set_override(EDGE_SCROLL_OVERRIDE, int(cursors[discrete_direction]), 100)


func current_cursor() -> int:
	return _active_cursor


func cursor_count() -> int:
	return CURSOR_COUNT


func model_source_path(cursor: int) -> String:
	var model_key := StringName(CURSOR_MODEL_KEYS.get(cursor, &""))
	return CursorModelCatalogScript.source_path(model_key) if model_key != &"" else ""


func model_scene_path(cursor: int) -> String:
	var model_key := StringName(CURSOR_MODEL_KEYS.get(cursor, &""))
	return CursorModelCatalogScript.output_path(model_key) if model_key != &"" else ""


func model_cursor_available(cursor: int) -> bool:
	var path := model_scene_path(cursor)
	return not path.is_empty() and ResourceLoader.exists(path)


func using_model_cursor() -> bool:
	return _active_model != null


func _setup_cursor_output() -> void:
	_cursor_layer = CanvasLayer.new()
	_cursor_layer.name = "CursorLayer"
	_cursor_layer.layer = CURSOR_CANVAS_LAYER
	add_child(_cursor_layer)

	_model_sprite = Sprite2D.new()
	_model_sprite.name = "Model"
	_model_sprite.centered = true
	_model_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_model_sprite.visible = false
	_cursor_layer.add_child(_model_sprite)

	_screen_model_sprite = Sprite2D.new()
	_screen_model_sprite.name = "ScreenModel"
	_screen_model_sprite.centered = true
	_screen_model_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	var screen_material := ShaderMaterial.new()
	screen_material.shader = CURSOR_SCREEN_BLEND_SHADER
	_screen_model_sprite.material = screen_material
	_screen_model_sprite.visible = false
	_cursor_layer.add_child(_screen_model_sprite)
	_previous_mouse_mode = Input.mouse_mode


func _setup_model_viewport() -> void:
	_model_viewport = SubViewport.new()
	_model_viewport.name = "CursorModelViewport"
	_model_viewport.size = MODEL_VIEWPORT_SIZE
	_model_viewport.transparent_bg = true
	_model_viewport.own_world_3d = true
	_model_viewport.msaa_3d = Viewport.MSAA_4X
	_model_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_model_viewport)

	_model_root = Node3D.new()
	_model_root.name = "Models"
	_model_viewport.add_child(_model_root)

	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.0, 0.0, 0.0, 0.0)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color.WHITE
	environment.ambient_light_energy = 0.75
	var world_environment := WorldEnvironment.new()
	world_environment.name = "WorldEnvironment"
	world_environment.environment = environment
	_model_viewport.add_child(world_environment)

	var light := DirectionalLight3D.new()
	light.name = "KeyLight"
	light.rotation_degrees = Vector3(-55.0, -35.0, 0.0)
	light.light_energy = 0.8
	light.shadow_enabled = false
	_model_viewport.add_child(light)

	var camera := Camera3D.new()
	camera.name = "Camera3D"
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = MODEL_CAMERA_ORTHO_SIZE
	camera.near = 0.05
	camera.far = 30.0
	camera.cull_mask = CURSOR_NORMAL_RENDER_LAYER
	var camera_tilt := deg_to_rad(MODEL_CAMERA_TILT_DEGREES)
	var camera_distance := 12.0
	# Cursor XBF direction names are authored for a camera on the negative-Z
	# side of the converted model. Viewing them from positive Z mirrors the
	# Pointer vertically and reverses all directional Scroll cursors.
	var camera_position := Vector3(
		0.0, sin(camera_tilt) * camera_distance, -cos(camera_tilt) * camera_distance
	)
	camera.look_at_from_position(camera_position, Vector3.ZERO, Vector3.UP)
	camera.current = true
	_model_viewport.add_child(camera)

	_model_sprite.texture = _model_viewport.get_texture()

	_screen_model_viewport = SubViewport.new()
	_screen_model_viewport.name = "CursorScreenModelViewport"
	_screen_model_viewport.size = MODEL_VIEWPORT_SIZE
	# Additive !-marked surfaces must accumulate over defined black RGB.
	# Transparent viewport RGB is undefined (and can be white), while black is
	# exactly neutral when this pass is later composited with Screen.
	_screen_model_viewport.transparent_bg = false
	_screen_model_viewport.own_world_3d = true
	_screen_model_viewport.msaa_3d = Viewport.MSAA_4X
	_screen_model_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_screen_model_viewport)

	_screen_model_root = Node3D.new()
	_screen_model_root.name = "Models"
	_screen_model_viewport.add_child(_screen_model_root)

	var screen_environment := Environment.new()
	screen_environment.background_mode = Environment.BG_COLOR
	screen_environment.background_color = Color.BLACK
	screen_environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	screen_environment.ambient_light_color = environment.ambient_light_color
	screen_environment.ambient_light_energy = environment.ambient_light_energy
	var screen_world_environment := WorldEnvironment.new()
	screen_world_environment.name = "WorldEnvironment"
	screen_world_environment.environment = screen_environment
	_screen_model_viewport.add_child(screen_world_environment)

	var screen_light := DirectionalLight3D.new()
	screen_light.name = "KeyLight"
	screen_light.rotation = light.rotation
	screen_light.light_energy = light.light_energy
	screen_light.shadow_enabled = false
	_screen_model_viewport.add_child(screen_light)

	var screen_camera := Camera3D.new()
	screen_camera.name = "Camera3D"
	screen_camera.projection = camera.projection
	screen_camera.size = camera.size
	screen_camera.near = camera.near
	screen_camera.far = camera.far
	screen_camera.cull_mask = CURSOR_SCREEN_RENDER_LAYER
	screen_camera.transform = camera.transform
	screen_camera.current = true
	_screen_model_viewport.add_child(screen_camera)
	_screen_model_sprite.texture = _screen_model_viewport.get_texture()


func _update_cursor_position() -> void:
	if _model_sprite != null:
		# XBFs are authored around their command point, so the model origin is
		# the hotspot and stays directly under the hardware pointer.
		_model_sprite.position = get_viewport().get_mouse_position()
	if _screen_model_sprite != null:
		_screen_model_sprite.position = get_viewport().get_mouse_position()


func _resolve_active_cursor() -> void:
	var resolved_cursor := _base_cursor
	var best_priority := -2147483648
	var best_sequence := -1
	for request_value in _overrides.values():
		var request: Dictionary = request_value
		var priority := int(request.get("priority", 0))
		var sequence := int(request.get("sequence", 0))
		if priority < best_priority or (priority == best_priority and sequence <= best_sequence):
			continue
		best_priority = priority
		best_sequence = sequence
		resolved_cursor = int(request.get("cursor", _base_cursor))
	_activate_cursor(resolved_cursor)


func _activate_cursor(cursor: int) -> void:
	if cursor == _active_cursor:
		return
	_active_cursor = cursor
	_activate_model_cursor(cursor)


func _activate_model_cursor(cursor: int) -> void:
	if _model_viewport == null or _model_root == null or _screen_model_root == null:
		return
	if _active_model != null:
		_active_model.visible = false
		_set_model_animation_playing(_active_model, false)
	if _active_screen_model != null:
		_active_screen_model.visible = false
		_set_model_animation_playing(_active_screen_model, false)
	_active_model = null
	_active_screen_model = null

	var model_key := StringName(CURSOR_MODEL_KEYS.get(cursor, &""))
	var scene_path := CursorModelCatalogScript.output_path(model_key) if model_key != &"" else ""
	if scene_path.is_empty() or not ResourceLoader.exists(scene_path):
		_warn_missing_model(cursor, scene_path)
		_refresh_visual_mode()
		return

	if not _model_nodes.has(model_key):
		var scene := load(scene_path) as PackedScene
		if scene == null:
			_warn_missing_model(cursor, scene_path)
			_refresh_visual_mode()
			return
		var model := scene.instantiate() as Node3D
		var screen_model := scene.instantiate() as Node3D
		if model == null or screen_model == null:
			if model != null:
				model.free()
			if screen_model != null:
				screen_model.free()
			_warn_missing_model(cursor, scene_path)
			_refresh_visual_mode()
			return
		model.name = String(model_key)
		model.visible = false
		_model_root.add_child(model)
		_model_nodes[model_key] = model
		screen_model.name = String(model_key)
		screen_model.visible = false
		_screen_model_root.add_child(screen_model)
		_screen_model_nodes[model_key] = screen_model

	_active_model = _model_nodes[model_key] as Node3D
	_active_screen_model = _screen_model_nodes[model_key] as Node3D
	_active_model.visible = true
	_active_screen_model.visible = true
	_set_model_animation_playing(_active_model, true)
	_set_model_animation_playing(_active_screen_model, true)
	_refresh_visual_mode()


func _set_model_animation_playing(model: Node3D, playing: bool) -> void:
	for node in model.find_children("*", "AnimationPlayer", true, false):
		var player := node as AnimationPlayer
		if not playing:
			player.stop()
			continue
		var animation_name := StringName(player.autoplay)
		if animation_name == &"" or not player.has_animation(animation_name):
			animation_name = &"timeline" if player.has_animation(&"timeline") else &""
		if animation_name == &"":
			var animations := player.get_animation_list()
			if not animations.is_empty():
				animation_name = animations[0]
		if animation_name != &"":
			player.play(animation_name)
			player.seek(0.0, true)


func _refresh_visual_mode() -> void:
	var use_model := _active_model != null and _active_screen_model != null
	if _model_viewport != null:
		_model_viewport.render_target_update_mode = (
			SubViewport.UPDATE_ALWAYS if use_model else SubViewport.UPDATE_DISABLED
		)
	if _screen_model_viewport != null:
		_screen_model_viewport.render_target_update_mode = (
			SubViewport.UPDATE_ALWAYS if use_model else SubViewport.UPDATE_DISABLED
		)
	if _model_sprite != null:
		_model_sprite.visible = use_model
	if _screen_model_sprite != null:
		_screen_model_sprite.visible = use_model
	if use_model:
		Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
	elif Input.mouse_mode == Input.MOUSE_MODE_HIDDEN:
		Input.mouse_mode = _previous_mouse_mode


func _warn_missing_model(cursor: int, scene_path: String) -> void:
	if _missing_model_warnings.has(cursor):
		return
	_missing_model_warnings[cursor] = true
	push_warning(
		"3D cursor model is unavailable for cursor %d: %s (run `make godot-convert-cursors`)"
		% [cursor, scene_path]
	)


func _is_valid_cursor(cursor: int) -> bool:
	return cursor >= 0 and cursor < CURSOR_COUNT


func _direction_sign(value: float) -> int:
	if value > 0.0:
		return 1
	if value < 0.0:
		return -1
	return 0
