class_name QueueSlot
extends Button
## One icon slot in the production grid.
## DISABLED shows the grey icon, AVAILABLE the colored one, PROGRESS blends
## both with a clockwise radial mask (see queue_slot.gdshader), READY shows
## the colored icon with a READY caption.

enum State { DISABLED, AVAILABLE, PROGRESS, READY }

const SLOT_SHADER := preload("res://scripts/ui/queue_slot.gdshader")
const ICON_MARGIN := 3.0

var icon_colored: Texture2D:
	set(value):
		icon_colored = value
		_apply()
var icon_grey: Texture2D:
	set(value):
		icon_grey = value
		_apply()
var state: State = State.DISABLED:
	set(value):
		state = value
		_apply()
## 0..100, only visible in PROGRESS state.
var progress: float = 0.0:
	set(value):
		progress = clampf(value, 0.0, 100.0)
		_apply()

var _icon_rect: TextureRect
var _icon_material: ShaderMaterial
var _status: Label


func _ready() -> void:
	_icon_material = ShaderMaterial.new()
	_icon_material.shader = SLOT_SHADER

	_icon_rect = TextureRect.new()
	_icon_rect.material = _icon_material
	_icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon_rect.set_anchors_and_offsets_preset(
		Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, ICON_MARGIN
	)
	add_child(_icon_rect)

	_status = Label.new()
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_status.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_status)

	_apply()


func _apply() -> void:
	if _icon_rect == null:
		return

	_icon_rect.visible = icon_colored != null
	_icon_rect.texture = icon_colored
	# With no grey variant, fall back to the colored icon on both sides of the mask.
	_icon_material.set_shader_parameter("grey_texture", icon_grey if icon_grey else icon_colored)

	disabled = state == State.DISABLED or icon_colored == null
	match state:
		State.DISABLED:
			_icon_material.set_shader_parameter("progress", 0.0)
			_status.text = ""
		State.AVAILABLE:
			_icon_material.set_shader_parameter("progress", 1.0)
			_status.text = ""
		State.PROGRESS:
			_icon_material.set_shader_parameter("progress", progress / 100.0)
			_status.text = ""
		State.READY:
			_icon_material.set_shader_parameter("progress", 1.0)
			_status.text = "READY"
