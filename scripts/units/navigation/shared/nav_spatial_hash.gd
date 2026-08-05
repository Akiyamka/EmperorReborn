class_name NavSpatialHash
extends RefCounted
## Uniform-grid spatial hash of navigation agents, rebuilt once per navigation
## tick and queried per agent for nearby-agent candidate lists.

const NavConstantsScript := preload("res://scripts/units/navigation/shared/nav_constants.gd")


func build(agents: Array[Dictionary]) -> Dictionary:
	var buckets := {}
	for agent in agents:
		var unit: Node3D = agent["unit"]
		var key := bucket_key(unit.global_position)
		if not buckets.has(key):
			buckets[key] = []
		buckets[key].append(agent)
	return buckets


func nearby(position: Vector3, buckets: Dictionary, search_radius := NavConstantsScript.CELL_BUCKET_SIZE) -> Array:
	var center := bucket_key(position)
	var result := []
	var bucket_radius := maxi(1, ceili(search_radius / NavConstantsScript.CELL_BUCKET_SIZE))
	for y in range(-bucket_radius, bucket_radius + 1):
		for x in range(-bucket_radius, bucket_radius + 1):
			result.append_array(buckets.get(center + Vector2i(x, y), []))
	return result


func bucket_key(position: Vector3) -> Vector2i:
	return Vector2i(
		floori(position.x / NavConstantsScript.CELL_BUCKET_SIZE),
		floori(position.z / NavConstantsScript.CELL_BUCKET_SIZE)
	)
