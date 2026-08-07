extends RefCounted

## Resolves the reload sound a model authors *inside* one of its own clips: the
## bolt being racked between two shots of a Fire clip, or the gun being loaded
## as a Kindjal/Mortar folds out.
##
## Like the death voices (scripts/units/authored_death_voice.gd) and the mech
## footsteps (scripts/units/unit_movement_sounds.gd), this is an XBF FX event of
## **type 9**: one SFX section name pinned to one frame, baked losslessly onto
## the model root by converters/model_bake_builder.gd as `xbf_fx_events` /
## `xbf_animation_entries`. Six models author one:
##
##     AT_Sniper_H0    Fire_0        [213..289] frame 258 -> Atsniperreload
##     AT_Sniper_H0    Lay_Down_Fire [290..331] frame 309 -> Atsniperreload
##     HK_Trooper_H0   Fire_0        [195..248] frame 237 -> HKreload
##     OR_AATrooper_H0 Fire_0                   frame 338 -> ORkobrareload
##     HK_Inkvine_H0   Fire_0                   frame  50 -> HKinkvinereload
##     AT_Kindjal_H0   Deployed_Fire [386..436] frame 429 -> FRwarriorreload
##     AT_Kindjal_H0   Deploy_Gun    [322..384] frame 374 -> Atsniperreload
##     OR_Mortar_H0    Deploy_Gun               frame  54 -> ORkobrareload
##
## `RELOAD_SECTIONS` is an allowlist rather than a denylist, and that is the
## whole point of this script: a fire clip's *other* type-9 events are the
## weapon's own shot sound (ATSingleShotRifle, HKBazookaLaunch1, Catapult, ...),
## which CombatTurret already plays from the turret definition's baked
## `fire_sound_paths`. Playing every event in the clip would double the gunfire
## on nine units whose authored section resolves to the same WAV the turret
## already fires.
##
## Unlike AuthoredDeathVoice there is no per-family dedupe and no generic
## fallback spelling: two reload events in one clip would mean the gun was
## loaded twice, and every real reload section resolves directly once
## tools/generate_voice_feedback.py shadow-proofs the two Atreides ones.

const SfxSectionCatalogScript := preload("res://scripts/audio/sfx_section_catalog.gd")

## Mirrors AuthoredFireController.BAKED_MODEL_FRAMES_PER_SECOND: XBF frames are
## authored at a fixed 20 fps and the bake preserves that rate, so the times
## returned here are directly comparable with that controller's `shot_times`.
const BAKED_MODEL_FRAMES_PER_SECOND := 20.0

const XBF_SOUND_EVENT_TYPE := 9

## Every SFX section that is a weapon reload, keyed casefolded. Derived
## mechanically from assets/raw_original_content/SFX/*.txt: these are all the
## sections whose `Sounds=` list is one of the two reload samples
## (`kindjal_infantry_reload_1`, `hk_rocket_trooper_reload_1`), plus the two
## ImportedSfx.txt entries that name a `$`-prefixed localization stub which was
## never converted.
##
## `hkinkvinereload` and `hkmissiletankreload` are those two stubs: they are
## listed because they *are* reloads by name and origin, and dropped at the end
## of schedule() because no file anywhere gives them a playable sample. Keeping
## them here rather than omitting them is what makes "authored but silent"
## visible instead of looking like an oversight.
##
## `sniperriflereload` and `kindjalcannonreload` are the real English sections
## for the AT sniper rifle and Kindjal cannon; no shipped model names either one
## (the models reached for `atsniperreload`/`frwarriorreload` instead), but the
## list follows the SFX data rather than the model survey so that it stays
## correct if a model is ever re-baked.
const RELOAD_SECTIONS := {
	&"atsniperreload": true,
	&"frwarriorreload": true,
	&"sniperriflereload": true,
	&"kindjalcannonreload": true,
	&"hkreload": true,
	&"orkobrareload": true,
	&"hkinkvinereload": true,
	&"hkmissiletankreload": true,
}


## `[{"section": StringName, "time": float}, ...]` for `clip`, ordered by
## authored frame. `time` is seconds from the start of the clip on the clip's
## own 20 fps timeline, so a caller compares it against whatever clock it
## already advances the clip with.
##
## `model_root` may be any node above the baked XBF root (the unit's visual
## root, a building's model root, ...); the meta-bearing node is found by
## walking down from it.
static func schedule(model_root: Node, clip: StringName) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if model_root == null or clip == &"":
		return result
	var fx_root := _find_fx_root(model_root)
	# An incomplete event table means the parser kept only a valid prefix (see
	# ModelXbf._parse_fx_events), so absent events cannot be distinguished from
	# undecoded ones and a partial schedule would be a guess. Same gate the fire
	# controller and the movement sounds apply.
	if fx_root == null \
	or not bool(fx_root.get_meta("xbf_fx_events_complete", false)):
		return result

	var entries := fx_root.get_meta("xbf_animation_entries", []) as Array
	var clip_entry := _find_entry(entries, clip)
	if clip_entry.is_empty():
		return result
	var clip_start := int(clip_entry.get("start_frame", -1))
	var clip_end := int(clip_entry.get("end_frame", -1))
	if clip_start < 0 or clip_end < clip_start:
		return result

	for event_value: Variant in fx_root.get_meta("xbf_fx_events", []):
		var event := event_value as Dictionary
		if int(event.get("type", -1)) != XBF_SOUND_EVENT_TYPE:
			continue
		var frame := int(event.get("frame", -1))
		if frame < clip_start or frame > clip_end:
			continue
		# Authored clip ranges overlap in shipped models, so containment alone
		# would hand one clip's sounds to its neighbour: AT_Sniper's
		# `Lay_Down_Fire` [290..331] contains `Crawl` [332..356]'s neighbourhood,
		# and the AT Pillbox authors an `Idle 0` nested inside its `Fire 0` (the
		# bake repairs that one, see docs/quirks.md). The tightest range around a
		# frame is the clip that frame was authored for.
		if _has_tighter_entry(entries, frame, clip_end - clip_start):
			continue
		var section := _section_id(event)
		if not RELOAD_SECTIONS.has(section):
			continue
		# A reload whose section resolved to no converted WAV is silent, exactly
		# as the original data says -- HK_Inkvine's `HKinkvinereload` has no
		# definition outside ImportedSfx.txt's unconverted stub.
		if not SfxSectionCatalogScript.has_section(section):
			continue
		result.append({
			"section": section,
			"time": float(frame - clip_start) / BAKED_MODEL_FRAMES_PER_SECOND,
		})
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["time"]) < float(b["time"])
	)
	return result


## Same walk as AuthoredFireController.find_xbf_motion_root(), repeated rather
## than called: this resolver is static so it can be exercised with plain
## dictionaries and no scene, and a static-context call into another script's
## statics does not resolve here.
static func _find_fx_root(node: Node) -> Node:
	if node.has_meta("xbf_animation_entries") and node.has_meta("xbf_fx_events"):
		return node
	for child in node.get_children():
		var found := _find_fx_root(child)
		if found != null:
			return found
	return null


## Baked entry names keep the source spelling ("Deploy Gun") while clip names
## are underscored; same normalisation CombatTurretFx and AuthoredDeathVoice use.
static func _find_entry(entries: Array, clip: StringName) -> Dictionary:
	var wanted := _normalized(String(clip))
	for entry_value: Variant in entries:
		var entry := entry_value as Dictionary
		if _normalized(String(entry.get("name", ""))).nocasecmp_to(wanted) == 0:
			return entry
	return {}


## True when some other authored clip covers `frame` with a strictly tighter
## range than the one asking. Deliberately "strictly": equal-width overlaps are
## genuinely ambiguous, and letting both claim the event beats silencing both.
static func _has_tighter_entry(entries: Array, frame: int, width: int) -> bool:
	for entry_value: Variant in entries:
		var entry := entry_value as Dictionary
		var start_frame := int(entry.get("start_frame", -1))
		var end_frame := int(entry.get("end_frame", -1))
		if start_frame < 0 or end_frame < start_frame:
			continue
		if frame < start_frame or frame > end_frame:
			continue
		if end_frame - start_frame < width:
			return true
	return false


static func _section_id(event: Dictionary) -> StringName:
	var strings := event.get("strings", []) as Array
	if strings.is_empty():
		return &""
	return StringName(String(strings[0]).strip_edges().to_lower())


static func _normalized(name: String) -> String:
	return name.strip_edges().replace(" ", "_")
