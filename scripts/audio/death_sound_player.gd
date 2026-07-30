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
