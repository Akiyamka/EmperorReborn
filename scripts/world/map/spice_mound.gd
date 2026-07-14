class_name SpiceMound
extends Area3D
## Runtime spice-bloom trigger. Its plane owns local 0..1 UVs, while this
## Area3D owns contact activation and the Rules.txt maturation timer.

signal activated(mound: SpiceMound, early_activation: bool)

const RULE_TICKS_PER_SECOND := 60.0
const UNIT_COLLISION_LAYER := 2
const INITIAL_GROWTH_SCALE := 0.1
const MATURITY_DURATION_MULTIPLIER := 3.0

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
	return scale.x


func _apply_footprint() -> void:
	var mesh_node := get_node_or_null("Visual") as MeshInstance3D
	var plane := mesh_node.mesh as PlaneMesh if mesh_node != null else null
	if plane != null:
		plane.size = _footprint
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
	var growth := lerpf(INITIAL_GROWTH_SCALE, 1.0, clampf(progress, 0.0, 1.0))
	scale = Vector3(growth, 1.0, growth)


func _on_body_entered(body: Node3D) -> void:
	if body.is_in_group(&"units"):
		activate(true)


func _on_maturity_timeout() -> void:
	activate(false)


func _rules_config() -> Resource:
	var rules := get_node_or_null("/root/Rules")
	return rules.get_entity(&"spice_mound", &"SpiceMound") if rules != null else null
