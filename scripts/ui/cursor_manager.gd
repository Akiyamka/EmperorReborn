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
	GATHER,
	CANT_DEPLOY,
}

const SPRITE_SHEET_PATH := "res://assets/converted/ui/cursors/arrw_nw.res"
const SOURCE_SPRITE_SHEET_PATH := "res://assets/reworked/3DDATA/Textures/Arrw_nw_magenta_alpha.png"
const POINTER_FRAME_PATH_PATTERN := "res://assets/converted/ui/cursors/cursor_%04d.res"
const SOURCE_POINTER_FRAME_PATH_PATTERN := (
	"res://assets/reworked/3DDATA/Textures/cursor_%04d.png"
)
const MOVE_FRAME_PATH_PATTERN := "res://assets/converted/ui/cursors/move_cursor_%04d.res"
const SOURCE_MOVE_FRAME_PATH_PATTERN := (
	"res://assets/reworked/3DDATA/Textures/move_cursor_%04d.png"
)
const ATTACK_FRAME_PATH_PATTERN := "res://assets/converted/ui/cursors/attack_cursor_%04d.res"
const SOURCE_ATTACK_FRAME_PATH_PATTERN := (
	"res://assets/reworked/3DDATA/Textures/attack_cursor_%04d.png"
)
const ENTER_FRAME_PATH_PATTERN := "res://assets/converted/ui/cursors/move_in_cursor_%04d.res"
const SOURCE_ENTER_FRAME_PATH_PATTERN := (
	"res://assets/reworked/3DDATA/Textures/move_in_cursor_%04d.png"
)
const SELECTABLE_FRAME_PATH_PATTERN := "res://assets/converted/ui/cursors/selectable_%04d.res"
const SOURCE_SELECTABLE_FRAME_PATH_PATTERN := (
	"res://assets/reworked/3DDATA/Textures/selectable_%04d.png"
)
const DEPLOY_FRAME_PATH_PATTERN := "res://assets/converted/ui/cursors/deploy_cursor_%04d.res"
const SOURCE_DEPLOY_FRAME_PATH_PATTERN := (
	"res://assets/reworked/3DDATA/Textures/deploy_cursor_%04d.png"
)
const CANT_DEPLOY_FRAME_PATH_PATTERN := (
	"res://assets/converted/ui/cursors/no_deploy_cursor_%04d.res"
)
const SOURCE_CANT_DEPLOY_FRAME_PATH_PATTERN := (
	"res://assets/reworked/3DDATA/Textures/no_deploy_cursor_%04d.png"
)
const GATHER_FRAME_PATH_PATTERN := "res://assets/converted/ui/cursors/gather_cursor_%04d.res"
const SOURCE_GATHER_FRAME_PATH_PATTERN := (
	"res://assets/reworked/3DDATA/Textures/gather_cursor_%04d.png"
)
const TARGET_ABILITY_FRAME_PATH_PATTERN := (
	"res://assets/converted/ui/cursors/ability_cursor_%04d.res"
)
const SOURCE_TARGET_ABILITY_FRAME_PATH_PATTERN := (
	"res://assets/reworked/3DDATA/Textures/ability_cursor_%04d.png"
)
const CANT_MOVE_FRAME_PATH_PATTERN := (
	"res://assets/converted/ui/cursors/not_move_cursor_%04d.res"
)
const SOURCE_CANT_MOVE_FRAME_PATH_PATTERN := (
	"res://assets/reworked/3DDATA/Textures/not_move_cursor_%04d.png"
)
const ORIGINAL_FRAME_SIZE := Vector2i(48, 48)
const FRAMES_PER_CURSOR := 8
const POINTER_FIRST_FRAME := 0
const POINTER_FRAME_COUNT := 1
const MOVE_FIRST_FRAME := 0
const MOVE_FRAME_COUNT := 13
const MOVE_DISPLAY_SIZE := Vector2i(64, 64)
const ATTACK_FIRST_FRAME := 0
const ATTACK_FRAME_COUNT := 13
const ENTER_FIRST_FRAME := 0
const ENTER_FRAME_COUNT := 4
const SELECTABLE_FIRST_FRAME := 0
const SELECTABLE_FRAME_COUNT := 24
const DEPLOY_FIRST_FRAME := 0
const DEPLOY_FRAME_COUNT := 13
const CANT_DEPLOY_FIRST_FRAME := 0
const CANT_DEPLOY_FRAME_COUNT := 1
const GATHER_FIRST_FRAME := 0
const GATHER_FRAME_COUNT := 13
const TARGET_ABILITY_FIRST_FRAME := 0
const TARGET_ABILITY_FRAME_COUNT := 13
const CANT_MOVE_FIRST_FRAME := 1
const CANT_MOVE_FRAME_COUNT := 1
const ORIGINAL_CURSOR_COUNT := 33
const CURSOR_COUNT := 35
const ORIGINAL_UPDATES_PER_FRAME := 6
const ORIGINAL_UPDATES_PER_SECOND := 60.0
const FRAME_DURATION := ORIGINAL_UPDATES_PER_FRAME / ORIGINAL_UPDATES_PER_SECOND
const MOVE_FRAME_DURATION := 0.06
const SELECTABLE_FRAME_DURATION := FRAME_DURATION * 0.5
const EDGE_SCROLL_OVERRIDE := &"edge_scroll"
const CURSOR_CANVAS_LAYER := 128
const SHADOW_ALPHA := 0.5

const CURSOR_FALLBACKS := {
	CursorType.GATHER: CursorType.TARGET_ABILITY,
	CursorType.CANT_DEPLOY: CursorType.CANT_MOVE,
}

const SCROLL_CURSOR_ASSETS := {
	CursorType.SCROLL_N: "arrow_up",
	CursorType.SCROLL_NE: "arrow_up_right",
	CursorType.SCROLL_E: "arrow_right",
	CursorType.SCROLL_SE: "arrow_down_right",
	CursorType.SCROLL_S: "arrow_down",
	CursorType.SCROLL_SW: "arrow_down_left",
	CursorType.SCROLL_W: "arrow_left",
	CursorType.SCROLL_NW: "arrow_up_left",
}

const CANT_SCROLL_CURSOR_ASSETS := {
	CursorType.CANT_SCROLL_N: "arrow_stop_up",
	CursorType.CANT_SCROLL_NE: "arrow_stop_up_right",
	CursorType.CANT_SCROLL_E: "arrow_stop_right",
	CursorType.CANT_SCROLL_SE: "arrow_stop_down_right",
	CursorType.CANT_SCROLL_S: "arrow_stop_down",
	CursorType.CANT_SCROLL_SW: "arrow_stop_down_left",
	CursorType.CANT_SCROLL_W: "arrow_stop_left",
	CursorType.CANT_SCROLL_NW: "arrow_stop_up_left",
}

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
var _custom_color_frames: Dictionary = {}
var _custom_shadow_frames: Dictionary = {}
var _custom_frame_sizes: Dictionary = {}
var _frame_size := ORIGINAL_FRAME_SIZE
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
	var active_frame_duration := frame_duration(_active_cursor)
	var elapsed_frames := floori(_frame_time / active_frame_duration)
	if elapsed_frames <= 0:
		return
	_frame_time -= elapsed_frames * active_frame_duration
	_active_frame = (_active_frame + elapsed_frames) % frame_count(_active_cursor)
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


func frame_count(cursor: int) -> int:
	if not _is_valid_cursor(cursor):
		return 0
	if _custom_color_frames.has(cursor):
		var custom_frames: Array = _custom_color_frames[cursor]
		return custom_frames.size()
	var fallback_cursor := _fallback_cursor(cursor)
	if fallback_cursor != cursor:
		return frame_count(fallback_cursor)
	return FRAMES_PER_CURSOR if cursor < ORIGINAL_CURSOR_COUNT else 0


func frame_duration(cursor: int) -> float:
	match cursor:
		CursorType.MOVE:
			return MOVE_FRAME_DURATION
		CursorType.OVER_UNIT:
			return SELECTABLE_FRAME_DURATION
		_:
			return FRAME_DURATION


func hotspot(cursor: int) -> Vector2:
	if not _is_valid_cursor(cursor):
		return Vector2.ZERO
	if _custom_frame_sizes.has(cursor):
		return Vector2(frame_size(cursor)) * 0.5
	if cursor >= HOTSPOTS.size():
		return Vector2(frame_size(cursor)) * 0.5
	var scale := Vector2(frame_size(cursor)) / Vector2(ORIGINAL_FRAME_SIZE)
	return Vector2(HOTSPOTS[cursor]) * scale


func frame_size(cursor := -1) -> Vector2i:
	if _custom_frame_sizes.has(cursor):
		return Vector2i(_custom_frame_sizes[cursor])
	var fallback_cursor := _fallback_cursor(cursor)
	if fallback_cursor != cursor:
		return frame_size(fallback_cursor)
	return _frame_size


func frame_texture(cursor: int, frame: int) -> Texture2D:
	if not _is_valid_cursor(cursor) or frame < 0 or frame >= frame_count(cursor):
		return null
	if _custom_color_frames.has(cursor):
		var custom_frames: Array = _custom_color_frames[cursor]
		return custom_frames[frame] as Texture2D
	var fallback_cursor := _fallback_cursor(cursor)
	if fallback_cursor != cursor:
		return frame_texture(fallback_cursor, frame)
	var index := cursor * FRAMES_PER_CURSOR + frame
	return _color_frames[index] if index < _color_frames.size() else null


func shadow_frame_texture(cursor: int, frame: int) -> Texture2D:
	if not _is_valid_cursor(cursor) or frame < 0 or frame >= frame_count(cursor):
		return null
	if _custom_shadow_frames.has(cursor):
		var custom_frames: Array = _custom_shadow_frames[cursor]
		return custom_frames[frame] as Texture2D
	var fallback_cursor := _fallback_cursor(cursor)
	if fallback_cursor != cursor:
		return shadow_frame_texture(fallback_cursor, frame)
	var index := cursor * FRAMES_PER_CURSOR + frame
	return _shadow_frames[index] if index < _shadow_frames.size() else null


func _build_frames() -> void:
	var image := _load_sprite_sheet_image()
	if image == null:
		return
	if image.get_width() % FRAMES_PER_CURSOR != 0 or image.get_height() % ORIGINAL_CURSOR_COUNT != 0:
		push_error(
			"Cursor sheet cannot be divided into %dx%d frames"
			% [FRAMES_PER_CURSOR, ORIGINAL_CURSOR_COUNT]
		)
		return
	_frame_size = Vector2i(
		image.get_width() / FRAMES_PER_CURSOR,
		image.get_height() / ORIGINAL_CURSOR_COUNT
	)
	if _frame_size.x != _frame_size.y:
		push_error("Cursor frames must be square, got %s" % _frame_size)
		return
	image.convert(Image.FORMAT_RGBA8)
	var layers := _split_color_and_shadow(image)
	var color_sheet: Image = layers[0]
	var shadow_sheet: Image = layers[1]
	_color_frames.resize(ORIGINAL_CURSOR_COUNT * FRAMES_PER_CURSOR)
	_shadow_frames.resize(ORIGINAL_CURSOR_COUNT * FRAMES_PER_CURSOR)
	for cursor in ORIGINAL_CURSOR_COUNT:
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
	_load_custom_cursor_frames(
		CursorType.POINTER,
		"Pointer",
		POINTER_FRAME_PATH_PATTERN,
		SOURCE_POINTER_FRAME_PATH_PATTERN,
		POINTER_FIRST_FRAME,
		POINTER_FRAME_COUNT
	)
	_load_custom_cursor_frames(
		CursorType.MOVE,
		"Move",
		MOVE_FRAME_PATH_PATTERN,
		SOURCE_MOVE_FRAME_PATH_PATTERN,
		MOVE_FIRST_FRAME,
		MOVE_FRAME_COUNT,
		MOVE_DISPLAY_SIZE
	)
	_load_custom_cursor_frames(
		CursorType.ATTACK,
		"Attack",
		ATTACK_FRAME_PATH_PATTERN,
		SOURCE_ATTACK_FRAME_PATH_PATTERN,
		ATTACK_FIRST_FRAME,
		ATTACK_FRAME_COUNT
	)
	_load_custom_cursor_frames(
		CursorType.ENTER,
		"Enter",
		ENTER_FRAME_PATH_PATTERN,
		SOURCE_ENTER_FRAME_PATH_PATTERN,
		ENTER_FIRST_FRAME,
		ENTER_FRAME_COUNT
	)
	_load_custom_cursor_frames(
		CursorType.OVER_UNIT,
		"Selectable",
		SELECTABLE_FRAME_PATH_PATTERN,
		SOURCE_SELECTABLE_FRAME_PATH_PATTERN,
		SELECTABLE_FIRST_FRAME,
		SELECTABLE_FRAME_COUNT
	)
	_load_custom_cursor_frames(
		CursorType.DEPLOY,
		"Deploy",
		DEPLOY_FRAME_PATH_PATTERN,
		SOURCE_DEPLOY_FRAME_PATH_PATTERN,
		DEPLOY_FIRST_FRAME,
		DEPLOY_FRAME_COUNT
	)
	_load_custom_cursor_frames(
		CursorType.CANT_DEPLOY,
		"Cant Deploy",
		CANT_DEPLOY_FRAME_PATH_PATTERN,
		SOURCE_CANT_DEPLOY_FRAME_PATH_PATTERN,
		CANT_DEPLOY_FIRST_FRAME,
		CANT_DEPLOY_FRAME_COUNT
	)
	_load_custom_cursor_frames(
		CursorType.GATHER,
		"Gather",
		GATHER_FRAME_PATH_PATTERN,
		SOURCE_GATHER_FRAME_PATH_PATTERN,
		GATHER_FIRST_FRAME,
		GATHER_FRAME_COUNT
	)
	_load_custom_cursor_frames(
		CursorType.TARGET_ABILITY,
		"Target Ability",
		TARGET_ABILITY_FRAME_PATH_PATTERN,
		SOURCE_TARGET_ABILITY_FRAME_PATH_PATTERN,
		TARGET_ABILITY_FIRST_FRAME,
		TARGET_ABILITY_FRAME_COUNT
	)
	_load_custom_cursor_frames(
		CursorType.CANT_MOVE,
		"Cant Move",
		CANT_MOVE_FRAME_PATH_PATTERN,
		SOURCE_CANT_MOVE_FRAME_PATH_PATTERN,
		CANT_MOVE_FIRST_FRAME,
		CANT_MOVE_FRAME_COUNT
	)
	for cursor in SCROLL_CURSOR_ASSETS:
		var asset_name: String = SCROLL_CURSOR_ASSETS[cursor]
		_load_custom_cursor_frames(
			cursor,
			"Scroll %s" % asset_name,
			"res://assets/converted/ui/cursors/%s.res" % asset_name,
			"res://assets/reworked/3DDATA/Textures/%s.png" % asset_name,
			0,
			1
		)
	for cursor in CANT_SCROLL_CURSOR_ASSETS:
		var asset_name: String = CANT_SCROLL_CURSOR_ASSETS[cursor]
		_load_custom_cursor_frames(
			cursor,
			"Cant Scroll %s" % asset_name,
			"res://assets/converted/ui/cursors/%s.res" % asset_name,
			"res://assets/reworked/3DDATA/Textures/%s.png" % asset_name,
			0,
			1
		)


func _load_custom_cursor_frames(
	cursor: int,
	label: String,
	converted_path_pattern: String,
	source_path_pattern: String,
	first_frame: int,
	custom_frame_count: int,
	display_size := Vector2i.ZERO
) -> void:
	var color_frames: Array[Texture2D] = []
	var shadow_frames: Array[Texture2D] = []
	var source_frame_size := Vector2i.ZERO
	for frame_index in custom_frame_count:
		var frame_number := first_frame + frame_index
		var image := _load_custom_frame_image(
			_frame_path(converted_path_pattern, frame_number),
			_frame_path(source_path_pattern, frame_number)
		)
		if image == null:
			push_warning(
				"Custom %s cursor frame %d is missing; using the original cursor row"
				% [label, frame_number]
			)
			return
		if image.get_width() != image.get_height():
			push_warning(
				"Custom %s cursor frame %d must be square, got %s; using the original cursor row"
				% [label, frame_number, image.get_size()]
			)
			return
		if source_frame_size == Vector2i.ZERO:
			source_frame_size = image.get_size()
		elif image.get_size() != source_frame_size:
			push_warning(
				"Custom %s cursor frames must have equal sizes; using the original cursor row"
				% label
			)
			return

		image.convert(Image.FORMAT_RGBA8)
		var layers := _split_color_and_shadow(image)
		var color_image: Image = layers[0]
		var shadow_image: Image = layers[1]
		if display_size != Vector2i.ZERO and display_size != source_frame_size:
			color_image.resize(display_size.x, display_size.y, Image.INTERPOLATE_LANCZOS)
			shadow_image.resize(display_size.x, display_size.y, Image.INTERPOLATE_LANCZOS)
		color_frames.append(ImageTexture.create_from_image(color_image))
		shadow_frames.append(ImageTexture.create_from_image(shadow_image))

	_custom_color_frames[cursor] = color_frames
	_custom_shadow_frames[cursor] = shadow_frames
	_custom_frame_sizes[cursor] = display_size if display_size != Vector2i.ZERO else source_frame_size


func _load_custom_frame_image(converted_path: String, source_path: String) -> Image:
	if ResourceLoader.exists(converted_path):
		var texture := load(converted_path) as Texture2D
		if texture != null:
			return texture.get_image()
		push_error("Cursor frame is not a Texture2D: %s" % converted_path)
		return null

	return TextureImageUtilsScript.load_image(source_path)


func _frame_path(path_pattern: String, frame_number: int) -> String:
	return path_pattern % frame_number if path_pattern.contains("%") else path_pattern


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


func _fallback_cursor(cursor: int) -> int:
	return int(CURSOR_FALLBACKS.get(cursor, cursor))


func _direction_sign(value: float) -> int:
	if value > 0.0:
		return 1
	if value < 0.0:
		return -1
	return 0
