class_name Building
extends Node3D

signal owner_changed(player_id: int)
signal health_changed(health: float, max_health: float)
signal primary_changed(is_primary: bool)

const PlayerDataScript := preload("res://scripts/players/player_data.gd")
const BuildingSurvivorsScript := preload("res://scripts/buildings/building_survivors.gd")

## docs/mechanics/production.md section 4: max 2 docks per refinery. Docks are
## plain Buildings placed by BuildingUpgradeController next to this one (not
## children of it) and are tracked here purely so a second "Upgrade Dock"
## click knows the current count and where to lay out the next one. Rules
## gives each RefineryDock its own health/storm_damage, so a dock can be
## destroyed independently. The instance-bound upgrade still belongs to its
## refinery: losing the refinery removes every registered dock with it.
const MAX_REFINERY_DOCKS := 2

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
			_sync_purchased_upgrade()
		owner_changed.emit(owner_player_id)
@export var default_state := &"idle"
@export var max_health := 0.0
@export var upgrade_level := 0

var building_config: Resource
var health := 0.0:
	set(value):
		health = clampf(value, 0.0, max_health)
		health_changed.emit(health, max_health)
		_refresh_generated_energy()

var current_state := &""
var invulnerable := false
# §1 "primary Construction Yard" / §3 "primary building": true for the one
# instance (per player, per building group) a double-click has designated as
# the exit point for that group's queue. Ownership of which group a building
# belongs to lives with the caller (PrimaryBuildingRegistry); this flag is
# just where the resulting state is rendered/queried from.
var is_primary := false:
	set(value):
		if is_primary == value:
			return
		is_primary = value
		primary_changed.emit(is_primary)
var _scroll_fx_meshes: Array[MeshInstance3D] = []
var _scroll_fx_time := 0.0
var _generated_energy := 0
var _docks: Array[Node3D] = []


func _ready() -> void:
	add_to_group("buildings")
	if String(config_id).is_empty() and has_meta("building_id"):
		config_id = StringName(String(get_meta("building_id")))
	_apply_rules_config()
	health = max_health
	_scroll_fx_meshes = _collect_scroll_fx_meshes()
	_refresh_owner_visuals()
	_refresh_generated_energy()
	_sync_purchased_upgrade()
	play_state(default_state)
	_add_selection_collision()


func _exit_tree() -> void:
	_set_generated_energy(0)
	for dock in _docks.duplicate():
		if is_instance_valid(dock) and not dock.is_queued_for_deletion():
			dock.queue_free()
	_docks.clear()


func _process(delta: float) -> void:
	if _scroll_fx_meshes.is_empty():
		return
	# Scrolling textures (e.g. the windtrap's spinning blades/spotlights) need
	# a continuously advancing phase; a baked animation track would snap back
	# to 0 every time the (often sub-second) state clip loops, so it is driven
	# here every frame instead (mirrors Unit's energy-shield fx_time).
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


func _add_selection_collision() -> void:
	var bounds := AABB()
	var has_bounds := false
	for mesh_instance in _mesh_instances(self):
		if mesh_instance.mesh == null:
			continue
		for corner in _aabb_corners(mesh_instance.get_aabb()):
			var point := to_local(mesh_instance.to_global(corner))
			if has_bounds:
				bounds = bounds.expand(point)
			else:
				bounds = AABB(point, Vector3.ZERO)
				has_bounds = true

	if not has_bounds:
		return

	var body := StaticBody3D.new()
	body.name = "SelectionCollision"
	body.collision_layer = 2
	body.collision_mask = 0
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(
		maxf(bounds.size.x, 0.1),
		maxf(bounds.size.y, 0.1),
		maxf(bounds.size.z, 0.1)
	)
	collision.shape = shape
	collision.position = bounds.get_center()
	body.add_child(collision)
	add_child(body)


func _mesh_instances(node: Node) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		result.append(node)
	for child in node.get_children():
		result.append_array(_mesh_instances(child))
	return result


func _aabb_corners(bounds: AABB) -> Array[Vector3]:
	var corners: Array[Vector3] = []
	for x in [bounds.position.x, bounds.end.x]:
		for y in [bounds.position.y, bounds.end.y]:
			for z in [bounds.position.z, bounds.end.z]:
				corners.append(Vector3(x, y, z))
	return corners


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


func set_upgrade_level(level: int) -> void:
	upgrade_level = maxi(level, 0)


func dock_count() -> int:
	return _docks.size()


func can_add_dock() -> bool:
	return _docks.size() < MAX_REFINERY_DOCKS


func register_dock(dock: Node3D) -> void:
	if is_instance_valid(dock) and not _docks.has(dock):
		_docks.append(dock)
		dock.tree_exiting.connect(_on_registered_dock_exiting.bind(dock), CONNECT_ONE_SHOT)


func _on_registered_dock_exiting(dock: Node3D) -> void:
	_docks.erase(dock)


func setup(building_id: StringName) -> void:
	config_id = building_id
	if not is_inside_tree():
		return

	_apply_rules_config()
	health = max_health


func set_invulnerable(value: bool) -> void:
	invulnerable = value


func set_primary(value: bool) -> void:
	is_primary = value


func take_damage(amount: float) -> void:
	if invulnerable or amount <= 0.0 or health <= 0.0:
		return

	health -= amount
	if health <= 0.0:
		# §2.1 "Building destruction": no debris/ruins remain, so the footprint
		# is freed immediately via queue_free() — survivors must be spawned
		# first, before the building (and its footprint bounds) disappear.
		BuildingSurvivorsScript.spawn_for_destroyed_building(self)
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


## docs/mechanics/production.md section 4/5: a purchased global per-type
## upgrade belongs to the player, so any building of that type this player
## owns -- including ones built after the purchase -- should read as
## upgraded. UpgradeEffects pushes the level onto buildings that already
## exist when the purchase completes; this covers the building's own arrival
## afterwards.
func _sync_purchased_upgrade() -> void:
	if not is_inside_tree() or String(config_id).is_empty() or upgrade_level > 0:
		return
	var player = owner_player()
	if player == null or not player.has_method("has_purchased_upgrade"):
		return
	if player.has_purchased_upgrade(config_id):
		set_upgrade_level(1)
