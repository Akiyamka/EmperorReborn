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
	_expect(
		CursorManagerScript.ORIGINAL_CURSOR_COUNT == 33,
		"all 33 original cursor rows must remain exposed"
	)
	_expect(cursors.cursor_count() == 35, "the two additional semantic cursor types must be exposed")
	_expect(cursors.frames_per_cursor() == 8, "every original cursor must have eight frames")
	_expect(
		cursors.frame_count(CursorManagerScript.CursorType.POINTER) == 1,
		"the custom Pointer cursor must use its single rendered frame"
	)
	_expect(
		cursors.frame_size(CursorManagerScript.CursorType.POINTER) == Vector2i(64, 64),
		"the custom Pointer cursor must retain its rendered size"
	)
	_expect(
		cursors.hotspot(CursorManagerScript.CursorType.POINTER) == Vector2(32, 32),
		"the custom Pointer cursor hotspot must remain centered"
	)
	_expect(
		cursors.frame_texture(CursorManagerScript.CursorType.POINTER, 0) != null,
		"the custom Pointer cursor frame must be available"
	)
	_expect(
		cursors.frame_texture(CursorManagerScript.CursorType.POINTER, 1) == null,
		"the custom Pointer cursor must not duplicate its static frame"
	)
	_expect(
		cursors.frame_count(CursorManagerScript.CursorType.MOVE) == 13,
		"the custom Move cursor must expose all thirteen rendered frames"
	)
	_expect(
		is_equal_approx(
			cursors.frame_duration(CursorManagerScript.CursorType.MOVE),
			CursorManagerScript.MOVE_FRAME_DURATION
		),
		"the custom Move cursor must use its faster frame timing"
	)
	_expect(
		is_equal_approx(
			cursors.frame_duration(CursorManagerScript.CursorType.POINTER),
			CursorManagerScript.FRAME_DURATION
		),
		"original cursors must retain their frame timing"
	)
	_expect(
		cursors.frame_size(CursorManagerScript.CursorType.MOVE)
		== CursorManagerScript.MOVE_DISPLAY_SIZE,
		"the custom Move cursor must retain its rendered size"
	)
	_expect(
		cursors.hotspot(CursorManagerScript.CursorType.MOVE) == Vector2(32, 32),
		"the custom Move cursor hotspot must remain centered after resizing"
	)
	_expect(
		cursors.frame_texture(CursorManagerScript.CursorType.MOVE, 12) != null,
		"the thirteenth custom Move cursor frame must be available"
	)
	_expect(
		cursors.frame_count(CursorManagerScript.CursorType.ATTACK) == 13,
		"the custom Attack cursor must expose all thirteen rendered frames"
	)
	_expect(
		cursors.frame_size(CursorManagerScript.CursorType.ATTACK) == Vector2i(64, 64),
		"the custom Attack cursor must retain its rendered size"
	)
	_expect(
		cursors.hotspot(CursorManagerScript.CursorType.ATTACK) == Vector2(32, 32),
		"the custom Attack cursor hotspot must remain centered"
	)
	_expect(
		cursors.frame_texture(CursorManagerScript.CursorType.ATTACK, 12) != null,
		"the thirteenth custom Attack cursor frame must be available"
	)
	_expect(
		cursors.frame_count(CursorManagerScript.CursorType.ENTER) == 4,
		"the custom Enter cursor must expose all four rendered frames"
	)
	_expect(
		cursors.frame_size(CursorManagerScript.CursorType.ENTER) == Vector2i(64, 64),
		"the custom Enter cursor must retain its rendered size"
	)
	_expect(
		cursors.hotspot(CursorManagerScript.CursorType.ENTER) == Vector2(32, 32),
		"the custom Enter cursor hotspot must remain centered"
	)
	_expect(
		cursors.frame_texture(CursorManagerScript.CursorType.ENTER, 3) != null,
		"the fourth custom Enter cursor frame must be available"
	)
	_expect(
		cursors.frame_count(CursorManagerScript.CursorType.OVER_UNIT) == 24,
		"the custom Selectable cursor must expose all twenty-four rendered frames"
	)
	_expect(
		is_equal_approx(
			cursors.frame_duration(CursorManagerScript.CursorType.OVER_UNIT),
			CursorManagerScript.SELECTABLE_FRAME_DURATION
		),
		"the custom Selectable cursor must play at twice the original frame rate"
	)
	_expect(
		cursors.frame_size(CursorManagerScript.CursorType.OVER_UNIT) == Vector2i(64, 64),
		"the custom Selectable cursor must retain its rendered size"
	)
	_expect(
		cursors.hotspot(CursorManagerScript.CursorType.OVER_UNIT) == Vector2(32, 32),
		"the custom Selectable cursor hotspot must remain centered"
	)
	_expect(
		cursors.frame_texture(CursorManagerScript.CursorType.OVER_UNIT, 23) != null,
		"the twenty-fourth custom Selectable cursor frame must be available"
	)
	_expect(
		cursors.frame_count(CursorManagerScript.CursorType.DEPLOY) == 13,
		"the custom Deploy cursor must expose all thirteen rendered frames"
	)
	_expect(
		cursors.frame_size(CursorManagerScript.CursorType.DEPLOY) == Vector2i(64, 64),
		"the custom Deploy cursor must retain its rendered size"
	)
	_expect(
		cursors.hotspot(CursorManagerScript.CursorType.DEPLOY) == Vector2(32, 32),
		"the custom Deploy cursor hotspot must remain centered"
	)
	_expect(
		cursors.frame_texture(CursorManagerScript.CursorType.DEPLOY, 12) != null,
		"the thirteenth custom Deploy cursor frame must be available"
	)
	_expect(
		cursors.frame_count(CursorManagerScript.CursorType.CANT_DEPLOY) == 1,
		"the custom Cant Deploy cursor must use its single rendered frame"
	)
	_expect(
		cursors.frame_size(CursorManagerScript.CursorType.CANT_DEPLOY) == Vector2i(64, 64),
		"the custom Cant Deploy cursor must retain its rendered size"
	)
	_expect(
		cursors.hotspot(CursorManagerScript.CursorType.CANT_DEPLOY) == Vector2(32, 32),
		"the custom Cant Deploy cursor hotspot must remain centered"
	)
	_expect(
		cursors.frame_texture(CursorManagerScript.CursorType.CANT_DEPLOY, 0) != null,
		"the custom Cant Deploy cursor frame must be available"
	)
	_expect(
		cursors.frame_texture(CursorManagerScript.CursorType.CANT_DEPLOY, 1) == null,
		"the custom Cant Deploy cursor must not duplicate its static frame"
	)
	_expect(
		cursors.frame_count(CursorManagerScript.CursorType.GATHER) == 13,
		"the custom Gather cursor must expose all thirteen rendered frames"
	)
	_expect(
		cursors.frame_size(CursorManagerScript.CursorType.GATHER) == Vector2i(64, 64),
		"the custom Gather cursor must retain its rendered size"
	)
	_expect(
		cursors.hotspot(CursorManagerScript.CursorType.GATHER) == Vector2(32, 32),
		"the custom Gather cursor hotspot must remain centered"
	)
	_expect(
		cursors.frame_texture(CursorManagerScript.CursorType.GATHER, 12) != null,
		"the thirteenth custom Gather cursor frame must be available"
	)
	_expect(
		cursors.frame_count(CursorManagerScript.CursorType.TARGET_ABILITY) == 13,
		"the custom Target Ability cursor must expose all thirteen rendered frames"
	)
	_expect(
		cursors.frame_size(CursorManagerScript.CursorType.TARGET_ABILITY) == Vector2i(64, 64),
		"the custom Target Ability cursor must retain its rendered size"
	)
	_expect(
		cursors.hotspot(CursorManagerScript.CursorType.TARGET_ABILITY) == Vector2(32, 32),
		"the custom Target Ability cursor hotspot must remain centered"
	)
	_expect(
		cursors.frame_texture(CursorManagerScript.CursorType.TARGET_ABILITY, 12) != null,
		"the thirteenth custom Target Ability cursor frame must be available"
	)
	_expect(
		cursors.frame_count(CursorManagerScript.CursorType.CANT_MOVE) == 1,
		"the custom Cant Move cursor must use its single rendered frame"
	)
	_expect(
		cursors.frame_size(CursorManagerScript.CursorType.CANT_MOVE) == Vector2i(64, 64),
		"the custom Cant Move cursor must retain its rendered size"
	)
	_expect(
		cursors.hotspot(CursorManagerScript.CursorType.CANT_MOVE) == Vector2(32, 32),
		"the custom Cant Move cursor hotspot must remain centered"
	)
	_expect(
		cursors.frame_texture(CursorManagerScript.CursorType.CANT_MOVE, 0) != null,
		"the custom Cant Move cursor frame must be available"
	)
	_expect(
		cursors.frame_texture(CursorManagerScript.CursorType.CANT_MOVE, 1) == null,
		"the custom Cant Move cursor must not duplicate its static frame"
	)
	_expect(
		CursorManagerScript.CursorType.TARGET_ABILITY == 8,
		"the ninth original row must remain the generic targeted-ability cursor"
	)
	_expect(
		CursorManagerScript.CursorType.REPAIR == 11,
		"the twelfth cursor row must be reserved for repair commands"
	)
	_expect(
		CursorManagerScript.CursorType.DEPLOY == 12,
		"the thirteenth cursor row must be used for deploy commands"
	)
	for scroll_cursor in CursorManagerScript.SCROLL_CURSOR_ASSETS:
		_expect(
			cursors.frame_count(scroll_cursor) == 1,
			"each custom Scroll cursor must use its single rendered frame"
		)
		_expect(
			cursors.frame_size(scroll_cursor) == Vector2i(64, 64),
			"each custom Scroll cursor must retain its rendered size"
		)
		_expect(
			cursors.hotspot(scroll_cursor) == Vector2(32, 32),
			"each custom Scroll cursor hotspot must remain centered"
		)
		_expect(
			cursors.frame_texture(scroll_cursor, 0) != null,
			"each custom Scroll cursor frame must be available"
		)
		_expect(
			cursors.frame_texture(scroll_cursor, 1) == null,
			"custom Scroll cursors must not duplicate their static frame"
		)
	for cant_scroll_cursor in CursorManagerScript.CANT_SCROLL_CURSOR_ASSETS:
		_expect(
			cursors.frame_count(cant_scroll_cursor) == 1,
			"each custom Cant Scroll cursor must use its single rendered frame"
		)
		_expect(
			cursors.frame_size(cant_scroll_cursor) == Vector2i(64, 64),
			"each custom Cant Scroll cursor must retain its rendered size"
		)
		_expect(
			cursors.hotspot(cant_scroll_cursor) == Vector2(32, 32),
			"each custom Cant Scroll cursor hotspot must remain centered"
		)
		_expect(
			cursors.frame_texture(cant_scroll_cursor, 0) != null,
			"each custom Cant Scroll cursor frame must be available"
		)
		_expect(
			cursors.frame_texture(cant_scroll_cursor, 1) == null,
			"custom Cant Scroll cursors must not duplicate their static frame"
		)
	for cursor in cursors.cursor_count():
		for frame in cursors.frame_count(cursor):
			var texture: Texture2D = cursors.frame_texture(cursor, frame)
			var shadow_texture: Texture2D = cursors.shadow_frame_texture(cursor, frame)
			_expect(texture != null, "cursor %d frame %d must exist" % [cursor, frame])
			_expect(shadow_texture != null, "cursor %d shadow frame %d must exist" % [cursor, frame])
			if texture != null:
				_expect(
					texture.get_size() == Vector2(cursors.frame_size(cursor)),
					"cursor frames must use their configured scale"
				)

	var original_image: Image = cursors.frame_texture(
		CursorManagerScript.CursorType.INFANTRY_ROCK, 0
	).get_image()
	_expect(original_image.get_pixel(0, 0).a == 0.0, "magenta sheet pixels must become transparent")
	_expect(original_image.get_used_rect().has_area(), "the visible cursor pixels must remain opaque")
	_test_multiply_shadow(cursors, original_image)
	_expect(
		CursorManagerScript.HOTSPOTS[CursorManagerScript.CursorType.SCROLL_E]
		== Vector2(43, 33),
		"original per-cursor hotspot data must be retained"
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
		CursorManagerScript.CursorType.INFANTRY_ROCK, 0
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
	cursors.set_cursor(CursorManagerScript.CursorType.MOVE)
	var initial_frame: int = cursors.current_frame()
	cursors._process(CursorManagerScript.MOVE_FRAME_DURATION)
	_expect(
		cursors.current_frame()
		== (initial_frame + 1) % cursors.frame_count(CursorManagerScript.CursorType.MOVE),
		"the animated Move cursor must advance after its configured frame duration"
	)
	cursors.set_cursor(CursorManagerScript.CursorType.POINTER)
	cursors._process(CursorManagerScript.FRAME_DURATION * 2.0)
	_expect(cursors.current_frame() == 0, "the static Pointer cursor must remain on its only frame")


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s" % message)
