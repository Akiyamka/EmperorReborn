class_name Building
extends Node3D

signal owner_changed(player_id: int)
signal health_changed(health: float, max_health: float)

const PlayerDataScript := preload("res://scripts/players/player_data.gd")

@export var config_id: StringName
@export var owner_player_id := PlayerDataScript.NEUTRAL_PLAYER_ID:
	set(value):
		if owner_player_id == value:
			return
		_set_generated_energy(0)
		owner_player_id = value
		if is_inside_tree():
			_refresh_owner_visuals()
			_refresh_generated_energy()
		owner_changed.emit(owner_player_id)
@export var default_state := &"idle"
@export var max_health := 0.0

var building_config: Resource
var health := 0.0:
	set(value):
		health = clampf(value, 0.0, max_health)
		health_changed.emit(health, max_health)
		_refresh_generated_energy()

var current_state := &""
var _scroll_fx_meshes: Array[MeshInstance3D] = []
var _scroll_fx_time := 0.0
var _generated_energy := 0


func _ready() -> void:
	add_to_group("buildings")
	if String(config_id).is_empty() and has_meta("building_id"):
		config_id = StringName(String(get_meta("building_id")))
	_apply_rules_config()
	health = max_health
	_scroll_fx_meshes = _collect_scroll_fx_meshes()
	_refresh_owner_visuals()
	_refresh_generated_energy()
	play_state(default_state)


func _exit_tree() -> void:
	_set_generated_energy(0)


func _process(delta: float) -> void:
	if _scroll_fx_meshes.is_empty():
		return
	# Scrolling textures (e.g. the windtrap's spinning blades/spotlights) need
	# a continuously advancing phase; a baked animation track would snap back
	# to 0 every time the (often sub-second) state clip loops, so it is driven
	# here every frame instead (mirrors RTSUnit's energy-shield fx_time).
	_scroll_fx_time += delta
	for mesh_instance in _scroll_fx_meshes:
		mesh_instance.set_instance_shader_parameter("fx_time", _scroll_fx_time)


func _collect_scroll_fx_meshes() -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	_collect_scroll_fx_meshes_from(self, result)
	return result


func _collect_scroll_fx_meshes_from(node: Node, result: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D and node.has_meta("scroll_fx"):
		result.append(node)
	for child in node.get_children():
		_collect_scroll_fx_meshes_from(child, result)


func play_state(state: StringName) -> void:
	current_state = state
	var player := get_node_or_null("StatePlayer") as AnimationPlayer
	if player != null and player.has_animation(state):
		player.play(state)
		return

	var states := get_node_or_null("States")
	if states == null:
		return

	for child in states.get_children():
		var child_state := StringName(String(child.get_meta("state", child.name.to_lower())))
		child.visible = child_state == state


func set_owner_player_id(player_id: int) -> void:
	owner_player_id = player_id


func setup(building_id: StringName) -> void:
	config_id = building_id
	if not is_inside_tree():
		return

	_apply_rules_config()
	health = max_health


func take_damage(amount: float) -> void:
	if amount <= 0.0 or health <= 0.0:
		return

	health -= amount
	if health <= 0.0:
		queue_free()


func owner_player():
	var players = _players()
	if players == null:
		return null
	return players.player(owner_player_id)


func is_neutral_owner() -> bool:
	return owner_player_id == PlayerDataScript.NEUTRAL_PLAYER_ID


func is_owned_by(player_id: int) -> bool:
	return owner_player_id == player_id


func is_allied_with(player_id: int) -> bool:
	var players = _players()
	return players != null and players.are_allied(owner_player_id, player_id)


func is_enemy_of(player_id: int) -> bool:
	var players = _players()
	return players != null and players.are_enemies(owner_player_id, player_id)


func _refresh_owner_visuals() -> void:
	_apply_team_color(self, _owner_team_color())


func _apply_rules_config() -> void:
	if String(config_id).is_empty():
		return

	var rules := get_node_or_null("/root/Rules")
	if rules == null:
		push_warning("Rules autoload is not available; using scene defaults for %s" % name)
		return

	building_config = rules.call("building", config_id)
	if building_config == null:
		push_warning("Building rules config not found: %s" % String(config_id))
		return

	max_health = float(building_config.field(&"health", max_health))


func _refresh_generated_energy() -> void:
	if not is_inside_tree() or building_config == null or max_health <= 0.0 or health <= 0.0:
		_set_generated_energy(0)
		return

	var full_power := int(building_config.field(&"power_generated", 0))
	_set_generated_energy(roundi(float(full_power) * health / max_health))


func _set_generated_energy(value: int) -> void:
	if _generated_energy == value:
		return

	var player = owner_player()
	if player != null:
		player.add_energy(value - _generated_energy)
	_generated_energy = value


func _owner_team_color() -> Color:
	var roster_player = owner_player()
	if roster_player == null or roster_player.is_neutral:
		return Color(0.58, 0.58, 0.58)
	return roster_player.team_color


func _apply_team_color(node: Node, color: Color) -> void:
	if node is MeshInstance3D:
		node.set_instance_shader_parameter("team_color", color)
	for child in node.get_children():
		_apply_team_color(child, color)


func _players():
	if not is_inside_tree():
		return null
	return get_node_or_null("/root/Players")
