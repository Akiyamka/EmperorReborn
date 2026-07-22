class_name BuildingBakeBuilder
extends RefCounted

const ModelBakeBuilderScript := preload("res://converters/model_bake_builder.gd")
const BuildingScript := preload("res://scripts/buildings/building.gd")

const BUILDING_MODEL_DIR := "res://assets/raw_original_content/3DDATA/Buildings"
const DEFAULT_TEXTURE_DIR := "res://assets/raw_original_content/3DDATA/Textures"
const BUILDING_RULES_DIR := "res://assets/converted/rules/buildings"
## One occupy cell spans 2.0 world units (Building.OCCUPY_CELL_WORLD_SPAN).
const OCCUPY_CELL_WORLD_SPAN := 2.0
## Building art is authored slightly smaller than the placement pitch used by
## the original renderer. AT_Helipad's 64x96-unit Mesh_00 is the calibration
## reference: adjacent 2x3 pads occupy 72x108 model units, giving 9/8.
const BUILDING_WORLD_SCALE := 0.0625 * 1.125

const STATE_DEFS: Array[Dictionary] = [
	{"name": "construction", "node": "Build", "suffix": "_hc"},
	{"name": "idle", "node": "Idle", "suffix": "_h0"},
	{"name": "damage1", "node": "Damage1", "suffix": "_h1"},
	{"name": "damage2", "node": "Damage2", "suffix": "_h2"},
	{"name": "destroy", "node": "Destroy", "suffix": "_h3"},
]
## HC contains the authored transition clips. Most buildings expose only
## Construct; Construction Yards additionally expose Deconstruct and Sell,
## while wall HC models also carry Sell. Runtime names are deliberately
## lowercase and describe the action rather than the source H-state.
const CONSTRUCTION_ACTIONS := {
	&"construct": &"Construct",
	&"deconstruct": &"Deconstruct",
	&"sell": &"Sell",
}

var building_model_dir := BUILDING_MODEL_DIR
var source_texture_dir := DEFAULT_TEXTURE_DIR
var texture_output_dir := ""
var fps := 20.0
var world_scale := BUILDING_WORLD_SCALE
var source_prefix := ""

var missing_textures: PackedStringArray = []
var imported_files: PackedStringArray = []
var missing_states: PackedStringArray = []


func build(building_id: StringName) -> PackedScene:
	missing_textures = PackedStringArray()
	imported_files = PackedStringArray()
	missing_states = PackedStringArray()

	var prefix := source_prefix
	if prefix.is_empty():
		prefix = _building_prefix_from_id(String(building_id))

	var state_files := _find_state_files(prefix)
	if not state_files.has("idle"):
		push_error("BuildingBakeBuilder: no idle H0 model found for %s using prefix %s in %s" % [String(building_id), prefix, building_model_dir])
		return null

	var root := Node3D.new()
	root.name = String(building_id)
	root.set_script(BuildingScript)
	root.add_to_group("buildings")
	root.set("config_id", building_id)
	root.set_meta("building_id", String(building_id))
	root.set_meta("source_prefix", prefix)

	var states_root := Node3D.new()
	states_root.name = "States"
	root.add_child(states_root)

	var state_nodes: Array[Node3D] = []
	for state_def: Dictionary in STATE_DEFS:
		var state_name := String(state_def["name"])
		if not state_files.has(state_name):
			missing_states.append(state_name)
			continue

		var node := _build_state_node(state_def, String(state_files[state_name]))
		if node == null:
			return null
		node.visible = state_name == "idle"
		states_root.add_child(node)
		state_nodes.append(node)

	states_root.position = _footprint_alignment_offset(building_id, state_nodes)
	_add_state_player(root, states_root, state_nodes)
	_assign_scene_owner(root, root)

	var scene := PackedScene.new()
	var err := scene.pack(root)
	root.free()
	if err != OK:
		push_error("BuildingBakeBuilder: could not pack building scene (%s)" % error_string(err))
		return null
	return scene


## Source models are not authored around the occupy-matrix centre, while the
## runtime lays the matrix out symmetrically around the building's position.
## The authored #~~0 collision volume outlines the building's physical body,
## and its rear (-Z) face is flush with the matrix's rear edge - the front
## face is unreliable because porches/aprons overhang the skirt. So the model
## is shifted to put the collision's rear edge on the matrix's rear edge, and
## centred on X where the matrix is always symmetric. The idle (H0) state
## carries the canonical volume; the SLCT selection volume stands in for
## models without one, mirroring Building's own collision-source fallback.
func _footprint_alignment_offset(building_id: StringName, state_nodes: Array[Node3D]) -> Vector3:
	var idle: Node3D = null
	for node in state_nodes:
		if String(node.get_meta("state", "")) == "idle":
			idle = node
	if idle == null:
		return Vector3.ZERO
	var bounds_variant: Variant = _collision_points_bounds(idle, "#~~0", false)
	if bounds_variant == null:
		bounds_variant = _collision_points_bounds(idle, "slct", true)
	if bounds_variant == null:
		return Vector3.ZERO
	var bounds := bounds_variant as AABB
	var offset := Vector3(-bounds.get_center().x, 0.0, -bounds.get_center().z)
	var occupy_depth := _occupy_depth(building_id)
	if occupy_depth > 0:
		var matrix_rear := -float(occupy_depth) * OCCUPY_CELL_WORLD_SPAN * 0.5
		offset.z = matrix_rear - bounds.position.z
	return offset


func _occupy_depth(building_id: StringName) -> int:
	var config_path := BUILDING_RULES_DIR.path_join("%s.tres" % String(building_id))
	if not ResourceLoader.exists(config_path):
		return 0
	var config := load(config_path)
	if config == null or not config.has_method("list"):
		return 0
	return (config.call("list", &"occupy_rows") as Array).size()


## Returns the AABB of every matching descendant's collision_points in the
## state node's parent space (the space the States offset is applied in), or
## null when no descendant carries a usable volume.
func _collision_points_bounds(idle: Node3D, original_name: String, prefix_match: bool):
	var bounds := AABB()
	var has_bounds := false
	var stack: Array = [idle]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.push_back(child)
		if not (node is Node3D):
			continue
		var source_name := String(node.get_meta("original_name", "")).to_lower()
		var matches := source_name.begins_with(original_name) if prefix_match else source_name == original_name
		if not matches:
			continue
		var points: PackedVector3Array = node.get_meta("collision_points", PackedVector3Array())
		if points.size() < 4:
			continue
		var to_states := _transform_relative_to_parent_of(node, idle)
		for point in points:
			var local := to_states * point
			if has_bounds:
				bounds = bounds.expand(local)
			else:
				bounds = AABB(local, Vector3.ZERO)
				has_bounds = true
	return bounds if has_bounds else null


func _transform_relative_to_parent_of(node: Node3D, ancestor: Node3D) -> Transform3D:
	var result := Transform3D.IDENTITY
	var current: Node = node
	while current != null and current != ancestor.get_parent():
		if current is Node3D:
			result = (current as Node3D).transform * result
		current = current.get_parent()
	return result


func _build_state_node(state_def: Dictionary, xbf_path: String) -> Node3D:
	var builder = ModelBakeBuilderScript.new()
	builder.source_texture_dir = source_texture_dir
	builder.texture_output_dir = texture_output_dir
	builder.fps = fps
	builder.world_scale = world_scale

	var scene: PackedScene = builder.build(xbf_path)
	if scene == null:
		return null

	var node := scene.instantiate() as Node3D
	if node == null:
		push_error("BuildingBakeBuilder: converted state is not Node3D: %s" % xbf_path)
		return null

	node.name = String(state_def["node"])
	node.set_meta("state", String(state_def["name"]))
	node.set_meta("source_xbf", xbf_path)
	imported_files.append(xbf_path)
	for texture_name in builder.missing_textures:
		if not missing_textures.has(texture_name):
			missing_textures.append(texture_name)
	return node


func _find_state_files(prefix: String) -> Dictionary:
	var found := {}
	var dir := DirAccess.open(building_model_dir)
	if dir == null:
		push_error("BuildingBakeBuilder: cannot open %s" % building_model_dir)
		return found

	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if not dir.current_is_dir() and file_name.get_extension().to_lower() == "xbf":
			for state_def: Dictionary in STATE_DEFS:
				var state_name := String(state_def["name"])
				if not found.has(state_name) and _matches_state_file(file_name, prefix, String(state_def["suffix"])):
					found[state_name] = building_model_dir.path_join(file_name)
		file_name = dir.get_next()
	dir.list_dir_end()
	return found


func _matches_state_file(file_name: String, prefix: String, suffix: String) -> bool:
	var stem := file_name.get_basename().to_lower()
	if not stem.ends_with(suffix):
		return false
	var model_name := stem.substr(0, stem.length() - suffix.length())
	return _normalized_model_name(model_name) == _normalized_model_name(prefix)


func _building_prefix_from_id(building_id: String) -> String:
	var aliases := {
		"ATBarracks": "at_barracks",
		"ATSmWindtrap": "AT_Windtrap",
	}
	if aliases.has(building_id):
		return aliases[building_id]

	if building_id.length() <= 2:
		return building_id.to_lower()

	var house_prefix := building_id.substr(0, 2)
	var model_name := building_id.substr(2)
	var snake := _camel_to_snake(model_name)
	snake = snake.replace("con_yard", "conyard")
	return "%s_%s" % [house_prefix.to_lower(), snake]


func _camel_to_snake(value: String) -> String:
	var result := ""
	for i in value.length():
		var ch := value.substr(i, 1)
		var code := value.unicode_at(i)
		var is_upper := code >= 65 and code <= 90
		if is_upper and i > 0:
			result += "_"
		result += ch.to_lower()
	return result


func _normalized_model_name(value: String) -> String:
	return value.to_lower().replace("_", "").replace(" ", "")


func _add_state_player(root: Node3D, states_root: Node3D, state_nodes: Array[Node3D]) -> void:
	var player := AnimationPlayer.new()
	player.name = "StatePlayer"

	var library := AnimationLibrary.new()
	for active_node in state_nodes:
		var state_name := String(active_node.get_meta("state", active_node.name.to_lower()))
		if state_name == "construction":
			var added_construct := false
			for action_name: StringName in CONSTRUCTION_ACTIONS:
				var source_name: StringName = CONSTRUCTION_ACTIONS[action_name]
				var action_source := _named_state_source_animation(active_node, source_name)
				if action_source == null:
					continue
				library.add_animation(
					action_name,
					_state_animation(action_name, active_node, state_nodes, action_source, false)
				)
				added_construct = added_construct or action_name == &"construct"
			# Models without a named FX table entry still retain their usable HC
			# timeline under the construction action contract.
			if not added_construct:
				library.add_animation(
					&"construct",
					_state_animation(
						&"construct", active_node, state_nodes,
						_state_source_animation(active_node), false
					)
				)
			continue

		var source_animation := _state_source_animation(active_node)
		library.add_animation(
			state_name,
			_state_animation(
				StringName(state_name), active_node, state_nodes, source_animation,
				source_animation != null
			)
		)

	player.add_animation_library("", library)
	player.autoplay = "idle" if library.has_animation("idle") else String(state_nodes[0].get_meta("state", ""))
	root.add_child(player)


func _state_animation(
		animation_name: StringName,
		active_node: Node3D,
		state_nodes: Array[Node3D],
		source_animation: Animation,
		preserve_loop_mode: bool
	) -> Animation:
	var animation := Animation.new()
	animation.resource_name = String(animation_name)
	animation.length = maxf(source_animation.length if source_animation != null else 0.1, 0.1)
	animation.loop_mode = source_animation.loop_mode \
		if preserve_loop_mode and source_animation != null else Animation.LOOP_NONE
	for node in state_nodes:
		var track := animation.add_track(Animation.TYPE_VALUE)
		animation.track_set_path(track, NodePath("States/%s:visible" % node.name))
		animation.track_set_interpolation_type(track, Animation.INTERPOLATION_NEAREST)
		animation.value_track_set_update_mode(track, Animation.UPDATE_DISCRETE)
		animation.track_insert_key(track, 0.0, node == active_node)
	if source_animation != null:
		_copy_animation_tracks(
			source_animation, animation, "States/%s" % active_node.name
		)
	return animation


func _named_state_source_animation(
		state_node: Node3D, requested_name: StringName
	) -> Animation:
	var player := state_node.get_node_or_null("AnimationPlayer") as AnimationPlayer
	if player == null:
		return null
	for animation_name in player.get_animation_list():
		if String(animation_name).to_lower() == String(requested_name).to_lower():
			return player.get_animation(animation_name)
	return null


func _state_source_animation(state_node: Node3D) -> Animation:
	var player := state_node.get_node_or_null("AnimationPlayer") as AnimationPlayer
	if player == null:
		return null
	# H0 can also contain action clips for independently controlled building
	# parts. The idle state must use the authored Stationary clip, never a
	# longer pad/door/action clip selected merely by duration.
	if String(state_node.get_meta("state", "")) == "idle" and player.has_animation("Stationary"):
		return player.get_animation("Stationary")
	# "timeline" is the raw, unsliced union track ModelBakeBuilder always
	# produces as a slicing source; every other clip name comes straight from
	# the source xbf's own FX animation table (e.g. "Stationary", "Explode",
	# "Construct", ...) and carries that table's authored duration. Any of those
	# beats "timeline" as the state's clip, so pick the longest one instead of
	# hardcoding a couple of expected names - a model whose table entry isn't
	# named "Stationary" (H3's "Explode", for instance) must not silently fall
	# back to the ~1-frame "timeline" and look like it has no animation at all.
	var best: Animation = null
	for animation_name in player.get_animation_list():
		if animation_name == "timeline":
			continue
		var candidate := player.get_animation(animation_name)
		if best == null or candidate.length > best.length:
			best = candidate
	if best != null:
		return best
	if player.has_animation("timeline"):
		return player.get_animation("timeline")
	return null


func _copy_animation_tracks(source: Animation, target: Animation, path_prefix: String) -> void:
	for source_track in source.get_track_count():
		var track := target.add_track(source.track_get_type(source_track))
		target.track_set_path(track, NodePath("%s/%s" % [path_prefix, String(source.track_get_path(source_track))]))
		target.track_set_interpolation_type(track, source.track_get_interpolation_type(source_track))
		if source.track_get_type(source_track) == Animation.TYPE_VALUE:
			target.value_track_set_update_mode(track, source.value_track_get_update_mode(source_track))

		for key_index in source.track_get_key_count(source_track):
			target.track_insert_key(
				track,
				source.track_get_key_time(source_track, key_index),
				source.track_get_key_value(source_track, key_index),
				source.track_get_key_transition(source_track, key_index)
			)


func _assign_scene_owner(node: Node, scene_root: Node) -> void:
	for child in node.get_children():
		child.owner = scene_root
		_assign_scene_owner(child, scene_root)
