extends Control

## Live Solar, Battery & Inverter Telemetry dashboard for secondary monitors.
##
## Reads from the active scene's `SolarUI` and `AcPowerBus` at 4 Hz without
## duplicating simulation physics, and adapts cleanly between landscape (2×2
## grid) and portrait (single vertical stack) monitors.

const REFRESH_S := 0.25

var _main: Node = null
var _accum := 0.0
var _grid: GridContainer = null
var _sub_lbl: Label = null
var _pv_val: Label = null
var _pv_sub: Label = null
var _soc_val: Label = null
var _soc_bar: ProgressBar = null
var _soc_sub: Label = null
var _load_val: Label = null
var _load_sub: Label = null
var _net_val: Label = null
var _net_sub: Label = null


func setup(main: Node) -> void:
	_main = main
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	_refresh()


func _build() -> void:
	var bg := ColorRect.new()
	bg.color = UITheme.C_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_top", 52)
	margin.add_theme_constant_override("margin_bottom", 24)
	add_child(margin)

	var root_v := VBoxContainer.new()
	root_v.add_theme_constant_override("separation", 16)
	margin.add_child(root_v)

	var title := Label.new()
	title.text = "☀ Site Energy & Inverter Telemetry"
	title.add_theme_font_override("font", UITheme.font("semibold"))
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	root_v.add_child(title)

	_sub_lbl = Label.new()
	_sub_lbl.text = "Live digital-twin readout"
	_sub_lbl.add_theme_font_size_override("font_size", UITheme.FONT_MD)
	_sub_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	root_v.add_child(_sub_lbl)

	_grid = GridContainer.new()
	_grid.columns = 2
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_grid.add_theme_constant_override("h_separation", 16)
	_grid.add_theme_constant_override("v_separation", 16)
	root_v.add_child(_grid)

	var c_pv := _make_card("PV Solar Input", UITheme.C_GOLD)
	_pv_val = c_pv[1]
	_pv_sub = c_pv[2]

	var c_soc := _make_card("Battery State of Charge", UITheme.C_GREEN)
	_soc_val = c_soc[1]
	_soc_bar = ProgressBar.new()
	_soc_bar.min_value = 0.0
	_soc_bar.max_value = 100.0
	_soc_bar.show_percentage = false
	_soc_bar.custom_minimum_size = Vector2(0, 18)
	(c_soc[0] as VBoxContainer).add_child(_soc_bar)
	(c_soc[0] as VBoxContainer).move_child(_soc_bar, 2)
	_soc_sub = c_soc[2]

	var c_load := _make_card("AC & DC Site Load", UITheme.C_PRIMARY)
	_load_val = c_load[1]
	_load_sub = c_load[2]

	var c_net := _make_card("Net Battery Power", UITheme.C_LAVENDER)
	_net_val = c_net[1]
	_net_sub = c_net[2]

	resized.connect(_update_columns)
	call_deferred("_update_columns")


func _make_card(heading: String, accent: Color) -> Array:
	var p := PanelContainer.new()
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.size_flags_vertical = Control.SIZE_EXPAND_FILL
	p.add_theme_stylebox_override("panel", UITheme.card_style())
	_grid.add_child(p)
	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 10)
	p.add_child(vb)
	var h := Label.new()
	h.text = heading
	h.add_theme_font_size_override("font_size", UITheme.FONT_LG)
	h.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	vb.add_child(h)
	var v := Label.new()
	v.text = "—"
	v.add_theme_font_override("font", UITheme.font("semibold", true))
	v.add_theme_font_size_override("font_size", 46)
	v.add_theme_color_override("font_color", accent)
	vb.add_child(v)
	var sub := Label.new()
	sub.text = ""
	sub.add_theme_font_size_override("font_size", UITheme.FONT_MD)
	sub.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	vb.add_child(sub)
	return [vb, v, sub]


func _update_columns() -> void:
	if _grid != null:
		_grid.columns = 1 if size.y > size.x else 2


func _process(delta: float) -> void:
	_accum += delta
	if _accum < REFRESH_S:
		return
	_accum = 0.0
	_refresh()


func _refresh() -> void:
	var sui := ServiceLocator.solar_ui()
	var pv_w := 0.0
	var load_w := 0.0
	var soc_pct := 0.0
	var cap_kwh := 0.0
	var daily_kwh := 0.0
	if sui != null and is_instance_valid(sui):
		pv_w = float(sui.get("current_total_power_w") if sui.get("current_total_power_w") != null else 0.0)
		if pv_w == 0.0 and sui.get("total_solar_power") != null:
			pv_w = float(sui.get("total_solar_power"))
		load_w = float(sui.get("current_load_w") if sui.get("current_load_w") != null else 0.0)
		soc_pct = float(sui.get("battery_soc") if sui.get("battery_soc") != null else 0.0)
		if soc_pct <= 1.0 and soc_pct > 0.0 and sui.get("battery_soc_percent") != null:
			soc_pct = float(sui.get("battery_soc_percent"))
		elif soc_pct <= 1.0 and sui.get("battery_soc") != null:
			soc_pct *= 100.0
		cap_kwh = float(sui.get("battery_capacity_kwh") if sui.get("battery_capacity_kwh") != null else 0.0)
		daily_kwh = float(sui.get("daily_energy_kwh") if sui.get("daily_energy_kwh") != null else 0.0)
	if AcPowerBus != null and load_w <= 0.0 and AcPowerBus.get("total_load_w") != null:
		load_w = float(AcPowerBus.get("total_load_w"))
	var net_w := pv_w - load_w
	if _pv_val != null:
		_pv_val.text = _fmt_power(pv_w)
		_pv_sub.text = I18n.f("Today: {daily_kwh} kWh", {"daily_kwh": "%.2f" % daily_kwh}) if daily_kwh > 0.0 else "Simulated PV arrays"
	if _soc_val != null:
		_soc_val.text = "%.1f %%" % clampf(soc_pct, 0.0, 100.0)
		_soc_bar.value = clampf(soc_pct, 0.0, 100.0)
		_soc_sub.text = I18n.f("Bank capacity: {cap_kwh} kWh", {"cap_kwh": "%.1f" % cap_kwh}) if cap_kwh > 0.0 else "Site battery bank"
	if _load_val != null:
		_load_val.text = _fmt_power(load_w)
		_load_sub.text = "Active AC + DC consumers"
	if _net_val != null:
		_net_val.text = ("%s%s" % ["+" if net_w >= 0.0 else "−", _fmt_power(absf(net_w))])
		_net_val.add_theme_color_override("font_color", UITheme.C_OK if net_w >= -1.0 else UITheme.C_AMBER)
		_net_sub.text = "Charging bank" if net_w > 5.0 else ("Discharging bank" if net_w < -5.0 else "Balanced")
	if _main != null and is_instance_valid(_main) and _sub_lbl != null:
		var dt := float(_main.get("day_time") if _main.get("day_time") != null else 12.0)
		var hh := int(floor(dt)) % 24
		var mm := int(floor((dt - floor(dt)) * 60.0))
		_sub_lbl.text = I18n.f("Local sim time {hh}:{mm}  ·  Updated live", {"hh": "%02d" % hh, "mm": "%02d" % mm})


static func _fmt_power(w: float) -> String:
	if absf(w) >= 1000.0:
		return "%.2f kW" % (w / 1000.0)
	return "%.0f W" % w
