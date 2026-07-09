class_name BuildingBakeBuilder
extends RefCounted

const ModelBakeBuilderScript := preload("res://importers/model_bake_builder.gd")
const RTSBuildingScript := preload("res://scripts/rts_building.gd")

const BUILDING_MODEL_DIR := "res://assets/unpacked_rfd/3DDATA/Buildings"
const DEFAULT_TEXTURE_DIR := "res://assets/unpacked_rfd/3DDATA/Textures"

const STATE_DEFS: Array[Dictionary] = [
	{"name": "build", "node": "Build", "suffix": "_hc"},
	{"name": "idle", "node": "Idle", "suffix": "_h0"},
	{"name": "damage1", "node": "Damage1", "suffix": "_h1"},
	{"name": "damage2", "node": "Damage2", "suffix": "_h2"},
	{"name": "destroy", "node": "Destroy", "suffix": "_h3"},
]

var building_model_dir := BUILDING_MODEL_DIR
var source_texture_dir := DEFAULT_TEXTURE_DIR
var texture_output_dir := ""
var fps := 20.0
var world_scale := 0.0625
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
	root.set_script(RTSBuildingScript)
	root.add_to_group("rts_buildings")
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

	_add_state_player(root, states_root, state_nodes)
	_assign_scene_owner(root, root)

	var scene := PackedScene.new()
	var err := scene.pack(root)
	root.free()
	if err != OK:
		push_error("BuildingBakeBuilder: could not pack building scene (%s)" % error_string(err))
		return null
	return scene


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
		var anim := Animation.new()
		anim.resource_name = state_name
		var source_animation := _state_source_animation(active_node)
		anim.length = maxf(source_animation.length if source_animation != null else 0.1, 0.1)
		var loop_mode := Animation.LOOP_NONE
		if state_name != "build" and source_animation != null:
			loop_mode = source_animation.loop_mode
		anim.loop_mode = loop_mode

		for node in state_nodes:
			var track := anim.add_track(Animation.TYPE_VALUE)
			anim.track_set_path(track, NodePath("States/%s:visible" % node.name))
			anim.track_set_interpolation_type(track, Animation.INTERPOLATION_NEAREST)
			anim.value_track_set_update_mode(track, Animation.UPDATE_DISCRETE)
			anim.track_insert_key(track, 0.0, node == active_node)

		if source_animation != null:
			_copy_animation_tracks(source_animation, anim, "States/%s" % active_node.name)

		library.add_animation(state_name, anim)

	player.add_animation_library("", library)
	player.autoplay = "idle" if library.has_animation("idle") else String(state_nodes[0].get_meta("state", ""))
	root.add_child(player)


func _state_source_animation(state_node: Node3D) -> Animation:
	var player := state_node.get_node_or_null("AnimationPlayer") as AnimationPlayer
	if player == null:
		return null
	# "timeline" is the raw, unsliced union track ModelBakeBuilder always
	# produces as a slicing source; every other clip name comes straight from
	# the source xbf's own FX animation table (e.g. "Stationary", "Explode",
	# "Build", ...) and carries that table's authored duration. Any of those
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
