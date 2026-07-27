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
## variant, confirmed by disassembling the original engine (per-nibble decode
## at VA `0x4a5a80`, flags-to-format-type mapping at `0x472520`, tables
## byte-for-byte at `0x602298`/`0x602278` in `Game.exe`).
##
## The compressed stream is split into fixed-size blocks. The block size is
## stored per entry in the first of the four trailing u32s of its 64-byte
## table row (offset +48; 512 for all but 11 entries, which use 1024) — the
## engine copies those 16 tail bytes into its sound descriptor at `0x472596`.
## Every block independently begins with one 4-byte header per channel:
## `s16 LE` initial predictor, `u8` initial step_index (<= 88), `u8`
## reserved (always 0) — verified across all 17016 blocks of all 674
## compressed entries in the shipped AUDIO.BAG. The rest of the block is
## nibble-packed deltas, low-nibble first: `diff = (step >> 3) + (step >> 2
## if bit0) + (step >> 1 if bit1) + (step if bit2)`, sign is nibble bit 3,
## index-table lookup uses the full nibble (0-15) into a 16-entry table.
## (The exact shift-add form matters: `((2 * delta + 1) * step) >> 3` is NOT
## bit-identical because each term truncates separately.)

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
		var block_size := buffer.get_32()

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
		var pcm := _decode_ima_ws(raw, block_size) if compressed else raw
		entries.append({"name": name, "sample_rate": sample_rate, "channels": channels, "bits": bits, "pcm": pcm})

	return true


const CHANNEL_HEADER_SIZE := 4


## Decodes one channel's worth of this IMA-ADPCM-like stream. The stream is
## made of `block_size`-byte blocks, each starting with its own 4-byte header
## (see class doc) followed by nibble-packed deltas, so every block yields
## `(block_size - 4) * 2` samples (fewer for a short final block).
func _decode_ima_ws(raw: PackedByteArray, block_size: int) -> PackedByteArray:
	var out := StreamPeerBuffer.new()
	out.resize((raw.size() - CHANNEL_HEADER_SIZE) * 4)
	out.seek(0)

	for block_start: int in range(0, raw.size(), block_size):
		if block_start + CHANNEL_HEADER_SIZE > raw.size():
			break
		var predictor: int = raw.decode_s16(block_start)
		var step_index: int = clampi(raw.decode_u8(block_start + 2), 0, 88)
		var body_end: int = mini(block_start + block_size, raw.size())

		for i: int in range(block_start + CHANNEL_HEADER_SIZE, body_end):
			var byte: int = raw[i]
			for shift: int in [0, 4]:
				var nibble: int = (byte >> shift) & 0x0F
				var step: int = STEP_TABLE[step_index]
				var diff: int = step >> 3
				if nibble & 1:
					diff += step >> 2
				if nibble & 2:
					diff += step >> 1
				if nibble & 4:
					diff += step
				if nibble & 8:
					predictor -= diff
				else:
					predictor += diff
				predictor = clampi(predictor, -32768, 32767)
				step_index = clampi(step_index + INDEX_TABLE[nibble], 0, 88)
				out.put_16(predictor)

	return out.data_array.slice(0, out.get_position())
