extends Control

## Record Book Modal — Climate History Explorer
##
## Opened from the 🌡 button in the timeline bar.  Displays a per-year horizontal
## bar chart from 1940 to the current year showing:
##   ▲ Red bars above baseline  — # of all-time temperature record-high days
##   ▼ Blue bars below baseline — # of all-time temperature record-low days
##   ◆ Cyan pip row             — # of precipitation record days
##   ● Orange dot row           — NWS alert count (scaled dot radius)
##   Column tint                — NASA GISTEMP global temperature anomaly
##
## All data is read from already-loaded caches; no fetch is triggered by this
## panel itself except for GISTEMP (which is small and cached annually).

# ---------------------------------------------------------------------------
# Palette — mirrors TimelineUI
# ---------------------------------------------------------------------------
const C_BG      := Color(0.039, 0.055, 0.098, 0.97)
const C_PANEL   := Color(0.082, 0.114, 0.208, 1.0)
const C_BORDER  := Color(0.227, 0.290, 0.420, 1.0)
const C_PRIMARY := Color(0.133, 0.827, 0.933, 1.0)
const C_AMBER   := Color(0.961, 0.620, 0.043, 1.0)
const C_TEXT    := Color(0.886, 0.910, 0.941, 1.0)
const C_TEXT_S  := Color(0.580, 0.639, 0.722, 1.0)
const C_TEXT_M  := Color(0.392, 0.447, 0.545, 1.0)
const C_RED     := Color(0.90,  0.20, 0.20, 1.0)
const C_BLUE    := Color(0.25,  0.45, 1.00, 1.0)
const C_CYAN    := Color(0.10,  0.88, 0.88, 1.0)
const C_ORANGE  := Color(1.00,  0.55, 0.10, 1.0)

# ---------------------------------------------------------------------------
# Chart layout
# ---------------------------------------------------------------------------
const CHART_START_YEAR  := 1940
const CHART_END_YEAR    := 2049   # last year with CMIP6 + chart data
const BAR_STRIDE        := 16   # 14 px bar + 2 px gap
const BAR_WIDTH         := 14
const CHART_MARGIN_LEFT := 44   # space for y-axis labels
const LABEL_TOP_H       := 20   # top year-label strip
const UPPER_CHART_H     := 160  # record-high bars grow upward from baseline
const BASELINE_Y        := 180  # = LABEL_TOP_H + UPPER_CHART_H
const LOWER_CHART_H     := 160  # record-low bars grow downward from baseline
const PIP_ROW_Y         := 348  # = BASELINE_Y + LOWER_CHART_H + 8 px gap
const PIP_ROW_H         := 18
const DOT_ROW_Y         := 370  # = PIP_ROW_Y + PIP_ROW_H + 4 px gap
const DOT_ROW_H         := 18
const BOT_LABEL_Y       := 392  # = DOT_ROW_Y + DOT_ROW_H + 4 px gap
const CHART_TOTAL_H     := 412  # canvas height

const MIN_BAR_PX        := 2.0  # floor so 1-record years are still visible
const MAX_DOT_RADIUS    := 7.0

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
var _timeline: Node = null
var _main_node: Node = null

var _backdrop: ColorRect = null
var _panel: PanelContainer = null
var _header_lbl: Label = null
var _chart_canvas: Control = null
var _scroll: ScrollContainer = null
var _detail_lbl: RichTextLabel = null
var _progress_lbl: Label = null
var _status_lbl: Label = null
var _compute_btn: Button = null
var _gen_seed_spin: SpinBox = null
var _gen_years_spin: SpinBox = null
var _gen_engine_opt: OptionButton = null
var _gen_weather_btn: Button = null
var _weather_gen_active: bool = false
var _weather_gen_waiting_training: bool = false
var _training_loaded_count: int = 0
var _training_total_count: int = 5
var _gen_training_model: bool = false
var _gen_progress_year: int = 0
var _gen_progress_month: int = 0

var _hovered_year_idx: int = -1
var _locked_year_idx:  int = -1
var _detail_locked:    bool = false
var _signals_connected: bool = false

## Projected record-breaking day counts keyed by future year int (through 2049).
## Built incrementally in _process so scrolling stays responsive.
var _proj_yearbook_cache:    Dictionary = {}
var _proj_yearbook_scenario: int        = -1
var _proj_cache_building:    bool       = false
var _proj_build_next_year:   int        = 0
var _proj_partial_year:      int        = -1
var _proj_build_month:       int        = 1
var _proj_build_highs:       int        = 0
var _proj_build_lows:        int        = 0
## Generated-weather yearbook (Phase 8): incremental month build after generation_complete.
var _gen_ybook_cache_building: bool     = false
var _gen_ybook_years_queue:    Array[int] = []
var _gen_ybook_partial_year:   int        = -1
var _gen_ybook_build_month:    int        = 1
var _gen_ybook_build_highs:    int        = 0
var _gen_ybook_build_lows:     int        = 0
var _gen_ybook_build_precip:   int        = 0
var _cached_yearbook:        Dictionary = {}
var _cached_max_alerts:      int        = 1
var _yearbook_cache_valid:   bool       = false
var _alerts_cache_valid:     bool       = false
var _redraw_scheduled:       bool       = false
var _pending_detail_idx:     int        = -1
var _detail_update_scheduled: bool      = false
var _is_scrolling:           bool       = false
var _scroll_debounce_gen:    int        = 0
var _detail_text_cache:      String     = ""


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

## Called by TimelineUI after instantiation.  Adds self to the parent CanvasLayer
## so the modal is not clipped by the timeline bar.
func bind_timeline(tl: Node) -> void:
	_timeline = tl
	_main_node = tl.get("_main")
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	set_process(false)
	_build_modal()
	var layer := tl.get_parent()
	if layer != null:
		layer.add_child(self)
	else:
		tl.add_child(self)
	_connect_signals()


func _connect_signals() -> void:
	if _signals_connected:
		return
	_signals_connected = true
	var gistemp := get_node_or_null("/root/GistempService")
	if gistemp != null and gistemp.has_signal("gistemp_ready"):
		gistemp.connect("gistemp_ready", func(): _redraw_chart())
	var alert_svc := get_node_or_null("/root/NwsAlertService")
	if alert_svc != null:
		if alert_svc.has_signal("all_hist_years_ready"):
			alert_svc.connect("all_hist_years_ready", func(_u: String):
				_invalidate_draw_cache()
				_redraw_chart())
	if WeatherService.has_signal("records_ready"):
		WeatherService.connect("records_ready", func(_la: float, _lo: float):
			_invalidate_draw_cache()
			_ensure_generated_yearbook_queue()
			_redraw_chart())
	var cps := get_node_or_null("/root/ClimateProjectionService")
	if cps != null:
		if cps.has_signal("projection_ready"):
			cps.connect("projection_ready", func(_la: float, _lo: float, _s: int):
				_invalidate_proj_cache())
		if cps.has_signal("scenario_changed"):
			cps.connect("scenario_changed", func(_s: int):
				_invalidate_proj_cache())
	if WeatherService.has_signal("generation_complete"):
		WeatherService.connect("generation_complete", func(years: Array):
			_weather_gen_active = false
			_weather_gen_waiting_training = false
			_gen_training_model = false
			_update_gen_weather_button()
			_update_progress()
			_start_generated_yearbook_build(years))
	if WeatherService.has_signal("generation_progress"):
		WeatherService.connect("generation_progress", func(yr: int, mo: int, _frac: float):
			_gen_progress_year = yr
			_gen_progress_month = mo
			_update_progress())
	if WeatherService.has_signal("training_archives_progress"):
		WeatherService.connect("training_archives_progress", func(loaded: int, total: int):
			_training_loaded_count = loaded
			_training_total_count = total
			if _gen_weather_btn != null and _weather_gen_waiting_training:
				_gen_weather_btn.text = "Loading training %d/%d…" % [loaded, total]
			_update_progress())
	if WeatherService.has_signal("generation_training_started"):
		WeatherService.connect("generation_training_started", func():
			_gen_training_model = true
			if _gen_weather_btn != null:
				_gen_weather_btn.text = "Training model…"
			_update_progress())
	if WeatherService.has_signal("training_fetch_failed"):
		WeatherService.connect("training_fetch_failed", func(reason: String):
			_weather_gen_waiting_training = false
			_weather_gen_active = false
			if _status_lbl != null:
				_status_lbl.text = "Training fetch failed: %s" % reason
			_update_gen_weather_button())


## Trigger a chart redraw (called externally by TimelineUI signal callbacks).
func refresh_chart() -> void:
	_redraw_chart()


func _redraw_chart() -> void:
	if _redraw_scheduled:
		return
	_redraw_scheduled = true
	call_deferred("_flush_redraw")


func _flush_redraw() -> void:
	_redraw_scheduled = false
	if _chart_canvas != null and is_instance_valid(_chart_canvas):
		_chart_canvas.queue_redraw()
	_update_progress()


func _invalidate_draw_cache() -> void:
	_yearbook_cache_valid = false
	_alerts_cache_valid = false


func _invalidate_proj_cache() -> void:
	_proj_yearbook_cache.clear()
	_proj_yearbook_scenario = -1
	_proj_cache_building = false
	_proj_build_next_year = 0
	_proj_partial_year = -1
	_proj_build_month = 1
	_proj_build_highs = 0
	_proj_build_lows = 0
	set_process(false)
	if visible:
		_redraw_chart()
		_update_compute_button_state()


func _start_proj_cache_build() -> void:
	var cps := get_node_or_null("/root/ClimateProjectionService")
	if cps == null or not bool(cps.call("has_projection")):
		_proj_cache_building = false
		set_process(false)
		return
	var scenario := int(cps.get("active_scenario"))
	var cur_year := int(Time.get_date_dict_from_system().year)
	if scenario == _proj_yearbook_scenario and _proj_cache_fully_built(cur_year):
		_proj_cache_building = false
		set_process(false)
		return
	if scenario != _proj_yearbook_scenario:
		_proj_yearbook_cache.clear()
		_proj_build_next_year = cur_year + 1
		_proj_partial_year = -1
		_proj_build_month = 1
		_proj_build_highs = 0
		_proj_build_lows = 0
	else:
		for yr in range(cur_year + 1, CHART_END_YEAR + 1):
			if not _proj_yearbook_cache.has(yr):
				_proj_build_next_year = yr
				_proj_partial_year = -1
				_proj_build_month = 1
				_proj_build_highs = 0
				_proj_build_lows = 0
				break
	_proj_yearbook_scenario = scenario
	_proj_cache_building = true
	set_process(true)


func _proj_cache_fully_built(cur_year: int) -> bool:
	for yr in range(cur_year + 1, CHART_END_YEAR + 1):
		if not _proj_yearbook_cache.has(yr):
			return false
	return true


func _process(_delta: float) -> void:
	var keep_going := false
	if _proj_cache_building:
		if _tick_proj_cache_build():
			_proj_cache_building = false
		else:
			keep_going = true
	if _gen_ybook_cache_building:
		if _tick_generated_yearbook_build():
			_gen_ybook_cache_building = false
		else:
			keep_going = true
		if visible:
			_redraw_chart()
	if _weather_gen_active:
		var step: Dictionary = WeatherService.generation_step()
		if bool(step.get("done", false)):
			_weather_gen_active = false
		else:
			keep_going = true
	if _weather_gen_waiting_training:
		if WeatherService.is_loading_training():
			WeatherService.training_load_step()
			keep_going = true
		elif WeatherService.is_fetching_training():
			keep_going = true
		elif WeatherService.is_generating():
			_weather_gen_active = true
			_weather_gen_waiting_training = false
			_gen_training_model = false
			_update_gen_weather_button()
			keep_going = true
		elif not WeatherService.has_pending_generation():
			_weather_gen_waiting_training = false
			_gen_training_model = false
			_update_gen_weather_button()
		else:
			keep_going = true
	if not keep_going:
		set_process(false)
		return
	if visible:
		_update_progress()


func _needs_background_process() -> bool:
	return _proj_cache_building or _gen_ybook_cache_building \
		or _weather_gen_active or _weather_gen_waiting_training


func _tick_proj_cache_build() -> bool:
	var cps := get_node_or_null("/root/ClimateProjectionService")
	if cps == null or not bool(cps.call("has_projection")):
		return true
	var cur_year := int(Time.get_date_dict_from_system().year)
	var target := _next_proj_year_to_build(cur_year)
	if target < 0:
		return true
	_advance_proj_year_build(cps, target)
	_redraw_chart()
	return _proj_cache_fully_built(cur_year)


func _next_proj_year_to_build(cur_year: int) -> int:
	if _proj_partial_year > cur_year and not _proj_yearbook_cache.has(_proj_partial_year):
		return _proj_partial_year
	for yr in range(maxi(cur_year + 1, _proj_build_next_year), CHART_END_YEAR + 1):
		if not _proj_yearbook_cache.has(yr):
			return yr
	return -1


## Advance one calendar month for [param year]. Returns true when the year finished.
func _advance_proj_year_build(cps: Node, year: int) -> bool:
	if not cps.has_method("count_record_breaks_for_month"):
		_proj_yearbook_cache[year] = cps.call("compute_projected_yearbook_for_year", year)
		_proj_partial_year = -1
		if year >= _proj_build_next_year:
			_proj_build_next_year = year + 1
		return true
	if _proj_partial_year != year:
		_proj_partial_year = year
		_proj_build_month = 1
		_proj_build_highs = 0
		_proj_build_lows = 0
	var part: Dictionary = cps.call("count_record_breaks_for_month", year, _proj_build_month)
	_proj_build_highs += int(part.get("highs", 0))
	_proj_build_lows += int(part.get("lows", 0))
	_proj_build_month += 1
	if _proj_build_month > 12:
		_proj_yearbook_cache[year] = {"highs": _proj_build_highs, "lows": _proj_build_lows}
		_proj_partial_year = -1
		if year >= _proj_build_next_year:
			_proj_build_next_year = year + 1
		_proj_build_month = 1
		_proj_build_highs = 0
		_proj_build_lows = 0
		return true
	return false


func _start_generated_yearbook_build(years: Array) -> void:
	_gen_ybook_years_queue.clear()
	for yr_v in years:
		var yr := int(yr_v)
		if WeatherService.is_generated_year(yr) and not WeatherService.has_generated_yearbook(yr):
			_gen_ybook_years_queue.append(yr)
	if _gen_ybook_years_queue.is_empty():
		return
	WeatherService.invalidate_generated_yearbook(_gen_ybook_years_queue)
	_gen_ybook_partial_year = -1
	_gen_ybook_build_month = 1
	_gen_ybook_build_highs = 0
	_gen_ybook_build_lows = 0
	_gen_ybook_build_precip = 0
	_gen_ybook_cache_building = true
	set_process(true)


func _tick_generated_yearbook_build() -> bool:
	if not WeatherService.has_records():
		return false
	if _gen_ybook_years_queue.is_empty() and _gen_ybook_partial_year < 0:
		return true
	var year := _gen_ybook_partial_year
	if year < 0:
		if _gen_ybook_years_queue.is_empty():
			return true
		year = _gen_ybook_years_queue[0]
		_gen_ybook_partial_year = year
		_gen_ybook_build_month = 1
		_gen_ybook_build_highs = 0
		_gen_ybook_build_lows = 0
		_gen_ybook_build_precip = 0
	var part: Dictionary = WeatherService.count_generated_record_breaks_for_month(
		year, _gen_ybook_build_month)
	_gen_ybook_build_highs += int(part.get("highs", 0))
	_gen_ybook_build_lows += int(part.get("lows", 0))
	_gen_ybook_build_precip += int(part.get("precip", 0))
	_gen_ybook_build_month += 1
	if _gen_ybook_build_month > 12:
		WeatherService.store_generated_yearbook(year, {
			"highs": _gen_ybook_build_highs,
			"lows": _gen_ybook_build_lows,
			"precip": _gen_ybook_build_precip,
		})
		_gen_ybook_years_queue.erase(year)
		_gen_ybook_partial_year = -1
	return _gen_ybook_years_queue.is_empty()


## Queue yearbook rebuild for any generated years missing cached counts (e.g. panel
## was closed during generation_complete).
func _ensure_generated_yearbook_queue() -> void:
	if _gen_ybook_cache_building:
		return
	var missing: Array[int] = []
	for yr in WeatherService.generated_years():
		if not WeatherService.has_generated_yearbook(yr):
			missing.append(yr)
	if missing.is_empty():
		return
	_start_generated_yearbook_build(missing)


func _visible_column_range(num_years: int) -> Vector2i:
	if _scroll == null:
		return Vector2i(0, num_years - 1)
	var scroll_x := float(_scroll.scroll_horizontal)
	var view_w := maxf(float(_scroll.size.x), 1.0)
	var first_idx := int(floor((scroll_x - float(CHART_MARGIN_LEFT)) / float(BAR_STRIDE))) - 3
	var last_idx := int(ceil((scroll_x + view_w - float(CHART_MARGIN_LEFT)) / float(BAR_STRIDE))) + 3
	return Vector2i(
		clampi(first_idx, 0, num_years - 1),
		clampi(last_idx, 0, num_years - 1))


# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

func _build_modal() -> void:
	# Semi-transparent backdrop — click anywhere to close.
	_backdrop = ColorRect.new()
	_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_backdrop.color = Color(0.0, 0.0, 0.0, 0.55)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	_backdrop.gui_input.connect(_on_backdrop_input)
	add_child(_backdrop)

	# Centered panel.
	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.offset_left   = -550
	_panel.offset_right  =  550
	_panel.offset_top    = -325
	_panel.offset_bottom =  325
	var sb := StyleBoxFlat.new()
	sb.bg_color     = Color(C_PANEL.r, C_PANEL.g, C_PANEL.b, 0.99)
	sb.border_color = C_BORDER
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(10.0)
	sb.shadow_size = 14
	sb.shadow_color = Color(0.0, 0.0, 0.0, 0.50)
	_panel.add_theme_stylebox_override("panel", sb)
	add_child(_panel)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 6)
	_panel.add_child(vbox)

	_build_header(vbox)
	_build_legend(vbox)
	_build_weather_controls(vbox)
	_build_chart_area(vbox)
	_build_detail_panel(vbox)
	_build_status_bar(vbox)


func _build_header(parent: VBoxContainer) -> void:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	parent.add_child(hbox)

	_header_lbl = Label.new()
	_header_lbl.text = "🌡 Climate Record Book"
	_header_lbl.add_theme_color_override("font_color", C_PRIMARY)
	_header_lbl.add_theme_font_size_override("font_size", 15)
	_header_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(_header_lbl)

	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.flat = true
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.custom_minimum_size = Vector2(32, 32)
	close_btn.add_theme_color_override("font_color", C_TEXT_M)
	close_btn.add_theme_color_override("font_hover_color", C_TEXT)
	close_btn.add_theme_font_size_override("font_size", 16)
	close_btn.pressed.connect(close)
	hbox.add_child(close_btn)


func _build_legend(parent: VBoxContainer) -> void:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 16)
	parent.add_child(hbox)
	_mk_legend_item(hbox, C_RED,    "▲ Record highs")
	_mk_legend_item(hbox, C_BLUE,   "▼ Record lows")
	_mk_legend_item(hbox, C_CYAN,   "◆ Precip records")
	_mk_legend_item(hbox, C_ORANGE, "● NWS alerts")
	_mk_legend_item(hbox, Color(0.90, 0.22, 0.22, 0.72), "▲ Generated highs")
	_mk_legend_item(hbox, Color(0.35, 0.35, 0.35, 0.42), "▲ CMIP6 estimate")
	_compute_btn = Button.new()
	_compute_btn.text = "Compute Scenario"
	_compute_btn.focus_mode = Control.FOCUS_NONE
	_compute_btn.tooltip_text = (
		"Estimate projected record-breaking days for each future year "
		+ "(CMIP6 monthly warming applied to ERA5 climatology). "
		+ "Runs incrementally in the background — one month per frame."
	)
	_compute_btn.pressed.connect(_on_compute_scenario_pressed)
	hbox.add_child(_compute_btn)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(spacer)
	_progress_lbl = Label.new()
	_progress_lbl.text = ""
	_progress_lbl.add_theme_color_override("font_color", C_TEXT_M)
	_progress_lbl.add_theme_font_size_override("font_size", 10)
	_progress_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hbox.add_child(_progress_lbl)


func _build_weather_controls(parent: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	parent.add_child(row)

	var seed_lbl := Label.new()
	seed_lbl.text = "Seed"
	seed_lbl.add_theme_color_override("font_color", C_TEXT_S)
	seed_lbl.add_theme_font_size_override("font_size", 10)
	row.add_child(seed_lbl)

	_gen_seed_spin = SpinBox.new()
	_gen_seed_spin.min_value = 0
	_gen_seed_spin.max_value = 999999999
	_gen_seed_spin.value = absi(hash(str(randi()))) % 999999
	_gen_seed_spin.custom_minimum_size = Vector2(100, 0)
	_gen_seed_spin.focus_mode = Control.FOCUS_NONE
	_gen_seed_spin.tooltip_text = "Deterministic RNG seed — same seed reproduces identical weather."
	row.add_child(_gen_seed_spin)

	var yrs_lbl := Label.new()
	yrs_lbl.text = "Years"
	yrs_lbl.add_theme_color_override("font_color", C_TEXT_S)
	yrs_lbl.add_theme_font_size_override("font_size", 10)
	row.add_child(yrs_lbl)

	_gen_years_spin = SpinBox.new()
	_gen_years_spin.min_value = 1
	_gen_years_spin.max_value = 24
	_gen_years_spin.value = 1
	_gen_years_spin.custom_minimum_size = Vector2(48, 0)
	_gen_years_spin.focus_mode = Control.FOCUS_NONE
	_gen_years_spin.tooltip_text = (
		"Number of year-tranches to synthesize: 1 = rest of this calendar year "
		+ "(from the 1st of this month); 2+ adds full future years after that."
	)
	row.add_child(_gen_years_spin)

	var engine_lbl := Label.new()
	engine_lbl.text = "Engine"
	engine_lbl.add_theme_color_override("font_color", C_TEXT_S)
	engine_lbl.add_theme_font_size_override("font_size", 10)
	row.add_child(engine_lbl)

	_gen_engine_opt = OptionButton.new()
	_gen_engine_opt.focus_mode = Control.FOCUS_NONE
	_gen_engine_opt.add_item("Parametric", WeatherService.GenEngine.PARAMETRIC)
	_gen_engine_opt.add_item("Resampler", WeatherService.GenEngine.RESAMPLER)
	_gen_engine_opt.select(_gen_engine_opt.get_item_index(WeatherService.get_default_engine()))
	_gen_engine_opt.tooltip_text = (
		"Synthesis engine. Parametric = WGEN-style fitted distributions (smooth, "
		+ "fully synthetic). Resampler = k-NN block bootstrap that stitches real "
		+ "multi-day archive blocks (preserves observed textures), with quantile-"
		+ "mapping bias correction."
	)
	_gen_engine_opt.item_selected.connect(_on_engine_selected)
	row.add_child(_gen_engine_opt)

	_gen_weather_btn = Button.new()
	_gen_weather_btn.text = "Generate Weather"
	_gen_weather_btn.focus_mode = Control.FOCUS_NONE
	_gen_weather_btn.tooltip_text = (
		"Synthesize plausible hourly weather for future years (temp, wind, precip, "
		+ "cloud, radiation, humidity) with CMIP6 warming embedded. Rebuilds from "
		+ "the last %d Open-Meteo archive years every run (clears generated cache)."
		% WeatherService.TRAINING_YEAR_COUNT
	)
	_gen_weather_btn.pressed.connect(_on_generate_weather_pressed)
	row.add_child(_gen_weather_btn)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)


func _mk_legend_item(parent: HBoxContainer, col: Color, label: String) -> void:
	var swatch := ColorRect.new()
	swatch.color = Color(col.r, col.g, col.b, 0.85)
	swatch.custom_minimum_size = Vector2(10, 10)
	swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	parent.add_child(swatch)
	var lbl := Label.new()
	lbl.text = label
	lbl.add_theme_color_override("font_color", C_TEXT_S)
	lbl.add_theme_font_size_override("font_size", 10)
	parent.add_child(lbl)


func _build_chart_area(parent: VBoxContainer) -> void:
	_scroll = ScrollContainer.new()
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.vertical_scroll_mode   = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.mouse_filter = Control.MOUSE_FILTER_STOP
	parent.add_child(_scroll)

	_chart_canvas = Control.new()
	_chart_canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_chart_canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	_chart_canvas.draw.connect(_draw_chart)
	_chart_canvas.gui_input.connect(_on_canvas_input)
	_scroll.add_child(_chart_canvas)
	var hbar := _scroll.get_h_scroll_bar()
	if hbar != null:
		hbar.value_changed.connect(_on_chart_scroll_changed)


func _build_detail_panel(parent: VBoxContainer) -> void:
	var detail_pc := PanelContainer.new()
	detail_pc.custom_minimum_size = Vector2(0, 110)
	var dsb := StyleBoxFlat.new()
	dsb.bg_color = Color(C_BG.r, C_BG.g, C_BG.b, 0.80)
	dsb.border_color = Color(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.50)
	dsb.set_border_width_all(1)
	dsb.set_corner_radius_all(4)
	dsb.set_content_margin_all(8.0)
	detail_pc.add_theme_stylebox_override("panel", dsb)
	parent.add_child(detail_pc)

	_detail_lbl = RichTextLabel.new()
	_detail_lbl.bbcode_enabled = true
	_detail_lbl.fit_content = false
	_detail_lbl.scroll_active = false
	_detail_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail_lbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_detail_lbl.add_theme_color_override("default_color", C_TEXT_S)
	_detail_lbl.add_theme_font_size_override("normal_font_size", 11)
	_detail_lbl.text = "[color=#6080a0]Hover a historical year column to see details[/color]"
	detail_pc.add_child(_detail_lbl)


func _build_status_bar(parent: VBoxContainer) -> void:
	_status_lbl = Label.new()
	_status_lbl.text = "Temperature records: 1940-present · NWS alerts: 1986-present (IEM) · Global anomaly: NASA GISTEMP v4"
	_status_lbl.add_theme_color_override("font_color", C_TEXT_M)
	_status_lbl.add_theme_font_size_override("font_size", 9)
	parent.add_child(_status_lbl)


# ---------------------------------------------------------------------------
# Open / close / toggle
# ---------------------------------------------------------------------------

func toggle() -> void:
	if visible:
		close()
	else:
		open()


func open() -> void:
	_main_node = _timeline.get("_main") if _timeline != null else null
	_update_header()
	visible = true
	set_process(_needs_background_process())
	# Release mouse so the user can interact with the modal.
	if CursorController.has_method("set_paused"):
		CursorController.set_paused(true)
	_ensure_generated_yearbook_queue()
	_on_opened()


func close() -> void:
	visible = false
	if not _needs_background_process():
		set_process(false)
	_weather_gen_active = false
	_is_scrolling = false
	_hovered_year_idx = -1
	_locked_year_idx  = -1
	_detail_locked    = false
	_proj_partial_year = -1
	_pending_detail_idx = -1
	_detail_update_scheduled = false
	_detail_text_cache = ""
	if _timeline != null and _timeline.has_method("_recapture_mouse"):
		_timeline._recapture_mouse()


func is_open() -> bool:
	return visible


func _on_opened() -> void:
	_update_canvas_size()
	_bootstrap_record_book_data()
	if _chart_canvas != null:
		_chart_canvas.queue_redraw()
	_update_progress()
	call_deferred("_scroll_to_right")
	_update_compute_button_state()
	_update_gen_weather_button()


func _on_generate_weather_pressed() -> void:
	if _weather_gen_active or _weather_gen_waiting_training:
		return
	if _main_node == null:
		return
	var lat_v: Variant = _main_node.get("latitude")
	var lon_v: Variant = _main_node.get("longitude")
	if lat_v == null or lon_v == null:
		return
	var lat := float(lat_v)
	var lon := float(lon_v)
	var seed_val := int(_gen_seed_spin.value) if _gen_seed_spin != null else 0
	var num_years := int(_gen_years_spin.value) if _gen_years_spin != null else 1
	var scenario := -1
	var cps := get_node_or_null("/root/ClimateProjectionService")
	if cps != null and bool(cps.call("has_projection")):
		scenario = int(cps.get("active_scenario"))
	_start_weather_generation(seed_val, num_years, lat, lon, scenario)


func _on_engine_selected(index: int) -> void:
	if _gen_engine_opt == null:
		return
	WeatherService.set_default_engine(_gen_engine_opt.get_item_id(index))


func _start_weather_generation(seed_val: int, num_years: int, lat: float, lon: float, scenario: int) -> void:
	_training_loaded_count = 0
	_training_total_count = WeatherService.TRAINING_YEAR_COUNT
	_gen_training_model = false
	var engine_kind := WeatherService.get_default_engine()
	if _gen_engine_opt != null:
		engine_kind = _gen_engine_opt.get_item_id(_gen_engine_opt.selected)
	if WeatherService.begin_generation(seed_val, num_years, lat, lon, scenario, true, engine_kind):
		_weather_gen_active = WeatherService.is_generating()
		_weather_gen_waiting_training = false
		if _weather_gen_active:
			set_process(true)
		_update_gen_weather_button()
		_update_progress()
	elif WeatherService.is_loading_training() or WeatherService.is_fetching_training() \
			or WeatherService.has_pending_generation():
		_weather_gen_waiting_training = true
		set_process(true)
		_update_gen_weather_button()
		_update_progress()


func _on_compute_scenario_pressed() -> void:
	if _proj_cache_building:
		return
	var cps := get_node_or_null("/root/ClimateProjectionService")
	if cps == null or not bool(cps.call("has_projection")):
		return
	# Fresh run — keeps the incremental bar/scaling reveal the user liked.
	_proj_yearbook_cache.clear()
	var cur_year := int(Time.get_date_dict_from_system().year)
	_proj_build_next_year = cur_year + 1
	_proj_partial_year = -1
	_proj_build_month = 1
	_proj_build_highs = 0
	_proj_build_lows = 0
	_proj_yearbook_scenario = int(cps.get("active_scenario"))
	_start_proj_cache_build()
	_redraw_chart()
	_update_compute_button_state()


func _bootstrap_record_book_data() -> void:
	# Historical daily max/min/precip records (1940–present) for the chart.
	if _main_node != null:
		var lat_v: Variant = _main_node.get("latitude")
		var lon_v: Variant = _main_node.get("longitude")
		if lat_v != null and lon_v != null:
			WeatherService.request_records(float(lat_v), float(lon_v))
			var cps := get_node_or_null("/root/ClimateProjectionService")
			if cps != null and cps.has_method("begin_record_book"):
				cps.call("begin_record_book", float(lat_v), float(lon_v))
	# GISTEMP global anomaly (small, cached annually).
	var gistemp := get_node_or_null("/root/GistempService")
	if gistemp != null and gistemp.has_method("request_gistemp"):
		gistemp.call("request_gistemp")
	# NWS historical alerts for the chart dots.
	_request_nws_history_if_ready()
	var zone_svc := get_node_or_null("/root/NwsZoneService")
	if zone_svc != null and zone_svc.has_signal("zone_ready") \
			and not zone_svc.is_connected("zone_ready", _on_zone_ready_for_nws):
		zone_svc.connect("zone_ready", _on_zone_ready_for_nws)


func _request_nws_history_if_ready() -> void:
	var ugc := _current_ugc()
	if ugc.is_empty():
		return
	var alert_svc := get_node_or_null("/root/NwsAlertService")
	if alert_svc != null and alert_svc.has_method("request_all_hist_years"):
		var cur_year := int(Time.get_date_dict_from_system().year)
		alert_svc.call("request_all_hist_years", ugc, 1986, cur_year)


func _on_zone_ready_for_nws(_lat: float, _lon: float, _ugc: String,
		_stn: String, _icao: String) -> void:
	_update_header()
	_request_nws_history_if_ready()
	_redraw_chart()


func _scroll_to_right() -> void:
	if _scroll == null:
		return
	# Scroll so the TODAY line sits roughly 75% from the left edge of the viewport,
	# showing recent history and some future projected columns simultaneously.
	var cur_year := int(Time.get_date_dict_from_system().year)
	var today_x := CHART_MARGIN_LEFT + (cur_year - CHART_START_YEAR) * BAR_STRIDE
	var scroll_to := maxi(0, today_x - 820)
	_scroll.scroll_horizontal = scroll_to


func _on_chart_scroll_changed(_value: float) -> void:
	_is_scrolling = true
	_scroll_debounce_gen += 1
	var gen := _scroll_debounce_gen
	if _proj_cache_building:
		set_process(true)
	_redraw_chart()
	var tree := get_tree()
	if tree != null:
		tree.create_timer(0.12).timeout.connect(func():
			if gen == _scroll_debounce_gen:
				_is_scrolling = false
		, CONNECT_ONE_SHOT)


func _update_canvas_size() -> void:
	if _chart_canvas == null:
		return
	var num_years := CHART_END_YEAR - CHART_START_YEAR + 1  # 1940–2049
	var canvas_w := CHART_MARGIN_LEFT + num_years * BAR_STRIDE
	_chart_canvas.custom_minimum_size = Vector2(canvas_w, CHART_TOTAL_H)


func _update_header() -> void:
	if _header_lbl == null or _main_node == null:
		return
	var lat := float(_main_node.get("latitude") if _main_node.get("latitude") != null else 0.0)
	var lon := float(_main_node.get("longitude") if _main_node.get("longitude") != null else 0.0)
	var stn := ""
	var zone_svc := get_node_or_null("/root/NwsZoneService")
	if zone_svc != null and zone_svc.has_method("get_station_name"):
		stn = str(zone_svc.call("get_station_name", lat, lon))
	var loc_str: String
	if not stn.is_empty():
		loc_str = "%s  (%.4f, %.4f)" % [stn, lat, lon]
	else:
		loc_str = "%.4f, %.4f" % [lat, lon]
	_header_lbl.text = "🌡 Climate Record Book — %s" % loc_str


func _update_progress() -> void:
	if _progress_lbl == null:
		return
	var parts: Array = []
	var alert_svc := get_node_or_null("/root/NwsAlertService")
	if alert_svc != null:
		var queue_sz: Variant = alert_svc.get("_hist_queue")
		if queue_sz != null and (queue_sz as Array).size() > 0:
			parts.append("Loading NWS history… (%d remaining)" % (queue_sz as Array).size())
	var cps := get_node_or_null("/root/ClimateProjectionService")
	if cps != null and bool(cps.call("is_fetching")):
		var src := str(cps.call("get_data_source"))
		if src == "cds":
			parts.append("Fetching CMIP6 from Copernicus CDS… (first run may take several minutes)")
		else:
			parts.append("Loading climate projection…")
	if _proj_cache_building:
		var cur_year := int(Time.get_date_dict_from_system().year)
		var total := maxi(1, CHART_END_YEAR - cur_year)
		var done := 0
		for yr in _proj_yearbook_cache.keys():
			if int(yr) > cur_year:
				done += 1
		parts.append("Computing scenario… (%d/%d years)" % [done, total])
	if _weather_gen_waiting_training:
		if WeatherService.is_fetching_training():
			parts.append("Downloading training archive %d/%d…" % [
				_training_loaded_count, _training_total_count])
		elif WeatherService.is_loading_training():
			parts.append("Loading training archives %d/%d…" % [
				_training_loaded_count, _training_total_count])
		elif _gen_training_model:
			parts.append("Training weather model from %d years…" % _training_total_count)
	if _weather_gen_active:
		var mo_names: Array[String] = [
			"Jan", "Feb", "Mar", "Apr", "May", "Jun",
			"Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
		]
		var mn: String = mo_names[clampi(_gen_progress_month - 1, 0, 11)] \
			if _gen_progress_month > 0 else "…"
		parts.append("Generating weather %d — %s…" % [_gen_progress_year, mn])
	if _gen_ybook_cache_building:
		parts.append("Counting generated record breaks…")
	_progress_lbl.text = "  ".join(parts)
	_update_compute_button_state()
	if _status_lbl != null:
		var ugc := _current_ugc()
		var zone_str := (" · Zone: %s" % ugc) if not ugc.is_empty() else " · Zone: resolving…"
		var proj_str := ""
		if cps != null and bool(cps.call("has_projection")):
			var src := str(cps.call("get_data_source"))
			match src:
				"cds":
					proj_str = " · CMIP6 (Copernicus CDS)"
				"open_meteo":
					proj_str = " · CMIP6 (Open-Meteo)"
				_:
					proj_str = " · CMIP6 loaded"
		var gen_str := ""
		if WeatherService.has_generated():
			gen_str = " · Generated weather yearbook active"
		_status_lbl.text = "Temp records: 1940–present · NWS: 1986–present%s · Projection through %d%s%s · GISTEMP v4" \
			% [zone_str, CHART_END_YEAR, proj_str, gen_str]


func _update_compute_button_state() -> void:
	if _compute_btn == null:
		return
	var cps := get_node_or_null("/root/ClimateProjectionService")
	var has_proj := cps != null and bool(cps.call("has_projection"))
	_compute_btn.disabled = not has_proj or _proj_cache_building
	if not has_proj:
		_compute_btn.text = "Compute Scenario"
		_compute_btn.tooltip_text = "Load CMIP6 projection data first (opens automatically on first visit)."
		return
	var cur_year := int(Time.get_date_dict_from_system().year)
	if _proj_cache_building:
		var total := maxi(1, CHART_END_YEAR - cur_year)
		var done := 0
		for yr in _proj_yearbook_cache.keys():
			if int(yr) > cur_year:
				done += 1
		_compute_btn.text = "Computing… %d/%d" % [done, total]
		return
	if _proj_cache_fully_built(cur_year):
		_compute_btn.text = "Recompute Scenario"
	else:
		_compute_btn.text = "Compute Scenario"


func _update_gen_weather_button() -> void:
	if _gen_weather_btn == null:
		return
	var busy := _weather_gen_active or _weather_gen_waiting_training or _proj_cache_building
	_gen_weather_btn.disabled = busy
	if _gen_engine_opt != null:
		_gen_engine_opt.disabled = busy
	if _weather_gen_waiting_training:
		if not _gen_weather_btn.text.begins_with("Loading training"):
			_gen_weather_btn.text = "Loading training…"
		return
	if _weather_gen_active:
		_gen_weather_btn.text = "Generating…"
		return
	if WeatherService.has_generated():
		_gen_weather_btn.text = "Regenerate Weather"
	else:
		_gen_weather_btn.text = "Generate Weather"


# ---------------------------------------------------------------------------
# Chart drawing
# ---------------------------------------------------------------------------

func _draw_chart() -> void:
	if _chart_canvas == null:
		return
	var cur_year   := int(Time.get_date_dict_from_system().year)
	var num_years  := CHART_END_YEAR - CHART_START_YEAR + 1
	if not _yearbook_cache_valid:
		_cached_yearbook = WeatherService.compute_yearbook() if WeatherService.has_records() else {}
		_yearbook_cache_valid = true
	var yearbook   := _cached_yearbook
	var ugc        := _current_ugc()
	var gistemp    := get_node_or_null("/root/GistempService")
	var alert_svc  := get_node_or_null("/root/NwsAlertService")
	var cps        := get_node_or_null("/root/ClimateProjectionService")
	var canvas_w   := float(CHART_MARGIN_LEFT + num_years * BAR_STRIDE)
	var font       := ThemeDB.fallback_font
	var has_proj   := cps != null and bool(cps.call("has_projection"))
	var vis        := _visible_column_range(num_years)
	var vis_first  := vis.x
	var vis_last   := vis.y

	# --- Compute bar scale from historical + projected data ---
	var max_highs := 1
	var max_lows  := 1
	for yr_v in yearbook.keys():
		var e: Dictionary = yearbook[yr_v] as Dictionary
		max_highs = maxi(max_highs, int(e.get("highs", 0)))
		max_lows  = maxi(max_lows,  int(e.get("lows",  0)))
	for yr in range(cur_year + 1, CHART_END_YEAR + 1):
		var e: Dictionary = _proj_entry_for_year(yr)
		max_highs = maxi(max_highs, int(e.get("highs", 0)))
		max_lows  = maxi(max_lows,  int(e.get("lows",  0)))
	var high_scale := float(UPPER_CHART_H) / float(max_highs)
	var low_scale  := float(LOWER_CHART_H) / float(max_lows)

	# Max NWS count for dot-radius scaling (historical years only).
	if not _alerts_cache_valid:
		_cached_max_alerts = 1
		if alert_svc != null and alert_svc.has_method("get_alert_count_for_year"):
			for i in (cur_year - CHART_START_YEAR + 1):
				var yr := CHART_START_YEAR + i
				var cnt := int(alert_svc.call("get_alert_count_for_year", ugc, yr))
				if cnt > _cached_max_alerts:
					_cached_max_alerts = cnt
		_alerts_cache_valid = true
	var max_alerts := _cached_max_alerts

	# --- Per-year columns (viewport-culled) ---
	for i in range(vis_first, vis_last + 1):
		var yr      := CHART_START_YEAR + i
		var col_x   := float(CHART_MARGIN_LEFT + i * BAR_STRIDE)
		var is_future := yr > cur_year

		if is_future:
			# --- Projected future column ---
			# Dim grey overlay to distinguish from historical.
			_chart_canvas.draw_rect(
				Rect2(col_x, 0.0, float(BAR_STRIDE), float(CHART_TOTAL_H)),
				Color(0.0, 0.0, 0.0, 0.28), true)

			# CMIP6 anomaly tint (warmer = redder, lighter alpha than historical).
			if has_proj and yr <= CHART_END_YEAR and cps.has_method("get_projected_anomaly"):
				var anomaly := float(cps.call("get_projected_anomaly", yr))
				if not is_nan(anomaly):
					var alpha := clampf(anomaly * 0.04, 0.0, 0.15)
					_chart_canvas.draw_rect(
						Rect2(col_x, 0.0, float(BAR_STRIDE), float(CHART_TOTAL_H)),
						Color(1.0, 0.15, 0.05, alpha), true)

			# Projected / generated future bars (generated = brighter when available).
			var proj: Dictionary = _proj_entry_for_year(yr)
			if not proj.is_empty():
				var from_generated := str(proj.get("source", "")) == "generated"
				var high_alpha := 0.72 if from_generated else 0.42
				var low_alpha := 0.72 if from_generated else 0.42
				var n_highs := int(proj.get("highs", 0))
				if n_highs > 0:
					var bh := clampf(float(n_highs) * high_scale, MIN_BAR_PX, float(UPPER_CHART_H))
					_chart_canvas.draw_rect(
						Rect2(col_x + 1.0, float(BASELINE_Y) - bh, float(BAR_WIDTH), bh),
						Color(0.90, 0.22, 0.22, high_alpha), true)
				var n_lows := int(proj.get("lows", 0))
				if n_lows > 0:
					var bh := clampf(float(n_lows) * low_scale, MIN_BAR_PX, float(LOWER_CHART_H))
					_chart_canvas.draw_rect(
						Rect2(col_x + 1.0, float(BASELINE_Y), float(BAR_WIDTH), bh),
						Color(0.22, 0.45, 0.95, low_alpha), true)
			elif has_proj or _gen_ybook_cache_building:
				# Skeleton placeholder while cache is building.
				_chart_canvas.draw_rect(
					Rect2(col_x + 1.0, float(BASELINE_Y) - 18.0, float(BAR_WIDTH), 18.0),
					Color(0.35, 0.35, 0.35, 0.18), true)

		else:
			# --- Historical column ---
			# GISTEMP background tint.
			if gistemp != null and gistemp.has_method("get_anomaly"):
				var anomaly := float(gistemp.call("get_anomaly", yr))
				if not is_nan(anomaly):
					var alpha := clampf(absf(anomaly) * 0.045, 0.0, 0.10)
					var tint_col: Color
					if anomaly > 0.0:
						tint_col = Color(1.0, 0.15, 0.05, alpha)
					else:
						tint_col = Color(0.05, 0.35, 1.0, alpha)
					_chart_canvas.draw_rect(
						Rect2(col_x, 0.0, float(BAR_STRIDE), float(CHART_TOTAL_H)), tint_col, true)

			# Hover / lock highlight.
			if i == _hovered_year_idx or i == _locked_year_idx:
				_chart_canvas.draw_rect(
					Rect2(col_x, 0.0, float(BAR_STRIDE), float(CHART_TOTAL_H)),
					Color(1.0, 1.0, 1.0, 0.07), true)

			# Record-high bar (red, grows upward).
			var entry: Dictionary = yearbook.get(yr, {}) as Dictionary
			var n_highs := int(entry.get("highs", 0))
			if n_highs > 0:
				var bh := clampf(float(n_highs) * high_scale, MIN_BAR_PX, float(UPPER_CHART_H))
				_chart_canvas.draw_rect(
					Rect2(col_x + 1.0, float(BASELINE_Y) - bh, float(BAR_WIDTH), bh),
					Color(0.90, 0.22, 0.22, 0.85), true)

			# Record-low bar (blue, grows downward).
			var n_lows := int(entry.get("lows", 0))
			if n_lows > 0:
				var bh := clampf(float(n_lows) * low_scale, MIN_BAR_PX, float(LOWER_CHART_H))
				_chart_canvas.draw_rect(
					Rect2(col_x + 1.0, float(BASELINE_Y), float(BAR_WIDTH), bh),
					Color(0.22, 0.45, 0.95, 0.85), true)

			# Precip pip (cyan).
			var n_precip := int(entry.get("precip", 0))
			if n_precip > 0:
				_chart_canvas.draw_rect(
					Rect2(col_x + 3.0, float(PIP_ROW_Y) + 4.0, float(BAR_WIDTH) - 6.0, 10.0),
					Color(0.10, 0.88, 0.88, 0.85), true)

			# NWS alert dot (orange, radius ∝ count).
			if alert_svc != null and alert_svc.has_method("get_alert_count_for_year"):
				var cnt := int(alert_svc.call("get_alert_count_for_year", ugc, yr))
				var cx  := col_x + float(BAR_STRIDE) * 0.5
				var cy  := float(DOT_ROW_Y) + float(DOT_ROW_H) * 0.5
				if cnt > 0:
					var radius := clampf(float(cnt) / float(max_alerts) * MAX_DOT_RADIUS, 2.0, MAX_DOT_RADIUS)
					_chart_canvas.draw_circle(Vector2(cx, cy), radius, Color(1.0, 0.55, 0.10, 0.85))
				elif cnt == -1 and yr >= 1986:
					_chart_canvas.draw_circle(Vector2(cx, cy), 1.5, Color(0.4, 0.4, 0.4, 0.35))

	# --- TODAY divider line ---
	var today_x := float(CHART_MARGIN_LEFT + (cur_year - CHART_START_YEAR) * BAR_STRIDE)
	_chart_canvas.draw_line(
		Vector2(today_x, 0.0), Vector2(today_x, float(CHART_TOTAL_H)),
		Color(1.0, 1.0, 1.0, 0.55), 1.5)
	_chart_canvas.draw_string(font,
		Vector2(today_x + 3.0, 11.0), "TODAY",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color(1.0, 1.0, 1.0, 0.70))

	# --- Scenario label above first future column ---
	if has_proj and cps.has_method("get") and is_instance_valid(cps):
		var sc_names: Array[String] = [
			"SSP1-2.6 →", "SSP2-4.5 →", "SSP3-7.0 →", "SSP5-8.5 →"
		]
		var sc := clampi(int(cps.get("active_scenario")), 0, 3)
		_chart_canvas.draw_string(font,
			Vector2(today_x + float(BAR_STRIDE) + 2.0, float(BASELINE_Y) - float(UPPER_CHART_H) + 10.0),
			sc_names[sc], HORIZONTAL_ALIGNMENT_LEFT, -1, 8,
			Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.65))

	# --- Structural lines ---
	_chart_canvas.draw_line(
		Vector2(float(CHART_MARGIN_LEFT), float(BASELINE_Y)),
		Vector2(canvas_w, float(BASELINE_Y)),
		Color(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.55), 1.0)
	_chart_canvas.draw_line(
		Vector2(float(CHART_MARGIN_LEFT), float(PIP_ROW_Y)),
		Vector2(canvas_w, float(PIP_ROW_Y)),
		Color(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.20), 1.0)
	_chart_canvas.draw_line(
		Vector2(float(CHART_MARGIN_LEFT), float(DOT_ROW_Y)),
		Vector2(canvas_w, float(DOT_ROW_Y)),
		Color(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.20), 1.0)

	# --- Y-axis labels ---
	_chart_canvas.draw_string(font,
		Vector2(2.0, float(BASELINE_Y) - float(UPPER_CHART_H) + 10.0),
		"▲%d" % max_highs, HORIZONTAL_ALIGNMENT_LEFT, -1, 8,
		Color(0.90, 0.30, 0.30, 0.65))
	_chart_canvas.draw_string(font,
		Vector2(2.0, float(BASELINE_Y) + float(LOWER_CHART_H) - 2.0),
		"▼%d" % max_lows, HORIZONTAL_ALIGNMENT_LEFT, -1, 8,
		Color(0.30, 0.50, 0.95, 0.65))
	_chart_canvas.draw_string(font,
		Vector2(2.0, float(PIP_ROW_Y) + 12.0),
		"◆", HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(0.10, 0.88, 0.88, 0.65))
	_chart_canvas.draw_string(font,
		Vector2(2.0, float(DOT_ROW_Y) + 12.0),
		"●", HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(1.0, 0.55, 0.10, 0.65))

	# --- Year tick labels every 5 years (visible range) ---
	for i in range(vis_first, vis_last + 1):
		var yr := CHART_START_YEAR + i
		if yr % 5 != 0:
			continue
		var col_x := float(CHART_MARGIN_LEFT + i * BAR_STRIDE)
		_chart_canvas.draw_line(
			Vector2(col_x, float(BASELINE_Y) - 5.0),
			Vector2(col_x, float(BASELINE_Y) + 5.0),
			Color(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.40), 1.0)
		var yr_color := C_TEXT_M if (yr <= cur_year) else Color(C_TEXT_M.r, C_TEXT_M.g, C_TEXT_M.b, 0.55)
		_chart_canvas.draw_string(font,
			Vector2(col_x, float(BOT_LABEL_Y) + 12.0),
			str(yr), HORIZONTAL_ALIGNMENT_LEFT, -1, 8, yr_color)

	# --- Empty-state message ---
	if not WeatherService.has_records():
		var msg_x := float(CHART_MARGIN_LEFT) + float((cur_year - CHART_START_YEAR) * BAR_STRIDE) * 0.5
		_chart_canvas.draw_string(font,
			Vector2(msg_x - 120.0, float(BASELINE_Y) - 20.0),
			"Fetching temperature records…", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, C_TEXT_M)


# ---------------------------------------------------------------------------
# Input handling
# ---------------------------------------------------------------------------

func _on_backdrop_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			close()


func _on_canvas_input(event: InputEvent) -> void:
	var cur_year := int(Time.get_date_dict_from_system().year)
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		var idx := _year_idx_at_x(mm.position.x)
		var year := CHART_START_YEAR + idx if idx >= 0 else -1
		# Future columns: no hover highlight or detail — avoids compute storms on mouse sweep.
		if year > cur_year:
			if _hovered_year_idx != -1:
				_hovered_year_idx = -1
				_redraw_chart()
			return
		if idx != _hovered_year_idx:
			_hovered_year_idx = idx
			_redraw_chart()
			if not _detail_locked and not _is_scrolling:
				_schedule_detail_update(idx)
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			var idx := _year_idx_at_x(mb.position.x)
			if idx < 0:
				return
			var year := CHART_START_YEAR + idx
			if year > cur_year:
				return
			if _detail_locked and idx == _locked_year_idx:
				_detail_locked   = false
				_locked_year_idx = -1
			else:
				_detail_locked   = true
				_locked_year_idx = idx
				_apply_detail_update(idx)
			_redraw_chart()


func _schedule_detail_update(idx: int) -> void:
	_pending_detail_idx = idx
	if _detail_update_scheduled:
		return
	_detail_update_scheduled = true
	call_deferred("_flush_detail_update")


func _flush_detail_update() -> void:
	_detail_update_scheduled = false
	if _detail_locked or _is_scrolling:
		return
	_apply_detail_update(_pending_detail_idx)


func _apply_detail_update(idx: int) -> void:
	_update_detail(idx)


func _year_idx_at_x(x: float) -> int:
	var num_years := CHART_END_YEAR - CHART_START_YEAR + 1
	var idx := int((x - float(CHART_MARGIN_LEFT)) / float(BAR_STRIDE))
	return clampi(idx, 0, num_years - 1) if x >= float(CHART_MARGIN_LEFT) else -1


# ---------------------------------------------------------------------------
# Detail panel
# ---------------------------------------------------------------------------

func _update_detail(year_idx: int) -> void:
	if _detail_lbl == null:
		return
	if year_idx < 0:
		_detail_text_cache = ""
		_detail_lbl.text = "[color=#6080a0]Hover a historical year column to see details[/color]"
		return
	var year     := CHART_START_YEAR + year_idx
	var cur_year := int(Time.get_date_dict_from_system().year)
	if year > cur_year:
		return
	var text := ""

	# --- Historical year ---
	var gistemp := get_node_or_null("/root/GistempService")
	var anomaly_str := ""
	var rank_str    := ""
	if gistemp != null and gistemp.has_method("get_anomaly"):
		var anomaly := float(gistemp.call("get_anomaly", year))
		if not is_nan(anomaly):
			var sign_ch := "+" if anomaly >= 0.0 else ""
			var heat_col := "ff8866" if anomaly >= 0.0 else "88aaff"
			anomaly_str = "  [color=#%s](%s%.2f°C)[/color]" % [heat_col, sign_ch, anomaly]
			if gistemp.has_method("rank_of_year"):
				var rank := int(gistemp.call("rank_of_year", year))
				if rank > 0:
					var ord_s := _ordinal(rank)
					rank_str = "  [color=#ffd048]Global rank: #%d %s hottest[/color]" % [rank, ord_s]
	text += "[color=#cfebff][b]%d[/b][/color]%s%s\n" % [year, rank_str, anomaly_str]

	var dates := WeatherService.get_record_dates_for_year(year)
	var n_highs: int = (dates["highs"] as Array).size()
	var n_lows:  int = (dates["lows"]  as Array).size()
	var n_prec:  int = (dates["precip"] as Array).size()
	if n_highs > 0:
		var sample_s := _fmt_date_list(dates["highs"] as Array, 6)
		text += "[color=#ff5544]▲ Record highs (%d):[/color]  %s\n" % [n_highs, sample_s]
	if n_lows > 0:
		var sample_s := _fmt_date_list(dates["lows"] as Array, 6)
		text += "[color=#5577ff]▼ Record lows (%d):[/color]  %s\n" % [n_lows, sample_s]
	if n_prec > 0:
		var sample_s := _fmt_date_list(dates["precip"] as Array, 6)
		text += "[color=#22dddd]◆ Precip records (%d):[/color]  %s\n" % [n_prec, sample_s]

	var ugc := _current_ugc()
	var alert_svc := get_node_or_null("/root/NwsAlertService")
	if alert_svc != null and not ugc.is_empty() and alert_svc.has_method("get_alert_events_for_year"):
		var events: Array = alert_svc.call("get_alert_events_for_year", ugc, year)
		if events.size() > 0:
			var counts: Dictionary = {}
			for ev in events:
				var nm := str((ev as Dictionary).get("event", "Unknown"))
				counts[nm] = int(counts.get(nm, 0)) + 1
			var parts: Array = []
			var shown := 0
			for nm in counts.keys():
				if shown >= 8:
					parts.append("…")
					break
				parts.append("%s ×%d" % [nm, int(counts[nm])])
				shown += 1
			text += "[color=#ff8822]● NWS Alerts (%d):[/color]  %s\n" % [events.size(), ", ".join(parts)]
		elif events.size() == 0 and year >= 1986:
			text += "[color=#666680]● NWS Alerts: none on record[/color]\n"

	if _detail_locked and _locked_year_idx == year_idx:
		text += "[color=#aabbcc]🔒 Click again to unlock[/color]"

	if text == _detail_text_cache:
		return
	_detail_text_cache = text
	_detail_lbl.text = text


func _proj_entry_for_year(yr: int) -> Dictionary:
	if WeatherService.is_generated_year(yr) and WeatherService.has_generated_yearbook(yr):
		return WeatherService.get_generated_yearbook(yr)
	# TODO(weather-gen): future-year detail panel — list which MM-DD slots broke records
	# from generated hourly data (precip counts already tracked in yearbook entry).
	var v: Variant = _proj_yearbook_cache.get(yr, null)
	if v is Dictionary:
		return v as Dictionary
	return {}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _current_ugc() -> String:
	if _main_node == null:
		return ""
	var lat := float(_main_node.get("latitude")  if _main_node.get("latitude")  != null else 0.0)
	var lon := float(_main_node.get("longitude") if _main_node.get("longitude") != null else 0.0)
	var zone_svc := get_node_or_null("/root/NwsZoneService")
	if zone_svc != null and zone_svc.has_method("get_ugc_zone"):
		return str(zone_svc.call("get_ugc_zone", lat, lon))
	return ""


## Formats up to `max_count` MM-DD strings as "Jan 4, Jul 7, …"
func _fmt_date_list(keys: Array, max_count: int) -> String:
	var month_names := ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
	var parts: Array = []
	for i in mini(keys.size(), max_count):
		var k := str(keys[i])
		if k.length() >= 5:
			var mo := clampi(int(k.substr(0, 2)), 1, 12)
			var dy := int(k.substr(3, 2))
			parts.append("%s %d" % [month_names[mo - 1], dy])
	var result := ", ".join(parts)
	if keys.size() > max_count:
		result += "…"
	return result


func _ordinal(n: int) -> String:
	match n % 100:
		11, 12, 13: return "th"
	match n % 10:
		1: return "st"
		2: return "nd"
		3: return "rd"
	return "th"
