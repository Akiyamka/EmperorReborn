class_name UnitVoiceProfile
extends Resource

## Command-feedback hooks for one unit voice. The referenced SoundEvents own
## sample selection and playback metadata.

@export var profile_id: StringName
@export_file("*.tres") var selection_event_path: String
@export_file("*.tres") var move_event_path: String
@export_file("*.tres") var attack_event_path: String

