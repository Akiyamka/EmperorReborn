class_name PlayerData
extends Resource

signal resources_changed(player_id: int, money: int, energy: int)

const NEUTRAL_PLAYER_ID := -1
const NO_TEAM_ID := -1

enum Relation {
	NEUTRAL,
	ALLY,
	ENEMY,
}

@export var player_id := NEUTRAL_PLAYER_ID
@export var nickname := "Neutral"
@export var team_color := Color(0.7, 0.7, 0.7)
@export var house_id: StringName = &""
@export var subhouse_ids: Array[StringName] = []
@export var team_id := NO_TEAM_ID
@export var is_neutral := true
@export var money := 0:
	set(value):
		var clamped := maxi(value, 0)
		if money == clamped:
			return
		money = clamped
		resources_changed.emit(player_id, money, energy)
@export var energy := 0:
	set(value):
		if energy == value:
			return
		energy = value
		resources_changed.emit(player_id, money, energy)

## docs/mechanics/production.md section 4/5: a global per-type upgrade is
## purchased once and is irreversible -- it belongs to the player, not to any
## one building instance, and is not lost when every building of that type
## is destroyed. Keyed by building_id (config_id). Not @export: this is
## runtime match state, not designer-configurable player data.
var _purchased_upgrade_ids: Dictionary = {}


func configure(
		new_player_id: int,
		new_nickname: String,
		new_team_color: Color,
		new_house_id: StringName = &"",
		new_subhouse_ids: Array = [],
		new_team_id: int = NO_TEAM_ID,
		starting_money: int = 0,
		starting_energy: int = 0
) -> void:
	player_id = new_player_id
	nickname = new_nickname
	team_color = new_team_color
	house_id = new_house_id
	subhouse_ids = _unique_subhouse_ids(new_subhouse_ids)
	team_id = new_team_id
	is_neutral = new_player_id == NEUTRAL_PLAYER_ID
	money = starting_money
	energy = starting_energy


func add_money(amount: int) -> void:
	money += amount


func can_spend_money(amount: int) -> bool:
	return amount >= 0 and money >= amount


func spend_money(amount: int) -> bool:
	if not can_spend_money(amount):
		return false

	money -= amount
	return true


func add_energy(amount: int) -> void:
	energy += amount


func has_purchased_upgrade(building_id: StringName) -> bool:
	return _purchased_upgrade_ids.has(building_id)


func grant_upgrade(building_id: StringName) -> void:
	_purchased_upgrade_ids[building_id] = true


func purchased_upgrade_ids() -> Array:
	return _purchased_upgrade_ids.keys()


func has_house() -> bool:
	return not String(house_id).is_empty()


func has_subhouses() -> bool:
	return not subhouse_ids.is_empty()


func has_subhouse(subhouse_id: StringName) -> bool:
	return subhouse_ids.has(subhouse_id)


func add_subhouse(subhouse_id: StringName) -> void:
	if String(subhouse_id).is_empty() or subhouse_ids.has(subhouse_id):
		return

	subhouse_ids.append(subhouse_id)


func remove_subhouse(subhouse_id: StringName) -> void:
	subhouse_ids.erase(subhouse_id)


func _unique_subhouse_ids(values: Array) -> Array[StringName]:
	var result: Array[StringName] = []
	for subhouse_id in values:
		if String(subhouse_id).is_empty() or result.has(subhouse_id):
			continue
		result.append(subhouse_id)
	return result
