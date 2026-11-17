extends Control
## The ARMED chip on the first-person HUD (top centre): "ARMED · 3 outputs
## drive real devices". Shown only while the SCADA outputs are armed, so the
## player can never forget the game is switching real hardware. A click (with
## the cursor free) opens the graph on the Hardware window. Made by
## SystemGraphView the first time the outputs are armed; polls at 2 Hz.

const POLL_S := 0.5
const C_ARMED := Color(0.98, 0.50, 0.30)

var view: Node = null
var _accum := 0.0
var _chip: Button = null
var _blink := 0.0


func _ready() -> void:
	set_anchors_preset(Control.PRESET_CENTER_TOP)
	offset_top = 60.0
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_chip = Button.new()
	_chip.name = "armed_chip"
	_chip.focus_mode = Control.FOCUS_NONE
	_chip.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_chip.add_theme_stylebox_override("normal", UITheme.chip_style(Color(0.16, 0.07, 0.04, 0.95)))
	_chip.add_theme_stylebox_override("hover", UITheme.chip_style(Color(0.22, 0.10, 0.06, 0.97)))
	_chip.add_theme_stylebox_override("pressed", UITheme.chip_style(Color(0.22, 0.10, 0.06, 0.97)))
	_chip.add_theme_color_override("font_color", C_ARMED)
	_chip.add_theme_color_override("font_hover_color", C_ARMED)
	_chip.tooltip_text = "The game is driving real devices. Open the Hardware window."
	_chip.visible = false
	_chip.pressed.connect(func() -> void:
		if view != null:
			view.call("open_graph_view")
			view.call("open_outputs_panel"))
	add_child(_chip)
	HudLayout.register(_chip, "scada_armed", "top_center", {"order": 2, "tuckable": false,
		"size": func() -> Vector2: return _chip.get_combined_minimum_size()})
	_refresh()


func chip() -> Button:
	return _chip


func _process(delta: float) -> void:
	if _chip.visible:
		_blink += delta
		_chip.add_theme_color_override("font_color", C_ARMED if fmod(_blink, 1.6) < 1.2 else C_ARMED.darkened(0.35))
	_accum += delta
	if _accum < POLL_S:
		return
	_accum = 0.0
	_refresh()


func _refresh() -> void:
	var hub: Node = view.call("scada_hub") if view != null and view.has_method("scada_hub") else null
	var armed := hub != null and hub.has_method("outputs_armed") and bool(hub.call("outputs_armed"))
	if not armed:
		_chip.visible = false
		return
	var n := 0
	for l in hub.call("output_links"):
		if bool(l["enabled"]):
			n += 1
	var txt := "ARMED  ·  %s real %s" % [UiText.count(n, "output"), "devices" if n != 1 else "device"]
	txt = "ARMED  ·  %s driving real devices" % UiText.count(n, "output")
	if _chip.text != txt:
		_chip.text = txt
		_chip.reset_size()
	_chip.visible = true
