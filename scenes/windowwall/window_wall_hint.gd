extends CanvasLayer

## The one piece of UI the Window Wall keeps on the MAIN window: a small
## bottom-centre strip that says how to get out, then fades. Parented under the
## view node (never Main) so the mode's hide-every-CanvasLayer sweep cannot
## touch it — the same trick the settlement HUD uses.

const FADE_AFTER_S := 6.0
const FADE_S := 0.8

var _panel: PanelContainer = null
var _label: Label = null
var _tween: Tween = null


func _ready() -> void:
	layer = UITheme.LAYER_TOAST
	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", UITheme.panel_style())
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", UITheme.SPACE_MD)
	margin.add_theme_constant_override("margin_right", UITheme.SPACE_MD)
	margin.add_theme_constant_override("margin_top", UITheme.SPACE_SM)
	margin.add_theme_constant_override("margin_bottom", UITheme.SPACE_SM)
	_panel.add_child(margin)
	_label = Label.new()
	_label.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_label.add_theme_color_override("font_color", UITheme.C_TEXT)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	margin.add_child(_label)
	visible = false


## Show `text`, hold it `hold_s`, then fade out. Calling again restarts.
func flash(text: String, hold_s: float = FADE_AFTER_S) -> void:
	if _label == null:
		return
	_label.text = text
	visible = true
	_panel.modulate.a = 1.0
	# Re-centre now that the text (and so the width) changed. Control.position
	# is parent-relative (the window), not anchor-relative.
	_panel.reset_size()
	var vs := get_viewport().get_visible_rect().size
	_panel.position = Vector2((vs.x - _panel.size.x) * 0.5, vs.y - _panel.size.y - 28.0)
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.tween_interval(maxf(hold_s, 0.1))
	_tween.tween_property(_panel, "modulate:a", 0.0, FADE_S)
	_tween.tween_callback(func() -> void: visible = false)


func hide_now() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	visible = false
