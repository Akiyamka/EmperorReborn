class_name SpiceMound
extends Area3D
## Runtime spice-bloom trigger. The visual is converted from the original
## Spicemound.xbf mesh; this Area3D owns contact activation and the Rules.txt
## maturation timer.

signal activated(mound: SpiceMound, early_activation: bool)

const RULE_TICKS_PER_SECOND := 60.0
const UNIT_COLLISION_LAYER := 2
const MATURITY_DURATION_MULTIPLIER := 3.0
const SOURCE_MODEL_DIAMETER := 32.0
const SOURCE_GROWTH_ANIMATION := &"timeline"
const SOURCE_GROWTH_TRACK := NodePath("_0Spicemound:transform")

@export var source_cell := Vector2i(-1, -1)

var config: Resource
var _footprint := Vector2.ONE
var _lifespan_random_fraction := -1.0
var _cycle_duration_seconds := 0.0
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
	var timer := get_node_or_null("MaturityTimer") as Timer
	if timer != null:
		timer.stop()
	_set_maturity_progress(1.0)
	activated.emit(self, early_activation)
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
	var growth_time := animation.track_get_key_time(track, last_key) * clampf(progress, 0.0, 1.0)
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
