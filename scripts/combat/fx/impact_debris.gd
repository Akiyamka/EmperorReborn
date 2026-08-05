class_name ImpactDebris
extends RefCounted

## The hand-built particle rig behind the two authored emitter effects.
##
## Most ExplosionType XBFs draw themselves. ShellHit and MissileHit do not:
## their models are invisible `#bing` anchor cubes whose animation drives an FX
## bank, so what the player actually sees -- the burst billboard, the shrapnel
## spray, the flash of light -- has to be built here from the source texture
## sequences.
##
## The two effects differ in exactly one piece, so they are a table of pieces
## rather than a subclass or a boolean: MissileHit's RocketDetonation adds an
## expanding ring to the same spray.
##
## Nodes are parented to the CombatImpactEffect that owns this, and die with
## it; the tweens are created on the particles themselves.

const AuthoredFxBankScript := preload("res://scripts/combat/fx/authored_fx_bank.gd")

const BURST := &"burst"
const SHRAPNEL := &"shrapnel"
const RING := &"ring"
const LIGHT := &"light"

## Which pieces each authored emitter effect is made of. An ExplosionType that
## is not listed renders itself and needs nothing from here.
const PIECES := {
	&"ShellHit": [BURST, SHRAPNEL, LIGHT],
	&"MissileHit": [BURST, SHRAPNEL, RING, LIGHT],
}

const BURST_SEQUENCE := "!%Bru"
const BURST_FRAME_COUNT := 21
const BURST_SIZE := 2.0
const BURST_DURATION := 1.05
const BURST_SMOKE_FIRST_FRAME := 2
const BURST_SMOKE_OPACITY := 0.55
const BURST_MARKER := "?#bigbing~~1"
const SHRAPNEL_SEQUENCE := "!@sm"
const SHRAPNEL_FRAME_COUNT := 11
const SHRAPNEL_SIZE := 0.16
const SHRAPNEL_ANIMATION_DURATION := 1.0
const SHRAPNEL_FADE_DURATION := 0.3
const SHRAPNEL_START_HEIGHT := 0.08
const SHRAPNEL_COUNT := 16
const SHRAPNEL_VERTICAL_SPEED_MIN := 0.8
const SHRAPNEL_VERTICAL_SPEED_MAX := 1.4
const SHRAPNEL_GRAVITY := 1.6
const SHRAPNEL_TINT := Color(1.8, 1.45, 0.72, 1.0)
const RING_SPEED := 1.4
const RING_VERTICAL_SPEED := 0.55
const RING_GRAVITY := 1.1
const LIGHT_COLOR := Color(1.0, 0.43, 0.12)
const LIGHT_RANGE := 3.5
const CLEANUP_MARGIN := 0.05

var _effect: Node3D
var _particle_index := 0
var _follow_particles: Array[Dictionary] = []
var _random := RandomNumberGenerator.new()


func _init() -> void:
	_random.randomize()


func configure(effect: Node3D) -> void:
	_effect = effect


## Whether this effect id has an authored emitter rig, which is also what
## decides that its invisible marker geometry must be hidden.
static func has_rig(effect_id: StringName) -> bool:
	return PIECES.has(effect_id)


## Spawns the effect's pieces around the owner's position. `authored_visual`
## supplies the animated marker the burst billboard follows.
func build(effect_id: StringName, authored_visual: Node3D) -> void:
	if _effect == null or authored_visual == null or not is_instance_valid(authored_visual):
		return
	var pieces: Array = PIECES.get(effect_id, [])
	if pieces.has(BURST):
		var burst_textures := AuthoredFxBankScript.load_texture_sequence(
			BURST_SEQUENCE, BURST_FRAME_COUNT
		)
		var burst_marker := AuthoredFxBankScript.find_original_node(
			authored_visual, BURST_MARKER
		)
		if burst_marker != null and not burst_textures.is_empty():
			_spawn_follow_particle(
				BURST_SEQUENCE, burst_textures, BURST_SIZE, BURST_DURATION, burst_marker
			)

	if not pieces.has(SHRAPNEL) and not pieces.has(RING):
		return
	var shrapnel_textures := AuthoredFxBankScript.load_texture_sequence(
		SHRAPNEL_SEQUENCE, SHRAPNEL_FRAME_COUNT
	)
	if not shrapnel_textures.is_empty():
		if pieces.has(SHRAPNEL):
			_spawn_shrapnel(shrapnel_textures)
		if pieces.has(RING):
			_spawn_ring(shrapnel_textures)
	if pieces.has(LIGHT):
		_spawn_light()


## How long the owner must stay alive for the rig to finish: the slowest
## shrapnel piece has to land and fade before the node may be freed.
static func lifetime() -> float:
	var maximum_flight_time := _ballistic_landing_time(
		SHRAPNEL_START_HEIGHT, SHRAPNEL_VERTICAL_SPEED_MAX, SHRAPNEL_GRAVITY
	)
	return maxf(
		BURST_DURATION,
		maxf(SHRAPNEL_ANIMATION_DURATION, maximum_flight_time)
			+ SHRAPNEL_FADE_DURATION + CLEANUP_MARGIN
	)


## Copies each follower onto the marker it tracks, and reports whether any are
## left. The owner stops processing once none are.
func advance_followers() -> bool:
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
	return not _follow_particles.is_empty()


## RocketDetonation repeatedly emits the same small shrapnel sprite while its
## helpers expand from the centre. Every particle shares one radial speed so
## the group remains a ring, while independent random angles keep its points
## from forming an artificial regular polygon.
func _spawn_ring(textures: Array[Texture2D]) -> void:
	var start := _effect.global_position + Vector3.UP * SHRAPNEL_START_HEIGHT
	for particle_number in SHRAPNEL_COUNT:
		var angle := _random.randf_range(0.0, TAU)
		var direction := Vector3(sin(angle), 0.0, cos(angle))
		var velocity := direction * RING_SPEED + Vector3.UP * RING_VERTICAL_SPEED
		var particle := _spawn_world_particle(
			SHRAPNEL_SEQUENCE, textures, SHRAPNEL_SIZE,
			SHRAPNEL_ANIMATION_DURATION, start, false
		)
		if particle != null:
			particle.set_meta("combat_impact_ring", true)
			_throw(particle, start, velocity, RING_GRAVITY)


## The source effect is a loose radial spray, not four authored rays: every
## spark independently samples its direction and speed.
func _spawn_shrapnel(textures: Array[Texture2D]) -> void:
	var start := _effect.global_position + Vector3.UP * SHRAPNEL_START_HEIGHT
	for particle_number in SHRAPNEL_COUNT:
		var angle := _random.randf_range(0.0, TAU)
		var direction := Vector3(sin(angle), 0.0, cos(angle))
		var speed := _random.randf_range(0.55, 1.65)
		var velocity := direction * speed \
			+ Vector3.UP * _random.randf_range(
				SHRAPNEL_VERTICAL_SPEED_MIN, SHRAPNEL_VERTICAL_SPEED_MAX
			)
		var particle := _spawn_world_particle(
			SHRAPNEL_SEQUENCE, textures, SHRAPNEL_SIZE,
			SHRAPNEL_ANIMATION_DURATION, start, false
		)
		if particle != null:
			_throw(particle, start, velocity, SHRAPNEL_GRAVITY)


## Puts one piece on a ballistic arc and fades it where it lands. The metadata
## is what tests/combat/run.gd reads to check the spray.
func _throw(particle: Node3D, start: Vector3, velocity: Vector3, gravity: float) -> void:
	var landing_time := _ballistic_landing_time(SHRAPNEL_START_HEIGHT, velocity.y, gravity)
	particle.set_meta("combat_impact_velocity", velocity)
	particle.set_meta("combat_impact_landing_time", landing_time)
	var motion := particle.create_tween().set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	motion.tween_method(
		_update_particle_position.bind(particle, start, velocity, gravity),
		0.0, landing_time, landing_time
	)
	motion.finished.connect(_fade_landed.bind(particle))


static func _ballistic_landing_time(
		start_height: float,
		vertical_speed: float,
		gravity: float
	) -> float:
	if gravity <= 0.0:
		return SHRAPNEL_ANIMATION_DURATION
	return (vertical_speed + sqrt(
		vertical_speed * vertical_speed + 2.0 * gravity * maxf(start_height, 0.0)
	)) / gravity


func _fade_landed(particle: Node3D) -> void:
	if particle == null or not is_instance_valid(particle):
		return
	var visual := particle.get_node_or_null("Visual") as MeshInstance3D
	var material := (visual.mesh as QuadMesh).material as StandardMaterial3D \
		if visual != null else null
	if material == null:
		particle.queue_free()
		return
	var fade := particle.create_tween()
	fade.tween_method(
		_set_particle_opacity.bind(material),
		material.albedo_color.a, 0.0, SHRAPNEL_FADE_DURATION
	)
	fade.finished.connect(particle.queue_free)


func _spawn_light() -> void:
	var light := OmniLight3D.new()
	light.name = "ImpactLight"
	light.set_meta("combat_impact_light", true)
	light.light_color = LIGHT_COLOR
	light.light_energy = 5.0
	light.omni_range = LIGHT_RANGE
	light.shadow_enabled = false
	light.position = Vector3.UP * 0.12
	_effect.add_child(light)
	var illumination := light.create_tween()
	# Two-frame flash, then roughly ten source frames of local illumination.
	illumination.tween_property(light, "light_energy", 2.0, 0.1)
	illumination.tween_property(light, "light_energy", 0.8, 0.4)
	illumination.tween_property(light, "light_energy", 0.0, 0.1)
	illumination.finished.connect(light.queue_free)


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
	_effect.set_process(true)
	return particle


func _spawn_world_particle(
		sequence: String,
		textures: Array[Texture2D],
		size: float,
		duration: float,
		world_position: Vector3,
		free_after_animation: bool = true
	) -> Node3D:
	var tint := SHRAPNEL_TINT if sequence == SHRAPNEL_SEQUENCE else Color.WHITE
	var opacities := PackedFloat32Array()
	for frame_index in textures.size():
		opacities.append(
			BURST_SMOKE_OPACITY
			if sequence == BURST_SEQUENCE and frame_index >= BURST_SMOKE_FIRST_FRAME
			else 1.0
		)
	var spawned := AuthoredFxBankScript.spawn_frame_animated_quad(
		_effect, textures, {
			"name": "ImpactParticle_%d" % _particle_index,
			"position": world_position,
			"size": size,
			"tint": tint,
			"frame_seconds": duration / float(maxi(textures.size(), 1)),
			"opacities": opacities,
			"free_after_animation": free_after_animation,
			"metadata": {
				"combat_impact_particle": StringName(sequence),
			},
		}
	)
	_particle_index += 1
	return spawned.get("particle") as Node3D


func _update_particle_position(
		elapsed: float,
		particle: Node3D,
		start: Vector3,
		velocity: Vector3,
		gravity: float
	) -> void:
	AuthoredFxBankScript.integrate_motion(
		elapsed, particle, start, velocity, Vector3.DOWN * gravity
	)


func _set_particle_opacity(opacity: float, material: StandardMaterial3D) -> void:
	if material != null:
		var color := material.albedo_color
		color.a = opacity
		material.albedo_color = color
