class_name NavAgentRegistry
extends RefCounted
## Owns navigation agent creation/removal, movement-profile derivation, and the
## per-tick pruning/ordering of the agent set. `_agents` itself remains a
## Dictionary owned by the facade (`UnitNavigationSystem._agents`); GDScript
## Dictionaries are reference types, so this module receives it as a parameter
## on every call instead of holding its own copy.

## GROUND also covers a flying unit that is currently grounded/landed: it acts
## as a stationary hold-obstacle for ground avoidance until it takes off again
## (see `domain_for`), never as a routed ground agent.
enum Domain { GROUND, AIR }

var _facade: Node
var _next_agent_id := 1


func setup(facade: Node) -> void:
	_facade = facade
	_next_agent_id = 1


func register_unit(agents: Dictionary, unit: Node3D, debug_enabled: bool) -> int:
	if unit == null:
		return 0
	var key := unit.get_instance_id()
	if agents.has(key):
		return int(agents[key]["id"])
	var profile := profile_for(unit)
	var agent := {
		"id": _next_agent_id,
		"unit": unit,
		"radius": profile["radius"],
		"rotation_radius": profile["rotation_radius"],
		"terrain_radius": profile["rotation_radius"],
		"pass_mask": profile["pass_mask"],
		"terrain_mask": profile["terrain_mask"],
		"clearance": profile["clearance"],
		"body_clearance": profile["body_clearance"],
		"rotation_clearance": profile["clearance"],
		"footprint": profile["footprint"],
		"path": [] as Array[Vector2i],
		"path_index": 0,
		# Raw A* cell indices for the current route (before waypoint
		# simplification), used only to test whether a building-blocker
		# change actually crosses this agent's route (see
		# `_agent_route_intersects`). Empty while on a direct line.
		"corridor": PackedInt32Array(),
		"destination": unit.global_position,
		"command_id": 0,
		"mode": UnitNavigationSystem.MoveMode.FREE,
		"group_speed": INF,
		"hold": false,
		"blocked_time": 0.0,
		"reported_enemy": false,
		"avoidance_direction": Vector3.ZERO,
		"avoidance_side": 0,
		"steering_turn_in_place": false,
		"steering_target": unit.global_position,
		# Units issued one group order keep their initial cross-route ordering.
		# The compact A* paths may share a corner cell, but the runtime follower
		# treats it as a gate and gives each body a parallel lane through it.
		"route_lane_offset": 0.0,
		"route_lane_min": 0.0,
		"route_lane_max": 0.0,
		"yield_direction": Vector3.ZERO,
		"yield_remaining": 0.0,
		"direct_path": false,
		"exit_point": Vector3.INF,
		"reserved": true,
		"claim_radius": 0.0,
		"claim_center": unit.global_position,
		"swap_tick": -1000,
		# An ordinary order may deliberately end on traversable no-stop space.
		# Once that first leg arrives, navigation immediately parks the unit on
		# the nearest ordinary stopping block.
		"vacate_no_stop": false,
		# A harvester leaving a refinery temporarily keeps access to that
		# refinery's d/p cells. The exception is dropped as soon as its complete
		# footprint reaches ordinary stoppable ground.
		"departure_access": false,
		# Per-order exception used only while a harvester enters its reserved
		# refinery pad. Ordinary commands always clear it.
		"allowed_cells": {},
	}
	agent["domain"] = domain_for(agent)
	agents[key] = agent
	_next_agent_id += 1
	# A flying unit never routes through the ground A*/avoidance grid profile
	# (airborne: its own straight-line air pipeline; grounded: a stationary
	# hold-obstacle that never plans a route) — prewarming one for it would
	# just be a wasted grid bake.
	if int(profile["pass_mask"]) != MapNavigationGrid.PASS_AIR:
		_facade.planner.prewarm(int(profile["pass_mask"]), int(profile["clearance"]), int(profile["terrain_mask"]))
		_facade.avoidance.prewarm(int(profile["pass_mask"]), int(profile["terrain_mask"]))
	unit.set_meta(&"navigation_agent_id", agent["id"])
	if unit.has_method("set_navigation_managed"):
		unit.call("set_navigation_managed", true)
	if unit.has_method("set_navigation_controller"):
		unit.call("set_navigation_controller", _facade)
	if unit.has_method("set_navigation_debug_visible"):
		unit.call("set_navigation_debug_visible", debug_enabled)
	return int(agent["id"])


func unregister_unit(agents: Dictionary, unit: Node3D) -> void:
	if unit == null:
		return
	if unit.has_method("set_navigation_debug_visible"):
		unit.call("set_navigation_debug_visible", false)
	agents.erase(unit.get_instance_id())


func profile_for(unit: Node3D) -> Dictionary:
	var config = unit.get("unit_definition")
	var infantry := bool(config.infantry) if config != null else false
	var can_fly := bool(config.can_fly) if config != null else false
	var size := float(config.size) if config != null else 1.0
	var radius := maxf(0.35, size * 0.42)
	if unit.has_method("navigation_collision_radius"):
		radius = float(unit.call("navigation_collision_radius", radius))
	var rotation_radius := radius
	if unit.has_method("navigation_rotation_radius"):
		rotation_radius = maxf(
			radius, float(unit.call("navigation_rotation_radius", rotation_radius))
		)
	var cell_size: Vector2 = _facade.runtime_map.grid.cell_size()
	var body_clearance := maxi(
		0,
		int(ceil(radius / maxf(minf(cell_size.x, cell_size.y), 0.001))) - 1
	)
	var clearance := maxi(
		0,
		int(ceil(rotation_radius / maxf(minf(cell_size.x, cell_size.y), 0.001))) - 1
	)
	var pass_mask := MapNavigationGrid.PASS_AIR if can_fly else (MapNavigationGrid.PASS_INFANTRY if infantry else MapNavigationGrid.PASS_VEHICLE)
	# A flying unit's authored Terrain list constrains only where it may land,
	# never where it may fly — leave it unrestricted here so routing never
	# detours around terrain types (e.g. InfantryRock) that only matter to
	# ground movement classes.
	var terrain_mask_value := 0 if can_fly else terrain_mask(config.terrain_ids if config != null else [])
	# `size` is the side of the unit's square footprint in navigation cells;
	# destinations are always the center of a free size x size cell block.
	var footprint := maxi(1, roundi(size))
	return {
		"radius": radius,
		"rotation_radius": rotation_radius,
		"body_clearance": body_clearance,
		"clearance": clearance,
		"pass_mask": pass_mask,
		"terrain_mask": terrain_mask_value,
		"footprint": footprint,
	}


func terrain_mask(names: Array) -> int:
	var result := 0
	for value in names:
		match String(value).to_lower():
			"sand": result |= 1 << MapNavigationGrid.TERRAIN_SAND
			"rock": result |= 1 << MapNavigationGrid.TERRAIN_ROCK
			"cliff": result |= 1 << MapNavigationGrid.TERRAIN_CLIFF
			"nbrock", "nonbuildrock": result |= 1 << MapNavigationGrid.TERRAIN_NONBUILDROCK
			"infrock", "infantryrock": result |= 1 << MapNavigationGrid.TERRAIN_INFANTRYROCK
			"dustbowl": result |= 1 << MapNavigationGrid.TERRAIN_DUSTBOWL
			"ramp": result |= 1 << MapNavigationGrid.TERRAIN_RAMP
	return result


func movement_probe_for(agents: Dictionary, unit: Node3D) -> Dictionary:
	var registered := agent_for(agents, unit)
	if not registered.is_empty():
		return {
			"clearance": registered["rotation_clearance"],
			"pass_mask": registered["pass_mask"],
			"terrain_mask": registered["terrain_mask"],
			"footprint": registered["footprint"],
			"allowed_cells": {},
		}
	var profile := profile_for(unit)
	return {
		"clearance": profile["clearance"],
		"pass_mask": profile["pass_mask"],
		"terrain_mask": profile["terrain_mask"],
		"footprint": profile["footprint"],
		"allowed_cells": {},
	}


func prune_agents(agents: Dictionary) -> void:
	for key in agents.keys():
		var unit = agents[key]["unit"]
		if not is_instance_valid(unit) or unit.is_queued_for_deletion():
			agents.erase(key)


func agent_for(agents: Dictionary, unit: Node3D) -> Dictionary:
	if unit == null:
		return {}
	return agents.get(unit.get_instance_id(), {})


func ordered_agents(agents: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for value in agents.values():
		result.append(value)
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["id"]) < int(b["id"]))
	return result


func set_agent_rotation_envelope(agent: Dictionary, active: bool) -> void:
	agent["terrain_radius"] = agent["rotation_radius"] if active else agent["radius"]
	agent["clearance"] = agent["rotation_clearance"] \
		if active else agent["body_clearance"]


## AIR only while a flying agent is actually taking off/cruising/hovering/
## landing; a landed (or non-flying) unit is GROUND, regardless of pass mask —
## it sits still and participates in ground avoidance as a hold-obstacle
## instead of being routed by either pipeline. Recomputed every tick: takeoff/
## landing transitions only last ~1.5s, so this is cheap enough to just always
## reflect the unit's live flight phase instead of caching it across an order.
func domain_for(agent: Dictionary) -> int:
	if int(agent["pass_mask"]) != MapNavigationGrid.PASS_AIR:
		return Domain.GROUND
	var unit: Node3D = agent.get("unit")
	if unit != null and unit.has_method("flight_is_airborne_phase") \
	and not bool(unit.call("flight_is_airborne_phase")):
		return Domain.GROUND
	return Domain.AIR


func update_domains(agents_list: Array[Dictionary]) -> void:
	for agent in agents_list:
		agent["domain"] = domain_for(agent)
