class_name UnitMovementSounds
extends RefCounted

## The sounds a unit makes while it moves: a mech's footsteps and a vehicle's
## engine start. The original data expresses these two as two different
## mechanisms, and both are read here.
##
## Footsteps live inside the model. An XBF FX event of type 9 carries one
## string, and that string is the name of an SFX section to play; the converter
## bakes the whole event table onto the model root (`xbf_fx_events`, with the
## clip ranges in `xbf_animation_entries`), so a step is simply "event type 9 at
## frame N of the Move clip". Scoping the search to the movement clips is what
## keeps fire and death sounds out of it -- the Mongoose's
## `ATCannonSingleLoudShot` sits in `Fire 0` and its `ATMedBang1` in `Explode`,
## so no name blacklist is needed. Names with no matching section (every
## infantry `*Footsteps`, `TrackStartMove`, ...) resolve to nothing and stay
## silent, which is what the original data says.
##
## The engine start is not in the model at all: the original engine synthesised
## the section name as `<RulesSectionName>MoveFxStart`, resolved at convert time
## into `UnitDefinition.move_start_sound_id`. It fires once per departure.
##
## The one place the two mechanisms meet is HKDevastator: its model authors four
## `HKDevastatorFootsteps` events for which no section was ever shipped, while
## its `hkdevastatormovefxstart` section holds the walk sample. A mech whose
## step events resolve to nothing therefore falls back to its own move-start
## section for the steps, and does not additionally play it on departure --
## a mech's movement sound is its gait. That fallback is a gameplay decision,
## not something the data states; see docs/quirks.md.

const AuthoredFireControllerScript := preload(
	"res://scripts/combat/authored_fire_controller.gd"
)
const SfxSectionCatalogScript := preload("res://scripts/audio/sfx_section_catalog.gd")

## Converted XBF tracks use a 20 Hz timeline, same as UnitLocomotion.
const BAKED_MODEL_FRAMES_PER_SECOND := 20.0
## FX event record that means "play this sound event". Types 1/2/8 name objects
## and 3/4 particle banks; 10 and 11 are the launch and speed payloads the
## fire controller and locomotion already read.
const SOUND_FX_EVENT_TYPE := 9
## Only these clips are searched. Every other clip's sound events belong to
## firing, dying or deploying, which their own systems already drive.
const MOVEMENT_CLIP_NAMES: Array[StringName] = [
	&"Move", &"Move_Start", &"Move_Stop", &"Turn_Left", &"Turn_Right"
]
## Playback positions are compared frame to frame, so an event sitting exactly
## at time 0 needs the first window to open just before it.
const WINDOW_EPSILON := 0.0001

var _unit: CharacterBody3D
var _players: Array[AnimationPlayer] = []
## Clip name -> [{time, section}, ...] sorted by time.
var _schedules: Dictionary = {}
var _move_start_section: StringName = &""
var _is_mech := false
var _previous_animation: StringName = &""
var _previous_position := 0.0
var _was_moving := false


func configure(unit: CharacterBody3D) -> void:
	_unit = unit


func attach_model(players: Array[AnimationPlayer]) -> void:
	_players = players
	_previous_animation = &""
	_previous_position = 0.0


## Idempotent, like UnitLocomotion.detach_model(): a dying unit hands its model
## to the corpse and then still gets _exit_tree().
func detach_model() -> void:
	_players = []
	_schedules.clear()
	_previous_animation = &""
	_previous_position = 0.0


func adopt_definition(unit_definition: Resource) -> void:
	if unit_definition == null:
		_move_start_section = &""
		_is_mech = false
	else:
		_move_start_section = unit_definition.move_start_sound_id
		_is_mech = bool(unit_definition.mech)
	_was_moving = false


## Rebuilds the per-clip step schedule from the model's baked FX table. Called
## wherever the model or the definition can change, and safe to call with
## neither present -- a unit whose model authors no resolvable step event ends
## up with an empty schedule, and `advance()` then costs one dictionary check.
func refresh_step_schedule() -> void:
	_schedules.clear()
	_previous_animation = &""
	_previous_position = 0.0
	var visual_root: Node3D = _unit.visual_root if _unit != null else null
	if visual_root == null:
		return
	var model_root := AuthoredFireControllerScript.find_xbf_motion_root(visual_root)
	if model_root == null:
		return
	# A truncated event table has unreliable frame numbers for everything after
	# the truncation point, so the same gate the fire controller applies is
	# applied here rather than scheduling steps at guessed times.
	if not bool(model_root.get_meta("xbf_fx_events_complete", false)):
		return
	var clip_ranges := _movement_clip_ranges(model_root)
	if clip_ranges.is_empty():
		return
	for event_value: Variant in model_root.get_meta("xbf_fx_events", []):
		var event := event_value as Dictionary
		if int(event.get("type", -1)) != SOUND_FX_EVENT_TYPE:
			continue
		var strings: Array = event.get("strings", [])
		if strings.is_empty():
			continue
		var section := _resolved_section(StringName(String(strings[0]).strip_edges()))
		if section.is_empty():
			continue
		var frame := int(event.get("frame", -1))
		for clip_name: StringName in clip_ranges:
			var clip_range: Array = clip_ranges[clip_name]
			var start_frame := int(clip_range[0])
			if frame < start_frame or frame > int(clip_range[1]):
				continue
			# One event can belong to more than one clip: the Mongoose's third
			# step sits in the frame range Turn_Left and Turn_Right share.
			var schedule: Array = _schedules.get(clip_name, [])
			schedule.append({
				"time": float(frame - start_frame) / BAKED_MODEL_FRAMES_PER_SECOND,
				"section": section,
			})
			_schedules[clip_name] = schedule
	for clip_name: StringName in _schedules:
		var schedule: Array = _schedules[clip_name]
		schedule.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return float(a["time"]) < float(b["time"])
		)


## The move-start one-shot. Mechs are excluded: theirs is already playing per
## step through the schedule above.
func notify_movement_state(is_moving: bool) -> void:
	if is_moving and not _was_moving and not _is_mech:
		_play(_move_start_section)
	_was_moving = is_moving


## Plays every step the movement clip crossed since the previous frame. Driven
## from Unit._process(), after the AnimationPlayers have advanced, so the
## position read here is this frame's post-update value regardless of the speed
## scale the gait is currently running at.
func advance(_delta: float) -> void:
	if _schedules.is_empty():
		return
	var driver := _movement_clip_player()
	if driver == null:
		_previous_animation = &""
		return
	var animation_name := StringName(driver.current_animation)
	var position := driver.current_animation_position
	if animation_name != _previous_animation:
		_play_window(animation_name, -WINDOW_EPSILON, position)
	elif position + WINDOW_EPSILON < _previous_position:
		# The looping Move clip wrapped: finish the cycle that ended, then
		# replay the part of the new one that has already gone by.
		_play_window(animation_name, _previous_position, _clip_length(driver, animation_name))
		_play_window(animation_name, -WINDOW_EPSILON, position)
	else:
		_play_window(animation_name, _previous_position, position)
	_previous_animation = animation_name
	_previous_position = position


## The schedule built for `clip_name`, as [{time, section}, ...]. Exposed for
## tests, which assert against the frames the source models author.
func step_schedule_for(clip_name: StringName) -> Array:
	return _schedules.get(clip_name, [])


func _movement_clip_ranges(model_root: Node) -> Dictionary:
	var ranges := {}
	for entry_value: Variant in model_root.get_meta("xbf_animation_entries", []):
		var entry := entry_value as Dictionary
		# The bake stores the source clip name; the AnimationLibrary spells it
		# with underscores. Normalize the same way the fire controller does.
		var clip_name := StringName(
			String(entry.get("name", "")).strip_edges().replace(" ", "_")
		)
		if clip_name not in MOVEMENT_CLIP_NAMES:
			continue
		var start_frame := int(entry.get("start_frame", -1))
		var end_frame := int(entry.get("end_frame", -1))
		if start_frame < 0 or end_frame < start_frame:
			continue
		ranges[clip_name] = [start_frame, end_frame]
	return ranges


## Which section an authored step event should play, or `&""` for silence.
func _resolved_section(event_name: StringName) -> StringName:
	if SfxSectionCatalogScript.has_section(event_name):
		# Sections partitioned into attack/decay samples are spoken radio
		# events, not mechanical sounds -- ATadpMove, the only one authored
		# inside a movement clip, is the ADP's move acknowledgement and is
		# already played as a voice bark. Filtered by what the data says about
		# the section rather than by name.
		var section := SfxSectionCatalogScript.section(event_name)
		var controls := Array(section.get("controls", []))
		if &"attack" in controls or &"decay" in controls:
			return &""
		return event_name
	if _is_mech and SfxSectionCatalogScript.has_section(_move_start_section):
		return _move_start_section
	return &""


func _movement_clip_player() -> AnimationPlayer:
	for player in _players:
		if player == null or not player.is_playing():
			continue
		if _schedules.has(StringName(player.current_animation)):
			return player
	return null


func _clip_length(player: AnimationPlayer, animation_name: StringName) -> float:
	var animation := player.get_animation(animation_name)
	return animation.length if animation != null else 0.0


func _play_window(clip_name: StringName, after: float, until: float) -> void:
	for entry_value: Variant in _schedules.get(clip_name, []):
		var entry := entry_value as Dictionary
		var time := float(entry["time"])
		if time > after and time <= until:
			_play(entry["section"])


func _play(section: StringName) -> void:
	if section.is_empty() or _unit == null or not _unit.is_inside_tree():
		return
	# Parented to the unit's own parent, not the unit: a step that starts on
	# the frame the unit dies should finish playing rather than be freed with
	# it, exactly like the death sounds a corpse leaves behind.
	SfxSectionCatalogScript.play_at(
		_unit.get_parent(), _unit.global_position, section
	)
