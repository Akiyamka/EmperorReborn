class_name Building
extends Node3D

const SpatialOrientationScript := preload("res://scripts/world/spatial_orientation.gd")
const BuildingFootprintScript := preload("res://scripts/buildings/building_footprint.gd")
## Converted Emperor buildings expose their apron/door on authored local +Z.
const LOCAL_EXIT_DIRECTION := Vector3.BACK

signal owner_changed(player_id: int)
signal health_changed(health: float, max_health: float)
signal primary_changed(is_primary: bool)
signal rally_point_changed(position: Vector3)

const PlayerDataScript := preload("res://scripts/players/player_data.gd")
const BuildingSurvivorsScript := preload("res://scripts/buildings/building_survivors.gd")
const SelectionHaloScript := preload("res://scripts/ui/selection_halo.gd")

const COLLISION_OBJECT_NAME := "#~~0"
const RALLY_POINT_CLEARANCE := 1.5
const OCCUPY_CELL_WORLD_SPAN := 2.0
const REFINERY_ROLE := "Refinery"
const REFINERY_DOCK_RELEASE_DELAY_SECONDS := 3.0
const INVALID_REFINERY_DOCK := -1

## Refinery dock upgrades are visual states of the refinery itself, not
## separate Building nodes. The first/left upgrade unfolds ~~3SmallPad01 and
## the second/right unfolds ~~4SmallPad02; both retain their final pose.
enum RefineryUpgradeState { NONE, LEFT_DOCK, BOTH_DOCKS }

const MAX_REFINERY_DOCKS := 2
const REFINERY_DOCK_ANIMATIONS: Array[StringName] = [&"Refinery_Pad_1", &"Refinery_Pad_2"]
## Rules.txt lists the pads as centre, right, left. Upgrade animation 1 opens
## the left pad, so runtime dock ids follow the order in which pads become
## available: centre, left, right.
const REFINERY_DOCK_POINT_ORDER := [0, 2, 1]

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
@export var max_shields := 0.0
@export var upgrade_level := 0
@export_enum("No upgrades", "Left dock", "Both docks") var refinery_upgrade_state: int = RefineryUpgradeState.NONE

var building_config: Resource
var health := 0.0:
	set(value):
		health = clampf(value, 0.0, max_health)
		health_changed.emit(health, max_health)
		_refresh_generated_energy()
var shields := 0.0:
	set(value):
		shields = clampf(value, 0.0, max_shields)
var is_selected := false
var is_hovered := false
var rally_point := Vector3.ZERO

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
var _selection_halo
var _has_rally_point := false
var _refinery_dock_users: Dictionary = {}
var _refinery_dock_cooldowns: Dictionary = {}


func _ready() -> void:
	add_to_group("buildings")
	if String(config_id).is_empty() and has_meta("building_id"):
		config_id = StringName(String(get_meta("building_id")))
	_apply_rules_config()
	health = max_health
	shields = max_shields
	_scroll_fx_meshes = _collect_scroll_fx_meshes()
	_refresh_owner_visuals()
	_refresh_generated_energy()
	_sync_purchased_upgrade()
	play_state(default_state)
	_apply_refinery_upgrade_pose()
	_add_selection_collision()
	_add_selection_halo()
	# Placement assigns a newly-built node's final position immediately after it
	# enters the tree. Deferring this lets both pre-placed and newly-built
	# production buildings receive a point in front of their final transform.
	call_deferred("_set_default_rally_point_if_unset")


func _exit_tree() -> void:
	_set_generated_energy(0)


func _process(delta: float) -> void:
	_advance_refinery_dock_cooldowns(delta)
	if _scroll_fx_meshes.is_empty():
		return
	# Scrolling textures (e.g. the windtrap's spinning blades/spotlights) need
	# a continuously advancing phase; a baked animation track would snap back
	# to 0 every time the (often sub-second) state clip loops, so it is driven
	# here every frame instead (mirrors Unit's energy-shield fx_time).
	_scroll_fx_time += delta
	for mesh_instance in _scroll_fx_meshes:
		mesh_instance.set_instance_shader_parameter("fx_time", _scroll_fx_time)


func set_rally_point(position: Vector3) -> void:
	rally_point = position
	_has_rally_point = true
	rally_point_changed.emit(rally_point)


func rally_point_position() -> Vector3:
	_set_default_rally_point_if_unset()
	return rally_point


func production_spawn_position() -> Vector3:
	# Source models pivot their SLCT selection volume at the building's unit
	# exit (factory apron, hangar pad, barracks door), so when the authored
	# node is present its origin is the exact spawn point.
	var authored_exit := _authored_exit_node()
	if authored_exit != null:
		return authored_exit.global_position

	# Fallback: a skirt (`S`) is the footprint's front apron. Spawn in its
	# nearest-to-centre cell rather than at the outer edge, so units are born
	# inside the correct footprint cell but already facing a clear exit to the
	# rally point.
	if building_config == null:
		return global_position + exit_direction()
	var rows: Array[String] = []
	rows.assign(building_config.list(&"occupy_rows"))
	var spawn_cell := _nearest_skirt_cell(rows)
	if spawn_cell.x < 0:
		return global_position + exit_direction()
	var width := 0
	for row in rows:
		width = maxi(width, row.length())
	var local_offset := Vector3(
		(float(spawn_cell.x) + 0.5 - float(width) * 0.5) * OCCUPY_CELL_WORLD_SPAN,
		0.0,
		(float(spawn_cell.y) + 0.5 - float(rows.size()) * 0.5) * OCCUPY_CELL_WORLD_SPAN
	)
	return global_position + SpatialOrientationScript.world_right(self) * local_offset.x + exit_direction() * local_offset.z


## Where a produced unit should first walk to: the spawn point pushed past the
## footprint's front edge. The apron always faces local +Z (converter
## convention), so "out" is the building's forward direction; keeping the
## spawn's lateral offset makes the unit leave straight through the door.
func production_exit_position() -> Vector3:
	var spawn := production_spawn_position()
	var forward := exit_direction()
	var front_edge := _front_footprint_extent()
	var spawn_depth := (global_transform.affine_inverse() * spawn).z
	return spawn + forward * maxf(front_edge - spawn_depth + RALLY_POINT_CLEARANCE, RALLY_POINT_CLEARANCE)


func _front_footprint_extent() -> float:
	if building_config != null:
		var rows: Array = building_config.list(&"occupy_rows")
		if not rows.is_empty():
			return float(rows.size()) * OCCUPY_CELL_WORLD_SPAN * 0.5
	return _front_collision_extent()


func _authored_exit_node() -> Node3D:
	# The Idle (H0) state carries the canonical SLCT volume; damage states
	# duplicate it and the build/destroy states may reposition or drop it.
	var idle_state := get_node_or_null("States/Idle")
	if idle_state == null:
		return null
	return _find_slct_node(idle_state)


func _find_slct_node(node: Node) -> Node3D:
	if node is Node3D and String(node.get_meta("original_name", "")).to_lower().begins_with("slct"):
		return node
	for child in node.get_children():
		var found := _find_slct_node(child)
		if found != null:
			return found
	return null


func _nearest_skirt_cell(rows: Array[String]) -> Vector2i:
	if rows.is_empty():
		return Vector2i(-1, -1)
	var width := 0
	for row in rows:
		width = maxi(width, row.length())
	var centre := Vector2(float(width) * 0.5 - 0.5, float(rows.size()) * 0.5 - 0.5)
	var closest := Vector2i(-1, -1)
	var closest_distance := INF
	for row_index in rows.size():
		var row := rows[row_index]
		for column_index in row.length():
			if row.substr(column_index, 1).to_lower() != "s":
				continue
			var distance := Vector2(column_index, row_index).distance_squared_to(centre)
			if distance < closest_distance:
				closest = Vector2i(column_index, row_index)
				closest_distance = distance
	return closest


func _set_default_rally_point_if_unset() -> void:
	if _has_rally_point:
		return
	var clearance := RALLY_POINT_CLEARANCE + _front_collision_extent()
	set_rally_point(global_position + exit_direction() * clearance)


func _front_collision_extent() -> float:
	var collision_body := get_node_or_null("SelectionCollision") as StaticBody3D
	if collision_body != null and collision_body.has_meta("collision_bounds"):
		var bounds: AABB = collision_body.get_meta("collision_bounds")
		# Converted Emperor models are Z-mirrored, placing their exit/apron on
		# local +Z. The positive-Z extent is therefore the front-edge distance.
		return maxf(absf(bounds.position.z), absf(bounds.end.z))
	return 0.0


func exit_direction() -> Vector3:
	var direction := SpatialOrientationScript.world_horizontal_axis(self, LOCAL_EXIT_DIRECTION)
	return direction if not direction.is_zero_approx() else Vector3.BACK


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
	var body := StaticBody3D.new()
	body.name = "SelectionCollision"
	body.collision_layer = 2
	body.collision_mask = 0
	for source in _collision_sources():
		var shape := _collision_shape(source)
		if shape == null:
			push_warning("Building: collision mesh %s has no usable convex shape" % source.get_path())
			continue

		var collision := CollisionShape3D.new()
		collision.name = "AuthoredCollision"
		collision.shape = shape
		# SelectionCollision is at the Building origin. Convert the source's
		# world transform back into that local space before parenting it,
		# so this works while the body itself is not in the scene tree yet.
		collision.transform = global_transform.affine_inverse() * source.global_transform
		body.add_child(collision)

		for point in _collision_bounds_points(source):
			point = to_local(source.to_global(point))
			if has_bounds:
				bounds = bounds.expand(point)
			else:
				bounds = AABB(point, Vector3.ZERO)
				has_bounds = true

	if body.get_child_count() == 0:
		body.free()
		return
	if has_bounds:
		body.set_meta("collision_bounds", bounds)
	add_child(body)


func _collision_sources() -> Array[Node3D]:
	var result: Array[Node3D] = []
	# A building packs several visual damage states, each with its own #~~0.
	# Its footprint is the H0 (Idle) volume, rather than the union of hidden
	# construction/destruction-state volumes.
	var idle_state := get_node_or_null("States/Idle")
	var source_root: Node = idle_state if idle_state != null else self
	_collect_collision_sources(source_root, COLLISION_OBJECT_NAME, result)
	if result.is_empty():
		_collect_collision_sources(source_root, "slct", result, true)
	return result


func _collect_collision_sources(node: Node, original_name: String, result: Array[Node3D], prefix_match := false) -> void:
	if node is Node3D and _is_collision_source(node, original_name, prefix_match):
		_hide_collision_meshes(node)
		result.append(node)
		return
	for child in node.get_children():
		_collect_collision_sources(child, original_name, result, prefix_match)


func _is_collision_source(node: Node3D, original_name: String, prefix_match: bool) -> bool:
	var source_name := String(node.get_meta("original_name", ""))
	var matches := source_name.to_lower().begins_with(original_name) if prefix_match else source_name == original_name
	var points: PackedVector3Array = node.get_meta("collision_points", PackedVector3Array())
	return matches and points.size() >= 4


func _collision_shape(source: Node3D) -> Shape3D:
	var points: PackedVector3Array = source.get_meta("collision_points", PackedVector3Array())
	if points.size() >= 4:
		var shape := ConvexPolygonShape3D.new()
		shape.points = points
		return shape
	for child in source.get_children():
		if child is MeshInstance3D and child.mesh != null:
			return child.mesh.create_convex_shape(true, false)
	return null


func _collision_bounds_points(source: Node3D) -> PackedVector3Array:
	var points: PackedVector3Array = source.get_meta("collision_points", PackedVector3Array())
	if not points.is_empty():
		return points
	var bounds := PackedVector3Array()
	for child in source.get_children():
		if child is MeshInstance3D and child.mesh != null:
			for corner in _aabb_corners(child.get_aabb()):
				bounds.append(child.position + corner)
	return bounds


func _hide_collision_meshes(node: Node) -> void:
	for child in node.get_children():
		if child is MeshInstance3D and child.has_meta("collision_mesh"):
			child.visible = false


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
	return refinery_upgrade_state


## The base refinery starts with its central pad; refinery_upgrade_state counts
## only the one or two additional pads unfolded by upgrades.
func refinery_dock_capacity() -> int:
	if not is_refinery():
		return 0
	return mini(1 + refinery_upgrade_state, _refinery_dock_points().size())


func is_refinery() -> bool:
	return building_config != null and building_config.list(&"roles").has(REFINERY_ROLE)


## Reserves one currently active pad immediately. A reservation remains owned
## by this harvester through docking and Unload_End, then enters a three-second
## cooldown so the departing vehicle can clear the lane.
func try_reserve_refinery_dock(harvester: Node) -> int:
	if harvester == null or not is_instance_valid(harvester):
		return INVALID_REFINERY_DOCK
	_prune_refinery_dock_users()
	for dock_index in refinery_dock_capacity():
		if float(_refinery_dock_cooldowns.get(dock_index, 0.0)) > 0.0:
			continue
		if _refinery_dock_users.has(dock_index):
			continue
		_refinery_dock_users[dock_index] = harvester
		return dock_index
	return INVALID_REFINERY_DOCK


func refinery_dock_reserved_by(dock_index: int, harvester: Node) -> bool:
	_prune_refinery_dock_users()
	return _refinery_dock_users.get(dock_index) == harvester


func release_refinery_dock(
		harvester: Node, cooldown_seconds := REFINERY_DOCK_RELEASE_DELAY_SECONDS
	) -> void:
	for dock_index in _refinery_dock_users.keys():
		if _refinery_dock_users[dock_index] != harvester:
			continue
		_refinery_dock_users.erase(dock_index)
		_refinery_dock_cooldowns[dock_index] = maxf(cooldown_seconds, 0.0)


## Before a vehicle enters the pad lane there is nothing that needs a departure
## gap. This is used when an approach/wait order is replaced or the refinery is
## captured before parking begins.
func abandon_refinery_dock(harvester: Node) -> void:
	release_refinery_dock(harvester, 0.0)


func refinery_front_position() -> Vector3:
	return global_position + exit_direction() * (
		_front_footprint_extent() + RALLY_POINT_CLEARANCE
	)


## Converts the authoritative Rules.txt DeployTile into world space. Exported
## occupy rows are Z-mirrored to match converted models, while deploy_points
## intentionally retain their source orientation (import_rules.gd); mirror Y
## here against the occupy height before applying the building transform.
func refinery_dock_world_position(dock_index: int) -> Vector3:
	var points := _refinery_dock_points()
	var rows := _refinery_occupy_rows()
	if dock_index < 0 or dock_index >= refinery_dock_capacity() or rows.is_empty():
		return Vector3.INF
	var point: Dictionary = points[dock_index]
	var width := 0
	for row in rows:
		width = maxi(width, String(row).length())
	if width <= 0:
		return Vector3.INF
	var source_y := int(point.get("tile_y", 0))
	var mirrored_y := rows.size() - 1 - source_y
	var local_x := (float(point.get("tile_x", 0)) + 0.5 - float(width) * 0.5) * OCCUPY_CELL_WORLD_SPAN
	var local_z := (float(mirrored_y) + 0.5 - float(rows.size()) * 0.5) * OCCUPY_CELL_WORLD_SPAN
	return global_position \
		+ SpatialOrientationScript.world_right(self) * local_x \
		+ exit_direction() * local_z


func refinery_dock_facing_direction(dock_index: int) -> Vector3:
	var points := _refinery_dock_points()
	if dock_index < 0 or dock_index >= refinery_dock_capacity():
		return exit_direction()
	var degrees := float((points[dock_index] as Dictionary).get("angle", 0.0))
	# Rules angles use the source model's opposite yaw convention.
	return exit_direction().rotated(Vector3.UP, deg_to_rad(-degrees)).normalized()


func refinery_dock_navigation_cells(navigation_grid) -> Dictionary:
	if navigation_grid == null:
		return {}
	var footprint := BuildingFootprintScript.nav_cells_by_marker(
		self,
		_refinery_occupy_rows(),
		navigation_grid,
		BuildingPlacement.NAV_CELLS_PER_OCCUPY_CELL
	)
	var dock_cells := {}
	for cell in footprint:
		var marker := String(footprint[cell]).to_lower()
		if marker == "d" or marker == "p":
			dock_cells[cell] = marker
	return dock_cells


func _refinery_dock_points() -> Array:
	var source_points: Array = building_config.list(&"deploy_points") if building_config != null else []
	var ordered_points: Array = []
	for source_index in REFINERY_DOCK_POINT_ORDER:
		if source_index < source_points.size():
			ordered_points.append(source_points[source_index])
	return ordered_points


func _refinery_occupy_rows() -> Array:
	return building_config.list(&"occupy_rows") if building_config != null else []


func _advance_refinery_dock_cooldowns(delta: float) -> void:
	_prune_refinery_dock_users()
	for dock_index in _refinery_dock_cooldowns.keys():
		var remaining := maxf(float(_refinery_dock_cooldowns[dock_index]) - maxf(delta, 0.0), 0.0)
		if remaining <= 0.0001:
			_refinery_dock_cooldowns.erase(dock_index)
		else:
			_refinery_dock_cooldowns[dock_index] = remaining


func _prune_refinery_dock_users() -> void:
	for dock_index in _refinery_dock_users.keys():
		var harvester = _refinery_dock_users[dock_index]
		if not is_instance_valid(harvester) or harvester.is_queued_for_deletion():
			_refinery_dock_users.erase(dock_index)


func can_add_dock() -> bool:
	return refinery_upgrade_state < MAX_REFINERY_DOCKS


func add_refinery_dock_upgrade() -> bool:
	if not can_add_dock():
		return false
	refinery_upgrade_state += 1
	_play_refinery_dock_animation(refinery_upgrade_state - 1)
	return true


func set_refinery_upgrade_state(state: int) -> void:
	refinery_upgrade_state = clampi(state, 0, MAX_REFINERY_DOCKS)
	if is_inside_tree():
		_apply_refinery_upgrade_pose()


func _play_refinery_dock_animation(animation_index: int) -> void:
	var player := _refinery_animation_player()
	if player == null or animation_index < 0 or animation_index >= REFINERY_DOCK_ANIMATIONS.size():
		return
	var animation_name := REFINERY_DOCK_ANIMATIONS[animation_index]
	if player.has_animation(animation_name):
		player.play(animation_name)


## Restored/preconfigured refineries do not replay their opening sequence.
## Seeking each completed clip applies the same final transforms immediately;
## later clips target a different pad, so the earlier pose stays untouched.
func _apply_refinery_upgrade_pose() -> void:
	var player := _refinery_animation_player()
	if player == null:
		return
	for animation_index in refinery_upgrade_state:
		var animation_name := REFINERY_DOCK_ANIMATIONS[animation_index]
		if not player.has_animation(animation_name):
			continue
		var animation := player.get_animation(animation_name)
		player.play(animation_name)
		player.seek(animation.length, true)
		player.pause()


func _refinery_animation_player() -> AnimationPlayer:
	return get_node_or_null("States/Idle/AnimationPlayer") as AnimationPlayer


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


func set_selected(value: bool) -> void:
	if is_selected == value:
		return
	is_selected = value
	if _selection_halo != null:
		_selection_halo.set_selected(value)


func set_hovered(value: bool) -> void:
	if is_hovered == value:
		return
	is_hovered = value
	if _selection_halo != null:
		_selection_halo.set_hovered(value)


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
	max_shields = float(building_config.field(&"shield_health", max_shields))


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


func _add_selection_halo() -> void:
	_selection_halo = SelectionHaloScript.new()
	_selection_halo.name = "SelectionHalo"
	add_child(_selection_halo)
	_selection_halo.configure(self, _selection_radius(), _selection_position())


func _selection_radius() -> float:
	var anchor_bounds := _halo_anchor_bounds()
	if anchor_bounds.size.x > 0.0 or anchor_bounds.size.z > 0.0:
		return maxf(anchor_bounds.size.x, anchor_bounds.size.z) * 0.5

	var bounds := _selection_bounds()
	# A halo is circular: its diameter follows the authored selection volume's
	# narrow horizontal axis, not its length.  This keeps long vehicles and
	# buildings from receiving an oversized circle.
	return minf(bounds.size.x, bounds.size.z) * 0.5


func _selection_position() -> Vector3:
	var anchor: Node3D = _halo_anchor_node(self)
	if anchor != null:
		return to_local(anchor.to_global(Vector3.ZERO))

	return Vector3(0.0, _selection_bounds().end.y + 0.05, 0.0)


func _halo_anchor_bounds() -> AABB:
	var anchor: Node3D = _halo_anchor_node(self)
	if anchor == null or not anchor.has_meta("halo_anchor_bounds"):
		return AABB()
	var source_bounds: AABB = anchor.get_meta("halo_anchor_bounds")
	var bounds := AABB()
	var has_bounds := false
	for corner in _aabb_corners(source_bounds):
		var point := to_local(anchor.to_global(corner))
		if has_bounds:
			bounds = bounds.expand(point)
		else:
			bounds = AABB(point, Vector3.ZERO)
			has_bounds = true
	return bounds


func _selection_bounds() -> AABB:
	var bounds := AABB()
	var has_bounds := false
	for marker in _selection_marker_nodes(self):
		var marker_bounds: AABB = marker.get_meta("selection_bounds")
		for corner in _aabb_corners(marker_bounds):
			var point := to_local(marker.to_global(corner))
			if has_bounds:
				bounds = bounds.expand(point)
			else:
				bounds = AABB(point, Vector3.ZERO)
				has_bounds = true
	if has_bounds:
		return bounds
	return AABB(Vector3.ZERO, Vector3(1.0, 1.0, 1.0))

func _selection_marker_nodes(node: Node) -> Array[Node3D]:
	var result: Array[Node3D] = []
	_collect_selection_marker_nodes(node, result)
	return result


func _collect_selection_marker_nodes(node: Node, result: Array[Node3D]) -> void:
	if node is Node3D and node.has_meta("selection_bounds"):
		result.append(node)
	for child in node.get_children():
		_collect_selection_marker_nodes(child, result)


func _halo_anchor_node(node: Node) -> Node3D:
	if node is Node3D and node.has_meta("halo_anchor"):
		return node
	for child in node.get_children():
		var anchor: Node3D = _halo_anchor_node(child)
		if anchor != null:
			return anchor
	return null


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
