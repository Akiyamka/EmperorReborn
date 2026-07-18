class_name TextureImageUtils
extends RefCounted


static func load_image(path: String) -> Image:
	var absolute_path := ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(absolute_path):
		return null
	var image := Image.new()
	var err := image.load(absolute_path)
	if err != OK:
		return null
	if _is_16bpp_tga(absolute_path):
		_force_opaque_alpha(image)
	return image


## The attribute bit of 16bpp source TGAs is meaningless: the game's own
## loader always reads these pixels as opaque, and transparency comes solely
## from the magenta colour key. Godot's decoder honours the bit as per-pixel
## alpha, which turns entire textures (e.g. "=AT_overhangwall_D_128.tga")
## fully transparent.
static func _is_16bpp_tga(absolute_path: String) -> bool:
	if absolute_path.get_extension().to_lower() != "tga":
		return false
	var file := FileAccess.open(absolute_path, FileAccess.READ)
	if file == null:
		return false
	var header := file.get_buffer(18)
	return header.size() >= 17 and header[16] == 16


static func _force_opaque_alpha(image: Image) -> void:
	image.convert(Image.FORMAT_RGBA8)
	var data := image.get_data()
	for i in range(3, data.size(), 4):
		data[i] = 255
	image.set_data(image.get_width(), image.get_height(), image.has_mipmaps(), Image.FORMAT_RGBA8, data)


static func load_image_with_magenta_alpha(path: String) -> Image:
	var image := load_image(path)
	if image == null:
		return null
	apply_magenta_to_alpha(image)
	return image


static func apply_magenta_to_alpha(image: Image) -> bool:
	image.convert(Image.FORMAT_RGBA8)
	var keyed := PackedByteArray()
	keyed.resize(image.get_width() * image.get_height())
	var has_magenta := false
	for y in image.get_height():
		for x in image.get_width():
			var color := image.get_pixel(x, y)
			if color.r > 0.92 and color.g < 0.12 and color.b > 0.92:
				color.a = 0.0
				image.set_pixel(x, y, color)
				keyed[y * image.get_width() + x] = 1
				has_magenta = true

	if not has_magenta:
		return false

	for y in image.get_height():
		for x in image.get_width():
			if keyed[y * image.get_width() + x] == 0:
				continue
			var fill := _nearest_opaque_color(image, keyed, Vector2i(x, y), 4)
			fill.a = 0.0
			image.set_pixel(x, y, fill)
	return true


static func _nearest_opaque_color(image: Image, keyed: PackedByteArray, pixel: Vector2i, radius: int) -> Color:
	var width := image.get_width()
	var height := image.get_height()
	for distance in range(1, radius + 1):
		for y in range(maxi(0, pixel.y - distance), mini(height, pixel.y + distance + 1)):
			for x in range(maxi(0, pixel.x - distance), mini(width, pixel.x + distance + 1)):
				if abs(pixel.x - x) != distance and abs(pixel.y - y) != distance:
					continue
				if keyed[y * width + x] != 0:
					continue
				var color := image.get_pixel(x, y)
				if color.a > 0.5:
					return Color(color.r, color.g, color.b, 0.0)
	return Color(0.0, 0.0, 0.0, 0.0)
