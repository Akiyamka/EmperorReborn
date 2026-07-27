class_name UnitVoiceCatalog
extends RefCounted

const GeneratedManifest := preload("res://resources/audio/generated_voice_manifest.gd")

const HOUSE_PREFIXES: Dictionary = {
	&"Atreides": &"AT",
	&"Ordos": &"OR",
	&"Harkonnen": &"HK",
	&"Ix": &"IX",
	&"Imperial": &"IM",
	&"Fremen": &"FR",
	&"Guild": &"GU",
	&"Tleilaxu": &"TL",
	&"Incidental": &"IN",
}


func profile_for_unit(definition: Resource, owner_house_id: StringName) -> UnitVoiceProfile:
	if definition == null:
		return null
	var house_paths: Dictionary = definition.voice_profile_paths_by_house
	var house_path := String(house_paths.get(owner_house_id, ""))
	if not house_path.is_empty():
		return load(house_path) as UnitVoiceProfile
	var direct_path := String(definition.voice_profile_path)
	return load(direct_path) as UnitVoiceProfile if not direct_path.is_empty() else null


func group_profile_for_house(house_id: StringName) -> UnitVoiceProfile:
	return _profile_for_id(_house_profile_id(house_id, &"Group"))


func _house_profile_id(house_id: StringName, suffix: StringName) -> StringName:
	var prefix := String(HOUSE_PREFIXES.get(house_id, &""))
	return StringName(prefix + String(suffix)) if not prefix.is_empty() else &""


func _profile_for_id(profile_id: StringName) -> UnitVoiceProfile:
	var path := String(GeneratedManifest.PROFILE_PATHS.get(profile_id, ""))
	return load(path) as UnitVoiceProfile if not path.is_empty() else null
