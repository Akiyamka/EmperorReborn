class_name SelectionHalo
extends Node3D

const HALO_TEXTURE := preload("res://assets/raw_original_content/3DDATA/Textures/!Halo.tga")
const HEALTH_TEXTURES := [
	preload("res://assets/raw_original_content/3DDATA/Textures/@!Health0.tga"),
	preload("res://assets/raw_original_content/3DDATA/Textures/@!Health1.tga"),
	preload("res://assets/raw_original_content/3DDATA/Textures/@!Health2.tga"),
	preload("res://assets/raw_original_content/3DDATA/Textures/@!Health3.tga"),
	preload("res://assets/raw_original_content/3DDATA/Textures/@!Health4.tga"),
	preload("res://assets/raw_original_content/3DDATA/Textures/@!Health5.tga"),
]
const EMPTY_SHIELD_TEXTURE := preload("res://assets/raw_original_content/3DDATA/Textures/@!EmptyShield.tga")
const SHIELD_TEXTURE := preload("res://assets/raw_original_content/3DDATA/Textures/@!Shield.tga")
const EMPTY_SPICE_TEXTURE := preload("res://assets/raw_original_content/3DDATA/Textures/@!EmptySpice.tga")
const SPICE_TEXTURE := preload("res://assets/raw_original_content/3DDATA/Textures/@!Spice.tga")
const EMPTY_HARVESTER_TEXTURE := preload("res://assets/raw_original_content/3DDATA/Textures/@!EmptyHarv.tga")
const HARVESTER_TEXTURE := preload("res://assets/raw_original_content/3DDATA/Textures/@!Harv.tga")
const HALO_SHADER := preload("res://scripts/ui/selection_halo.gdshader")
const ADDITIVE_SHADER := preload("res://scripts/ui/selection_halo_outline.gdshader")
const OUTLINE_ROTATION_SPEED := 0.5

var _entity: Node3D
var _is_selected := false
var _is_hovered := false
var _layers := {}


func configure(entity: Node3D, radius: float, elevation: float) -> void:
	_entity = entity
	position.y = elevation
	var diameter := maxf(radius * 2.0, 0.1)
	_layers[&"outline"] = _add_layer(&"Outline", HALO_TEXTURE, diameter, 0.000, false, ADDITIVE_SHADER)
	_layers[&"health"] = _add_layer(&"Health", HEALTH_TEXTURES[5], diameter, 0.002, true)
	_layers[&"empty_shield"] = _add_layer(&"EmptyShield", EMPTY_SHIELD_TEXTURE, diameter, 0.004, false, ADDITIVE_SHADER)
	_layers[&"shield"] = _add_layer(&"Shield", SHIELD_TEXTURE, diameter, 0.006, true)
	# These are deliberately created now even though harvesting and transport
	# mechanics do not yet publish capacity values.  The component can start
	# showing them as soon as those fields are populated on the entity.
	_layers[&"empty_spice"] = _add_layer(&"EmptySpice", EMPTY_SPICE_TEXTURE, diameter, 0.008, false, ADDITIVE_SHADER)
	_layers[&"spice"] = _add_layer(&"Spice", SPICE_TEXTURE, diameter, 0.010, true)
	_layers[&"empty_transport"] = _add_layer(&"EmptyTransport", EMPTY_HARVESTER_TEXTURE, diameter, 0.012, false, ADDITIVE_SHADER)
	_layers[&"transport"] = _add_layer(&"Transport", HARVESTER_TEXTURE, diameter, 0.014, true)
	_refresh()


func set_selected(value: bool) -> void:
	_is_selected = value
	_refresh_visibility()


func set_hovered(value: bool) -> void:
	_is_hovered = value
	_refresh_visibility()


func _process(delta: float) -> void:
	if _entity == null:
		return
	# Units rotate while moving, but the original indicators retain their north
	# orientation.  The parent only rotates around Y, so cancel just that axis.
	rotation.y = -_entity.rotation.y
	# Only the decorative outline spins; the status indicators remain readable.
	var outline: MeshInstance3D = _layers[&"outline"]
	outline.rotation.y = fposmod(outline.rotation.y + OUTLINE_ROTATION_SPEED * delta, TAU)
	_refresh()


func _refresh() -> void:
	if _entity == null:
		return
	var health_fraction := _fraction(&"health", &"max_health")
	var health_index := mini(floori(health_fraction * 6.0), HEALTH_TEXTURES.size() - 1)
	_set_layer(&"health", HEALTH_TEXTURES[health_index], health_fraction, true)

	var has_shields := _number(&"max_shields") > 0.0
	_layers[&"empty_shield"].visible = has_shields
	_layers[&"shield"].visible = has_shields
	_set_layer(&"shield", SHIELD_TEXTURE, _fraction(&"shields", &"max_shields"), true)

	var has_spice_capacity := _number(&"max_spice") > 0.0
	_layers[&"empty_spice"].visible = has_spice_capacity
	_layers[&"spice"].visible = has_spice_capacity
	_set_layer(&"spice", SPICE_TEXTURE, _fraction(&"spice", &"max_spice"), true)

	var has_transport_capacity := _number(&"max_passengers") > 0.0
	_layers[&"empty_transport"].visible = has_transport_capacity
	_layers[&"transport"].visible = has_transport_capacity
	_set_layer(&"transport", HARVESTER_TEXTURE, _fraction(&"passengers", &"max_passengers"), true)
	_refresh_visibility()


func _refresh_visibility() -> void:
	visible = _is_selected or _is_hovered


func _fraction(current: StringName, maximum: StringName) -> float:
	var max_value := _number(maximum)
	return clampf(_number(current) / max_value, 0.0, 1.0) if max_value > 0.0 else 0.0


func _number(property: StringName) -> float:
	if _entity == null or not property in _entity:
		return 0.0
	return float(_entity.get(property))


func _add_layer(
	layer_name: StringName,
	texture: Texture2D,
	diameter: float,
	height: float,
	masked := false,
	shader: Shader = HALO_SHADER,
) -> MeshInstance3D:
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(diameter, diameter)
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter(&"indicator_texture", texture)
	material.set_shader_parameter(&"apply_radial_mask", masked)
	var layer := MeshInstance3D.new()
	layer.name = String(layer_name)
	layer.mesh = mesh
	layer.material_override = material
	layer.position.y = height
	add_child(layer)
	return layer


func _set_layer(layer_id: StringName, texture: Texture2D, fill: float, masked: bool) -> void:
	var layer: MeshInstance3D = _layers[layer_id]
	var material := layer.material_override as ShaderMaterial
	material.set_shader_parameter(&"indicator_texture", texture)
	material.set_shader_parameter(&"fill", fill)
	material.set_shader_parameter(&"apply_radial_mask", masked)
