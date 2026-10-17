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
const _CHART_SCRIPT := preload("res://scenes/ui/hydro_power_chart.gd")
const C_WARN := Color(0.98, 0.75, 0.35, 1.0)
## Poly-pipe-size palette for the power-curve families (1″ → 2″).
const _CHART_SIZE_COLORS: Array = [
	Color(0.55, 0.75, 1.00), Color(0.45, 0.95, 0.75),
	Color(1.00, 0.78, 0.45), Color(0.95, 0.58, 0.85),
]

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
## Siphon geometry (SiphonTurbinePhysics): the dip tube's hang, how the pipe
## is primed, the runner bore. Prime / break are DERIVED from these now.
var _dip_len_spin: SpinBox
var _show_dip_check: CheckBox
var _runner_spin: SpinBox
var _prime_opt: OptionButton
## Where the draft exit and the crest handles were drawn (section px), for
## picking; INF when off-frame.
var _exit_px := Vector2.INF
var _crest_px := Vector2.INF
var _siphon_sens_sig := ""
## The along (m, pond-relative) at the section's centre this draw — the x
## inverse of _pv_to_screen_centered needs it (the y inverse has _pv_elev_mid).
var _pv_along_mid := 0.0
var _net_lbl: Label
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
## Nozzle-governed kinds (kind_meta.uses_nozzle_model — PowerSpout Pelton):
## nozzle count/Ø replace the design-flow knob.
var _nozzle_count_spin: SpinBox
var _nozzle_d_spin: SpinBox
var _nozzle_off_spin: SpinBox
## The rest of the nozzle placement (close-up only, persisted per machine).
var _nozzle_pose_spins: Array[SpinBox] = []
## The placement row's header / hint / reset, shown with the spins.
var _nozzle_pose_extras: Array[Control] = []
const NOZZLE_POSE_KEYS := {
	"nozzle_axial_mm": "axial_m", "nozzle_angle_deg": "angle_deg",
	"nozzle_tilt_in_deg": "tilt_in_deg", "nozzle_tilt_out_deg": "tilt_out_deg",
	"nozzle_standoff_mm": "standoff_m"}
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
## Phase E what-if surface: warnings row + power-curve chart (P vs head, one
## polyline per poly pipe size, operating point marked) + per-size stats.
var _warn_lbl: Label
var _chart: Control
var _chart_body: VBoxContainer
var _chart_stats_lbl: Label
## The stat deck under the section (scenes/ui/hydro_stat_deck.gd): the SAME
## operating point as the dock's Live readouts and the status strip, drawn as
## the causal chain flow → head → pressure → jet → speed → power.
const _DECK_SCRIPT := preload("res://scenes/ui/hydro_stat_deck.gd")
var _deck: Control
## "+1 m head → +12 W · …" — recomputed inside the estimate's signature gate.
var _sens_text := ""
## The routed pipe's pressure rating (psi), from the design checks; NAN = unknown.
var _last_rating_psi := NAN
var _chart_sig: String = ""
var _route_size_opt: OptionButton
var _route_sdr_opt: OptionButton
var _stock_spin: SpinBox
var _route_status_lbl: Label
var _source_lbl: Label
var _design_lbl: Label
var _design_summary := ""
var _close_spin: SpinBox
var _intake_lbl: Label
var _firm_lbl: Label
var _limited_lbl: Label
var _firm_text := ""
var _intake_text := ""
var _last_sim_specs: Dictionary = {}
## Penstock placement mode: a glowing gizmo sits on the turbine inlet and the
## player DRAGS it across the section to the uphill water source. The same
## commit the 3D drag uses (SystemGraphView.create_penstock_intake_at), so both
## surfaces produce one identical routed connection.
var _penstock_mode := false
var _penstock_dragging := false
## Ghost end while dragging: section along-metres + absolute elevation.
var _penstock_ghost_along := 0.0
var _penstock_ghost_elev := 0.0
var _penstock_ghost_site := Vector2.ZERO
var _penstock_ghost_valid := false
## Screen rect of the inlet gizmo, rebuilt every draw (hit target).
var _penstock_gizmo_screen := Vector2.INF
var _penstock_btn: Button
var _outlet_btn: Button
var _hint_lbl: Label
var _ws_status_lbl: Label
var _ws_season_lbl: Label
var _ws_preview_btn: Button
var _ws_designate_btn: Button
var _sim_inflow_btn: CheckButton
var _sim_inflow_spin: SpinBox
var _nav_hint_lbl: Label
var _status_lbl: Label
var _drive_hint_lbl: Label
## View tabs — the cross-section and the turbine close-up are peer views of the
## same machine, not a panel nested inside the dock.
const VIEW_SECTION := "section"
const VIEW_CLOSEUP := "closeup"
const _CLOSEUP_SCRIPT := preload("res://scenes/ui/hydro_turbine_closeup.gd")
var _lab_view := VIEW_SECTION
var _tab_section_btn: Button
var _tab_closeup_btn: Button
var _closeup: Control
## Load fraction for the close-up's speed model: 1.0 = matched (x_opt), 0.0 = open
## circuit (runaway at 2·x_opt). Driven by a slider, overridden by the real
## electrical load once the turbine's DC output is feeding something.
var _load_frac := 1.0
var _load_slider: HSlider
var _load_lbl: Label
var _load_row: HBoxContainer
## Harness-pinned operating point (see set_state_for_test); empty = use the live
## reach snapshot.
var _test_op: Dictionary = {}
## Nozzle Ø (mm) the supply-limited warning recommends; 0 = nothing to offer.
var _fit_nozzle_mm := 0.0
var _fit_nozzle_btn: Button
## Test-flow slider (mirrors _sim_inflow_spin). Linear over the band essentially
## every micro-hydro site lives in; the spin still reaches 2000 L/s and the
## slider's ceiling follows it up when it does.
const FLOW_SLIDER_MAX_LPS := 20.0
var _sim_inflow_slider: HSlider
var _side: VBoxContainer

var _prop_angle: float = 0.0
var _prop_omega: float = 0.0
var _display_level_m := NAN   # eased pond level for smooth drawing (physics untouched)
var _inflow_lps := 0.0        # smoothed pond inflow rate (catchment + test inflow)
var _inflow_target_lps := 0.0
var _inflow_sample_t := 0.0
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
## Pan in SECTION METRES (along-rel, elev), not pixels. It used to be pixels that
## _lab_view_metrics then divided by a zoom-dependent metres-per-pixel, so a wheel
## notch after a pan silently re-scaled the accumulated pan and the view slid.
var _view_pan_m := Vector2.ZERO
const LAB_ZOOM_MIN := 0.25
const LAB_ZOOM_MAX := 8.0
## Per-notch zoom step. 1.1 needs seven notches to double — that slowness is a
## large part of the Lab reading as sluggish. Ctrl+wheel keeps a fine step.
const LAB_ZOOM_STEP := 1.18
const LAB_ZOOM_STEP_FINE := 1.05
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
## Cached _slice_frame result (see that function — it is called from the draw,
## from _lab_view_metrics, and from every pan/zoom event).
var _slice_cache: Dictionary = {}
var _slice_sig: String = ""
## Signature gates for the 6 Hz refreshes that are NOT live telemetry: the annual
## estimate + chart stats, and the routed-penstock scan. Live readouts (rpm, flow,
## head, state) stay ungated — those are the numbers that must feel live.
var _est_sig: String = ""
var _stats_sig: String = ""
var _route_sig: String = ""
## Cached id of the routed contour penstock feeding this turbine (re-resolved
## whenever _route_sig moves) — resolving it walked every connection per draw.
var _routed_conn_id: String = ""


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
		# Re-entry with no explicit target — e.g. the DEFERRED visibility
		# reapply that fires right after open_siphon_lab(id) when the graph was
		# opened programmatically (prop edit UI sets `visible = true`, which
		# queues _reapply_current_graph_view_mode with no opts). Falling to
		# "first siphon on the graph" here is how selecting a PowerSpout used
		# to land you in the Lab with the ORIGINAL siphon turbine active: keep
		# the current turbine whenever it is still valid.
		if _is_lab_turbine(_item_id):
			item_id = _item_id
		else:
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
	# Always open on the cross-section: it answers "is the water getting there",
	# which is what a player has just come to check.
	_set_lab_view(VIEW_SECTION)
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
	# Free the close-up's particles and stop its viewport before hiding; the
	# section CT must be handed its slot back or the next Lab open shows nothing.
	if _closeup != null and _closeup.has_method("set_active"):
		_closeup.call("set_active", false)
	if _graph_view != null and _graph_view.has_method("set_lab_section_ct_visible"):
		_graph_view.call("set_lab_section_ct_visible", true)
	_lab_view = VIEW_SECTION
	if _preview_col != null:
		_preview_col.visible = true
	if _preview != null:
		_preview.visible = true
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
	# Clamp to the SAME floor the CT camera clamps to. Doing it here — in the one
	# function that feeds both the 2D overlay projection and the 3D frame push —
	# is what makes the clamp invisible: the value never reaches the camera below
	# its limit, so the two can no longer drift apart at deep zoom.
	if ortho_h < GraphSiteLayout.LAB_MIN_ORTHO_H_M:
		ortho_h = GraphSiteLayout.LAB_MIN_ORTHO_H_M
		ortho_w = ortho_h * aspect
	# Overlay DEM is pond-relative (pond at along=0). CT camera uses absolute
	# site along = relative + pond·heading. Look-at = turbine.
	var heading := float(frame.get("heading", 0.0))
	var pond_site: Vector2 = frame.get("pond_site", Vector2.ZERO) as Vector2
	var pond_along := pond_site.dot(Vector2(cos(heading), sin(heading)))
	# Pan is already in metres — no zoom-dependent conversion, which is what stops
	# the view sliding when you zoom after panning.
	var along_mid_rel := module_along - _view_pan_m.x
	var elev_mid := module_m + _view_pan_m.y
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
	# Return to whatever mode the player opened the Lab from (the graph view
	# recorded it in open_siphon_lab); hard-coding Elevation dumped a player who
	# came from Site Plan somewhere they never asked to be.
	if _graph_view != null and _graph_view.has_method("close_hydro_lab"):
		_graph_view.call("close_hydro_lab")
	elif _graph_view != null and _graph_view.has_method("_apply_graph_view_mode"):
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
	IconButton.as_close(close_btn, "Back to Elevation")
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

	# View tabs. The close-up is a genuinely different way of looking at the same
	# machine — the cross-section answers "is the water getting there", the
	# close-up answers "what is the runner actually doing" — so it is a peer view,
	# not a panel buried in the dock.
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 6)
	_preview_col.add_child(tabs)
	_tab_section_btn = _view_tab(tabs, "Cross-section",
			"The reach: source, penstock, turbine and water line in elevation.",
			VIEW_SECTION)
	_tab_closeup_btn = _view_tab(tabs, "Turbine close-up",
			"The runner side-on with the housing ghosted: jet, buckets, tailwater.",
			VIEW_CLOSEUP)
	_tab_section_btn.set_pressed_no_signal(true)

	_preview_stack = Control.new()
	_preview_stack.custom_minimum_size = Vector2(520, 280)
	_preview_stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preview_stack.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_preview_stack.mouse_filter = Control.MOUSE_FILTER_STOP
	# The section's overlay (penstock, pins) is drawn in metres and runs past
	# the preview's edge at depth — it used to draw over the Lab's own title.
	_preview_stack.clip_contents = true
	_preview_stack.gui_input.connect(_on_preview_stack_input)
	_preview_col.add_child(_preview_stack)

	_preview = Control.new()
	_preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_preview.draw.connect(_draw_preview)
	_preview_stack.add_child(_preview)

	# Close-up studio, over the section. Built lazily on first activation, so a Lab
	# session that never opens this tab costs nothing.
	_closeup = Control.new()
	_closeup.name = "TurbineCloseup"
	_closeup.set_script(_CLOSEUP_SCRIPT)
	_closeup.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_preview_stack.add_child(_closeup)

	# The stat deck: the headline readout. Big tiles in causal order with a bar
	# against each quantity's limit, an insight line naming what caps the
	# output, and a sensitivity line with real deltas — so the relationship
	# between flow, nozzle, head, pressure, speed and power is READ, not
	# inferred from six 12 px rows in a scrolling dock.
	_deck = Control.new()
	_deck.name = "StatDeck"
	_deck.set_script(_DECK_SCRIPT)
	_deck.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preview_col.add_child(_deck)

	# Live status strip under the section. The same facts used to be a string
	# PAINTED into the cross-section, where it fought the terrain for contrast and
	# scrolled off under pan/zoom.
	var status_row := HBoxContainer.new()
	status_row.add_theme_constant_override("separation", 10)
	_preview_col.add_child(status_row)
	_status_lbl = Label.new()
	_status_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_lbl.add_theme_font_size_override("font_size", 11)
	_status_lbl.add_theme_color_override("font_color", C_MUTED)
	_status_lbl.text = "—"
	status_row.add_child(_status_lbl)
	# Load control — only meaningful in the close-up, where you watch the wheel
	# run away as the load is shed and the runner efficiency collapse with it.
	_load_row = HBoxContainer.new()
	_load_row.add_theme_constant_override("separation", 6)
	_load_row.visible = false
	status_row.add_child(_load_row)
	var load_key := Label.new()
	load_key.text = "Load"
	load_key.add_theme_font_size_override("font_size", 11)
	load_key.add_theme_color_override("font_color", C_MUTED)
	_load_row.add_child(load_key)
	_load_slider = HSlider.new()
	_load_slider.min_value = 0.0
	_load_slider.max_value = 1.0
	_load_slider.step = 0.01
	_load_slider.value = 1.0
	_load_slider.custom_minimum_size = Vector2(110, 0)
	_load_slider.tooltip_text = ("Electrical load on the generator. 100% is the "
			+ "matched load (bucket speed u = 0.46 x jet) — what a real dump-load "
			+ "or MPPT controller holds, and what the graph node reports. Shedding "
			+ "it lets the runner accelerate toward runaway, where it spins "
			+ "fastest and makes no power at all. A what-if: this drives the "
			+ "close-up, not the graph's output.")
	_load_slider.value_changed.connect(func(v: float) -> void:
		_load_frac = clampf(v, 0.0, 1.0)
		if _load_lbl != null:
			_load_lbl.text = "%d%%" % int(round(_load_frac * 100.0)))
	_load_row.add_child(_load_slider)
	_load_lbl = Label.new()
	_load_lbl.text = "100%"
	_load_lbl.add_theme_font_size_override("font_size", 11)
	_load_lbl.add_theme_color_override("font_color", C_MUTED)
	_load_row.add_child(_load_lbl)

	var frame_btn := Button.new()
	frame_btn.text = "Frame turbine (F)"
	frame_btn.tooltip_text = "Reset zoom/pan back onto the turbine."
	frame_btn.pressed.connect(_on_frame_turbine)
	status_row.add_child(frame_btn)
	var runbtn := Button.new()
	runbtn.text = "Whole run (Home)"
	runbtn.tooltip_text = "Zoom out until the intake and the turbine are both in frame."
	runbtn.pressed.connect(_on_frame_whole_run)
	status_row.add_child(runbtn)

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
	var snap_btn := Button.new()
	snap_btn.text = "Snap turbine to terrain"
	snap_btn.tooltip_text = ("Set the turbine elevation to the ground height at "
			+ "its site position (you can also drag the 3D module on the cut).")
	snap_btn.pressed.connect(_on_snap_module_to_terrain)
	_side.add_child(snap_btn)
	_outlet_inv_spin = _spin(_side, "Draft exit (m)", -500.0, 5000.0, 0.01,
			func(v: float) -> void:
		_commit_float("outlet_invert_m", v)
		_push_outlet_invert(v))
	_outlet_inv_spin.tooltip_text = ("Where the draft pipe (culvert) daylights. Lower = more head, "
			+ "until the runner's outlet reaches vapour pressure and the extra drop is wasted. "
			+ "Moves the outlet node and the culvert's far end with it.")
	_intake_d_spin = _spin(_side, "Intake diameter (mm)", 25.0, 600.0, 1.0,
			func(v: float) -> void: _commit_float("intake_diameter_mm", v))
	_outlet_d_spin = _spin(_side, "Outlet diameter (mm)", 25.0, 800.0, 1.0,
			func(v: float) -> void: _commit_float("outlet_diameter_mm", v))

	# Siphon-only: prime/break levels + orifice barrel. Hidden for penstock kinds
	# (the spins stay populated so _refresh_physics still reads siphon_break_m as
	# the intake invert).
	_siphon_group = VBoxContainer.new()
	_side.add_child(_siphon_group)
	_section(_siphon_group, "Siphon")
	var levels_hint := Label.new()
	levels_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	levels_hint.add_theme_color_override("font_color", C_MUTED)
	levels_hint.add_theme_font_size_override("font_size", 11)
	levels_hint.text = ("A dip tube hangs from the turbine into the pond; the draft pipe "
			+ "runs from the runner down the hill. The pond primes the siphon by rising "
			+ "to the crest (or a vacuum pump does), and it breaks when the surface "
			+ "reaches the dip tube's mouth. On the cut: drag the mouth, the crest or "
			+ "the draft exit.")
	_siphon_group.add_child(levels_hint)
	_dip_len_spin = _spin(_siphon_group, "Dip tube length (m)", 0.1, 30.0, 0.05,
			func(v: float) -> void: _commit_float("dip_tube_length_m", v))
	_dip_len_spin.tooltip_text = ("How far the 6″ dip tube hangs below the turbine. Its mouth is "
			+ "the BREAK level — a longer tube siphons the pond lower before it sucks air.")
	_show_dip_check = CheckBox.new()
	_show_dip_check.text = "Show dip tube in the world"
	_show_dip_check.focus_mode = Control.FOCUS_NONE
	_show_dip_check.add_theme_font_size_override("font_size", 12)
	_show_dip_check.tooltip_text = ("Draw the dip tube on the placed turbine in 3D: one vertical length "
			+ "of 6″ PVC straight down from the machine's intake fitting. Off by default — the real "
			+ "tube is under water. The cut and the close-up always draw it.")
	_show_dip_check.toggled.connect(func(on: bool) -> void:
		if _syncing:
			return
		_commit_bool("show_dip_tube", on))
	_siphon_group.add_child(_show_dip_check)
	var prime_row := HBoxContainer.new()
	prime_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_siphon_group.add_child(prime_row)
	var prime_lbl := Label.new()
	prime_lbl.text = "Priming"
	prime_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	prime_lbl.add_theme_color_override("font_color", C_TEXT)
	prime_lbl.add_theme_font_size_override("font_size", 12)
	prime_row.add_child(prime_lbl)
	_prime_opt = OptionButton.new()
	_prime_opt.focus_mode = Control.FOCUS_NONE
	_prime_opt.add_item("Overflow at the crest")
	_prime_opt.set_item_metadata(0, "overflow")
	_prime_opt.add_item("Vacuum pump")
	_prime_opt.set_item_metadata(1, "pump")
	_prime_opt.tooltip_text = ("Overflow: the pond has to rise to the crest (the turbine) and "
			+ "spill into the draft pipe before the siphon runs. Vacuum pump: the pipe is "
			+ "pumped full, so it runs as soon as the dip tube's mouth is under water.")
	_prime_opt.item_selected.connect(func(i: int) -> void:
		if _syncing:
			return
		_commit_string("siphon_prime_mode", str(_prime_opt.get_item_metadata(i))))
	prime_row.add_child(_prime_opt)
	_runner_spin = _spin(_siphon_group, "Runner Ø (mm, 0 = dip tube)", 0.0, 600.0, 1.0,
			func(v: float) -> void: _commit_float("runner_diameter_mm", v))
	_runner_spin.tooltip_text = "The propeller runner's bore. Sets how much water passes at a given turbine head (Q = 0.7·A·√(2g·h))."
	_barrel_spin = _spin(_siphon_group, "Draft pipe length (m)", 1.0, 500.0, 0.1,
			func(v: float) -> void: _commit_float("barrel_length_m", v))
	# Derived levels — shown, not typed: the crest and the dip mouth set them.
	_start_spin = _spin(_siphon_group, "Primes at (m)", -500.0, 5000.0, 0.01,
			func(v: float) -> void: _commit_float("siphon_start_m", v))
	_start_spin.editable = false
	_start_spin.tooltip_text = "Where the pond surface must reach for the siphon to start — the crest (overflow) or just over the dip mouth (pump)."
	_break_spin = _spin(_siphon_group, "Breaks at (m)", -500.0, 5000.0, 0.01,
			func(v: float) -> void: _commit_float("siphon_break_m", v))
	_break_spin.editable = false
	_break_spin.tooltip_text = "The dip tube's mouth: when the surface falls here the siphon sucks air and stops."
	# The draft exit: move it by hand (a what-if on the exit height) or
	# re-trace it further down the hill (the real move).
	var exit_row := HBoxContainer.new()
	exit_row.add_theme_constant_override("separation", 6)
	_siphon_group.add_child(exit_row)
	var trace_btn := Button.new()
	trace_btn.text = "Trace exit 3 m lower"
	trace_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	trace_btn.tooltip_text = "Walk the draft pipe further down the hill (steepest descent over the real terrain, never into the pond) until it has 3 m more drop."
	trace_btn.pressed.connect(func() -> void: _on_retrace_exit(3.0))
	exit_row.add_child(trace_btn)
	var retrace_btn := Button.new()
	retrace_btn.text = "Re-trace"
	retrace_btn.tooltip_text = "Route the draft pipe downhill again from the turbine (after sculpting, or to undo a hand-set exit)."
	retrace_btn.pressed.connect(func() -> void: _on_retrace_exit(0.0))
	exit_row.add_child(retrace_btn)
	# Manning n is no longer a physics input (a full siphon is a pressure
	# pipe); the spin stays for old saves but is hidden.
	_manning_spin = _spin(_siphon_group, "Manning n", 0.008, 0.05, 0.001,
			func(v: float) -> void: _commit_float("manning_n", v))
	(_manning_spin.get_parent() as Control).visible = false

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
	# Shown in µm (HDPE is 1.5 µm — "0.0015 mm" read as a raw number); the
	# spec stays in mm.
	_roughness_spin = _spin(_penstock_group, "Roughness ε (µm)", 0.5, 1000.0, 0.5,
			func(v: float) -> void: _commit_float("pipe_roughness_mm", v / 1000.0))
	_design_flow_spin = _spin(_penstock_group, "Design flow (L/s)", 0.1, 5000.0, 0.1,
			func(v: float) -> void: _commit_float("design_flow_lps", v))
	# Nozzle-governed kinds (PowerSpout Pelton): flow is jet velocity × nozzle
	# area at the head — these replace the design-flow knob when visible.
	_nozzle_count_spin = _spin(_penstock_group, "Nozzles", 1.0, 2.0, 1.0,
			func(v: float) -> void: _commit_float("nozzle_count", v))
	_nozzle_d_spin = _spin(_penstock_group, "Nozzle Ø (mm)", 3.0, 25.0, 0.5,
			func(v: float) -> void: _commit_float("nozzle_diameter_mm", v))
	# Visual only — it moves where the jet is DRAWN, never the physics (the jet
	# strikes the pitch circle wherever it enters, and the head/flow do not care
	# which chord it takes). Stored on specs so it persists per machine.
	_nozzle_pose_extras.clear()
	var np_hdr := SectionHeader.make("Nozzle placement")
	_penstock_group.add_child(np_hdr)
	_nozzle_pose_extras.append(np_hdr)
	var np_hint := Label.new()
	np_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	np_hint.add_theme_color_override("font_color", C_MUTED)
	np_hint.add_theme_font_size_override("font_size", 11)
	np_hint.text = ("Where the jet comes from and lands on the cups — the close-up's "
			+ "Jet's eye view shows it. Picture only: the head and flow do not change.")
	_penstock_group.add_child(np_hint)
	_nozzle_pose_extras.append(np_hint)
	_nozzle_off_spin = _spin(_penstock_group, "Jet aim offset (mm)",
			-300.0, 300.0, 1.0, func(v: float) -> void:
		_commit_float("nozzle_offset_mm", v)
		_push_nozzle_pose())
	_nozzle_off_spin.tooltip_text = ("Slide the jet line across the wheel, toward or away from "
			+ "the shaft (up/down on a horizontal-shaft machine). 0 = where the machine's "
			+ "own inlet puts it; the jet should meet the cups at the pitch circle.")
	# The rest of the nozzle placement: along the shaft (the splitter vs one
	# side of the bucket — the jet's-eye view shows which), where on the rim
	# the nozzle sits, two tilts off tangential, and the standoff. Visual
	# only, like the aim offset: the physics does not care which chord the
	# jet takes, the picture does.
	_nozzle_pose_spins.clear()
	for spec: Array in [
			["Jet axial offset (mm)", "nozzle_axial_mm", -60.0, 60.0, 0.5,
				"Shift the jet along the shaft. 0 = as the machine is modelled; the splitter is where the water divides evenly between the two halves of the bucket."],
			["Nozzle position (°)", "nozzle_angle_deg", -180.0, 180.0, 1.0,
				"Where on the rim the nozzle sits, turned about the shaft. The jet stays tangential."],
			["Jet tilt, in plane (°)", "nozzle_tilt_in_deg", -30.0, 30.0, 0.5,
				"Tilt the jet within the wheel's plane: toward (+) or away from the shaft."],
			["Jet tilt, out of plane (°)", "nozzle_tilt_out_deg", -30.0, 30.0, 0.5,
				"Tilt the jet along the shaft, so it crosses the splitter at an angle."],
			["Nozzle standoff (mm)", "nozzle_standoff_mm", -40.0, 200.0, 1.0,
				"Move the nozzle mouth back from the cups along the jet (a longer jet spreads and slows a little in air)."]]:
		var key := str(spec[1])
		var sb := _spin(_penstock_group, str(spec[0]), float(spec[2]), float(spec[3]), float(spec[4]),
				func(v: float) -> void:
			_commit_float(key, v)
			_push_nozzle_pose())
		sb.tooltip_text = str(spec[5])
		sb.set_meta("spec_key", key)
		_nozzle_pose_spins.append(sb)
	var np_reset := Button.new()
	np_reset.text = "Reset placement"
	np_reset.tooltip_text = "Back to the nozzle as the machine is modelled."
	np_reset.focus_mode = Control.FOCUS_NONE
	np_reset.size_flags_horizontal = Control.SIZE_SHRINK_END
	UITheme.style_button(np_reset)
	np_reset.add_theme_font_size_override("font_size", 11)
	np_reset.pressed.connect(_on_reset_nozzle_placement)
	_penstock_group.add_child(np_reset)
	_nozzle_pose_extras.append(np_reset)
	_turb_eff_spin = _spin(_penstock_group, "Turbine η (0=auto)", 0.0, 0.95, 0.01,
			func(v: float) -> void: _commit_float("turbine_efficiency", v))
	# How fast the flow is shut: the spear valve is wound by hand over tens of
	# seconds; a ball valve slams in under a second and sees the full
	# Joukowsky rise. Drives the surge design check.
	_close_spin = _spin(_penstock_group, "Valve closure (s)", 0.2, 120.0, 0.5,
			func(v: float) -> void: _commit_float("valve_close_s", v))
	_close_spin.value = 10.0
	_close_spin.tooltip_text = ("Seconds to shut the flow at the turbine. A hand-wound spear valve: 10–30 s. "
			+ "A ball valve: well under a second (never use one as the shut-off). "
			+ "Below 2L/a the pipe sees the full instant-stop surge.")

	# Penstock route: restyle the pond→turbine wire as a contour-routed poly
	# penstock. ONE route, two surfaces — this is the same connection the 3D
	# conduit controller edits, so the measured ground-following run (length,
	# drop, styled Ø) is what drives HydroReach from then on.
	_section(_penstock_group, "Water source & penstock")
	# What feeds the turbine now (pond / stream / spring / nothing).
	_source_lbl = Label.new()
	_source_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_source_lbl.add_theme_color_override("font_color", C_TEXT)
	_source_lbl.add_theme_font_size_override("font_size", 12)
	_source_lbl.text = ""
	_penstock_group.add_child(_source_lbl)
	var route_hint := Label.new()
	route_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	route_hint.add_theme_color_override("font_color", C_MUTED)
	route_hint.add_theme_font_size_override("font_size", 11)
	route_hint.text = ("A pond on the graph, a stream, or bare ground (a spring) can feed the "
			+ "turbine. Drag the intake, auto-route, or route from the bound pond — the "
			+ "drop point decides which; the poly run follows the ground and its measured "
			+ "run + drop replace the typed length / head above.")
	_penstock_group.add_child(route_hint)
	var route_row := HBoxContainer.new()
	route_row.add_theme_constant_override("separation", 6)
	_penstock_group.add_child(route_row)
	_route_size_opt = OptionButton.new()
	_route_size_opt.focus_mode = Control.FOCUS_NONE
	for sz: Variant in ConduitKinds.pipe_kit_sizes_in("poly_penstock"):
		_route_size_opt.add_item(PipeKit.size_label(float(sz)))
		_route_size_opt.set_item_metadata(_route_size_opt.item_count - 1, float(sz))
		if is_equal_approx(float(sz), 1.5):
			_route_size_opt.select(_route_size_opt.item_count - 1)
	_route_size_opt.item_selected.connect(func(_i: int) -> void: _apply_route_style())
	route_row.add_child(_route_size_opt)
	# The pipe you actually have: its dimension ratio sets the bore, the
	# pressure rating and the cold-bend radius (PPI tables, ConduitKinds).
	_route_sdr_opt = OptionButton.new()
	_route_sdr_opt.focus_mode = Control.FOCUS_NONE
	_route_sdr_opt.tooltip_text = ("Dimension ratio (OD / wall) printed on the coil. SDR 9 = 250 psi, "
		+ "SDR 11 = 200 psi, SDR 11.5 = 190 psi, SDR 13.5 = 160 psi (PE4710). A thinner wall "
		+ "gives a bigger bore but a lower rating and a wider minimum bend.")
	for sdr: Variant in ConduitKinds.PENSTOCK_SDR_OPTIONS:
		_route_sdr_opt.add_item("SDR %s" % ("%.1f" % float(sdr)).trim_suffix(".0"))
		_route_sdr_opt.set_item_metadata(_route_sdr_opt.item_count - 1, float(sdr))
		if is_equal_approx(float(sdr), 9.0):
			_route_sdr_opt.select(_route_sdr_opt.item_count - 1)
	_route_sdr_opt.item_selected.connect(func(_i: int) -> void: _apply_route_style())
	route_row.add_child(_route_sdr_opt)
	_penstock_btn = Button.new()
	_penstock_btn.text = "Route penstock…"
	_penstock_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_penstock_btn.tooltip_text = ("Drag the glowing gizmo on the turbine inlet "
			+ "up the slope and release: on a pond → from that pond, within 8 m of a "
			+ "stream → that stream is tapped, on bare ground → a spring intake. The "
			+ "same drag works in first person off the inlet port.")
	_penstock_btn.pressed.connect(_on_toggle_penstock_mode)
	route_row.add_child(_penstock_btn)
	var route_btn := Button.new()
	route_btn.text = "From pond"
	route_btn.tooltip_text = ("Restyle the existing pond→turbine wire as Poly "
			+ "Penstock (ground-contour route; edit it later with the 3D wire tools)")
	route_btn.pressed.connect(_on_route_penstock)
	route_row.add_child(route_btn)
	# One-click alternative to dragging: scan the terrain around the turbine
	# and tap the best genuinely-higher ground — navigating the section uphill
	# by hand is fiddly, and most sites have one obvious answer anyway.
	var uphill_btn := Button.new()
	uphill_btn.text = "Auto-route uphill"
	uphill_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	uphill_btn.tooltip_text = ("Tap the highest stream vertex within 150 m that stands "
			+ "above the turbine (a creek is where the water is); with no stream in "
			+ "reach, the highest bare ground within 120 m becomes a spring intake.")
	uphill_btn.pressed.connect(_on_auto_route_uphill)
	_penstock_group.add_child(uphill_btn)
	# Pipe on hand: the one number every real install starts from.
	var stock_row := HBoxContainer.new()
	stock_row.add_theme_constant_override("separation", 6)
	_penstock_group.add_child(stock_row)
	var stock_lbl := Label.new()
	stock_lbl.text = "Pipe on hand (ft)"
	stock_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stock_lbl.add_theme_color_override("font_color", C_MUTED)
	stock_lbl.add_theme_font_size_override("font_size", 12)
	stock_row.add_child(stock_lbl)
	_stock_spin = SpinBox.new()
	_stock_spin.min_value = 0.0
	_stock_spin.max_value = 20000.0
	_stock_spin.step = 1.0
	_stock_spin.value = 0.0
	_stock_spin.custom_minimum_size.x = 96.0
	_stock_spin.tooltip_text = "Length of this coil you own, in feet (0 = not tracked). The design check compares the routed run against it."
	_stock_spin.value_changed.connect(func(_v: float) -> void: _apply_route_style())
	stock_row.add_child(_stock_spin)
	_route_status_lbl = Label.new()
	_route_status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_route_status_lbl.add_theme_color_override("font_color", C_MUTED)
	_route_status_lbl.add_theme_font_size_override("font_size", 11)
	_route_status_lbl.text = ""
	_penstock_group.add_child(_route_status_lbl)
	var goto_btn := Button.new()
	goto_btn.text = "Go to turbine in 3D"
	goto_btn.tooltip_text = ("Close the Lab and stand at the turbine, with the "
			+ "penstock lit — grab a mid-pin there to add bends.")
	goto_btn.pressed.connect(_on_go_to_turbine)
	_penstock_group.add_child(goto_btn)

	# Placing the turbine near a pond auto-binds it and auto-routes its outlet
	# (and re-tries automatically whenever the Lab opens on an unbound siphon)
	# — these are fallback/override controls, not a required setup step.
	var bind_btn := Button.new()
	bind_btn.text = "Rebind to nearest pond"
	bind_btn.tooltip_text = "Auto-bind normally happens on placement — use this to switch ponds or retry"
	bind_btn.pressed.connect(_on_bind_pond)
	_side.add_child(bind_btn)
	_outlet_btn = Button.new()
	_outlet_btn.text = "Refresh outlet route"
	_outlet_btn.tooltip_text = "Re-route the downhill culvert outlet (e.g. after sculpting terrain)"
	_outlet_btn.pressed.connect(_on_ensure_outlet)
	_side.add_child(_outlet_btn)

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

	_section(_side, "Test flow")
	_drive_hint_lbl = Label.new()
	_drive_hint_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_drive_hint_lbl.add_theme_color_override("font_color", C_MUTED)
	_drive_hint_lbl.add_theme_font_size_override("font_size", 11)
	_side.add_child(_drive_hint_lbl)
	_sim_inflow_btn = CheckButton.new()
	_sim_inflow_btn.toggled.connect(_on_sim_inflow_toggled)
	_side.add_child(_sim_inflow_btn)
	_sim_inflow_spin = _spin(_side, "Flow L/s", 0.05, 2000.0, 0.05, func(v: float) -> void:
		if _syncing:
			return
		_sync_flow_slider_from_spin(v)
		var on := _sim_inflow_btn != null and _sim_inflow_btn.button_pressed
		_write_sim_inflow(on, v))
	_sim_inflow_spin.value = 0.5
	# Slider for the same value: sweeping a flow and watching the power track is
	# the point of the control, and a SpinBox's up/down arrows make that a chore.
	# Linear over the micro-hydro band; the spin stays the escape hatch above it
	# and the slider's ceiling follows whatever it is set to.
	_sim_inflow_slider = HSlider.new()
	_sim_inflow_slider.min_value = 0.0
	_sim_inflow_slider.max_value = FLOW_SLIDER_MAX_LPS
	_sim_inflow_slider.step = 0.01
	_sim_inflow_slider.value = 0.5
	_sim_inflow_slider.custom_minimum_size = Vector2(0, 18)
	_sim_inflow_slider.tooltip_text = "Drag to sweep the source flow and watch the power, head and nozzle warnings track it live."
	_sim_inflow_slider.value_changed.connect(func(v: float) -> void:
		if _syncing or _sim_inflow_spin == null:
			return
		_syncing = true
		_sim_inflow_spin.value = v
		_syncing = false
		var on := _sim_inflow_btn != null and _sim_inflow_btn.button_pressed
		_write_sim_inflow(on, v))
	_side.add_child(_sim_inflow_slider)
	# What the pond is actually doing: the fill against the siphon's draw.
	# "I can't get the level to rise" is this line being negative.
	_net_lbl = Label.new()
	_net_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_net_lbl.add_theme_color_override("font_color", C_MUTED)
	_net_lbl.add_theme_font_size_override("font_size", 11)
	_net_lbl.text = ""
	_side.add_child(_net_lbl)
	var fill_btn := Button.new()
	fill_btn.text = "Fill pond to the prime level"
	fill_btn.tooltip_text = "Set the pond's surface just over the prime level (what the Test inflow would reach eventually) so the siphon starts now."
	fill_btn.pressed.connect(_on_fill_to_prime)
	_side.add_child(fill_btn)
	_sync_test_flow_labels()

	_section(_side, "Live readouts")
	# Name the source explicitly. Three surfaces in this Lab show live numbers and
	# people could not tell which to trust; these and the strip under the section
	# are the SAME operating point, written in the same refresh.
	var live_hint := Label.new()
	live_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	live_hint.add_theme_color_override("font_color", C_MUTED)
	live_hint.add_theme_font_size_override("font_size", 10)
	live_hint.text = "The machine's operating point at the matched load — the same numbers as the strip under the section. The close-up's own readout shows this scaled to whatever load you set there."
	_side.add_child(live_hint)
	_rpm_lbl = _ro(_side, "RPM", true)
	_pe_lbl = _ro(_side, "Hydraulic PE", true)
	_elec_lbl = _ro(_side, "Electrical", true)
	_elec_lbl.add_theme_color_override("font_color", C_ACCENT)
	_flow_lbl = _ro(_side, "Flow", true)
	_head_lbl = _ro(_side, "Head", true)
	_state_lbl = _ro(_side, "State", true)
	_cum_lbl = _ro(_side, "Outlet volume")
	_warn_lbl = Label.new()
	_warn_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_warn_lbl.add_theme_color_override("font_color", C_WARN)
	_warn_lbl.add_theme_font_size_override("font_size", 11)
	_warn_lbl.visible = false
	_side.add_child(_warn_lbl)
	# The oversized-nozzle warning already knows the diameter that would match the
	# supply, and the nozzle Ø spin is four rows up — so make the recommendation
	# something you can act on rather than something you have to retype.
	_fit_nozzle_btn = Button.new()
	_fit_nozzle_btn.visible = false
	_fit_nozzle_btn.pressed.connect(_on_fit_nozzle)
	_side.add_child(_fit_nozzle_btn)

	# Power curves: P vs gross head, one polyline per poly pipe size, with the
	# live operating point marked — change a knob and watch the marker move
	# against the alternatives (penstock kinds only; hidden for the siphon).
	_chart_body = _fold_section(_side, "Power curves", true)
	_chart = Control.new()
	_chart.set_script(_CHART_SCRIPT)
	_chart.custom_minimum_size = Vector2(0, 190)
	_chart.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chart_body.add_child(_chart)
	_chart_stats_lbl = Label.new()
	_chart_stats_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_chart_stats_lbl.add_theme_color_override("font_color", C_MUTED)
	_chart_stats_lbl.add_theme_font_size_override("font_size", 11)
	_chart_body.add_child(_chart_stats_lbl)

	var intake_body := _fold_section(_side, "Intake works", false)
	_intake_lbl = Label.new()
	_intake_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_intake_lbl.add_theme_color_override("font_color", C_TEXT)
	_intake_lbl.add_theme_font_size_override("font_size", 11)
	_intake_lbl.text = ""
	intake_body.add_child(_intake_lbl)
	var est_body := _fold_section(_side, "Estimate", false)
	_capacity_lbl = _ro(est_body, "Pipe capacity")
	_loss_lbl = _ro(est_body, "Head loss")
	_capfac_lbl = _ro(est_body, "Capacity factor")
	_annual_lbl = _ro(est_body, "Annual energy")
	# The year the nozzle actually sees.
	_firm_lbl = _ro(est_body, "Driest / wettest month")
	_limited_lbl = _ro(est_body, "Supply-limited")
	_design_lbl = Label.new()
	_design_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_design_lbl.add_theme_color_override("font_color", C_TEXT)
	_design_lbl.add_theme_font_size_override("font_size", 11)
	_design_lbl.text = ""
	est_body.add_child(_design_lbl)
	var copy_btn := Button.new()
	copy_btn.text = "Copy design summary"
	copy_btn.tooltip_text = "Puts the pipe spec, route, operating point, annual estimate and every design check on the clipboard as plain text."
	copy_btn.pressed.connect(_on_copy_design_summary)
	est_body.add_child(copy_btn)
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
	_nav_hint_lbl.text = "Right-drag pans · wheel zooms at the cursor (Ctrl = fine) · F frames the turbine, Home the whole run · heading locked to source→outlet"
	_side.add_child(_nav_hint_lbl)


func _section(parent: Control, title: String) -> void:
	parent.add_child(SectionHeader.make(title))


## Collapsible dock block — returns the body VBox to parent controls into.
## Its parent is the Collapsible, so hiding `body.get_parent()` hides the
## whole block (the Power curves card relies on that).
func _fold_section(parent: Control, title: String, open: bool = false) -> VBoxContainer:
	var sec := Collapsible.make(title, open)
	parent.add_child(sec)
	sec.body.add_theme_constant_override("separation", 4)
	return sec.body


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


## Read-only key/value row. `big` = a Live-readout row: the value at 14 px
## (the 12 px pair read as one more hint line in the dock).
func _ro(parent: Control, label: String, big: bool = false) -> Label:
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
	v.add_theme_font_size_override("font_size", 14 if big else 12)
	row.add_child(v)
	return v


func _model() -> GraphModel:
	if _graph_view == null:
		return null
	return _graph_view.get("model") as GraphModel


## True when `item_id` is a live hydro-turbine item this Lab can drive.
func _is_lab_turbine(item_id: String) -> bool:
	if item_id.is_empty():
		return false
	var m := _model()
	if m == null:
		return false
	var it := m.get_item(item_id)
	if it.is_empty():
		return false
	return str((it.get("specs", {}) as Dictionary).get("role", "")) == "siphon_hydro"


## Switch the Lab to another turbine WITHOUT leaving the view — clicking a
## different turbine in the cross-section makes it the active one (before this,
## the dock params always applied to whichever turbine the Lab opened on, and
## with two turbines on a site there was no way to move the session over).
func set_active_turbine(item_id: String) -> void:
	if item_id == _item_id or not _is_lab_turbine(item_id):
		return
	# Park the old turbine's test inflow — it belongs to that session.
	if not _item_id.is_empty():
		var lps := float(_sim_inflow_spin.value) if _sim_inflow_spin != null else 0.5
		_write_sim_inflow(false, lps)
	_item_id = item_id
	_load_from_model()
	if _graph_view != null and _graph_view.has_method("prepare_siphon_lab_session"):
		_graph_view.call("prepare_siphon_lab_session", _item_id)
	_reset_view_transform()
	_phys_acc = 999.0
	call_deferred("_push_lab_section_frame")
	if _preview != null:
		_preview.queue_redraw()


func _pick_default_siphon_id() -> String:
	var m := _model()
	if m == null:
		return ""
	# Prefer current selection on the graph view.
	if _graph_view != null:
		var sel := str(_graph_view.get("_selected_item_id") if _graph_view.get("_selected_item_id") != null else "")
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
	# A reload means the pond binding, the basin polygon or the routed penstock
	# may all have changed under the cached signatures.
	_invalidate_slice_cache()
	_est_sig = ""
	_route_sig = ""
	_routed_conn_id = ""
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
	var dip_len_l := float(specs.get("dip_tube_length_m", NAN))
	if is_nan(dip_len_l) or dip_len_l <= 0.0:
		dip_len_l = maxf(mod_e - break_m, 0.1)
	if _dip_len_spin != null:
		_dip_len_spin.value = dip_len_l
	if _prime_opt != null:
		_prime_opt.select(1 if str(specs.get("siphon_prime_mode", "overflow")) == "pump" else 0)
	if _runner_spin != null:
		_runner_spin.value = float(specs.get("runner_diameter_mm", 0.0))
	_penstock_len_spin.value = float(specs.get("penstock_length_m", 60.0))
	_penstock_d_spin.value = float(specs.get("penstock_diameter_mm", 63.0))
	_roughness_spin.value = float(specs.get("pipe_roughness_mm", 0.0015)) * 1000.0
	_design_flow_spin.value = float(specs.get("design_flow_lps", 5.0))
	_turb_eff_spin.value = float(specs.get("turbine_efficiency", 0.0))
	# A model reload means a different turbine / fresh state — never leave the
	# placement gizmo armed against the previous one.
	_penstock_mode = false
	_penstock_dragging = false
	_penstock_ghost_valid = false
	_sync_penstock_btn()
	var kind := str(specs.get("turbine_kind", "siphon"))
	var kmeta := HydroSource.kind_meta(kind)
	if _nozzle_count_spin != null:
		_nozzle_count_spin.max_value = maxf(float(kmeta.get("nozzle_count_max", 2)), 1.0)
		_nozzle_count_spin.value = maxf(float(specs.get("nozzle_count", 1)), 1.0)
	if _nozzle_d_spin != null:
		_nozzle_d_spin.value = float(specs.get("nozzle_diameter_mm",
				float(kmeta.get("default_nozzle_mm", 10.0))))
	if _close_spin != null:
		_close_spin.value = float(specs.get("valve_close_s", 10.0))
	if _nozzle_off_spin != null:
		_nozzle_off_spin.value = float(specs.get("nozzle_offset_mm", 0.0))
	for sb: SpinBox in _nozzle_pose_spins:
		sb.value = float(specs.get(str(sb.get_meta("spec_key", "")), 0.0))
	_push_nozzle_pose()
	_select_kind_in_dropdown(kind)
	_apply_kind_visibility(kind)
	if _sim_inflow_spin != null:
		_sim_inflow_spin.value = maxf(float(specs.get("lab_sim_inflow_lps", 0.5)), 0.05)
		_sync_flow_slider_from_spin(float(_sim_inflow_spin.value))
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
	elif key == "dip_tube_length_m":
		specs[key] = maxf(v, 0.1)
		SiphonHydraulics.apply_resolved_levels(specs, module)
		_syncing = true
		if _start_spin != null:
			_start_spin.value = float(specs.get("siphon_start_m", module))
		if _break_spin != null:
			_break_spin.value = float(specs.get("siphon_break_m", module))
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


func _commit_bool(key: String, v: bool) -> void:
	var m := _model()
	if m == null or _item_id.is_empty():
		return
	var item := m.get_item(_item_id)
	if item.is_empty():
		return
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	specs[key] = v
	m.update_item(_item_id, {"specs": specs})


func _commit_string(key: String, v: String) -> void:
	var m := _model()
	if m == null or _item_id.is_empty():
		return
	var item := m.get_item(_item_id)
	if item.is_empty():
		return
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	specs[key] = v
	if key == "siphon_prime_mode":
		var module := float(_module_spin.value) if _module_spin != null \
				else float(specs.get("module_elev_m", item.get("elevation_m", 0.0)))
		SiphonHydraulics.apply_resolved_levels(specs, module)
		_syncing = true
		if _start_spin != null:
			_start_spin.value = float(specs.get("siphon_start_m", module))
		if _break_spin != null:
			_break_spin.value = float(specs.get("siphon_break_m", module))
		_syncing = false
	m.update_item(_item_id, {"specs": specs})
	_phys_acc = 999.0


func _on_kind_selected(idx: int) -> void:
	if _syncing or _kind_opt == null:
		return
	var kind := str(_kind_opt.get_item_metadata(idx))
	_commit_string("turbine_kind", kind)
	_apply_kind_visibility(kind)
	# A different turbine kind is a different MACHINE — swap the placed 3D model
	# so a PowerSpout stops wearing the siphon turbine's body.
	if _graph_view != null and _graph_view.has_method("sync_turbine_model_to_kind"):
		_graph_view.call("sync_turbine_model_to_kind", _item_id)
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
	var nozzle := bool(meta.get("uses_nozzle_model", false))
	_sync_test_flow_labels()
	if _siphon_group != null:
		_siphon_group.visible = not penstock
	if _penstock_group != null:
		_penstock_group.visible = penstock
	# Nozzle-governed kinds: the nozzle IS the flow control — swap the knob.
	if _design_flow_spin != null and _design_flow_spin.get_parent() != null:
		(_design_flow_spin.get_parent() as Control).visible = penstock and not nozzle
	if _nozzle_count_spin != null and _nozzle_count_spin.get_parent() != null:
		(_nozzle_count_spin.get_parent() as Control).visible = penstock and nozzle
	if _nozzle_d_spin != null and _nozzle_d_spin.get_parent() != null:
		(_nozzle_d_spin.get_parent() as Control).visible = penstock and nozzle
	if _nozzle_off_spin != null and _nozzle_off_spin.get_parent() != null:
		(_nozzle_off_spin.get_parent() as Control).visible = penstock and nozzle
	for sb: SpinBox in _nozzle_pose_spins:
		if sb.get_parent() != null:
			(sb.get_parent() as Control).visible = penstock and nozzle
	for c: Control in _nozzle_pose_extras:
		c.visible = penstock and nozzle
	# Power curves are a penstock story (pipe-size families); the siphon's
	# output is orifice/weir-limited, not pipe-diameter-limited.
	if _chart_body != null and _chart_body.get_parent() != null:
		(_chart_body.get_parent() as Control).visible = penstock
	# Penstock kinds discharge tailwater at the machine — there is no culvert
	# outlet to refresh (and ensure_siphon_outlet_sink now refuses to mint one).
	if _outlet_btn != null:
		_outlet_btn.visible = not penstock
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


## Nozzle-governed (PowerSpout-class Pelton): the NOZZLE sets the flow, so
## `design_flow_lps == 0` means unlimited rather than "no water".
func _kind_uses_nozzle() -> bool:
	return bool(HydroSource.kind_meta(_current_kind()).get("uses_nozzle_model", false))


## Snap the turbine module to the ground at its site position — the quick
## "seat it on the hillside" placement move (the CT drag stays for fine work).
func _on_snap_module_to_terrain() -> void:
	var m := _model()
	if m == null or _item_id.is_empty():
		return
	var item := m.get_item(_item_id)
	if not GraphSiteLayout.has_site_coords(item):
		if _route_status_lbl != null:
			_route_status_lbl.text = "Place the turbine on the map first (Site Plan / 3D)."
		return
	var soi := _soi_service()
	if soi == null or not soi.has_method("ground_y_at") \
			or not soi.has_method("world_center"):
		return
	var center: Vector3 = soi.call("world_center") as Vector3
	var wxz := GraphSiteLayout.site_to_world_xz(GraphSiteLayout.site_xz(item), center)
	var gy := float(soi.call("ground_y_at", wxz.x, wxz.y))
	if _module_spin != null:
		_module_spin.value = gy   # spin commit path persists module_elev_m + levels
	_commit_float("module_elev_m", gy)


## Restyle the pond→turbine water wire as a contour-routed poly penstock — the
## SAME connection the 3D wire tools edit (one route, two surfaces). The
## conduit manager then measures the ground-following run and stamps
## route_length_m + endpoint inverts, which the flow engine feeds HydroReach.
func _on_route_penstock() -> void:
	var m := _model()
	if m == null or _item_id.is_empty() or _route_status_lbl == null:
		return
	var tank: Dictionary = {}
	if _graph_view != null and _graph_view.has_method("resolve_siphon_pond"):
		tank = _graph_view.call("resolve_siphon_pond", _item_id)
	if tank.is_empty():
		_route_status_lbl.text = "No pond bound — Rebind to nearest pond first."
		return
	var tid := str(tank.get("id", ""))
	var conn_id := str(_graph_view.call("route_penstock_to_source", _item_id,
			{"kind": "pond", "item_id": tid}, _route_style_opts()))
	if conn_id.is_empty():
		_route_status_lbl.text = "Couldn't route from the pond."
		return
	_phys_acc = 999.0
	_refresh_route_status(true)
	# The run length is stamped by the rebuild, which lands a frame or two
	# later — refresh the readout again once it has.
	get_tree().create_timer(0.35).timeout.connect(
			_refresh_route_status.bind(true), CONNECT_ONE_SHOT)


## Arm / disarm penstock placement: a glowing gizmo appears on the turbine
## inlet in the cross-section and the player drags it to the water source.
func _on_toggle_penstock_mode() -> void:
	_penstock_mode = not _penstock_mode
	_penstock_dragging = false
	_penstock_ghost_valid = false
	_sync_penstock_btn()
	if _route_status_lbl != null:
		if _penstock_mode:
			_route_status_lbl.text = "Drag the ● on the turbine inlet up to the water source, then release."
		else:
			_refresh_route_status(true)
	_redraw_preview()


func _sync_penstock_btn() -> void:
	if _penstock_btn == null:
		return
	_penstock_btn.text = "Cancel routing" if _penstock_mode else "Route penstock…"
	_penstock_btn.modulate = Color(1.0, 0.86, 0.45) if _penstock_mode else Color.WHITE


## Section drag → world. `canvas_to_elevation_hit` is the SAME authority
## GraphSpatialEdit uses (it intersects the canvas ray with the section plane
## and stays correct under pan/zoom), so the gizmo can never disagree with the
## props drawn beside it.
func _penstock_hit_from_canvas(pos: Vector2) -> Dictionary:
	if _graph_view == null:
		return {}
	var preview = _graph_view.get("_soi_preview")
	if preview == null or not preview.has_method("canvas_to_elevation_hit"):
		return {}
	var params := _elev_section_params()
	var e: Variant = preview.call("canvas_to_elevation_hit", pos,
			float(params.get("heading", 0.0)))
	if not (e is Dictionary) or (e as Dictionary).is_empty():
		return {}
	return e as Dictionary


func _penstock_try_input(event: InputEvent) -> bool:
	if not _penstock_mode or _item_id.is_empty():
		return false
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			_on_toggle_penstock_mode()   # RMB cancels the mode
			_preview_stack.accept_event()
			return true
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return false
		if mb.pressed:
			# Grab only ON the gizmo, so panning and level drags still work.
			if not is_finite(_penstock_gizmo_screen.x) \
					or mb.position.distance_to(_penstock_gizmo_screen) > 22.0:
				return false
			_penstock_dragging = true
			_penstock_ghost_valid = false
			_preview_stack.accept_event()
			return true
		if _penstock_dragging:
			_penstock_dragging = false
			_preview_stack.accept_event()
			_commit_penstock_drag()
			return true
		return false
	if event is InputEventMouseMotion and _penstock_dragging:
		var hit := _penstock_hit_from_canvas((event as InputEventMouseMotion).position)
		if hit.is_empty():
			_penstock_ghost_valid = false
		else:
			var site := Vector2(float(hit.get("site_x_m", 0.0)),
					float(hit.get("site_z_m", 0.0)))
			var params := _elev_section_params()
			_penstock_ghost_site = site
			# Pond-relative, like everything else the overlay draws — see
			# _pond_along_m. Absolute here put the drag ghost (and therefore the
			# committed intake) against the wrong part of the terrain profile.
			_penstock_ghost_along = GraphSiteLayout.project_onto_section(
					site, float(params.get("heading", 0.0))).x - _pond_along_m()
			# Snap the end to the GROUND, not the click height — a penstock
			# intake sits on the terrain, and the drag then reads as "walking"
			# the pipe up the slope.
			var gy := _ground_elev_at_site(site)
			_penstock_ghost_elev = gy if not is_nan(gy) \
					else float(hit.get("elevation_m", 0.0))
			_penstock_ghost_valid = true
		_preview_stack.accept_event()
		_redraw_preview()
		return true
	return false


## Terrain elevation at a site point (SoI service), NAN when unavailable.
func _ground_elev_at_site(site: Vector2) -> float:
	var soi := _soi_service()
	if soi == null or not soi.has_method("ground_y_at") \
			or not soi.has_method("world_center"):
		return NAN
	var center: Vector3 = soi.call("world_center") as Vector3
	var wxz := GraphSiteLayout.site_to_world_xz(site, center)
	return float(soi.call("ground_y_at", wxz.x, wxz.y))


func _commit_penstock_drag() -> void:
	if not _penstock_ghost_valid:
		if _route_status_lbl != null:
			_route_status_lbl.text = "Released off the terrain — try again on the hillside."
		_redraw_preview()
		return
	var turbine_elev := float(_module_spin.value) if _module_spin != null else 0.0
	if _penstock_ghost_elev <= turbine_elev + 0.25:
		if _route_status_lbl != null:
			_route_status_lbl.text = "Source must be ABOVE the turbine — drag further uphill."
		_penstock_ghost_valid = false
		_redraw_preview()
		return
	var soi := _soi_service()
	if soi == null or not soi.has_method("world_center") or _graph_view == null:
		return
	var center: Vector3 = soi.call("world_center") as Vector3
	var wxz := GraphSiteLayout.site_to_world_xz(_penstock_ghost_site, center)
	var conn_id := ""
	if _graph_view.has_method("route_penstock_to_source"):
		var source: Dictionary = _graph_view.call("resolve_hydro_source_at", wxz)
		if str(source.get("kind", "")) == "spring":
			source["world_pos"] = Vector3(wxz.x, _penstock_ghost_elev, wxz.y)
		conn_id = str(_graph_view.call("route_penstock_to_source", _item_id, source,
				_route_style_opts()))
	_penstock_mode = false
	_penstock_ghost_valid = false
	_sync_penstock_btn()
	_phys_acc = 999.0
	if conn_id.is_empty():
		if _route_status_lbl != null:
			_route_status_lbl.text = "Couldn't place the intake there."
	else:
		_refresh_route_status(true)
		get_tree().create_timer(0.35).timeout.connect(
				_refresh_route_status.bind(true), CONNECT_ONE_SHOT)
	_redraw_preview()


func _on_go_to_turbine() -> void:
	if _graph_view != null and _graph_view.has_method("go_to_turbine_in_world"):
		_graph_view.call("go_to_turbine_in_world", _item_id)


## One-click uphill routing: ring-scan real terrain around the turbine, place
## the Stream Intake on the best genuinely-higher ground, run the penstock.
func _on_auto_route_uphill() -> void:
	if _graph_view == null or _item_id.is_empty() or _route_status_lbl == null:
		return
	var m := _model()
	if m == null:
		return
	var item := m.get_item(_item_id)
	if not GraphSiteLayout.has_site_coords(item):
		_route_status_lbl.text = "Place the turbine on the map first (Site Plan / 3D)."
		return
	var soi := _soi_service()
	if soi == null or not soi.has_method("ground_y_at") \
			or not soi.has_method("world_center"):
		_route_status_lbl.text = "No terrain on this map — set Gross head by hand."
		return
	# A creek above the turbine beats a bare hilltop: the view scans the
	# map's streams first, then the terrain ring (the old scan).
	var source: Dictionary = _graph_view.call("find_uphill_source", _item_id, 150.0) \
		if _graph_view.has_method("find_uphill_source") else {}
	if source.is_empty():
		_route_status_lbl.text = "Nothing higher within 150 m — drag the gizmo further, or set Gross head by hand."
		return
	var conn_id := str(_graph_view.call("route_penstock_to_source", _item_id, source, _route_style_opts()))
	_phys_acc = 999.0
	if conn_id.is_empty():
		_route_status_lbl.text = "Couldn't route the penstock."
	else:
		_route_status_lbl.text = "%s tapped %.1f m above the turbine." % [
			str(source.get("label", "Source")), float(source.get("rise_m", 0.0))]
		get_tree().create_timer(0.35).timeout.connect(_refresh_route_status.bind(true),
				CONNECT_ONE_SHOT)
	_redraw_preview()


## The routed penstock's live facts (run / drop / size), or why there isn't one.
## Signature-gated: this ran a full connections scan on every 6 Hz physics tick,
## and the answer only moves when a route is added, removed or re-measured.
## `force` is for the paths that just wrote a TRANSIENT message into this label
## (placement hints, refusals): the route itself did not change, so the signature
## would otherwise leave that message on screen forever.
func _refresh_route_status(force: bool = false) -> void:
	if _route_status_lbl == null:
		return
	var m := _model()
	if m == null or _item_id.is_empty():
		return
	if force:
		_route_sig = ""
	var conn := _penstock_conn_for_status(m)
	var sig := "%d|%s|%.3f|%.3f|%.3f|%.3f" % [
		m.connections.size(), str(conn.get("id", "")),
		float(conn.get("route_length_m", 0.0)),
		float(conn.get("invert_in_m", NAN)),
		float(conn.get("invert_out_m", NAN)),
		ConduitKinds.pipe_size_in("poly_penstock",
				conn.get("conduit_style", {}) as Dictionary) if not conn.is_empty() else 0.0,
	]
	if sig == _route_sig:
		return
	_route_sig = sig
	if _source_lbl != null and _graph_view != null and _graph_view.has_method("hydro_source_summary"):
		var src: Dictionary = _graph_view.call("hydro_source_summary", _item_id)
		var kind_word: String = {"pond": "Pond", "stream": "Stream", "spring": "Spring", "none": ""}.get(str(src.get("kind", "")), "")
		_source_lbl.text = ("%s: %s — %s" % [kind_word, str(src.get("label", "")), str(src.get("detail", ""))]) \
			if not kind_word.is_empty() else "%s — %s" % [str(src.get("label", "")), str(src.get("detail", ""))]
	if conn.is_empty():
		_route_status_lbl.text = "Not routed — physics uses the typed length/head above."
		return
	var style: Dictionary = conn.get("conduit_style", {}) as Dictionary
	_sync_route_controls(style)
	var sz := ConduitKinds.pipe_size_in("poly_penstock", style)
	var sdr := ConduitKinds.pipe_sdr("poly_penstock", style)
	var run := float(conn.get("route_length_m", 0.0))
	var inv_in := float(conn.get("invert_in_m", NAN))
	var inv_out := float(conn.get("invert_out_m", NAN))
	var drop := absf(inv_in - inv_out) if not (is_nan(inv_in) or is_nan(inv_out)) else NAN
	var pipe := "%s SDR %s poly (ID %.1f mm, %.0f psi)" % [PipeKit.size_label(sz),
		("%.1f" % sdr).trim_suffix(".0"),
		ConduitKinds.inner_diameter_for("poly_penstock", style) * 1000.0,
		ConduitKinds.pressure_rating_psi("poly_penstock", style)]
	if run > 0.5:
		var txt := "Routed: %s · run %.0f m (%.0f ft)" % [pipe, run, run / 0.3048]
		if not is_nan(drop):
			txt += " · drop %.1f m"  % drop
		var stock := float(style.get("stock_length_m", 0.0))
		if stock > 0.0:
			txt += " · %s" % (("%.0f ft spare" % ((stock - run) / 0.3048)) if run <= stock
				else ("SHORT by %.0f ft" % ((run - stock) / 0.3048)))
		_route_status_lbl.text = txt
	else:
		_route_status_lbl.text = "Routed: %s (measuring run…)" % pipe


## Size / SDR / stock from the route row, as route_penstock_to_source opts.
func _route_style_opts() -> Dictionary:
	var o := {}
	if _route_size_opt != null and _route_size_opt.selected >= 0:
		o["pipe_size_in"] = float(_route_size_opt.get_item_metadata(_route_size_opt.selected))
	if _route_sdr_opt != null and _route_sdr_opt.selected >= 0:
		o["pipe_sdr"] = float(_route_sdr_opt.get_item_metadata(_route_sdr_opt.selected))
	if _stock_spin != null and _stock_spin.value > 0.0:
		o["stock_length_m"] = _stock_spin.value * 0.3048
	return o


## The route controls show the live run's style (size / SDR / stock) without
## echoing back into it.
func _sync_route_controls(style: Dictionary) -> void:
	if _syncing:
		return
	_syncing = true
	var sz := ConduitKinds.pipe_size_in("poly_penstock", style)
	if _route_size_opt != null:
		for i in _route_size_opt.item_count:
			if is_equal_approx(float(_route_size_opt.get_item_metadata(i)), sz):
				_route_size_opt.select(i)
	var sdr := ConduitKinds.pipe_sdr("poly_penstock", style)
	if _route_sdr_opt != null:
		for i in _route_sdr_opt.item_count:
			if is_equal_approx(float(_route_sdr_opt.get_item_metadata(i)), sdr):
				_route_sdr_opt.select(i)
	if _stock_spin != null:
		_stock_spin.value = roundf(float(style.get("stock_length_m", 0.0)) / 0.3048)
	_syncing = false


## Size / SDR / stock from the controls onto the live penstock run. Size and
## SDR change the bore and the bend radius, so the run is rebuilt (the flow
## engine then adopts the new measured geometry); stock is data only.
func _apply_route_style() -> void:
	if _syncing:
		return
	var m := _model()
	if m == null:
		return
	var conn := _penstock_conn_for_status(m)
	if conn.is_empty():
		return
	var style: Dictionary = (conn.get("conduit_style", {}) as Dictionary).duplicate(true)
	var before_geo := "%.3f|%.3f" % [ConduitKinds.pipe_size_in("poly_penstock", style),
		ConduitKinds.pipe_sdr("poly_penstock", style)]
	if _route_size_opt != null and _route_size_opt.selected >= 0:
		style["pipe_size_in"] = float(_route_size_opt.get_item_metadata(_route_size_opt.selected))
	if _route_sdr_opt != null and _route_sdr_opt.selected >= 0:
		style["pipe_sdr"] = float(_route_sdr_opt.get_item_metadata(_route_sdr_opt.selected))
	if _stock_spin != null:
		if _stock_spin.value > 0.0:
			style["stock_length_m"] = _stock_spin.value * 0.3048
		else:
			style.erase("stock_length_m")
	m.update_connection(str(conn.get("id", "")), {"conduit_style": style})
	var after_geo := "%.3f|%.3f" % [ConduitKinds.pipe_size_in("poly_penstock", style),
		ConduitKinds.pipe_sdr("poly_penstock", style)]
	if after_geo != before_geo and _graph_view != null \
			and _graph_view.has_method("reveal_penstock_conduit"):
		_graph_view.call("reveal_penstock_conduit", str(conn.get("id", "")))
	_phys_acc = 999.0
	_refresh_route_status(true)
	get_tree().create_timer(0.35).timeout.connect(
			_refresh_route_status.bind(true), CONNECT_ONE_SHOT)


## The design checks (PenstockDesign) from the live operating point + the
## routed run, and the plain-text summary the Copy button exports.
func _refresh_design_checks(sim_specs: Dictionary) -> void:
	if _design_lbl == null:
		return
	if not _kind_has_penstock():
		_design_lbl.text = ""
		_design_summary = ""
		_last_rating_psi = NAN
		return
	var m := _model()
	var conn: Dictionary = _penstock_conn_for_status(m) if m != null else {}
	var style: Dictionary = conn.get("conduit_style", {}) as Dictionary
	var id_m := float(sim_specs.get("penstock_diameter_mm", 0.0)) / 1000.0
	var od_m := ConduitKinds.outer_diameter_m("poly_penstock", style)
	if conn.is_empty():
		od_m = id_m / (1.0 - 2.0 / ConduitKinds.pipe_sdr("poly_penstock", style))
	var sdr := ConduitKinds.pipe_sdr("poly_penstock", style)
	var r_route := float(conn.get("route_min_bend_r_m", -1.0))
	var d := {
		"q_lps": float(_last_r.get("q_lps", NAN)),
		"gross_head_m": float(_last_r.get("head_m", NAN)),
		"head_loss_m": float(_last_r.get("head_loss_m", NAN)),
		"id_m": id_m, "od_m": od_m, "sdr": sdr,
		"wall_m": od_m / sdr,
		"length_m": float(sim_specs.get("penstock_length_m", NAN)),
		"stock_m": float(style.get("stock_length_m", NAN)) if style.has("stock_length_m") else NAN,
		"rating_psi": ConduitKinds.pressure_rating_psi("poly_penstock", style),
		"min_bend_r_m": ConduitKinds.contour_bend_radius_m("poly_penstock", style),
		"bend_mult": ConduitKinds.bend_radius_mult_for_sdr(sdr),
		"route_min_bend_r_m": r_route if r_route > 0.0 else NAN,
		"high_points": int(conn.get("route_high_points", -1)) if not conn.is_empty() else -1,
		"rise_above_intake_m": float(conn.get("route_rise_m", NAN)) if not conn.is_empty() else NAN,
		"close_s": float(_close_spin.value) if _close_spin != null else NAN,
	}
	_last_rating_psi = float(d["rating_psi"])
	var cks := PenstockDesign.checks(d)
	_refresh_intake_works(sim_specs, id_m)
	var lines: Array[String] = []
	for c in cks:
		var cd: Dictionary = c
		var mark: String = str({"ok": "✓", "warn": "⚠", "fail": "✗", "info": "·"}.get(str(cd.get("level", "")), "·"))
		lines.append("%s %s" % [mark, str(cd.get("text", ""))])
	_design_lbl.text = "\n".join(lines)
	var worst := PenstockDesign.worst_level(cks)
	_design_lbl.add_theme_color_override("font_color",
		C_TEXT if worst == "ok" else (Color(0.98, 0.78, 0.35) if worst == "warn" else Color(1.0, 0.45, 0.4)))
	# Summary text.
	var item := m.get_item(_item_id) if m != null else {}
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var head := [
		"Turbine: %s (%s)" % [str(specs.get("name", "")), str(specs.get("turbine_kind", ""))],
		"Nozzle: %d × %.1f mm" % [int(sim_specs.get("nozzle_count", 1)), float(sim_specs.get("nozzle_diameter_mm", 0.0))],
		"Pipe: %s SDR %s poly, ID %.1f mm, rated %.0f psi (%.0f m)" % [
			PipeKit.size_label(ConduitKinds.pipe_size_in("poly_penstock", style)),
			("%.1f" % sdr).trim_suffix(".0"), id_m * 1000.0, float(d["rating_psi"]),
			PenstockDesign.psi_to_head_m(float(d["rating_psi"]))],
		"Run: %.1f m (%.0f ft), gross head %.1f m, net %.1f m" % [
			float(d["length_m"]), float(d["length_m"]) / 0.3048, float(d["gross_head_m"]),
			float(_last_r.get("net_head_m", 0.0))],
		"Operating point: %.2f L/s, %.0f W electrical, %.0f rpm" % [
			float(_last_r.get("q_lps", 0.0)), float(_last_r.get("power_w", 0.0)), float(_last_r.get("rpm", 0.0))],
		"Annual energy: %s" % (_annual_lbl.text if _annual_lbl != null else "—"),
	]
	var src := str(specs.get("penstock_source_mode", ""))
	if src == "stream":
		head.append("Supply: %.2f L/s from the stream intake" % float(sim_specs.get("supply_lps", 0.0)))
	if not _firm_text.is_empty():
		head.append(_firm_text)
	if not _intake_text.is_empty():
		head.append("Intake works: " + _intake_text.replace("\n", "; "))
	_design_summary = PenstockDesign.summary_text("Penstock design — %s" % str(specs.get("name", "turbine")), head, cks)


## Driest / wettest month and how many months the jet is starved, from the
## same seasonal curve the annual estimate used. Runs inside the estimate's
## signature gate (one extra Pelton solve for the nozzle's demand).
func _refresh_firm_flow(est: Dictionary, supply_prof: Array, ann: Dictionary) -> void:
	_firm_text = ""
	if _firm_lbl == null:
		return
	if supply_prof.size() != 12:
		_firm_lbl.text = "—"
		_limited_lbl.text = "— (no seasonal supply: bind a stream intake)"
		return
	var monthly_kwh: Variant = ann.get("monthly_kwh", PackedFloat32Array())
	var monthly_kw: Array = []
	for mo in 12:
		var days: int = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][mo]
		monthly_kw.append(float(monthly_kwh[mo]) / (24.0 * days) if monthly_kwh.size() == 12 else NAN)
	var nozzle_q := NAN
	if _kind_uses_nozzle():
		var meta := HydroSource.kind_meta(str(est.get("turbine_kind", est.get("kind", "pelton"))))
		var op := PeltonPhysics.operating_point(float(est.get("gross_head_m", 0.0)),
				float(est.get("penstock_length_m", 60.0)),
				float(est.get("penstock_diameter_mm", 63.0)) / 1000.0,
				float(est.get("pipe_roughness_mm", 0.0015)) / 1000.0,
				float(est.get("nozzle_diameter_mm", float(meta.get("default_nozzle_mm", 10.0)))) / 1000.0,
				int(est.get("nozzle_count", 1)))
		nozzle_q = float(op.get("q_lps", NAN))
	var ff := PenstockDesign.firm_flow(supply_prof, monthly_kw, nozzle_q)
	if ff.is_empty():
		_firm_lbl.text = "—"
		return
	var lo_name: String = PenstockDesign.MONTH_ABBR[int(ff["min_month"])]
	var hi_name: String = PenstockDesign.MONTH_ABBR[int(ff["max_month"])]
	_firm_lbl.text = "%s %.2f L/s → %.0f W  ·  %s %.2f L/s → %.0f W" % [
		lo_name, float(ff["min_lps"]), float(ff["min_kw"]) * 1000.0,
		hi_name, float(ff["max_lps"]), float(ff["max_kw"]) * 1000.0]
	if is_nan(nozzle_q):
		_limited_lbl.text = "n/a (no nozzle)"
	else:
		var n := int(ff["limited_months"])
		var txt := "%d of 12 months below the %.2f L/s the jet takes" % [n, nozzle_q]
		if n > 0:
			var fit := PeltonPhysics.nozzle_d_for_supply_m(float(est.get("gross_head_m", 0.0)),
					float(est.get("penstock_length_m", 60.0)),
					float(est.get("penstock_diameter_mm", 63.0)) / 1000.0,
					float(est.get("pipe_roughness_mm", 0.0015)) / 1000.0,
					int(est.get("nozzle_count", 1)), float(ff["min_lps"]) / 1000.0)
			if fit > 0.0:
				txt += " — a %.1f mm jet runs unlimited all year" % (fit * 1000.0)
		_limited_lbl.text = txt
	_firm_text = "Firm flow: %s %.2f L/s (%.0f W); wettest %s %.2f L/s (%.0f W); %s" % [
		lo_name, float(ff["min_lps"]), float(ff["min_kw"]) * 1000.0,
		hi_name, float(ff["max_lps"]), float(ff["max_kw"]) * 1000.0, _limited_lbl.text]


## Screen, settling box and submergence for the most the nozzle will take.
func _refresh_intake_works(sim_specs: Dictionary, id_m: float) -> void:
	_intake_text = ""
	if _intake_lbl == null:
		return
	if not _kind_has_penstock() or id_m <= 0.0:
		_intake_lbl.text = ""
		return
	var gross := maxf(float(_last_r.get("head_m", 0.0)), 0.0)
	var q_design := float(_last_r.get("q_lps", 0.0))
	if _kind_uses_nozzle() and gross > 0.05:
		var meta := HydroSource.kind_meta(str(sim_specs.get("turbine_kind", sim_specs.get("kind", "pelton"))))
		var op := PeltonPhysics.operating_point(gross,
				float(sim_specs.get("penstock_length_m", 60.0)), id_m,
				float(sim_specs.get("pipe_roughness_mm", 0.0015)) / 1000.0,
				float(sim_specs.get("nozzle_diameter_mm", float(meta.get("default_nozzle_mm", 10.0)))) / 1000.0,
				int(sim_specs.get("nozzle_count", 1)))
		q_design = maxf(q_design, float(op.get("q_lps", 0.0)))
	if q_design <= 1e-4:
		_intake_lbl.text = "No flow yet — route the penstock to a source above the turbine."
		return
	var w := PenstockDesign.intake_works(q_design, id_m)
	_intake_text = "Sized for %.2f L/s (the jet's full demand at %.1f m)\n" % [q_design, gross]
	_intake_text += "Screen ≥ %.0f × %.0f cm gross (%.1f m/s approach, 50 %% open)\n" % [
		float(w["screen_side_m"]) * 100.0, float(w["screen_side_m"]) * 100.0, PenstockDesign.SCREEN_V_MS]
	_intake_text += "Settling box %.2f × %.2f m, %.2f m deep — settles %.1f mm sand, %.0f s dwell\n" % [
		float(w["settle_len_m"]), float(w["settle_w_m"]), float(w["settle_depth_m"]),
		float(w["grain_mm"]), float(w["settle_time_s"])]
	_intake_text += "Pipe mouth ≥ %.2f m under water (Gordon, %.2f m/s in the pipe) — add a bell or tee and a vortex plate" % [
		float(w["submergence_m"]), float(w["pipe_v_ms"])]
	_intake_lbl.text = _intake_text


func _on_copy_design_summary() -> void:
	if _design_summary.is_empty():
		_refresh_design_checks(_last_sim_specs)
	if _design_summary.is_empty():
		return
	DisplayServer.clipboard_set(_design_summary)
	print(_design_summary)
	if _graph_view != null and _graph_view.has_method("_show_toast"):
		_graph_view.call("_show_toast", "Design summary copied to the clipboard")


## Status looks for ANY poly_penstock on this turbine (not only contour-routed
## ones — a hand-pinned run still has a real measured length worth reporting).
func _penstock_conn_for_status(m: Variant) -> Dictionary:
	for conn: Dictionary in m.connections:
		if str(conn.get("source_item_id", "")) != _item_id \
				and str(conn.get("target_item_id", "")) != _item_id:
			continue
		if str(conn.get("conduit_type", "")) == "poly_penstock":
			return conn
	return {}


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
		# Only invalidate the pond cache when the tick's own 0.12 s throttle
		# actually fired and wrote tank state. Dropping it unconditionally turned
		# the 0.25 s _pond_context() cache into a per-frame resolve_siphon_pond().
		if bool(_graph_view.call("lab_siphon_tick", _item_id, delta)):
			_pond_cache_t = 999.0
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
	# Smooth the inflow rate for the runoff-into-pond depiction. The sample
	# walks every connection; 4 Hz is plenty under a 0.5 s smoothing constant.
	_inflow_sample_t += delta
	if _inflow_sample_t >= 0.25:
		_inflow_sample_t = 0.0
		_inflow_target_lps = _sample_pond_inflow_lps()
	_inflow_lps = lerpf(_inflow_lps, _inflow_target_lps,
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
		# A stream-fed turbine has no pond; its INTAKE anchors the section
		# (site + label), with no level — the basin block stays off.
		var rf: Variant = _graph_view.get("_resource_flow")
		if rf != null and rf.has_method("_stream_intake_for"):
			var intake: Dictionary = rf.call("_stream_intake_for", _graph_view.get("model").get_item(_item_id))
			if not intake.is_empty():
				var isp: Dictionary = intake.get("specs", {}) as Dictionary
				out["label"] = str(isp.get("name", "Stream intake"))
				if GraphSiteLayout.has_site_coords(intake):
					out["site"] = GraphSiteLayout.site_xz(intake)
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
	# The draft exit follows the model too: the Lab's session prep reconciles
	# it with the outlet node AFTER the first load, and a re-trace moves it.
	var oi := float(specs.get("outlet_invert_m", NAN))
	if not is_nan(oi) and _outlet_inv_spin != null and absf(float(_outlet_inv_spin.value) - oi) > 1e-3:
		_outlet_inv_spin.value = oi
	if _show_dip_check != null:
		_show_dip_check.set_pressed_no_signal(bool(specs.get("show_dip_tube", false)))
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
	# Apply the test flow to OUR OWN evaluation immediately rather than waiting
	# for the flow engine to re-stamp `supply_lps` on its next tick. The engine
	# lands within a frame or two, but "a frame or two" is exactly the lag that
	# made dragging the slider feel disconnected from the readouts.
	if _kind_has_penstock() and bool(specs.get("lab_sim_inflow_enabled", false)):
		sim_specs["supply_lps"] = maxf(float(specs.get("lab_sim_inflow_lps", 0.0)), 0.0)
		if not sim_specs.has("penstock_source_mode"):
			sim_specs["penstock_source_mode"] = "stream"
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
	if not _kind_has_penstock():
		_sens_text = _siphon_sensitivity_text(sim_specs, level_m)
	_last_sim_specs = sim_specs
	_refresh_design_checks(sim_specs)
	_refresh_warnings()
	_refresh_route_status()
	_refresh_status_strip()
	_refresh_net_readout(level_m)
	_refresh_stat_deck()
	_push_closeup_state()


## The at-a-glance line under the cross-section.
##
## There are three places in this Lab that show live numbers, and they confused
## people because nothing said how they relate. They now have distinct jobs and,
## crucially, ONE source:
##   * this strip — the CHAIN, source → machine, at a glance;
##   * the dock's "Live readouts" — the same operating point, itemised with units;
##   * the close-up's HUD — the same machine AT THE VIEWED LOAD, which is the only
##     one that may legitimately differ, and it says so on its own line.
## Strip and dock both read `_last_r` and are written in the same refresh, so they
## cannot drift apart.
func _refresh_status_strip() -> void:
	if _status_lbl == null:
		return
	var q := float(_last_r.get("q_lps", 0.0))
	var flowing := q > 0.01
	# Lead with the SOURCE so the chain reads left to right: what the water is
	# doing, then what the machine makes of it.
	var parts := PackedStringArray()
	var supply := float(_last_r.get("q_supply_lps", NAN))
	if not is_nan(supply):
		parts.append("source %.2f L/s" % supply)
	parts.append("→ Q %.2f L/s" % q)
	parts.append("head %.1f m" % float(_last_r.get("head_m", 0.0)))
	parts.append("%.0f W" % float(_last_r.get("power_w", 0.0)))
	parts.append("%.0f rpm" % float(_last_r.get("rpm", 0.0)))
	if _kind_has_penstock():
		parts.append("FLOWING" if flowing else str(_last_r.get("regime", "dry")))
	else:
		parts.append("PRIMED" if bool(_last_r.get("primed", false)) else
				str(_last_r.get("regime", "dry")))
	if bool(_last_r.get("supply_limited", false)):
		parts.append("supply-limited")
	if not _kind_has_penstock() and flowing:
		parts.append("suction %.1f / %.1f m" % [float(_last_r.get("suction_m", 0.0)),
				float(_last_r.get("suction_max_m", 0.0))])
		if bool(_last_r.get("cavitating", false)):
			parts.append("CAVITATING")
	_status_lbl.text = " · ".join(parts)
	_status_lbl.add_theme_color_override("font_color", C_ACCENT if flowing else C_MUTED)


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
		_sens_text = ""
		return

	# Build a spec for the shared closed form from the live geometry + penstock edits.
	var gross := maxf(float(_last_r.get("head_m", 0.0)), 0.0)
	var est := sim_specs.duplicate(true)
	# Head is snapped to 5 cm: it drifts continuously as the pond fills/drains, and
	# a raw float in the signature would defeat the gate on every single tick.
	var est_sig := "%s|%.2f|%.2f|%.2f|%.3f|%.3f|%.2f|%d|%.2f|%.1f" % [
		_current_kind(), snappedf(gross, 0.05),
		float(_penstock_len_spin.value) if _penstock_len_spin != null else 60.0,
		float(_penstock_d_spin.value) if _penstock_d_spin != null else 63.0,
		float(_roughness_spin.value) / 1000.0 if _roughness_spin != null else 0.0015,
		float(_turb_eff_spin.value) if _turb_eff_spin != null else 0.0,
		float(_design_flow_spin.value) if _design_flow_spin != null else 0.0,
		int(_nozzle_count_spin.value) if _nozzle_count_spin != null else 1,
		float(_nozzle_d_spin.value) if _nozzle_d_spin != null else 0.0,
		float(sim_specs.get("max_power_w", 0.0)),
	]
	# Editing the intake's base flow / rain response reshapes the seasonal curve
	# without touching a single control in THIS panel, so the annual estimate has
	# to notice. Summing it is enough to discriminate; it is 12 floats.
	var prof_sum := 0.0
	for v: Variant in (sim_specs.get("supply_monthly_lps", []) as Array):
		prof_sum += float(v)
	# The LIVE supply belongs here too. Without it, dragging the Lab's test flow
	# changed every physics number but left the estimate, the chart and the
	# per-size stats frozen — the single loudest "nothing updates" symptom.
	# Quantised: under live rain the engine re-stamps the supply by fractions
	# of a mL/s every tick, and at 4 decimals that reran the annual estimate
	# (12 Pelton solves) and the curve families at 6 Hz.
	est_sig += "|%.1f|%.2f" % [prof_sum,
		float(sim_specs.get("supply_lps", -1.0))]
	est["gross_head_m"] = gross
	# design_flow 0 means UNLIMITED for a nozzle kind (the nozzle is the flow
	# control), so flooring it at 0.01 pinned the whole estimate to a 0.01 L/s
	# supply and returned ~0 W — the PowerSpout's power curve was flat zero
	# whenever its (hidden) design-flow spin sat at 0, which is its default.
	# Only design-flow kinds, where 0 really does mean "no flow", get the floor.
	var design_in := float(_design_flow_spin.value) if _design_flow_spin != null else 0.0
	if _kind_uses_nozzle():
		est["design_flow_lps"] = maxf(design_in, 0.0)
	else:
		est["design_flow_lps"] = maxf(design_in, 0.01)
	est["penstock_length_m"] = float(_penstock_len_spin.value) if _penstock_len_spin != null else 60.0
	est["penstock_diameter_mm"] = float(_penstock_d_spin.value) if _penstock_d_spin != null else 63.0
	if _roughness_spin != null:
		est["pipe_roughness_mm"] = float(_roughness_spin.value) / 1000.0
	if _turb_eff_spin != null and float(_turb_eff_spin.value) > 0.0:
		est["turbine_efficiency"] = float(_turb_eff_spin.value)
	# The annual closed form is 12 power evaluations and nothing about it is live
	# telemetry, so it runs only when a design input actually moved — it used to
	# recompute at the full 6 Hz physics rate.
	if est_sig != _est_sig:
		_est_sig = est_sig
		var mults: Array = []
		var ws := _weather_service()
		if ws != null and ws.has_method("monthly_precip_multipliers"):
			mults = ws.call("monthly_precip_multipliers") as Array
		# A stream intake's supply VARIES over the year. Without the monthly curve
		# every month reuses the one instantaneous supply the engine last stamped,
		# so the annual figure reads whatever the spring happened to be doing when
		# the panel opened.
		var supply_prof: Array = []
		var prof_v: Variant = sim_specs.get("supply_monthly_lps", null)
		if prof_v is PackedFloat32Array:
			supply_prof = Array(prof_v as PackedFloat32Array)
		elif prof_v is Array:
			supply_prof = prof_v as Array
		var ann := HydroSource.annual_energy_kwh_from_specs(est, mults, supply_prof)
		var mean_kw := float(ann.get("mean_kw", 0.0))
		var nameplate_w := float(sim_specs.get("max_power_w", 0.0))
		if nameplate_w > 0.0:
			_capfac_lbl.text = "%.0f%%" % clampf(mean_kw * 1000.0 / nameplate_w * 100.0, 0.0, 100.0)
		else:
			_capfac_lbl.text = "n/a (no nameplate)"
		_annual_lbl.text = "%.0f kWh/yr" % float(ann.get("annual_kwh", 0.0))
		_refresh_firm_flow(est, supply_prof, ann)
		_sens_text = _sensitivity_text(est, gross)
		if supply_prof.size() == 12:
			var lo := 1e30
			var hi := -1e30
			for v: Variant in supply_prof:
				lo = minf(lo, float(v))
				hi = maxf(hi, float(v))
			_estimate_hint_lbl.text = "Representative-year estimate from the intake's SEASONAL supply (%.2f–%.2f L/s over the year), not today's flow." % [lo, hi]
		else:
			_estimate_hint_lbl.text = "Representative-year estimate at continuous flow (Q capped by pipe + design flow); seasonal precipitation weights the monthly flow."
	# Always: the chart's OPERATING-POINT MARKER is live telemetry. The curve
	# itself carries its own _chart_sig gate.
	_refresh_power_chart(est, gross)


## Warnings row under Live readouts — the "is this design sane" glance:
##  - head outside the turbine kind's published band (KINDS head_band);
##  - penstock friction eating > 30% of gross head — standard micro-hydro
##    sizing guidance keeps pipe loss in the 10–30% range (Thake; upsizing the
##    pipe is the fix);
##  - penstock velocity > 3 m/s — common PE-penstock design ceiling before
##    surge/wear costs outweigh the pipe savings.
func _refresh_warnings() -> void:
	if _warn_lbl == null:
		return
	var warns := PackedStringArray()
	var fit_mm := 0.0   ## recommended nozzle Ø (mm); 0 = nothing to recommend
	var kind := _current_kind()
	var meta := HydroSource.kind_meta(kind)
	var gross := float(_last_r.get("head_m", 0.0))
	var band: Array = meta.get("head_band", []) as Array
	if gross > 0.05 and band.size() == 2:
		if gross < float(band[0]) * 0.95:
			warns.append("⚠ %.1f m head is below %s's %.0f–%.0f m band — expect poor output."
					% [gross, str(meta.get("display", kind)), float(band[0]), float(band[1])])
		elif gross > float(band[1]) * 1.05:
			warns.append("⚠ %.1f m head is above %s's %.0f–%.0f m band."
					% [gross, str(meta.get("display", kind)), float(band[0]), float(band[1])])
	if str(_last_r.get("conveyance", "")) == "penstock" and gross > 0.05:
		var loss := float(_last_r.get("head_loss_m", 0.0))
		if loss / gross > 0.30:
			warns.append("⚠ Pipe undersized — friction eats %.0f%% of the head (keep it under ~30%%: shorter run or fatter Ø)."
					% (loss / gross * 100.0))
		var q_m3s := float(_last_r.get("q_lps", 0.0)) / 1000.0
		var d := maxf(float(_penstock_d_spin.value) if _penstock_d_spin != null else 63.0, 1.0) / 1000.0
		var v := q_m3s / (PI * 0.25 * d * d)
		if v > 3.0:
			warns.append("⚠ Penstock velocity %.1f m/s (> 3 m/s guideline) — upsize the pipe." % v)
		# Supply-limited: the jet is bigger than the stream can feed, so most of the
		# head never becomes jet velocity. The fix is a SMALLER nozzle, which is
		# unintuitive enough that the Lab should just name the size.
		if bool(_last_r.get("supply_limited", false)):
			var unused := float(_last_r.get("unused_head_m", 0.0))
			var supply := float(_last_r.get("q_lps", 0.0))
			var msg := "⚠ Nozzle oversized for this supply — only %.1f m of the %.1f m head is converted." \
					% [float(_last_r.get("net_head_m", 0.0)), gross]
			if bool(HydroSource.kind_meta(kind).get("uses_nozzle_model", false)) \
					and supply > 1e-6 and unused > 0.05:
				var d_fit := PeltonPhysics.nozzle_d_for_supply_m(gross,
						float(_penstock_len_spin.value) if _penstock_len_spin != null else 60.0,
						d, maxf(float(_roughness_spin.value) / 1000.0 if _roughness_spin != null else 0.0015, 0.0) / 1000.0,
						int(_nozzle_count_spin.value) if _nozzle_count_spin != null else 1,
						supply / 1000.0)
				if d_fit > 0.0:
					msg += " A %.1f mm nozzle would match %.2f L/s." % [d_fit * 1000.0, supply]
					fit_mm = d_fit * 1000.0
			warns.append(msg)
	if str(_last_r.get("regime", "")) == "no_supply":
		warns.append("⚠ The source is dry — no flow at the intake. Set a base flow on the intake node, raise the test flow, or wait for rain.")
	_warn_lbl.visible = not warns.is_empty()
	_warn_lbl.text = "\n".join(warns)
	_fit_nozzle_mm = fit_mm
	if _fit_nozzle_btn != null and _nozzle_d_spin != null:
		# Offer — and LABEL — the size that will actually be written: the spin
		# steps by 0.5 mm, so promising 6.6 and delivering 6.5 would be a lie the
		# player can read straight off the control.
		var step := maxf(_nozzle_d_spin.step, 0.01)
		var snapped := clampf(snappedf(fit_mm, step),
				_nozzle_d_spin.min_value, _nozzle_d_spin.max_value)
		var cur_mm := float(_nozzle_d_spin.value)
		_fit_nozzle_btn.visible = fit_mm > 0.0 and absf(snapped - cur_mm) > step * 0.5
		if _fit_nozzle_btn.visible:
			_fit_nozzle_btn.text = "Fit the %.1f mm nozzle" % snapped
			_fit_nozzle_btn.tooltip_text = ("Sets Nozzle Ø to %.1f mm — the jet "
					+ "this supply can actually feed, so the head goes into "
					+ "velocity instead of being left unconverted.") % snapped


## Power-curve chart: P vs gross head for the four poly sizes (plus the current
## Ø when it matches none), operating point marked. Curve recompute is gated on
## a parameter signature; the marker alone follows the live pond level.
func _refresh_power_chart(est: Dictionary, gross: float) -> void:
	if _chart == null or not _kind_has_penstock():
		return
	var marker := Vector2(gross, float(_last_r.get("power_w", 0.0)))
	var base := est.duplicate(true)
	# Nameplate curve, not a seasonal sample: flat multipliers so the chart
	# answers "what does this HARDWARE do at head X".
	base["monthly_flow_multipliers"] = [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]
	# The per-size curves are a HARDWARE comparison — "what would a fatter pipe
	# buy me". A live stream supply is a property of the SITE, not the pipe, and
	# leaving it in made every size return the identical number (Q = supply and
	# h_jet = nozzle_head_required(supply) regardless of bore), so four curves
	# drew on top of each other and the comparison silently said "nothing". The
	# supply gets its own curve below instead, which is the honest way to show it.
	var supply_lps := float(base.get("supply_lps", NAN)) if base.has("supply_lps") else NAN
	base.erase("supply_lps")
	base.erase("supply_monthly_lps")
	var x_max := clampf(maxf(gross * 1.6, 15.0), 10.0, 200.0)
	var cur_d := float(base.get("penstock_diameter_mm", 63.0))
	var sig := "%s|%.1f|%.2f|%.3f|%.2f|%s|%s|%.1f|%.0f|%.1f|%.3f" % [
		str(base.get("turbine_kind", base.get("kind", ""))),
		float(base.get("penstock_length_m", 0.0)),
		cur_d,
		float(base.get("design_flow_lps", 0.0)),
		float(base.get("generator_efficiency", 0.85)),
		str(base.get("nozzle_count", "")), str(base.get("nozzle_diameter_mm", "")),
		float(base.get("turbine_efficiency", 0.0)),
		float(base.get("max_power_w", 0.0)),
		x_max,
		# Supply is in the signature even though the size curves exclude it —
		# the supply curve below depends on it, and dragging the Lab's test flow
		# has to redraw the chart. Its absence here is why the test slider looked
		# inert. Snapped to 0.01 L/s so live rain does not redraw every tick.
		0.0 if is_nan(supply_lps) else snappedf(supply_lps, 0.01),
	]
	if sig == _chart_sig:
		if _chart.has_method("set_marker"):
			_chart.call("set_marker", marker)
		_refresh_chart_stats(est, gross)
		return
	_chart_sig = sig
	var sizes: Array = ConduitKinds.pipe_kit_sizes_in("poly_penstock")
	var curves: Array = []
	var cur_matches_listed := false
	for i in sizes.size():
		var sz := float(sizes[i])
		var id_mm := ConduitKinds.inner_diameter_for("poly_penstock",
				{"pipe_size_in": sz}) * 1000.0
		if absf(id_mm - cur_d) < 0.6:
			cur_matches_listed = true
		var s2 := base.duplicate(true)
		s2["penstock_diameter_mm"] = id_mm
		curves.append({
			"label": "%s poly" % PipeKit.size_label(sz),
			"color": _CHART_SIZE_COLORS[i % _CHART_SIZE_COLORS.size()],
			"pts": _power_curve_pts(s2, x_max),
		})
	if not cur_matches_listed:
		curves.push_front({
			"label": "current Ø %.0f mm" % cur_d,
			"color": Color(0.92, 0.94, 0.98),
			"pts": _power_curve_pts(base, x_max),
		})
	# What the SOURCE actually allows, on the current pipe. The gap between this
	# and the size curves above is the whole story for a supply-limited machine:
	# the pipe is not the limit, the spring is — and no amount of fatter pipe
	# closes it. Drawn last so it reads as the ceiling over the family.
	if not is_nan(supply_lps) and supply_lps > 1e-6:
		var s_sup := base.duplicate(true)
		s_sup["supply_lps"] = supply_lps
		curves.append({
			"label": "at your supply (%.2f L/s)" % supply_lps,
			"color": Color(1.0, 0.72, 0.30),
			"pts": _power_curve_pts(s_sup, x_max),
		})
	if _chart.has_method("set_data"):
		_chart.call("set_data", curves, marker)
	# Stats stay SUPPLY-AWARE: "what would a fatter pipe buy me" has to answer
	# honestly, and when the spring is the limit the honest answer is "nothing".
	_refresh_chart_stats(est, gross)


func _power_curve_pts(specs: Dictionary, x_max: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	const N := 24
	for i in range(1, N + 1):
		var h := x_max * float(i) / float(N)
		var s := specs.duplicate(true)
		s["gross_head_m"] = h
		pts.append(Vector2(h, HydroSource.power_kw_from_graph_specs(s, 6, []) * 1000.0))
	return pts


## Per-size watts at the CURRENT head — the one-line "what would a fatter pipe
## buy me" answer under the chart.
func _refresh_chart_stats(base: Dictionary, gross: float) -> void:
	if _chart_stats_lbl == null:
		return
	if gross <= 0.05:
		_stats_sig = ""
		_chart_stats_lbl.text = "No head yet — raise the pond or lower the turbine."
		return
	# One power evaluation per listed pipe size. Sat OUTSIDE the chart's own gate,
	# so it ran on every 6 Hz physics tick even when the curve was cached.
	var stats_sig := "%s|%.2f" % [_chart_sig, snappedf(gross, 0.05)]
	if stats_sig == _stats_sig:
		return
	_stats_sig = stats_sig
	var parts := PackedStringArray()
	var lo := 1e30
	var hi := -1e30
	for sz: Variant in ConduitKinds.pipe_kit_sizes_in("poly_penstock"):
		var s2 := base.duplicate(true)
		s2["gross_head_m"] = gross
		s2["penstock_diameter_mm"] = ConduitKinds.inner_diameter_for(
				"poly_penstock", {"pipe_size_in": float(sz)}) * 1000.0
		var w := HydroSource.power_kw_from_graph_specs(s2, 6, []) * 1000.0
		lo = minf(lo, w)
		hi = maxf(hi, w)
		parts.append("%s %.0fW" % [PipeKit.size_label(float(sz)), w])
	var txt := "At %.1f m head: %s" % [gross, " · ".join(parts)]
	# When every size returns the same number the pipe is NOT the constraint, and
	# saying so is more useful than four identical figures the player has to
	# notice are identical.
	if hi > 0.0 and (hi - lo) < maxf(hi * 0.02, 0.5):
		txt += "  — pipe size makes no difference here; the source flow is the limit."
	_chart_stats_lbl.text = txt


# ---------------------------------------------------------------------------
# Stat deck — the operating point as a causal chain (scenes/ui/hydro_stat_deck.gd)
# ---------------------------------------------------------------------------

const PSI_PER_M := 1.42197      ## water column: 0.433 psi per foot = 1.422 psi per metre
const BAR_PER_M := 0.0980665    ## ρ·g per metre of water, in bar


func _fmt_lps(q: float) -> String:
	if q >= 100.0:
		return "%.0f" % q
	if q >= 10.0:
		return "%.1f" % q
	if q >= 0.1:
		return "%.2f" % q
	return "%.3f" % q


## Watts as [value, unit] for a tile, or joined for prose.
func _fmt_w_pair(w: float) -> Array:
	if w >= 10000.0:
		return ["%.1f" % (w / 1000.0), "kW"]
	if w >= 1000.0:
		return ["%.2f" % (w / 1000.0), "kW"]
	if w >= 100.0:
		return ["%.0f" % w, "W"]
	if w >= 10.0:
		return ["%.1f" % w, "W"]
	return ["%.2f" % w, "W"]


func _fmt_watts(w: float) -> String:
	var p := _fmt_w_pair(w)
	return "%s %s" % [p[0], p[1]]


func _fmt_delta_w(dw: float) -> String:
	if absf(dw) < 0.05:
		return "no change"
	return "%s%s" % ["+" if dw > 0.0 else "−", _fmt_watts(absf(dw))]


## "What moves the needle": the output's response to one step on each lever,
## from the SAME closed form the annual estimate and the power chart use. Runs
## inside the estimate's signature gate (five evaluations per design change,
## never per tick). A lever that reads "no change" IS the finding — at the
## nameplate, or when the source is the limit, more head buys nothing.
func _sensitivity_text(est: Dictionary, gross: float) -> String:
	if gross <= 0.05:
		return ""
	var base := est.duplicate(true)
	base["gross_head_m"] = gross
	var w0 := HydroSource.power_kw_from_graph_specs(base, 6, []) * 1000.0
	var parts := PackedStringArray()
	var s1 := base.duplicate(true)
	s1["gross_head_m"] = gross + 1.0
	parts.append("+1 m head → %s" % _fmt_delta_w(
			HydroSource.power_kw_from_graph_specs(s1, 6, []) * 1000.0 - w0))
	if _kind_uses_nozzle():
		var meta := HydroSource.kind_meta(_current_kind())
		var d0 := float(base.get("nozzle_diameter_mm", float(meta.get("default_nozzle_mm", 10.0))))
		var s2 := base.duplicate(true)
		s2["nozzle_diameter_mm"] = d0 + 1.0
		parts.append("+1 mm jet → %s" % _fmt_delta_w(
				HydroSource.power_kw_from_graph_specs(s2, 6, []) * 1000.0 - w0))
	else:
		var q0 := float(base.get("design_flow_lps", 0.0))
		if q0 > 0.0:
			var s2b := base.duplicate(true)
			s2b["design_flow_lps"] = q0 * 1.25
			parts.append("+25%% flow → %s" % _fmt_delta_w(
					HydroSource.power_kw_from_graph_specs(s2b, 6, []) * 1000.0 - w0))
	if base.has("supply_lps") and float(base.get("supply_lps", -1.0)) >= 0.0:
		var s3 := base.duplicate(true)
		s3["supply_lps"] = float(base["supply_lps"]) + 0.5
		parts.append("+0.5 L/s source → %s" % _fmt_delta_w(
				HydroSource.power_kw_from_graph_specs(s3, 6, []) * 1000.0 - w0))
	var cur_d := float(base.get("penstock_diameter_mm", 63.0))
	var next_id := -1.0
	for sz: Variant in ConduitKinds.pipe_kit_sizes_in("poly_penstock"):
		var id_mm := ConduitKinds.inner_diameter_for("poly_penstock",
				{"pipe_size_in": float(sz)}) * 1000.0
		if id_mm > cur_d + 0.6 and (next_id < 0.0 or id_mm < next_id):
			next_id = id_mm
	if next_id > 0.0:
		var s4 := base.duplicate(true)
		s4["penstock_diameter_mm"] = next_id
		parts.append("next pipe size → %s" % _fmt_delta_w(
				HydroSource.power_kw_from_graph_specs(s4, 6, []) * 1000.0 - w0))
	if parts.is_empty():
		return ""
	return "What moves the needle:  " + "  ·  ".join(parts)


## Pond balance under the test fill: inflow − the siphon's draw, in L/s and
## in cm/h of surface (prismatic: capacity over the rim−floor span).
func _refresh_net_readout(level_m: float) -> void:
	if _net_lbl == null:
		return
	if _kind_has_penstock() or _sim_inflow_btn == null:
		_net_lbl.text = ""
		return
	var on := _sim_inflow_btn.button_pressed
	var fill := float(_sim_inflow_spin.value) if (_sim_inflow_spin != null and on) else 0.0
	var draw := float(_last_r.get("q_lps", 0.0)) if bool(_last_r.get("primed", false)) else 0.0
	var net := fill - draw
	var pond := _pond_context()
	var floor_m := float(pond.get("floor_m", NAN))
	var rim_m := float(pond.get("rim_m", NAN))
	var rate_txt := ""
	if not is_nan(floor_m) and not is_nan(rim_m) and rim_m > floor_m and _graph_view != null \
			and _graph_view.has_method("resolve_siphon_pond"):
		var tank: Dictionary = _graph_view.call("resolve_siphon_pond", _item_id)
		var cap_l := float((tank.get("specs", {}) as Dictionary).get("capacity_qty", 0.0))
		if cap_l > 1.0:
			var cm_per_h := net * 3600.0 / cap_l * (rim_m - floor_m) * 100.0
			rate_txt = " → surface %+.1f cm/h" % cm_per_h
	var lvl_now := float(pond.get("level_m", NAN))
	var full := not is_nan(lvl_now) and not is_nan(rim_m) and lvl_now >= rim_m - 0.05
	if full and draw <= 0.01:
		# The reason an inflow "does nothing": there is nowhere for it to go.
		_net_lbl.text = "Pond: FULL at its max fill level (%.2f m) — any inflow spills over. Raise the max fill level (Ctrl-aim the pond surface in 3D and drag it up, or Pond settings) so the pond can reach a crest above the rim; or lower the turbine, extend the dip tube, or prime with a pump." % rim_m
		_net_lbl.add_theme_color_override("font_color", C_WARN)
		return
	if not on:
		_net_lbl.text = "Pond: the siphon draws %.1f L/s%s. Turn on the test inflow, or fill the pond to the prime level." % [
				draw, rate_txt] if draw > 0.01 else "Pond: still (nothing flowing)."
	else:
		_net_lbl.text = "Pond: inflow %.1f − siphon draw %.1f = net %+.1f L/s%s" % [fill, draw, net, rate_txt]
		if net < -0.01 and draw > 0.01:
			_net_lbl.text += " — the fill cannot keep up; the level falls until the siphon breaks."
	_net_lbl.add_theme_color_override("font_color", C_WARN if (on and net < -0.01 and draw > 0.01) else C_MUTED)


## The siphon's levers, through the same reach the readouts use: a lower exit,
## a fatter draft pipe, a longer dip tube. Gated on a signature (three
## evaluations, each a 48-step bisection — not per tick).
func _siphon_sensitivity_text(sim_specs: Dictionary, level_m: float) -> String:
	if is_nan(level_m) or not bool(_last_r.get("primed", false)):
		return ""
	var out_inv := float(sim_specs.get("outlet_invert_m", NAN))
	if is_nan(out_inv):
		return ""
	var sig := "%.2f|%.2f|%.2f|%.1f|%.2f|%s" % [snappedf(level_m, 0.05), out_inv,
			float(sim_specs.get("dip_tube_length_m", 0.0)), float(sim_specs.get("outlet_diameter_mm", 0.0)),
			float(sim_specs.get("module_elev_m", 0.0)), str(sim_specs.get("siphon_prime_mode", ""))]
	if sig == _siphon_sens_sig and not _sens_text.is_empty():
		return _sens_text
	_siphon_sens_sig = sig
	var w0 := float(_last_r.get("power_w", 0.0))
	var parts := PackedStringArray()
	var s1 := sim_specs.duplicate(true)
	s1["outlet_invert_m"] = out_inv - 0.5
	var r1 := HydroReach.evaluate_specs(level_m, s1)
	var d1 := float(r1.get("power_w", 0.0)) - w0
	parts.append("exit 0.5 m lower → %s%s" % [_fmt_delta_w(d1),
			" (cavitation cap)" if bool(r1.get("cavitating", false)) else ""])
	var d_mm := float(sim_specs.get("outlet_diameter_mm", 203.0))
	var next_mm := 254.0 if d_mm < 250.0 else (305.0 if d_mm < 300.0 else d_mm * 1.25)
	var s2 := sim_specs.duplicate(true)
	s2["outlet_diameter_mm"] = next_mm
	parts.append("%.0f mm draft pipe → %s" % [next_mm,
			_fmt_delta_w(float(HydroReach.evaluate_specs(level_m, s2).get("power_w", 0.0)) - w0)])
	var pond := _pond_context()
	var floor_m := float(pond.get("floor_m", NAN))
	var rim_m := float(pond.get("rim_m", NAN))
	var cap_l := float(pond.get("stock_l", 0.0))
	var brk := float(_last_r.get("break_level_m", NAN))
	if not is_nan(floor_m) and not is_nan(rim_m) and rim_m > floor_m and not is_nan(brk):
		# Prismatic: half a metre of dip tube = that share of the basin.
		var capacity_l := 0.0
		if _graph_view != null and _graph_view.has_method("resolve_siphon_pond"):
			var tank: Dictionary = _graph_view.call("resolve_siphon_pond", _item_id)
			capacity_l = float((tank.get("specs", {}) as Dictionary).get("capacity_qty", 0.0))
		var gain_m := minf(0.5, maxf(brk - floor_m, 0.0))
		var litres := capacity_l * gain_m / (rim_m - floor_m)
		if litres > 1.0:
			parts.append("+0.5 m dip tube → siphons %.0f L more before it breaks" % litres)
	if parts.is_empty():
		return ""
	return "What moves the needle:  " + "  ·  ".join(parts)


## Write the deck from `_last_r` — the same operating point the dock rows and
## the status strip were just written from, in the same refresh.
func _refresh_stat_deck() -> void:
	if _deck == null or not _deck.has_method("set_tiles"):
		return
	var r := _last_r
	var kind := _current_kind()
	var meta := HydroSource.kind_meta(kind)
	var penstock := _kind_has_penstock()
	var nozzle := _kind_uses_nozzle()
	var q := float(r.get("q_lps", 0.0))
	var gross := maxf(float(r.get("head_m", 0.0)), 0.0)
	var loss := maxf(float(r.get("head_loss_m", 0.0)), 0.0)
	var net := float(r.get("net_head_m", NAN))
	if is_nan(net):
		net = maxf(gross - loss, 0.0)
	var supply := float(r.get("q_supply_lps", NAN))
	var cap := float(r.get("q_capacity_lps", NAN))
	var power := maxf(float(r.get("power_w", 0.0)), 0.0)
	var pe := maxf(float(r.get("pe_w", 0.0)), 0.0)
	var rpm := maxf(float(r.get("rpm", 0.0)), 0.0)
	var primed := bool(r.get("primed", false))
	var regime := str(r.get("regime", ""))
	var limited := bool(r.get("supply_limited", false))
	var flowing := q > 0.01 and (penstock or primed)
	var idle := "muted"
	var band: Array = meta.get("head_band", []) as Array
	var nameplate := float(_last_sim_specs.get("max_power_w", 0.0))
	if nameplate <= 0.0:
		nameplate = maxf(float(meta.get("max_power_w", 0.0)), 0.0)
	var tiles: Array = []

	# 1. FLOW — what runs through the machine, against what the source gives.
	var f_sub := ""
	var f_frac := NAN
	var f_bar := ""
	var f_tone := "ok" if flowing else idle
	if not is_nan(supply):
		f_sub = "%s L/s at the source" % _fmt_lps(supply)
		if supply > 1e-6:
			f_frac = q / supply
			f_bar = "%.0f%% of source" % (clampf(f_frac, 0.0, 1.0) * 100.0)
		if limited:
			f_tone = "warn"
			f_bar = "all the source"
	elif not is_nan(cap) and cap > 1e-6:
		f_sub = "%s L/s pipe can pass" % _fmt_lps(cap)
		f_frac = q / cap
		f_bar = "%.0f%% of pipe" % (clampf(f_frac, 0.0, 1.0) * 100.0)
	if regime == "no_supply":
		f_sub = "the source is dry"
		f_tone = "bad"
	tiles.append({"key": "flow", "label": "Flow", "value": _fmt_lps(q), "unit": "L/s",
		"sub": f_sub, "frac": f_frac, "bar_text": f_bar, "tone": f_tone,
		"tip": ("Q — the water through the machine. A nozzle passes Q = n·A·v at its head; "
			+ "the source caps it. Supply-limited means the stream, not the jet, sets Q.")})

	# 2. NET HEAD — the gross drop, less what the pipe takes.
	var h_tone := "ok" if gross > 0.05 else idle
	var loss_pct := (loss / gross * 100.0) if gross > 0.05 else 0.0
	if gross > 0.05 and loss / gross > 0.30:
		h_tone = "warn"
	if gross > 0.05 and band.size() == 2 and gross < float(band[0]) * 0.95:
		h_tone = "warn"
	var h_sub := "no drop to the turbine"
	if gross > 0.05:
		h_sub = "%.1f m gross − %.1f m friction" % [gross, loss]
	if limited:
		h_sub = "%.1f m gross · %.1f m unused" % [gross,
				maxf(float(r.get("unused_head_m", 0.0)), 0.0)]
	tiles.append({"key": "head", "label": "Net head", "value": "%.1f" % net, "unit": "m",
		"sub": h_sub, "frac": (net / gross) if gross > 0.05 else NAN,
		"bar_text": ("%.0f%% reaches jet" % (net / gross * 100.0)) if gross > 0.05 else "",
		"tone": h_tone,
		"tip": ("Gross head is the drop from the water surface (or intake) to the turbine. "
			+ "Friction in the penstock (∝ v², so ∝ Q²) takes its share first; what is left is "
			+ "the net head the jet is made from. Keep the loss under ~30 %: a fatter pipe or "
			+ "a shorter run.")})

	# 3. PRESSURE — penstock kinds: static (valve shut) vs the pipe's rating,
	#    and what remains at the jet after friction.
	if penstock:
		var static_psi := gross * PSI_PER_M
		var jet_psi := net * PSI_PER_M
		var rating := _last_rating_psi
		var p_tone := "ok" if gross > 0.05 else idle
		var p_frac := NAN
		var p_bar := ""
		var p_sub := "%.0f psi static (%.1f bar), valve shut" % [static_psi, gross * BAR_PER_M]
		if not is_nan(rating) and rating > 0.0:
			p_frac = static_psi / rating
			p_sub = "%.0f psi static · pipe rated %.0f" % [static_psi, rating]
			p_bar = "%.0f%% of rating" % (p_frac * 100.0)
			if p_frac > 1.0:
				p_tone = "bad"
			elif p_frac > 0.8:
				p_tone = "warn"
		tiles.append({"key": "pressure", "label": "Pressure", "value": "%.0f" % jet_psi,
			"unit": "psi at jet", "sub": p_sub, "frac": p_frac, "bar_text": p_bar,
			"tone": p_tone,
			"tip": ("Water-column pressure: 1.42 psi per metre of head (0.433 psi/ft). STATIC is "
				+ "the shut-valve pressure the pipe must hold — compare it with the SDR rating. "
				+ "At the jet, after friction, the pressure becomes velocity: v = 0.97·√(2g·h).")})

	# 4. JET — nozzle kinds: the jet the nozzle makes, and whether the source
	#    can keep it fed.
	if nozzle:
		var noz_d := maxf(float(_nozzle_d_spin.value) if _nozzle_d_spin != null
				else float(meta.get("default_nozzle_mm", 10.0)), 0.5)
		var noz_n := maxi(int(_nozzle_count_spin.value) if _nozzle_count_spin != null else 1, 1)
		var v_jet := float(r.get("v_jet_ms", NAN))
		if is_nan(v_jet):
			v_jet = PeltonPhysics.jet_velocity_ms(net)
		var demand_lps := PeltonPhysics.nozzle_flow_m3s(maxf(gross - loss, 0.0),
				noz_d / 1000.0, noz_n) * 1000.0
		var j_tone := "ok" if flowing else idle
		var j_frac := NAN
		var j_bar := ""
		if demand_lps > 1e-6 and gross > 0.05:
			j_frac = q / demand_lps
			j_bar = "%.0f%% fed" % (clampf(j_frac, 0.0, 1.0) * 100.0)
			if limited:
				j_tone = "warn"
			elif flowing:
				j_bar = "fully fed"
		var j_sub := "%s L/s wanted · %d × %.1f mm" % [_fmt_lps(demand_lps), noz_n, noz_d]
		tiles.append({"key": "jet", "label": "Jet", "value": "%.1f" % v_jet, "unit": "m/s",
			"sub": j_sub, "frac": j_frac, "bar_text": j_bar, "tone": j_tone,
			"tip": ("The nozzle turns pressure into a jet (v = 0.97·√(2g·h_net)) and its area "
				+ "sets how much water the jet carries (Q ∝ d²·√h). A bigger jet wants more "
				+ "water: if the source cannot supply it, the pressure at the jet collapses and "
				+ "head is wasted — a smaller jet keeps the full pressure behind the water you have.")})

	# 4b. LEVEL — siphon kinds: where the pond stands between prime and air break.
	if not penstock:
		var lvl := float(_pond_context().get("level_m", NAN))
		var start := float(_start_spin.value) if _start_spin != null else NAN
		var brk := float(_break_spin.value) if _break_spin != null else NAN
		var l_frac := NAN
		if not is_nan(lvl) and not is_nan(start) and not is_nan(brk) and start > brk:
			l_frac = (lvl - brk) / (start - brk)
		var l_tone := "ok" if primed else ("bad" if regime == "broken" else idle)
		var l_bar := "primed" if primed else ("sucking air" if regime == "broken" else "below prime")
		if regime == "lift_exceeded":
			l_tone = "bad"
			l_bar = "lift too high"
		tiles.append({"key": "level", "label": "Pond level",
			"value": ("%.2f" % lvl) if not is_nan(lvl) else "—", "unit": "m",
			"sub": "primes %.2f · breaks %.2f m" % [start, brk], "frac": l_frac,
			"bar_text": l_bar, "tone": l_tone,
			"tip": ("A siphon runs on the pond's own surface: it starts when the surface reaches "
				+ "the prime level (the crest, or the dip mouth with a pump) and stops when it "
				+ "falls to the dip tube's mouth and sucks air. The gross head is the drop from "
				+ "the surface to the draft exit — the crest's height costs pressure, not head.")})
		# SUCTION — the runner's outlet against the cavitation limit: the
		# tile that answers "how low is the exit worth running".
		var suction := float(r.get("suction_m", 0.0))
		var s_max := float(r.get("suction_max_m", 0.0))
		var cav := bool(r.get("cavitating", false))
		var crest_abs := float(r.get("crest_abs_m", 0.0))
		var su_tone := idle
		var su_frac := NAN
		var su_bar := ""
		var su_sub := "%.1f m crest above the pond" % float(r.get("lift_m", 0.0))
		if flowing and s_max > 1e-6:
			su_frac = suction / s_max
			su_tone = "bad" if cav else ("warn" if su_frac > 0.85 else "ok")
			su_bar = ("%.1f m wasted" % float(r.get("draft_excess_m", 0.0))) if cav \
					else "%.0f%% of limit" % (su_frac * 100.0)
			su_sub = "%.1f m limit · crest %.1f m abs" % [s_max, crest_abs]
		elif regime == "lift_exceeded":
			su_tone = "bad"
			su_sub = "%.1f m lift · %.1f m abs: air comes out" % [float(r.get("lift_m", 0.0)), crest_abs]
		tiles.append({"key": "suction", "label": "Suction at runner", "value": "%.1f" % suction, "unit": "m",
			"sub": su_sub, "frac": su_frac, "bar_text": su_bar, "tone": su_tone,
			"tip": ("The draft pipe below the runner pulls its outlet under atmospheric pressure "
				+ "by the drop less the pipe losses. Atmosphere is only ~10 m of water: once the "
				+ "outlet reaches vapour pressure (Thoma, σ·h_t) the column separates and any "
				+ "further exit drop is wasted. The crest side has the same limit the other way — "
				+ "a crest more than ~7–8 m above the pond cannot hold a siphon.")})

	# 5. SPEED — the runner against runaway.
	var s_sub := "standing still"
	var s_frac := NAN
	var s_bar := ""
	if nozzle and rpm > 0.5:
		var runaway := rpm / PeltonPhysics.SPEED_RATIO_OPT
		s_sub = "%.0f rpm at runaway" % runaway
		s_frac = PeltonPhysics.SPEED_RATIO_OPT
		s_bar = "matched load"
	elif rpm > 0.5:
		s_sub = "rotor curve at this flow"
	tiles.append({"key": "speed", "label": "Speed", "value": "%.0f" % rpm, "unit": "rpm",
		"sub": s_sub, "frac": s_frac, "bar_text": s_bar, "tone": "ok" if rpm > 0.5 else idle,
		"tip": ("A Pelton runner is most efficient with the buckets moving at ~46 % of the jet "
			+ "speed (u = 0.46·v). Shed the electrical load and it accelerates toward runaway at "
			+ "about twice that, making nothing — the close-up's Load slider shows it. "
			+ "rpm = 60·u / (π·PCD).")})

	# 6. POWER — against the nameplate, or the hydraulic input.
	var pw := _fmt_w_pair(power)
	var eta := (power / pe) if pe > 1e-6 else 0.0
	var p2_frac := NAN
	var p2_bar := ""
	var p2_tone := "accent" if flowing and power > 0.5 else idle
	var p2_sub := "%s in the water · η %.0f%%" % [_fmt_watts(pe), eta * 100.0]
	if pe <= 1e-6:
		p2_sub = "no water power yet"
	if nameplate > 0.0:
		p2_frac = power / nameplate
		p2_bar = "%.0f%% of %s" % [p2_frac * 100.0, _fmt_watts(nameplate)]
		if flowing and power >= nameplate * 0.98:
			p2_tone = "warn"
			p2_bar = "generator-capped"
	elif pe > 1e-6:
		p2_frac = eta
		p2_bar = "η %.0f%%" % (eta * 100.0)
	tiles.append({"key": "power", "label": "Power", "value": pw[0], "unit": pw[1],
		"sub": p2_sub, "frac": p2_frac, "bar_text": p2_bar, "tone": p2_tone,
		"tip": ("Electrical output: the hydraulic power ρ·g·Q·h_net (water × drop) times the "
			+ "turbine and generator efficiencies, never above the generator's nameplate. More "
			+ "net head raises BOTH the flow a nozzle passes and the energy per litre, so a nozzle "
			+ "kind's power grows as h^1.5.")})
	_deck.call("set_tiles", tiles)

	# The insight: what limits the output RIGHT NOW, and the lever that moves it.
	var ins := ""
	var ins_tone := "muted"
	if regime == "no_supply":
		ins = "The source is dry → nothing flows → nothing turns. Raise the test flow, set a base flow on the intake, or wait for rain."
		ins_tone = "bad"
	elif not penstock and not primed:
		var pump := str(_last_sim_specs.get("siphon_prime_mode", "overflow")) == "pump"
		var lvl_now := float(_pond_context().get("level_m", NAN))
		if regime == "broken":
			ins = "Broken: the pond fell to the dip tube's mouth at %.2f m and the siphon sucked air. Extend the dip tube to run lower, or wait for the pond to refill to %.2f m." % [
					float(r.get("break_level_m", float(_break_spin.value) if _break_spin != null else 0.0)),
					float(r.get("prime_level_m", float(_start_spin.value) if _start_spin != null else 0.0))]
			ins_tone = "bad"
		elif regime == "no_head":
			ins = "The draft exit is not below the pond — there is no head to drive the siphon. Trace the exit further downhill."
			ins_tone = "bad"
		elif pump:
			ins = "Not primed: the dip tube's mouth is out of the water (pump priming runs as soon as it is a bore under). Extend the tube or let the pond rise."
		else:
			var prime_now := float(r.get("prime_level_m", float(_start_spin.value) if _start_spin != null else 0.0))
			var rim_now := float(_pond_context().get("rim_m", NAN))
			if not is_nan(rim_now) and prime_now > rim_now - 0.02:
				ins = "The crest at %.2f m stands ABOVE the pond's rim at %.2f m — the pond would spill before it reached it, so an overflow prime can never happen here. Switch Priming to a vacuum pump (or lower the turbine below the rim)." % [prime_now, rim_now]
				ins_tone = "bad"
			else:
				ins = "Not primed: the pond must rise to the crest at %.2f m%s to spill into the draft pipe — or switch Priming to a vacuum pump and it runs once the dip tube is under water." % [
						prime_now, ("" if is_nan(lvl_now) else " (it is at %.2f)" % lvl_now)]
	elif not penstock and regime == "lift_exceeded":
		ins = "Lift too high: the crest sits %.1f m above the pond and the air there is at %.1f m absolute — the column lets go. Lower the turbine or raise the pond." % [
				float(r.get("lift_m", 0.0)), float(r.get("crest_abs_m", 0.0))]
		ins_tone = "bad"
	elif not penstock and bool(r.get("cavitating", false)):
		ins = "Suction-limited: the runner's outlet is at vapour pressure. The bottom %.1f m of the draft pipe does nothing — the useful exit is %.1f m below the runner; the rest only adds pipe." % [
				float(r.get("draft_excess_m", 0.0)), float(r.get("useful_draft_m", 0.0))]
		ins_tone = "warn"
	elif penstock and gross <= 0.05:
		ins = "No head: the turbine sits level with or above its source. Lower the turbine or tap water higher up — every metre of drop is 1.42 psi at the nozzle."
		ins_tone = "bad"
	elif penstock and q <= 0.01:
		ins = "No flow reaches the turbine at this head — check the source and the penstock route."
	elif limited:
		var noz_d2 := float(_nozzle_d_spin.value) if _nozzle_d_spin != null else 0.0
		var noz_n2 := int(_nozzle_count_spin.value) if _nozzle_count_spin != null else 1
		var demand2 := PeltonPhysics.nozzle_flow_m3s(maxf(gross - loss, 0.0),
				maxf(noz_d2, 0.5) / 1000.0, maxi(noz_n2, 1)) * 1000.0
		ins = "Source-limited: the source runs %s L/s but the %d × %.1f mm jet could pass %s L/s — only %.1f of %.1f m head turns into jet speed." % [
				_fmt_lps(q), maxi(noz_n2, 1), noz_d2, _fmt_lps(demand2), net, gross]
		if _fit_nozzle_mm > 0.0:
			ins += " A %.1f mm nozzle puts the full head behind the water you have." % _fit_nozzle_mm
		ins_tone = "warn"
	elif gross > 0.05 and loss / gross > 0.30:
		if nozzle:
			ins = "Pipe-limited: friction takes %.0f%% of the head before the nozzle sees it (loss ∝ Q²). A fatter pipe or a shorter run puts more pressure at the jet." % loss_pct
		else:
			ins = "Pipe-limited: friction in the dip tube and draft pipe takes %.0f%% of the head before the runner sees it (loss ∝ Q²). A fatter or shorter pipe leaves more for the runner." % loss_pct
		ins_tone = "warn"
	elif band.size() == 2 and gross > 0.05 and gross < float(band[0]) * 0.95:
		ins = "%.1f m head is under this turbine's %.0f–%.0f m band — the jet is too slow for the buckets. Find more drop, or pick a low-head machine." % [
				gross, float(band[0]), float(band[1])]
		ins_tone = "warn"
	elif nameplate > 0.0 and flowing and power >= nameplate * 0.98:
		ins = "Generator-capped at the %.0f W nameplate: the water could give more. A smaller nozzle saves water for the dry months at the same output." % nameplate
		ins_tone = "ok"
	elif nozzle:
		ins = "Nozzle-governed: more head → a faster jet (v ∝ √h) → more flow through the same jet → power ∝ h^1.5. A bigger jet buys flow until the source or the pipe runs out."
		ins_tone = "ok"
	elif penstock:
		ins = "Flow-governed: P = η·ρ·g·Q·h_net — more flow or more net head, linearly. Friction grows with Q², so a fatter pipe pays off fastest at high flow."
		ins_tone = "ok"
	else:
		ins = "Siphoning: %.1f m gross, the runner sees %.1f m after %.1f m of pipe and exit losses. A lower exit adds head until the suction limit (%.1f m) caps it; the pond draws down to the dip mouth." % [
				gross, float(r.get("turbine_head_m", net)), loss, float(r.get("suction_max_m", 0.0))]
		ins_tone = "ok"
	_deck.call("set_insight", ins, ins_tone)
	_deck.call("set_sensitivity", _sens_text)


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


## Drop the cached slice frame. The pond POLYGON is deliberately not part of the
## cache signature (it would mean re-projecting the basin just to decide whether
## to re-project the basin), so a re-carve or a rebind must say so explicitly.
func _invalidate_slice_cache() -> void:
	_slice_sig = ""
	_slice_cache.clear()


func _slice_frame(pond: Dictionary) -> Dictionary:
	## Pond-relative along window on the Elevation CT plane (shared heading/offset).
	## half_w from full basin poly span when available (not footprint-only).
	##
	## CACHED: this runs from _draw_preview (12 Hz), from _lab_view_metrics, AND
	## from every mouse-move during a pan and every wheel notch — while calling an
	## uncached terrain pond lookup plus a full basin-polygon projection.
	var half_w := 4.0
	var module_along := 3.5
	var params := _elev_section_params()
	var heading := float(params.get("heading", 0.0))
	var offset := float(params.get("offset", 0.0))
	var pond_site := pond.get("site", Vector2.ZERO) as Vector2
	var sig := "%s|%.5f|%.3f|%.3f|%.3f" % [_item_id, heading, offset,
			pond_site.x, pond_site.y]
	if sig == _slice_sig and not _slice_cache.is_empty():
		return _slice_cache
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
	_slice_sig = sig
	_slice_cache = {
		"heading": heading,
		"offset": offset,
		"half_w": half_w,
		"module_along": module_along,
		"along0": along0,
		"along1": along1,
		"pond_site": pond_site,
	}
	return _slice_cache


## Along-axis offset of the POND on the section plane.
##
## This overlay draws everything in POND-RELATIVE along — `_ensure_dem_bake`
## subtracts this from the terrain profile, and `along_mid` is the metrics'
## `along_m_rel`. So anything derived from an ABSOLUTE site coordinate
## (`GraphSiteLayout.project_onto_section`) must subtract it as well.
##
## Getting that wrong does not look like a horizontal error: on sloping ground a
## sideways shift puts the element against a different part of the terrain
## profile, which reads as the penstock FLOATING several metres above the ground
## it is lying on — while 3D, which never goes through here, looks correct.
func _pond_along_m() -> float:
	var frame := _slice_frame(_pond_context())
	var heading := float(frame.get("heading", 0.0))
	return (frame.get("pond_site", Vector2.ZERO) as Vector2) \
			.dot(Vector2(cos(heading), sin(heading)))


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
	_view_pan_m = Vector2.ZERO
	_view_dragging = false
	_grab_kind = ""


func _view_tab(parent: Control, text: String, tip: String, mode: String) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.toggle_mode = true
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(func() -> void: _set_lab_view(mode))
	parent.add_child(b)
	return b


## Switch between the cross-section and the turbine close-up.
func _set_lab_view(mode: String) -> void:
	_lab_view = mode
	var closeup := mode == VIEW_CLOSEUP
	if _tab_section_btn != null:
		_tab_section_btn.set_pressed_no_signal(not closeup)
	if _tab_closeup_btn != null:
		_tab_closeup_btn.set_pressed_no_signal(closeup)
	if _preview != null:
		_preview.visible = not closeup
	if _closeup != null and _closeup.has_method("set_active"):
		_closeup.call("set_active", closeup)
	# The 3D section CT lives BEHIND the 2D overlay in the same stack — hide it
	# while the close-up owns the slot, or two 3D views fight for the same pixels.
	if _graph_view != null and _graph_view.has_method("set_lab_section_ct_visible"):
		_graph_view.call("set_lab_section_ct_visible", not closeup)
	if _load_row != null:
		_load_row.visible = closeup
	_redraw_preview()


## Apply the recommended nozzle. Snapped to the SPIN'S OWN step (real jets come in
## discrete sizes, and the control steps by 0.5 mm) — writing 6.64 would be
## silently rounded by the SpinBox anyway, and then read back as a value the
## player never saw recommended.
func _on_fit_nozzle() -> void:
	if _nozzle_d_spin == null or _fit_nozzle_mm <= 0.0:
		return
	var step := maxf(_nozzle_d_spin.step, 0.01)
	_nozzle_d_spin.value = clampf(snappedf(_fit_nozzle_mm, step),
			_nozzle_d_spin.min_value, _nozzle_d_spin.max_value)
	# Force the gated recomputes: the nozzle is in both signatures, but the
	# warnings + status strip should update on THIS frame, not in a sixth of one.
	_phys_acc = 999.0
	_refresh_physics()


## Harness hook: pin a synthetic operating point so --capture=siphon can shoot the
## jet / splash / speed model on a map whose turbine happens to be dry. Held in its
## own field rather than written into `_last_r`, which the 6 Hz physics refresh
## rewrites from the real reach within a sixth of a second. Pass q_lps <= 0 to clear.
func set_state_for_test(q_lps: float, v_jet_ms: float) -> void:
	if q_lps <= 0.0:
		_test_op = {}
	else:
		var h_net := v_jet_ms * v_jet_ms / (2.0 * 9.80665 * 0.97 * 0.97)
		_test_op = {"q_lps": q_lps, "v_jet_ms": v_jet_ms, "net_head_m": h_net,
			# P = rho g Q h_net · eta_t · eta_g at the matched load.
			"power_w": 1000.0 * 9.80665 * (q_lps / 1000.0) * h_net * 0.65 * 0.85}
	_push_closeup_state()


## Zero every placement knob (the model's own nozzle), one commit each.
func _on_reset_nozzle_placement() -> void:
	_syncing = true
	if _nozzle_off_spin != null:
		_nozzle_off_spin.value = 0.0
	for sb: SpinBox in _nozzle_pose_spins:
		sb.value = 0.0
	_syncing = false
	_commit_float("nozzle_offset_mm", 0.0)
	for sb: SpinBox in _nozzle_pose_spins:
		_commit_float(str(sb.get_meta("spec_key", "")), 0.0)
	_push_nozzle_pose()


## Hand the close-up the whole nozzle placement off the spinboxes (mm → m).
func _push_nozzle_pose() -> void:
	if _closeup == null or not _closeup.has_method("set_nozzle_pose"):
		return
	var pose := {"offset_m": (float(_nozzle_off_spin.value) if _nozzle_off_spin != null else 0.0) / 1000.0}
	for sb: SpinBox in _nozzle_pose_spins:
		var key := str(sb.get_meta("spec_key", ""))
		var ck := str(NOZZLE_POSE_KEYS.get(key, ""))
		if ck.is_empty():
			continue
		pose[ck] = float(sb.value) / 1000.0 if key.ends_with("_mm") else float(sb.value)
	_closeup.call("set_nozzle_pose", pose)


## Feed the close-up the live operating point. Load comes from the slider, but a
## turbine whose DC output is actually being consumed reports its OWN ratio —
## the slider is for experimenting, the real graph wins when there is one.
func _push_closeup_state() -> void:
	if _closeup == null or _lab_view != VIEW_CLOSEUP \
			or not _closeup.has_method("set_state"):
		return
	var meta := HydroSource.kind_meta(_current_kind())
	# The slider decides; its default (100 %) IS what a battery-charging turbine
	# runs at — the regulator (MPPT or a diversion / dump load, which a
	# PowerSpout needs) holds the matched point whatever the battery does. The
	# old "output ÷ nameplate" read a 60 W operating point on a 1.6 kW machine
	# as a 3 % load and spun the close-up toward runaway the moment the turbine
	# was wired to the batteries.
	var load := _load_frac
	var op: Dictionary = _test_op if not _test_op.is_empty() else _last_r
	var siphon_kind := not _kind_has_penstock()
	var lvl_rel := NAN
	if siphon_kind:
		var lvl := float(_pond_context().get("level_m", NAN))
		var mod_e := float(_module_spin.value) if _module_spin != null else NAN
		if not is_nan(lvl) and not is_nan(mod_e):
			lvl_rel = lvl - mod_e
	_closeup.call("set_state", {
		# The machine the kind wears — the close-up swaps its model to match.
		"model_id": str(meta.get("model_id", "powerspout_plt")),
		# SIPHON mode: the propeller in its pipe, the pond's surface relative
		# to the turbine, the dip tube and the draft, the flow through them.
		"kind": "siphon" if siphon_kind else "penstock",
		"level_rel_m": lvl_rel,
		"dip_len_m": float(_dip_len_spin.value) if _dip_len_spin != null else 1.0,
		"dip_d_m": (float(_intake_d_spin.value) if _intake_d_spin != null else 152.0) / 1000.0,
		"draft_d_m": (float(_outlet_d_spin.value) if _outlet_d_spin != null else 203.0) / 1000.0,
		"primed": bool(op.get("primed", false)),
		"regime": str(op.get("regime", "")),
		"turbine_head_m": float(op.get("turbine_head_m", op.get("net_head_m", 0.0))),
		"v_draft_ms": float(op.get("v_draft_ms", 0.0)),
		"suction_m": float(op.get("suction_m", 0.0)),
		"suction_max_m": float(op.get("suction_max_m", 0.0)),
		"cavitating": bool(op.get("cavitating", false)),
		"q_lps": float(op.get("q_lps", 0.0)),
		"h_net_m": float(op.get("net_head_m", 0.0)),
		"v_jet_ms": float(op.get("v_jet_ms", 0.0)),
		"rpm": float(op.get("rpm", 0.0)),
		"nozzle_d_m": maxf(float(_nozzle_d_spin.value)
				if _nozzle_d_spin != null else 10.0, 1.0) / 1000.0,
		"nozzle_n": int(_nozzle_count_spin.value) if _nozzle_count_spin != null else 1,
		"runner_pcd_m": float(meta.get("runner_pcd_m", 0.28)),
		"load_frac": load,
		# Matched-load output — the close-up derates it by the speed-ratio's
		# runner efficiency so shedding load visibly costs watts.
		"power_w": float(op.get("power_w", _last_r.get("power_w", 0.0))),
	})


## Keep the slider tracking the spin, growing its ceiling if the spin is driven
## past it (so a 500 L/s canal still leaves the handle somewhere meaningful).
func _sync_flow_slider_from_spin(v: float) -> void:
	if _sim_inflow_slider == null:
		return
	var was := _syncing
	_syncing = true
	var ceiling := FLOW_SLIDER_MAX_LPS
	if not _kind_has_penstock():
		# A siphon draws tens of L/s; a 20 L/s ceiling could never out-fill
		# it and the slider read as inert. Reach past the current draw.
		ceiling = maxf(200.0, float(_last_r.get("q_lps", 0.0)) * 1.5)
	_sim_inflow_slider.max_value = maxf(ceiling, v)
	_sim_inflow_slider.value = clampf(v, 0.0, _sim_inflow_slider.max_value)
	_syncing = was


## The test-flow control means two different things and must SAY which. On a
## penstock turbine it is the flow the stream/spring is running, before the nozzle
## — no pond required, which is the whole point. On a siphon it is a steady fill
## into the bound pond, as it always was.
func _sync_test_flow_labels() -> void:
	if _sim_inflow_btn == null:
		return
	if _sim_inflow_slider != null and _sim_inflow_spin != null:
		_sync_flow_slider_from_spin(float(_sim_inflow_spin.value))
	if _kind_has_penstock():
		_sim_inflow_btn.text = "Test stream flow at intake (L/s)"
		_sim_inflow_btn.tooltip_text = ("Overrides what the source is running, "
				+ "BEFORE the nozzle. Works with no pond — a spring or creek is a "
				+ "flow, not a reservoir. Updates immediately, even while paused.")
		if _drive_hint_lbl != null:
			_drive_hint_lbl.text = "Simulate the stream at a chosen rate to size the nozzle and read the power. The intake's own Base flow + Rain response (freeform inspector) drive it when this is off."
	else:
		_sim_inflow_btn.text = "Test inflow (steady L/s)"
		_sim_inflow_btn.tooltip_text = ("Constant fill into the bound pond (works "
				+ "while sim is paused / Elev noon-lock). The only manual water driver.")
		if _drive_hint_lbl != null:
			_drive_hint_lbl.text = "Steady fill into the pond, advanced on the world clock. Play / speed up time to watch it prime, then drain (orifice-limited by the barrel)."


## F — back to the default framing, centred on the turbine.
func _on_frame_turbine() -> void:
	_reset_view_transform()
	_push_lab_section_frame()
	_redraw_preview()


## Home — zoom out until the whole intake→turbine run is in frame. On a 90 m
## penstock the default framing shows the turbine and nothing else, so "where did
## my intake go" is the first thing that happens after routing one.
func _on_frame_whole_run() -> void:
	_view_pan_m = Vector2.ZERO
	var frame := _slice_frame(_pond_context())
	var module_along := float(frame.get("module_along", 3.5))
	var half_w := float(frame.get("half_w", 3.0))
	# The routed run's own along-extent when there is one; else the pond window.
	var span := absf(module_along) + half_w + 8.0
	var conn := _routed_penstock_conn()
	if not conn.is_empty():
		var run := float(conn.get("route_length_m", 0.0))
		if run > 1.0:
			span = maxf(span, run * 1.15)
	var base := _lab_projection_for(1.0, Vector2.ZERO)
	var host := _lab_host_size()
	var base_span := host.x / maxf(float(base.get("sx", 1.0)), 1e-6)
	_view_zoom = clampf(base_span / maxf(span, 1.0), LAB_ZOOM_MIN, LAB_ZOOM_MAX)
	# Recentre on the midpoint of the run rather than the turbine.
	_view_pan_m.x = -module_along * 0.5
	_push_lab_section_frame()
	_redraw_preview()


func _unhandled_key_input(event: InputEvent) -> void:
	if not visible or not _as_view:
		return
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	if k.keycode == KEY_F:
		_on_frame_turbine()
		get_viewport().set_input_as_handled()
	elif k.keycode == KEY_HOME:
		_on_frame_whole_run()
		get_viewport().set_input_as_handled()


## Where a HYPOTHETICAL zoom/pan would put the section: centre metres plus px/m on
## each axis. Reuses _lab_view_metrics rather than re-deriving the framing maths,
## so the cursor anchoring below can never drift from what actually gets drawn.
func _lab_projection_for(zoom: float, pan_m: Vector2) -> Dictionary:
	var z0 := _view_zoom
	var p0 := _view_pan_m
	_view_zoom = zoom
	_view_pan_m = pan_m
	var mt := _lab_view_metrics()
	_view_zoom = z0
	_view_pan_m = p0
	var host := _lab_host_size()
	return {
		"along_mid": float(mt.get("along_m_rel", 0.0)),
		"elev_mid": float(mt.get("elev_m", 0.0)),
		"sx": host.x / maxf(float(mt.get("ortho_w_m", 1.0)), 1e-6),
		"sy": host.y / maxf(float(mt.get("ortho_h_m", 1.0)), 1e-6),
	}


## Section metres under a point in preview-stack pixels, at the given projection.
func _lab_point_to_section_m(proj: Dictionary, p: Vector2) -> Vector2:
	var d := p - _lab_host_size() * 0.5
	return Vector2(
		float(proj.get("along_mid", 0.0)) + d.x / float(proj.get("sx", 1.0)),
		float(proj.get("elev_mid", 0.0)) - d.y / float(proj.get("sy", 1.0)))


## Wheel zoom that keeps the metre under the CURSOR fixed, matching how Elevation
## already zooms (graph_canvas._elev_zoom_at). Zooming about the turbine instead
## meant every notch also walked the view away from whatever you were looking at.
func _lab_zoom_at(factor: float, screen_pos: Vector2) -> void:
	var old_zoom := _view_zoom
	var new_zoom := clampf(old_zoom * factor, LAB_ZOOM_MIN, LAB_ZOOM_MAX)
	if is_equal_approx(new_zoom, old_zoom):
		return
	var before := _lab_point_to_section_m(
			_lab_projection_for(old_zoom, _view_pan_m), screen_pos)
	var after := _lab_point_to_section_m(
			_lab_projection_for(new_zoom, _view_pan_m), screen_pos)
	_view_zoom = new_zoom
	# along_mid = module_along - pan.x and elev_mid = module_m + pan.y, so the
	# corrections carry opposite signs.
	_view_pan_m += Vector2(after.x - before.x, before.y - after.y)


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
	return _pv_y_min + _view_pan_m.y + (_pv_origin.y + _pv_size.y - y) / denom2


## Preview interaction: wheel zoom (linked CT), prop hover/drag, level lines, pan.
func _on_preview_stack_input(event: InputEvent) -> void:
	if not visible:
		return
	# Penstock gizmo FIRST — the prop drag and the pond level grab both claim
	# broad areas of the section and would swallow it.
	if _penstock_try_input(event):
		return
	# Prop hover / drag / click (Elevation-plane spatial edit) before level/pan.
	if _try_lab_spatial_input(event):
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		var step := LAB_ZOOM_STEP_FINE if mb.ctrl_pressed else LAB_ZOOM_STEP
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_lab_zoom_at(step, mb.position)
			_preview_stack.accept_event()
			_push_lab_section_frame()
			_redraw_preview()
			return
		if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_lab_zoom_at(1.0 / step, mb.position)
			_preview_stack.accept_event()
			_push_lab_section_frame()
			_redraw_preview()
			return
		# RIGHT / MIDDLE always pan; LEFT pans only when it did not grab a level
		# line. LEFT alone used to mean gizmo, prop drag, level grab AND pan, which
		# is most of why the cross-section feels unpredictable to navigate.
		if mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_MIDDLE \
				or mb.button_index == MOUSE_BUTTON_RIGHT:
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
			if _grab_kind == "exit":
				_drag_exit(mm.position)
			else:
				_apply_level_drag(_grab_kind, _elev_at_screen_y(mm.position.y))
			_view_last_mouse = mm.position
			_preview_stack.accept_event()
			_redraw_preview()
			return
		if _view_dragging:
			var proj := _lab_projection_for(_view_zoom, _view_pan_m)
			var d := mm.position - _view_last_mouse
			_view_pan_m += Vector2(d.x / float(proj.get("sx", 1.0)),
					d.y / float(proj.get("sy", 1.0)))
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
				# Clicking ANOTHER hydro turbine hands it the whole Lab session
				# — the dock params, kind selector and charts follow the click
				# (before this they were pinned to whichever turbine the Lab
				# opened on, with no way to move over).
				if not pid.is_empty():
					var m2 := _model()
					if m2 != null:
						var hit_item := GraphEmbodiment.find_item_by_bound_prop_id(m2, pid)
						if not hit_item.is_empty() and hit_item != _item_id \
								and _is_lab_turbine(hit_item):
							set_active_turbine(hit_item)
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
	# The draft exit is a POINT handle (it moves the outlet), picked first.
	if _exit_px.is_finite() and pos.distance_to(_exit_px) < 11.0:
		return "exit"
	var elev := _elev_at_screen_y(pos.y)
	var scale := _pv_sy * _view_zoom
	var best := ""
	var best_px := 8.0
	var hit_scale := _pv_sy if _pv_linked else scale
	if _kind_has_penstock():
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
	else:
		# Siphon: the crest (the turbine itself) and the dip tube's mouth are
		# the two things to drag; prime / break follow from them.
		if _module_spin != null:
			var dc := absf(elev - float(_module_spin.value)) * hit_scale
			if dc < best_px:
				best_px = dc
				best = "crest"
		if _break_spin != null:
			var d3 := absf(elev - float(_break_spin.value)) * hit_scale
			if d3 < best_px:
				best_px = d3
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
	elif kind == "crest" and _module_spin != null:
		_module_spin.value = elev
	elif kind == "break":
		if _kind_has_penstock():
			if _break_spin != null:
				_break_spin.value = elev
		elif _dip_len_spin != null and _module_spin != null:
			# Dragging the mouth = extending the dip tube.
			_dip_len_spin.value = maxf(float(_module_spin.value) - elev, 0.1)
	elif kind == "exit" and _outlet_inv_spin != null:
		_outlet_inv_spin.value = elev
	elif kind == "water" and _graph_view != null \
			and _graph_view.has_method("lab_set_pond_level"):
		_graph_view.call("lab_set_pond_level", _item_id, elev)
		_pond_cache_t = 999.0
	_phys_acc = 999.0


## Prime the siphon now: fill the pond just over the prime level. When the
## crest stands ABOVE the pond's rim an overflow prime can never happen (the
## pond would spill first) — the real reason "the level won't rise" on a
## turbine seated on the bank — so this switches Priming to a vacuum pump,
## whose prime level is just over the dip mouth, and fills to that.
func _on_fill_to_prime() -> void:
	if _graph_view == null or not _graph_view.has_method("lab_set_pond_level"):
		return
	var prime := float(_start_spin.value) if _start_spin != null else NAN
	if is_nan(prime):
		return
	var pond := _pond_context()
	var rim := float(pond.get("rim_m", NAN))
	# A crest a little above the rim: dam the pond (raise its max fill level)
	# rather than switch to a pump — the overflow prime the player asked for.
	if not is_nan(rim) and prime + 0.06 > rim - 0.02 and prime - rim <= 1.0 \
			and _graph_view.has_method("raise_pond_max_level_for_siphon"):
		if bool(_graph_view.call("raise_pond_max_level_for_siphon", _item_id, prime + 0.12)):
			_pond_cache_t = 999.0
			pond = _pond_context()
			rim = float(pond.get("rim_m", NAN))
			if _graph_view.has_method("_show_toast"):
				_graph_view.call("_show_toast", "Raised the pond's max fill level to %.2f m (a dam above the basin rim) so it can reach the crest" % (prime + 0.12))
	if not is_nan(rim) and prime + 0.06 > rim - 0.02 and _prime_opt != null \
			and str(_prime_opt.get_item_metadata(_prime_opt.selected)) != "pump":
		_syncing = true
		_prime_opt.select(1)
		_syncing = false
		_commit_string("siphon_prime_mode", "pump")
		_refresh_physics()
		prime = float(_start_spin.value) if _start_spin != null else prime
		if _graph_view.has_method("_show_toast"):
			_graph_view.call("_show_toast", "The crest is above the pond's rim — switched to vacuum-pump priming")
	# Even a pumped siphon needs its mouth a bore UNDER the surface. If the
	# dip tube does not reach that deep into a full pond, extend it: the mouth
	# goes to half a metre under the rim (the pond can hold no more).
	if not is_nan(rim) and prime + 0.06 > rim - 0.02 and _dip_len_spin != null and _module_spin != null:
		var want_mouth := rim - 0.6
		var need_len := float(_module_spin.value) - want_mouth
		if need_len > float(_dip_len_spin.value) + 1e-3:
			_dip_len_spin.value = clampf(need_len, 0.1, 30.0)
			_refresh_physics()
			prime = float(_start_spin.value) if _start_spin != null else prime
			if _graph_view.has_method("_show_toast"):
				_graph_view.call("_show_toast", "Dip tube extended to %.2f m so its mouth reaches the water" % float(_dip_len_spin.value))
	_graph_view.call("lab_set_pond_level", _item_id, prime + 0.06)
	_pond_cache_t = 999.0
	_phys_acc = 999.0


## The outlet node wired to this turbine's water out, if any.
func _outlet_sink() -> Dictionary:
	if _graph_view == null or _item_id.is_empty():
		return {}
	var rf: Variant = _graph_view.get("_resource_flow")
	if rf == null or not (rf as Object).has_method("_resolve_siphon_outlet_tank"):
		return {}
	return rf.call("_resolve_siphon_outlet_tank", _current_item())


## Along (m, pond-relative) under a section x pixel — the x inverse of
## _pv_to_screen_centered.
func _along_at_screen_x(x: float) -> float:
	var cx := _pv_origin.x + _pv_size.x * 0.5
	if _pv_linked:
		return _pv_along_mid + (x - cx) / maxf(_pv_sx, 1e-6)
	return _pv_along_mid - _view_pan_m.x + (x - cx) / maxf(_pv_sx * _view_zoom, 1e-6)


## Drag the draft exit on the cut: x walks it along the slice (down the hill),
## y sets its height, never above the ground there — a culvert daylights at
## or under the surface. Moves the outlet NODE (and the culvert's far end).
func _drag_exit(pos: Vector2) -> void:
	if _graph_view == null or not _graph_view.has_method("move_siphon_outlet"):
		return
	var along_rel := _along_at_screen_x(pos.x)
	var elev := _elev_at_screen_y(pos.y)
	var ground := _dem_elev_at(along_rel)
	if not is_nan(ground):
		elev = minf(elev, ground - 0.25)
	var heading := float(_elev_section_params().get("heading", 0.0))
	var cross := 0.0
	var turbine := _current_item()
	if GraphSiteLayout.has_site_coords(turbine):
		cross = GraphSiteLayout.project_onto_section(GraphSiteLayout.site_xz(turbine), heading).y
	var site := GraphSiteLayout.section_to_site(along_rel + _pond_along_m(), cross, heading)
	_graph_view.call("move_siphon_outlet", _item_id, site, elev)
	_syncing = true
	if _outlet_inv_spin != null:
		_outlet_inv_spin.value = elev
	_syncing = false
	_invalidate_slice_cache()
	_phys_acc = 999.0


## Write a hand-set draft exit through to the outlet node and the culvert's
## far end, so the 3D pipe and the Elevation CT move with the spin.
func _push_outlet_invert(v: float) -> void:
	var m := _model()
	if m == null or _graph_view == null or _item_id.is_empty():
		return
	var rf: Variant = _graph_view.get("_resource_flow")
	if rf == null or not (rf as Object).has_method("_resolve_siphon_outlet_tank"):
		return
	var sink: Dictionary = rf.call("_resolve_siphon_outlet_tank", _current_item())
	if sink.is_empty():
		return
	var sid := str(sink.get("id", ""))
	if absf(float(sink.get("elevation_m", NAN)) - v) > 1e-3:
		m.update_item(sid, {"elevation_m": v})
	for conn: Dictionary in m.connections:
		if str(conn.get("source_item_id", "")) == _item_id \
				and str(conn.get("target_item_id", "")) == sid \
				and str(conn.get("conduit_type", "")) == "culvert_pipe":
			if absf(float(conn.get("invert_out_m", NAN)) - v) > 1e-3:
				m.update_connection(str(conn.get("id", "")), {"invert_out_m": v})
	_invalidate_slice_cache()


## Re-route the draft pipe downhill: `extra_drop_m` more than it has now
## (0 = the stock 9 m from the turbine).
func _on_retrace_exit(extra_drop_m: float) -> void:
	if _graph_view == null or not _graph_view.has_method("retrace_siphon_outlet"):
		return
	var target := 0.0
	if extra_drop_m > 0.0:
		var mod_e := float(_module_spin.value) if _module_spin != null else 0.0
		var cur := float(_outlet_inv_spin.value) if _outlet_inv_spin != null else mod_e - 9.0
		target = maxf(mod_e - cur, 0.0) + extra_drop_m
	_graph_view.call("retrace_siphon_outlet", _item_id, target)
	_load_from_model()
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
		# The camera's own floor, not 1 m: below a metre of frame the overlay
		# used a different scale than the CT it is drawn over, and drifted.
		var ortho_w := maxf(float(metrics.get("ortho_w_m", a1 - a0)), GraphSiteLayout.LAB_MIN_ORTHO_H_M)
		var ortho_h := maxf(float(metrics.get("ortho_h_m", hi - lo)), GraphSiteLayout.LAB_MIN_ORTHO_H_M)
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
	_pv_along_mid = along_mid

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
			# The idealized two-segment glyph is the NO-ROUTE fallback only. Once
			# a real penstock is routed its measured polyline is drawn above
			# (_draw_routed_penstock) — drawing both told two different stories,
			# and the schematic one was why routing looked like a no-op.
			if not _has_routed_penstock():
				var pen_d_m := float(_penstock_d_spin.value) * 0.001 if _penstock_d_spin != null else 0.063
				_draw_penstock_glyph(mx, intake_elev, half_w - 0.3, out_inv, module_m,
						a1, along_mid, pen_d_m, out_d_m, q_lps, flowing,
						origin, size)
		else:
			var in_d_m := float(_intake_d_spin.value) * 0.001 if _intake_d_spin != null else 0.2
			# The dip tube hangs from the crest (the turbine) to its mouth (the
			# break level) just inside the pond's edge.
			_draw_turbine_module(mx, mod_base, mod_top_elev, break_m,
					half_w - 0.3, along_mid, q_lps, primed, in_d_m, out_d_m, water_top, module_m)
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

	_draw_routed_penstock(along_mid, origin, size, q_lps, flowing)
	_draw_penstock_gizmo(mx, module_m, along_mid, origin, size)
	_exit_px = Vector2.INF
	_crest_px = Vector2.INF
	if not _kind_has_penstock():
		_draw_siphon_gauges(mx, module_m, break_m, out_inv, a1, along_mid, origin, size)

	# The source label stays painted (it names what you are looking at, in place);
	# the numbers moved to the status strip below the section, where they have
	# contrast and do not scroll away under pan/zoom.
	var caption := str(pond.get("label", ""))
	if caption.is_empty():
		caption = "Stream intake" if _kind_has_penstock() else "Bind a pond for a site CT slice"
	_preview.draw_string(ThemeDB.fallback_font, origin + Vector2(8, 16), caption,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, C_MUTED)


## The siphon's two pressure limits, drawn ON the cut: the crest (lift + the
## absolute pressure there) and a suction gauge beside the draft pipe from the
## runner down to the exit, with the cavitation limit ticked — the number the
## Lab exists to make visible. Also the two drag handles the section offers:
## the crest (moves the turbine) and the draft exit (moves the outlet).
func _draw_siphon_gauges(mx: float, module_m: float, break_m: float, out_inv: float,
		a1: float, along_mid: float, origin: Vector2, size: Vector2) -> void:
	var fnt := ThemeDB.fallback_font
	var r := _last_r
	var flowing := bool(r.get("primed", false)) and float(r.get("q_lps", 0.0)) > 0.01
	var regime := str(r.get("regime", ""))
	var lo_y := origin.y + 14.0
	var hi_y := origin.y + size.y - 10.0
	# Crest handle + lift readout at the turbine.
	var crest := _pv_to_screen_centered(mx, module_m, along_mid)
	if crest.x > origin.x - 40.0 and crest.x < origin.x + size.x + 40.0:
		var cy := clampf(crest.y, lo_y, hi_y)
		_crest_px = Vector2(crest.x, cy)
		var cc := Color(1.0, 0.85, 0.35, 0.95) if regime != "lift_exceeded" else Color(1.0, 0.45, 0.4, 1.0)
		_preview.draw_circle(_crest_px, 5.0, cc)
		_preview.draw_arc(_crest_px, 8.0, 0.0, TAU, 20, Color(cc.r, cc.g, cc.b, 0.45), 1.2)
		var lift := float(r.get("lift_m", maxf(module_m - float(_pond_context().get("level_m", module_m)), 0.0)))
		var ctxt := "crest · lift %.1f m" % lift
		if flowing or regime == "lift_exceeded":
			ctxt += " · %.1f m abs" % float(r.get("crest_abs_m", 0.0))
		# Above-left of the handle; the suction gauge's text goes below-right.
		var cw := fnt.get_string_size(ctxt, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
		var cpos := _crest_px + Vector2(-cw - 10.0, -8.0)
		cpos.x = maxf(cpos.x, origin.x + 4.0)
		_preview.draw_string(fnt, cpos, ctxt, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, cc)
	# Dip mouth label.
	var mouth := _pv_to_screen_centered(mx, break_m, along_mid)
	if mouth.y > lo_y and mouth.y < hi_y:
		var mw := fnt.get_string_size("dip mouth · break", HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x
		_preview.draw_string(fnt, mouth + Vector2(-mw - 10.0, 4.0), "dip mouth · break",
				HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(1.0, 0.55, 0.45, 0.9))
	if is_nan(out_inv):
		return
	# Draft exit handle: where the OUTLET NODE really stands on the section
	# (its site projected onto the cut), not a fixed spot at the frame's edge.
	# Drag it sideways to walk the exit down the hill, up/down to set its
	# height (never above the ground there).
	var exit_along := a1 - 0.5
	var exit_elev := out_inv
	var sink := _outlet_sink()
	if not sink.is_empty() and GraphSiteLayout.has_site_coords(sink):
		var heading := float(_elev_section_params().get("heading", 0.0))
		exit_along = GraphSiteLayout.project_onto_section(GraphSiteLayout.site_xz(sink), heading).x - _pond_along_m()
		var se := float(sink.get("elevation_m", NAN))
		if not is_nan(se):
			exit_elev = se
	var ex_raw := _pv_to_screen_centered(exit_along, exit_elev, along_mid)
	# A 2D guide of the draft run, module → exit, so the pipe reads even where
	# the 3D conduit is hidden or off the slice.
	var run_from := _pv_to_screen_centered(mx, module_m - 0.3, along_mid)
	_preview.draw_line(run_from, ex_raw, Color(0.85, 0.65, 0.25, 0.55), 2.0, true)
	var ex := ex_raw
	ex.x = clampf(ex.x, origin.x + 30.0, origin.x + size.x - 30.0)
	var ex_clamped := ex.y > hi_y or ex.y < lo_y or absf(ex_raw.x - ex.x) > 0.5
	ex.y = clampf(ex.y, lo_y, hi_y)
	_exit_px = ex
	var ec := Color(0.85, 0.65, 0.25, 0.95)
	var dia := PackedVector2Array([ex + Vector2(0, -7), ex + Vector2(7, 0), ex + Vector2(0, 7), ex + Vector2(-7, 0)])
	_preview.draw_colored_polygon(dia, ec)
	var etxt := "draft exit %.1f m · %.0f m out%s" % [exit_elev, absf(exit_along - mx), " (off frame)" if ex_clamped else ""]
	var ew := fnt.get_string_size(etxt, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
	_preview.draw_string(fnt, ex + Vector2(-ew * 0.5, 20.0), etxt,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, ec)
	# Suction gauge: a bar from the runner down to the exit, filled to the
	# suction the draft demands, with the cavitation limit ticked.
	if not flowing:
		return
	var suction := float(r.get("suction_m", 0.0))
	var s_max := float(r.get("suction_max_m", 0.0))
	var useful := float(r.get("useful_draft_m", module_m - out_inv))
	var cav := bool(r.get("cavitating", false))
	var gx := clampf(crest.x + 26.0, origin.x + 12.0, origin.x + size.x - 60.0)
	var top := clampf(crest.y, lo_y, hi_y)
	var bot := clampf(_pv_to_screen_centered(mx, out_inv, along_mid).y, lo_y, hi_y)
	if bot - top < 16.0:
		return
	_preview.draw_line(Vector2(gx, top), Vector2(gx, bot), Color(0.05, 0.08, 0.13, 0.85), 7.0)
	var frac := clampf(suction / maxf(s_max, 1e-6), 0.0, 1.0)
	var col := Color(0.94, 0.27, 0.27, 0.95) if cav else (Color(0.96, 0.62, 0.04, 0.95) if frac > 0.85 else Color(0.15, 0.9, 0.47, 0.95))
	var draft_px := bot - top
	var fill_px := draft_px * clampf(suction / maxf(module_m - out_inv, 1e-6), 0.0, 1.0)
	_preview.draw_line(Vector2(gx, top), Vector2(gx, top + fill_px), col, 5.0)
	# The limit tick: where the runner's outlet reaches vapour pressure.
	var lim := _pv_to_screen_centered(mx, module_m - useful, along_mid).y
	if lim > top and lim < bot:
		_preview.draw_line(Vector2(gx - 7.0, lim), Vector2(gx + 7.0, lim), Color(1.0, 0.95, 0.85, 0.95), 2.0)
		_preview.draw_string(fnt, Vector2(gx + 10.0, lim + 4.0), "suction limit",
				HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(1.0, 0.95, 0.85, 0.9))
		if cav:
			# Hatch the wasted part of the draft.
			var yy := lim + 6.0
			while yy < bot:
				_preview.draw_line(Vector2(gx - 5.0, yy), Vector2(gx + 5.0, yy + 4.0), Color(0.94, 0.27, 0.27, 0.6), 1.0)
				yy += 8.0
	# Text at the BOTTOM of the gauge, clear of the crest label above it and
	# of the limit tick's own label when the draft is short.
	var ty := minf(bot + 4.0, hi_y)
	if lim > top and lim < bot and absf(ty - (lim + 4.0)) < 14.0:
		ty = minf(lim + 18.0, hi_y)
	_preview.draw_string(fnt, Vector2(gx + 10.0, ty),
			"suction %.1f / %.1f m%s" % [suction, s_max, " · CAVITATING" if cav else ""],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, col)


## True when `conn` is a contour-routed conduit on THIS turbine.
func _is_our_contour_conn(conn: Dictionary) -> bool:
	if conn.is_empty():
		return false
	# A penstock FEEDS the turbine: only a run ending at it counts (a contour
	# run leaving it — a routed tailrace — is not its penstock).
	if str(conn.get("target_item_id", "")) != _item_id:
		return false
	var tid := ConduitKinds.derive_type_for_connection(conn)
	var rm := ConduitKinds.normalize_route_mode(
			str((conn.get("conduit_style", {}) as Dictionary).get("route_mode",
				ConduitKinds.type_meta(tid).get("route_mode", ""))))
	return rm == "contour"


## The routed penstock connection for this turbine, or {}.
## The id is CACHED: this is called per draw (12 Hz) and again from the route
## status refresh, and each miss walked every connection in the model. GraphModel
## indexes connections by id, so a hit is a dictionary lookup.
func _routed_penstock_conn() -> Dictionary:
	var m := _model()
	if m == null or _item_id.is_empty():
		return {}
	if not _routed_conn_id.is_empty():
		var cached: Dictionary = m.get_connection(_routed_conn_id)
		if _is_our_contour_conn(cached):
			return cached
		_routed_conn_id = ""
	for conn: Dictionary in m.connections:
		if _is_our_contour_conn(conn):
			_routed_conn_id = str(conn.get("id", ""))
			return conn
	return {}


func _has_routed_penstock() -> bool:
	return not _routed_penstock_conn().is_empty()


## Draw the ACTUAL routed penstock on the cross-section — its real terrain-
## following polyline, projected through the section frame. Before this the Lab
## only ever drew an idealized two-segment schematic, so routing a pipe changed
## nothing on screen (the single loudest symptom of the whole feature looking
## broken). Samples come from ConduitManager.ensure_preview_samples, which
## builds them WITHOUT remeshing, so this works even with 3D wires off.
func _draw_routed_penstock(along_mid: float, origin: Vector2, size: Vector2,
		q_lps: float, flowing: bool) -> bool:
	var conn := _routed_penstock_conn()
	if conn.is_empty() or _graph_view == null:
		return false
	var mgr = _graph_view.call("_get_conduit_manager") \
			if _graph_view.has_method("_get_conduit_manager") else null
	if mgr == null or not mgr.has_method("ensure_preview_samples"):
		return false
	var samples: PackedVector3Array = mgr.call("ensure_preview_samples", conn)
	if samples.size() < 2:
		return false
	var soi := _soi_service()
	if soi == null or not soi.has_method("world_center"):
		return false
	var center: Vector3 = soi.call("world_center") as Vector3
	var heading := float(_elev_section_params().get("heading", 0.0))
	var pond_along := _pond_along_m()
	var pts := PackedVector2Array()
	for p in samples:
		var site := GraphSiteLayout.world_xz_to_site(Vector2(p.x, p.z), center)
		var along := GraphSiteLayout.project_onto_section(site, heading).x - pond_along
		pts.append(_pv_to_screen_centered(along, p.y, along_mid))
	if pts.size() < 2:
		return false
	var style: Dictionary = conn.get("conduit_style", {}) as Dictionary
	var sz_in := ConduitKinds.pipe_size_in("poly_penstock", style)
	var col := Color(0.30, 0.80, 1.0, 0.95) if flowing else Color(0.62, 0.70, 0.80, 0.85)
	# Stroke width tracks the pipe's real bore at the section's scale, floored
	# so a 1" run is still visible when zoomed out.
	var od_px := maxf(ConduitKinds.outer_diameter_m("poly_penstock", style)
			* _pv_sx * (1.0 if _pv_linked else _view_zoom), 2.5)
	_preview.draw_polyline(pts, Color(0.05, 0.07, 0.10, 0.85), od_px + 2.5, true)
	_preview.draw_polyline(pts, col, od_px, true)
	if flowing:
		_draw_flow_dashes(pts, q_lps)
	# Label at the run's midpoint: measured length + drop + size.
	var mid := pts[pts.size() / 2]
	var run := float(conn.get("route_length_m", 0.0))
	var inv_in := float(conn.get("invert_in_m", NAN))
	var inv_out := float(conn.get("invert_out_m", NAN))
	var txt := "%s poly" % PipeKit.size_label(sz_in)
	if run > 0.5:
		txt += " · %.0f m run" % run
	if not (is_nan(inv_in) or is_nan(inv_out)):
		txt += " · %.1f m drop" % absf(inv_in - inv_out)
	var lp := mid + Vector2(8.0, -8.0)
	lp.x = clampf(lp.x, origin.x + 6.0, origin.x + size.x - 180.0)
	lp.y = clampf(lp.y, origin.y + 30.0, origin.y + size.y - 8.0)
	_preview.draw_string(ThemeDB.fallback_font, lp, txt,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.72, 0.86, 1.0, 0.95))
	return true


## Penstock placement gizmo: a pulsing ring on the turbine inlet, plus — while
## dragging — the ghost run following the DEM up to the release point and a
## live run/drop readout. Drawn last so it sits over the terrain + pond fills.
func _draw_penstock_gizmo(module_along: float, module_elev: float,
		along_mid: float, origin: Vector2, size: Vector2) -> void:
	_penstock_gizmo_screen = Vector2.INF
	if not _penstock_mode:
		return
	var inlet_elev := module_elev + 0.35
	var g := _pv_to_screen_centered(module_along, inlet_elev, along_mid)
	if g.x < origin.x - 40.0 or g.x > origin.x + size.x + 40.0:
		return
	_penstock_gizmo_screen = g
	var pulse := 0.65 + 0.35 * sin(_flow_phase * 4.0)
	var glow := Color(1.0, 0.86, 0.40, 0.30 * pulse)
	_preview.draw_circle(g, 15.0, glow)
	_preview.draw_circle(g, 7.0, Color(1.0, 0.90, 0.55, 0.95))
	_preview.draw_arc(g, 11.0, 0.0, TAU, 28, Color(1.0, 0.80, 0.35, 0.95), 2.0, true)

	if _penstock_dragging and _penstock_ghost_valid:
		# Ghost run: sample the section's baked DEM between the inlet and the
		# release point so the preview reads as pipe LYING ON the hillside —
		# the same story ContourRouter tells in 3D.
		var pts := PackedVector2Array()
		pts.append(g)
		var steps := 28
		for i in range(1, steps + 1):
			var t := float(i) / float(steps)
			var a := lerpf(module_along, _penstock_ghost_along, t)
			var ground := _dem_elev_at(a)
			var e := lerpf(inlet_elev, _penstock_ghost_elev, t)
			if not is_nan(ground):
				e = maxf(ground + 0.12, minf(e, maxf(inlet_elev, _penstock_ghost_elev)))
			pts.append(_pv_to_screen_centered(a, e, along_mid))
		var end_pt := _pv_to_screen_centered(_penstock_ghost_along,
				_penstock_ghost_elev, along_mid)
		pts.append(end_pt)
		var rise := _penstock_ghost_elev - module_elev
		var ok := rise > 0.25
		var col := Color(0.35, 0.85, 1.0, 0.95) if ok else Color(0.95, 0.45, 0.35, 0.95)
		if pts.size() >= 2:
			_preview.draw_polyline(pts, Color(col.r, col.g, col.b, 0.35), 7.0, true)
			_preview.draw_polyline(pts, col, 3.0, true)
		_preview.draw_circle(end_pt, 6.0, col)
		_preview.draw_arc(end_pt, 10.0, 0.0, TAU, 20,
				Color(col.r, col.g, col.b, 0.55), 1.5, true)
		# Report the SECTION run in metres (the honest measured 3D run is
		# stamped by the conduit rebuild once the route commits).
		var run_m := absf(_penstock_ghost_along - module_along)
		var lbl := "intake %.1f m up · run ≈ %.0f m" % [rise, maxf(run_m, 0.0)] if ok \
				else "source must be ABOVE the turbine"
		var lp := end_pt + Vector2(10.0, -10.0)
		lp.x = clampf(lp.x, origin.x + 6.0, origin.x + size.x - 190.0)
		lp.y = clampf(lp.y, origin.y + 18.0, origin.y + size.y - 8.0)
		_preview.draw_string(ThemeDB.fallback_font, lp, lbl,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 12, col)
	else:
		_preview.draw_string(ThemeDB.fallback_font, g + Vector2(14.0, -12.0),
				"drag to the water source", HORIZONTAL_ALIGNMENT_LEFT, -1, 11,
				Color(1.0, 0.86, 0.45, 0.9))


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
	# Linked to the CT, _pv_sx/_pv_sy already include the zoom (pipes drew
	# zoom× too thick); the standalone section still applies it.
	return maxf(dia_m * (_pv_sx + _pv_sy) * 0.5 * (1.0 if _pv_linked else _view_zoom), 3.0)


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
		water_top: float, crest_elev: float = NAN) -> void:
	var flowing := primed and q_lps > 0.01
	var half := maxf(_dia_px(out_d_m) * 0.5 / maxf(_pv_sx * (1.0 if _pv_linked else _view_zoom), 1e-3), 0.32)
	var top_l := _pv_to_screen_centered(mx - half, top_elev, along_mid)
	var top_r := _pv_to_screen_centered(mx + half, top_elev, along_mid)
	var bot_l := _pv_to_screen_centered(mx - half, base_elev, along_mid)
	var bot_r := _pv_to_screen_centered(mx + half, base_elev, along_mid)

	# The dip tube: hangs from the crest (the turbine inlet) straight down into
	# the pond to its mouth at `intake_elev` (the break level), then a short
	# run over the bank into the housing. With no crest given (legacy callers)
	# it is the old low side-intake.
	if is_nan(crest_elev):
		var in_a := _pv_to_screen_centered(intake_from_along, intake_elev, along_mid)
		var in_b := _pv_to_screen_centered(mx - half * 0.4, intake_elev, along_mid)
		_draw_pipe_run(in_a, in_b, in_d_m, flowing)
		if flowing:
			_draw_flow_dashes(PackedVector2Array([in_a, in_b]), q_lps)
	else:
		var mouth := _pv_to_screen_centered(intake_from_along, intake_elev, along_mid)
		var knee := _pv_to_screen_centered(intake_from_along, crest_elev, along_mid)
		var inlet := _pv_to_screen_centered(mx - half * 0.4, crest_elev, along_mid)
		_draw_pipe_run(mouth, knee, in_d_m, flowing)
		_draw_pipe_run(knee, inlet, in_d_m, flowing)
		# The open mouth: a bell at the bottom of the tube.
		var bell := _dia_px(in_d_m) * 0.6
		_preview.draw_arc(mouth, bell, 0.0, PI, 10, _C_PIPE_WALL_DK, 2.0, true)
		if flowing:
			_draw_flow_dashes(PackedVector2Array([mouth, knee, inlet]), q_lps)

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
	# Unlinked (no CT behind): zoom/pan applied here. Pan is metres, so scale it by
	# the same px/m the geometry uses — same convention as the linked branch.
	return Vector2(
		_pv_origin.x + _pv_size.x * 0.5
			+ (along_m - along_mid + _view_pan_m.x) * _pv_sx * _view_zoom,
		_pv_origin.y + _pv_size.y
			- (elev_m - _pv_y_min - _view_pan_m.y) * _pv_sy * _view_zoom)


func _pv_to_screen(along_m: float, elev_m: float) -> Vector2:
	return _pv_to_screen_centered(along_m, elev_m, 0.0)
