class_name DamagePolicy
extends RefCounted

## The shield/health arithmetic shared by Unit.take_damage() and
## Building.take_damage(). Deliberately stateless: the canonical health/shields
## live as @export fields on the entity, whose setters run entity-specific side
## effects (health_changed, power recompute, damage-state visuals, shield mesh
## visibility). This resolves *how much* to subtract; the caller applies it
## through its own setters and decides what a lethal result means.


## Fixed-shape result. A declared class rather than a Dictionary so a typo in a
## field name is diagnosed instead of silently reading null.
class Result extends RefCounted:
	var absorbed_by_shields := 0.0
	var health_delta := 0.0
	var is_lethal := false


static func resolve(
	amount: float, health: float, shields: float, invulnerable: bool
) -> Result:
	var result := Result.new()
	if invulnerable or amount <= 0.0 or health <= 0.0:
		return result

	var remaining_damage := amount
	if shields > 0.0:
		result.absorbed_by_shields = minf(shields, remaining_damage)
		remaining_damage -= result.absorbed_by_shields
	if remaining_damage <= 0.0:
		return result

	result.health_delta = -remaining_damage
	result.is_lethal = health + result.health_delta <= 0.0
	return result
