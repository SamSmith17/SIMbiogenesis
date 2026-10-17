extends Control

## Parametric Mars-College pallet-rack structure builder with a SubViewport studio
## preview. Drives PalletRackBuilder from catalog dropdowns, layout sliders, level
## / deck / variant / wall controls, and places the result via PlacedPropService
## as model_id "pallet_rack" + rack_spec extras.

const MODAL_NAME := "pallet_rack_builder"
const REBUILD_DEBOUNCE_S := 0.10

const C_BG := Color(0.039, 0.055, 0.098, 0.85)
const C_PANEL := Color(0.082, 0.114, 0.208, 1.0)
const C_BORDER := Color(0.227, 0.290, 0.420, 1.0)
const C_PRIMARY := Color(0.133, 0.827, 0.933, 1.0)
const C_TEXT := Color(0.886, 0.910, 0.941, 1.0)
const C_TEXT_S := Color(0.580, 0.639, 0.722, 1.0)

var _loader: Node = null
var _active := false
var _spec: Dictionary = {}

var _dim: ColorRect = null
var _panel: PanelContainer = null
var _vp_container: SubViewportContainer = null
var _viewport: SubViewport = null
var _studio: Node3D = null
var _holder: Node3D = null
var _camera: Camera3D = null

var _depth_opt: OptionButton = null
var _height_opt: OptionButton = null
var _beam_opt: OptionButton = null
var _bay_slider: HSlider = null
var _bay_val: Label = null
var _col_slider: HSlider = null
var _col_val: Label = null
var _spacing_slider: HSlider = null
var _spacing_val: Label = null
var _levels_spin: SpinBox = null
var _level_box: VBoxContainer = null
var _level_spins: Array = []
var _roof_chk: CheckBox = null
var _decked_chk: CheckBox = null
var _lumber_opt: OptionButton = null
var _joist_opt: OptionButton = null
var _stepped_spin: SpinBox = null
var _u_chk: CheckBox = null
var _u_row: HBoxContainer = null
var _u_bays_spin: SpinBox = null
var _u_cols_spin: SpinBox = null
var _wall_chks: Dictionary = {}
var _collide_chk: CheckBox = null
var _bom_lbl: Label = null
var _title_lbl: Label = null
var _place_btn: Button = null
var _apply_btn: Button = null
var _delete_btn: Button = null

## Non-empty while editing a placed rack in place ("Apply changes" rebuilds it).
var _bound_prop_id := ""
var _space_row: NpcSpaceTagRow

var _rebuild_pending := false
var _rebuild_timer := 0.0
## Light rebuild = geometry + highlight only (no UI re-read/BOM), used mid-drag
## so the preview glides at frame rate instead of stepping on the debounce.
var _rebuild_light := false
var _suppress := false
## Frame the camera to the structure only on the first build after opening — not
## on every edit, so the user's orbit/zoom is preserved while tweaking params.
var _framed := false

# Orbit camera state (RMB-drag).
var _yaw := 0.7
var _pitch := 0.5
var _dist := 12.0
var _target := Vector3(0, 2.0, 0)
var _dragging := false

# ---- Per-component editor state ----
## Small dead-zone so a click reads as a select, a nudge reads as a drag.
const DRAG_THRESHOLD_PX := 1.5
const MANIP_KINDS := ["deck", "step", "beam", "wall_sheet"]
## Fraction of the deck's far Z edge that counts as the resize grab band.
const RESIZE_EDGE_FRAC := 0.28
const UNDO_LIMIT := 40

var _sel_hud: Label = null
var _undo_btn: Button = null
var _steps_btn: Button = null
var _highlight_holder: Node3D = null
## Pick registry for the currently-built spec (refreshed on every rebuild).
var _pick_cache: Array = []
var _hover_group: Array = []
var _selection: Array = []
## Undo history of override snapshots (cell/beam/wall).
var _undo_stack: Array = []
## When true, LMB drops a step section on the cell slot under the cursor.
var _place_step_mode := false

# LMB gesture state.
var _lmb_down := false
var _lmb_press_pos := Vector2.ZERO
var _press_shift := false
var _manip_active := false
var _manip_mode := ""          # "deck_move" | "deck_resize" | "beam_move"
var _manip_targets: Array = []  # component ids being moved together
var _manip_start: Dictionary = {}  # id -> starting values


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	set_process(false)
	_spec = PalletRackBuilder.default_spec()
	_build_ui()


func bind_loader(loader: Node) -> void:
	_loader = loader


func open() -> void:
	if _active:
		return
	_bound_prop_id = ""
	_spec = PalletRackBuilder.default_spec()
	# Nothing placed yet, so there is no target to tag.
	if _space_row != null:
		_space_row.bind_prop(_loader, "")
	_sync_controls()
	_apply_edit_mode_ui()
	_activate()


## Edit an already-placed pallet rack in place. "Apply changes" rebuilds that
## prop from the edited spec; "Place in world" stays available for a fresh copy.
func open_for_prop(prop_id: String) -> void:
	if _active or prop_id.is_empty():
		return
	var rec := _prop_record(prop_id)
	var spec: Dictionary = rec.get("rack_spec", {}) as Dictionary
	if spec.is_empty() and rec.has("record_extra"):
		spec = (rec.get("record_extra", {}) as Dictionary).get("rack_spec", {}) as Dictionary
	_bound_prop_id = prop_id
	_spec = PalletRackBuilder.resolve_spec(spec)
	if _space_row != null:
		_space_row.bind_prop(_loader, prop_id)
	_sync_controls()
	_apply_edit_mode_ui()
	_activate()


func _activate() -> void:
	_framed = false
	_selection.clear()
	_hover_group.clear()
	_undo_stack.clear()
	_place_step_mode = false
	_reset_gesture()
	_active = true
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(true)
	CursorController.request_modal(MODAL_NAME, Callable(self, "close"))
	_queue_rebuild(true)


func _apply_edit_mode_ui() -> void:
	var editing := not _bound_prop_id.is_empty()
	if _title_lbl != null:
		_title_lbl.text = "Edit Pallet Rack" if editing else "Pallet Rack Structure Builder"
	if _apply_btn != null:
		_apply_btn.visible = editing
	if _delete_btn != null:
		_delete_btn.visible = editing


func close() -> void:
	if not _active:
		return
	_active = false
	_bound_prop_id = ""
	_set_step_mode(false)
	_undo_stack.clear()
	_update_undo_btn()
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)
	CursorController.release_modal(MODAL_NAME)


func _process(delta: float) -> void:
	if not _rebuild_pending:
		return
	_rebuild_timer -= delta
	if _rebuild_timer <= 0.0:
		_rebuild_pending = false
		var light := _rebuild_light
		_rebuild_light = false
		_rebuild_preview(light)


# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	# Full-screen modal (mirrors the Linkage Lab layout): dim backdrop, a top bar
	# with the title + primary actions, then a large 3D viewport beside a scrollable
	# parameter sidebar.
	_dim = ColorRect.new()
	_dim.color = C_BG
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_dim)

	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 10)
	root.add_theme_constant_override("separation", 8)
	add_child(root)

	root.add_child(_build_topbar())

	var main_row := HBoxContainer.new()
	main_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_row.add_theme_constant_override("separation", 8)
	root.add_child(main_row)

	var vp_frame := PanelContainer.new()
	vp_frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vp_frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vp_frame.add_theme_stylebox_override("panel", _card_style())
	main_row.add_child(vp_frame)
	_vp_container = SubViewportContainer.new()
	_vp_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vp_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_vp_container.stretch = true
	_vp_container.gui_input.connect(_on_viewport_input)
	vp_frame.add_child(_vp_container)
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(960, 720)
	_viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE  # idle while the modal is hidden
	_viewport.own_world_3d = true
	_vp_container.add_child(_viewport)
	_build_studio_world()

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(340, 0)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var side_frame := PanelContainer.new()
	side_frame.add_theme_stylebox_override("panel", _card_style())
	side_frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_row.add_child(side_frame)
	side_frame.add_child(scroll)
	var side := VBoxContainer.new()
	side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	side.custom_minimum_size.x = 300
	side.add_theme_constant_override("separation", 6)
	scroll.add_child(side)

	_section(side, "Rack system")
	_depth_opt = _add_option(side, "Upright depth", PalletRackBuilder.DEPTH_OPTIONS_IN,
		"\"", int(_spec["upright_depth_in"]))
	_height_opt = _add_option(side, "Upright height", PalletRackBuilder.HEIGHT_OPTIONS_FT,
		"'", int(_spec["upright_height_ft"]))
	_beam_opt = _add_option(side, "Beam span", PalletRackBuilder.BEAM_OPTIONS_FT,
		"'", int(_spec["beam_span_ft"]))

	_section(side, "Layout")
	var bay_pack := _add_slider(side, "Bays across", 1, 10, int(_spec["bay_count"]))
	_bay_slider = bay_pack[0]
	_bay_val = bay_pack[1]
	var col_pack := _add_slider(side, "Columns (decked spans)", 1, 10, int(_spec["column_count"]))
	_col_slider = col_pack[0]
	_col_val = col_pack[1]
	var gap_pack := _add_float_slider(side, "Assembly spacing", 4.0, 20.0,
		PalletRackBuilder.HALF_PANEL_FT, float(_spec["row_gap_ft"]), "'")
	_spacing_slider = gap_pack[0]
	_spacing_val = gap_pack[1]

	_section(side, "Levels")
	_levels_spin = _add_spin(side, "Deck levels", 1, 3, 1, float(_spec["deck_levels"]))
	_levels_spin.value_changed.connect(func(_v: float) -> void: _rebuild_level_spins())
	_level_box = VBoxContainer.new()
	_level_box.add_theme_constant_override("separation", 4)
	side.add_child(_level_box)
	_roof_chk = _add_check(side, "Rooftop deck", bool(_spec["roof_deck"]))

	_section(side, "Decking")
	_decked_chk = _add_check(side, "Deck the columns (2x4 + plywood)", bool(_spec["decked"]))
	_lumber_opt = _add_option(side, "Joist stock length", PalletRackBuilder.LUMBER_OPTIONS_FT,
		"'", int(_spec["lumber_len_ft"]))
	_joist_opt = _add_option(side, "Joist spacing", PalletRackBuilder.JOIST_SPACING_OPTIONS_IN,
		"\" o.c.", int(_spec["joist_spacing_in"]))

	_section(side, "Variants")
	_stepped_spin = _add_spin(side, "Stepped module (0 = none)", 0, 10, 1,
		float(_spec["stepped_module"]))
	_u_chk = _add_check(side, "U-shape (open centre bay)", bool(_spec["u_shape"]))
	_u_row = HBoxContainer.new()
	_u_row.add_theme_constant_override("separation", 8)
	side.add_child(_u_row)
	var ub := VBoxContainer.new()
	ub.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_u_row.add_child(ub)
	_u_bays_spin = _add_spin(ub, "Open bays", 1, 10, 1, float(_spec["u_open_bays"]))
	var uc := VBoxContainer.new()
	uc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_u_row.add_child(uc)
	_u_cols_spin = _add_spin(uc, "Open cols", 1, 10, 1, float(_spec["u_open_cols"]))

	_section(side, "Placement")
	_collide_chk = _add_check(side, "Solid collision (walk into it when off)", true)

	_section(side, "Walls (4x8 plywood)")
	var wall_row := GridContainer.new()
	wall_row.columns = 2
	side.add_child(wall_row)
	for face in ["front", "back", "left", "right"]:
		_wall_chks[face] = _add_check(wall_row, face.capitalize(),
			bool((_spec["walls"] as Dictionary).get(face, false)))

	_section(side, "Bill of materials")
	_bom_lbl = Label.new()
	_bom_lbl.add_theme_color_override("font_color", C_TEXT_S)
	_bom_lbl.add_theme_font_size_override("font_size", 11)
	_bom_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	side.add_child(_bom_lbl)

	_rebuild_level_spins()


func _build_topbar() -> Control:
	var bar := PanelContainer.new()
	bar.add_theme_stylebox_override("panel", _card_style())
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	bar.add_child(row)

	_title_lbl = Label.new()
	_title_lbl.text = "Pallet Rack Structure Builder"
	_title_lbl.add_theme_color_override("font_color", C_TEXT)
	_title_lbl.add_theme_font_size_override("font_size", 18)
	_title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_title_lbl)

	_sel_hud = Label.new()
	_sel_hud.text = ""
	_sel_hud.add_theme_color_override("font_color", C_PRIMARY)
	_sel_hud.add_theme_font_size_override("font_size", 11)
	_sel_hud.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_sel_hud)

	var hint := Label.new()
	hint.text = "RMB: orbit  •  LMB: select/drag deck strip  •  Shift+LMB: multi  •  Del: remove"
	hint.add_theme_color_override("font_color", C_TEXT_S)
	hint.add_theme_font_size_override("font_size", 11)
	hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(hint)

	# Pallet racks route here rather than to the generic prop drawer, so the tag
	# control has to live in this modal too (see npc_space_tag_row.gd). Only
	# meaningful when editing a placed rack, so it hides itself for a fresh one.
	_space_row = NpcSpaceTagRow.new()
	row.add_child(_space_row)

	_steps_btn = Button.new()
	_steps_btn.text = "Add steps"
	_steps_btn.toggle_mode = true
	_steps_btn.focus_mode = Control.FOCUS_NONE
	_steps_btn.toggled.connect(func(on: bool) -> void: _set_step_mode(on))
	row.add_child(_steps_btn)

	_undo_btn = Button.new()
	_undo_btn.text = "Undo"
	_undo_btn.focus_mode = Control.FOCUS_NONE
	_undo_btn.disabled = true
	_undo_btn.pressed.connect(_undo)
	row.add_child(_undo_btn)

	_apply_btn = Button.new()
	_apply_btn.text = "Apply changes"
	_apply_btn.focus_mode = Control.FOCUS_NONE
	_apply_btn.add_theme_color_override("font_color", C_PRIMARY)
	_apply_btn.visible = false
	_apply_btn.pressed.connect(_on_apply_to_prop)
	row.add_child(_apply_btn)

	_delete_btn = Button.new()
	_delete_btn.text = "Delete"
	_delete_btn.focus_mode = Control.FOCUS_NONE
	_delete_btn.add_theme_color_override("font_color", Color(0.94, 0.45, 0.45))
	_delete_btn.visible = false
	_delete_btn.pressed.connect(_on_delete_prop)
	row.add_child(_delete_btn)

	_place_btn = Button.new()
	_place_btn.text = "Place in world"
	_place_btn.focus_mode = Control.FOCUS_NONE
	_place_btn.add_theme_color_override("font_color", C_PRIMARY)
	_place_btn.pressed.connect(_on_place)
	row.add_child(_place_btn)

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.pressed.connect(close)
	row.add_child(close_btn)
	return bar


func _card_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_PANEL
	sb.border_color = C_BORDER
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	return sb


func _section(parent: Control, text: String) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", C_PRIMARY)
	lbl.add_theme_font_size_override("font_size", 12)
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_top", 6)
	m.add_child(lbl)
	parent.add_child(m)


func _add_option(parent: Control, label: String, values: Array, suffix: String,
		current: int) -> OptionButton:
	var lbl := Label.new()
	lbl.text = label
	lbl.add_theme_color_override("font_color", C_TEXT_S)
	lbl.add_theme_font_size_override("font_size", 11)
	parent.add_child(lbl)
	var opt := OptionButton.new()
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt.focus_mode = Control.FOCUS_NONE
	for i in values.size():
		var v := int(values[i])
		opt.add_item(str(v) + suffix)
		opt.set_item_metadata(i, v)
		if v == current:
			opt.select(i)
	opt.item_selected.connect(func(_i: int) -> void: _on_control_changed())
	parent.add_child(opt)
	return opt


func _add_slider(parent: Control, label: String, mn: int, mx: int,
		val: int) -> Array:
	var head := HBoxContainer.new()
	head.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var lbl := Label.new()
	lbl.text = label
	lbl.add_theme_color_override("font_color", C_TEXT_S)
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(lbl)
	var val_lbl := Label.new()
	val_lbl.text = str(val)
	val_lbl.add_theme_color_override("font_color", C_TEXT)
	val_lbl.add_theme_font_size_override("font_size", 11)
	head.add_child(val_lbl)
	parent.add_child(head)
	var sl := HSlider.new()
	sl.min_value = mn
	sl.max_value = mx
	sl.step = 1
	sl.value = val
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl.focus_mode = Control.FOCUS_NONE
	sl.value_changed.connect(func(v: float) -> void:
		val_lbl.text = str(int(v))
		_on_layout_changed())
	parent.add_child(sl)
	return [sl, val_lbl]


func _add_float_slider(parent: Control, label: String, mn: float, mx: float,
		step: float, val: float, suffix: String = "") -> Array:
	var head := HBoxContainer.new()
	head.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var lbl := Label.new()
	lbl.text = label
	lbl.add_theme_color_override("font_color", C_TEXT_S)
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(lbl)
	var val_lbl := Label.new()
	val_lbl.text = _fmt_num(val) + suffix
	val_lbl.add_theme_color_override("font_color", C_TEXT)
	val_lbl.add_theme_font_size_override("font_size", 11)
	head.add_child(val_lbl)
	parent.add_child(head)
	var sl := HSlider.new()
	sl.min_value = mn
	sl.max_value = mx
	sl.step = step
	sl.value = val
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl.focus_mode = Control.FOCUS_NONE
	sl.value_changed.connect(func(v: float) -> void:
		val_lbl.text = _fmt_num(v) + suffix
		_on_control_changed())
	parent.add_child(sl)
	return [sl, val_lbl]


func _add_spin(parent: Control, label: String, mn: float, mx: float,
		step: float, val: float) -> SpinBox:
	var lbl := Label.new()
	lbl.text = label
	lbl.add_theme_color_override("font_color", C_TEXT_S)
	lbl.add_theme_font_size_override("font_size", 11)
	parent.add_child(lbl)
	var spin := SpinBox.new()
	spin.min_value = mn
	spin.max_value = mx
	spin.step = step
	spin.value = val
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spin.value_changed.connect(func(_v: float) -> void: _on_control_changed())
	parent.add_child(spin)
	return spin


func _add_check(parent: Control, label: String, on: bool) -> CheckBox:
	var chk := CheckBox.new()
	chk.text = label
	chk.button_pressed = on
	chk.focus_mode = Control.FOCUS_NONE
	chk.add_theme_color_override("font_color", C_TEXT)
	chk.add_theme_font_size_override("font_size", 11)
	chk.toggled.connect(func(_p: bool) -> void: _on_control_changed())
	parent.add_child(chk)
	return chk


func _rebuild_level_spins() -> void:
	if _level_box == null:
		return
	var n := int(_levels_spin.value)
	var prev: Array = []
	for sp in _level_spins:
		prev.append(float((sp as SpinBox).value))
	for c in _level_box.get_children():
		c.queue_free()
	_level_spins.clear()
	var max_h := float(_selected_meta(_height_opt, 16))
	for i in range(n):
		var v: float = prev[i] if i < prev.size() else PalletRackBuilder._default_level_height_ft(i)
		var sp := _add_spin(_level_box, "  Level %d height (ft)" % (i + 1),
			0.25, maxf(max_h - 0.5, 0.25), 0.25, clampf(float(v), 0.25, max_h))
		_level_spins.append(sp)
	_on_control_changed()


func _on_layout_changed() -> void:
	# Keep dependent control ranges in sync with bay/column counts.
	if _stepped_spin:
		_stepped_spin.max_value = _col_slider.value
	if _u_bays_spin:
		_u_bays_spin.max_value = _bay_slider.value
	if _u_cols_spin:
		_u_cols_spin.max_value = _col_slider.value
	_on_control_changed()


func _on_control_changed() -> void:
	if _suppress:
		return
	if _u_row:
		_u_row.visible = _u_chk.button_pressed
	_queue_rebuild(false)


func _on_viewport_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			# RMB is ALWAYS the camera orbit — it never manipulates geometry.
			_dragging = mb.pressed
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_dist = maxf(3.0, _dist - 1.5)
			_update_camera()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_dist = minf(80.0, _dist + 1.5)
			_update_camera()
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if _place_step_mode:
				if mb.pressed:
					_place_step_at(mb.position)
			elif mb.pressed:
				_begin_gesture(mb.position, mb.shift_pressed)
			else:
				_end_gesture(mb.position)
	elif e is InputEventMouseMotion:
		var mm := e as InputEventMouseMotion
		if _dragging:
			_yaw -= mm.relative.x * 0.01
			_pitch = clampf(_pitch - mm.relative.y * 0.01, 0.05, 1.4)
			_update_camera()
		elif _place_step_mode:
			_update_step_ghost(mm.position)
		elif _lmb_down and not _manip_mode.is_empty():
			_update_manip(mm.position)
		else:
			_update_hover(mm.position)


## Keyboard shortcuts. Uses _input (not _unhandled_key_input) so the modal
## reliably receives Delete/Ctrl+Z even when a sidebar control had focus, but
## skips while a text field is being edited.
func _input(e: InputEvent) -> void:
	if not _active or not (e is InputEventKey):
		return
	var ke := e as InputEventKey
	if not ke.pressed or ke.echo:
		return
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return
	if ke.keycode == KEY_Z and ke.ctrl_pressed:
		_undo()
		get_viewport().set_input_as_handled()
	elif ke.keycode == KEY_DELETE or ke.keycode == KEY_BACKSPACE:
		_delete_selection()
		get_viewport().set_input_as_handled()
	elif ke.keycode == KEY_S and not ke.ctrl_pressed:
		_toggle_step_on_selection()
		get_viewport().set_input_as_handled()
	elif ke.keycode == KEY_ESCAPE:
		# Esc backs out one layer at a time: step tool → selection → (modal close).
		if _place_step_mode:
			_set_step_mode(false)
			get_viewport().set_input_as_handled()
		elif not _selection.is_empty():
			_selection.clear()
			_refresh_highlight()
			_update_sel_hud()
			get_viewport().set_input_as_handled()


## Flip the selected deck cells between a flat deck and a step section (a step
## rises from the level below). Applies to every selected cell.
func _toggle_step_on_selection() -> void:
	var changed := false
	_push_undo()
	for id in _selection:
		if not str(id).begins_with("cell:"):
			continue
		var comp := _comp_by_id(id)
		if comp.is_empty():
			continue
		var new_kind := "step" if str(comp.get("kind", "deck")) != "step" else "deck"
		_set_cell_override(_id_key(id), "kind", new_kind)
		changed = true
	if changed:
		_queue_rebuild(true)
	else:
		_undo_stack.pop_back()  # nothing changed; drop the snapshot
		_update_undo_btn()


# ---------------------------------------------------------------------------
# Ray picking (pure math against the pick registry — no physics)
# ---------------------------------------------------------------------------

## Map a click in the SubViewportContainer's local space into the SubViewport's
## pixel space so Camera3D.project_ray_* aims where the user actually clicked.
func _to_viewport_pos(local_pos: Vector2) -> Vector2:
	if _vp_container == null or _viewport == null:
		return local_pos
	var cont := _vp_container.size
	if cont.x <= 0.0 or cont.y <= 0.0:
		return local_pos
	return local_pos * (Vector2(_viewport.size) / cont)


func _pick_at(local_pos: Vector2, kinds: Array = []) -> Dictionary:
	if _camera == null:
		return {}
	var vp := _to_viewport_pos(local_pos)
	var origin := _camera.project_ray_origin(vp)
	var dir := _camera.project_ray_normal(vp)
	return PalletRackBuilder.pick_nearest(_pick_cache, origin, dir, kinds)


## World Z where the camera ray through `local_pos` crosses the plane y=plane_y.
func _ray_plane_z(local_pos: Vector2, plane_y: float) -> float:
	if _camera == null:
		return NAN
	var vp := _to_viewport_pos(local_pos)
	var o := _camera.project_ray_origin(vp)
	var d := _camera.project_ray_normal(vp)
	if absf(d.y) < 1e-6:
		return NAN
	var t := (plane_y - o.y) / d.y
	if t < 0.0:
		return NAN
	return (o + d * t).z


func _comp_by_id(id: String) -> Dictionary:
	for comp in _pick_cache:
		if str(comp["id"]) == id:
			return comp
	return {}


func _update_hover(local_pos: Vector2) -> void:
	var comp := _pick_at(local_pos, MANIP_KINDS)
	var group := _pick_group(comp)
	# Cursor hint: resize arrows over a deck's far edge, move arrows over a
	# draggable body, default arrow over nothing.
	if _vp_container != null:
		var shape := Control.CURSOR_ARROW
		if not comp.is_empty():
			var k := str(comp.get("kind", ""))
			if (k == "deck" or k == "step") and _near_cell_z_edge(comp, local_pos):
				shape = Control.CURSOR_BDIAGSIZE
			elif k == "deck" or k == "step" or k == "beam":
				shape = Control.CURSOR_MOVE
			elif k == "wall_sheet":
				shape = Control.CURSOR_POINTING_HAND
		_vp_container.mouse_default_cursor_shape = shape
	if group != _hover_group:
		_hover_group = group
		_refresh_highlight()


## The set of ids a pick resolves to: a whole deck strip (column of cells + its
## two inner beam lines) for a deck/step, otherwise just the picked id.
func _pick_group(comp: Dictionary) -> Array:
	if comp.is_empty():
		return []
	var kind := str(comp.get("kind", ""))
	if kind == "deck" or kind == "step":
		return _strip_of(comp)
	return [str(comp["id"])]


## All ids in the deck strip of `comp`: every cell in its (col, level) across
## bays, plus the two beam lines that bound its column gap on the inside (so the
## plywood, joists — which follow cell height — and crossbeams move as one unit).
func _strip_of(comp: Dictionary) -> Array:
	var col := int(comp.get("col", -1))
	var lvl := int(comp.get("level", -1))
	if col < 0 or lvl < 0:
		return [str(comp["id"])]
	var cols := int(_spec.get("column_count", 1))
	var last_row := cols  # rows = cols + 1; row index of the rear frame line
	var ids: Array = []
	for c in _pick_cache:
		var k := str(c.get("kind", ""))
		if (k == "deck" or k == "step") and int(c.get("col", -1)) == col \
				and int(c.get("level", -1)) == lvl:
			ids.append(str(c["id"]))
		elif k == "beam" and int(c.get("level", -1)) == lvl:
			var row := int(c.get("row", -1))
			var side := int(c.get("side", -1))
			# Inner rails the deck rests on, PLUS the outer rail the edge deck
			# overhangs (front frame's front beam / rear frame's back beam) so an
			# edge strip moves together with every beam beneath it.
			var inner := (row == col and side == 1) or (row == col + 1 and side == 0)
			var edge_front := col == 0 and row == 0 and side == 0
			var edge_back := col == cols - 1 and row == last_row and side == 1
			if inner or edge_front or edge_back:
				ids.append(str(c["id"]))
	return ids


# ---------------------------------------------------------------------------
# Gestures: LMB click = select, LMB drag = manipulate
# ---------------------------------------------------------------------------

func _reset_gesture() -> void:
	_lmb_down = false
	_manip_active = false
	_manip_mode = ""
	_manip_targets = []
	_manip_start = {}


func _begin_gesture(local_pos: Vector2, shift: bool) -> void:
	_lmb_down = true
	_lmb_press_pos = local_pos
	_press_shift = shift
	_manip_active = false
	_manip_mode = ""
	_manip_targets = []
	_manip_start = {}
	var comp := _pick_at(local_pos, MANIP_KINDS)
	if comp.is_empty():
		return
	var kind := str(comp["kind"])
	var id := str(comp["id"])
	if kind == "beam":
		_manip_mode = "beam_move"
	elif kind == "deck" or kind == "step":
		_manip_mode = "deck_resize" if _near_cell_z_edge(comp, local_pos) else "deck_move"
	else:
		return  # wall sheets: click select / delete only, no drag
	# Drag the whole current selection if the pressed item belongs to it; else
	# the pressed item's natural unit (a deck drags its full strip + beams).
	if _selection.has(id) and _selection.size() > 1:
		_manip_targets = _compatible_targets(_manip_mode)
	elif _manip_mode == "beam_move":
		_manip_targets = [id]
	elif _manip_mode == "deck_resize":
		_manip_targets = _strip_cells_only(comp)
	else:
		_manip_targets = _strip_of(comp)
	_capture_manip_start()


func _end_gesture(local_pos: Vector2) -> void:
	if _manip_active:
		_finalize_manip()
	else:
		_click_select(local_pos)
	_reset_gesture()


func _click_select(local_pos: Vector2) -> void:
	var comp := _pick_at(local_pos, MANIP_KINDS)
	var group := _pick_group(comp)
	if group.is_empty():
		if not _press_shift:
			_selection.clear()
	elif _press_shift:
		# Toggle the whole group in/out of the selection set together.
		var present := true
		for gid in group:
			if not _selection.has(gid):
				present = false
				break
		for gid in group:
			if present:
				_selection.erase(gid)
			elif not _selection.has(gid):
				_selection.append(gid)
	else:
		_selection = group.duplicate()
	_refresh_highlight()
	_update_sel_hud()


## Cell ids of the strip only (deck-edge resize changes depth, never beams).
func _strip_cells_only(comp: Dictionary) -> Array:
	var out: Array = []
	for id in _strip_of(comp):
		if str(id).begins_with("cell:"):
			out.append(id)
	return out


## True when the click sits in the far-Z grab band of a deck cell (edge resize).
func _near_cell_z_edge(comp: Dictionary, local_pos: Vector2) -> bool:
	var z0 := float(comp.get("z0", 0.0))
	var z1 := float(comp.get("z1", 0.0))
	if z1 <= z0:
		return false
	var box: AABB = comp["aabb"]
	var plane_y := box.position.y + box.size.y
	var zw := _ray_plane_z(local_pos, plane_y)
	if is_nan(zw):
		return false
	var band := (z1 - z0) * RESIZE_EDGE_FRAC
	return zw >= z1 - band


func _compatible_targets(mode: String) -> Array:
	var out: Array = []
	for id in _selection:
		if mode == "beam_move":
			if str(id).begins_with("beam:"):
				out.append(id)
		elif mode == "deck_resize":
			if str(id).begins_with("cell:"):
				out.append(id)
		else:  # deck_move: cells (height) AND beams (dy) move together
			if str(id).begins_with("cell:") or str(id).begins_with("beam:"):
				out.append(id)
	return out


func _capture_manip_start() -> void:
	_manip_start = {}
	for id in _manip_targets:
		var comp := _comp_by_id(id)
		if comp.is_empty():
			continue
		if str(id).begins_with("beam:"):
			_manip_start[id] = {"dy_in": float(comp.get("dy_in", 0.0))}
		else:
			var z0 := float(comp.get("z0", 0.0))
			var z1 := float(comp.get("z1", 0.0))
			var full_units := maxi(1, int(round((z1 - z0) / PalletRackBuilder.FT
				/ PalletRackBuilder.HALF_PANEL_FT)))
			var du := int(comp.get("depth_units", -1))
			_manip_start[id] = {
				"height_ft": float(comp.get("height_ft", 0.0)),
				"z0": z0, "full_units": full_units,
				"start_units": du if du >= 0 else full_units,
			}


func _update_manip(local_pos: Vector2) -> void:
	var d := local_pos - _lmb_press_pos
	if not _manip_active:
		if d.length() < DRAG_THRESHOLD_PX:
			return
		_manip_active = true
		_push_undo()  # one undo entry per drag, capturing the pre-drag state
		# Make the moving unit the live selection so it's obvious what's dragging.
		_selection = _manip_targets.duplicate()
	match _manip_mode:
		"deck_move", "beam_move":
			_preview_vertical(-d.y)
		"deck_resize":
			_preview_deck_resize(local_pos)
	_update_manip_hud()
	_queue_rebuild(true, true)  # immediate + light → glides at frame rate


## Live readout of the value being dragged (before the release snap).
func _update_manip_hud() -> void:
	if _sel_hud == null or _manip_targets.is_empty():
		return
	var id := str(_manip_targets[0])
	var key := _id_key(id)
	match _manip_mode:
		"deck_move":
			var cov: Dictionary = _spec.get("cell_overrides", {})
			var h := float((cov.get(key, {}) as Dictionary).get("height_ft", 0.0))
			_sel_hud.text = "Deck height: %s  (snaps to 1\" on release)" % _fmt_ft_in(h)
		"beam_move":
			var bov: Dictionary = _spec.get("beam_overrides", {})
			var dy := float((bov.get(key, {}) as Dictionary).get("dy_in", 0.0))
			_sel_hud.text = "Beam offset: %+.1f\"  (snaps to 1\" on release)" % dy
		"deck_resize":
			var cov2: Dictionary = _spec.get("cell_overrides", {})
			var du := int((cov2.get(key, {}) as Dictionary).get("depth_units", 0))
			var depth_ft := du * PalletRackBuilder.HALF_PANEL_FT if du > 0 \
				else _strip_full_depth_ft(id)
			_sel_hud.text = "Deck depth: %d ft" % int(round(depth_ft))


## Feet → e.g. "8' 3\"" using whole inches.
func _fmt_ft_in(ft: float) -> String:
	var total_in := int(round(ft * 12.0))
	return "%d' %d\"" % [total_in / 12, total_in % 12]


func _strip_full_depth_ft(id: String) -> float:
	var st: Dictionary = _manip_start.get(id, {})
	return float(st.get("full_units", 0)) * PalletRackBuilder.HALF_PANEL_FT


## Vertical drag → raise/lower. `px` up-positive; scaled by camera distance so
## the feel is zoom-independent. Applied live (unsnapped); snapped on release.
## Cells move via height_ft, beams via dy_in — by the SAME world delta — so a
## deck strip and its crossbeams rise/lower as one unit.
func _preview_vertical(px: float) -> void:
	var dy_world := px * _dist * 0.0055
	var max_ft := float(_spec["upright_height_ft"])
	for id in _manip_targets:
		var st: Dictionary = _manip_start.get(id, {})
		if st.is_empty():
			continue
		if str(id).begins_with("beam:"):
			_set_beam_override(_id_key(id), "dy_in",
				float(st["dy_in"]) + dy_world / PalletRackBuilder.IN)
		else:
			var h := clampf(float(st["height_ft"]) + dy_world / PalletRackBuilder.FT,
				0.25, max_ft - 0.25)
			_set_cell_override(_id_key(id), "height_ft", h)


func _preview_deck_resize(local_pos: Vector2) -> void:
	for id in _manip_targets:
		var st: Dictionary = _manip_start.get(id, {})
		if st.is_empty():
			continue
		var comp := _comp_by_id(id)
		var plane_y := float(_spec_height_ft_from_start(st)) * PalletRackBuilder.FT \
			+ PalletRackBuilder.JOIST_H
		if not comp.is_empty():
			var box: AABB = comp["aabb"]
			plane_y = box.position.y + box.size.y
		var zw := _ray_plane_z(local_pos, plane_y)
		var full_units := int(st["full_units"])
		var units := full_units
		if not is_nan(zw):
			var z0 := float(st["z0"])
			var span_units := (zw - z0) / PalletRackBuilder.FT / PalletRackBuilder.HALF_PANEL_FT
			units = clampi(int(round(span_units)), 1, full_units)
		if units >= full_units:
			_erase_cell_field(_id_key(id), "depth_units")
		else:
			_set_cell_override(_id_key(id), "depth_units", units)


func _spec_height_ft_from_start(st: Dictionary) -> float:
	return float(st.get("height_ft", 0.0))


func _finalize_manip() -> void:
	match _manip_mode:
		"deck_move":
			for id in _manip_targets:
				var key := _id_key(id)
				var cov: Dictionary = _spec.get("cell_overrides", {})
				var e: Dictionary = cov.get(key, {})
				if e.has("height_ft"):
					_set_cell_override(key, "height_ft", _snap_inch_ft(float(e["height_ft"])))
		"beam_move":
			for id in _manip_targets:
				var key := _id_key(id)
				var bov: Dictionary = _spec.get("beam_overrides", {})
				var e: Dictionary = bov.get(key, {})
				if e.has("dy_in"):
					var snapped := roundf(float(e["dy_in"]))
					if absf(snapped) < 0.01:
						e.erase("dy_in")
						if e.is_empty():
							bov.erase(key)
						else:
							bov[key] = e
						_spec["beam_overrides"] = bov
					else:
						_set_beam_override(key, "dy_in", snapped)
	_queue_rebuild(true)  # commit the snapped result immediately (full rebuild)


func _snap_inch_ft(ft: float) -> float:
	return roundf(ft * 12.0) / 12.0


# ---------------------------------------------------------------------------
# Override writers + delete
# ---------------------------------------------------------------------------

func _id_key(id: String) -> String:
	var colon := id.find(":")
	return id.substr(colon + 1) if colon >= 0 else id


func _set_cell_override(key: String, field: String, value: Variant) -> void:
	var cov: Dictionary = _spec.get("cell_overrides", {})
	var e: Dictionary = cov.get(key, {})
	e[field] = value
	cov[key] = e
	_spec["cell_overrides"] = cov


func _erase_cell_field(key: String, field: String) -> void:
	var cov: Dictionary = _spec.get("cell_overrides", {})
	if not cov.has(key):
		return
	var e: Dictionary = cov[key]
	e.erase(field)
	if e.is_empty():
		cov.erase(key)
	else:
		cov[key] = e
	_spec["cell_overrides"] = cov


func _set_beam_override(key: String, field: String, value: Variant) -> void:
	var bov: Dictionary = _spec.get("beam_overrides", {})
	var e: Dictionary = bov.get(key, {})
	e[field] = value
	bov[key] = e
	_spec["beam_overrides"] = bov


func _delete_selection() -> void:
	if _selection.is_empty():
		return
	_push_undo()
	for id in _selection:
		if str(id).begins_with("cell:"):
			_set_cell_override(_id_key(id), "kind", "none")
		elif str(id).begins_with("beam:"):
			_set_beam_override(_id_key(id), "deleted", true)
		elif str(id).begins_with("wall:"):
			var wdel: Array = _spec.get("wall_sheet_deleted", [])
			var key := _id_key(id)
			if not wdel.has(key):
				wdel.append(key)
			_spec["wall_sheet_deleted"] = wdel
	_selection.clear()
	_queue_rebuild(true)


# ---------------------------------------------------------------------------
# Undo (button + Ctrl+Z) — snapshots the override containers before each edit.
# ---------------------------------------------------------------------------

func _snapshot_overrides() -> Dictionary:
	return {
		"cell_overrides": (_spec.get("cell_overrides", {}) as Dictionary).duplicate(true),
		"beam_overrides": (_spec.get("beam_overrides", {}) as Dictionary).duplicate(true),
		"wall_sheet_deleted": (_spec.get("wall_sheet_deleted", []) as Array).duplicate(true),
	}


func _push_undo() -> void:
	_undo_stack.append(_snapshot_overrides())
	if _undo_stack.size() > UNDO_LIMIT:
		_undo_stack.pop_front()
	_update_undo_btn()


func _undo() -> void:
	if _undo_stack.is_empty():
		return
	var snap: Dictionary = _undo_stack.pop_back()
	_spec["cell_overrides"] = snap["cell_overrides"]
	_spec["beam_overrides"] = snap["beam_overrides"]
	_spec["wall_sheet_deleted"] = snap["wall_sheet_deleted"]
	_selection.clear()
	_hover_group.clear()
	_update_undo_btn()
	_queue_rebuild(true)


func _update_undo_btn() -> void:
	if _undo_btn != null:
		_undo_btn.disabled = _undo_stack.is_empty()


# ---------------------------------------------------------------------------
# Step placement tool — drop a step section onto a grid cell slot. It snaps to
# the frame lines (uprights) and merges into the structure, e.g. internal steps
# from one deck level to the one below.
# ---------------------------------------------------------------------------

func _set_step_mode(on: bool) -> void:
	_place_step_mode = on
	if _steps_btn != null:
		_steps_btn.button_pressed = on
	if on:
		_selection.clear()
	_hover_group.clear()
	_refresh_highlight()
	_update_sel_hud()


func _pick_slot(local_pos: Vector2) -> Dictionary:
	if _camera == null:
		return {}
	var vp := _to_viewport_pos(local_pos)
	var origin := _camera.project_ray_origin(vp)
	var dir := _camera.project_ray_normal(vp)
	return PalletRackBuilder.pick_nearest(
		PalletRackBuilder.cell_slots(_spec), origin, dir)


func _update_step_ghost(local_pos: Vector2) -> void:
	var slot := _pick_slot(local_pos)
	_hover_group = [str(slot["id"])] if not slot.is_empty() else []
	_refresh_highlight(true)


func _place_step_at(local_pos: Vector2) -> void:
	var slot := _pick_slot(local_pos)
	if slot.is_empty():
		return
	_push_undo()
	_set_cell_override(_id_key(str(slot["id"])), "kind", "step")
	_queue_rebuild(true)


# ---------------------------------------------------------------------------
# Highlight overlay + HUD
# ---------------------------------------------------------------------------

func _refresh_highlight(step_ghost: bool = false) -> void:
	if _highlight_holder == null:
		return
	for c in _highlight_holder.get_children():
		c.queue_free()
	for id in _selection:
		var comp := _comp_by_id(id)
		if not comp.is_empty():
			_add_highlight_box(comp["aabb"], Color(1.0, 0.6, 0.1, 0.38))
	# Cyan ghost while dropping a step; green for a normal hover.
	var hover_col := Color(0.2, 0.75, 1.0, 0.4) if step_ghost else Color(0.2, 1.0, 0.35, 0.28)
	for id in _hover_group:
		if _selection.has(id):
			continue
		var hc := _slot_or_comp_by_id(id) if step_ghost else _comp_by_id(id)
		if not hc.is_empty():
			_add_highlight_box(hc["aabb"], hover_col)


## Resolve an id against the full slot list (includes empty cells) for the step
## ghost, falling back to the live pick cache.
func _slot_or_comp_by_id(id: String) -> Dictionary:
	for slot in PalletRackBuilder.cell_slots(_spec):
		if str(slot["id"]) == id:
			return slot
	return _comp_by_id(id)


func _add_highlight_box(box: AABB, color: Color) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = box.size + Vector3(0.04, 0.04, 0.04)
	mi.mesh = bm
	mi.position = box.position + box.size * 0.5
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = true
	bm.material = mat
	_highlight_holder.add_child(mi)


func _update_sel_hud() -> void:
	if _sel_hud == null:
		return
	if _place_step_mode:
		_sel_hud.text = "Step tool: click a cell to drop steps  (Esc to exit)"
		return
	if _selection.is_empty():
		_sel_hud.text = ""
		return
	# Count distinct deck strips (a strip is many cell ids) so the readout is
	# meaningful rather than "12 deck".
	var strips := {}
	var n_beam := 0
	var n_wall := 0
	for id in _selection:
		if str(id).begins_with("cell:"):
			var parts_cell := _id_key(id).split(",")
			if parts_cell.size() == 3:
				strips["%s,%s" % [parts_cell[1], parts_cell[2]]] = true
		elif str(id).begins_with("beam:"):
			n_beam += 1
		elif str(id).begins_with("wall:"):
			n_wall += 1
	var parts: Array = []
	if strips.size() > 0:
		parts.append("%d deck%s" % [strips.size(), "" if strips.size() == 1 else "s"])
	if n_beam > 0:
		parts.append("%d beam" % n_beam)
	if n_wall > 0:
		parts.append("%d sheet" % n_wall)
	_sel_hud.text = "Selected: " + ", ".join(parts) + "  (Del remove • Ctrl+Z undo)"


func _build_studio_world() -> void:
	_studio = Node3D.new()
	_studio.name = "Studio"
	_viewport.add_child(_studio)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	# Deep near-black studio backdrop, matching the Linkage Lab viewport.
	e.background_color = Color(0.035, 0.043, 0.063)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.52, 0.56, 0.62)
	e.ambient_light_energy = 0.55
	e.fog_enabled = true
	e.fog_light_color = Color(0.035, 0.043, 0.063)
	e.fog_light_energy = 1.0
	e.fog_density = 0.0016
	env.environment = e
	_studio.add_child(env)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-40, 35, 0)
	key.light_energy = 1.2
	key.shadow_enabled = true
	_studio.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-30, -140, 0)
	fill.light_energy = 0.35
	_studio.add_child(fill)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(300, 300)
	ground.mesh = plane
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.09, 0.10, 0.13)
	gmat.roughness = 0.95
	ground.material_override = gmat
	_studio.add_child(ground)
	_holder = Node3D.new()
	_holder.name = "Holder"
	_studio.add_child(_holder)
	_highlight_holder = Node3D.new()
	_highlight_holder.name = "Highlights"
	_studio.add_child(_highlight_holder)
	_camera = Camera3D.new()
	_camera.far = 400.0
	_studio.add_child(_camera)
	_update_camera()


func _update_camera() -> void:
	if _camera == null:
		return
	var cp := Vector3(
		_dist * cos(_pitch) * sin(_yaw),
		_dist * sin(_pitch),
		_dist * cos(_pitch) * cos(_yaw))
	# look_at_from_position avoids the "not inside tree" edge case if the camera
	# transform is set before it fully enters the SubViewport tree.
	_camera.look_at_from_position(_target + cp, _target, Vector3.UP)


## Compact number string ("12", "12.5") — GDScript's % has no %g specifier.
func _fmt_num(v: float) -> String:
	if absf(v - roundf(v)) < 0.001:
		return str(int(round(v)))
	return String.num(v, 2)


# ---------------------------------------------------------------------------
# Spec I/O
# ---------------------------------------------------------------------------

func _selected_meta(opt: OptionButton, fallback: int) -> int:
	if opt == null:
		return fallback
	var m = opt.get_selected_metadata()
	return int(m) if m != null else fallback


func _sync_controls() -> void:
	_suppress = true
	_select_meta(_depth_opt, int(_spec["upright_depth_in"]))
	_select_meta(_height_opt, int(_spec["upright_height_ft"]))
	_select_meta(_beam_opt, int(_spec["beam_span_ft"]))
	_select_meta(_lumber_opt, int(_spec["lumber_len_ft"]))
	_select_meta(_joist_opt, int(_spec["joist_spacing_in"]))
	if _bay_slider:
		_bay_slider.value = int(_spec["bay_count"])
		_bay_val.text = str(int(_spec["bay_count"]))
	if _col_slider:
		_col_slider.value = int(_spec["column_count"])
		_col_val.text = str(int(_spec["column_count"]))
	if _spacing_slider:
		_spacing_slider.value = float(_spec["row_gap_ft"])
		_spacing_val.text = _fmt_num(float(_spec["row_gap_ft"])) + "'"
	if _levels_spin:
		_levels_spin.value = int(_spec["deck_levels"])
	if _roof_chk:
		_roof_chk.button_pressed = bool(_spec["roof_deck"])
	if _decked_chk:
		_decked_chk.button_pressed = bool(_spec["decked"])
	if _stepped_spin:
		_stepped_spin.value = int(_spec["stepped_module"])
	if _u_chk:
		_u_chk.button_pressed = bool(_spec["u_shape"])
	if _u_bays_spin:
		_u_bays_spin.value = int(_spec["u_open_bays"])
	if _u_cols_spin:
		_u_cols_spin.value = int(_spec["u_open_cols"])
	for face in _wall_chks.keys():
		(_wall_chks[face] as CheckBox).button_pressed = \
			bool((_spec["walls"] as Dictionary).get(face, false))
	_suppress = false
	_rebuild_level_spins()


func _select_meta(opt: OptionButton, value: int) -> void:
	if opt == null:
		return
	for i in opt.item_count:
		if int(opt.get_item_metadata(i)) == value:
			opt.select(i)
			return


func _read_spec() -> Dictionary:
	var heights: Array = []
	for sp in _level_spins:
		heights.append(float((sp as SpinBox).value))
	var walls := {}
	for face in _wall_chks.keys():
		walls[face] = (_wall_chks[face] as CheckBox).button_pressed
	return PalletRackBuilder.resolve_spec({
		"upright_depth_in": _selected_meta(_depth_opt, 42),
		"upright_height_ft": _selected_meta(_height_opt, 16),
		"beam_span_ft": _selected_meta(_beam_opt, 12),
		"bay_count": int(_bay_slider.value) if _bay_slider else 3,
		"column_count": int(_col_slider.value) if _col_slider else 2,
		"row_gap_ft": float(_spacing_slider.value) if _spacing_slider else 12.0,
		"decked": _decked_chk.button_pressed if _decked_chk else true,
		"lumber_len_ft": _selected_meta(_lumber_opt, 12),
		"joist_spacing_in": _selected_meta(_joist_opt, 24),
		"deck_levels": int(_levels_spin.value) if _levels_spin else 2,
		"level_heights_ft": heights,
		"roof_deck": _roof_chk.button_pressed if _roof_chk else true,
		"walls": walls,
		"stepped_module": int(_stepped_spin.value) if _stepped_spin else 0,
		"u_shape": _u_chk.button_pressed if _u_chk else false,
		"u_open_bays": int(_u_bays_spin.value) if _u_bays_spin else 1,
		"u_open_cols": int(_u_cols_spin.value) if _u_cols_spin else 1,
		# Per-component editor overrides survive control-driven rebuilds.
		"cell_overrides": (_spec.get("cell_overrides", {}) as Dictionary),
		"beam_overrides": (_spec.get("beam_overrides", {}) as Dictionary),
		"wall_sheet_deleted": (_spec.get("wall_sheet_deleted", []) as Array),
	})


func _queue_rebuild(immediate: bool, light: bool = false) -> void:
	# A pending FULL rebuild always wins over a light one.
	if not light:
		_rebuild_light = false
	elif not _rebuild_pending:
		_rebuild_light = true
	_rebuild_pending = true
	_rebuild_timer = 0.0 if immediate else REBUILD_DEBOUNCE_S


func _rebuild_preview(light: bool = false) -> void:
	if _holder == null:
		return
	# free() (not queue_free) so the previous build is gone before the new one
	# renders — no one-frame ghost while a drag streams rebuilds at 60 fps.
	for c in _holder.get_children():
		c.free()
	if not light:
		_spec = _read_spec()
	var node := PalletRackBuilder.build_node(_spec)
	_holder.add_child(node)
	# Frame the structure once (on open); keep the user's orbit/zoom afterwards.
	if not _framed:
		var fp := PalletRackBuilder.footprint_xz(_spec)
		var h := float(_spec["upright_height_ft"]) * PalletRackBuilder.FT
		_target = Vector3(0, h * 0.45, 0)
		_dist = maxf(fp.x, fp.y) * 1.2 + h * 0.9 + 4.0
		_update_camera()
		_framed = true
	if not light:
		_update_bom(node)
	# Refresh the pick registry + prune selection/hover to still-present ids.
	_pick_cache = PalletRackBuilder.pick_components(_spec)
	var live := {}
	for comp in _pick_cache:
		live[str(comp["id"])] = true
	var kept: Array = []
	for id in _selection:
		if live.has(id):
			kept.append(id)
	_selection = kept
	var kept_hover: Array = []
	for id in _hover_group:
		if live.has(id):
			kept_hover.append(id)
	_hover_group = kept_hover
	_refresh_highlight()
	if not light:
		_update_undo_btn()
		_update_sel_hud()


func _update_bom(node: Node3D) -> void:
	if _bom_lbl == null:
		return
	var b: Dictionary = node.get_meta("bom", {}) if node.has_meta("bom") else {}
	_bom_lbl.text = "%s   %s\n%s   %s" % [
		UiText.count(int(b.get("uprights", 0)), "upright"), UiText.count(int(b.get("beams", 0)), "beam"),
		UiText.count(int(b.get("lumber", 0)), "2x4 joist"), UiText.count(int(b.get("plywood", 0)), "plywood sheet")]


func _on_place() -> void:
	_spec = _read_spec()
	if _loader == null:
		return
	if _loader.has_method("begin_pallet_rack_placement"):
		var collide := _collide_chk.button_pressed if _collide_chk else true
		_loader.call("begin_pallet_rack_placement", _spec, collide)
	close()


func _on_apply_to_prop() -> void:
	if _bound_prop_id.is_empty():
		return
	_spec = _read_spec()
	var main := _main_node()
	if main != null:
		PlacedPropService.update_prop_record(main, _bound_prop_id,
			{"rack_spec": _spec.duplicate(true)}, true)
	elif _loader != null and _loader.has_method("update_prop_record"):
		_loader.call("update_prop_record", _bound_prop_id, {"rack_spec": _spec.duplicate(true)})
	close()


func _on_delete_prop() -> void:
	if _bound_prop_id.is_empty():
		return
	var pid := _bound_prop_id
	if _loader != null and _loader.has_method("delete_prop_by_id"):
		_loader.call("delete_prop_by_id", pid)
	close()


func _main_node() -> Node:
	var tree := get_tree()
	if tree != null and tree.current_scene != null:
		return tree.current_scene
	if _loader != null:
		return _loader.get_parent()
	return null


func _prop_record(prop_id: String) -> Dictionary:
	if _loader != null and _loader.has_method("get_prop_record"):
		var rec: Dictionary = _loader.call("get_prop_record", prop_id)
		if not rec.is_empty():
			return rec
	var main := _main_node()
	if main != null:
		return PlacedPropService.get_prop_record(main, prop_id)
	return {}
