extends Control
## The alarm chip on the first-person HUD (top centre): "2 alarms · Day tank
## nearly full 96.2 (limit 95)", in the worst one's colour, flashing while any
## is not acknowledged. Shown only while something is in alarm. A click (with
## the cursor free) opens the graph on the alarm window. Made by
## SystemGraphView once a site has alarm rules; polls its ScadaHub at 2 Hz.

const POLL_S := 0.5
const PRI_COLORS := {"high": Color(0.94, 0.33, 0.31), "medium": Color(0.98, 0.70, 0.22), "low": Color(0.35, 0.78, 0.98)}

var view: Node = null
var _accum := 0.0
var _chip: Button = null
var _last := ""
var _unack := false
var _color := Color.WHITE
var _blink := 0.0


func _ready() -> void:
	set_anchors_preset(Control.PRESET_CENTER_TOP)
	offset_top = 60.0
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_chip = Button.new()
	_chip.name = "alarm_chip"
	_chip.focus_mode = Control.FOCUS_NONE
	_chip.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_chip.add_theme_stylebox_override("normal", UITheme.chip_style(Color(0.10, 0.07, 0.07, 0.94)))
	_chip.add_theme_stylebox_override("hover", UITheme.chip_style(Color(0.16, 0.10, 0.10, 0.96)))
	_chip.add_theme_stylebox_override("pressed", UITheme.chip_style(Color(0.16, 0.10, 0.10, 0.96)))
	_chip.tooltip_text = "Open the alarms"
	_chip.visible = false
	_chip.pressed.connect(func() -> void:
		if view != null:
			view.call("open_graph_view")
			view.call("open_alarm_panel", "active"))
	add_child(_chip)
	HudLayout.register(_chip, "scada_alarms", "top_center", {"order": 3, "tuckable": false,
		"size": func() -> Vector2: return _chip.get_combined_minimum_size()})


func chip() -> Button:
	return _chip


func _process(delta: float) -> void:
	if _unack and _chip.visible:
		_blink += delta
		# ~1 Hz, as the graph's own alerts beat.
		_chip.add_theme_color_override("font_color", _color if fmod(_blink, 1.0) < 0.6 else _color.darkened(0.45))
	_accum += delta
	if _accum < POLL_S:
		return
	_accum = 0.0
	_refresh()


func _refresh() -> void:
	var hub: Node = view.call("scada_hub") if view != null and view.has_method("scada_hub") else null
	if hub == null or not hub.has_method("alarm_summary"):
		_chip.visible = false
		return
	var sm: Dictionary = hub.call("alarm_summary")
	if int(sm.get("count", 0)) <= 0:
		_chip.visible = false
		_last = ""
		return
	_unack = int(sm.get("unack", 0)) > 0
	_color = PRI_COLORS.get(str(sm.get("worst", "medium")), UITheme.C_WARN)
	var txt := "%s  ·  %s" % [UiText.count(int(sm["count"]), "alarm"), str(sm.get("text", ""))]
	if txt.length() > 90:
		txt = txt.substr(0, 88) + "…"
	if txt != _last:
		_last = txt
		_chip.text = txt
		_chip.add_theme_color_override("font_color", _color)
		_chip.add_theme_color_override("font_hover_color", _color)
		_chip.reset_size()
	_chip.visible = true
