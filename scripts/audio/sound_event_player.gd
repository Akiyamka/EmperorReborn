class_name SoundEventPlayer
extends Node

var _player: AudioStreamPlayer
var _queue: Array[String] = []


func _ready() -> void:
	_player = AudioStreamPlayer.new()
	_player.name = "VoiceFeedback"
	add_child(_player)
	_player.finished.connect(_play_next)


func _exit_tree() -> void:
	_queue.clear()
	if _player != null:
		_player.stop()
		_player.stream = null


func play_event(event: SoundEvent) -> void:
	if event == null or event.sample_paths.is_empty():
		return
	if _player == null:
		return
	_player.stop()
	_queue = _playback_sequence(event)
	_player.volume_db = linear_to_db(clampf(float(event.volume) / 100.0, 0.0001, 1.0))
	_play_next()


func _playback_sequence(event: SoundEvent) -> Array[String]:
	var paths := event.sample_paths
	var controls := event.controls
	if &"attack" not in controls and &"decay" not in controls:
		var simple_result: Array[String] = []
		simple_result.append(paths.pick_random() if &"random" in controls else paths.front())
		return simple_result

	var attack_count := mini(event.attack_count, paths.size())
	var decay_count := mini(event.decay_count, paths.size() - attack_count)
	var result: Array[String] = []
	if attack_count > 0:
		result.append(paths[randi_range(0, attack_count - 1)])
	var body_end := paths.size() - decay_count
	if body_end > attack_count:
		result.append(paths[randi_range(attack_count, body_end - 1)])
	if decay_count > 0:
		result.append(paths[randi_range(body_end, paths.size() - 1)])
	return result


func _play_next() -> void:
	if _queue.is_empty() or _player == null:
		return
	var stream = load(_queue.pop_front())
	if stream == null:
		_play_next()
		return
	_player.stream = stream
	_player.play()
