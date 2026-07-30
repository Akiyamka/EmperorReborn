class_name InfantryDeathStrategy
extends UnitDeathStrategy

const ExplosionTierPools := preload("res://scripts/audio/explosion_tier_pools.gd")

## Death policy for `unit_definition.infantry` units. Clip families mirror the
## converted model content directly (`Blow_Up_1/2`, `Shot_1/2`, `Gassed_1`,
## `Burnt_1`, `Deployed_Death_1/2`) and the flags come from
## `CombatBullet.death_category()`.

const CANDIDATES := {
	&"Blow_Up": [&"Blow_Up_1", &"Blow_Up_2"],
	&"Burn": [&"Burnt_1"],
	&"Gassed": [&"Gassed_1"],
	&"Shot": [&"Shot_1", &"Shot_2"],
}
const DEPLOYED_CANDIDATES: Array[StringName] = [&"Deployed_Death_1", &"Deployed_Death_2"]

## Confirmed sections in assets/raw_original_content/SFX/*.txt (grepped
## directly, not trusted from an earlier draft of this plan):
##
## - `Blow_Up` has **no corpse-level sound at all**, per-house or generic:
##   `Blow_Up_1/2` is purely a "corpse gets launched by an explosion"
##   animation, and the boom the player hears belongs to the weapon that
##   detonated, which is a separate system (combat_impact_resolver.gd /
##   combat_projectile.gd, no SFX wiring yet). Giving the corpse its own boom
##   would double it up once weapon-impact SFX lands. The `[explode]` family it
##   used to borrow is not generic anyway — it is HarkDevastatorDie, one
##   vehicle's personal hook (see vehicle_death_strategy.gd, docs/quirks.md).
## - `Shot`/unmapped causes fall back to the `*normalmandying` family: the
##   generic `[NormalManDying]` hook plus per-faction `[atnormalmandying]`/
##   `[hknormalmandying]`/`[ORNORMALMANDYING]` variants.
## - `Burn` has a *different* per-house stem than its generic fallback:
##   `[atburningmandying]`/`[hkburningmandying]`/`[ORBURNINGMANDYING]` vs. the
##   generic `[BurningSmall]` — the per-house id cannot be derived by
##   prefixing the generic one.
## - `Gassed` maps to the **choking** family, not `normalmandying`:
##   `[Choking]`/`[atchoking]`/`[hkchoking]`/`[orchoking]` exist, and
##   GeneralSFX.txt states outright that these fire whenever infantry are hit
##   with poisonous gas. Its per-house stem happens to equal its generic id
##   ("choking" either way).
##
## The per-unit-hook tier the eventual generator supports (e.g.
## `[SardaukarDying]`) needs a unit id this strategy is not handed today, so
## composition here stops at the faction tier; wiring a per-unit hook in
## later is additive, not a rework.
const CAUSE_SOUND_FAMILIES := {
	&"Blow_Up": {"stem": "", "generic": &""},
	&"Burn": {"stem": "burningmandying", "generic": &"burningsmall"},
	&"Gassed": {"stem": "choking", "generic": &"choking"},
}
const DEFAULT_SOUND_STEM := "normalmandying"
const DEFAULT_SOUND_GENERIC := &"normalmandying"

## house_id (PlayerData) carries the full house name ("Atreides", "Harkonnen",
## "Ordos", ...), but the SFX section prefixes are two-letter codes and only
## exist for these three houses — grep-confirmed exhaustive across every
## assets/raw_original_content/SFX/*.txt file (searched for
## *normalmandying/*burningmandying/*dicedmandying in every casing): only
## at/hk/or prefixed sections exist. Fremen/Guild/Imperial/Ix/Tleilaxu/
## Incidental have no per-house dying hook at all, so they — and any other
## unmapped house_id — fall back to the generic, unprefixed hook.
const HOUSE_SOUND_PREFIXES := {
	&"Atreides": "at",
	&"Harkonnen": "hk",
	&"Ordos": "or",
}

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


## One layer for the cause itself — per-house hook first (when the faction has
## one and the cause has a per-house stem at all), then the generic fallback,
## the two being alternative spellings of the same sound, so `Unit` plays only
## the first that resolves. `Blow_Up` contributes no layer at all (see above).
func death_sound_event_layers(
		cause: StringName, faction: StringName, _config_id: StringName
	) -> Array:
	var family: Dictionary = CAUSE_SOUND_FAMILIES.get(cause, {
		"stem": DEFAULT_SOUND_STEM,
		"generic": DEFAULT_SOUND_GENERIC,
	})
	var stem: String = family.get("stem", "")
	var prefix: String = HOUSE_SOUND_PREFIXES.get(faction, "")
	var generic: StringName = family.get("generic", &"")
	var cause_layer: Array[StringName] = []
	if not stem.is_empty() and not prefix.is_empty():
		cause_layer.append(StringName(prefix + stem))
	if generic != &"":
		cause_layer.append(generic)

	var layers: Array = []
	if not cause_layer.is_empty():
		layers.append(cause_layer)
	return layers


## `HKFlamer` always emits a `small`-tier boom no matter what killed it,
## because its own fuel tank ruptures as part of dying. Its converted model
## carries only the ordinary infantry clip set (no bespoke "tank explodes"
## clip), so the correct per-cause clip and sound (death_sound_event_layers
## above) still play unchanged — this is purely an extra, unconditional sound
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
	# Shot/Burn/Gassed clips are authored in place; the body must not drift
	# even if it was mid-stride the instant it died.
	return Vector3.ZERO
