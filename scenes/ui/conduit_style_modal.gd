extends Control

## Live style editor for a 3D conduit / graph connection. Opens seeded with the
## SELECTED wire's real type + settings, shows an orbitable/zoomable preview that
## renders the actual material + routing (not a generic glow stub), and exposes
## only the controls relevant to the chosen conduit type. Apply writes the style
## to the wire; styles can be saved as a type default or a named library preset.

signal style_applied(conn_id: String)
signal closed()

const MODAL_NAME := "conduit_style"
const PREVIEW_LEN_M := 4.2

var _conn_id: String = ""
var _model: GraphModel = null
var _main: Node = null
var _draft: Dictionary = {}          ## working style + conduit_type + flags
var _derived_type: String = "extension_cord"  ## the wire's resolved kind (for "Auto")
var _built := false
var _syncing := false                ## guard control→draft while seeding

# Preview
var _vp_container: SubViewportContainer = null
var _viewport: SubViewport = null
var _studio: Node3D = null
var _camera: Camera3D = null
var _cam_target := Vector3(0.0, 0.35, 0.0)
var _cam_yaw := 0.6
var _cam_pitch := 0.5
var _cam_dist := 4.6
var _orbiting := false
var _auto_rotate := true

# Controls
var _type_opt: OptionButton = null
var _size_opt: OptionButton = null
var _radius_slider: HSlider = null
var _roughness_slider: HSlider = null
var _glow_slider: HSlider = null
var _emission_slider: HSlider = null
var _color_picker: ColorPickerButton = null
var _flow_color_picker: ColorPickerButton = null
var _route_opt: OptionButton = null
var _fitting_opt: OptionButton = null
var _elbow_slider: HSlider = null
var _slack_slider: HSlider = null
var _visible_opt: OptionButton = null
var _flow_glow_opt: OptionButton = null
var _status_lbl: Label = null
var _preset_name_edit: LineEdit = null
var _named_list: ItemList = null
var _title_lbl: Label = null
var _subtitle_lbl: Label = null
var _rotate_chk: CheckButton = null
var _preview_debounce: Timer = null

# Rows (for per-type show/hide) + section headers
var _row_type: Control = null
var _row_size: Control = null
var _row_radius: Control = null
var _row_roughness: Control = null
var _row_glow: Control = null
var _row_emission: Control = null
var _row_flow_color: Control = null
var _row_route: Control = null
var _row_fitting: Control = null
var _row_elbow: Control = null
var _row_slack: Control = null
var _row_flow_glow: Control = null
var _hdr_glow: Control = null


func open(conn_id: String, model: GraphModel, main: Node) -> void:
	_conn_id = conn_id
	_model = model
	_main = main
	if not _built:
		_build_ui()
		_built = true
	_load_draft_from_connection()
	_syncing = true
	_sync_controls_from_draft()
	_syncing = false
	_update_control_visibility()
	_rebuild_preview()
	_refresh_named_list()
	visible = true
	set_process(true)
	CursorController.request_modal(MODAL_NAME, Callable(self, "close"))


func close() -> void:
	visible = false
	set_process(false)
	CursorController.release_modal(MODAL_NAME)
	closed.emit()


func _process(delta: float) -> void:
	if _auto_rotate and not _orbiting:
		_cam_yaw += delta * 0.35
		_update_camera()


# ---------------------------------------------------------------------------
# UI construction
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	# Responsive panel: fills the screen minus a margin, so it scales to any res.
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.offset_left = 56
	panel.offset_top = 36
	panel.offset_right = -56
	panel.offset_bottom = -36
	panel.add_theme_stylebox_override("panel", UITheme.panel_style())
	add_child(panel)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	panel.add_child(root)

	# Header
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	root.add_child(head)
	var head_txt := VBoxContainer.new()
	head_txt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(head_txt)
	_title_lbl = Label.new()
	_title_lbl.text = "Conduit Style"
	_title_lbl.add_theme_font_size_override("font_size", 20)
	_title_lbl.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	head_txt.add_child(_title_lbl)
	_subtitle_lbl = Label.new()
	_subtitle_lbl.text = ""
	_subtitle_lbl.add_theme_font_size_override("font_size", 12)
	_subtitle_lbl.modulate = Color(0.72, 0.8, 0.9)
	head_txt.add_child(_subtitle_lbl)
	var head_x := Button.new()
	head_x.text = "✕"
	head_x.tooltip_text = "Close (Esc)"
	head_x.focus_mode = Control.FOCUS_NONE
	head_x.custom_minimum_size = Vector2(36, 32)
	head_x.pressed.connect(close)
	head.add_child(head_x)

	# Body: preview | settings
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 14)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(body)

	_build_preview_pane(body)
	_build_settings_pane(body)

	# Action bar (always visible, not scrolled)
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 8)
	root.add_child(bar)
	_status_lbl = Label.new()
	_status_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_lbl.add_theme_font_size_override("font_size", 12)
	_status_lbl.modulate = Color(0.7, 0.86, 0.72)
	bar.add_child(_status_lbl)
	var reset_btn := Button.new()
	reset_btn.text = "Reset auto-route"
	reset_btn.tooltip_text = "Clear manual bends and re-run automatic routing"
	reset_btn.focus_mode = Control.FOCUS_NONE
	reset_btn.pressed.connect(_on_reset_autoroute)
	bar.add_child(reset_btn)
	var apply_btn := Button.new()
	apply_btn.text = "Apply to wire"
	apply_btn.custom_minimum_size = Vector2(150, 34)
	apply_btn.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	apply_btn.focus_mode = Control.FOCUS_NONE
	apply_btn.pressed.connect(_on_apply)
	bar.add_child(apply_btn)
	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.custom_minimum_size = Vector2(90, 34)
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.pressed.connect(close)
	bar.add_child(close_btn)


func _build_preview_pane(parent: Control) -> void:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_stretch_ratio = 1.35
	col.add_theme_constant_override("separation", 6)
	parent.add_child(col)

	_vp_container = SubViewportContainer.new()
	_vp_container.stretch = true  # auto-sizes the SubViewport to the container
	_vp_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_vp_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vp_container.mouse_filter = Control.MOUSE_FILTER_STOP
	_vp_container.gui_input.connect(_on_preview_gui_input)
	var vp_style := StyleBoxFlat.new()
	vp_style.bg_color = Color(0.05, 0.06, 0.09)
	vp_style.set_corner_radius_all(8)
	vp_style.set_border_width_all(1)
	vp_style.border_color = Color(0.3, 0.36, 0.46)
	# StyleBox on a SubViewportContainer isn't drawn, so wrap it in a Panel.
	var vp_panel := PanelContainer.new()
	vp_panel.add_theme_stylebox_override("panel", vp_style)
	vp_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vp_panel.add_child(_vp_container)
	col.add_child(vp_panel)

	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.transparent_bg = false
	_viewport.msaa_3d = Viewport.MSAA_4X
	_viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE  # idle while the modal is hidden
	_vp_container.add_child(_viewport)

	var hint := Label.new()
	hint.text = "Drag to orbit · scroll to zoom · live preview of the real material & routing"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 11)
	hint.modulate = Color(0.65, 0.72, 0.82)
	col.add_child(hint)
	_rotate_chk = CheckButton.new()
	_rotate_chk.text = "Auto-rotate"
	_rotate_chk.button_pressed = true
	_rotate_chk.focus_mode = Control.FOCUS_NONE
	_rotate_chk.toggled.connect(func(on: bool) -> void: _auto_rotate = on)
	col.add_child(_rotate_chk)


func _build_settings_pane(parent: Control) -> void:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_stretch_ratio = 1.0
	scroll.custom_minimum_size = Vector2(380, 0)
	parent.add_child(scroll)
	var form := VBoxContainer.new()
	form.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	form.add_theme_constant_override("separation", 7)
	scroll.add_child(form)

	form.add_child(_section("Conduit type"))
	_type_opt = _add_opt(form, "Type")
	_row_type = _type_opt.get_parent()
	_populate_types()
	_type_opt.item_selected.connect(func(_i: int) -> void: _on_type_changed())
	_size_opt = _add_opt(form, "Nominal size")
	_row_size = _size_opt.get_parent()
	_populate_sizes()
	_size_opt.item_selected.connect(func(_i: int) -> void: _on_draft_changed())

	form.add_child(_section("Appearance"))
	_color_picker = _add_color(form, "Base color")
	_radius_slider = _add_slider(form, "Thickness (Ø)", 0.003, 0.09, 0.001)
	_row_radius = _radius_slider.get_parent()
	_roughness_slider = _add_slider(form, "Roughness", 0.0, 1.0, 0.02)
	_row_roughness = _roughness_slider.get_parent()

	_hdr_glow = _section("Glow / flow")
	form.add_child(_hdr_glow)
	_glow_slider = _add_slider(form, "Flow strength", 0.0, 2.0, 0.05)
	_row_glow = _glow_slider.get_parent()
	_emission_slider = _add_slider(form, "Emission", 0.0, 5.0, 0.05)
	_row_emission = _emission_slider.get_parent()
	_flow_color_picker = _add_color(form, "Flow color")
	_row_flow_color = _flow_color_picker.get_parent()
	_flow_glow_opt = _add_opt(form, "Flow glow")
	_flow_glow_opt.add_item("Follow default", 0)
	_flow_glow_opt.add_item("On", 1)
	_flow_glow_opt.add_item("Off", 2)
	_flow_glow_opt.item_selected.connect(func(_i: int) -> void: _on_draft_changed())
	_row_flow_glow = _flow_glow_opt.get_parent()

	form.add_child(_section("Routing"))
	_route_opt = _add_opt(form, "Style")
	for opt: Variant in ConduitKinds.route_mode_options():
		var od: Dictionary = opt
		_route_opt.add_item(str(od.get("label", "")))
		_route_opt.set_item_metadata(_route_opt.item_count - 1, str(od.get("id", "")))
	_route_opt.item_selected.connect(func(_i: int) -> void: _on_route_changed())
	_row_route = _route_opt.get_parent()
	_fitting_opt = _add_opt(form, "Elbow angle")
	for pair: Array in [["", "Auto"], ["30", "30°"], ["45", "45°"], ["60", "60°"], ["90", "90°"]]:
		_fitting_opt.add_item(str(pair[1]))
		_fitting_opt.set_item_metadata(_fitting_opt.item_count - 1, str(pair[0]))
	_fitting_opt.item_selected.connect(func(_i: int) -> void: _on_draft_changed())
	_row_fitting = _fitting_opt.get_parent()
	_elbow_slider = _add_slider(form, "Elbow roundness", 0.0, 0.45, 0.01)
	_row_elbow = _elbow_slider.get_parent()
	_slack_slider = _add_slider(form, "Slack / sag (m)", 0.0, 0.8, 0.01)
	_row_slack = _slack_slider.get_parent()

	form.add_child(_section("Visibility"))
	_visible_opt = _add_opt(form, "Show in 3D")
	_visible_opt.add_item("Follow global", 0)
	_visible_opt.add_item("Always on", 1)
	_visible_opt.add_item("Hidden", 2)
	_visible_opt.item_selected.connect(func(_i: int) -> void: _on_draft_changed())

	form.add_child(_section("Library presets"))
	var save_row := HBoxContainer.new()
	save_row.add_theme_constant_override("separation", 6)
	form.add_child(save_row)
	_preset_name_edit = LineEdit.new()
	_preset_name_edit.placeholder_text = "Preset name…"
	_preset_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save_row.add_child(_preset_name_edit)
	var save_named_btn := Button.new()
	save_named_btn.text = "Save"
	save_named_btn.focus_mode = Control.FOCUS_NONE
	save_named_btn.pressed.connect(_on_save_named)
	save_row.add_child(save_named_btn)
	var save_type_btn := Button.new()
	save_type_btn.text = "Set as default for this type"
	save_type_btn.focus_mode = Control.FOCUS_NONE
	save_type_btn.pressed.connect(_on_save_type_default)
	form.add_child(save_type_btn)
	_named_list = ItemList.new()
	_named_list.custom_minimum_size = Vector2(0, 96)
	_named_list.item_activated.connect(_on_named_activated)
	form.add_child(_named_list)
	var load_named_btn := Button.new()
	load_named_btn.text = "Load selected preset"
	load_named_btn.focus_mode = Control.FOCUS_NONE
	load_named_btn.pressed.connect(_on_load_named)
	form.add_child(load_named_btn)


func _section(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text.to_upper()
	lbl.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	lbl.add_theme_font_size_override("font_size", 12)
	return lbl


func _add_opt(parent: Control, label: String) -> OptionButton:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var lbl := Label.new()
	lbl.text = label
	lbl.custom_minimum_size.x = 118
	row.add_child(lbl)
	var opt := OptionButton.new()
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt.focus_mode = Control.FOCUS_NONE
	row.add_child(opt)
	parent.add_child(row)
	return opt


func _add_slider(parent: Control, label: String, mn: float, mx: float, step: float) -> HSlider:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var lbl := Label.new()
	lbl.text = label
	lbl.custom_minimum_size.x = 118
	row.add_child(lbl)
	var sl := HSlider.new()
	sl.min_value = mn
	sl.max_value = mx
	sl.step = step
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(sl)
	var val := Label.new()
	val.custom_minimum_size.x = 48
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val.add_theme_font_size_override("font_size", 11)
	val.modulate = Color(0.7, 0.78, 0.88)
	row.add_child(val)
	sl.value_changed.connect(func(v: float) -> void:
		val.text = ("%.3f" % v) if step < 0.01 else ("%.2f" % v)
		_on_draft_changed())
	parent.add_child(row)
	return sl


func _add_color(parent: Control, label: String) -> ColorPickerButton:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var lbl := Label.new()
	lbl.text = label
	lbl.custom_minimum_size.x = 118
	row.add_child(lbl)
	var cp := ColorPickerButton.new()
	cp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cp.custom_minimum_size.y = 26
	cp.edit_alpha = false
	cp.color_changed.connect(func(_c: Color) -> void: _on_draft_changed())
	row.add_child(cp)
	parent.add_child(row)
	return cp


func _populate_types() -> void:
	_type_opt.clear()
	# Entry 0 = auto (matches the connection's resource-derived kind).
	_type_opt.add_item("Auto (by resource)")
	_type_opt.set_item_metadata(0, "")
	var i := 1
	for tid: Variant in ConduitKinds.all_types():
		var id := str(tid)
		_type_opt.add_item(ConduitKinds.display_name(id))
		_type_opt.set_item_metadata(i, id)
		i += 1


func _populate_sizes(type_id: String = "") -> void:
	if _size_opt == null:
		return
	_size_opt.clear()
	var tid := type_id if not type_id.is_empty() else _effective_type_id()
	var sizes: Array = ConduitKinds.pipe_kit_sizes_in(tid)
	if sizes.is_empty():
		sizes = PipeKit.SCH40_SIZES_IN.duplicate()
	for sz: Variant in sizes:
		var s := float(sz)
		var label := CulvertKit.size_label(s) if ConduitKinds.uses_culvert_kit(tid) \
				else PipeKit.size_label(s)
		_size_opt.add_item(label)
		_size_opt.set_item_metadata(_size_opt.item_count - 1, s)


# ---------------------------------------------------------------------------
# Draft <-> controls
# ---------------------------------------------------------------------------

func _load_draft_from_connection() -> void:
	_draft = {}
	if _model == null:
		return
	var conn := _model.get_connection(_conn_id)
	if conn.is_empty():
		return
	_derived_type = ConduitKinds.derive_type_for_connection(conn)
	# Seed the FULL style of the resolved type (radius/color/route/…) + overrides,
	# so opening a wire shows its real look — not a generic thin-black default.
	_draft = ConduitStylePresets.style_from_connection(conn, _derived_type)
	_draft["conduit_type"] = str(conn.get("conduit_type", ""))
	if conn.has("visible_3d"):
		_draft["visible_3d"] = conn.get("visible_3d")
	if conn.has("flow_glow"):
		_draft["flow_glow"] = conn.get("flow_glow")
	_populate_sizes(_effective_type_id())
	_title_lbl.text = "Conduit Style"
	var sub := "Editing: %s" % ConduitKinds.display_name_with_size(
		_derived_type, _draft)
	if ConduitKinds.uses_culvert_kit(_derived_type):
		sub += " · corrugated PE culvert · wide-arc routing"
	elif ConduitKinds.uses_pipe_kit(_derived_type):
		sub += " · Sch40 fittings kit · white PVC / black ABS"
	_subtitle_lbl.text = sub


## The type actually used for preview/material: explicit selection, or the wire's
## resolved kind when set to "Auto".
func _effective_type_id() -> String:
	var ctype := str(_draft.get("conduit_type", ""))
	return ctype if not ctype.is_empty() else _derived_type


func _sync_controls_from_draft() -> void:
	var ctype := str(_draft.get("conduit_type", ""))
	var sel := 0
	for i: int in _type_opt.item_count:
		if str(_type_opt.get_item_metadata(i)) == ctype:
			sel = i
			break
	_type_opt.select(sel)
	var eff := _effective_type_id()
	var meta := ConduitKinds.type_meta(eff)
	if _size_opt != null:
		var sz := ConduitKinds.pipe_size_in(eff, _draft)
		var size_sel := 0
		for i: int in _size_opt.item_count:
			if absf(float(_size_opt.get_item_metadata(i)) - sz) < 0.01:
				size_sel = i
				break
		_size_opt.select(size_sel)
	_color_picker.color = _draft.get("color", meta.get("color", Color.WHITE)) as Color
	_radius_slider.value = float(_draft.get("radius_m", meta.get("radius_m", 0.02)))
	_roughness_slider.value = float(_draft.get("roughness", meta.get("roughness", 0.7)))
	_glow_slider.value = float(_draft.get("flow_strength_default", 0.7))
	_emission_slider.value = float(_draft.get("emission_energy", meta.get("emission_energy", 1.8)))
	_flow_color_picker.color = _draft.get("flow_color", _color_picker.color.lightened(0.4)) as Color
	# Routing dropdown from route_mode (or the type default).
	var rm := ConduitKinds.normalize_route_mode(str(_draft.get("route_mode",
		meta.get("route_mode", ""))))
	_select_by_metadata(_route_opt, rm)
	# Elbow angle override.
	var fs := str(int(float(_draft.get("fitting_step_deg", 0.0)))) if _draft.has("fitting_step_deg") else ""
	_select_by_metadata(_fitting_opt, fs)
	_elbow_slider.value = float(_draft.get("elbow_radius_frac", meta.get("elbow_radius_frac", 0.35)))
	_slack_slider.value = float(_draft.get("end_slack_m", meta.get("end_slack_m",
		meta.get("sag_amount", 0.0))))
	_visible_opt.select(1 if _draft.get("visible_3d") == true else (2 if _draft.get("visible_3d") == false else 0))
	_flow_glow_opt.select(1 if _draft.get("flow_glow") == true else (2 if _draft.get("flow_glow") == false else 0))


func _select_by_metadata(opt: OptionButton, meta_val: String) -> void:
	for i: int in opt.item_count:
		if str(opt.get_item_metadata(i)) == meta_val:
			opt.select(i)
			return
	opt.select(0)


func _read_draft_from_controls() -> void:
	_draft["conduit_type"] = str(_type_opt.get_item_metadata(_type_opt.selected))
	var eff := _effective_type_id()
	var glow_type := ConduitKinds.is_conceptual_type(eff) or ConduitKinds.is_light_type(eff)
	if _size_opt != null and ConduitKinds.uses_pipe_kit(eff):
		_draft["pipe_size_in"] = float(_size_opt.get_item_metadata(_size_opt.selected))
	elif _draft.has("pipe_size_in") and not ConduitKinds.uses_pipe_kit(eff):
		_draft.erase("pipe_size_in")
	_draft["color"] = _color_picker.color
	_draft["radius_m"] = _radius_slider.value
	_draft["roughness"] = _roughness_slider.value
	_draft["flow_strength_default"] = _glow_slider.value
	_draft["emission_energy"] = _emission_slider.value
	_draft["flow_color"] = _flow_color_picker.color
	var rm := str(_route_opt.get_item_metadata(_route_opt.selected))
	if rm.is_empty():
		_draft.erase("route_mode")
	else:
		_draft["route_mode"] = rm
	var fs := str(_fitting_opt.get_item_metadata(_fitting_opt.selected))
	if fs.is_empty():
		_draft.erase("fitting_step_deg")
	else:
		_draft["fitting_step_deg"] = float(fs)
	_draft["elbow_radius_frac"] = _elbow_slider.value
	_draft["end_slack_m"] = _slack_slider.value
	_draft["sag_amount"] = _slack_slider.value
	# Only conceptual / light kinds glow; physical wires render their PBR material.
	if glow_type:
		_draft["emissive"] = true
		_draft["use_flow_shader"] = true
	else:
		_draft.erase("emissive")
		_draft.erase("use_flow_shader")
		_draft.erase("jacket_emissive")
	match _visible_opt.selected:
		0: _draft.erase("visible_3d")
		1: _draft["visible_3d"] = true
		2: _draft["visible_3d"] = false
	match _flow_glow_opt.selected:
		0: _draft.erase("flow_glow")
		1: _draft["flow_glow"] = true
		2: _draft["flow_glow"] = false


func _on_type_changed() -> void:
	# Switching type reseeds the appearance from that type's defaults (so each type
	# has its own sensible settings), preserving the user's visibility choices.
	var new_type := str(_type_opt.get_item_metadata(_type_opt.selected))
	var eff := new_type if not new_type.is_empty() else _derived_type
	var meta := ConduitKinds.type_meta(eff)
	var keep_vis: Variant = _draft.get("visible_3d")
	var keep_glow: Variant = _draft.get("flow_glow")
	_draft = {}
	for k: String in ConduitStylePresets.STYLE_KEYS:
		if meta.has(k):
			_draft[k] = meta[k]
	_draft["conduit_type"] = new_type
	if ConduitKinds.uses_pipe_kit(eff):
		_draft["pipe_size_in"] = float(meta.get("default_pipe_size_in", 1.25))
	if keep_vis != null:
		_draft["visible_3d"] = keep_vis
	if keep_glow != null:
		_draft["flow_glow"] = keep_glow
	_populate_sizes(eff)
	_syncing = true
	_sync_controls_from_draft()
	_syncing = false
	_update_control_visibility()
	_rebuild_preview()


func _on_route_changed() -> void:
	_update_control_visibility()
	_on_draft_changed()


func _on_draft_changed() -> void:
	if _syncing:
		return
	_read_draft_from_controls()
	_update_control_visibility()
	_schedule_preview_rebuild()


func _schedule_preview_rebuild() -> void:
	if _preview_debounce == null:
		_preview_debounce = Timer.new()
		_preview_debounce.one_shot = true
		_preview_debounce.wait_time = 0.1
		_preview_debounce.timeout.connect(_rebuild_preview)
		add_child(_preview_debounce)
	_preview_debounce.start()


## Show only the controls that matter for the current type + routing.
func _update_control_visibility() -> void:
	var eff := _effective_type_id()
	var conceptual := ConduitKinds.is_conceptual_type(eff)
	var light := ConduitKinds.is_light_type(eff)
	var glow_type := conceptual or light
	var kit := ConduitKinds.uses_pipe_kit(eff)
	var culvert := ConduitKinds.uses_culvert_kit(eff)
	var rm := ConduitKinds.normalize_route_mode(str(_route_opt.get_item_metadata(_route_opt.selected)))
	if rm.is_empty():
		rm = ConduitKinds.normalize_route_mode(str(ConduitKinds.type_meta(eff).get("route_mode", "")))
	var is_pipes := rm == "pipes" or (rm.is_empty() and ConduitKinds.is_pipes_type(eff) and not culvert)
	var is_culvert_rm := rm == "culvert" or culvert
	var can_sag := rm == "catenary" or rm == "direct" or rm == "" \
			or ConduitKinds.is_flexible_type(eff) or ConduitKinds.is_ground_drape_type(eff)
	if _row_size != null:
		_row_size.visible = kit
	# Kit OD is baked into fittings — thickness slider is misleading.
	_row_radius.visible = not kit
	_row_roughness.visible = not glow_type
	_hdr_glow.visible = glow_type
	_row_glow.visible = glow_type
	_row_emission.visible = glow_type
	_row_flow_color.visible = glow_type
	_row_flow_glow.visible = glow_type
	_row_fitting.visible = is_pipes and not kit and not is_culvert_rm
	_row_elbow.visible = (is_pipes or rm == "ortho") and not kit and not is_culvert_rm
	_row_slack.visible = can_sag and rm != "taut" and not kit


# ---------------------------------------------------------------------------
# Preview
# ---------------------------------------------------------------------------

func _rebuild_preview() -> void:
	if _viewport == null:
		return
	if _studio == null or not is_instance_valid(_studio):
		_setup_studio()
	# Clear previous conduit + fittings (keep the studio rig).
	for c in _studio.get_children():
		if c.has_meta("preview_conduit"):
			c.queue_free()

	var a := Vector3(-PREVIEW_LEN_M * 0.5, 0.55, -0.5)
	var b := Vector3(PREVIEW_LEN_M * 0.5, 0.55, 0.7)
	var type_id := _effective_type_id()
	var meta := ConduitKinds.type_meta(type_id)
	var rm := ConduitKinds.normalize_route_mode(str(_draft.get("route_mode", meta.get("route_mode", ""))))
	var elbow := float(_draft.get("elbow_radius_frac", meta.get("elbow_radius_frac", 0.35)))
	var flat := func(_p: Vector3) -> float: return 0.0
	var control: Array = []
	match rm:
		"ortho":
			for p: Vector3 in ConduitOrthoRouter.route(a, b, [], true, elbow):
				control.append(p)
		"culvert":
			var r_bend := CulvertKit.bend_radius_for_type(type_id, _draft)
			for p: Vector3 in CulvertRouter.expand([a, b], r_bend):
				control.append(p)
		"pipes":
			var fs := ConduitKinds.fitting_step_deg(type_id, _draft)
			var ef := 0.0 if ConduitKinds.uses_pipe_kit(type_id) \
					and not ConduitKinds.uses_culvert_kit(type_id) else elbow
			for p: Vector3 in ConduitPipesRouter.route(a, b, [], flat, 0.06, ef, [], fs):
				control.append(p)
		_:
			if ConduitKinds.uses_culvert_kit(type_id):
				var r2 := CulvertKit.bend_radius_for_type(type_id, _draft)
				for p: Vector3 in CulvertRouter.expand([a, b], r2):
					control.append(p)
			elif ConduitKinds.is_pipes_type(type_id):
				var fs2 := ConduitKinds.fitting_step_deg(type_id, _draft)
				var ef2 := 0.0 if ConduitKinds.uses_pipe_kit(type_id) else elbow
				for p: Vector3 in ConduitPipesRouter.route(a, b, [], flat, 0.06, ef2, [], fs2):
					control.append(p)
			else:
				control = [a, b]
	if control.size() < 2:
		control = [a, b]

	var tint: Color = _draft.get("color", meta.get("color", Color.WHITE)) as Color
	# Culvert PE: stamp corrugation rings along the wide-arc preview path.
	if ConduitKinds.uses_culvert_kit(type_id):
		var ckit := CulvertKit.load_kit(ConduitKinds.pipe_kit_id(type_id, _draft))
		if ckit != null:
			var path := PackedVector3Array()
			for p: Variant in control:
				if p is Vector3:
					path.append(p as Vector3)
			var host := Node3D.new()
			host.set_meta("preview_conduit", true)
			_studio.add_child(host)
			var cmat := ConduitKinds.make_pipe_kit_material(type_id, tint)
			cmat.roughness = float(_draft.get("roughness", meta.get("roughness", 0.7)))
			var applied := CulvertAssembler.apply(host, "preview", path, ckit, cmat)
			if bool(applied.get("ok", false)):
				return
	# Kit-backed PVC/ABS: show real straight/elbow MultiMeshes in the preview.
	if ConduitKinds.uses_pipe_kit(type_id) and not ConduitKinds.uses_culvert_kit(type_id):
		var kit := PipeKit.load_kit(ConduitKinds.pipe_kit_id(type_id, _draft))
		if kit != null:
			var sharp := PackedVector3Array()
			for p: Variant in control:
				if p is Vector3:
					sharp.append(p as Vector3)
			var bom := PipePartsPlanner.plan(sharp, kit)
			if bool(bom.get("ok", false)):
				var host2 := Node3D.new()
				host2.set_meta("preview_conduit", true)
				_studio.add_child(host2)
				var pmat := ConduitKinds.make_pipe_kit_material(type_id, tint)
				pmat.roughness = float(_draft.get("roughness", meta.get("roughness", 0.7)))
				PipePartsAssembler.apply(host2, "preview", bom, kit, pmat)
				return

	var style_ov: Dictionary = {}
	for k: String in ConduitStylePresets.STYLE_KEYS:
		if _draft.has(k):
			style_ov[k] = _draft[k]
	# Route-mode sag/drape behaviour so the preview tube matches the routing.
	var mesh_style := style_ov.duplicate(true)
	for msk: String in ConduitKinds.mesh_style_override(rm).keys():
		if not mesh_style.has(msk):
			mesh_style[msk] = ConduitKinds.mesh_style_override(rm)[msk]

	var built := ConduitMeshBuilder.build(control, type_id, 16, Callable(), mesh_style)
	var mi := MeshInstance3D.new()
	mi.set_meta("preview_conduit", true)
	mi.mesh = built.get("mesh", null)

	var conceptual := ConduitKinds.is_conceptual_type(type_id)
	var light := ConduitKinds.is_light_type(type_id)
	var glow: bool = conceptual or light or bool(_draft.get("flow_glow", false))
	if glow:
		var fmat := ConduitKinds.make_flow_material(type_id, tint,
			float(_draft.get("flow_strength_default", 0.7)), 1.3)
		fmat.set_shader_parameter("base_color", tint)
		fmat.set_shader_parameter("flow_color", _draft.get("flow_color", tint.lightened(0.4)))
		fmat.set_shader_parameter("emission_boost", float(_draft.get("emission_energy", 1.8)))
		fmat.set_shader_parameter("conceptual", 1.0 if conceptual else 0.0)
		mi.material_override = fmat
	else:
		# The REAL physical material (PVC clearcoat white, hose green, etc.).
		var pmat2 := ConduitKinds.make_material(type_id, tint)
		pmat2.roughness = float(_draft.get("roughness", meta.get("roughness", 0.7)))
		mi.material_override = pmat2
	_studio.add_child(mi)

	var draft_r := float(_draft.get("radius_m", meta.get("radius_m", 0.02)))
	# End plugs.
	for endp: Vector3 in [control[0] as Vector3, control[control.size() - 1] as Vector3]:
		var plug := MeshInstance3D.new()
		plug.set_meta("preview_conduit", true)
		var cap := SphereMesh.new()
		cap.radius = maxf(draft_r * 1.7, 0.02)
		cap.height = cap.radius * 2.0
		plug.mesh = cap
		plug.position = endp
		plug.material_override = ConduitKinds.make_fitting_material(type_id)
		_studio.add_child(plug)
	# Elbow collar sleeves for collared pipe kinds — a wider tube that follows the
	# pipe through each bend (matches ConduitManager._make_collar_sleeve).
	if bool(meta.get("fitting_collars", false)):
		var samples: PackedVector3Array = built.get("sample_points", PackedVector3Array())
		if samples.size() >= 3:
			for bd: Variant in ConduitManager._detect_bend_points(samples, 22.0):
				var bdd: Dictionary = bd
				var i0: int = clampi(int(bdd.get("i0", 0)) - 1, 0, samples.size() - 1)
				var i1: int = clampi(int(bdd.get("i1", 0)) + 1, 0, samples.size() - 1)
				if i1 - i0 < 1:
					continue
				var sub := PackedVector3Array()
				for k: int in range(i0, i1 + 1):
					sub.append(samples[k])
				var collar := MeshInstance3D.new()
				collar.set_meta("preview_conduit", true)
				collar.mesh = ConduitMeshBuilder.build_tube(sub, draft_r * 1.35, 12)
				collar.material_override = ConduitKinds.make_fitting_material(type_id)
				_studio.add_child(collar)
	_update_camera()


func _setup_studio() -> void:
	for c in _viewport.get_children():
		c.queue_free()
	_studio = Node3D.new()
	_viewport.add_child(_studio)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-42, 35, 0)
	key.light_energy = 1.15
	key.shadow_enabled = true
	_studio.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-20, -130, 0)
	fill.light_energy = 0.4
	fill.light_color = Color(0.8, 0.85, 1.0)
	_studio.add_child(fill)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.08, 0.1, 0.14)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.45, 0.5, 0.58)
	e.ambient_light_energy = 0.55
	e.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.environment = e
	_studio.add_child(env)
	_camera = Camera3D.new()
	_camera.current = true
	_studio.add_child(_camera)
	# Soft studio floor with a subtle grid feel via a dark matte plane.
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(10, 10)
	ground.mesh = plane
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.16, 0.17, 0.2)
	gm.roughness = 0.95
	ground.material_override = gm
	ground.position.y = -0.02
	_studio.add_child(ground)


func _update_camera() -> void:
	if _camera == null or not is_instance_valid(_camera):
		return
	_cam_pitch = clampf(_cam_pitch, -1.4, 1.4)
	_cam_dist = clampf(_cam_dist, 1.6, 9.0)
	var offset := Basis.from_euler(Vector3(_cam_pitch, _cam_yaw, 0.0)) * Vector3(0.0, 0.0, _cam_dist)
	_camera.position = _cam_target + offset
	_camera.look_at(_cam_target, Vector3.UP)


func _on_preview_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_orbiting = mb.pressed
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_cam_dist *= 0.9
			_update_camera()
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_cam_dist *= 1.1
			_update_camera()
			accept_event()
	elif event is InputEventMouseMotion and _orbiting:
		var mm := event as InputEventMouseMotion
		_cam_yaw -= mm.relative.x * 0.01
		_cam_pitch -= mm.relative.y * 0.01
		_update_camera()
		accept_event()


func _input(event: InputEvent) -> void:
	if visible and event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_ESCAPE:
		close()
		get_viewport().set_input_as_handled()


# ---------------------------------------------------------------------------
# Apply + presets
# ---------------------------------------------------------------------------

func _on_apply() -> void:
	_read_draft_from_controls()
	if _model == null or _conn_id.is_empty():
		return
	var patch: Dictionary = {"conduit_type": str(_draft.get("conduit_type", ""))}
	var style: Dictionary = {}
	for k: String in ConduitStylePresets.STYLE_KEYS:
		if _draft.has(k):
			style[k] = _draft[k]
	if _draft.has("fitting_step_deg"):
		style["fitting_step_deg"] = _draft["fitting_step_deg"]
	patch["conduit_style"] = style
	patch["visible_3d"] = _draft["visible_3d"] if _draft.has("visible_3d") else null
	patch["flow_glow"] = _draft["flow_glow"] if _draft.has("flow_glow") else null
	_model.update_connection(_conn_id, patch)
	_status_lbl.text = "✓ Applied to wire"
	style_applied.emit(_conn_id)
	var mgr := _main.get_node_or_null("ConduitManager") if _main != null else null
	# Force this wire now — sync_all's dirty gate can skip kit reseat when
	# endpoints/anchors look unchanged after a type/size/style swap.
	if mgr != null and mgr.has_method("force_remesh"):
		mgr.call("force_remesh", _conn_id)
	elif mgr != null and mgr.has_method("sync_all"):
		mgr.call("sync_all")


func _on_reset_autoroute() -> void:
	if _main == null:
		return
	var mgr := _main.get_node_or_null("ConduitManager")
	if mgr != null and mgr.has_method("reset_autoroute"):
		mgr.call("reset_autoroute", _conn_id)
		_status_lbl.text = "Auto-route reset"
		style_applied.emit(_conn_id)


func _current_style_dict() -> Dictionary:
	_read_draft_from_controls()
	var style: Dictionary = {}
	for k: String in ConduitStylePresets.STYLE_KEYS:
		if _draft.has(k):
			style[k] = _draft[k]
	return style


func _on_save_type_default() -> void:
	var type_id := _effective_type_id()
	if ConduitStylePresets.set_type_defaults(type_id, _current_style_dict()):
		_status_lbl.text = "✓ Default saved for %s" % ConduitKinds.display_name(type_id)
		ConduitStylePresets.reload()
	else:
		_status_lbl.text = "Could not save type default"


func _on_save_named() -> void:
	var label := _preset_name_edit.text.strip_edges()
	var type_id := _effective_type_id()
	if label.is_empty():
		label = "%s style" % ConduitKinds.display_name(type_id)
	var id := ConduitStylePresets.save_named(label, type_id, _current_style_dict())
	_status_lbl.text = ("✓ Saved “%s”" % label) if not id.is_empty() else "Save failed"
	_refresh_named_list()


func _refresh_named_list() -> void:
	if _named_list == null:
		return
	_named_list.clear()
	for p: Variant in ConduitStylePresets.list_named():
		var d: Dictionary = p as Dictionary
		_named_list.add_item("%s  (%s)" % [
			str(d.get("label", "")), ConduitKinds.display_name(str(d.get("base_type", "")))])
		_named_list.set_item_metadata(_named_list.item_count - 1, str(d.get("id", "")))


func _on_load_named() -> void:
	var sel := _named_list.get_selected_items()
	if not sel.is_empty():
		_apply_named(str(_named_list.get_item_metadata(sel[0])))


func _on_named_activated(idx: int) -> void:
	_apply_named(str(_named_list.get_item_metadata(idx)))


func _apply_named(preset_id: String) -> void:
	var entry := ConduitStylePresets.named_by_id(preset_id)
	if entry.is_empty():
		return
	var style: Dictionary = entry.get("style", {}) as Dictionary
	_draft["conduit_type"] = str(entry.get("base_type", ""))
	for k: Variant in style.keys():
		_draft[k] = style[k]
	_syncing = true
	_sync_controls_from_draft()
	_syncing = false
	_update_control_visibility()
	_rebuild_preview()
	_status_lbl.text = "Loaded “%s”" % str(entry.get("label", ""))
