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
enum ShapeMode { BRUSH, CIRCLE, RECT, LASSO, POLYGON }

const MODAL_NAME := "vegetation_edit"
const SliderSpinRowScript := preload("res://scenes/ui/slider_spin_row.gd")
## Grew with the Phase 8 chip row (the row above the tools that shows what the
## brush will actually do).
const PANEL_HEIGHT := 176.0
const HIGHLIGHT_DEBOUNCE_S := 0.016
const RESPECIES_DEBOUNCE_S := 0.35
const MAX_SELECTION_RADIUS_M := 75.0
const MAX_SELECTION_AREA_M2 := 17500.0
const MAX_BRUSH_RADIUS_M := 40.0
## A LMB press+release that moves less than this (screen px) in Paint mode is a
## "click, not a drag" → drop a single instance instead of scattering a circle.
const SINGLE_CLICK_PX := 6.0
const HIGHLIGHT_CLEAR := Color(0.95, 0.25, 0.2, 0.42)
const HIGHLIGHT_PAINT := Color(0.2, 0.9, 0.4, 0.42)
const HIGHLIGHT_SELECT := Color(0.35, 0.75, 0.95, 0.42)

## Chip swatch per mesh family — the dock's only job is WHERE and WHICH, so the
## species chip is the one piece of state that must always be readable at a
## glance. Values are recognisably "that kind of plant", not the render tint.
const FAMILY_CHIP_COLORS := {
	"pine": Color(0.30, 0.55, 0.38),
	"deciduous": Color(0.42, 0.72, 0.32),
	"shrub": Color(0.55, 0.62, 0.28),
	"palm": Color(0.36, 0.68, 0.52),
	"cactus": Color(0.48, 0.62, 0.40),
	"grass_lawn": Color(0.52, 0.80, 0.44),
	"grass_field": Color(0.72, 0.72, 0.36),
}

var _loader: Node = null
var _active := false
var _tool := Tool.PAINT
var _preset := VegetationPaint.Preset.SHRUB
var _paint_species := "shrub"
var _spacing_m := 4.0
var _density := 1.0
var _size_var := 0.25
## Overhaul v2: painted plants appear MATURE (exactly as previewed) unless the
## player opts into watching seedlings grow.
var _plant_young := false
var _scale_min := 0.75
var _scale_max := 1.25
var _seed_value := 1337
var _brush_radius_m := 4.0
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
var _stroking := false
var _brush_undo_pushed := false
var _last_stamp := Vector2(-1e9, -1e9)
var _brush_anchor := Vector2.ZERO
var _brush_poly := PackedVector2Array()
var _lasso_pts := PackedVector2Array()
var _lasso_screen_pts := PackedVector2Array()
var _last_lasso_sample := Vector2.ZERO
var _shape_mode := ShapeMode.BRUSH
var _shape_mode_buttons: Array[Button] = []
var _poly_points := PackedVector2Array()
var _selection_locked := false
var _selection_poly := PackedVector2Array()

var _capture: ColorRect = null
var _poly_draw: Control = null
var _chip_row: HBoxContainer = null
var _topdown_btn: Button = null
## The dock's own slider rows, kept so a value pushed from ELSEWHERE (the
## Tune-look modal's "Apply to brush"/"Apply to map" both push density and size
## variance) moves the widget too. Without this the chip row and the slider
## disagreed, and the next drag snapped the value back.
var _density_row: Dictionary = {}
var _size_var_row: Dictionary = {}
## Ortho top-down paint (Phase 8). The drone has read a
## `vegetation_edit_ortho` meta since the feature was written; nothing ever set
## it, so the veg dock's top-down mode was dead code while terrain sculpt had
## the equivalent button. Mirrors terrain_edit_ui._lock_drone_ortho.
var _topdown := false
var _we_mounted_drone := false
var _saved_camera_projection := Camera3D.PROJECTION_PERSPECTIVE
var _saved_camera_size := 70.0
var _undo_btn: Button = null
var _panel: PanelContainer = null
var _status: Label = null
var _hero_section: HBoxContainer = null
var _subspecies_opt: OptionButton = null
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


## Drives the tool-row progress bar from the loader's async re-scatter
## (respecies / regen). bind_loader connected this by name since the feature
## shipped, but the method itself was never written — a connect error at bind
## time and a progress bar that only ever flashed on synchronous paints.
func _on_veg_operation_progress(message: String, fraction: float) -> void:
	if _progress_bar != null:
		_progress_bar.visible = fraction < 1.0
		_progress_bar.value = clampf(fraction, 0.0, 1.0)
	if _status != null and message != "":
		_status.text = message


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
	SliderSpinRowScript.set_values(_density_row, _density)
	_refresh_chips()


func get_paint_species() -> String:
	return _paint_species


func set_paint_species(species: String) -> void:
	if species.is_empty() or not VegSpeciesCatalog.is_paintable(species):
		return
	_paint_species = species
	var fam := VegSpeciesCatalog.mesh_family(species)
	match fam:
		"pine":
			_preset = VegetationPaint.Preset.PINE
		"deciduous":
			_preset = VegetationPaint.Preset.DECIDUOUS
		"shrub":
			_preset = VegetationPaint.Preset.SHRUB
		"grass_lawn":
			_preset = VegetationPaint.Preset.GRASS_LAWN
		"grass_field":
			_preset = VegetationPaint.Preset.GRASS_FIELD
	for i in _preset_buttons.size():
		_style_tool_button(_preset_buttons[i], i == int(_preset))
	_refresh_subspecies_dropdown()
	_refresh_chips()


func get_size_var() -> float:
	return _size_var


func set_size_var(value: float) -> void:
	_size_var = clampf(value, 0.0, 0.5)
	_apply_size_var_scales()
	SliderSpinRowScript.set_values(_size_var_row, _size_var * 100.0)
	_refresh_chips()


func _apply_size_var_scales() -> void:
	var scales := VegetationStyleConfig.scales_from_size_var(_size_var)
	_scale_min = scales.x
	_scale_max = scales.y


## Called by the "Tune look…" modal's "Apply to brush": subsequently-painted
## vegetation carries this look snapshot (empty dict clears it → paint uses the
## global map style, same as "Apply to map").
func set_brush_style(card: Dictionary) -> void:
	_brush_card = card.duplicate(true) if card != null else {}
	if _brush_card.is_empty():
		_set_status("Brush look cleared — painting uses the map style")
	else:
		_set_status("Custom brush look set — paint to place trees with this look")
	_refresh_chips()


func has_brush_style() -> bool:
	return not _brush_card.is_empty()


func _open_preview_editor() -> void:
	if _loader == null or not _loader.has_method("open_vegetation_preview_editor"):
		return
	_loader.call("open_vegetation_preview_editor", int(_preset))


func _process(delta: float) -> void:
	if not _active:
		return
	if _stroking:
		_brush_stroke_tick()
	elif _brushing:
		_update_brush_from_crosshair(true)
	elif _shape_mode == ShapeMode.POLYGON and _poly_points.size() > 0:
		_update_polygon_preview(true)
	elif _shape_mode == ShapeMode.LASSO and _brushing:
		_update_lasso_preview(true)
	elif _shape_mode == ShapeMode.BRUSH and (_tool == Tool.PAINT or _tool == Tool.CLEAR):
		_update_brush_ring_preview()
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
		# Per-tree Select actions. Guarded on a live pick so Delete never
		# silently removes something the player can't see they had selected.
		if not _picked_plant.is_empty():
			if key.keycode == KEY_DELETE or key.keycode == KEY_BACKSPACE:
				_delete_picked_plant()
				get_viewport().set_input_as_handled()
				return
			if key.keycode == KEY_BRACKETLEFT:
				_resize_picked_plant(0.85)
				get_viewport().set_input_as_handled()
				return
			if key.keycode == KEY_BRACKETRIGHT:
				_resize_picked_plant(1.18)
				get_viewport().set_input_as_handled()
				return
			if key.keycode == KEY_H:
				_convert_picked_to_hero()
				get_viewport().set_input_as_handled()
				return


func _on_capture_input(event: InputEvent) -> void:
	if not _active or _busy:
		return
	if _is_pointer_over_panel():
		return
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _stroking:
			_brush_stroke_tick()
			get_viewport().set_input_as_handled()
			return
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
	var sb := UITheme.panel_style(0.96)
	sb.set_border_width_all(2)
	sb.shadow_color = Color(0, 0, 0, 0.45)
	sb.shadow_size = 6
	return sb


func _secondary_btn_style() -> StyleBoxFlat:
	return UITheme.button_style("normal")


## Toggle (tool / preset / shape) button faces. The OFF+hover face is the point:
## every one of these 15 buttons used to render its hover state identically to
## normal, so the dock gave no feedback at all about what was clickable.
func _toggle_btn_style(on: bool, hover: bool = false) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(UITheme.CORNER_RADIUS)
	sb.set_border_width_all(1)
	if on:
		sb.bg_color = Color(UITheme.C_PRIMARY, 0.30 if hover else 0.22)
		sb.border_color = UITheme.C_PRIMARY
	elif hover:
		sb.bg_color = UITheme.C_PANEL_RAISED
		sb.border_color = Color(UITheme.C_PRIMARY, 0.75)
	else:
		sb.bg_color = UITheme.C_PANEL
		sb.border_color = UITheme.C_BORDER
	return sb


func _style_section(lbl: Label, text: String) -> void:
	lbl.text = text
	lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)


func _style_muted(lbl: Label) -> void:
	lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)


func _style_tool_button(btn: Button, on: bool) -> void:
	btn.toggle_mode = true
	btn.button_pressed = on
	btn.add_theme_stylebox_override("normal", _toggle_btn_style(on))
	btn.add_theme_stylebox_override("pressed", _toggle_btn_style(true, true))
	btn.add_theme_stylebox_override("hover", _toggle_btn_style(on, true))
	btn.add_theme_stylebox_override("hover_pressed", _toggle_btn_style(true, true))
	btn.add_theme_color_override("font_color", UITheme.C_TEXT if on else UITheme.C_TEXT_S)
	btn.add_theme_color_override("font_hover_color", UITheme.C_TEXT)
	btn.add_theme_font_size_override("font_size", UITheme.FONT_SM)


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

	# Persistent state chips. Everything the brush will actually DO lives here —
	# before this, active species/density/radius/brush-override were only ever
	# implied by which buttons looked pressed, or buried in a status line that
	# clipped (AUTOWRAP_OFF in an expanding row) and was overwritten by the next
	# transient message.
	_chip_row = HBoxContainer.new()
	_chip_row.add_theme_constant_override("separation", UITheme.SPACE_XS)
	col.add_child(_chip_row)

	var tool_row := HBoxContainer.new()
	tool_row.add_theme_constant_override("separation", 6)
	col.add_child(tool_row)
	_tool_buttons.clear()
	var tool_tips := [
		"Scatter plants of the active type (hold LMB, or drag a shape to fill it)",
		"Place ONE hero tree (full 3D model) where you click",
		"Erase painted plants under the brush / inside a dragged shape",
		"Pick a single plant: Del deletes, [ ] resize, H promotes it to a hero model",
	]
	for i in ["Paint", "Place", "Clear", "Select"]:
		var b := Button.new()
		b.text = i
		b.tooltip_text = str(tool_tips[_tool_buttons.size()])
		b.custom_minimum_size = Vector2(64, 28)
		b.pressed.connect(_on_tool_pressed.bind(_tool_buttons.size()))
		_style_tool_button(b, _tool_buttons.size() == int(_tool))
		tool_row.add_child(b)
		_tool_buttons.append(b)
	_undo_btn = Button.new()
	_undo_btn.text = "Undo"
	_undo_btn.tooltip_text = "Undo the last paint / clear / place stroke"
	_undo_btn.custom_minimum_size = Vector2(52, 28)
	_undo_btn.add_theme_stylebox_override("normal", _secondary_btn_style())
	_undo_btn.pressed.connect(_do_undo)
	tool_row.add_child(_undo_btn)
	var tune_btn := Button.new()
	tune_btn.text = "Tune look…"
	tune_btn.tooltip_text = "Open the live studio editor: shape, colours, leaves, presets — then Apply to map or brush"
	tune_btn.custom_minimum_size = Vector2(92, 28)
	tune_btn.add_theme_stylebox_override("normal", _secondary_btn_style())
	tune_btn.pressed.connect(_open_preview_editor)
	tool_row.add_child(tune_btn)
	_topdown_btn = Button.new()
	_topdown_btn.text = "Top-down"
	_topdown_btn.tooltip_text = "Mount the survey drone and paint from a locked orthographic top-down view"
	_topdown_btn.custom_minimum_size = Vector2(80, 28)
	_topdown_btn.pressed.connect(func() -> void: _set_topdown(not _topdown))
	_style_tool_button(_topdown_btn, false)
	tool_row.add_child(_topdown_btn)
	var exit_btn := Button.new()
	exit_btn.text = "Exit"
	exit_btn.custom_minimum_size = Vector2(52, 28)
	exit_btn.add_theme_stylebox_override("normal", _secondary_btn_style())
	exit_btn.pressed.connect(_exit_mode)
	tool_row.add_child(exit_btn)
	_status = Label.new()
	_style_muted(_status)
	_status.text = "Hold LMB to paint · drag shapes to fill areas · Tune look… to style"
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
	var type_tips := [
		"Conifers (pine, spruce, fir…)", "Broadleaf trees (maple, birch, oak…)",
		"Shrubs + desert plants", "Mixed woodland blend (tune ratios in Tune look…)",
		"Short mowed grass", "Tall meadow grass + crops",
	]
	for i in 6:
		var names := ["Pine", "Decid", "Shrub", "Mix", "Lawn", "Field"]
		var b := Button.new()
		b.text = names[i]
		b.tooltip_text = str(type_tips[i])
		b.custom_minimum_size = Vector2(46, 24)
		b.pressed.connect(_on_preset_pressed.bind(i))
		_style_tool_button(b, i == int(_preset))
		param_row.add_child(b)
		_preset_buttons.append(b)
	_subspecies_opt = OptionButton.new()
	_subspecies_opt.custom_minimum_size = Vector2(110, 24)
	_subspecies_opt.tooltip_text = "Subspecies preset for this family"
	_subspecies_opt.item_selected.connect(_on_subspecies_selected)
	param_row.add_child(_subspecies_opt)
	_refresh_subspecies_dropdown()

	var shape_row := HBoxContainer.new()
	shape_row.add_theme_constant_override("separation", 4)
	col.add_child(shape_row)
	var shape_lbl := Label.new()
	_style_section(shape_lbl, "Shape")
	shape_lbl.custom_minimum_size = Vector2(40, 0)
	shape_row.add_child(shape_lbl)
	_shape_mode_buttons.clear()
	for spec in [["Brush", ShapeMode.BRUSH, "Freehand: hold LMB and sweep"],
			["Circle", ShapeMode.CIRCLE, "Drag centre → edge to fill a circle"],
			["Rect", ShapeMode.RECT, "Drag corner → corner to fill a rectangle"],
			["Lasso", ShapeMode.LASSO, "Draw a freehand outline; release to fill it"],
			["Polygon", ShapeMode.POLYGON, "Click corners; click the first corner (or RMB) to close and fill"]]:
		var sb := Button.new()
		sb.text = spec[0]
		sb.tooltip_text = str(spec[2])
		sb.custom_minimum_size = Vector2(52, 24)
		var mode: ShapeMode = spec[1]
		sb.pressed.connect(_on_shape_mode_pressed.bind(mode))
		_style_tool_button(sb, mode == _shape_mode)
		shape_row.add_child(sb)
		_shape_mode_buttons.append(sb)
	_labeled_slider_row(shape_row, "Size m", 1.0, MAX_BRUSH_RADIUS_M, _brush_radius_m,
		func(v: float) -> void:
			_brush_radius_m = v
			_refresh_chips(), 64)
	_size_var_row = _labeled_slider_pair(shape_row, "Size var %", 0.0, 50.0, _size_var * 100.0,
		func(v: float) -> void:
			_size_var = clampf(v / 100.0, 0.0, 0.5)
			_apply_size_var_scales()
			_refresh_chips(), 56, 1.0)
	_density_row = _labeled_slider_pair(shape_row, "Dens", 0.25, 3.0, _density,
		func(v: float) -> void: set_paint_density(v), 56)
	var young_cb := CheckBox.new()
	young_cb.text = "Plant young"
	young_cb.tooltip_text = "Plant seedlings that grow over the years instead of full-size trees"
	young_cb.button_pressed = _plant_young
	young_cb.toggled.connect(func(on: bool) -> void:
		_plant_young = on
		_refresh_chips())
	shape_row.add_child(young_cb)

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
	return _labeled_slider_pair(parent, label, min_v, max_v, start, handler,
		slider_min_w, step).get("row")


## Same row, but returns the {row, slider, spin} triple so the caller can push
## values back into the widget later (SliderSpinRow.set_values).
func _labeled_slider_pair(parent: Control, label: String, min_v: float, max_v: float,
		start: float, handler: Callable, slider_min_w: int = 80,
		step: float = -1.0) -> Dictionary:
	return SliderSpinRowScript.add(parent, label, min_v, max_v, start, handler,
		func(lbl: Label, txt: String) -> void: _style_section(lbl, txt),
		36, slider_min_w, 58, step)


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
	_apply_size_var_scales()
	_on_shape_mode_pressed(ShapeMode.BRUSH)
	_refresh_subspecies_dropdown()
	_layout_panel()
	_refresh_chips()
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
	_stroking = false
	_brush_undo_pushed = false
	_place_click_armed = false
	_paint_click_candidate = false
	_highlight_pending = false
	_poly_points = PackedVector2Array()
	_lasso_pts = PackedVector2Array()
	if _poly_draw != null:
		_poly_draw.queue_redraw()
	set_process(false)
	visible = false
	# Leaving the dock must also release the drone — otherwise the player is
	# stranded in a locked top-down ortho view with no dock to turn it off.
	if _topdown:
		_set_topdown(false)
	mode_changed.emit(false)
	_clear_locked_selection()
	_clear_crosshair_prompt()
	_set_busy(false)
	if _capture != null:
		_capture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	CursorController.release_modal(MODAL_NAME)


func _clear_selection_or_exit() -> bool:
	if _stroking:
		_end_brush_stroke()
		return true
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
	_refresh_chips()


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
	if _shape_mode == ShapeMode.BRUSH:
		if _tool == Tool.PAINT or _tool == Tool.CLEAR:
			_begin_brush_stroke(Vector2(p.x, p.z))
		elif _tool == Tool.SELECT:
			# Select + Brush is the per-tree tool (Phase 8): the area shapes
			# already cover "re-scatter this region", and there was previously
			# no way at all to touch ONE plant.
			_pick_single_plant(Vector2(p.x, p.z))
		else:
			_set_status("Brush paints/clears — switch tool, or use Circle/Rect to select")
		return
	if _shape_mode == ShapeMode.POLYGON:
		var pt := Vector2(p.x, p.z)
		if _poly_points.size() >= 3 and pt.distance_to(_poly_points[0]) < 3.0:
			_finish_polygon(_poly_points)
			return
		_poly_points.append(pt)
		_update_polygon_preview(true)
		_set_status("Polygon: %s — Enter/RMB to finish" % UiText.count(_poly_points.size(), "point"))
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
	if _stroking:
		_end_brush_stroke()
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
	if _shape_mode == ShapeMode.BRUSH and (_tool == Tool.PAINT or _tool == Tool.CLEAR):
		var hit: Variant = _pick_pointer()
		if hit is Vector3:
			var center := Vector2((hit as Vector3).x, (hit as Vector3).z)
			var ring := VegetationPaint.circle_polygon(center, _brush_radius_m, 40)
			var pts := _project_poly(ring)
			if pts.size() >= 3:
				pts.append(pts[0])
				_poly_draw.draw_polyline(pts, col, 2.0, true)


func _project_poly(poly: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	var cam := get_viewport().get_camera_3d()
	if cam == null or _loader == null or not _loader.has_method("ground_height_at"):
		return out
	for p in poly:
		var y := float(_loader.call("ground_height_at", p.x, p.y))
		var wp := Vector3(p.x, y + 0.3, p.y)
		if cam.is_position_behind(wp):
			continue
		out.append(cam.unproject_position(wp))
	return out


func _begin_brush_stroke(world: Vector2) -> void:
	_stroking = true
	_brush_undo_pushed = false
	_last_stamp = Vector2(-1e9, -1e9)
	_stamp_brush_at(world)
	_update_brush_ring_preview()


func _end_brush_stroke() -> void:
	_stroking = false
	_brush_undo_pushed = false
	_last_stamp = Vector2(-1e9, -1e9)
	_update_undo_button()
	if _loader != null and _loader.has_method("clear_vegetation_highlight"):
		_loader.call("clear_vegetation_highlight")
	_set_status("Hold LMB to paint · drag shapes to fill areas")
	if _poly_draw != null:
		_poly_draw.queue_redraw()


func _brush_stroke_tick() -> void:
	var hit: Variant = _pick_pointer()
	if not (hit is Vector3):
		return
	var p: Vector3 = hit
	_stamp_brush_at(Vector2(p.x, p.z))
	_update_brush_ring_preview()
	if _poly_draw != null:
		_poly_draw.queue_redraw()


func _stamp_brush_at(world: Vector2) -> void:
	if _loader == null or _busy:
		return
	var min_step := maxf(_brush_radius_m * 0.45, _effective_spacing() * 0.85)
	if _last_stamp.x > -1e8 and world.distance_to(_last_stamp) < min_step:
		return
	_last_stamp = world
	if not _brush_undo_pushed:
		_push_undo("brush")
		_brush_undo_pushed = true
	var poly := VegetationPaint.circle_polygon(world, _brush_radius_m, 24)
	match _tool:
		Tool.CLEAR:
			if _loader.has_method("clear_vegetation_in_polygon"):
				_loader.call("clear_vegetation_in_polygon", poly)
			if _loader.has_method("clear_auto_vegetation_in_polygon"):
				_loader.call("clear_auto_vegetation_in_polygon", poly)
			vegetation_applied.emit()
		Tool.PAINT:
			if _loader.has_method("populate_vegetation"):
				var n: int = int(_loader.call("populate_vegetation", poly, _scatter_params()))
				if n > 0:
					vegetation_applied.emit()
		_:
			pass


func _update_brush_ring_preview() -> void:
	var hit: Variant = _pick_pointer()
	if not (hit is Vector3):
		return
	var p: Vector3 = hit
	_brush_poly = VegetationPaint.circle_polygon(Vector2(p.x, p.z), _brush_radius_m, 28)
	_queue_highlight_refresh(true)
	if _poly_draw != null:
		_poly_draw.queue_redraw()


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
	if _preset != VegetationPaint.Preset.MIX and not _paint_species.is_empty():
		return VegSpeciesCatalog.label_for(_paint_species).to_lower()
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
	_stroking = false
	for i in _shape_mode_buttons.size():
		_style_tool_button(_shape_mode_buttons[i], i == int(mode))
	_update_shape_prompt()
	_refresh_chips()
	if _loader != null and _loader.has_method("clear_vegetation_highlight"):
		_loader.call("clear_vegetation_highlight")
	if _poly_draw != null:
		_poly_draw.queue_redraw()


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
	_refresh_chips()


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
	_apply_size_var_scales()
	_refresh_subspecies_dropdown()
	_refresh_chips()
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


func _refresh_subspecies_dropdown() -> void:
	if _subspecies_opt == null:
		return
	_subspecies_opt.clear()
	var fam := _preset_to_species()
	if fam.is_empty():
		_subspecies_opt.add_item("— mix —")
		_subspecies_opt.disabled = true
		_paint_species = ""
		return
	_subspecies_opt.disabled = false
	var ids := VegSpeciesCatalog.subspecies_for_family(fam)
	var select_idx := 0
	for i in ids.size():
		var sid: String = ids[i]
		_subspecies_opt.add_item(VegSpeciesCatalog.label_for(sid))
		_subspecies_opt.set_item_metadata(i, sid)
		if sid == _paint_species:
			select_idx = i
	_subspecies_opt.select(select_idx)
	_paint_species = str(_subspecies_opt.get_item_metadata(select_idx))


func _on_subspecies_selected(idx: int) -> void:
	if _subspecies_opt == null or _subspecies_opt.disabled:
		return
	var sid := str(_subspecies_opt.get_item_metadata(idx))
	if sid.is_empty() or not VegSpeciesCatalog.is_paintable(sid):
		return
	_paint_species = sid
	# Overhaul v2: NO hidden per-record snapshot here. Saved species defaults
	# flow through the style store's species layer at render time, so painting
	# Spruce just paints spruce — the old auto-loaded card_settings silently
	# pinned every painted tree to a stale look that later style edits could
	# never touch ("Tune look does nothing to my painted trees").
	_refresh_chips()
	if _selection_locked:
		_queue_respecies()


func _set_tool(t: Tool) -> void:
	if _tool == Tool.SELECT and t != Tool.SELECT:
		_clear_locked_selection()
		_picked_plant = {}
	_tool = t
	if _loader != null and _loader.has_method("reset_vegetation_highlight_cache"):
		_loader.call("reset_vegetation_highlight_cache")
	for i in _tool_buttons.size():
		_style_tool_button(_tool_buttons[i], i == int(t))
	if _hero_section != null:
		_hero_section.visible = t == Tool.PLACE
	_update_shape_prompt()
	_refresh_chips()


func _update_shape_prompt() -> void:
	match _tool:
		Tool.PAINT:
			match _shape_mode:
				ShapeMode.BRUSH:
					_set_status("Hold LMB to paint · drag shapes to fill areas")
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
				ShapeMode.BRUSH:
					_set_status("Hold LMB to clear along the brush path")
				ShapeMode.POLYGON:
					_set_status("Clear — click corners, Enter/RMB to finish, then confirm")
				_:
					_set_status("Clear — click center, drag to size, release to apply")
		Tool.SELECT:
			match _shape_mode:
				ShapeMode.BRUSH:
					_set_status("Select — click ONE plant to pick it (Del deletes, [ / ] resize, H makes it a hero tree); Circle/Rect/Lasso locks an area")
				ShapeMode.POLYGON:
					_set_status("Select — use Circle or Rect to lock an area, then change Type")
				_:
					_set_status("Select — click center, drag to size, release to lock; change Type to re-scatter")
	_update_crosshair_prompt()


func _set_status(msg: String) -> void:
	if _status != null:
		_status.text = msg


# ---------------------------------------------------------------------------
# Top-down ortho paint (survey drone)
# ---------------------------------------------------------------------------

func _set_topdown(on: bool) -> void:
	_topdown = on
	if _topdown_btn != null:
		_style_tool_button(_topdown_btn, on)
	_lock_drone_ortho(on)
	if _topdown:
		_set_status("Top-down paint — WASD repositions · paint with LMB as usual")
	else:
		_update_shape_prompt()


## Mount the survey drone (if the player isn't already on it), lock it to a
## top-down orthographic view, and set the meta the drone reads. Exactly the
## terrain-sculpt flow (terrain_edit_ui._lock_drone_ortho) against the veg meta.
func _lock_drone_ortho(on: bool) -> void:
	var main := get_tree().get_first_node_in_group("main_scene") if is_inside_tree() else null
	var player := main.get_node_or_null("Player") as CharacterBody3D if main != null else null
	var drone := main.get_node_or_null("FPVDrone") if main != null else null
	# No scene / no drone are the same outcome: the toggle must fall back OFF.
	# Returning early on a null main left `_topdown` true with nothing locked,
	# so the button read "on" while the camera never moved.
	if player == null or drone == null:
		_topdown = false
		if _topdown_btn != null:
			_style_tool_button(_topdown_btn, false)
		if on:
			_set_status("Top-down needs the survey drone")
		return
	if on:
		if player.has_method("_release_mouse"):
			player.call("_release_mouse")
		_we_mounted_drone = false
		if not drone.is_mounted and player.has_method("_mount_vehicle"):
			player.call("_mount_vehicle", drone)
			_we_mounted_drone = true
		drone.set_meta("vegetation_edit_ortho", true)
		var cam := _find_drone_camera(drone)
		if cam != null:
			_saved_camera_projection = cam.projection
			_saved_camera_size = cam.size
			cam.projection = Camera3D.PROJECTION_ORTHOGONAL
			cam.size = maxf(_brush_radius_m * 8.0, 120.0)
	else:
		drone.set_meta("vegetation_edit_ortho", false)
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


# ---------------------------------------------------------------------------
# State chips
# ---------------------------------------------------------------------------

## The chip row's content as pure data — [{text, color}] — so the dock's
## visible state can be asserted offline without building a single Control
## (see vegetation/veg_dock_state_selftest.gd).
func chip_specs() -> Array:
	var chips: Array = []
	chips.append({
		"text": "%s: %s" % [_tool_name(_tool), _species_chip_label()],
		"color": species_chip_color(_paint_species, _preset),
	})
	chips.append({"text": "×%.2f dens" % _density, "color": UITheme.C_PRIMARY})
	if _shape_mode == ShapeMode.BRUSH:
		chips.append({"text": "r %.1f m" % _brush_radius_m, "color": UITheme.C_TEXT_S})
	else:
		chips.append({"text": _shape_name(_shape_mode), "color": UITheme.C_TEXT_S})
	if _size_var > 0.005:
		chips.append({"text": "±%.0f%% size" % (_size_var * 100.0), "color": UITheme.C_TEXT_S})
	if has_brush_style():
		# The single most surprising piece of hidden state: painting carries a
		# per-instance look override that nothing else on screen hints at.
		chips.append({"text": "custom look", "color": UITheme.C_AMBER})
	if _selection_locked:
		var area := VegetationPaint.polygon_area(_selection_poly)
		chips.append({
			"text": "selection %s" % _area_chip_text(area),
			"color": UITheme.C_INFO,
		})
	if not _picked_plant.is_empty():
		chips.append({
			"text": "picked %s ×%.2f" % [
				VegSpeciesCatalog.label_for(str(_picked_plant.get("species", ""))),
				float(_picked_plant.get("scale", 1.0))],
			"color": UITheme.C_INFO,
		})
	return chips


static func _tool_name(t: Tool) -> String:
	match t:
		Tool.PLACE:
			return "Place"
		Tool.CLEAR:
			return "Clear"
		Tool.SELECT:
			return "Select"
		_:
			return "Paint"


static func _shape_name(m: ShapeMode) -> String:
	match m:
		ShapeMode.CIRCLE:
			return "circle"
		ShapeMode.RECT:
			return "rect"
		ShapeMode.LASSO:
			return "lasso"
		ShapeMode.POLYGON:
			return "polygon"
		_:
			return "brush"


static func _area_chip_text(area_m2: float) -> String:
	if area_m2 >= 10000.0:
		return "%.2f ha" % (area_m2 / 10000.0)
	return "%.0f m²" % area_m2


## Swatch for the active species. Falls back to the preset when the subspecies
## dropdown is on "— mix —" (no single species selected).
static func species_chip_color(species: String, preset: int) -> Color:
	if not species.is_empty():
		var fam := VegSpeciesCatalog.mesh_family(species)
		if FAMILY_CHIP_COLORS.has(fam):
			return FAMILY_CHIP_COLORS[fam]
	match preset:
		VegetationPaint.Preset.PINE:
			return FAMILY_CHIP_COLORS["pine"]
		VegetationPaint.Preset.DECIDUOUS:
			return FAMILY_CHIP_COLORS["deciduous"]
		VegetationPaint.Preset.SHRUB:
			return FAMILY_CHIP_COLORS["shrub"]
		VegetationPaint.Preset.GRASS_LAWN:
			return FAMILY_CHIP_COLORS["grass_lawn"]
		VegetationPaint.Preset.GRASS_FIELD:
			return FAMILY_CHIP_COLORS["grass_field"]
	return UITheme.C_LAVENDER


func _species_chip_label() -> String:
	if _tool == Tool.PLACE:
		var hero := HeroTreeCatalog.find(_hero_preset)
		return str(hero.get("label", _hero_preset)) if not hero.is_empty() else _hero_preset
	if not _paint_species.is_empty():
		return VegSpeciesCatalog.label_for(_paint_species)
	return _preset_label()


func _refresh_chips() -> void:
	if _chip_row == null:
		return
	for child in _chip_row.get_children():
		child.queue_free()
	for spec in chip_specs():
		var color: Color = spec.get("color", UITheme.C_TEXT_S)
		var pill := PanelContainer.new()
		pill.add_theme_stylebox_override("panel", UITheme.chip_style(color))
		var lbl := Label.new()
		lbl.text = str(spec.get("text", ""))
		lbl.add_theme_color_override("font_color", color.lightened(0.35))
		lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		pill.add_child(lbl)
		_chip_row.add_child(pill)


func _set_busy(on: bool) -> void:
	_busy = on
	if _progress_bar != null and not on:
		_progress_bar.visible = false


func _update_process_enabled() -> void:
	set_process(_active)


# ---------------------------------------------------------------------------
# Crosshair UI
# ---------------------------------------------------------------------------

var _crosshair_cache: Node = null


func _crosshair_ui() -> Node:
	# The dock lives on its own CanvasLayer (VegetationEditLayer), NOT under
	# UILayer — the old get_parent() lookup always returned null, so every
	# crosshair prompt/aim update in this file was a silent no-op. Resolve via
	# the Main scene (group "main_scene", same pattern as the preview editor).
	if _crosshair_cache != null and is_instance_valid(_crosshair_cache):
		return _crosshair_cache
	_crosshair_cache = null
	# _set_tool / _update_shape_prompt reach here, and the loader can call those
	# before this dock is inside the tree (as the offline dock selftest does).
	# is_inside_tree(), NOT get_tree() == null: calling get_tree() off-tree
	# PRINTS an engine error before returning null, so the guard would be the
	# thing generating the noise it exists to avoid.
	if not is_inside_tree():
		return null
	var main := get_tree().get_first_node_in_group("main_scene")
	if main != null:
		_crosshair_cache = main.get_node_or_null("UILayer/CrosshairUI")
	return _crosshair_cache


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
				ShapeMode.BRUSH:
					_set_crosshair_prompt("Hold LMB to paint · Size m sets brush radius")
				ShapeMode.CIRCLE:
					_set_crosshair_prompt("Drag LMB — circle preview, release to apply")
				ShapeMode.RECT:
					_set_crosshair_prompt("Drag LMB — rectangle preview, release to apply")
				ShapeMode.POLYGON:
					_set_crosshair_prompt("Click LMB — add corners; Enter/RMB to finish")
				ShapeMode.LASSO:
					_set_crosshair_prompt("Drag LMB — lasso area, release to apply")
		Tool.PLACE:
			_set_crosshair_prompt("Click LMB to place hero tree")
		Tool.SELECT:
			match _shape_mode:
				ShapeMode.POLYGON:
					_set_crosshair_prompt("Click corners; Enter/RMB to lock selection")
				ShapeMode.BRUSH:
					_set_crosshair_prompt("Click a plant to pick it — Del deletes, [ / ] resize, H → hero")
				_:
					_set_crosshair_prompt("Drag LMB — release to lock selection")


# ---------------------------------------------------------------------------
# Scatter params + selection re-scatter
# ---------------------------------------------------------------------------

func _scatter_params() -> Dictionary:
	_apply_size_var_scales()
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
	if _preset != VegetationPaint.Preset.MIX and VegSpeciesCatalog.is_paintable(_paint_species):
		params["species"] = _paint_species
	if not _brush_card.is_empty():
		params["card_settings"] = _brush_card
	params["plant_young"] = _plant_young
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
		_set_status("Re-scattered selection — %s" % UiText.count(n, "instance"))


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
	_set_status("Re-scattered selection — %s" % UiText.count(n, "instance"))


## Resolve the concrete species for a single-instance drop. Mix picks one weighted
## by the mix sliders; otherwise use the subspecies dropdown selection.
func _resolve_single_species() -> String:
	if _preset != VegetationPaint.Preset.MIX and VegSpeciesCatalog.is_paintable(_paint_species):
		return _paint_species
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
	# Hero placement is the one paint action that never pushed an undo entry —
	# a misplaced 20 m tree could only be removed by hunting for it.
	_push_undo("place hero")
	if bool(_loader.call("place_hero_tree", _hero_preset, p.x, p.z, _hero_scale, p.y)):
		vegetation_applied.emit()
		_set_status("Placed hero tree — Undo removes it")
	else:
		_set_status("Could not place hero (limit reached?)")


# ---------------------------------------------------------------------------
# Per-tree Select
# ---------------------------------------------------------------------------

## The plant last picked with Select+Brush: {kind, species, index, x, z, scale}.
## Held only to render the readout — the (species, index) handle is re-resolved
## from the world position on every action, because any edit reorders the array
## the index points into.
var _picked_plant: Dictionary = {}
const PICK_RADIUS_M := 6.0


func _pick_single_plant(world_xz: Vector2) -> void:
	if _loader == null or not _loader.has_method("pick_plant_at"):
		return
	var desc: Dictionary = _loader.call("pick_plant_at", world_xz, PICK_RADIUS_M)
	if desc.is_empty():
		_picked_plant = {}
		_set_status("No painted plant within %.0f m — Select+Brush picks ONE plant (auto-scattered OSM trees aren't editable individually)" % PICK_RADIUS_M)
		_refresh_chips()
		return
	_picked_plant = desc
	_set_status("%s · Del deletes · [ / ] resize · H → hero tree · click elsewhere to pick another"
		% _picked_label(desc))
	_refresh_chips()


static func _picked_label(desc: Dictionary) -> String:
	var species := str(desc.get("species", ""))
	var name := VegSpeciesCatalog.label_for(species) if not species.is_empty() else "plant"
	if str(desc.get("kind", "")) == "hero":
		name = "%s (hero)" % name
	return "%s ×%.2f, %.1f m away" % [name, float(desc.get("scale", 1.0)),
		float(desc.get("dist_m", 0.0))]


func _delete_picked_plant() -> void:
	if _picked_plant.is_empty() or _loader == null \
			or not _loader.has_method("delete_plant_at"):
		return
	_push_undo("delete plant")
	var at := Vector2(float(_picked_plant.get("x", 0.0)), float(_picked_plant.get("z", 0.0)))
	var gone: Dictionary = _loader.call("delete_plant_at", at, PICK_RADIUS_M)
	if gone.is_empty():
		_set_status("Nothing deleted — pick a plant first")
		return
	vegetation_applied.emit()
	_picked_plant = {}
	_set_status("Deleted %s — Undo restores it" % _picked_label(gone))
	_refresh_chips()


## Promote the picked card plant to a hero GLB at the same spot and apparent
## size. The species chooses the model — a pine becomes a pine, whatever hero
## preset the Place tool happens to be showing.
func _convert_picked_to_hero() -> void:
	if _picked_plant.is_empty() or _loader == null \
			or not _loader.has_method("convert_plant_to_hero_at"):
		return
	if str(_picked_plant.get("kind", "")) == "hero":
		_set_status("Already a hero tree")
		return
	_push_undo("convert to hero")
	var at := Vector2(float(_picked_plant.get("x", 0.0)), float(_picked_plant.get("z", 0.0)))
	var res: Dictionary = _loader.call("convert_plant_to_hero_at", at, PICK_RADIUS_M)
	if res.is_empty():
		_set_status("Could not convert (hero limit reached?)")
		return
	vegetation_applied.emit()
	_picked_plant = _loader.call("pick_plant_at", at, PICK_RADIUS_M)
	_set_status("Converted to hero %s at %.1f m — Undo restores the card tree"
		% [str(res.get("preset", "")), float(res.get("height_m", 0.0))])
	_refresh_chips()


func _resize_picked_plant(factor: float) -> void:
	if _picked_plant.is_empty() or _loader == null \
			or not _loader.has_method("scale_plant_at"):
		return
	_push_undo("resize plant")
	var at := Vector2(float(_picked_plant.get("x", 0.0)), float(_picked_plant.get("z", 0.0)))
	var changed: Dictionary = _loader.call("scale_plant_at", at, factor, PICK_RADIUS_M)
	if changed.is_empty():
		return
	# Re-read the record so the readout shows the NEW scale, not the old one.
	_picked_plant = _loader.call("pick_plant_at", at, PICK_RADIUS_M)
	vegetation_applied.emit()
	_set_status("Resized %s" % _picked_label(_picked_plant))
	_refresh_chips()
