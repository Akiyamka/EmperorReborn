class_name FireRequest
extends RefCounted

## One request for a turret to shoot: what at, on whose behalf, and under which
## of the gates a shot normally has to pass.
##
## The gates used to be four trailing boolean/scalar parameters, which made the
## one call site that changes them read as
## `try_fire_at(target, source, null, Vector3.ZERO, false, false, true, scale)`
## -- unreadable in place, and impossible to change safely. Each is now named
## where it is set.
##
## Every field has the value an ordinary shot wants, so the common case is one
## call to at().

## An entity to shoot at, or a Vector3 ground position.
var target: Variant = null
## Who is shooting. Used to exclude the shooter's own collision shapes from the
## projectile's path; defaults to the turret's model root when left null.
var source: Object = null
## Where the projectile node is added. Defaults to the shooter's scene root.
var projectile_parent: Node = null
## Applied to the aim point, not to the muzzle: lets a caller shoot at a
## deliberate offset from the target's own aim position.
var aim_offset := Vector3.ZERO

## Whether landing this shot starts the reload timer. False when something else
## owns the weapon's rhythm -- an authored fire clip reloads at the end of the
## whole sequence, not per shot.
var begin_reload_after_shot := true
## Whether the turret must already be aimed. False when the shot's timing comes
## from an animation, which fires on its authored event regardless of where the
## servo-driven aim currently points.
var require_aim := true
## Whether the weapon is already committed to firing, which skips the readiness
## gate. Set for shots emitted from inside a running fire sequence: the sequence
## passed that gate when it started.
var committed_sequence := false
## Multiplies the payload's damage. Veterancy and per-sequence falloff use it.
var damage_scale := 1.0


## An ordinary shot: every gate applies.
static func at(
	fire_target: Variant,
	fire_source: Object = null,
	parent: Node = null,
	offset := Vector3.ZERO
) -> FireRequest:
	var request := FireRequest.new()
	request.target = fire_target
	request.source = fire_source
	request.projectile_parent = parent
	request.aim_offset = offset
	return request


## A shot emitted from an authored Fire clip's shot event. The animation owns
## the timing, the aim and the reload, so all three gates belong to the sequence
## rather than to this call.
static func authored(
	fire_target: Variant, fire_source: Object, scale := 1.0
) -> FireRequest:
	var request := at(fire_target, fire_source)
	request.begin_reload_after_shot = false
	request.require_aim = false
	request.committed_sequence = true
	request.damage_scale = scale
	return request
