extends Control

## Vegetation paint toolbar — click/drag area selection + compact dock over timeline.
##
## Appearance (shape / shader / tints / density) is owned entirely by the
## "Tune look…" modal (vegetation_preview_editor.gd). This dock only handles
## WHERE and WHICH species to paint. The modal can push its look either to the
## whole map ("Apply to map") or to this dock's paint brush ("Apply to brush"),
## in which case newly-painted trees carry that look as a per-instance override.

signal vegetation_applied
signal mode_changed(active: bool)

enum Tool { PAINT, PLACE, CLEAR, SELECT }
enum ShapeMode { CIRCLE, RECT, LASSO, POLYGON }

const MODAL_NAME := "vegetation_edit"
const SliderSpinRowScript := preload("res://scenes/ui/slider_spin_row.gd")
const PANEL_HEIGHT := 132.0
const HIGHLIGHT_DEBOUNCE_S := 0.016
const RESPECIES_DEBOUNCE_S := 0.35
const MAX_SELECTION_RADIUS_M := 75.0
const MAX_SELECTION_AREA_M2 := 17500.0
## A LMB press+release that moves less than this (screen px) in Paint mode is a
## "click, not a drag" → drop a single instance instead of scattering a circle.
const SINGLE_CLICK_PX := 6.0
const HIGHLIGHT_CLEAR := Color(0.95, 0.25, 0.2, 0.42)
const HIGHLIGHT_PAINT := Color(0.2, 0.9, 0.4, 0.42)
const HIGHLIGHT_SELECT := Color(0.35, 0.75, 0.95, 0.42)

var _loader: Node = null
var _active := false
var _tool := Tool.PAINT
var _preset := VegetationPaint.Preset.SHRUB
var _spacing_m := 4.0
var _density := 1.0
var _scale_min := 1.0
var _scale_max := 1.8
var _seed_value := 1337
var _brush_min_m := 2.0
var _mix_pine := 0.3
var _mix_deciduous := 0.3
var _mix_shrub := 0.2
var _mix_grass_lawn := 0.1
var _mix_grass_field := 0.1
var _hero_preset := "pine_1"
var _hero_scale := 1.0
## Per-brush look snapshot from the modal's "Apply to brush" (empty = paint with
## the global map style). Stamped onto every instance painted while active.
var _brush_card: Dictionary = {}
var _brushing := false
var _brush_anchor := Vector2.ZERO
var _brush_poly := PackedVector2Array()
var _lasso_pts := PackedVector2Array()
var _lasso_screen_pts := PackedVector2Array()
var _last_lasso_sample := Vector2.ZERO
var _shape_mode := ShapeMode.CIRCLE
var _shape_mode_buttons: Array[Button] = []
var _poly_points := PackedVector2Array()
var _selection_locked := false
var _selection_poly := PackedVector2Array()

var _capture: ColorRect = null
var _poly_draw: Control = null
var _undo_btn: Button = null
var _panel: PanelContainer = null
var _status: Label = null
var _hero_section: HBoxContainer = null
var _tool_buttons: Array[Button] = []
var _preset_buttons: Array[Button] = []
var _progress_bar: ProgressBar = null
var _busy := false
var _highlight_pending := false
var _highlight_timer := 0.0
var _respecies_pending := false
var _respecies_timer := 0.0
var _place_click_armed := false
var _paint_press_pos := Vector2.ZERO
var _paint_click_candidate := false


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiScreenLayout.pin_fullscreen(self)
	set_process(false)
	_build_ui()


func bind_loader(loader: Node) -> void:
	_loader = loader
	if _loader != null and _loader.has_signal("vegetation_operation_progress"):
		var cb := Callable(self, "_on_veg_operation_progress")
		if not _loader.is_connected("vegetation_operation_progress", cb):
			_loader.connect("vegetation_operation_progress", cb)


func toggle_mode() -> void:
	if _active:
		_exit_mode()
	else:
		_enter_mode()


func get_paint_density() -> float:
	return _density


func set_paint_density(value: float) -> void:
	# Range matches the Tune look… density slider + auto_density_scale (0.25–3.0)
	# so a modal density isn't silently capped when pushed to the brush.
	_density = clampf(value, 0.25, 3.0)
	_spacing_m = _effective_spacing()


## Called by the "Tune look…" modal's "Apply to brush": subsequently-painted
## vegetation carries this look snapshot (empty dict clears it → paint uses the
## global map style, same as "Apply to map").
func set_brush_style(card: Dictionary) -> void:
	_brush_card = card.duplicate(true) if card != null else {}
	if _brush_card.is_empty():
		_set_status("Brush look cleared — painting uses the map style")
	else:
		_set_status("Custom brush look set — paint to place trees with this look")


func has_brush_style() -> bool:
	return not _brush_card.is_empty()


func _open_preview_editor() -> void:
	if _loader == null or not _loader.has_method("open_vegetation_preview_editor"):
		return
	_loader.call("open_vegetation_preview_editor", int(_preset))


func _process(delta: float) -> void:
	if not _active:
		return
	if _brushing:
		_update_brush_from_crosshair(true)
	elif _shape_mode == ShapeMode.POLYGON and _poly_points.size() > 0:
		_update_polygon_preview(true)
	elif _shape_mode == ShapeMode.LASSO and _brushing:
		_update_lasso_preview(true)
	if _highlight_pending:
		_highlight_timer += delta
		if _highlight_timer >= HIGHLIGHT_DEBOUNCE_S:
			_highlight_pending = false
			_highlight_timer = 0.0
			_do_refresh_highlight(true)
	if _respecies_pending:
		_respecies_timer += delta
		if _respecies_timer >= RESPECIES_DEBOUNCE_S:
			_respecies_pending = false
			_start_respecies()
	_update_crosshair_aim()
	_update_process_enabled()


func _unhandled_input(event: InputEvent) -> void:
	if not _active or _busy:
		return
	if event is InputEventKey and (event as InputEventKey).pressed:
		var key := event as InputEventKey
		if key.keycode == KEY_ESCAPE:
			if _clear_selection_or_exit():
				get_viewport().set_input_as_handled()
			return
		if key.keycode == KEY_Z and key.ctrl_pressed:
			_do_undo()
			get_viewport().set_input_as_handled()
			return
		if key.keycode == KEY_ENTER or key.keycode == KEY_KP_ENTER:
			if _shape_mode == ShapeMode.POLYGON and _poly_points.size() >= 3:
				_finish_polygon(_poly_points)
				get_viewport().set_input_as_handled()
			return


func _on_capture_input(event: InputEvent) -> void:
	if not _active or _busy:
		return
	if _is_pointer_over_panel():
		return
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _brushing and _shape_mode == ShapeMode.LASSO:
			if mm.position.distance_to(_last_lasso_sample) >= 8.0:
				_append_lasso_point(mm.position)
				_last_lasso_sample = mm.position
				_update_lasso_preview(true)
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
				_finish_polygon(_poly_points)
				get_viewport().set_input_as_handled()
			elif _clear_selection_or_exit():
				get_viewport().set_input_as_handled()


# ---------------------------------------------------------------------------
# Style helpers
# ---------------------------------------------------------------------------

func _panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.1, 0.14, 0.96)
	sb.set_corner_radius_all(8)
	sb.set_border_width_all(2)
	sb.border_color = Color(0.2, 0.4, 0.6, 0.85)
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
		sb.bg_color = Color(0.15, 0.35, 0.22, 1.0)
		sb.border_color = Color(0.3, 0.85, 0.45, 0.9)
	else:
		sb.bg_color = Color(0.1, 0.13, 0.18, 1.0)
		sb.border_color = Color(0.22, 0.32, 0.45, 0.6)
	return sb


func _style_section(lbl: Label, text: String) -> void:
	lbl.text = text
	lbl.add_theme_color_override("font_color", Color(0.5, 0.65, 0.8, 1.0))
	lbl.add_theme_font_size_override("font_size", 11)


func _style_muted(lbl: Label) -> void:
	lbl.add_theme_color_override("font_color", Color(0.65, 0.72, 0.78, 1.0))
	lbl.add_theme_font_size_override("font_size", 11)


func _style_tool_button(btn: Button, on: bool) -> void:
	btn.toggle_mode = true
	btn.button_pressed = on
	btn.add_theme_stylebox_override("normal", _toggle_btn_style(on))
	btn.add_theme_stylebox_override("pressed", _toggle_btn_style(true))
	btn.add_theme_stylebox_override("hover", _toggle_btn_style(on))
	btn.add_theme_color_override("font_color", Color(0.85, 0.92, 0.95) if on else Color(0.6, 0.68, 0.75))
	btn.add_theme_font_size_override("font_size", 12)


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

	_poly_draw = Control.new()
	_poly_draw.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_poly_draw.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_poly_draw.draw.connect(_draw_selection_overlay)
	add_child(_poly_draw)

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

	var tool_row := HBoxContainer.new()
	tool_row.add_theme_constant_override("separation", 6)
	col.add_child(tool_row)
	_tool_buttons.clear()
	for i in ["Paint", "Place", "Clear", "Select"]:
		var b := Button.new()
		b.text = i
		b.custom_minimum_size = Vector2(64, 28)
		b.pressed.connect(_on_tool_pressed.bind(_tool_buttons.size()))
		_style_tool_button(b, _tool_buttons.size() == int(_tool))
		tool_row.add_child(b)
		_tool_buttons.append(b)
	_undo_btn = Button.new()
	_undo_btn.text = "Undo"
	_undo_btn.custom_minimum_size = Vector2(52, 28)
	_undo_btn.add_theme_stylebox_override("normal", _secondary_btn_style())
	_undo_btn.pressed.connect(_do_undo)
	tool_row.add_child(_undo_btn)
	var tune_btn := Button.new()
	tune_btn.text = "Tune look…"
	tune_btn.custom_minimum_size = Vector2(92, 28)
	tune_btn.add_theme_stylebox_override("normal", _secondary_btn_style())
	tune_btn.pressed.connect(_open_preview_editor)
	tool_row.add_child(tune_btn)
	var exit_btn := Button.new()
	exit_btn.text = "Exit"
	exit_btn.custom_minimum_size = Vector2(52, 28)
	exit_btn.add_theme_stylebox_override("normal", _secondary_btn_style())
	exit_btn.pressed.connect(_exit_mode)
	tool_row.add_child(exit_btn)
	_status = Label.new()
	_style_muted(_status)
	_status.text = "V — click terrain, drag to select · Ctrl+Z undo · Tune look… to style"
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.autowrap_mode = TextServer.AUTOWRAP_OFF
	tool_row.add_child(_status)

	var param_row := HBoxContainer.new()
	param_row.add_theme_constant_override("separation", 6)
	col.add_child(param_row)
	var type_lbl := Label.new()
	_style_section(type_lbl, "Type")
	type_lbl.custom_minimum_size = Vector2(34, 0)
	param_row.add_child(type_lbl)
	for i in 6:
		var names := ["Pine", "Decid", "Shrub", "Mix", "Lawn", "Field"]
		var b := Button.new()
		b.text = names[i]
		b.custom_minimum_size = Vector2(46, 24)
		b.pressed.connect(_on_preset_pressed.bind(i))
		_style_tool_button(b, i == int(_preset))
		param_row.add_child(b)
		_preset_buttons.append(b)
	_labeled_slider_row(param_row, "Seed", 1.0, 9999.0, float(_seed_value),
		func(v: float) -> void: _seed_value = int(v), 72, 1.0)

	var shape_row := HBoxContainer.new()
	shape_row.add_theme_constant_override("separation", 4)
	col.add_child(shape_row)
	var shape_lbl := Label.new()
	_style_section(shape_lbl, "Shape")
	shape_lbl.custom_minimum_size = Vector2(40, 0)
	shape_row.add_child(shape_lbl)
	_shape_mode_buttons.clear()
	for spec in [["Circle", ShapeMode.CIRCLE], ["Rect", ShapeMode.RECT],
			["Lasso", ShapeMode.LASSO], ["Polygon", ShapeMode.POLYGON]]:
		var sb := Button.new()
		sb.text = spec[0]
		sb.custom_minimum_size = Vector2(58, 24)
		var mode: ShapeMode = spec[1]
		sb.pressed.connect(_on_shape_mode_pressed.bind(mode))
		_style_tool_button(sb, mode == _shape_mode)
		shape_row.add_child(sb)
		_shape_mode_buttons.append(sb)

	_progress_bar = ProgressBar.new()
	_progress_bar.visible = false
	_progress_bar.custom_minimum_size = Vector2(120, 14)
	_progress_bar.max_value = 1.0
	_progress_bar.show_percentage = false
	col.add_child(_progress_bar)

	_hero_section = HBoxContainer.new()
	_hero_section.visible = false
	col.add_child(_hero_section)
	var hero_lbl := Label.new()
	_style_section(hero_lbl, "Hero")
	_hero_section.add_child(hero_lbl)
	var opt := OptionButton.new()
	opt.custom_minimum_size = Vector2(120, 0)
	for p in HeroTreeCatalog.all_presets():
		opt.add_item(str(p.get("label", p.get("id", ""))))
		opt.set_item_metadata(opt.item_count - 1, str(p.get("id", "")))
	opt.item_selected.connect(func(idx: int) -> void: _hero_preset = str(opt.get_item_metadata(idx)))
	_hero_section.add_child(opt)
	_labeled_slider_row(_hero_section, "Scale", 0.15, 2.5, _hero_scale, func(v: float) -> void: _hero_scale = v, 70)


func _labeled_slider_row(parent: Control, label: String, min_v: float, max_v: float,
		start: float, handler: Callable, slider_min_w: int = 80, step: float = -1.0) -> HBoxContainer:
	var pair := SliderSpinRowScript.add(parent, label, min_v, max_v, start, handler,
		func(lbl: Label, txt: String) -> void: _style_section(lbl, txt),
		36, slider_min_w, 58, step)
	return pair.get("row")


func _layout_panel() -> void:
	if _panel == null:
		return
	UiScreenLayout.pin_over_timeline(_panel, PANEL_HEIGHT)


# ---------------------------------------------------------------------------
# Mode enter / exit
# ---------------------------------------------------------------------------

func _enter_mode() -> void:
	_active = true
	visible = true
	if _capture != null:
		_capture.mouse_filter = Control.MOUSE_FILTER_STOP
	mode_changed.emit(true)
	if _loader != null and _loader.has_method("reground_all_vegetation"):
		_loader.call("reground_all_vegetation")
	_set_tool(Tool.PAINT)
	_on_shape_mode_pressed(ShapeMode.CIRCLE)
	_layout_panel()
	_update_crosshair_prompt()
	set_process(true)
	move_to_front()
	CursorController.request_modal(MODAL_NAME, Callable(self, "_exit_mode"))
	_update_undo_button()


func _exit_mode() -> void:
	if not _active:
		return
	_active = false
	_brushing = false
	_place_click_armed = false
	_paint_click_candidate = false
	_highlight_pending = false
	_poly_points = PackedVector2Array()
	_lasso_pts = PackedVector2Array()
	if _poly_draw != null:
		_poly_draw.queue_redraw()
	set_process(false)
	visible = false
	mode_changed.emit(false)
	_clear_locked_selection()
	_clear_crosshair_prompt()
	_set_busy(false)
	if _capture != null:
		_capture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	CursorController.release_modal(MODAL_NAME)


func _clear_selection_or_exit() -> bool:
	if _shape_mode == ShapeMode.POLYGON and _poly_points.size() > 0:
		_poly_points = PackedVector2Array()
		_brush_poly = PackedVector2Array()
		_do_refresh_highlight(true)
		if _poly_draw != null:
			_poly_draw.queue_redraw()
		_set_status("Polygon cleared — click terrain to add corners")
		return true
	if _brushing:
		_brushing = false
		_brush_poly = PackedVector2Array()
		_lasso_pts = PackedVector2Array()
		if _loader != null and _loader.has_method("clear_vegetation_highlight"):
			_loader.call("clear_vegetation_highlight")
		if _poly_draw != null:
			_poly_draw.queue_redraw()
		return true
	if _selection_locked:
		_clear_locked_selection()
		return true
	_exit_mode()
	return true


func _clear_locked_selection() -> void:
	_selection_locked = false
	_selection_poly = PackedVector2Array()
	if _loader != null and _loader.has_method("clear_vegetation_highlight"):
		_loader.call("clear_vegetation_highlight")
	if _poly_draw != null:
		_poly_draw.queue_redraw()


# ---------------------------------------------------------------------------
# Crosshair brush input
# ---------------------------------------------------------------------------

func _viewport_center() -> Vector2:
	var vp := get_viewport()
	if vp == null:
		return Vector2.ZERO
	return vp.get_visible_rect().size * 0.5


func _pick_center() -> Variant:
	return _pick_at_screen(_viewport_center())


func _pick_pointer() -> Variant:
	var vp := get_viewport()
	if vp != null and Input.get_mouse_mode() == Input.MOUSE_MODE_VISIBLE:
		return _pick_at_screen(vp.get_mouse_position())
	return _pick_center()


func _pick_brush_cursor() -> Variant:
	return _pick_pointer()


func _pick_at_screen(screen_pos: Vector2) -> Variant:
	if _loader == null or not _loader.has_method("terrain_pick_ray"):
		return null
	return _loader.call("terrain_pick_ray", screen_pos)


func _is_pointer_over_panel() -> bool:
	if _panel == null or not _panel.visible:
		return false
	return _panel.get_global_rect().has_point(get_viewport().get_mouse_position())


func _on_lmb_pressed() -> void:
	if _tool == Tool.PLACE:
		_place_click_armed = true
		_place_hero_at_crosshair()
		return
	var hit: Variant = _pick_pointer()
	if not (hit is Vector3):
		_set_status("Click terrain to set selection center")
		return
	var p: Vector3 = hit
	if _shape_mode == ShapeMode.POLYGON:
		var pt := Vector2(p.x, p.z)
		if _poly_points.size() >= 3 and pt.distance_to(_poly_points[0]) < 3.0:
			_finish_polygon(_poly_points)
			return
		_poly_points.append(pt)
		_update_polygon_preview(true)
		_set_status("Polygon: %d points — Enter/RMB to finish" % _poly_points.size())
		return
	if _shape_mode == ShapeMode.LASSO:
		_brushing = true
		_lasso_pts = PackedVector2Array()
		_lasso_screen_pts = PackedVector2Array()
		_last_lasso_sample = get_viewport().get_mouse_position()
		_append_lasso_point(_last_lasso_sample)
		if _loader != null and _loader.has_method("reset_vegetation_highlight_cache"):
			_loader.call("reset_vegetation_highlight_cache")
		return
	_brushing = true
	_brush_anchor = Vector2(p.x, p.z)
	# Arm single-instance placement: a Paint circle/rect press that releases with
	# almost no drag drops one tree instead of scattering the minimum-radius brush.
	_paint_click_candidate = _tool == Tool.PAINT \
		and (_shape_mode == ShapeMode.CIRCLE or _shape_mode == ShapeMode.RECT)
	_paint_press_pos = get_viewport().get_mouse_position()
	if _loader != null and _loader.has_method("reset_vegetation_highlight_cache"):
		_loader.call("reset_vegetation_highlight_cache")
	_update_brush_from_crosshair(true)


func _on_lmb_released() -> void:
	if _tool == Tool.PLACE:
		_place_click_armed = false
		return
	if not _brushing:
		return
	if _shape_mode == ShapeMode.LASSO:
		_brushing = false
		var poly := _validated_selection_poly(_lasso_pts)
		_lasso_pts = PackedVector2Array()
		_lasso_screen_pts = PackedVector2Array()
		_apply_tool_to_poly(poly)
		if _poly_draw != null:
			_poly_draw.queue_redraw()
		return
	# Single click (no meaningful drag) in Paint mode → drop one instance.
	if _paint_click_candidate:
		_paint_click_candidate = false
		var moved := get_viewport().get_mouse_position().distance_to(_paint_press_pos)
		if moved < SINGLE_CLICK_PX:
			_brushing = false
			_brush_poly = PackedVector2Array()
			_place_single_at_crosshair()
			if _loader != null and _loader.has_method("clear_vegetation_highlight"):
				_loader.call("clear_vegetation_highlight")
			if _poly_draw != null:
				_poly_draw.queue_redraw()
			return
	if _shape_mode != ShapeMode.POLYGON:
		_update_brush_from_crosshair(true)
	_brushing = false
	var poly := _validated_selection_poly(_brush_poly)
	_brush_poly = PackedVector2Array()
	_apply_tool_to_poly(poly)
	if _poly_draw != null:
		_poly_draw.queue_redraw()


func _update_brush_from_crosshair(immediate: bool) -> void:
	var hit: Variant = _pick_brush_cursor()
	if not (hit is Vector3):
		return
	var p: Vector3 = hit
	var cursor := Vector2(p.x, p.z)
	match _shape_mode:
		ShapeMode.CIRCLE:
			var radius := clampf(
				maxf(_brush_min_m, _brush_anchor.distance_to(cursor)),
				_brush_min_m, MAX_SELECTION_RADIUS_M)
			_brush_poly = VegetationPaint.circle_polygon(_brush_anchor, radius)
		ShapeMode.RECT:
			var delta := cursor - _brush_anchor
			if delta.length() > MAX_SELECTION_RADIUS_M:
				cursor = _brush_anchor + delta.normalized() * MAX_SELECTION_RADIUS_M
			_brush_poly = VegetationPaint.rect_to_polygon(_brush_anchor, cursor)
		_:
			return
	_queue_highlight_refresh(immediate)


func _update_polygon_preview(immediate: bool) -> void:
	if _poly_points.size() < 2:
		_brush_poly = _poly_points.duplicate()
	else:
		_brush_poly = _poly_points.duplicate()
		var hit: Variant = _pick_pointer()
		if hit is Vector3:
			var p: Vector3 = hit
			_brush_poly.append(Vector2(p.x, p.z))
	_queue_highlight_refresh(immediate)


func _validated_selection_poly(poly: PackedVector2Array) -> PackedVector2Array:
	if poly.size() < 3:
		return PackedVector2Array()
	var area := VegetationPaint.polygon_area(poly)
	if area > MAX_SELECTION_AREA_M2:
		_set_status("Area too large (max ~%.0f m radius) — shrink selection" % MAX_SELECTION_RADIUS_M)
		return PackedVector2Array()
	return poly


func _effective_spacing() -> float:
	var base := VegetationPaint.default_spacing_for_preset(_preset)
	return maxf(0.35, base / maxf(_density, 0.25))


func _apply_tool_to_poly(poly: PackedVector2Array) -> void:
	var valid := _validated_selection_poly(poly)
	if valid.size() < 3:
		_set_status("Selection too small — widen the area")
		if _loader != null and _loader.has_method("clear_vegetation_highlight"):
			_loader.call("clear_vegetation_highlight")
		return
	match _tool:
		Tool.SELECT:
			_lock_selection(valid)
		Tool.PAINT:
			_apply_paint(valid)
		Tool.CLEAR:
			_apply_clear(valid)
	if _loader != null and _loader.has_method("clear_vegetation_highlight"):
		_loader.call("clear_vegetation_highlight")


func _finish_polygon(poly: PackedVector2Array) -> void:
	_poly_points = PackedVector2Array()
	_apply_tool_to_poly(poly)
	if _poly_draw != null:
		_poly_draw.queue_redraw()


func _append_lasso_point(screen_pos: Vector2) -> void:
	if _loader == null or not _loader.has_method("terrain_pick_ray"):
		return
	var hit: Variant = _loader.call("terrain_pick_ray", screen_pos)
	if hit is Vector3:
		_lasso_pts.append(Vector2((hit as Vector3).x, (hit as Vector3).z))
		_lasso_screen_pts.append(screen_pos)


func _update_lasso_preview(immediate: bool) -> void:
	_brush_poly = _lasso_pts.duplicate()
	_queue_highlight_refresh(immediate)
	if _poly_draw != null:
		_poly_draw.queue_redraw()


func _draw_selection_overlay() -> void:
	if not _active or _poly_draw == null:
		return
	var col := _highlight_color_for_tool()
	col.a = 0.35
	if _brushing and _shape_mode == ShapeMode.LASSO and _lasso_screen_pts.size() >= 2:
		_poly_draw.draw_polyline(_lasso_screen_pts, col, 2.0, true)


func _do_undo() -> void:
	if _loader == null or not _loader.has_method("undo_vegetation"):
		return
	if bool(_loader.call("undo_vegetation")):
		vegetation_applied.emit()
		_set_status("Undid last vegetation edit")
		_update_undo_button()
	else:
		_set_status("Nothing to undo")


func _update_undo_button() -> void:
	if _undo_btn == null or _loader == null:
		return
	var can := _loader.has_method("can_undo_vegetation") and bool(_loader.call("can_undo_vegetation"))
	_undo_btn.disabled = not can


func _push_undo(label: String) -> void:
	if _loader != null and _loader.has_method("push_vegetation_undo"):
		_loader.call("push_vegetation_undo", label)
	_update_undo_button()


func _fill_cap_for_preset() -> int:
	return VegetationPaint.fill_cap_for_preset(_preset)


func _preset_label() -> String:
	match _preset:
		VegetationPaint.Preset.PINE:
			return "pine"
		VegetationPaint.Preset.DECIDUOUS:
			return "deciduous"
		VegetationPaint.Preset.SHRUB:
			return "shrub"
		VegetationPaint.Preset.GRASS_LAWN:
			return "lawn grass"
		VegetationPaint.Preset.GRASS_FIELD:
			return "field grass"
		_:
			return "mixed veg"


func _queue_highlight_refresh(immediate: bool) -> void:
	if immediate:
		_do_refresh_highlight(true)
	else:
		_highlight_pending = true
		_highlight_timer = 0.0
	_update_process_enabled()


func _on_shape_mode_pressed(mode: ShapeMode) -> void:
	_shape_mode = mode
	_poly_points = PackedVector2Array()
	_brush_poly = PackedVector2Array()
	_lasso_pts = PackedVector2Array()
	_lasso_screen_pts = PackedVector2Array()
	_brushing = false
	for i in _shape_mode_buttons.size():
		_style_tool_button(_shape_mode_buttons[i], i == int(mode))
	_update_shape_prompt()
	if _loader != null and _loader.has_method("clear_vegetation_highlight"):
		_loader.call("clear_vegetation_highlight")


func _active_highlight_poly() -> PackedVector2Array:
	if _selection_locked:
		return _selection_poly
	if _shape_mode == ShapeMode.LASSO and _lasso_pts.size() >= 3:
		return _lasso_pts
	return _brush_poly


func _highlight_color_for_tool() -> Color:
	match _tool:
		Tool.CLEAR:
			return HIGHLIGHT_CLEAR
		Tool.SELECT:
			return HIGHLIGHT_SELECT
		_:
			return HIGHLIGHT_PAINT


func _do_refresh_highlight(fast_preview: bool = true) -> void:
	if _loader == null or not _loader.has_method("update_vegetation_highlight"):
		return
	var poly := _active_highlight_poly()
	if poly.size() >= 3:
		_loader.call("update_vegetation_highlight", poly, _highlight_color_for_tool(), fast_preview)
	elif _loader.has_method("clear_vegetation_highlight"):
		_loader.call("clear_vegetation_highlight")


func _apply_paint(poly: PackedVector2Array) -> void:
	if _busy or _loader == null or not _loader.has_method("populate_vegetation"):
		return
	_push_undo("paint")
	_set_busy(true)
	if _progress_bar != null:
		_progress_bar.visible = true
		_progress_bar.value = 0.3
	var params := _scatter_params()
	var n: int = int(_loader.call("populate_vegetation", poly, params))
	vegetation_applied.emit()
	_set_busy(false)
	if _progress_bar != null:
		_progress_bar.visible = false
	if n > 0:
		var suffix := " (custom brush look)" if has_brush_style() else ""
		_set_status("Painted %d %s%s — hold LMB to add more" % [n, _preset_label(), suffix])
	else:
		var area := VegetationPaint.polygon_area(poly)
		_set_status("No vegetation placed (~%.0f m²) — widen area, reduce spacing, or check capacity" % area)


func _apply_clear(poly: PackedVector2Array) -> void:
	if _loader == null:
		return
	_push_undo("clear")
	var area := VegetationPaint.polygon_area(poly)
	if _loader.has_method("clear_vegetation_in_polygon"):
		_loader.call("clear_vegetation_in_polygon", poly)
	var auto_removed := 0
	if _loader.has_method("clear_auto_vegetation_in_polygon"):
		auto_removed = int(_loader.call("clear_auto_vegetation_in_polygon", poly))
	vegetation_applied.emit()
	if auto_removed > 0:
		_set_status("Cleared ~%.0f m² — %d auto + manual bulk removed" % [area, auto_removed])
	else:
		_set_status("Cleared ~%.0f m² — manual bulk removed (heroes kept)" % area)


func _lock_selection(poly: PackedVector2Array) -> void:
	_selection_locked = true
	_selection_poly = poly.duplicate()
	_do_refresh_highlight(true)
	var manual_n := 0
	if _loader != null and _loader.has_method("count_manual_bulk_in_polygon"):
		manual_n = int(_loader.call("count_manual_bulk_in_polygon", poly))
	_set_status("Selected area — change Type to re-scatter %d+ bulk (heroes untouched)" % manual_n)


# ---------------------------------------------------------------------------
# Tool / preset handlers
# ---------------------------------------------------------------------------

func _on_tool_pressed(idx: int) -> void:
	_set_tool(idx as Tool)


func _on_preset_pressed(idx: int) -> void:
	_preset = idx as VegetationPaint.Preset
	for i in _preset_buttons.size():
		_style_tool_button(_preset_buttons[i], i == idx)
	_spacing_m = _effective_spacing()
	match _preset:
		VegetationPaint.Preset.DECIDUOUS:
			_scale_min = maxf(_scale_min, 1.0)
			_scale_max = maxf(_scale_max, 1.6)
		VegetationPaint.Preset.GRASS_LAWN, VegetationPaint.Preset.GRASS_FIELD:
			_scale_min = 0.75
			_scale_max = 1.15
	if _selection_locked:
		_queue_respecies()


func _preset_to_species() -> String:
	match _preset:
		VegetationPaint.Preset.PINE:
			return "pine"
		VegetationPaint.Preset.DECIDUOUS:
			return "deciduous"
		VegetationPaint.Preset.SHRUB:
			return "shrub"
		VegetationPaint.Preset.GRASS_LAWN:
			return "grass_lawn"
		VegetationPaint.Preset.GRASS_FIELD:
			return "grass_field"
		_:
			return ""


func _set_tool(t: Tool) -> void:
	if _tool == Tool.SELECT and t != Tool.SELECT:
		_clear_locked_selection()
	_tool = t
	if _loader != null and _loader.has_method("reset_vegetation_highlight_cache"):
		_loader.call("reset_vegetation_highlight_cache")
	for i in _tool_buttons.size():
		_style_tool_button(_tool_buttons[i], i == int(t))
	if _hero_section != null:
		_hero_section.visible = t == Tool.PLACE
	_update_shape_prompt()


func _update_shape_prompt() -> void:
	match _tool:
		Tool.PAINT:
			match _shape_mode:
				ShapeMode.POLYGON:
					_set_status("Paint — click corners, Enter/RMB to finish, then confirm")
				ShapeMode.LASSO:
					_set_status("Paint — drag to lasso an area, release to apply")
				_:
					_set_status("Paint — click to drop one, or drag to scatter a circle/rect")
		Tool.PLACE:
			_set_status("Place — click terrain to drop hero tree")
		Tool.CLEAR:
			match _shape_mode:
				ShapeMode.POLYGON:
					_set_status("Clear — click corners, Enter/RMB to finish, then confirm")
				_:
					_set_status("Clear — click center, drag to size, release to apply")
		Tool.SELECT:
			match _shape_mode:
				ShapeMode.POLYGON:
					_set_status("Select — use Circle or Rect to lock an area, then change Type")
				_:
					_set_status("Select — click center, drag to size, release to lock; change Type to re-scatter")
	_update_crosshair_prompt()


func _set_status(msg: String) -> void:
	if _status != null:
		_status.text = msg


func _set_busy(on: bool) -> void:
	_busy = on
	if _progress_bar != null and not on:
		_progress_bar.visible = false


func _update_process_enabled() -> void:
	set_process(_active)


# ---------------------------------------------------------------------------
# Crosshair UI
# ---------------------------------------------------------------------------

func _crosshair_ui() -> Node:
	var parent := get_parent()
	if parent == null:
		return null
	return parent.get_node_or_null("CrosshairUI")


func _set_crosshair_prompt(text: String) -> void:
	var cross := _crosshair_ui()
	if cross != null and cross.has_method("set_prompt_text"):
		cross.call("set_prompt_text", text)


func _clear_crosshair_prompt() -> void:
	var cross := _crosshair_ui()
	if cross != null and cross.has_method("set_prompt_text"):
		cross.call("set_prompt_text", "")
	if cross != null and cross.has_method("set_target_active"):
		cross.call("set_target_active", false)


func _update_crosshair_aim() -> void:
	if not _active:
		return
	var cross := _crosshair_ui()
	if cross == null:
		return
	var on_terrain := _pick_pointer() is Vector3
	if cross.has_method("set_target_active"):
		cross.call("set_target_active", on_terrain)


func _update_crosshair_prompt() -> void:
	match _tool:
		Tool.PAINT, Tool.CLEAR:
			match _shape_mode:
				ShapeMode.CIRCLE:
					_set_crosshair_prompt("Drag LMB — circle preview, release to apply")
				ShapeMode.RECT:
					_set_crosshair_prompt("Drag LMB — rectangle preview, release to apply")
				ShapeMode.POLYGON:
					_set_crosshair_prompt("Click LMB — add corners; Enter/RMB to finish")
		Tool.PLACE:
			_set_crosshair_prompt("Click LMB to place hero tree")
		Tool.SELECT:
			match _shape_mode:
				ShapeMode.POLYGON:
					_set_crosshair_prompt("Click corners; Enter/RMB to lock selection")
				_:
					_set_crosshair_prompt("Drag LMB — release to lock selection")


# ---------------------------------------------------------------------------
# Scatter params + selection re-scatter
# ---------------------------------------------------------------------------

func _scatter_params() -> Dictionary:
	var params := {
		"preset": _preset,
		"spacing_m": _effective_spacing(),
		"scale_min": _scale_min,
		"scale_max": _scale_max,
		"seed": _seed_value,
		"mix_pine": _mix_pine,
		"mix_deciduous": _mix_deciduous,
		"mix_shrub": _mix_shrub,
		"mix_grass_lawn": _mix_grass_lawn,
		"mix_grass_field": _mix_grass_field,
	}
	if not _brush_card.is_empty():
		params["card_settings"] = _brush_card
	return params


func _queue_respecies() -> void:
	if not _selection_locked or _busy:
		return
	_respecies_pending = true
	_respecies_timer = 0.0
	_update_process_enabled()


func _start_respecies() -> void:
	if not _selection_locked or _loader == null or _busy:
		return
	_push_undo("respecies")
	if _loader.has_method("respecies_selection_async"):
		_respecies_async()
	else:
		_set_busy(true)
		var n: int = int(_loader.call("respecies_selection", _selection_poly, _scatter_params()))
		vegetation_applied.emit()
		_set_busy(false)
		_set_status("Re-scattered selection — %d instances" % n)


func _respecies_async() -> void:
	_set_busy(true)
	if _progress_bar != null:
		_progress_bar.visible = true
		_progress_bar.value = 0.05
	var n: int = await _loader.call("respecies_selection_async", _selection_poly, _scatter_params())
	vegetation_applied.emit()
	_set_busy(false)
	if _progress_bar != null:
		_progress_bar.visible = false
	_set_status("Re-scattered selection — %d instances" % n)


## Resolve the concrete species for a single-instance drop. Mix picks one weighted
## by the mix sliders; grass presets stay grass.
func _resolve_single_species() -> String:
	var s := _preset_to_species()
	if s != "":
		return s
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed_value ^ int(Time.get_ticks_usec())
	return VegetationPaint.pick_species(_preset, _mix_pine, _mix_deciduous,
		_mix_shrub, rng, _mix_grass_lawn, _mix_grass_field)


func _place_single_at_crosshair() -> void:
	if _loader == null or not _loader.has_method("place_single_vegetation"):
		return
	var hit: Variant = _pick_pointer()
	if not (hit is Vector3):
		_set_status("Click terrain to place one %s" % _preset_label())
		return
	var p: Vector3 = hit
	var species := _resolve_single_species()
	if species.is_empty():
		return
	_push_undo("place one")
	if bool(_loader.call("place_single_vegetation", species, p.x, p.z, _scatter_params())):
		vegetation_applied.emit()
		var suffix := " (custom brush look)" if has_brush_style() else ""
		_set_status("Placed 1 %s%s — click to add more, drag to scatter" % [_preset_label(), suffix])
	else:
		_set_status("Could not place %s (capacity reached?)" % _preset_label())


func _place_hero_at_crosshair() -> void:
	if _loader == null or not _loader.has_method("place_hero_tree"):
		return
	var hit: Variant = _pick_pointer()
	if not (hit is Vector3):
		_set_status("Click terrain to place hero tree")
		return
	var p: Vector3 = hit
	if bool(_loader.call("place_hero_tree", _hero_preset, p.x, p.z, _hero_scale, p.y)):
		vegetation_applied.emit()
		_set_status("Placed hero tree")
	else:
		_set_status("Could not place hero (limit reached?)")
