class_name VehicleDeathStrategy
extends UnitDeathStrategy

## Death policy for every non-infantry unit (ground vehicles, mechs,
## aircraft): converted vehicle models carry exactly one death clip,
## `Explode`, regardless of the incoming damage type.

const ExplosionTierPools := preload("res://scripts/audio/explosion_tier_pools.gd")

const CANDIDATES: Array[StringName] = [&"Explode"]

## Size-tier overrides, user-specified from listening tests against the
## reference build (see docs/quirks.md for the falsified "personal death
## hook" design this replaced). Everything not listed here defaults to
## `medium` (DEFAULT_TIER) — an approximation, not sourced data: the
## per-unit tier was hardcoded in the original engine's binary and left no
## trace in any available asset (in particular `explosion_type_id`, the
## visual VFX bank, does not correlate with it at all — `HKDevastator` and
## `ATMongoose` share the same generic `Explosion` bank).
const TIER_OVERRIDES := {
	# Harkonnen: every vehicle is medium except HKDevastator.
	&"HKDevastator": &"large",
	# Atreides: ATTrike/ATAPC are small, ATMinotaurus is large, everything
	# else Atreides defaults to medium.
	&"ATTrike": &"small",
	&"ATAPC": &"small",
	&"ATMinotaurus": &"large",
	# Ordos: ORDustScout is small, ORKobra is large, everything else Ordos
	# defaults to medium.
	&"ORDustScout": &"small",
	&"ORKobra": &"large",
	# Shared/cross-faction units (not owned by AT/HK/OR at all — house_id is
	# NULL for the harvesters, 7/Guild for GUNIABTank):
	&"Harvester": &"large",
	&"FakeHarvester": &"large",
	&"GUNIABTank": &"large",
}
const DEFAULT_TIER := &"medium"


func death_animation_candidates(_cause: StringName, _deployed: bool) -> Array[StringName]:
	return CANDIDATES.duplicate()


## Vehicle death explosions carry no manifest-backed sound layer at all
## today (see UnitDeathStrategy.death_sound_event_layers docstring) — the
## size-tier and faction layers below replace it entirely.
func death_sound_event_layers(
		_cause: StringName, _faction: StringName, _config_id: StringName
	) -> Array:
	return []


## The size-tier boom, timed by the caller to `_spawn_death_explosion_effects`
## firing rather than corpse/clip start.
func death_vfx_sound_paths(config_id: StringName) -> Array[String]:
	var tier: StringName = TIER_OVERRIDES.get(config_id, DEFAULT_TIER)
	return ExplosionTierPools.pool_for_tier(tier)


## Every Harkonnen vehicle gets an extra explosion_vehicle_* layer, every
## Ordos vehicle gets an extra explosionordos* layer, both unconditional and
## on top of whatever the size tier resolved to above. Driven by house_id
## (via `faction`, e.g. "Harkonnen"/"Ordos") rather than a hardcoded per-unit
## list, since this is true of every vehicle in those houses, not a handful
## of named exceptions. Atreides and every other faction get no extra layer.
func death_start_sound_paths(faction: StringName, _config_id: StringName) -> Array[String]:
	match faction:
		&"Harkonnen":
			return ExplosionTierPools.HARKONNEN_START.duplicate()
		&"Ordos":
			return ExplosionTierPools.ORDOS_START.duplicate()
		_:
			return []


## Always zero: the Explode clip is too short for added motion to read, and
## momentum for a flying unit's corpse comes from Unit inheriting velocity
## unconditionally for can_fly units, not from an impulse here (see
## Unit._begin_death_sequence).
func death_launch_impulse(_cause: StringName) -> Vector3:
	return Vector3.ZERO
