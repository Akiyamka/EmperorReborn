class_name TurretDefinition
extends Resource

@export var config_id: StringName
@export var bullet_id: StringName
@export var next_joint_id: StringName
@export var reload_count: float
@export var muzzle_flash_id: StringName
@export_file("*.scn", "*.tscn") var muzzle_flash_scene_path: String
@export var yaw_speed: float
@export var minimum_yaw: float = NAN
@export var maximum_yaw: float = NAN
@export var pitch_speed: float
@export var minimum_pitch: float = NAN
@export var maximum_pitch: float = NAN
@export var acceptable_yaw: float = 1.0
@export var acceptable_pitch: float = 1.0
@export var bullet_count: int = 1
## Zero leaves projectile timing to the authored fire animation.
@export var burst_shot_count: int = 0
## Rule ticks between launcher shots. Zero fires the configured burst together.
@export var burst_interval_ticks: float = 0.0
@export var disabled_when_deployed: bool
@export var disabled_when_undeployed: bool
