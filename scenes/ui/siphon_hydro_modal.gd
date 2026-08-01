extends Control

## Siphon Lab — graph-view mode (VIEW_SIPHON): live Elevation CT in the preview
## slot + 2D overlays (pond bathymetry fill, level ticks, labels). Params dock
## on the right.

const C_PANEL := Color(0.07, 0.10, 0.18, 1.0)
const C_BORDER := Color(0.22, 0.30, 0.44, 1.0)
const C_TEXT := Color(0.90, 0.93, 0.96, 1.0)
const C_MUTED := Color(0.62, 0.68, 0.78, 1.0)
const C_ACCENT := Color(0.30, 0.70, 1.0, 1.0)
const C_WATER := Color(0.22, 0.52, 0.92, 0.62)
const C_WATER_LINE := Color(0.45, 0.85, 1.0, 0.95)
## Cap UI refresh — full redraw every frame was a crash/jank source.
const _UI_HZ := 12.0
const _PHYS_HZ := 6.0
const _DEM_SAMPLES := 64

var _graph_view: Node = null
var _item_id: String = ""
var _syncing := false
var _as_view := false

var _panel: PanelContainer
var _preview_col: Control
var _preview_stack: Control
var _preview: Control
var _title_lbl: Label
var _empty_lbl: Label
var _module_spin: SpinBox
var _start_spin: SpinBox
var _break_spin: SpinBox
var _intake_d_spin: SpinBox
var _outlet_d_spin: SpinBox
var _outlet_inv_spin: SpinBox
var _barrel_spin: SpinBox
var _manning_spin: SpinBox
## Generalized turbine controls (Phase C).
var _kind_opt: OptionButton
var _kind_hint_lbl: Label
var _siphon_group: VBoxContainer
var _penstock_group: VBoxContainer
var _penstock_len_spin: SpinBox
var _penstock_d_spin: SpinBox
var _roughness_spin: SpinBox
var _design_flow_spin: SpinBox
var _turb_eff_spin: SpinBox
var _rpm_lbl: Label
var _pe_lbl: Label
var _elec_lbl: Label
var _flow_lbl: Label
var _head_lbl: Label
var _state_lbl: Label
var _cum_lbl: Label
var _capacity_lbl: Label
var _loss_lbl: Label
var _capfac_lbl: Label
var _annual_lbl: Label
var _estimate_hint_lbl: Label
var _hint_lbl: Label
var _ws_status_lbl: Label
var _ws_season_lbl: Label
var _ws_preview_btn: Button
var _ws_designate_btn: Button
var _sim_inflow_btn: CheckButton
var _sim_inflow_spin: SpinBox
var _nav_hint_lbl: Label
var _side: VBoxContainer

var _prop_angle: float = 0.0
var _prop_omega: float = 0.0
var _display_level_m := NAN   # eased pond level for smooth drawing (physics untouched)
var _inflow_lps := 0.0        # smoothed pond inflow rate (catchment + test inflow)
var _last_r: Dictionary = {}
var _ui_acc := 0.0
var _phys_acc := 999.0
var _pv_origin := Vector2.ZERO
var _pv_size := Vector2.ZERO
var _pv_y_min := 0.0
var _pv_sx := 1.0
var _pv_sy := 1.0
var _cached_pond: Dictionary = {}
var _pond_cache_t := 0.0
var _dem_along: PackedFloat32Array = PackedFloat32Array()
var _dem_elev: PackedFloat32Array = PackedFloat32Array()
var _dem_bake_key: String = ""
## Own 2D cross-section view transform (Phase 2 — no shared Elev canvas).
var _view_zoom := 1.0
var _view_pan := Vector2.ZERO
var _view_dragging := false
var _view_last_mouse := Vector2.ZERO
## Which level line the user grabbed on the CT: "" | "prime" | "break" | "water".
var _grab_kind := ""
## Continuous phase for flow-particle animation (seconds).
var _flow_phase := 0.0
## When true, Elevation SoI CT fills `_preview_stack` — skip opaque 2D ground.
var _elev_ct_bg := false
## Linked CT+overlay projection (centre elev + px/m; pan/zoom folded into mids).
var _pv_linked := false
var _pv_elev_mid := 0.0
## Spatial edit is consuming a prop drag inside the Lab preview.
var _lab_prop_drag := false


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	set_process(false)


func bind_graph_view(gv: Node) -> void:
	_graph_view = gv


## Graph view-mode entry. Preview stack hosts the Elevation CT; overlays draw on top.
func enter_as_view(item_id: String = "") -> void:
	_as_view = true
	_elev_ct_bg = true
	if item_id.is_empty():
		item_id = _pick_default_siphon_id()
	_item_id = item_id
	_show_shell()
	_load_from_model()
	if _preview_col != null:
		_preview_col.visible = true
	# Fresh Lab session — don't inherit a prior test-inflow toggle.
	if _sim_inflow_btn != null:
		_sim_inflow_btn.set_pressed_no_signal(false)
	var lps0 := 0.5
	if _sim_inflow_spin != null:
		lps0 = float(_sim_inflow_spin.value)
	_write_sim_inflow(false, lps0)
	if _graph_view != null and _graph_view.has_method("prepare_siphon_lab_session"):
		_graph_view.call("prepare_siphon_lab_session", _item_id)
	_reset_view_transform()
	set_process(true)
	_phys_acc = 999.0
	_ui_acc = 0.0
	_refresh_ws_status()
	call_deferred("_push_lab_section_frame")
	if _preview != null:
		_preview.queue_redraw()


func exit_view() -> void:
	if not _as_view and not visible:
		return
	if _sim_inflow_btn != null:
		_sim_inflow_btn.set_pressed_no_signal(false)
	# Clear test inflow before wiping _item_id (parent teardown also clears).
	if not _item_id.is_empty():
		var lps1 := 0.5
		if _sim_inflow_spin != null:
			lps1 = float(_sim_inflow_spin.value)
		_write_sim_inflow(false, lps1)
	_as_view = false
	_elev_ct_bg = false
	if _preview_col != null:
		_preview_col.visible = true
	_hide_shell()
	_item_id = ""
	set_process(false)


## Host Control for SoI SubViewportContainer (below the 2D overlay).
func get_preview_embed_host() -> Control:
	return _preview_stack


## Metre window for the embedded Elevation CT camera (along / elev / ortho height).
## Same metrics drive the 2D overlay so zoom/pan stay linked.
func get_lab_section_frame() -> Dictionary:
	return _lab_view_metrics()


## Shared Lab CT + overlay framing (metres). Pan is in screen px; zoom shrinks
## the visible window. Ortho height matches vertical metres; widened if needed
## so the along-axis window matches the host aspect.
## CT look-at is the TURBINE (module along + elev), not the pond midpoint.
func _lab_view_metrics() -> Dictionary:
	var pond := _pond_context()
	var frame := _slice_frame(pond)
	var half_w := float(frame.get("half_w", 3.0))
	var module_along := float(frame.get("module_along", 3.5))
	var a0 := float(frame.get("along0", -half_w - 2.0))
	var a1 := float(frame.get("along1", module_along + 6.0))
	var floor_m := float(pond.get("floor_m", NAN))
	var rim_m := float(pond.get("rim_m", NAN))
	var module_m := float(_module_spin.value) if _module_spin != null else 0.0
	var start_m := float(_start_spin.value) if _start_spin != null else module_m
	var break_m := float(_break_spin.value) if _break_spin != null else module_m
	if is_nan(floor_m):
		floor_m = minf(module_m, break_m) - 1.5
	if is_nan(rim_m):
		rim_m = maxf(module_m, start_m) + 0.8
	var lo := minf(floor_m, break_m)
	var hi := maxf(rim_m, maxf(start_m, module_m + 1.2))
	var elev_span0 := maxf((hi - lo) * 1.28, 2.5)
	# Keep pond + turbine in the along window; centre camera on the turbine.
	var along_span0 := maxf(a1 - a0, absf(module_along) + half_w + 4.0)
	along_span0 = maxf(along_span0, 1.0)
	var zoom := maxf(_view_zoom, 0.15)
	# Same pixel rect as the embedded CT (full preview stack — no 2D inset).
	var host := _lab_host_size()
	var aspect := host.x / host.y
	var ortho_h := elev_span0 / zoom
	var ortho_w := ortho_h * aspect
	var need_along := along_span0 / zoom
	if ortho_w < need_along:
		ortho_w = need_along
		ortho_h = ortho_w / aspect
	# Overlay DEM is pond-relative (pond at along=0). CT camera uses absolute
	# site along = relative + pond·heading. Look-at = turbine.
	var heading := float(frame.get("heading", 0.0))
	var pond_site: Vector2 = frame.get("pond_site", Vector2.ZERO) as Vector2
	var pond_along := pond_site.dot(Vector2(cos(heading), sin(heading)))
	var along_mid_rel := module_along - _view_pan.x * (ortho_w / host.x)
	var elev_mid := module_m + _view_pan.y * (ortho_h / host.y)
	return {
		"along_m": along_mid_rel + pond_along,
		"along_m_rel": along_mid_rel,
		"elev_m": elev_mid,
		"ortho_h_m": ortho_h,
		"ortho_w_m": ortho_w,
		"heading": heading,
		"a0": a0,
		"a1": a1,
		"lo": lo,
		"hi": hi,
		"floor_m": floor_m,
		"rim_m": rim_m,
		"half_w": half_w,
		"module_along": module_along,
		"pond_along": pond_along,
	}


## Pixel size shared by Lab CT embed + 2D overlay (must match or zoom unlinks).
func _lab_host_size() -> Vector2:
	var host := Vector2(640, 360)
	if _preview_stack != null and _preview_stack.size.x > 8.0:
		host = _preview_stack.size
	elif _preview != null and _preview.size.x > 8.0:
		host = _preview.size
	host.x = maxf(host.x, 8.0)
	host.y = maxf(host.y, 8.0)
	return host


func close() -> void:
	if _graph_view != null and _graph_view.has_method("_apply_graph_view_mode"):
		_graph_view.call("_apply_graph_view_mode", GraphSiteLayout.VIEW_ELEVATION)
	else:
		exit_view()


func _show_shell() -> void:
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	if _panel != null:
		_panel.mouse_filter = Control.MOUSE_FILTER_STOP
		_panel.clip_contents = true
		# Fill the Siphon Lab dock slot (parent anchors the dock width).
		_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_panel.anchor_left = 0.0
		_panel.anchor_top = 0.0
		_panel.anchor_right = 1.0
		_panel.anchor_bottom = 1.0
		_panel.offset_left = 0
		_panel.offset_top = 0
		_panel.offset_right = 0
		_panel.offset_bottom = 0
		_panel.custom_minimum_size = Vector2.ZERO
		# Transparent shell so the embedded Elevation CT shows through the left
		# column; the params ScrollContainer keeps its own opaque cards.
		var ps := _panel.get_theme_stylebox("panel") as StyleBoxFlat
		if ps != null:
			ps = ps.duplicate() as StyleBoxFlat
			ps.bg_color = Color(0.05, 0.07, 0.10, 0.35)
			_panel.add_theme_stylebox_override("panel", ps)
	if _preview_col != null:
		_preview_col.visible = true
		_preview_col.custom_minimum_size = Vector2.ZERO
	if _preview_stack != null:
		_preview_stack.custom_minimum_size = Vector2.ZERO
	if _side != null:
		# Keep the right dock readable over the CT.
		var side_bg := StyleBoxFlat.new()
		side_bg.bg_color = Color(0.07, 0.10, 0.18, 0.94)
		side_bg.set_corner_radius_all(8)
		side_bg.content_margin_left = 6
		side_bg.content_margin_right = 6
		side_bg.content_margin_top = 6
		side_bg.content_margin_bottom = 6
		# ScrollContainer parent — wrap side in a panel if needed; tint via modulate.
		_side.modulate = Color(1, 1, 1, 1)


func _hide_shell() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var ps := StyleBoxFlat.new()
	ps.bg_color = C_PANEL
	ps.border_color = C_BORDER
	ps.set_border_width_all(1)
	ps.set_corner_radius_all(10)
	ps.content_margin_left = 14
	ps.content_margin_right = 14
	ps.content_margin_top = 12
	ps.content_margin_bottom = 12
	_panel.add_theme_stylebox_override("panel", ps)
	add_child(_panel)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	_panel.add_child(root)

	var header := HBoxContainer.new()
	root.add_child(header)
	_title_lbl = Label.new()
	_title_lbl.text = "Hydro Lab"
	_title_lbl.add_theme_color_override("font_color", C_TEXT)
	_title_lbl.add_theme_font_size_override("font_size", 18)
	_title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_title_lbl)
	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.tooltip_text = "Back to Elevation"
	close_btn.custom_minimum_size = Vector2(32, 28)
	close_btn.pressed.connect(close)
	header.add_child(close_btn)

	_empty_lbl = Label.new()
	_empty_lbl.text = "No Siphon Hydroturbine on the graph — add one from the Library (Hydro)."
	_empty_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_empty_lbl.add_theme_color_override("font_color", C_MUTED)
	_empty_lbl.visible = false
	root.add_child(_empty_lbl)

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 14)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(body)

	_preview_col = VBoxContainer.new()
	_preview_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preview_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_preview_col.size_flags_stretch_ratio = 1.0
	_preview_col.add_theme_constant_override("separation", 8)
	body.add_child(_preview_col)

	_preview_stack = Control.new()
	_preview_stack.custom_minimum_size = Vector2(520, 280)
	_preview_stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preview_stack.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_preview_stack.mouse_filter = Control.MOUSE_FILTER_STOP
	_preview_stack.gui_input.connect(_on_preview_stack_input)
	_preview_col.add_child(_preview_stack)

	_preview = Control.new()
	_preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_preview.draw.connect(_draw_preview)
	_preview_stack.add_child(_preview)

	# Fixed-width params dock (~300 px) so CT owns ~3/4 of Lab width.
	var side_panel := PanelContainer.new()
	side_panel.custom_minimum_size = Vector2(300, 0)
	side_panel.size_flags_horizontal = Control.SIZE_SHRINK_END
	side_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var side_ps := StyleBoxFlat.new()
	side_ps.bg_color = Color(0.07, 0.10, 0.18, 0.96)
	side_ps.set_corner_radius_all(8)
	side_ps.content_margin_left = 8
	side_ps.content_margin_right = 4
	side_ps.content_margin_top = 8
	side_ps.content_margin_bottom = 8
	side_panel.add_theme_stylebox_override("panel", side_ps)
	body.add_child(side_panel)
	var side_scroll := ScrollContainer.new()
	side_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	side_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	side_panel.add_child(side_scroll)
	_side = VBoxContainer.new()
	_side.custom_minimum_size = Vector2(284, 0)
	_side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_side.add_theme_constant_override("separation", 6)
	side_scroll.add_child(_side)

	# Turbine kind selector — drives which conveyance HydroReach uses and which
	# param sections show below.
	_section(_side, "Turbine")
	var kind_row := HBoxContainer.new()
	kind_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_side.add_child(kind_row)
	var kind_lbl := Label.new()
	kind_lbl.text = "Kind"
	kind_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	kind_lbl.add_theme_color_override("font_color", C_TEXT)
	kind_lbl.add_theme_font_size_override("font_size", 12)
	kind_row.add_child(kind_lbl)
	_kind_opt = OptionButton.new()
	_kind_opt.focus_mode = Control.FOCUS_NONE
	for k in HydroSource.KINDS.keys():
		_kind_opt.add_item(str((HydroSource.KINDS[k] as Dictionary).get("display", k)))
		_kind_opt.set_item_metadata(_kind_opt.item_count - 1, k)
	_kind_opt.item_selected.connect(_on_kind_selected)
	kind_row.add_child(_kind_opt)
	_kind_hint_lbl = Label.new()
	_kind_hint_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_kind_hint_lbl.add_theme_color_override("font_color", C_MUTED)
	_kind_hint_lbl.add_theme_font_size_override("font_size", 11)
	_side.add_child(_kind_hint_lbl)

	# Shared geometry — turbine/module elevation, outlet (tailrace) invert, and
	# the pond-side + discharge pipe diameters (both conveyances have these).
	_section(_side, "Geometry")
	_module_spin = _spin(_side, "Turbine elevation (m)", -500.0, 5000.0, 0.01,
			func(v: float) -> void: _commit_float("module_elev_m", v))
	_outlet_inv_spin = _spin(_side, "Outlet invert (m)", -500.0, 5000.0, 0.01,
			func(v: float) -> void: _commit_float("outlet_invert_m", v))
	_intake_d_spin = _spin(_side, "Intake diameter (mm)", 25.0, 600.0, 1.0,
			func(v: float) -> void: _commit_float("intake_diameter_mm", v))
	_outlet_d_spin = _spin(_side, "Outlet diameter (mm)", 25.0, 800.0, 1.0,
			func(v: float) -> void: _commit_float("outlet_diameter_mm", v))

	# Siphon-only: prime/break levels + orifice barrel. Hidden for penstock kinds
	# (the spins stay populated so _refresh_physics still reads siphon_break_m as
	# the intake invert).
	_siphon_group = VBoxContainer.new()
	_side.add_child(_siphon_group)
	_section(_siphon_group, "Siphon levels")
	var levels_hint := Label.new()
	levels_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	levels_hint.add_theme_color_override("font_color", C_MUTED)
	levels_hint.add_theme_font_size_override("font_size", 11)
	levels_hint.text = "Drag Prime / Break / water on the cut — spins stay in sync."
	_siphon_group.add_child(levels_hint)
	_start_spin = _spin(_siphon_group, "Start / prime (m)", -500.0, 5000.0, 0.01,
			func(v: float) -> void: _commit_float("siphon_start_m", v))
	_break_spin = _spin(_siphon_group, "Break / air (m)", -500.0, 5000.0, 0.01,
			func(v: float) -> void: _commit_float("siphon_break_m", v))
	_barrel_spin = _spin(_siphon_group, "Barrel length (m)", 1.0, 500.0, 0.1,
			func(v: float) -> void: _commit_float("barrel_length_m", v))
	_manning_spin = _spin(_siphon_group, "Manning n", 0.008, 0.05, 0.001,
			func(v: float) -> void: _commit_float("manning_n", v))

	# Penstock-only: pressurized pipe feeding a pelton/turgo/run-of-river runner.
	_penstock_group = VBoxContainer.new()
	_side.add_child(_penstock_group)
	_section(_penstock_group, "Penstock")
	var pen_hint := Label.new()
	pen_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	pen_hint.add_theme_color_override("font_color", C_MUTED)
	pen_hint.add_theme_font_size_override("font_size", 11)
	pen_hint.text = "Q is the turbine's design flow, capped by what the penstock can gravity-deliver at the current head."
	_penstock_group.add_child(pen_hint)
	_penstock_len_spin = _spin(_penstock_group, "Penstock length (m)", 1.0, 2000.0, 1.0,
			func(v: float) -> void: _commit_float("penstock_length_m", v))
	_penstock_d_spin = _spin(_penstock_group, "Penstock Ø (mm)", 20.0, 2000.0, 1.0,
			func(v: float) -> void: _commit_float("penstock_diameter_mm", v))
	_roughness_spin = _spin(_penstock_group, "Roughness ε (mm)", 0.0005, 1.0, 0.0005,
			func(v: float) -> void: _commit_float("pipe_roughness_mm", v))
	_design_flow_spin = _spin(_penstock_group, "Design flow (L/s)", 0.1, 5000.0, 0.1,
			func(v: float) -> void: _commit_float("design_flow_lps", v))
	_turb_eff_spin = _spin(_penstock_group, "Turbine η (0=auto)", 0.0, 0.95, 0.01,
			func(v: float) -> void: _commit_float("turbine_efficiency", v))

	# Placing the turbine near a pond auto-binds it and auto-routes its outlet
	# (and re-tries automatically whenever the Lab opens on an unbound siphon)
	# — these are fallback/override controls, not a required setup step.
	var bind_btn := Button.new()
	bind_btn.text = "Rebind to nearest pond"
	bind_btn.tooltip_text = "Auto-bind normally happens on placement — use this to switch ponds or retry"
	bind_btn.pressed.connect(_on_bind_pond)
	_side.add_child(bind_btn)
	var outlet_btn := Button.new()
	outlet_btn.text = "Refresh outlet route"
	outlet_btn.tooltip_text = "Re-route the downhill culvert outlet (e.g. after sculpting terrain)"
	outlet_btn.pressed.connect(_on_ensure_outlet)
	_side.add_child(outlet_btn)

	# Folded by default — Geometry / Levels / Live stay primary.
	var ws_body := _fold_section(_side, "Watershed (rain → pond)", false)
	var ws_hint := Label.new()
	ws_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ws_hint.add_theme_color_override("font_color", C_MUTED)
	ws_hint.add_theme_font_size_override("font_size", 11)
	ws_hint.text = "Preview paints a temporary hillside ghost (3D + Site). Clear removes it. Designate wires a graph catchment so weather rain fills the tank — that node stays on the freeform graph, not as a Site outline."
	ws_body.add_child(ws_hint)
	var ws_row := HBoxContainer.new()
	ws_row.add_theme_constant_override("separation", 6)
	ws_body.add_child(ws_row)
	_ws_preview_btn = Button.new()
	_ws_preview_btn.text = "Preview"
	_ws_preview_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ws_preview_btn.pressed.connect(_on_ws_preview)
	ws_row.add_child(_ws_preview_btn)
	_ws_designate_btn = Button.new()
	_ws_designate_btn.text = "Designate"
	_ws_designate_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ws_designate_btn.tooltip_text = "Preview a valid catchment first"
	_ws_designate_btn.pressed.connect(_on_ws_designate)
	ws_row.add_child(_ws_designate_btn)
	var ws_clear := Button.new()
	ws_clear.text = "Clear"
	ws_clear.tooltip_text = "Hide the watershed preview ghost in 3D and Site Plan (keeps a designated catchment)"
	ws_clear.pressed.connect(_on_ws_clear_preview)
	ws_row.add_child(ws_clear)
	var ws_rm := Button.new()
	ws_rm.text = "Remove"
	ws_rm.tooltip_text = "Delete the designated hillside catchment from the graph"
	ws_rm.pressed.connect(_on_ws_remove)
	ws_row.add_child(ws_rm)
	_ws_status_lbl = Label.new()
	_ws_status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_ws_status_lbl.add_theme_color_override("font_color", C_MUTED)
	_ws_status_lbl.add_theme_font_size_override("font_size", 11)
	_ws_status_lbl.text = "Bind a pond first, then Preview."
	ws_body.add_child(_ws_status_lbl)
	_ws_season_lbl = Label.new()
	_ws_season_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_ws_season_lbl.add_theme_color_override("font_color", C_MUTED)
	_ws_season_lbl.add_theme_font_size_override("font_size", 11)
	_ws_season_lbl.text = ""
	ws_body.add_child(_ws_season_lbl)

	_section(_side, "Test inflow")
	var drive_hint := Label.new()
	drive_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	drive_hint.add_theme_color_override("font_color", C_MUTED)
	drive_hint.add_theme_font_size_override("font_size", 11)
	drive_hint.text = "Steady fill into the pond, advanced on the world clock. Play / speed up time to watch it prime, then drain (orifice-limited by the barrel)."
	_side.add_child(drive_hint)
	_sim_inflow_btn = CheckButton.new()
	_sim_inflow_btn.text = "Test inflow (steady L/s)"
	_sim_inflow_btn.tooltip_text = (
			"Constant fill into the bound pond (works while sim is paused / "
			+ "Elev noon-lock). The only manual water driver.")
	_sim_inflow_btn.toggled.connect(_on_sim_inflow_toggled)
	_side.add_child(_sim_inflow_btn)
	_sim_inflow_spin = _spin(_side, "Inflow L/s", 0.05, 2000.0, 0.05, func(v: float) -> void:
		var on := _sim_inflow_btn != null and _sim_inflow_btn.button_pressed
		_write_sim_inflow(on, v))
	_sim_inflow_spin.value = 0.5

	_section(_side, "Live readouts")
	_rpm_lbl = _ro(_side, "RPM")
	_pe_lbl = _ro(_side, "Hydraulic PE")
	_elec_lbl = _ro(_side, "Electrical")
	_flow_lbl = _ro(_side, "Flow")
	_head_lbl = _ro(_side, "Head")
	_state_lbl = _ro(_side, "State")
	_cum_lbl = _ro(_side, "Outlet volume")

	var est_body := _fold_section(_side, "Estimate", false)
	_capacity_lbl = _ro(est_body, "Pipe capacity")
	_loss_lbl = _ro(est_body, "Head loss")
	_capfac_lbl = _ro(est_body, "Capacity factor")
	_annual_lbl = _ro(est_body, "Annual energy")
	_estimate_hint_lbl = Label.new()
	_estimate_hint_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_estimate_hint_lbl.add_theme_color_override("font_color", C_MUTED)
	_estimate_hint_lbl.add_theme_font_size_override("font_size", 11)
	_estimate_hint_lbl.text = ""
	est_body.add_child(_estimate_hint_lbl)
	_hint_lbl = Label.new()
	_hint_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint_lbl.add_theme_color_override("font_color", C_MUTED)
	_hint_lbl.add_theme_font_size_override("font_size", 11)
	_hint_lbl.text = "CT: green = prime · red = air break · drag water / levels on the cut."
	_side.add_child(_hint_lbl)
	_nav_hint_lbl = Label.new()
	_nav_hint_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_nav_hint_lbl.add_theme_color_override("font_color", C_MUTED)
	_nav_hint_lbl.add_theme_font_size_override("font_size", 10)
	_nav_hint_lbl.text = "Drag CT to pan · Wheel zoom · heading locked to pond→outlet"
	_side.add_child(_nav_hint_lbl)


func _section(parent: Control, title: String) -> void:
	var lbl := Label.new()
	lbl.text = title
	lbl.add_theme_color_override("font_color", C_ACCENT)
	lbl.add_theme_font_size_override("font_size", 12)
	parent.add_child(lbl)


## Collapsible dock block — returns the body VBox to parent controls into.
func _fold_section(parent: Control, title: String, open: bool = false) -> VBoxContainer:
	var wrap := VBoxContainer.new()
	wrap.add_theme_constant_override("separation", 4)
	wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(wrap)
	var btn := Button.new()
	btn.toggle_mode = true
	btn.button_pressed = open
	btn.flat = true
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_color_override("font_color", C_ACCENT)
	btn.add_theme_font_size_override("font_size", 12)
	btn.text = ("%s %s" % ["▾" if open else "▸", title])
	wrap.add_child(btn)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 4)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.visible = open
	wrap.add_child(body)
	btn.toggled.connect(func(on: bool) -> void:
		body.visible = on
		btn.text = ("%s %s" % ["▾" if on else "▸", title]))
	return body


func _spin(parent: Control, label: String, mn: float, mx: float, step: float,
		on_change: Callable) -> SpinBox:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(row)
	var lbl := Label.new()
	lbl.text = label
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.clip_text = true
	lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	lbl.add_theme_color_override("font_color", C_TEXT)
	lbl.add_theme_font_size_override("font_size", 12)
	row.add_child(lbl)
	var sb := SpinBox.new()
	sb.min_value = mn
	sb.max_value = mx
	sb.step = step
	sb.custom_minimum_size.x = 88
	sb.size_flags_horizontal = Control.SIZE_SHRINK_END
	sb.value_changed.connect(func(v: float) -> void:
		if _syncing:
			return
		on_change.call(v))
	row.add_child(sb)
	return sb


func _ro(parent: Control, label: String) -> Label:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var k := Label.new()
	k.text = label
	k.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	k.add_theme_color_override("font_color", C_MUTED)
	k.add_theme_font_size_override("font_size", 12)
	row.add_child(k)
	var v := Label.new()
	v.text = "—"
	v.add_theme_color_override("font_color", C_TEXT)
	v.add_theme_font_size_override("font_size", 12)
	row.add_child(v)
	return v


func _model() -> GraphModel:
	if _graph_view == null:
		return null
	return _graph_view.get("model") as GraphModel


func _pick_default_siphon_id() -> String:
	var m := _model()
	if m == null:
		return ""
	# Prefer current selection on the graph view.
	if _graph_view != null:
		var sel := str(_graph_view.get("_selected_item_id") if _graph_view.get("_selected_item_id") != null else "")
		if sel.is_empty() and _graph_view.has_method("get"):
			pass
		var canvas = _graph_view.get("_graph_canvas")
		if canvas != null:
			sel = str(canvas.get("selected_item_id"))
		if not sel.is_empty():
			var it := m.get_item(sel)
			var sp: Dictionary = it.get("specs", {}) as Dictionary
			if str(sp.get("role", "")) == "siphon_hydro":
				return sel
	for it in m.items:
		if not (it is Dictionary):
			continue
		var item: Dictionary = it
		if str((item.get("specs", {}) as Dictionary).get("role", "")) == "siphon_hydro":
			return str(item.get("id", ""))
	return ""


func _load_from_model() -> bool:
	var m := _model()
	var has_item := m != null and not _item_id.is_empty()
	var item := m.get_item(_item_id) if has_item else {}
	var specs: Dictionary = item.get("specs", {}) as Dictionary if not item.is_empty() else {}
	var ok := not item.is_empty() and str(specs.get("role", "")) == "siphon_hydro"
	if _empty_lbl != null:
		_empty_lbl.visible = not ok
	if _side != null:
		_side.visible = ok
	if _preview != null:
		_preview.visible = ok
	if not ok:
		_title_lbl.text = "Hydro Lab"
		return false
	_syncing = true
	var elev_seed := float(item.get("elevation_m", NAN))
	if is_nan(elev_seed):
		elev_seed = float(specs.get("module_elev_m", NAN))
	# Migrate absolutes → offsets and stamp resolved levels onto a working copy.
	var resolved_specs: Dictionary = specs.duplicate(true)
	SiphonHydraulics.apply_resolved_levels(resolved_specs, elev_seed)
	var mod_e := float(resolved_specs.get("module_elev_m", elev_seed))
	if is_nan(mod_e):
		mod_e = 0.0
	var start_m := float(resolved_specs.get("siphon_start_m", mod_e + 0.15))
	var break_m := float(resolved_specs.get("siphon_break_m", mod_e))
	_module_spin.value = mod_e
	_start_spin.value = start_m
	_break_spin.value = break_m
	# Persist migrated offsets so later prop moves keep tracking.
	if m != null and (
			not specs.has("siphon_start_offset_m") or not specs.has("siphon_break_offset_m")
			or absf(float(specs.get("siphon_start_m", start_m)) - start_m) > 1e-4):
		m.update_item(_item_id, {"specs": resolved_specs, "elevation_m": mod_e})
		specs = resolved_specs
	_intake_d_spin.value = float(specs.get("intake_diameter_mm", 203.0))
	_outlet_d_spin.value = float(specs.get("outlet_diameter_mm", 203.0))
	var out_inv := float(specs.get("outlet_invert_m", NAN))
	if is_nan(out_inv):
		out_inv = mod_e - 9.0
	_outlet_inv_spin.value = out_inv
	_barrel_spin.value = float(specs.get("barrel_length_m", 20.0))
	_manning_spin.value = float(specs.get("manning_n", 0.012))
	_penstock_len_spin.value = float(specs.get("penstock_length_m", 60.0))
	_penstock_d_spin.value = float(specs.get("penstock_diameter_mm", 63.0))
	_roughness_spin.value = float(specs.get("pipe_roughness_mm", 0.0015))
	_design_flow_spin.value = float(specs.get("design_flow_lps", 5.0))
	_turb_eff_spin.value = float(specs.get("turbine_efficiency", 0.0))
	var kind := str(specs.get("turbine_kind", "siphon"))
	_select_kind_in_dropdown(kind)
	_apply_kind_visibility(kind)
	if _sim_inflow_spin != null:
		_sim_inflow_spin.value = maxf(float(specs.get("lab_sim_inflow_lps", 0.5)), 0.05)
	if _sim_inflow_btn != null:
		_sim_inflow_btn.set_pressed_no_signal(bool(specs.get("lab_sim_inflow_enabled", false)))
	_title_lbl.text = "Hydro Lab — %s" % str(specs.get("name", "Turbine"))
	_syncing = false
	_cached_pond.clear()
	_pond_cache_t = 0.0
	# Clear any leftover hillside ghost — Preview is opt-in; Clear also available.
	var loader_ws := _terrain_loader()
	if loader_ws != null and loader_ws.has_method("clear_watershed_preview"):
		loader_ws.call("clear_watershed_preview")
	_refresh_ws_status()
	_refresh_physics()
	return true


func _commit_float(key: String, v: float) -> void:
	var m := _model()
	if m == null or _item_id.is_empty():
		return
	var item := m.get_item(_item_id)
	if item.is_empty():
		return
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	var module := float(_module_spin.value) if _module_spin != null \
			else float(specs.get("module_elev_m", item.get("elevation_m", 0.0)))
	if key == "siphon_start_m":
		# Edit absolute in the UI; persist as offset vs module + absolute mirror.
		specs["siphon_start_offset_m"] = v - module
		specs["siphon_start_m"] = v
		specs["intake_crown_m"] = v
		var break_m := float(specs.get("siphon_break_m", NAN))
		if is_nan(break_m):
			break_m = module + float(specs.get("siphon_break_offset_m",
					SiphonHydraulics.DEFAULT_BREAK_OFFSET_M))
		if break_m > v:
			break_m = v
			specs["siphon_break_m"] = break_m
			specs["siphon_break_offset_m"] = break_m - module
			specs["intake_invert_m"] = break_m
			_syncing = true
			_break_spin.value = break_m
			_syncing = false
	elif key == "siphon_break_m":
		specs["siphon_break_offset_m"] = v - module
		specs["siphon_break_m"] = v
		specs["intake_invert_m"] = v
		var start_m := float(specs.get("siphon_start_m", NAN))
		if is_nan(start_m):
			start_m = module + float(specs.get("siphon_start_offset_m", NAN))
		if not is_nan(start_m) and v > start_m:
			start_m = v
			specs["siphon_start_m"] = start_m
			specs["siphon_start_offset_m"] = start_m - module
			specs["intake_crown_m"] = start_m
			_syncing = true
			_start_spin.value = start_m
			_syncing = false
	elif key == "module_elev_m":
		specs["module_elev_m"] = v
		# Keep offsets; refresh absolute start/break to follow the turbine.
		SiphonHydraulics.apply_resolved_levels(specs, v)
		_syncing = true
		if _start_spin != null:
			_start_spin.value = float(specs.get("siphon_start_m", v))
		if _break_spin != null:
			_break_spin.value = float(specs.get("siphon_break_m", v))
		_syncing = false
		m.update_item(_item_id, {"elevation_m": v, "specs": specs})
		_phys_acc = 999.0
		var canvas_m := _elev_canvas()
		if canvas_m != null:
			canvas_m.call("queue_redraw")
		return
	else:
		specs[key] = v
	m.update_item(_item_id, {"specs": specs})
	_phys_acc = 999.0
	var canvas := _elev_canvas()
	if canvas != null:
		canvas.call("queue_redraw")


func _commit_string(key: String, v: String) -> void:
	var m := _model()
	if m == null or _item_id.is_empty():
		return
	var item := m.get_item(_item_id)
	if item.is_empty():
		return
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	specs[key] = v
	m.update_item(_item_id, {"specs": specs})
	_phys_acc = 999.0


func _on_kind_selected(idx: int) -> void:
	if _syncing or _kind_opt == null:
		return
	var kind := str(_kind_opt.get_item_metadata(idx))
	_commit_string("turbine_kind", kind)
	_apply_kind_visibility(kind)
	_refresh_physics()
	if _preview != null:
		_preview.queue_redraw()


func _select_kind_in_dropdown(kind: String) -> void:
	if _kind_opt == null:
		return
	for i in _kind_opt.item_count:
		if str(_kind_opt.get_item_metadata(i)) == kind:
			_kind_opt.select(i)
			return
	_kind_opt.select(0)   # unknown → first (siphon); commit is untouched


## Show the siphon vs. penstock parameter group for the current kind, and update
## the head-band hint. The hidden group's spins stay populated so _refresh_physics
## keeps reading siphon_break_m (the intake invert) either way.
func _apply_kind_visibility(kind: String) -> void:
	var meta := HydroSource.kind_meta(kind)
	var penstock := bool(meta.get("has_penstock", false))
	if _siphon_group != null:
		_siphon_group.visible = not penstock
	if _penstock_group != null:
		_penstock_group.visible = penstock
	if _kind_hint_lbl != null:
		var band: Array = meta.get("head_band", []) as Array
		var band_txt := "%.0f–%.0f m head" % [float(band[0]), float(band[1])] if band.size() == 2 else ""
		_kind_hint_lbl.text = "%s · %s" % [str(meta.get("display", kind)), band_txt]


## Currently-selected turbine kind (dropdown metadata), defaulting to siphon.
func _current_kind() -> String:
	if _kind_opt != null and _kind_opt.selected >= 0:
		return str(_kind_opt.get_item_metadata(_kind_opt.selected))
	return "siphon"


func _kind_has_penstock() -> bool:
	return bool(HydroSource.kind_meta(_current_kind()).get("has_penstock", false))


func _on_bind_pond() -> void:
	if _graph_view != null and _graph_view.has_method("bind_siphon_to_nearest_pond"):
		_graph_view.call("bind_siphon_to_nearest_pond", _item_id)
		_cached_pond.clear()
		_load_from_model()
		if _graph_view.has_method("focus_siphon_conduit_glow"):
			_graph_view.call("focus_siphon_conduit_glow", _item_id)
		_reset_view_transform()
		_refresh_ws_status()
	_phys_acc = 999.0


func _on_ensure_outlet() -> void:
	if _graph_view != null and _graph_view.has_method("ensure_siphon_outlet_sink"):
		_graph_view.call("ensure_siphon_outlet_sink", _item_id)
	_focus_siphon_conduit_glow()
	_phys_acc = 999.0
	var canvas := _elev_canvas()
	if canvas != null:
		canvas.call("queue_redraw")


func _terrain_loader() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	var main := tree.get_first_node_in_group("main_scene")
	if main == null:
		main = ServiceLocator.main()
	if main == null:
		return null
	return main.get_node_or_null("TerrainLoader")


## Resolve bound graph tank → live map water index (heals stale tags).
func _resolve_bound_pond() -> Dictionary:
	var empty := {"idx": -1, "tag": "", "label": "", "healed": false, "live": false}
	if _graph_view == null or not _graph_view.has_method("resolve_siphon_pond") \
			or _item_id.is_empty():
		return empty
	var tank: Dictionary = _graph_view.call("resolve_siphon_pond", _item_id)
	if tank.is_empty():
		return empty
	var loader := _terrain_loader()
	if loader == null:
		return empty
	var resolved: Dictionary = empty
	if loader.has_method("resolve_pond_idx_for_graph_tank"):
		resolved = loader.call("resolve_pond_idx_for_graph_tank", tank) as Dictionary
	else:
		var tag := str((tank.get("specs", {}) as Dictionary).get("osm_water_tag", ""))
		var idx := -1
		if loader.has_method("find_pond_idx_by_tag"):
			idx = int(loader.call("find_pond_idx_by_tag", tag))
		resolved = {"idx": idx, "tag": tag, "label": str((tank.get("specs", {}) as Dictionary).get("name", "Pond")),
				"healed": false, "live": idx >= 0}
	# Heal stale osm_water_tag on the graph tank when proximity matched a live pond.
	if bool(resolved.get("healed", false)) and _graph_view.get("model") != null:
		var m: GraphModel = _graph_view.get("model") as GraphModel
		var tid := str(tank.get("id", ""))
		var live_tag := str(resolved.get("tag", ""))
		if m != null and not tid.is_empty() and not live_tag.is_empty():
			var specs: Dictionary = (tank.get("specs", {}) as Dictionary).duplicate(true)
			specs["osm_water_tag"] = live_tag
			m.update_item(tid, {"specs": specs})
	return resolved


func _bound_pond_water_idx() -> int:
	return int(_resolve_bound_pond().get("idx", -1))


## True when a catchment node is wired to this turbine's water-in port — mirrors
## resource_flow_engine._siphon_water_in_is_catchment for the Lab status hint.
func _water_in_is_catchment() -> bool:
	var m := _model()
	if m == null or _item_id.is_empty():
		return false
	for conn: Dictionary in m.connections:
		if str(conn.get("target_item_id", "")) != _item_id:
			continue
		var th := str(conn.get("target_handle_id", ""))
		if th != "res_in_0" and th != "input":
			continue
		var src := m.get_item(str(conn.get("source_item_id", "")))
		if not src.is_empty() and str(src.get("type", "")) == "catchment":
			return true
	return false


func _set_ws_status(msg: String, warn: bool = false) -> void:
	if _ws_status_lbl == null:
		return
	_ws_status_lbl.text = msg
	_ws_status_lbl.add_theme_color_override("font_color",
			Color(1.0, 0.72, 0.45, 1.0) if warn else C_MUTED)


func _lab_status_suffix() -> String:
	var parts: PackedStringArray = []
	if _graph_view != null and _graph_view.has_method("resolve_siphon_pond") \
			and not _item_id.is_empty():
		var tank: Dictionary = _graph_view.call("resolve_siphon_pond", _item_id)
		if not tank.is_empty():
			var ts: Dictionary = tank.get("specs", {}) as Dictionary
			var stock := float(ts.get("stock_l", NAN))
			if is_nan(stock):
				stock = float(ts.get("level", 0.0)) * maxf(float(ts.get("capacity_qty", 0.0)), 0.0)
			parts.append("tank %.0f L" % stock)
	var m := _model()
	if m != null and not _item_id.is_empty():
		var q := float((m.get_item(_item_id).get("specs", {}) as Dictionary).get(
				"live_q_lps", 0.0))
		if q > 0.01:
			parts.append("Q %.1f L/s (8″ orifice)" % q)
	if _graph_view != null and _graph_view.has_method("siphon_outlet_cumulative_l") \
			and not _item_id.is_empty():
		var cum := float(_graph_view.call("siphon_outlet_cumulative_l", _item_id))
		parts.append("outlet %.0f L" % cum)
	if parts.is_empty():
		return ""
	return " · " + " · ".join(parts)


func _refresh_ws_status() -> void:
	var resolved := _resolve_bound_pond()
	var idx := int(resolved.get("idx", -1))
	var pond_name := str(resolved.get("label", ""))
	var tank_id := ""
	if _graph_view != null and _graph_view.has_method("resolve_siphon_pond") \
			and not _item_id.is_empty():
		var tank: Dictionary = _graph_view.call("resolve_siphon_pond", _item_id)
		if pond_name.is_empty():
			pond_name = str((tank.get("specs", {}) as Dictionary).get("name", ""))
		tank_id = str(tank.get("id", ""))
	var eng := _lab_status_suffix()
	if pond_name.is_empty() and idx < 0:
		if _water_in_is_catchment():
			_set_ws_status("Catchment can't feed the turbine directly — wire "
					+ "Catchment → Pond storage → turbine (rain needs a pond to fill first).", true)
		else:
			_set_ws_status("No pond nearby — place a pond, then Rebind.", true)
		_update_ws_controls(false, 0.0)
		return
	if idx < 0:
		var id_bit := (" [%s]" % tank_id) if not tank_id.is_empty() else ""
		_set_ws_status("Bound to %s%s — no map body (Add sculpted pond to graph, then Rebind)%s" % [
			pond_name, id_bit, eng], true)
		_update_ws_controls(false, 0.0)
		return
	var loader := _terrain_loader()
	if loader == null:
		_set_ws_status("Terrain loader unavailable.", true)
		_update_ws_controls(false, 0.0)
		return
	var has_ws := false
	if loader.has_method("pond_has_watershed_catchment"):
		has_ws = bool(loader.call("pond_has_watershed_catchment", idx))
	var prev: Dictionary = {}
	if loader.has_method("get_watershed_preview"):
		prev = loader.call("get_watershed_preview") as Dictionary
	var healed := " · tag healed" if bool(resolved.get("healed", false)) else ""
	var id_bit := (" [%s]" % tank_id) if not tank_id.is_empty() else ""
	var preview_valid := bool(prev.get("valid", false)) \
			and str(prev.get("pond_tag", "")) == str(resolved.get("tag", ""))
	# Live inflow arriving from a designated catchment (engine writes it per tick).
	var inflow_bit := ""
	if has_ws and _inflow_lps > 0.02:
		inflow_bit = " · inflow ≈%.2f L/s" % _inflow_lps
	if preview_valid:
		_set_ws_status("Bound: %s%s%s · upstream ~%.2f ha%s%s%s" % [
			pond_name, id_bit, healed,
			float(prev.get("area_m2", 0.0)) / 10000.0,
			" · catchment on graph" if has_ws else "", inflow_bit, eng])
	elif has_ws:
		_set_ws_status("Bound: %s%s%s · watershed on graph — Preview to refresh%s%s" % [
			pond_name, id_bit, healed, inflow_bit, eng])
	else:
		_set_ws_status("Bound: %s%s%s — Preview, then Designate%s" % [
			pond_name, id_bit, healed, eng])
	# F3: Designate only enabled once a matching preview exists (or a catchment is
	# already on the graph — re-designate to refresh). F4: seasonal inflow estimate.
	_update_ws_controls(preview_valid or has_ws,
			float(prev.get("area_m2", 0.0)) if (preview_valid or has_ws) else 0.0)


## Enable/disable the Designate button per the preview state machine and refresh
## the seasonal inflow estimate line for the given catchment area (m²).
func _update_ws_controls(can_designate: bool, area_m2: float) -> void:
	if _ws_designate_btn != null:
		_ws_designate_btn.disabled = not can_designate
		_ws_designate_btn.tooltip_text = "" if can_designate else "Preview a valid catchment first"
	if _ws_season_lbl == null:
		return
	if area_m2 <= 1.0:
		_ws_season_lbl.text = ""
		return
	var mm := _monthly_precip_mm()
	if mm.size() != 12:
		_ws_season_lbl.text = ""
		return
	# Runoff volume for the wettest and driest months: area × runoff coeff × depth.
	var runoff := 0.85
	var wet_i := 0
	var dry_i := 0
	for i in 12:
		if float(mm[i]) > float(mm[wet_i]):
			wet_i = i
		if float(mm[i]) < float(mm[dry_i]):
			dry_i = i
	var names := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
	var wet_m3 := area_m2 * runoff * float(mm[wet_i]) / 1000.0
	var dry_m3 := area_m2 * runoff * float(mm[dry_i]) / 1000.0
	_ws_season_lbl.text = "Seasonal runoff ≈ %s m³ in %s (wettest) · %s m³ in %s (driest)" % [
		_fmt_m3(wet_m3), names[wet_i], _fmt_m3(dry_m3), names[dry_i]]


func _fmt_m3(v: float) -> String:
	return ("%.0f" % v) if v >= 100.0 else ("%.1f" % v)


func _monthly_precip_mm() -> Array:
	var ws := _weather_service()
	if ws != null and ws.has_method("monthly_precip_mm"):
		return ws.call("monthly_precip_mm") as Array
	return []


func _on_ws_preview() -> void:
	var resolved := _resolve_bound_pond()
	var idx := int(resolved.get("idx", -1))
	var loader := _terrain_loader()
	if idx < 0 or loader == null:
		_set_ws_status("No live map pond for this bind — Add sculpted pond to graph, then Rebind.", true)
		return
	var result: Dictionary = {}
	if loader.has_method("preview_pond_watershed"):
		result = loader.call("preview_pond_watershed", idx) as Dictionary
	if bool(result.get("valid", false)):
		_set_ws_status("Bound: %s · upstream ~%.2f ha (%d cells) — teal on Elev + ground" % [
			str(resolved.get("label", "Pond")),
			float(result.get("area_m2", 0.0)) / 10000.0,
			int(result.get("cell_count", 0))])
		_update_ws_controls(true, float(result.get("area_m2", 0.0)))
	else:
		_set_ws_status("Watershed failed: %s" % str(result.get("reason", "unknown")), true)
		_update_ws_controls(false, 0.0)
	var canvas := _elev_canvas()
	if canvas != null:
		canvas.call("queue_redraw")
	if _graph_view != null and _graph_view.has_method("queue_canvas_redraw"):
		_graph_view.call("queue_canvas_redraw")


func _on_ws_designate() -> void:
	var resolved := _resolve_bound_pond()
	var idx := int(resolved.get("idx", -1))
	var loader := _terrain_loader()
	if idx < 0 or loader == null:
		_set_ws_status("No live map pond for this bind — Add to graph, then Rebind.", true)
		return
	var ok := false
	if loader.has_method("designate_pond_watershed"):
		ok = bool(loader.call("designate_pond_watershed", idx))
	if ok:
		var prev: Dictionary = {}
		if loader.has_method("get_watershed_preview"):
			prev = loader.call("get_watershed_preview") as Dictionary
		_set_ws_status("Designated %s · ~%.2f ha · catchment beside tank" % [
			str(resolved.get("label", "Pond")),
			float(prev.get("area_m2", 0.0)) / 10000.0])
	else:
		var result: Dictionary = {}
		if loader.has_method("analyze_pond_watershed"):
			result = loader.call("analyze_pond_watershed", idx) as Dictionary
		_set_ws_status("Designate failed: %s" % str(result.get("reason", "check pond on graph")), true)
	var canvas := _elev_canvas()
	if canvas != null:
		canvas.call("queue_redraw")
	if _graph_view != null and _graph_view.has_method("queue_canvas_redraw"):
		_graph_view.call("queue_canvas_redraw")


func _on_ws_clear_preview() -> void:
	var loader := _terrain_loader()
	if loader != null and loader.has_method("clear_watershed_preview"):
		loader.call("clear_watershed_preview")
	_set_ws_status("Watershed preview cleared (designation unchanged).")
	_refresh_ws_status()
	var canvas := _elev_canvas()
	if canvas != null:
		canvas.call("queue_redraw")
	if _graph_view != null and _graph_view.has_method("queue_canvas_redraw"):
		_graph_view.call("queue_canvas_redraw")


func _on_ws_remove() -> void:
	var resolved := _resolve_bound_pond()
	var idx := int(resolved.get("idx", -1))
	var loader := _terrain_loader()
	if idx < 0 or loader == null:
		_set_ws_status("No live map pond bound.", true)
		return
	if loader.has_method("remove_pond_watershed"):
		loader.call("remove_pond_watershed", idx)
	if loader.has_method("clear_watershed_preview"):
		loader.call("clear_watershed_preview")
	_set_ws_status("Watershed catchment removed from %s" % str(resolved.get("label", "pond")))
	var canvas := _elev_canvas()
	if canvas != null:
		canvas.call("queue_redraw")
	if _graph_view != null and _graph_view.has_method("queue_canvas_redraw"):
		_graph_view.call("queue_canvas_redraw")


func _on_sim_inflow_toggled(on: bool) -> void:
	if _syncing:
		return
	var lps := 5.0
	if _sim_inflow_spin != null:
		lps = float(_sim_inflow_spin.value)
	_write_sim_inflow(on, lps)


func _write_sim_inflow(enabled: bool, lps: float) -> void:
	var m := _model()
	if m == null or _item_id.is_empty():
		return
	var item := m.get_item(_item_id)
	if item.is_empty():
		return
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	specs["lab_sim_inflow_enabled"] = enabled
	specs["lab_sim_inflow_lps"] = maxf(lps, 0.0)
	m.update_item(_item_id, {"specs": specs})
	if enabled and _graph_view != null and _graph_view.has_method("ensure_siphon_outlet_sink"):
		_graph_view.call("ensure_siphon_outlet_sink", _item_id)
	_phys_acc = 999.0
	_pond_cache_t = 999.0
	# Immediate visual kick — don't wait for the next flow-engine wall tick.
	if enabled and _graph_view != null and _graph_view.has_method("push_pond_levels_to_mesh"):
		_graph_view.call("push_pond_levels_to_mesh", true)
	_redraw_preview()


## True when the manual test-inflow term is filling the bound pond.
func _lab_runtime_active() -> bool:
	if not _as_view or _item_id.is_empty():
		return false
	var m := _model()
	if m == null:
		return false
	var specs: Dictionary = m.get_item(_item_id).get("specs", {}) as Dictionary
	return bool(specs.get("lab_sim_inflow_enabled", false))


## Current water inflow into the bound pond (L/s) — the sum of any catchment
## rain-capture wired to the pond (engine writes `live_capture_lph` per tick) plus
## the manual Test-inflow term. Drives the Lab's runoff-into-pond depiction.
func _sample_pond_inflow_lps() -> float:
	var m := _model()
	if m == null or _graph_view == null:
		return 0.0
	var total := 0.0
	# Manual test inflow (added to the pond by the engine's siphon path).
	if not _item_id.is_empty():
		var s_specs: Dictionary = m.get_item(_item_id).get("specs", {}) as Dictionary
		if bool(s_specs.get("lab_sim_inflow_enabled", false)):
			total += maxf(float(s_specs.get("lab_sim_inflow_lps", 0.0)), 0.0)
	# Catchment rain-capture wired into the pond tank.
	if _graph_view.has_method("resolve_siphon_pond"):
		var tank: Dictionary = _graph_view.call("resolve_siphon_pond", _item_id)
		var pond_id := str(tank.get("id", ""))
		if not pond_id.is_empty():
			for conn: Dictionary in m.connections:
				if str(conn.get("target_item_id", "")) != pond_id:
					continue
				var src := m.get_item(str(conn.get("source_item_id", "")))
				if src.is_empty() or str(src.get("type", "")) != "catchment":
					continue
				var c_specs: Dictionary = src.get("specs", {}) as Dictionary
				total += maxf(float(c_specs.get("live_capture_lph", 0.0)), 0.0) / 3600.0
	return total


func _process(delta: float) -> void:
	if not visible:
		return
	# Mirror the world-clock-driven pond onto the 3D twin + Elevation CT while the
	# Lab is open. The flow engine ticks the water on the world clock; this only
	# syncs visuals (no separate lab clock, no demo oscillator).
	if _as_view and _graph_view != null and _graph_view.has_method("lab_siphon_tick"):
		_graph_view.call("lab_siphon_tick", _item_id, delta)
		_pond_cache_t = 999.0  # force pond context refresh after tank writes
	_phys_acc += delta
	_ui_acc += delta
	_pond_cache_t += delta
	if _phys_acc >= 1.0 / _PHYS_HZ:
		_phys_acc = 0.0
		_refresh_physics()
		if _elev_ct_bg:
			_push_lab_section_frame()
	var target := float(_last_r.get("omega", 0.0))
	var k := 1.0 - exp(-delta / 0.45)
	_prop_omega = lerpf(_prop_omega, target, clampf(k, 0.0, 1.0))
	if absf(_prop_omega) > 0.02:
		_prop_angle = wrapf(_prop_angle + _prop_omega * delta, -TAU, TAU)
	# Advance the flow-particle animation while there is EITHER outflow through the
	# turbine or inflow arriving at the pond (freezes only when the whole reach is
	# static, so a dry culvert with no rain reads dry).
	var outflowing := float(_last_r.get("q_lps", 0.0)) > 0.01 and bool(_last_r.get("primed", false))
	if outflowing or _inflow_lps > 0.02:
		_flow_phase += delta
	# Ease the DRAWN pond level toward the model level so a fast drain/fill reads as
	# a smooth surface instead of snapping frame-to-frame (physics untouched).
	var lvl_target := float(_pond_context().get("level_m", NAN))
	if not is_nan(lvl_target):
		if is_nan(_display_level_m):
			_display_level_m = lvl_target
		else:
			_display_level_m = lerpf(_display_level_m, lvl_target,
					clampf(1.0 - exp(-delta / 0.35), 0.0, 1.0))
	# Smooth the inflow rate for the runoff-into-pond depiction.
	_inflow_lps = lerpf(_inflow_lps, _sample_pond_inflow_lps(),
			clampf(1.0 - exp(-delta / 0.5), 0.0, 1.0))
	# Redraw the own cross-section every UI tick while open — the pond level and
	# flow evolve continuously on the world clock, even when the rotor is parked.
	if _ui_acc >= 1.0 / _UI_HZ:
		_ui_acc = 0.0
		if _preview != null:
			_preview.queue_redraw()


func _pond_context() -> Dictionary:
	if _pond_cache_t < 0.25 and not _cached_pond.is_empty():
		return _cached_pond
	_pond_cache_t = 0.0
	var out := {
		"level_m": NAN, "floor_m": NAN, "rim_m": NAN,
		"site": Vector2.ZERO, "label": "", "stock_l": 0.0,
	}
	if _graph_view == null or not _graph_view.has_method("resolve_siphon_pond") \
			or _item_id.is_empty():
		_cached_pond = out
		return out
	var tank: Dictionary = _graph_view.call("resolve_siphon_pond", _item_id)
	if tank.is_empty():
		_cached_pond = out
		return out
	var ts: Dictionary = tank.get("specs", {}) as Dictionary
	out["label"] = str(ts.get("name", "Pond"))
	out["floor_m"] = float(ts.get("floor_m", NAN))
	out["rim_m"] = float(ts.get("rim_m", NAN))
	out["level_m"] = float(ts.get("level_m", NAN))
	out["stock_l"] = float(ts.get("stock_l",
			float(ts.get("level", 0.0)) * float(ts.get("capacity_qty", 0.0))))
	if GraphSiteLayout.has_site_coords(tank):
		out["site"] = GraphSiteLayout.site_xz(tank)
	if is_nan(out["level_m"]) and not is_nan(out["rim_m"]) and not is_nan(out["floor_m"]):
		var span := maxf(out["rim_m"] - out["floor_m"], 0.05)
		out["level_m"] = out["floor_m"] + clampf(float(ts.get("level", 0.5)), 0.0, 1.0) * span
	_cached_pond = out
	return out


## Pull module/start/break from the live graph item (3D prop moves update specs).
func _sync_level_spins_from_model() -> void:
	if _syncing or not _grab_kind.is_empty():
		return
	var item := _current_item()
	if item.is_empty():
		return
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	var elev := float(item.get("elevation_m", NAN))
	var levels := SiphonHydraulics.resolve_siphon_levels(specs, elev)
	var mod_e := float(levels.get("module_elev_m", NAN))
	var start_m := float(levels.get("siphon_start_m", NAN))
	var break_m := float(levels.get("siphon_break_m", NAN))
	if is_nan(mod_e) or is_nan(start_m) or is_nan(break_m):
		return
	_syncing = true
	if _module_spin != null and absf(float(_module_spin.value) - mod_e) > 1e-3:
		_module_spin.value = mod_e
	if _start_spin != null and absf(float(_start_spin.value) - start_m) > 1e-3:
		_start_spin.value = start_m
	if _break_spin != null and absf(float(_break_spin.value) - break_m) > 1e-3:
		_break_spin.value = break_m
	_syncing = false


func _refresh_physics() -> void:
	_sync_level_spins_from_model()
	var m := _model()
	if m == null or _item_id.is_empty():
		return
	var item := m.get_item(_item_id)
	if item.is_empty():
		return
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var pond := _pond_context()
	var level_m := float(pond.get("level_m", NAN))
	if is_nan(level_m):
		level_m = float(_start_spin.value)
	# Single source of truth: readouts come from the SAME unified reach the flow
	# engine steps (HydroReach), so there's no live-telemetry-vs-fallback branch
	# to diverge. `siphon_primed` in specs carries prime hysteresis from the
	# engine's last tick; the spin values are the user's live edits.
	var sim_specs := specs.duplicate(true)
	sim_specs["siphon_start_m"] = float(_start_spin.value)
	sim_specs["siphon_break_m"] = float(_break_spin.value)
	sim_specs["module_elev_m"] = float(_module_spin.value)
	if is_nan(float(sim_specs.get("outlet_invert_m", NAN))):
		sim_specs["outlet_invert_m"] = float(_module_spin.value) - 9.0
	_last_r = HydroReach.evaluate_specs(level_m, sim_specs)
	_rpm_lbl.text = "%.0f" % float(_last_r.get("rpm", 0.0))
	_pe_lbl.text = "%.0f W" % float(_last_r.get("pe_w", 0.0))
	_elec_lbl.text = "%.0f W" % float(_last_r.get("power_w", 0.0))
	_flow_lbl.text = "%.2f L/s" % float(_last_r.get("q_lps", 0.0))
	_head_lbl.text = "%.2f m" % float(_last_r.get("head_m", 0.0))
	var primed := bool(_last_r.get("primed", false))
	if str(_last_r.get("conveyance", "")) == "penstock":
		var q_now := float(_last_r.get("q_lps", 0.0))
		if q_now > 0.01:
			_state_lbl.text = "FLOWING"
			_state_lbl.tooltip_text = "Water is flowing through the penstock to the turbine."
		else:
			_state_lbl.text = "dry"
			_state_lbl.tooltip_text = "No flow — the pond surface is at or below the intake invert. Raise the water level."
	else:
		if primed:
			_state_lbl.text = "PRIMED"
			_state_lbl.tooltip_text = "The siphon is primed and draining the pond."
		else:
			var regime := str(_last_r.get("regime", "dry"))
			_state_lbl.text = regime
			# Explain WHY it isn't producing instead of a bare "broken"/"dry".
			if regime == "broken":
				_state_lbl.tooltip_text = "Pond dropped to the air-break level — the siphon sucks air and loses prime. Raise the water above the prime line to restart."
			elif regime == "no_head":
				_state_lbl.tooltip_text = "Outlet isn't below the pond — no head to drive flow. Route the culvert downhill."
			else:
				_state_lbl.tooltip_text = "Not primed — fill the pond above the prime (Start) line to start the siphon."
	if _lab_runtime_active():
		_refresh_ws_status()
	var cum := 0.0
	if _graph_view != null and _graph_view.has_method("siphon_outlet_cumulative_l"):
		cum = float(_graph_view.call("siphon_outlet_cumulative_l", _item_id))
	_cum_lbl.text = "%.0f L" % cum
	_refresh_estimate(sim_specs)


## Populate the Estimate card: instantaneous pipe capacity + head loss (from the
## live reach snapshot, valid for both conveyances) and, for CONTINUOUS-flow
## penstock kinds, a representative-year capacity factor + annual energy via the
## shared `HydroSource.annual_energy_kwh_from_specs` closed form. Siphon drawdown
## has no well-defined annual figure (bounded by pond refill), so it shows the
## operating point only with an explanatory note.
func _refresh_estimate(sim_specs: Dictionary) -> void:
	if _capacity_lbl == null:
		return
	var cap_lps := float(_last_r.get("q_capacity_lps", NAN))
	_capacity_lbl.text = ("%.2f L/s" % cap_lps) if not is_nan(cap_lps) else "—"
	var loss := float(_last_r.get("head_loss_m", NAN))
	_loss_lbl.text = ("%.2f m" % loss) if not is_nan(loss) else "—"

	if not _kind_has_penstock():
		_capfac_lbl.text = "—"
		_annual_lbl.text = "—"
		_estimate_hint_lbl.text = "Siphon drains a stored pond — annual output depends on how fast rain refills it (see Watershed). Operating point above is the live estimate."
		return

	# Build a spec for the shared closed form from the live geometry + penstock edits.
	var gross := maxf(float(_last_r.get("head_m", 0.0)), 0.0)
	var est := sim_specs.duplicate(true)
	est["gross_head_m"] = gross
	est["design_flow_lps"] = maxf(float(_design_flow_spin.value) if _design_flow_spin != null else 0.0, 0.01)
	est["penstock_length_m"] = float(_penstock_len_spin.value) if _penstock_len_spin != null else 60.0
	est["penstock_diameter_mm"] = float(_penstock_d_spin.value) if _penstock_d_spin != null else 63.0
	if _roughness_spin != null:
		est["pipe_roughness_mm"] = float(_roughness_spin.value)
	if _turb_eff_spin != null and float(_turb_eff_spin.value) > 0.0:
		est["turbine_efficiency"] = float(_turb_eff_spin.value)
	var mults: Array = []
	var ws := _weather_service()
	if ws != null and ws.has_method("monthly_precip_multipliers"):
		mults = ws.call("monthly_precip_multipliers") as Array
	var ann := HydroSource.annual_energy_kwh_from_specs(est, mults)
	var mean_kw := float(ann.get("mean_kw", 0.0))
	var nameplate_w := float(sim_specs.get("max_power_w", 0.0))
	if nameplate_w > 0.0:
		_capfac_lbl.text = "%.0f%%" % clampf(mean_kw * 1000.0 / nameplate_w * 100.0, 0.0, 100.0)
	else:
		_capfac_lbl.text = "n/a (no nameplate)"
	_annual_lbl.text = "%.0f kWh/yr" % float(ann.get("annual_kwh", 0.0))
	_estimate_hint_lbl.text = "Representative-year estimate at continuous flow (Q capped by pipe + design flow); seasonal precipitation weights the monthly flow."


func _weather_service() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	return tree.root.get_node_or_null("WeatherService")


func _soi_service() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	return tree.root.get_node_or_null("SoiService")


func _elev_canvas() -> Node:
	if _graph_view == null:
		return null
	return _graph_view.get("_graph_canvas") as Node


## Same CT heading + slice offset as Elevation view (single source of truth).
func _elev_section_params() -> Dictionary:
	var canvas := _elev_canvas()
	var heading := 0.0
	var offset := 0.0
	if canvas != null:
		heading = float(canvas.get("elevation_heading_rad"))
		offset = float(canvas.get("elevation_section_offset_m"))
	return {"heading": heading, "offset": offset}


func _slice_frame(pond: Dictionary) -> Dictionary:
	## Pond-relative along window on the Elevation CT plane (shared heading/offset).
	## half_w from full basin poly span when available (not footprint-only).
	var half_w := 4.0
	var module_along := 3.5
	var params := _elev_section_params()
	var heading := float(params.get("heading", 0.0))
	var offset := float(params.get("offset", 0.0))
	var pond_site := pond.get("site", Vector2.ZERO) as Vector2
	var m := _model()
	var along_dir := Vector2(cos(heading), sin(heading))
	var tank: Dictionary = {}
	if m != null and not _item_id.is_empty():
		var item: Dictionary = m.get_item(_item_id)
		if GraphSiteLayout.has_site_coords(item) and pond_site != Vector2.ZERO:
			# Along the Elev section — not a private pond→module heading.
			module_along = GraphSiteLayout.site_xz(item).dot(along_dir) \
					- pond_site.dot(along_dir)
			if absf(module_along) < 0.5:
				module_along = 3.5
		if _graph_view != null and _graph_view.has_method("resolve_siphon_pond"):
			tank = _graph_view.call("resolve_siphon_pond", _item_id)
	if not tank.is_empty():
		var specs: Dictionary = tank.get("specs", {}) as Dictionary
		half_w = maxf(float(specs.get("footprint_w_m", 8.0)) * 0.5, 2.0)
		half_w = maxf(half_w, maxf(float(specs.get("footprint_d_m", 0.0)), 2.0) * 0.5)
		# Prefer live poly along-span (full basin, not truncated footprint).
		if _graph_view != null and _graph_view.has_method("pond_poly_half_width_m"):
			half_w = maxf(half_w, float(_graph_view.call(
					"pond_poly_half_width_m", tank, along_dir)))
		elif _elev_canvas() != null \
				and _elev_canvas().has_method("_elevation_pond_half_width_m"):
			half_w = maxf(half_w, float(_elev_canvas().call(
					"_elevation_pond_half_width_m", tank, specs, along_dir)))
	# Cover full basin + turbine with slack; do not cap at 10 m for DEM bake.
	var along0 := -half_w - 2.0
	var along1 := maxf(module_along + 6.0, half_w + 4.0)
	if module_along < 0.0:
		along0 = minf(module_along - 6.0, -half_w - 2.0)
		along1 = half_w + 2.0
	return {
		"heading": heading,
		"offset": offset,
		"half_w": half_w,
		"module_along": module_along,
		"along0": along0,
		"along1": along1,
		"pond_site": pond_site,
	}


func _ensure_dem_bake(pond: Dictionary, frame: Dictionary) -> void:
	var soi := _soi_service()
	var center3 := Vector3.ZERO
	if soi != null and soi.has_method("world_center"):
		center3 = soi.call("world_center") as Vector3
	# MUST match Elevation CT: same heading + section_offset_m.
	var heading := float(frame.get("heading", 0.0))
	var offset := float(frame.get("offset", 0.0))
	var a0 := float(frame.get("along0", -6.0))
	var a1 := float(frame.get("along1", 8.0))
	var pond_site: Vector2 = frame.get("pond_site", Vector2.ZERO) as Vector2
	var along_dir := Vector2(cos(heading), sin(heading))
	var pond_along := pond_site.dot(along_dir)
	a0 += pond_along
	a1 += pond_along
	var key := "%.4f|%.2f|%.2f|%.2f|%.1f" % [heading, offset, a0, a1, center3.y]
	if key == _dem_bake_key and _dem_along.size() >= _DEM_SAMPLES:
		return
	_dem_bake_key = key
	ElevationProfile.bake_window(soi, center3, heading, offset, a0, a1, _DEM_SAMPLES,
			_dem_along, _dem_elev)
	# Shift along so pond is at 0 for screen mapping.
	for i in _dem_along.size():
		_dem_along[i] -= pond_along


func _focus_siphon_conduit_glow() -> void:
	if _graph_view == null or _item_id.is_empty():
		return
	if _graph_view.has_method("focus_siphon_conduit_glow"):
		_graph_view.call("focus_siphon_conduit_glow", _item_id)


func _reset_view_transform() -> void:
	_view_zoom = 1.0
	_view_pan = Vector2.ZERO
	_view_dragging = false
	_grab_kind = ""


func _redraw_preview() -> void:
	if _preview != null:
		_preview.queue_redraw()


## Elevation (m) at a screen Y, inverting _pv_to_screen_centered (zoom/pan aware).
func _elev_at_screen_y(y: float) -> float:
	if _pv_linked:
		var denom := _pv_sy
		if denom <= 1e-6:
			return _pv_elev_mid
		return _pv_elev_mid - (y - (_pv_origin.y + _pv_size.y * 0.5)) / denom
	var denom2 := _pv_sy * _view_zoom
	if denom2 <= 1e-6:
		return _pv_y_min
	return _pv_y_min + (_pv_origin.y + _pv_size.y + _view_pan.y - y) / denom2


## Preview interaction: wheel zoom (linked CT), prop hover/drag, level lines, pan.
func _on_preview_stack_input(event: InputEvent) -> void:
	if not visible:
		return
	# Prop hover / drag / click (Elevation-plane spatial edit) before level/pan.
	if _try_lab_spatial_input(event):
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_view_zoom = clampf(_view_zoom * 1.1, 0.25, 8.0)
			_preview_stack.accept_event()
			_push_lab_section_frame()
			_redraw_preview()
			return
		if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_view_zoom = clampf(_view_zoom / 1.1, 0.25, 8.0)
			_preview_stack.accept_event()
			_push_lab_section_frame()
			_redraw_preview()
			return
		if mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_MIDDLE:
			if mb.pressed:
				_view_last_mouse = mb.position
				_grab_kind = _pick_level_grab(mb.position) \
						if mb.button_index == MOUSE_BUTTON_LEFT else ""
				_view_dragging = _grab_kind.is_empty()
			else:
				_view_dragging = false
				_grab_kind = ""
			_preview_stack.accept_event()
			return
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if not _grab_kind.is_empty():
			_apply_level_drag(_grab_kind, _elev_at_screen_y(mm.position.y))
			_view_last_mouse = mm.position
			_preview_stack.accept_event()
			_redraw_preview()
			return
		if _view_dragging:
			_view_pan += mm.position - _view_last_mouse
			_view_last_mouse = mm.position
			_preview_stack.accept_event()
			_push_lab_section_frame()
			_redraw_preview()


## Hydro Lab → GraphSpatialEdit (hover / LMB drag in the section plane / click).
func _try_lab_spatial_input(event: InputEvent) -> bool:
	if _graph_view == null or not _elev_ct_bg:
		return false
	var se = _graph_view.get("_spatial_edit")
	if se == null:
		return false
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return false
		if mb.pressed:
			if se.has_method("begin_prop_drag") \
					and bool(se.call("begin_prop_drag", mb.position, mb.shift_pressed)):
				_lab_prop_drag = true
				_view_dragging = false
				_grab_kind = ""
				# Select bound graph item → inspector shows turbine props.
				var pid := str(se.get("selected_prop_id"))
				if not pid.is_empty() and _graph_view.has_method("select_item_by_world_binding"):
					_graph_view.call("select_item_by_world_binding", pid)
				_preview_stack.accept_event()
				_redraw_preview()
				return true
			return false
		if _lab_prop_drag or (se.has_method("is_dragging") and bool(se.call("is_dragging"))):
			if se.has_method("end_prop_drag"):
				se.call("end_prop_drag")
			_lab_prop_drag = false
			_preview_stack.accept_event()
			_push_lab_section_frame()
			_redraw_preview()
			return true
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _lab_prop_drag or (se.has_method("is_dragging") and bool(se.call("is_dragging"))):
			if se.has_method("drag_to"):
				se.call("drag_to", mm.position, mm.shift_pressed)
			_preview_stack.accept_event()
			_redraw_preview()
			return true
		if se.has_method("update_hover"):
			se.call("update_hover", mm.position)
	return false


## What the user grabbed on the CT: the thin Prime/Break lines (tight snap), else
## anywhere in the pond column drags the WATER level (fill/drain by hand).
func _pick_level_grab(pos: Vector2) -> String:
	var elev := _elev_at_screen_y(pos.y)
	var scale := _pv_sy * _view_zoom
	var best := ""
	var best_px := 8.0
	var hit_scale := _pv_sy if _pv_linked else scale
	if _start_spin != null:
		var d := absf(elev - float(_start_spin.value)) * hit_scale
		if d < best_px:
			best_px = d
			best = "prime"
	if _break_spin != null:
		var d2 := absf(elev - float(_break_spin.value)) * hit_scale
		if d2 < best_px:
			best_px = d2
			best = "break"
	if not best.is_empty():
		return best
	# Not on a level line — grab the water if the cursor is in the pond's range.
	var pond := _pond_context()
	var floor_m := float(pond.get("floor_m", NAN))
	var rim_m := float(pond.get("rim_m", NAN))
	if not is_nan(floor_m) and not is_nan(rim_m) \
			and elev >= floor_m - 0.5 and elev <= rim_m + 1.0:
		return "water"
	return ""


func _apply_level_drag(kind: String, elev: float) -> void:
	if _syncing:
		return
	if kind == "prime" and _start_spin != null:
		_start_spin.value = elev
	elif kind == "break" and _break_spin != null:
		_break_spin.value = elev
	elif kind == "water" and _graph_view != null \
			and _graph_view.has_method("lab_set_pond_level"):
		_graph_view.call("lab_set_pond_level", _item_id, elev)
		_pond_cache_t = 999.0
	_phys_acc = 999.0


func _current_item() -> Dictionary:
	if _graph_view == null or _item_id.is_empty():
		return {}
	var m: Variant = _graph_view.get("model")
	if m == null or not m.has_method("get_item"):
		return {}
	return m.call("get_item", _item_id) as Dictionary


func _push_lab_section_frame() -> void:
	if not _elev_ct_bg or _graph_view == null:
		return
	if not _graph_view.has_method("sync_siphon_lab_section_frame"):
		return
	_graph_view.call("sync_siphon_lab_section_frame", get_lab_section_frame())


func _draw_preview() -> void:
	var r := _preview.get_rect()
	if r.size.x < 8.0 or r.size.y < 8.0:
		return
	# Linked CT mode: project into the FULL preview rect (same pixels as the
	# SubViewportContainer). A 20px inset made overlays diverge on zoom/pan.
	var origin := Vector2.ZERO
	var size := r.size
	if not _elev_ct_bg:
		origin = Vector2(20, 20)
		size = r.size - Vector2(36, 36)
	if size.x < 8.0 or size.y < 8.0:
		return
	# Elevation CT is the background when embedded; otherwise opaque 2D CT.
	if not _elev_ct_bg:
		_preview.draw_rect(Rect2(origin, size), Color(0.05, 0.08, 0.12, 1.0), true)
	_preview.draw_rect(Rect2(origin, size), C_BORDER, false, 1.0)

	var pond := _pond_context()
	var floor_m := float(pond.get("floor_m", NAN))
	var rim_m := float(pond.get("rim_m", NAN))
	# Draw the EASED level so a fast drain/fill glides instead of snapping; fall back
	# to the raw model level before the ease has a first sample.
	var level_m := _display_level_m if not is_nan(_display_level_m) else float(pond.get("level_m", NAN))
	var module_m := float(_module_spin.value)
	var start_m := float(_start_spin.value)
	var break_m := float(_break_spin.value)
	if is_nan(floor_m):
		floor_m = minf(module_m, break_m) - 1.5
	if is_nan(rim_m):
		rim_m = maxf(module_m, start_m) + 0.8
	if is_nan(level_m):
		level_m = clampf((start_m + break_m) * 0.5, floor_m, rim_m)

	var frame := _slice_frame(pond)
	var half_w := float(frame.get("half_w", 3.0))
	var module_along := float(frame.get("module_along", 3.5))
	var a0 := float(frame.get("along0", -half_w - 2.0))
	var a1 := float(frame.get("along1", module_along + 6.0))
	var heading := float(frame.get("heading", 0.0))
	var along_dir := Vector2(cos(heading), sin(heading))
	var pond_site: Vector2 = frame.get("pond_site", Vector2.ZERO) as Vector2
	var pond_along := pond_site.dot(along_dir)
	var out_inv := float(_outlet_inv_spin.value) if _outlet_inv_spin != null else NAN

	_ensure_dem_bake(pond, frame)
	_pv_origin = origin
	_pv_size = size
	# Frame vertically on the pond BASIN + module + prime/break levels only — NOT
	# the full culvert drop to the outlet or the distant hilltop, both of which
	# crush the level detail into an unreadable sliver. The culvert exits the
	# frame heading down to the (labeled) outlet.
	var mod_ground := _dem_elev_at(module_along)
	var lo := minf(floor_m, break_m)
	var hi := maxf(rim_m, maxf(start_m, module_m + 1.2))
	if not is_nan(mod_ground):
		lo = minf(lo, mod_ground - 0.4)
		hi = maxf(hi, mod_ground + 0.4)
	var along_mid := (a0 + a1) * 0.5
	_pv_linked = false
	if _elev_ct_bg:
		# Overlay uses pond-relative along; CT camera gets absolute via sync.
		var metrics := _lab_view_metrics()
		along_mid = float(metrics.get("along_m_rel", along_mid))
		_pv_elev_mid = float(metrics.get("elev_m", (lo + hi) * 0.5))
		var ortho_w := maxf(float(metrics.get("ortho_w_m", a1 - a0)), 1.0)
		var ortho_h := maxf(float(metrics.get("ortho_h_m", hi - lo)), 1.0)
		_pv_sx = size.x / ortho_w
		_pv_sy = size.y / ortho_h
		_pv_y_min = _pv_elev_mid - ortho_h * 0.5
		_pv_linked = true
	else:
		var vspan := maxf(hi - lo, 2.0)
		_pv_y_min = lo - vspan * 0.14
		var y_max := hi + vspan * 0.14
		var span := maxf(y_max - _pv_y_min, 1.0)
		var along_span := maxf(a1 - a0, 1.0)
		_pv_sx = size.x / along_span
		_pv_sy = size.y / span

	# Project DEM once — shared by terrain fill + bathymetry-clipped pond.
	var ground := PackedVector2Array()
	var n_dem := mini(_dem_along.size(), _dem_elev.size())
	ground.resize(n_dem)
	for i in range(n_dem):
		ground[i] = _pv_to_screen_centered(_dem_along[i], _dem_elev[i], along_mid)
	# 2D terrain only when Elevation CT is not hosting the slot.
	if not _elev_ct_bg and n_dem >= 2:
		ElevationCrossSection.draw_terrain(_preview, ground,
				Vector2(origin.x, origin.y + size.y),
				Vector2(origin.x + size.x, origin.y + size.y), 2.0)

	# Pond water follows DEM bathymetry (not a floor→level rectangle).
	if n_dem >= 2:
		var level_sy := _pv_to_screen_centered(along_mid, level_m, along_mid).y
		ElevationCrossSection.draw_pond_filled(_preview, ground, _dem_elev,
				level_m, level_sy, 2.0)
	else:
		var left := _pv_to_screen_centered(-half_w, level_m, along_mid)
		var right := _pv_to_screen_centered(half_w, level_m, along_mid)
		var bot_l := _pv_to_screen_centered(-half_w, floor_m, along_mid)
		var bot_r := _pv_to_screen_centered(half_w, floor_m, along_mid)
		ElevationCrossSection.draw_pond_band(_preview, left, right, bot_l, bot_r, 2.0)

	# Runoff arriving from the watershed: when the catchment (or test inflow) is
	# feeding the pond, draw falling streaks onto the uphill (higher-ground) bank so
	# the "rain fills the pond" half of the loop is visible, labelled in L/s.
	if _inflow_lps > 0.02:
		var up_left := _dem_elev_at(-half_w) if not is_nan(_dem_elev_at(-half_w)) else rim_m
		var up_right := _dem_elev_at(half_w) if not is_nan(_dem_elev_at(half_w)) else rim_m
		var uphill_left := up_left >= up_right
		var bank_along := (-half_w) if uphill_left else half_w
		var bank_ground := maxf(up_left, up_right)
		_draw_runoff_inflow(bank_along, bank_ground, level_m, along_mid,
				_inflow_lps, uphill_left, origin, size)

	var s0 := _pv_to_screen_centered(-half_w - 0.2, start_m, along_mid)
	var s1 := _pv_to_screen_centered(half_w + 0.2, start_m, along_mid)
	var b0 := _pv_to_screen_centered(-half_w - 0.2, break_m, along_mid)
	var b1 := _pv_to_screen_centered(half_w + 0.2, break_m, along_mid)
	ElevationCrossSection.draw_level_ticks(_preview, s0, s1, b0, b1, Rect2(), 11)

	# Turbine module: submerged side-intake elbow (low, from the pond, no visible
	# fitting) into a vertical housing with a spinning prop + shaft + motor cap
	# poking above ground, exiting straight out the bottom into the culvert —
	# matches the player's SketchUp reference cross-section.
	var mx := module_along
	var mod_base := module_m - 1.0
	if not is_nan(mod_ground):
		mod_base = minf(mod_base, mod_ground - 0.3)
	var mod_top_elev := maxf(module_m, start_m) + 0.6
	var q_lps := float(_last_r.get("q_lps", 0.0))
	var primed := bool(_last_r.get("primed", false))
	var flowing := primed and q_lps > 0.01
	var water_top := level_m if not is_nan(level_m) else start_m
	var intake_elev := minf(break_m, water_top) - 0.2
	var out_d_m := float(_outlet_d_spin.value) * 0.001 if _outlet_d_spin != null else 0.2

	# When Elevation CT hosts the slot, the sliced hydroturbine GLB + 3D conduits
	# are the turbine/pipe visuals; 2D glyphs are a fallback for offline CT.
	if not _elev_ct_bg:
		if _kind_has_penstock():
			var pen_d_m := float(_penstock_d_spin.value) * 0.001 if _penstock_d_spin != null else 0.063
			_draw_penstock_glyph(mx, intake_elev, half_w - 0.3, out_inv, module_m,
					a1, along_mid, pen_d_m, out_d_m, q_lps, flowing,
					origin, size)
		else:
			var in_d_m := float(_intake_d_spin.value) * 0.001 if _intake_d_spin != null else 0.2
			_draw_turbine_module(mx, mod_base, mod_top_elev, intake_elev,
					half_w - 0.3, along_mid, q_lps, primed, in_d_m, out_d_m, water_top)
			var c0 := _pv_to_screen_centered(mx, mod_base - 0.35, along_mid)
			var c1_elev := (module_m - 8.0) if is_nan(out_inv) else out_inv
			var c1 := _pv_to_screen_centered(a1 - 0.5, c1_elev, along_mid)
			ElevationCrossSection.draw_outflow_streaks(_preview, c0, c1, q_lps, primed, _flow_phase)
			if not is_nan(out_inv):
				var lbl := "↓ culvert → outlet %.1f m" % out_inv
				var lp := c0.lerp(c1, 0.5) + Vector2(8, 0)
				lp.y = clampf(lp.y, origin.y + 20, origin.y + size.y - 8)
				_preview.draw_string(ThemeDB.fallback_font, lp, lbl,
						HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.85, 0.65, 0.25, 0.95))
	elif not is_nan(out_inv):
		var c_lbl := _pv_to_screen_centered(a1 - 0.5, out_inv, along_mid)
		c_lbl.y = clampf(c_lbl.y, origin.y + 20, origin.y + size.y - 8)
		_preview.draw_string(ThemeDB.fallback_font, c_lbl + Vector2(8, 0),
				"↓ culvert → outlet %.1f m" % out_inv,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.85, 0.65, 0.25, 0.95))

	var caption := str(pond.get("label", "Pond"))
	if caption.is_empty():
		caption = "Bind a pond for a site CT slice"
	else:
		var st: String
		if _kind_has_penstock():
			st = "FLOWING · %.1f L/s" % q_lps if flowing else "dry"
		else:
			st = "PRIMED · %.1f L/s" % q_lps if flowing else "broken (dry)"
		caption = "%s · %s" % [caption, st]
	_preview.draw_string(ThemeDB.fallback_font, origin + Vector2(8, 16), caption,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, C_MUTED)


## Interpolated baked-DEM ground elevation at a pond-relative along distance.
func _dem_elev_at(along_m: float) -> float:
	var n := mini(_dem_along.size(), _dem_elev.size())
	if n == 0:
		return NAN
	if along_m <= _dem_along[0]:
		return _dem_elev[0]
	if along_m >= _dem_along[n - 1]:
		return _dem_elev[n - 1]
	for i in range(1, n):
		if _dem_along[i] >= along_m:
			var t := (along_m - _dem_along[i - 1]) / maxf(_dem_along[i] - _dem_along[i - 1], 1e-6)
			return lerpf(_dem_elev[i - 1], _dem_elev[i], t)
	return _dem_elev[n - 1]


const _C_CASING_OUTER := Color(0.60, 0.65, 0.72, 0.95)
const _C_CASING_INNER := Color(0.13, 0.16, 0.20, 1.0)
const _C_HOUSING_FILL := Color(0.88, 0.90, 0.93, 0.95)
const _C_MOTOR := Color(0.20, 0.22, 0.26, 0.98)
const _C_PROP := Color(0.10, 0.11, 0.13, 0.98)
const _C_PIPE_WALL := Color(0.62, 0.67, 0.74, 0.98)
const _C_PIPE_WALL_DK := Color(0.10, 0.12, 0.15, 1.0)
const _C_WATER_FILL := Color(0.26, 0.55, 0.86, 0.62)


## Screen-space pixel diameter for a pipe of `dia_m` metres at the current zoom
## (min 3 px so a thin penstock is still legible), averaging the anisotropic
## along/elevation scales.
func _dia_px(dia_m: float) -> float:
	return maxf(dia_m * (_pv_sx + _pv_sy) * 0.5 * _view_zoom, 3.0)


## Falling runoff streaks onto the uphill bank of the pond, animated downward with
## `_flow_phase`, plus an "≈X L/s" label — the visible "watershed rain fills the
## pond" cue. `bank_ground`/`level_m` bound the fall; `uphill_left` picks the side.
func _draw_runoff_inflow(bank_along: float, bank_ground: float, level_m: float,
		along_mid: float, q_lps: float, uphill_left: bool, origin: Vector2,
		size: Vector2) -> void:
	var top_elev := bank_ground + 0.8
	var land_elev := level_m if not is_nan(level_m) else bank_ground
	# Spread the streaks across a short span of bank, tilted toward the pond centre.
	var sign_in := 1.0 if uphill_left else -1.0
	var n_streak := 5
	var col := Color(0.55, 0.82, 1.0, 0.8)
	for i in n_streak:
		var off := (float(i) / float(maxi(n_streak - 1, 1)) - 0.5) * 0.7
		var top := _pv_to_screen_centered(bank_along + off, top_elev, along_mid)
		var bottom := _pv_to_screen_centered(bank_along + off + sign_in * 0.35, land_elev, along_mid)
		# Animate a bright dash falling along each streak.
		var ph := fmod(_flow_phase * 1.6 + float(i) * 0.27, 1.0)
		var d0 := top.lerp(bottom, ph)
		var d1 := top.lerp(bottom, minf(ph + 0.16, 1.0))
		_preview.draw_line(top, bottom, Color(col.r, col.g, col.b, 0.28), 1.5, true)
		_preview.draw_line(d0, d1, col, 2.5, true)
	# Splash tick + label at the waterline.
	var land := _pv_to_screen_centered(bank_along + sign_in * 0.35, land_elev, along_mid)
	_preview.draw_arc(land, 4.0, PI, TAU, 8, col, 1.5, true)
	var lbl := "≈ %.2f L/s in" % q_lps if q_lps < 10.0 else "≈ %.0f L/s in" % q_lps
	var lp := _pv_to_screen_centered(bank_along, top_elev, along_mid) + Vector2(
			6.0 if uphill_left else -70.0, -4.0)
	lp.x = clampf(lp.x, origin.x + 4, origin.x + size.x - 74)
	lp.y = clampf(lp.y, origin.y + 14, origin.y + size.y - 6)
	_preview.draw_string(ThemeDB.fallback_font, lp, lbl,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.6, 0.85, 1.0, 0.95))


## Draw a straight pipe run (centreline a→b) as two parallel walls at the scaled
## bore, filling the interior with water when `water` (flowing) — else empty.
func _draw_pipe_run(a: Vector2, b: Vector2, dia_m: float, water: bool) -> void:
	var dir := b - a
	var l := dir.length()
	if l < 0.5:
		return
	dir /= l
	var nrm := Vector2(-dir.y, dir.x) * (_dia_px(dia_m) * 0.5)
	var w0 := a + nrm
	var w1 := b + nrm
	var w2 := b - nrm
	var w3 := a - nrm
	if water:
		_preview.draw_colored_polygon(PackedVector2Array([w0, w1, w2, w3]), _C_WATER_FILL)
	_preview.draw_line(w0, w1, _C_PIPE_WALL_DK, 2.0, true)
	_preview.draw_line(w3, w2, _C_PIPE_WALL_DK, 2.0, true)


## Turbine module cross-section matching the player's SketchUp reference: a
## side-intake elbow enters LOW from the pond (no visible fitting) into a
## vertical housing; a spinning prop + shaft rise to a motor cap poking above
## the crown; the housing exits straight out the bottom into the culvert. Pipe
## runs are drawn at their true scaled bore with water shown inside when primed.
## `mx`/`base_elev`/`top_elev` are the housing's along-position + elevation span;
## `intake_elev` is the pond-side entry height (near the break level);
## `in_d_m`/`out_d_m` are the intake/outlet bores (m); `water_top` the pond level.
func _draw_turbine_module(mx: float, base_elev: float, top_elev: float,
		intake_elev: float, intake_from_along: float, along_mid: float,
		q_lps: float, primed: bool, in_d_m: float, out_d_m: float,
		water_top: float) -> void:
	var flowing := primed and q_lps > 0.01
	var half := maxf(_dia_px(out_d_m) * 0.5 / maxf(_pv_sx * _view_zoom, 1e-3), 0.32)
	var top_l := _pv_to_screen_centered(mx - half, top_elev, along_mid)
	var top_r := _pv_to_screen_centered(mx + half, top_elev, along_mid)
	var bot_l := _pv_to_screen_centered(mx - half, base_elev, along_mid)
	var bot_r := _pv_to_screen_centered(mx + half, base_elev, along_mid)

	# Intake: horizontal pipe run from the pond side into the housing wall, low,
	# drawn at the scaled intake bore with water inside when flowing.
	var in_a := _pv_to_screen_centered(intake_from_along, intake_elev, along_mid)
	var in_b := _pv_to_screen_centered(mx - half * 0.4, intake_elev, along_mid)
	_draw_pipe_run(in_a, in_b, in_d_m, flowing)
	if flowing:
		_draw_flow_dashes(PackedVector2Array([in_a, in_b]), q_lps)

	# Housing body (vertical pipe): light casing fill + dark outline, rounded cap.
	var body := PackedVector2Array([top_l, top_r, bot_r, bot_l])
	_preview.draw_colored_polygon(body, _C_HOUSING_FILL)
	# Water column inside the housing: fills from the base up to the pond level
	# (clamped to the housing) when primed; empties toward the base when broken.
	var col_top_elev := clampf(water_top if primed else base_elev, base_elev, top_elev)
	if col_top_elev > base_elev + 0.02:
		var wl := _pv_to_screen_centered(mx - half, col_top_elev, along_mid)
		var wr := _pv_to_screen_centered(mx + half, col_top_elev, along_mid)
		_preview.draw_colored_polygon(PackedVector2Array([wl, wr, bot_r, bot_l]), _C_WATER_FILL)
	_preview.draw_polyline(PackedVector2Array([top_l, bot_l]), _C_CASING_INNER, 2.0, true)
	_preview.draw_polyline(PackedVector2Array([top_r, bot_r]), _C_CASING_INNER, 2.0, true)
	_preview.draw_line(bot_l, bot_r, _C_CASING_INNER, 2.0, true)
	var cap_r := (top_r - top_l).length() * 0.5
	var cap_c := (top_l + top_r) * 0.5
	_preview.draw_arc(cap_c, cap_r, PI, TAU, 16, _C_CASING_INNER, 2.0, true)

	# Motor cap: small dark housing straddling the top rim.
	var motor_h := maxf(cap_r * 1.1, 8.0)
	var motor_rect := Rect2(cap_c - Vector2(cap_r * 0.75, motor_h), Vector2(cap_r * 1.5, motor_h))
	_preview.draw_rect(motor_rect, _C_MOTOR, true)
	_preview.draw_rect(motor_rect, _C_CASING_INNER, false, 1.5)

	# Shaft: thin line from the motor cap down to the propeller position (upper
	# third of the housing, where the real hoverboard-motor rotor sits).
	var prop_elev := lerpf(base_elev, top_elev, 0.32)
	var prop_c := _pv_to_screen_centered(mx, prop_elev, along_mid)
	_preview.draw_line(cap_c, prop_c, _C_CASING_INNER, 2.0, true)

	# Propeller: spinning blades (2D edge-on silhouette) driven by _prop_angle.
	var blade_len := cap_r * 0.85
	var spin := _prop_angle
	for k in 3:
		var a := spin + float(k) * (TAU / 3.0)
		var tip := prop_c + Vector2(cos(a), sin(a) * 0.4) * blade_len
		_preview.draw_line(prop_c, tip, _C_PROP, 3.0, true)
	_preview.draw_circle(prop_c, 3.0, _C_PROP)

	# Outlet stub: short scaled-bore drop from the housing floor before the
	# culvert takes over, water inside when flowing.
	var stub_top := (bot_l + bot_r) * 0.5
	var stub_bot := _pv_to_screen_centered(mx, base_elev - 0.35, along_mid)
	_draw_pipe_run(stub_top, stub_bot, out_d_m, flowing)


## Penstock-turbine glyph (pelton/turgo/run-of-river): a pressure pipe leaving the
## pond intake and running down toward a powerhouse at the outlet elevation, with a
## nozzle jet driving a spinning runner wheel. The pipe is drawn at its true scaled
## bore with water inside when flowing; net head is labelled along the drop.
func _draw_penstock_glyph(mx: float, intake_elev: float, intake_from_along: float,
		out_inv: float, module_elev: float, a1: float, along_mid: float,
		pen_d_m: float, tail_d_m: float, q_lps: float, flowing: bool,
		origin: Vector2, size: Vector2) -> void:
	var ph_elev := (module_elev - 8.0) if is_nan(out_inv) else out_inv
	var intake := _pv_to_screen_centered(intake_from_along, intake_elev, along_mid)
	# Powerhouse sits toward the low/right edge of the frame; clamp on-screen.
	var ph := _pv_to_screen_centered(a1 - 0.7, ph_elev, along_mid)
	ph.y = clampf(ph.y, origin.y + size.y * 0.45, origin.y + size.y - 28.0)
	ph.x = clampf(ph.x, origin.x + 40.0, origin.x + size.x - 40.0)
	# Penstock: a two-segment run (short horizontal off the intake, then the drop)
	# so it reads as leaving the pond bank before diving to the powerhouse.
	var knee := Vector2(lerpf(intake.x, ph.x, 0.35), intake.y + (ph.y - intake.y) * 0.12)
	_draw_pipe_run(intake, knee, pen_d_m, flowing)
	_draw_pipe_run(knee, ph, pen_d_m, flowing)
	if flowing:
		_draw_flow_dashes(PackedVector2Array([intake, knee, ph]), q_lps)

	# Powerhouse box + spinning runner wheel + nozzle.
	var box_w := 34.0
	var box_h := 26.0
	var box := Rect2(ph - Vector2(box_w * 0.5, box_h * 0.55), Vector2(box_w, box_h))
	_preview.draw_rect(box, _C_HOUSING_FILL, true)
	_preview.draw_rect(box, _C_CASING_INNER, false, 1.5)
	var wheel_c := box.get_center()
	var wheel_r := box_h * 0.32
	_preview.draw_circle(wheel_c, wheel_r, Color(0.18, 0.20, 0.24, 1.0))
	_preview.draw_arc(wheel_c, wheel_r, 0.0, TAU, 24, _C_CASING_INNER, 1.5, true)
	for k in 6:
		var a := _prop_angle + float(k) * (TAU / 6.0)
		var tip := wheel_c + Vector2(cos(a), sin(a)) * wheel_r
		_preview.draw_line(wheel_c, tip, Color(0.55, 0.62, 0.72, 0.95), 2.0, true)
	# Nozzle jet striking the wheel from the penstock side.
	if flowing:
		var noz := wheel_c - Vector2(wheel_r + 10.0, 0.0)
		_preview.draw_line(noz, wheel_c - Vector2(wheel_r, 0.0),
				Color(0.55, 0.9, 1.0, 0.92), 3.0, true)

	# Tailrace stub out the bottom of the powerhouse.
	var tail_bot := Vector2(wheel_c.x, box.position.y + box.size.y + 10.0)
	tail_bot.y = minf(tail_bot.y, origin.y + size.y - 6.0)
	_draw_pipe_run(Vector2(wheel_c.x, box.position.y + box.size.y), tail_bot, tail_d_m, flowing)

	# Net-head label along the drop.
	var h_net := float(_last_r.get("net_head_m", NAN))
	if is_nan(h_net):
		h_net = intake_elev - ph_elev
	var lp := knee.lerp(ph, 0.5) + Vector2(8, 0)
	lp.y = clampf(lp.y, origin.y + 20, origin.y + size.y - 8)
	_preview.draw_string(ThemeDB.fallback_font, lp, "penstock · net %.1f m" % h_net,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.85, 0.65, 0.25, 0.95))


## Draw the siphon body as a casing polyline + (when primed) flow dashes that
## travel along its arc length from the pond intake over the crown to the outlet.
func _draw_siphon_pipe(pts: PackedVector2Array, q_lps: float, primed: bool) -> void:
	if pts.size() < 2:
		return
	_preview.draw_polyline(pts, Color(0.60, 0.65, 0.72, 0.95), 6.0, true)
	_preview.draw_polyline(pts, Color(0.13, 0.16, 0.20, 1.0), 2.5, true)
	if not primed or q_lps < 0.01:
		return
	_draw_flow_dashes(pts, q_lps)


## Animate bright flow dashes travelling along a polyline's arc length at a speed
## scaled by flow rate — the in-pipe motion cue shared by the siphon body, the
## turbine intake/outlet stubs, and the penstock run.
func _draw_flow_dashes(pts: PackedVector2Array, q_lps: float) -> void:
	if pts.size() < 2:
		return
	var seglen := PackedFloat32Array()
	var total := 0.0
	for i in range(1, pts.size()):
		var l := pts[i - 1].distance_to(pts[i])
		seglen.append(l)
		total += l
	if total < 1.0:
		return
	var speed := clampf(0.12 + q_lps * 0.008, 0.08, 0.5)   # arc-fraction / sec
	var n_dash := 9
	for d in n_dash:
		var base := fmod(_flow_phase * speed + float(d) / float(n_dash), 1.0)
		var p := _point_along_polyline(pts, seglen, total, base * total)
		var p2 := _point_along_polyline(pts, seglen, total, minf(base * total + total * 0.05, total))
		_preview.draw_line(p, p2, Color(0.55, 0.9, 1.0, 0.92), 3.0, true)


func _point_along_polyline(pts: PackedVector2Array, seglen: PackedFloat32Array,
		total: float, dist: float) -> Vector2:
	dist = clampf(dist, 0.0, total)
	var acc := 0.0
	for i in seglen.size():
		if acc + seglen[i] >= dist:
			var t := (dist - acc) / maxf(seglen[i], 1e-6)
			return pts[i].lerp(pts[i + 1], t)
		acc += seglen[i]
	return pts[pts.size() - 1]


func _pv_to_screen_centered(along_m: float, elev_m: float, along_mid: float) -> Vector2:
	if _pv_linked:
		# Pan/zoom already baked into along_mid / _pv_elev_mid (matches CT ortho).
		return Vector2(
			_pv_origin.x + _pv_size.x * 0.5 + (along_m - along_mid) * _pv_sx,
			_pv_origin.y + _pv_size.y * 0.5 - (elev_m - _pv_elev_mid) * _pv_sy)
	return Vector2(
		_pv_origin.x + _pv_size.x * 0.5 + (along_m - along_mid) * _pv_sx * _view_zoom + _view_pan.x,
		_pv_origin.y + _pv_size.y - (elev_m - _pv_y_min) * _pv_sy * _view_zoom + _view_pan.y)


func _pv_to_screen(along_m: float, elev_m: float) -> Vector2:
	return _pv_to_screen_centered(along_m, elev_m, 0.0)
