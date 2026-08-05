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


func _init() -> void:
	unit_size = UNIT_SIZE
	max_distance = MAX_DISTANCE
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
static func play_pool(
	parent: Node, world_position: Vector3, paths: Array, volume: float = 100.0
) -> void:
	if paths.is_empty() or parent == null or not parent.is_inside_tree():
		return
	var path: String = paths[randi() % paths.size()]
	var stream := load(path) as AudioStream
	if stream == null:
		return
	var player := DeathSoundPlayer.new()
	parent.add_child(player)
	player.global_position = world_position
	player.finished.connect(player.queue_free)
	player.stream = stream
	player.volume_db = linear_to_db(clampf(volume / 100.0, 0.0001, 1.0))
	player.play()
