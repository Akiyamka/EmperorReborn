extends SceneTree

## Converts every entry in Emperor: Battle for Dune's `AUDIO.BAG` sound
## archive to a standalone `.wav` file that Godot's asset pipeline imports
## natively. See `converters/bag/audio_bag.gd` for the archive format.

const AudioBagScript := preload("res://converters/bag/audio_bag.gd")

const DEFAULT_SOURCE := "res://assets/raw_original_content/SFX/AUDIO.BAG"
const DEFAULT_OUTPUT := "res://assets/converted/audio/sfx"


func _init() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	var source := String(args.get("source", DEFAULT_SOURCE))
	var output := String(args.get("output", DEFAULT_OUTPUT))

	var bag := AudioBagScript.load_file(source)
	if bag == null:
		quit(1)
		return

	var absolute_output := ProjectSettings.globalize_path(output)
	var mkdir_err := DirAccess.make_dir_recursive_absolute(absolute_output)
	if mkdir_err != OK:
		push_error("convert_audio_bag: could not create %s (%s)" % [output, error_string(mkdir_err)])
		quit(1)
		return

	var written := 0
	var failures: PackedStringArray = []
	var entries_by_name := {}
	for entry in bag.entries:
		var folded_name := String(entry.name).to_lower()
		if entries_by_name.has(folded_name):
			var original: Dictionary = entries_by_name[folded_name]
			if not _same_audio(original, entry):
				failures.append("%s conflicts with %s by case" % [entry.name, original.name])
			continue
		entries_by_name[folded_name] = entry
		var entry_path := output.path_join("%s.wav" % String(entry.name))
		var err := _write_wav(entry_path, entry)
		if err != OK:
			failures.append(String(entry.name))
			continue
		written += 1
	_remove_case_duplicate_outputs(output, entries_by_name)

	print("convert_audio_bag: wrote %d wav files to %s" % [written, output])
	if not failures.is_empty():
		push_error("convert_audio_bag: failed to write %d entries: %s" % [failures.size(), ", ".join(failures)])
	if not bag.unknown_formats.is_empty():
		var unknown: PackedStringArray = []
		for name in bag.unknown_formats:
			unknown.append("%s (format %d)" % [name, bag.unknown_formats[name]])
		push_error("convert_audio_bag: skipped %d entries with unrecognized format: %s" % [unknown.size(), ", ".join(unknown)])

	quit(1 if (not failures.is_empty() or not bag.unknown_formats.is_empty()) else 0)


func _same_audio(first: Dictionary, second: Dictionary) -> bool:
	return (
		first.sample_rate == second.sample_rate
		and first.channels == second.channels
		and first.bits == second.bits
		and first.pcm == second.pcm
	)


func _remove_case_duplicate_outputs(output: String, entries_by_name: Dictionary) -> void:
	var directory := DirAccess.open(output)
	if directory == null:
		return
	for file_name in directory.get_files():
		if file_name.get_extension().to_lower() != "wav":
			continue
		var folded_name := file_name.get_basename().to_lower()
		if not entries_by_name.has(folded_name):
			continue
		var canonical_name := "%s.wav" % String(entries_by_name[folded_name].name)
		if file_name != canonical_name:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(output.path_join(file_name)))


func _write_wav(path: String, entry: Dictionary) -> Error:
	var absolute_path := ProjectSettings.globalize_path(path)
	var file := FileAccess.open(absolute_path, FileAccess.WRITE)
	if file == null:
		push_error("convert_audio_bag: could not open %s (%s)" % [path, error_string(FileAccess.get_open_error())])
		return FileAccess.get_open_error()

	var channels: int = entry.channels
	var bits: int = entry.bits
	var sample_rate: int = entry.sample_rate
	var pcm: PackedByteArray = entry.pcm
	var block_align := channels * (bits / 8)
	var byte_rate := sample_rate * block_align
	# AUDIO.BAG contains a deliberately empty `silent` sample used by a few
	# dialog hooks. Godot cannot instantiate playback for a zero-frame WAV
	# (AudioStreamWAV fetches an initial block of eight frames), so preserve its
	# meaning as a tiny playable block of digital silence. Keep enough frames
	# beyond AudioStreamWAV's eight-frame interpolation window to avoid
	# reaching EOF while that initial window is populated.
	if pcm.is_empty():
		pcm.resize(block_align * 32)
		if bits == 8:
			pcm.fill(128)

	file.store_string("RIFF")
	file.store_32(36 + pcm.size())
	file.store_string("WAVE")

	file.store_string("fmt ")
	file.store_32(16)
	file.store_16(1) # PCM
	file.store_16(channels)
	file.store_32(sample_rate)
	file.store_32(byte_rate)
	file.store_16(block_align)
	file.store_16(bits)

	file.store_string("data")
	file.store_32(pcm.size())
	file.store_buffer(pcm)

	return OK


func _parse_args(raw_args: PackedStringArray) -> Dictionary:
	var parsed := {}
	var i := 0
	while i < raw_args.size():
		var arg := raw_args[i]
		if arg.begins_with("--"):
			var key := arg.substr(2)
			if i + 1 < raw_args.size() and not raw_args[i + 1].begins_with("--"):
				parsed[key] = raw_args[i + 1]
				i += 2
			else:
				parsed[key] = true
				i += 1
		else:
			i += 1
	return parsed
