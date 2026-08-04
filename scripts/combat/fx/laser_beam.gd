class_name LaserBeam
extends RefCounted

## The visible bolt a laser leaves behind, drawn once when the shot resolves.
##
## Unlike a missile trail this is not a flight visual: a laser is hitscan, so
## there is no interval to animate. The beam only exists after the raycast has
## established where it actually stopped, and it lives for LIFETIME_SECONDS
## while the projectile node stays alive to hold it.
##
## Two coaxial cylinders: a wide translucent glow and a thin near-white core.

const LIFETIME_SECONDS := 0.16
const CORE_RADIUS := 0.025
const GLOW_RADIUS := 0.07
const TANK_GLOW_RADIUS := 0.1
const RADIAL_SEGMENTS := 8
const TANK_COLOR := Color(0.2, 1.0, 0.08)
const TANK_GLOW_COLOR := Color(0.08, 0.72, 1.0, 0.24)
const TANK_GLOW_ENERGY := 3.0
const INFANTRY_COLOR := Color(1.0, 0.55, 0.08)
const INFANTRY_BULLET_ID := &"InfLaser_B"


## Adds the beam under `projectile` and reports whether one was drawn. Returns
## false for a zero-length shot or when a beam is already present, which is how
## the caller decides between deferring the projectile's cleanup and freeing it
## on the spot.
static func build(
	projectile: Node3D, bullet_id: StringName, start_position: Vector3, end_position: Vector3
) -> bool:
	if not projectile.is_inside_tree() or projectile.get_node_or_null("LaserBeam") != null:
		return false
	var segment := end_position - start_position
	var length := segment.length()
	if length <= 0.000001:
		return false

	var beam_direction := segment / length
	var beam := Node3D.new()
	beam.name = "LaserBeam"
	beam.set_meta("start_position", start_position)
	beam.set_meta("end_position", end_position)
	projectile.add_child(beam)
	# Impact resolution moves the projectile node to the hit position. Keeping
	# the beam top-level prevents that parent move from dragging its midpoint
	# away from the muzzle on the same frame.
	beam.top_level = true
	beam.global_transform = Transform3D(
		Basis(Quaternion(Vector3.UP, beam_direction)),
		start_position.lerp(end_position, 0.5)
	)

	var is_infantry: bool = bullet_id == INFANTRY_BULLET_ID
	var color: Color = INFANTRY_COLOR if is_infantry else TANK_COLOR
	var glow_color: Color = Color(color.r, color.g, color.b, 0.24) \
		if is_infantry else TANK_GLOW_COLOR
	var glow_energy: float = 2.5 if is_infantry else TANK_GLOW_ENERGY
	var glow_radius: float = GLOW_RADIUS if is_infantry else TANK_GLOW_RADIUS
	_add_layer(beam, "Glow", length, glow_radius, glow_color, glow_energy)
	_add_layer(
		beam, "Core", length, CORE_RADIUS,
		Color(
			lerpf(color.r, 1.0, 0.72),
			lerpf(color.g, 1.0, 0.72),
			lerpf(color.b, 1.0, 0.72),
			0.98
		),
		5.0
	)
	return true


static func _add_layer(
		parent: Node3D,
		layer_name: String,
		length: float,
		radius: float,
		color: Color,
		emission_energy: float
	) -> void:
	var mesh := CylinderMesh.new()
	mesh.height = length
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.radial_segments = RADIAL_SEGMENTS
	mesh.rings = 1

	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = Color(color.r, color.g, color.b)
	material.emission_energy_multiplier = emission_energy
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.material = material

	var visual := MeshInstance3D.new()
	visual.name = layer_name
	visual.mesh = mesh
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(visual)
