class_name CombatImpactEffect
extends Node3D

## Short-lived rules-backed impact presentation. Most ExplosionType XBFs are
## directly renderable. ShellHit is an authored particle-emitter rig: its
## `#bing` cubes are invisible moving anchors. In the XBF event table, record
## types 3/4 start and stop an FX bank; they are not animation frame numbers.

const RULE_UPDATES_PER_SECOND := 20.0
const DEFAULT_DURATION := 0.5
const INLINE_FX_TEXTURE_DIR := "res://assets/raw_original_content/3DDATA/Textures"
const SHELL_HIT_ID := &"ShellHit"
const SHELL_HIT_BURST_SEQUENCE := "!%Bru"
const SHELL_HIT_BURST_FRAME_COUNT := 21
const SHELL_HIT_BURST_SIZE := 2.0
const SHELL_HIT_BURST_DURATION := 1.05
const SHELL_HIT_SMOKE_FIRST_FRAME := 2
const SHELL_HIT_SMOKE_OPACITY := 0.55
const SHELL_HIT_SHRAPNEL_SEQUENCE := "!@sm"
const SHELL_HIT_SHRAPNEL_FRAME_COUNT := 11
const SHELL_HIT_SHRAPNEL_SIZE := 0.16
const SHELL_HIT_SHRAPNEL_DURATION := 0.65
const SHELL_HIT_SHRAPNEL_COUNT := 16
const SHELL_HIT_SHRAPNEL_TINT := Color(1.8, 1.45, 0.72, 1.0)
const SHELL_HIT_LIGHT_COLOR := Color(1.0, 0.43, 0.12)
const SHELL_HIT_LIGHT_RANGE := 3.5

static var _texture_sequence_cache: Dictionary = {}

var effect_id: StringName = &""
var _authored_visual: Node3D
var _particle_index := 0
var _follow_particles: Array[Dictionary] = []
var _random := RandomNumberGenerator.new()


func _init() -> void:
	_random.randomize()
	set_process(false)


func configure(
		configured_effect_id: StringName,
		visual_scene: PackedScene,
		world_position: Vector3
	) -> bool:
	if visual_scene == null or not is_inside_tree():
		return false
	var visual := visual_scene.instantiate() as Node3D
	if visual == null:
		return false

	effect_id = configured_effect_id
	name = "ImpactEffect_%s" % String(effect_id)
	set_meta("combat_impact_fx", effect_id)
	top_level = true
	global_position = world_position
	_authored_visual = visual
	_authored_visual.name = "Visual"
	add_child(_authored_visual)

	if effect_id == SHELL_HIT_ID:
		_hide_emitter_geometry(_authored_visual)

	var lifetime := _play_authored_animation_once()
	if effect_id == SHELL_HIT_ID:
		_start_shell_hit_fx()

	var cleanup := Timer.new()
	cleanup.name = "Cleanup"
	cleanup.one_shot = true
	cleanup.wait_time = lifetime
	add_child(cleanup)
	cleanup.timeout.connect(queue_free)
	cleanup.start()
	return true


func _process(_delta: float) -> void:
	for index in range(_follow_particles.size() - 1, -1, -1):
		var entry: Dictionary = _follow_particles[index]
		var particle_ref := entry.get("particle") as WeakRef
		var marker_ref := entry.get("marker") as WeakRef
		var particle := particle_ref.get_ref() as Node3D \
			if particle_ref != null else null
		var marker := marker_ref.get_ref() as Node3D \
			if marker_ref != null else null
		if particle == null or marker == null:
			_follow_particles.remove_at(index)
			continue
		particle.global_position = marker.global_position
	if _follow_particles.is_empty():
		set_process(false)


func _play_authored_animation_once() -> float:
	var lifetime := DEFAULT_DURATION
	var player := _authored_visual.find_child(
		"AnimationPlayer", true, false
	) as AnimationPlayer
	if player == null:
		return lifetime
	var animation_name := &"Stationary" if player.has_animation(&"Stationary") \
		else &"timeline"
	if not player.has_animation(animation_name):
		return lifetime
	var animation := player.get_animation(animation_name)
	if animation != null:
		animation.loop_mode = Animation.LOOP_NONE
		lifetime = maxf(animation.length, 1.0 / RULE_UPDATES_PER_SECOND)
	player.play(animation_name)
	return lifetime


func _hide_emitter_geometry(node: Node) -> void:
	if node is MeshInstance3D:
		(node as MeshInstance3D).visible = false
	for child in node.get_children():
		_hide_emitter_geometry(child)


func _start_shell_hit_fx() -> void:
	if _authored_visual == null or not is_instance_valid(_authored_visual):
		return
	var burst_textures := _load_texture_sequence(
		SHELL_HIT_BURST_SEQUENCE, SHELL_HIT_BURST_FRAME_COUNT
	)
	var burst_marker := _find_original_node(_authored_visual, "?#bigbing~~1")
	if burst_marker != null and not burst_textures.is_empty():
		_spawn_follow_particle(
			SHELL_HIT_BURST_SEQUENCE, burst_textures,
			SHELL_HIT_BURST_SIZE, SHELL_HIT_BURST_DURATION, burst_marker
		)

	var shrapnel_textures := _load_texture_sequence(
		SHELL_HIT_SHRAPNEL_SEQUENCE, SHELL_HIT_SHRAPNEL_FRAME_COUNT
	)
	if not shrapnel_textures.is_empty():
		_spawn_shell_hit_shrapnel(shrapnel_textures)
	_spawn_shell_hit_light()


func _spawn_shell_hit_shrapnel(textures: Array[Texture2D]) -> void:
	var start := global_position + Vector3.UP * 0.08
	for particle_number in SHELL_HIT_SHRAPNEL_COUNT:
		# The source effect is a loose radial spray, not four authored rays:
		# every spark independently samples its direction and speed.
		var angle := _random.randf_range(0.0, TAU)
		var direction := Vector3(sin(angle), 0.0, cos(angle))
		var speed := _random.randf_range(0.55, 1.65)
		var velocity := direction * speed \
			+ Vector3.UP * _random.randf_range(0.05, 0.18)
		var particle := _spawn_world_particle(
			SHELL_HIT_SHRAPNEL_SEQUENCE, textures,
			SHELL_HIT_SHRAPNEL_SIZE, SHELL_HIT_SHRAPNEL_DURATION, start
		)
		if particle != null:
			particle.set_meta("combat_impact_velocity", velocity)
			var motion := particle.create_tween().set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
			motion.tween_method(
				_update_shrapnel_position.bind(particle, start, velocity),
				0.0, SHELL_HIT_SHRAPNEL_DURATION, SHELL_HIT_SHRAPNEL_DURATION
			)


func _spawn_shell_hit_light() -> void:
	var light := OmniLight3D.new()
	light.name = "ImpactLight"
	light.set_meta("combat_impact_light", true)
	light.light_color = SHELL_HIT_LIGHT_COLOR
	light.light_energy = 5.0
	light.omni_range = SHELL_HIT_LIGHT_RANGE
	light.shadow_enabled = false
	light.position = Vector3.UP * 0.12
	add_child(light)
	var illumination := light.create_tween()
	# Two-frame flash, then roughly ten source frames of local illumination.
	illumination.tween_property(light, "light_energy", 2.0, 0.1)
	illumination.tween_property(light, "light_energy", 0.8, 0.4)
	illumination.tween_property(light, "light_energy", 0.0, 0.1)
	illumination.finished.connect(light.queue_free)


func _find_original_node(node: Node, original_name: String) -> Node3D:
	if node is Node3D and String(node.get_meta("original_name", "")) == original_name:
		return node as Node3D
	for child in node.get_children():
		var result := _find_original_node(child, original_name)
		if result != null:
			return result
	return null


func _spawn_follow_particle(
		sequence: String,
		textures: Array[Texture2D],
		size: float,
		duration: float,
		marker: Node3D
	) -> Node3D:
	# Marker transforms carry source-model scale for their hidden cubes. Keep
	# the billboard in world space and copy only the animated marker position.
	var particle := _spawn_world_particle(
		sequence, textures, size, duration, marker.global_position
	)
	_follow_particles.append({
		"particle": weakref(particle),
		"marker": weakref(marker),
	})
	set_process(true)
	return particle


func _spawn_world_particle(
		sequence: String,
		textures: Array[Texture2D],
		size: float,
		duration: float,
		world_position: Vector3
	) -> Node3D:
	var particle := _create_particle(sequence, textures, size)
	add_child(particle)
	particle.top_level = true
	particle.global_position = world_position
	_start_particle_animation(particle, textures, duration)
	return particle


func _create_particle(
		sequence: String,
		textures: Array[Texture2D],
		size: float
	) -> Node3D:
	var particle := Node3D.new()
	particle.name = "ImpactParticle_%d" % _particle_index
	particle.set_meta("combat_impact_particle", StringName(sequence))
	_particle_index += 1

	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_texture = textures.front()
	if sequence == SHELL_HIT_SHRAPNEL_SEQUENCE:
		material.albedo_color = SHELL_HIT_SHRAPNEL_TINT
	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	quad.material = material
	var visual := MeshInstance3D.new()
	visual.name = "Visual"
	visual.mesh = quad
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	particle.add_child(visual)

	return particle


func _start_particle_animation(
		particle: Node3D,
		textures: Array[Texture2D],
		duration: float
	) -> void:
	var visual := particle.get_node_or_null("Visual") as MeshInstance3D
	var material := (visual.mesh as QuadMesh).material as StandardMaterial3D \
		if visual != null else null
	if material == null or textures.is_empty():
		return
	var animation := particle.create_tween()
	var frame_duration := duration / float(textures.size())
	var is_shell_hit_burst: bool = particle.get_meta(
		"combat_impact_particle", &""
	) == StringName(SHELL_HIT_BURST_SEQUENCE)
	for frame_index in textures.size():
		var opacity := SHELL_HIT_SMOKE_OPACITY \
			if is_shell_hit_burst and frame_index >= SHELL_HIT_SMOKE_FIRST_FRAME \
			else 1.0
		animation.tween_callback(
			_set_particle_frame.bind(material, textures[frame_index], opacity)
		)
		animation.tween_interval(frame_duration)
	animation.finished.connect(particle.queue_free)


func _update_shrapnel_position(
		elapsed: float,
		particle: Node3D,
		start: Vector3,
		velocity: Vector3
	) -> void:
	if particle == null or not is_instance_valid(particle):
		return
	particle.global_position = start + velocity * elapsed \
		+ Vector3.DOWN * (0.18 * elapsed * elapsed)


func _set_particle_frame(
		material: StandardMaterial3D,
		texture: Texture2D,
		opacity: float
	) -> void:
	if material != null:
		material.albedo_texture = texture
		var color := material.albedo_color
		color.a = opacity
		material.albedo_color = color


static func _load_texture_sequence(base_name: String, count: int) -> Array[Texture2D]:
	var cache_key := "%s:%d" % [base_name, count]
	if _texture_sequence_cache.has(cache_key):
		var cached: Array[Texture2D] = []
		cached.assign(_texture_sequence_cache[cache_key])
		return cached
	var result: Array[Texture2D] = []
	for frame in count:
		# Concatenate instead of %-formatting because source names such as
		# `!%Bru` contain a literal format marker.
		var path := INLINE_FX_TEXTURE_DIR + "/" + base_name + str(frame) + ".tga"
		var source_texture := load(path) as Texture2D
		if source_texture == null:
			return []
		result.append(_opaque_additive_texture(source_texture))
	_texture_sequence_cache[cache_key] = result
	return result


static func _opaque_additive_texture(source: Texture2D) -> Texture2D:
	var image := source.get_image()
	if image == null or image.is_empty():
		return source
	# Original 16-bpp explosion TGAs carry an unused zero alpha bit. Black is
	# already invisible under additive blending; the color pixels must be opaque.
	image.convert(Image.FORMAT_RGBA8)
	var data := image.get_data()
	for alpha_index in range(3, data.size(), 4):
		data[alpha_index] = 255
	image.set_data(
		image.get_width(), image.get_height(), image.has_mipmaps(),
		Image.FORMAT_RGBA8, data
	)
	return ImageTexture.create_from_image(image)
