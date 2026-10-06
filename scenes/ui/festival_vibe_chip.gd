extends Control

## The festival's "Overall Vibe" chip (top-centre, under the hazard badge):
## one line from FestivalVibe — band, score, trend arrow and the reason —
## visible only while the map has festival camps on the graph. Polls
## SystemGraphView.festival_vibe() at 2 Hz (the HazardBadgeUI pattern; the
## view computes the vibe once a second alongside the camp cards, so this is
## a read, never a walk of the model). Main creates it under UILayer.

const POLL_S := 0.5

var _accum := 0.0
var _chip: PanelContainer = null
var _lbl: Label = null
var _last := ""


func _ready() -> void:
	set_anchors_preset(Control.PRESET_CENTER_TOP)
	offset_top = 36.0
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_chip = PanelContainer.new()
	_chip.add_theme_stylebox_override("panel", UITheme.chip_style(Color(0.08, 0.10, 0.12, 0.92)))
	_chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_chip.visible = false
	_lbl = Label.new()
	_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_chip.add_child(_lbl)
	add_child(_chip)


func _process(delta: float) -> void:
	_accum += delta
	if _accum < POLL_S:
		return
	_accum = 0.0
	_refresh()


func _refresh() -> void:
	var sgv := get_tree().current_scene.get_node_or_null("UILayer/SystemGraphView") \
		if get_tree().current_scene != null else null
	if sgv == null or not sgv.has_method("festival_vibe"):
		_chip.visible = false
		return
	var v: Dictionary = sgv.call("festival_vibe")
	if v.is_empty() or int(v.get("people", 0)) <= 0:
		_chip.visible = false
		return
	var txt := str(v.get("headline", ""))
	if txt != _last:
		_last = txt
		_lbl.text = txt
		_lbl.add_theme_color_override("font_color", v.get("color", UITheme.C_TEXT) as Color)
		_chip.reset_size()
	_chip.visible = true
	_chip.position.x = -_chip.size.x * 0.5
