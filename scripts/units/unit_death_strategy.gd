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


## Candidate sound layers for this death, as a list of *layers*, each layer
## itself an ordered candidate list, most-preferred first. Within one layer
## the candidates are a *fallback* chain, not extra sounds: the caller (Unit)
## resolves each layer against the generated
## `GeneratedVoiceManifest.DEATH_EVENT_PATHS` and keeps only the first id
## actually present, since e.g. Burn's per-house `atburningmandying` and its
## generic `BurningSmall` are two spellings of one sound, not two.
##
## This is the *manifest-backed* hook system (real, grep/listening-confirmed
## per-house dying/burning/choking hooks) and is now infantry-only. Vehicle
## death explosions no longer go through this at all — see
## `death_vfx_sound_paths()`/`death_start_sound_paths()` below and
## docs/quirks.md for why: the vehicle "personal death hook" this method used
## to also carry for `VehicleDeathStrategy` turned out not to correspond to
## anything real once tested against the reference build.
func death_sound_event_layers(
		_cause: StringName, _faction: StringName, _config_id: StringName
	) -> Array:
	return []


## Direct WAV paths (bypassing SoundEvent/GeneratedVoiceManifest entirely —
## see ExplosionTierPools) for the sound tied to the *visual* explosion
## moment: for vehicles this is `Unit._spawn_death_explosion_effects()`
## firing, not corpse/clip-start. One random pick from the returned pool
## plays once per death; an empty array means no such layer for this unit.
## Base default is empty: only `VehicleDeathStrategy` overrides this today.
func death_vfx_sound_paths(_config_id: StringName) -> Array[String]:
	return []


## Direct WAV paths for the sound played immediately at corpse/clip-spawn
## time, independent of `death_vfx_sound_paths()`'s VFX-spawn timing. Used
## for two unrelated, unconditional layers: every Harkonnen/Ordos vehicle's
## faction explosion layer (`VehicleDeathStrategy`), and `HKFlamer`'s
## always-on fuel-tank boom (`InfantryDeathStrategy`) — both are "just play
## this immediately, no timing dependency on anything else." Base default is
## empty.
func death_start_sound_paths(_faction: StringName, _config_id: StringName) -> Array[String]:
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
