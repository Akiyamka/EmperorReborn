class_name Building
extends Node3D

const SpatialOrientationScript := preload("res://scripts/world/spatial_orientation.gd")
const BuildingFootprintScript := preload("res://scripts/buildings/building_footprint.gd")
const WallConnectivityScript := preload("res://scripts/buildings/wall_connectivity.gd")
const CombatTurretScript := preload("res://scripts/combat/combat_turret.gd")
const AuthoredFireControllerScript := preload(
	"res://scripts/combat/authored_fire_controller.gd"
)
const BuildingDefinitionCatalogScript := preload("res://scripts/buildings/building_definition_catalog.gd")
static var _native_definition_catalog := BuildingDefinitionCatalogScript.new()
## Converted Emperor buildings expose their apron/door on authored local +Z.
const LOCAL_EXIT_DIRECTION := Vector3.BACK

signal owner_changed(player_id: int)
signal health_changed(health: float, max_health: float)
signal primary_changed(is_primary: bool)
signal rally_point_changed(position: Vector3)
signal construction_completed
signal attack_order_changed(active: bool, target: Variant)
signal weapon_fired(projectiles: Array, target: Variant, weapon_index: int)

const PlayerDataScript := preload("res://scripts/players/player_data.gd")
const BuildingSurvivorsScript := preload("res://scripts/buildings/building_survivors.gd")
const SelectionHaloScript := preload("res://scripts/ui/selection_halo.gd")
const REPAIR_EFFECT_SCENE := preload("res://assets/converted/ui/cursor_models/repair.scn")
const RALLY_POINT_MARKER_SCENE := preload(
	"res://assets/converted/ui/cursor_models/place_flag.scn"
)

const COLLISION_OBJECT_NAME := "#~~0"
const RALLY_POINT_CLEARANCE := 1.5
const OCCUPY_CELL_WORLD_SPAN := 2.0
const REFINERY_ROLE := "Refinery"
const WALL_BUILDING_GROUP := "Wall"
const REFINERY_DOCK_RELEASE_DELAY_SECONDS := 3.0
const INVALID_REFINERY_DOCK := -1
const RULE_COMBAT_TICKS_PER_SECOND := 25.0
const AUTO_TARGET_REFRESH_SECONDS := 0.25
const POPUP_TURRET_ROLE := &"PopupTurret"
const POPUP_DEPLOY_ANIMATION := &"Deploy_Gun"
const POPUP_HOLD_ANIMATION := &"Deploy_Gun_Hold"
const POPUP_UNDEPLOY_ANIMATION := &"Undeploy_Gun"
const DEFENSIVE_TURRET_IDS: Array[StringName] = [
	&"HKFlameTurret",
	&"TLTurret",
	&"HKGunTurret",
	&"ORGasTurret",
	&"ORPopUpTurret",
	&"ATPillbox",
	&"ATRocketTurret",
]
const WALL_ANCHOR_CELL_SPAN := 2
const WALL_WORLD_NEIGHBOR_TOLERANCE := 0.35
const MAX_COMBAT_HULL_VERTICES := 8
const RALLY_POINT_LINE_COLOR := Color(0.12, 1.0, 0.28, 0.9)
const RALLY_POINT_LINE_WIDTH := 0.10
const RALLY_POINT_LINE_HEIGHT := 0.08

## Refinery dock upgrades are visual states of the refinery itself, not
## separate Building nodes. The first/left upgrade unfolds ~~3SmallPad01 and
## the second/right unfolds ~~4SmallPad02; both retain their final pose.
enum RefineryUpgradeState { NONE, LEFT_DOCK, BOTH_DOCKS }
enum PopupTurretState { RETRACTED, DEPLOYING, DEPLOYED, UNDEPLOYING }

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
		if is_inside_tree():
			cancel_attack_order()
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
@export var armour_type: StringName = &""
@export var upgrade_level := 0
@export_enum("No upgrades", "Left dock", "Both docks") var refinery_upgrade_state: int = RefineryUpgradeState.NONE

var building_definition: Resource
var building_config: Resource:
	get:
		return building_definition
	set(value):
		building_definition = value
var health := 0.0:
	set(value):
		health = clampf(value, 0.0, max_health)
		health_changed.emit(health, max_health)
		_refresh_generated_energy()
		_refresh_health_visual_state()
var shields := 0.0:
	set(value):
		shields = clampf(value, 0.0, max_shields)
var is_selected := false
var is_hovered := false
var is_repairing := false:
	set(value):
		if is_repairing == value:
			return
		is_repairing = value
		_refresh_repair_effect()
var rally_point := Vector3.ZERO
var combat_turrets: Array = []

var current_state := &""
var invulnerable := false
## Pre-placed buildings are operational immediately. BuildingPlacement marks
## newly placed buildings incomplete until StatePlayer actually finishes the
## authored construct clip; unit production uses this instead of mere tree/group
## membership when deciding whether the building can accept orders.
var _construction_complete := true
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
var _repair_effect: Node3D
var _has_rally_point := false
var _rally_point_is_default := true
var _rally_point_line: MeshInstance3D
var _rally_point_line_mesh: ImmediateMesh
var _rally_point_line_material: StandardMaterial3D
var _rally_point_marker: Node3D
var _refinery_dock_users: Dictionary = {}
var _refinery_dock_cooldowns: Dictionary = {}
var _wall_connection_mask := 0
var _wall_topology: StringName = WallConnectivityScript.SINGLE
var _wall_rotation_quarters := 0
var _combat_hull := PackedVector2Array()
var _combat_hull_minimum_y := 0.0
var _combat_hull_maximum_y := 0.0
var _has_attack_order := false
var _attack_is_ground := false
var _attack_ground_position := Vector3.INF
var _attack_target_ref: WeakRef
var _automatic_target_ref: WeakRef
var _automatic_target_cooldown := 0.0
var _authored_fire_controller = AuthoredFireControllerScript.new()
var _popup_turret_state := PopupTurretState.RETRACTED
var _popup_transition_player: AnimationPlayer
var _popup_transition_animation: StringName = &""
var _popup_transition_elapsed := 0.0
var _popup_transition_duration := 0.0


func _ready() -> void:
	add_to_group("buildings")
	var state_player := get_node_or_null("StatePlayer") as AnimationPlayer
	if state_player != null:
		# The outer state clip contains a full copy of Stationary transforms.
		# Evaluate it first, then the active model clip, then this building's
		# combat servo. Otherwise StatePlayer overwrites both popup motion and
		# the yaw/pitch applied later in _process.
		state_player.process_priority = process_priority - 2
	_authored_fire_controller.weapon_fired.connect(
		_on_authored_weapon_fired
	)
	if String(config_id).is_empty() and has_meta("building_id"):
		config_id = StringName(String(get_meta("building_id")))
	_apply_building_definition()
	health = max_health
	shields = max_shields
	_scroll_fx_meshes = _collect_scroll_fx_meshes()
	_refresh_owner_visuals()
	_refresh_generated_energy()
	_sync_purchased_upgrade()
	play_state(default_state)
	_apply_refinery_upgrade_pose()
	_combat_hull = get_meta("combat_hull", PackedVector2Array())
	_combat_hull_minimum_y = float(get_meta("combat_hull_minimum_y", 0.0))
	_combat_hull_maximum_y = float(get_meta("combat_hull_maximum_y", 0.0))
	_add_selection_collision()
	_add_selection_halo()
	_add_rally_point_line()
	_add_rally_point_marker()
	# Placement assigns a newly-built node's final position immediately after it
	# enters the tree. Deferring this lets both pre-placed and newly-built
	# production buildings receive a point in front of their final transform.
	call_deferred("_set_default_rally_point_if_unset")
	if _has_wall_role():
		# BuildingPlacement writes placement_anchor_cell and the final transform
		# immediately after add_child(), so defer adjacency until both exist.
		call_deferred("refresh_wall_connections")


func _exit_tree() -> void:
	_authored_fire_controller.cancel()
	if is_in_group("wall_buildings"):
		_defer_adjacent_wall_refresh()
	_set_generated_energy(0)


func _process(delta: float) -> void:
	_automatic_target_cooldown = maxf(
		_automatic_target_cooldown - maxf(delta, 0.0), 0.0
	)
	for turret in combat_turrets:
		turret.advance_ticks(delta * RULE_COMBAT_TICKS_PER_SECOND)
	_advance_popup_transition(delta)
	_restore_popup_hold_pose()
	_advance_building_combat(delta)
	_authored_fire_controller.advance(delta)
	_restore_popup_hold_pose()
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


func can_set_rally_point() -> bool:
	if building_definition == null:
		return false
	# Refineries use their rally point to direct harvesters, not to route
	# freshly produced units, so it stays available regardless of AiManufacturing.
	return building_definition.ai_manufacturing or is_refinery()


func set_rally_point(position: Vector3) -> bool:
	if not can_set_rally_point():
		return false
	_assign_rally_point(position, false)
	return true


func _assign_rally_point(position: Vector3, is_default: bool) -> void:
	rally_point = position
	_has_rally_point = true
	_rally_point_is_default = is_default
	_rebuild_rally_point_line()
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
	if building_definition == null:
		return global_position + exit_direction()
	var rows: Array[String] = []
	rows.assign(building_definition.occupy_rows)
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
	if building_definition != null:
		var rows: Array = building_definition.occupy_rows
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
	_assign_rally_point(global_position + exit_direction() * clearance, true)


func _add_rally_point_line() -> void:
	_rally_point_line = MeshInstance3D.new()
	_rally_point_line.name = "RallyPointLine"
	_rally_point_line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_rally_point_line.extra_cull_margin = 1000.0
	add_child(_rally_point_line)

	_rally_point_line_mesh = ImmediateMesh.new()
	_rally_point_line_material = StandardMaterial3D.new()
	_rally_point_line_material.albedo_color = RALLY_POINT_LINE_COLOR
	_rally_point_line_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_rally_point_line_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_rally_point_line_material.no_depth_test = true
	_rally_point_line_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_rally_point_line_material.render_priority = 19
	_rebuild_rally_point_line()


func _add_rally_point_marker() -> void:
	_rally_point_marker = RALLY_POINT_MARKER_SCENE.instantiate() as Node3D
	if _rally_point_marker == null:
		return
	_rally_point_marker.name = "RallyPointMarker"
	# Cursor conversion separates screen/additive surfaces onto render layer 2.
	# In the world marker both passes must be visible through the gameplay
	# camera, whose ordinary geometry is on layer 1.
	for node in _rally_point_marker.find_children("*", "MeshInstance3D", true, false):
		(node as MeshInstance3D).layers = 1
	add_child(_rally_point_marker)
	_refresh_rally_point_marker()


func _rebuild_rally_point_line() -> void:
	if _rally_point_line == null:
		return
	_rally_point_line_mesh.clear_surfaces()
	if not _has_rally_point or _rally_point_is_default:
		_rally_point_line.mesh = null
		_refresh_rally_point_line_visibility()
		_refresh_rally_point_marker()
		return

	var spawn := to_local(production_spawn_position())
	var exit := to_local(production_exit_position())
	var finish := to_local(rally_point)
	var spawn_to_exit := exit - spawn
	spawn_to_exit.y = 0.0
	var exit_to_finish := finish - exit
	exit_to_finish.y = 0.0
	if spawn_to_exit.length_squared() <= 0.000001 \
	and exit_to_finish.length_squared() <= 0.000001:
		_rally_point_line.mesh = null
		_refresh_rally_point_line_visibility()
		_refresh_rally_point_marker()
		return

	spawn.y += RALLY_POINT_LINE_HEIGHT
	exit.y += RALLY_POINT_LINE_HEIGHT
	finish.y += RALLY_POINT_LINE_HEIGHT
	_rally_point_line_mesh.surface_begin(
		Mesh.PRIMITIVE_TRIANGLES, _rally_point_line_material
	)
	_add_rally_point_line_segment(spawn, exit)
	_add_rally_point_line_segment(exit, finish)
	_rally_point_line_mesh.surface_end()
	_rally_point_line.mesh = _rally_point_line_mesh
	_refresh_rally_point_line_visibility()
	_refresh_rally_point_marker()


func _add_rally_point_line_segment(start: Vector3, finish: Vector3) -> void:
	var direction := finish - start
	direction.y = 0.0
	if direction.length_squared() <= 0.000001:
		return
	var lateral := Vector3(-direction.z, 0.0, direction.x).normalized() \
		* RALLY_POINT_LINE_WIDTH * 0.5
	_add_rally_point_line_triangle(start - lateral, finish - lateral, finish + lateral)
	_add_rally_point_line_triangle(start - lateral, finish + lateral, start + lateral)


func _add_rally_point_line_triangle(a: Vector3, b: Vector3, c: Vector3) -> void:
	_rally_point_line_mesh.surface_add_vertex(a)
	_rally_point_line_mesh.surface_add_vertex(b)
	_rally_point_line_mesh.surface_add_vertex(c)


func _refresh_rally_point_line_visibility() -> void:
	if _rally_point_line != null:
		_rally_point_line.visible = is_selected \
			and _has_rally_point and not _rally_point_is_default \
			and _rally_point_line.mesh != null


func _refresh_rally_point_marker() -> void:
	if _rally_point_marker == null:
		return
	if _has_rally_point:
		_rally_point_marker.position = to_local(rally_point)
	_rally_point_marker.visible = is_selected \
		and _has_rally_point and not _rally_point_is_default


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
	if get_node_or_null("CombatCollision") != null:
		body.set_meta("combat_ignore", true)
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
	# A building packs several visual damage states, each with its own #~~0.
	# The footprint is always taken from H0 (Idle), not hidden damage states.
	var idle_state := get_node_or_null("States/Idle")
	var source_root: Node = idle_state if idle_state != null else self
	return collision_sources_for(source_root, true)


## Returns the authored selectable footprint below source_root. Models which
## provide SLCT use it directly; #~~0 is retained for legacy models without
## an explicit selection volume. This API is shared by runtime collision and
## building-scene baking so their footprint decisions cannot diverge.
static func collision_sources_for(source_root: Node, hide_source_meshes := false) -> Array[Node3D]:
	var result: Array[Node3D] = []
	_collect_collision_sources(source_root, "slct", result, true, hide_source_meshes)
	if result.is_empty():
		_collect_collision_sources(source_root, COLLISION_OBJECT_NAME, result, false, hide_source_meshes)
	return result


static func _collect_collision_sources(node: Node, original_name: String, result: Array[Node3D], prefix_match := false, hide_source_meshes := false) -> void:
	if node is Node3D and _is_collision_source(node, original_name, prefix_match):
		if hide_source_meshes:
			_hide_collision_meshes(node)
		result.append(node)
		return
	for child in node.get_children():
		_collect_collision_sources(child, original_name, result, prefix_match, hide_source_meshes)


static func _is_collision_source(node: Node3D, original_name: String, prefix_match: bool) -> bool:
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


static func _hide_collision_meshes(node: Node) -> void:
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
		# Apply time-zero visibility and pose tracks before the next rendered
		# frame. Otherwise a freshly added building can briefly render its
		# default idle state before construct starts updating.
		player.advance(0.0)
		_refresh_wall_variant_visual()
		_apply_refinery_upgrade_pose()
		_bind_combat_turrets(_state_root(state))
		return

	var states := get_node_or_null("States")
	if states == null:
		return

	for child in states.get_children():
		var child_state := StringName(String(child.get_meta("state", child.name.to_lower())))
		child.visible = child_state == state
	_refresh_wall_variant_visual()
	_apply_refinery_upgrade_pose()
	_bind_combat_turrets(_state_root(state))


## Recomputes this wall plus the at-most-four segments whose topology can
## change because of it. Placement calls this deferred from _ready; removal
## schedules the same refresh for surviving neighbours from _exit_tree.
func refresh_wall_connections() -> void:
	if not is_inside_tree() or not _has_wall_role():
		return
	_refresh_wall_topology()
	for candidate in get_tree().get_nodes_in_group("wall_buildings"):
		if candidate == self or not is_instance_valid(candidate) \
		or candidate.is_queued_for_deletion():
			continue
		if _wall_direction_to(candidate as Node3D) != 0:
			candidate.call("_refresh_wall_topology")


func wall_connection_mask() -> int:
	return _wall_connection_mask


func wall_topology() -> StringName:
	return _wall_topology


func wall_rotation_quarters() -> int:
	return _wall_rotation_quarters


func active_wall_variant_path() -> NodePath:
	var variants := get_node_or_null("WallVariants")
	if variants == null:
		return NodePath()
	for variant in variants.get_children():
		for state_node in variant.get_children():
			if state_node is Node3D and state_node.visible:
				return state_node.get_path()
	return NodePath()


func _refresh_wall_topology() -> void:
	if not is_inside_tree() or not _has_wall_role():
		return
	_wall_connection_mask = _wall_neighbor_mask()
	var selection: Dictionary = WallConnectivityScript.selection_for_mask(
		_wall_connection_mask
	)
	_wall_topology = selection["topology"]
	_wall_rotation_quarters = int(selection["rotation_quarters"])
	_refresh_wall_variant_visual()


func _wall_neighbor_mask() -> int:
	var mask := 0
	for candidate in get_tree().get_nodes_in_group("wall_buildings"):
		if candidate == self or not is_instance_valid(candidate) \
		or candidate.is_queued_for_deletion():
			continue
		mask |= _wall_direction_to(candidate as Node3D)
	return mask


func _wall_direction_to(other: Node3D) -> int:
	if other == null:
		return 0
	if has_meta(&"placement_anchor_cell") and other.has_meta(&"placement_anchor_cell"):
		var delta: Vector2i = (
			other.get_meta(&"placement_anchor_cell") as Vector2i
			- get_meta(&"placement_anchor_cell") as Vector2i
		)
		match delta:
			Vector2i(0, -WALL_ANCHOR_CELL_SPAN):
				return WallConnectivityScript.NORTH
			Vector2i(WALL_ANCHOR_CELL_SPAN, 0):
				return WallConnectivityScript.EAST
			Vector2i(0, WALL_ANCHOR_CELL_SPAN):
				return WallConnectivityScript.SOUTH
			Vector2i(-WALL_ANCHOR_CELL_SPAN, 0):
				return WallConnectivityScript.WEST
			_:
				return 0

	# Legacy/pre-placed walls have no placement metadata. Their relative world
	# positions still share the authored two-unit occupy-cell pitch.
	var delta_world := other.global_position - global_position
	var span := OCCUPY_CELL_WORLD_SPAN
	var tolerance := WALL_WORLD_NEIGHBOR_TOLERANCE
	if absf(delta_world.x) <= tolerance:
		if absf(delta_world.z + span) <= tolerance:
			return WallConnectivityScript.NORTH
		if absf(delta_world.z - span) <= tolerance:
			return WallConnectivityScript.SOUTH
	if absf(delta_world.z) <= tolerance:
		if absf(delta_world.x - span) <= tolerance:
			return WallConnectivityScript.EAST
		if absf(delta_world.x + span) <= tolerance:
			return WallConnectivityScript.WEST
	return 0


func _refresh_wall_variant_visual() -> void:
	if not _has_wall_role():
		return
	var variants := get_node_or_null("WallVariants") as Node3D
	if variants == null:
		return
	for variant in variants.get_children():
		if variant is Node3D:
			variant.visible = false
		for state_node in variant.get_children():
			if state_node is Node3D:
				state_node.visible = false

	var visual_state := String(current_state)
	if visual_state != "idle" and not visual_state.begins_with("damage"):
		return

	# Wall Stationary clips carry no gameplay animation. Pause the outer state
	# player after applying time zero so its looping visibility key cannot
	# reveal the base Single model over an active joined variant.
	var state_player := get_node_or_null("StatePlayer") as AnimationPlayer
	if state_player != null:
		state_player.pause()

	var states := get_node_or_null("States")
	var base_state := _state_root(current_state)
	if states != null:
		for child in states.get_children():
			var child_state := String(child.get_meta("state", child.name.to_lower()))
			if child_state == "idle" or child_state.begins_with("damage"):
				child.visible = false

	if _wall_topology == WallConnectivityScript.SINGLE:
		if base_state != null:
			base_state.visible = true
		return

	var variant_name := WallConnectivityScript.variant_node_name(_wall_topology)
	var variant_root := variants.get_node_or_null(NodePath(String(variant_name))) as Node3D
	if variant_root == null:
		if base_state != null:
			base_state.visible = true
		return
	variant_root.visible = true
	# The mask is expressed in world/grid directions. Compensate any authored
	# or pre-placed parent yaw so the selected arms still face those neighbours.
	variant_root.rotation.y = (
		float(_wall_rotation_quarters) * PI * 0.5 - variants.global_rotation.y
	)

	var state_node_name := "Damage2" if visual_state.begins_with("damage") else "Idle"
	var active_state := variant_root.get_node_or_null(NodePath(state_node_name)) as Node3D
	# Some original families (notably IX Middle/Cross) omit H2. Preserve the
	# correct join topology and fall back to that family's intact H0 art.
	if active_state == null:
		active_state = variant_root.get_node_or_null("Idle") as Node3D
	if active_state != null:
		active_state.visible = true
	elif base_state != null:
		base_state.visible = true


func _defer_adjacent_wall_refresh() -> void:
	var tree := get_tree()
	if tree == null:
		return
	for candidate in tree.get_nodes_in_group("wall_buildings"):
		if candidate == self or not is_instance_valid(candidate) \
		or candidate.is_queued_for_deletion():
			continue
		if _wall_direction_to(candidate as Node3D) != 0:
			candidate.call_deferred("_refresh_wall_topology")


## Idle is the single undamaged health band. Every available DamageN state is
## one further equally sized band, ordered by its numeric suffix.  The source
## assets occasionally omit Damage1 while retaining Damage2; those are still
## valid two-band buildings (Idle, Damage2), so state numbers are ordering only
## and never used as band indices.
func _refresh_health_visual_state() -> void:
	if not is_inside_tree() or max_health <= 0.0:
		return
	var damage_states := _damage_visual_states()
	var state_count := damage_states.size() + 1
	var damaged_fraction := 1.0 - health / max_health
	var state_index := clampi(floori(damaged_fraction * state_count), 0, state_count - 1)
	var desired_state: StringName = &"idle"
	if state_index > 0:
		desired_state = damage_states[state_index - 1]
	if desired_state != current_state:
		play_state(desired_state)


func _damage_visual_states() -> Array[StringName]:
	var states_root := get_node_or_null("States")
	if states_root == null:
		return []
	var numbered_states: Array[Dictionary] = []
	for child in states_root.get_children():
		var state_name := String(child.get_meta("state", child.name.to_lower()))
		if not state_name.begins_with("damage"):
			continue
		var suffix := state_name.trim_prefix("damage")
		if not suffix.is_valid_int():
			continue
		numbered_states.append({"name": StringName(state_name), "number": suffix.to_int()})
	numbered_states.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return int(left["number"]) < int(right["number"])
	)
	var result: Array[StringName] = []
	for state in numbered_states:
		result.append(state["name"])
	return result


func _state_root(state: StringName) -> Node3D:
	var states := get_node_or_null("States")
	if states == null:
		return null
	for child in states.get_children():
		var child_state := StringName(String(child.get_meta("state", child.name.to_lower())))
		if child_state == state and child is Node3D:
			return child as Node3D
	return null


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
	return building_definition != null and building_definition.roles.has(REFINERY_ROLE)


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
	var source_points: Array = building_definition.deploy_points if building_definition != null else []
	var ordered_points: Array = []
	for source_index in REFINERY_DOCK_POINT_ORDER:
		if source_index < source_points.size():
			ordered_points.append(source_points[source_index])
	return ordered_points


func _refinery_occupy_rows() -> Array:
	return building_definition.occupy_rows if building_definition != null else []


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


## Idle, Damage1 and Damage2 each carry their own copy of the dock pad nodes
## and their own AnimationPlayer, so the pose has to be reapplied against
## whichever state is currently active, not always against Idle.
func _refinery_animation_player() -> AnimationPlayer:
	var state_root := _state_root(current_state)
	if state_root == null:
		state_root = get_node_or_null("States/Idle")
	if state_root == null:
		return null
	return state_root.get_node_or_null("AnimationPlayer") as AnimationPlayer


func setup(building_id: StringName) -> void:
	cancel_attack_order()
	config_id = building_id
	if not is_inside_tree():
		return

	_apply_building_definition()
	health = max_health


func set_invulnerable(value: bool) -> void:
	invulnerable = value


func begin_construction() -> void:
	_construction_complete = false
	cancel_attack_order()


func finish_construction() -> void:
	if _construction_complete:
		return
	_construction_complete = true
	construction_completed.emit()


func is_construction_complete() -> bool:
	return _construction_complete


func set_primary(value: bool) -> void:
	is_primary = value


func set_selected(value: bool) -> void:
	if is_selected == value:
		return
	is_selected = value
	if _selection_halo != null:
		_selection_halo.set_selected(value)
	_refresh_rally_point_line_visibility()
	_refresh_rally_point_marker()


func set_hovered(value: bool) -> void:
	if is_hovered == value:
		return
	is_hovered = value
	if _selection_halo != null:
		_selection_halo.set_hovered(value)


func take_damage(amount: float) -> void:
	if invulnerable or amount <= 0.0 or health <= 0.0:
		return

	var remaining_damage := amount
	if shields > 0.0:
		var absorbed := minf(shields, remaining_damage)
		shields -= absorbed
		remaining_damage -= absorbed
	if remaining_damage <= 0.0:
		return
	health -= remaining_damage
	if health <= 0.0:
		# §2.1 "Building destruction": no debris/ruins remain, so the footprint
		# is freed immediately via queue_free() — survivors must be spawned
		# first, before the building (and its footprint bounds) disappear.
		BuildingSurvivorsScript.spawn_for_destroyed_building(self)
		queue_free()


func combat_armour_type() -> StringName:
	return armour_type


func combat_is_airborne() -> bool:
	return false


func combat_aim_position() -> Vector3:
	return global_position


## Spreads incoming fire across the footprint-facing edge instead of making
## every attacker converge on the building root.
func combat_aim_position_from(world_origin: Vector3) -> Vector3:
	if _combat_hull.size() >= 3:
		var local_origin := to_local(world_origin)
		var nearest := _nearest_combat_hull_point(
			Vector2(local_origin.x, local_origin.z)
		)
		var local_aim := to_local(combat_aim_position())
		local_aim.x = nearest.x
		local_aim.y = clampf(
			local_origin.y,
			_combat_hull_minimum_y,
			_combat_hull_maximum_y
		)
		local_aim.z = nearest.y
		return to_global(local_aim)
	var collision_body := get_node_or_null("SelectionCollision") as StaticBody3D
	if collision_body == null or not collision_body.has_meta("collision_bounds"):
		return combat_aim_position()
	var bounds: AABB = collision_body.get_meta("collision_bounds")
	var local_origin := to_local(world_origin)
	var local_aim := to_local(combat_aim_position())
	local_aim.x = clampf(local_origin.x, bounds.position.x, bounds.end.x)
	local_aim.z = clampf(local_origin.z, bounds.position.z, bounds.end.z)
	return to_global(local_aim)


func _nearest_combat_hull_point(point: Vector2) -> Vector2:
	if Geometry2D.is_point_in_polygon(point, _combat_hull):
		return point
	var nearest := _combat_hull[0]
	var nearest_distance := INF
	for index in _combat_hull.size():
		var candidate := Geometry2D.get_closest_point_to_segment(
			point,
			_combat_hull[index],
			_combat_hull[(index + 1) % _combat_hull.size()]
		)
		var distance := point.distance_squared_to(candidate)
		if distance < nearest_distance:
			nearest = candidate
			nearest_distance = distance
	return nearest


func combat_hull() -> PackedVector2Array:
	return _combat_hull.duplicate()


func combat_has_precise_collision() -> bool:
	return get_node_or_null("CombatCollision") != null


func combat_contains_impact_position(world_position: Vector3) -> bool:
	if _combat_hull.size() < 3:
		return false
	var local_position := to_local(world_position)
	var footprint_position := Vector2(local_position.x, local_position.z)
	return Geometry2D.is_point_in_polygon(footprint_position, _combat_hull) \
		or footprint_position.distance_to(
			_nearest_combat_hull_point(footprint_position)
		) <= 0.001


func combat_is_alive() -> bool:
	return health > 0.0 and not is_queued_for_deletion()


func combat_hit_radius() -> float:
	var collision_body := get_node_or_null("SelectionCollision") as StaticBody3D
	if collision_body != null and collision_body.has_meta("collision_bounds"):
		var bounds: AABB = collision_body.get_meta("collision_bounds")
		return maxf(minf(bounds.size.x, bounds.size.z) * 0.5, 0.5)
	return 0.5


## Weapon range is measured to the nearest point of a building's authored
## footprint. Entity roots remain the range point for units and other targets.
func combat_range_distance_from(
		world_origin: Vector3
	) -> float:
	var nearest_world := combat_aim_position_from(world_origin)
	var offset := nearest_world - world_origin
	return Vector2(offset.x, offset.z).length()


func combat_owner_player_id() -> int:
	# Stable combat-facing ownership contract used for friendly-fire scaling.
	return owner_player_id


func aim_turrets_at(world_position: Vector3, delta: float) -> bool:
	if combat_turrets.is_empty():
		return false
	var all_aimed := true
	for turret in combat_turrets:
		all_aimed = turret.aim_at(world_position, delta) and all_aimed
	return all_aimed


func turret_emission_points(weapon_index: int = 0) -> Array[Dictionary]:
	var turret = _combat_turret_for_weapon(weapon_index)
	if turret == null:
		return []
	return turret.emission_points()


func next_turret_emission(weapon_index: int = 0) -> Dictionary:
	var turret = _combat_turret_for_weapon(weapon_index)
	if turret == null:
		return {}
	return turret.next_emission()


func fire_weapon_at(
		target_or_position: Variant,
		weapon_index: int = 0,
		projectile_parent: Node = null,
		aim_offset := Vector3.ZERO
	) -> Array:
	var turret = _combat_turret_for_weapon(weapon_index)
	if turret == null:
		return []
	return turret.try_fire_at(target_or_position, self, projectile_parent, aim_offset)


func can_attack(target_or_position: Variant) -> bool:
	if not _combat_is_operational():
		return false
	for turret in combat_turrets:
		if turret.can_target(target_or_position):
			return true
	return false


## Buildings accept the same explicit attack contract as units. They retain an
## out-of-range target rather than pursuing it and begin firing if it later
## enters range. Relation checks remain in UnitCommandController so Ctrl can
## deliberately force fire against allied or neutral targets.
func command_attack(target_or_position: Variant) -> bool:
	if not can_attack(target_or_position):
		return false
	_authored_fire_controller.cancel()
	_has_attack_order = true
	_attack_is_ground = target_or_position is Vector3
	_attack_ground_position = (
		target_or_position if _attack_is_ground else Vector3.INF
	)
	_attack_target_ref = (
		null if _attack_is_ground else weakref(target_or_position as Object)
	)
	_automatic_target_ref = null
	_automatic_target_cooldown = 0.0
	attack_order_changed.emit(true, target_or_position)
	return true


func cancel_attack_order() -> void:
	_authored_fire_controller.cancel()
	_automatic_target_ref = null
	_automatic_target_cooldown = 0.0
	if not _has_attack_order:
		return
	_has_attack_order = false
	_attack_is_ground = false
	_attack_ground_position = Vector3.INF
	_attack_target_ref = null
	attack_order_changed.emit(false, null)


## Shared Stop-command contract. Stationary buildings can only have an explicit
## attack order, so Stop deliberately leaves rally points and production state
## unchanged.
func cancel_all_orders() -> bool:
	var had_order := _has_attack_order
	if not had_order:
		return false
	cancel_attack_order()
	return true


func has_attack_order() -> bool:
	return _has_attack_order


func has_active_order() -> bool:
	return _has_attack_order


func attack_order_target() -> Variant:
	if not _has_attack_order:
		return null
	if _attack_is_ground:
		return _attack_ground_position
	return (
		_attack_target_ref.get_ref()
		if _attack_target_ref != null
		else null
	)


func _advance_building_combat(delta: float) -> void:
	if not _combat_is_operational() or combat_turrets.is_empty():
		return
	var turret = combat_turrets.front()
	var target: Variant = attack_order_target()
	if _has_attack_order and (
		(not _attack_is_ground and not _combat_target_is_alive(target))
		or not _combat_target_position(target).is_finite()
	):
		cancel_attack_order()
		target = null
	if target == null:
		target = _automatic_target_for(turret)

	var target_in_range: bool = target != null \
		and turret.target_range(target) \
			== CombatTurretScript.TargetRange.IN_RANGE
	var target_position := (
		_combat_target_position(target) if target_in_range else Vector3.INF
	)
	if target_in_range and turret.requires_hull_turn_for(target_position):
		target_in_range = false

	if _uses_popup_turret():
		if _popup_turret_state in [
			PopupTurretState.DEPLOYING,
			PopupTurretState.UNDEPLOYING,
		]:
			return
		if target_in_range \
		and _popup_turret_state == PopupTurretState.RETRACTED:
			_begin_popup_transition(true)
			return
		if not target_in_range \
		and _popup_turret_state == PopupTurretState.DEPLOYED \
		and not _authored_fire_controller.is_active():
			if turret.recenter(delta):
				_begin_popup_transition(false)
			return
		if _popup_turret_state != PopupTurretState.DEPLOYED:
			return

	if not target_in_range:
		if not _authored_fire_controller.is_active():
			turret.recenter(delta)
		return
	var aimed := bool(turret.aim_at(target_position, delta))
	if config_id == &"ATRocketTurret":
		aimed = bool(turret.is_group_yaw_aimed_at(target_position))
	if not aimed or _authored_fire_controller.is_active():
		return
	if _authored_fire_controller.try_start(target):
		return
	if _authored_fire_controller.has_fire_animation():
		return
	var projectiles: Array = turret.try_fire_at(target, self)
	if not projectiles.is_empty():
		weapon_fired.emit(projectiles, target, turret.weapon_index())


func _automatic_target_for(turret) -> Variant:
	var cached: Variant = (
		_automatic_target_ref.get_ref()
		if _automatic_target_ref != null
		else null
	)
	if _automatic_target_is_usable(turret, cached):
		return cached
	if _automatic_target_cooldown > 0.0:
		return null
	_automatic_target_cooldown = AUTO_TARGET_REFRESH_SECONDS
	var tree := get_tree()
	if tree == null:
		return null
	var best_target: Node3D
	var best_distance := INF
	var candidates: Array[Node] = []
	candidates.append_array(tree.get_nodes_in_group(&"units"))
	candidates.append_array(tree.get_nodes_in_group(&"buildings"))
	for candidate_node in candidates:
		if not candidate_node is Node3D or candidate_node == self:
			continue
		var candidate := candidate_node as Node3D
		if not _automatic_target_is_usable(turret, candidate):
			continue
		var distance := global_position.distance_squared_to(
			candidate.global_position
		)
		if distance < best_distance \
		or (
			is_equal_approx(distance, best_distance)
			and best_target != null
			and candidate.get_instance_id() < best_target.get_instance_id()
		):
			best_distance = distance
			best_target = candidate
	_automatic_target_ref = (
		weakref(best_target) if best_target != null else null
	)
	return best_target


func _automatic_target_is_usable(turret, target: Variant) -> bool:
	if not target is Node3D or not is_instance_valid(target):
		return false
	var candidate := target as Node3D
	if not _combat_target_is_alive(candidate) \
	or not candidate.has_method("is_enemy_of") \
	or not bool(candidate.call("is_enemy_of", owner_player_id)):
		return false
	if turret.target_range(candidate) \
		!= CombatTurretScript.TargetRange.IN_RANGE:
		return false
	var target_position := _combat_target_position(candidate)
	return target_position.is_finite() \
		and not turret.requires_hull_turn_for(target_position)


func _combat_target_position(target: Variant) -> Vector3:
	if target is Vector3:
		return target
	if not target is Object or not is_instance_valid(target):
		return Vector3.INF
	var target_object := target as Object
	if target_object.has_method("combat_aim_position_from"):
		var value: Variant = target_object.call(
			"combat_aim_position_from", global_position
		)
		if value is Vector3:
			return value
	if target_object.has_method("combat_aim_position"):
		var value: Variant = target_object.call("combat_aim_position")
		if value is Vector3:
			return value
	return (
		(target_object as Node3D).global_position
		if target_object is Node3D
		else Vector3.INF
	)


func _combat_target_is_alive(target: Variant) -> bool:
	if not target is Object or not is_instance_valid(target):
		return false
	var target_object := target as Object
	if target_object is Node \
	and (target_object as Node).is_queued_for_deletion():
		return false
	return not target_object.has_method("combat_is_alive") \
		or bool(target_object.call("combat_is_alive"))


func _combat_is_operational() -> bool:
	return config_id in DEFENSIVE_TURRET_IDS \
		and _construction_complete \
		and health > 0.0 \
		and not is_queued_for_deletion() \
		and not combat_turrets.is_empty()


func _combat_turret_for_weapon(weapon_index: int):
	if weapon_index < 0:
		return null
	for turret in combat_turrets:
		if turret.weapon_index() == weapon_index:
			return turret
	return null


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


func _apply_building_definition() -> void:
	if String(config_id).is_empty():
		return

	building_definition = _native_definition_catalog.definition(config_id)
	if building_definition == null:
		push_warning("Building definition not found: %s" % String(config_id))
		return

	_sync_wall_group()
	max_health = building_definition.health
	max_shields = building_definition.shield_health
	armour_type = building_definition.armour_type
	_configure_combat_turret()


func _has_wall_role() -> bool:
	return building_definition != null \
		and String(building_definition.building_group_id) == WALL_BUILDING_GROUP


func _sync_wall_group() -> void:
	if _has_wall_role():
		add_to_group("wall_buildings")
	elif is_in_group("wall_buildings"):
		remove_from_group("wall_buildings")


func _configure_combat_turret() -> void:
	_authored_fire_controller.cancel()
	combat_turrets.clear()
	var definition := _native_definition_catalog.definition(config_id)
	var turret_id: StringName = definition.turret_id if definition != null else &""
	if turret_id == &"":
		return
	var turret = CombatTurretScript.new()
	if turret.configure(turret_id):
		turret.bind_model(_state_root(current_state), 0)
		combat_turrets.append(turret)


func _bind_combat_turrets(model_root: Node3D) -> void:
	_authored_fire_controller.cancel()
	_reset_popup_transition()
	for turret in combat_turrets:
		turret.bind_model(model_root, turret.weapon_index())
		if model_root != null:
			for node in model_root.find_children(
				"*", "AnimationPlayer", true, false
			):
				var player := node as AnimationPlayer
				player.process_priority = mini(
					player.process_priority, process_priority - 1
				)
	if not combat_turrets.is_empty():
		_authored_fire_controller.configure(
			self, combat_turrets.front(), model_root
		)


func _uses_popup_turret() -> bool:
	return building_definition != null \
		and POPUP_TURRET_ROLE in building_definition.roles


func _begin_popup_transition(deploying: bool) -> void:
	var animation_name := (
		POPUP_DEPLOY_ANIMATION
		if deploying
		else POPUP_UNDEPLOY_ANIMATION
	)
	var player := _active_model_animation_player(animation_name)
	if player == null:
		_popup_turret_state = (
			PopupTurretState.DEPLOYED
			if deploying
			else PopupTurretState.RETRACTED
		)
		return
	var animation := player.get_animation(animation_name)
	if animation == null:
		return
	_authored_fire_controller.cancel()
	_popup_turret_state = (
		PopupTurretState.DEPLOYING
		if deploying
		else PopupTurretState.UNDEPLOYING
	)
	_popup_transition_player = player
	_popup_transition_animation = animation_name
	_popup_transition_elapsed = 0.0
	_popup_transition_duration = animation.length
	player.speed_scale = 1.0
	player.stop(true)
	player.play(animation_name)


func _advance_popup_transition(delta: float) -> void:
	if _popup_turret_state not in [
		PopupTurretState.DEPLOYING,
		PopupTurretState.UNDEPLOYING,
	]:
		return
	if _popup_transition_player == null \
	or not is_instance_valid(_popup_transition_player):
		_finish_popup_transition()
		return
	_popup_transition_elapsed = minf(
		_popup_transition_elapsed + maxf(delta, 0.0),
		_popup_transition_duration
	)
	if _popup_transition_elapsed + 0.0001 < _popup_transition_duration:
		return
	var animation := _popup_transition_player.get_animation(
		_popup_transition_animation
	)
	if animation != null:
		_popup_transition_player.seek(animation.length, true)
	_popup_transition_player.pause()
	_finish_popup_transition()


func _finish_popup_transition() -> void:
	var was_deploying := (
		_popup_turret_state == PopupTurretState.DEPLOYING
	)
	var player := _popup_transition_player
	_popup_turret_state = (
		PopupTurretState.DEPLOYED
		if was_deploying
		else PopupTurretState.RETRACTED
	)
	_popup_transition_player = null
	_popup_transition_animation = &""
	_popup_transition_elapsed = 0.0
	_popup_transition_duration = 0.0
	if was_deploying and player != null \
	and player.has_animation(POPUP_HOLD_ANIMATION):
		player.stop(true)
		player.play(POPUP_HOLD_ANIMATION)
		player.advance(0.0)
		player.pause()
	for turret in combat_turrets:
		turret.capture_current_rest_pose()


func _restore_popup_hold_pose() -> void:
	if not _uses_popup_turret() \
	or _popup_turret_state != PopupTurretState.DEPLOYED \
	or _authored_fire_controller.is_active():
		return
	var player := _active_model_animation_player(POPUP_HOLD_ANIMATION)
	if player == null:
		return
	player.stop(true)
	player.play(POPUP_HOLD_ANIMATION)
	player.advance(0.0)
	player.pause()
	for turret in combat_turrets:
		turret.restore_aim_pose()


func _reset_popup_transition() -> void:
	_popup_turret_state = PopupTurretState.RETRACTED
	_popup_transition_player = null
	_popup_transition_animation = &""
	_popup_transition_elapsed = 0.0
	_popup_transition_duration = 0.0


func _active_model_animation_player(
	animation_name: StringName
	) -> AnimationPlayer:
	var state_root := _state_root(current_state)
	if state_root == null:
		return null
	for node in state_root.find_children(
		"*", "AnimationPlayer", true, false
	):
		var player := node as AnimationPlayer
		if player.has_animation(animation_name):
			return player
	return null


func _on_authored_weapon_fired(
	projectiles: Array, target: Variant, weapon_index: int
	) -> void:
	weapon_fired.emit(projectiles, target, weapon_index)


func _refresh_generated_energy() -> void:
	if not is_inside_tree() or building_definition == null or max_health <= 0.0 or health <= 0.0:
		_set_generated_energy(0)
		return

	var full_power := int(building_definition.power_generated)
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
	if node is MeshInstance3D and _mesh_declares_team_color(node as MeshInstance3D):
		node.set_instance_shader_parameter("team_color", color)
	for child in node.get_children():
		_apply_team_color(child, color)


func _mesh_declares_team_color(mesh_instance: MeshInstance3D) -> bool:
	var materials: Array[Material] = []
	if mesh_instance.material_override != null:
		materials.append(mesh_instance.material_override)
	if mesh_instance.material_overlay != null:
		materials.append(mesh_instance.material_overlay)
	if mesh_instance.mesh != null:
		for surface_index in mesh_instance.mesh.get_surface_count():
			var material := mesh_instance.get_surface_override_material(surface_index)
			if material == null:
				material = mesh_instance.mesh.surface_get_material(surface_index)
			if material != null:
				materials.append(material)
	for material in materials:
		if material is ShaderMaterial:
			var shader := (material as ShaderMaterial).shader
			if shader != null and "instance uniform vec4 team_color" in shader.code:
				return true
	return false


func _add_selection_halo() -> void:
	_selection_halo = SelectionHaloScript.new()
	_selection_halo.name = "SelectionHalo"
	add_child(_selection_halo)
	_selection_halo.configure(self, _selection_radius(), _selection_position())
	_refresh_repair_effect()


## The original repair marker reuses the animated repair cursor. It cannot be
## a child of SelectionHalo: that node intentionally hides itself unless its
## building is selected or hovered, whereas an active repair marker is always
## visible.
func _refresh_repair_effect() -> void:
	if not is_instance_valid(_repair_effect):
		_repair_effect = null
	if not is_repairing:
		if _repair_effect != null:
			_repair_effect.queue_free()
			_repair_effect = null
		return
	if _selection_halo == null or _repair_effect != null:
		return
	_repair_effect = REPAIR_EFFECT_SCENE.instantiate() as Node3D
	if _repair_effect == null:
		return
	_repair_effect.name = "RepairEffect"
	_repair_effect.position = _selection_position() + Vector3(0.0, 0.02, 0.0)
	# Cursor assets are authored at screen-cursor scale; they must not inherit a
	# large factory's halo diameter or they overwhelm the building.
	_repair_effect.scale = Vector3.ONE * 0.08
	add_child(_repair_effect)


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
