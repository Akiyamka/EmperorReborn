class_name InfantryDeathStrategy
extends UnitDeathStrategy

const ExplosionTierPools := preload("res://scripts/audio/explosion_tier_pools.gd")

## Death policy for `unit_definition.infantry` units. Clip families mirror the
## converted model content directly (`Blow_Up_1/2`, `Shot_1/2`, `Gassed_1`,
## `Burnt_1`, `Run_Over_1`, `Deployed_Death_1/2`) and the flags come from
## `CombatBullet.death_category()`.
##
## The dying scream is not chosen here: whichever clip below wins the caller's
## has_animation() scan, `UnitDeathSequence` reads that clip's authored FX
## events off the model itself (scripts/units/authored_death_voice.gd). That is
## how TL_Contaminator ends up screaming `contaminator_die_*` and INFemaleCiv
## `female_death_*` without a per-unit branch anywhere in this file.

const CANDIDATES := {
	&"Blow_Up": [&"Blow_Up_1", &"Blow_Up_2"],
	&"Burn": [&"Burnt_1"],
	## Dormant: nothing produces this cause yet. Crushing is declared in the
	## rules (`UnitDefinition.crushable`/`crushes`) but not implemented, and
	## `CombatBullet.death_category()` has no crush flag because a crush is not
	## a bullet. The clip and its authored `crush_guy_*` scream are wired and
	## covered by tests so that landing the gameplay is a one-line call into
	## `take_damage(..., &"Crush")`.
	&"Crush": [&"Run_Over_1"],
	&"Gassed": [&"Gassed_1"],
	&"Shot": [&"Shot_1", &"Shot_2"],
}
const DEPLOYED_CANDIDATES: Array[StringName] = [&"Deployed_Death_1", &"Deployed_Death_2"]

## Hand-tuned gameplay value, not derived from Rules.txt: infantry speed alone
## (ATInfantry.tres: speed = 6) reads as horizontal sliding rather than a body
## being thrown, so Blow_Up adds a positive-Y kick on top of inherited
## momentum. Also the natural extension point for a future explosion
## knockback impulse (direction from detonation point to victim).
const BLOW_UP_LAUNCH_IMPULSE := Vector3(0.0, 6.0, 0.0)


func death_animation_candidates(cause: StringName, deployed: bool) -> Array[StringName]:
	var result: Array[StringName] = []
	if deployed:
		for candidate in _shuffled(DEPLOYED_CANDIDATES):
			result.append(candidate)
	for candidate in _shuffled(CANDIDATES.get(cause, [])):
		result.append(candidate)
	return result


## `HKFlamer` always emits a `small`-tier boom no matter what killed it,
## because its own fuel tank ruptures as part of dying. Its converted model
## carries only the ordinary infantry clip set (no bespoke "tank explodes"
## clip), so the correct per-cause clip and its authored voice still play
## unchanged — this is purely an extra, unconditional sound
## layer, not a forced Blow_Up cause. Scoped to this one unit: no equivalent
## hook or comment exists for any other infantry. Plays immediately (no
## VFX-spawn timing to hook into: infantry has no separate explosion-effect
## call site the way vehicles do via `_spawn_death_explosion_effects`, and
## `HKFlamer.explosion_type_id` is already `None`), same direct-WAV pool
## system vehicles use for their size tiers (ExplosionTierPools) rather than
## the manifest — user-confirmed: play it immediately, no artificial delay/
## sync attempt.
const SELF_DESTRUCT_SOUND_UNITS := {
	&"HKFlamer": &"small",
}


func death_start_sound_paths(_faction: StringName, config_id: StringName) -> Array[String]:
	var tier: StringName = SELF_DESTRUCT_SOUND_UNITS.get(config_id, &"")
	if tier == &"":
		return []
	return ExplosionTierPools.pool_for_tier(tier)


func death_launch_impulse(cause: StringName) -> Vector3:
	if cause == &"Blow_Up":
		return BLOW_UP_LAUNCH_IMPULSE
	# Shot/Burn/Gassed/Crush clips are authored in place; the body must not
	# drift even if it was mid-stride the instant it died.
	return Vector3.ZERO
