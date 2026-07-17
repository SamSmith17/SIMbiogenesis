extends Control

## Site Report — interactive, site-specific infographic modal.
##
## Opened from the timeline toolbar (📊) or the `toggle_site_report` key. Computes
## a full representative year of month-by-month site analysis (solar radiation,
## PV potential of the current graph, windrose + wind energy, rainflow, and
## temperature) via SiteReportBuilder (async, chunked, disk-cached), then paints
## it into a scrollable set of cards using SiteReportCharts.
##
## Structure follows record_book_panel.gd (added to the parent CanvasLayer so the
## modal isn't clipped by the timeline bar; CursorController.request_modal to
## release the mouse).

const MONTHS := SiteReportMetrics.MONTH_ABBR
const MODAL_NAME := "site_report"
const WEATHER_WAIT_TIMEOUT_S := 10.0

var _timeline: Node = null
var _main_node: Node = null

var _backdrop: ColorRect = null
var _panel: PanelContainer = null
var _header_lbl: Label = null
var _sub_lbl: Label = null
var _source_chip: Label = null
var _scroll: ScrollContainer = null
var _cards_vbox: VBoxContainer = null
var _progress_overlay: Control = null
var _progress_bar: ProgressBar = null
var _progress_lbl: Label = null
var _footnote_lbl: Label = null

# Chart canvases + their hover state.
var _solar_canvas: Control = null
var _pv_canvas: Control = null
var _wind_rose_canvas: Control = null
var _wind_canvas: Control = null
var _precip_canvas: Control = null
var _temp_canvas: Control = null
var _hydro_canvas: Control = null
var _hydro_card: Control = null

# Summary labels per card.
var _solar_stat: RichTextLabel = null
var _pv_stat: RichTextLabel = null
var _wind_stat: RichTextLabel = null
var _precip_stat: RichTextLabel = null
var _temp_stat: RichTextLabel = null
var _hydro_stat: RichTextLabel = null

var _hover: Dictionary = {}   # canvas instance id -> month/sector idx

var _builder: SiteReportBuilder = null
var _data: SiteReportData = null
var _building: bool = false
var _waiting_weather: bool = false
var _weather_wait_left: float = 0.0
var _signals_connected: bool = false


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

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
	_builder = SiteReportBuilder.new()
	_builder.name = "SiteReportBuilder"
	add_child(_builder)
	if not _signals_connected:
		_signals_connected = true
		_builder.progress.connect(_on_build_progress)
		_builder.report_ready.connect(_on_report_ready)
		if WeatherService.has_signal("weather_data_ready"):
			WeatherService.weather_data_ready.connect(_on_weather_ready)


func _build_modal() -> void:
	_backdrop = ColorRect.new()
	_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_backdrop.color = Color(0.0, 0.0, 0.0, 0.6)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	_backdrop.gui_input.connect(_on_backdrop_input)
	add_child(_backdrop)

	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.offset_left = -580
	_panel.offset_right = 580
	_panel.offset_top = -370
	_panel.offset_bottom = 370
	var sb := UITheme.panel_style(0.99)
	sb.shadow_size = 16
	sb.shadow_color = Color(0.0, 0.0, 0.0, 0.5)
	_panel.add_theme_stylebox_override("panel", sb)
	add_child(_panel)

	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", UITheme.SPACE_SM)
	_panel.add_child(root)

	_build_header(root)

	# Body: scroll area with cards, plus an overlay for the compute progress.
	var body := Control.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(body)

	_scroll = ScrollContainer.new()
	_scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	body.add_child(_scroll)

	_cards_vbox = VBoxContainer.new()
	_cards_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cards_vbox.add_theme_constant_override("separation", UITheme.SPACE_MD)
	_scroll.add_child(_cards_vbox)

	_build_cards(_cards_vbox)
	_build_footnote(_cards_vbox)
	_build_progress_overlay(body)


func _build_header(parent: VBoxContainer) -> void:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", UITheme.SPACE_SM)
	parent.add_child(hbox)

	var title_box := VBoxContainer.new()
	title_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_box.add_theme_constant_override("separation", 0)
	hbox.add_child(title_box)

	_header_lbl = Label.new()
	_header_lbl.text = "📊 Site Report"
	_header_lbl.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	_header_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XL)
	title_box.add_child(_header_lbl)

	_sub_lbl = Label.new()
	_sub_lbl.text = "—"
	_sub_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_sub_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	title_box.add_child(_sub_lbl)

	_source_chip = Label.new()
	_source_chip.text = ""
	_source_chip.add_theme_color_override("font_color", UITheme.C_TEXT)
	_source_chip.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_source_chip.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_source_chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hbox.add_child(_source_chip)

	var refresh_btn := Button.new()
	refresh_btn.text = "⟳ Recompute"
	refresh_btn.focus_mode = Control.FOCUS_NONE
	refresh_btn.tooltip_text = "Discard the cached report and recompute for the current site + graph."
	UITheme.style_button(refresh_btn)
	refresh_btn.pressed.connect(_on_recompute_pressed)
	hbox.add_child(refresh_btn)

	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.flat = true
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.custom_minimum_size = Vector2(32, 32)
	close_btn.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	close_btn.add_theme_color_override("font_hover_color", UITheme.C_TEXT)
	close_btn.add_theme_font_size_override("font_size", 16)
	close_btn.pressed.connect(close)
	hbox.add_child(close_btn)


func _build_cards(parent: VBoxContainer) -> void:
	# Solar resource + PV potential side by side.
	var row1 := HBoxContainer.new()
	row1.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row1.add_theme_constant_override("separation", UITheme.SPACE_MD)
	parent.add_child(row1)
	_solar_canvas = Control.new()
	_solar_stat = _mk_stat()
	_add_card(row1, "☀ Solar Radiation Resource", _solar_canvas, _solar_stat, _draw_solar)
	_pv_canvas = Control.new()
	_pv_stat = _mk_stat()
	_add_card(row1, "🔆 PV Potential (current graph)", _pv_canvas, _pv_stat, _draw_pv)

	# Wind rose + wind energy.
	var row2 := HBoxContainer.new()
	row2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row2.add_theme_constant_override("separation", UITheme.SPACE_MD)
	parent.add_child(row2)
	_wind_rose_canvas = Control.new()
	var rose_stat := _mk_stat()
	_add_card(row2, "🧭 Wind Rose", _wind_rose_canvas, rose_stat, _draw_windrose, 190)
	_wind_canvas = Control.new()
	_wind_stat = _mk_stat()
	_add_card(row2, "🌀 Wind Energy Potential", _wind_canvas, _wind_stat, _draw_wind, 190)

	# Rainflow + temperature.
	var row3 := HBoxContainer.new()
	row3.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row3.add_theme_constant_override("separation", UITheme.SPACE_MD)
	parent.add_child(row3)
	_precip_canvas = Control.new()
	_precip_stat = _mk_stat()
	_add_card(row3, "🌧 Rainflow (precipitation)", _precip_canvas, _precip_stat, _draw_precip)
	_temp_canvas = Control.new()
	_temp_stat = _mk_stat()
	_add_card(row3, "🌡 Temperature", _temp_canvas, _temp_stat, _draw_temp)

	# Hydro (hidden unless the graph has hydro items).
	var row4 := HBoxContainer.new()
	row4.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(row4)
	_hydro_canvas = Control.new()
	_hydro_stat = _mk_stat()
	_hydro_card = _add_card(row4, "💧 Hydro Potential (current graph)", _hydro_canvas, _hydro_stat, _draw_hydro)
	_hydro_card.visible = false


func _add_card(parent: Control, title: String, canvas: Control, stat: RichTextLabel,
		draw_cb: Callable, chart_h: int = 150) -> Control:
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.add_theme_stylebox_override("panel", UITheme.card_style())
	parent.add_child(card)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", UITheme.SPACE_XS)
	card.add_child(vb)

	var t := Label.new()
	t.text = title
	t.add_theme_color_override("font_color", UITheme.C_TEXT)
	t.add_theme_font_size_override("font_size", UITheme.FONT_MD)
	vb.add_child(t)

	canvas.custom_minimum_size = Vector2(0, chart_h)
	canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	canvas.draw.connect(draw_cb)
	canvas.gui_input.connect(_on_canvas_input.bind(canvas))
	canvas.mouse_exited.connect(_on_canvas_exit.bind(canvas))
	vb.add_child(canvas)

	vb.add_child(stat)
	return card


func _mk_stat() -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = true
	r.scroll_active = false
	r.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	r.custom_minimum_size = Vector2(0, 34)
	r.add_theme_color_override("default_color", UITheme.C_TEXT_S)
	r.add_theme_font_size_override("normal_font_size", UITheme.FONT_SM)
	r.text = ""
	return r


func _build_footnote(parent: VBoxContainer) -> void:
	_footnote_lbl = Label.new()
	_footnote_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_footnote_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	_footnote_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_footnote_lbl.text = ""
	parent.add_child(_footnote_lbl)


func _build_progress_overlay(parent: Control) -> void:
	_progress_overlay = ColorRect.new()
	(_progress_overlay as ColorRect).color = Color(UITheme.C_BG, 0.82)
	_progress_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_progress_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_progress_overlay.visible = false
	parent.add_child(_progress_overlay)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_progress_overlay.add_child(center)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", UITheme.SPACE_MD)
	vb.custom_minimum_size = Vector2(360, 0)
	center.add_child(vb)

	_progress_lbl = Label.new()
	_progress_lbl.text = "Computing site report…"
	_progress_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_progress_lbl.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	_progress_lbl.add_theme_font_size_override("font_size", UITheme.FONT_LG)
	vb.add_child(_progress_lbl)

	_progress_bar = ProgressBar.new()
	_progress_bar.min_value = 0.0
	_progress_bar.max_value = 1.0
	_progress_bar.value = 0.0
	_progress_bar.custom_minimum_size = Vector2(360, 18)
	_progress_bar.show_percentage = true
	vb.add_child(_progress_bar)

	var hint := Label.new()
	hint.text = "Analyzing a full year of hourly weather + physics for this site."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	hint.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	vb.add_child(hint)


# ---------------------------------------------------------------------------
# Open / close
# ---------------------------------------------------------------------------

func toggle() -> void:
	if visible:
		close()
	else:
		open()


func open() -> void:
	_main_node = _timeline.get("_main") if _timeline != null else _main_node
	if _main_node == null:
		_main_node = get_tree().current_scene
	visible = true
	move_to_front()
	CursorController.request_modal(MODAL_NAME, Callable(self, "close"))
	_begin(false)


func close() -> void:
	visible = false
	_waiting_weather = false
	set_process(false)
	if _builder != null and _builder.is_building():
		_builder.cancel()
		_building = false
	CursorController.release_modal(MODAL_NAME)


func is_open() -> bool:
	return visible


# ---------------------------------------------------------------------------
# Build orchestration
# ---------------------------------------------------------------------------

func _begin(force: bool) -> void:
	var refs := _resolve_refs()
	var main: Node = refs["main"]
	if main == null:
		_show_message("Site report needs an active map.")
		return
	var solar_ui: Node = refs["solar_ui"]
	var model: Object = refs["model"]
	var lat := float(main.get("latitude")) if main.get("latitude") != null else 0.0
	var lon := float(main.get("longitude")) if main.get("longitude") != null else 0.0
	var sim_year := _current_sim_year(main)

	var covers := WeatherService.has_method("covers") and bool(WeatherService.call("covers", lat, lon))
	var generated := WeatherService.has_method("is_generated_year") \
		and bool(WeatherService.call("is_generated_year", int(WeatherService.effective_year(sim_year))))
	var sig := SiteReportBuilder.signature_for(main, solar_ui, model, sim_year, covers, generated)

	_update_header(main, lat, lon)

	if not force:
		var cached := SiteReportBuilder.load_cached(lat, lon, sim_year, sig)
		if cached != null:
			_data = cached
			_populate()
			_set_progress_visible(false)
			return

	# Need to compute. Ensure weather coverage first (best effort), then build.
	_set_progress_visible(true)
	_progress_bar.value = 0.0
	if covers:
		_start_builder(main, solar_ui, model, sim_year)
	else:
		_progress_lbl.text = "Fetching weather for this site…"
		if WeatherService.has_method("request_weather"):
			WeatherService.call("request_weather", lat, lon, int(WeatherService.effective_year(sim_year)))
		_waiting_weather = true
		_weather_wait_left = WEATHER_WAIT_TIMEOUT_S
		set_process(true)


func _process(delta: float) -> void:
	if not _waiting_weather:
		set_process(false)
		return
	_weather_wait_left -= delta
	var refs := _resolve_refs()
	var main: Node = refs["main"]
	if main == null:
		_waiting_weather = false
		set_process(false)
		return
	var lat := float(main.get("latitude")) if main.get("latitude") != null else 0.0
	var lon := float(main.get("longitude")) if main.get("longitude") != null else 0.0
	var covers := WeatherService.has_method("covers") and bool(WeatherService.call("covers", lat, lon))
	if covers or _weather_wait_left <= 0.0:
		_waiting_weather = false
		set_process(false)
		_progress_lbl.text = "Computing site report…"
		_start_builder(main, refs["solar_ui"], refs["model"], _current_sim_year(main))


func _on_weather_ready(_lat: float, _lon: float, _year: int) -> void:
	if not visible or not _waiting_weather:
		return
	_waiting_weather = false
	set_process(false)
	var refs := _resolve_refs()
	var main: Node = refs["main"]
	if main == null:
		return
	_progress_lbl.text = "Computing site report…"
	_start_builder(main, refs["solar_ui"], refs["model"], _current_sim_year(main))


func _start_builder(main: Node, solar_ui: Node, model: Object, sim_year: int) -> void:
	if _builder == null:
		return
	_building = true
	var soi := get_node_or_null("/root/SoiService")
	var soi_r := float(soi.call("radius_m")) if soi != null and soi.has_method("radius_m") else 0.0
	var soi_a := float(soi.call("area_m2")) if soi != null and soi.has_method("area_m2") else 0.0
	var label := _site_label(main)
	_builder.start(main, solar_ui, model, sim_year, label, soi_r, soi_a)


func _on_build_progress(frac: float) -> void:
	if _progress_bar != null:
		_progress_bar.value = frac


func _on_report_ready(data: SiteReportData) -> void:
	_building = false
	_data = data
	_populate()
	_set_progress_visible(false)


func _on_recompute_pressed() -> void:
	if _building or _waiting_weather:
		return
	_begin(true)


# ---------------------------------------------------------------------------
# Populate (labels + chart redraw)
# ---------------------------------------------------------------------------

func _populate() -> void:
	if _data == null:
		return
	var d := _data
	var src_txt: String = {"archive": "🌎 Archive %d" % d.year,
		"generated": "🔮 Generated %d" % d.year,
		"synthetic": "🔄 Synthetic"}.get(d.weather_source, d.weather_source)
	_source_chip.text = src_txt
	var chip_col := UITheme.C_INFO
	if d.weather_source == "generated":
		chip_col = UITheme.C_LAVENDER
	elif d.weather_source == "synthetic":
		chip_col = UITheme.C_WARN
	_source_chip.add_theme_color_override("font_color", chip_col)

	# Solar resource.
	_solar_stat.text = "[b]%.0f[/b] kWh/m²·yr   ·   [b]%.1f[/b] peak-sun-h/day   ·   climatology [b]%.1f[/b] kWh/m²·day (%s)" % [
		d.solar_annual_kwh_m2, d.solar_peak_sun_hours,
		d.ghi_climatology_kwh_m2_day, d.ghi_zone_label]

	# PV.
	if d.pv_peak_kw > 0.0:
		_pv_stat.text = "[b]%.0f[/b] kWh/yr  ·  [b]%.1f[/b] kWp (%d panels)  ·  capacity factor [b]%.1f%%[/b]  ·  tilt %.0f° az %.0f°" % [
			d.pv_annual_kwh, d.pv_peak_kw, d.pv_panel_count,
			d.pv_capacity_factor * 100.0, d.pv_panel_tilt_deg, d.pv_panel_azimuth_deg]
	else:
		_pv_stat.text = "[color=#8090a8]No PV panels in the current graph — add panels to see production potential.[/color]"

	# Wind.
	if d.wind_turbine_count > 0:
		_wind_stat.text = "[b]%.0f[/b] kWh/yr  ·  %d turbine(s), [b]%.1f[/b] kW rated  ·  capacity factor [b]%.1f%%[/b]  ·  mean wind [b]%.1f[/b] m/s" % [
			d.wind_annual_kwh, d.wind_turbine_count, d.wind_rated_kw,
			d.wind_capacity_factor * 100.0, d.wind_mean_speed_ms]
	else:
		_wind_stat.text = "[color=#8090a8]No wind turbines in the graph — mean site wind [b]%.1f[/b] m/s. Add a turbine to estimate yield.[/color]" % d.wind_mean_speed_ms

	# Precip.
	_precip_stat.text = "[b]%.0f[/b] mm/yr  ·  [b]%d[/b] wet days" % [
		d.precip_annual_mm, d.precip_wet_days_total]

	# Temp.
	_temp_stat.text = "mean [b]%.1f[/b]°C  ·  range [b]%.0f[/b]…[b]%.0f[/b]°C" % [
		d.temp_annual_mean_c, d.temp_annual_min_c, d.temp_annual_max_c]

	# Hydro card visibility.
	_hydro_card.visible = d.hydro_count > 0
	if d.hydro_count > 0:
		_hydro_stat.text = "[b]%.0f[/b] kWh/yr  ·  %d hydro unit(s)  (precipitation-scaled seasonal flow)" % [
			d.hydro_annual_kwh, d.hydro_count]

	_footnote_lbl.text = ("Representative year %d for %.4f, %.4f. PV uses the graph's global tilt/azimuth "
		+ "and ignores 3D terrain shading (live-only). Hover any chart for month detail. "
		+ "Multi-year / climate-scenario reports are a future extension.") % [d.year, d.latitude, d.longitude]

	for cv in [_solar_canvas, _pv_canvas, _wind_rose_canvas, _wind_canvas,
			_precip_canvas, _temp_canvas, _hydro_canvas]:
		if cv != null:
			cv.queue_redraw()


# ---------------------------------------------------------------------------
# Chart draw callbacks
# ---------------------------------------------------------------------------

func _font() -> Font:
	return ThemeDB.fallback_font


func _draw_solar() -> void:
	if _data == null:
		return
	SiteReportCharts.draw_monthly_bars(_solar_canvas, _data.solar_monthly_kwh_m2,
		UITheme.C_GOLD, "kWh/m²", _font(), _hover_of(_solar_canvas), "%.0f")


func _draw_pv() -> void:
	if _data == null:
		return
	SiteReportCharts.draw_monthly_bars(_pv_canvas, _data.pv_monthly_kwh,
		UITheme.C_PRIMARY, "kWh", _font(), _hover_of(_pv_canvas), "%.0f")


func _draw_windrose() -> void:
	if _data == null:
		return
	SiteReportCharts.draw_windrose(_wind_rose_canvas, _data.windrose_freq,
		_data.windrose_mean_ms, _font(), _hover_of(_wind_rose_canvas))


func _draw_wind() -> void:
	if _data == null:
		return
	SiteReportCharts.draw_monthly_bars(_wind_canvas, _data.wind_monthly_kwh,
		UITheme.C_LAVENDER, "kWh", _font(), _hover_of(_wind_canvas), "%.0f")


func _draw_precip() -> void:
	if _data == null:
		return
	SiteReportCharts.draw_monthly_bars(_precip_canvas, _data.precip_monthly_mm,
		Color(0.25, 0.55, 1.0, 1.0), "mm", _font(), _hover_of(_precip_canvas), "%.0f")


func _draw_temp() -> void:
	if _data == null:
		return
	SiteReportCharts.draw_temp_band(_temp_canvas, _data.temp_monthly_mean_c,
		_data.temp_monthly_min_c, _data.temp_monthly_max_c, _font(), _hover_of(_temp_canvas))


func _draw_hydro() -> void:
	if _data == null:
		return
	SiteReportCharts.draw_monthly_bars(_hydro_canvas, _data.hydro_monthly_kwh,
		UITheme.C_GREEN, "kWh", _font(), _hover_of(_hydro_canvas), "%.0f")


# ---------------------------------------------------------------------------
# Hover interactivity
# ---------------------------------------------------------------------------

func _hover_of(canvas: Control) -> int:
	if canvas == null:
		return -1
	return int(_hover.get(canvas.get_instance_id(), -1))


func _on_canvas_input(event: InputEvent, canvas: Control) -> void:
	if event is not InputEventMouseMotion:
		return
	var mm := event as InputEventMouseMotion
	var idx: int
	if canvas == _wind_rose_canvas and _data != null:
		idx = SiteReportCharts.windrose_sector_at(canvas, mm.position, _data.windrose_sectors)
	else:
		idx = _month_at_x(canvas, mm.position.x)
	var key := canvas.get_instance_id()
	if int(_hover.get(key, -1)) != idx:
		_hover[key] = idx
		canvas.queue_redraw()


func _on_canvas_exit(canvas: Control) -> void:
	var key := canvas.get_instance_id()
	if int(_hover.get(key, -1)) != -1:
		_hover[key] = -1
		canvas.queue_redraw()


func _month_at_x(canvas: Control, x: float) -> int:
	var pad := 6.0
	var plot_w := canvas.size.x - pad * 2.0
	if plot_w <= 0.0:
		return -1
	var rel := x - pad
	if rel < 0.0 or rel > plot_w:
		return -1
	return clampi(int(rel / (plot_w / 12.0)), 0, 11)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _resolve_refs() -> Dictionary:
	var main := _main_node
	if main == null:
		main = get_tree().current_scene
	var solar_ui: Node = null
	var sgv: Node = null
	if main != null:
		solar_ui = main.get_node_or_null("UILayer/SolarUI")
		sgv = main.get_node_or_null("UILayer/SystemGraphView")
	var model: Object = null
	if sgv != null and "model" in sgv:
		model = sgv.get("model")
	return {"main": main, "solar_ui": solar_ui, "model": model, "sgv": sgv}


func _current_sim_year(main: Node) -> int:
	var y: Variant = main.get("year")
	if y != null:
		return int(y)
	return int(Time.get_date_dict_from_system().year)


func _site_label(main: Node) -> String:
	var lat := float(main.get("latitude")) if main.get("latitude") != null else 0.0
	var lon := float(main.get("longitude")) if main.get("longitude") != null else 0.0
	# Prefer the persisted place label from location_prefs.cfg.
	if main.has_method("_location_prefs_section"):
		var cfg := ConfigFile.new()
		if cfg.load("user://location_prefs.cfg") == OK:
			var section := str(main.call("_location_prefs_section"))
			var lbl := str(cfg.get_value(section, "label", ""))
			if not lbl.is_empty():
				return lbl
	return "%.4f, %.4f" % [lat, lon]


func _update_header(main: Node, lat: float, lon: float) -> void:
	if _header_lbl == null:
		return
	var label := _site_label(main)
	_header_lbl.text = "📊 Site Report — %s" % label
	_sub_lbl.text = "%.4f, %.4f" % [lat, lon]


func _show_message(msg: String) -> void:
	_set_progress_visible(true)
	_progress_bar.visible = false
	_progress_lbl.text = msg


func _set_progress_visible(v: bool) -> void:
	if _progress_overlay != null:
		_progress_overlay.visible = v
	if _progress_bar != null:
		_progress_bar.visible = v


func _on_backdrop_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			close()
