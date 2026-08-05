class_name BulletDefinition
extends Resource

@export var config_id: StringName
@export var warhead_id: StringName
@export var damage: float
@export var maximum_range: float
@export var minimum_range: float
## Multiplies maximum_range to get how far the shot may actually travel before
## it burns out. Firing range is unaffected. Rules.txt has no separate missile
## lifetime field, so a homing shot that spends part of its flight steering
## after a moving target would otherwise die short of a target that was well
## inside range at launch. See docs/quirks.md.
@export var flight_range_scale: float = 1.0
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
@export var blow_up: bool
@export var shot: bool
@export var effect_health: float
@export var effect_damage_per_tick: float
@export var linger_duration: float
@export var linger_damage: float
@export var explosion_type_id: StringName
@export var explosion_effect_ids: Array[StringName] = []
## Original ExplosionType.DamageToTile value. Positive values leave a crater
## decal where a ground-capable detonation reaches the terrain.
@export var damage_to_tile: float
@export_file("*.scn", "*.tscn") var projectile_scene_path: String
@export var impact_scene_paths: Dictionary = {}
## Positional impact sound(s) for this bullet, resolved at convert time from a
## documented SFX event alias (there is no generic "hit sound" concept in the
## original data, only per-weapon splat/impact hooks for a handful of
## non-explosive bullets). Empty for the common case of an explosive warhead,
## which already gets its sound from the explosion/death sound systems. One is
## picked at random per impact via DeathSoundPlayer.play_pool(). See
## docs/quirks.md.
@export var hit_sound_paths: Array[String] = []
## Authored SFX `Volume` (0-100) for the resolved hit sound event, applied as
## linear gain by DeathSoundPlayer.play_pool(). See
## TurretDefinition.fire_sound_volume for why this isn't left at an unscaled
## 100. Defaults to 100 when the source omitted it.
@export var hit_sound_volume: float = 100.0
