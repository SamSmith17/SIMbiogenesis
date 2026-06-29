extends CanvasLayer

## HUD for in-world 3D conduit routing mode.

const C_BG := Color(0.039, 0.055, 0.098, 0.82)
const C_TEXT := Color(0.886, 0.910, 0.941, 1.0)
const C_ACCENT := Color(0.133, 0.827, 0.933, 1.0)

var _panel: PanelContainer = null
var _title: Label = null
var _info: Label = null
var _hint: Label = null


func _ready() -> void:
	layer = 6
	visible = false
	_build_ui()


func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_panel.offset_top = 12.0
	_panel.offset_bottom = 120.0
	_panel.offset_left = 80.0
	_panel.offset_right = -80.0
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_BG
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(12)
	_panel.add_theme_stylebox_override("panel", sb)
	add_child(_panel)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	_panel.add_child(vbox)
	_title = Label.new()
	_title.text = "Route 3D Conduit"
	_title.add_theme_color_override("font_color", C_ACCENT)
	_title.add_theme_font_size_override("font_size", 16)
	vbox.add_child(_title)
	_info = Label.new()
	_info.add_theme_color_override("font_color", C_TEXT)
	_info.add_theme_font_size_override("font_size", 12)
	vbox.add_child(_info)
	_hint = Label.new()
	_hint.text = "LMB pin waypoint · RMB undo · Enter commit · Esc cancel"
	_hint.add_theme_color_override("font_color", Color(C_TEXT.r, C_TEXT.g, C_TEXT.b, 0.75))
	_hint.add_theme_font_size_override("font_size", 11)
	vbox.add_child(_hint)


func show_route(type_id: String, waypoint_count: int, length_m: float, aim_valid: bool) -> void:
	visible = true
	var name_: String = ConduitKinds.display_name(type_id)
	var aim_txt := "aim: ready" if aim_valid else "aim: no hit"
	_info.text = "%s  ·  %d waypoint(s)  ·  %.2f m  ·  %s" % [name_, waypoint_count, length_m, aim_txt]


func hide_route() -> void:
	visible = false
