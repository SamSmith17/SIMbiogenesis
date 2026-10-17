extends Control

## Style editor for one 3D conduit / graph connection, LIVE.
##
## Every control writes straight to the wire (debounced 0.15 s) and the run in
## the world remeshes, so what you see out there is what you are setting. The
## preview is a copy of THAT run — its real path, length and fittings, framed
## on its own bounds, with the two devices it joins as ghost boxes — not a
## sample on a studio floor. A wire with nothing drawn in 3D yet (3D wires off,
## never revealed) falls back to a short sample in its material.
##
## Revert puts the wire back the way it was when the modal opened; Done (or
## Esc) keeps the changes. The whole visit is ONE undo step: the live writes
## run with the graph's history suppressed and one entry is pushed on close.
##
## The header measures the run: true length (sag and drape included — the
## route_length_m the run stamps), straight-line distance, rise or fall, the
## stock length that covers it, and for an electric run its live I²R loss.

signal style_applied(conn_id: String)
signal closed()

const MODAL_NAME := "conduit_style"
const PREVIEW_LEN_M := 4.2
const WANT_SIZE := Vector2(1240.0, 820.0)
const OPTS := preload("res://scenes/ui/conduit_style_options.gd")

var _conn_id: String = ""
var _model: GraphModel = null
var _main: Node = null
var _draft: Dictionary = {}          ## working style + conduit_type + flags
var _derived_type: String = "extension_cord"  ## the wire's resolved kind (for "Auto")
var _built := false
var _syncing := false                ## guard control→draft while seeding
var _orig: Dictionary = {}           ## the wire as it was on open (Revert)
var _changed := false                ## anything written this visit (one undo step)

# Preview
var _panel: PanelContainer = null
var _vp_container: SubViewportContainer = null
var _viewport: SubViewport = null
var _studio: Node3D = null
var _camera: Camera3D = null
var _cam_target := Vector3(0.0, 0.35, 0.0)
var _cam_yaw := 0.6
var _cam_pitch := 0.5
var _cam_dist := 4.6
var _cam_dist_min := 1.6
var _cam_dist_max := 9.0
var _orbiting := false
var _auto_rotate := true
var _preview_kind := ""               ## "run" (the real run) | "sample"
var _preview_lbl: Label = null

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
var _measure_lbl: Label = null
var _rotate_chk: CheckButton = null
var _preview_debounce: Timer = null
var _apply_debounce: Timer = null

# Rows (for per-type show/hide) + section headers
var _row_size: Control = null
var _row_radius: Control = null
var _row_roughness: Control = null
var _row_glow: Control = null
var _row_emission: Control = null
var _row_flow_color: Control = null
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
	_snapshot_original()
	_changed = false
	_load_draft_from_connection()
	_syncing = true
	_sync_controls_from_draft()
	_syncing = false
	_update_control_visibility()
	_rebuild_preview()
	_refresh_named_list()
	_refresh_measurements()
	_status_lbl.text = "Changes apply to the wire as you make them"
	visible = true
	set_process(true)
	UiFit.keep_fitted(_panel, WANT_SIZE)
	CursorController.request_modal(MODAL_NAME, Callable(self, "close"))


## Done / Esc: keep what was set. The visit is one undo step.
func close() -> void:
	if not visible:
		return
	_flush_live_apply()
	visible = false
	set_process(false)
	CursorController.release_modal(MODAL_NAME)
	if _changed:
		var gv := _graph_view()
		if gv != null and gv.has_method("_push_history"):
			gv.call("_push_history")
			if gv.has_method("_update_undo_redo_btns"):
				gv.call("_update_undo_redo_btns")
		if gv != null and gv.has_method("_schedule_graph_autosave"):
			gv.call("_schedule_graph_autosave")
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

	# Sized by UiFit: centred above the timeline, never larger than that area.
	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", UITheme.panel_style())
	add_child(_panel)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	_panel.add_child(root)

	# Header
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	root.add_child(head)
	var head_txt := VBoxContainer.new()
	head_txt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(head_txt)
	_title_lbl = Label.new()
	_title_lbl.text = "Conduit"
	_title_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XL)
	_title_lbl.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	head_txt.add_child(_title_lbl)
	_subtitle_lbl = Label.new()
	_subtitle_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_subtitle_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	head_txt.add_child(_subtitle_lbl)
	var head_x := Button.new()
	IconButton.as_close(head_x, "Done (Esc) — keeps your changes")
	head_x.pressed.connect(close)
	head.add_child(head_x)

	# Measurements strip — the run in numbers.
	var meas := PanelContainer.new()
	meas.add_theme_stylebox_override("panel", UITheme.card_style())
	root.add_child(meas)
	_measure_lbl = Label.new()
	_measure_lbl.add_theme_font_size_override("font_size", UITheme.FONT_MD)
	_measure_lbl.add_theme_font_override("font", UITheme.font("medium", true))
	_measure_lbl.add_theme_color_override("font_color", UITheme.C_TEXT)
	_measure_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	meas.add_child(_measure_lbl)

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
	_status_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_status_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_status_lbl.clip_text = true
	_status_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	bar.add_child(_status_lbl)
	var reset_btn := Button.new()
	reset_btn.text = "Reset auto-route"
	reset_btn.tooltip_text = "Clear manual bends and re-run automatic routing"
	reset_btn.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(reset_btn)
	reset_btn.pressed.connect(_on_reset_autoroute)
	bar.add_child(reset_btn)
	var revert_btn := Button.new()
	revert_btn.text = "Revert"
	revert_btn.tooltip_text = "Put the wire back the way it was when this opened"
	revert_btn.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(revert_btn)
	revert_btn.pressed.connect(_on_revert)
	bar.add_child(revert_btn)
	var done_btn := Button.new()
	done_btn.text = "Done"
	done_btn.tooltip_text = "Close — the changes are already on the wire"
	done_btn.custom_minimum_size = Vector2(110, 34)
	done_btn.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(done_btn)
	done_btn.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	done_btn.pressed.connect(close)
	bar.add_child(done_btn)


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
	vp_panel.custom_minimum_size = Vector2(320, 240)
	vp_panel.add_child(_vp_container)
	col.add_child(vp_panel)

	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.transparent_bg = false
	_viewport.msaa_3d = Viewport.MSAA_4X
	_viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE  # idle while the modal is hidden
	_vp_container.add_child(_viewport)

	_preview_lbl = Label.new()
	_preview_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_preview_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_preview_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_preview_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_preview_lbl)
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
	scroll.custom_minimum_size = Vector2(360, 0)
	parent.add_child(scroll)
	var form := VBoxContainer.new()
	form.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	form.add_theme_constant_override("separation", 7)
	scroll.add_child(form)

	form.add_child(_section("What it is"))
	_type_opt = _add_opt(form, OPTS.LABEL_TYPE)
	OPTS.fill_types(_type_opt)
	_type_opt.item_selected.connect(func(_i: int) -> void: _on_type_changed())
	_size_opt = _add_opt(form, OPTS.LABEL_SIZE)
	_row_size = _size_opt.get_parent()
	OPTS.fill_sizes(_size_opt, _derived_type)
	_size_opt.item_selected.connect(func(_i: int) -> void: _on_draft_changed())

	form.add_child(_section("Routing"))
	_route_opt = _add_opt(form, OPTS.LABEL_ROUTE)
	OPTS.fill_route_modes(_route_opt)
	_route_opt.item_selected.connect(func(_i: int) -> void: _on_route_changed())
	_fitting_opt = _add_opt(form, OPTS.LABEL_FITTING)
	OPTS.fill_fittings(_fitting_opt)
	_fitting_opt.item_selected.connect(func(_i: int) -> void: _on_draft_changed())
	_row_fitting = _fitting_opt.get_parent()
	_elbow_slider = _add_slider(form, "Elbow roundness", 0.0, 0.45, 0.01)
	_row_elbow = _elbow_slider.get_parent()
	_slack_slider = _add_slider(form, "Slack / sag", 0.0, 0.8, 0.01, "m")
	_row_slack = _slack_slider.get_parent()

	form.add_child(_section("Appearance"))
	_color_picker = _add_color(form, "Colour")
	_radius_slider = _add_slider(form, "Thickness (Ø)", 0.003, 0.09, 0.001, "m")
	_row_radius = _radius_slider.get_parent()
	_roughness_slider = _add_slider(form, "Roughness", 0.0, 1.0, 0.02)
	_row_roughness = _roughness_slider.get_parent()

	_hdr_glow = _section("Glow / flow")
	form.add_child(_hdr_glow)
	_glow_slider = _add_slider(form, "Flow strength", 0.0, 2.0, 0.05)
	_row_glow = _glow_slider.get_parent()
	_emission_slider = _add_slider(form, "Emission", 0.0, 5.0, 0.05)
	_row_emission = _emission_slider.get_parent()
	_flow_color_picker = _add_color(form, "Flow colour")
	_row_flow_color = _flow_color_picker.get_parent()
	_flow_glow_opt = _add_opt(form, "Flow glow")
	_flow_glow_opt.add_item("Follow default", 0)
	_flow_glow_opt.add_item("On", 1)
	_flow_glow_opt.add_item("Off", 2)
	_flow_glow_opt.item_selected.connect(func(_i: int) -> void: _on_draft_changed())
	_row_flow_glow = _flow_glow_opt.get_parent()

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
	save_type_btn.text = "Set as default for this kind"
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


func _section(text: String) -> Control:
	return SectionHeader.make(text)


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
	opt.fit_to_longest_item = false
	opt.clip_text = true
	row.add_child(opt)
	parent.add_child(row)
	return opt


func _add_slider(parent: Control, label: String, mn: float, mx: float, step: float,
		unit: String = "") -> HSlider:
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
	val.custom_minimum_size.x = 64
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	val.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	row.add_child(val)
	sl.value_changed.connect(func(v: float) -> void:
		var t := ("%.3f" % v) if step < 0.01 else ("%.2f" % v)
		val.text = t + ((" " + unit) if not unit.is_empty() else "")
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


# ---------------------------------------------------------------------------
# Draft <-> controls
# ---------------------------------------------------------------------------

const _ORIG_KEYS := ["conduit_type", "conduit_style", "visible_3d", "flow_glow",
	"route_3d", "route_locked"]
## Values written back by Revert for keys the wire did not carry (a null
## route would break readers that expect an Array / bool).
const _ORIG_DEFAULTS := {"route_3d": [], "route_locked": false}


func _snapshot_original() -> void:
	_orig = {}
	if _model == null:
		return
	var conn := _model.get_connection(_conn_id)
	for k in _ORIG_KEYS:
		_orig[k] = conn[k] if conn.has(k) else _ORIG_DEFAULTS.get(k, null)
		if _orig[k] is Dictionary or _orig[k] is Array:
			_orig[k] = _orig[k].duplicate(true)


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
	OPTS.fill_sizes(_size_opt, _effective_type_id())
	_refresh_titles()


func _refresh_titles() -> void:
	var conn := _model.get_connection(_conn_id) if _model != null else {}
	var a := _model.get_item(str(conn.get("source_item_id", ""))) if _model != null else {}
	var b := _model.get_item(str(conn.get("target_item_id", ""))) if _model != null else {}
	_title_lbl.text = ConduitKinds.display_name_with_size(_effective_type_id(), _draft)
	var sub := "%s  →  %s" % [GraphPortLabels.node_name(a), GraphPortLabels.node_name(b)]
	var eff := _effective_type_id()
	if ConduitKinds.uses_culvert_kit(eff):
		sub += "  ·  corrugated PE culvert, wide-arc routing"
	elif ConduitKinds.uses_pipe_kit(eff):
		sub += "  ·  real fittings (Sch40 PVC / ABS)"
	_subtitle_lbl.text = sub


## The type actually used for preview/material: explicit selection, or the wire's
## resolved kind when set to "Auto".
func _effective_type_id() -> String:
	var ctype := str(_draft.get("conduit_type", ""))
	return ctype if not ctype.is_empty() else _derived_type


func _sync_controls_from_draft() -> void:
	OPTS.select_meta(_type_opt, str(_draft.get("conduit_type", "")))
	var eff := _effective_type_id()
	var meta := ConduitKinds.type_meta(eff)
	if _size_opt != null:
		OPTS.select_meta(_size_opt, ConduitKinds.pipe_size_in(eff, _draft))
	_color_picker.color = _draft.get("color", meta.get("color", Color.WHITE)) as Color
	_radius_slider.value = float(_draft.get("radius_m", meta.get("radius_m", 0.02)))
	_roughness_slider.value = float(_draft.get("roughness", meta.get("roughness", 0.7)))
	_glow_slider.value = float(_draft.get("flow_strength_default", 0.7))
	_emission_slider.value = float(_draft.get("emission_energy", meta.get("emission_energy", 1.8)))
	_flow_color_picker.color = _draft.get("flow_color", _color_picker.color.lightened(0.4)) as Color
	var rm := ConduitKinds.normalize_route_mode(str(_draft.get("route_mode",
		meta.get("route_mode", ""))))
	OPTS.select_meta(_route_opt, rm)
	OPTS.select_meta(_fitting_opt, float(_draft.get("fitting_step_deg", 0.0)))
	_elbow_slider.value = float(_draft.get("elbow_radius_frac", meta.get("elbow_radius_frac", 0.35)))
	_slack_slider.value = float(_draft.get("end_slack_m", meta.get("end_slack_m",
		meta.get("sag_amount", 0.0))))
	_visible_opt.select(1 if _draft.get("visible_3d") == true else (2 if _draft.get("visible_3d") == false else 0))
	_flow_glow_opt.select(1 if _draft.get("flow_glow") == true else (2 if _draft.get("flow_glow") == false else 0))


func _read_draft_from_controls() -> void:
	_draft["conduit_type"] = str(_type_opt.get_item_metadata(_type_opt.selected))
	var eff := _effective_type_id()
	var glow_type := ConduitKinds.is_conceptual_type(eff) or ConduitKinds.is_light_type(eff)
	if _size_opt != null and ConduitKinds.has_size_options(eff) and _size_opt.item_count > 0:
		_draft["pipe_size_in"] = float(_size_opt.get_item_metadata(_size_opt.selected))
	elif _draft.has("pipe_size_in") and not ConduitKinds.has_size_options(eff):
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
	var fs := float(_fitting_opt.get_item_metadata(_fitting_opt.selected))
	if fs < 0.5:
		_draft.erase("fitting_step_deg")
	else:
		_draft["fitting_step_deg"] = fs
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
	if ConduitKinds.has_size_options(eff):
		_draft["pipe_size_in"] = float(meta.get("default_pipe_size_in", 1.25))
	if keep_vis != null:
		_draft["visible_3d"] = keep_vis
	if keep_glow != null:
		_draft["flow_glow"] = keep_glow
	OPTS.fill_sizes(_size_opt, eff)
	_syncing = true
	_sync_controls_from_draft()
	_syncing = false
	_update_control_visibility()
	_refresh_titles()
	_schedule_live_apply()


func _on_route_changed() -> void:
	_update_control_visibility()
	_on_draft_changed()


func _on_draft_changed() -> void:
	if _syncing:
		return
	_read_draft_from_controls()
	_update_control_visibility()
	_schedule_live_apply()


## Live: every change reaches the wire 0.15 s after the last one.
func _schedule_live_apply() -> void:
	if _apply_debounce == null:
		_apply_debounce = Timer.new()
		_apply_debounce.one_shot = true
		_apply_debounce.wait_time = 0.15
		_apply_debounce.timeout.connect(func() -> void: _apply_to_wire())
		add_child(_apply_debounce)
	_apply_debounce.start()
	_status_lbl.text = "Updating the wire…"


func _flush_live_apply() -> void:
	if _apply_debounce != null and not _apply_debounce.is_stopped():
		_apply_debounce.stop()
		_apply_to_wire()


func _schedule_preview_rebuild(after_s: float = 0.1) -> void:
	if _preview_debounce == null:
		_preview_debounce = Timer.new()
		_preview_debounce.one_shot = true
		_preview_debounce.timeout.connect(_rebuild_preview)
		add_child(_preview_debounce)
	_preview_debounce.wait_time = after_s
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
		_row_size.visible = kit or ConduitKinds.has_size_options(eff)
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
# Writing to the wire (live), Revert
# ---------------------------------------------------------------------------

func _graph_view() -> Node:
	var gv := ServiceLocator.graph()
	if gv == null and get_tree() != null:
		gv = get_tree().root.find_child("SystemGraphView", true, false)
	return gv


func _manager() -> Node:
	return _main.get_node_or_null("ConduitManager") if _main != null else null


func _write_patch(patch: Dictionary) -> void:
	var gv := _graph_view()
	var was := false
	if gv != null:
		was = bool(gv.get("_history_suppress"))
		gv.set("_history_suppress", true)
	_model.update_connection(_conn_id, patch)
	if gv != null:
		gv.set("_history_suppress", was)
	var mgr := _manager()
	# Force this wire now — sync_all's dirty gate can skip kit reseat when
	# endpoints/anchors look unchanged after a type/size/style swap.
	if mgr != null and mgr.has_method("force_remesh"):
		mgr.call("force_remesh", _conn_id)
	elif mgr != null and mgr.has_method("sync_all"):
		mgr.call("sync_all")
	_changed = true
	style_applied.emit(_conn_id)


func _apply_to_wire() -> void:
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
	_write_patch(patch)
	_status_lbl.text = "✓ On the wire"
	_refresh_measurements()
	# The run remeshes this frame or next; preview it once it has.
	_schedule_preview_rebuild(0.2)


func _on_revert() -> void:
	if _model == null or _orig.is_empty():
		return
	if _apply_debounce != null:
		_apply_debounce.stop()
	var patch := {}
	for k in _ORIG_KEYS:
		patch[k] = _orig[k]
		if patch[k] is Dictionary or patch[k] is Array:
			patch[k] = patch[k].duplicate(true)
	_write_patch(patch)
	_changed = false
	_load_draft_from_connection()
	_syncing = true
	_sync_controls_from_draft()
	_syncing = false
	_update_control_visibility()
	_refresh_measurements()
	_schedule_preview_rebuild(0.2)
	_status_lbl.text = "Reverted to how the wire was"


func _on_reset_autoroute() -> void:
	var mgr := _manager()
	if mgr != null and mgr.has_method("reset_autoroute"):
		mgr.call("reset_autoroute", _conn_id)
		_changed = true
		_status_lbl.text = "Auto-route reset"
		style_applied.emit(_conn_id)
		_refresh_measurements()
		_schedule_preview_rebuild(0.2)


# ---------------------------------------------------------------------------
# Measurements
# ---------------------------------------------------------------------------

## The run in numbers: true length (ConduitLength, the run's own stamped
## route_length_m), straight line between the ends, rise/fall, stock fit,
## and for an electric run its live I²R loss.
func _refresh_measurements() -> void:
	if _measure_lbl == null or _model == null:
		return
	var conn := _model.get_connection(_conn_id)
	var eff := _effective_type_id()
	var len_m := float(conn.get("route_length_m", 0.0))
	var parts := PackedStringArray()
	if len_m > 0.001:
		parts.append("Run %s" % ConduitLength.describe(len_m, eff))
	else:
		parts.append("Not routed in 3D yet — no measured length")
	var ends := _end_points(conn)
	if ends.size() == 2:
		var a: Vector3 = ends[0]
		var b: Vector3 = ends[1]
		var straight := a.distance_to(b)
		parts.append("straight %s" % ConduitLength.format(straight))
		var dy := b.y - a.y
		if absf(dy) >= 0.05:
			parts.append("%s %.1f m" % ["rises" if dy > 0.0 else "falls", absf(dy)])
	var loss := float(conn.get("loss_w", 0.0))
	if loss > 0.05:
		parts.append("loses %s" % UiText.num(loss, "W"))
	_measure_lbl.text = "  ·  ".join(parts)


func _end_points(conn: Dictionary) -> Array:
	var mgr := _manager()
	if mgr == null or _model == null:
		return []
	var tree := get_tree()
	var a: Vector3 = ConduitManager.anchor_global_for_item(_model.get_item(str(conn.get("source_item_id", ""))),
		tree, str(conn.get("source_handle_id", "")), _main)
	var b: Vector3 = ConduitManager.anchor_global_for_item(_model.get_item(str(conn.get("target_item_id", ""))),
		tree, str(conn.get("target_handle_id", "")), _main)
	if not is_finite(a.x) or not is_finite(b.x):
		return []
	return [a, b]


# ---------------------------------------------------------------------------
# Preview
# ---------------------------------------------------------------------------

func _clear_preview() -> void:
	if _studio == null or not is_instance_valid(_studio):
		_setup_studio()
	for c in _studio.get_children():
		if c.has_meta("preview_conduit"):
			c.queue_free()


## The real run if it is drawn in 3D; a sample in its material otherwise.
func _rebuild_preview() -> void:
	if _viewport == null:
		return
	_clear_preview()
	var mgr := _manager()
	var copy: Node3D = null
	if mgr != null and mgr.has_method("run_visual_copy"):
		copy = mgr.call("run_visual_copy", _conn_id) as Node3D
	if copy != null:
		_show_real_run(copy)
	else:
		_rebuild_sample_preview()


func _show_real_run(copy: Node3D) -> void:
	_preview_kind = "run"
	var aabb := _tree_aabb(copy)
	var center := aabb.get_center()
	# Recentre the run on the studio origin (it carries world transforms).
	copy.position = -center
	copy.set_meta("preview_conduit", true)
	_studio.add_child(copy)
	# Ghost boxes for the two devices it joins.
	var conn := _model.get_connection(_conn_id)
	var ends := _end_points(conn)
	for e in ends:
		var g := MeshInstance3D.new()
		g.set_meta("preview_conduit", true)
		var bm := BoxMesh.new()
		var s := clampf(aabb.get_longest_axis_size() * 0.04, 0.2, 1.2)
		bm.size = Vector3(s, s, s)
		g.mesh = bm
		var gm := StandardMaterial3D.new()
		gm.albedo_color = Color(0.6, 0.75, 0.95, 0.28)
		gm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		gm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		g.material_override = gm
		g.position = (e as Vector3) - center
		_studio.add_child(g)
	# Ground grid under the run, at its lowest point.
	var floor_y := aabb.position.y - center.y - 0.05
	var ground := _studio.get_node_or_null("Ground") as MeshInstance3D
	if ground != null:
		ground.position.y = floor_y
		(ground.mesh as PlaneMesh).size = Vector2(1, 1) * maxf(10.0, aabb.get_longest_axis_size() * 1.4)
	var ext := maxf(aabb.get_longest_axis_size(), 1.0)
	_add_path_highlight(conn, center, ext)
	_cam_target = Vector3.ZERO
	_cam_dist_min = maxf(0.6, ext * 0.25)
	_cam_dist_max = ext * 3.0
	_cam_dist = clampf(ext * 1.15, _cam_dist_min, _cam_dist_max)
	_preview_lbl.text = "The run as drawn in the world · drag to orbit · scroll to zoom"
	_update_camera()


## A long run is a few millimetres thick: framed whole, the real tube is a
## hairline. A translucent highlight tube along the same path (thickness
## scaled to the view) shows where it goes; the real tube is inside it.
func _add_path_highlight(conn: Dictionary, center: Vector3, ext: float) -> void:
	var mgr := _manager()
	if mgr == null:
		return
	var pts: PackedVector3Array = mgr.call("get_sample_points", _conn_id) if mgr.has_method("get_sample_points") \
		else PackedVector3Array()
	if pts.size() < 2 and mgr.has_method("build_control_points"):
		pts = PackedVector3Array(mgr.call("build_control_points", conn))
	if pts.size() < 2:
		return
	var local := PackedVector3Array()
	for p in pts:
		local.append(p - center)
	var r := clampf(ext * 0.004, 0.01, 0.5)
	var draft_r := float(_draft.get("radius_m", 0.0))
	if draft_r * 3.0 > r:
		return   # thick enough to read on its own
	var mi := MeshInstance3D.new()
	mi.set_meta("preview_conduit", true)
	mi.mesh = ConduitMeshBuilder.build_tube(local, r, 8)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var tint: Color = _draft.get("color", ConduitKinds.type_meta(_effective_type_id()).get("color", Color.WHITE)) as Color
	var hl := tint.lightened(0.45) if tint.get_luminance() < 0.5 else tint
	m.albedo_color = Color(hl, 0.45)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_studio.add_child(mi)


func _tree_aabb(root: Node3D) -> AABB:
	var have := false
	var out := AABB()
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is VisualInstance3D:
			var vi := n as VisualInstance3D
			var t := _relative_transform(vi, root)
			var box := t * vi.get_aabb()
			if box.size.length() > 0.0:
				out = box if not have else out.merge(box)
				have = true
		for c in n.get_children():
			stack.append(c)
	return out if have else AABB(Vector3(-1, -1, -1), Vector3(2, 2, 2))


func _relative_transform(n: Node3D, root: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var cur: Node = n
	while cur != null and cur != root:
		if cur is Node3D:
			t = (cur as Node3D).transform * t
		cur = cur.get_parent()
	return t


## No run drawn in 3D (3D wires off and never revealed): a short sample in
## the kind's material and routing style.
func _rebuild_sample_preview() -> void:
	_preview_kind = "sample"
	_preview_lbl.text = ("Sample in this kind's material — this wire is not drawn in 3D "
		+ "(turn on 3D wires or set Show in 3D: Always on)")
	_cam_target = Vector3(0.0, 0.35, 0.0)
	_cam_dist_min = 1.6
	_cam_dist_max = 9.0
	_cam_dist = clampf(_cam_dist, _cam_dist_min, _cam_dist_max)
	var ground := _studio.get_node_or_null("Ground") as MeshInstance3D
	if ground != null:
		ground.position.y = -0.02
		(ground.mesh as PlaneMesh).size = Vector2(10, 10)
	var a := Vector3(-PREVIEW_LEN_M * 0.5, 0.55, -0.5)
	var b := Vector3(PREVIEW_LEN_M * 0.5, 0.55, 0.7)
	var type_id := _effective_type_id()
	var meta := ConduitKinds.type_meta(type_id)
	var rm := ConduitKinds.normalize_route_mode(str(_draft.get("route_mode", meta.get("route_mode", ""))))
	var elbow := float(_draft.get("elbow_radius_frac", meta.get("elbow_radius_frac", 0.35)))
	var flat := func(_p: Vector3) -> float: return 0.0
	var control: Array = []
	match rm:
		"contour":
			var r_min := ConduitKinds.contour_bend_radius_m(type_id, _draft)
			for p: Vector3 in ContourRouter.route_polyline([a, b], flat, r_min):
				control.append(p)
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
			control = [a, b]
	if control.size() < 2:
		control = [a, b]
	var tint: Color = _draft.get("color", meta.get("color", Color.WHITE)) as Color
	var style_ov: Dictionary = {}
	for k: String in ConduitStylePresets.STYLE_KEYS:
		if _draft.has(k):
			style_ov[k] = _draft[k]
	for msk: String in ConduitKinds.mesh_style_override(rm).keys():
		if not style_ov.has(msk):
			style_ov[msk] = ConduitKinds.mesh_style_override(rm)[msk]
	var built := ConduitMeshBuilder.build(control, type_id, 16, Callable(), style_ov)
	var mi := MeshInstance3D.new()
	mi.set_meta("preview_conduit", true)
	mi.mesh = built.get("mesh", null)
	var conceptual := ConduitKinds.is_conceptual_type(type_id)
	var glow: bool = conceptual or ConduitKinds.is_light_type(type_id) or bool(_draft.get("flow_glow", false))
	if glow:
		var fmat := ConduitKinds.make_flow_material(type_id, tint,
			float(_draft.get("flow_strength_default", 0.7)), 1.3)
		fmat.set_shader_parameter("base_color", tint)
		fmat.set_shader_parameter("flow_color", _draft.get("flow_color", tint.lightened(0.4)))
		fmat.set_shader_parameter("emission_boost", float(_draft.get("emission_energy", 1.8)))
		fmat.set_shader_parameter("conceptual", 1.0 if conceptual else 0.0)
		mi.material_override = fmat
	else:
		var pmat := ConduitKinds.make_material(type_id, tint)
		pmat.roughness = float(_draft.get("roughness", meta.get("roughness", 0.7)))
		mi.material_override = pmat
	_studio.add_child(mi)
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
	_camera.far = 4000.0
	_studio.add_child(_camera)
	var ground := MeshInstance3D.new()
	ground.name = "Ground"
	var plane := PlaneMesh.new()
	plane.size = Vector2(10, 10)
	ground.mesh = plane
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.11, 0.12, 0.15)
	gm.roughness = 0.95
	ground.material_override = gm
	ground.position.y = -0.02
	_studio.add_child(ground)


func _update_camera() -> void:
	if _camera == null or not is_instance_valid(_camera):
		return
	_cam_pitch = clampf(_cam_pitch, -1.4, 1.4)
	_cam_dist = clampf(_cam_dist, _cam_dist_min, _cam_dist_max)
	var offset := Basis.from_euler(Vector3(-absf(_cam_pitch), _cam_yaw, 0.0)) * Vector3(0.0, 0.0, _cam_dist)
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
# Presets
# ---------------------------------------------------------------------------

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
		_status_lbl.text = "Could not save the kind's default"


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
	OPTS.fill_sizes(_size_opt, _effective_type_id())
	_syncing = true
	_sync_controls_from_draft()
	_syncing = false
	_update_control_visibility()
	_refresh_titles()
	_apply_to_wire()
	_status_lbl.text = "Loaded “%s” onto the wire" % str(entry.get("label", ""))
