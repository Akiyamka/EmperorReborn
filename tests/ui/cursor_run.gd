extends SceneTree

const CursorManagerScript := preload("res://scripts/ui/cursor_manager.gd")

var _assertions := 0
var _failures := 0


func _initialize() -> void:
	await process_frame
	var cursors: Variant = get_root().get_node_or_null("Cursors")
	_expect(cursors != null, "the Cursors autoload must be available")
	if cursors != null:
		_test_sprite_sheet(cursors)
		_test_cursor_selection(cursors)
		_test_animation(cursors)

	if _failures > 0:
		printerr("Cursor tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("Cursor tests: %d assertions passed" % _assertions)
	quit(0)


func _test_sprite_sheet(cursors) -> void:
	_expect(cursors.cursor_count() == 33, "all 33 original cursor rows must be exposed")
	_expect(cursors.frames_per_cursor() == 8, "every original cursor must have eight frames")
	_expect(
		CursorManagerScript.CursorType.REPAIR == 11,
		"the twelfth cursor row must be reserved for repair commands"
	)
	_expect(
		CursorManagerScript.CursorType.DEPLOY == 12,
		"the thirteenth cursor row must be used for deploy commands"
	)
	for cursor in cursors.cursor_count():
		for frame in cursors.frames_per_cursor():
			var texture: Texture2D = cursors.frame_texture(cursor, frame)
			var shadow_texture: Texture2D = cursors.shadow_frame_texture(cursor, frame)
			_expect(texture != null, "cursor %d frame %d must exist" % [cursor, frame])
			_expect(shadow_texture != null, "cursor %d shadow frame %d must exist" % [cursor, frame])
			if texture != null:
				_expect(texture.get_size() == Vector2(cursors.frame_size()), "cursor frames must use the source scale")

	var pointer_image: Image = cursors.frame_texture(CursorManagerScript.CursorType.POINTER, 0).get_image()
	_expect(pointer_image.get_pixel(0, 0).a == 0.0, "magenta sheet pixels must become transparent")
	_expect(pointer_image.get_used_rect().has_area(), "the visible cursor pixels must remain opaque")
	_test_multiply_shadow(cursors, pointer_image)
	_expect(
		cursors.hotspot(CursorManagerScript.CursorType.SCROLL_E) == Vector2(43, 33),
		"original per-cursor hotspots must be retained"
	)
	var shadow_sprite := cursors.get_node_or_null("CursorLayer/Shadow") as Sprite2D
	_expect(shadow_sprite != null, "the software cursor must expose a separate shadow layer")
	_expect(
		shadow_sprite != null
		and shadow_sprite.material is CanvasItemMaterial
		and shadow_sprite.material.blend_mode == CanvasItemMaterial.BLEND_MODE_MUL,
		"the blue fill layer must use multiply blending"
	)


func _test_multiply_shadow(cursors, color_image: Image) -> void:
	var shadow_image: Image = cursors.shadow_frame_texture(
		CursorManagerScript.CursorType.POINTER, 0
	).get_image()
	var shadow_pixel := Vector2i(-1, -1)
	for y in shadow_image.get_height():
		for x in shadow_image.get_width():
			var pixel := shadow_image.get_pixel(x, y)
			if pixel.r < 0.998 or pixel.g < 0.998 or pixel.b < 0.998:
				shadow_pixel = Vector2i(x, y)
				break
		if shadow_pixel.x >= 0:
			break
	_expect(shadow_pixel.x >= 0, "#0000ff pixels must create a shadow mask")
	if shadow_pixel.x < 0:
		return
	var shadow_color := shadow_image.get_pixelv(shadow_pixel)
	var expected_factor := 1.0 - CursorManagerScript.SHADOW_ALPHA
	_expect(
		absf(shadow_color.r - expected_factor) <= 1.0 / 255.0
		and absf(shadow_color.g - expected_factor) <= 1.0 / 255.0
		and absf(shadow_color.b - expected_factor) <= 1.0 / 255.0,
		"shadow pixels must encode the configured black multiply opacity"
	)
	_expect(shadow_color.a > 0.998, "multiply mask pixels must preserve their RGB factor")
	var neutral_shadow := shadow_image.get_pixel(0, 0)
	_expect(
		neutral_shadow.r > 0.998 and neutral_shadow.g > 0.998 and neutral_shadow.b > 0.998,
		"non-shadow pixels must be neutral white in the multiply layer"
	)
	_expect(color_image.get_pixelv(shadow_pixel).a == 0.0, "#0000ff must be removed from the color layer")


func _test_cursor_selection(cursors) -> void:
	cursors.set_cursor(CursorManagerScript.CursorType.MOVE)
	_expect(cursors.current_cursor() == CursorManagerScript.CursorType.MOVE, "the base cursor must be selectable")
	cursors.set_edge_scroll_cursor(Vector2(1, 1), true)
	_expect(
		cursors.current_cursor() == CursorManagerScript.CursorType.SCROLL_NE,
		"north-east edge scroll must use its directional cursor"
	)
	cursors.set_edge_scroll_cursor(Vector2(1, 1), false)
	_expect(
		cursors.current_cursor() == CursorManagerScript.CursorType.CANT_SCROLL_NE,
		"blocked north-east edge scroll must use its disabled cursor"
	)
	cursors.set_edge_scroll_cursor(Vector2.ZERO, false)
	_expect(cursors.current_cursor() == CursorManagerScript.CursorType.MOVE, "leaving the edge must restore the base cursor")


func _test_animation(cursors) -> void:
	cursors.set_cursor(CursorManagerScript.CursorType.POINTER)
	var initial_frame: int = cursors.current_frame()
	cursors._process(CursorManagerScript.FRAME_DURATION)
	_expect(
		cursors.current_frame() == (initial_frame + 1) % cursors.frames_per_cursor(),
		"cursor animation must advance after six 60 Hz updates"
	)


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s" % message)
