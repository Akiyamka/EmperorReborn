class_name UnitDeploymentController
extends Node

## Owns the MCV-specific deployment strategy: resolve the Construction Yard
## linked directly from the concrete ATMCV/HKMCV/ORMCV rules entry, validate
## its footprint without build radius,
## wait for the unit's locked animation, then hand off to the normal building
## construction lifecycle.

signal construction_yard_deployed(building: Node3D)

const BuildingPlacementScript := preload("res://scripts/buildings/building_placement.gd")
const SpatialOrientationScript := preload("res://scripts/world/spatial_orientation.gd")

const MCV_IDS: Array[StringName] = [&"ATMCV", &"HKMCV", &"ORMCV"]
const QUARTER_TURN_RADIANS := PI * 0.5
const BUILDING_SCENE_ROOT := "res://assets/converted/buildings"

var _navigation_grid
var _buildings_root: Node3D
var _deployments: Dictionary = {}


func setup(navigation_grid, buildings_root: Node3D) -> void:
	_navigation_grid = navigation_grid
	_buildings_root = buildings_root


## Result keys: handled (this is an MCV command), started, and message.
func try_deploy(unit: Node3D) -> Dictionary:
	if not can_handle(unit):
		return {"handled": false, "started": false, "message": ""}
	if bool(unit.call("is_deploying")):
		return _result(false, "MCV is already deploying")
	if _navigation_grid == null or not _navigation_grid.is_loaded():
		return _result(false, "MCV cannot deploy: navigation grid is unavailable")
	if _buildings_root == null:
		return _result(false, "MCV cannot deploy: buildings root is unavailable")

	var con_yard := _construction_yard_for(unit)
	var building_id: StringName = con_yard.get("id", &"")
	var config: Resource = con_yard.get("config")
	if building_id == &"" or config == null:
		return _result(false, "MCV cannot deploy: its rules have no Construction Yard")

	var scene_path := _building_scene_path(building_id)
	if not ResourceLoader.exists(scene_path):
		return _result(false, "MCV cannot deploy: %s scene is unavailable" % String(building_id))
	var building_scene := load(scene_path) as PackedScene
	if building_scene == null:
		return _result(false, "MCV cannot deploy: %s scene is invalid" % String(building_id))

	var placement: BuildingPlacement = BuildingPlacementScript.new()
	add_child(placement)
	placement.setup(
		null,
		_navigation_grid,
		_buildings_root,
		null,
		null,
		null,
		null,
		Callable(self, "_occupy_rows_for_existing_building")
	)
	var occupy_rows: Array[String] = []
	occupy_rows.assign(config.list(&"occupy_rows"))
	if not placement.begin(building_id, String(building_id), occupy_rows, false, true):
		placement.queue_free()
		return _result(false, "MCV cannot deploy: %s has no valid footprint" % String(building_id))

	placement.set_rotation_quarter_turns(_deployment_quarter_turns(unit))
	var hover_cell: Vector2i = _navigation_grid.world_to_grid(unit.global_position)
	var evaluation: int = placement.evaluate_at_hover_cell(hover_cell)
	if evaluation != BuildingPlacement.PlaceResult.AVAILABLE:
		placement.queue_free()
		return _result(false, "MCV cannot deploy at this location")

	var deployment_id := unit.get_instance_id()
	_deployments[deployment_id] = {
		"unit": unit,
		"placement": placement,
		"hover_cell": hover_cell,
		"building_id": building_id,
		"building_scene": building_scene,
		"owner_player_id": int(unit.get("owner_player_id")),
	}
	placement.building_placed.connect(_on_building_placed.bind(deployment_id))
	unit.deployment_animation_finished.connect(
		_on_deployment_animation_finished.bind(deployment_id), CONNECT_ONE_SHOT
	)
	unit.tree_exiting.connect(_on_deploying_unit_exiting.bind(deployment_id), CONNECT_ONE_SHOT)
	if not bool(unit.call("deploy")):
		_abort_deployment(deployment_id, true)
		return _result(false, "MCV could not start its deployment animation")
	return _result(true, "%s deployment started" % String(building_id))


func can_handle(unit: Node3D) -> bool:
	return (
		unit != null
		and StringName(String(unit.get("config_id"))) in MCV_IDS
		and unit.has_method("deploy")
		and unit.has_method("is_deploying")
		and unit.has_method("finish_deployment")
	)


## Units face local -Z while converted buildings expose their front/exit on
## local +Z. Convert the MCV's semantic world direction instead of copying its
## raw yaw, then snap that building direction to the nearest 90 degrees.
func _deployment_quarter_turns(unit: Node3D) -> int:
	var facing := SpatialOrientationScript.world_forward(unit)
	if facing.length_squared() <= SpatialOrientationScript.DIRECTION_EPSILON:
		return 0
	var building_yaw := atan2(facing.x, facing.z)
	return posmod(int(roundf(building_yaw / QUARTER_TURN_RADIANS)), 4)


func _on_deployment_animation_finished(deployment_id: int) -> void:
	var deployment: Dictionary = _deployments.get(deployment_id, {})
	if deployment.is_empty():
		return
	var unit := deployment["unit"] as Node3D
	var placement: BuildingPlacement = deployment["placement"]
	if unit == null or not is_instance_valid(unit) or placement == null:
		_abort_deployment(deployment_id, unit != null and is_instance_valid(unit))
		return

	var result: int = placement.try_place_at_hover_cell(
		deployment["hover_cell"],
		deployment["building_scene"],
		deployment["owner_player_id"],
		unit
	)
	if result != BuildingPlacement.PlaceResult.PLACED:
		_abort_deployment(deployment_id, true)
		return

	unit.call("finish_deployment", true)
	_deployments.erase(deployment_id)
	unit.queue_free()


func _on_building_placed(building: Node3D, deployment_id: int) -> void:
	var deployment: Dictionary = _deployments.get(deployment_id, {})
	if deployment.is_empty() or building == null:
		return
	if building.has_signal("construction_completed"):
		building.construction_completed.connect(
			_on_construction_yard_completed.bind(building), CONNECT_ONE_SHOT
		)
	else:
		_on_construction_yard_completed(building)


func _on_construction_yard_completed(building: Node3D) -> void:
	if building == null or not is_instance_valid(building):
		return
	var players := get_node_or_null("/root/Players")
	if players != null:
		players.set_main_base(int(building.get("owner_player_id")), building)
	construction_yard_deployed.emit(building)


func _on_deploying_unit_exiting(deployment_id: int) -> void:
	_abort_deployment(deployment_id, false)


func _abort_deployment(deployment_id: int, release_unit: bool) -> void:
	var deployment: Dictionary = _deployments.get(deployment_id, {})
	if deployment.is_empty():
		return
	_deployments.erase(deployment_id)
	var placement = deployment.get("placement")
	if placement != null and is_instance_valid(placement):
		placement.queue_free()
	var unit = deployment.get("unit")
	if release_unit and unit != null and is_instance_valid(unit):
		unit.call("finish_deployment", false)


func _construction_yard_for(unit: Node3D) -> Dictionary:
	var rules := get_node_or_null("/root/Rules")
	if rules == null:
		return {}
	var unit_config = unit.get("unit_config") as Resource
	if unit_config == null:
		unit_config = rules.call("unit", StringName(String(unit.get("config_id"))))
	if unit_config == null:
		return {}
	# The concrete MCV rules entry carries exactly one deployment target. Player
	# ownership and the player's default/cosmetic house are intentionally absent
	# from this decision.
	for link in unit_config.link(&"resources", []):
		var building_id := StringName(String((link as Dictionary).get("target", "")))
		var config := rules.call("building", building_id) as Resource
		if config == null or not bool(config.field(&"is_con_yard", false)):
			continue
		return {"id": building_id, "config": config}
	return {}


func _occupy_rows_for_existing_building(building: Node3D) -> Array[String]:
	var config = building.get("building_config") as Resource
	if config == null:
		var rules := get_node_or_null("/root/Rules")
		if rules != null:
			config = rules.call("building", StringName(String(building.get("config_id"))))
	var rows: Array[String] = []
	if config != null:
		rows.assign(config.list(&"occupy_rows"))
	return rows


func _building_scene_path(building_id: StringName) -> String:
	var id_text := String(building_id)
	return BUILDING_SCENE_ROOT.path_join(id_text).path_join("%s.scn" % id_text)


func _result(started: bool, message: String) -> Dictionary:
	return {"handled": true, "started": started, "message": message}
