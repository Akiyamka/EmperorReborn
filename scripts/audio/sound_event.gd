class_name SoundEvent
extends Resource

## A converted event from the original SFX configuration. Sample paths stay
## separate from unit data because one event may be reused by several actors.

@export var event_id: StringName
@export var event_type: StringName
@export var controls: Array[StringName] = []
@export_file("*.wav") var sample_paths: Array[String] = []
@export var localized_samples: Array[bool] = []
@export_range(0, 100) var volume: int = 100
@export var priority: StringName
@export var limit: int
@export var attack_count: int
@export var decay_count: int

