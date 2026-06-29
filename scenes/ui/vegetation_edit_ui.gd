extends Control

## Vegetation paint toolbar — click/drag area selection + compact dock over timeline.

signal vegetation_applied
signal mode_changed(active: bool)

enum Tool { PAINT, PLACE, CLEAR, SELECT }
enum ShapeMode { CIRCLE, RECT, LASSO, POLYGON }

const MODAL_NAME := "vegetation_edit"
const PANEL_HEIGHT := 172.0
const HIGHLIGHT_DEBOUNCE_S := 0.016
const SHAPE_LIVE_DEBOUNCE_S := 0.12
const RESPECIES_DEBOUNCE_S := 0.35
const MAX_SELECTION_RADIUS_M := 75.0
const MAX_SELECTION_AREA_M2 := 17500.0
const HIGHLIGHT_CLEAR := Color(0.95, 0.25, 0.2, 0.42)
const HIGHLIGHT_PAINT := Color(0.2, 0.9, 0.4, 0.42)
const HIGHLIGHT_SELECT := Color(0.35, 0.75, 0.95, 0.42)

var _loader: Node = null
var _active := false
var _tool := Tool.PAINT
var _preset := VegetationPaint.Preset.SHRUB
var _spacing_m := 4.0
var _density := 1.0
var _scale_mul := 1.0
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
var _vertical_offset := 0.0
var _decid_canopy_w := 11.0
var _decid_canopy_h := 4.5
var _decid_trunk_w := 0.45
var _decid_trunk_h := 4.5
var _decid_bulk_scale := 1.35
var _decid_raise := 0.0
var _pine_card_w := 0.85
var _pine_card_h := 4.5
var _pine_trunk_w := 0.24
var _pine_bulk_scale := 1.0
var _pine_raise := 0.0
var _shrub_card_w := 1.4
var _shrub_card_h := 1.15
var _shrub_bulk_scale := 1.0
var _shrub_raise := 0.0
var _grass_lawn_w := 0.08
var _grass_lawn_h := 0.42
var _grass_lawn_bulk_scale := 1.35
var _grass_lawn_raise := 0.0
var _grass_field_w := 0.11
var _grass_field_h := 0.88
var _grass_field_bulk_scale := 1.25
var _grass_field_raise := 0.0
var _tint_pine := Color.WHITE
var _tint_deciduous := Color.WHITE
var _tint_shrub := Color.WHITE
var _tint_grass_lawn := Color.WHITE
var _tint_grass_field := Color.WHITE
var _style_drape_match := 0.35
var _style_hue_jitter := 0.05
var _style_dither := 1.0
var _style_building_excl := 0.0
var _style_road_excl := 0.0
var _style_building_excl_enabled := true
var _style_road_excl_enabled := true
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
var _edit_all_map := false
var _select_all_btn: Button = null
var _mix_tune_hint: Label = null

var _capture: ColorRect = null
var _poly_draw: Control = null
var _undo_btn: Button = null
var _panel: PanelContainer = null
var _advanced_drawer: VBoxContainer = null
var _status: Label = null
var _mix_row: HBoxContainer = null
var _hero_section: HBoxContainer = null
var _tool_buttons: Array[Button] = []
var _preset_buttons: Array[Button] = []
var _decid_section: VBoxContainer = null
var _pine_section: VBoxContainer = null
var _shrub_section: VBoxContainer = null
var _grass_lawn_section: VBoxContainer = null
var _grass_field_section: VBoxContainer = null
var _style_drawer: VBoxContainer = null
var _progress_bar: ProgressBar = null
var _busy := false
var _highlight_pending := false
var _highlight_timer := 0.0
var _style_regen_pending := false
var _style_regen_timer := 0.0
var _shape_live_pending := false
var _shape_live_timer := 0.0
var _selection_patch_pending := false
var _selection_patch_timer := 0.0
var _respecies_pending := false
var _respecies_timer := 0.0
var _shape_rendering := false
var _place_click_armed := false


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiScreenLayout.pin_fullscreen(self)
	set_process(false)
	_build_ui()


func bind_loader(loader: Node) -> void:
	_loader = loader
	_load_settings_from_loader()
	if _loader != null and _loader.has_signal("vegetation_operation_progress"):
		var cb := Callable(self, "_on_veg_operation_progress")
		if not _loader.is_connected("vegetation_operation_progress", cb):
			_loader.connect("vegetation_operation_progress", cb)


func toggle_mode() -> void:
	if _active:
		_exit_mode()
	else:
		_enter_mode()


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
	if _style_regen_pending:
		_style_regen_timer += delta
		if _style_regen_timer >= SHAPE_LIVE_DEBOUNCE_S:
			_style_regen_pending = false
			_commit_style_changes(true)
	if _shape_live_pending and not _selection_locked:
		_shape_live_timer += delta
		if _shape_live_timer >= SHAPE_LIVE_DEBOUNCE_S:
			_shape_live_pending = false
			_apply_shape_live()
	if _selection_patch_pending:
		_selection_patch_timer += delta
		if _selection_patch_timer >= SHAPE_LIVE_DEBOUNCE_S:
			_selection_patch_pending = false
			_apply_selection_patch()
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
	var adv_btn := Button.new()
	adv_btn.text = "Advanced ▾"
	adv_btn.custom_minimum_size = Vector2(88, 28)
	adv_btn.add_theme_stylebox_override("normal", _secondary_btn_style())
	adv_btn.pressed.connect(_toggle_advanced)
	tool_row.add_child(adv_btn)
	var exit_btn := Button.new()
	exit_btn.text = "Exit"
	exit_btn.custom_minimum_size = Vector2(52, 28)
	exit_btn.add_theme_stylebox_override("normal", _secondary_btn_style())
	exit_btn.pressed.connect(_exit_mode)
	tool_row.add_child(exit_btn)
	_status = Label.new()
	_style_muted(_status)
	_status.text = "V — click terrain, drag to select · Ctrl+Z undo"
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
	_labeled_slider_row(param_row, "Density", 0.25, 2.0, _density,
		func(v: float) -> void:
			_density = v
			_spacing_m = _effective_spacing()
			if _selection_locked:
				_queue_respecies(), 64)

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

	_mix_row = HBoxContainer.new()
	_mix_row.visible = _preset == VegetationPaint.Preset.MIX
	col.add_child(_mix_row)
	_labeled_slider_row(_mix_row, "Pine", 0.0, 1.0, _mix_pine,
		func(v: float) -> void: _on_mix_changed("pine", v), 52)
	_labeled_slider_row(_mix_row, "Decid", 0.0, 1.0, _mix_deciduous,
		func(v: float) -> void: _on_mix_changed("deciduous", v), 52)
	_labeled_slider_row(_mix_row, "Shrub", 0.0, 1.0, _mix_shrub,
		func(v: float) -> void: _on_mix_changed("shrub", v), 52)
	_labeled_slider_row(_mix_row, "Lawn", 0.0, 1.0, _mix_grass_lawn,
		func(v: float) -> void: _on_mix_changed("grass_lawn", v), 52)
	_labeled_slider_row(_mix_row, "Field", 0.0, 1.0, _mix_grass_field,
		func(v: float) -> void: _on_mix_changed("grass_field", v), 52)

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

	_advanced_drawer = VBoxContainer.new()
	_advanced_drawer.visible = false
	_advanced_drawer.add_theme_constant_override("separation", 4)
	col.add_child(_advanced_drawer)
	_build_advanced_drawer(_advanced_drawer)


func _build_advanced_drawer(parent: VBoxContainer) -> void:
	var universal_row := HBoxContainer.new()
	parent.add_child(universal_row)
	_labeled_slider_row(universal_row, "Raise all", -25.0, 25.0, _vertical_offset,
		func(v: float) -> void: _on_vertical_offset_changed(v), 72, false,
		Callable(self, "_persist_shape_settings"))
	_select_all_btn = Button.new()
	_select_all_btn.text = "Select all"
	_select_all_btn.custom_minimum_size = Vector2(72, 24)
	_select_all_btn.add_theme_stylebox_override("normal", _secondary_btn_style())
	_select_all_btn.pressed.connect(_toggle_select_all)
	universal_row.add_child(_select_all_btn)

	_mix_tune_hint = Label.new()
	_style_muted(_mix_tune_hint)
	_mix_tune_hint.text = "Mix paints with each type's current settings below — switch Type to tune one species."
	_mix_tune_hint.autowrap_mode = TextServer.AUTOWRAP_WORD
	_mix_tune_hint.visible = false
	parent.add_child(_mix_tune_hint)

	var adv_row := HBoxContainer.new()
	parent.add_child(adv_row)
	_labeled_slider_row(adv_row, "Seed", 1.0, 9999.0, float(_seed_value),
		func(v: float) -> void: _seed_value = int(v), 56)
	_labeled_slider_row(adv_row, "MinR", 1.0, 30.0, _brush_min_m,
		func(v: float) -> void: _brush_min_m = v, 48)
	_labeled_slider_row(adv_row, "H×", 0.25, 3.0, _scale_mul,
		func(v: float) -> void:
			_scale_mul = v
			_queue_selection_patch(), 56)
	_labeled_slider_row(adv_row, "H min", 0.5, 3.0, _scale_min, func(v: float) -> void: _scale_min = v, 70)
	_labeled_slider_row(adv_row, "H max", 0.5, 4.0, _scale_max, func(v: float) -> void: _scale_max = v, 70)

	var act_row := HBoxContainer.new()
	parent.add_child(act_row)
	var patch_btn := Button.new()
	patch_btn.text = "Patch auto"
	patch_btn.add_theme_stylebox_override("normal", _secondary_btn_style())
	patch_btn.pressed.connect(_patch_auto_veg)
	act_row.add_child(patch_btn)

	_decid_section = _build_species_section(parent, "Deciduous", [
		{"label": "Can W", "min": 4.0, "max": 16.0, "value": _decid_canopy_w, "key": "deciduous_canopy_w", "width": 70},
		{"label": "Can H", "min": 2.0, "max": 8.0, "value": _decid_canopy_h, "key": "deciduous_canopy_h", "width": 70},
		{"label": "Tr W", "min": 0.2, "max": 1.2, "value": _decid_trunk_w, "key": "deciduous_trunk_w", "width": 60},
		{"label": "Tr H", "min": 2.0, "max": 8.0, "value": _decid_trunk_h, "key": "deciduous_trunk_h", "width": 60},
		{"label": "Bulk×", "min": 0.5, "max": 3.0, "value": _decid_bulk_scale, "key": "deciduous_bulk_scale", "width": 60},
	], "deciduous", _decid_raise, _tint_deciduous)

	_pine_section = _build_species_section(parent, "Pine", [
		{"label": "Bulk×", "min": 0.5, "max": 3.0, "value": _pine_bulk_scale, "key": "pine_bulk_scale", "width": 60},
		{"label": "W", "min": 0.3, "max": 2.5, "value": _pine_card_w, "key": "pine_card_w", "width": 56},
		{"label": "H", "min": 1.5, "max": 10.0, "value": _pine_card_h, "key": "pine_card_h", "width": 56},
		{"label": "Trunk", "min": 0.08, "max": 0.8, "value": _pine_trunk_w, "key": "pine_trunk_w", "width": 62},
	], "pine", _pine_raise, _tint_pine)

	_shrub_section = _build_species_section(parent, "Shrub", [
		{"label": "Bulk×", "min": 0.5, "max": 3.0, "value": _shrub_bulk_scale, "key": "shrub_bulk_scale", "width": 60},
		{"label": "W", "min": 0.4, "max": 3.5, "value": _shrub_card_w, "key": "shrub_card_w", "width": 56},
		{"label": "H", "min": 0.4, "max": 3.0, "value": _shrub_card_h, "key": "shrub_card_h", "width": 56},
	], "shrub", _shrub_raise, _tint_shrub)

	_grass_lawn_section = _build_species_section(parent, "Lawn grass", [
		{"label": "Bulk×", "min": 0.5, "max": 3.0, "value": _grass_lawn_bulk_scale, "key": "grass_lawn_bulk_scale", "width": 60},
		{"label": "Blade W", "min": 0.04, "max": 0.2, "value": _grass_lawn_w, "key": "grass_lawn_card_w", "width": 70},
		{"label": "Blade H", "min": 0.15, "max": 1.2, "value": _grass_lawn_h, "key": "grass_lawn_card_h", "width": 70},
	], "grass_lawn", _grass_lawn_raise, _tint_grass_lawn)

	_grass_field_section = _build_species_section(parent, "Field grass", [
		{"label": "Bulk×", "min": 0.5, "max": 3.0, "value": _grass_field_bulk_scale, "key": "grass_field_bulk_scale", "width": 60},
		{"label": "Blade W", "min": 0.06, "max": 0.25, "value": _grass_field_w, "key": "grass_field_card_w", "width": 70},
		{"label": "Blade H", "min": 0.3, "max": 1.5, "value": _grass_field_h, "key": "grass_field_card_h", "width": 70},
	], "grass_field", _grass_field_raise, _tint_grass_field)

	_style_drawer = VBoxContainer.new()
	parent.add_child(_style_drawer)
	var style_row := HBoxContainer.new()
	_style_drawer.add_child(style_row)
	_labeled_slider_row(style_row, "Drape", 0.0, 1.0, _style_drape_match,
		func(v: float) -> void: _on_style_shader_live("drape_match_strength", v), 70)
	_labeled_slider_row(style_row, "Hue", 0.0, 0.15, _style_hue_jitter,
		func(v: float) -> void: _on_style_shader_live("hue_jitter", v), 60)
	_update_preset_sections()


func _build_species_section(parent: VBoxContainer, title: String, sliders: Array,
		species: String, raise_value: float, tint: Color) -> VBoxContainer:
	var section := VBoxContainer.new()
	section.add_theme_constant_override("separation", 2)
	parent.add_child(section)
	var hdr := Label.new()
	_style_section(hdr, title)
	section.add_child(hdr)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	section.add_child(row)
	for spec in sliders:
		var sd: Dictionary = spec
		var slider_key := str(sd["key"])
		_labeled_slider_row(row, str(sd["label"]), float(sd["min"]), float(sd["max"]),
			float(sd["value"]),
			func(v: float) -> void: _on_shape_setting_changed(slider_key, v),
			int(sd.get("width", 60)), false, Callable(self, "_on_selection_shape_drag_end"))
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 4)
	section.add_child(row2)
	var raise_key := "%s_vertical_offset_m" % species
	_labeled_slider_row(row2, "Raise", -8.0, 8.0, raise_value,
		func(v: float) -> void: _on_shape_setting_changed(raise_key, v),
		56, false, Callable(self, "_on_selection_shape_drag_end"))
	_add_species_tint_picker(row2, "Color", species, tint)
	return section


func _make_confirm_button(label: String, handler: Callable) -> Button:
	var cb := Button.new()
	cb.text = label
	cb.custom_minimum_size = Vector2(88, 26)
	cb.add_theme_stylebox_override("normal", _secondary_btn_style())
	cb.pressed.connect(handler)
	return cb


func _add_species_tint_picker(parent: Control, label: String, species: String, start: Color) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	parent.add_child(row)
	var lbl := Label.new()
	_style_section(lbl, label)
	lbl.custom_minimum_size = Vector2(36, 0)
	row.add_child(lbl)
	var cp := ColorPickerButton.new()
	cp.color = start
	cp.custom_minimum_size = Vector2(44, 22)
	cp.color_changed.connect(func(c: Color) -> void: _on_species_tint_changed(species, c))
	row.add_child(cp)


func _on_species_tint_changed(species: String, color: Color) -> void:
	match species:
		"pine":
			_tint_pine = color
		"deciduous":
			_tint_deciduous = color
		"shrub":
			_tint_shrub = color
		"grass_lawn":
			_tint_grass_lawn = color
		"grass_field":
			_tint_grass_field = color
	if _loader == null or not _loader.has_method("set_vegetation_style"):
		return
	_loader.call("set_vegetation_style", {"%s_albedo_tint" % species: color}, false, false)
	_set_status("%s tint updated (live)" % species.capitalize())


func _on_mix_changed(which: String, value: float) -> void:
	match which:
		"pine":
			_mix_pine = value
		"deciduous":
			_mix_deciduous = value
		"shrub":
			_mix_shrub = value
		"grass_lawn":
			_mix_grass_lawn = value
		"grass_field":
			_mix_grass_field = value
	if _selection_locked:
		_queue_respecies()


func _on_veg_operation_progress(message: String, fraction: float) -> void:
	if _progress_bar != null:
		_progress_bar.visible = fraction >= 0.0 and fraction < 1.0
		_progress_bar.value = clampf(fraction, 0.0, 1.0)
	_set_status(message)


func _labeled_slider_row(parent: Control, label: String, min_v: float, max_v: float,
		start: float, handler: Callable, slider_min_w: int = 80,
		defer_mesh_rebuild: bool = false, drag_end_handler: Callable = Callable()) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	parent.add_child(row)
	if not label.is_empty():
		var lbl := Label.new()
		_style_section(lbl, label)
		lbl.custom_minimum_size = Vector2(36, 0)
		row.add_child(lbl)
	var sl := HSlider.new()
	sl.min_value = min_v
	sl.max_value = max_v
	sl.step = 0.05 if max_v <= 16.0 else 1.0
	sl.value = start
	sl.custom_minimum_size = Vector2(slider_min_w, 0)
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl.value_changed.connect(handler)
	if drag_end_handler.is_valid():
		sl.drag_ended.connect(func(_changed: bool) -> void: drag_end_handler.call())
	elif defer_mesh_rebuild:
		sl.drag_ended.connect(func(_changed: bool) -> void: _sync_settings_to_loader(true))
	row.add_child(sl)
	return row


func _toggle_advanced() -> void:
	if _advanced_drawer != null:
		_advanced_drawer.visible = not _advanced_drawer.visible
		_layout_panel()


func _layout_panel() -> void:
	if _panel == null:
		return
	var h := PANEL_HEIGHT
	if _advanced_drawer != null and _advanced_drawer.visible:
		h += 300.0
	UiScreenLayout.pin_over_timeline(_panel, h)


# ---------------------------------------------------------------------------
# Mode enter / exit
# ---------------------------------------------------------------------------

func _enter_mode() -> void:
	_active = true
	visible = true
	if _capture != null:
		_capture.mouse_filter = Control.MOUSE_FILTER_STOP
	mode_changed.emit(true)
	_load_settings_from_loader()
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
	_highlight_pending = false
	_selection_patch_pending = false
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
	_edit_all_map = false
	if _select_all_btn != null:
		_select_all_btn.text = "Select all"
		_style_tool_button(_select_all_btn, false)
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


func _on_vertical_offset_changed(value: float) -> void:
	_vertical_offset = value
	_on_setting_changed("vertical_offset_m", value)
	_queue_shape_live()


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
	if _loader.has_method("set_vegetation_settings"):
		_loader.call("set_vegetation_settings", _settings_dict(), false, false)
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
		_set_status("Painted %d %s — hold LMB to add more" % [n, _preset_label()])
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
	_set_status("Selected area — adjust H× / Advanced to restyle, or change Type to re-scatter %d+ bulk" % manual_n)


func _lock_selection_poly_for_advanced() -> PackedVector2Array:
	if _selection_locked:
		return _selection_poly
	return _brush_poly if _brush_poly.size() >= 3 else PackedVector2Array()


# ---------------------------------------------------------------------------
# Tool / preset handlers
# ---------------------------------------------------------------------------

func _on_tool_pressed(idx: int) -> void:
	_set_tool(idx as Tool)


func _on_preset_pressed(idx: int) -> void:
	_preset = idx as VegetationPaint.Preset
	for i in _preset_buttons.size():
		_style_tool_button(_preset_buttons[i], i == idx)
	if _mix_row != null:
		_mix_row.visible = _preset == VegetationPaint.Preset.MIX
	_spacing_m = _effective_spacing()
	match _preset:
		VegetationPaint.Preset.DECIDUOUS:
			_scale_min = maxf(_scale_min, 1.0)
			_scale_max = maxf(_scale_max, 1.6)
		VegetationPaint.Preset.GRASS_LAWN, VegetationPaint.Preset.GRASS_FIELD:
			_scale_min = 0.75
			_scale_max = 1.15
	_update_preset_sections()
	if _selection_locked:
		_queue_respecies()


func _update_preset_sections() -> void:
	var is_mix := _preset == VegetationPaint.Preset.MIX
	if _mix_tune_hint != null:
		_mix_tune_hint.visible = is_mix
	if _decid_section != null:
		_decid_section.visible = _preset == VegetationPaint.Preset.DECIDUOUS
	if _pine_section != null:
		_pine_section.visible = _preset == VegetationPaint.Preset.PINE
	if _shrub_section != null:
		_shrub_section.visible = _preset == VegetationPaint.Preset.SHRUB
	if _grass_lawn_section != null:
		_grass_lawn_section.visible = _preset == VegetationPaint.Preset.GRASS_LAWN
	if _grass_field_section != null:
		_grass_field_section.visible = _preset == VegetationPaint.Preset.GRASS_FIELD


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


func _toggle_select_all() -> void:
	if _edit_all_map:
		_clear_locked_selection()
		return
	_edit_all_map = true
	_selection_locked = true
	if _loader != null and _loader.has_method("get_map_vegetation_bounds"):
		_selection_poly = _loader.call("get_map_vegetation_bounds")
	else:
		_selection_poly = PackedVector2Array([
			Vector2(-15000, -15000), Vector2(15000, -15000),
			Vector2(15000, 15000), Vector2(-15000, 15000),
		])
	if _select_all_btn != null:
		_select_all_btn.text = "Clear all"
		_style_tool_button(_select_all_btn, true)
	_do_refresh_highlight(true)
	_set_status("Select all — Advanced edits apply to the whole map")


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
				_:
					_set_status("Paint — click center, drag to size (max %.0f m), release to apply" % MAX_SELECTION_RADIUS_M)
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
					_set_status("Select — use Circle or Rect to lock an area for Advanced")
				_:
					_set_status("Select — click center, drag to size, release to lock for Advanced")
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
# Selection patch + shape/style (advanced)
# ---------------------------------------------------------------------------

func _scatter_params() -> Dictionary:
	return {
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


func _selection_patch_params() -> Dictionary:
	var params := _scatter_params()
	params["scale_mul"] = _scale_mul
	params["patch_species"] = _preset_to_species()
	params["patch_all_map"] = _edit_all_map
	params.merge(_settings_dict(), true)
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


func _queue_selection_patch() -> void:
	if not _selection_locked:
		return
	_selection_patch_pending = true
	_selection_patch_timer = 0.0
	_update_process_enabled()


func _apply_selection_patch() -> void:
	if not _selection_locked or _loader == null:
		return
	if not _loader.has_method("apply_selection_patch"):
		return
	var result: Dictionary = _loader.call("apply_selection_patch", _selection_poly, _selection_patch_params())
	var manual_n := int(result.get("manual", 0))
	var auto_n := int(result.get("auto", 0))
	vegetation_applied.emit()
	_set_status("Patched selection — manual %d, auto %d (heroes untouched)" % [manual_n, auto_n])


func _on_selection_shape_drag_end(_changed: bool = true) -> void:
	if _selection_locked:
		_queue_selection_patch()
		return
	_persist_shape_settings(_changed)


func _on_shape_setting_changed(key: String, value: float) -> void:
	_on_setting_changed(key, value)
	if _selection_locked:
		_queue_selection_patch()
	else:
		_queue_shape_live()


func _queue_shape_live() -> void:
	_shape_live_pending = true
	_shape_live_timer = 0.0
	_update_process_enabled()


func _apply_shape_live() -> void:
	if _loader == null or not _loader.has_method("set_vegetation_settings"):
		return
	_loader.call("set_vegetation_settings", _settings_dict(), true, false)


func _persist_shape_settings(_changed: bool = true) -> void:
	if _shape_live_pending:
		_shape_live_pending = false
		_apply_shape_live()
	if _loader == null or not _loader.has_method("set_vegetation_settings"):
		return
	_loader.call("set_vegetation_settings", _settings_dict(), false, true)


func _on_style_shader_live(key: String, value: float) -> void:
	match key:
		"drape_match_strength":
			_style_drape_match = value
		"hue_jitter":
			_style_hue_jitter = value
		"dither_strength":
			_style_dither = value
	_sync_style_to_loader(false)


func _queue_style_regen() -> void:
	_style_regen_pending = true
	_style_regen_timer = 0.0
	_update_process_enabled()


func _commit_style_changes(regen: bool) -> void:
	if _loader == null or not _loader.has_method("set_vegetation_style"):
		return
	_loader.call("set_vegetation_style", _style_dict(), regen, true)
	_set_status("Map style updated")


func _patch_auto_veg() -> void:
	var poly := _lock_selection_poly_for_advanced()
	if poly.size() < 3:
		_set_status("Select an area first (Select tool + LMB drag)")
		return
	if _loader == null or not _loader.has_method("apply_auto_vegetation_patch"):
		return
	var n: int = int(_loader.call("apply_auto_vegetation_patch", poly, _selection_patch_params()))
	vegetation_applied.emit()
	_set_status("Patched %d auto trees" % n)


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


func _on_setting_changed(key: String, value: float) -> void:
	match key:
		"vertical_offset_m":
			_vertical_offset = value
		"deciduous_canopy_w":
			_decid_canopy_w = value
		"deciduous_canopy_h":
			_decid_canopy_h = value
		"deciduous_trunk_w":
			_decid_trunk_w = value
		"deciduous_trunk_h":
			_decid_trunk_h = value
		"deciduous_bulk_scale":
			_decid_bulk_scale = value
		"deciduous_vertical_offset_m":
			_decid_raise = value
		"pine_card_w":
			_pine_card_w = value
		"pine_card_h":
			_pine_card_h = value
		"pine_trunk_w":
			_pine_trunk_w = value
		"pine_bulk_scale":
			_pine_bulk_scale = value
		"pine_vertical_offset_m":
			_pine_raise = value
		"shrub_card_w":
			_shrub_card_w = value
		"shrub_card_h":
			_shrub_card_h = value
		"shrub_bulk_scale":
			_shrub_bulk_scale = value
		"shrub_vertical_offset_m":
			_shrub_raise = value
		"grass_lawn_card_w":
			_grass_lawn_w = value
		"grass_lawn_card_h":
			_grass_lawn_h = value
		"grass_lawn_bulk_scale":
			_grass_lawn_bulk_scale = value
		"grass_lawn_vertical_offset_m":
			_grass_lawn_raise = value
		"grass_field_card_w":
			_grass_field_w = value
		"grass_field_card_h":
			_grass_field_h = value
		"grass_field_bulk_scale":
			_grass_field_bulk_scale = value
		"grass_field_vertical_offset_m":
			_grass_field_raise = value


func _settings_dict() -> Dictionary:
	return {
		"vertical_offset_m": _vertical_offset,
		"deciduous_canopy_w": _decid_canopy_w,
		"deciduous_canopy_h": _decid_canopy_h,
		"deciduous_trunk_w": _decid_trunk_w,
		"deciduous_trunk_h": _decid_trunk_h,
		"deciduous_bulk_scale": _decid_bulk_scale,
		"deciduous_vertical_offset_m": _decid_raise,
		"pine_card_w": _pine_card_w,
		"pine_card_h": _pine_card_h,
		"pine_trunk_w": _pine_trunk_w,
		"pine_bulk_scale": _pine_bulk_scale,
		"pine_vertical_offset_m": _pine_raise,
		"shrub_card_w": _shrub_card_w,
		"shrub_card_h": _shrub_card_h,
		"shrub_bulk_scale": _shrub_bulk_scale,
		"shrub_vertical_offset_m": _shrub_raise,
		"grass_lawn_card_w": _grass_lawn_w,
		"grass_lawn_card_h": _grass_lawn_h,
		"grass_lawn_bulk_scale": _grass_lawn_bulk_scale,
		"grass_lawn_vertical_offset_m": _grass_lawn_raise,
		"grass_field_card_w": _grass_field_w,
		"grass_field_card_h": _grass_field_h,
		"grass_field_bulk_scale": _grass_field_bulk_scale,
		"grass_field_vertical_offset_m": _grass_field_raise,
	}


func _style_dict() -> Dictionary:
	return {
		"drape_match_strength": _style_drape_match,
		"hue_jitter": _style_hue_jitter,
		"dither_strength": _style_dither,
		"building_exclusion_m": _style_building_excl,
		"road_exclusion_m": _style_road_excl,
		"building_exclusion_enabled": _style_building_excl_enabled,
		"road_exclusion_enabled": _style_road_excl_enabled,
		"pine_albedo_tint": _tint_pine,
		"deciduous_albedo_tint": _tint_deciduous,
		"shrub_albedo_tint": _tint_shrub,
		"grass_lawn_albedo_tint": _tint_grass_lawn,
		"grass_field_albedo_tint": _tint_grass_field,
	}


func _sync_style_to_loader(regen: bool = true) -> void:
	if _loader == null or not _loader.has_method("set_vegetation_style"):
		return
	_loader.call("set_vegetation_style", _style_dict(), regen, false)


func _sync_settings_to_loader(rebuild: bool = true) -> void:
	if _loader == null or not _loader.has_method("set_vegetation_settings"):
		return
	_loader.call("set_vegetation_settings", _settings_dict(), rebuild)


func _load_settings_from_loader() -> void:
	if _loader == null or not _loader.has_method("get_vegetation_settings"):
		return
	var s: Dictionary = _loader.call("get_vegetation_settings")
	_vertical_offset = float(s.get("vertical_offset_m", 0.0))
	_decid_canopy_w = float(s.get("deciduous_canopy_w", 11.0))
	_decid_canopy_h = float(s.get("deciduous_canopy_h", 4.5))
	_decid_trunk_w = float(s.get("deciduous_trunk_w", 0.45))
	_decid_trunk_h = float(s.get("deciduous_trunk_h", 4.5))
	_decid_bulk_scale = float(s.get("deciduous_bulk_scale", 1.35))
	_decid_raise = float(s.get("deciduous_vertical_offset_m", 0.0))
	_pine_card_w = float(s.get("pine_card_w", 0.85))
	_pine_card_h = float(s.get("pine_card_h", 4.5))
	_pine_trunk_w = float(s.get("pine_trunk_w", 0.24))
	_pine_bulk_scale = float(s.get("pine_bulk_scale", 1.0))
	_pine_raise = float(s.get("pine_vertical_offset_m", 0.0))
	_shrub_card_w = float(s.get("shrub_card_w", 1.4))
	_shrub_card_h = float(s.get("shrub_card_h", 1.15))
	_shrub_bulk_scale = float(s.get("shrub_bulk_scale", 1.0))
	_shrub_raise = float(s.get("shrub_vertical_offset_m", 0.0))
	_grass_lawn_w = float(s.get("grass_lawn_card_w", 0.08))
	_grass_lawn_h = float(s.get("grass_lawn_card_h", 0.42))
	_grass_lawn_bulk_scale = float(s.get("grass_lawn_bulk_scale", 1.0))
	_grass_lawn_raise = float(s.get("grass_lawn_vertical_offset_m", 0.0))
	_grass_field_w = float(s.get("grass_field_card_w", 0.11))
	_grass_field_h = float(s.get("grass_field_card_h", 0.88))
	_grass_field_bulk_scale = float(s.get("grass_field_bulk_scale", 1.0))
	_grass_field_raise = float(s.get("grass_field_vertical_offset_m", 0.0))
	if _loader.has_method("get_vegetation_style"):
		var st: Dictionary = _loader.call("get_vegetation_style")
		_style_drape_match = float(st.get("drape_match_strength", 0.35))
		_style_hue_jitter = float(st.get("hue_jitter", 0.05))
		_style_dither = float(st.get("dither_strength", 1.0))
		_style_building_excl = float(st.get("building_exclusion_m", 0.0))
		_style_road_excl = float(st.get("road_exclusion_m", 0.0))
		_style_building_excl_enabled = bool(st.get("building_exclusion_enabled", true))
		_style_road_excl_enabled = bool(st.get("road_exclusion_enabled", true))
		_tint_pine = st.get("pine_albedo_tint", Color.WHITE)
		_tint_deciduous = st.get("deciduous_albedo_tint", Color.WHITE)
		_tint_shrub = st.get("shrub_albedo_tint", Color.WHITE)
		_tint_grass_lawn = st.get("grass_lawn_albedo_tint", Color.WHITE)
		_tint_grass_field = st.get("grass_field_albedo_tint", Color.WHITE)
