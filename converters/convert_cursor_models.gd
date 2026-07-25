extends SceneTree

const ModelBakeBuilderScript := preload("res://converters/model_bake_builder.gd")
const CursorModelCatalogScript := preload("res://scripts/ui/cursor_model_catalog.gd")

const NORMAL_RENDER_LAYER := 1
const SCREEN_RENDER_LAYER := 2
# Move, Attack, and Deploy author their blue rings as ordinary
# `whitering2.TGA` even though the original cursor renderer treats those
# surfaces as screen effects. Keep these exceptions source-specific: the same
# shared texture is used normally by many other cursor XBFs.
const SCREEN_SURFACE_QUIRKS := {
	"cu_move_h0.xbf": {"whitering2.tga": true},
	"cu_attack_h0.xbf": {"whitering2.tga": true},
	"cu_deploy_h0.xbf": {"whitering2.tga": true},
}
const CURSOR_TIMELINE_LENGTH_OVERRIDES := {
	# The authored PlaceFlag rotation completes its seamless clockwise cycle in
	# the first eight 20 Hz frames. Later keys continue into a different pose,
	# so wrapping the full movement creates a visible jump.
	&"place_flag": 0.4,
}


func _initialize() -> void:
	var converted := 0
	var model_keys: Array = CursorModelCatalogScript.MODEL_FILES.keys()
	model_keys.sort()
	for value in model_keys:
		var model_key := StringName(value)
		var source_path := CursorModelCatalogScript.source_path(model_key)
		if not FileAccess.file_exists(source_path):
			_fail("missing original cursor model: %s" % source_path)
			return

		var builder = ModelBakeBuilderScript.new()
		builder.world_scale = CursorModelCatalogScript.MODEL_SCALE
		var scene: PackedScene = builder.build(source_path)
		if scene == null:
			_fail("could not convert %s" % source_path)
			return
		scene = _prepare_cursor_timeline(
			scene,
			builder.fps,
			float(CURSOR_TIMELINE_LENGTH_OVERRIDES.get(model_key, 0.0))
		)
		if scene == null:
			_fail("could not trim cursor animation in %s" % source_path)
			return
		if not builder.missing_textures.is_empty():
			_fail(
				"%s is missing textures: %s"
				% [source_path, ", ".join(builder.missing_textures)]
			)
			return

		scene = _split_screen_surfaces(scene, source_path.get_file())
		if scene == null:
			_fail("could not split cursor render passes for %s" % source_path)
			return

		var output_path := CursorModelCatalogScript.output_path(model_key)
		var output_absolute := ProjectSettings.globalize_path(output_path)
		var directory_error := DirAccess.make_dir_recursive_absolute(output_absolute.get_base_dir())
		if directory_error != OK:
			_fail(
				"could not create %s (%s)"
				% [output_path.get_base_dir(), error_string(directory_error)]
			)
			return
		var save_error := ResourceSaver.save(scene, output_path)
		if save_error != OK:
			_fail("could not save %s (%s)" % [output_path, error_string(save_error)])
			return
		converted += 1

	print("Converted %d original 3D cursor models" % converted)
	quit(0)


## Some cursor XBFs pad one object's transform track with hundreds of identical
## keys. ModelBakeBuilder correctly preserves that raw timeline, but for a
## looping cursor this creates a long visual pause after all motion has ended.
## Retain one source frame after the final actual change, then wrap.
func _prepare_cursor_timeline(
	source_scene: PackedScene, fps: float, length_override: float
) -> PackedScene:
	var root := source_scene.instantiate() as Node3D
	if root == null:
		return null
	for node in root.find_children("*", "AnimationPlayer", true, false):
		var player := node as AnimationPlayer
		if not player.has_animation(&"timeline"):
			continue
		var animation := player.get_animation(&"timeline")
		if length_override > 0.0:
			animation.length = length_override
			continue
		var last_change_time := 0.0
		for track in animation.get_track_count():
			var previous: Variant = null
			for key in animation.track_get_key_count(track):
				var value: Variant = animation.track_get_key_value(track, key)
				if previous == null or not _animation_values_equal(value, previous):
					last_change_time = maxf(
						last_change_time, animation.track_get_key_time(track, key)
					)
				previous = value
		var trimmed_length := maxf(last_change_time + 1.0 / fps, 1.0 / fps)
		if trimmed_length < animation.length:
			animation.length = trimmed_length
	var result := PackedScene.new()
	var pack_error := result.pack(root)
	root.free()
	return result if pack_error == OK else null


func _animation_values_equal(a: Variant, b: Variant) -> bool:
	if typeof(a) != typeof(b):
		return false
	if a is Transform3D:
		return (a as Transform3D).is_equal_approx(b as Transform3D)
	if a is Vector3:
		return (a as Vector3).is_equal_approx(b as Vector3)
	if a is Quaternion:
		return (a as Quaternion).is_equal_approx(b as Quaternion)
	if a is Color:
		return (a as Color).is_equal_approx(b as Color)
	if a is float:
		return is_equal_approx(a as float, b as float)
	return a == b


func _fail(message: String) -> void:
	printerr("3D cursor conversion failed: %s" % message)
	quit(1)


## XBF's `!` texture prefix marks a surface for screen/additive composition.
## A single XBF mesh can mix marked and ordinary surfaces, so split those
## surfaces into child MeshInstance3Ds that cameras can select independently.
func _split_screen_surfaces(source_scene: PackedScene, source_file: String) -> PackedScene:
	var root := source_scene.instantiate() as Node3D
	if root == null:
		return null

	var mesh_instances: Array[Node] = root.find_children("*", "MeshInstance3D", true, false)
	for node in mesh_instances:
		var mesh_instance := node as MeshInstance3D
		var source_mesh := mesh_instance.mesh as ArrayMesh
		if source_mesh == null or source_mesh.get_surface_count() == 0:
			continue

		var normal_mesh := _filtered_mesh(source_mesh, false, source_file)
		var screen_mesh := _filtered_mesh(source_mesh, true, source_file)
		mesh_instance.layers = NORMAL_RENDER_LAYER
		mesh_instance.mesh = normal_mesh
		if screen_mesh.get_surface_count() == 0:
			continue

		var screen_instance := MeshInstance3D.new()
		screen_instance.name = "ScreenPass"
		screen_instance.layers = SCREEN_RENDER_LAYER
		screen_instance.mesh = screen_mesh
		screen_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		screen_instance.set_meta("cursor_screen_pass", true)
		mesh_instance.add_child(screen_instance)
		screen_instance.owner = root

	var result := PackedScene.new()
	var pack_error := result.pack(root)
	root.free()
	return result if pack_error == OK else null


func _filtered_mesh(source: ArrayMesh, keep_screen: bool, source_file: String) -> ArrayMesh:
	var filtered := source.duplicate(true) as ArrayMesh
	for surface in range(filtered.get_surface_count() - 1, -1, -1):
		if _is_screen_surface(source, surface, source_file) != keep_screen:
			filtered.surface_remove(surface)
	return filtered


func _is_screen_surface(mesh: ArrayMesh, surface: int, source_file: String) -> bool:
	if _is_screen_material(mesh.surface_get_material(surface)):
		return true
	var source_quirks: Dictionary = SCREEN_SURFACE_QUIRKS.get(source_file.to_lower(), {})
	return bool(source_quirks.get(mesh.surface_get_name(surface).to_lower(), false))


func _is_screen_material(material: Material) -> bool:
	if material is BaseMaterial3D:
		return (material as BaseMaterial3D).blend_mode == BaseMaterial3D.BLEND_MODE_ADD
	if material is ShaderMaterial:
		var shader := (material as ShaderMaterial).shader
		return shader != null and shader.code.contains("blend_add")
	return false
