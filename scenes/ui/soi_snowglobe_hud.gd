extends CanvasLayer

## In-Snowglobe SoI controls: labeled radius slider, area/atmosphere readout, exit.
## Root ignores mouse so orbit drag still works; only the dock captures input.

const MODAL_HINT := "Drag to orbit · Scroll to zoom · Esc to exit · the timeline below stays live"
## Space kept between the dock and the timeline bar under it.
const DOCK_TIMELINE_GAP := 12.0
const DOCK_HEIGHT := 144.0
const DOCK_WIDTH := 760.0

var _svc: Node = null
var _dock: PanelContainer = null
var _radius_slider: HSlider = null
var _radius_value: Label = null
var _area_lbl: Label = null
var _pbi_lbl: Label = null
var _hint_lbl: Label = null
var _updating := false
var _active := false


func _ready() -> void:
	layer = UITheme.LAYER_MODAL
	visible = false
	process_mode = Node.PROCESS_MODE_ALWAYS


func bind_service(svc: Node) -> void:
	_svc = svc
	if _svc != null and _svc.has_signal("soi_changed"):
		if not _svc.is_connected("soi_changed", _on_soi_changed):
			_svc.connect("soi_changed", _on_soi_changed)
	if _dock == null:
		_build_ui()


func show_hud() -> void:
	if _dock == null:
		_build_ui()
	_active = true
	visible = true
	_place_above_timeline()
	_refresh()
	if _radius_slider != null:
		_radius_slider.grab_focus()


## The clock runs while the globe is up, so the timeline must stay reachable:
## seat the dock just above it (it used to sit over the play / speed / scrub
## controls). Falls back to the old bottom inset with no timeline.
func _place_above_timeline() -> void:
	if _dock == null:
		return
	var inset := 24.0
	var tree := get_tree()
	var main := tree.current_scene if tree != null else null
	var tl := main.get_node_or_null("UILayer/TimelineUI") as Control if main != null else null
	if tl != null and tl.visible:
		var h := float(tl.call("get_stack_height")) if tl.has_method("get_stack_height") else tl.size.y
		if h > 1.0:
			inset = h + DOCK_TIMELINE_GAP
	_dock.offset_bottom = -inset
	_dock.offset_top = -inset - DOCK_HEIGHT


func hide_hud() -> void:
	_active = false
	visible = false


func _on_soi_changed() -> void:
	if _active:
		_refresh()


func _build_ui() -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	# Top title chip
	var title_wrap := PanelContainer.new()
	title_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# A centred chip, not a full-width bar — the full width sat on top of the
	# weather card in the top-left corner.
	title_wrap.set_anchors_preset(Control.PRESET_CENTER_TOP)
	title_wrap.offset_left = -300.0
	title_wrap.offset_right = 300.0
	title_wrap.offset_top = 18.0
	title_wrap.offset_bottom = 64.0
	var title_sb := StyleBoxFlat.new()
	title_sb.bg_color = Color(UITheme.C_BG, 0.72)
	title_sb.border_color = Color(UITheme.C_PRIMARY, 0.55)
	title_sb.set_border_width_all(1)
	title_sb.set_corner_radius_all(10)
	title_sb.set_content_margin_all(10)
	title_wrap.add_theme_stylebox_override("panel", title_sb)
	root.add_child(title_wrap)

	var title_col := VBoxContainer.new()
	title_col.add_theme_constant_override("separation", 2)
	title_wrap.add_child(title_col)
	var title := Label.new()
	title.text = "Sphere of Influence — Snowglobe"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", UITheme.FONT_LG)
	title.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	title_col.add_child(title)
	_hint_lbl = Label.new()
	_hint_lbl.text = MODAL_HINT
	_hint_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_hint_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	title_col.add_child(_hint_lbl)

	# Bottom control dock
	_dock = PanelContainer.new()
	_dock.mouse_filter = Control.MOUSE_FILTER_STOP
	# A centred card, not a full-width slab: the globe is the subject, and the
	# old bottom-wide dock covered a third of it (and the whole timeline).
	_dock.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_dock.offset_left = -DOCK_WIDTH * 0.5
	_dock.offset_right = DOCK_WIDTH * 0.5
	# Content taller than DOCK_HEIGHT grows the card UP, never into the timeline.
	_dock.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_dock.offset_top = -168.0
	_dock.offset_bottom = -24.0
	var dock_sb := StyleBoxFlat.new()
	dock_sb.bg_color = Color(UITheme.C_PANEL, 0.94)
	dock_sb.border_color = Color(UITheme.C_PRIMARY, 0.65)
	dock_sb.set_border_width_all(1)
	dock_sb.set_corner_radius_all(12)
	dock_sb.content_margin_left = 18
	dock_sb.content_margin_right = 18
	dock_sb.content_margin_top = 14
	dock_sb.content_margin_bottom = 14
	_dock.add_theme_stylebox_override("panel", dock_sb)
	root.add_child(_dock)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	_dock.add_child(vbox)

	var radius_hdr := HBoxContainer.new()
	radius_hdr.add_theme_constant_override("separation", 10)
	vbox.add_child(radius_hdr)

	var radius_title := Label.new()
	radius_title.text = "RADIUS"
	radius_title.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	radius_title.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	radius_hdr.add_child(radius_title)

	_radius_value = Label.new()
	_radius_value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_radius_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_radius_value.add_theme_font_size_override("font_size", UITheme.FONT_XL)
	_radius_value.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	radius_hdr.add_child(_radius_value)

	_radius_slider = HSlider.new()
	_radius_slider.min_value = SoiConfig.MIN_RADIUS_M
	_radius_slider.max_value = SoiConfig.MAX_RADIUS_M
	_radius_slider.step = 5.0
	_radius_slider.value = SoiConfig.DEFAULT_RADIUS_M
	_radius_slider.custom_minimum_size = Vector2(0, 28)
	_radius_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_radius_slider.tooltip_text = "Drag to expand or contract your Sphere of Influence"
	_radius_slider.value_changed.connect(_on_radius_changed)
	_radius_slider.gui_input.connect(_on_slider_gui_input)
	vbox.add_child(_radius_slider)

	var meta := HBoxContainer.new()
	meta.add_theme_constant_override("separation", 16)
	vbox.add_child(meta)

	_area_lbl = Label.new()
	_area_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_area_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_area_lbl.add_theme_color_override("font_color", UITheme.C_TEXT)
	meta.add_child(_area_lbl)

	_pbi_lbl = Label.new()
	_pbi_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_pbi_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_pbi_lbl.add_theme_color_override("font_color", UITheme.C_GREEN)
	meta.add_child(_pbi_lbl)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	btn_row.alignment = BoxContainer.ALIGNMENT_END
	vbox.add_child(btn_row)

	var move_btn := Button.new()
	move_btn.text = "Move origin"
	move_btn.tooltip_text = "Exit Snowglobe, then aim and Interact to place the pin"
	UITheme.style_button(move_btn)
	move_btn.pressed.connect(_on_move_origin)
	btn_row.add_child(move_btn)

	var settings_btn := Button.new()
	settings_btn.text = "Settings…"
	settings_btn.tooltip_text = "Open the SoI settings panel"
	UITheme.style_button(settings_btn)
	settings_btn.pressed.connect(_on_settings)
	btn_row.add_child(settings_btn)

	var exit_btn := Button.new()
	exit_btn.text = "Exit Snowglobe"
	UITheme.style_button(exit_btn)
	exit_btn.pressed.connect(_on_exit)
	btn_row.add_child(exit_btn)


func _refresh() -> void:
	if _svc == null:
		return
	var r: float = float(_svc.call("radius_m"))
	_updating = true
	if _radius_slider != null and not _radius_slider.has_focus():
		_radius_slider.value = r
	elif _radius_slider != null and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_radius_slider.value = r
	_updating = false
	if _radius_value != null:
		_radius_value.text = "%d m" % int(round(r))
	if _area_lbl != null:
		var km2: float = float(_svc.call("area_m2")) / 1_000_000.0
		_area_lbl.text = "Area  %.2f km²" % km2
	if _pbi_lbl != null:
		var month := _sim_month()
		var day := _sim_day()
		var hour := _sim_hour()
		var lat := _sim_lat()
		var lon := _sim_lon()
		var ws := get_node_or_null("/root/WeatherService")
		var atmo: Dictionary = AtmospherePbi.sample(lat, lon, month, day, hour, ws)
		var wind_ms: float = float(atmo.get("wind_ms", 0.0))
		var kinetic: float = AtmospherePbi.kinetic_flux_kw(wind_ms, float(_svc.call("area_m2")))
		if kinetic >= 1000.0:
			_pbi_lbl.text = "Wind PBI  %.1f MW · %.0f m/s" % [kinetic / 1000.0, wind_ms]
		else:
			_pbi_lbl.text = "Wind PBI  %.0f kW · %.0f m/s" % [kinetic, wind_ms]


func _sim_month() -> int:
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		return 6
	var m: Variant = tree.current_scene.get("month")
	return int(m) if m != null else 6


func _sim_day() -> int:
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		return 15
	var d: Variant = tree.current_scene.get("day")
	return int(d) if d != null else 15


func _sim_hour() -> float:
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		return 12.0
	var h: Variant = tree.current_scene.get("day_time")
	return float(h) if h != null else 12.0


func _sim_lat() -> float:
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		return 0.0
	var v: Variant = tree.current_scene.get("latitude")
	return float(v) if v != null else 0.0


func _sim_lon() -> float:
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		return 0.0
	var v: Variant = tree.current_scene.get("longitude")
	return float(v) if v != null else 0.0


func _on_radius_changed(v: float) -> void:
	if _updating or _svc == null:
		return
	_svc.call("set_radius_m", v)
	if _radius_value != null:
		_radius_value.text = "%d m" % int(round(v))


func _on_slider_gui_input(event: InputEvent) -> void:
	# Keep wheel on the slider adjusting radius (not camera zoom).
	if event is InputEventMouseButton and _radius_slider != null:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
				_radius_slider.value = minf(
						_radius_slider.max_value, _radius_slider.value + 10.0)
				get_viewport().set_input_as_handled()
			elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_radius_slider.value = maxf(
						_radius_slider.min_value, _radius_slider.value - 10.0)
				get_viewport().set_input_as_handled()


func _on_move_origin() -> void:
	if _svc == null:
		return
	if _svc.has_method("exit_snowglobe"):
		_svc.call("exit_snowglobe")
	if _svc.has_method("begin_placement_mode"):
		_svc.call("begin_placement_mode")
	if _svc.has_method("open_panel"):
		_svc.call("open_panel")


func _on_settings() -> void:
	if _svc == null:
		return
	if _svc.has_method("exit_snowglobe"):
		_svc.call("exit_snowglobe")
	if _svc.has_method("open_panel"):
		_svc.call("open_panel")


func _on_exit() -> void:
	if _svc != null and _svc.has_method("exit_snowglobe"):
		_svc.call("exit_snowglobe")
