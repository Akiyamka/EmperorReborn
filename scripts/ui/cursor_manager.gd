class_name CursorManager
extends Node

const TextureImageUtilsScript := preload("res://converters/texture_image_utils.gd")

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
}

const SPRITE_SHEET_PATH := "res://assets/converted/ui/cursors/arrw_nw.res"
const SOURCE_SPRITE_SHEET_PATH := "res://assets/reworked/3DDATA/Textures/Arrw_nw_magenta_alpha.png"
const ORIGINAL_FRAME_SIZE := Vector2i(48, 48)
const FRAMES_PER_CURSOR := 8
const CURSOR_COUNT := 33
const ORIGINAL_UPDATES_PER_FRAME := 6
const ORIGINAL_UPDATES_PER_SECOND := 60.0
const FRAME_DURATION := ORIGINAL_UPDATES_PER_FRAME / ORIGINAL_UPDATES_PER_SECOND
const EDGE_SCROLL_OVERRIDE := &"edge_scroll"
const CURSOR_CANVAS_LAYER := 128
const SHADOW_ALPHA := 0.5

# Values come from UI0001/CURSORS/Cursor Test.txt in the original content.
const HOTSPOTS := [
	Vector2(24, 24),
	Vector2(24, 24),
	Vector2(24, 24),
	Vector2(24, 24),
	Vector2(24, 24),
	Vector2(24, 24),
	Vector2(24, 24),
	Vector2(24, 24),
	Vector2(24, 24),
	Vector2(24, 24),
	Vector2(24, 24),
	Vector2(24, 24),
	Vector2(24, 24),
	Vector2(24, 24),
	Vector2(30, 21),
	Vector2(42, 24),
	Vector2(43, 33),
	Vector2(42, 39),
	Vector2(34, 39),
	Vector2(25, 42),
	Vector2(23, 33),
	Vector2(26, 22),
	Vector2(30, 21),
	Vector2(42, 24),
	Vector2(43, 33),
	Vector2(42, 39),
	Vector2(34, 39),
	Vector2(25, 42),
	Vector2(23, 33),
	Vector2(26, 22),
	Vector2(24, 24),
	Vector2(24, 24),
	Vector2(24, 24),
]

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

var _color_frames: Array[Texture2D] = []
var _shadow_frames: Array[Texture2D] = []
var _frame_size := ORIGINAL_FRAME_SIZE
var _hotspot_scale := Vector2.ONE
var _base_cursor := CursorType.POINTER
var _active_cursor := CursorType.POINTER
var _active_frame := 0
var _frame_time := 0.0
var _overrides: Dictionary = {}
var _override_sequence := 0
var _cursor_layer: CanvasLayer
var _shadow_sprite: Sprite2D
var _color_sprite: Sprite2D
var _previous_mouse_mode := Input.MOUSE_MODE_VISIBLE


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_frames()
	if _color_frames.is_empty():
		return
	_setup_software_cursor()
	_apply_current_frame()
	_update_cursor_position()


func _process(delta: float) -> void:
	if _color_frames.is_empty():
		return
	_update_cursor_position()
	_frame_time += delta
	var elapsed_frames := floori(_frame_time / FRAME_DURATION)
	if elapsed_frames <= 0:
		return
	_frame_time -= elapsed_frames * FRAME_DURATION
	_active_frame = (_active_frame + elapsed_frames) % FRAMES_PER_CURSOR
	_apply_current_frame()


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


func current_frame() -> int:
	return _active_frame


func cursor_count() -> int:
	return CURSOR_COUNT


func frames_per_cursor() -> int:
	return FRAMES_PER_CURSOR


func hotspot(cursor: int) -> Vector2:
	if not _is_valid_cursor(cursor):
		return Vector2.ZERO
	return Vector2(HOTSPOTS[cursor]) * _hotspot_scale


func frame_size() -> Vector2i:
	return _frame_size


func frame_texture(cursor: int, frame: int) -> Texture2D:
	if not _is_valid_cursor(cursor) or frame < 0 or frame >= FRAMES_PER_CURSOR:
		return null
	var index := cursor * FRAMES_PER_CURSOR + frame
	return _color_frames[index] if index < _color_frames.size() else null


func shadow_frame_texture(cursor: int, frame: int) -> Texture2D:
	if not _is_valid_cursor(cursor) or frame < 0 or frame >= FRAMES_PER_CURSOR:
		return null
	var index := cursor * FRAMES_PER_CURSOR + frame
	return _shadow_frames[index] if index < _shadow_frames.size() else null


func _build_frames() -> void:
	var image := _load_sprite_sheet_image()
	if image == null:
		return
	if image.get_width() % FRAMES_PER_CURSOR != 0 or image.get_height() % CURSOR_COUNT != 0:
		push_error("Cursor sheet cannot be divided into %dx%d frames" % [FRAMES_PER_CURSOR, CURSOR_COUNT])
		return
	_frame_size = Vector2i(
		image.get_width() / FRAMES_PER_CURSOR, image.get_height() / CURSOR_COUNT
	)
	if _frame_size.x != _frame_size.y:
		push_error("Cursor frames must be square, got %s" % _frame_size)
		return
	_hotspot_scale = Vector2(_frame_size) / Vector2(ORIGINAL_FRAME_SIZE)

	image.convert(Image.FORMAT_RGBA8)
	var layers := _split_color_and_shadow(image)
	var color_sheet: Image = layers[0]
	var shadow_sheet: Image = layers[1]
	_color_frames.resize(CURSOR_COUNT * FRAMES_PER_CURSOR)
	_shadow_frames.resize(CURSOR_COUNT * FRAMES_PER_CURSOR)
	for cursor in CURSOR_COUNT:
		for frame in FRAMES_PER_CURSOR:
			var region := Rect2i(
				frame * _frame_size.x, cursor * _frame_size.y, _frame_size.x, _frame_size.y
			)
			var index := cursor * FRAMES_PER_CURSOR + frame
			_color_frames[index] = ImageTexture.create_from_image(
				color_sheet.get_region(region)
			)
			_shadow_frames[index] = ImageTexture.create_from_image(
				shadow_sheet.get_region(region)
			)


func _load_sprite_sheet_image() -> Image:
	if ResourceLoader.exists(SPRITE_SHEET_PATH):
		var sheet := load(SPRITE_SHEET_PATH) as Texture2D
		if sheet != null:
			return sheet.get_image()
		push_error("Cursor sheet is not a Texture2D: %s" % SPRITE_SHEET_PATH)
		return null

	# This keeps local/editor runs usable before the generated asset exists.
	# Exports should run the converter so the reworked PNG is not needed at runtime.
	var source_image: Image = TextureImageUtilsScript.load_image(SOURCE_SPRITE_SHEET_PATH)
	if source_image == null:
		push_error(
			"Cursor sheets are missing: %s (run `make godot-convert-cursors`)"
			% SPRITE_SHEET_PATH
		)
	return source_image


func _split_color_and_shadow(image: Image) -> Array[Image]:
	var color_image := Image.create(
		image.get_width(), image.get_height(), false, Image.FORMAT_RGBA8
	)
	var shadow_image := Image.create(
		image.get_width(), image.get_height(), false, Image.FORMAT_RGBA8
	)
	for y in image.get_height():
		for x in image.get_width():
			var color := image.get_pixel(x, y)
			if _is_shadow_blue(color):
				color_image.set_pixel(x, y, Color(0.0, 0.0, 0.0, 0.0))
				# blend_mul uses source RGB as the multiplication factor. White is
				# neutral; gray 0.5 is equivalent to black at 50% opacity.
				var factor := 1.0 - color.a * SHADOW_ALPHA
				shadow_image.set_pixel(x, y, Color(factor, factor, factor, 1.0))
			else:
				color_image.set_pixel(x, y, color)
				shadow_image.set_pixel(x, y, Color.WHITE)
	return [color_image, shadow_image]


func _is_shadow_blue(color: Color) -> bool:
	return color.a > 0.0 and color.r < 0.002 and color.g < 0.002 and color.b > 0.998


func _setup_software_cursor() -> void:
	_cursor_layer = CanvasLayer.new()
	_cursor_layer.name = "CursorLayer"
	_cursor_layer.layer = CURSOR_CANVAS_LAYER
	add_child(_cursor_layer)

	_shadow_sprite = Sprite2D.new()
	_shadow_sprite.name = "Shadow"
	_shadow_sprite.centered = false
	_shadow_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	var shadow_material := CanvasItemMaterial.new()
	shadow_material.blend_mode = CanvasItemMaterial.BLEND_MODE_MUL
	_shadow_sprite.material = shadow_material
	_cursor_layer.add_child(_shadow_sprite)

	_color_sprite = Sprite2D.new()
	_color_sprite.name = "Color"
	_color_sprite.centered = false
	_color_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_cursor_layer.add_child(_color_sprite)

	_previous_mouse_mode = Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN


func _update_cursor_position() -> void:
	if _cursor_layer == null:
		return
	var cursor_position := get_viewport().get_mouse_position() - hotspot(_active_cursor)
	_shadow_sprite.position = cursor_position
	_color_sprite.position = cursor_position


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
	_active_frame = 0
	_frame_time = 0.0
	_apply_current_frame()


func _apply_current_frame() -> void:
	if _color_sprite == null or _shadow_sprite == null:
		return
	_color_sprite.texture = frame_texture(_active_cursor, _active_frame)
	_shadow_sprite.texture = shadow_frame_texture(_active_cursor, _active_frame)
	_update_cursor_position()


func _is_valid_cursor(cursor: int) -> bool:
	return cursor >= 0 and cursor < CURSOR_COUNT


func _direction_sign(value: float) -> int:
	if value > 0.0:
		return 1
	if value < 0.0:
		return -1
	return 0
