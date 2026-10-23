@tool
class_name TimelineUI
extends Control

const WORLD_PANEL_SCRIPT := preload("res://scenes/ui/world_panel.gd")

## Thin bottom-bar timeline UI.
## Displays: 24h day scrubber, playback controls, time, date, moon phase,
## sunrise/sunset, speed preset, and save/load button.
## Spacebar toggles sim pause; when paused the cursor is released for interaction.
## @tool makes _build_bar() run in the editor so the layout is visible in the 2D editor.

# ---------------------------------------------------------------------------
# Palette — redirected to UITheme (single source of truth); local const
# names kept so existing call sites are unchanged.
# ---------------------------------------------------------------------------
const C_BG       := Color(UITheme.C_BG, 0.97)
const C_PANEL    := UITheme.C_PANEL
const C_BORDER   := UITheme.C_BORDER
const C_PRIMARY  := UITheme.C_PRIMARY
const C_AMBER    := UITheme.C_AMBER
const C_GOLD     := UITheme.C_GOLD
const C_LAVENDER := UITheme.C_LAVENDER
const C_GREEN    := UITheme.C_GREEN
const C_TEXT     := UITheme.C_TEXT
const C_TEXT_S   := UITheme.C_TEXT_S
const C_TEXT_M   := UITheme.C_TEXT_M

# Variable scrubber track + main info row (transport / left NLE icons /
# right system icons). NLE clip controls live in the left icon cluster so
# the bar no longer needs a separate 22 px button strip.
# INFO_ROW_HEIGHT fits the tallest cluster — the centre time cluster (22 pt
# time + date spin row). Weather lives in the floating WeatherCardUI.
# Kept slim so graph sidebars / place-edit dock sit flush above the bar.
const INFO_ROW_HEIGHT : int = 56
## @deprecated Kept for older references; chrome no longer includes an NLE row.
const NLE_ROW_HEIGHT : int = 0
const BAR_CHROME_HEIGHT : int = INFO_ROW_HEIGHT + 6
## Gap between the bar bottom edge and the viewport (external padding).
const BAR_BOTTOM_PAD : int = 4
## Extra breathing room inside the info row above the bar bottom.
const INFO_ROW_BOTTOM_PAD : int = 2
## Legacy alias — minimum scrubber height before waveform tracks.
const TRACK_ROW_HEIGHT : int = 54
const NWS_ALERT_SERVICE_SCRIPT := preload("res://core/nws_alert_service.gd")
const TimelineViewScript := preload("res://core/timeline/timeline_view.gd")
const TimelineTrackLayoutScript := preload("res://core/timeline/timeline_track_layout.gd")
const TimelineTrackDefScript := preload("res://core/timeline/timeline_track_def.gd")
const TimelineWaveformDrawScript := preload("res://core/timeline/timeline_waveform_draw.gd")
const _CLOSURE_METRICS_SCRIPT := preload("res://system_graph/closure_metrics.gd")

# ---------------------------------------------------------------------------
# Speed presets  [display_label, time_scale_value]
# REALTIME_SCALE = 1/3600 ≈ 0.000278  (1 sim-hour per real-hour)
# ---------------------------------------------------------------------------
const SPEED_STEPS : Array = [
	["1×",    0.000278],
	["10×",   0.002778],
	["60×",   0.016667],
	["300×",  0.083333],
	["450×",  0.125000],
	["1440×", 0.400000],
	["Max",   2.000000],
	["∞×2",   INF],       # Analemma view: 2 calendar days per frame.
	["∞",     INF],       # Analemma view: 1 calendar day per frame.
]

# ---------------------------------------------------------------------------
# Climelapse MP4 export
# ---------------------------------------------------------------------------
## Output frame rate of the exported video. The sim advances
## (selected speed / CLIM_EXPORT_FPS) sim-hours per rendered frame, so the video
## plays back at exactly the speed shown on the bar.
const CLIM_EXPORT_FPS := 30
const CLIM_EXPORT_DIALOG_SCRIPT := preload("res://scenes/ui/climelapse_export_dialog.gd")
## Pixels either side of a keyframe diamond that still pick it.
const CLIM_KEY_HIT_PX := 7.0

const MOON_EMOJIS  : Array = ["🌑","🌒","🌓","🌔","🌕","🌖","🌗","🌘"]
const MONTH_NAMES  : Array = ["Jan","Feb","Mar","Apr","May","Jun",
							   "Jul","Aug","Sep","Oct","Nov","Dec"]

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
var _main         : Node  = null
var _player       : Node  = null
var _is_playing   : bool  = true
## Play-button ring state last written (-1 = never): see _update_display.
var _play_ring_key : int = -1
var _speed_idx    : int   = 2        # default 60×
var _stored_scale : float = 0.016667
## True while the sim is paused by THIS bar (spacebar). Used externally by time_ui.
var _sim_paused_by_bar : bool = false

var _update_accum : float = 0.0
var _ready_done   : bool  = false

const UPDATE_INTERVAL := 0.1

## _draw_waveform_lane's TimelineBinning bins (exact over every sample) and
## the per-day WeatherService temperature-record loop in _draw_track both
## recompute on every track redraw (~10 fps via UPDATE_INTERVAL above) even
## when the view window hasn't moved and the sim is paused. Cache the last
## result per track / per calendar day, bounded by a short TTL so data stays
## fresh while actively simulating (or after a location/dataset change) but
## an unchanged, paused view isn't recomputed ~10x/sec for nothing.
const WAVEFORM_CACHE_TTL := 0.25
var _waveform_cache : Dictionary = {}      # track id -> {key, bins, t}
const WEATHER_PIP_CACHE_TTL := 0.5
var _weather_pip_cache : Dictionary = {}   # day index (int) -> {rec, sim_t, t}

# ---------------------------------------------------------------------------
# UI node refs
# ---------------------------------------------------------------------------
var _time_slider  : HSlider   # legacy 24h day scrubber (retired; kept for refs)
var _time_lbl     : Label
var _year_input   : SpinBox
var _month_input  : SpinBox
var _day_input    : SpinBox
var _date_syncing : bool = false
var _settings_panel : Control = null

# Multi-day absolute-time track (replaces the 24h slider). Custom-drawn.
var _track          : Control = null
var _track_lbl_start: Label = null
var _track_lbl_end  : Label = null
var _track_dragging : bool = false
var _track_panning : bool = false
var _track_pan_anchor_x : float = 0.0
var _track_view : TimelineView = TimelineView.new()
var _track_layout : TimelineTrackLayout = TimelineTrackLayout.new()
var _scrubber_row : HBoxContainer = null
var _resize_track_idx : int = -1
var _tracks_menu : PopupMenu = null
var _tracks_btn : Button = null

## Needs strip (Energy / Water / Food / Waste) — Phase 1 closure HUD.
var _needs_chips: Dictionary = {}  # kind -> Button
var _needs_score_lbl: Label = null
## Phase 2 challenge progress chip + picker modal (lazy-init).
var _challenge_chip: Button = null
var _challenge_picker_panel: Control = null
## Multiplayer lobby (listen-server co-presence) + status chip + chat HUD.
var _mp_chip: Button = null
var _ha_chip: Button = null
var _mp_lobby: Control = null
var _mp_chat_hud: Control = null
var _conduits_chip: Button = null
## Site Projects (the crew's work queue: unload → fabricate → raise → break down).
var _projects_chip: Button = null
## Settlement view — the watch-the-community-work camera.
var _settlement_chip: Button = null
## Festival mode -- populate the painted camps, assume them stocked, watch.
var _festival_chip: Button = null

var _solar_analyzer: SolarShadingAnalyzer = null
var _shading_overlay: PanelContainer = null
var _shading_progress: ProgressBar = null
var _shading_status: Label = null
var _shading_decal: Decal = null
var _shading_btn: Button = null

signal stack_height_changed(height: float)

func get_stack_height() -> float:
	return _bar_height() + float(BAR_BOTTOM_PAD)


func _bar_height() -> float:
	return float(BAR_CHROME_HEIGHT + _track_layout.content_height())


func _sync_scrubber_row_height() -> void:
	if _scrubber_row != null:
		_scrubber_row.custom_minimum_size = Vector2(0.0, _track_layout.content_height())

## TimeDirector autoload (modes, NOW anchor, provenance). May be null in editor.
var _td : Node = null
## Mode chip (LIVE / PLAYBACK / SIM) + data-provenance chip (REAL/OBSERVED/…).
var _mode_chip : Button = null
var _data_chip : Label = null

# Provenance band tints (dim fills behind the track).
const C_OBSERVED  := Color(0.133, 0.827, 0.933, 0.16)   # teal — real/observed past
const C_PROJECTED := Color(0.686, 0.600, 1.000, 0.16)   # lavender — projected future
const C_RECORDED  := Color(0.149, 0.902, 0.467, 0.16)   # green — recorded playback

# NLE clip lanes (observed datastream + batch-rendered simulation + timelapse video).
const LANE_OBS_FILL  := Color(0.961, 0.620, 0.043, 0.55)  # amber — observed CSV clip
const LANE_OBS_BG    := Color(0.961, 0.620, 0.043, 0.10)
const LANE_SIM_FILL  := Color(0.133, 0.827, 0.933, 0.55)  # cyan — rendered sim clip
const LANE_SIM_BG    := Color(0.133, 0.827, 0.933, 0.10)
const LANE_VID_FILL  := Color(0.149, 0.902, 0.467, 0.55)  # green — timelapse video
const LANE_VID_BG    := Color(0.149, 0.902, 0.467, 0.10)
const LANE_CLIM_FILL := Color(0.686, 0.420, 0.933, 0.55)  # purple — climelapse bake
const LANE_CLIM_BG   := Color(0.686, 0.420, 0.933, 0.10)
const SEL_FILL       := Color(1.0, 1.0, 1.0, 0.09)        # selection span
const SEL_EDGE       := Color(1.0, 1.0, 1.0, 0.55)
# NLE control buttons (built in _build_left_cluster).
var _import_btn        : Button = null
var _linkagelab_btn    : Button = null
var _render_btn        : Button = null
var _export_mp4_btn    : Button = null
var _loadmode_btn      : Button = null
var _compare_btn       : Button = null
var _load_video_btn    : Button = null
var _live_feed_btn     : Button = null
var _snap_video_btn    : Button = null
var _render_progress_lbl : Label = null
var _import_dialog     : FileDialog = null
var _linkagelab_dialog : FileDialog = null
var _linkagelab_open_confirm : ConfirmationDialog = null
var _pending_linkage_project : Dictionary = {}

const BUNDLE_IMPORTER_SCRIPT := preload("res://core/linkagelab/bundle_importer.gd")
## Selection drag state (shift-drag on the track sets the render in/out range).
var _selecting         : bool = false
var _sel_anchor_abs    : float = NAN
## True once SolarUI's compare signals are connected (lazy, once).
var _solar_signals_connected : bool = false
var _clim_signals_connected : bool = false
var _clim_progress_dialog : Window = null
var _clim_progress_bar : ProgressBar = null
var _clim_progress_lbl : Label = null
var _clim_cancel_btn : Button = null
var _clim_options_dialog : Node = null
var _clim_preview_rect : TextureRect = null
## Camera keyframe being dragged on the CLIM lane (index), -1 = none.
var _clim_key_drag := -1
var _clim_key_drag_moved := false
var _clim_key_press_x := 0.0
## Screen rect of the CLIM sub-lane, cached by the draw for hit tests.
var _clim_lane_rect := Rect2()
var _clim_key_menu : PopupMenu = null
var _clim_key_menu_idx := -1
var _clim_key_menu_t := 0.0
var _clim_key_drag_t := NAN
## Guards the one-shot completion toast (state_changed fires repeatedly).
var _clim_last_reported_result := ""
var _sunrise_lbl  : Label
var _sunset_lbl   : Label
var _moon_lbl     : Label
var _play_btn     : Button
var _speed_lbl    : Label
var _hold_lbl     : Label
var _hold_owner   : String = ""
## Readable names for clock-claim owners (see main.clock_hold_owner).
const CLOCK_HOLD_LABELS := {
	"csv_playback": "CSV playback",
	"challenge_bake": "challenge bake",
	"climelapse_export": "video export",
	"climelapse_preview": "video preview",
	"window_wall": "Window Wall",
}
# Info-row clusters (manually placed: NLE icons left · transport/time/date
# centre · system icons right). Parent is a plain Control so we position them.
var _info_row       : Control = null
var _left_cluster   : Control = null
var _center_time_cluster : Control = null
var _center_transport_cluster : Control = null
var _center_speed_cluster : Control = null
var _right_cluster  : Control = null
## Right-cluster buttons that fold into the ⋯ menu when the row is too
## narrow, in fold order (least used first): {btn, label}.
var _right_fold_items: Array = []
var _sfx_btn: Button = null
var _right_overflow: MenuButton = null
var _right_folded := -1
const INFO_ROW_EDGE_PAD : float = 8.0
const CENTER_CLUSTER_GAP : float = 18.0
var _scrubber_updating : bool = false   # prevents feedback loop

# Weather display moved to the floating WeatherCardUI (sibling on UILayer);
# SolarUI keeps pushing through this node and we forward (node-name contract).
var _wx_status_lbl: Label  # kept for API compatibility; not rendered
var _weather_card: Control = null
## Kept for pref-file compatibility (card owns the live unit toggle now).
var _use_imperial: bool = true
var _solar_ui: Node = null
var _map_confirm: ConfirmationDialog
var _csv_playback_ui: CsvPlaybackUI = null
var _layout_enforced: bool = false
var _bar_layout_pending: bool = false
var _bar_layout_guard: bool = false
var _last_viewport_size: Vector2 = Vector2.ZERO
## Record Book Modal — lazy-init on first press.
var _record_book_panel: Control = null
var _site_report_panel: Control = null
## 🌫 Microclimate drawer (scenes/ui/microclimate_drawer.gd), lazy.
var _microclimate_drawer: CanvasLayer = null

# Tooltip panel — sibling on the parent CanvasLayer. Still used by the NWS
# alert-band hover on the track (stat-tile hovers moved to WeatherCardUI).
var _wx_tooltip_panel: PanelContainer = null
var _tip_var_lbl:  Label = null
var _tip_val_lbl:  Label = null
var _tip_time_lbl: Label = null
var _tip_src_lbl:  Label = null
var _tip_stn_lbl:  Label = null



# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	ServiceLocator.provide(ServiceLocator.TIMELINE_UI, self)
	_track_layout.reset_defaults()
	_build_bar()
	if Engine.is_editor_hint():
		return   # editor preview only — skip runtime setup
	_load_ui_prefs()

	_map_confirm = ConfirmationDialog.new()
	_map_confirm.dialog_text = "Save this world and return to your worlds?\n\nEverything is saved first — Play puts you back exactly here."
	_map_confirm.ok_button_text = "Return to menu"
	_map_confirm.confirmed.connect(_on_map_select_confirmed)
	add_child(_map_confirm)
	call_deferred("_setup_runtime_ui")
	call_deferred("_request_bar_layout")
	_ready_done = true
	_try_connect_main()
	call_deferred("_try_connect_csv_playback")
	_connect_viewport_resize()


func _connect_viewport_resize() -> void:
	if Engine.is_editor_hint():
		return
	var vp := get_viewport()
	if vp != null and not vp.size_changed.is_connected(_on_viewport_size_changed):
		vp.size_changed.connect(_on_viewport_size_changed)
		_last_viewport_size = vp.get_visible_rect().size


func _on_viewport_size_changed() -> void:
	var vp := get_viewport()
	if vp == null:
		return
	var sz := vp.get_visible_rect().size
	if sz == _last_viewport_size:
		return
	_last_viewport_size = sz
	_request_bar_layout()


func _notification(what: int) -> void:
	# @tool scene preview in the editor only — never during a running game session.
	if what == NOTIFICATION_RESIZED and Engine.is_editor_hint():
		_request_bar_layout()


func _request_bar_layout() -> void:
	if _bar_layout_pending:
		return
	_bar_layout_pending = true
	call_deferred("_enforce_bar_layout")


func _setup_runtime_ui() -> void:
	_ensure_crosshair_ui()
	_setup_settings_panel()
	_setup_mp_lobby()
	_setup_wx_tooltip()
	_setup_weather_card()
	_connect_weather_signals()
	if is_instance_valid(SimSettingsController) \
			and not SimSettingsController.conduits_3d_visible_changed.is_connected(
				_on_conduits_visible_signal):
		SimSettingsController.conduits_3d_visible_changed.connect(
			_on_conduits_visible_signal)
	_refresh_conduits_chip()
	if is_instance_valid(CursorController):
		CursorController.set_paused(false)


func _setup_mp_lobby() -> void:
	if _mp_lobby != null:
		_setup_mp_chat_hud()
		return
	var script := load("res://scenes/ui/multiplayer_lobby_ui.gd") as Script
	if script == null:
		return
	_mp_lobby = Control.new()
	_mp_lobby.name = "MultiplayerLobbyUI"
	_mp_lobby.set_script(script)
	UiScreenLayout.pin_fullscreen(_mp_lobby)
	var ui_layer := get_parent()
	if ui_layer != null:
		ui_layer.add_child(_mp_lobby)
	else:
		add_child(_mp_lobby)
	if MultiplayerSession != null:
		if not MultiplayerSession.session_changed.is_connected(_refresh_mp_chip):
			MultiplayerSession.session_changed.connect(_refresh_mp_chip)
		if not MultiplayerSession.peer_list_changed.is_connected(_refresh_mp_chip):
			MultiplayerSession.peer_list_changed.connect(_refresh_mp_chip)
	_setup_mp_chat_hud()


func _setup_mp_chat_hud() -> void:
	if _mp_chat_hud != null:
		return
	var script := load("res://scenes/ui/multiplayer_chat_hud.gd") as Script
	if script == null:
		return
	_mp_chat_hud = Control.new()
	_mp_chat_hud.name = "MultiplayerChatHUD"
	_mp_chat_hud.set_script(script)
	UiScreenLayout.pin_fullscreen(_mp_chat_hud)
	var ui_layer := get_parent()
	if ui_layer != null:
		ui_layer.add_child(_mp_chat_hud)
	else:
		add_child(_mp_chat_hud)
	# Sync line, the host's review cards, edge arrows to other players.
	var act_script := load("res://scenes/ui/multiplayer_activity_hud.gd") as Script
	if act_script != null:
		var act := Control.new()
		act.name = "MultiplayerActivityHUD"
		act.set_script(act_script)
		UiScreenLayout.pin_fullscreen(act)
		if ui_layer != null:
			ui_layer.add_child(act)
		else:
			add_child(act)


func _refresh_mp_chip() -> void:
	if _mp_chip == null or Engine.is_editor_hint():
		return
	if MultiplayerSession == null or not is_instance_valid(MultiplayerSession):
		return
	_mp_chip.text = MultiplayerSession.status_label()
	if MultiplayerSession.is_active():
		_mp_chip.add_theme_color_override("font_color", UITheme.C_OK)
	elif MultiplayerSession.is_joining():
		_mp_chip.add_theme_color_override("font_color", UITheme.C_WARN)
	else:
		_mp_chip.add_theme_color_override("font_color", UITheme.C_TEXT)


func _on_conduits_chip_pressed() -> void:
	if not is_instance_valid(SimSettingsController):
		return
	SimSettingsController.set_conduits_3d_visible(
		not bool(SimSettingsController.conduits_3d_visible))
	_refresh_conduits_chip()


## Site Projects panel. Called BY STRING through ServiceLocator (the
## npc_routines_panel idiom) so this chip needs no main.gd wiring; the view's
## own opener already toasts when no population is running, so pressing it on
## a crewless map is a no-op with an explanation rather than a dead button.
func _on_projects_chip_pressed() -> void:
	var g: Node = ServiceLocator.graph()
	if g != null and g.has_method("open_site_projects"):
		g.call("open_site_projects")


## Settlement view. Toggles, so the chip is both the way in and the way back.
func _on_settlement_chip_pressed() -> void:
	if _main != null and _main.has_method("toggle_settlement_view"):
		_main.call("toggle_settlement_view")


## Festival mode. Toggles; the chip reads green while the mode is on (the
## guardrails are off then, which is worth seeing from every screen).
func _on_festival_chip_pressed() -> void:
	if _main == null or not _main.has_method("toggle_festival_mode"):
		return
	_main.call("toggle_festival_mode")
	var fm: Variant = _main.get("festival_mode")
	if fm is Node and is_instance_valid(fm) and fm.has_signal("changed") \
			and not fm.changed.is_connected(_refresh_festival_chip):
		fm.changed.connect(_refresh_festival_chip)
	_refresh_festival_chip()


func _refresh_festival_chip() -> void:
	if _festival_chip == null or _main == null:
		return
	var on := _main.has_method("festival_mode_active") and bool(_main.call("festival_mode_active"))
	_festival_chip.add_theme_color_override("font_color", UITheme.C_OK if on else UITheme.C_TEXT)


func _on_conduits_visible_signal(_enabled: bool) -> void:
	_refresh_conduits_chip()


func _refresh_conduits_chip() -> void:
	if _conduits_chip == null or Engine.is_editor_hint():
		return
	var on := false
	if is_instance_valid(SimSettingsController):
		on = bool(SimSettingsController.conduits_3d_visible)
	_conduits_chip.text = "3D wires ●" if on else "3D wires"
	_conduits_chip.add_theme_color_override("font_color",
		UITheme.C_OK if on else UITheme.C_TEXT)
	_conduits_chip.tooltip_text = (
		"3D wires ON — click to hide (improves FPS)" if on
		else "3D wires OFF — click to show graph connections in the world")


## Floating weather card — sibling on the parent UILayer, centered above the
## bar. All weather pushes from SolarUI are forwarded to it (the bar itself no
## longer renders weather).
func _setup_weather_card() -> void:
	if _weather_card != null:
		return
	var ui_layer := get_parent()
	if ui_layer == null:
		return
	if ui_layer.get_node_or_null("WeatherCardUI") != null:
		_weather_card = ui_layer.get_node_or_null("WeatherCardUI")
		return
	var script := load("res://scenes/ui/weather_card_ui.gd") as Script
	if script == null:
		return
	_weather_card = PanelContainer.new()
	_weather_card.set_script(script)
	ui_layer.add_child(_weather_card)
	stack_height_changed.connect(func(_h: float) -> void:
		if is_instance_valid(_weather_card) and _weather_card.has_method("refresh_position"):
			_weather_card.call("refresh_position"))


func _ensure_crosshair_ui() -> void:
	var ui_layer := get_parent()
	if ui_layer == null:
		return
	if ui_layer.get_node_or_null("CrosshairUI") != null:
		return
	var packed := load("res://scenes/ui/crosshair_ui.tscn") as PackedScene
	if packed != null:
		ui_layer.add_child(packed.instantiate())


func _setup_settings_panel() -> void:
	if _settings_panel != null:
		return
	var script := load("res://scenes/ui/timeline_settings_panel.gd") as Script
	if script == null:
		return
	# Use a plain Control — the script builds its own full-screen modal layout.
	_settings_panel = Control.new()
	_settings_panel.set_script(script)
	UiScreenLayout.pin_fullscreen(_settings_panel)
	# Add to the parent CanvasLayer, NOT self.  Self has clip_contents=true and
	# size.y = BAR_HEIGHT, so any child extending upward is invisible there.
	var ui_layer := get_parent()
	if ui_layer != null:
		ui_layer.add_child(_settings_panel)
	else:
		add_child(_settings_panel)
	if _settings_panel.has_method("bind_timeline"):
		_settings_panel.bind_timeline(self)


func _process(delta: float) -> void:
	PerfSpan.begin("timeline_ui")
	_perf_tick(delta)
	PerfSpan.end("timeline_ui")


## The per-frame body; `_process` above only times it.
func _perf_tick(delta: float) -> void:
	if Engine.is_editor_hint() or not _ready_done:
		return
	if _main == null:
		_try_connect_main()
		return
	if not _layout_enforced:
		_request_bar_layout()
		_layout_enforced = true
	_update_accum += delta
	if _update_accum >= UPDATE_INTERVAL:
		_update_accum = 0.0
		_update_display()


func _input(event: InputEvent) -> void:
	if Engine.is_editor_hint():
		return
	# sim_pause_toggle handled globally by CursorController._shortcut_input.
	var _fo := get_viewport().gui_get_focus_owner() if get_viewport() != null else null
	if _fo is LineEdit or _fo is TextEdit:
		return
	if event.is_action_pressed("sim_speed_up"):
		_on_dpad_right()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("sim_speed_down"):
		_on_dpad_left()
		get_viewport().set_input_as_handled()


## D-pad right: resume if paused, speed up if already playing
func _on_dpad_right() -> void:
	if _main == null or not is_instance_valid(_main):
		return
	var ts := float(_main.get("time_scale") if _main.get("time_scale") != null else 0.0)
	if ts <= 0.0 and not _analemma_active():
		# Paused or reversed — resume forward at stored speed
		_resume_forward()
		_sim_paused_by_bar = false
		CursorController.set_paused(false)
	else:
		_on_faster_pressed()
	_update_display()


## D-pad left: slow down → pause → reverse
func _on_dpad_left() -> void:
	if _main == null or not is_instance_valid(_main):
		return
	# Analemma is forward-only: a slow-down drops back to the fastest normal speed.
	if _analemma_active():
		_speed_idx = _last_finite_idx()
		_apply_speed()
		_update_display()
		return
	var ts := float(_main.get("time_scale") if _main.get("time_scale") != null else 0.0)
	if ts > 0.0:
		if _speed_idx > 0:
			_on_slower_pressed()
		else:
			_stored_scale = maxf(ts, 1e-6)
			_main.set("time_scale", 0.0)
			_sim_paused_by_bar = true
			CursorController.set_paused(true)
	elif ts == 0.0:
		var reverse := -(_stored_scale if _stored_scale > 1e-6 else float(SPEED_STEPS[_speed_idx][1]))
		_main.set("time_scale", reverse)
		_sim_paused_by_bar = false
		CursorController.set_paused(false)
	else:
		# Already reversing — speed up the reverse (more negative); never reverse
		# into the ∞ analemma preset.
		_speed_idx = min(_speed_idx + 1, _last_finite_idx())
		var val := -float(SPEED_STEPS[_speed_idx][1])
		_main.set("time_scale", val)
	_update_display()


## Returns true when this bar is holding the simulation paused (spacebar pause).
func is_sim_paused() -> bool:
	return _sim_paused_by_bar


func is_settings_open() -> bool:
	return _settings_panel != null and _settings_panel.has_method("is_open") and _settings_panel.is_open()


## Step simulation speed up one preset. Called externally (e.g. ProjectionCanvas).
func speed_up() -> void:
	_on_faster_pressed()


## Step simulation speed down one preset. Called externally (e.g. ProjectionCanvas).
func speed_down() -> void:
	_on_slower_pressed()


## Toggle simulation play/pause. Called externally (e.g. ProjectionCanvas).
func toggle_play() -> void:
	_on_play_pressed()


## Called by main.gd after save / load.
func refresh_from_main() -> void:
	_try_connect_main()
	if _main != null:
		var ts := float(_main.get("time_scale") if _main.get("time_scale") != null else 0.016667)
		if ts > 0.0:
			_stored_scale = ts
			_speed_idx    = _nearest_speed_idx(ts)
	if is_instance_valid(SimSettingsController):
		SimSettingsController.refresh_from_main()
	if _settings_panel != null and _settings_panel.has_method("refresh_from_controller"):
		_settings_panel.refresh_from_controller()
	_update_display()


# ---------------------------------------------------------------------------
# Main-node / player resolution
# ---------------------------------------------------------------------------

func _try_connect_main() -> void:
	if _main != null and is_instance_valid(_main):
		return
	_main = _find_main()
	if _main != null:
		_player = _main.get_node_or_null("Player")
		var ts := float(_main.get("time_scale") if _main.get("time_scale") != null else 0.016667)
		if ts > 0.0:
			_stored_scale = ts
			_speed_idx    = _nearest_speed_idx(ts)
		if is_nan(_track_view.start):
			_track_view.reset_to_playhead(_playhead_abs())
		_update_display()


func _find_main() -> Node:
	var p := get_parent()
	if p != null:
		var pp := p.get_parent()
		if pp != null and pp.has_method("get_lunar_phase"):
			return pp
	var tree := get_tree()
	if tree == null:
		return null
	var scene := tree.current_scene
	if scene != null and scene.has_method("get_lunar_phase"):
		return scene
	return null


func _try_connect_csv_playback() -> void:
	if _csv_playback_ui != null and is_instance_valid(_csv_playback_ui):
		return
	var p := get_parent()
	if p != null:
		_csv_playback_ui = p.get_node_or_null("CsvPlaybackUI") as CsvPlaybackUI
	if _csv_playback_ui == null and p != null:
		_csv_playback_ui = p.find_child("CsvPlaybackUI", true, false) as CsvPlaybackUI
	if _csv_playback_ui == null:
		var tree := get_tree()
		if tree != null and tree.root != null:
			var found := tree.root.find_child("CsvPlaybackUI", true, false)
			if found is CsvPlaybackUI:
				_csv_playback_ui = found as CsvPlaybackUI


func _on_csv_playback_pressed() -> void:
	# Repointed: the 📂 button now imports the CSV as an NLE clip on the timeline
	# (like dropping a video clip), instead of the old slider-based replay UI.
	_on_import_pressed()


# ---------------------------------------------------------------------------
# Display refresh
# ---------------------------------------------------------------------------

func set_weather_status_text(line: String) -> void:
	if _wx_status_lbl:
		_wx_status_lbl.text = line


## Forwarded to the floating WeatherCardUI (SolarUI keeps calling TimelineUI —
## the node-name contract stays intact).
func set_weather_cycle_display(caption: String, mod: Color, tip: String) -> void:
	if is_instance_valid(_weather_card) and _weather_card.has_method("set_source_display"):
		_weather_card.call("set_source_display", caption, mod, tip)


func set_weather_link_display(tip: String, mod: Color) -> void:
	if is_instance_valid(_weather_card) and _weather_card.has_method("set_link_display"):
		_weather_card.call("set_link_display", tip, mod)


## All inputs SI units (°C, m/s, mm/h, mm); the card converts per its unit pref.
func set_weather_stats(rad: float, temp_c: float, hum: float,
		wind_ms: float, wind_deg: float, rain_mmh: float, rain_24h_mm: float) -> void:
	if is_instance_valid(_weather_card) and _weather_card.has_method("set_weather_stats"):
		_weather_card.call("set_weather_stats",
			rad, temp_c, hum, wind_ms, wind_deg, rain_mmh, rain_24h_mm)


static func _deg_to_compass(deg: float) -> String:
	var dirs := ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
	return dirs[int(round(deg / 45.0)) % 8]


func _load_ui_prefs() -> void:
	var cfg := ConfigFile.new()
	if cfg.load("user://ui_prefs.cfg") == OK:
		_use_imperial = cfg.get_value("units", "imperial", true)
		_track_view.set_span(float(cfg.get_value("timeline", "view_span_hours", TimelineViewScript.DEFAULT_SPAN_HOURS)))
		var raw_tracks : Variant = cfg.get_value("timeline", "tracks", [])
		if raw_tracks is Array and not (raw_tracks as Array).is_empty():
			_track_layout.load_from_array(raw_tracks as Array)
	_sync_scrubber_row_height()
	_request_bar_layout()


func _save_ui_prefs() -> void:
	var cfg := ConfigFile.new()
	cfg.load("user://ui_prefs.cfg")  # preserve any other saved values
	cfg.set_value("units", "imperial", _use_imperial)
	cfg.set_value("timeline", "view_span_hours", _track_view.span)
	cfg.set_value("timeline", "tracks", _track_layout.to_array())
	cfg.save("user://ui_prefs.cfg")


func _save_track_layout_prefs() -> void:
	_save_ui_prefs()


## Tracks ▾: the tracks on the timeline (click to show / hide), then one
## submenu per kind of track to add — power (live / simulated / observed CSV),
## weather, Home Assistant (each Live link, or any sensor through the picker) —
## and one to remove a track.
var _tracks_subs: Dictionary = {}   # "power" | "weather" | "ha" | "remove" -> PopupMenu

const TRACK_SOURCE_NAMES := {"live": "live", "sim": "simulated", "observed": "observed CSV",
	"ha": "Home Assistant link", "ha_entity": "Home Assistant", "weather": "weather"}


func _setup_tracks_menu() -> void:
	if _tracks_menu != null:
		return
	_tracks_menu = PopupMenu.new()
	_tracks_menu.name = "TracksMenu"
	add_child(_tracks_menu)
	_tracks_menu.id_pressed.connect(_on_tracks_menu_id_pressed.bind(_tracks_menu))
	for key in ["power", "weather", "ha", "remove"]:
		var sub := PopupMenu.new()
		sub.name = "Tracks_%s" % key
		_tracks_menu.add_child(sub)
		sub.id_pressed.connect(_on_tracks_menu_id_pressed.bind(sub))
		_tracks_subs[key] = sub
	_rebuild_tracks_menu()


func _track_menu_add(menu: PopupMenu, text: String, meta: Variant, disabled: bool = false) -> void:
	var id := menu.item_count
	menu.add_item(text, id)
	menu.set_item_metadata(menu.get_item_index(id), meta)
	menu.set_item_disabled(menu.get_item_index(id), disabled)


func _rebuild_tracks_menu() -> void:
	if _tracks_menu == null:
		return
	_tracks_menu.clear()
	for sub in _tracks_subs.values():
		(sub as PopupMenu).clear()
	var shown := 0
	for t_v in _track_layout.tracks:
		if not (t_v is TimelineTrackDef):
			continue
		var td : TimelineTrackDef = t_v as TimelineTrackDef
		if td.kind == TimelineTrackDef.KIND_CLIPS:
			continue
		var src := str(TRACK_SOURCE_NAMES.get(td.source, td.source))
		_track_menu_add(_tracks_menu, "%s %s  (%s)" % ["✓" if td.enabled else "   ", td.label, src], td.id)
		_track_menu_add(_tracks_subs["remove"], "%s  (%s)" % [td.label, src], {"remove": td.id})
		shown += 1
	if shown > 0:
		_tracks_menu.add_separator()
	# Power: the energy timeline's channels, each as live / simulated / CSV.
	var power: PopupMenu = _tracks_subs["power"]
	for ch in TimelineTrackDef.channel_catalog():
		var cid := str(ch.get("id", ""))
		for src in ch.get("sources", []):
			_track_menu_add(power, "%s (%s)" % [str(ch.get("label", cid)), str(TRACK_SOURCE_NAMES.get(str(src), src))],
				{"add": cid, "source": str(src)})
	_tracks_menu.add_submenu_node_item("Add power track", power)
	# Weather: WeatherService's variables (the loaded archive / forecast).
	var wx: PopupMenu = _tracks_subs["weather"]
	for ch in TimelineWeatherChannels.CHANNELS:
		_track_menu_add(wx, str(ch["label"]), {"add_weather": str(ch["id"])})
	_tracks_menu.add_submenu_node_item("Add weather track", wx)
	# Home Assistant: each Live link (in the value's own unit), then any sensor.
	var ha: PopupMenu = _tracks_subs["ha"]
	var svc := get_node_or_null("/root/HomeAssistant")
	var connected := svc != null and bool(svc.call("is_authed"))
	_track_menu_add(ha, "Pick any sensor…" if connected else "Pick any sensor… (connect Home Assistant first)",
		{"pick_ha": true}, not connected)
	var linker := _ha_linker()
	if linker != null:
		var first := true
		for l in linker.call("links"):
			var tid := str(l.get("target_id", ""))
			var t: Dictionary = linker.call("target", tid)
			if t.is_empty():
				continue
			if first:
				ha.add_separator("Linked values")
				first = false
			_track_menu_add(ha, str(t.get("label", tid)), {"add_ha": tid, "label": str(t.get("label", tid))})
	_tracks_menu.add_submenu_node_item("Add Home Assistant track", ha)
	if shown > 0:
		_tracks_menu.add_separator()
		_tracks_menu.add_submenu_node_item("Remove a track", _tracks_subs["remove"])


func _ha_linker() -> Node:
	var g := ServiceLocator.graph()
	return g.get("_ha_linker") if g != null else null


func _on_tracks_pressed() -> void:
	_rebuild_tracks_menu()
	if _tracks_menu == null or _tracks_btn == null:
		return
	var pos := _tracks_btn.global_position + Vector2(0.0, _tracks_btn.size.y)
	_tracks_menu.position = pos
	_tracks_menu.popup()


## Metadata is looked up by the item's INDEX: the old handler read it with
## the id, so every "＋ add" item (ids from 1000) found nothing and did nothing.
func _on_tracks_menu_id_pressed(id : int, menu : PopupMenu) -> void:
	if menu == null:
		return
	var idx := menu.get_item_index(id)
	if idx < 0:
		return
	var meta : Variant = menu.get_item_metadata(idx)
	if meta is Dictionary and meta.has("pick_ha"):
		_open_ha_sensor_picker()
		return
	if meta is Dictionary and meta.has("add_ha"):
		var dh : Dictionary = meta as Dictionary
		_track_layout.add_ha_track(str(dh["add_ha"]), str(dh.get("label", "")))
	elif meta is Dictionary and meta.has("add_weather"):
		_track_layout.add_weather_track(str(meta["add_weather"]))
	elif meta is Dictionary and meta.has("add"):
		var d : Dictionary = meta as Dictionary
		_track_layout.add_waveform_track(str(d.get("add", "")), str(d.get("source", "live")))
	elif meta is Dictionary and meta.has("remove"):
		_track_layout.remove_track(str(meta["remove"]))
		_waveform_cache.clear()
	elif meta is String:
		var track : TimelineTrackDef = _track_layout.find_track(str(meta))
		if track != null:
			track.enabled = not track.enabled
	else:
		return
	_tracks_changed()


func _tracks_changed() -> void:
	_save_track_layout_prefs()
	_sync_scrubber_row_height()
	_request_bar_layout()
	if _track != null:
		_track.queue_redraw()


## Any Home Assistant sensor as a track: the entity picker, then a track.
func add_ha_entity_track(entity_id : String, label : String) -> void:
	_track_layout.add_ha_entity_track(entity_id, label)
	var svc := get_node_or_null("/root/HomeAssistant")
	if svc != null:
		svc.call("track_entity", entity_id)
	_tracks_changed()


func _open_ha_sensor_picker() -> void:
	var script := load("res://scenes/ui/ha_entity_picker.gd") as Script
	if script == null:
		return
	var picker := Node.new()
	picker.set_script(script)
	add_child(picker)
	picker.call("open", "Add a Home Assistant track", "Its readings are recorded while the game runs, and the window on screen is filled in from Home Assistant's history.",
		func(eid: String, label: String) -> void: add_ha_entity_track(eid, label))


func _ensure_solar_ref() -> void:
	if is_instance_valid(_solar_ui):
		return
	var p := get_parent()
	if p != null:
		_solar_ui = p.get_node_or_null("SolarUI")


func _update_hold_pill() -> void:
	if _hold_lbl == null:
		return
	var owner := ""
	if _main != null and _main.has_method("clock_hold_owner"):
		owner = str(_main.call("clock_hold_owner"))
	if owner == _hold_owner:
		return
	_hold_owner = owner
	_hold_lbl.visible = not owner.is_empty()
	if owner.is_empty():
		return
	var label := str(CLOCK_HOLD_LABELS.get(owner, owner.replace("_", " ")))
	_hold_lbl.text = "⏸ held · %s" % label
	_hold_lbl.tooltip_text = ("The clock is paused by %s. Play and the speed buttons "
			+ "take effect when it lets go.") % label


func _update_display() -> void:
	if not is_instance_valid(_main):
		return
	_ensure_solar_ref()

	# ── Time scrubber (multi-day absolute track) ─────────────────────────────
	var dt : float = float(_main.get("day_time") if _main.get("day_time") != null else 0.0)
	if _track != null:
		_track.queue_redraw()
		_update_track_edge_labels()
	_update_nle_controls()

	# ── Time label ───────────────────────────────────────────────────────────
	_time_lbl.text = _fmt_hour_full(dt)

	# ── Date spinboxes (always derived from the canonical absolute timecode) ──
	_date_syncing = true
	var yr : int = int(_main.get("year")  if _main.get("year")  != null else 2025)
	var mo : int = int(_main.get("month") if _main.get("month") != null else 1)
	var dy : int = int(_main.get("day")   if _main.get("day")   != null else 1)
	var clk_spin : CelestialClock = _track_clock()
	var ph_spin := _playhead_abs()
	if clk_spin != null:
		var dd : Dictionary = clk_spin.abs_hours_to_date(ph_spin)
		if not dd.is_empty():
			yr = int(dd.get("year", yr))
			mo = int(dd.get("month", mo))
			dy = int(dd.get("day", dy))
	if _year_input:
		_year_input.set_value_no_signal(yr)
	if _month_input:
		_month_input.set_value_no_signal(mo)
	if _day_input:
		_update_day_spin_max(mo, yr)
		_day_input.set_value_no_signal(dy)
	_date_syncing = false

	# ── Sunrise / sunset ─────────────────────────────────────────────────────
	var sr : float = float(_main.get("sunrise_hour") if _main.get("sunrise_hour") != null else 6.0)
	var ss : float = float(_main.get("sunset_hour")  if _main.get("sunset_hour")  != null else 18.0)
	_sunrise_lbl.text = "🌅 %s" % _fmt_hour_short(sr)
	_sunset_lbl.text  = "🌇 %s" % _fmt_hour_short(ss)

	# ── Moon ─────────────────────────────────────────────────────────────────
	if _main.has_method("get_lunar_phase"):
		var phase    : float  = _main.get_lunar_phase()
		var phase_nm : String = _main.get_lunar_phase_name()
		var idx : int = int(round(phase * 7.999)) % 8
		var short_nm := phase_nm.split(" ")[0] if not phase_nm.is_empty() else phase_nm
		_moon_lbl.text = "%s %s" % [MOON_EMOJIS[idx], short_nm]

	# ── Play / speed ─────────────────────────────────────────────────────────
	var ts : float = float(_main.get("time_scale") if _main.get("time_scale") != null else 0.0)
	var analemma := _analemma_active()
	_is_playing    = ts > 0.0 or analemma
	var play_text := "⏸" if _is_playing else ("◀" if ts < 0.0 else "▶")
	if _play_btn.text != play_text:
		_play_btn.text = play_text
	# The ring border and icon colour signal play/pause state. Written only
	# when the state CHANGES: two StyleBoxFlats and four theme overrides every
	# 0.1 s re-themed the button (and re-laid out its row) while nothing moved.
	var ring_key := 1 if _is_playing else 0
	if ring_key != _play_ring_key:
		_play_ring_key = ring_key
		var ring_col   : Color = C_AMBER if _is_playing else C_PRIMARY
		var sb_n := StyleBoxFlat.new()
		sb_n.bg_color   = Color(ring_col.r * 0.22, ring_col.g * 0.22, ring_col.b * 0.22, 1.0)
		sb_n.border_color = Color(ring_col.r, ring_col.g, ring_col.b, 0.90)
		sb_n.set_border_width_all(2)
		sb_n.set_corner_radius_all(21)
		var sb_h := sb_n.duplicate() as StyleBoxFlat
		sb_h.bg_color   = Color(ring_col.r * 0.38, ring_col.g * 0.38, ring_col.b * 0.38, 1.0)
		sb_h.border_color = ring_col
		_play_btn.add_theme_stylebox_override("normal",  sb_n)
		_play_btn.add_theme_stylebox_override("hover",   sb_h)
		_play_btn.add_theme_stylebox_override("pressed", sb_h)
		_play_btn.add_theme_color_override("font_color",
			Color(ring_col.r * 1.6, ring_col.g * 1.6, ring_col.b * 1.6, 1.0).clamp())
	if _is_playing and ts > 0.0:
		_stored_scale = ts
		_speed_idx    = _nearest_speed_idx(ts)
	_speed_lbl.text = str(SPEED_STEPS[_speed_idx][0])
	_update_hold_pill()

	# Keep the centre cluster optically centred as the clock/date text width
	# changes (e.g. "12:00 PM" → "9:00 AM").
	_layout_info_clusters()


# ---------------------------------------------------------------------------
# Button callbacks
# ---------------------------------------------------------------------------

func _on_play_pressed() -> void:
	if _main == null or not is_instance_valid(_main):
		return
	if get_viewport() != null:
		get_viewport().gui_release_focus()
	var ts := float(_main.get("time_scale") if _main.get("time_scale") != null else 0.0)
	if ts > 0.0 or _analemma_active():
		if ts > 0.0:
			_stored_scale = maxf(ts, 1e-6)
		_pause_motion()
		_sim_paused_by_bar = true
		CursorController.set_paused(true)
	else:
		_resume_forward()
		_sim_paused_by_bar = false
		CursorController.set_paused(false)
	_update_display()


func _on_slower_pressed() -> void:
	_speed_idx = max(_speed_idx - 1, 0)
	_apply_speed()


func _on_faster_pressed() -> void:
	_speed_idx = min(_speed_idx + 1, SPEED_STEPS.size() - 1)
	_apply_speed()


## True when the current preset is the ∞ / analemma step.
func _is_analemma_idx() -> bool:
	return is_inf(float(SPEED_STEPS[_speed_idx][1]))


## Calendar days per analemma frame (1 for ∞, 2 for ∞×2).
func _analemma_days_per_frame() -> int:
	if not _is_analemma_idx():
		return 1
	if str(SPEED_STEPS[_speed_idx][0]) == "∞×2":
		return 2
	return 1


func _push_analemma_days() -> void:
	if _main == null or not is_instance_valid(_main):
		return
	if _main.get("analemma_days_per_frame") != null:
		_main.set("analemma_days_per_frame", _analemma_days_per_frame())


## Highest preset index that is a normal (finite) playback speed.
func _last_finite_idx() -> int:
	for i in range(SPEED_STEPS.size() - 1, -1, -1):
		if is_finite(float(SPEED_STEPS[i][1])):
			return i
	return 0


## True when main is currently running the analemma stepper.
func _analemma_active() -> bool:
	if _main == null or not is_instance_valid(_main):
		return false
	var v: Variant = _main.get("analemma_mode")
	return v != null and bool(v)


## Push "play forward at the current preset" to main, routing the ∞ preset to
## the analemma stepper (visual-only; time_scale stays 0 so nothing integrates).
func _resume_forward() -> void:
	if _main == null or not is_instance_valid(_main):
		return
	if _is_analemma_idx():
		_main.set("analemma_mode", true)
		_main.set("time_scale", 0.0)
		_push_analemma_days()
		_recenter_track_on_playhead()
	else:
		var resume := _stored_scale if _stored_scale > 1e-6 else float(SPEED_STEPS[_speed_idx][1])
		_main.set("analemma_mode", false)
		_main.set("time_scale", resume)


## Stop all motion (normal pause or leaving analemma).
func _pause_motion() -> void:
	if _main == null or not is_instance_valid(_main):
		return
	_main.set("analemma_mode", false)
	_main.set("time_scale", 0.0)


func _apply_speed() -> void:
	var val := float(SPEED_STEPS[_speed_idx][1])
	if _main != null and is_instance_valid(_main):
		if is_inf(val):
			# Analemma preset: drive the stepper instead of a continuous scale.
			_main.set("analemma_mode", _is_playing)
			_push_analemma_days()
			if _is_playing:
				_main.set("time_scale", 0.0)
		else:
			_stored_scale = val
			_main.set("analemma_mode", false)
			if _is_playing:
				_main.set("time_scale", val)
	elif is_finite(val):
		_stored_scale = val
	_speed_lbl.text = str(SPEED_STEPS[_speed_idx][0])


func _on_time_scrubber_changed(value: float) -> void:
	# Legacy 24h-slider callback (slider retired). Kept for compatibility.
	if _scrubber_updating or _main == null:
		return
	_main.set("day_time", value)
	_update_display()


# ---------------------------------------------------------------------------
# Multi-day absolute-time track (NOW marker + provenance bands)
# ---------------------------------------------------------------------------

func _track_clock() -> CelestialClock:
	if _main != null and is_instance_valid(_main):
		var c : Variant = _main.get("clock")
		if c is CelestialClock:
			return c as CelestialClock
	return null


func _sync_track_view() -> void:
	if _track == null:
		return
	_track_view.width_px = _track.size.x
	var ph := _playhead_abs()
	_track_view.apply_playhead_follow(ph)
	# When the user panned away, still snap if the playhead is completely off-screen.
	if not _track_view.contains_time(ph):
		_track_view.reset_to_playhead(ph)


func _recenter_track_on_playhead() -> void:
	if _track == null:
		return
	_track_view.width_px = _track.size.x
	_track_view.reset_to_playhead(_playhead_abs())


## [start, span] of the track's window in hours. 64-bit: as a Vector2 the
## start (~1.8e7 h) was rounded to 2 h, so everything drawn on the track
## moved in 2-hour jumps while panning.
func _track_window() -> PackedFloat64Array:
	_sync_track_view()
	return PackedFloat64Array([_track_view.start, _track_view.span])


func _resolve_td() -> void:
	if _td == null or not is_instance_valid(_td):
		_td = get_node_or_null("/root/TimeDirector")

func _playhead_abs() -> float:
	if _main != null and is_instance_valid(_main) and _main.has_method("get_absolute_hours"):
		return float(_main.call("get_absolute_hours"))
	return 0.0

func _now_abs() -> float:
	_resolve_td()
	if _td != null:
		return float(_td.get("now_abs_hours"))
	return _playhead_abs()

func _update_track_edge_labels() -> void:
	if _track_lbl_start == null or _track_lbl_end == null:
		return
	var win := _track_window()
	var clk : CelestialClock = _track_clock()
	_track_lbl_start.text = _track_view.format_edge_label(win[0], win[1], clk)
	_track_lbl_end.text = _track_view.format_edge_label(win[0] + win[1], win[1], clk)
	var zoom_lbl : String = TimelineView.span_label(win[1])
	if _track != null:
		_track.tooltip_text = (
			"Drag: scrub  •  Ctrl-drag: render range  •  Wheel: zoom  •  Alt/MMB-drag: pan\n"
			+ "Drag track bottom edge to resize  •  Tracks button: add/hide channels\n"
			+ "White = NOW  •  View: %s  •  Alt+Right-click: re-center on playhead" % zoom_lbl
		)

## "Mon D" for an absolute-hours value (uses the sim clock calendar).
func _short_date_for_abs(abs_hours: float) -> String:
	var clk : CelestialClock = _track_clock()
	if clk != null:
		var dd: Dictionary = clk.abs_hours_to_date(abs_hours)
		if not dd.is_empty():
			var mo := int(dd.get("month", 1))
			var day := int(dd.get("day", 1))
			return "%s %d" % [MONTH_NAMES[clamp(mo - 1, 0, 11)], day]
	return ""

func _draw_track() -> void:
	if _track == null:
		return
	var w := _track.size.x
	var h := _track.size.y
	if w <= 1.0 or h <= 1.0:
		return
	var win := _track_window()
	var win_start := win[0]
	var span := win[1]
	var ph := _playhead_abs()
	var now := _now_abs()
	var fnt := ThemeDB.fallback_font

	# ── Time ruler (top portion) ─────────────────────────────────────────────
	var groove_y := 13.0

	# Provenance bands behind the groove.
	var playback := false
	_resolve_td()
	if _td != null and _td.has_method("is_playback"):
		playback = bool(_td.call("is_playback"))
	var band_top := groove_y - 6.0
	var band_h := 12.0
	if playback:
		_track.draw_rect(Rect2(0, band_top, w, band_h), C_RECORDED, true)
	else:
		var now_x : float = clampf((now - win_start) / span * w, 0.0, w)
		if now_x > 0.0:
			_track.draw_rect(Rect2(0, band_top, now_x, band_h), C_OBSERVED, true)
		if now_x < w:
			_track.draw_rect(Rect2(now_x, band_top, w - now_x, band_h), C_PROJECTED, true)

	# Groove baseline.
	_track.draw_line(Vector2(0, groove_y), Vector2(w, groove_y), C_BORDER, 2.0)

	# ── NWS alert spans (Phase 3) ─────────────────────────────────────────────
	var _alert_svc := get_node_or_null("/root/NwsAlertService")
	if _alert_svc != null:
		var _alerts: Array = _alert_svc.get_alerts_in_range(win_start, win_start + span)
		for _alert in _alerts:
			var _a0 := float(_alert.get("onset_abs", NAN))
			var _a1 := float(_alert.get("expires_abs", NAN))
			if is_nan(_a0) or is_nan(_a1) or _a1 <= _a0:
				continue
			var _ax0 := clampf((_a0 - win_start) / span * w, 0.0, w)
			var _ax1 := clampf((_a1 - win_start) / span * w, 0.0, w)
			if _ax1 <= _ax0:
				continue
			var _cat := str(_alert.get("category", "advisory"))
			var _col: Color = NWS_ALERT_SERVICE_SCRIPT.color_for_category(_cat)
			_track.draw_rect(Rect2(_ax0, band_top - 2.0, _ax1 - _ax0, band_h + 4.0), _col, true)
			# 1.5 px solid left edge for legibility on narrow spans.
			_track.draw_line(Vector2(_ax0, band_top - 2.0), Vector2(_ax0, band_top + band_h + 2.0),
				Color(_col.r, _col.g, _col.b, 0.85), 1.5)

	# ── Temperature record pips (Phase 4) — day zoom only ─────────────────────
	if WeatherService.has_records() and span <= 60.0 * 24.0:
		var _pip_y: float = groove_y - 9.0
		var _d_pip: float = floor(win_start / 24.0)
		var _pip_now := Time.get_ticks_msec() / 1000.0
		while _d_pip * 24.0 <= win_start + span:
			# Noon-temperature/record lookup only depends on which calendar day
			# this is, not the live playhead — cache per day (TTL-bounded so a
			# location/dataset change still refreshes quickly) instead of
			# re-querying WeatherService on every ~10 fps track redraw.
			var _day_key := int(_d_pip)
			var _pip_cached: Dictionary = _weather_pip_cache.get(_day_key, {})
			var _rec: Dictionary
			var _sim_t: float
			if _pip_cached.has("t") and _pip_now - float(_pip_cached["t"]) < WEATHER_PIP_CACHE_TTL:
				_rec = _pip_cached.get("rec", {})
				_sim_t = float(_pip_cached.get("sim_t", NAN))
			else:
				_rec = {}
				_sim_t = NAN
				var _md := _month_day_for_abs(_d_pip * 24.0)
				if _md.x > 0:
					_rec = WeatherService.get_records(_md.x, _md.y)
					if not _rec.is_empty():
						_sim_t = WeatherService.temperature_c(_md.x, _md.y, 12.0)
				_weather_pip_cache[_day_key] = {"rec": _rec, "sim_t": _sim_t, "t": _pip_now}
			if not _rec.is_empty():
				var _px_pip: float = (_d_pip * 24.0 - win_start) / span * w
				if _px_pip >= 0.0 and _px_pip <= w and not is_nan(_sim_t):
					if _sim_t >= float(_rec.get("high", 1e9)):
						_track.draw_circle(Vector2(_px_pip, _pip_y), 3.0,
							Color(1.0, 0.25, 0.25, 0.9))
					elif _sim_t <= float(_rec.get("low", -1e9)):
						_track.draw_circle(Vector2(_px_pip, _pip_y), 3.0,
							Color(0.25, 0.50, 1.0, 0.9))
			_d_pip += 1.0

	# Adaptive ruler ticks (major + minor).
	var clk : CelestialClock = _track_clock()
	var tick_info : Dictionary = _track_view.collect_ticks(clk)
	var major_iv : float = float(tick_info.get("major_interval", 24.0))
	for t_minor in tick_info.get("minor", []):
		var mx : float = _track_view.time_to_x(float(t_minor))
		if mx >= 0.0 and mx <= w:
			_track.draw_line(Vector2(mx, groove_y - 3.0), Vector2(mx, groove_y + 3.0),
				Color(C_TEXT_M.r, C_TEXT_M.g, C_TEXT_M.b, 0.45), 1.0)
	for t_major in tick_info.get("major", []):
		var tx : float = _track_view.time_to_x(float(t_major))
		if tx >= 0.0 and tx <= w:
			_track.draw_line(Vector2(tx, groove_y - 5.0), Vector2(tx, groove_y + 5.0), C_TEXT_M, 1.0)
			var lbl : String = _track_view.format_tick_label(float(t_major), major_iv, clk)
			if not lbl.is_empty():
				_track.draw_string(fnt, Vector2(tx + 2.0, groove_y - 7.0),
					lbl, HORIZONTAL_ALIGNMENT_LEFT, -1, 8, C_TEXT_M)

	_draw_microclimate_strip(win_start, span, w, groove_y)

	# ── NLE lanes (clips + resizable sensor waveforms) ───────────────────────
	var lanes_top := TimelineTrackLayout.RULER_HEIGHT
	var lanes_bottom := lanes_top
	var s := null if Engine.is_editor_hint() else _get_solar()
	lanes_bottom = _draw_track_lanes(win_start, span, w, fnt, s, lanes_top)
	if s != null and s.has_method("get_selection_abs"):
		var sel : PackedFloat64Array = s.call("get_selection_abs")
		if not is_nan(sel[0]) and sel[1] > sel[0]:
			var sx0 := clampf((sel[0] - win_start) / span * w, 0.0, w)
			var sx1 := clampf((sel[1] - win_start) / span * w, 0.0, w)
			_track.draw_rect(Rect2(sx0, lanes_top - 2.0, sx1 - sx0, lanes_bottom - lanes_top + 4.0),
				SEL_FILL, true)
			_track.draw_line(Vector2(sx0, lanes_top - 2.0), Vector2(sx0, lanes_bottom + 2.0), SEL_EDGE, 1.0)
			_track.draw_line(Vector2(sx1, lanes_top - 2.0), Vector2(sx1, lanes_bottom + 2.0), SEL_EDGE, 1.0)

	# ── NOW marker (white) + playhead (amber), full height ────────────────────
	var nx := (now - win_start) / span * w
	if nx >= 0.0 and nx <= w:
		_track.draw_line(Vector2(nx, 2.0), Vector2(nx, h - 2.0), Color(1, 1, 1, 0.85), 2.0)
		_track.draw_string(fnt, Vector2(minf(nx + 3.0, w - 28.0), 10.0),
			"NOW", HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color(1, 1, 1, 0.9))

	var px : float = clampf((ph - win_start) / span * w, 0.0, w)
	_track.draw_line(Vector2(px, 0.0), Vector2(px, h), C_AMBER, 2.0)
	_track.draw_colored_polygon(
		PackedVector2Array([Vector2(px - 5, 0), Vector2(px + 5, 0), Vector2(px, 6)]), C_AMBER)


## Microclimate strip under the ruler groove: the automatic fog as a white
## band, each calibration rule as a lavender band, nearest-match as a faint
## one — so a rule made from one foggy night visibly recurs on the others.
## Skipped beyond two weeks of span (hourly resolution stops meaning anything).
## The microclimate sweep is up to 337 dict rows (a 14-day window, hourly),
## and the track redraws at 10 Hz: the rows are recomputed only when the
## window moves or MC_SWEEP_TTL_S has passed (a drawer edit lands within it).
const MC_SWEEP_TTL_S := 1.0
var _mc_sweep_rows: Array = []
var _mc_sweep_key := PackedFloat64Array([INF, INF])
var _mc_sweep_at_ms := -100000


func _mc_sweep_rows_for(mc: Node, win_start: float, span: float) -> Array:
	var key := PackedFloat64Array([win_start, span])
	var now_ms := Time.get_ticks_msec()
	if key != _mc_sweep_key or now_ms - _mc_sweep_at_ms > int(MC_SWEEP_TTL_S * 1000.0):
		_mc_sweep_rows = mc.call("sweep", win_start, win_start + span)
		_mc_sweep_key = key
		_mc_sweep_at_ms = now_ms
	return _mc_sweep_rows


func _draw_microclimate_strip(win_start : float, span : float, w : float, groove_y : float) -> void:
	if span > 14.0 * 24.0:
		return
	var mc := get_node_or_null("/root/Microclimate")
	if mc == null or not bool(mc.get("enabled")):
		return
	var rows: Array = _mc_sweep_rows_for(mc, win_start, span)
	if rows.is_empty():
		return
	# Inside the provenance band, just under the groove (the ruler is 14 px).
	var y := groove_y + 1.0
	var px_per_h := w / span
	for r in rows:
		var x0 := (float(r["h"]) - win_start) * px_per_h
		if x0 > w or x0 + px_per_h < 0.0:
			continue
		var fog := float(r["auto_fog"])
		if fog > 0.05:
			_track.draw_rect(Rect2(x0, y, px_per_h + 0.5, 2.0), Color(0.92, 0.94, 0.97, 0.25 + 0.55 * fog), true)
		var rw := 0.0
		for k in (r["rules"] as Dictionary):
			rw = maxf(rw, float(r["rules"][k]))
		if rw > 0.05:
			_track.draw_rect(Rect2(x0, y + 2.0, px_per_h + 0.5, 2.5),
				Color(C_LAVENDER.r, C_LAVENDER.g, C_LAVENDER.b, 0.25 + 0.65 * rw), true)
		var nw := float(r["nearest"])
		if nw > 0.05:
			_track.draw_rect(Rect2(x0, y + 4.5, px_per_h + 0.5, 1.5),
				Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.2 + 0.5 * nw), true)


func _draw_track_lanes(win_start : float, span : float, w : float, fnt : Font,
		solar : Node, y_start : float) -> float:
	var y := y_start
	for t_v in _track_layout.enabled_tracks():
		if not (t_v is TimelineTrackDef):
			continue
		var td : TimelineTrackDef = t_v as TimelineTrackDef
		y += TimelineTrackLayout.TRACK_GAP
		var lane_rect := Rect2(0.0, y, w, td.height)
		if td.kind == TimelineTrackDef.KIND_CLIPS:
			_draw_clips_lane(lane_rect, win_start, span, w, solar, fnt)
		else:
			_draw_waveform_lane(td, lane_rect, win_start, span, w, fnt, solar)
		if td.kind != TimelineTrackDef.KIND_CLIPS:
			_track.draw_line(Vector2(0.0, lane_rect.end.y), Vector2(w, lane_rect.end.y),
				Color(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.65), 1.0)
		y += td.height
	return y


func _draw_clips_lane(lane_rect : Rect2, win_start : float, span : float, w : float,
		solar : Node, fnt : Font) -> void:
	var lane_h := lane_rect.size.y
	var lane_y := lane_rect.position.y
	# The top of the clips lane is the sim render strip (green = rendered, red
	# = selected but not), like Premiere's bar above the sequence.
	var strip_h := minf(RENDER_STRIP_H, maxf(lane_h - 8.0, 0.0))
	if strip_h > 0.0:
		_draw_render_strip(lane_y, strip_h, win_start, span, w, solar)
		lane_y += strip_h
		lane_h -= strip_h
	var quarter := lane_h / 4.0
	_track.draw_rect(lane_rect, Color(LANE_OBS_BG.r, LANE_OBS_BG.g, LANE_OBS_BG.b, 0.35), true)
	_track.draw_string(fnt, Vector2(3.0, lane_y + quarter * 0.8), "OBS",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 7, Color(LANE_OBS_FILL.r, LANE_OBS_FILL.g, LANE_OBS_FILL.b, 0.75))
	_track.draw_string(fnt, Vector2(3.0, lane_y + quarter * 1.8), "SIM",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 7, Color(LANE_SIM_FILL.r, LANE_SIM_FILL.g, LANE_SIM_FILL.b, 0.75))
	_track.draw_string(fnt, Vector2(3.0, lane_y + quarter * 2.8), "CLIM",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 7, Color(LANE_CLIM_FILL.r, LANE_CLIM_FILL.g, LANE_CLIM_FILL.b, 0.75))
	_track.draw_string(fnt, Vector2(3.0, lane_y + quarter * 3.7), "VID",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 7, Color(LANE_VID_FILL.r, LANE_VID_FILL.g, LANE_VID_FILL.b, 0.75))
	if solar != null:
		if solar.has_method("get_observed_range_abs"):
			var orng : PackedFloat64Array = solar.call("get_observed_range_abs")
			if not is_nan(orng[0]):
				_draw_clip(orng[0], orng[1], win_start, span, w, lane_y, quarter, LANE_OBS_FILL)
		if solar.has_method("get_rendered_range_abs"):
			var rrng : PackedFloat64Array = solar.call("get_rendered_range_abs")
			if not is_nan(rrng[0]):
				_draw_clip(rrng[0], rrng[1], win_start, span, w,
					lane_y + quarter, quarter, LANE_SIM_FILL)
				if solar.has_method("is_rendering") and bool(solar.call("is_rendering")):
					var prog := clampf(float(solar.call("get_render_progress")), 0.0, 1.0)
					var fx0 := clampf((rrng[0] - win_start) / span * w, 0.0, w)
					var fx1 := clampf((rrng[0] + (rrng[1] - rrng[0]) * prog - win_start) / span * w, 0.0, w)
					if fx1 > fx0:
						_track.draw_rect(Rect2(fx0, lane_y + quarter, fx1 - fx0, quarter),
							Color(LANE_SIM_FILL.r, LANE_SIM_FILL.g, LANE_SIM_FILL.b, 0.9), true)
	var tl := _get_terrain_loader()
	if tl != null and tl.has_method("get_climelapse_range_abs"):
		var crng : PackedFloat64Array = tl.call("get_climelapse_range_abs")
		if not is_nan(crng[0]):
			_draw_clip(crng[0], crng[1], win_start, span, w, lane_y + quarter * 2.0, quarter, LANE_CLIM_FILL)
			if tl.has_method("is_climelapse_rendering") and bool(tl.call("is_climelapse_rendering")):
				var cprog := clampf(float(tl.call("get_climelapse_progress")), 0.0, 1.0)
				var cx0 := clampf((crng[0] - win_start) / span * w, 0.0, w)
				var cx1 := clampf((crng[0] + (crng[1] - crng[0]) * cprog - win_start) / span * w, 0.0, w)
				if cx1 > cx0:
					_track.draw_rect(Rect2(cx0, lane_y + quarter * 2.0, cx1 - cx0, quarter),
						Color(LANE_CLIM_FILL.r, LANE_CLIM_FILL.g, LANE_CLIM_FILL.b, 0.9), true)
	var pc := _get_projection_canvas()
	if pc != null and pc.has_method("get_video_clip_range_abs"):
		var vrng : PackedFloat64Array = pc.call("get_video_clip_range_abs")
		if not is_nan(vrng[0]):
			_draw_clip(vrng[0], vrng[1], win_start, span, w, lane_y + quarter * 3.0, quarter, LANE_VID_FILL)
	_clim_lane_rect = Rect2(0.0, lane_y + quarter * 2.0, w, quarter)
	_draw_clim_keys(tl, win_start, span, w)


## Camera keyframes as diamonds on the CLIM sub-lane, joined by a thin line —
## drag one to retime it, right-click for its menu, double-click to jump there.
func _draw_clim_keys(tl : Node, win_start : float, span : float, w : float) -> void:
	if tl == null or not tl.has_method("climelapse_keys"):
		return
	var keys : ClimelapseKeyframes = tl.call("climelapse_keys")
	if keys == null or keys.is_empty():
		return
	var cy := _clim_lane_rect.position.y + _clim_lane_rect.size.y * 0.5
	var r := clampf(_clim_lane_rect.size.y * 0.5 + 2.0, 4.0, 6.0)
	var ts := keys.times()
	var xs := PackedFloat32Array()
	for i in ts.size():
		var t := ts[i]
		if i == _clim_key_drag and not is_nan(_clim_key_drag_t):
			t = _clim_key_drag_t
		xs.append((t - win_start) / span * w)
	if xs.size() >= 2:
		var lo := clampf(xs[0], 0.0, w)
		var hi := clampf(xs[0], 0.0, w)
		for x in xs:
			lo = minf(lo, clampf(x, 0.0, w))
			hi = maxf(hi, clampf(x, 0.0, w))
		if hi > lo:
			_track.draw_line(Vector2(lo, cy), Vector2(hi, cy),
				Color(LANE_CLIM_FILL.r, LANE_CLIM_FILL.g, LANE_CLIM_FILL.b, 0.7), 1.0)
	for i in xs.size():
		var x := xs[i]
		if x < -r or x > w + r:
			continue
		var hot := i == _clim_key_drag or i == _clim_key_menu_idx
		var col := Color(1.0, 0.85, 0.35) if hot else Color(0.86, 0.72, 1.0)
		var pts := PackedVector2Array([Vector2(x, cy - r), Vector2(x + r, cy),
			Vector2(x, cy + r), Vector2(x - r, cy)])
		_track.draw_colored_polygon(pts, col)
		pts.append(pts[0])
		_track.draw_polyline(pts, Color(0.1, 0.05, 0.2, 0.9), 1.0)


## Index of the keyframe diamond under track point `p`, else -1.
func _clim_key_at(p : Vector2) -> int:
	var tl := _get_terrain_loader()
	if tl == null or not tl.has_method("climelapse_keys") or _clim_lane_rect.size.x <= 0.0:
		return -1
	var cy := _clim_lane_rect.position.y + _clim_lane_rect.size.y * 0.5
	if absf(p.y - cy) > CLIM_KEY_HIT_PX + 2.0:
		return -1
	var keys : ClimelapseKeyframes = tl.call("climelapse_keys")
	if keys == null:
		return -1
	var win := _track_window()
	var best := -1
	var best_d := CLIM_KEY_HIT_PX
	var ts := keys.times()
	for i in ts.size():
		var x := (ts[i] - win[0]) / win[1] * _clim_lane_rect.size.x
		var d := absf(x - p.x)
		if d <= best_d:
			best_d = d
			best = i
	return best


func _clim_key_time(i : int) -> float:
	var tl := _get_terrain_loader()
	if tl == null:
		return 0.0
	return float((tl.call("climelapse_keys") as ClimelapseKeyframes).key(i).get("t", 0.0))


func _on_clim_lane_right_click(p : Vector2) -> void:
	var tl := _get_terrain_loader()
	if tl == null or not tl.has_method("climelapse_keys"):
		return
	if _clim_key_menu == null:
		_clim_key_menu = PopupMenu.new()
		_clim_key_menu.id_pressed.connect(_on_clim_key_menu)
		_clim_key_menu.popup_hide.connect(func() -> void:
			_clim_key_menu_idx = -1
			if _track != null:
				_track.queue_redraw())
		add_child(_clim_key_menu)
	_clim_key_menu.clear()
	_clim_key_menu_idx = _clim_key_at(p)
	_clim_key_menu_t = _x_to_abs(p.x)
	var keys : ClimelapseKeyframes = tl.call("climelapse_keys")
	if _clim_key_menu_idx >= 0:
		var k : Dictionary = keys.key(_clim_key_menu_idx)
		_clim_key_menu.add_item("Camera keyframe · %s" % ClimelapseExportOptions.timecode_at(float(k.get("t", 0.0))), 99)
		_clim_key_menu.set_item_disabled(0, true)
		_clim_key_menu.add_item("Jump the playhead here", 1)
		_clim_key_menu.add_item("Preview from here", 2)
		_clim_key_menu.add_item("Set to the current view", 3)
		_clim_key_menu.add_item("Edit camera path…", 9)
		_clim_key_menu.add_separator()
		_clim_key_menu.add_item("Delete keyframe", 4)
	else:
		_clim_key_menu.add_item("Key the current view here (%s)" % ClimelapseExportOptions.timecode_at(_clim_key_menu_t), 5)
		_clim_key_menu.add_item("Key the current view at the playhead", 6)
		if keys.size() > 0:
			_clim_key_menu.add_item("Preview the keyframed shot", 8)
			_clim_key_menu.add_item("Edit camera path…", 9)
			_clim_key_menu.add_separator()
			_clim_key_menu.add_item("Clear all %s" % UiText.count(keys.size(), "keyframe"), 7)
	var screen := _track.get_screen_transform() * p
	_clim_key_menu.popup(Rect2i(Vector2i(screen), Vector2i.ZERO))
	_track.queue_redraw()


func _on_clim_key_menu(id : int) -> void:
	var tl := _get_terrain_loader()
	if tl == null:
		return
	var i := _clim_key_menu_idx
	var keys : ClimelapseKeyframes = tl.call("climelapse_keys")
	match id:
		1:
			if i >= 0 and _main != null:
				_main.call("set_absolute_hours", float(keys.key(i).get("t", 0.0)))
				_update_display()
		2:
			if i >= 0:
				_preview_clim_from(float(keys.key(i).get("t", 0.0)))
		3:
			if i >= 0:
				tl.call("repose_climelapse_key", i)
				_notify("Keyframe set to the current view.", 1)
		4:
			if i >= 0:
				tl.call("remove_climelapse_key", i)
		5:
			tl.call("set_climelapse_key_at", _clim_key_menu_t)
		6:
			tl.call("set_climelapse_key_at", _playhead_abs())
		7:
			tl.call("clear_climelapse_path")
		8:
			_preview_clim_from(NAN)
		9:
			tl.call("open_climelapse_path_editor", i)
	_clim_key_menu_idx = -1
	if _track != null:
		_track.queue_redraw()


## Play the hyperlapse with the last export settings over the selection (or the
## keyframes' span when nothing is selected), from `from_abs` (NAN = the start).
func _preview_clim_from(from_abs : float) -> void:
	var tl := _get_terrain_loader()
	if tl == null or not tl.has_method("start_climelapse_preview"):
		return
	var o := ClimelapseExportOptions.load_prefs()
	var sel := _climelapse_selection_range()
	var keys : ClimelapseKeyframes = tl.call("climelapse_keys")
	if not is_nan(sel[0]):
		o["start_abs"] = sel[0]
		o["end_abs"] = sel[1]
	elif keys != null and keys.size() >= 2:
		var ts := keys.times()
		o["start_abs"] = ts[0]
		o["end_abs"] = ts[ts.size() - 1]
	else:
		var a := _playhead_abs() if is_nan(from_abs) else from_abs
		o["start_abs"] = a
		o["end_abs"] = a + 24.0
	o = ClimelapseExportOptions.analemma_range(o)
	if int(o.get("analemma", 0)) > 0:
		from_abs = NAN   # an analemma plays from its first day
	if not bool(tl.call("start_climelapse_preview", o, from_abs)):
		_notify("Preview could not start (an export or another view holds the clock).")


## Every sensor lane — power, weather, Home Assistant — goes through ONE
## path (TimelineBinning): a bin width from a fixed ladder, bins anchored to
## absolute time, and exact min / mean / max per bin, drawn as the mean line
## over its min–max band. Panning never resamples (a bin is the same interval
## wherever the window sits) and zooming only changes the shape when the ladder
## steps; a fast oscillation zoomed out stays a band, never a different curve.
func _draw_waveform_lane(td : TimelineTrackDef, lane_rect : Rect2, win_start : float, span : float,
		_w : float, fnt : Font, solar : Node) -> void:
	var bg := Color(0.05, 0.07, 0.11, 0.55)
	TimelineWaveformDraw.draw_track_background(_track, lane_rect, bg, Color(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.35))
	TimelineWaveformDraw.draw_label(_track, lane_rect, td.label, td.color, fnt)
	match td.source:
		"ha":
			_draw_ha_lane(td, lane_rect, win_start, span, fnt)
		"ha_entity":
			_draw_ha_entity_lane(td, lane_rect, win_start, span, fnt)
		TimelineWeatherChannels.SOURCE:
			_draw_weather_lane(td, lane_rect, win_start, span, fnt)
		_:
			_draw_power_lane(td, lane_rect, win_start, span, fnt, solar)


## Bin width + anchored grid for a lane: {w, i0, n}. `min_w` = the data's own
## sample spacing (no bin finer than one sample).
func _lane_grid(lane_rect : Rect2, win_start : float, span : float, min_w : float) -> Dictionary:
	var bw := TimelineBinning.bin_width(span, lane_rect.size.x, min_w)
	var g := TimelineBinning.grid(win_start, win_start + span, bw)
	g["w"] = bw
	return g


## Cached bins for a lane. The key is the anchored grid, so a pan smaller than
## a bin reuses them; `ttl` lets live data refresh.
func _lane_bins_cached(td : TimelineTrackDef, g : Dictionary, ttl : float, make : Callable) -> Dictionary:
	var key : Array = [td.source, td.channel, g["w"], g["i0"], g["n"]]
	var now := Time.get_ticks_msec() / 1000.0
	var cached : Dictionary = _waveform_cache.get(td.id, {})
	if cached.get("key", []) == key and now - float(cached.get("t", -1.0)) < ttl:
		return cached.get("bins", {})
	var out : Dictionary = make.call()
	_waveform_cache[td.id] = {"key": key, "bins": out, "t": now}
	return out


## Draw bins with an axis (or the empty note) and the range label.
func _draw_bins_lane(td : TimelineTrackDef, lane_rect : Rect2, bins : Dictionary, win_start : float,
		span : float, axis : Vector2, unit : String, empty_msg : String, fnt : Font) -> void:
	if is_nan(axis.x):
		if not empty_msg.is_empty():
			_track.draw_string(fnt, Vector2(lane_rect.position.x + 140.0, lane_rect.position.y + lane_rect.size.y * 0.5 + 4.0),
				empty_msg, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(0.6, 0.65, 0.72, 0.8))
		return
	TimelineWaveformDraw.draw_bins(_track, lane_rect, bins, win_start, span, axis.x, axis.y, td.color)
	var txt := "off – on" if unit == "bool" else "%s – %s %s" % [_fmt_axis(axis.x), _fmt_axis(axis.y), unit]
	TimelineWaveformDraw.draw_range_label(_track, lane_rect, txt.strip_edges(), td.color, fnt)


static func _fmt_axis(v : float) -> String:
	var a := absf(v)
	if a >= 100.0:
		return "%.0f" % v
	if a >= 10.0:
		return "%.1f" % v
	return "%.2f" % v


## An axis around a value range: [NAN, NAN] when empty; from 0 when the
## values never go below it and `floor_zero`; padded otherwise.
static func _axis_for(r : Vector2, floor_zero : bool = false) -> Vector2:
	if is_nan(r.x):
		return r
	if floor_zero and r.x >= 0.0:
		return Vector2(0.0, maxf(r.y * 1.15, 1e-3))
	var pad := maxf((r.y - r.x) * 0.1, maxf(absf(r.y) * 0.02, 0.05))
	return Vector2(r.x - pad, r.y + pad)


## Power: the energy timeline / simulated run / CSV clip (SolarUI).
func _draw_power_lane(td : TimelineTrackDef, lane_rect : Rect2, win_start : float, span : float,
		fnt : Font, solar : Node) -> void:
	if solar == null or not solar.has_method("get_timeline_bins"):
		return
	var step := float(solar.call("get_timeline_step_hours", td.source))
	var g := _lane_grid(lane_rect, win_start, span, step)
	var bins : Dictionary = _lane_bins_cached(td, g, WAVEFORM_CACHE_TTL, func() -> Dictionary:
		return solar.call("get_timeline_bins", td.source, td.channel, float(g["w"]), int(g["i0"]), int(g["n"])))
	var cap := float(solar.call("get_timeline_capacity_kwh")) if solar.has_method("get_timeline_capacity_kwh") else 16.0
	var r := TimelineBinning.value_range(bins)
	var axis := _axis_for(r, true)
	var unit := str(TimelineTrackDef.lookup_channel(td.channel).get("unit", ""))
	if not is_nan(r.x):
		match td.channel:
			"soc_pct":
				axis = Vector2(0.0, 100.0)
			"soc_kwh":
				axis = Vector2(0.0, maxf(cap, 1.0))
	_draw_bins_lane(td, lane_rect, bins, win_start, span, axis, unit, "", fnt)


## A Live link's recorded readings, in the linked value's unit (real time).
func _draw_ha_lane(td : TimelineTrackDef, lane_rect : Rect2, win_start : float, span : float, fnt : Font) -> void:
	var linker := _ha_linker()
	if linker == null:
		return
	var g := _lane_grid(lane_rect, win_start, span, 0.0)
	var bins : Dictionary = _lane_bins_cached(td, g, 0.5, func() -> Dictionary:
		return linker.call("observed_bins_exact", td.channel, float(g["w"]), int(g["i0"]), int(g["n"])))
	var t : Dictionary = linker.call("target", td.channel)
	var unit := str(t.get("unit", ""))
	var r := TimelineBinning.value_range(bins)
	var axis := _axis_for(r, unit in ["W", "kW", "kWh", "%", "L"])
	if unit == "bool" and not is_nan(r.x):
		axis = Vector2(-0.05, 1.05)
	_draw_bins_lane(td, lane_rect, bins, win_start, span, axis, unit,
		"no readings in this window" if not t.is_empty() else "this link was removed", fnt)


## Any Home Assistant entity (the service records it and fetches the window
## from HA's history), in the entity's own unit.
func _draw_ha_entity_lane(td : TimelineTrackDef, lane_rect : Rect2, win_start : float, span : float, fnt : Font) -> void:
	var svc := get_node_or_null("/root/HomeAssistant")
	if svc == null:
		return
	var g := _lane_grid(lane_rect, win_start, span, 0.0)
	var bins : Dictionary = _lane_bins_cached(td, g, 1.0, func() -> Dictionary:
		return svc.call("entity_bins_exact", td.channel, float(g["w"]), int(g["i0"]), int(g["n"])))
	var row : Dictionary = svc.call("catalog_entry", td.channel)
	var unit := str(row.get("unit", ""))
	var binary := td.channel.get_slice(".", 0) in ["switch", "binary_sensor", "input_boolean", "light", "fan"]
	var r := TimelineBinning.value_range(bins)
	var axis := _axis_for(r, unit in ["W", "kW", "kWh", "Wh", "%", "L", "mm", "mm/h", "in", "in/h"])
	if binary and not is_nan(r.x):
		axis = Vector2(-0.05, 1.05)
	var msg := "no readings in this window"
	if not bool(svc.call("is_authed")):
		msg = "Home Assistant is not connected"
	elif row.is_empty() and int(svc.call("catalog_size")) > 0:
		msg = "%s is not in your Home Assistant" % td.channel
	_draw_bins_lane(td, lane_rect, bins, win_start, span, axis, "bool" if binary else unit, msg, fnt)


## A weather variable from WeatherService (hourly, linear between hours), in
## the weather card's units (°F / °C switch).
func _draw_weather_lane(td : TimelineTrackDef, lane_rect : Rect2, win_start : float, span : float, fnt : Font) -> void:
	var ws := get_node_or_null("/root/WeatherService")
	var ch := TimelineWeatherChannels.find(td.channel)
	if ws == null or ch.is_empty():
		return
	var g := _lane_grid(lane_rect, win_start, span, 0.0)
	var reader := func(acc : String, m : int, d : int, h : float) -> float:
		return float(ws.call(acc, m, d, h))
	var bins : Dictionary = _lane_bins_cached(td, g, 10.0, func() -> Dictionary:
		return TimelineWeatherChannels.bins_exact(td.channel, float(g["w"]), int(g["i0"]), int(g["n"]), reader))
	var si_unit := str(ch["si"])
	var imperial := _weather_imperial()
	var unit := str(TimelineWeatherChannels.display(0.0, si_unit, imperial)["unit"])
	var shown := bins
	if unit != si_unit:
		shown = TimelineBinning.mapped(bins, func(v : float) -> float:
			return float(TimelineWeatherChannels.display(v, si_unit, imperial)["value"]))
	var r := TimelineBinning.value_range(shown)
	var axis := _axis_for(r, bool(ch.get("floor_zero", false)))
	var fixed : Variant = ch.get("fixed", null)
	if fixed is Array and not is_nan(r.x):
		axis = Vector2(float(fixed[0]), float(fixed[1]))
	var msg := "no weather data loaded for this site" if not bool(ws.call("has_data")) else "no data for this variable"
	_draw_bins_lane(td, lane_rect, shown, win_start, span, axis, unit, msg, fnt)


## The weather card's unit switch (ui_prefs.cfg [units] imperial).
func _weather_imperial() -> bool:
	if is_instance_valid(_weather_card):
		var v : Variant = _weather_card.get("_use_imperial")
		if v != null:
			return bool(v)
	return _use_imperial


## Draw a clip rect for an absolute-hours range on a lane (clamped to the window).
func _draw_clip(a0: float, a1: float, win_start: float, span: float, w: float,
		lane_y: float, lane_h: float, col: Color) -> void:
	var x0 := clampf((a0 - win_start) / span * w, 0.0, w)
	var x1 := clampf((a1 - win_start) / span * w, 0.0, w)
	if x1 <= x0:
		return
	_track.draw_rect(Rect2(x0, lane_y, x1 - x0, lane_h), col, true)
	_track.draw_rect(Rect2(x0, lane_y, x1 - x0, lane_h),
		Color(col.r, col.g, col.b, 0.9), false, 1.0)

func _on_track_input(event: InputEvent) -> void:
	if _main == null or not is_instance_valid(_main):
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_track_view.zoom_at_cursor(TimelineViewScript.ZOOM_IN_FACTOR, mb.position.x)
			_save_ui_prefs()
			_track.queue_redraw()
			_update_track_edge_labels()
			get_viewport().set_input_as_handled()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_track_view.zoom_at_cursor(TimelineViewScript.ZOOM_OUT_FACTOR, mb.position.x)
			_save_ui_prefs()
			_track.queue_redraw()
			_update_track_edge_labels()
			get_viewport().set_input_as_handled()
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				var hit : int = _track_layout.resize_hit_at(mb.position.y)
				if hit >= 0:
					_resize_track_idx = hit
					get_viewport().set_input_as_handled()
				elif not mb.ctrl_pressed and _clim_key_at(mb.position) >= 0:
					var ki := _clim_key_at(mb.position)
					if mb.double_click:
						_main.call("set_absolute_hours", _clim_key_time(ki))
						_update_display()
					else:
						_clim_key_drag = ki
						_clim_key_drag_t = _clim_key_time(ki)
						_clim_key_drag_moved = false
						_clim_key_press_x = mb.position.x
					get_viewport().set_input_as_handled()
				elif mb.ctrl_pressed:
					# Ctrl-drag = set the render in/out selection.
					_selecting = true
					_sel_anchor_abs = _x_to_abs(mb.position.x)
					_apply_selection(_sel_anchor_abs, _sel_anchor_abs)
				else:
					_track_dragging = true
					_scrub_to_x(mb.position.x)
			else:
				if _resize_track_idx >= 0:
					_resize_track_idx = -1
					_save_track_layout_prefs()
				if _clim_key_drag >= 0:
					var tlk := _get_terrain_loader()
					if _clim_key_drag_moved and tlk != null and not is_nan(_clim_key_drag_t):
						tlk.call("move_climelapse_key", _clim_key_drag, _clim_key_drag_t)
					elif tlk != null and tlk.has_method("open_climelapse_path_editor"):
						# A click (no drag) opens the camera-path editor on that key.
						tlk.call("open_climelapse_path_editor", _clim_key_drag)
					_clim_key_drag = -1
					_clim_key_drag_t = NAN
					_track.queue_redraw()
				_track_dragging = false
				_selecting = false
		elif mb.button_index == MOUSE_BUTTON_MIDDLE:
			if mb.pressed:
				_track_panning = true
				_track_pan_anchor_x = mb.position.x
			else:
				_track_panning = false
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed and not mb.alt_pressed \
				and _clim_lane_rect.size.x > 0.0 \
				and absf(mb.position.y - (_clim_lane_rect.position.y + _clim_lane_rect.size.y * 0.5)) <= CLIM_KEY_HIT_PX + 2.0:
			_on_clim_lane_right_click(mb.position)
			get_viewport().set_input_as_handled()
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed and mb.alt_pressed:
			_track_view.reset_to_playhead(_playhead_abs())
			_track.queue_redraw()
			_update_track_edge_labels()
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _resize_track_idx >= 0:
			_track_layout.apply_resize(_resize_track_idx, mm.relative.y)
			_sync_scrubber_row_height()
			_request_bar_layout()
			_track.queue_redraw()
		elif _track_panning:
			_track_view.pan_by_pixels(mm.relative.x)
			_track.queue_redraw()
			_update_track_edge_labels()
		elif _clim_key_drag >= 0:
			if _clim_key_drag_moved or absf(mm.position.x - _clim_key_press_x) >= 4.0:
				_clim_key_drag_t = _x_to_abs(mm.position.x)
				_clim_key_drag_moved = true
				_track.queue_redraw()
		elif _selecting:
			_apply_selection(_sel_anchor_abs, _x_to_abs(mm.position.x))
		elif _track_dragging:
			_scrub_to_x(mm.position.x)
		elif mm.alt_pressed and (mm.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
			_track_view.pan_by_pixels(mm.relative.x)
			_track.queue_redraw()
			_update_track_edge_labels()
		_update_track_alert_tooltip(mm.position)


## Map a track-local x to absolute hours within the visible window.
func _x_to_abs(x: float) -> float:
	if _track == null:
		return 0.0
	_sync_track_view()
	return _track_view.x_to_time(x)


func _apply_selection(a: float, b: float) -> void:
	var s := _get_solar()
	if s != null and s.has_method("set_selection_abs"):
		s.call("set_selection_abs", a, b)
	if _track != null:
		_track.queue_redraw()


func _scrub_to_x(x: float) -> void:
	var t := _x_to_abs(x)
	if _main.has_method("set_absolute_hours"):
		_main.call("set_absolute_hours", t)
	else:
		_main.set("day_time", fmod(t, 24.0))
	_update_display()

func _on_mode_chip_pressed() -> void:
	_resolve_td()
	if _td == null:
		return
	# Cycle: Auto → LIVE → SIM → Auto. PLAYBACK is latch-driven (CSV/history).
	if not bool(_td.call("has_explicit_mode")):
		_td.call("set_explicit_mode", 0)        # LIVE
	elif int(_td.call("current_mode")) == 0:
		_td.call("set_explicit_mode", 2)        # SIMULATE
	else:
		_td.call("clear_explicit_mode")         # back to auto
	_update_display()

func _update_mode_chips() -> void:
	_resolve_td()
	if _mode_chip == null:
		return
	if _td == null:
		_mode_chip.text = "SIM"
		_mode_chip.add_theme_color_override("font_color", C_LAVENDER)
		if _data_chip != null:
			_data_chip.text = ""
		return
	var mode := int(_td.call("current_mode"))
	var pinned : bool = bool(_td.call("has_explicit_mode"))
	_mode_chip.text = ("📌 " if pinned else "") + String(_td.call("mode_label", mode))
	var mcol := C_LAVENDER
	match mode:
		0: mcol = C_GREEN      # LIVE
		1: mcol = C_GOLD       # PLAYBACK
		2: mcol = C_LAVENDER   # SIM
	_mode_chip.add_theme_color_override("font_color", mcol)
	if _data_chip != null:
		var prov := int(_td.call("playhead_provenance"))
		_data_chip.text = "● " + String(_td.call("provenance_label", prov))
		var dcol := C_TEXT_S
		match prov:
			0: dcol = C_GREEN     # REAL
			1: dcol = C_PRIMARY   # OBSERVED
			2: dcol = C_LAVENDER  # PROJECTED
			3: dcol = C_GOLD      # RECORDED
			4: dcol = C_GREEN     # RENDERED (the sim pre-render's cache)
		_data_chip.add_theme_color_override("font_color", dcol)


## 💾 opens the WORLD panel (scenes/ui/world_panel.gd), which replaced the
## eight anonymous save slots: name, what the world holds, save / copy / new
## world on this map / exit to menu.
func _on_save_load_pressed() -> void:
	var ui_layer := get_parent()
	if ui_layer == null:
		return
	var wp := ui_layer.get_node_or_null("WorldPanel")
	if wp == null:
		wp = WORLD_PANEL_SCRIPT.new()
		wp.name = "WorldPanel"
		ui_layer.add_child(wp)
	if wp.has_method("show_panel"):
		wp.show_panel()


func _on_map_select_pressed() -> void:
	if _map_confirm != null:
		_map_confirm.popup_centered()


func _on_map_select_confirmed() -> void:
	_release_mouse()
	if is_instance_valid(_main) and WorldPaths.has_active_world():
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		WorldSession.exit_to_menu(_main)
		return
	if is_instance_valid(_main) and _main.has_method("request_autosave"):
		_main.request_autosave()
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	var err := get_tree().change_scene_to_file("res://scenes/ui/map_select/map_select.tscn")
	if err != OK:
		push_warning("TimelineUI: could not open map select (error %d)" % err)


# ---------------------------------------------------------------------------
# Mouse capture helpers
# ---------------------------------------------------------------------------

func _release_mouse() -> void:
	CursorController.set_paused(true)


func _recapture_mouse() -> void:
	if is_settings_open():
		return
	var ui_layer := get_parent()
	if ui_layer != null:
		var gv := ui_layer.get_node_or_null("SystemGraphView")
		if gv != null and gv.visible:
			return
	CursorController.set_paused(false)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _nearest_speed_idx(scale: float) -> int:
	if is_inf(scale):
		# Default ∞ (1 day/frame), not ∞×2, when matching by scale alone.
		return SPEED_STEPS.size() - 1
	var best      : int   = 0
	var best_dist : float = 1e9
	for i in SPEED_STEPS.size():
		var v := float(SPEED_STEPS[i][1])
		if not is_finite(v):
			continue
		var d := absf(scale - v)
		if d < best_dist:
			best_dist = d
			best      = i
	return best


func _fmt_hour_full(h: float) -> String:
	var hh   : int    = int(h) % 24
	var mm   : int    = int((h - floor(h)) * 60.0)
	var ap   : String = "AM" if hh < 12 else "PM"
	var disp : int    = hh % 12
	if disp == 0: disp = 12
	return "%d:%02d %s" % [disp, mm, ap]


func _fmt_hour_short(h: float) -> String:
	var hh   : int    = int(h) % 24
	var mm   : int    = int((h - floor(h)) * 60.0)
	var ap   : String = "AM" if hh < 12 else "PM"
	var disp : int    = hh % 12
	if disp == 0: disp = 12
	return "%d:%02d %s" % [disp, mm, ap]


# ---------------------------------------------------------------------------
# Layout builder
# ---------------------------------------------------------------------------

func _build_bar() -> void:
	# @tool re-runs in editor — rebuild cleanly once.
	for child in get_children():
		if child != _settings_panel and child != _map_confirm:
			child.free()
	_request_bar_layout()

	# ── Background: dark navy with cyan top glow line ─────────────────────
	var bg    := PanelContainer.new()
	bg.name = "TimelineBarBg"
	bg.clip_contents = true
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg_sb := StyleBoxFlat.new()
	bg_sb.bg_color         = Color(0.040, 0.058, 0.110, 0.97)
	bg_sb.set_border_width_all(0)
	bg_sb.border_width_top = 2
	bg_sb.border_color     = Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.55)
	bg_sb.set_corner_radius_all(0)
	bg.add_theme_stylebox_override("panel", bg_sb)
	add_child(bg)

	# ── Master VBox ────────────────────────────────────────────────────────
	var vbox := VBoxContainer.new()
	vbox.name = "TimelineBarVBox"
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.clip_contents = true
	vbox.add_theme_constant_override("separation", 0)
	bg.add_child(vbox)

	_build_scrubber_row(vbox)
	_build_info_row(vbox)
	_sync_scrubber_row_height()
	_request_bar_layout()


func _enforce_bar_layout() -> void:
	_bar_layout_pending = false
	if _bar_layout_guard:
		return
	_bar_layout_guard = true

	# Small gap above the viewport bottom so the bar doesn't feel clipped.
	var want_top := -_bar_height() - BAR_BOTTOM_PAD
	var want_bottom := -BAR_BOTTOM_PAD
	var want_min := Vector2(0.0, _bar_height() + BAR_BOTTOM_PAD)
	var height_changed := absf(offset_top - want_top) > 0.5 \
			or absf(custom_minimum_size.y - want_min.y) > 0.5

	if anchor_left != 0.0 or anchor_top != 1.0 or anchor_right != 1.0 or anchor_bottom != 1.0:
		set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
		anchor_left = 0.0
		anchor_top = 1.0
		anchor_right = 1.0
		anchor_bottom = 1.0
	if offset_left != 0.0:
		offset_left = 0.0
	if offset_right != 0.0:
		offset_right = 0.0
	if offset_top != want_top:
		offset_top = want_top
	if offset_bottom != want_bottom:
		offset_bottom = want_bottom
	if custom_minimum_size != want_min:
		custom_minimum_size = want_min
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	grow_vertical = Control.GROW_DIRECTION_BEGIN
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP

	_bar_layout_guard = false
	if height_changed:
		stack_height_changed.emit(get_stack_height())


func _build_scrubber_row(parent: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	_scrubber_row = row
	row.custom_minimum_size = Vector2(0, _track_layout.content_height())
	row.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	row.add_theme_constant_override("separation", 0)
	parent.add_child(row)

	_track_lbl_start = Label.new()
	_track_lbl_start.text = ""
	_track_lbl_start.vertical_alignment  = VERTICAL_ALIGNMENT_CENTER
	_track_lbl_start.custom_minimum_size = Vector2(58, 0)
	_track_lbl_start.add_theme_color_override("font_color", C_TEXT_M)
	_track_lbl_start.add_theme_font_size_override("font_size", 9)
	row.add_child(_track_lbl_start)

	# Custom-drawn multi-day absolute-time track with NOW marker + provenance bands.
	_track = Control.new()
	_track.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_track.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_track.mouse_filter          = Control.MOUSE_FILTER_STOP
	_track.tooltip_text          = "Drag: scrub  •  Ctrl-drag: render range  •  Wheel: zoom  •  Alt/MMB-drag: pan"
	_track.draw.connect(_draw_track)
	if not Engine.is_editor_hint():
		_track.gui_input.connect(_on_track_input)
		_track.mouse_exited.connect(func():
			if _wx_tooltip_panel != null:
				_wx_tooltip_panel.visible = false)
	row.add_child(_track)

	_track_lbl_end = Label.new()
	_track_lbl_end.text = ""
	_track_lbl_end.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_track_lbl_end.custom_minimum_size  = Vector2(58, 0)
	_track_lbl_end.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_track_lbl_end.add_theme_color_override("font_color", C_TEXT_M)
	_track_lbl_end.add_theme_font_size_override("font_size", 9)
	row.add_child(_track_lbl_end)


## LEFT — NLE / clip / video icon cluster (pinned left, mirrors right system icons).
## Icons deliberately differ from the right cluster (📥 vs 📂, 📈 vs ⚙).
func _build_left_cluster() -> Control:
	var left := HBoxContainer.new()
	left.alignment = BoxContainer.ALIGNMENT_BEGIN
	left.add_theme_constant_override("separation", 4)

	_import_btn = _mk_icon_btn("📥", _on_import_pressed,
			"Import datastream — load a Home Assistant CSV as an observed comparison clip")
	left.add_child(_import_btn)

	_render_btn = _mk_icon_btn("📈", _on_render_pressed, RENDER_TIP)
	left.add_child(_render_btn)

	_export_mp4_btn = _mk_icon_btn("🎬", _on_export_clim_mp4_pressed,
			"Export video — choose the range (the Ctrl-drag selection), speed, size, frame "
			+ "rate and render settings, preview it, then render an MP4 (needs ffmpeg)")
	_export_mp4_btn.add_theme_color_override("font_color", Color(0.45, 0.75, 1.0))
	left.add_child(_export_mp4_btn)

	var path_add := _mk_icon_btn("📍", _on_clim_path_add_pressed,
			"Camera keyframe — key the current view at the playhead. Keys sit on the CLIM "
			+ "lane: drag to retime, double-click to jump there, right-click to edit, delete "
			+ "or preview. The video camera flies between them in time.")
	left.add_child(path_add)
	var path_clr := _mk_icon_btn("🧹", _on_clim_path_clear_pressed,
			"Clear every camera keyframe")
	left.add_child(path_clr)

	_loadmode_btn = _mk_icon_btn("📄", _on_loadmode_pressed,
			"Render load source — CSV uses observed load (isolates solar/weather error); Modeled also simulates load")
	left.add_child(_loadmode_btn)

	_compare_btn = _mk_icon_btn("⧉", _on_compare_pressed,
			"Compare — simulate a past span and lay it over what really happened (Home Assistant or the imported CSV)")
	left.add_child(_compare_btn)

	_tracks_btn = _mk_icon_btn("🎚", _on_tracks_pressed,
			"Tracks — show/hide sensor waveform lanes and add channels")
	left.add_child(_tracks_btn)
	_setup_tracks_menu()

	# Visual break before video/live tools.
	left.add_child(_mk_vsep())

	_load_video_btn = _mk_icon_btn("📹", _on_load_video_pressed,
			"Load video — open a timelapse file for the TR panel (auto-synced to timecode)")
	_load_video_btn.add_theme_color_override("font_color", C_GREEN)
	left.add_child(_load_video_btn)

	_live_feed_btn = _mk_icon_btn("📷", _on_live_feed_pressed,
			"Live feed — pick a camera / OBS virtual camera for the TR panel")
	_live_feed_btn.add_theme_color_override("font_color", C_GREEN)
	left.add_child(_live_feed_btn)

	_snap_video_btn = _mk_icon_btn("⏲", _on_snap_video_pressed,
			"Snap video — align video frame 0 to the current playhead (re-syncs the VID track)")
	left.add_child(_snap_video_btn)

	_render_progress_lbl = Label.new()
	_render_progress_lbl.text = ""
	_render_progress_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_render_progress_lbl.add_theme_font_size_override("font_size", 9)
	_render_progress_lbl.add_theme_color_override("font_color", C_TEXT_S)
	_render_progress_lbl.custom_minimum_size = Vector2(52, 0)
	left.add_child(_render_progress_lbl)

	return left


# ---------------------------------------------------------------------------
# NLE clip controls — handlers
# ---------------------------------------------------------------------------

func _get_solar() -> Node:
	_ensure_solar_ref()
	return _solar_ui


func _get_terrain_loader() -> Node:
	if _main == null:
		return null
	return _main.get_node_or_null("TerrainLoader")


func _get_projection_canvas() -> Node:
	var p := get_parent()
	if p != null:
		var pc := p.get_node_or_null("ProjectionCanvas")
		if pc != null:
			return pc
	if get_tree() != null:
		return get_tree().root.find_child("ProjectionCanvas", true, false)
	return null


## Same lookup, but instances the canvas when the map didn't ship one (mars +
## every generated location map). Only the video buttons call this — the polling
## `_get_projection_canvas()` must stay lookup-only or the always-on SubViewport
## would be created on every UI refresh whether the player wants it or not.
func _ensure_projection_canvas() -> Node:
	var pc := _get_projection_canvas()
	if pc != null:
		return pc
	if _main != null and _main.has_method("ensure_projection_canvas"):
		return _main.call("ensure_projection_canvas")
	return null


## User-visible feedback for the NLE buttons. push_warning() only reaches the
## console, which is why these paths read as "the button does nothing".
func _notify(msg: String, level: int = 2) -> void:
	if _main != null and _main.has_method("show_toast"):
		_main.call("show_toast", msg, level, 4.0)
	else:
		push_warning(msg)


func _on_import_pressed() -> void:
	if _import_dialog == null:
		_import_dialog = FileDialog.new()
		_import_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_import_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_import_dialog.filters = PackedStringArray(["*.csv ; CSV files"])
		_import_dialog.title = "Import datastream CSV"
		_import_dialog.size = Vector2i(900, 600)
		_import_dialog.file_selected.connect(_on_import_file_selected)
		add_child(_import_dialog)
	_import_dialog.popup_centered_ratio(0.6)


func _on_import_file_selected(path: String) -> void:
	var s := _get_solar()
	if s != null and s.has_method("import_observed_csv"):
		s.call("import_observed_csv", path)


func _on_linkagelab_import_pressed() -> void:
	if _linkagelab_dialog == null:
		_linkagelab_dialog = FileDialog.new()
		_linkagelab_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_linkagelab_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_linkagelab_dialog.filters = PackedStringArray([
			"*.gamebundle.json ; LinkageLab Game Bundle",
			"*.json ; JSON",
		])
		_linkagelab_dialog.title = "Import LinkageLab Game Bundle"
		_linkagelab_dialog.size = Vector2i(900, 600)
		_linkagelab_dialog.file_selected.connect(_on_linkagelab_file_selected)
		add_child(_linkagelab_dialog)
	_linkagelab_dialog.popup_centered_ratio(0.6)


func _on_linkagelab_file_selected(path: String) -> void:
	var result := BUNDLE_IMPORTER_SCRIPT.apply_bundle_file(get_tree(), path)
	if not bool(result.get("ok", false)):
		push_warning("TimelineUI: bundle import failed: %s" % str(result.get("error", "unknown")))
		return
	if _render_progress_lbl != null:
		_render_progress_lbl.text = "LinkageLab import: %s" % str(result.get("model_id", "ok"))
	var ui_layer := get_parent()
	if ui_layer != null:
		var props_ui := ui_layer.get_node_or_null("PlacedPropsUI")
		if props_ui != null and props_ui.has_method("notify_bundle_imported"):
			props_ui.call("notify_bundle_imported", result)
	# If the bundle carries an editable parametric design (v30 project block),
	# offer to open it natively in Linkage Lab so it becomes live-foldable
	# instead of a static imported GLB.
	var project := result.get("linkage_project", {}) as Dictionary
	if not project.is_empty():
		_offer_open_in_linkage_lab(project)


func _offer_open_in_linkage_lab(project: Dictionary) -> void:
	if _linkagelab_open_confirm == null:
		_linkagelab_open_confirm = ConfirmationDialog.new()
		_linkagelab_open_confirm.title = "Editable design detected"
		_linkagelab_open_confirm.dialog_text = "This bundle includes the full parametric design. Open it in Linkage Lab to make it live-foldable and editable?"
		_linkagelab_open_confirm.ok_button_text = "Open in Linkage Lab"
		_linkagelab_open_confirm.get_cancel_button().text = "Keep imported model"
		_linkagelab_open_confirm.confirmed.connect(_on_open_in_linkage_lab_confirmed)
		add_child(_linkagelab_open_confirm)
	_pending_linkage_project = project.duplicate(true)
	_linkagelab_open_confirm.popup_centered()


func _on_open_in_linkage_lab_confirmed() -> void:
	if _pending_linkage_project.is_empty():
		return
	var main := _find_main_for_linkage()
	if main != null and main.has_method("open_linkage_lab"):
		main.call("open_linkage_lab", _pending_linkage_project)
	_pending_linkage_project = {}


func _find_main_for_linkage() -> Node:
	var tree := get_tree()
	if tree != null and tree.current_scene != null \
			and ("day_time" in tree.current_scene) and ("sun" in tree.current_scene):
		return tree.current_scene
	var n: Node = self
	while n != null:
		if ("day_time" in n) and ("sun" in n):
			return n
		n = n.get_parent()
	return null





func _climelapse_selection_range() -> PackedFloat64Array:
	var s := _get_solar()
	var sel := PackedFloat64Array([NAN, NAN])
	if s != null and s.has_method("get_selection_abs"):
		sel = s.call("get_selection_abs")
	if is_nan(sel[0]) or is_nan(sel[1]) or sel[1] <= sel[0]:
		return PackedFloat64Array([NAN, NAN])
	return sel


func _on_clim_path_add_pressed() -> void:
	var tl := _get_terrain_loader()
	if tl == null or not tl.has_method("add_climelapse_path_waypoint"):
		_notify("Camera keyframes need a location map (this one has no TerrainLoader).")
		return
	if bool(tl.call("add_climelapse_path_waypoint")):
		var n := int(tl.call("get_climelapse_path_count")) if tl.has_method("get_climelapse_path_count") else 0
		_notify("Camera keyframe at %s — %s on the CLIM lane." % [
			ClimelapseExportOptions.timecode_at(_playhead_abs()), UiText.count(n, "keyframe")], 1)
		if _track != null:
			_track.queue_redraw()


func _on_clim_path_clear_pressed() -> void:
	var tl := _get_terrain_loader()
	if tl != null and tl.has_method("clear_climelapse_path"):
		tl.call("clear_climelapse_path")
		_notify("Camera keyframes cleared.", 1)
	else:
		_notify("Camera keyframes need a location map (this one has no TerrainLoader).")


func _on_export_clim_mp4_pressed() -> void:
	var tl := _get_terrain_loader()
	if tl == null or not tl.has_method("start_climelapse_export_with"):
		_notify("Video export needs a location map (this one has no TerrainLoader).")
		return
	if _clim_options_dialog != null and is_instance_valid(_clim_options_dialog):
		return
	var sel := _climelapse_selection_range()
	_clim_options_dialog = CLIM_EXPORT_DIALOG_SCRIPT.new()
	_clim_options_dialog.name = "ClimelapseExportDialog"
	add_child(_clim_options_dialog)
	_clim_options_dialog.export_requested.connect(_begin_clim_export)
	_clim_options_dialog.open_on(tl, _main, sel, _playhead_abs(), _clim_bar_rate())


## Sim-hours per real second the bar is set to (the dialog's first-time
## default). The ∞ analemma presets have no finite rate.
func _clim_bar_rate() -> float:
	return float(SPEED_STEPS[_speed_idx][1])


## Kick off the capture with the world clock parked where the export starts.
func _begin_clim_export(opts: Dictionary) -> void:
	var tl := _get_terrain_loader()
	if tl == null:
		return
	# Stop the world: the capture places every frame's instant itself.
	_sim_paused_by_bar = true
	_pause_motion()
	CursorController.set_paused(true)
	if _main != null and _main.has_method("set_absolute_hours"):
		_main.call("set_absolute_hours", float(opts.get("start_abs", _playhead_abs())))

	# Progress window first, so there is visible feedback even if the start refuses.
	_clim_last_reported_result = ""
	_ensure_clim_progress_dialog()
	_clim_progress_bar.value = 0.0
	_clim_cancel_btn.text = "Cancel"
	_clim_progress_lbl.text = "Preparing export…"
	if not _clim_progress_dialog.visible:
		_clim_progress_dialog.popup_centered()

	tl.call("start_climelapse_export_with", opts)
	_update_clim_progress_dialog()
	_update_nle_controls()


func _ensure_clim_progress_dialog() -> void:
	if _clim_progress_dialog != null:
		return
	_clim_progress_dialog = Window.new()
	_clim_progress_dialog.title = "Exporting video"
	_clim_progress_dialog.size = Vector2i(660, 500)
	_clim_progress_dialog.unresizable = true
	_clim_progress_dialog.close_requested.connect(func() -> void:
		_clim_progress_dialog.hide())
	var vb := VBoxContainer.new()
	vb.set_anchors_preset(Control.PRESET_FULL_RECT)
	vb.offset_left = 12
	vb.offset_top = 12
	vb.offset_right = -12
	vb.offset_bottom = -12
	vb.add_theme_constant_override("separation", 8)
	_clim_progress_dialog.add_child(vb)
	# The export's own picture, live: the game window stops drawing the world
	# while the export renders it once per step.
	_clim_preview_rect = TextureRect.new()
	_clim_preview_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_clim_preview_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_clim_preview_rect.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_clim_preview_rect.custom_minimum_size = Vector2(0, 300)
	vb.add_child(_clim_preview_rect)
	_clim_progress_lbl = Label.new()
	_clim_progress_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_clim_progress_lbl.text = "Preparing export…"
	vb.add_child(_clim_progress_lbl)
	_clim_progress_bar = ProgressBar.new()
	_clim_progress_bar.custom_minimum_size = Vector2(0, 22)
	_clim_progress_bar.show_percentage = true
	vb.add_child(_clim_progress_bar)
	_clim_cancel_btn = Button.new()
	_clim_cancel_btn.text = "Cancel"
	_clim_cancel_btn.pressed.connect(_on_clim_cancel_pressed)
	vb.add_child(_clim_cancel_btn)
	add_child(_clim_progress_dialog)


func _on_clim_cancel_pressed() -> void:
	var tl := _get_terrain_loader()
	if tl != null and tl.has_method("is_climelapse_exporting") \
			and bool(tl.call("is_climelapse_exporting")):
		tl.call("cancel_climelapse_render")
	elif _clim_progress_dialog != null:
		_clim_progress_dialog.hide()
	if _clim_cancel_btn != null:
		_clim_cancel_btn.text = "Cancel"
	_update_nle_controls()


## Drives the export progress window: frame counter while the sim steps, then
## the ffmpeg encode, then the final result (which stays on screen until the
## player closes it — an export that failed must not vanish silently).
func _update_clim_progress_dialog() -> void:
	var tl := _get_terrain_loader()
	if tl == null or not tl.has_method("get_climelapse_export_stats"):
		return
	var st: Dictionary = tl.call("get_climelapse_export_stats")
	if bool(st.get("active", false)):
		_ensure_clim_progress_dialog()
		_clim_cancel_btn.text = "Cancel"
		var prog := clampf(float(st.get("progress", 0.0)), 0.0, 1.0)
		_clim_progress_bar.value = prog * 100.0
		var done := int(st.get("done", 0))
		var total := int(st.get("total", 0))
		if _clim_preview_rect != null and _clim_preview_rect.texture == null 				and tl.has_method("get_climelapse_export_preview_texture"):
			_clim_preview_rect.texture = tl.call("get_climelapse_export_preview_texture")
		match str(st.get("phase", "")):
			"encode":
				_clim_progress_lbl.text = "Finishing the MP4 (ffmpeg)…"
			"warmup":
				_clim_progress_lbl.text = "Warming up the renderer…"
			_:
				_clim_progress_lbl.text = "Frame %s / %s (%d%%)" % [
					UiText.thousands(done), UiText.thousands(total), int(round(prog * 100.0))]
		if not _clim_progress_dialog.visible:
			_clim_progress_dialog.popup_centered()
		return

	# Finished (or refused) — show the outcome on whichever dialog is open.
	if _clim_preview_rect != null:
		_clim_preview_rect.texture = null
	var result := str(st.get("result", ""))
	if result.is_empty() or _clim_progress_dialog == null or not _clim_progress_dialog.visible:
		return
	var msg := str(st.get("message", ""))
	_clim_progress_bar.value = 100.0 if result == "ok" else 0.0
	_clim_progress_lbl.text = msg if not msg.is_empty() else (
		"Export finished." if result == "ok" else "Export failed.")
	_clim_cancel_btn.text = "Close"
	if result != _clim_last_reported_result:
		_clim_last_reported_result = result
		_notify(("Video exported — %s" % msg) if result == "ok" else ("Export failed — %s" % msg),
			1 if result == "ok" else 3)


const RENDER_TIP := ("Render — pre-compute the whole simulation (battery, water, hydro, camps, "
	+ "people) from the playhead to the end of the Ctrl-drag selection, or the next 24 h, "
	+ "so that stretch plays back from the cache while you explore. The green strip above "
	+ "the clips shows what is rendered; an edit cuts it at the playhead.\n"
	+ "Shift-click: the observed-vs-sim comparison render (needs an imported CSV clip).")
const _MONTHS: Array[String] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep",
	"Oct", "Nov", "Dec"]
const RENDER_STRIP_H := 3.0
const STRIP_RENDERED := Color(0.149, 0.902, 0.467, 0.95)   # green — rendered, plays back
const STRIP_PENDING := Color(0.149, 0.902, 0.467, 0.30)    # the part still rendering
const STRIP_NEEDED := Color(0.937, 0.267, 0.267, 0.80)     # red — selected, not rendered

var _render_card: Control = null
var _render_signals_connected := false


## 📈: pre-render the simulation from the playhead. Shift-click keeps the old
## energy-only observed-vs-sim render into the Compare series.
func _on_render_pressed() -> void:
	if Input.is_key_pressed(KEY_SHIFT):
		var s := _get_solar()
		if s != null and s.has_method("start_batch_render"):
			if not bool(s.call("start_batch_render")):
				_render_toast("Nothing to compare: import a CSV clip (📥) or Ctrl-drag a range first.", true)
			_update_nle_controls()
		return
	var sr := _sim_renderer(true)
	if sr == null:
		_render_toast("The simulation is not up yet.", true)
		return
	var res: Dictionary = sr.call("start", _render_target_end())
	if not bool(res.get("ok", false)):
		_render_toast(str(res.get("why", "Cannot render right now.")), true)
	_update_nle_controls()


## The range end the button renders to: the Ctrl-drag selection's end when it
## lies ahead of the playhead, else the next 24 h.
func _render_target_end() -> float:
	var play := _playhead_abs()
	var s := _get_solar()
	if s != null and s.has_method("get_selection_abs"):
		var sel: PackedFloat64Array = s.call("get_selection_abs")
		if not is_nan(sel[0]) and not is_nan(sel[1]) and sel[1] > play + 1.0 / 60.0:
			return sel[1]
	return play + SimRenderer.DEFAULT_RENDER_H


## The graph view's renderer. `create` false only looks (the 10 Hz control
## refresh and the track draw must not spawn one).
func _sim_renderer(create: bool = false) -> Node:
	var ui_layer := get_parent()
	if ui_layer == null:
		return null
	var gv := ui_layer.get_node_or_null("SystemGraphView")
	if gv == null:
		return null
	var sr: Node = null
	if create and gv.has_method("sim_renderer"):
		sr = gv.call("sim_renderer")
	else:
		var v: Variant = gv.get("_sim_renderer")
		sr = v if v is Node and is_instance_valid(v) else null
	if sr != null and not _render_signals_connected:
		_render_signals_connected = true
		sr.connect("render_started", _on_render_started)
		sr.connect("render_progress", _on_render_progress)
		sr.connect("render_finished", _on_render_finished)
		sr.connect("cache_changed", _on_render_cache_changed)
	return sr


func _ensure_render_card() -> Control:
	if _render_card != null and is_instance_valid(_render_card):
		return _render_card
	var ui_layer := get_parent()
	if ui_layer == null:
		return null
	_render_card = RenderProgressCard.new()
	ui_layer.add_child(_render_card)
	_render_card.connect("cancel_requested", func() -> void:
		var sr := _sim_renderer()
		if sr != null:
			sr.call("cancel"))
	return _render_card


func _on_render_started(a: float, b: float) -> void:
	var card := _ensure_render_card()
	if card != null:
		card.call("show_render", "%s → %s · %s" % [_fmt_abs(a), _fmt_abs(b), UiText.duration(b - a)])
	_update_nle_controls()
	if _track != null:
		_track.queue_redraw()


func _on_render_progress(frac: float, eta_s: float, _cursor: float) -> void:
	if _render_card != null and is_instance_valid(_render_card):
		_render_card.call("set_progress", frac, eta_s)
	if _track != null:
		_track.queue_redraw()


func _on_render_finished(completed: bool, a: float, b: float) -> void:
	if _render_card != null and is_instance_valid(_render_card):
		_render_card.call("finish")
	if b > a + 1e-6:
		_render_toast("%s %s → %s. That stretch now plays back from the cache." % [
			"Rendered" if completed else "Kept the rendered part", _fmt_abs(a), _fmt_abs(b)], false)
	_update_nle_controls()
	if _track != null:
		_track.queue_redraw()


func _on_render_cache_changed() -> void:
	_update_nle_controls()
	if _track != null:
		_track.queue_redraw()


func _render_toast(msg: String, warn: bool) -> void:
	if _main != null and is_instance_valid(_main) and _main.has_method("show_toast"):
		_main.call("show_toast", msg, ToastUI.Level.WARN if warn else ToastUI.Level.INFO, 5.0)
	else:
		print("timeline render: %s" % msg)


## "Oct 17 14:00" for an absolute sim-hour, through the clock's own calendar.
func _fmt_abs(h: float) -> String:
	var clk := _track_clock()
	if clk == null:
		return "%.1f h" % h
	var d: Dictionary = clk.abs_hours_to_date(h)
	var dt := float(d.get("day_time", 0.0))
	var mins := int(round(fmod(dt, 1.0) * 60.0))
	var hrs := int(floor(dt))
	if mins >= 60:
		mins = 0
		hrs += 1
	return "%s %d %02d:%02d" % [_MONTHS[clampi(int(d.get("month", 1)) - 1, 0, 11)],
		int(d.get("day", 1)), hrs % 24, mins]


## The Premiere-style render strip: green over every rendered range, the part
## still rendering in dim green, red over a selection ahead of the playhead
## that is not rendered. Drawn in the band reserved at the top of the clips
## lane.
func _draw_render_strip(y: float, h: float, win_start: float, span: float, w: float,
		solar: Node) -> void:
	var sr := _sim_renderer()
	var play := _playhead_abs()
	var ranges: Array = []
	var active := false
	var active_range := PackedFloat64Array([NAN, NAN])
	var prog := 0.0
	if sr != null:
		ranges = sr.call("ranges")
		active = bool(sr.call("is_active"))
		if active:
			active_range = sr.call("active_range")
			prog = float(sr.call("progress"))
	# Red first (under the green): a selection ahead of the playhead.
	if solar != null and solar.has_method("get_selection_abs"):
		var sel: PackedFloat64Array = solar.call("get_selection_abs")
		if not is_nan(sel[0]) and not is_nan(sel[1]) and sel[1] > sel[0]:
			var a := maxf(sel[0], play)
			if sel[1] > a:
				_draw_strip_span(a, sel[1], y, h, win_start, span, w, STRIP_NEEDED)
	for r in ranges:
		if r is Dictionary:
			_draw_strip_span(float((r as Dictionary)["a"]), float((r as Dictionary)["b"]),
				y, h, win_start, span, w, STRIP_RENDERED)
	if active and not is_nan(active_range[0]):
		var cur := active_range[0] + (active_range[1] - active_range[0]) * prog
		_draw_strip_span(active_range[0], cur, y, h, win_start, span, w, STRIP_RENDERED)
		_draw_strip_span(cur, active_range[1], y, h, win_start, span, w, STRIP_PENDING)


func _draw_strip_span(a0: float, a1: float, y: float, h: float, win_start: float, span: float,
		w: float, col: Color) -> void:
	var x0 := clampf((a0 - win_start) / span * w, 0.0, w)
	var x1 := clampf((a1 - win_start) / span * w, 0.0, w)
	if x1 <= x0:
		return
	_track.draw_rect(Rect2(x0, y, x1 - x0, h), col, true)


# NOTE: the old `_on_render_clim_pressed` keyframe-bake handler was removed — it
# was wired to no button and called `start_climelapse_render`, which TerrainLoader
# no longer implements (the bake folded into `start_climelapse_export`). 🎬 is the
# whole climelapse path now.



func _on_loadmode_pressed() -> void:
	var s := _get_solar()
	if s == null or not s.has_method("get_render_load_mode"):
		return
	var m := int(s.call("get_render_load_mode"))
	s.call("set_render_load_mode", 0 if m == 1 else 1)   # toggle CSV(0) ↔ MODELED(1)
	_update_nle_controls()


func _on_compare_pressed() -> void:
	if _main != null and is_instance_valid(_main) and _main.has_method("open_compare_view"):
		# 64-bit: a Vector2 selection is rounded to 2 h at absolute-hour scale.
		var sel := PackedFloat64Array([NAN, NAN])
		var s := _get_solar()
		if s != null and s.has_method("get_selection_abs"):
			sel = s.call("get_selection_abs")
			if not is_nan(sel[0]) and sel[1] <= sel[0]:
				sel = PackedFloat64Array([NAN, NAN])
		_main.call("open_compare_view", sel)


func _on_load_video_pressed() -> void:
	var pc := _ensure_projection_canvas()
	if pc != null and pc.has_method("open_load_video_dialog"):
		pc.call("open_load_video_dialog")
	else:
		_notify("Load video: no projection canvas on this map.")


func _on_live_feed_pressed() -> void:
	var pc := _ensure_projection_canvas()
	if pc != null and pc.has_method("open_live_feed_dialog"):
		pc.call("open_live_feed_dialog")
	else:
		_notify("Live feed: no projection canvas on this map.")


func _on_snap_video_pressed() -> void:
	var pc := _get_projection_canvas()
	if pc != null and pc.has_method("set_video_start_abs_hours"):
		pc.call("set_video_start_abs_hours", _playhead_abs())
	if _track != null:
		_track.queue_redraw()


## Refresh the left-cluster NLE icons / enabled state from SolarUI.
func _update_nle_controls() -> void:
	var s := _get_solar()
	if s != null:
		if not _solar_signals_connected:
			if s.has_signal("observed_clip_changed"):
				s.connect("observed_clip_changed", Callable(self, "_on_solar_clip_changed"))
			if s.has_signal("render_state_changed"):
				s.connect("render_state_changed", Callable(self, "_on_solar_clip_changed"))
			var pc := _get_projection_canvas()
			if pc != null and pc.has_signal("video_clip_changed"):
				pc.connect("video_clip_changed", Callable(self, "_on_solar_clip_changed"))
			_solar_signals_connected = true
		if _loadmode_btn != null and s.has_method("get_render_load_mode"):
			var csv_mode := int(s.call("get_render_load_mode")) == 0
			_loadmode_btn.text = "📄" if csv_mode else "🧮"
			_loadmode_btn.tooltip_text = (
					"Render load source: CSV (observed load — isolates solar/weather error). Click for Modeled."
					if csv_mode else
					"Render load source: Modeled (simulates load too). Click for CSV.")
		if _render_progress_lbl != null and s.has_method("get_render_progress"):
			var parts: PackedStringArray = []
			if s.has_method("is_rendering") and bool(s.call("is_rendering")):
				parts.append("E%d%%" % int(round(float(s.call("get_render_progress")) * 100.0)))
			elif float(s.call("get_render_progress")) >= 1.0:
				parts.append("E✓")
			var tl := _get_terrain_loader()
			if tl != null and tl.has_method("is_climelapse_rendering"):
				if bool(tl.call("is_climelapse_rendering")):
					var cp := float(tl.call("get_climelapse_progress"))
					parts.append("C%d%%" % int(round(cp * 100.0)))
				elif tl.has_method("get_climelapse_progress") and float(tl.call("get_climelapse_progress")) >= 1.0:
					parts.append("C✓")
			_render_progress_lbl.text = " ".join(parts)

	# Snap button enabled only when a video is loaded.
	if _snap_video_btn != null:
		var pc2 := _get_projection_canvas()
		var has_video := pc2 != null and pc2.has_method("get_video_clip_range_abs") and \
			not is_nan((pc2.call("get_video_clip_range_abs") as PackedFloat64Array)[0])
		_snap_video_btn.disabled = not has_video
	if _render_btn != null:
		var tl2 := _get_terrain_loader()
		var clim_busy := tl2 != null and tl2.has_method("is_climelapse_rendering") \
			and bool(tl2.call("is_climelapse_rendering"))
		# The sim render needs no clip (it renders from the playhead); only a
		# render / bake / export already owning the world disables it.
		var sr := _sim_renderer()
		var render_busy := sr != null and bool(sr.call("is_active"))
		var clock_owned := _main != null and is_instance_valid(_main) \
			and _main.has_method("clock_is_owned") and bool(_main.call("clock_is_owned"))
		_render_btn.disabled = clim_busy or render_busy or (clock_owned and not render_busy)
		_render_btn.tooltip_text = ("Rendering… (click Cancel on the card to stop)" if render_busy
			else RENDER_TIP)
		_dim_disabled(_render_btn)
		_dim_disabled(_compare_btn)
		_dim_disabled(_snap_video_btn)
	if not _clim_signals_connected:
		var tl4 := _get_terrain_loader()
		if tl4 != null and tl4.has_signal("climelapse_state_changed"):
			tl4.connect("climelapse_state_changed", Callable(self, "_on_climelapse_changed"))
			_clim_signals_connected = true


func _on_solar_clip_changed() -> void:
	if _track != null:
		_track.queue_redraw()
	_update_nle_controls()


func _on_climelapse_changed() -> void:
	if _track != null:
		_track.queue_redraw()
	_update_clim_progress_dialog()
	_update_nle_controls()


# NOTE: the old auto-play-after-render pair (`_maybe_auto_play_climelapse` /
# `_start_climelapse_playback_after_render`) was removed. It forced the sim into
# the ∞ analemma stepper when an export finished — while the speed label still
# read whatever the player had picked — which is what made a finished (or
# instantly-refused) export look like "the game just started flying". An export
# now leaves the clock parked and paused where the player left it.


func _build_info_row(parent: VBoxContainer) -> void:
	_info_row = Control.new()
	_info_row.name = "InfoRow"
	_info_row.custom_minimum_size = Vector2(0, INFO_ROW_HEIGHT)
	_info_row.size_flags_vertical = Control.SIZE_FILL
	_info_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_info_row.clip_contents = true
	_info_row.mouse_filter = Control.MOUSE_FILTER_PASS
	_info_row.resized.connect(_layout_info_clusters)
	parent.add_child(_info_row)

	_left_cluster = _build_left_cluster()
	_info_row.add_child(_left_cluster)
	_center_time_cluster = _build_center_cluster()
	_info_row.add_child(_center_time_cluster)
	_right_cluster = _build_right_cluster()
	_info_row.add_child(_right_cluster)
	# A label whose text changes width (sunset time, moon phase, the
	# multiplayer status, "3D wires ●") re-runs the measured layout.
	for c: Control in [_left_cluster, _center_time_cluster, _mp_chip, _conduits_chip]:
		if c != null:
			c.minimum_size_changed.connect(_queue_info_layout)

	call_deferred("_layout_info_clusters")


var _info_layout_queued := false


func _queue_info_layout() -> void:
	if _info_layout_queued:
		return
	_info_layout_queued = true
	call_deferred("_run_queued_info_layout")


func _run_queued_info_layout() -> void:
	_info_layout_queued = false
	_layout_info_clusters()


func _layout_info_clusters() -> void:
	if _info_row == null:
		return
	var row_w := _info_row.size.x
	var row_h := _info_row.size.y
	if row_w <= 1.0:
		return
	var usable_h := maxf(1.0, row_h - INFO_ROW_BOTTOM_PAD)
	# Fold the right cluster's least-used buttons into the ⋯ menu until the
	# centre cluster fits BETWEEN the side clusters (it used to be centred on
	# the row regardless, so the date spinboxes and the sunset / moon readout
	# drew straight over the Multiplayer / 3D wires / Projects chips).
	_fold_right_cluster(row_w)
	for c: Control in [_left_cluster, _center_time_cluster, _right_cluster]:
		if c == null:
			continue
		var cs: Vector2 = c.get_combined_minimum_size()
		if c == _right_cluster:
			cs.x = _right_cluster_width()
		c.size = cs
		c.position.y = maxf(0.0, (usable_h - cs.y) * 0.5)
	var lo := INFO_ROW_EDGE_PAD
	var hi := row_w - INFO_ROW_EDGE_PAD
	if _left_cluster != null:
		_left_cluster.position.x = INFO_ROW_EDGE_PAD
		lo = _left_cluster.position.x + _left_cluster.size.x + CENTER_CLUSTER_GAP
	if _right_cluster != null:
		_right_cluster.position.x = row_w - _right_cluster.size.x - INFO_ROW_EDGE_PAD
		hi = _right_cluster.position.x - CENTER_CLUSTER_GAP
	if _center_time_cluster != null:
		var cw := _center_time_cluster.size.x
		var x := (row_w - cw) * 0.5
		# Centred when it can be, otherwise slid into the gap between the
		# clusters; only if even the gap is too narrow does it hug the left.
		x = minf(x, hi - cw)
		x = maxf(x, lo)
		_center_time_cluster.position.x = x


## The right cluster's width from its VISIBLE children — the container's own
## cached minimum size lags a frame behind a visibility change.
func _right_cluster_width() -> float:
	if _right_cluster == null:
		return 0.0
	var sep := float(_right_cluster.get_theme_constant("separation"))
	var w := 0.0
	var n := 0
	for ch in _right_cluster.get_children():
		var c := ch as Control
		if c == null or not c.visible:
			continue
		w += c.get_combined_minimum_size().x
		n += 1
	return w + sep * maxf(n - 1, 0)


## Folds buttons in fold order (least used first) while the three clusters
## do not fit the row. Widths are measured off every button whether shown or
## not, so the decision needs no visibility churn; visibility and the menu are
## rewritten only when the fold COUNT changes (this runs as the clock text
## changes, and hiding a hovered button every frame would flicker it).
## Folded buttons live on in the ⋯ menu with the same action.
func _fold_right_cluster(row_w: float) -> void:
	if _right_cluster == null or _right_overflow == null:
		return
	var sep := float(_right_cluster.get_theme_constant("separation"))
	var folded_set := {}
	for it in _right_fold_items:
		folded_set[it["btn"]] = true
	var right_w := 0.0
	var n := 0
	for ch in _right_cluster.get_children():
		var c := ch as Control
		if c == null or c == _right_overflow:
			continue
		right_w += c.get_combined_minimum_size().x
		n += 1
	right_w += sep * maxf(n - 1, 0)
	var left_w := _left_cluster.get_combined_minimum_size().x if _left_cluster != null else 0.0
	var center_w := _center_time_cluster.get_combined_minimum_size().x if _center_time_cluster != null else 0.0
	var fixed := INFO_ROW_EDGE_PAD * 2.0 + left_w + center_w + CENTER_CLUSTER_GAP * 2.0
	var over_w := _right_overflow.get_combined_minimum_size().x + sep
	var count := 0
	while count < _right_fold_items.size():
		var w := right_w + (over_w if count > 0 else 0.0)
		if fixed + w <= row_w:
			break
		right_w -= (_right_fold_items[count]["btn"] as Control).get_combined_minimum_size().x + sep
		count += 1
	if count == _right_folded:
		return
	_right_folded = count
	var pop := _right_overflow.get_popup()
	pop.clear()
	for i in _right_fold_items.size():
		var fold := i < count
		(_right_fold_items[i]["btn"] as Control).visible = not fold
		if fold:
			pop.add_item(str(_right_fold_items[i]["label"]), i)
	_right_overflow.visible = count > 0
	_right_overflow.tooltip_text = "More — %s" % UiText.count(count, "tool")


func _on_right_overflow_id(id: int) -> void:
	if id < 0 or id >= _right_fold_items.size():
		return
	var btn := _right_fold_items[id]["btn"] as Button
	if btn != null:
		btn.pressed.emit()


func _build_center_cluster() -> Control:
	var master := HBoxContainer.new()
	master.alignment = BoxContainer.ALIGNMENT_CENTER
	master.add_theme_constant_override("separation", 16)
	
	# [1] Sunrise
	var astro_left := VBoxContainer.new()
	astro_left.alignment = BoxContainer.ALIGNMENT_CENTER
	_sunrise_lbl = _mk_astro_label("🌅 6:00", C_GOLD, "Sunrise (local solar time)")
	astro_left.add_child(_sunrise_lbl)
	master.add_child(astro_left)
	
	# [2] Clock Time
	_time_lbl = Label.new()
	_time_lbl.text = "12:00 PM"
	_time_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_time_lbl.tooltip_text = "Local time at the playhead. Drag the track above to scrub."
	_time_lbl.add_theme_color_override("font_color", C_PRIMARY)
	_time_lbl.add_theme_font_size_override("font_size", 22)
	# Tabular figures + a width pinned to the widest possible reading: the
	# clock text changes every sim minute, and an unpinned proportional label
	# re-centred the whole cluster on every tick, jittering the transport,
	# date and sun/moon controls beside it (_pin_label_widths).
	_time_lbl.add_theme_font_override("font", UITheme.font("regular", true))
	master.add_child(_time_lbl)
	
	# [3] Transport Controls + Speed
	var transport_panel := PanelContainer.new()
	transport_panel.mouse_filter = Control.MOUSE_FILTER_PASS
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(C_PANEL.r, C_PANEL.g, C_PANEL.b, 0.72)
	sb.border_color = Color(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.85)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(22)
	sb.set_content_margin_all(4.0)
	sb.content_margin_left = 10.0
	sb.content_margin_right = 10.0
	transport_panel.add_theme_stylebox_override("panel", sb)
	var ctrl := HBoxContainer.new()
	ctrl.alignment = BoxContainer.ALIGNMENT_CENTER
	ctrl.add_theme_constant_override("separation", 10)
	var slow_btn := _mk_transport_btn("◀◀", _on_slower_pressed, "Slower (D-pad Left on controller)")
	ctrl.add_child(slow_btn)
	_play_btn = _mk_play_btn()
	ctrl.add_child(_play_btn)
	var fast_btn := _mk_transport_btn("▶▶", _on_faster_pressed, "Faster (D-pad Right on controller)")
	ctrl.add_child(fast_btn)
	var spd_box := VBoxContainer.new()
	spd_box.alignment = BoxContainer.ALIGNMENT_CENTER
	spd_box.add_theme_constant_override("separation", 0)
	spd_box.tooltip_text = "Time-lapse speed. ◀◀ / ▶▶ to change (1× = real time)."
	var spd_hdr := Label.new()
	spd_hdr.text = "SPEED"
	spd_hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	spd_hdr.add_theme_color_override("font_color", C_TEXT_M)
	spd_hdr.add_theme_font_size_override("font_size", 8)
	spd_box.add_child(spd_hdr)
	_speed_lbl = Label.new()
	_speed_lbl.text = str(SPEED_STEPS[_speed_idx][0])
	_speed_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_speed_lbl.custom_minimum_size  = Vector2(46, 0)
	_speed_lbl.add_theme_color_override("font_color", C_AMBER)
	_speed_lbl.add_theme_font_size_override("font_size", 14)
	spd_box.add_child(_speed_lbl)
	# "Held" pill: shown only while a claim pins the clock at 0 (CSV playback,
	# a challenge bake, an export…). Play/speed write the user's base scale, so
	# without this the buttons would appear to do nothing.
	_hold_lbl = Label.new()
	_hold_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hold_lbl.add_theme_color_override("font_color", C_AMBER)
	_hold_lbl.add_theme_font_size_override("font_size", 9)
	_hold_lbl.add_theme_stylebox_override("normal", UITheme.chip_style(C_AMBER))
	_hold_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	_hold_lbl.visible = false
	spd_box.add_child(_hold_lbl)
	ctrl.add_child(spd_box)
	transport_panel.add_child(ctrl)
	master.add_child(transport_panel)
	
	# [4] Date Spinboxes (MM / DD / YYYY)
	var date_row := HBoxContainer.new()
	date_row.alignment = BoxContainer.ALIGNMENT_CENTER
	date_row.add_theme_constant_override("separation", 4)
	_year_input = _mk_date_spin(1940, 2100, 1.0, "Simulation year")
	_month_input = _mk_date_spin(1, 12, 1.0, "Month (1–12)")
	_day_input = _mk_date_spin(1, 31, 1.0, "Day of month")
	_year_input.value_changed.connect(_on_year_changed)
	_month_input.value_changed.connect(_on_month_changed)
	_day_input.value_changed.connect(_on_day_changed)
	date_row.add_child(_wrap_date_spin("M", _month_input))
	date_row.add_child(_wrap_date_spin("D", _day_input))
	date_row.add_child(_wrap_date_spin("Y", _year_input))
	master.add_child(date_row)
	
	# [5] Sunset & Moon Phase
	var astro_right := VBoxContainer.new()
	astro_right.alignment = BoxContainer.ALIGNMENT_CENTER
	astro_right.add_theme_constant_override("separation", 1)
	_sunset_lbl = _mk_astro_label("🌇 7:00", C_GOLD, "Sunset (local solar time)")
	astro_right.add_child(_sunset_lbl)
	_moon_lbl = _mk_astro_label("🌕 Full", C_LAVENDER, "Moon phase")
	astro_right.add_child(_moon_lbl)
	master.add_child(astro_right)
	for l: Label in [_sunrise_lbl, _sunset_lbl, _moon_lbl]:
		l.add_theme_font_override("font", UITheme.font("regular", true))
	_pin_label_widths()
	master.theme_changed.connect(_pin_label_widths)
	
	return master


## Every label in the centre cluster whose text changes as the clock runs is
## pinned to the width of its WIDEST possible text, so the cluster's minimum
## width — and with it the centring and the right cluster's fold count — is
## constant. Tabular figures alone are not enough: "9:05 AM" and "12:05 PM"
## differ by a digit, and AM / PM differ in width.
const _CLOCK_SAMPLES := ["12:00 AM", "12:00 PM", "10:00 AM", "10:00 PM", "88:88 AM", "88:88 PM"]
const _MOON_SAMPLES := ["New", "Waxing", "First", "Full", "Waning", "Last", "Third"]


func _pin_label_widths() -> void:
	_pin_label_width(_time_lbl, _CLOCK_SAMPLES)
	var astro: Array = []
	for t in _CLOCK_SAMPLES:
		astro.append("🌅 %s" % t)
		astro.append("🌇 %s" % t)
	_pin_label_width(_sunrise_lbl, astro)
	_pin_label_width(_sunset_lbl, astro)
	var moon: Array = []
	for e in MOON_EMOJIS:
		for n in _MOON_SAMPLES:
			moon.append("%s %s" % [e, n])
	_pin_label_width(_moon_lbl, moon)


static func widest_text_px(lbl: Label, samples: Array) -> float:
	if lbl == null:
		return 0.0
	var f: Font = lbl.get_theme_font("font")
	var fs: int = lbl.get_theme_font_size("font_size")
	if f == null:
		return 0.0
	var w := 0.0
	for t in samples:
		w = maxf(w, f.get_string_size(str(t), HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x)
	return ceilf(w) + 2.0


func _pin_label_width(lbl: Label, samples: Array) -> void:
	if lbl == null:
		return
	var w := widest_text_px(lbl, samples)
	if w > 0.0 and absf(lbl.custom_minimum_size.x - w) > 0.5:
		lbl.custom_minimum_size.x = w


## RIGHT — system icons (save / settings / shading / import shortcut / …).
## Pinned to the right edge; mirrors the left NLE cluster.
func _build_right_cluster() -> Control:
	var right := HBoxContainer.new()
	right.alignment             = BoxContainer.ALIGNMENT_END
	right.add_theme_constant_override("separation", 4)

	var sl_btn := _mk_icon_btn("💾", _on_save_load_pressed, "World — save, copy, start a new world on this map, exit to menu")
	right.add_child(sl_btn)
	_mp_chip = _mk_chip_btn("Multiplayer", _on_mp_pressed,
		"Multiplayer — host or join a private listen-server session (avatars + shared clock)")
	right.add_child(_mp_chip)
	_ha_chip = _mk_chip_btn("HA", _on_ha_chip_pressed,
		"Home Assistant — not connected. Click to set it up.")
	right.add_child(_ha_chip)
	_hook_ha_chip()
	_conduits_chip = _mk_chip_btn("3D wires", _on_conduits_chip_pressed,
		"Toggle 3D graph wires in the world (off by default for performance)")
	right.add_child(_conduits_chip)
	_projects_chip = _mk_chip_btn("Projects", _on_projects_chip_pressed,
		"Site Projects — the crew's work queue: unload → fabricate → raise → break down")
	right.add_child(_projects_chip)
	_settlement_chip = _mk_chip_btn("Settlement", _on_settlement_chip_pressed,
		"Settlement view — watch the community at work, from ground level out to the whole site")
	right.add_child(_settlement_chip)
	_festival_chip = _mk_chip_btn("Festival", _on_festival_chip_pressed,
		"Festival mode — populate every painted camp, assume the camps stocked (no starving, no queues, no leaving), and watch the crowd from the settlement view")
	right.add_child(_festival_chip)
	_sfx_btn = _mk_icon_btn("🔇", _on_sfx_pressed, "")
	right.add_child(_sfx_btn)
	var sfx := get_node_or_null("/root/UiSound")
	if sfx != null and sfx.has_signal("muted_changed") and not sfx.is_connected("muted_changed", _on_sfx_muted_changed):
		sfx.connect("muted_changed", _on_sfx_muted_changed)
	_refresh_sfx_btn()
	var gear_btn := _mk_icon_btn("⚙", _on_settings_pressed, "Settings — simulation, player, graphics & sky, site, integrations")
	right.add_child(gear_btn)
	_shading_btn = _mk_icon_btn("🔆", _on_solar_shading_pressed, "Solar shading — compute a year-long shadow heatmap")
	right.add_child(_shading_btn)
	var csv_btn := _mk_icon_btn("📂", _on_csv_playback_pressed, "Open datastream CSV (same as Import on the left)")
	right.add_child(csv_btn)
	_linkagelab_btn = _mk_icon_btn("🎮", _on_linkagelab_import_pressed,
		"LinkageLab — import a .gamebundle.json into this map")
	right.add_child(_linkagelab_btn)
	var record_btn := _mk_icon_btn("🌡", _on_record_book_pressed, "Climate Record Book — historical records & trends for this location")
	right.add_child(record_btn)
	var report_btn := _mk_icon_btn("📊", _on_site_report_pressed, "Site Report — year-round & month-by-month solar/wind/rain/PV analysis for this site")
	right.add_child(report_btn)
	var mc_btn := _mk_icon_btn("🌫", _on_microclimate_pressed,
		"Microclimate — calibrate how this site's fog, haze, cloud and wind look against the weather data")
	right.add_child(mc_btn)
	var lib_btn := _mk_icon_btn("📦", _on_library_pressed,
		"Library — buildings, graph nodes, vegetation & structures")
	right.add_child(lib_btn)
	var challenge_btn := _mk_icon_btn("🎯", _on_challenge_pressed, "Challenges — structured survival missions")
	right.add_child(challenge_btn)
	var map_btn := _mk_icon_btn("🗺", _on_map_select_pressed, "Map select — return to the map chooser")
	right.add_child(map_btn)

	_right_overflow = MenuButton.new()
	_right_overflow.text = "⋯"
	_right_overflow.flat = false
	_right_overflow.focus_mode = Control.FOCUS_NONE
	_right_overflow.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_right_overflow.custom_minimum_size = Vector2(38, 38)
	_right_overflow.add_theme_font_size_override("font_size", 18)
	_right_overflow.visible = false
	_right_overflow.get_popup().id_pressed.connect(_on_right_overflow_id)
	right.add_child(_right_overflow)

	# Fold order: least-used first. Save, Sound, Settings and the Library never fold.
	_right_fold_items.clear()
	for pair in [[csv_btn, "Open datastream CSV"], [_linkagelab_btn, "Import LinkageLab bundle"],
			[_shading_btn, "Solar shading"], [mc_btn, "Microclimate"],
			[record_btn, "Climate Record Book"], [challenge_btn, "Challenges"],
			[report_btn, "Site Report"], [map_btn, "Map select"],
			[_mp_chip, "Multiplayer"], [_conduits_chip, "3D wires"],
			[_festival_chip, "Festival mode"], [_settlement_chip, "Settlement view"],
			[_projects_chip, "Site Projects"], [_ha_chip, "Home Assistant"]]:
		var b: Button = pair[0]
		var lbl := str(pair[1])
		if b.text.length() <= 2:
			lbl = "%s  %s" % [b.text, lbl]
		_right_fold_items.append({"btn": b, "label": lbl})

	return right


## Sound effects on / off — the same switch as Settings → UI sounds (UiSound
## autoload, resolved by path: the autoload-identifier trap).
func _on_sfx_pressed() -> void:
	var sfx := get_node_or_null("/root/UiSound")
	if sfx != null:
		sfx.call("toggle_muted")
	_refresh_sfx_btn()


func _on_sfx_muted_changed(_on: bool) -> void:
	_refresh_sfx_btn()


func _refresh_sfx_btn() -> void:
	if _sfx_btn == null:
		return
	var sfx := get_node_or_null("/root/UiSound")
	var muted := sfx == null or bool(sfx.call("is_muted"))
	_sfx_btn.text = "🔇" if muted else "🔊"
	_sfx_btn.tooltip_text = ("Sound effects are OFF — click to turn them on" if muted
		else "Sound effects are ON — click to mute them (wind, rain, birds, thunder, UI chirps; not stage music)")


func _on_library_pressed() -> void:
	if _main == null:
		return
	if _main.has_method("open_unified_library"):
		_main.call("open_unified_library")
		return
	var loader := _main.get_node_or_null("TerrainLoader")
	if loader == null:
		loader = TerrainSurfaceQuery.find_terrain_loader(_main)
	if loader != null and loader.has_method("open_unified_library"):
		loader.call("open_unified_library")
		return
	if loader != null and loader.has_method("open_building_builder"):
		loader.call("open_building_builder", -1)


func _on_settings_pressed() -> void:
	if _settings_panel != null and _settings_panel.has_method("toggle"):
		_settings_panel.toggle()


## Home Assistant status chip: grey = off, amber = connecting / retrying,
## green = connected (with how many sensors are live), red = failed. A click
## opens Settings on the Home Assistant page.
func _hook_ha_chip() -> void:
	var ha := get_node_or_null("/root/HomeAssistant")
	if ha == null:
		_ha_chip.visible = false
		return
	if not ha.is_connected("state_changed", _on_ha_state_changed):
		ha.connect("state_changed", _on_ha_state_changed)
	_refresh_ha_chip()


func _on_ha_state_changed(_state: int, _info: Dictionary) -> void:
	_refresh_ha_chip()


func _refresh_ha_chip() -> void:
	if _ha_chip == null or Engine.is_editor_hint():
		return
	var ha := get_node_or_null("/root/HomeAssistant")
	if ha == null:
		return
	var st := int(ha.get("state"))
	var info: Dictionary = ha.call("info")
	var col := UITheme.C_TEXT_M
	var text := "HA"
	match st:
		HomeAssistantService.State.CONNECTING, HomeAssistantService.State.AUTHENTICATING:
			col = UITheme.C_WARN
			text = "HA …"
		HomeAssistantService.State.CONNECTED:
			col = UITheme.C_OK
			var live := int(ha.call("live_link_count")) if ha.has_method("live_link_count") else 0
			text = "HA · %d live" % live if live > 0 else "HA"
		HomeAssistantService.State.FAILED:
			col = UITheme.C_WARN if info.has("retry_in_s") else UITheme.C_ERROR
			text = "HA ✕"
	_ha_chip.text = text
	_ha_chip.add_theme_color_override("font_color", col)
	var tip := "Home Assistant — %s" % str(ha.call("status_text"))
	if st == HomeAssistantService.State.FAILED:
		tip += "\n" + str(info.get("detail", ""))
	tip += "\nClick to open the Home Assistant settings."
	_ha_chip.tooltip_text = tip


func _on_ha_chip_pressed() -> void:
	open_settings_page("Home Assistant")


## Open the Settings modal on one page (by its title).
func open_settings_page(title: String) -> void:
	if _settings_panel == null:
		return
	if _settings_panel.has_method("open"):
		_settings_panel.call("open")
	if _settings_panel.has_method("open_page"):
		_settings_panel.call("open_page", title)


func _on_mp_pressed() -> void:
	_setup_mp_lobby()
	if _mp_lobby != null and _mp_lobby.has_method("toggle"):
		_mp_lobby.call("toggle")


func _on_solar_shading_pressed() -> void:
	if _shading_decal != null and _shading_decal.is_inside_tree():
		_shading_decal.queue_free()
		_shading_decal = null
		_shading_btn.text = "🔆"
		return
		
	if _solar_analyzer != null and _solar_analyzer.is_running():
		return
		
	if _solar_analyzer == null:
		_solar_analyzer = SolarShadingAnalyzer.new()
		add_child(_solar_analyzer)
		_solar_analyzer.progress_updated.connect(_on_shading_progress)
		_solar_analyzer.analysis_completed.connect(_on_shading_completed)
		
	if _shading_overlay == null:
		_shading_overlay = PanelContainer.new()
		var p_style = StyleBoxFlat.new()
		p_style.bg_color = Color(0.1, 0.1, 0.1, 0.9)
		p_style.set_corner_radius_all(8)
		p_style.content_margin_left = 20
		p_style.content_margin_right = 20
		p_style.content_margin_top = 20
		p_style.content_margin_bottom = 20
		_shading_overlay.add_theme_stylebox_override("panel", p_style)
		
		var vbox = VBoxContainer.new()
		vbox.alignment = BoxContainer.ALIGNMENT_CENTER
		vbox.add_theme_constant_override("separation", 10)
		_shading_overlay.add_child(vbox)
		
		var title = Label.new()
		title.text = "Solar Shading Analysis"
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		title.add_theme_font_size_override("font_size", 16)
		vbox.add_child(title)
		
		_shading_status = Label.new()
		_shading_status.text = "Initializing..."
		_shading_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_shading_status.add_theme_font_size_override("font_size", 12)
		vbox.add_child(_shading_status)
		
		_shading_progress = ProgressBar.new()
		_shading_progress.custom_minimum_size = Vector2(300, 20)
		_shading_progress.max_value = 1.0
		vbox.add_child(_shading_progress)
		
		add_child(_shading_overlay)
		_shading_overlay.set_anchors_preset(Control.PRESET_CENTER)
		
	_shading_overlay.show()
	_solar_analyzer.start_analysis(_main, 128)

func _on_shading_progress(pct: float, text: String) -> void:
	if _shading_progress:
		_shading_progress.value = pct
	if _shading_status:
		_shading_status.text = text

func _on_shading_completed(heatmap: ImageTexture, rect: Rect2) -> void:
	if _shading_overlay:
		_shading_overlay.hide()
	
	if heatmap == null:
		push_warning("TimelineUI: Shading analysis failed.")
		return
		
	if _shading_decal == null:
		_shading_decal = Decal.new()
		var map_parent = _main.get_node_or_null("Terrain")
		if not map_parent: map_parent = _main
		map_parent.add_child(_shading_decal)
		
	_shading_decal.texture_albedo = heatmap
	_shading_decal.size = Vector3(rect.size.x, 2000.0, rect.size.y)
	
	# Compute center and ground Y
	var center_x = rect.position.x + rect.size.x * 0.5
	var center_z = rect.position.y + rect.size.y * 0.5
	var gy = TerrainSurfaceQuery.ground_height_at(_main, center_x, center_z)
	
	_shading_decal.global_position = Vector3(center_x, gy, center_z)
	_shading_btn.text = "✖" # Turn into a clear button



func _on_record_book_pressed() -> void:
	if _record_book_panel == null:
		var script := load("res://scenes/ui/record_book_panel.gd") as Script
		if script == null:
			push_warning("TimelineUI: could not load record_book_panel.gd")
			return
		_record_book_panel = Control.new()
		_record_book_panel.set_script(script)
		if _record_book_panel.has_method("bind_timeline"):
			_record_book_panel.bind_timeline(self)
	if _record_book_panel.has_method("toggle"):
		_record_book_panel.toggle()


func _on_site_report_pressed() -> void:
	if _site_report_panel == null:
		var script := load("res://scenes/ui/site_report_panel.gd") as Script
		if script == null:
			push_warning("TimelineUI: could not load site_report_panel.gd")
			return
		_site_report_panel = Control.new()
		_site_report_panel.set_script(script)
		if _site_report_panel.has_method("bind_timeline"):
			_site_report_panel.bind_timeline(self)
	if _site_report_panel.has_method("toggle"):
		_site_report_panel.toggle()


func _on_microclimate_pressed() -> void:
	if _microclimate_drawer == null or not is_instance_valid(_microclimate_drawer):
		var script := load("res://scenes/ui/microclimate_drawer.gd") as Script
		if script == null:
			push_warning("TimelineUI: could not load microclimate_drawer.gd")
			return
		_microclimate_drawer = CanvasLayer.new()
		_microclimate_drawer.set_script(script)
		_microclimate_drawer.call("bind_timeline", self)
		get_tree().root.add_child(_microclimate_drawer)
	_microclimate_drawer.call("toggle")


func _on_challenge_pressed() -> void:
	_open_challenge_picker()


func _on_challenge_chip_pressed() -> void:
	_open_challenge_picker()


func _open_challenge_picker() -> void:
	var panel := ensure_challenge_picker()
	if panel != null and panel.has_method("toggle"):
		panel.toggle()


func ensure_challenge_picker() -> Control:
	if _challenge_picker_panel == null:
		var script := load("res://scenes/ui/challenge_picker_panel.gd") as Script
		if script == null:
			push_warning("TimelineUI: could not load challenge_picker_panel.gd")
			return null
		_challenge_picker_panel = Control.new()
		_challenge_picker_panel.name = "ChallengePickerPanel"
		_challenge_picker_panel.set_script(script)
		if _challenge_picker_panel.has_method("bind_timeline"):
			_challenge_picker_panel.bind_timeline(self)
	return _challenge_picker_panel


func on_challenge_started(_id: String, def: Variant) -> void:
	_update_challenge_chip(def)
	if _challenge_picker_panel != null and _challenge_picker_panel.has_method("refresh_active_label"):
		_challenge_picker_panel.refresh_active_label()


func on_challenge_tick(_id: String, _metrics: Dictionary, elapsed_h: float) -> void:
	_update_challenge_chip(null, elapsed_h)


func on_challenge_finished() -> void:
	_update_challenge_chip()
	if _challenge_picker_panel != null and _challenge_picker_panel.has_method("refresh_active_label"):
		_challenge_picker_panel.refresh_active_label()


func show_challenge_result(challenge_id: String, won: bool, payload: Dictionary) -> void:
	var panel := ensure_challenge_picker()
	if panel != null and panel.has_method("show_result"):
		panel.show_result(challenge_id, won, payload)


func _update_challenge_chip(def: Variant = null, elapsed_h: float = -1.0) -> void:
	if _challenge_chip == null:
		return
	var runner: Node = null
	if _main != null:
		runner = _main.get_node_or_null("ChallengeRunner") as Node
	if runner == null or not bool(runner.call("is_active")):
		_challenge_chip.text = "🎯 Mission"
		_challenge_chip.tooltip_text = "Challenges — click to pick a mission"
		_style_challenge_chip(UITheme.C_TEXT_M)
		return
	if def == null and runner.has_method("active_def"):
		def = runner.call("active_def")
	var title := str(def.title) if def != null else str(runner.call("active_challenge_id"))
	if elapsed_h < 0.0 and runner.has_method("evaluate_now"):
		var ev: Dictionary = runner.call("evaluate_now") as Dictionary
		elapsed_h = float(ev.get("elapsed_h", 0.0))
	var dur := float(def.duration_hours) if def != null else 0.0
	var short := title
	if short.length() > 10:
		short = short.substr(0, 9) + "…"
	_challenge_chip.text = "🎯 %s %.0f/%.0fh" % [short, elapsed_h, dur]
	_challenge_chip.tooltip_text = "%s — %.0f / %.0f h elapsed · click for missions" % [
			title, elapsed_h, dur]
	_style_challenge_chip(UITheme.C_AMBER)


func _style_challenge_chip(col: Color) -> void:
	var sb: StyleBox = _challenge_chip.get_theme_stylebox("normal")
	if sb is StyleBoxFlat:
		var sbf := (sb as StyleBoxFlat).duplicate() as StyleBoxFlat
		sbf.border_color = col
		sbf.bg_color = Color(col.r, col.g, col.b, 0.18)
		_challenge_chip.add_theme_stylebox_override("normal", sbf)
	_challenge_chip.add_theme_color_override("font_color", col)


func _on_year_changed(value: float) -> void:
	if _date_syncing or Engine.is_editor_hint():
		return
	if is_instance_valid(SimSettingsController):
		SimSettingsController.apply_year(int(value))
		_update_day_spin_max(int(_month_input.value), int(value))
	_recenter_track_on_playhead()


func _on_month_changed(value: float) -> void:
	if _date_syncing or Engine.is_editor_hint():
		return
	if is_instance_valid(SimSettingsController):
		SimSettingsController.apply_month(int(value))
		_update_day_spin_max(int(value), int(_year_input.value))
	_recenter_track_on_playhead()


func _on_day_changed(value: float) -> void:
	if _date_syncing or Engine.is_editor_hint():
		return
	if is_instance_valid(SimSettingsController):
		SimSettingsController.apply_day(int(value))
	_recenter_track_on_playhead()


func _update_day_spin_max(month: int, year: int) -> void:
	if _day_input == null or not is_instance_valid(SimSettingsController):
		return
	var max_days := SimSettingsController.update_day_max_for(month, year)
	_day_input.max_value = max_days


func _mk_date_spin(min_v: float, max_v: float, step: float, tip: String) -> SpinBox:
	var sp := SpinBox.new()
	sp.min_value = min_v
	sp.max_value = max_v
	sp.step = step
	sp.editable = true
	sp.select_all_on_focus = true
	sp.tooltip_text = tip
	sp.custom_minimum_size = Vector2(46, 22)
	sp.add_theme_font_size_override("font_size", 10)
	return sp


func _wrap_date_spin(title: String, spin: SpinBox) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 1)
	box.tooltip_text = spin.tooltip_text
	var hdr := Label.new()
	hdr.text = title
	hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hdr.add_theme_color_override("font_color", C_TEXT_M)
	hdr.add_theme_font_size_override("font_size", 8)
	box.add_child(hdr)
	box.add_child(spin)
	return box


## Compact astro readout label (sunrise / moon / sunset). Centred, mouse-pass
## so the tooltip shows without stealing scrub input.
func _mk_astro_label(txt: String, color: Color, tip: String) -> Label:
	var lbl := Label.new()
	lbl.text = txt
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.tooltip_text = tip
	lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	lbl.add_theme_color_override("font_color", color)
	lbl.add_theme_font_size_override("font_size", 10)
	return lbl


## Pill-styled chip button (rounded, subtle fill) for the mode chip and other
## status toggles. Colours are overridden per-state by the caller / refresh.
func _on_needs_chip_pressed(_kind: String = "") -> void:
	var ui_layer := get_parent()
	if ui_layer == null:
		return
	var gv := ui_layer.get_node_or_null("SystemGraphView")
	if gv == null:
		return
	if not gv.visible and gv.has_method("toggle"):
		gv.call("toggle")
	elif not gv.visible:
		gv.visible = true
	if gv.has_method("_on_system_review"):
		gv.call("_on_system_review")


func _update_needs_strip() -> void:
	if _needs_chips.is_empty():
		return
	var ui_layer := get_parent()
	var gv: Node = ui_layer.get_node_or_null("SystemGraphView") if ui_layer != null else null
	var m: Dictionary = {}
	if gv != null and gv.has_method("compute_closure_metrics"):
		m = gv.call("compute_closure_metrics") as Dictionary
	var channels: Dictionary = m.get("channels", {}) as Dictionary
	# Colorblind-safe: icon + letter + status glyph (not hue alone).
	var icons := {"energy": "⚡", "water": "💧", "food": "🍎", "waste": "♻"}
	var letters := {"energy": "E", "water": "W", "food": "F", "waste": "X"}
	var glyphs := {"ok": "●", "warn": "▲", "critical": "■", "idle": "○"}
	for kind: String in _needs_chips.keys():
		var btn: Button = _needs_chips[kind] as Button
		if btn == null:
			continue
		var ch: Dictionary = channels.get(kind, {}) as Dictionary
		var st: String = str(ch.get("status", "idle"))
		var icon: String = str(icons.get(kind, ""))
		var letter: String = str(letters.get(kind, kind.substr(0, 1).to_upper()))
		var glyph: String = str(glyphs.get(st, "○"))
		if st == "idle":
			btn.text = "%s %s %s" % [icon, letter, glyph]
			btn.tooltip_text = "%s — inactive (place a Habitat / tanks)" % kind.capitalize()
		else:
			var pct := float(ch.get("closure_pct", 0.0)) * 100.0
			btn.text = "%s %s%s" % [icon, letter, glyph]
			btn.tooltip_text = "%s: %s · closure %.0f%% · autonomy %.1f d — click Review" % [
					kind.capitalize(),
					_CLOSURE_METRICS_SCRIPT.status_label(st),
					pct,
					float(ch.get("autonomy_days", 0.0)),
			]
		var col: Color = _CLOSURE_METRICS_SCRIPT.status_color(st)
		btn.add_theme_color_override("font_color", col)
		var sb: StyleBox = btn.get_theme_stylebox("normal")
		if sb is StyleBoxFlat:
			var sbf := (sb as StyleBoxFlat).duplicate() as StyleBoxFlat
			sbf.border_color = col
			sbf.bg_color = Color(col.r, col.g, col.b, 0.22)
			sbf.set_border_width_all(2 if st == "critical" else 1)
			btn.add_theme_stylebox_override("normal", sbf)
	if _needs_score_lbl != null:
		var score: float = float(m.get("score", 0.0))
		_needs_score_lbl.text = ("%.0f" % score) if score > 0.01 else "—"
		_needs_score_lbl.add_theme_color_override("font_color",
				C_PRIMARY if score > 0.01 else C_TEXT_M)


func _mk_chip_btn(txt: String, callback: Callable, tip: String = "") -> Button:
	var btn := Button.new()
	btn.text         = txt
	btn.flat         = false
	btn.focus_mode   = Control.FOCUS_NONE
	btn.tooltip_text = tip
	btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	btn.add_theme_font_size_override("font_size", 10)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(C_PANEL.r, C_PANEL.g, C_PANEL.b, 0.85)
	sb.border_color = Color(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.9)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(11)
	sb.set_content_margin_all(4.0)
	sb.content_margin_left = 8.0
	sb.content_margin_right = 8.0
	var sb_h := sb.duplicate() as StyleBoxFlat
	sb_h.border_color = C_PRIMARY
	btn.add_theme_stylebox_override("normal", sb)
	btn.add_theme_stylebox_override("hover", sb_h)
	btn.add_theme_stylebox_override("pressed", sb_h)
	btn.add_theme_color_override("font_color", C_TEXT)
	btn.pressed.connect(callback)
	return btn


# ---------------------------------------------------------------------------
# Widget helpers
# ---------------------------------------------------------------------------

## ---------------------------------------------------------------------------
## Phase 1: Provenance tooltip setup + helpers
## ---------------------------------------------------------------------------

## Create the provenance tooltip panel and add it to the parent CanvasLayer
## (same pattern as _settings_panel) so it is not clipped by the bar.
func _setup_wx_tooltip() -> void:
	if _wx_tooltip_panel != null:
		return
	_wx_tooltip_panel = PanelContainer.new()
	_wx_tooltip_panel.visible = false
	_wx_tooltip_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_wx_tooltip_panel.custom_minimum_size = Vector2(230, 0)
	# Style to match the existing dark UI palette.
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(C_PANEL.r, C_PANEL.g, C_PANEL.b, 0.96)
	sb.border_color = C_BORDER
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(8.0)
	_wx_tooltip_panel.add_theme_stylebox_override("panel", sb)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 3)
	_wx_tooltip_panel.add_child(vbox)

	_tip_var_lbl  = _mk_tip_label(vbox, C_TEXT_M,    10)
	_tip_val_lbl  = _mk_tip_label(vbox, C_TEXT,      14)
	_tip_time_lbl = _mk_tip_label(vbox, C_TEXT_S,    10)
	_tip_src_lbl  = _mk_tip_label(vbox, C_PRIMARY,   10)
	_tip_stn_lbl  = _mk_tip_label(vbox, C_TEXT_M,    10)

	var ui_layer := get_parent()
	if ui_layer != null:
		ui_layer.add_child(_wx_tooltip_panel)
	else:
		add_child(_wx_tooltip_panel)


func _mk_tip_label(parent: Control, color: Color, font_size: int) -> Label:
	var lbl := Label.new()
	lbl.add_theme_color_override("font_color", color)
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(lbl)
	return lbl


## Connect weather service signals to trigger track and record-book redraws.
func _connect_weather_signals() -> void:
	var alert_svc := get_node_or_null("/root/NwsAlertService")
	if alert_svc != null and alert_svc.has_signal("alerts_ready"):
		# Use lambdas to discard extra signal arguments.
		alert_svc.connect("alerts_ready", func(_ugc: String): _on_weather_layer_ready())
	if WeatherService.has_signal("records_ready"):
		WeatherService.connect("records_ready", func(_lat: float, _lon: float): _on_weather_layer_ready())
	var gistemp := get_node_or_null("/root/GistempService")
	if gistemp != null and gistemp.has_signal("gistemp_ready"):
		gistemp.connect("gistemp_ready", func(): _on_record_layer_ready())


func _on_record_layer_ready() -> void:
	if _record_book_panel != null and _record_book_panel.has_method("refresh_chart"):
		_record_book_panel.refresh_chart()


func _on_weather_layer_ready() -> void:
	if _track != null:
		_track.queue_redraw()


## Show an NWS alert tooltip when the mouse is over an alert band on the track.
## Alert bands are drawn at y ≈ 5–21 (groove_y=13, band_top=7, band_h=12).
func _update_track_alert_tooltip(mouse_pos: Vector2) -> void:
	if _wx_tooltip_panel == null or _track == null:
		return
	# Hide during drag or selection to avoid interfering with those operations.
	if _track_dragging or _selecting:
		_wx_tooltip_panel.visible = false
		return
	# Only trigger in the alert-band vertical range.
	if mouse_pos.y < 0.0 or mouse_pos.y > 24.0:
		_wx_tooltip_panel.visible = false
		return
	var abs_t := _x_to_abs(mouse_pos.x)
	var alert_svc := get_node_or_null("/root/NwsAlertService")
	if alert_svc == null or not alert_svc.has_method("get_alerts_in_range"):
		_wx_tooltip_panel.visible = false
		return
	var nearby: Array = alert_svc.call("get_alerts_in_range", abs_t - 0.25, abs_t + 0.25)
	if nearby.is_empty():
		_wx_tooltip_panel.visible = false
		return
	# Sort by severity: warning first, then watch, then advisory.
	var sev_order := {"warning": 0, "watch": 1, "advisory": 2}
	nearby.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return sev_order.get(a.get("category", "advisory"), 2) \
			< sev_order.get(b.get("category", "advisory"), 2))
	var alert: Dictionary = nearby[0]
	var event_name := str(alert.get("event", "Unknown Alert"))
	var category   := str(alert.get("category", "advisory"))
	var onset_abs  := float(alert.get("onset_abs",   NAN))
	var expire_abs := float(alert.get("expires_abs", NAN))
	var time_str := ""
	if not is_nan(onset_abs) and not is_nan(expire_abs):
		time_str = "%s – %s" % [_short_date_for_abs(onset_abs), _short_date_for_abs(expire_abs)]
	var cat_color: Color
	match category:
		"warning": cat_color = Color(1.0, 0.35, 0.35)
		"watch":   cat_color = Color(1.0, 0.65, 0.15)
		_:         cat_color = Color(1.0, 0.95, 0.30)
	_tip_var_lbl.text = "NWS ALERT"
	_tip_val_lbl.add_theme_color_override("font_color", cat_color)
	_tip_val_lbl.text = event_name
	_tip_time_lbl.text = time_str
	_tip_src_lbl.text  = "National Weather Service Watch/Warning/Advisory"
	_tip_stn_lbl.text  = ("+%d more alert%s at this time" % [nearby.size() - 1, "s" if nearby.size() > 2 else ""]) \
		if nearby.size() > 1 else ""
	_wx_tooltip_panel.visible = true
	_wx_tooltip_panel.reset_size()
	var panel_sz := _wx_tooltip_panel.get_combined_minimum_size()
	var track_rect := _track.get_global_rect()
	var vp_sz := get_viewport().get_visible_rect().size
	var gx := track_rect.position.x + mouse_pos.x
	var gy := track_rect.position.y
	var px := clampf(gx, 4.0, vp_sz.x - panel_sz.x - 4.0)
	var py := clampf(gy - panel_sz.y - 6.0, 4.0, vp_sz.y - panel_sz.y - 4.0)
	_wx_tooltip_panel.position = Vector2(px, py)


## ---------------------------------------------------------------------------
## Phase 4: Temperature record helpers
## ---------------------------------------------------------------------------

## Converts absolute hours to (month, day) using the same calendar arithmetic
## as _short_date_for_abs(). Returns Vector2i(-1, -1) on failure.
func _month_day_for_abs(abs_hours: float) -> Vector2i:
	var clk : CelestialClock = _track_clock()
	if clk == null:
		return Vector2i(-1, -1)
	var dd: Dictionary = clk.abs_hours_to_date(abs_hours)
	if dd.is_empty():
		return Vector2i(-1, -1)
	return Vector2i(int(dd.get("month", 1)), int(dd.get("day", 1)))


func _mk_play_btn() -> Button:
	var btn := Button.new()
	btn.text       = "⏸"
	btn.flat       = false
	btn.focus_mode = Control.FOCUS_NONE
	btn.custom_minimum_size = Vector2(42, 42)
	var sb_n := StyleBoxFlat.new()
	sb_n.bg_color   = Color(C_PRIMARY.r * 0.22, C_PRIMARY.g * 0.22, C_PRIMARY.b * 0.22, 1.0)
	sb_n.border_color = Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.90)
	sb_n.set_border_width_all(2)
	sb_n.set_corner_radius_all(21)
	var sb_h := sb_n.duplicate() as StyleBoxFlat
	sb_h.bg_color = Color(C_PRIMARY.r * 0.38, C_PRIMARY.g * 0.38, C_PRIMARY.b * 0.38, 1.0)
	sb_h.border_color = C_PRIMARY
	btn.add_theme_stylebox_override("normal",  sb_n)
	btn.add_theme_stylebox_override("hover",   sb_h)
	btn.add_theme_stylebox_override("pressed", sb_h)
	btn.add_theme_color_override("font_color", Color(C_PRIMARY.r * 1.6, C_PRIMARY.g * 1.6, C_PRIMARY.b * 1.6, 1.0).clamp())
	btn.add_theme_font_size_override("font_size", 24)
	btn.tooltip_text = "Play / Pause  (Space  |  controller: D-pad Left to slow/pause/reverse)"
	btn.pressed.connect(_on_play_pressed)
	return btn


func _mk_transport_btn(txt: String, callback: Callable, tip: String) -> Button:
	var btn := Button.new()
	btn.text = txt
	btn.flat = false
	btn.focus_mode = Control.FOCUS_NONE
	btn.tooltip_text = tip
	btn.custom_minimum_size = Vector2(36, 36)
	var sb_n := StyleBoxFlat.new()
	sb_n.bg_color = Color(C_TEXT_M.r * 0.25, C_TEXT_M.g * 0.25, C_TEXT_M.b * 0.25, 0.85)
	sb_n.border_color = Color(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.75)
	sb_n.set_border_width_all(1)
	sb_n.set_corner_radius_all(18)
	var sb_h := sb_n.duplicate() as StyleBoxFlat
	sb_h.bg_color = Color(C_PRIMARY.r * 0.20, C_PRIMARY.g * 0.20, C_PRIMARY.b * 0.20, 1.0)
	sb_h.border_color = Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.65)
	var sb_p := sb_h.duplicate() as StyleBoxFlat
	sb_p.bg_color = Color(C_AMBER.r * 0.22, C_AMBER.g * 0.22, C_AMBER.b * 0.22, 1.0)
	sb_p.border_color = C_AMBER
	btn.add_theme_stylebox_override("normal", sb_n)
	btn.add_theme_stylebox_override("hover", sb_h)
	btn.add_theme_stylebox_override("pressed", sb_p)
	btn.add_theme_color_override("font_color", C_TEXT_S)
	btn.add_theme_color_override("font_hover_color", C_PRIMARY)
	btn.add_theme_color_override("font_pressed_color", C_AMBER)
	btn.add_theme_font_size_override("font_size", 13)
	btn.pressed.connect(callback)
	return btn


func _mk_flat_btn(txt: String, callback: Callable, tip: String = "") -> Button:
	var btn := Button.new()
	btn.text         = txt
	btn.flat         = true
	btn.focus_mode   = Control.FOCUS_NONE
	btn.tooltip_text = tip
	btn.custom_minimum_size = Vector2(32, 32)
	btn.add_theme_color_override("font_color",         C_TEXT_S)
	btn.add_theme_color_override("font_hover_color",   C_PRIMARY)
	btn.add_theme_color_override("font_pressed_color", C_AMBER)
	btn.add_theme_font_size_override("font_size", 13)
	btn.pressed.connect(callback)
	return btn


func _mk_icon_btn(txt: String, callback: Callable, tip: String = "") -> Button:
	var btn := _mk_flat_btn(txt, callback, tip)
	btn.flat = false
	btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	btn.custom_minimum_size = Vector2(38, 38)
	btn.add_theme_font_size_override("font_size", 18)
	# Subtle rounded hover/pressed fill so the icon row reads as a button group.
	var sb_n := StyleBoxFlat.new()
	sb_n.bg_color = Color(0, 0, 0, 0)
	sb_n.set_corner_radius_all(8)
	sb_n.set_content_margin_all(4.0)
	var sb_h := sb_n.duplicate() as StyleBoxFlat
	sb_h.bg_color = Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.14)
	sb_h.border_color = Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.45)
	sb_h.set_border_width_all(1)
	var sb_p := sb_h.duplicate() as StyleBoxFlat
	sb_p.bg_color = Color(C_AMBER.r, C_AMBER.g, C_AMBER.b, 0.18)
	sb_p.border_color = Color(C_AMBER.r, C_AMBER.g, C_AMBER.b, 0.55)
	btn.add_theme_stylebox_override("normal", sb_n)
	btn.add_theme_stylebox_override("hover", sb_h)
	btn.add_theme_stylebox_override("pressed", sb_p)
	# A DISABLED icon button must look disabled: these are colour emoji, which
	# ignore the font colour, so the whole button dims (the 📈 Render button sat
	# disabled-but-identical for every player without a CSV clip loaded, which
	# read as "the button does nothing").
	btn.add_theme_stylebox_override("disabled", sb_n)
	btn.add_theme_color_override("font_disabled_color", Color(C_TEXT_M.r, C_TEXT_M.g, C_TEXT_M.b, 0.6))
	return btn


## Keep an icon button's dimming in step with its `disabled` flag.
func _dim_disabled(btn: Button) -> void:
	if btn == null:
		return
	btn.modulate.a = 0.38 if btn.disabled else 1.0


func _mk_ctrl_btn(txt: String, callback: Callable) -> Button:
	return _mk_flat_btn(txt, callback)


func _mk_vsep() -> Control:
	var sep := ColorRect.new()
	sep.color               = Color(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.45)
	sep.custom_minimum_size = Vector2(1, 28)
	sep.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return _mk_margin(sep, 0, 8)


func _mk_margin(child: Control, h_pad: int, v_pad: int) -> MarginContainer:
	var mc := MarginContainer.new()
	mc.add_theme_constant_override("margin_left",   h_pad)
	mc.add_theme_constant_override("margin_right",  h_pad)
	mc.add_theme_constant_override("margin_top",    v_pad)
	mc.add_theme_constant_override("margin_bottom", v_pad)
	mc.add_child(child)
	return mc
