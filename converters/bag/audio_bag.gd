class_name AudioBag
extends RefCounted

## Parses Emperor: Battle for Dune's `AUDIO.BAG` sound archive.
##
## Format (reverse engineered, no public spec exists): a 16-byte header
## (`"GABA"` magic, format version, entry count, entry stride), followed by
## a flat table of fixed-size entries, followed by one contiguous data blob.
## Each entry's `offset` is absolute from the start of the file and entries
## are laid out back-to-back inside the blob.
##
## Most entries store raw PCM. The rest are compressed with an IMA-ADPCM-like
## variant. Confirmed bit-exact by disassembling the original engine
## (`Game.exe`'s decode routine at file offset `0x4a5a80`, called from a loop
## at `0x4a5990`, both tables byte-for-byte at `0x602298`/`0x602258`): each
## compressed entry starts with one 4-byte header per channel — `s16 LE`
## initial predictor, `u8` initial step_index, `u8` reserved (must be 0) —
## then nibble-packed deltas follow, low-nibble first, `diff = (step * (2 *
## delta + 1)) >> 3`, sign is nibble bit 3, index-table lookup uses the full
## nibble (0-15) into a duplicated 16-entry table (mathematically identical
## to indexing `nibble & 7` into the 8-entry half used here). No further
## per-block reset exists in the decode loop itself.
##
## Despite the algorithm now being disassembly-confirmed, decoded voice lines
## still show audible crackle and a "stepped" waveform (sudden scale/DC
## jumps) not present in live in-game audio captures. Whether that remaining
## difference is a real decode gap (something in the streaming/output path
## not yet traced) or just energetic speech transients showing up as false
## positives in coarse change-point analysis is unresolved — see
## `docs/audio_bag_compressed_codec.md`.

const MAGIC := "GABA"
const HEADER_SIZE := 16
const ENTRY_NAME_SIZE := 32

## The 32-bit field after sample_rate is a flags bitmask, not an opaque code
## (matches `ebfd-re`'s `BagEntry.Flags`).
const FLAG_STEREO := 1
const FLAG_UNCOMPRESSED := 2
const FLAG_16BIT := 4
const FLAG_COMPRESSED := 8
const FLAG_UNKNOWN := 16 # present on most compressed voice lines; purpose unknown, decoded the same as without it
const FLAG_MP3 := 32

const STEP_TABLE: PackedInt32Array = [
	7, 8, 9, 10, 11, 12, 13, 14, 16, 17,
	19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
	50, 55, 60, 66, 73, 80, 88, 97, 107, 118,
	130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
	337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
	876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
	2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358,
	5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
	15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
]
const INDEX_TABLE: PackedInt32Array = [-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8]

## Array[Dictionary]: {name, sample_rate, channels, bits, pcm: PackedByteArray}
var entries: Array[Dictionary] = []
## name -> original format_code, for entries whose format was not recognized.
var unknown_formats := {}


static func load_file(path: String) -> AudioBag:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		push_error("AudioBag: cannot read %s (%s)" % [path, error_string(FileAccess.get_open_error())])
		return null
	var bag := AudioBag.new()
	if not bag._parse(bytes):
		return null
	return bag


func _parse(bytes: PackedByteArray) -> bool:
	if bytes.size() < HEADER_SIZE:
		push_error("AudioBag: file is too small (%d bytes)" % bytes.size())
		return false

	var buffer := StreamPeerBuffer.new()
	buffer.data_array = bytes

	var magic := bytes.slice(0, 4).get_string_from_ascii()
	if magic != MAGIC:
		push_error("AudioBag: unexpected magic %s" % magic)
		return false
	buffer.seek(4)

	var _version := buffer.get_32()
	var count := buffer.get_32()
	var stride := buffer.get_32()
	if HEADER_SIZE + count * stride > bytes.size():
		push_error("AudioBag: table (%d entries x %d bytes) overruns %d byte file" % [count, stride, bytes.size()])
		return false

	entries.clear()
	unknown_formats.clear()

	for i in count:
		var entry_offset := HEADER_SIZE + i * stride
		var name_bytes := bytes.slice(entry_offset, entry_offset + ENTRY_NAME_SIZE)
		var name_end := name_bytes.find(0)
		if name_end < 0:
			name_end = name_bytes.size()
		var name := name_bytes.slice(0, name_end).get_string_from_ascii()
		buffer.seek(entry_offset + ENTRY_NAME_SIZE)
		var data_offset := buffer.get_32()
		var data_size := buffer.get_32()
		var sample_rate := buffer.get_32()
		var flags := buffer.get_32()

		if data_offset + data_size > bytes.size():
			push_error("AudioBag: entry '%s' data (%d+%d) overruns file" % [name, data_offset, data_size])
			continue
		var raw := bytes.slice(data_offset, data_offset + data_size)

		if flags & FLAG_MP3:
			# No MP3 entries exist in AUDIO.BAG today; leave unhandled rather
			# than guess at a container/output convention nothing exercises.
			unknown_formats[name] = flags
			continue

		var compressed := bool(flags & FLAG_COMPRESSED)
		var uncompressed := bool(flags & FLAG_UNCOMPRESSED)
		if compressed == uncompressed:
			unknown_formats[name] = flags
			continue

		var channels := 2 if flags & FLAG_STEREO else 1
		var bits := 16 if flags & FLAG_16BIT else 8
		var pcm := _decode_ima_ws(raw) if compressed else raw
		entries.append({"name": name, "sample_rate": sample_rate, "channels": channels, "bits": bits, "pcm": pcm})

	return true


const CHANNEL_HEADER_SIZE := 4


## Decodes one channel's worth of this IMA-ADPCM-like stream. `raw` starts
## with that channel's 4-byte header (see class doc); the returned PCM
## covers only the nibble-packed body, i.e. `(raw.size() - 4) * 2` samples.
func _decode_ima_ws(raw: PackedByteArray) -> PackedByteArray:
	var predictor: int = raw.decode_s16(0)
	var step_index: int = clampi(raw.decode_u8(2), 0, 88)

	var body := raw.slice(CHANNEL_HEADER_SIZE)
	var out := StreamPeerBuffer.new()
	out.resize(body.size() * 4)
	out.seek(0)

	for byte: int in body:
		for shift: int in [0, 4]:
			var nibble: int = (byte >> shift) & 0x0F
			var step: int = STEP_TABLE[step_index]
			var delta: int = nibble & 7
			var diff: int = ((2 * delta + 1) * step) >> 3
			if nibble & 8:
				predictor -= diff
			else:
				predictor += diff
			predictor = clampi(predictor, -32768, 32767)
			step_index = clampi(step_index + INDEX_TABLE[nibble], 0, 88)
			out.put_16(predictor)

	return out.data_array
