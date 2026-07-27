extends CanvasLayer

## HUD for in-world 3D conduit routing mode (pin or drag-reroute).

const C_BG := Color(UITheme.C_BG, 0.82)
const C_TEXT := UITheme.C_TEXT
const C_ACCENT := UITheme.C_PRIMARY

var _panel: PanelContainer = null
var _title: Label = null
var _info: Label = null
var _hint: Label = null


func _ready() -> void:
	# +1 over LAYER_WORLD_HINT: this HUD must render above the crosshair reticle.
	layer = UITheme.LAYER_WORLD_HINT + 1
	visible = false
	_build_ui()


func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_panel.offset_top = 12.0
	_panel.offset_bottom = 120.0
	_panel.offset_left = 80.0
	_panel.offset_right = -80.0
	# Display-only HUD — never steal clicks from modals beneath/above.
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_BG
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(12)
	_panel.add_theme_stylebox_override("panel", sb)
	add_child(_panel)
	var vbox := VBoxContainer.new()
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_theme_constant_override("separation", 6)
	_panel.add_child(vbox)
	_title = Label.new()
	_title.text = "Route 3D Conduit"
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title.add_theme_color_override("font_color", C_ACCENT)
	_title.add_theme_font_size_override("font_size", 16)
	vbox.add_child(_title)
	_info = Label.new()
	_info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_info.add_theme_color_override("font_color", C_TEXT)
	_info.add_theme_font_size_override("font_size", 12)
	vbox.add_child(_info)
	_hint = Label.new()
	_hint.text = "LMB pin waypoint · RMB undo · Enter commit · Esc cancel"
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint.add_theme_color_override("font_color", Color(C_TEXT.r, C_TEXT.g, C_TEXT.b, 0.75))
	_hint.add_theme_font_size_override("font_size", 11)
	vbox.add_child(_hint)


func show_route(type_id: String, waypoint_count: int, length_m: float, aim_valid: bool) -> void:
	show_route_ex(type_id, waypoint_count, length_m, aim_valid, false)


func show_route_ex(type_id: String, waypoint_count: int, length_m: float,
		aim_valid: bool, drag_mode: bool) -> void:
	visible = true
	var name_: String = ConduitKinds.display_name(type_id)
	var aim_txt := "aim: ready" if aim_valid else "aim: no hit"
	_info.text = "%s  ·  %d waypoint(s)  ·  %.2f m  ·  %s" % [name_, waypoint_count, length_m, aim_txt]
	if drag_mode:
		_title.text = "Hang / Reroute Conduit"
		_hint.text = "Drag pin to move · release commits · double-click pin removes · Esc cancel"
	else:
		_title.text = "Route 3D Conduit"
		_hint.text = "LMB pin · RMB undo · Enter commit · Esc cancel · drag focused cord/lights to hang"


func hide_route() -> void:
	visible = false
