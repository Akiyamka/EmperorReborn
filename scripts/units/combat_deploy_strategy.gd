class_name CombatDeployStrategy
extends RefCounted

## Stationary-combat-mode deploy strategy for units that ship a travel/deployed
## turret pair (ATKindjal, ORMortar, ORKobra) rather than transforming into a
## building. Far simpler than the MCV strategy in UnitDeploymentController: no
## world validation, no BuildingPlacement, no facing alignment, no scene swap.
## It only ever drives Unit.deploy()/undeploy() and waits for the animation
## handoff; Unit itself owns the nav-agent hold (set_hold_position) across the
## whole DEPLOYING/DEPLOYED/UNDEPLOYING span.
##
## Eligibility is data-driven, not a hardcoded unit-id list: a unit is
## combat-deployable iff its turret_ids contain at least one turret gated
## disabled_when_deployed and at least one gated disabled_when_undeployed
## (see docs/quirks.md for why IMADVSardaukar is excluded at generation time
## instead of by an exception list here).

const CombatDefinitionCatalogScript := preload("res://scripts/combat/combat_definition_catalog.gd")

var _combat_definition_catalog := CombatDefinitionCatalogScript.new()
var _eligibility_cache: Dictionary = {}


## Result keys mirror the MCV strategy: handled, started, and message.
func try_deploy(unit: Node3D) -> Dictionary:
	if not can_handle(unit):
		return {"handled": false, "started": false, "message": ""}
	if bool(unit.call("is_deployed")):
		return try_undeploy(unit)
	if bool(unit.call("is_deploying")):
		return _result(false, "%s is already deploying" % _unit_label(unit))
	if not bool(unit.call("deploy")):
		return _result(false, "%s could not start its deployment" % _unit_label(unit))
	unit.deployment_animation_finished.connect(
		_on_deploy_animation_finished.bind(unit), CONNECT_ONE_SHOT
	)
	return _result(true, "%s deploying" % _unit_label(unit))


## Same toggle entry point handles the reverse direction: `D` or a repeated
## left-click on an already-deployed unit calls try_deploy(), which routes
## here.
func try_undeploy(unit: Node3D) -> Dictionary:
	if not can_handle(unit):
		return {"handled": false, "started": false, "message": ""}
	if bool(unit.call("is_deploying")):
		return _result(false, "%s is already deploying" % _unit_label(unit))
	if not bool(unit.call("is_deployed")):
		return _result(false, "%s is not deployed" % _unit_label(unit))
	if not bool(unit.call("undeploy")):
		return _result(false, "%s could not start its undeployment" % _unit_label(unit))
	unit.deployment_animation_finished.connect(
		_on_undeploy_animation_finished.bind(unit), CONNECT_ONE_SHOT
	)
	return _result(true, "%s undeploying" % _unit_label(unit))


func can_handle(unit: Node3D) -> bool:
	return (
		unit != null
		and unit.has_method("deploy")
		and unit.has_method("undeploy")
		and unit.has_method("is_deploying")
		and unit.has_method("is_deployed")
		and unit.has_method("finish_deployment")
		and _is_combat_deployable(unit)
	)


## Used by the deploy cursor: cheap (no footprint evaluation), so it can
## bypass the MCV-only cursor throttle in UnitCommandController.
func can_issue_deploy(unit: Node3D) -> bool:
	return can_handle(unit) and not bool(unit.call("is_deploying"))


func _on_deploy_animation_finished(unit: Node3D) -> void:
	if unit == null or not is_instance_valid(unit):
		return
	# Nothing is consumed/destroyed by a combat deploy; `true` here means the
	# transition simply completed, landing the unit in DEPLOYED.
	unit.call("finish_deployment", true)


func _on_undeploy_animation_finished(unit: Node3D) -> void:
	if unit == null or not is_instance_valid(unit):
		return
	unit.call("finish_deployment", true)


func _is_combat_deployable(unit: Node3D) -> bool:
	var unit_definition := unit.get("unit_definition") as Resource
	if unit_definition == null:
		return false
	var config_id := StringName(String(unit.get("config_id")))
	if config_id != &"" and _eligibility_cache.has(config_id):
		return bool(_eligibility_cache[config_id])
	var has_travel_gate := false
	var has_deployed_gate := false
	for turret_value: Variant in unit_definition.turret_ids:
		var turret_config := _combat_definition_catalog.turret(StringName(String(turret_value)))
		if turret_config == null:
			continue
		if bool(turret_config.disabled_when_deployed):
			has_travel_gate = true
		if bool(turret_config.disabled_when_undeployed):
			has_deployed_gate = true
	var eligible := has_travel_gate and has_deployed_gate
	if config_id != &"":
		_eligibility_cache[config_id] = eligible
	return eligible


func _unit_label(unit: Node3D) -> String:
	var config_id := String(unit.get("config_id"))
	return config_id if not config_id.is_empty() else "Unit"


func _result(started: bool, message: String) -> Dictionary:
	return {"handled": true, "started": started, "message": message}
