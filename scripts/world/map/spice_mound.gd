class_name SpiceMound
extends Area3D
## Runtime spice-bloom trigger. The visual is converted from the original
## Spicemound.xbf mesh; this Area3D owns contact activation and the Rules.txt
## maturation timer.

signal activated(mound: SpiceMound, early_activation: bool, maturity_fraction: float)

const RULE_TICKS_PER_SECOND := 60.0
const UNIT_COLLISION_LAYER := 2
const MATURITY_DURATION_MULTIPLIER := 3.0
const SOURCE_MODEL_DIAMETER := 32.0
const SOURCE_GROWTH_ANIMATION := &"timeline"
const SOURCE_GROWTH_TRACK := NodePath("_0Spicemound:transform")
const PARTICLES_PER_HAZARD_CELL := 3
const MIN_HAZARD_PARTICLES := 48
const MAX_HAZARD_PARTICLES := 512
const HAZARD_PARTICLE_SIZE_DIVISOR := 3.0
const HAZARD_DAMPING_MIN_RATIO := 0.24
const HAZARD_DAMPING_MAX_RATIO := 0.34
const HAZARD_DAMPING_RANGE_COMPENSATION := 1.45

@export var source_cell := Vector2i(-1, -1)

var config: Resource
var _footprint := Vector2.ONE
var _lifespan_random_fraction := -1.0
var _cycle_duration_seconds := 0.0
var _maturity_progress := 0.0
var _activation_in_progress := false

@onready var maturity_timer: Timer = $MaturityTimer


func configure(
	cell: Vector2i,
	footprint: Vector2,
	rules_config: Resource = null,
	lifespan_random_fraction := -1.0
) -> void:
	source_cell = cell
	_footprint = Vector2(maxf(footprint.x, 0.001), maxf(footprint.y, 0.001))
	config = rules_config
	_lifespan_random_fraction = lifespan_random_fraction
	_apply_footprint()
	_prepare_maturity_cycle()


func _ready() -> void:
	add_to_group(&"spice_mounds")
	collision_layer = 0
	collision_mask = UNIT_COLLISION_LAYER
	monitoring = true
	monitorable = true
	if config == null:
		config = _rules_config()
	_apply_footprint()
	body_entered.connect(_on_body_entered)
	maturity_timer.timeout.connect(_on_maturity_timeout)
	restart_maturity_cycle()


func _process(_delta: float) -> void:
	if maturity_timer.is_stopped() or _cycle_duration_seconds <= 0.0:
		return
	var progress := 1.0 - maturity_timer.time_left / _cycle_duration_seconds
	_set_maturity_progress(progress)


func maturity_duration_seconds(random_fraction := -1.0) -> float:
	if config == null:
		return 0.0
	var fraction := randf() if random_fraction < 0.0 else clampf(random_fraction, 0.0, 1.0)
	var minimum_ticks := maxf(float(config.field(&"size", 0.0)), 0.0)
	var random_ticks := maxf(float(config.field(&"cost", 0.0)), 0.0)
	return (minimum_ticks + random_ticks * fraction) / RULE_TICKS_PER_SECOND \
		* MATURITY_DURATION_MULTIPLIER


func activate(early_activation := false) -> bool:
	if _activation_in_progress:
		return false
	_activation_in_progress = true
	var maturity_fraction := maturity_progress() if early_activation else 1.0
	var timer := get_node_or_null("MaturityTimer") as Timer
	if timer != null:
		timer.stop()
	_set_maturity_progress(1.0)
	activated.emit(self, early_activation, maturity_fraction)
	_activation_in_progress = false
	restart_maturity_cycle()
	return true


func restart_maturity_cycle() -> void:
	_prepare_maturity_cycle()
	var timer := get_node_or_null("MaturityTimer") as Timer
	if timer != null and timer.is_inside_tree() and _cycle_duration_seconds > 0.0:
		timer.start()


func growth_scale() -> float:
	var animated_node := get_node_or_null("Visual/_0Spicemound") as Node3D
	return animated_node.scale.x if animated_node != null else 0.0


func maturity_progress() -> float:
	var timer := get_node_or_null("MaturityTimer") as Timer
	if timer == null or timer.is_stopped() or _cycle_duration_seconds <= 0.0:
		return _maturity_progress
	return clampf(1.0 - timer.time_left / _cycle_duration_seconds, 0.0, 1.0)


func _apply_footprint() -> void:
	var visual := get_node_or_null("Visual") as Node3D
	if visual != null:
		var vertical_footprint := minf(_footprint.x, _footprint.y)
		visual.scale = Vector3(_footprint.x, vertical_footprint, _footprint.y) / SOURCE_MODEL_DIAMETER
	var shape_node := get_node_or_null("CollisionShape3D") as CollisionShape3D
	var box := shape_node.shape as BoxShape3D if shape_node != null else null
	if box != null:
		box.size = Vector3(_footprint.x, maxf(minf(_footprint.x, _footprint.y), 0.5), _footprint.y)
		shape_node.position.y = box.size.y * 0.5


func start_spread_hazard(local_points: PackedVector3Array, particle_size: float) -> void:
	var dust := get_node_or_null("SpreadDust") as GPUParticles3D
	var dust_material := dust.process_material as ParticleProcessMaterial if dust != null else null
	if dust == null or dust_material == null or local_points.is_empty():
		return
	var hazard_radius := 0.0
	for point: Vector3 in local_points:
		hazard_radius = maxf(hazard_radius, Vector2(point.x, point.z).length())
	# A 48-degree cone gives the burst a narrow vertical core and enough lateral
	# velocity to open into a geyser umbrella. Scaling both gravity and velocity
	# from the radius keeps the apex early while the fall fills the five seconds.
	var gravity_strength := maxf(hazard_radius * 0.2, 1.2)
	# Strong early damping shortens the ballistic arc, so give the burst a
	# matching launch boost. This restores the hazard radius without sacrificing
	# the fast-to-slow motion profile.
	var outer_velocity := sqrt(maxf(hazard_radius, particle_size) * gravity_strength) \
		* 1.08 * HAZARD_DAMPING_RANGE_COMPENSATION
	dust_material.initial_velocity_min = maxf(outer_velocity * 0.38, 0.8)
	dust_material.initial_velocity_max = maxf(outer_velocity, 1.5)
	dust_material.gravity = Vector3(0.0, -gravity_strength, 0.0)
	# Front-load the damping so the geyser bursts outward quickly, loses most of
	# its speed early, then drifts and falls gently for the rest of its lifetime.
	dust_material.damping_min = maxf(outer_velocity * HAZARD_DAMPING_MIN_RATIO, 0.55)
	dust_material.damping_max = maxf(outer_velocity * HAZARD_DAMPING_MAX_RATIO, 0.8)
	_ensure_hazard_damping_curve(dust_material)
	_ensure_hazard_scale_curve(dust_material)
	dust.amount = clampi(
		local_points.size() * PARTICLES_PER_HAZARD_CELL,
		MIN_HAZARD_PARTICLES,
		MAX_HAZARD_PARTICLES
	)
	var dust_quad := dust.draw_pass_1 as QuadMesh
	if dust_quad != null:
		var size := maxf(particle_size / HAZARD_PARTICLE_SIZE_DIVISOR, 0.1)
		dust_quad.size = Vector2(size, size)
	var margin := maxf(particle_size, 1.0) * 2.0
	var apex_height := dust_material.initial_velocity_max * dust_material.initial_velocity_max \
		/ (2.0 * gravity_strength)
	dust.visibility_aabb = AABB(
		Vector3(-hazard_radius - margin, -margin, -hazard_radius - margin),
		Vector3(
			(hazard_radius + margin) * 2.0,
			apex_height + margin * 2.0,
			(hazard_radius + margin) * 2.0
		)
	)
	dust.visible = true
	dust.restart()


func _ensure_hazard_scale_curve(dust_material: ParticleProcessMaterial) -> void:
	if dust_material.scale_curve != null:
		return
	var growth_curve := Curve.new()
	growth_curve.min_value = 0.0
	growth_curve.max_value = HAZARD_PARTICLE_SIZE_DIVISOR
	growth_curve.add_point(Vector2(0.0, 1.0))
	growth_curve.add_point(Vector2(1.0, HAZARD_PARTICLE_SIZE_DIVISOR))
	var growth_texture := CurveTexture.new()
	growth_texture.curve = growth_curve
	dust_material.scale_curve = growth_texture


func _ensure_hazard_damping_curve(dust_material: ParticleProcessMaterial) -> void:
	if dust_material.damping_curve != null:
		return
	var damping_curve := Curve.new()
	damping_curve.min_value = 0.0
	damping_curve.max_value = 1.0
	damping_curve.add_point(Vector2(0.0, 1.0))
	damping_curve.add_point(Vector2(0.16, 0.92))
	damping_curve.add_point(Vector2(0.38, 0.28))
	damping_curve.add_point(Vector2(1.0, 0.08))
	var damping_texture := CurveTexture.new()
	damping_texture.curve = damping_curve
	dust_material.damping_curve = damping_texture


func stop_spread_hazard() -> void:
	var dust := get_node_or_null("SpreadDust") as GPUParticles3D
	if dust == null:
		return
	dust.emitting = false
	dust.visible = false


func _prepare_maturity_cycle() -> void:
	_set_maturity_progress(0.0)
	var timer := get_node_or_null("MaturityTimer") as Timer
	if timer == null:
		return
	_cycle_duration_seconds = maturity_duration_seconds(_lifespan_random_fraction)
	if _cycle_duration_seconds <= 0.0:
		timer.stop()
		return
	timer.wait_time = _cycle_duration_seconds


func _set_maturity_progress(progress: float) -> void:
	_maturity_progress = clampf(progress, 0.0, 1.0)
	var player := get_node_or_null("Visual/AnimationPlayer") as AnimationPlayer
	var animated_node := get_node_or_null("Visual/_0Spicemound") as Node3D
	if player == null or animated_node == null or not player.has_animation(SOURCE_GROWTH_ANIMATION):
		return
	player.stop()
	var animation := player.get_animation(SOURCE_GROWTH_ANIMATION)
	var track := animation.find_track(SOURCE_GROWTH_TRACK, Animation.TYPE_VALUE)
	if track < 0 or animation.track_get_key_count(track) == 0:
		return
	var last_key := animation.track_get_key_count(track) - 1
	var growth_time := animation.track_get_key_time(track, last_key) * _maturity_progress
	var authored_transform: Variant = animation.value_track_interpolate(track, growth_time)
	if authored_transform is Transform3D:
		animated_node.transform = authored_transform


func _on_body_entered(body: Node3D) -> void:
	if body.is_in_group(&"units"):
		activate(true)


func _on_maturity_timeout() -> void:
	activate(false)


func _rules_config() -> Resource:
	var rules := get_node_or_null("/root/Rules")
	return rules.get_entity(&"spice_mound", &"SpiceMound") if rules != null else null
