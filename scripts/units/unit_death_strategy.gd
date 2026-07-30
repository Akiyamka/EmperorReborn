class_name UnitDeathStrategy
extends RefCounted

## Pure policy object consulted once, synchronously, by
## `Unit._begin_death_sequence()` before the unit is freed. Mirrors
## `CombatDeployStrategy`: a plain `RefCounted` that only maps data to data and
## never touches nodes, so it can be unit-tested with no scene setup at all.
## Subclasses are duck-typed against these three methods, not against this
## base class's (deliberately empty) defaults — a config with no clips at all
## degrades to "no candidates, no sound, no impulse" rather than an error.

## Candidate clip names for the given death cause, most-preferred first. The
## caller (Unit) owns the final has_animation() scan against its own
## AnimationPlayers; this only proposes names, since only the caller knows
## which player, if any, actually carries a given clip.
func death_animation_candidates(_cause: StringName, _deployed: bool) -> Array[StringName]:
	return []


## Ordered candidate sound-event ids for the given cause/faction pair, most-
## preferred first (e.g. a per-house hook before the generic fallback). The
## caller (Unit) resolves this against the generated
## `GeneratedVoiceManifest.DEATH_EVENT_PATHS` and picks the first id actually
## present, then hands that single resolved id to `DeathCorpse`. A list
## rather than one composed id because the per-house hook's stem does not
## always match the generic hook's stem (e.g. Burn's per-house
## `atburningmandying` vs. the generic `BurningSmall`), so a single string
## template cannot express the fallback.
func death_sound_event_id(_cause: StringName, _faction: StringName) -> Array[StringName]:
	return []


## Extra world-space velocity added on top of momentum the corpse already
## inherits from the dying unit's motion. `Vector3.ZERO` means "no physics at
## all for this cause" (see `Unit._begin_death_sequence` and
## `DeathCorpse.spawn()` for how that collapses inherited momentum too, not
## just this impulse).
func death_launch_impulse(_cause: StringName) -> Vector3:
	return Vector3.ZERO


## Shared "pick one variant" helper: death clip families (Blow_Up_1/2, the
## deployed-death pair, ...) read as repetitive if the first-listed variant
## always won the caller's first-match scan. Shuffling the candidate order
## here — rather than always returning candidates in a fixed order — spreads
## the caller's deterministic "first player owning one of these" scan over
## every authored variant. Mirrors the random-variant idiom `Unit` already
## uses for idle animations (`_play_random_idle`/`_idle_animations`).
## Untyped Array in/out deliberately: CANDIDATES.get(cause, []) on a plain
## Dictionary literal returns an untyped Array, and Godot 4 refuses to pass
## that into a statically Array[StringName]-typed parameter even when every
## element is a StringName. Callers that need a typed result append the
## (untyped) elements back into their own Array[StringName].
func _shuffled(candidates: Array) -> Array:
	var result := candidates.duplicate()
	result.shuffle()
	return result
