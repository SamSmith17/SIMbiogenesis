extends CanvasLayer

## Center-screen reticle for crosshair interaction.

var _reticle: Control = null
var _prompt_lbl: Label = null
var _target_active: bool = false

const C_NEUTRAL := Color(1.0, 1.0, 1.0, 0.75)
const C_ACTIVE := Color(0.2, 0.95, 0.35, 0.95)


func _ready() -> void:
	layer = UITheme.LAYER_WORLD_HINT
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	_reticle = Control.new()
	_reticle.custom_minimum_size = Vector2(24, 24)
	_reticle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_reticle.draw.connect(_draw_reticle)
	center.add_child(_reticle)

	var prompt_wrap := CenterContainer.new()
	prompt_wrap.set_anchors_preset(Control.PRESET_FULL_RECT)
	prompt_wrap.offset_top = 28.0
	add_child(prompt_wrap)

	_prompt_lbl = Label.new()
	_prompt_lbl.visible = false
	_prompt_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt_lbl.add_theme_color_override("font_color", Color(0.9, 0.95, 0.9, 0.95))
	_prompt_lbl.add_theme_font_size_override("font_size", 12)
	prompt_wrap.add_child(_prompt_lbl)

	CursorController.capture_state_changed.connect(_on_capture_changed)
	_on_capture_changed()
	visible = false


func set_target_active(active: bool) -> void:
	_target_active = active
	if _reticle:
		_reticle.queue_redraw()


func set_prompt_text(text: String) -> void:
	if _prompt_lbl == null:
		return
	if text.is_empty():
		_prompt_lbl.visible = false
	else:
		_prompt_lbl.text = text
		_prompt_lbl.visible = true


## The prompt currently shown ("" when hidden).
func get_prompt_text() -> String:
	if _prompt_lbl == null or not _prompt_lbl.visible:
		return ""
	return _prompt_lbl.text


func _draw_reticle() -> void:
	var col := C_ACTIVE if _target_active else C_NEUTRAL
	var c := _reticle.size * 0.5
	var r := 6.0
	_reticle.draw_line(Vector2(c.x - r, c.y), Vector2(c.x + r, c.y), col, 1.5)
	_reticle.draw_line(Vector2(c.x, c.y - r), Vector2(c.x, c.y + r), col, 1.5)
	_reticle.draw_arc(c, r + 3.0, 0.0, TAU, 24, col, 1.0)


func _on_capture_changed() -> void:
	visible = CursorController.should_capture_look()
	if not visible:
		set_target_active(false)
		set_prompt_text("")
