class_name WeatherCardUI
extends PanelContainer

## Floating weather card — centered just above the timeline bar.
##
## Replaces the cramped weather rows that used to live inside TimelineUI's left
## cluster. SolarUI keeps pushing weather through TimelineUI (node-name contract
## unchanged); TimelineUI forwards to this card. All inputs are SI units;
## imperial conversion happens here (card owns the °F/°C pref, persisted to the
## same `units/imperial` key in user://ui_prefs.cfg).
##
## Layout: header row (condition icon · headline temp · source chip · °F/°C ·
## HA-link · collapse) over a row of five accented stat tiles (RAD / RH% /
## WIND / RAIN / 24H). Collapsed → a slim pill (icon + temp + source glyph).
## The card hides while the system graph is open (graph has its own dashboard).

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

const CARD_WIDTH := 400.0
const GAP_ABOVE_TIMELINE := 8.0
const MONTH_NAMES : Array = ["Jan","Feb","Mar","Apr","May","Jun",
							  "Jul","Aug","Sep","Oct","Nov","Dec"]

var _use_imperial: bool = true
var _collapsed: bool = false

var _main: Node = null
var _solar_ui: Node = null
var _timeline: Node = null

# Header widgets
var _icon_lbl: Label = null
var _temp_lbl: Label = null
var _source_chip: Label = null
var _unit_btn: Button = null
var _link_btn: Button = null
var _collapse_btn: Button = null
# Stat tile value labels
var _rad_lbl: Label = null
var _hum_lbl: Label = null
var _wind_lbl: Label = null
var _rain_lbl: Label = null
var _rain24_lbl: Label = null
var _stat_row: Control = null

# Last raw SI values so unit toggles re-render without waiting for a push.
var _last := {"rad": NAN, "temp_c": NAN, "hum": NAN, "wind_ms": NAN,
		"wind_deg": NAN, "rain_mmh": NAN, "rain_24h_mm": NAN}

# Provenance tooltip (own panel on the UILayer so the card doesn't clip it).
var _tip_panel: PanelContainer = null
var _tip_var_lbl: Label = null
var _tip_val_lbl: Label = null
var _tip_time_lbl: Label = null
var _tip_src_lbl: Label = null
var _tip_stn_lbl: Label = null

var _graph_poll_accum: float = 0.0


func _ready() -> void:
	name = "WeatherCardUI"
	mouse_filter = Control.MOUSE_FILTER_STOP
	_load_prefs()
	_apply_card_style()
	_build_content()
	_apply_collapsed_state()
	call_deferred("refresh_position")


func _process(delta: float) -> void:
	# Hide while the system graph view is open (it has its own dashboard and
	# docks fight for the same clearance above the bar).
	_graph_poll_accum += delta
	if _graph_poll_accum < 0.25:
		return
	_graph_poll_accum = 0.0
	var graph: Node = get_parent().get_node_or_null("SystemGraphView") if get_parent() != null else null
	var want_hidden: bool = graph is CanvasItem and (graph as CanvasItem).visible
	if visible == want_hidden:
		visible = not want_hidden


# ---------------------------------------------------------------------------
# Public API (fed by TimelineUI forwards)
# ---------------------------------------------------------------------------

func set_weather_stats(rad: float, temp_c: float, hum: float,
		wind_ms: float, wind_deg: float, rain_mmh: float, rain_24h_mm: float) -> void:
	_last = {"rad": rad, "temp_c": temp_c, "hum": hum, "wind_ms": wind_ms,
			"wind_deg": wind_deg, "rain_mmh": rain_mmh, "rain_24h_mm": rain_24h_mm}
	_render_stats()


func set_source_display(caption: String, mod: Color, tip: String) -> void:
	if _source_chip == null:
		return
	_source_chip.text = caption
	_source_chip.tooltip_text = tip
	_source_chip.add_theme_color_override("font_color", mod)
	var sb := UITheme.chip_style(mod)
	_source_chip.add_theme_stylebox_override("normal", sb)


func set_link_display(tip: String, mod: Color) -> void:
	if _link_btn != null:
		_link_btn.tooltip_text = tip
		_link_btn.add_theme_color_override("font_color", mod)


func set_collapsed(on: bool) -> void:
	if _collapsed == on:
		return
	_collapsed = on
	_apply_collapsed_state()
	_save_prefs()
	call_deferred("refresh_position")


## Re-anchor above the Solar UI on the left side.
func refresh_position() -> void:
	anchor_left = 0.0
	anchor_right = 0.0
	anchor_top = 0.0
	anchor_bottom = 0.0
	grow_horizontal = Control.GROW_DIRECTION_END
	grow_vertical = Control.GROW_DIRECTION_END
	
	var w := 380.0 # Exactly matches SolarUI width
	offset_left = 12.0
	offset_right = offset_left + w
	offset_top = 10.0
	var h := get_combined_minimum_size().y
	offset_bottom = offset_top + h
	
	# Push SolarUI down just below the weather card
	_ensure_solar_ref()
	if is_instance_valid(_solar_ui):
		_solar_ui.offset_top = offset_bottom + 10.0
		# Preserve its height of 610.0 from its original layout (default top 10, bottom 620)
		_solar_ui.offset_bottom = _solar_ui.offset_top + 610.0


# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

func _apply_card_style() -> void:
	var sb := UITheme.panel_style(0.92)
	# Family resemblance with the bar: bright primary top edge.
	sb.border_width_top = 2
	sb.border_color = Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.55)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 12.0
	sb.content_margin_right = 12.0
	sb.content_margin_top = 6.0
	sb.content_margin_bottom = 7.0
	add_theme_stylebox_override("panel", sb)


func _build_content() -> void:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	add_child(col)

	# ── Header row ──
	var head := HBoxContainer.new()
	head.alignment = BoxContainer.ALIGNMENT_BEGIN
	head.add_theme_constant_override("separation", 8)
	col.add_child(head)

	_icon_lbl = Label.new()
	_icon_lbl.text = "☀"
	_icon_lbl.add_theme_font_size_override("font_size", 30)
	_icon_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	head.add_child(_icon_lbl)

	_temp_lbl = Label.new()
	_temp_lbl.text = "—"
	_temp_lbl.add_theme_font_size_override("font_size", 30)
	_temp_lbl.add_theme_color_override("font_color", Color(1.00, 0.55, 0.30, 1.0))
	_temp_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_temp_lbl.tooltip_text = "Air temperature (hover a tile below for data provenance)"
	_temp_lbl.mouse_filter = Control.MOUSE_FILTER_STOP
	_temp_lbl.mouse_entered.connect(_on_tile_entered.bind("temp", _temp_lbl))
	_temp_lbl.mouse_exited.connect(_on_tile_exited)
	head.add_child(_temp_lbl)

	_source_chip = Label.new()
	_source_chip.text = "☀ —"
	_source_chip.add_theme_font_size_override("font_size", 11)
	_source_chip.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_source_chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_source_chip.tooltip_text = "Active weather source"
	_source_chip.mouse_filter = Control.MOUSE_FILTER_PASS
	_source_chip.add_theme_stylebox_override("normal", UITheme.chip_style(C_TEXT_S))
	head.add_child(_source_chip)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(spacer)

	_unit_btn = _mk_flat_btn("°F" if _use_imperial else "°C", _on_unit_pressed,
		"Switch units: imperial (°F, mph, in) ↔ metric (°C, m/s, mm)")
	_unit_btn.add_theme_color_override("font_color", C_AMBER)
	_unit_btn.custom_minimum_size = Vector2(30, 22)
	head.add_child(_unit_btn)

	_link_btn = _mk_flat_btn("🔗", _on_link_pressed,
		"Link this location's weather to a Home Assistant feed")
	_link_btn.add_theme_font_size_override("font_size", 13)
	head.add_child(_link_btn)

	_collapse_btn = _mk_flat_btn("▾", _on_collapse_pressed, "Collapse weather card")
	_collapse_btn.custom_minimum_size = Vector2(24, 22)
	head.add_child(_collapse_btn)

	# ── Stat tile row ──
	_stat_row = HBoxContainer.new()
	(_stat_row as HBoxContainer).alignment = BoxContainer.ALIGNMENT_CENTER
	(_stat_row as HBoxContainer).add_theme_constant_override("separation", 0)
	col.add_child(_stat_row)

	_rad_lbl = _mk_stat_tile("rad", "W/m²", C_GOLD, 66)
	_mk_vsep()
	_hum_lbl = _mk_stat_tile("hum", "RH%", Color(0.40, 0.80, 1.00, 1.0), 56)
	_mk_vsep()
	_wind_lbl = _mk_stat_tile("wind", "WIND", C_GREEN, 92)
	_mk_vsep()
	_rain_lbl = _mk_stat_tile("rain", "RAIN", C_PRIMARY, 62)
	_mk_vsep()
	_rain24_lbl = _mk_stat_tile("rain24", "24H", C_LAVENDER, 62)


## Stat tile: small muted header over a large accented value; hover shows the
## provenance tooltip. Values get 15pt (up from the old cramped 13pt tiles).
func _mk_stat_tile(key: String, header: String, val_color: Color, min_w: int) -> Label:
	var tile := VBoxContainer.new()
	tile.alignment = BoxContainer.ALIGNMENT_CENTER
	tile.add_theme_constant_override("separation", 1)
	tile.custom_minimum_size = Vector2(min_w, 0)
	tile.mouse_filter = Control.MOUSE_FILTER_STOP

	var hdr := Label.new()
	hdr.text = header
	hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hdr.add_theme_color_override("font_color", C_TEXT_M)
	hdr.add_theme_font_size_override("font_size", 9)
	hdr.mouse_filter = Control.MOUSE_FILTER_PASS
	tile.add_child(hdr)

	var val := Label.new()
	val.text = "—"
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	val.add_theme_color_override("font_color", val_color)
	val.add_theme_font_size_override("font_size", 15)
	val.mouse_filter = Control.MOUSE_FILTER_PASS
	tile.add_child(val)

	_stat_row.add_child(tile)
	tile.mouse_entered.connect(_on_tile_entered.bind(key, tile))
	tile.mouse_exited.connect(_on_tile_exited)
	return val


func _mk_vsep() -> void:
	var sep := ColorRect.new()
	sep.color = Color(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.30)
	sep.custom_minimum_size = Vector2(1, 22)
	sep.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", 5)
	m.add_theme_constant_override("margin_right", 5)
	m.add_child(sep)
	_stat_row.add_child(m)


func _mk_flat_btn(text_: String, callback: Callable, tip: String) -> Button:
	var btn := Button.new()
	btn.text = text_
	btn.flat = true
	btn.focus_mode = Control.FOCUS_NONE
	btn.tooltip_text = tip
	btn.add_theme_font_size_override("font_size", 11)
	btn.pressed.connect(callback)
	return btn


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

func _render_stats() -> void:
	var rad: float = float(_last.get("rad", NAN))
	var temp_c: float = float(_last.get("temp_c", NAN))
	var hum: float = float(_last.get("hum", NAN))
	var wind_ms: float = float(_last.get("wind_ms", NAN))
	var wind_deg: float = float(_last.get("wind_deg", NAN))
	var rain_mmh: float = float(_last.get("rain_mmh", NAN))
	var rain_24h: float = float(_last.get("rain_24h_mm", NAN))

	if _icon_lbl != null:
		_icon_lbl.text = _condition_icon(rad, rain_mmh)
	if _temp_lbl != null:
		if is_nan(temp_c):
			_temp_lbl.text = "—"
		elif _use_imperial:
			_temp_lbl.text = "%.0f°F" % (temp_c * 9.0 / 5.0 + 32.0)
		else:
			_temp_lbl.text = "%.0f°C" % temp_c
	if _rad_lbl != null:
		_rad_lbl.text = "—" if is_nan(rad) else "%.0f" % rad
	if _hum_lbl != null:
		_hum_lbl.text = "—" if is_nan(hum) else "%.0f%%" % hum
	if _wind_lbl != null:
		if is_nan(wind_ms):
			_wind_lbl.text = "—"
		else:
			var spd := "%.0f mph" % (wind_ms * 2.23694) if _use_imperial else "%.1f m/s" % wind_ms
			if not is_nan(wind_deg):
				spd += " " + _deg_to_compass(wind_deg)
			_wind_lbl.text = spd
	if _rain_lbl != null:
		if is_nan(rain_mmh) or rain_mmh < 0.05:
			_rain_lbl.text = "dry"
		elif _use_imperial:
			_rain_lbl.text = '%.2f"' % (rain_mmh / 25.4)
		else:
			_rain_lbl.text = "%.1fmm" % rain_mmh
	if _rain24_lbl != null:
		if is_nan(rain_24h):
			_rain24_lbl.text = "—"
		elif _use_imperial:
			_rain24_lbl.text = '%.2f"' % (rain_24h / 25.4)
		else:
			_rain24_lbl.text = "%.1fmm" % rain_24h


## First-order condition glyph from radiation + rain (no dedicated code from
## the weather service yet): rain → 🌧, bright → ☀, dim daylight → ⛅, dark → 🌙.
func _condition_icon(rad: float, rain_mmh: float) -> String:
	if not is_nan(rain_mmh) and rain_mmh >= 0.05:
		return "🌧"
	if is_nan(rad):
		return "☀"
	if rad >= 400.0:
		return "☀"
	if rad >= 60.0:
		return "⛅"
	return "🌙"


static func _deg_to_compass(deg: float) -> String:
	var dirs := ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
	return dirs[int(round(deg / 45.0)) % 8]


func _apply_collapsed_state() -> void:
	if _stat_row != null:
		_stat_row.visible = not _collapsed
	if _collapse_btn != null:
		_collapse_btn.text = "▴" if _collapsed else "▾"
		_collapse_btn.tooltip_text = "Expand weather card" if _collapsed else "Collapse weather card"
	if _temp_lbl != null:
		_temp_lbl.add_theme_font_size_override("font_size", 18 if _collapsed else 30)
	if _icon_lbl != null:
		_icon_lbl.add_theme_font_size_override("font_size", 18 if _collapsed else 30)
	if _link_btn != null:
		_link_btn.visible = not _collapsed
	if _unit_btn != null:
		_unit_btn.visible = not _collapsed
	reset_size()


# ---------------------------------------------------------------------------
# Interaction
# ---------------------------------------------------------------------------

func _on_unit_pressed() -> void:
	_use_imperial = not _use_imperial
	if _unit_btn != null:
		_unit_btn.text = "°F" if _use_imperial else "°C"
	_render_stats()
	_save_prefs()


func _on_link_pressed() -> void:
	_ensure_solar_ref()
	if _solar_ui != null and _solar_ui.has_method("show_weather_link_menu_for_anchor"):
		_solar_ui.call("show_weather_link_menu_for_anchor", _link_btn)


func _on_collapse_pressed() -> void:
	set_collapsed(not _collapsed)


func _load_prefs() -> void:
	var cfg := ConfigFile.new()
	if cfg.load("user://ui_prefs.cfg") == OK:
		_use_imperial = bool(cfg.get_value("units", "imperial", true))
		_collapsed = bool(cfg.get_value("weather_card", "collapsed", false))


func _save_prefs() -> void:
	var cfg := ConfigFile.new()
	cfg.load("user://ui_prefs.cfg")  # preserve other saved values
	cfg.set_value("units", "imperial", _use_imperial)
	cfg.set_value("weather_card", "collapsed", _collapsed)
	cfg.save("user://ui_prefs.cfg")


func _ensure_solar_ref() -> void:
	if is_instance_valid(_solar_ui):
		return
	var p := get_parent()
	if p != null:
		_solar_ui = p.get_node_or_null("SolarUI")


func _ensure_timeline_ref() -> void:
	if is_instance_valid(_timeline):
		return
	var p := get_parent()
	if p != null:
		_timeline = p.get_node_or_null("TimelineUI")


func _find_main() -> Node:
	if is_instance_valid(_main):
		return _main
	var tree := get_tree()
	if tree == null or tree.root == null:
		return null
	_main = tree.root.get_node_or_null("Main")
	if _main == null:
		for child in tree.root.get_children():
			if child.name == "Main" or child.has_method("get_absolute_hours"):
				_main = child
				break
	return _main


# ---------------------------------------------------------------------------
# Provenance tooltip (ported from TimelineUI's stat tiles)
# ---------------------------------------------------------------------------

func _setup_tooltip() -> void:
	if _tip_panel != null:
		return
	_tip_panel = PanelContainer.new()
	_tip_panel.visible = false
	_tip_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tip_panel.custom_minimum_size = Vector2(230, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(C_PANEL.r, C_PANEL.g, C_PANEL.b, 0.96)
	sb.border_color = C_BORDER
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(8.0)
	_tip_panel.add_theme_stylebox_override("panel", sb)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 3)
	_tip_panel.add_child(vbox)
	_tip_var_lbl = _mk_tip_label(vbox, C_TEXT_M, 10)
	_tip_val_lbl = _mk_tip_label(vbox, C_TEXT, 14)
	_tip_time_lbl = _mk_tip_label(vbox, C_TEXT_S, 10)
	_tip_src_lbl = _mk_tip_label(vbox, C_PRIMARY, 10)
	_tip_stn_lbl = _mk_tip_label(vbox, C_TEXT_M, 10)

	var ui_layer := get_parent()
	if ui_layer != null:
		ui_layer.add_child(_tip_panel)
	else:
		add_child(_tip_panel)


func _mk_tip_label(parent: Control, color: Color, font_size: int) -> Label:
	var lbl := Label.new()
	lbl.add_theme_color_override("font_color", color)
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(lbl)
	return lbl


func _on_tile_entered(key: String, anchor: Control) -> void:
	_show_tooltip(key, anchor)


func _on_tile_exited() -> void:
	if _tip_panel != null:
		_tip_panel.visible = false


func _show_tooltip(key: String, anchor: Control) -> void:
	_setup_tooltip()
	var main := _find_main()
	if _tip_panel == null or main == null:
		return
	var month := int(main.get("month") if main.get("month") != null else 1)
	var day := int(main.get("day") if main.get("day") != null else 1)
	var hour := float(main.get("day_time") if main.get("day_time") != null else 0.0)
	var year_v: Variant = main.get("year")
	var sim_year := int(year_v) if year_v != null else 0

	_ensure_solar_ref()
	var ha_active := false
	if _solar_ui != null:
		var wlm: Variant = _solar_ui.get("_weather_live_mode")
		ha_active = bool(wlm) if wlm != null else false

	var source := WeatherService.get_sample_source(month, day, hour, ha_active)
	var src_str: String
	match source:
		"forecast":
			src_str = "Open-Meteo GFS Forecast  (GFS/ERA5 blend)"
		"ha":
			src_str = "Home Assistant"
		_:
			src_str = "Open-Meteo ERA5 Archive  (~25 km grid)"

	var mo_name: String = MONTH_NAMES[clampi(month - 1, 0, 11)]
	var h_int := int(hour)
	var m_int := int((hour - h_int) * 60.0)
	var time_str := "%s %d %d · %02d:%02d local" % [mo_name, day, sim_year, h_int, m_int]

	var lat := float(main.get("latitude") if main.get("latitude") != null else 0.0)
	var lon := float(main.get("longitude") if main.get("longitude") != null else 0.0)
	var stn_name := NwsZoneService.get_station_name(lat, lon)
	var stn_icao := NwsZoneService.get_station_icao(lat, lon)
	var stn_str: String
	if stn_name.is_empty():
		stn_str = "Nearest NWS station:  — (loading…)"
	else:
		stn_str = "Nearest NWS station:  %s  (%s)" % [stn_name, stn_icao]

	var var_names := {
		"rad": "SOLAR RADIATION", "temp": "TEMPERATURE",
		"hum": "HUMIDITY", "wind": "WIND SPEED",
		"rain": "RAINFALL RATE", "rain24": "24H RAINFALL",
	}
	_tip_var_lbl.text = var_names.get(key, key.to_upper())
	_tip_val_lbl.add_theme_color_override("font_color", C_TEXT)
	_tip_val_lbl.text = _value_str_for_key(key, month, day, hour)
	_tip_time_lbl.text = time_str
	_tip_src_lbl.text = src_str
	_tip_stn_lbl.text = stn_str

	_tip_panel.visible = true
	_tip_panel.reset_size()
	var panel_sz := _tip_panel.get_combined_minimum_size()
	var anchor_rect := anchor.get_global_rect()
	var vp_sz := get_viewport().get_visible_rect().size
	var px := clampf(anchor_rect.position.x, 4.0, vp_sz.x - panel_sz.x - 4.0)
	var py := clampf(anchor_rect.position.y - panel_sz.y - 6.0, 4.0, vp_sz.y - panel_sz.y - 4.0)
	_tip_panel.position = Vector2(px, py)


func _value_str_for_key(key: String, month: int, day: int, hour: float) -> String:
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
			var d := WeatherService.wind_direction_deg(month, day, hour)
			var dir_str := "  " + _deg_to_compass(d) if not is_nan(d) else ""
			return ("%.0f mph  (%.1f m/s)%s" % [v * 2.23694, v, dir_str]) if _use_imperial \
					else ("%.1f m/s%s" % [v, dir_str])
		"rain":
			var v := WeatherService.rain_rate_mmh(month, day, hour)
			if is_nan(v) or v < 0.05: return "dry"
			return '%.2f"/hr' % (v / 25.4) if _use_imperial else "%.1f mm/h" % v
		"rain24":
			var v := WeatherService.rain_24h_mm(month, day, hour)
			if is_nan(v): return "—"
			return '%.2f" (24h)' % (v / 25.4) if _use_imperial else "%.1f mm (24h)" % v
	return "—"
