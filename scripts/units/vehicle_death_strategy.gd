class_name VehicleDeathStrategy
extends UnitDeathStrategy

## Death policy for every non-infantry unit (ground vehicles, mechs,
## aircraft): converted vehicle models carry exactly one death clip,
## `Explode`, regardless of the incoming damage type.

const CANDIDATES: Array[StringName] = [&"Explode"]

## Personal death hooks: sections in HarkonnenSFX.txt whose name was renamed
## away from a per-unit label that survives as a commented-out line directly
## above it (`;dko[HarkAssaultTankDie]` above `[hkmedium1]`, and so on). `explode`
## is one of these — it is `HarkDevastatorDie`, *not* a generic explosion id,
## which is why it must never be handed to an arbitrary vehicle or to infantry.
## Grep-confirmed exhaustive: no equivalent pattern exists in AtreidesSFX.txt or
## ORDOSSFX.TXT (Ordos's similarly-named ormedium1/ormedium2 are the pop-up
## turret's own explosion, not a vehicle-death hook). See docs/quirks.md.
const PERSONAL_DEATH_HOOKS := {
	&"HKAssault": &"hkmedium1",
	&"HKInkVine": &"hkmedium2",
	&"HKBuzzsaw": &"hksmall1",
	&"HKDevastator": &"explode",
}

## The second, independent layer: GeneralSFX.txt's generic size-tiered
## [Small]/[Medium]/[Large] families, commented as firing "when small/medium/
## large vehicles are destroyed". A unit with a personal hook plays *both*
## (user-confirmed: HKAssault/HKInkVine/HKBuzzsaw are heard booming twice).
##
## The per-unit tier itself was hardcoded in the original engine's binary and
## left no trace in the source data beyond comments naming a handful of units —
## in particular `explosion_type_id` (the visual VFX bank) does not correlate
## with it at all (HKDevastator and ATMongoose share the same generic
## `Explosion` bank). So everything not listed here falls back to `medium`, an
## approximation, not sourced data. ATMongoose is deliberately absent despite a
## GeneralSFX.txt comment naming it a "Small" example: the user hears it play
## the medium family in the reference build, and the live observation wins.
const TIER_OVERRIDES := {
	&"ATTrike": &"small",
	&"ORDustScout": &"small",
	&"HKDevastator": &"large",
}
const DEFAULT_TIER := &"medium"


func death_animation_candidates(_cause: StringName, _deployed: bool) -> Array[StringName]:
	return CANDIDATES.duplicate()


## Two concurrent layers for the handful of units that have a personal hook,
## one (the size tier) for everyone else. Each layer is a single-candidate
## list: vehicle hooks have no per-house fallback spelling the way infantry
## dying hooks do.
func death_sound_event_layers(
		_cause: StringName, _faction: StringName, config_id: StringName
	) -> Array:
	var layers: Array = []
	var personal: StringName = PERSONAL_DEATH_HOOKS.get(config_id, &"")
	var tier: StringName = TIER_OVERRIDES.get(config_id, DEFAULT_TIER)
	if personal != &"":
		layers.append([personal] as Array[StringName])
	if tier != personal:
		layers.append([tier] as Array[StringName])
	return layers


## Always zero: the Explode clip is too short for added motion to read, and
## momentum for a flying unit's corpse comes from Unit inheriting velocity
## unconditionally for can_fly units, not from an impulse here (see
## Unit._begin_death_sequence).
func death_launch_impulse(_cause: StringName) -> Vector3:
	return Vector3.ZERO
