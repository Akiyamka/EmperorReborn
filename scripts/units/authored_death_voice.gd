extends RefCounted

## Resolves an infantry unit's dying scream out of the FX event table its own
## model carries, rather than from a per-cause table in code.
##
## Every infantry XBF authors its death sounds as FX event **type 9** records:
## one SFX section name pinned to one frame, and that frame falls inside the
## frame range of exactly the death clip it belongs to. The converter already
## bakes both halves losslessly onto the model root
## (`xbf_fx_events` / `xbf_animation_entries`, see converters/model_bake_builder.gd),
## and `unit_locomotion.gd` (type 11) and `combat_turret_fx.gd` (types 3/4)
## already read their own event types the same way. TL_Contaminator, for
## example, authors:
##
##     Shot 1     [424..453] -> GunHit1, ContaminatorDying
##     Burnt 1    [454..507] -> BurningSmall, HKburningManDying, ContaminatorDying
##     Gassed 1   [508..566] -> ContamChoking
##     Blow Up 1  [567..594] -> RocketDetonation2, ContaminatorDying
##     Run Over 1 [611..625] -> HKCrush, ContaminatorDying
##
## which is why it screams `contaminator_die_*` instead of `normal_dying_*`
## without a single per-unit line of code, and why a cause whose clip the model
## never authored is silent rather than falling back to somebody else's scream.

const GeneratedVoiceManifest := preload("res://resources/audio/generated_voice_manifest.gd")

## Mirrors UnitLocomotion.BAKED_MODEL_FRAMES_PER_SECOND: XBF frames are authored
## at a fixed 20 fps and the bake preserves that rate.
const BAKED_MODEL_FRAMES_PER_SECOND := 20.0

const XBF_SOUND_EVENT_TYPE := 9
const CRUSH_CLIP := &"Run_Over_1"

## The closed set of infantry death-voice sections, keyed by lower-cased section
## id -> the sample family it draws from. Derived mechanically from
## assets/raw_original_content/SFX/*.txt: these are every section whose Sounds=
## list is one of the six dying-infantry sample pools (normal_dying_*,
## burn_dying_*, choke_dying_*, contaminator_die_*, female_death_*,
## crush_guy_*), and nothing else.
##
## Death clips also carry type-9 events for the weapon/explosion that killed the
## man (RocketDetonation*, ShellDetonation*, GunHit*, MachineGunHit*, RifleHit,
## Small/Medium, HKExplodeFlame, ...). Those belong to the impact and
## explosion-tier systems, which fire them from their own call sites, so this
## table is an allowlist rather than a denylist: an unknown id is somebody
## else's sound, not a missing voice.
const VOICE_FAMILIES := {
	&"normalmandying": &"normal_dying",
	&"atnormalmandying": &"normal_dying",
	&"hknormalmandying": &"normal_dying",
	&"ornormalmandying": &"normal_dying",
	&"sardaukardying": &"normal_dying",
	&"fremendying": &"normal_dying",
	&"burningsmall": &"burn_dying",
	&"atburningmandying": &"burn_dying",
	&"hkburningmandying": &"burn_dying",
	&"orburningmandying": &"burn_dying",
	&"choking": &"choke_dying",
	&"atchoking": &"choke_dying",
	&"hkchoking": &"choke_dying",
	&"orchoking": &"choke_dying",
	&"contamchoking": &"choke_dying",
	&"contaminatordying": &"contaminator_die",
	&"femalecivdying": &"female_death",
	&"crush": &"crush_guy",
	&"atcrush": &"crush_guy",
	&"hkcrush": &"crush_guy",
	&"orcrush": &"crush_guy",
}

## Per-house section -> the generic section spelling the same samples. Only used
## when the per-house id went ungenerated (ImportedSfx.txt shadowing, see
## tools/generate_voice_feedback.py): the two are alternative names for one
## sound, so falling back keeps the scream instead of dropping it.
const GENERIC_FALLBACKS := {
	&"atnormalmandying": &"normalmandying",
	&"hknormalmandying": &"normalmandying",
	&"ornormalmandying": &"normalmandying",
	&"atburningmandying": &"burningsmall",
	&"hkburningmandying": &"burningsmall",
	&"orburningmandying": &"burningsmall",
	&"atchoking": &"choking",
	&"hkchoking": &"choking",
	&"orchoking": &"choking",
	&"atcrush": &"crush",
	&"hkcrush": &"crush",
	&"orcrush": &"crush",
}


## `[{"event_id": StringName, "delay": float}, ...]` for the death clip that
## actually matched, ordered by authored frame. `delay` is seconds from the
## start of the clip, so the scream lands where the animation puts it rather
## than all at once on the killing blow.
##
## `model_root` may be any node above the baked XBF root (the corpse model, the
## unit's visual root, ...); the meta-bearing node is found by walking down from
## it.
static func schedule(model_root: Node, clip: StringName) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if model_root == null or clip == &"":
		return result
	var fx_root := _find_fx_root(model_root)
	# An incomplete event table means the parser kept only a valid prefix (see
	# ModelXbf._parse_fx_events), so absent events cannot be distinguished from
	# undecoded ones and a partial schedule would be a guess.
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
	var is_crush_clip := _normalized(String(clip)).nocasecmp_to(
		_normalized(String(CRUSH_CLIP))
	) == 0

	var claimed_families := {}
	for event_value: Variant in fx_root.get_meta("xbf_fx_events", []):
		var event := event_value as Dictionary
		if int(event.get("type", -1)) != XBF_SOUND_EVENT_TYPE:
			continue
		var frame := int(event.get("frame", -1))
		if frame < clip_start or frame > clip_end:
			continue
		# Authored clip ranges overlap in shipped models — HK_Flamer's
		# `Run Over 1` [328..338] sits wholly inside its `Shot 1` [332..356] —
		# so containment alone would hand one clip's sounds to its neighbour.
		# The tightest range around a frame is the clip that frame was authored
		# for.
		if _has_tighter_entry(entries, frame, clip_end - clip_start):
			continue
		var event_id := _event_id(event)
		var family: StringName = VOICE_FAMILIES.get(event_id, &"")
		if family == &"":
			continue
		# GU_Man authors its `ATCrush` one frame *before* its own `Run Over 1`
		# starts, which leaves it inside `Shot 1` where no range rule can
		# dislodge it. Crush is the one family whose clip is unambiguous, so
		# pin it there.
		if family == &"crush_guy" and not is_crush_clip:
			continue
		# Models spell the same pool twice in one clip — TL_Contaminator's
		# `Burnt 1` names both `BurningSmall` and `HKburningManDying`, which are
		# the same eight burn_dying_* samples — and playing both doubles the
		# scream. One voice per family, earliest authored frame wins; different
		# families in one clip (the burn scream *and* the contaminator's own
		# gurgle) are both intended and both kept.
		if claimed_families.has(family):
			continue
		var resolved := _resolved_event_id(event_id)
		if resolved == &"":
			continue
		claimed_families[family] = true
		result.append({
			"event_id": resolved,
			"delay": float(frame - clip_start) / BAKED_MODEL_FRAMES_PER_SECOND,
		})
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["delay"]) < float(b["delay"])
	)
	return result


## Same walk as AuthoredFireController.find_xbf_motion_root(), repeated rather
## than called: this whole resolver is static (so it can be exercised with plain
## dictionaries and no scene), and a static-context call into another script's
## statics does not resolve here.
static func _find_fx_root(node: Node) -> Node:
	if node.has_meta("xbf_animation_entries") and node.has_meta("xbf_fx_events"):
		return node
	for child in node.get_children():
		var found := _find_fx_root(child)
		if found != null:
			return found
	return null


## Baked entry names keep the source spelling ("Blow Up 1") while clip names are
## underscored; same normalisation CombatTurretFx._model_animation_entry() uses.
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


static func _event_id(event: Dictionary) -> StringName:
	var strings := event.get("strings", []) as Array
	if strings.is_empty():
		return &""
	return StringName(String(strings[0]).strip_edges().to_lower())


static func _resolved_event_id(event_id: StringName) -> StringName:
	if GeneratedVoiceManifest.DEATH_EVENT_PATHS.has(event_id):
		return event_id
	var fallback: StringName = GENERIC_FALLBACKS.get(event_id, &"")
	if fallback != &"" and GeneratedVoiceManifest.DEATH_EVENT_PATHS.has(fallback):
		return fallback
	return &""


static func _normalized(name: String) -> String:
	return name.strip_edges().replace(" ", "_")
