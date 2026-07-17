extends Control

## Camp Scatter UI — thin bottom-dock panel for manually placing Black Rock City
## camp geometry inside a user-drawn or auto-detected area.
##
## Toggle with C key (wired in terrain_loader._unhandled_input).
## Selection tools (reuse VegetationPaint helpers like vegetation_edit_ui):
##   Circle / Rect / Lasso / Polygon / BRC Auto
##
## Parameters: density, mix bias (shade+RV ↔ tent), scale, seed + Advanced
## (plot depth, scatter step, light LOD). Generate rebuilds Camps; Clear removes it.

signal mode_changed(active: bool)

enum Tool { CIRCLE, RECT, LASSO, POLYGON, BRC_AUTO }

const MODAL_NAME := "camp_scatter"
const TIMELINE_CLEARANCE := 162.0
const PANEL_HEIGHT := 360.0

var _loader: Node = null
var _active := false
var _tool := Tool.BRC_AUTO

# Selection state.
var _selecting := false
var _sel_start := Vector2.ZERO
var _sel_end := Vector2.ZERO
var _brush_anchor := Vector2.ZERO
var _brush_poly := PackedVector2Array()
var _poly_points := PackedVector2Array()
var _lasso_pts := PackedVector2Array()
var _auto_area := PackedVector2Array()     # cached BRC convex hull
var _last_lasso_sample := Vector2.ZERO

# Parameters.
var _density := 0.72
var _mix_bias := 0.0       # -1 = shade/RV heavy, +1 = tent heavy
var _scale_min := 0.9
var _scale_max := 1.18
var _seed := 12345
var _exclusion_r := 804.672  # playa exclusion radius in metres (default 0.5 mi)
var _light_density := 1.0
var _plot_depth_m := 60.0
var _scatter_step_m := 6.0
var _light_lod_m := 130.0
var _max_pool_lights := 40
var _advanced_open := false
var _advanced_box: VBoxContainer = null

# UI refs.
var _panel: PanelContainer = null
var _capture: ColorRect = null
var _rect_overlay: ColorRect = null
var _poly_draw: Control = null
var _status: Label = null
var _generate_btn: Button = null
var _tool_buttons: Array[Button] = []
var _density_slider: HSlider = null
var _mix_slider: HSlider = null
var _scale_slider: HSlider = null
var _light_density_slider: HSlider = null
var _seed_spin: SpinBox = null
var _busy := false


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)
	_build_ui()


func bind_loader(loader: Node) -> void:
	_loader = loader


func toggle_mode() -> void:
	if _active:
		_exit_mode()
	else:
		_enter_mode()


# ---------------------------------------------------------------------------
# Style helpers (match vegetation_edit_ui chrome)
# ---------------------------------------------------------------------------

func _panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.09, 0.12, 0.97)
	sb.set_corner_radius_all(8)
	sb.set_border_width_all(2)
	sb.border_color = Color(0.65, 0.45, 0.15, 0.85)
	sb.shadow_color = Color(0, 0, 0, 0.45)
	sb.shadow_size = 6
	return sb


func _primary_btn_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.18, 0.10, 0.02, 1.0)
	sb.border_color = Color(0.95, 0.65, 0.12, 0.95)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	return sb


func _secondary_btn_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.12, 0.14, 0.18, 1.0)
	sb.border_color = Color(0.4, 0.3, 0.18, 0.7)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	return sb


func _toggle_btn_style(on: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(4)
	sb.set_border_width_all(1)
	if on:
		sb.bg_color = Color(0.28, 0.18, 0.04, 1.0)
		sb.border_color = Color(0.95, 0.65, 0.12, 0.9)
	else:
		sb.bg_color = Color(0.1, 0.12, 0.16, 1.0)
		sb.border_color = Color(0.32, 0.26, 0.16, 0.6)
	return sb


func _style_tool_button(btn: Button, on: bool) -> void:
	btn.toggle_mode = true
	btn.button_pressed = on
	btn.add_theme_stylebox_override("normal", _toggle_btn_style(on))
	btn.add_theme_stylebox_override("pressed", _toggle_btn_style(true))
	btn.add_theme_stylebox_override("hover", _toggle_btn_style(on))
	btn.add_theme_color_override("font_color",
		Color(1.0, 0.80, 0.30) if on else Color(0.65, 0.56, 0.38))
	btn.add_theme_font_size_override("font_size", 13)


# ---------------------------------------------------------------------------
# UI build
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	_capture = ColorRect.new()
	_capture.name = "SelectCapture"
	_capture.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_capture.color = Color(0, 0, 0, 0)
	_capture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_capture.gui_input.connect(_on_capture_input)
	add_child(_capture)

	_rect_overlay = ColorRect.new()
	_rect_overlay.color = Color(0.95, 0.65, 0.12, 0.22)
	_rect_overlay.visible = false
	_rect_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_rect_overlay)

	_poly_draw = Control.new()
	_poly_draw.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_poly_draw.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_poly_draw.draw.connect(_draw_selection_overlay)
	add_child(_poly_draw)

	_panel = PanelContainer.new()
	_panel.name = "DockPanel"
	_panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_panel.offset_bottom = -TIMELINE_CLEARANCE
	_panel.offset_top = -(TIMELINE_CLEARANCE + PANEL_HEIGHT)
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.add_theme_stylebox_override("panel", _panel_style())
	add_child(_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	_panel.add_child(margin)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	margin.add_child(col)

	# Title row.
	var title_row := HBoxContainer.new()
	col.add_child(title_row)
	var title := Label.new()
	title.text = "🏕  CAMP SCATTER"
	title.add_theme_color_override("font_color", Color(1.0, 0.75, 0.25, 1.0))
	title.add_theme_font_size_override("font_size", 17)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title)
	var hint := Label.new()
	hint.text = "C toggle · Esc exit"
	hint.add_theme_color_override("font_color", Color(0.58, 0.52, 0.40, 1.0))
	hint.add_theme_font_size_override("font_size", 11)
	hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title_row.add_child(hint)

	col.add_child(HSeparator.new())

	# Tools + primary actions row.
	var top_row := HBoxContainer.new()
	top_row.add_theme_constant_override("separation", 8)
	col.add_child(top_row)

	_generate_btn = Button.new()
	_generate_btn.text = "▶  GENERATE"
	_generate_btn.tooltip_text = "Fill selection with camp structures (Enter)"
	_generate_btn.custom_minimum_size = Vector2(148, 40)
	_generate_btn.add_theme_stylebox_override("normal", _primary_btn_style())
	_generate_btn.add_theme_stylebox_override("hover", _primary_btn_style())
	_generate_btn.add_theme_stylebox_override("pressed", _primary_btn_style())
	_generate_btn.add_theme_stylebox_override("disabled", _secondary_btn_style())
	_generate_btn.add_theme_color_override("font_color", Color(1.0, 0.75, 0.20, 1.0))
	_generate_btn.add_theme_color_override("font_hover_color", Color(1.0, 0.90, 0.50, 1.0))
	_generate_btn.add_theme_font_size_override("font_size", 15)
	_generate_btn.pressed.connect(_generate)
	top_row.add_child(_generate_btn)

	for spec: Array in [
		["Clear", _clear],
		["Exit", func() -> void: _exit_mode()],
	]:
		var b := Button.new()
		b.text = spec[0]
		b.custom_minimum_size = Vector2(72, 36)
		b.add_theme_stylebox_override("normal", _secondary_btn_style())
		b.add_theme_stylebox_override("hover", _secondary_btn_style())
		b.add_theme_color_override("font_color", Color(0.75, 0.70, 0.58, 1.0))
		b.pressed.connect(spec[1])
		top_row.add_child(b)

	# Tool + seed row.
	var mid_row := HBoxContainer.new()
	mid_row.add_theme_constant_override("separation", 10)
	col.add_child(mid_row)

	var tool_lbl := Label.new()
	tool_lbl.text = "Area:"
	tool_lbl.add_theme_color_override("font_color", Color(0.60, 0.55, 0.42, 1.0))
	tool_lbl.add_theme_font_size_override("font_size", 12)
	tool_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	mid_row.add_child(tool_lbl)

	_tool_buttons.clear()
	var tool_specs: Array = [
		["Circle", Tool.CIRCLE, "Drag radius from centre (veg select shape)"],
		["Rect", Tool.RECT, "Drag a rectangle on terrain"],
		["Lasso", Tool.LASSO, "Freehand trace on terrain"],
		["Polygon", Tool.POLYGON, "Click points · Enter/RMB to finish"],
		["BRC Auto", Tool.BRC_AUTO, "Auto-detect BRC footprint from OSM roads"],
	]
	for spec: Array in tool_specs:
		var b := Button.new()
		b.text = str(spec[0])
		b.tooltip_text = str(spec[2])
		var tool_id: int = int(spec[1])
		b.pressed.connect(_on_tool_pressed.bind(tool_id))
		_style_tool_button(b, tool_id == int(_tool))
		mid_row.add_child(b)
		_tool_buttons.append(b)

	mid_row.add_child(_v_sep())

	var seed_lbl := Label.new()
	seed_lbl.text = "Seed:"
	seed_lbl.add_theme_color_override("font_color", Color(0.60, 0.55, 0.42, 1.0))
	seed_lbl.add_theme_font_size_override("font_size", 12)
	seed_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	mid_row.add_child(seed_lbl)

	_seed_spin = SpinBox.new()
	_seed_spin.min_value = 0
	_seed_spin.max_value = 999999
	_seed_spin.step = 1
	_seed_spin.value = _seed
	_seed_spin.custom_minimum_size = Vector2(90, 0)
	_seed_spin.value_changed.connect(func(v: float) -> void: _seed = int(v))
	mid_row.add_child(_seed_spin)

	var rng_btn := Button.new()
	rng_btn.text = "🎲"
	rng_btn.tooltip_text = "Random seed"
	rng_btn.add_theme_stylebox_override("normal", _secondary_btn_style())
	rng_btn.add_theme_stylebox_override("hover", _secondary_btn_style())
	rng_btn.pressed.connect(_randomize_seed)
	mid_row.add_child(rng_btn)

	# Parameter sliders.
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 4)
	col.add_child(grid)

	_density_slider = _add_slider(grid, "Density", 0.1, 1.0, _density,
		"Fraction of available cells that receive a structure",
		func(v: float) -> void: _density = v)
	_mix_slider = _add_slider(grid, "Mix  ← shade  tent →", -1.0, 1.0, _mix_bias,
		"Negative = shade structures & RVs dominant\nPositive = tents & tarps dominant",
		func(v: float) -> void: _mix_bias = v)
	_scale_slider = _add_slider(grid, "Scale", 0.4, 2.5, (_scale_min + _scale_max) * 0.5,
		"Average structure scale (range ±15% around this)",
		func(v: float) -> void: _scale_min = v * 0.85; _scale_max = v * 1.15)
	_light_density_slider = _add_slider(grid, "Light Density", 0.0, 2.0, _light_density,
		"Modulate the density of lights independent of camp geometry",
		func(v: float) -> void: _light_density = v)
	_add_slider(grid, "Playa excl. (mi)", 0.0, 1.0, _exclusion_r / 1609.344,
		"Exclusion radius from city centre (Man) in miles — blocks open playa.\n0.5 mi ≈ 804 m covers the Esplanade inward.",
		func(v: float) -> void:
			_exclusion_r = v * 1609.344
			if _loader != null and _loader.has_method("set_camp_exclusion_r"):
				_loader.call("set_camp_exclusion_r", _exclusion_r))

	var adv_btn := Button.new()
	adv_btn.text = "▸ Advanced"
	adv_btn.add_theme_stylebox_override("normal", _secondary_btn_style())
	adv_btn.add_theme_stylebox_override("hover", _secondary_btn_style())
	adv_btn.add_theme_color_override("font_color", Color(0.75, 0.70, 0.58, 1.0))
	adv_btn.pressed.connect(func() -> void:
		_advanced_open = not _advanced_open
		if _advanced_box != null:
			_advanced_box.visible = _advanced_open
		adv_btn.text = ("▾ Advanced" if _advanced_open else "▸ Advanced"))
	col.add_child(adv_btn)

	_advanced_box = VBoxContainer.new()
	_advanced_box.visible = false
	_advanced_box.add_theme_constant_override("separation", 4)
	col.add_child(_advanced_box)
	var adv_grid := GridContainer.new()
	adv_grid.columns = 2
	adv_grid.add_theme_constant_override("h_separation", 12)
	adv_grid.add_theme_constant_override("v_separation", 4)
	_advanced_box.add_child(adv_grid)
	_add_slider(adv_grid, "Plot depth (m)", 10.0, 120.0, _plot_depth_m,
		"How far from a street a cell may still be camped",
		func(v: float) -> void: _plot_depth_m = v)
	_add_slider(adv_grid, "Scatter step (m)", 2.0, 16.0, _scatter_step_m,
		"Average spacing between camp components",
		func(v: float) -> void: _scatter_step_m = v)
	_add_slider(adv_grid, "Light LOD (m)", 40.0, 400.0, _light_lod_m,
		"Real OmniLight pool only considers glow points within this camera radius",
		func(v: float) -> void: _light_lod_m = v)
	_add_slider(adv_grid, "Billboard lights", 4.0, 80.0, float(_max_pool_lights),
		"Max live OmniLights following the camera (billboard glow density)",
		func(v: float) -> void: _max_pool_lights = int(round(v)))

	# Status.
	_status = Label.new()
	_status.text = "Select an area · Circle/Rect/Lasso/Polygon · BRC Auto: auto-detect"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", 11)
	_status.add_theme_color_override("font_color", Color(0.68, 0.60, 0.45, 1.0))
	col.add_child(_status)


func _v_sep() -> VSeparator:
	var s := VSeparator.new()
	s.custom_minimum_size = Vector2(2, 0)
	return s


func _add_slider(parent: Control, label: String, lo: float, hi: float, val: float,
		tip: String, on_change: Callable) -> HSlider:
	var lbl := Label.new()
	lbl.text = label
	lbl.tooltip_text = tip
	lbl.add_theme_color_override("font_color", Color(0.60, 0.55, 0.42, 1.0))
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	parent.add_child(lbl)
	var sl := HSlider.new()
	sl.min_value = lo
	sl.max_value = hi
	sl.step = 0.01
	sl.value = val
	sl.tooltip_text = tip
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl.value_changed.connect(on_change)
	parent.add_child(sl)
	return sl


# ---------------------------------------------------------------------------
# Mode enter / exit
# ---------------------------------------------------------------------------

func _enter_mode() -> void:
	_active = true
	visible = true
	_capture.mouse_filter = Control.MOUSE_FILTER_STOP
	mode_changed.emit(true)
	set_process(false)
	_set_status("Select area · BRC Auto detects the full city · Rect/Lasso: drag on terrain")
	# Refresh BRC auto area if tool is already set to BRC_AUTO.
	if _tool == Tool.BRC_AUTO:
		_fetch_brc_auto_area()
	CursorController.request_modal(MODAL_NAME, Callable(self, "_exit_mode"))
	move_to_front()


func _exit_mode() -> void:
	if not _active:
		return
	_active = false
	_selecting = false
	_capture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect_overlay.visible = false
	_poly_draw.queue_redraw()
	visible = false
	mode_changed.emit(false)
	CursorController.release_modal(MODAL_NAME)
	_set_busy(false)


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

func _on_capture_input(event: InputEvent) -> void:
	if not _active or _busy:
		return
	if event is InputEventKey and (event as InputEventKey).pressed:
		var key := event as InputEventKey
		match key.keycode:
			KEY_ESCAPE:
				_exit_mode()
				get_viewport().set_input_as_handled()
			KEY_ENTER, KEY_KP_ENTER:
				_generate()
				get_viewport().set_input_as_handled()
		return

	if _tool == Tool.BRC_AUTO:
		return  # BRC Auto doesn't use mouse drag.

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_handle_mouse_btn(mb)
			get_viewport().set_input_as_handled()
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			if _tool == Tool.POLYGON and _poly_points.size() >= 3:
				_handle_mouse_btn(mb)
			else:
				_reset_selection()
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion:
		_handle_mouse_move(event as InputEventMouseMotion)
		get_viewport().set_input_as_handled()


func _handle_mouse_btn(mb: InputEventMouseButton) -> void:
	if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed and _tool == Tool.POLYGON:
		if _poly_points.size() >= 3:
			_brush_poly = _poly_points.duplicate()
			_set_status("Polygon closed (%d pts) · press GENERATE" % _poly_points.size())
			_poly_draw.queue_redraw()
		return
	match _tool:
		Tool.CIRCLE, Tool.RECT:
			if mb.pressed:
				var hit := _pick_world(mb.position)
				if hit == Vector2.INF:
					return
				_selecting = true
				_brush_anchor = hit
				_brush_poly = PackedVector2Array()
				_sel_start = mb.position
				_sel_end = mb.position
				_update_rect_overlay()
			else:
				_selecting = false
				_rect_overlay.visible = false
				_update_brush_from_screen(mb.position)
				_poly_draw.queue_redraw()
				if _brush_poly.size() >= 3:
					_set_status("Area selected · press Enter or GENERATE")
		Tool.LASSO:
			if mb.pressed:
				_selecting = true
				_lasso_pts = PackedVector2Array()
				_append_lasso(mb.position)
				_last_lasso_sample = mb.position
			else:
				_selecting = false
				_poly_draw.queue_redraw()
				if _lasso_pts.size() >= 3:
					_set_status("Lasso area selected (%d pts) · press GENERATE" % _lasso_pts.size())
		Tool.POLYGON:
			if mb.pressed:
				var hit := _pick_world(mb.position)
				if hit == Vector2.INF:
					return
				if _poly_points.size() >= 3 and hit.distance_to(_poly_points[0]) < 3.0:
					_brush_poly = _poly_points.duplicate()
					_set_status("Polygon closed (%d pts) · press GENERATE" % _poly_points.size())
				else:
					_poly_points.append(hit)
					_brush_poly = _poly_points.duplicate()
					_set_status("Polygon: %d points — Enter/RMB to finish" % _poly_points.size())
				_poly_draw.queue_redraw()


func _handle_mouse_move(mm: InputEventMouseMotion) -> void:
	match _tool:
		Tool.CIRCLE, Tool.RECT:
			if _selecting:
				_sel_end = mm.position
				_update_brush_from_screen(mm.position)
				_update_rect_overlay()
				_poly_draw.queue_redraw()
		Tool.LASSO:
			if _selecting and mm.position.distance_to(_last_lasso_sample) >= 8.0:
				_append_lasso(mm.position)
				_last_lasso_sample = mm.position
				_poly_draw.queue_redraw()
		Tool.POLYGON:
			if _poly_points.size() >= 1:
				_poly_draw.queue_redraw()


func _pick_world(screen_pos: Vector2) -> Vector2:
	if _loader == null or not _loader.has_method("terrain_pick_ray"):
		return Vector2.INF
	var hit: Variant = _loader.call("terrain_pick_ray", screen_pos)
	if hit is Vector3:
		return Vector2((hit as Vector3).x, (hit as Vector3).z)
	return Vector2.INF


func _update_brush_from_screen(screen_pos: Vector2) -> void:
	var cursor := _pick_world(screen_pos)
	if cursor == Vector2.INF:
		return
	match _tool:
		Tool.CIRCLE:
			var radius := maxf(_brush_anchor.distance_to(cursor), 2.0)
			_brush_poly = VegetationPaint.circle_polygon(_brush_anchor, radius)
		Tool.RECT:
			_brush_poly = VegetationPaint.rect_to_polygon(_brush_anchor, cursor)


func _append_lasso(screen_pos: Vector2) -> void:
	var hit := _pick_world(screen_pos)
	if hit != Vector2.INF:
		_lasso_pts.append(hit)


func _update_rect_overlay() -> void:
	# Screen rect preview only for RECT; CIRCLE uses world poly overlay.
	if _tool != Tool.RECT:
		_rect_overlay.visible = false
		return
	var r := Rect2(_sel_start, _sel_end - _sel_start).abs()
	_rect_overlay.visible = r.size.length_squared() > 4.0
	_rect_overlay.position = r.position
	_rect_overlay.size = r.size


func _draw_selection_overlay() -> void:
	if not _active:
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return

	var pts_world := PackedVector2Array()
	match _tool:
		Tool.CIRCLE, Tool.RECT:
			pts_world = _brush_poly
		Tool.LASSO:
			pts_world = _lasso_pts
		Tool.POLYGON:
			pts_world = _poly_points.duplicate()
			var cursor := _pick_world(get_viewport().get_mouse_position())
			if cursor != Vector2.INF and _poly_points.size() >= 1:
				pts_world.append(cursor)
		Tool.BRC_AUTO:
			pts_world = _auto_area

	if pts_world.size() < 2:
		return

	var screen_pts := PackedVector2Array()
	for p in pts_world:
		screen_pts.append(cam.unproject_position(Vector3(p.x, 0.0, p.y)))
	if screen_pts.size() >= 2:
		var col := Color(0.95, 0.65, 0.12, 0.85)
		_poly_draw.draw_polyline(screen_pts, col, 2.5, true)
		if screen_pts.size() >= 3:
			_poly_draw.draw_line(screen_pts[screen_pts.size() - 1], screen_pts[0], col, 2.5, true)


# ---------------------------------------------------------------------------
# Tool selection
# ---------------------------------------------------------------------------

func _on_tool_pressed(t: int) -> void:
	_tool = t as Tool
	for i in _tool_buttons.size():
		_style_tool_button(_tool_buttons[i], i == t)
	_reset_selection()
	match _tool:
		Tool.CIRCLE:
			_set_status("Drag from centre to set circle radius on terrain")
		Tool.RECT:
			_set_status("Drag a rectangle on the terrain to define camp area")
		Tool.LASSO:
			_set_status("Click and drag freehand on terrain · release to finish")
		Tool.POLYGON:
			_set_status("Click points on terrain · Enter/RMB or click near start to finish")
		Tool.BRC_AUTO:
			_fetch_brc_auto_area()


func _fetch_brc_auto_area() -> void:
	if _loader == null or not _loader.has_method("get_brc_city_area"):
		_set_status("BRC Auto: terrain not ready or no OSM data loaded")
		return
	var area: PackedVector2Array = _loader.call("get_brc_city_area")
	if area.size() < 3:
		_set_status("BRC Auto: no road data found — load a BRC map first or use Circle/Rect/Lasso")
		_auto_area = PackedVector2Array()
		_poly_draw.queue_redraw()
		return
	_auto_area = area
	_poly_draw.queue_redraw()
	_set_status("BRC Auto: %d-pt city outline · press GENERATE to populate" % area.size())


func _reset_selection() -> void:
	_lasso_pts = PackedVector2Array()
	_poly_points = PackedVector2Array()
	_brush_poly = PackedVector2Array()
	_brush_anchor = Vector2.ZERO
	_sel_start = Vector2.ZERO
	_sel_end = Vector2.ZERO
	_rect_overlay.visible = false
	if _tool != Tool.BRC_AUTO:
		_auto_area = PackedVector2Array()
	_poly_draw.queue_redraw()


# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

func _current_polygon() -> PackedVector2Array:
	match _tool:
		Tool.CIRCLE, Tool.RECT:
			return _brush_poly
		Tool.LASSO:
			return _lasso_pts
		Tool.POLYGON:
			return _poly_points if _poly_points.size() >= 3 else _brush_poly
		Tool.BRC_AUTO:
			return _auto_area
	return PackedVector2Array()


func _generate() -> void:
	if _busy or _loader == null or not _loader.has_method("generate_camps_in_polygon"):
		return
	if _tool == Tool.POLYGON and _poly_points.size() >= 3 and _brush_poly.size() < 3:
		_brush_poly = _poly_points.duplicate()
	var poly := _current_polygon()
	if poly.size() < 3:
		_set_status("No area selected — use Circle, Rect, Lasso, Polygon, or BRC Auto")
		return
	_set_busy(true)
	_set_status("Generating camps…")
	var params := {
		"density": _density,
		"mix_bias": _mix_bias,
		"scale_min": _scale_min,
		"scale_max": _scale_max,
		"light_density": _light_density,
		"seed": _seed,
		"exclusion_radius_m": _exclusion_r,
		"plot_depth_m": _plot_depth_m,
		"scatter_step_m": _scatter_step_m,
		"light_lod_m": _light_lod_m,
		"max_pool_lights": _max_pool_lights,
	}
	var n: int = int(_loader.call("generate_camps_in_polygon", poly, params))
	_set_busy(false)
	if n > 0:
		_set_status("Generated %d camp structures · adjust seed/params and regenerate anytime" % n)
	else:
		_set_status("No structures placed — area may be outside road network, or no roads loaded")


func _clear() -> void:
	if _loader == null or not _loader.has_method("clear_camps"):
		return
	_loader.call("clear_camps")
	_set_status("Camps cleared")


func _randomize_seed() -> void:
	_seed = randi() % 999999
	if _seed_spin != null:
		_seed_spin.set_block_signals(true)
		_seed_spin.value = _seed
		_seed_spin.set_block_signals(false)


# ---------------------------------------------------------------------------
# Status / busy helpers
# ---------------------------------------------------------------------------

func _set_status(msg: String) -> void:
	if _status != null:
		_status.text = msg


func _set_busy(on: bool) -> void:
	_busy = on
	if _generate_btn != null:
		_generate_btn.disabled = on
		_generate_btn.text = "…  Working" if on else "▶  GENERATE"
