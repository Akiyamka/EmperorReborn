class_name DeathSoundPlayer
extends AudioStreamPlayer3D

## One-shot, positional playback for a resolved death/explosion `SoundEvent`,
## spawned as a child of a `DeathCorpse` so it dies with the corpse and is
## positioned at the corpse's own transform. Unlike `SoundEventPlayer` (a
## single non-positional `AudioStreamPlayer` tied to one persistent owner,
## built for command barks), this is throwaway: it plays exactly one sample
## and reports back via `sound_finished`, mirroring the same random-pick
## idiom `SoundEventPlayer._playback_sequence()` uses for a plain (non
## attack/decay) event.

signal sound_finished

## Godot's AudioStreamPlayer3D defaults (unit_size = 10, inverse-distance
## falloff, unbounded max_distance) assume a camera a few units from the
## source — normal first/third-person scale. This project's camera never
## gets that close: RTSCameraConfig positions the camera at
## `zoom * sqrt(1 + camera_height_per_zoom^2)` world units from its view
## target (rts_camera.gd._apply_zoom — camera.position is
## `Vector3(0, zoom * camera_height_per_zoom, zoom)`), which with
## camera_height_per_zoom = 0.75 is `zoom * 1.25`. With min_zoom=14 /
## default_zoom=32 / max_zoom=240 that puts the camera 17.5 / 40 / 300 world
## units from a dying unit. At the untouched default (unit_size=10), Godot's
## inverse-distance gain `1 / (1 + distance / unit_size)` is already down to
## roughly -12dB at default zoom and -28dB at max zoom, before the sample's
## own authored volume is even applied — quiet enough at normal play zoom,
## and buried under anything else at high zoom, to read as "no sound at
## all", exactly as reported. Widening unit_size to UNIT_SIZE keeps a real,
## audible distance cue (still quieter far away) while making the common
## "watching combat at normal zoom" case clearly audible:
## `1 / (1 + 40 / UNIT_SIZE)` ~= -3.5dB at default zoom, ~= -13.5dB at max
## zoom. MAX_DISTANCE gives the falloff a hard floor a bit past the
## farthest the camera can ever be (max_zoom's ~300 units) instead of the
## unbounded default, so a death across the map fades out instead of
## lingering at an inaudible whisper forever. Applies equally to infantry
## and vehicle deaths: both go through this same class.
const UNIT_SIZE := 80.0
const MAX_DISTANCE := 400.0

## Length of the ramp `fade_out_and_free()` applies before freeing a player
## that is still mid-sample. Cutting a running stream with a hard `stop()`
## leaves a step discontinuity in the mixed signal — an audible click — so the
## gain is ramped down first. Short enough (30ms) that the retired sample reads
## as "replaced by the next shot" rather than as its own fading tail, long
## enough to stay below the click threshold.
const FADE_OUT_SECONDS := 0.03
## Gain the fade ramps down to before freeing. -60dB is inaudible under any
## other combat sound; ramping to actual silence is not possible in dB space.
const FADE_OUT_DB := -60.0

var _fading := false


func _init() -> void:
	unit_size = UNIT_SIZE
	max_distance = MAX_DISTANCE
	# Godot's default attenuation low-pass (cutoff 5000Hz/-24dB) simulates air
	# absorption for a close first-person listener; at RTS camera distances
	# it made every positional sound sound muffled even at default zoom.
	# 20500Hz+ disables the filter outright (per AudioStreamPlayer3D docs).
	attenuation_filter_cutoff_hz = 20500.0
	attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE


## Picks one sample from `event` and plays it. If the event carries no
## resolvable sample at all (empty `sample_paths`, or the referenced stream
## fails to load), reports completion immediately instead of playing
## nothing forever — the caller (`DeathCorpse`) must not wait on a sound
## that will never start.
func play_event(event: SoundEvent) -> void:
	if event == null or event.sample_paths.is_empty():
		sound_finished.emit()
		return
	var sample_path: String = (
		event.sample_paths.pick_random()
		if &"random" in event.controls
		else event.sample_paths.front()
	)
	var sample_stream := load(sample_path)
	if sample_stream == null:
		sound_finished.emit()
		return
	stream = sample_stream
	volume_db = linear_to_db(clampf(float(event.volume) / 100.0, 0.0001, 1.0))
	finished.connect(_on_finished)
	play()


func _on_finished() -> void:
	sound_finished.emit()


## Loads and plays `stream` directly, bypassing SoundEvent entirely — used by
## the direct-WAV explosion-tier system (ExplosionTierPools) which
## deliberately does not go through GeneratedVoiceManifest (see
## VehicleDeathStrategy/docs/quirks.md for why). Unlike `play_event()`, the
## caller picks the sample (one random file from a tier/faction pool) and
## just wants it played; connecting to `finished`/`sound_finished` is the
## caller's job since some callers (a corpse's pending-sound count) need to
## track completion and some (a fire-and-forget standalone layer) don't.
func play_stream(stream: AudioStream) -> void:
	if stream == null:
		sound_finished.emit()
		return
	self.stream = stream
	finished.connect(_on_finished)
	play()


## Retires a still-playing one-shot early, for a caller that has decided this
## sound has been superseded — the fire-sound "one voice per weapon" rule in
## CombatTurret, where the next shot of a burst replaces the previous one
## instead of layering on top of it.
##
## Ramps the gain down over `duration` and then frees the node, rather than
## calling `stop()`: stopping mid-sample truncates the waveform at whatever
## non-zero amplitude it happened to be at, and that step discontinuity is an
## audible click. Idempotent — a second call while the ramp is running is
## ignored, so a player already on its way out is never re-tweened.
func fade_out_and_free(duration: float = FADE_OUT_SECONDS) -> void:
	if _fading:
		return
	_fading = true
	# Nothing to ramp: either not yet in the tree (create_tween() would fail) or
	# the sample already finished on its own.
	if not is_inside_tree() or not playing:
		queue_free()
		return
	var tween := create_tween()
	tween.tween_property(self, "volume_db", FADE_OUT_DB, maxf(duration, 0.0))
	tween.tween_callback(queue_free)


## Fire-and-forget playback of one random sample from `paths`, parented
## directly under `parent` at `world_position` and freeing itself once done.
## For layers that have no owner tracking their completion (the VFX-timed
## size-tier layer, and the corpse-less early-out death path in
## Unit._begin_death_sequence) — contrast with DeathCorpse's own
## _pending_sounds tracking, which callers that DO need to wait on a layer
## should use instead.
##
## `volume` is the original SFX event's authored `Volume` (0-100), applied as
## linear gain — samples were mixed down from that value in the original
## engine, and playing them all back unscaled at 100 clips or sounds harsh on
## ones authored hot and quiet (e.g. TurretDefinition.fire_sound_volume).
## Defaults to 100 (unscaled) for callers (explosion/death pools) that have
## no per-sample volume of their own.
##
## Returns the started player so a caller that owns a single "voice" (see
## `fade_out_and_free()`) can retire it when the next sound replaces it, or
## null when nothing was played. Callers with no such tracking ignore the
## return value — the player still frees itself when the sample ends.
static func play_pool(
	parent: Node, world_position: Vector3, paths: Array, volume: float = 100.0
) -> DeathSoundPlayer:
	if paths.is_empty() or parent == null or not parent.is_inside_tree():
		return null
	var path: String = paths[randi() % paths.size()]
	var stream := load(path) as AudioStream
	if stream == null:
		return null
	var player := DeathSoundPlayer.new()
	parent.add_child(player)
	player.global_position = world_position
	player.finished.connect(player.queue_free)
	player.stream = stream
	player.volume_db = linear_to_db(clampf(volume / 100.0, 0.0001, 1.0))
	player.play()
	return player
