class_name BulletDefinition
extends Resource

@export var config_id: StringName
@export var warhead_id: StringName
@export var damage: float
@export var maximum_range: float
@export var minimum_range: float
@export var speed: float
@export var blast_radius: float
@export var friendly_damage_amount: float
@export var reduce_damage_with_distance: bool = true
@export var anti_aircraft: bool
@export var anti_ground: bool = true
@export var homing: bool
@export var homing_delay: float
@export var turn_rate: float
@export var continuous: bool
@export var trajectory: bool
@export var is_laser: bool
@export var missile_trail_present: bool
@export var missile_trail: int
@export var missile_trail_size: float
@export var missile_trail_wiggle_frequency: float
@export var missile_trail_wiggle_scale: float
@export var missile_trail_length: int
@export var missile_trail_delta: float
@export var burnt: bool
@export var ignites: bool
@export var gassed: bool
@export var leech: bool
@export var infantry: bool
@export var damage_column: bool
@export var deviate: bool
@export var beserk: bool
@export var retreat: bool
@export var effect_health: float
@export var effect_damage_per_tick: float
@export var linger_duration: float
@export var linger_damage: float
@export var explosion_type_id: StringName
@export var explosion_effect_ids: Array[StringName] = []
@export_file("*.scn", "*.tscn") var projectile_scene_path: String
@export var impact_scene_paths: Dictionary = {}

