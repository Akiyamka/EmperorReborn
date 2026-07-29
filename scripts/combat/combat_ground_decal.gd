class_name CombatGroundDecal
extends Node3D

const GameSettingsCatalogScript := preload(
	"res://scripts/rules/game_settings_catalog.gd"
)
const GameSettingsScript := preload("res://scripts/rules/game_settings.gd")

## Persistent crater decal placed on terrain after an ExplosionType with a
## positive DamageToTile value. The original @craters texture is a 2x2 atlas.
## A transparent PlaneMesh is used because the project targets Godot's
## Compatibility renderer, where the Decal node is unavailable.

const CRATER_ATLAS_PATH := \
	"res://assets/raw_original_content/3DDATA/Textures/@craters.tga"
const ATLAS_CELL_SIZE := Vector2(32.0, 32.0)
const RULE_TILE_WORLD_SPAN := 2.0
const BASE_DAMAGE_TO_TILE := 30.0
const MIN_DIAMETER := 1.0
const MAX_DIAMETER := 4.0
const SURFACE_OFFSET := 0.03
const TERRAIN_COLLISION_MASK := 1
const RAY_HEIGHT := 2.0
const RAY_DEPTH := 32.0

static var _next_sequence := 0
static var _game_settings_catalog := GameSettingsCatalogScript.new()


func configure(tile_damage: float, impact_position: Vector3) -> bool:
	if tile_damage <= 0.0 or not is_inside_tree():
		return false
	var maximum_decal_count := _maximum_decal_count()
	if maximum_decal_count <= 0:
		return false
	var atlas := load(CRATER_ATLAS_PATH) as Texture2D
	if atlas == null:
		return false

	var sequence := _next_sequence
	_next_sequence += 1
	var variant := sequence % 4
	var texture := AtlasTexture.new()
	texture.atlas = atlas
	texture.filter_clip = true
	texture.region = Rect2(
		Vector2(float(variant % 2), float(variant >> 1)) * ATLAS_CELL_SIZE,
		ATLAS_CELL_SIZE
	)

	name = "GroundCrater_%d" % sequence
	set_meta("combat_ground_decal", true)
	set_meta("damage_to_tile", tile_damage)
	set_meta("crater_variant", variant)
	set_meta("decal_sequence", sequence)
	top_level = true

	var placement := _terrain_placement(impact_position)
	var surface_position: Vector3 = placement["position"]
	var surface_normal: Vector3 = placement["normal"]
	global_transform = Transform3D(
		Basis(Quaternion(Vector3.UP, surface_normal)),
		surface_position + surface_normal * SURFACE_OFFSET
	)
	rotate_object_local(Vector3.UP, fmod(float(sequence) * 2.399963, TAU))

	var diameter := clampf(
		RULE_TILE_WORLD_SPAN * sqrt(tile_damage / BASE_DAMAGE_TO_TILE),
		MIN_DIAMETER,
		MAX_DIAMETER
	)
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_texture = texture
	material.cull_mode = BaseMaterial3D.CULL_DISABLED

	var plane := PlaneMesh.new()
	plane.size = Vector2(diameter, diameter)
	plane.material = material

	var decal := MeshInstance3D.new()
	decal.name = "Decal"
	decal.mesh = plane
	decal.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(decal)

	_enforce_parent_budget(maximum_decal_count)
	return true


func _terrain_placement(impact_position: Vector3) -> Dictionary:
	var fallback := {
		"position": impact_position,
		"normal": Vector3.UP,
	}
	if get_world_3d() == null:
		return fallback
	var query := PhysicsRayQueryParameters3D.create(
		impact_position + Vector3.UP * RAY_HEIGHT,
		impact_position + Vector3.DOWN * RAY_DEPTH,
		TERRAIN_COLLISION_MASK
	)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return fallback
	var normal := Vector3(hit.get("normal", Vector3.UP)).normalized()
	if normal.is_zero_approx():
		normal = Vector3.UP
	return {
		"position": Vector3(hit["position"]),
		"normal": normal,
	}


func _maximum_decal_count() -> int:
	var settings: Resource = _game_settings_catalog.settings()
	if settings == null:
		return GameSettingsScript.DEFAULT_MAXIMUM_GROUND_DECALS
	return maxi(int(settings.maximum_ground_decals), 0)


func _enforce_parent_budget(maximum_decal_count: int) -> void:
	var parent := get_parent()
	if parent == null:
		return
	var decals: Array[Node] = []
	for child in parent.get_children():
		if child.has_meta("combat_ground_decal"):
			decals.append(child)
	if decals.size() <= maximum_decal_count:
		return
	var oldest: Node = decals.front()
	for candidate in decals:
		if int(candidate.get_meta("decal_sequence", 0)) \
		< int(oldest.get_meta("decal_sequence", 0)):
			oldest = candidate
	oldest.free()
