extends SceneTree

const CursorManagerScript := preload("res://scripts/ui/cursor_manager.gd")
const CursorModelCatalogScript := preload("res://scripts/ui/cursor_model_catalog.gd")

var _assertions := 0
var _failures := 0


func _initialize() -> void:
	await process_frame
	var cursors: Variant = get_root().get_node_or_null("Cursors")
	_expect(cursors != null, "the Cursors autoload must be available")
	if cursors != null:
		_test_model_catalog(cursors)
		_test_model_viewport(cursors)
		_test_every_cursor_uses_a_model(cursors)
		_test_cursor_render_passes(cursors)
		_test_cursor_selection(cursors)

	if _failures > 0:
		printerr("Cursor tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("Cursor tests: %d assertions passed" % _assertions)
	quit(0)


func _test_model_catalog(cursors) -> void:
	_expect(
		CursorManagerScript.ORIGINAL_CURSOR_COUNT == 33,
		"the original Cursor Test.txt ordering must retain all 33 entries"
	)
	_expect(cursors.cursor_count() == 36, "the remake semantic states must remain appended")
	_expect(
		CursorManagerScript.CURSOR_MODEL_KEYS.size() == cursors.cursor_count(),
		"every semantic cursor must map to a 3D model key"
	)
	_expect(
		CursorModelCatalogScript.MODEL_FILES.size() == cursors.cursor_count(),
		"every semantic cursor must own a replaceable catalog entry"
	)
	for cursor in cursors.cursor_count():
		_expect(
			CursorManagerScript.CURSOR_MODEL_KEYS.has(cursor),
			"cursor %d must not fall back to a raster asset" % cursor
		)
		var source_path: String = cursors.model_source_path(cursor)
		_expect(not source_path.is_empty(), "cursor %d must resolve an original XBF" % cursor)
		_expect(
			FileAccess.file_exists(source_path),
			"cursor %d must reference a local original XBF: %s" % [cursor, source_path]
		)
		_expect(
			not cursors.model_scene_path(cursor).is_empty(),
			"cursor %d must resolve a converted scene path" % cursor
		)

	_expect(
		cursors.model_source_path(CursorManagerScript.CursorType.INFANTRY_ROCK).get_file()
		== "CU_Enter_H0.xbf",
		"Infantry Rock must temporarily reuse the Enter model"
	)
	_expect(
		cursors.model_source_path(CursorManagerScript.CursorType.DN3).get_file()
		== "CU_Move_Map_H0.xbf",
		"DN3 must temporarily reuse the blue Move Map model"
	)
	_expect(
		cursors.model_source_path(CursorManagerScript.CursorType.DN4).get_file()
		== "CU_DeathHand_H0.xbf",
		"the skull DN4 state must use the Death Hand model"
	)
	_expect(
		cursors.model_source_path(CursorManagerScript.CursorType.DN5).get_file()
		== "CU_PickUp_H0.xbf",
		"the object DN5 state must use the Pick Up model"
	)
	_expect(
		cursors.model_source_path(CursorManagerScript.CursorType.DN6).get_file()
		== "CU_Teleport_H0.xbf",
		"the ring DN6 state must use the Teleport model"
	)
	_expect(
		cursors.model_scene_path(CursorManagerScript.CursorType.GATHER)
		!= cursors.model_scene_path(CursorManagerScript.CursorType.MOVE),
		"Gather must have its own replaceable scene even while sharing the Move XBF"
	)
	var directional_sources := {
		CursorManagerScript.CursorType.SCROLL_N: "CU_Scroll_down_H0.xbf",
		CursorManagerScript.CursorType.SCROLL_NE: "CU_Scroll_downright_H0.xbf",
		CursorManagerScript.CursorType.SCROLL_E: "CU_Scroll_right_H0.xbf",
		CursorManagerScript.CursorType.SCROLL_SE: "CU_Scroll_upright_H0.xbf",
		CursorManagerScript.CursorType.SCROLL_S: "CU_Scroll_up_H0.xbf",
		CursorManagerScript.CursorType.SCROLL_SW: "CU_Scroll_upleft_H0.xbf",
		CursorManagerScript.CursorType.SCROLL_W: "CU_Scroll_left_H0.xbf",
		CursorManagerScript.CursorType.SCROLL_NW: "CU_Scroll_downleft_H0.xbf",
		CursorManagerScript.CursorType.CANT_SCROLL_N: "CU_Cant_Scroll_Down_H0.xbf",
		CursorManagerScript.CursorType.CANT_SCROLL_NE: "CU_Cant_Scroll_Downleft_H0.xbf",
		CursorManagerScript.CursorType.CANT_SCROLL_E: "CU_Cant_Scroll_left_H0.xbf",
		CursorManagerScript.CursorType.CANT_SCROLL_SE: "CU_Cant_Scroll_Upleft_H0.xbf",
		CursorManagerScript.CursorType.CANT_SCROLL_S: "CU_Cant_Scroll_Up_H0.xbf",
		CursorManagerScript.CursorType.CANT_SCROLL_SW: "CU_Cant_Scroll_Upright_H0.xbf",
		CursorManagerScript.CursorType.CANT_SCROLL_W: "CU_Cant_Scroll_right_H0.xbf",
		CursorManagerScript.CursorType.CANT_SCROLL_NW: "CU_Cant_Scroll_Downright_H0.xbf",
	}
	for cursor: int in directional_sources:
		_expect(
			cursors.model_source_path(cursor).get_file() == directional_sources[cursor],
			"cursor %d must use its visually correct converted direction" % cursor
		)
	var manager_source := FileAccess.get_file_as_string("res://scripts/ui/cursor_manager.gd")
	_expect(not manager_source.contains("frame_texture"), "the runtime manager must not expose raster frames")
	_expect(not manager_source.contains("TextureImageUtils"), "the runtime manager must not load raster cursor images")
	_expect(not manager_source.contains("SPRITE"), "the runtime manager must not contain a sprite fallback path")


func _test_model_viewport(cursors) -> void:
	var model_viewport := cursors.get_node_or_null("CursorModelViewport") as SubViewport
	_expect(model_viewport != null, "the cursor manager must own a 3D render viewport")
	_expect(
		model_viewport != null and model_viewport.size == CursorManagerScript.MODEL_VIEWPORT_SIZE,
		"the 3D cursor viewport must render at the configured display size"
	)
	_expect(model_viewport != null and model_viewport.transparent_bg, "the 3D cursor viewport must be transparent")
	_expect(model_viewport != null and model_viewport.own_world_3d, "3D cursors must render in an isolated world")
	var screen_viewport := cursors.get_node_or_null("CursorScreenModelViewport") as SubViewport
	_expect(screen_viewport != null, "screen-marked cursor surfaces must have a separate viewport output")
	_expect(
		screen_viewport != null and not screen_viewport.transparent_bg,
		"the additive !-surface pass must clear to defined black instead of undefined transparent RGB"
	)
	_expect(
		screen_viewport != null
		and screen_viewport.own_world_3d
		and screen_viewport.get_node_or_null("Models") != model_viewport.get_node_or_null("Models"),
		"Compatibility rendering requires an independent scene tree for each cursor pass"
	)
	var model_camera := cursors.get_node_or_null("CursorModelViewport/Camera3D") as Camera3D
	_expect(
		model_camera != null and model_camera.projection == Camera3D.PROJECTION_ORTHOGONAL,
		"3D cursors must use an orthographic projection"
	)
	_expect(
		model_camera != null
		and is_equal_approx(model_camera.size, CursorManagerScript.MODEL_CAMERA_ORTHO_SIZE),
		"the 3D cursor camera must preserve the original model scale"
	)
	_expect(
		model_camera != null
		and model_camera.position.z < 0.0
		and (-model_camera.transform.basis.z).z > 0.0,
		"the cursor camera must view the XBFs from their authored side"
	)
	_expect(
		model_camera != null
		and model_camera.cull_mask == CursorManagerScript.CURSOR_NORMAL_RENDER_LAYER,
		"the normal cursor viewport must render only ordinary XBF surfaces"
	)
	var screen_camera := cursors.get_node_or_null("CursorScreenModelViewport/Camera3D") as Camera3D
	_expect(
		screen_camera != null
		and screen_camera.cull_mask == CursorManagerScript.CURSOR_SCREEN_RENDER_LAYER,
		"the screen cursor viewport must render only !-marked XBF surfaces"
	)
	var model_sprite := cursors.get_node_or_null("CursorLayer/Model") as Sprite2D
	_expect(model_sprite != null, "the normal model viewport must have a screen-space output")
	_expect(
		model_sprite != null and model_sprite.material == null,
		"ordinary cursor surfaces must use normal alpha composition"
	)
	var screen_sprite := cursors.get_node_or_null("CursorLayer/ScreenModel") as Sprite2D
	_expect(screen_sprite != null, "!-marked cursor surfaces must have a screen-space output")
	var screen_material := screen_sprite.material as ShaderMaterial if screen_sprite != null else null
	_expect(screen_material != null, "the 3D cursor output must use a composition shader")
	var screen_shader_code := screen_material.shader.code if screen_material != null else ""
	_expect(
		screen_shader_code.contains("hint_screen_texture"),
		"the cursor composition shader must sample the game image below it"
	)
	_expect(
		screen_shader_code.contains("vec3(1.0) - (vec3(1.0) - backdrop)"),
		"the cursor composition shader must use screen blending so black stays transparent"
	)
	_expect(
		screen_shader_code.contains("blend_disabled")
		and screen_shader_code.contains("COLOR = vec4(screened, 1.0)"),
		"the completed screen colour must not be erased by additive viewport alpha"
	)
	_expect(
		cursors.get_node_or_null("CursorLayer/Color") == null
		and cursors.get_node_or_null("CursorLayer/Shadow") == null,
		"no raster color or shadow fallback nodes may remain"
	)


func _test_every_cursor_uses_a_model(cursors) -> void:
	var previous_model: Node3D = null
	var previous_screen_model: Node3D = null
	for cursor in cursors.cursor_count():
		cursors.set_cursor(cursor)
		_expect(cursors.current_cursor() == cursor, "cursor %d must be selectable" % cursor)
		_expect(cursors.model_cursor_available(cursor), "cursor %d must have a converted scene" % cursor)
		_expect(cursors.using_model_cursor(), "cursor %d must activate a 3D model" % cursor)
		var model_key := String(CursorManagerScript.CURSOR_MODEL_KEYS[cursor])
		var model := cursors.get_node_or_null("CursorModelViewport/Models/%s" % model_key) as Node3D
		var screen_model := cursors.get_node_or_null(
			"CursorScreenModelViewport/Models/%s" % model_key
		) as Node3D
		_expect(model != null and model.visible, "cursor %d must instantiate and show %s" % [cursor, model_key])
		_expect(
			screen_model != null and screen_model.visible,
			"cursor %d must instantiate its !-surface pass for %s" % [cursor, model_key]
		)
		if previous_model != null and previous_model != model:
			_expect(not previous_model.visible, "switching cursors must hide the previous 3D model")
		if previous_screen_model != null and previous_screen_model != screen_model:
			_expect(
				not previous_screen_model.visible,
				"switching cursors must hide the previous !-surface model"
			)
		if model != null:
			var player := model.find_child("AnimationPlayer", true, false) as AnimationPlayer
			if player != null:
				_expect(player.is_playing(), "animated cursor %d must play its XBF timeline" % cursor)
		if screen_model != null:
			var screen_player := screen_model.find_child("AnimationPlayer", true, false) as AnimationPlayer
			if screen_player != null:
				_expect(
					screen_player.is_playing(),
					"animated !-surface cursor %d must play its XBF timeline" % cursor
				)
		previous_model = model
		previous_screen_model = screen_model
	var model_sprite := cursors.get_node_or_null("CursorLayer/Model") as Sprite2D
	_expect(model_sprite != null and model_sprite.visible, "the active 3D viewport output must remain visible")
	var screen_sprite := cursors.get_node_or_null("CursorLayer/ScreenModel") as Sprite2D
	_expect(screen_sprite != null and screen_sprite.visible, "the active !-marked surface output must remain visible")
	cursors.set_cursor(CursorManagerScript.CursorType.POINTER)


func _test_cursor_render_passes(cursors) -> void:
	cursors.set_cursor(CursorManagerScript.CursorType.ATTACK)
	var attack := cursors.get_node_or_null("CursorModelViewport/Models/attack") as Node3D
	var normal_surfaces := 0
	var screen_surfaces := 0
	if attack != null:
		for node in attack.find_children("*", "MeshInstance3D", true, false):
			var mesh_instance := node as MeshInstance3D
			var surface_count := mesh_instance.mesh.get_surface_count() if mesh_instance.mesh != null else 0
			if mesh_instance.has_meta("cursor_screen_pass"):
				screen_surfaces += surface_count
				_expect(
					mesh_instance.layers == CursorManagerScript.CURSOR_SCREEN_RENDER_LAYER,
					"!-marked Attack surfaces must belong only to the screen render layer"
				)
			else:
				normal_surfaces += surface_count
				_expect(
					mesh_instance.layers == CursorManagerScript.CURSOR_NORMAL_RENDER_LAYER,
					"ordinary Attack surfaces must belong only to the normal render layer"
				)
	_expect(normal_surfaces > 0, "Attack must retain its ordinary red surfaces")
	_expect(screen_surfaces > 0, "Attack must isolate its !%orange surface for screen composition")

	var blue_ring_quirks := {
		CursorManagerScript.CursorType.MOVE: "move",
		CursorManagerScript.CursorType.ATTACK: "attack",
		CursorManagerScript.CursorType.DEPLOY: "deploy",
	}
	for cursor: int in blue_ring_quirks:
		cursors.set_cursor(cursor)
		var model_key: String = blue_ring_quirks[cursor]
		var model := cursors.get_node_or_null(
			"CursorModelViewport/Models/%s" % model_key
		) as Node3D
		var normal_names := _surface_names_for_pass(model, false)
		var screen_names := _surface_names_for_pass(model, true)
		_expect(
			screen_names.has("whitering2.tga"),
			"%s's unmarked blue whitering2 surface must use its source-specific screen quirk"
			% model_key.capitalize()
		)
		_expect(
			not normal_names.has("whitering2.tga"),
			"%s's blue ring must not remain in the normal alpha-composited pass"
			% model_key.capitalize()
		)
	cursors.set_cursor(CursorManagerScript.CursorType.POINTER)


func _surface_names_for_pass(model: Node3D, screen_pass: bool) -> PackedStringArray:
	var names := PackedStringArray()
	if model == null:
		return names
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh == null or mesh_instance.has_meta("cursor_screen_pass") != screen_pass:
			continue
		for surface in mesh_instance.mesh.get_surface_count():
			names.append(String(mesh_instance.mesh.surface_get_name(surface)).to_lower())
	return names


func _test_cursor_selection(cursors) -> void:
	cursors.set_cursor(CursorManagerScript.CursorType.MOVE)
	_expect(cursors.current_cursor() == CursorManagerScript.CursorType.MOVE, "the base cursor must be selectable")
	cursors.set_edge_scroll_cursor(Vector2(1, 1), true)
	_expect(
		cursors.current_cursor() == CursorManagerScript.CursorType.SCROLL_NE,
		"north-east edge scroll must use its directional 3D cursor"
	)
	cursors.set_edge_scroll_cursor(Vector2(1, 1), false)
	_expect(
		cursors.current_cursor() == CursorManagerScript.CursorType.CANT_SCROLL_NE,
		"blocked north-east edge scroll must use its disabled 3D cursor"
	)
	cursors.set_edge_scroll_cursor(Vector2.ZERO, false)
	_expect(cursors.current_cursor() == CursorManagerScript.CursorType.MOVE, "leaving the edge must restore the base cursor")

	cursors.set_override(&"low", CursorManagerScript.CursorType.ATTACK, 10)
	cursors.set_override(&"high", CursorManagerScript.CursorType.DEPLOY, 20)
	_expect(cursors.current_cursor() == CursorManagerScript.CursorType.DEPLOY, "the highest-priority model override must win")
	cursors.clear_override(&"high")
	_expect(cursors.current_cursor() == CursorManagerScript.CursorType.ATTACK, "clearing an override must restore the next model")
	cursors.clear_override(&"low")
	_expect(cursors.current_cursor() == CursorManagerScript.CursorType.MOVE, "clearing all overrides must restore the base model")
	cursors.set_cursor(CursorManagerScript.CursorType.POINTER)


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s" % message)
