class_name UpgradeEffects
extends RefCounted

## docs/mechanics/production.md section 4/5: a global per-type upgrade
## purchase is player state, not building state ("upgrades are irreversible
## ... the purchased state belongs to the player, not the building"). Every
## Building instance still carries its own upgrade_level (technology_tree.gd
## reads it directly off owned instances), so buying the upgrade has to push
## the new level onto every currently-owned building of that type right now;
## future instances of that type pick the level up themselves on placement
## via Building._sync_purchased_upgrade() reading PlayerData.

const UPGRADED_LEVEL := 1


static func apply_to_existing_buildings(buildings: Array, player_id: int, building_id: StringName) -> void:
	for building in buildings:
		if not is_instance_valid(building):
			continue
		if int(building.get("owner_player_id")) != player_id:
			continue
		if StringName(String(building.get("config_id"))) != building_id:
			continue
		if building.has_method("set_upgrade_level"):
			building.call("set_upgrade_level", UPGRADED_LEVEL)
