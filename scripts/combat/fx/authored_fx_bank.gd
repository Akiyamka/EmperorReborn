extends RefCounted

const INLINE_FX_TEXTURE_DIR := "res://assets/raw_original_content/3DDATA/Textures"

static var _texture_paths_by_lowercase: Dictionary = {}
static var _texture_sequence_cache: Dictionary = {}


static func find_original_node(node: Node, original_name: String) -> Node3D:
	if node is Node3D \
	and String(node.get_meta("original_name", "")) == original_name:
		return node as Node3D
	for child in node.get_children():
		var result := find_original_node(child, original_name)
		if result != null:
			return result
	return null


## Expands XBF start/stop pairs into one emission per authored interior frame.
static func particle_schedule(
		events: Array,
		bank_id: String,
		clip_start_frame: int,
		clip_end_frame: int,
		attachment_filter := Callable(),
		filter_events_to_clip := false
	) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var active_frames := {}
	for event_value: Variant in events:
		var event := event_value as Dictionary
		if String(event.get("bank_id", "")) != bank_id:
			continue
		var attachment := String(event.get("attachment", ""))
		if attachment_filter.is_valid() and not attachment_filter.call(attachment):
			continue
		var frame := int(event.get("frame", -1))
		if filter_events_to_clip \
		and (frame < clip_start_frame or frame > clip_end_frame):
			continue
		var action := String(event.get("action", ""))
		if action == "start":
			if filter_events_to_clip and active_frames.has(attachment):
				_append_particle_frames(
					result, int(active_frames[attachment]), frame, attachment
				)
			active_frames[attachment] = frame
		elif action == "stop" and active_frames.has(attachment):
			var start_frame := int(active_frames[attachment])
			active_frames.erase(attachment)
			if not filter_events_to_clip \
			and (start_frame < clip_start_frame or frame > clip_end_frame):
				continue
			_append_particle_frames(result, start_frame, frame, attachment)
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["frame"]) < int(b["frame"])
	)
	return result


static func _append_particle_frames(
		result: Array[Dictionary],
		start_frame: int,
		stop_frame: int,
		attachment: String
	) -> void:
	if stop_frame < start_frame:
		return
	var first_particle_frame := start_frame + 1 \
		if stop_frame - start_frame > 1 else start_frame
	var particle_count := maxi(stop_frame - start_frame - 1, 1)
	for particle_offset in particle_count:
		result.append({
			"frame": first_particle_frame + particle_offset,
			"attachment": attachment,
		})


## Materializes the common XBF timeline skeleton after callers resolve each
## authored attachment into its effect-specific callback.
static func start_timeline(
		owner: Node,
		callbacks: Array[Dictionary],
		base_frame: int,
		seconds_per_frame: float,
		tail_seconds := 0.0
	) -> Tween:
	if owner == null or callbacks.is_empty():
		return null
	var timeline := owner.create_tween()
	var previous_time := 0.0
	for entry: Dictionary in callbacks:
		var emission_time := maxf(
			float(int(entry.get("frame", base_frame)) - base_frame)
				* seconds_per_frame,
			0.0
		)
		if emission_time > previous_time:
			timeline.tween_interval(emission_time - previous_time)
		timeline.tween_callback(entry["callback"] as Callable)
		previous_time = emission_time
	if tail_seconds > 0.0:
		timeline.tween_interval(tail_seconds)
	return timeline


static func billboard_material(
		texture: Texture2D, tint := Color.WHITE
	) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_texture = texture
	material.albedo_color = tint
	return material


static func billboard_quad(
		texture: Texture2D, size: float, tint := Color.WHITE
	) -> MeshInstance3D:
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE * size
	quad.material = billboard_material(texture, tint)
	var visual := MeshInstance3D.new()
	visual.mesh = quad
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return visual


## Creates the single billboard-particle shape used by muzzle banks and
## impacts. Callers supply only authored metadata and motion policy.
static func spawn_frame_animated_quad(
		parent: Node,
		textures: Array[Texture2D],
		options: Dictionary
	) -> Dictionary:
	if parent == null or not parent.is_inside_tree() or textures.is_empty():
		return {}
	var particle := options.get("particle") as Node3D
	if particle == null:
		particle = Node3D.new()
	particle.name = String(options.get("name", particle.name))
	for key: Variant in (options.get("metadata", {}) as Dictionary):
		particle.set_meta(StringName(String(key)), options["metadata"][key])
	var size := float(options.get("size", 1.0))
	var tint := options.get("tint", Color.WHITE) as Color
	var visual := options.get("visual") as MeshInstance3D
	if visual == null:
		visual = billboard_quad(textures.front(), size, tint)
		visual.name = "Visual"
		particle.add_child(visual)
	parent.add_child(particle)
	particle.top_level = bool(options.get("top_level", true))
	var start := options.get("position", Vector3.ZERO) as Vector3
	particle.global_position = start

	var frame_seconds := float(options.get("frame_seconds", 0.05))
	var duration := frame_seconds * float(textures.size())
	var velocity := options.get("velocity", Vector3.ZERO) as Vector3
	var acceleration := options.get("acceleration", Vector3.ZERO) as Vector3
	if not velocity.is_zero_approx() or not acceleration.is_zero_approx():
		var motion := particle.create_tween().set_process_mode(
			Tween.TWEEN_PROCESS_PHYSICS
		)
		motion.tween_method(
			integrate_motion.bind(particle, start, velocity, acceleration),
			0.0, duration, duration
		)

	var material := (visual.mesh as QuadMesh).material as StandardMaterial3D
	var opacities: PackedFloat32Array = options.get(
		"opacities", PackedFloat32Array()
	) as PackedFloat32Array
	var animation := particle.create_tween()
	for frame_index in textures.size():
		var opacity := opacities[frame_index] \
			if frame_index < opacities.size() else tint.a
		animation.tween_callback(
			set_frame.bind(material, textures[frame_index], tint, opacity)
		)
		animation.tween_interval(frame_seconds)
	if bool(options.get("free_after_animation", true)):
		animation.finished.connect(particle.queue_free)
	return {
		"particle": particle,
		"visual": visual,
		"quad": visual.mesh as QuadMesh,
		"material": material,
		"duration": duration,
		"animation": animation,
	}


static func integrate_motion(
		elapsed: float,
		particle: Node3D,
		start: Vector3,
		velocity: Vector3,
		acceleration: Vector3
	) -> void:
	if particle == null or not is_instance_valid(particle):
		return
	particle.global_position = start + velocity * elapsed \
		+ 0.5 * acceleration * elapsed * elapsed


static func set_frame(
		material: StandardMaterial3D,
		texture: Texture2D,
		tint: Color,
		opacity: float
	) -> void:
	if material == null:
		return
	material.albedo_texture = texture
	var color := tint
	color.a = opacity
	material.albedo_color = color


static func load_texture_sequence(base_name: String, count: int) -> Array[Texture2D]:
	var cache_key := "%s:%d" % [base_name.to_lower(), count]
	if _texture_sequence_cache.has(cache_key):
		var cached: Array[Texture2D] = []
		cached.assign(_texture_sequence_cache[cache_key])
		return cached
	var result: Array[Texture2D] = []
	for frame in count:
		# Concatenate because source names such as `!%Bru` contain a literal `%`.
		var path := resolved_texture_path(base_name + str(frame) + ".tga")
		var source_texture := load(path) as Texture2D
		if source_texture == null:
			return []
		result.append(opaque_additive_texture(source_texture))
	_texture_sequence_cache[cache_key] = result
	return result


static func resolved_texture_path(file_name: String) -> String:
	if _texture_paths_by_lowercase.is_empty():
		var directory := DirAccess.open(INLINE_FX_TEXTURE_DIR)
		if directory != null:
			for entry in directory.get_files():
				_texture_paths_by_lowercase[entry.to_lower()] = \
					INLINE_FX_TEXTURE_DIR + "/" + entry
	return String(_texture_paths_by_lowercase.get(
		file_name.to_lower(), INLINE_FX_TEXTURE_DIR + "/" + file_name
	))


static func opaque_additive_texture(source: Texture2D) -> Texture2D:
	var image := source.get_image()
	if image == null or image.is_empty():
		return source
	image.convert(Image.FORMAT_RGBA8)
	var data := image.get_data()
	for alpha_index in range(3, data.size(), 4):
		data[alpha_index] = 255
	image.set_data(
		image.get_width(), image.get_height(), image.has_mipmaps(),
		Image.FORMAT_RGBA8, data
	)
	return ImageTexture.create_from_image(image)
