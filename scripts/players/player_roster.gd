class_name PlayerRoster
extends Node

signal roster_changed
signal player_changed(player_id: int)
signal relation_changed(first_player_id: int, second_player_id: int, relation: int)
signal local_player_changed(player_id: int)

const PlayerDataScript := preload("res://scripts/players/player_data.gd")

@export var local_player_id := PlayerDataScript.NEUTRAL_PLAYER_ID:
	set(value):
		if local_player_id == value:
			return
		local_player_id = value
		local_player_changed.emit(local_player_id)

var _players := {}
var _relations := {}


func _ready() -> void:
	reset_for_match()


func reset_for_match() -> void:
	_players.clear()
	_relations.clear()
	local_player_id = PlayerDataScript.NEUTRAL_PLAYER_ID
	add_player(_create_neutral_player())


func create_player(
		player_id: int,
		nickname: String,
		team_color: Color,
		house_id: StringName = &"",
		subhouse_ids: Array = [],
		team_id: int = PlayerDataScript.NO_TEAM_ID,
		starting_money: int = 0,
		starting_energy: int = 0
) -> Resource:
	var new_player := PlayerDataScript.new()
	new_player.configure(
		player_id,
		nickname,
		team_color,
		house_id,
		subhouse_ids,
		team_id,
		starting_money,
		starting_energy
	)
	add_player(new_player)
	return new_player


func add_player(player) -> void:
	if player == null:
		push_warning("Cannot add a null player to the roster")
		return

	_disconnect_existing_player(player.player_id)
	_players[player.player_id] = player
	player.resources_changed.connect(_on_player_resources_changed)
	player_changed.emit(player.player_id)
	roster_changed.emit()


func remove_player(player_id: int) -> void:
	if player_id == PlayerDataScript.NEUTRAL_PLAYER_ID:
		push_warning("The neutral player cannot be removed")
		return
	if not _players.has(player_id):
		return

	_disconnect_existing_player(player_id)
	_players.erase(player_id)
	_remove_relations_for(player_id)
	if local_player_id == player_id:
		local_player_id = PlayerDataScript.NEUTRAL_PLAYER_ID
	roster_changed.emit()


func player(player_id: int):
	return _players.get(player_id)


func neutral_player():
	return player(PlayerDataScript.NEUTRAL_PLAYER_ID)


func local_player():
	return player(local_player_id)


func has_player(player_id: int) -> bool:
	return _players.has(player_id)


func player_count(include_neutral := false) -> int:
	return all_players(include_neutral).size()


func all_players(include_neutral := false) -> Array:
	var result := []
	for roster_player in _players.values():
		if not include_neutral and roster_player.is_neutral:
			continue
		result.append(roster_player)
	return result


func player_ids(include_neutral := false) -> Array:
	var result := []
	for player_id in _players.keys():
		if not include_neutral and player_id == PlayerDataScript.NEUTRAL_PLAYER_ID:
			continue
		result.append(player_id)
	result.sort()
	return result


func set_team(player_id: int, team_id: int) -> void:
	var roster_player = player(player_id)
	if roster_player == null:
		push_warning("Cannot set team for missing player: %d" % player_id)
		return

	roster_player.team_id = team_id
	player_changed.emit(player_id)


func add_subhouse(player_id: int, subhouse_id: StringName) -> void:
	var roster_player = player(player_id)
	if roster_player == null:
		push_warning("Cannot add subhouse for missing player: %d" % player_id)
		return

	roster_player.add_subhouse(subhouse_id)
	player_changed.emit(player_id)


func remove_subhouse(player_id: int, subhouse_id: StringName) -> void:
	var roster_player = player(player_id)
	if roster_player == null:
		push_warning("Cannot remove subhouse for missing player: %d" % player_id)
		return

	roster_player.remove_subhouse(subhouse_id)
	player_changed.emit(player_id)


func set_relation(first_player_id: int, second_player_id: int, relation: int) -> void:
	if first_player_id == second_player_id:
		return

	_relations[_relation_key(first_player_id, second_player_id)] = relation
	relation_changed.emit(first_player_id, second_player_id, relation)


func clear_relation(first_player_id: int, second_player_id: int) -> void:
	_relations.erase(_relation_key(first_player_id, second_player_id))
	relation_changed.emit(first_player_id, second_player_id, relation_between(first_player_id, second_player_id))


func relation_between(first_player_id: int, second_player_id: int) -> int:
	if first_player_id == second_player_id:
		return PlayerDataScript.Relation.NEUTRAL if first_player_id == PlayerDataScript.NEUTRAL_PLAYER_ID else PlayerDataScript.Relation.ALLY

	if first_player_id == PlayerDataScript.NEUTRAL_PLAYER_ID or second_player_id == PlayerDataScript.NEUTRAL_PLAYER_ID:
		return PlayerDataScript.Relation.NEUTRAL

	var key := _relation_key(first_player_id, second_player_id)
	if _relations.has(key):
		return _relations[key]

	var first_player = player(first_player_id)
	var second_player = player(second_player_id)
	if first_player == null or second_player == null:
		return PlayerDataScript.Relation.NEUTRAL

	if first_player.team_id != PlayerDataScript.NO_TEAM_ID and first_player.team_id == second_player.team_id:
		return PlayerDataScript.Relation.ALLY

	return PlayerDataScript.Relation.ENEMY


func are_allied(first_player_id: int, second_player_id: int) -> bool:
	return relation_between(first_player_id, second_player_id) == PlayerDataScript.Relation.ALLY


func are_enemies(first_player_id: int, second_player_id: int) -> bool:
	return relation_between(first_player_id, second_player_id) == PlayerDataScript.Relation.ENEMY


func share_vision(first_player_id: int, second_player_id: int) -> bool:
	return are_allied(first_player_id, second_player_id)


func shared_vision_player_ids(player_id: int) -> Array:
	var result := []
	for other_player_id in player_ids():
		if share_vision(player_id, other_player_id):
			result.append(other_player_id)
	return result


func add_money(player_id: int, amount: int) -> void:
	var roster_player = player(player_id)
	if roster_player != null:
		roster_player.add_money(amount)


func spend_money(player_id: int, amount: int) -> bool:
	var roster_player = player(player_id)
	return roster_player != null and roster_player.spend_money(amount)


func add_energy(player_id: int, amount: int) -> void:
	var roster_player = player(player_id)
	if roster_player != null:
		roster_player.add_energy(amount)


func _create_neutral_player() -> Resource:
	var neutral := PlayerDataScript.new()
	neutral.configure(
		PlayerDataScript.NEUTRAL_PLAYER_ID,
		"Neutral",
		Color(0.58, 0.58, 0.58),
		&"",
		[],
		PlayerDataScript.NO_TEAM_ID,
		0,
		0
	)
	neutral.is_neutral = true
	return neutral


func _disconnect_existing_player(player_id: int) -> void:
	var existing_player = player(player_id)
	if existing_player == null:
		return

	var callback := Callable(self, "_on_player_resources_changed")
	if existing_player.resources_changed.is_connected(callback):
		existing_player.resources_changed.disconnect(callback)


func _remove_relations_for(player_id: int) -> void:
	for key in _relations.keys():
		if key.begins_with("%d:" % player_id) or key.ends_with(":%d" % player_id):
			_relations.erase(key)


func _relation_key(first_player_id: int, second_player_id: int) -> String:
	return "%d:%d" % [mini(first_player_id, second_player_id), maxi(first_player_id, second_player_id)]


func _on_player_resources_changed(player_id: int, _money: int, _energy: int) -> void:
	player_changed.emit(player_id)
