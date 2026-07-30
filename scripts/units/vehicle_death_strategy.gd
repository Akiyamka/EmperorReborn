class_name VehicleDeathStrategy
extends UnitDeathStrategy

## Death policy for every non-infantry unit (ground vehicles, mechs,
## aircraft): converted vehicle models carry exactly one death clip,
## `Explode`, regardless of the incoming damage type.

const CANDIDATES: Array[StringName] = [&"Explode"]
const SOUND_ID := &"explode"


func death_animation_candidates(_cause: StringName, _deployed: bool) -> Array[StringName]:
	return CANDIDATES.duplicate()


func death_sound_event_id(_cause: StringName, _faction: StringName) -> Array[StringName]:
	return [SOUND_ID]


## Always zero: the Explode clip is too short for added motion to read, and
## momentum for a flying unit's corpse comes from Unit inheriting velocity
## unconditionally for can_fly units, not from an impulse here (see
## Unit._begin_death_sequence).
func death_launch_impulse(_cause: StringName) -> Vector3:
	return Vector3.ZERO
