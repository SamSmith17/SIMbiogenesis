extends Control

## Terrain sculpt dock (T). All tools write the unified high-resolution edit-tile
## layer (TerrainEditTiles, rendered live by TerrainHeightField as per-tile hi-res
## meshes + colliders): Level a selection to one height, Raise/Lower/Smooth
## freehand brushes, Ramp a graded path, Measure distance/grade, Pond (carve
## only), and Rain/Drain (hold to modulate water toward spill). Top-down shows
## live contours + cut/fill.

signal mode_changed(active: bool)

enum Tool { SMOOTH, FLATTEN, POND, BRUSH_RAISE, BRUSH_LOWER, RAMP, MEASURE, RAIN, DRAIN }
enum ShapeMode { BRUSH, CIRCLE, RECT, LASSO, POLYGON }

const MODAL_NAME := "terrain_edit"
const SliderSpinRowScript := preload("res://scenes/ui/slider_spin_row.gd")
const PANEL_HEIGHT := 148.0
const PITCH_90 := -89.0
const MAX_RADIUS_M := 150.0
const MAX_AREA_M2 := 90000.0
const LASSO_SAMPLE_PX := 8.0
const HIGHLIGHT_COLOR := Color(0.35, 0.85, 1.0, 0.45)
const TOP_HIGHLIGHT_COLOR := Color(1.0, 0.78, 0.28, 0.95)

var _loader: Node = null
var _active := false
var _tool := Tool.FLATTEN
var _shape_mode := ShapeMode.RECT
var _radius_m := 12.0
var _strength := 6.0
var _hardness := 0.5
var _pond_depth := 1.2
var _rain_rate := 0.15  ## m/s of water-surface rise while Rain/Drain held

# Soft brush stroke.
var _stroking := false
var _flatten_target := 0.0

# Shape selection.
var _shaping := false
var _shape_anchor := Vector2.ZERO
var _shape_poly := PackedVector2Array()
var _lasso_pts := PackedVector2Array()
var _lasso_screen := PackedVector2Array()
var _last_lasso_sample := Vector2.ZERO
var _poly_points := PackedVector2Array()

# Locked selection (persists after draw).
var _selection_locked := false
var _selection_poly := PackedVector2Array()

# Two-click gestures (Ramp grade, Measure tape). _gesture_a is the first world
# point once placed; the second click completes the action.
var _gesture_has_a := false
var _gesture_a := Vector2.ZERO

# Top-down elevation contour overlay (cached world-space segments recomputed only
# when the camera moves; projected + drawn each frame).
var _show_contours := true
var _contour_segs: Array = []          ## each: [Vector2 a, Vector2 b, float level]
var _contour_center := Vector2(INF, INF)
var _contour_interval_m := 1.0
const CONTOUR_GRID_N := 40
const CONTOUR_HALF_M := 180.0
const CONTOUR_RECOMPUTE_MOVE_M := 25.0

# Top-down.
var _topdown := false
var _pitch_deg := PITCH_90
var _locked_yaw := 0.0
var _saved_camera_projection := Camera3D.PROJECTION_PERSPECTIVE
var _saved_camera_size := 500.0
var _we_mounted_drone := false

var _cursor_hit: Variant = null
var _clear_armed := false

var _brush_ring: MeshInstance3D = null

var _capture: ColorRect = null
var _overlay: Control = null
var _panel: PanelContainer = null
var _status: Label = null
var _undo_btn: Button = null
var _topdown_btn: Button = null
var _tool_buttons: Array[Button] = []
## Parallel to _tool_buttons: the Tool each button selects. The button display
## order does NOT match the Tool enum's values, so highlight state must key off
## this map, never the loop index (that was the crosswired-highlight bug).
var _tool_button_tools: Array = []
var _shape_buttons: Array[Button] = []
## Parallel to _shape_buttons: the ShapeMode each selects (same reasoning).
var _shape_button_modes: Array = []
var _brush_row: HBoxContainer = null
var _pond_row: HBoxContainer = null
var _rain_row: HBoxContainer = null
var _basin_lbl: Label = null
var _height_lbl: Label = null

## Hold-to-modulate Rain/Drain while selection is locked.
var _water_modulating := false
var _water_mod_undo_pushed := false
var _last_fill_rate_lps := 0.0
var _basin_cache: Dictionary = {}


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiScreenLayout.pin_fullscreen(self)
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
# UI
# ---------------------------------------------------------------------------

func _panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.1, 0.14, 0.96)
	sb.set_corner_radius_all(8)
	sb.set_border_width_all(2)
	sb.border_color = Color(0.3, 0.5, 0.6, 0.85)
	sb.shadow_color = Color(0, 0, 0, 0.45)
	sb.shadow_size = 6
	return sb


func _secondary_btn_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.12, 0.16, 0.22, 1.0)
	sb.border_color = Color(0.25, 0.4, 0.55, 0.7)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	return sb


func _toggle_btn_style(on: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(4)
	sb.set_border_width_all(1)
	if on:
		sb.bg_color = Color(0.16, 0.32, 0.4, 1.0)
		sb.border_color = Color(0.35, 0.7, 0.9, 0.9)
	else:
		sb.bg_color = Color(0.1, 0.13, 0.18, 1.0)
		sb.border_color = Color(0.22, 0.32, 0.45, 0.6)
	return sb


func _style_tool_button(btn: Button, on: bool) -> void:
	btn.toggle_mode = true
	btn.button_pressed = on
	btn.add_theme_stylebox_override("normal", _toggle_btn_style(on))
	btn.add_theme_stylebox_override("pressed", _toggle_btn_style(true))
	btn.add_theme_stylebox_override("hover", _toggle_btn_style(on))
	btn.add_theme_color_override("font_color", Color(0.85, 0.92, 0.95) if on else Color(0.6, 0.68, 0.75))
	btn.add_theme_font_size_override("font_size", 12)


func _style_section(lbl: Label, text: String) -> void:
	lbl.text = text
	lbl.add_theme_color_override("font_color", Color(0.5, 0.65, 0.8, 1.0))
	lbl.add_theme_font_size_override("font_size", 11)


func _build_ui() -> void:
	_capture = ColorRect.new()
	_capture.name = "SelectCapture"
	_capture.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_capture.color = Color(0, 0, 0, 0)
	_capture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_capture.gui_input.connect(_on_capture_input)
	add_child(_capture)

	_overlay = Control.new()
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_draw_overlay)
	add_child(_overlay)

	_panel = PanelContainer.new()
	_panel.name = "DockPanel"
	UiScreenLayout.pin_over_timeline(_panel, PANEL_HEIGHT)
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.add_theme_stylebox_override("panel", _panel_style())
	add_child(_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_bottom", 6)
	_panel.add_child(margin)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	margin.add_child(col)

	# Action row.
	var tool_row := HBoxContainer.new()
	tool_row.add_theme_constant_override("separation", 5)
	col.add_child(tool_row)
	_tool_buttons.clear()
	_tool_button_tools.clear()
	for spec in [
			["Level", Tool.FLATTEN,
				"Drag a rectangle — releasing grades the pad flat at its centre height"],
			["Pond", Tool.POND,
				"Hold LMB and lasso an outline — releasing digs a bowl (use Rain to fill)"],
			["Rain", Tool.RAIN,
				"Draw over a depression, then hold LMB to raise the water toward the spill"],
			["Drain", Tool.DRAIN,
				"Draw over a user pond, then hold LMB to lower / empty the water"],
			["Raise", Tool.BRUSH_RAISE,
				"Hold LMB and paint to build the ground up (Size / Strength / Hardness below)"],
			["Lower", Tool.BRUSH_LOWER,
				"Hold LMB and paint to dig the ground down (Size / Strength / Hardness below)"],
			["Smooth", Tool.SMOOTH,
				"Hold LMB and paint to soften bumps and steps"],
			["Ramp", Tool.RAMP,
				"Click a start point, then an end point, to grade an even slope between them"],
			["Measure", Tool.MEASURE,
				"Click two points to read distance, elevation change, and grade"]]:
		var b := Button.new()
		b.text = spec[0]
		b.custom_minimum_size = Vector2(54, 28)
		b.tooltip_text = spec[2]
		var t: Tool = spec[1]
		b.pressed.connect(_on_tool_pressed.bind(t))
		_style_tool_button(b, t == _tool)
		tool_row.add_child(b)
		_tool_buttons.append(b)
		_tool_button_tools.append(t)
	_undo_btn = Button.new()
	_undo_btn.text = "Undo"
	_undo_btn.custom_minimum_size = Vector2(48, 28)
	_undo_btn.add_theme_stylebox_override("normal", _secondary_btn_style())
	_undo_btn.pressed.connect(_do_undo)
	tool_row.add_child(_undo_btn)
	var clear_btn := Button.new()
	clear_btn.text = "Clear all"
	clear_btn.custom_minimum_size = Vector2(66, 28)
	clear_btn.add_theme_stylebox_override("normal", _secondary_btn_style())
	clear_btn.pressed.connect(_on_clear_all)
	tool_row.add_child(clear_btn)
	_topdown_btn = Button.new()
	_topdown_btn.text = "Top-down"
	_topdown_btn.custom_minimum_size = Vector2(72, 28)
	_style_tool_button(_topdown_btn, false)
	_topdown_btn.pressed.connect(_toggle_topdown)
	tool_row.add_child(_topdown_btn)
	var exit_btn := Button.new()
	exit_btn.text = "Exit"
	exit_btn.custom_minimum_size = Vector2(44, 28)
	exit_btn.add_theme_stylebox_override("normal", _secondary_btn_style())
	exit_btn.pressed.connect(_exit_mode)
	tool_row.add_child(exit_btn)
	_status = Label.new()
	_status.add_theme_color_override("font_color", Color(0.65, 0.72, 0.78, 1.0))
	_status.add_theme_font_size_override("font_size", 11)
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.text = "Pick a tool: Level · Pond (carve) · Rain/Drain · Raise/Lower"
	tool_row.add_child(_status)

	# Shape + params.
	var shape_row := HBoxContainer.new()
	shape_row.add_theme_constant_override("separation", 4)
	col.add_child(shape_row)
	var shape_lbl := Label.new()
	_style_section(shape_lbl, "Shape")
	shape_lbl.custom_minimum_size = Vector2(40, 0)
	shape_row.add_child(shape_lbl)
	_shape_buttons.clear()
	_shape_button_modes.clear()
	for spec in [["Brush", ShapeMode.BRUSH], ["Circle", ShapeMode.CIRCLE],
			["Rect", ShapeMode.RECT], ["Lasso", ShapeMode.LASSO], ["Polygon", ShapeMode.POLYGON]]:
		var sb := Button.new()
		sb.text = spec[0]
		sb.custom_minimum_size = Vector2(54, 24)
		var m: ShapeMode = spec[1]
		sb.pressed.connect(_on_shape_pressed.bind(m))
		_style_tool_button(sb, m == _shape_mode)
		shape_row.add_child(sb)
		_shape_buttons.append(sb)
		_shape_button_modes.append(m)

	_height_lbl = Label.new()
	_height_lbl.add_theme_color_override("font_color", Color(0.7, 0.85, 0.55, 1.0))
	_height_lbl.add_theme_font_size_override("font_size", 11)
	_height_lbl.text = ""
	shape_row.add_child(_height_lbl)

	var param_row := HBoxContainer.new()
	param_row.add_theme_constant_override("separation", 8)
	col.add_child(param_row)
	_brush_row = HBoxContainer.new()
	_brush_row.add_theme_constant_override("separation", 4)
	param_row.add_child(_brush_row)
	_labeled_slider(_brush_row, "Size m", 1.0, MAX_RADIUS_M, _radius_m,
		func(v: float) -> void: _radius_m = v, 100)
	_labeled_slider(_brush_row, "Strength", 0.1, 25.0, _strength,
		func(v: float) -> void: _strength = v, 100)
	_labeled_slider(_brush_row, "Hardness", 0.0, 1.0, _hardness,
		func(v: float) -> void: _hardness = v, 100)
	_pond_row = HBoxContainer.new()
	_pond_row.add_theme_constant_override("separation", 4)
	param_row.add_child(_pond_row)
	_labeled_slider(_pond_row, "Dig depth m", 0.1, 8.0, _pond_depth,
		func(v: float) -> void: _pond_depth = v, 110)
	_rain_row = HBoxContainer.new()
	_rain_row.add_theme_constant_override("separation", 4)
	param_row.add_child(_rain_row)
	_labeled_slider(_rain_row, "Rate m/s", 0.02, 1.0, _rain_rate,
		func(v: float) -> void: _rain_rate = v, 100)
	var flood_btn := Button.new()
	flood_btn.text = "Flood pits"
	flood_btn.custom_minimum_size = Vector2(76, 28)
	flood_btn.add_theme_stylebox_override("normal", _secondary_btn_style())
	flood_btn.tooltip_text = ("Gravity-fill every closed depression inside the "
			+ "selection — each pit ponds to its own natural spill level")
	flood_btn.pressed.connect(_on_flood_pits)
	_rain_row.add_child(flood_btn)
	_basin_lbl = Label.new()
	_basin_lbl.add_theme_color_override("font_color", Color(0.55, 0.85, 0.95, 1.0))
	_basin_lbl.add_theme_font_size_override("font_size", 11)
	_basin_lbl.text = ""
	_rain_row.add_child(_basin_lbl)


func _labeled_slider(parent: Control, label: String, min_v: float, max_v: float,
		start: float, handler: Callable, slider_min_w: int = 110) -> void:
	SliderSpinRowScript.add(parent, label, min_v, max_v, start, handler,
		func(lbl: Label, txt: String) -> void: _style_section(lbl, txt),
		78, slider_min_w, 56)


# ---------------------------------------------------------------------------
# Enter / exit
# ---------------------------------------------------------------------------

func _enter_mode() -> void:
	_active = true
	visible = true
	_capture.mouse_filter = Control.MOUSE_FILTER_STOP
	mode_changed.emit(true)
	_clear_stale_ortho_meta()
	_clear_armed = false
	if _loader != null and not bool(_loader.call("can_sculpt_detail")):
		_set_status("Detail terrain still loading — sculpting needs the hi-res patch")
	else:
		_set_status("Pick a tool: Level · Pond (carve) · Rain/Drain · Raise/Lower")
		if _loader != null:
			_loader.call("begin_sculpt_session")
	set_process(true)
	move_to_front()
	CursorController.request_modal(MODAL_NAME, Callable(self, "_exit_mode"))
	_update_param_rows()
	_update_undo_button()
	_update_crosshair_prompt()


func _exit_mode() -> void:
	if not _active:
		return
	_active = false
	_stroking = false
	_shaping = false
	_gesture_has_a = false
	_clear_locked_selection()
	_poly_points = PackedVector2Array()
	_lasso_pts = PackedVector2Array()
	_lasso_screen = PackedVector2Array()
	_shape_poly = PackedVector2Array()
	set_process(false)
	visible = false
	mode_changed.emit(false)
	_free_brush_ring()
	if _topdown:
		_set_topdown(false)
	if _loader != null:
		_loader.call("end_sculpt_session")
	_capture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	CursorController.release_modal(MODAL_NAME)
	_clear_crosshair_prompt()
	if _overlay != null:
		_overlay.queue_redraw()


func _clear_stale_ortho_meta() -> void:
	var main: Node = _loader.get_parent() if _loader != null else null
	if main == null:
		return
	var drone := main.get_node_or_null("FPVDrone")
	if drone != null and drone.has_meta("terrain_edit_ortho"):
		drone.set_meta("terrain_edit_ortho", false)


# ---------------------------------------------------------------------------
# Process
# ---------------------------------------------------------------------------

## Last pointer position the dock reacted to, so an idle mouse costs nothing.
var _last_pointer_px: Vector2 = Vector2(-1.0e9, -1.0e9)


func _process(delta: float) -> void:
	if not _active:
		return
	# _pick_pointer() is a ray into the world and the overlay redraw below is a
	# full canvas pass; both ran every frame while the dock was merely OPEN,
	# with no stroke in progress and the mouse sitting still. Gate on "the
	# pointer moved, or something is actively being dragged" — the shape
	# scenes/ui/space_edit_ui.gd already uses.
	var mouse := get_viewport().get_mouse_position() if get_viewport() != null else Vector2.ZERO
	var busy := _water_modulating or _stroking or _shaping
	if not busy and mouse.is_equal_approx(_last_pointer_px):
		return
	_last_pointer_px = mouse
	_cursor_hit = _pick_pointer()
	if _water_modulating:
		_tick_water_modulate(delta)
	elif _stroking:
		_brush_tick(delta)
	elif _shaping and (_shape_mode == ShapeMode.CIRCLE or _shape_mode == ShapeMode.RECT):
		_update_shape_from_cursor()
	_update_brush_ring()
	_update_height_readout()
	if _overlay != null:
		_overlay.queue_redraw()


## Live cursor readout: ground elevation + the player's net edit at that spot —
## instant numeric proof that a stroke is landing where the cursor is.
func _update_height_readout() -> void:
	if _height_lbl == null or _loader == null:
		return
	if not (_cursor_hit is Vector3):
		_height_lbl.text = ""
		return
	var p: Vector3 = _cursor_hit
	var gy := float(_loader.call("ground_height_at", p.x, p.z))
	var d := 0.0
	if _loader.has_method("terrain_edit_delta_at"):
		d = float(_loader.call("terrain_edit_delta_at", p.x, p.z))
	if absf(d) >= 0.05:
		_height_lbl.text = "Ground %.1f m · edited %+.1f m" % [gy, d]
	else:
		_height_lbl.text = "Ground %.1f m" % gy


# ---------------------------------------------------------------------------
# 3D brush ring — a world-space decal at the cursor sized to the brush radius,
# so freehand brushing has clear feedback (SimCity/Skylines style).
# ---------------------------------------------------------------------------

func _ensure_brush_ring() -> MeshInstance3D:
	if _brush_ring != null and is_instance_valid(_brush_ring):
		return _brush_ring
	var main: Node = _loader.get_parent() if _loader != null else null
	if main == null:
		return null
	var ring := MeshInstance3D.new()
	ring.name = "TerrainBrushRing"
	var torus := TorusMesh.new()
	torus.outer_radius = 1.0
	torus.inner_radius = 0.94
	torus.rings = 48
	ring.mesh = torus
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.85, 0.3, 0.9)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = true
	mat.render_priority = 2
	ring.material_override = mat
	ring.top_level = true
	ring.visible = false
	main.add_child(ring)
	_brush_ring = ring
	return ring


func _update_brush_ring() -> void:
	var show := _active and _shape_mode == ShapeMode.BRUSH \
		and _tool != Tool.POND and _tool != Tool.RAIN and _tool != Tool.DRAIN \
		and (_cursor_hit is Vector3)
	var ring := _ensure_brush_ring()
	if ring == null:
		return
	if not show:
		ring.visible = false
		return
	var p: Vector3 = _cursor_hit
	ring.visible = true
	ring.global_position = Vector3(p.x, p.y + 0.15, p.z)
	# Uniform scale to the brush radius (torus lies flat in the XZ plane).
	var r := maxf(_radius_m, 0.5)
	ring.scale = Vector3(r, maxf(r * 0.02, 0.15), r)


func _free_brush_ring() -> void:
	if _brush_ring != null and is_instance_valid(_brush_ring):
		_brush_ring.queue_free()
	_brush_ring = null


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not _active:
		return
	if event is InputEventKey and (event as InputEventKey).pressed:
		var key := event as InputEventKey
		if key.keycode == KEY_ESCAPE:
			if _cancel_shape_or_exit():
				get_viewport().set_input_as_handled()
			return
		if key.keycode == KEY_Z and key.ctrl_pressed:
			_do_undo()
			get_viewport().set_input_as_handled()
			return
		if key.keycode == KEY_ENTER or key.keycode == KEY_KP_ENTER:
			if _shape_mode == ShapeMode.POLYGON and _poly_points.size() >= 3:
				_finish_polygon()
				get_viewport().set_input_as_handled()
			return


func _on_capture_input(event: InputEvent) -> void:
	if not _active:
		return
	if _is_pointer_over_panel():
		return
	if event is InputEventMouseMotion:
		if _shaping and _shape_mode == ShapeMode.LASSO:
			var mm := event as InputEventMouseMotion
			if mm.position.distance_to(_last_lasso_sample) >= LASSO_SAMPLE_PX:
				_append_lasso_point(mm.position)
				_last_lasso_sample = mm.position
			get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_on_lmb_pressed()
			else:
				_on_lmb_released()
			get_viewport().set_input_as_handled()
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			if _shape_mode == ShapeMode.POLYGON and _poly_points.size() >= 3:
				_finish_polygon()
			else:
				_cancel_shape_or_exit()
			get_viewport().set_input_as_handled()


func _on_lmb_pressed() -> void:
	_clear_armed = false
	var hit: Variant = _pick_pointer()
	if not (hit is Vector3):
		_set_status("Aim at the terrain")
		return
	var p: Vector3 = hit
	var world := Vector2(p.x, p.z)

	# Two-click gestures own the click entirely.
	if _tool == Tool.RAMP or _tool == Tool.MEASURE:
		_gesture_click(world)
		return

	# Rain/Drain: hold inside a locked selection to modulate level.
	if (_tool == Tool.RAIN or _tool == Tool.DRAIN) and _selection_locked \
			and _selection_poly.size() >= 3 \
			and Geometry2D.is_point_in_polygon(world, _selection_poly):
		_begin_water_modulate()
		return

	# A click outside an existing locked selection starts a new shape.
	if _selection_locked and _shape_mode != ShapeMode.BRUSH \
			and not Geometry2D.is_point_in_polygon(world, _selection_poly):
		_clear_locked_selection()

	match _shape_mode:
		ShapeMode.BRUSH:
			_begin_brush(world)
		ShapeMode.CIRCLE, ShapeMode.RECT:
			_shaping = true
			_shape_anchor = world
			_shape_poly = PackedVector2Array()
		ShapeMode.LASSO:
			_shaping = true
			_lasso_pts = PackedVector2Array()
			_lasso_screen = PackedVector2Array()
			_last_lasso_sample = get_viewport().get_mouse_position()
			_append_lasso_point(_last_lasso_sample)
		ShapeMode.POLYGON:
			if _poly_points.size() >= 3 and world.distance_to(_poly_points[0]) < maxf(_radius_m * 0.25, 3.0):
				_finish_polygon()
			else:
				_poly_points.append(world)
				_set_status("Polygon: %s — Enter/RMB to lock" % UiText.count(_poly_points.size(), "point"))


func _on_lmb_released() -> void:
	if _water_modulating:
		_end_water_modulate()
		return
	if _stroking:
		if _loader != null:
			_loader.call("end_terrain_tile_edit")
		_stroking = false
		_set_status(_volume_summary())
		_invalidate_contours()
		_update_undo_button()
		return
	if not _shaping:
		return
	match _shape_mode:
		ShapeMode.CIRCLE, ShapeMode.RECT:
			_update_shape_from_cursor()
			_shaping = false
			_lock_selection(_shape_poly)
			_shape_poly = PackedVector2Array()
		ShapeMode.LASSO:
			_shaping = false
			var poly := _lasso_pts.duplicate()
			_lasso_pts = PackedVector2Array()
			_lasso_screen = PackedVector2Array()
			_lock_selection(poly)


# ---------------------------------------------------------------------------
# Selection lock
# ---------------------------------------------------------------------------

func _lock_selection(poly: PackedVector2Array) -> void:
	if poly.size() < 3:
		_set_status("Selection too small — draw again")
		return
	var area := VegetationPaint.polygon_area(poly)
	if area > MAX_AREA_M2:
		_set_status("Area too large — shrink the selection")
		return
	if _loader == null or not bool(_loader.call("can_sculpt_detail")):
		_set_status("Sculpting needs the hi-res detail patch")
		return
	_selection_locked = true
	_selection_poly = poly.duplicate()
	# Pond tool: carve only (+ optional seed puddle); Rain fills afterward.
	if _tool == Tool.POND:
		if bool(_loader.call("pond_command", _selection_poly, _pond_depth, "Sculpted Pond",
				0.85, true)):
			_set_status(
				"Basin carved %.1f m — switch to Rain to fill · Esc clears" % _pond_depth)
			_invalidate_contours()
			_loader.call("update_sculpt_selection_highlight", _selection_poly)
			_refresh_basin_preview()
		else:
			_set_status("Pond needs a larger outline (min ~80 m²) — draw again")
			_clear_locked_selection()
	elif _tool == Tool.FLATTEN:
		# Level applies immediately on release (SimCity-style: draw → graded).
		_apply_area_op()
		_clear_locked_selection()
	elif _tool == Tool.RAIN or _tool == Tool.DRAIN:
		_loader.call("update_sculpt_selection_highlight", _selection_poly)
		_refresh_basin_preview()
		if bool(_basin_cache.get("valid", false)):
			_set_status(
				"Basin locked — hold %s to modulate · Esc clears" % (
					"Rain" if _tool == Tool.RAIN else "Drain"))
		else:
			var msg := "No closed basin"
			if _loader.has_method("basin_failure_message"):
				msg = str(_loader.call("basin_failure_message", _basin_cache))
			_set_status(msg)
	else:
		_loader.call("update_sculpt_selection_highlight", _selection_poly)
		_set_status("Selection locked (%.0f m²) — Esc clears · switch to Rain to fill" % area)
	_update_param_rows()
	_update_undo_button()
	_update_crosshair_prompt()


func _clear_locked_selection() -> void:
	_end_water_modulate()
	_selection_locked = false
	_selection_poly = PackedVector2Array()
	_basin_cache = {}
	if _loader != null and _loader.has_method("clear_sculpt_selection_highlight"):
		_loader.call("clear_sculpt_selection_highlight")
	if _height_lbl != null:
		_height_lbl.text = ""
	if _basin_lbl != null:
		_basin_lbl.text = ""
	_update_param_rows()
	_update_crosshair_prompt()


# ---------------------------------------------------------------------------
# Soft brush
# ---------------------------------------------------------------------------

func _begin_brush(world: Vector2) -> void:
	if _loader == null or not bool(_loader.call("can_sculpt_detail")):
		_set_status("Sculpting needs the hi-res detail patch")
		return
	# Raise / Lower / Smooth / Flatten drive the high-resolution edit layer.
	_loader.call("begin_terrain_tile_edit")
	_stroking = true
	if _tool == Tool.FLATTEN:
		_flatten_target = float(_loader.call("ground_height_at", world.x, world.y))
	_apply_brush_at(world, get_process_delta_time())


func _brush_tick(dt: float) -> void:
	var hit: Variant = _cursor_hit
	if not (hit is Vector3):
		return
	var p: Vector3 = hit
	_apply_brush_at(Vector2(p.x, p.z), dt)


func _apply_brush_at(world: Vector2, dt: float) -> void:
	if _loader == null:
		return
	var amount := 0.0
	match _tool:
		Tool.BRUSH_RAISE, Tool.BRUSH_LOWER:
			amount = _strength * clampf(dt, 0.0, 0.05)
		Tool.SMOOTH, Tool.FLATTEN:
			amount = clampf(_strength / 25.0, 0.0, 1.0) * clampf(dt * 6.0, 0.0, 1.0)
	var ty := _flatten_target if _tool == Tool.FLATTEN else NAN
	_loader.call("brush_stamp", _brush_op_name(), Vector3(world.x, 0.0, world.y),
		_radius_m, amount, _hardness, ty)


## First click sets the anchor; second click completes the ramp grade or reports
## the measured distance/elevation delta.
func _gesture_click(world: Vector2) -> void:
	if not _gesture_has_a:
		_gesture_a = world
		_gesture_has_a = true
		if _tool == Tool.RAMP:
			_set_status("Ramp: click the far end (width %.0f m)" % _radius_m)
		else:
			_set_status("Measure: click the second point")
		return
	var a := _gesture_a
	_gesture_has_a = false
	if _tool == Tool.RAMP:
		if _loader != null:
			_loader.call("ramp_command", Vector3(a.x, 0.0, a.y),
				Vector3(world.x, 0.0, world.y), _radius_m)
			_set_status("Ramp graded — %s" % _volume_summary())
			_invalidate_contours()
			_update_undo_button()
	else:
		var ya := 0.0
		var yb := 0.0
		if _loader != null:
			ya = float(_loader.call("ground_height_at", a.x, a.y))
			yb = float(_loader.call("ground_height_at", world.x, world.y))
		var horiz := a.distance_to(world)
		var slope_pct := 0.0 if horiz < 0.01 else (yb - ya) / horiz * 100.0
		_set_status("Distance %.1f m · Δelev %.2f m · slope %.1f%%" % [horiz, yb - ya, slope_pct])


func _volume_summary() -> String:
	if _loader == null or not _loader.has_method("edit_volume_estimate"):
		return ""
	var v: Dictionary = _loader.call("edit_volume_estimate")
	return "cut %.0f m³ · fill %.0f m³" % [
		float(v.get("cut_m3", 0.0)), float(v.get("fill_m3", 0.0))]


func _brush_op_name() -> String:
	match _tool:
		Tool.BRUSH_RAISE: return "raise"
		Tool.BRUSH_LOWER: return "lower"
		Tool.SMOOTH: return "smooth"
		Tool.FLATTEN: return "flatten"
		_: return "raise"


## Level the locked selection to the centroid's ground height at high resolution,
## feathered out to natural terrain at the rim (one undo step).
func _apply_area_op() -> void:
	if not _selection_locked or _loader == null or _tool != Tool.FLATTEN:
		return
	var c := _poly_centroid(_selection_poly)
	var target := float(_loader.call("ground_height_at", c.x, c.y))
	var feather := lerpf(24.0, 2.0, _hardness)
	_loader.call("level_region_command", _selection_poly, target, feather)
	_set_status("Leveled the pad to the centre height · %s · Undo reverts" % _volume_summary())
	_invalidate_contours()
	_update_undo_button()


# ---------------------------------------------------------------------------
# Shape helpers
# ---------------------------------------------------------------------------

func _update_shape_from_cursor() -> void:
	var hit: Variant = _cursor_hit
	if not (hit is Vector3):
		return
	var p: Vector3 = hit
	var cursor := Vector2(p.x, p.z)
	if _shape_mode == ShapeMode.CIRCLE:
		var radius := clampf(maxf(1.0, _shape_anchor.distance_to(cursor)), 1.0, MAX_RADIUS_M)
		_shape_poly = VegetationPaint.circle_polygon(_shape_anchor, radius)
	else:
		var d := cursor - _shape_anchor
		if d.length() > MAX_RADIUS_M * 2.0:
			cursor = _shape_anchor + d.normalized() * MAX_RADIUS_M * 2.0
		_shape_poly = VegetationPaint.rect_to_polygon(_shape_anchor, cursor)


func _append_lasso_point(screen_pos: Vector2) -> void:
	if _loader == null:
		return
	var hit: Variant = _loader.call("terrain_pick_ray", screen_pos)
	if hit is Vector3:
		_lasso_pts.append(Vector2((hit as Vector3).x, (hit as Vector3).z))
		_lasso_screen.append(screen_pos)


func _finish_polygon() -> void:
	var poly := _poly_points.duplicate()
	_poly_points = PackedVector2Array()
	_lock_selection(poly)


# ---------------------------------------------------------------------------
# Rain / Drain hold-to-modulate
# ---------------------------------------------------------------------------

func _is_water_tool(t: Tool = _tool) -> bool:
	return t == Tool.POND or t == Tool.RAIN or t == Tool.DRAIN


func _refresh_basin_preview() -> void:
	_basin_cache = {}
	if _loader == null or not _selection_locked or _selection_poly.size() < 3:
		if _basin_lbl != null:
			_basin_lbl.text = ""
		return
	if not _loader.has_method("analyze_selection_basin"):
		return
	_basin_cache = _loader.call("analyze_selection_basin", _selection_poly)
	_update_basin_label()


func _update_basin_label() -> void:
	if _basin_lbl == null:
		return
	if not bool(_basin_cache.get("valid", false)):
		var reason := str(_basin_cache.get("reason", ""))
		_basin_lbl.text = reason if not reason.is_empty() else ""
		return
	var rate_txt := ""
	if _water_modulating and absf(_last_fill_rate_lps) > 0.5:
		rate_txt = " · %.0f L/s" % _last_fill_rate_lps
	_basin_lbl.text = "Lvl %.2f / spill %.2f m · %.0f L (%.0f%%)%s" % [
		float(_basin_cache.get("level_m", 0.0)),
		float(_basin_cache.get("spill_m", 0.0)),
		float(_basin_cache.get("stock_l", 0.0)),
		float(_basin_cache.get("fill_frac", 0.0)) * 100.0,
		rate_txt,
	]


## One-shot gravity flood of the locked selection. The loader half
## (fill_selection_depressions) shipped complete but caller-less — the same
## shape as the apply_terrain_extents incident (built and correct, no UI).
func _on_flood_pits() -> void:
	if _loader == null or not _selection_locked or _selection_poly.size() < 3:
		_set_status("Lock a selection first (Rect / Circle / Lasso), then flood")
		return
	if not _loader.has_method("fill_selection_depressions"):
		return
	_push_sculpt_undo_if_possible()
	var n := int(_loader.call("fill_selection_depressions", _selection_poly))
	if n > 0:
		_set_status("Flooded %d pit%s to natural spill level" % [
			n, "" if n == 1 else "s"])
	else:
		_set_status("No closed depressions here — carve a basin first (Pond)")


func _begin_water_modulate() -> void:
	if _loader == null or not _selection_locked:
		return
	_water_modulating = true
	_water_mod_undo_pushed = false
	_last_fill_rate_lps = 0.0
	_refresh_basin_preview()
	if _tool == Tool.RAIN and not bool(_basin_cache.get("valid", false)):
		var msg := "No closed basin"
		if _loader.has_method("basin_failure_message"):
			msg = str(_loader.call("basin_failure_message", _basin_cache))
		_set_status(msg)
		_water_modulating = false


func _end_water_modulate() -> void:
	if not _water_modulating:
		return
	_water_modulating = false
	_last_fill_rate_lps = 0.0
	_refresh_basin_preview()
	_update_undo_button()
	if bool(_basin_cache.get("valid", false)):
		_set_status("Water at %.2f m · %.0f L (%.0f%%) · hold again to scrub" % [
			float(_basin_cache.get("level_m", 0.0)),
			float(_basin_cache.get("stock_l", 0.0)),
			float(_basin_cache.get("fill_frac", 0.0)) * 100.0])
	_update_basin_label()


func _tick_water_modulate(delta: float) -> void:
	if _loader == null or not _selection_locked or _selection_poly.size() < 3:
		_end_water_modulate()
		return
	if not _water_mod_undo_pushed:
		_push_sculpt_undo_if_possible()
		_water_mod_undo_pushed = true
	var step := maxf(_rain_rate, 0.01) * clampf(delta, 0.0, 0.05)
	var result: Dictionary = {}
	if _tool == Tool.RAIN and _loader.has_method("rain_selection"):
		result = _loader.call("rain_selection", _selection_poly, step)
	elif _tool == Tool.DRAIN and _loader.has_method("drain_selection"):
		result = _loader.call("drain_selection", _selection_poly, step)
	else:
		_end_water_modulate()
		return
	if not bool(result.get("ok", false)):
		var msg := str(result.get("reason", "failed"))
		if _loader.has_method("basin_failure_message"):
			msg = str(_loader.call("basin_failure_message", result))
		_set_status(msg)
		_end_water_modulate()
		return
	if bool(result.get("removed", false)):
		_set_status("Pond drained dry and removed")
		_basin_cache = result
		_update_basin_label()
		_end_water_modulate()
		return
	var dstock := float(result.get("delta_stock_l", 0.0))
	var dt := maxf(delta, 1e-4)
	_last_fill_rate_lps = dstock / dt
	_basin_cache = {
		"valid": true,
		"level_m": float(result.get("level_m", 0.0)),
		"spill_m": float(result.get("spill_m", 0.0)),
		"floor_m": float(result.get("floor_m", 0.0)),
		"stock_l": float(result.get("stock_l", 0.0)),
		"capacity_l": float(result.get("capacity_l", 0.0)),
		"fill_frac": float(result.get("fill_frac", 0.0)),
	}
	_update_basin_label()
	if bool(result.get("at_spill", false)) and _tool == Tool.RAIN:
		_set_status("At spill — rain stopped rising")


func _push_sculpt_undo_if_possible() -> void:
	# Rain/Drain should be undoable as one gesture — snapshot user water once.
	if _loader != null and _loader.has_method("push_sculpt_undo"):
		_loader.call("push_sculpt_undo")


func _active_pond_poly() -> PackedVector2Array:
	if _selection_locked and _selection_poly.size() >= 3:
		return _selection_poly
	return PackedVector2Array()


# ---------------------------------------------------------------------------
# Clear all
# ---------------------------------------------------------------------------

func _on_clear_all() -> void:
	if _loader == null:
		return
	if not _clear_armed:
		_clear_armed = true
		_set_status("Click Clear all again to confirm — wipes all terrain edits")
		return
	_clear_armed = false
	_clear_locked_selection()
	_loader.call("clear_all_terrain_edits")
	_set_status("All terrain edits cleared")
	_update_undo_button()


# ---------------------------------------------------------------------------
# Overlay
# ---------------------------------------------------------------------------

func _draw_overlay() -> void:
	if not _active or _overlay == null:
		return
	var col := _tool_color()
	if _topdown and _show_contours:
		_draw_contours()
	# Two-click gesture line (Ramp / Measure).
	if (_tool == Tool.RAMP or _tool == Tool.MEASURE) and _gesture_has_a:
		var cursor_w := _gesture_a
		if _cursor_hit is Vector3:
			cursor_w = Vector2((_cursor_hit as Vector3).x, (_cursor_hit as Vector3).z)
		var line := _project_poly(PackedVector2Array([_gesture_a, cursor_w]))
		if line.size() == 2:
			_overlay.draw_polyline(line, col, 2.5, true)
			_overlay.draw_circle(line[0], 4.0, col)
			_overlay.draw_circle(line[1], 4.0, col)
		return
	if _shape_mode == ShapeMode.LASSO and _lasso_screen.size() >= 2:
		_overlay.draw_polyline(_lasso_screen, col, 2.0, true)
		return
	if _shape_mode == ShapeMode.POLYGON and _poly_points.size() >= 1:
		var pts := _project_poly(_poly_points)
		if pts.size() >= 2:
			_overlay.draw_polyline(pts, col, 2.0, true)
		for sp in pts:
			_overlay.draw_circle(sp, 3.0, col)
		return
	if (_shape_mode == ShapeMode.CIRCLE or _shape_mode == ShapeMode.RECT) and _shape_poly.size() >= 3:
		var pts2 := _project_poly(_shape_poly)
		if pts2.size() >= 3:
			pts2.append(pts2[0])
			_overlay.draw_polyline(pts2, col, 2.0, true)
		return
	if _selection_locked and _selection_poly.size() >= 3:
		var pts3 := _project_poly(_selection_poly)
		if pts3.size() >= 3:
			pts3.append(pts3[0])
			_overlay.draw_polyline(pts3, HIGHLIGHT_COLOR, 2.5, true)
		return
	if _shape_mode == ShapeMode.BRUSH:
		var hit: Variant = _cursor_hit
		if hit is Vector3:
			var center := Vector2((hit as Vector3).x, (hit as Vector3).z)
			var ring := VegetationPaint.circle_polygon(center, _radius_m, 40)
			var pts4 := _project_poly(ring)
			if pts4.size() >= 3:
				pts4.append(pts4[0])
				_overlay.draw_polyline(pts4, col, 2.0, true)


## Elevation contour lines (marching squares) in the top-down view. Recomputed in
## world space only when the camera pans; each frame the cached segments are
## projected and drawn — cheap and steady.
func _draw_contours() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null or _loader == null:
		return
	var center := Vector2(cam.global_position.x, cam.global_position.z)
	if _contour_center.distance_to(center) > CONTOUR_RECOMPUTE_MOVE_M:
		_recompute_contours(center)
	var line_col := Color(0.95, 0.97, 1.0, 0.28)
	var index_col := Color(0.98, 0.85, 0.4, 0.5)  # every 5th line brighter
	for seg in _contour_segs:
		var a: Vector2 = seg[0]
		var b: Vector2 = seg[1]
		var level: float = seg[2]
		var wa := Vector3(a.x, level + 0.2, a.y)
		var wb := Vector3(b.x, level + 0.2, b.y)
		if cam.is_position_behind(wa) or cam.is_position_behind(wb):
			continue
		var is_index := absf(fmod(level, _contour_interval_m * 5.0)) < 0.01
		_overlay.draw_line(cam.unproject_position(wa), cam.unproject_position(wb),
			index_col if is_index else line_col, 1.5 if is_index else 1.0, true)


func _invalidate_contours() -> void:
	_contour_center = Vector2(INF, INF)


func _recompute_contours(center: Vector2) -> void:
	_contour_segs.clear()
	_contour_center = center
	if _loader == null:
		return
	var n := CONTOUR_GRID_N
	var half := CONTOUR_HALF_M
	var step := (half * 2.0) / float(n - 1)
	var h := PackedFloat32Array()
	h.resize(n * n)
	var lo := INF
	var hi := -INF
	for j in n:
		for i in n:
			var wx := center.x - half + float(i) * step
			var wz := center.y - half + float(j) * step
			var y := float(_loader.call("ground_height_at", wx, wz))
			h[j * n + i] = y
			lo = minf(lo, y)
			hi = maxf(hi, y)
	if not is_finite(lo) or (hi - lo) < 0.5:
		return
	_contour_interval_m = _contour_interval_for(hi - lo)
	var ci := _contour_interval_m
	var level := ceilf(lo / ci) * ci
	var guard := 0
	while level < hi and guard < 400:
		guard += 1
		_march_contour_level(h, n, center, half, step, level)
		level += ci


func _contour_interval_for(range_m: float) -> float:
	if range_m < 8.0:
		return 0.5
	if range_m < 25.0:
		return 1.0
	if range_m < 80.0:
		return 2.0
	if range_m < 200.0:
		return 5.0
	return 10.0


func _march_contour_level(h: PackedFloat32Array, n: int, center: Vector2,
		half: float, step: float, level: float) -> void:
	for j in n - 1:
		for i in n - 1:
			var h00 := h[j * n + i]
			var h10 := h[j * n + i + 1]
			var h01 := h[(j + 1) * n + i]
			var h11 := h[(j + 1) * n + i + 1]
			var mask := 0
			if h00 > level: mask |= 1
			if h10 > level: mask |= 2
			if h11 > level: mask |= 4
			if h01 > level: mask |= 8
			if mask == 0 or mask == 15:
				continue
			var ox := center.x - half + float(i) * step
			var oz := center.y - half + float(j) * step
			# Edge crossing points (bottom, right, top, left of the cell).
			var pb := Vector2(ox + step * _frac(h00, h10, level), oz)
			var pr := Vector2(ox + step, oz + step * _frac(h10, h11, level))
			var pt := Vector2(ox + step * _frac(h01, h11, level), oz + step)
			var pl := Vector2(ox, oz + step * _frac(h00, h01, level))
			match mask:
				1, 14: _contour_segs.append([pl, pb, level])
				2, 13: _contour_segs.append([pb, pr, level])
				3, 12: _contour_segs.append([pl, pr, level])
				4, 11: _contour_segs.append([pr, pt, level])
				6, 9: _contour_segs.append([pb, pt, level])
				7, 8: _contour_segs.append([pl, pt, level])
				5:
					_contour_segs.append([pl, pt, level])
					_contour_segs.append([pb, pr, level])
				10:
					_contour_segs.append([pl, pb, level])
					_contour_segs.append([pr, pt, level])


func _frac(a: float, b: float, level: float) -> float:
	var d := b - a
	if absf(d) < 1e-6:
		return 0.5
	return clampf((level - a) / d, 0.0, 1.0)


func _project_poly(poly: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	var cam := get_viewport().get_camera_3d()
	if cam == null or _loader == null:
		return out
	for p in poly:
		var y := float(_loader.call("ground_height_at", p.x, p.y))
		var wp := Vector3(p.x, y + 0.3, p.y)
		if cam.is_position_behind(wp):
			continue
		out.append(cam.unproject_position(wp))
	return out


func _tool_color() -> Color:
	match _tool:
		Tool.BRUSH_RAISE: return Color(0.4, 0.9, 0.5, 0.9)
		Tool.BRUSH_LOWER: return Color(0.95, 0.6, 0.3, 0.9)
		Tool.SMOOTH: return Color(0.6, 0.8, 0.95, 0.9)
		Tool.FLATTEN: return Color(0.85, 0.85, 0.4, 0.9)
		Tool.RAIN: return Color(0.35, 0.75, 1.0, 0.9)
		Tool.DRAIN: return Color(0.55, 0.7, 0.85, 0.9)
		Tool.POND: return Color(0.3, 0.55, 0.95, 0.9)
		_: return Color(0.35, 0.65, 1.0, 0.9)


# ---------------------------------------------------------------------------
# Tool / shape handlers
# ---------------------------------------------------------------------------

func _on_tool_pressed(t: Tool) -> void:
	var prev := _tool
	_tool = t
	_gesture_has_a = false
	# Keep selection when switching among Pond / Rain / Drain.
	var keep_sel := _selection_locked and _is_water_tool(prev) and _is_water_tool(t)
	if not keep_sel:
		_clear_locked_selection()
	else:
		_end_water_modulate()
	for i in _tool_buttons.size():
		_style_tool_button(_tool_buttons[i], _tool_button_tools[i] == t)
	# Each tool picks its natural shape: brushes paint freehand, Pond lassos an
	# outline, Level drags a rectangle. Other shapes stay selectable below.
	match t:
		Tool.BRUSH_RAISE, Tool.BRUSH_LOWER, Tool.SMOOTH:
			_on_shape_pressed(ShapeMode.BRUSH)
			_set_status("Hold LMB and paint the ground · Size / Strength / Hardness below")
		Tool.POND:
			if not keep_sel:
				_on_shape_pressed(ShapeMode.LASSO)
			_set_status("Pond: lasso outline — releasing digs %.1f m (use Rain to fill)" % _pond_depth)
		Tool.RAIN, Tool.DRAIN:
			if _shape_mode == ShapeMode.BRUSH:
				_on_shape_pressed(ShapeMode.CIRCLE)
			if keep_sel:
				_refresh_basin_preview()
				_set_status("Hold LMB over the selection to %s" % (
					"raise water" if t == Tool.RAIN else "drain water"))
			else:
				_set_status("Draw over a depression, then hold %s" % (
					"Rain" if t == Tool.RAIN else "Drain"))
		Tool.FLATTEN:
			_on_shape_pressed(ShapeMode.RECT)
			_set_status("Level: drag a rectangle over the site — releasing grades it flat")
		Tool.RAMP:
			_set_status("Ramp: click the start point, then the end point (width = Size)")
		Tool.MEASURE:
			_set_status("Measure: click two points for distance / Δelevation / grade")
	_update_param_rows()
	_update_crosshair_prompt()


func _on_shape_pressed(m: ShapeMode) -> void:
	_shape_mode = m
	_shaping = false
	_poly_points = PackedVector2Array()
	_lasso_pts = PackedVector2Array()
	_lasso_screen = PackedVector2Array()
	_shape_poly = PackedVector2Array()
	for i in _shape_buttons.size():
		_style_tool_button(_shape_buttons[i], _shape_button_modes[i] == m)
	_update_param_rows()
	_update_crosshair_prompt()


func _update_param_rows() -> void:
	var brushish := _shape_mode == ShapeMode.BRUSH or _tool == Tool.BRUSH_RAISE \
			or _tool == Tool.BRUSH_LOWER or _tool == Tool.SMOOTH
	if _brush_row != null:
		_brush_row.visible = brushish or _tool == Tool.FLATTEN or _tool == Tool.RAMP
	if _pond_row != null:
		_pond_row.visible = _tool == Tool.POND
	if _rain_row != null:
		_rain_row.visible = _tool == Tool.RAIN or _tool == Tool.DRAIN \
				or (_selection_locked and _is_water_tool())


func _cancel_shape_or_exit() -> bool:
	if _gesture_has_a:
		_gesture_has_a = false
		_set_status("Cancelled")
		return true
	if _shape_mode == ShapeMode.POLYGON and _poly_points.size() > 0:
		_poly_points = PackedVector2Array()
		_set_status("Polygon cleared")
		return true
	if _shaping:
		_shaping = false
		_shape_poly = PackedVector2Array()
		_lasso_pts = PackedVector2Array()
		_lasso_screen = PackedVector2Array()
		return true
	if _selection_locked:
		_clear_locked_selection()
		_set_status("Selection cleared")
		return true
	_exit_mode()
	return true


func _do_undo() -> void:
	if _loader == null or not _loader.has_method("undo_terrain_sculpt"):
		return
	if bool(_loader.call("undo_terrain_sculpt")):
		_set_status("Undid last sculpt")
		_invalidate_contours()
	else:
		_set_status("Nothing to undo")
	_update_undo_button()


func _update_undo_button() -> void:
	if _undo_btn == null or _loader == null:
		return
	var can := _loader.has_method("can_undo_terrain_sculpt") and bool(_loader.call("can_undo_terrain_sculpt"))
	_undo_btn.disabled = not can


# ---------------------------------------------------------------------------
# Picking
# ---------------------------------------------------------------------------

func _pick_pointer() -> Variant:
	if _loader == null or not _loader.has_method("terrain_pick_ray"):
		return null
	var vp := get_viewport()
	if vp == null:
		return null
	var pos := vp.get_mouse_position()
	if Input.get_mouse_mode() != Input.MOUSE_MODE_VISIBLE:
		pos = vp.get_visible_rect().size * 0.5
	return _loader.call("terrain_pick_ray", pos)


func _is_pointer_over_panel() -> bool:
	if _panel == null or not _panel.visible:
		return false
	return _panel.get_global_rect().has_point(get_viewport().get_mouse_position())


func _poly_centroid(poly: PackedVector2Array) -> Vector2:
	var c := Vector2.ZERO
	for p in poly:
		c += p
	return c / float(maxi(poly.size(), 1))


func _set_status(msg: String) -> void:
	if _status != null:
		_status.text = msg


# ---------------------------------------------------------------------------
# Crosshair
# ---------------------------------------------------------------------------

func _crosshair_ui() -> Node:
	var parent := get_parent()
	return parent.get_node_or_null("CrosshairUI") if parent != null else null


func _update_crosshair_prompt() -> void:
	var cross := _crosshair_ui()
	if cross == null or not cross.has_method("set_prompt_text"):
		return
	if _tool == Tool.RAMP:
		cross.call("set_prompt_text", "Click start, then end, to grade a ramp")
	elif _tool == Tool.MEASURE:
		cross.call("set_prompt_text", "Click two points to measure distance + grade")
	elif _selection_locked and (_tool == Tool.RAIN or _tool == Tool.DRAIN):
		cross.call("set_prompt_text", "Hold LMB to %s · Esc clears" % (
			"raise water" if _tool == Tool.RAIN else "drain"))
	elif _selection_locked:
		cross.call("set_prompt_text", "Selection locked — switch to Rain/Drain · Esc clears")
	elif _tool == Tool.RAIN:
		cross.call("set_prompt_text", "Draw area over a depression, then hold Rain")
	elif _tool == Tool.DRAIN:
		cross.call("set_prompt_text", "Draw over a user pond, then hold Drain")
	elif _tool == Tool.POND:
		cross.call("set_prompt_text", "Lasso the pond outline — release digs (Rain fills)")
	elif _tool == Tool.FLATTEN:
		cross.call("set_prompt_text", "Drag a rectangle — release levels the pad")
	elif _shape_mode == ShapeMode.BRUSH:
		cross.call("set_prompt_text", "Hold LMB to sculpt")
	else:
		cross.call("set_prompt_text", "Drag to select an area")


func _clear_crosshair_prompt() -> void:
	var cross := _crosshair_ui()
	if cross != null and cross.has_method("set_prompt_text"):
		cross.call("set_prompt_text", "")
	if cross != null and cross.has_method("set_target_active"):
		cross.call("set_target_active", false)


# ---------------------------------------------------------------------------
# Top-down
# ---------------------------------------------------------------------------

func _toggle_topdown() -> void:
	_set_topdown(not _topdown)


func _set_topdown(on: bool) -> void:
	_topdown = on
	if _topdown_btn != null:
		_style_tool_button(_topdown_btn, on)
	_lock_drone_ortho(on)
	_invalidate_contours()
	if on:
		_set_status("Top-down survey — WASD pans · Arrow keys raise/lower · Space toggles look/time")


func _lock_drone_ortho(on: bool) -> void:
	var main: Node = _loader.get_parent() if _loader != null else null
	if main == null:
		return
	var player := main.get_node_or_null("Player") as CharacterBody3D
	var drone := main.get_node_or_null("FPVDrone")
	if player == null or drone == null:
		_topdown = false
		if _topdown_btn != null:
			_style_tool_button(_topdown_btn, false)
		_set_status("Top-down needs the survey drone")
		return
	if on:
		if player.has_method("_release_mouse"):
			player.call("_release_mouse")
		_we_mounted_drone = false
		if not drone.is_mounted and player.has_method("_mount_vehicle"):
			player.call("_mount_vehicle", drone)
			_we_mounted_drone = true
		_locked_yaw = drone.rotation.y
		if _loader.has_method("set_sculpt_locked_yaw"):
			_loader.call("set_sculpt_locked_yaw", _locked_yaw)
		drone.set_meta("terrain_edit_ortho", true)
		drone.set_meta("terrain_edit_pitch_deg", _pitch_deg)
		drone.current_pitch = deg_to_rad(_pitch_deg)
		drone.current_yaw = _locked_yaw
		var cam := _find_drone_camera(drone)
		if cam != null:
			_saved_camera_projection = cam.projection
			_saved_camera_size = cam.size
			cam.projection = Camera3D.PROJECTION_ORTHOGONAL
			cam.size = maxf(_radius_m * 8.0, 200.0)
	else:
		drone.set_meta("terrain_edit_ortho", false)
		if drone.has_meta("terrain_edit_pitch_deg"):
			drone.remove_meta("terrain_edit_pitch_deg")
		var cam2 := _find_drone_camera(drone)
		if cam2 != null:
			cam2.projection = _saved_camera_projection
			cam2.size = _saved_camera_size
		if _we_mounted_drone and drone.is_mounted and player.has_method("_dismount_vehicle"):
			player.call("_dismount_vehicle")
		_we_mounted_drone = false


func _find_drone_camera(drone: Node) -> Camera3D:
	for child in drone.get_children():
		if child is Camera3D:
			return child as Camera3D
		for sub in child.get_children():
			if sub is Camera3D:
				return sub as Camera3D
	return null
