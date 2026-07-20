extends SceneTree

const TextureImageUtilsScript := preload("res://converters/texture_image_utils.gd")

const SOURCE_PATH := "res://assets/reworked/3DDATA/Textures/Arrw_nw_magenta_alpha.png"
const OUTPUT_PATH := "res://assets/converted/ui/cursors/arrw_nw.res"
const POINTER_SOURCE_PATH_PATTERN := (
	"res://assets/reworked/3DDATA/Textures/cursor_%04d.png"
)
const POINTER_OUTPUT_PATH_PATTERN := "res://assets/converted/ui/cursors/cursor_%04d.res"
const MOVE_SOURCE_PATH_PATTERN := (
	"res://assets/reworked/3DDATA/Textures/move_cursor_%04d.png"
)
const MOVE_OUTPUT_PATH_PATTERN := "res://assets/converted/ui/cursors/move_cursor_%04d.res"
const ATTACK_SOURCE_PATH_PATTERN := (
	"res://assets/reworked/3DDATA/Textures/attack_cursor_%04d.png"
)
const ATTACK_OUTPUT_PATH_PATTERN := "res://assets/converted/ui/cursors/attack_cursor_%04d.res"
const ENTER_SOURCE_PATH_PATTERN := (
	"res://assets/reworked/3DDATA/Textures/move_in_cursor_%04d.png"
)
const ENTER_OUTPUT_PATH_PATTERN := "res://assets/converted/ui/cursors/move_in_cursor_%04d.res"
const SELECTABLE_SOURCE_PATH_PATTERN := (
	"res://assets/reworked/3DDATA/Textures/selectable_%04d.png"
)
const SELECTABLE_OUTPUT_PATH_PATTERN := "res://assets/converted/ui/cursors/selectable_%04d.res"
const DEPLOY_SOURCE_PATH_PATTERN := (
	"res://assets/reworked/3DDATA/Textures/deploy_cursor_%04d.png"
)
const DEPLOY_OUTPUT_PATH_PATTERN := "res://assets/converted/ui/cursors/deploy_cursor_%04d.res"
const CANT_DEPLOY_SOURCE_PATH_PATTERN := (
	"res://assets/reworked/3DDATA/Textures/no_deploy_cursor_%04d.png"
)
const CANT_DEPLOY_OUTPUT_PATH_PATTERN := (
	"res://assets/converted/ui/cursors/no_deploy_cursor_%04d.res"
)
const GATHER_SOURCE_PATH_PATTERN := (
	"res://assets/reworked/3DDATA/Textures/gather_cursor_%04d.png"
)
const GATHER_OUTPUT_PATH_PATTERN := "res://assets/converted/ui/cursors/gather_cursor_%04d.res"
const TARGET_ABILITY_SOURCE_PATH_PATTERN := (
	"res://assets/reworked/3DDATA/Textures/ability_cursor_%04d.png"
)
const TARGET_ABILITY_OUTPUT_PATH_PATTERN := (
	"res://assets/converted/ui/cursors/ability_cursor_%04d.res"
)
const CANT_MOVE_SOURCE_PATH_PATTERN := (
	"res://assets/reworked/3DDATA/Textures/not_move_cursor_%04d.png"
)
const CANT_MOVE_OUTPUT_PATH_PATTERN := (
	"res://assets/converted/ui/cursors/not_move_cursor_%04d.res"
)
const FRAMES_PER_CURSOR := 8
const CURSOR_COUNT := 33
const MOVE_FRAME_COUNT := 13
const ATTACK_FRAME_COUNT := 13
const ENTER_FRAME_COUNT := 4
const SELECTABLE_FRAME_COUNT := 24
const DEPLOY_FRAME_COUNT := 13
const GATHER_FRAME_COUNT := 13
const TARGET_ABILITY_FRAME_COUNT := 13

const SCROLL_CURSOR_ASSETS := [
	"arrow_up",
	"arrow_up_right",
	"arrow_right",
	"arrow_down_right",
	"arrow_down",
	"arrow_down_left",
	"arrow_left",
	"arrow_up_left",
]

const CANT_SCROLL_CURSOR_ASSETS := [
	"arrow_stop_up",
	"arrow_stop_up_right",
	"arrow_stop_right",
	"arrow_stop_down_right",
	"arrow_stop_down",
	"arrow_stop_down_left",
	"arrow_stop_left",
	"arrow_stop_up_left",
]


func _initialize() -> void:
	var image: Image = TextureImageUtilsScript.load_image(SOURCE_PATH)
	if image == null:
		_fail("could not load %s" % SOURCE_PATH)
		return

	if image.get_width() % FRAMES_PER_CURSOR != 0 or image.get_height() % CURSOR_COUNT != 0:
		_fail(
			"sprite sheet size %s is not divisible into %dx%d frames"
			% [image.get_size(), FRAMES_PER_CURSOR, CURSOR_COUNT]
		)
		return
	var frame_size := Vector2i(
		image.get_width() / FRAMES_PER_CURSOR, image.get_height() / CURSOR_COUNT
	)
	if frame_size.x != frame_size.y:
		_fail("cursor frames must be square, got %s" % frame_size)
		return

	var output_directory := ProjectSettings.globalize_path(OUTPUT_PATH.get_base_dir())
	var directory_error := DirAccess.make_dir_recursive_absolute(output_directory)
	if directory_error != OK:
		_fail("could not create %s (error %d)" % [output_directory, directory_error])
		return

	var texture := ImageTexture.create_from_image(image)
	var save_error := ResourceSaver.save(texture, OUTPUT_PATH)
	if save_error != OK:
		_fail("could not save %s (error %d)" % [OUTPUT_PATH, save_error])
		return

	if not _convert_cursor_sequence(
		"Pointer", POINTER_SOURCE_PATH_PATTERN, POINTER_OUTPUT_PATH_PATTERN, 0, 1
	):
		return
	if not _convert_cursor_sequence(
		"Move", MOVE_SOURCE_PATH_PATTERN, MOVE_OUTPUT_PATH_PATTERN, 0, MOVE_FRAME_COUNT
	):
		return
	if not _convert_cursor_sequence(
		"Attack", ATTACK_SOURCE_PATH_PATTERN, ATTACK_OUTPUT_PATH_PATTERN, 0, ATTACK_FRAME_COUNT
	):
		return
	if not _convert_cursor_sequence(
		"Enter", ENTER_SOURCE_PATH_PATTERN, ENTER_OUTPUT_PATH_PATTERN, 0, ENTER_FRAME_COUNT
	):
		return
	if not _convert_cursor_sequence(
		"Selectable",
		SELECTABLE_SOURCE_PATH_PATTERN,
		SELECTABLE_OUTPUT_PATH_PATTERN,
		0,
		SELECTABLE_FRAME_COUNT
	):
		return
	if not _convert_cursor_sequence(
		"Deploy", DEPLOY_SOURCE_PATH_PATTERN, DEPLOY_OUTPUT_PATH_PATTERN, 0, DEPLOY_FRAME_COUNT
	):
		return
	if not _convert_cursor_sequence(
		"Cant Deploy", CANT_DEPLOY_SOURCE_PATH_PATTERN, CANT_DEPLOY_OUTPUT_PATH_PATTERN, 0, 1
	):
		return
	if not _convert_cursor_sequence(
		"Gather", GATHER_SOURCE_PATH_PATTERN, GATHER_OUTPUT_PATH_PATTERN, 0, GATHER_FRAME_COUNT
	):
		return
	if not _convert_cursor_sequence(
		"Target Ability",
		TARGET_ABILITY_SOURCE_PATH_PATTERN,
		TARGET_ABILITY_OUTPUT_PATH_PATTERN,
		0,
		TARGET_ABILITY_FRAME_COUNT
	):
		return
	if not _convert_cursor_sequence(
		"Cant Move", CANT_MOVE_SOURCE_PATH_PATTERN, CANT_MOVE_OUTPUT_PATH_PATTERN, 1, 1
	):
		return
	for asset_name in SCROLL_CURSOR_ASSETS:
		if not _convert_cursor_sequence(
			"Scroll %s" % asset_name,
			"res://assets/reworked/3DDATA/Textures/%s.png" % asset_name,
			"res://assets/converted/ui/cursors/%s.res" % asset_name,
			0,
			1
		):
			return
	for asset_name in CANT_SCROLL_CURSOR_ASSETS:
		if not _convert_cursor_sequence(
			"Cant Scroll %s" % asset_name,
			"res://assets/reworked/3DDATA/Textures/%s.png" % asset_name,
			"res://assets/converted/ui/cursors/%s.res" % asset_name,
			0,
			1
		):
			return

	print(
		"Converted cursor sprite sheet, Pointer, %d Move frames, %d Attack frames, %d Enter frames, %d Selectable frames, %d Deploy frames, Cant Deploy, %d Gather frames, %d Target Ability frames, Cant Move frame, 8 Scroll arrows, and 8 Cant Scroll arrows"
		% [
			MOVE_FRAME_COUNT,
			ATTACK_FRAME_COUNT,
			ENTER_FRAME_COUNT,
			SELECTABLE_FRAME_COUNT,
			DEPLOY_FRAME_COUNT,
			GATHER_FRAME_COUNT,
			TARGET_ABILITY_FRAME_COUNT,
		]
	)
	quit(0)


func _convert_cursor_sequence(
	label: String,
	source_path_pattern: String,
	output_path_pattern: String,
	first_frame: int,
	frame_count: int
) -> bool:
	var frame_size := Vector2i.ZERO
	for frame_index in frame_count:
		var frame_number := first_frame + frame_index
		var source_path := _frame_path(source_path_pattern, frame_number)
		var image: Image = TextureImageUtilsScript.load_image(source_path)
		if image == null:
			_fail("could not load %s" % source_path)
			return false
		if image.get_width() != image.get_height():
			_fail("%s cursor frame must be square, got %s: %s" % [label, image.get_size(), source_path])
			return false
		if frame_size == Vector2i.ZERO:
			frame_size = image.get_size()
		elif image.get_size() != frame_size:
			_fail("%s cursor frames must have equal sizes, got %s: %s" % [label, image.get_size(), source_path])
			return false
		var texture := ImageTexture.create_from_image(image)
		var output_path := _frame_path(output_path_pattern, frame_number)
		var save_error := ResourceSaver.save(texture, output_path)
		if save_error != OK:
			_fail("could not save %s (error %d)" % [output_path, save_error])
			return false
	return true


func _frame_path(path_pattern: String, frame_number: int) -> String:
	return path_pattern % frame_number if path_pattern.contains("%") else path_pattern


func _fail(message: String) -> void:
	printerr("Cursor conversion failed: %s" % message)
	quit(1)
