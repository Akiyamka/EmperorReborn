class_name InfantryDeathStrategy
extends UnitDeathStrategy

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
## - `Blow_Up` has no per-house hook at all — the only "exploding person"
##   sound the source models is the same `[explode]` family vehicles use, and
##   there is no man-scream hook for a physical blow-up. So Blow_Up always
##   resolves to the generic `explode` id regardless of faction.
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
	&"Blow_Up": {"stem": "", "generic": &"explode"},
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


## Ordered candidates, per-house hook first (when the faction has one and the
## cause has a per-house stem at all) then the generic fallback. `Unit`
## resolves this against the generated `DEATH_EVENT_PATHS` and plays the
## first id that actually exists — see `unit_death_strategy.gd` for why a
## list is needed instead of one composed id.
func death_sound_event_id(cause: StringName, faction: StringName) -> Array[StringName]:
	var family: Dictionary = CAUSE_SOUND_FAMILIES.get(cause, {
		"stem": DEFAULT_SOUND_STEM,
		"generic": DEFAULT_SOUND_GENERIC,
	})
	var stem: String = family.get("stem", "")
	var prefix: String = HOUSE_SOUND_PREFIXES.get(faction, "")
	var result: Array[StringName] = []
	if not stem.is_empty() and not prefix.is_empty():
		result.append(StringName(prefix + stem))
	result.append(family.get("generic", &""))
	return result


func death_launch_impulse(cause: StringName) -> Vector3:
	if cause == &"Blow_Up":
		return BLOW_UP_LAUNCH_IMPULSE
	# Shot/Burn/Gassed clips are authored in place; the body must not drift
	# even if it was mid-stride the instant it died.
	return Vector3.ZERO
