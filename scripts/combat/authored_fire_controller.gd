class_name AuthoredFireController
extends RefCounted

const CombatRulesScript := preload("res://scripts/combat/combat_rules.gd")

signal weapon_fired(projectiles: Array, target: Variant, weapon_index: int)

const BAKED_MODEL_FRAMES_PER_SECOND := 20.0
const RULE_COMBAT_TICKS_PER_SECOND := CombatRulesScript.TICKS_PER_SECOND
const FIRE_ANIMATION_SPEED_SCALE := (
	RULE_COMBAT_TICKS_PER_SECOND / BAKED_MODEL_FRAMES_PER_SECOND
)
const FIRE_ANIMATION_PREFIX := "Fire_"
const FIRE_EVENT_EPSILON := 0.0001

var _source: Object
var _turret
var _model_root: Node3D
var _sequence: Dictionary = {}


func configure(source: Object, turret, model_root: Node3D) -> void:
	cancel()
	_source = source
	_turret = turret
	_model_root = model_root


func is_active() -> bool:
	return not _sequence.is_empty()


## Starts the active model's authored Fire clip and commits all projectile
## events in it. Returns false when no clip exists or the reload is not ready;
## callers may use the ordinary one-shot turret fallback only when no clip
## exists (`has_fire_animation` is false).
func try_start(target: Variant) -> bool:
	if is_active() or _turret == null:
		return false
	var binding := _fire_animation_binding()
	if binding.is_empty():
		return false
	var is_continuous: bool = bool(_turret.is_continuous_bullet())
	var starting_new_burst := false
	var ready := false
	if is_continuous and bool(_turret.continuous_burst_active()):
		ready = true
	else:
		ready = bool(_turret.is_ready())
		starting_new_burst = is_continuous and ready
	if not ready:
		return false
	var encoded_target := _encoded_target(target)
	if encoded_target.is_empty():
		return false
	var player := binding["player"] as AnimationPlayer
	var animation_name := StringName(binding["name"])
	var animation := player.get_animation(animation_name)
	if animation == null or animation.length <= 0.0:
		return false
	_sequence = {
		"target": encoded_target,
		"player": player,
		"animation": animation_name,
		"duration": animation.length,
		"elapsed": 0.0,
		"shot_times": _authored_fire_shot_times(
			player, animation, animation_name
		),
		"next_shot": 0,
	}
	_turret.begin_reload()
	if starting_new_burst:
		_turret.begin_continuous_burst()
	player.speed_scale = FIRE_ANIMATION_SPEED_SCALE
	_play_animation_from_start(player, animation_name)
	_turret.start_authored_fire_fx(
		animation_name, null, FIRE_ANIMATION_SPEED_SCALE
	)
	return true


func has_fire_animation() -> bool:
	return not _fire_animation_binding().is_empty()


func advance(delta: float) -> void:
	if _sequence.is_empty():
		return
	var duration := float(_sequence.get("duration", 0.0))
	var elapsed := minf(
		float(_sequence.get("elapsed", 0.0))
			+ maxf(delta, 0.0) * FIRE_ANIMATION_SPEED_SCALE,
		duration
	)
	_sequence["elapsed"] = elapsed
	var shot_times: Array = _sequence.get("shot_times", [])
	var next_shot := int(_sequence.get("next_shot", 0))
	var target: Variant = _decoded_target(_sequence.get("target", {}))
	var damage_scale := 1.0
	if bool(_turret.is_continuous_bullet()) and not shot_times.is_empty():
		damage_scale = 1.0 / float(shot_times.size())
	while (
		next_shot < shot_times.size()
		and float(shot_times[next_shot]) <= elapsed + FIRE_EVENT_EPSILON
	):
		next_shot += 1
		if target == null:
			continue
		var projectiles: Array = _turret.try_fire_at(
			target,
			_source,
			null,
			Vector3.ZERO,
			false,
			false,
			true,
			damage_scale
		)
		if not projectiles.is_empty():
			weapon_fired.emit(projectiles, target, _turret.weapon_index())
	_sequence["next_shot"] = next_shot
	if elapsed + FIRE_EVENT_EPSILON >= duration:
		_finish()


func cancel() -> void:
	if _sequence.is_empty():
		return
	var player := _sequence.get("player") as AnimationPlayer
	if player != null and is_instance_valid(player):
		player.stop(true)
	if _turret != null:
		_turret.cancel_authored_fire_fx()
	_sequence.clear()


func _finish() -> void:
	if _sequence.is_empty():
		return
	var player := _sequence.get("player") as AnimationPlayer
	if player != null and is_instance_valid(player):
		player.stop(true)
	if _turret != null:
		_turret.cancel_authored_fire_fx()
	_sequence.clear()


func _fire_animation_binding() -> Dictionary:
	if _model_root == null or not is_instance_valid(_model_root) or _turret == null:
		return {}
	var preferred := StringName(
		"%s%d" % [FIRE_ANIMATION_PREFIX, _turret.weapon_index()]
	)
	var fallback_candidates: Array[StringName] = [preferred, &"Fire"]
	if _turret.weapon_index() != 0:
		fallback_candidates.append(&"Fire_0")
	for node in _model_root.find_children("*", "AnimationPlayer", true, false):
		var player := node as AnimationPlayer
		for animation_name in fallback_candidates:
			if player.has_animation(animation_name):
				return {"player": player, "name": animation_name}
	return {}


func _play_animation_from_start(
	player: AnimationPlayer, animation_name: StringName
	) -> void:
	player.stop(true)
	player.play(animation_name)
	_apply_animation_start_transforms(player, animation_name)
	if _turret != null:
		_turret.restore_aim_pose()


func _apply_animation_start_transforms(
	player: AnimationPlayer, animation_name: StringName
	) -> void:
	var animation := player.get_animation(animation_name)
	if animation == null:
		return
	for track in animation.get_track_count():
		if animation.track_get_type(track) != Animation.TYPE_VALUE \
		or not String(animation.track_get_path(track)).ends_with(":transform") \
		or animation.track_get_key_count(track) == 0 \
		or animation.track_get_key_time(track, 0) > FIRE_EVENT_EPSILON:
			continue
		var target := _animation_track_node(
			player, String(animation.track_get_path(track))
		) as Node3D
		var value: Variant = animation.track_get_key_value(track, 0)
		if target != null and value is Transform3D:
			target.transform = value as Transform3D


func _animation_track_node(
	player: AnimationPlayer, track_path: String
	) -> Node:
	if player == null:
		return null
	var animation_root := player.get_node_or_null(player.root_node)
	if animation_root == null:
		return null
	var separator := track_path.find(":")
	var node_path := track_path.substr(0, separator) \
		if separator >= 0 else track_path
	return animation_root.get_node_or_null(NodePath(node_path))


func _authored_fire_shot_times(
	player: AnimationPlayer,
	animation: Animation,
	animation_name: StringName
	) -> Array[float]:
	var xbf_events := _xbf_fire_shot_times(animation_name, animation)
	if not xbf_events.is_empty():
		return xbf_events
	var configured_burst := _configured_burst_shot_times(animation)
	if not configured_burst.is_empty():
		return configured_burst
	var fallback: Array[float] = [
		minf(1.0 / BAKED_MODEL_FRAMES_PER_SECOND, animation.length)
	]
	if _turret.muzzle_count() <= 1:
		return fallback
	var animation_root := player.get_node_or_null(player.root_node)
	if animation_root == null:
		return fallback
	var events: Array[Dictionary] = []
	var used_tracks: Dictionary = {}
	for emission: Dictionary in _turret.emission_points():
		var muzzle := emission.get("node") as Node
		if muzzle == null:
			return fallback
		var current := muzzle.get_parent()
		var found := false
		while current != null and (
			current == animation_root or animation_root.is_ancestor_of(current)
		):
			var relative_path := animation_root.get_path_to(current)
			var track_path := NodePath("%s:transform" % String(relative_path))
			var track := animation.find_track(track_path, Animation.TYPE_VALUE)
			if track >= 0:
				var peak := _animation_transform_peak(animation, track)
				if float(peak.get("score", 0.0)) > FIRE_EVENT_EPSILON:
					var track_key := String(track_path)
					if used_tracks.has(track_key):
						return fallback
					used_tracks[track_key] = true
					events.append({
						"muzzle": int(emission.get("index", events.size())),
						"time": clampf(
							float(peak["time"]), 0.0, animation.length
						),
					})
					found = true
					break
			if current == animation_root:
				break
			current = current.get_parent()
		if not found:
			return fallback
	if events.size() != _turret.muzzle_count():
		return fallback
	events.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["time"]) < float(b["time"])
	)
	var result: Array[float] = []
	for event in events:
		result.append(float(event["time"]))
	return result


func _xbf_fire_shot_times(
	animation_name: StringName, animation: Animation
	) -> Array[float]:
	if animation_name.is_empty() or _model_root == null:
		return []
	var motion_root := _find_xbf_motion_root(_model_root)
	if motion_root == null \
	or not bool(motion_root.get_meta("xbf_fx_events_complete", false)):
		return []
	var source_entry := {}
	for entry_value: Variant in motion_root.get_meta(
		"xbf_animation_entries", []
	):
		var entry := entry_value as Dictionary
		var converted_name := String(
			entry.get("name", "")
		).strip_edges().replace(" ", "_")
		if converted_name == String(animation_name):
			source_entry = entry
			break
	if source_entry.is_empty():
		return []
	var start_frame := int(source_entry.get("start_frame", -1))
	var end_frame := int(source_entry.get("end_frame", -1))
	if start_frame < 0 or end_frame < start_frame:
		return []
	var result: Array[float] = []
	for event_value: Variant in motion_root.get_meta("xbf_fx_events", []):
		var event := event_value as Dictionary
		var frame := int(event.get("frame", -1))
		if int(event.get("type", -1)) == 10 \
		and frame >= start_frame and frame <= end_frame:
			result.append(clampf(
				float(frame - start_frame) / BAKED_MODEL_FRAMES_PER_SECOND,
				0.0,
				animation.length
			))
	if (
		result.size() == 1
		and _turret.bullet_config != null
		and bool(_turret.bullet_config.continuous)
	):
		var first_shot_frame := int(round(
			result[0] * BAKED_MODEL_FRAMES_PER_SECOND
		)) + start_frame
		var continuous_result := _xbf_continuous_fire_shot_times(
			motion_root,
			start_frame,
			end_frame,
			animation.length,
			first_shot_frame
		)
		if continuous_result.size() > 1:
			return continuous_result
	if _turret.firing_config != null:
		var configured_count := int(
			_turret.firing_config.burst_shot_count
		)
		if configured_count > 0 and result.size() != configured_count:
			return []
	return result


func _xbf_continuous_fire_shot_times(
	motion_root: Node,
	clip_start: int,
	clip_end: int,
	animation_length: float,
	first_shot_frame: int
	) -> Array[float]:
	var stream_stop_frame := first_shot_frame + 1
	var events := motion_root.get_meta("xbf_fx_events", []) as Array
	for start_value: Variant in events:
		var start_event := start_value as Dictionary
		if String(start_event.get("action", "")) != "start":
			continue
		var start_frame := int(start_event.get("frame", -1))
		if start_frame < clip_start or start_frame > first_shot_frame:
			continue
		var attachment := String(
			start_event.get("attachment", "")
		).to_lower()
		if not attachment.begins_with(">>") and not attachment.contains("gun"):
			continue
		var bank_id := String(start_event.get("bank_id", ""))
		for stop_value: Variant in events:
			var stop_event := stop_value as Dictionary
			if (
				String(stop_event.get("action", "")) != "stop"
				or String(stop_event.get("bank_id", "")) != bank_id
				or String(stop_event.get("attachment", "")).nocasecmp_to(
					String(start_event.get("attachment", ""))
				) != 0
			):
				continue
			var stop_frame := int(stop_event.get("frame", -1))
			if stop_frame > first_shot_frame and stop_frame <= clip_end:
				stream_stop_frame = maxi(stream_stop_frame, stop_frame)
				break
	var result: Array[float] = []
	for frame in range(first_shot_frame, stream_stop_frame):
		result.append(clampf(
			float(frame - clip_start) / BAKED_MODEL_FRAMES_PER_SECOND,
			0.0,
			animation_length
		))
	return result


func _configured_burst_shot_times(
	animation: Animation
	) -> Array[float]:
	if _turret.firing_config == null:
		return []
	var count := int(_turret.firing_config.burst_shot_count)
	if count <= 0:
		return []
	var first_shot_time := minf(
		1.0 / BAKED_MODEL_FRAMES_PER_SECOND, animation.length
	)
	var interval_seconds := maxf(
		float(_turret.firing_config.burst_interval_ticks), 0.0
	) / RULE_COMBAT_TICKS_PER_SECOND
	var result: Array[float] = []
	for index in count:
		result.append(minf(
			first_shot_time + float(index) * interval_seconds,
			animation.length
		))
	return result


func _animation_transform_peak(
	animation: Animation, track: int
	) -> Dictionary:
	if animation.track_get_key_count(track) <= 1:
		return {}
	var rest: Variant = animation.track_get_key_value(track, 0)
	if not rest is Transform3D:
		return {}
	var peak_score := 0.0
	var peak_time := 0.0
	for key_index in animation.track_get_key_count(track):
		var value: Variant = animation.track_get_key_value(track, key_index)
		if not value is Transform3D:
			continue
		var score := _transform_difference(
			rest as Transform3D, value as Transform3D
		)
		if score > peak_score:
			peak_score = score
			peak_time = animation.track_get_key_time(track, key_index)
	return {"score": peak_score, "time": peak_time}


func _transform_difference(a: Transform3D, b: Transform3D) -> float:
	var result := a.origin.distance_to(b.origin)
	result += a.basis.get_scale().distance_to(b.basis.get_scale())
	var relative_basis := (
		a.basis.orthonormalized().inverse()
		* b.basis.orthonormalized()
	)
	result += absf(
		relative_basis.get_rotation_quaternion().get_angle()
	)
	return result


func _find_xbf_motion_root(node: Node) -> Node:
	if node.has_meta("xbf_animation_entries") and node.has_meta("xbf_fx_events"):
		return node
	for child in node.get_children():
		var found := _find_xbf_motion_root(child)
		if found != null:
			return found
	return null


func _encoded_target(target: Variant) -> Dictionary:
	if target is Vector3:
		return {"is_ground": true, "ground": target}
	if target is Object and is_instance_valid(target):
		return {"is_ground": false, "ref": weakref(target as Object)}
	return {}


func _decoded_target(state: Variant) -> Variant:
	if not state is Dictionary or (state as Dictionary).is_empty():
		return null
	if bool((state as Dictionary).get("is_ground", false)):
		return (state as Dictionary).get("ground", Vector3.INF)
	var target_ref := (state as Dictionary).get("ref") as WeakRef
	return target_ref.get_ref() if target_ref != null else null
