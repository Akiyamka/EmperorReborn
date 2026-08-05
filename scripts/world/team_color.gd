class_name TeamColor
extends RefCounted


static func declares_team_color(mesh_instance: MeshInstance3D) -> bool:
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


static func apply(root: Node, color: Color) -> void:
	if root is MeshInstance3D and declares_team_color(root as MeshInstance3D):
		(root as MeshInstance3D).set_instance_shader_parameter("team_color", color)
	for child in root.get_children():
		apply(child, color)


static func color_for(roster_player, neutral_color: Color) -> Color:
	if roster_player == null or bool(roster_player.get("is_neutral")):
		return neutral_color
	return roster_player.get("team_color") as Color
