# AUDIO.BAG compressed codec: investigation log

**Status: SOLVED (finding #9).** The compressed stream is **block-based**:
each entry's 64-byte table row carries a per-entry block size in its first
trailing u32 (offset +48; 512 for all but 11 entries, which use 1024), and
**every block independently restarts the codec with its own 4-byte header**
(`s16 LE` predictor, `u8` step_index <= 88, `u8` reserved = 0). The earlier
decoder read one header for the whole entry and treated every later block's
header bytes as nibble data — that is exactly what produced the
crackle/"stepped waveform" artifact (each block after the first decoded from
a stale predictor/step, giving per-section scale and DC-offset errors, with
a click at every 512-byte boundary). The per-nibble math from finding #6
was always correct. `converters/bag/audio_bag.gd` now decodes per-block;
verified structurally against all 17016 blocks of all 674 compressed
entries (0 invalid headers — the `reserved == 0` check alone would fail with
p=255/256 per block on misaligned data). Findings #1–#8 below are kept as
the historical record of how this was narrowed down.

The raw (uncompressed) formats are solid and not in question: 8-bit mono,
16-bit mono, and 16-bit stereo PCM entries (269 of 945) decode and sound
correct, confirmed by ear (`Button1`, `normal_dying_1`, `ConstructSpark`,
`DropShipLand`, etc.).

## Container format (solved, confident)

16-byte header: `"GABA"` magic, `u32` version, `u32` entry count, `u32`
entry stride (64). Then a flat table of fixed-size entries: 32-byte
null-padded name, `u32 data_offset` (absolute from file start), `u32
data_size`, `u32 sample_rate`, `u32 flags`. Entries are laid out back-to-back
in one contiguous blob starting right after the table
(`header_size + count*stride == first_entry.data_offset`, verified exactly).

The `flags` field is a bitmask, confirmed against the independent
[`ebfd-re`](https://github.com/IceReaper/ebfd-re) reverse-engineering
project's `LibEmperor/BagEntry.cs`:

```
Stereo       = 1
Uncompressed = 2
Is16Bit      = 4
Compressed   = 8
Unk          = 16  // present on most compressed voice lines; ebfd-re doesn't special-case it either
Mp3          = 32  // not observed in AUDIO.BAG
```

Exactly one of `Compressed`/`Uncompressed` is set per entry (never both,
never neither, per `ebfd-re`'s own validation).

## The compressed format (unresolved)

All compressed entries are 16-bit mono. The general shape everyone agrees on:
a 4-bit-nibble, adaptive-step delta codec resembling IMA-ADPCM — same 89-entry
step table and 8-entry index table as classic IMA/DVI4/`adpcm_ima_ws`, no
per-block header, single predictor/step-index pair carried across the whole
entry, nibbles read low-nibble-then-high-nibble per byte:

```gdscript
const STEP_TABLE = [7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31,
  34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173,
  190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724,
  796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499,
  2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630,
  9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623,
  27086, 29794, 32767]
const INDEX_TABLE = [-1, -1, -1, -1, 2, 4, 6, 8]

# per nibble:
step = STEP_TABLE[step_index]
delta = nibble & 7
diff = (step * (2*delta + 1)) / DIVISOR   # <-- the unresolved constant
predictor += (nibble & 8) ? -diff : diff
predictor = clamp(predictor, -32768, 32767)
step_index = clamp(step_index + INDEX_TABLE[delta], 0, 88)
```

**What's not resolved: `DIVISOR`, and/or something else entirely wrong that
just happens to produce audio-shaped output.** Every source that has looked
at this specific format admits the same failure:

- **Vladan Bato**, author of the 1998 `AUD2WAV`/`WAV2AUD`/`AUDINFO` utilities
  (found locally at `~/Downloads/AudioConverterV0.1/audwav/README.TXT`):
  classic Westwood `.aud` (a different, older container, C&C/Red Alert era)
  has two compression types. The common one is standard IMA-ADPCM (shift 3,
  i.e. `DIVISOR=8`) and his tools handle it. The other, used for 8-bit sounds
  like death screams, is "Westwood's proprietary compression and I don't know
  how it works" — he never cracked it, despite having contact with people who
  reverse-engineered the rest of the `.aud` format.
- **`ebfd-re`** (`github.com/IceReaper/ebfd-re`, `LibEmperor/BagEntry.cs`,
  commit `9004511`, message "Wav compression progress"): implements the exact
  decode shown above with `DIVISOR=16`. Its own README states: *"Audio: Mostly
  working, but compressed files have a continuous noise."* No issues/PRs
  discuss it further; the repo appears abandoned at that point.
- **`BagTool`** (the era-contemporary Windows tool, not decompiled — the user
  ran it directly): its own README states *"The format of 0x0C WAVE files
  (CMP) in Dialog.bag is still a mystery to me"* — `0x0C` = 12 =
  `Compressed | Is16Bit`, i.e. exactly this codec. It exports these entries
  as an unplayable `.CMP` file rather than a real WAV.

So three independent parties across ~25 years, one of them the tool
contemporary with the game, all failed to fully crack this same compressed
format. Treat that as a real difficulty signal, not a reason to assume the
current code is close.

## What was tried this session

### 1. Nibble/shift/sign parameter sweep (no ground truth)

Before any reference recording existed, candidates were judged only by
self-consistency (clip rate, lag-1 autocorrelation, total variation vs. the
known-good raw PCM entries). This is weak evidence — it can't distinguish "a
plausible-sounding wrong decode" from "correct". Tried and rejected on vibes
alone: `DIVISOR` of 8, 16, 32; nibble order swapped (high nibble first).
`DIVISOR=32` (shift 5) sounded subjectively "smoothest" to a human listener
but that's expected of *any* wrong divisor that's too large — it just damps
the signal into something quieter and less clippy without being correct.

### 2. Ground-truth capture via PipeWire loopback

The user recorded the game's actual audio output directly (`pw-record`/
`ffmpeg -f pulse` against the sink monitor, not the mic — the first attempt
via `pw-record --target <stream-id>` silently fell back to the mic instead of
linking the pulse-compat stream node, a known PipeWire gotcha), isolated with
all music/SFX muted in-game, for three named entries: `07-UM04`, `07-UM06`,
`07-US07` (all `Compressed | Is16Bit | Unk`, i.e. the same class as the
crackly `ATR*` lines).

Cross-correlating the decoded bag bytes against the resampled (48kHz→22050Hz
mono) reference, with a full grid search over `DIVISOR` (4–24) × nibble order
× sign inversion:

- Best and most consistent: `DIVISOR=8` (classic shift-3 IMA), low-nibble
  first, no sign inversion. Global normalized correlation ~0.18–0.33
  (z-scored signals, FFT cross-correlation), locally up to **~0.67** in a
  mid-clip window for `07-UM04` — a real, non-trivial signal, clearly not
  noise-floor (chance level ≈ 1/sqrt(N) ≈ 0.007 for N≈20000).
- `DIVISOR=16` (the `ebfd-re` value) and `DIVISOR=32`: correlation stayed at
  noise-floor levels (peaks of ~150–250 out of tens of thousands of samples,
  i.e. no real match) for all three files.
- A sliding-window local-correlation scan (window 1000 samples, hop 500)
  showed correlation rising from negative near the very start, up to ~0.67
  mid-clip, then decaying toward the end — not a clean monotonic decay
  (which would point to simple accumulating drift) nor a clean periodic
  sawtooth (which would point to a fixed-size block reset). No fixed-period
  structure was found: attempted `u16`- and `u32`-length-prefixed sub-chunk
  parsing of the raw bytes both failed within the first few chunks (implied
  chunk sizes ran past the buffer almost immediately), and a direct byte
  search for the classic Westwood `.aud` `0x0000DEAF` chunk magic found zero
  occurrences in any tested entry. So: no evidence of a periodic block-reset
  header: the current code's assumption of one continuous predictor/index
  pair per entry is still the best available structural model.

Based on this, `converters/bag/audio_bag.gd` was changed from `DIVISOR=16` to
`DIVISOR=8`.

### 3. Discovery: a separate "radio static" layer is mixed in at runtime

`assets/raw_original_content/SFX/AtreidesSFX.txt` lists `Static01i_vol1`/
`Static02i_vol1` (themselves `Compressed | Is16Bit`, *not* `Unk`-flagged)
alongside voice-line entries like `$07-US06`, i.e. the game plays a
radio-static sound **as a second, separately mixed layer** under
acknowledgement barks, not baked into the voice sample. The user's raw
capture confirmed this independently: it had an audible "radio on/off pshick"
at the very start and end of each captured line that is not present in (and
was never expected to be present in) the corresponding `AUDIO.BAG` entry's
own data. The user manually trimmed this out of the three reference `.wav`
files.

### 4. Re-running the correlation on the trimmed (hiss-free) reference

This should have made the comparison *cleaner*. Instead, correlation **got
worse** across the board (`07-UM04`: 0.33 → 0.21; `07-US07`: 0.18 → 0.10;
best divisor also shifted around between reruns: 8, 9, 10, 7 depending on
file). That is a bad sign for the `DIVISOR=8` conclusion from step 2: it
suggests the earlier, higher correlation numbers were partly an artifact of
matching against leftover silence/hiss padding in the untrimmed reference,
not a genuine lock onto the voice waveform. The honest reading right now is
**inconclusive**: `DIVISOR=8` is still the best available guess (it's at
least the documented behavior of *some* real Westwood IMA-ADPCM decoder
elsewhere in this codebase's ancestry), but it is not confirmed against
ground truth, and the audible crackle in `ATRMove1`/`ATRAttack1`/etc. is
real, reproducible, and unexplained.

### 5. Visual waveform comparison reveals discrete section structure

Comparing `07-UM04`'s reference waveform against the `DIVISOR=32` (shift 5)
decode side-by-side in an audio editor (shift 5 matched the reference's
overall amplitude scale best by eye, though it still crackles) showed the
reference as one smooth continuous envelope, while the decode is visibly
built from **at least 11 irregular-length sections**, each internally
resembling the reference's waveform shape but at its own distinct
scale/gain, and often vertically shifted (DC-offset) up or down relative to
neighboring sections. Section boundaries line up exactly with where the
audible clicks occur. This is a real, reproducible structural difference,
not a subjective loudness judgment.

Programmatic change-point detection (rolling mean/std over a 500-sample
window, on the shift-5 decode of `07-UM04`) found boundaries at samples
[1125, 2875, 4875, 7875, 11000, 15125] (byte offsets [562, 1437, 2437, 3937,
5500, 7562] into the entry's compressed data), roughly matching the times the
user marked by eye (0.139s/0.168s/0.232s/0.511s/0.697s — some of the user's
closely-spaced marks likely correspond to one detected boundary each,
detection granularity differs).

**Tested and refuted: resetting `predictor=0, step_index=0` at these exact
byte/nibble positions does not fix the discontinuity — it makes the jump
larger** in 5 of 6 tested boundaries (tried nibble-offsets -6..+6 around each
candidate byte to account for imprecise localization). So *if* there's a
real per-section re-sync in the bitstream, it encodes actual non-zero
predictor/step-index values (a real header), not a bare reset-to-zero. That
header's location and encoding were not identified this session — would need
searching for a plausible (predictor, step_index) pair that makes each
section's start continuous with the reference, then looking for those
specific values in the raw bytes near the boundary, rather than assuming a
constant reset value.

### 6. Ground truth: disassembling the real engine's decode routine

The user located the actual game install (`Game.exe`, a native x86 PE32
binary, not managed code — straightforward to disassemble with `objdump -d
-M intel`). Since `STEP_TABLE` (all 89 values, as `int32` little-endian) is a
distinctive constant, it was found byte-for-byte in `Game.exe` via a raw
binary search (`Game.exe` file offset `2106008` = VA `0x602298`, `.data`
section). The 16-entry `INDEX_TABLE` sits immediately before it at VA
`0x602278` (i.e. `0x602298 - 0x20`), values `[-1,-1,-1,-1,2,4,6,8,-1,-1,-1,
-1,2,4,6,8]` — exactly what this codebase already had.

`objdump` output was grepped for instructions referencing `0x602298` as an
addressing-mode immediate, which led straight to the per-nibble decode
function at VA `0x4a5a80` (called from a loop at `~0x4a5990`/`~0x4a591c`).
Hand-decompiled:

```
; eax = state* (predictor at +0, step_index at +4), edx = nibble (0-15)
ecx = state.step_index
esi = STEP_TABLE[ecx]                  ; step
ecx = esi >> 3                         ; diff = step >> 3
if nibble & 1: ecx += esi >> 2
if nibble & 2: ecx += esi >> 1
if nibble & 4: ecx += esi
if nibble & 8: ecx = -ecx              ; sign bit
state.predictor = clamp(state.predictor + ecx, -32768, 32767)
idx_delta = INDEX_TABLE[nibble]        ; full nibble 0-15 into the 16-entry table
state.step_index = clamp(state.step_index + idx_delta, 0, 88)
return (int16) state.predictor
```

This is **exactly** the decode already implemented (shift 3 / `>> 3`, sign =
bit 3, index table lookup — mathematically identical whether indexed by the
full nibble into 16 entries or `nibble & 7` into the duplicated first half).
So the per-nibble math was already bit-exact before this finding; what it
added was the missing piece — a header — found in the *caller* at
`~0x4a5860`-`0x4a58a4`:

```
for channel in 0..<channel_count:                 ; channel_count from state+0xb0
    predictor  = s16_le(input[0:2])                ; sign-extended
    step_index = u8(input[2])                      ; must be <= 88, else bail
    reserved   = u8(input[3])                       ; must be 0, else bail
    input += 4
    ; (unpacked into a per-channel state array, decoding proceeds after this loop)
```

So **every compressed entry begins with one 4-byte header per channel**:
`s16 LE` initial predictor, `u8` initial step_index, `u8` reserved(=0) — not
nibble data. This codebase's decoder was starting from `predictor=0,
step_index=0` unconditionally and decoding nibbles from byte 0, silently
treating the header's 4 bytes as if they were 8 more nibbles of audio. Some
test entries (`00-UA07`, `Static02i_vol1`, the three ground-truth captures)
happened to have an all-zero header, which is why they partially "worked" by
coincidence; entries with a non-zero header (`ATRAttack1`'s header decodes to
predictor=13, step_index=0, for example) were wrong from sample 0.

`converters/bag/audio_bag.gd` now reads this header and decodes the nibble
body starting from its predictor/step_index instead of `(0, 0)`. No
stereo-compressed entries exist in `AUDIO.BAG` today (checked: 0 entries have
both `Stereo` and `Compressed` set), so only the single-channel 4-byte header
case is implemented — the multi-channel per-channel-array unpacking seen in
the disassembly is not exercised and not implemented.

Re-running the change-point scan (same method as finding #5) on `ATRAttack1`
decoded with the header-corrected, disassembly-confirmed algorithm still
found ~6 discrete scale/DC jumps. **The user then actually listened to the
header-corrected output (`ATRAttack1_H_header_shift3.wav`,
`07-UM04/06/US07_H_header_shift3.wav`) against the reference captures: the
crackle and stepped waveform are still there, confirmed by ear, not just by
the change-point heuristic.** So this is a real, audible discrepancy, not a
false positive — and since the per-nibble math and initial state are now
disassembly-confirmed correct, the remaining bug must be upstream: either in
which bytes actually reach this decode function, or in a second decode path
this session didn't find yet (see #7 below).

### 7. A second, genuinely different codec exists in the binary — but doesn't fit `AUDIO.BAG`

The object constructor that wires up a sound for playback (around VA
`0x4a4a40`) dispatches on a `format type` field (0-3) read from a per-sound
descriptor, picking one of several decode function pointers. Format type 1
is the routine already covered above (`0x4a5810`/`0x4a5a80`). **Format type 2
points to a completely different function at `0x4a5b20`**, which is not an
IMA-style adaptive-delta codec at all — it's a linear predictor using two
`s16` coefficients plus a delta-scaled nibble term, with a 7-byte
per-channel block header (`coef_index: u8`, `delta: s16 LE`, two `s16 LE`
history samples). Pulling the two tables it indexes into directly from
`Game.exe`:

```
coefficient pairs (VA 0x5d1bfc, index 0-6): (256,0) (512,-256) (0,0) (192,64) (240,0) (460,-208) (392,-232)
adaptation table  (VA 0x5d30a4, 16 entries): 230 230 230 230 307 409 512 614 768 614 512 409 307 230 230 230
```

These are, byte-for-byte, the **standard Microsoft ADPCM** (`WAVE_FORMAT_ADPCM`)
coefficient and adaptation tables — a public, thoroughly documented codec
(same one ffmpeg's `ms_adpcm` decoder implements). Tried it directly against
the three ground-truth entries (`07-UM04/06/US07`, all `Compressed|16Bit|Unk`)
on the theory that the `Unk` flag selects this codec instead of format
type 1: it does not fit. `07-US07`'s first byte as a coefficient index reads
`0xFF` (invalid — only indices 0-6 exist), and the other two entries
correlate *worse* against the reference than the already-implemented format
type 1 decoder. So format type 2 (real MS-ADPCM) exists in the engine but
is not what encodes `AUDIO.BAG`'s compressed voice lines — it's presumably
used by a different `.bag` file. (`BagTool`'s README specifically complains
about `Dialog.bag`, not `AUDIO.BAG` — plausibly the same codec, in a file
this session didn't have.)

### 8. Traced the archive loader; didn't reach the flags→format-type mapping

Located the actual `AUDIO.BAG` file-opening code by searching for the
`"GABA"` magic string directly in `Game.exe` (file offset 467396, VA
`0x4721c4` region): confirmed it validates magic, version(4), and
stride(0x40=64) exactly as this codebase's parser does, then builds the
entry table and a name-lookup hash index. This is the archive/table loader
only — it stores each entry's raw flags in the table but doesn't interpret
them. The code that reads a *specific* entry's flags and decides format
type 0-3 (the thing that would settle finding #7 conclusively — does `Unk`
actually select format type 1 or something else?) lives in a separate
"open sound for playback" path behind several virtual calls not yet
located. Tracing further was judged not worth the time this session; see
the summary status at the top of this document.

### 9. SOLVED: the flags→format-type mapping, and the per-entry block size

Finishing the trace that #8 left off: the function at VA `0x472520` in
`Game.exe` is `get_entry_descriptor(bag, index, out)` — it looks up the
64-byte table row (`index << 6`, or via the name-hash index at `bag+0x814`)
and converts it into the descriptor the decoder constructor at `0x4a4a40`
consumes:

```
out+0x00 = 4                                  ; descriptor tag/size?
out+0x04 = format type:
             flags & 0x08 (Compressed) -> 1   ; the IMA-style codec (0x4a5810/0x4a5a80)
             else flags & 0x40         -> 2   ; MS-ADPCM (0x4a5b20) — flag not present in AUDIO.BAG
             else flags & 0x20 (Mp3)   -> 3
             else                      -> 0   ; raw PCM
out+0x08 = entry.sample_rate  (entry+0x28)
out+0x0c = (flags & 1) ? 2 : 1                ; channels
out+0x10 = bytes per sample (2 if 16-bit/compressed/mp3 else 1)
out+0x18..0x27 = entry bytes +0x30..+0x3f     ; the 16 "padding" tail bytes, copied verbatim
```

This settles finding #7's open question: **`Compressed` (bit 3) alone selects
format type 1; the `Unk` flag (bit 4) plays no part in codec selection**, and
format type 2 (MS-ADPCM) is selected by flag bit 6 (0x40), which no
AUDIO.BAG entry has.

The real discovery is the last line: the 16 tail bytes of each 64-byte
table row — which this codebase's parser had been ignoring as padding — are
copied into the descriptor, and the decoder constructor reads the first of
them (`desc+0x18`) as its per-block buffer size (`obj+0xb8`, with
`size*4+0x80` allocated at `obj+0xac`). In the shipped AUDIO.BAG, that
first tail u32 is 512 for every compressed entry except 11 (`47-UA*`,
which use 1024) and 0 for every non-compressed entry.

**The compressed stream is therefore a sequence of `block_size`-byte blocks,
each beginning with its own 4-byte header** (the same `s16 predictor / u8
step_index / u8 reserved=0` layout finding #6 found — the engine re-runs
that header read per block, not once per entry). Verified structurally:
across all 674 compressed entries, all 17016 blocks have `step_index <= 88`
and `reserved == 0` (16284 of them with non-zero initial state); random
misaligned data would fail the `reserved == 0` check with probability
255/256 per block, so this cannot be coincidence. This also explains every
prior symptom: the ~11 "sections at their own scale/DC offset" in finding
#5 were runs of blocks decoded from stale state, the clicks were block
boundaries, resetting to `(0,0)` at boundaries (tested in #5) failed
because the real headers carry non-zero values, and the three ground-truth
entries partially matched with `DIVISOR=8` because their *first* block's
header happened to be all-zero.

One more correction found while porting: the engine computes
`diff = (step>>3) + (step>>2 if bit0) + (step>>1 if bit1) + (step if bit2)`
with each term truncated separately; the algebraically equivalent-looking
`((2*delta+1)*step) >> 3` the old code used is **not** bit-identical (e.g.
`step=7, delta=1`: 2 vs 1). The decoder now uses the exact shift-add form.

`converters/bag/audio_bag.gd` reads the block size from entry offset +48
and decodes per-block; all 945 entries convert cleanly
(`make godot-convert-audio`), and the GDScript output was verified
byte-identical to an independent Python re-implementation of the same
algorithm.

## Where things stand / what would actually move this forward (historical — superseded by #9)

The single most direct next step: finish tracing from the archive loader
(#8) to wherever a specific entry's `flags` get turned into the `format
type` value the constructor at `0x4a4a40` switches on, in `Game.exe`. That
would settle, with certainty, whether `AUDIO.BAG`'s `Unk`-flagged
(`Compressed|16Bit|Unk` = `28`) entries actually use format type 1 (the
decoder implemented here, now disassembly-confirmed bit-exact) or something
else. If it confirms format type 1, the bug is genuinely upstream of
decoding (wrong bytes reaching the routine, e.g. an off-by-N in how this
codebase locates the entry's data or an extra layer of buffering the real
engine has that this session didn't reproduce) — in which case the dynamic
route below becomes the more promising path, since static tracing clearly
hasn't been enough on its own.

Also worth doing:
- **Dynamic tracing instead of static**: run `Game.exe` under Wine with a
  debugger (`winedbg`, or `x64dbg`/`gdb` via Wine's debug support) and set a
  breakpoint directly at the now-known decode function address (`0x4a5a80`,
  or the format-type-2 one at `0x4a5b20`) while playing an `ATR*` voice line
  in-game. This sidesteps the whole "which format type gets selected, and
  from where" question — the breakpoint hit (or not) settles it directly,
  and the register/memory state at that point gives the real predictor,
  step_index, and input pointer for comparison against what this codebase
  computes for the same entry.
- More ground-truth samples (especially longer ones, and specifically some
  of the `ATR*`/`00-U*` files already discussed here) would make any future
  correlation-based check meaningfully more reliable — three short clips
  wasn't enough to separate real signal from alignment noise, per finding
  #4.
- The reference `.wav` files used for correlation (`07-UM04.wav`,
  `07-UM06.wav`, `07-US07.wav`, trimmed) are in `assets/` — not committed
  anywhere permanent, worth moving somewhere durable if this investigation
  continues later.
- If someone else's format-type-1 decode disagrees with this one on a
  concrete test vector, or a working reference decoder for `AUDIO.BAG`
  specifically ever surfaces, that trumps everything above — but per
  findings #1-#8, nothing found this session (public tools, other RE
  projects, nor the shipped binary's own tables) contradicts the current
  implementation; the crackle remains real and unexplained regardless.
