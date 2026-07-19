extends SceneTree

const TextureImageUtilsScript := preload("res://converters/texture_image_utils.gd")

const SOURCE_PATH := "res://assets/reworked/3DDATA/Textures/Arrw_nw_magenta_alpha.png"
const OUTPUT_PATH := "res://assets/converted/ui/cursors/arrw_nw.res"
const FRAMES_PER_CURSOR := 8
const CURSOR_COUNT := 33


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

	print("Converted cursor sprite sheet: %s" % OUTPUT_PATH)
	quit(0)


func _fail(message: String) -> void:
	printerr("Cursor conversion failed: %s" % message)
	quit(1)
