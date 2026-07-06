extends CanvasLayer
## Debug panel with live sliders for terrain shader and lighting parameters.
## Toggle with F1. Values apply immediately to the loaded map's materials
## and lights; "Print" dumps current values to the console for copying
## back into the scripts as new defaults.

@export var terrain_path: NodePath
@export var sun_path: NodePath
@export var environment_path: NodePath

var _terrain: MapLoader
var _sun: DirectionalLight3D
var _environment: WorldEnvironment

var _values := {
	"tone_scale": 3.0,
	"tone_saturation": 0.0,
	"tone_alpha_gain": 1.5,
	"sun_energy": 1.0,
	"ambient_energy": 1.0,
	"light_saturation": 1.0,
}
var _panel: PanelContainer
var _sun_color_button: ColorPickerButton


func _ready() -> void:
	_terrain = get_node_or_null(terrain_path)
	_sun = get_node_or_null(sun_path)
	_environment = get_node_or_null(environment_path)
	_build_ui()
	_panel.visible = false


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_F1:
		_panel.visible = not _panel.visible
		get_viewport().set_input_as_handled()


func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.anchor_left = 1.0
	_panel.anchor_right = 1.0
	_panel.offset_left = -340.0
	_panel.offset_top = 80.0
	_panel.offset_right = -16.0
	add_child(_panel)

	var vbox := VBoxContainer.new()
	_panel.add_child(vbox)

	var title := Label.new()
	title.text = "Terrain tuning (F1)"
	vbox.add_child(title)

	_add_slider(vbox, "tone_scale", 0.0, 5.0)
	_add_slider(vbox, "tone_saturation", 0.0, 1.0)
	_add_slider(vbox, "tone_alpha_gain", 0.0, 4.0)
	_add_slider(vbox, "sun_energy", 0.0, 3.0)
	_add_slider(vbox, "ambient_energy", 0.0, 3.0)
	_add_slider(vbox, "light_saturation", 0.0, 1.0)

	var sun_color_label := Label.new()
	sun_color_label.text = "sun_color"
	vbox.add_child(sun_color_label)
	_sun_color_button = ColorPickerButton.new()
	_sun_color_button.custom_minimum_size = Vector2(300, 28)
	if _sun != null:
		_sun_color_button.color = _sun.light_color
	_sun_color_button.color_changed.connect(func(color: Color) -> void:
		if _sun != null:
			_sun.light_color = color
	)
	vbox.add_child(_sun_color_button)

	var print_button := Button.new()
	print_button.text = "Print values to console"
	print_button.pressed.connect(func() -> void:
		var dump := _values.duplicate()
		if _sun != null:
			dump["sun_color"] = _sun.light_color.to_html(false)
		print("Terrain tuning: ", dump)
	)
	vbox.add_child(print_button)


func _add_slider(parent: Container, key: String, min_value: float, max_value: float) -> void:
	var label := Label.new()
	parent.add_child(label)

	var slider := HSlider.new()
	slider.min_value = min_value
	slider.max_value = max_value
	slider.step = 0.01
	slider.value = _values[key]
	slider.custom_minimum_size = Vector2(300, 0)
	parent.add_child(slider)

	var update_label := func() -> void:
		label.text = "%s: %.2f" % [key, _values[key]]
	update_label.call()

	slider.value_changed.connect(func(value: float) -> void:
		_values[key] = value
		update_label.call()
		_apply(key)
	)


func _apply(key: String) -> void:
	match key:
		"tone_scale", "tone_saturation", "tone_alpha_gain":
			_set_terrain_param(key, _values[key])
		"sun_energy":
			if _sun != null:
				_sun.light_energy = _values.sun_energy
		"ambient_energy":
			if _environment != null:
				_environment.environment.ambient_light_energy = _values.ambient_energy
		"light_saturation":
			_apply_light_colors()


func _apply_light_colors() -> void:
	if _terrain == null or _terrain._lit_colors.size() < 2:
		return
	var keep: float = _values.light_saturation
	if _sun != null:
		_sun.light_color = _terrain._desaturated(_terrain._lit_colors[1], keep)
		if _sun_color_button != null:
			_sun_color_button.color = _sun.light_color
	if _environment != null:
		_environment.environment.ambient_light_color = _terrain._desaturated(_terrain._lit_colors[0], keep)


func _set_terrain_param(param: StringName, value: float) -> void:
	if _terrain == null:
		return
	var mesh_instance := _terrain.get_node_or_null("TerrainMesh") as MeshInstance3D
	if mesh_instance == null:
		return
	var mesh := mesh_instance.mesh
	for surface_index in mesh.get_surface_count():
		var material := mesh.surface_get_material(surface_index)
		if material is ShaderMaterial:
			material.set_shader_parameter(param, value)
