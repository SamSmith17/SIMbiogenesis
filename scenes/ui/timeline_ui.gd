@tool
class_name TimelineUI
extends Control

## Thin bottom-bar timeline UI.
## Displays: 24h day scrubber, playback controls, time, date, moon phase,
## sunrise/sunset, speed preset, and save/load button.
## Spacebar toggles sim pause; when paused the cursor is released for interaction.
## @tool makes _build_bar() run in the editor so the layout is visible in the 2D editor.

# ---------------------------------------------------------------------------
# Palette  (mirrors system_graph_view.gd / solar_ui)
# ---------------------------------------------------------------------------
const C_BG       := Color(0.039, 0.055, 0.098, 0.97)
const C_PANEL    := Color(0.082, 0.114, 0.208, 1.0)
const C_BORDER   := Color(0.227, 0.290, 0.420, 1.0)
const C_PRIMARY  := Color(0.133, 0.827, 0.933, 1.0)
const C_AMBER    := Color(0.961, 0.620, 0.043, 1.0)
const C_GOLD     := Color(1.000, 0.816, 0.310, 1.0)
const C_LAVENDER := Color(0.686, 0.600, 1.000, 1.0)
const C_GREEN    := Color(0.149, 0.902, 0.467, 1.0)
const C_TEXT     := Color(0.886, 0.910, 0.941, 1.0)
const C_TEXT_S   := Color(0.580, 0.639, 0.722, 1.0)
const C_TEXT_M   := Color(0.392, 0.447, 0.545, 1.0)

# NLE track (variable) + clip-controls (22) + main info row + padding.
# INFO_ROW_HEIGHT must comfortably fit the tallest cluster (the two-line
# weather block: chip row + stat-tile row) or the value labels get clipped.
const INFO_ROW_HEIGHT : int = 78
const NLE_ROW_HEIGHT : int = 22
const BAR_CHROME_HEIGHT : int = INFO_ROW_HEIGHT + NLE_ROW_HEIGHT + 10
## Gap between the bar bottom edge and the viewport (external padding).
const BAR_BOTTOM_PAD : int = 10
## Extra breathing room inside the info row above the bar bottom.
const INFO_ROW_BOTTOM_PAD : int = 4
## Legacy alias — minimum scrubber height before waveform tracks.
const TRACK_ROW_HEIGHT : int = 54
const NWS_ALERT_SERVICE_SCRIPT := preload("res://core/nws_alert_service.gd")
const TimelineViewScript := preload("res://core/timeline/timeline_view.gd")
const TimelineTrackLayoutScript := preload("res://core/timeline/timeline_track_layout.gd")
const TimelineTrackDefScript := preload("res://core/timeline/timeline_track_def.gd")
const TimelineWaveformDrawScript := preload("res://core/timeline/timeline_waveform_draw.gd")

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
]

const MOON_EMOJIS  : Array = ["🌑","🌒","🌓","🌔","🌕","🌖","🌗","🌘"]
const MONTH_NAMES  : Array = ["Jan","Feb","Mar","Apr","May","Jun",
							   "Jul","Aug","Sep","Oct","Nov","Dec"]

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
var _main         : Node  = null
var _player       : Node  = null
var _is_playing   : bool  = true
var _speed_idx    : int   = 2        # default 60×
var _stored_scale : float = 0.016667
## True while the sim is paused by THIS bar (spacebar). Used externally by time_ui.
var _sim_paused_by_bar : bool = false

var _update_accum : float = 0.0
var _ready_done   : bool  = false

const UPDATE_INTERVAL := 0.1

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
const SEL_FILL       := Color(1.0, 1.0, 1.0, 0.09)        # selection span
const SEL_EDGE       := Color(1.0, 1.0, 1.0, 0.55)
# NLE control buttons (built in _build_nle_row).
var _import_btn        : Button = null
var _linkagelab_btn    : Button = null
var _render_btn        : Button = null
var _loadmode_btn      : Button = null
var _compare_btn       : Button = null
var _load_video_btn    : Button = null
var _live_feed_btn     : Button = null
var _snap_video_btn    : Button = null
var _render_progress_lbl : Label = null
var _import_dialog     : FileDialog = null
var _linkagelab_dialog : FileDialog = null

const BUNDLE_IMPORTER_SCRIPT := preload("res://core/linkagelab/bundle_importer.gd")
## Selection drag state (shift-drag on the track sets the render in/out range).
var _selecting         : bool = false
var _sel_anchor_abs    : float = NAN
## True once SolarUI's compare signals are connected (lazy, once).
var _solar_signals_connected : bool = false
var _sunrise_lbl  : Label
var _sunset_lbl   : Label
var _moon_lbl     : Label
var _play_btn     : Button
var _speed_lbl    : Label
# Info-row clusters (manually centred: weather left · transport/time/date centre
# · icon buttons right). Parent is a plain Control so we position them ourselves.
var _info_row       : Control = null
var _left_cluster   : Control = null
var _center_time_cluster : Control = null
var _center_transport_cluster : Control = null
var _center_speed_cluster : Control = null
var _right_cluster  : Control = null
const INFO_ROW_EDGE_PAD : float = 8.0
const CENTER_CLUSTER_GAP : float = 18.0
var _scrubber_updating : bool = false   # prevents feedback loop

# Weather row (driven by SolarUI)
var _wx_status_lbl: Label  # kept for API compatibility; not rendered
var _wx_source_lbl:  Label   # automatic weather-source indicator (no manual picker)
var _wx_link_btn:     Button
var _unit_toggle_btn: Button
# Individual stat tile value labels (updated via set_weather_stats).
var _wx_rad_lbl:    Label
var _wx_temp_lbl:   Label
var _wx_hum_lbl:    Label
var _wx_wind_lbl:   Label
var _wx_dir_lbl:    Label
var _wx_rain_lbl:   Label
var _wx_rain24_lbl: Label
## True = show °F / mph / inches; false = show °C / m/s / mm.
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

# Provenance tooltip panel (Phase 1) — sibling on the parent CanvasLayer.
var _wx_tooltip_panel: PanelContainer = null
var _tip_var_lbl:  Label = null
var _tip_val_lbl:  Label = null
var _tip_time_lbl: Label = null
var _tip_src_lbl:  Label = null
var _tip_stn_lbl:  Label = null
# Hoverable stat tile containers (parallel to _wx_*_lbl refs).
var _wx_tile_containers: Array[Control] = []
var _wx_tile_keys: Array[String] = []


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	_track_layout.reset_defaults()
	_build_bar()
	if Engine.is_editor_hint():
		return   # editor preview only — skip runtime setup
	_load_ui_prefs()

	_map_confirm = ConfirmationDialog.new()
	_map_confirm.dialog_text = "Autosave and return to map selection?\n\nThe current session is written to autosave first."
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
	_setup_wx_tooltip()
	_connect_weather_signals()
	if is_instance_valid(CursorController):
		CursorController.set_paused(false)


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
	if ts <= 0.0:
		# Paused or reversed — resume forward at stored speed
		var resume := _stored_scale if _stored_scale > 1e-6 else float(SPEED_STEPS[_speed_idx][1])
		_main.set("time_scale", resume)
		_sim_paused_by_bar = false
		CursorController.set_paused(false)
	else:
		_on_faster_pressed()
	_update_display()


## D-pad left: slow down → pause → reverse
func _on_dpad_left() -> void:
	if _main == null or not is_instance_valid(_main):
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
		# Already reversing — speed up the reverse (more negative)
		_speed_idx = min(_speed_idx + 1, SPEED_STEPS.size() - 1)
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


func set_weather_cycle_display(caption: String, mod: Color, tip: String) -> void:
	if _wx_source_lbl:
		_wx_source_lbl.text = caption
		_wx_source_lbl.add_theme_color_override("font_color", mod)
		_wx_source_lbl.tooltip_text = tip


func set_weather_link_display(tip: String, mod: Color) -> void:
	if _wx_link_btn:
		_wx_link_btn.tooltip_text = tip
		_wx_link_btn.add_theme_color_override("font_color", mod)


## Update the prominent weather stat tiles. All inputs are SI units
## (°C, m/s, mm/h, mm); conversion to imperial is done here based on
## _use_imperial. Pass NAN for any unavailable value.
func set_weather_stats(rad: float, temp_c: float, hum: float,
		wind_ms: float, wind_deg: float, rain_mmh: float, rain_24h_mm: float) -> void:
	if _wx_rad_lbl:
		_wx_rad_lbl.text = "—" if is_nan(rad) else "%.0f" % rad
	if _wx_temp_lbl:
		if is_nan(temp_c):
			_wx_temp_lbl.text = "—"
		elif _use_imperial:
			_wx_temp_lbl.text = "%.0f°F" % (temp_c * 9.0 / 5.0 + 32.0)
		else:
			_wx_temp_lbl.text = "%.0f°C" % temp_c
	if _wx_hum_lbl:
		_wx_hum_lbl.text = "—" if is_nan(hum) else "%.0f%%" % hum
	if _wx_wind_lbl:
		if is_nan(wind_ms):
			_wx_wind_lbl.text = "—"
		elif _use_imperial:
			_wx_wind_lbl.text = "%.0fmph" % (wind_ms * 2.23694)
		else:
			_wx_wind_lbl.text = "%.1fm/s" % wind_ms
	if _wx_dir_lbl:
		_wx_dir_lbl.text = "—" if is_nan(wind_deg) else _deg_to_compass(wind_deg)
	if _wx_rain_lbl:
		if is_nan(rain_mmh) or rain_mmh < 0.05:
			_wx_rain_lbl.text = "dry"
		elif _use_imperial:
			_wx_rain_lbl.text = '%.2f"' % (rain_mmh / 25.4)
		else:
			_wx_rain_lbl.text = "%.1fmm" % rain_mmh
	if _wx_rain24_lbl:
		if is_nan(rain_24h_mm):
			_wx_rain24_lbl.text = "—"
		elif _use_imperial:
			_wx_rain24_lbl.text = '%.2f"' % (rain_24h_mm / 25.4)
		else:
			_wx_rain24_lbl.text = "%.1fmm" % rain_24h_mm


static func _deg_to_compass(deg: float) -> String:
	var dirs := ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
	return dirs[int(round(deg / 45.0)) % 8]


func _on_unit_toggle_pressed() -> void:
	_use_imperial = not _use_imperial
	if _unit_toggle_btn:
		_unit_toggle_btn.text = "°F" if _use_imperial else "°C"
	_save_ui_prefs()


func _load_ui_prefs() -> void:
	var cfg := ConfigFile.new()
	if cfg.load("user://ui_prefs.cfg") == OK:
		_use_imperial = cfg.get_value("units", "imperial", true)
		_track_view.set_span(float(cfg.get_value("timeline", "view_span_hours", TimelineViewScript.DEFAULT_SPAN_HOURS)))
		var raw_tracks : Variant = cfg.get_value("timeline", "tracks", [])
		if raw_tracks is Array and not (raw_tracks as Array).is_empty():
			_track_layout.load_from_array(raw_tracks as Array)
	if _unit_toggle_btn:
		_unit_toggle_btn.text = "°F" if _use_imperial else "°C"
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


func _setup_tracks_menu() -> void:
	if _tracks_menu != null:
		return
	_tracks_menu = PopupMenu.new()
	_tracks_menu.name = "TracksMenu"
	add_child(_tracks_menu)
	_tracks_menu.id_pressed.connect(_on_tracks_menu_id_pressed)
	_rebuild_tracks_menu()


func _rebuild_tracks_menu() -> void:
	if _tracks_menu == null:
		return
	_tracks_menu.clear()
	var idx := 0
	for t_v in _track_layout.tracks:
		if not (t_v is TimelineTrackDef):
			continue
		var td : TimelineTrackDef = t_v as TimelineTrackDef
		if td.kind == TimelineTrackDef.KIND_CLIPS:
			continue
		var label := td.label
		if td.enabled:
			label = "✓ " + label
		else:
			label = "   " + label
		_tracks_menu.add_item("%s  (%s)" % [label, td.source], idx)
		_tracks_menu.set_item_metadata(idx, td.id)
		idx += 1
	if idx > 0:
		_tracks_menu.add_separator()
	var add_base := 1000
	var add_i := 0
	for ch in TimelineTrackDef.channel_catalog():
		var cid := str(ch.get("id", ""))
		for src in ch.get("sources", []):
			_tracks_menu.add_item("＋ %s (%s)" % [str(ch.get("label", cid)), src], add_base + add_i)
			_tracks_menu.set_item_metadata(add_base + add_i, {"add": cid, "source": str(src)})
			add_i += 1


func _on_tracks_pressed() -> void:
	_rebuild_tracks_menu()
	if _tracks_menu == null or _tracks_btn == null:
		return
	var pos := _tracks_btn.global_position + Vector2(0.0, _tracks_btn.size.y)
	_tracks_menu.position = pos
	_tracks_menu.popup()


func _on_tracks_menu_id_pressed(id : int) -> void:
	if _tracks_menu == null:
		return
	var meta : Variant = _tracks_menu.get_item_metadata(id)
	if meta is Dictionary and meta.has("add"):
		var d : Dictionary = meta as Dictionary
		_track_layout.add_waveform_track(str(d.get("add", "")), str(d.get("source", "live")))
		_save_track_layout_prefs()
	elif meta is String:
		var track : TimelineTrackDef = _track_layout.find_track(str(meta))
		if track != null:
			track.enabled = not track.enabled
			_save_track_layout_prefs()
	_sync_scrubber_row_height()
	_request_bar_layout()
	if _track != null:
		_track.queue_redraw()


func _on_weather_link_pressed() -> void:
	_ensure_solar_ref()
	if _solar_ui != null and _solar_ui.has_method("show_weather_link_menu_for_anchor"):
		_solar_ui.show_weather_link_menu_for_anchor(_wx_link_btn)


func _ensure_solar_ref() -> void:
	if is_instance_valid(_solar_ui):
		return
	var p := get_parent()
	if p != null:
		_solar_ui = p.get_node_or_null("SolarUI")


func _update_display() -> void:
	if not is_instance_valid(_main):
		return
	_ensure_solar_ref()

	# ── Time scrubber (multi-day absolute track) ─────────────────────────────
	var dt : float = float(_main.get("day_time") if _main.get("day_time") != null else 0.0)
	if _track != null:
		_track.queue_redraw()
		_update_track_edge_labels()
	_update_mode_chips()
	_update_nle_controls()

	# ── Time label ───────────────────────────────────────────────────────────
	_time_lbl.text = _fmt_hour_full(dt)

	# ── Date spinboxes ─────────────────────────────────────────────────────
	_date_syncing = true
	var yr : int = int(_main.get("year")  if _main.get("year")  != null else 2025)
	var mo : int = int(_main.get("month") if _main.get("month") != null else 1)
	var dy : int = int(_main.get("day")   if _main.get("day")   != null else 1)
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
	_is_playing    = ts > 0.0
	_play_btn.text = "⏸" if _is_playing else ("◀" if ts < 0.0 else "▶")
	# Update the ring border and icon colour to signal play/pause state.
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
	if ts > 0.0:
		_stored_scale = maxf(ts, 1e-6)
		_main.set("time_scale", 0.0)
		_sim_paused_by_bar = true
		CursorController.set_paused(true)
	else:
		var resume := _stored_scale if _stored_scale > 1e-6 else float(SPEED_STEPS[_speed_idx][1])
		_main.set("time_scale", resume)
		_sim_paused_by_bar = false
		CursorController.set_paused(false)
	_update_display()


func _on_slower_pressed() -> void:
	_speed_idx = max(_speed_idx - 1, 0)
	_apply_speed()


func _on_faster_pressed() -> void:
	_speed_idx = min(_speed_idx + 1, SPEED_STEPS.size() - 1)
	_apply_speed()


func _apply_speed() -> void:
	var val := float(SPEED_STEPS[_speed_idx][1])
	_stored_scale = val
	if _is_playing and _main != null and is_instance_valid(_main):
		_main.set("time_scale", val)
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
	_track_view.apply_playhead_follow(_playhead_abs())


func _track_window() -> Vector2:
	_sync_track_view()
	return Vector2(_track_view.start, _track_view.span)


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
	_track_lbl_start.text = _track_view.format_edge_label(win.x, win.y, clk)
	_track_lbl_end.text = _track_view.format_edge_label(win.x + win.y, win.y, clk)
	var zoom_lbl : String = TimelineView.span_label(win.y)
	if _track != null:
		_track.tooltip_text = (
			"Drag: scrub  •  Ctrl-drag: render range  •  Wheel: zoom  •  Alt/MMB-drag: pan\n"
			+ "Drag track bottom edge to resize  •  Tracks button: add/hide channels\n"
			+ "White = NOW  •  View: %s  •  Alt+Right-click: re-center on playhead" % zoom_lbl
		)

## "Mon D" for an absolute-hours value (uses Unix epoch conversion for naming).
func _short_date_for_abs(abs_hours: float) -> String:
	# Absolute hours since year 1; convert to a date dict via day arithmetic.
	var total_days : int = int(floor(abs_hours / 24.0))
	# Reuse the engine's clock if available for an exact calendar mapping.
	if _main != null and _main.get("clock") != null:
		var clk = _main.get("clock")
		if clk.has_method("_year_from_abs_days") and clk.has_method("_days_before_year"):
			var y : int = clk._year_from_abs_days(total_days)
			var doy : int = total_days - clk._days_before_year(y) + 1
			var mo : int = 1
			var dd : int = doy
			var acc : int = 0
			for m in range(1, 13):
				var dim : int = clk.get_days_in_month(m, y)
				if acc + dim >= doy:
					mo = m
					dd = doy - acc
					break
				acc += dim
			return "%s %d" % [MONTH_NAMES[clamp(mo - 1, 0, 11)], dd]
	return ""

func _draw_track() -> void:
	if _track == null:
		return
	var w := _track.size.x
	var h := _track.size.y
	if w <= 1.0 or h <= 1.0:
		return
	var win := _track_window()
	var win_start := win.x
	var span := win.y
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
		while _d_pip * 24.0 <= win_start + span:
			var _md := _month_day_for_abs(_d_pip * 24.0)
			if _md.x > 0:
				var _rec: Dictionary = WeatherService.get_records(_md.x, _md.y)
				if not _rec.is_empty():
					var _sim_t: float = WeatherService.temperature_c(_md.x, _md.y, 12.0)
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

	# ── NLE lanes (clips + resizable sensor waveforms) ───────────────────────
	var lanes_top := TimelineTrackLayout.RULER_HEIGHT
	var lanes_bottom := lanes_top
	var s := null if Engine.is_editor_hint() else _get_solar()
	lanes_bottom = _draw_track_lanes(win_start, span, w, fnt, s, lanes_top)
	if s != null and s.has_method("get_selection_abs"):
		var sel : Vector2 = s.call("get_selection_abs")
		if not is_nan(sel.x) and sel.y > sel.x:
			var sx0 := clampf((sel.x - win_start) / span * w, 0.0, w)
			var sx1 := clampf((sel.y - win_start) / span * w, 0.0, w)
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
	var third := lane_h / 3.0
	_track.draw_rect(lane_rect, Color(LANE_OBS_BG.r, LANE_OBS_BG.g, LANE_OBS_BG.b, 0.35), true)
	_track.draw_string(fnt, Vector2(3.0, lane_y + third * 0.8), "OBS",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 7, Color(LANE_OBS_FILL.r, LANE_OBS_FILL.g, LANE_OBS_FILL.b, 0.75))
	_track.draw_string(fnt, Vector2(3.0, lane_y + third * 1.8), "SIM",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 7, Color(LANE_SIM_FILL.r, LANE_SIM_FILL.g, LANE_SIM_FILL.b, 0.75))
	_track.draw_string(fnt, Vector2(3.0, lane_y + third * 2.7), "VID",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 7, Color(LANE_VID_FILL.r, LANE_VID_FILL.g, LANE_VID_FILL.b, 0.75))
	if solar != null:
		if solar.has_method("get_observed_range_abs"):
			var orng : Vector2 = solar.call("get_observed_range_abs")
			if not is_nan(orng.x):
				_draw_clip(orng.x, orng.y, win_start, span, w, lane_y, third, LANE_OBS_FILL)
		if solar.has_method("get_rendered_range_abs"):
			var rrng : Vector2 = solar.call("get_rendered_range_abs")
			if not is_nan(rrng.x):
				_draw_clip(rrng.x, rrng.y, win_start, span, w,
					lane_y + third, third, LANE_SIM_FILL)
				if solar.has_method("is_rendering") and bool(solar.call("is_rendering")):
					var prog := clampf(float(solar.call("get_render_progress")), 0.0, 1.0)
					var fx0 := clampf((rrng.x - win_start) / span * w, 0.0, w)
					var fx1 := clampf((rrng.x + (rrng.y - rrng.x) * prog - win_start) / span * w, 0.0, w)
					if fx1 > fx0:
						_track.draw_rect(Rect2(fx0, lane_y + third, fx1 - fx0, third),
							Color(LANE_SIM_FILL.r, LANE_SIM_FILL.g, LANE_SIM_FILL.b, 0.9), true)
	var pc := _get_projection_canvas()
	if pc != null and pc.has_method("get_video_clip_range_abs"):
		var vrng : Vector2 = pc.call("get_video_clip_range_abs")
		if not is_nan(vrng.x):
			_draw_clip(vrng.x, vrng.y, win_start, span, w, lane_y + third * 2.0, third, LANE_VID_FILL)


func _draw_waveform_lane(td : TimelineTrackDef, lane_rect : Rect2, win_start : float, span : float,
		w : float, fnt : Font, solar : Node) -> void:
	var bg := Color(0.05, 0.07, 0.11, 0.55)
	TimelineWaveformDraw.draw_track_background(_track, lane_rect, bg, Color(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.35))
	TimelineWaveformDraw.draw_label(_track, lane_rect, td.label, td.color, fnt)
	if solar == null or not solar.has_method("get_timeline_waveform_bins"):
		return
	var bins : int = clampi(int(w), 64, 512)
	var samples : PackedFloat32Array = solar.call("get_timeline_waveform_bins",
		td.source, td.channel, win_start, win_start + span, bins)
	if samples.is_empty():
		return
	var cap := float(solar.call("get_timeline_capacity_kwh")) if solar.has_method("get_timeline_capacity_kwh") else 16.0
	var mode := td.aggregate_mode()
	if mode == "avg" or td.channel.begins_with("soc"):
		var v_max := TimelineWaveformDraw.vmax_for_bins(samples, td.channel, cap)
		TimelineWaveformDraw.draw_line_fill(_track, lane_rect, samples, 0.0, v_max, td.color)
	else:
		var v_max := TimelineWaveformDraw.vmax_for_bins(samples, td.channel, cap)
		TimelineWaveformDraw.draw_envelope(_track, lane_rect, samples, v_max, td.color)


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
				_track_dragging = false
				_selecting = false
		elif mb.button_index == MOUSE_BUTTON_MIDDLE:
			if mb.pressed:
				_track_panning = true
				_track_pan_anchor_x = mb.position.x
			else:
				_track_panning = false
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
		_data_chip.add_theme_color_override("font_color", dcol)


func _on_save_load_pressed() -> void:
	var ui_layer := get_parent()
	if ui_layer == null:
		return
	var sl := ui_layer.get_node_or_null("SaveLoadUI")
	if sl != null and sl.has_method("show_panel"):
		sl.show_panel()


func _on_map_select_pressed() -> void:
	if _map_confirm != null:
		_map_confirm.popup_centered()


func _on_map_select_confirmed() -> void:
	_release_mouse()
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
	var best      : int   = 0
	var best_dist : float = 1e9
	for i in SPEED_STEPS.size():
		var d := absf(scale - float(SPEED_STEPS[i][1]))
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
	_build_nle_row(vbox)
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


## NLE clip-controls strip: import datastream, render selection, load-mode
## toggle, compare toggle, and a render-progress readout.
func _build_nle_row(parent: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, NLE_ROW_HEIGHT)
	row.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	row.alignment = BoxContainer.ALIGNMENT_BEGIN
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)

	var lead := Control.new()
	lead.custom_minimum_size = Vector2(8, 0)
	row.add_child(lead)

	_import_btn = _mk_flat_btn("📂 Import datastream…", _on_import_pressed,
		"Load a Home Assistant CSV export as an observed comparison clip")
	_import_btn.add_theme_font_size_override("font_size", 11)
	row.add_child(_import_btn)

	_render_btn = _mk_flat_btn("⚙ Render selection", _on_render_pressed,
		"Batch-render a simulated datastream over the selected range")
	_render_btn.add_theme_font_size_override("font_size", 11)
	row.add_child(_render_btn)

	_loadmode_btn = _mk_flat_btn("Load: CSV", _on_loadmode_pressed,
		"Simulated-battery load source — CSV: feed observed load (isolates solar/weather error); Modeled: simulate load too")
	_loadmode_btn.add_theme_font_size_override("font_size", 11)
	row.add_child(_loadmode_btn)

	_compare_btn = _mk_flat_btn("⧉ Compare", _on_compare_pressed,
		"Split-screen observed vs simulated on the projection canvas (I)")
	_compare_btn.add_theme_font_size_override("font_size", 11)
	row.add_child(_compare_btn)

	_tracks_btn = _mk_flat_btn("Tracks", _on_tracks_pressed,
		"Show/hide sensor waveform tracks and add channels")
	_tracks_btn.add_theme_font_size_override("font_size", 11)
	row.add_child(_tracks_btn)
	_setup_tracks_menu()

	# Separator before video controls.
	var vid_sep := ColorRect.new()
	vid_sep.color = Color(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.35)
	vid_sep.custom_minimum_size = Vector2(1, 18)
	vid_sep.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_mk_margin(vid_sep, 4, 0))

	_load_video_btn = _mk_flat_btn("📹 Load video", _on_load_video_pressed,
		"Load a timelapse video file for the TR panel (auto-synced to timecode)")
	_load_video_btn.add_theme_font_size_override("font_size", 11)
	_load_video_btn.add_theme_color_override("font_color", C_GREEN)
	row.add_child(_load_video_btn)

	_live_feed_btn = _mk_flat_btn("📷 Live feed", _on_live_feed_pressed,
		"Select a live camera / OBS virtual camera feed for the TR panel")
	_live_feed_btn.add_theme_font_size_override("font_size", 11)
	_live_feed_btn.add_theme_color_override("font_color", C_GREEN)
	row.add_child(_live_feed_btn)

	_snap_video_btn = _mk_flat_btn("⏮ Snap video", _on_snap_video_pressed,
		"Align video frame 0 to the current playhead position (re-syncs the VID track)")
	_snap_video_btn.add_theme_font_size_override("font_size", 11)
	row.add_child(_snap_video_btn)

	_render_progress_lbl = Label.new()
	_render_progress_lbl.text = ""
	_render_progress_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_render_progress_lbl.add_theme_font_size_override("font_size", 10)
	_render_progress_lbl.add_theme_color_override("font_color", C_TEXT_S)
	row.add_child(_render_progress_lbl)


# ---------------------------------------------------------------------------
# NLE clip controls — handlers
# ---------------------------------------------------------------------------

func _get_solar() -> Node:
	_ensure_solar_ref()
	return _solar_ui


func _get_projection_canvas() -> Node:
	var p := get_parent()
	if p != null:
		var pc := p.get_node_or_null("ProjectionCanvas")
		if pc != null:
			return pc
	if get_tree() != null:
		return get_tree().root.find_child("ProjectionCanvas", true, false)
	return null


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


func _on_render_pressed() -> void:
	var s := _get_solar()
	if s != null and s.has_method("start_batch_render"):
		s.call("start_batch_render")
		_update_nle_controls()


func _on_loadmode_pressed() -> void:
	var s := _get_solar()
	if s == null or not s.has_method("get_render_load_mode"):
		return
	var m := int(s.call("get_render_load_mode"))
	s.call("set_render_load_mode", 0 if m == 1 else 1)   # toggle CSV(0) ↔ MODELED(1)
	_update_nle_controls()


func _on_compare_pressed() -> void:
	var s := _get_solar()
	if s == null or not s.has_method("set_compare_active"):
		return
	var on := false
	if s.has_method("is_compare_active"):
		on = bool(s.call("is_compare_active"))
	s.call("set_compare_active", not on)
	_update_nle_controls()


func _on_load_video_pressed() -> void:
	var pc := _get_projection_canvas()
	if pc != null and pc.has_method("open_load_video_dialog"):
		pc.call("open_load_video_dialog")


func _on_live_feed_pressed() -> void:
	var pc := _get_projection_canvas()
	if pc != null and pc.has_method("open_live_feed_dialog"):
		pc.call("open_live_feed_dialog")


func _on_snap_video_pressed() -> void:
	var pc := _get_projection_canvas()
	if pc != null and pc.has_method("set_video_start_abs_hours"):
		pc.call("set_video_start_abs_hours", _playhead_abs())
	if _track != null:
		_track.queue_redraw()


## Refresh the NLE control labels/enabled state from SolarUI.
func _update_nle_controls() -> void:
	var s := _get_solar()
	if s == null:
		return
	if not _solar_signals_connected:
		if s.has_signal("observed_clip_changed"):
			s.connect("observed_clip_changed", Callable(self, "_on_solar_clip_changed"))
		if s.has_signal("render_state_changed"):
			s.connect("render_state_changed", Callable(self, "_on_solar_clip_changed"))
		# Connect ProjectionCanvas video_clip_changed so the VID lane redraws.
		var pc := _get_projection_canvas()
		if pc != null and pc.has_signal("video_clip_changed"):
			pc.connect("video_clip_changed", Callable(self, "_on_solar_clip_changed"))
		_solar_signals_connected = true

	# Snap button enabled only when a video is loaded.
	if _snap_video_btn != null:
		var pc2 := _get_projection_canvas()
		var has_video := pc2 != null and pc2.has_method("get_video_clip_range_abs") and \
			not is_nan((pc2.call("get_video_clip_range_abs") as Vector2).x)
		_snap_video_btn.disabled = not has_video
	if _loadmode_btn != null and s.has_method("get_render_load_mode"):
		_loadmode_btn.text = "Load: CSV" if int(s.call("get_render_load_mode")) == 0 else "Load: Modeled"
	if _render_btn != null and s.has_method("has_observed_clip"):
		_render_btn.disabled = not bool(s.call("has_observed_clip"))
	if _compare_btn != null:
		var has_render := false
		if s.has_method("get_rendered_range_abs"):
			has_render = not is_nan((s.call("get_rendered_range_abs") as Vector2).x)
		_compare_btn.disabled = not has_render
		var on := s.has_method("is_compare_active") and bool(s.call("is_compare_active"))
		_compare_btn.add_theme_color_override("font_color", C_GREEN if on else C_TEXT)
	if _render_progress_lbl != null and s.has_method("get_render_progress"):
		if s.has_method("is_rendering") and bool(s.call("is_rendering")):
			_render_progress_lbl.text = "Rendering %d%%" % int(round(float(s.call("get_render_progress")) * 100.0))
		elif float(s.call("get_render_progress")) >= 1.0:
			_render_progress_lbl.text = "Rendered ✓"
		else:
			_render_progress_lbl.text = ""


func _on_solar_clip_changed() -> void:
	if _track != null:
		_track.queue_redraw()
	_update_nle_controls()


func _build_info_row(parent: VBoxContainer) -> void:
	# Plain Control host — Containers don't reposition plain-Control children,
	# so we can pin the three clusters independently: weather hugs the left
	# edge, icons hug the right edge, and the transport/time/date cluster sits
	# at the TRUE horizontal centre (not merely between the two side groups).
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
	_center_time_cluster = _build_center_time_cluster()
	_info_row.add_child(_center_time_cluster)
	_center_transport_cluster = _build_center_transport_cluster()
	_info_row.add_child(_center_transport_cluster)
	_center_speed_cluster = _build_center_speed_cluster()
	_info_row.add_child(_center_speed_cluster)
	_right_cluster = _build_right_cluster()
	_info_row.add_child(_right_cluster)

	call_deferred("_layout_info_clusters")


## Re-pin info-row clusters: weather → left, icons → right, transport → true
## centre, time+date → left of transport, speed → right of transport.
func _layout_info_clusters() -> void:
	if _info_row == null:
		return
	var row_w := _info_row.size.x
	var row_h := _info_row.size.y
	if row_w <= 1.0:
		return
	var usable_h := maxf(1.0, row_h - INFO_ROW_BOTTOM_PAD)
	for c: Control in [_left_cluster, _center_time_cluster, _center_transport_cluster,
			_center_speed_cluster, _right_cluster]:
		if c == null:
			continue
		var cs: Vector2 = c.get_combined_minimum_size()
		c.size = cs
		c.position.y = maxf(0.0, (usable_h - cs.y) * 0.5)
	if _left_cluster != null:
		_left_cluster.position.x = INFO_ROW_EDGE_PAD
	if _right_cluster != null:
		_right_cluster.position.x = row_w - _right_cluster.size.x - INFO_ROW_EDGE_PAD
	if _center_transport_cluster != null:
		_center_transport_cluster.position.x = (row_w - _center_transport_cluster.size.x) * 0.5
	if _center_time_cluster != null and _center_transport_cluster != null:
		var tx := _center_transport_cluster.position.x
		_center_time_cluster.position.x = maxf(
			INFO_ROW_EDGE_PAD,
			tx - CENTER_CLUSTER_GAP - _center_time_cluster.size.x)
	if _center_speed_cluster != null and _center_transport_cluster != null:
		var tx2 := _center_transport_cluster.position.x
		var tw := _center_transport_cluster.size.x
		_center_speed_cluster.position.x = minf(
			row_w - _center_speed_cluster.size.x - INFO_ROW_EDGE_PAD,
			tx2 + tw + CENTER_CLUSTER_GAP)


## LEFT — weather source/chips row stacked over the stat tiles, plus a compact
## astro column. Pinned to the left edge of the info row.
func _build_left_cluster() -> Control:
	var left := HBoxContainer.new()
	left.alignment             = BoxContainer.ALIGNMENT_BEGIN
	left.add_theme_constant_override("separation", 8)

	# Weather block — two stacked rows.
	var wx_box := VBoxContainer.new()
	wx_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	wx_box.add_theme_constant_override("separation", 4)

	# Row 1: source indicator + mode/data chips + unit + link.
	var wx_ctrl_row := HBoxContainer.new()
	wx_ctrl_row.alignment = BoxContainer.ALIGNMENT_BEGIN
	wx_ctrl_row.add_theme_constant_override("separation", 4)

	# Automatic weather-source indicator (no manual picker). Shows the weather
	# type + source glyph: 🌎 archive, 🌤 forecast, 📡 live HA, 🔄 synthetic.
	_wx_source_lbl = Label.new()
	_wx_source_lbl.text = "☀ —"
	_wx_source_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_wx_source_lbl.custom_minimum_size = Vector2(72, 0)
	_wx_source_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	_wx_source_lbl.tooltip_text = "Active weather source (hover a stat for details)"
	_wx_source_lbl.add_theme_font_size_override("font_size", 11)
	wx_ctrl_row.add_child(_wx_source_lbl)

	# Mode chip (LIVE / PLAYBACK / SIM) — click to pin/unpin the mode.
	_mode_chip = _mk_chip_btn("SIM", _on_mode_chip_pressed,
		"Simulation mode. Click to pin LIVE / SIM (Auto when unpinned).")
	_mode_chip.custom_minimum_size = Vector2(58, 22)
	wx_ctrl_row.add_child(_mode_chip)

	# Data-provenance chip (REAL / OBSERVED / PROJECTED / RECORDED at playhead).
	_data_chip = Label.new()
	_data_chip.text = ""
	_data_chip.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_data_chip.tooltip_text = "Data provenance at the playhead"
	_data_chip.add_theme_font_size_override("font_size", 10)
	_data_chip.add_theme_color_override("font_color", C_TEXT_S)
	_data_chip.custom_minimum_size = Vector2(74, 0)
	wx_ctrl_row.add_child(_data_chip)

	_unit_toggle_btn = _mk_flat_btn("°F", _on_unit_toggle_pressed,
		"Switch units: imperial (°F, mph, in) ↔ metric (°C, m/s, mm)")
	_unit_toggle_btn.add_theme_font_size_override("font_size", 11)
	_unit_toggle_btn.add_theme_color_override("font_color", C_AMBER)
	_unit_toggle_btn.custom_minimum_size = Vector2(30, 22)
	wx_ctrl_row.add_child(_unit_toggle_btn)

	_wx_link_btn = _mk_flat_btn("🔗", _on_weather_link_pressed,
		"Link this location's weather to a Home Assistant feed")
	_wx_link_btn.add_theme_font_size_override("font_size", 13)
	wx_ctrl_row.add_child(_wx_link_btn)

	wx_box.add_child(wx_ctrl_row)

	# Row 2: stat tiles — generic headers; values include unit suffix after conversion.
	var stat_row := HBoxContainer.new()
	stat_row.alignment = BoxContainer.ALIGNMENT_BEGIN
	stat_row.add_theme_constant_override("separation", 0)

	# Widths chosen for the longest value each tile can show.
	# W/m²: "1200"=4ch, TEMP: "100°F"=5ch, RH%: "100%"=4ch,
	# WIND: "13.8m/s"=7ch (widest), DIR: "NW"=2ch,
	# RAIN: "1.50\""=5ch, 24H: "2.50\""=5ch.
	_wx_rad_lbl    = _mk_hoverable_stat_tile("rad",    "W/m²", "—", C_GOLD,                       stat_row, 46)
	_mk_stat_vsep(stat_row)
	_wx_temp_lbl   = _mk_hoverable_stat_tile("temp",   "TEMP", "—", Color(1.00, 0.55, 0.30, 1.0), stat_row, 52)
	_mk_stat_vsep(stat_row)
	_wx_hum_lbl    = _mk_hoverable_stat_tile("hum",    "RH%",  "—", Color(0.40, 0.80, 1.00, 1.0), stat_row, 44)
	_mk_stat_vsep(stat_row)
	_wx_wind_lbl   = _mk_hoverable_stat_tile("wind",   "WIND", "—", C_GREEN,                      stat_row, 64)
	_mk_stat_vsep(stat_row)
	_wx_dir_lbl    = _mk_hoverable_stat_tile("dir",    "DIR",  "—", C_TEXT_S,                     stat_row, 36)
	_mk_stat_vsep(stat_row)
	_wx_rain_lbl   = _mk_hoverable_stat_tile("rain",   "RAIN", "—", C_PRIMARY,                    stat_row, 50)
	_mk_stat_vsep(stat_row)
	_wx_rain24_lbl = _mk_hoverable_stat_tile("rain24", "24H",  "—", C_LAVENDER,                   stat_row, 50)

	wx_box.add_child(stat_row)
	left.add_child(_mk_margin(wx_box, 8, 0))

	left.add_child(_mk_vsep())

	# Astro (sunrise / moon / sunset) — compact column next to the weather.
	var astro := VBoxContainer.new()
	astro.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	astro.alignment = BoxContainer.ALIGNMENT_CENTER
	astro.add_theme_constant_override("separation", 1)
	_sunrise_lbl = _mk_astro_label("🌅 6:00", C_GOLD, "Sunrise (local solar time)")
	astro.add_child(_sunrise_lbl)
	_moon_lbl = _mk_astro_label("🌕 Full", C_LAVENDER, "Moon phase")
	astro.add_child(_moon_lbl)
	_sunset_lbl = _mk_astro_label("🌇 7:00", C_GOLD, "Sunset (local solar time)")
	astro.add_child(_sunset_lbl)
	left.add_child(astro)

	return left


## Time + date (day · month · year) — sits left of the transport cluster.
func _build_center_time_cluster() -> Control:
	var tbox := VBoxContainer.new()
	tbox.alignment = BoxContainer.ALIGNMENT_CENTER
	tbox.add_theme_constant_override("separation", 2)

	_time_lbl = Label.new()
	_time_lbl.text = "12:00 PM"
	_time_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_time_lbl.tooltip_text = "Local time at the playhead. Drag the track above to scrub."
	_time_lbl.add_theme_color_override("font_color", C_PRIMARY)
	_time_lbl.add_theme_font_size_override("font_size", 22)
	tbox.add_child(_time_lbl)

	var date_row := HBoxContainer.new()
	date_row.alignment = BoxContainer.ALIGNMENT_BEGIN
	date_row.add_theme_constant_override("separation", 4)
	_year_input = _mk_date_spin(2000, 2100, 1.0, "Simulation year")
	_month_input = _mk_date_spin(1, 12, 1.0, "Month (1–12)")
	_day_input = _mk_date_spin(1, 31, 1.0, "Day of month")
	_year_input.value_changed.connect(_on_year_changed)
	_month_input.value_changed.connect(_on_month_changed)
	_day_input.value_changed.connect(_on_day_changed)
	date_row.add_child(_wrap_date_spin("D", _day_input))
	date_row.add_child(_wrap_date_spin("M", _month_input))
	date_row.add_child(_wrap_date_spin("Y", _year_input))
	tbox.add_child(date_row)

	return tbox


## Transport controls — pinned to the true horizontal centre of the bar.
func _build_center_transport_cluster() -> Control:
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_PASS
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(C_PANEL.r, C_PANEL.g, C_PANEL.b, 0.72)
	sb.border_color = Color(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.85)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(22)
	sb.set_content_margin_all(4.0)
	sb.content_margin_left = 10.0
	sb.content_margin_right = 10.0
	panel.add_theme_stylebox_override("panel", sb)

	var ctrl := HBoxContainer.new()
	ctrl.alignment = BoxContainer.ALIGNMENT_CENTER
	ctrl.add_theme_constant_override("separation", 10)

	var slow_btn := _mk_transport_btn("◀◀", _on_slower_pressed, "Slower  (D-pad Left on controller)")
	ctrl.add_child(slow_btn)

	_play_btn = _mk_play_btn()
	ctrl.add_child(_play_btn)

	var fast_btn := _mk_transport_btn("▶▶", _on_faster_pressed, "Faster  (D-pad Right on controller)")
	ctrl.add_child(fast_btn)

	panel.add_child(ctrl)
	return panel


## Speed readout — sits right of the transport cluster.
func _build_center_speed_cluster() -> Control:
	var spd_box := VBoxContainer.new()
	spd_box.alignment = BoxContainer.ALIGNMENT_CENTER
	spd_box.add_theme_constant_override("separation", 1)
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
	_speed_lbl.add_theme_font_size_override("font_size", 15)
	spd_box.add_child(_speed_lbl)

	return spd_box


## RIGHT — icon buttons (save / settings / import / records / map). Pinned to
## the right edge of the info row, mirroring the left cluster.
func _build_right_cluster() -> Control:
	var right := HBoxContainer.new()
	right.alignment             = BoxContainer.ALIGNMENT_END
	right.add_theme_constant_override("separation", 4)

	var sl_btn := _mk_icon_btn("💾", _on_save_load_pressed, "Save / Load  (manage save slots)")
	right.add_child(sl_btn)
	var gear_btn := _mk_icon_btn("⚙", _on_settings_pressed, "Settings — clouds, sun/moon, stars & planets, location")
	right.add_child(gear_btn)
	var csv_btn := _mk_icon_btn("📂", _on_csv_playback_pressed, "Import a datastream CSV as a timeline clip")
	right.add_child(csv_btn)
	_linkagelab_btn = _mk_icon_btn("🎮", _on_linkagelab_import_pressed,
		"Import a LinkageLab game bundle (.gamebundle.json) into this map")
	right.add_child(_linkagelab_btn)
	var record_btn := _mk_icon_btn("🌡", _on_record_book_pressed, "Climate Record Book — historical records & global trends for this location")
	right.add_child(record_btn)
	var map_btn := _mk_icon_btn("🗺", _on_map_select_pressed, "Return to map select")
	right.add_child(map_btn)

	return right


func _on_settings_pressed() -> void:
	if _settings_panel != null and _settings_panel.has_method("toggle"):
		_settings_panel.toggle()


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


func _on_year_changed(value: float) -> void:
	if _date_syncing or Engine.is_editor_hint():
		return
	if is_instance_valid(SimSettingsController):
		SimSettingsController.apply_year(int(value))
		_update_day_spin_max(int(_month_input.value), int(value))


func _on_month_changed(value: float) -> void:
	if _date_syncing or Engine.is_editor_hint():
		return
	if is_instance_valid(SimSettingsController):
		SimSettingsController.apply_month(int(value))
		_update_day_spin_max(int(value), int(_year_input.value))


func _on_day_changed(value: float) -> void:
	if _date_syncing or Engine.is_editor_hint():
		return
	if is_instance_valid(SimSettingsController):
		SimSettingsController.apply_day(int(value))


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

## Hoverable stat tile variant: same visual as _mk_stat_tile but enables mouse
## events so hovering the tile shows the provenance tooltip. Returns the value
## Label (same type as _mk_stat_tile) so existing assignments stay intact.
func _mk_hoverable_stat_tile(key: String, header: String, init_val: String,
		val_color: Color, parent: Control, min_w: int = 50) -> Label:
	var tile := VBoxContainer.new()
	tile.alignment = BoxContainer.ALIGNMENT_CENTER
	tile.add_theme_constant_override("separation", 1)
	tile.custom_minimum_size = Vector2(min_w, 0)
	tile.mouse_filter = Control.MOUSE_FILTER_STOP

	var hdr := Label.new()
	hdr.text                 = header
	hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hdr.add_theme_color_override("font_color", C_TEXT_M)
	hdr.add_theme_font_size_override("font_size", 9)
	hdr.mouse_filter = Control.MOUSE_FILTER_PASS
	tile.add_child(hdr)

	var val := Label.new()
	val.text                 = init_val
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	val.add_theme_color_override("font_color", val_color)
	val.add_theme_font_size_override("font_size", 13)
	val.mouse_filter = Control.MOUSE_FILTER_PASS
	tile.add_child(val)

	parent.add_child(tile)
	_wx_tile_containers.append(tile)
	_wx_tile_keys.append(key)
	tile.mouse_entered.connect(_on_stat_tile_entered.bind(key, tile))
	tile.mouse_exited.connect(_on_stat_tile_exited)
	return val


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


func _on_stat_tile_entered(key: String, container: Control) -> void:
	_show_wx_tooltip(key, container)


func _on_stat_tile_exited() -> void:
	if _wx_tooltip_panel != null:
		_wx_tooltip_panel.visible = false


func _show_wx_tooltip(key: String, anchor: Control) -> void:
	if _wx_tooltip_panel == null or _main == null:
		return
	var month := int(_main.get("month") if _main.get("month") != null else 1)
	var day   := int(_main.get("day")   if _main.get("day")   != null else 1)
	var hour  := float(_main.get("day_time") if _main.get("day_time") != null else 0.0)
	var year_v: Variant = _main.get("year")
	var sim_year := int(year_v) if year_v != null else 0

	# Detect HA-live mode from SolarUI.
	_ensure_solar_ref()
	var ha_active := false
	if _solar_ui != null:
		var wlm: Variant = _solar_ui.get("_weather_live_mode")
		ha_active = bool(wlm) if wlm != null else false

	# Data source.
	var source := WeatherService.get_sample_source(month, day, hour, ha_active)
	var src_str: String
	match source:
		"forecast":
			src_str = "Open-Meteo GFS Forecast  (GFS/ERA5 blend)"
		"ha":
			src_str = "Home Assistant"
		_:
			src_str = "Open-Meteo ERA5 Archive  (~25 km grid)"

	# Simulated date/time — read directly from Main.
	var mo_name: String = MONTH_NAMES[clampi(month - 1, 0, 11)]
	var h_int := int(hour)
	var m_int := int((hour - h_int) * 60.0)
	var time_str := "%s %d %d · %02d:%02d local" % [mo_name, day, sim_year, h_int, m_int]

	# Nearest NWS station from zone service.
	var lat := float(_main.get("latitude") if _main.get("latitude") != null else 0.0)
	var lon := float(_main.get("longitude") if _main.get("longitude") != null else 0.0)
	var stn_name := NwsZoneService.get_station_name(lat, lon)
	var stn_icao := NwsZoneService.get_station_icao(lat, lon)
	var stn_str: String
	if stn_name.is_empty():
		stn_str = "Nearest NWS station:  — (loading…)"
	else:
		stn_str = "Nearest NWS station:  %s  (%s)" % [stn_name, stn_icao]

	# Variable display name and formatted value.
	var var_names := {
		"rad":    "SOLAR RADIATION", "temp": "TEMPERATURE",
		"hum":    "HUMIDITY",        "wind": "WIND SPEED",
		"dir":    "WIND DIRECTION",  "rain": "RAINFALL RATE",
		"rain24": "24H RAINFALL",
	}
	_tip_var_lbl.text  = var_names.get(key, key.to_upper())
	_tip_val_lbl.add_theme_color_override("font_color", C_TEXT)
	_tip_val_lbl.text  = _wx_value_str_for_key(key, month, day, hour)
	_tip_time_lbl.text = time_str
	_tip_src_lbl.text  = src_str
	_tip_stn_lbl.text  = stn_str

	# Position above the anchor tile, clamped to viewport.
	_wx_tooltip_panel.visible = true
	_wx_tooltip_panel.reset_size()
	var panel_sz := _wx_tooltip_panel.get_combined_minimum_size()
	var anchor_rect := anchor.get_global_rect()
	var vp_sz := get_viewport().get_visible_rect().size
	var px := clampf(anchor_rect.position.x, 4.0, vp_sz.x - panel_sz.x - 4.0)
	var py := clampf(anchor_rect.position.y - panel_sz.y - 6.0, 4.0, vp_sz.y - panel_sz.y - 4.0)
	_wx_tooltip_panel.position = Vector2(px, py)


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


func _wx_value_str_for_key(key: String, month: int, day: int, hour: float) -> String:
	match key:
		"rad":
			var v := WeatherService.solar_radiation_wm2(month, day, hour)
			return "%.0f W/m²" % v if not is_nan(v) else "—"
		"temp":
			var v := WeatherService.temperature_c(month, day, hour)
			if is_nan(v): return "—"
			return "%.0f °F  (%.1f °C)" % [v * 9.0 / 5.0 + 32.0, v] if _use_imperial else "%.1f °C" % v
		"hum":
			var v := WeatherService.humidity_pct(month, day, hour)
			return "%.0f %%" % v if not is_nan(v) else "—"
		"wind":
			var v := WeatherService.wind_speed_ms(month, day, hour)
			if is_nan(v): return "—"
			return "%.0f mph  (%.1f m/s)" % [v * 2.23694, v] if _use_imperial else "%.1f m/s" % v
		"dir":
			var v := WeatherService.wind_direction_deg(month, day, hour)
			return _deg_to_compass(v) if not is_nan(v) else "—"
		"rain":
			var v := WeatherService.rain_rate_mmh(month, day, hour)
			if is_nan(v) or v < 0.05: return "dry"
			return '%.2f"/hr' % (v / 25.4) if _use_imperial else "%.1f mm/h" % v
		"rain24":
			var v := WeatherService.rain_24h_mm(month, day, hour)
			if is_nan(v): return "—"
			return '%.2f" (24h)' % (v / 25.4) if _use_imperial else "%.1f mm (24h)" % v
	return "—"


## ---------------------------------------------------------------------------
## Phase 4: Temperature record helpers
## ---------------------------------------------------------------------------

## Converts absolute hours to (month, day) using the same calendar arithmetic
## as _short_date_for_abs(). Returns Vector2i(-1, -1) on failure.
func _month_day_for_abs(abs_hours: float) -> Vector2i:
	var total_days := int(floor(abs_hours / 24.0))
	if _main == null:
		return Vector2i(-1, -1)
	var clk: Variant = _main.get("clock")
	if clk == null:
		return Vector2i(-1, -1)
	if not (clk.has_method("_year_from_abs_days") and clk.has_method("_days_before_year")):
		return Vector2i(-1, -1)
	var y: int = clk._year_from_abs_days(total_days)
	var doy: int = total_days - clk._days_before_year(y) + 1
	var mo := 1
	var dd := doy
	var acc := 0
	for m in range(1, 13):
		var dim: int = clk.get_days_in_month(m, y)
		if acc + dim >= doy:
			mo = m
			dd = doy - acc
			break
		acc += dim
	return Vector2i(mo, dd)


## Build a labelled stat tile (header + value), add it to parent, return the
## value Label so the caller can update it later. min_w sets the tile width;
## choose it large enough for the widest possible value string at font 16.
func _mk_stat_tile(header: String, init_val: String, val_color: Color,
		parent: Control, min_w: int = 50) -> Label:
	var tile := VBoxContainer.new()
	tile.alignment = BoxContainer.ALIGNMENT_CENTER
	tile.add_theme_constant_override("separation", 1)
	tile.custom_minimum_size = Vector2(min_w, 0)

	var hdr := Label.new()
	hdr.text                  = header
	hdr.horizontal_alignment  = HORIZONTAL_ALIGNMENT_CENTER
	hdr.add_theme_color_override("font_color",  C_TEXT_M)
	hdr.add_theme_font_size_override("font_size", 9)
	tile.add_child(hdr)

	var val := Label.new()
	val.text                 = init_val
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	val.add_theme_color_override("font_color", val_color)
	val.add_theme_font_size_override("font_size", 13)
	tile.add_child(val)

	parent.add_child(tile)
	return val


func _mk_stat_vsep(parent: Control) -> void:
	var sep := ColorRect.new()
	sep.color               = Color(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.30)
	sep.custom_minimum_size = Vector2(1, 18)
	sep.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	parent.add_child(_mk_margin(sep, 4, 0))


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
	return btn


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
