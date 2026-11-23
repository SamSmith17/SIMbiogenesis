extends Node

## Patterns (plans/FLOW_VIZ_PLAN.md Part D): the days this world has recorded,
## read three ways.
##   - Hour by hour: a carpet plot (a column per day, the hours running
##     down) of the battery, solar, load, net power or any store's fill.
##   - Two stores against each other: a phase orbit, the battery's charge
##     across and a store's fill up, hour by hour. A steady site draws the
##     same loop every day; one running down spirals off.
##   - The energy budget: where the window's energy went, as a waterfall and
##     as a Sankey (EnergyRunSankey, the same split the run debriefs show).
## It reads the live caches (SolarUI's EnergyTimeline, the flow engine's tank
## timelines) and changes nothing. Opened from the timeline's ⋯ / pattern
## button; `open()`.

const WINDOWS := [["3 days", 3], ["7 days", 7], ["14 days", 14]]
const MONTHS := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

var _frame: ModalFrame = null
var _days := 7
var _win_btns: Array = []
var _carpet: CarpetPlot = null
var _carpet_opt: OptionButton = null
var _carpet_note: Label = null
var _orbit: PhaseOrbit = null
var _orbit_opt: OptionButton = null
var _orbit_note: Label = null
var _water: WaterfallChart = null
var _budget_box: HBoxContainer = null
var _budget_note: Label = null
var _span_lbl: Label = null
## Cached for the window: day0 (midnight), days, and the hourly grids.
var _day0 := 0.0
var _n_days := 0
var _grids := {}
var _stores: Array = []   # [[item id, name]]


func open() -> void:
	if _frame == null:
		_build()
	_refresh()
	_frame.open()


func is_open() -> bool:
	return _frame != null and _frame.is_open()


func _build() -> void:
	_frame = ModalFrame.create("Patterns", "The days this world has recorded, read three ways.",
		Vector2(1120, 900), "patterns")
	add_child(_frame)
	var b := _frame.body
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 6)
	b.add_child(top)
	_span_lbl = Label.new()
	_span_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_span_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	top.add_child(_span_lbl)
	for w in WINDOWS:
		var bt := Button.new()
		bt.text = str(w[0])
		bt.name = "win_%d" % int(w[1])
		bt.toggle_mode = true
		UITheme.style_button(bt)
		var nd := int(w[1])
		bt.pressed.connect(func() -> void:
			_days = nd
			_refresh())
		top.add_child(bt)
		_win_btns.append([bt, nd])

	b.add_child(SectionHeader.make("Hour by hour", "calendar",
		"a column per day, midnight at the top; seasons read across, the daily rhythm down"))
	var cr := HBoxContainer.new()
	b.add_child(cr)
	_carpet_opt = OptionButton.new()
	_carpet_opt.name = "carpet_channel"
	_carpet_opt.item_selected.connect(func(_i: int) -> void: _fill_carpet())
	cr.add_child(_carpet_opt)
	_carpet_note = _note()
	cr.add_child(_carpet_note)
	_carpet = CarpetPlot.new()
	_carpet.name = "carpet"
	_carpet.custom_minimum_size = Vector2(0, 230)
	_carpet.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_child(_carpet)

	b.add_child(SectionHeader.make("Two stores against each other", "route",
		"hour by hour; a steady site draws the same loop every day"))
	var orr := HBoxContainer.new()
	b.add_child(orr)
	var ol := Label.new()
	ol.text = "Battery charge against"
	ol.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	orr.add_child(ol)
	_orbit_opt = OptionButton.new()
	_orbit_opt.name = "orbit_store"
	_orbit_opt.item_selected.connect(func(_i: int) -> void: _fill_orbit())
	orr.add_child(_orbit_opt)
	_orbit_note = _note()
	orr.add_child(_orbit_note)
	_orbit = PhaseOrbit.new()
	_orbit.name = "orbit"
	_orbit.custom_minimum_size = Vector2(0, 300)
	_orbit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_child(_orbit)

	b.add_child(SectionHeader.make("Where the energy went", "zap",
		"the window's energy budget, step by step"))
	_budget_note = _note()
	b.add_child(_budget_note)
	_budget_box = HBoxContainer.new()
	_budget_box.add_theme_constant_override("separation", 16)
	b.add_child(_budget_box)
	_water = WaterfallChart.new()
	_water.name = "waterfall"
	_water.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_water.size_flags_stretch_ratio = 1.0
	_budget_box.add_child(_water)

	_frame.add_button("Close", ModalFrame.PRIMARY, _frame.close)


func _note() -> Label:
	var l := Label.new()
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	l.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	return l


func _main() -> Node:
	return get_tree().current_scene if get_tree() != null else null


func _energy() -> EnergyTimeline:
	var su := ServiceLocator.solar_ui()
	if su == null:
		var m := _main()
		su = m.get_node_or_null("UILayer/SolarUI") if m != null else null
	return su.get("energy_timeline") as EnergyTimeline if su != null else null


func _engine() -> Object:
	var gv := ServiceLocator.graph()
	return gv.call("resource_flow_engine") if gv != null and gv.has_method("resource_flow_engine") else null


func _date_label(day: int) -> String:
	var m := _main()
	if m == null or m.get("clock") == null:
		return "day %d" % (day + 1)
	var dd: Dictionary = m.get("clock").call("abs_hours_to_date", _day0 + float(day) * 24.0 + 12.0)
	return "%s %d" % [MONTHS[clampi(int(dd.get("month", 1)) - 1, 0, 11)], int(dd.get("day", 1))]


## Re-read the window: midnight-aligned days ending at the last recorded hour.
func _refresh() -> void:
	for wb in _win_btns:
		(wb[0] as Button).button_pressed = int(wb[1]) == _days
	_grids.clear()
	var tl := _energy()
	if tl == null or tl.is_empty():
		_n_days = 0
		_span_lbl.text = "Nothing recorded yet: let the clock run, or render ahead with 📈 Render."
	else:
		var t1 := tl.end_abs_hours()
		var t0 := maxf(tl.start_abs_hours(), t1 - float(_days) * 24.0)
		_day0 = floorf(t0 / 24.0) * 24.0
		_n_days = maxi(int(ceil((t1 - _day0) / 24.0)), 1)
		for ch in ["soc_pct", "solar_kw", "load_kw", "net_kw"]:
			var sl := tl.channel_slice(ch, _day0, t1)
			_grids[ch] = PatternData.hour_grid(sl["values"], float(sl["base_t"]), float(sl["step"]), _day0, _n_days)
		_span_lbl.text = I18n.f("{date} to {n_days} · {n_days_2} recorded", {
			"date": _date_label(0),
			"n_days": _date_label(_n_days - 1),
			"n_days_2": UiText.count(_n_days, "day"),
		})
	# Stores with a recorded fill.
	_stores.clear()
	var eng := _engine()
	var gv := ServiceLocator.graph()
	var model: GraphModel = gv.get("model") if gv != null else null
	if eng != null and model != null and _n_days > 0:
		for it: Dictionary in model.items:
			if str(it.get("type", "")) != "resource":
				continue
			var rtl: ResourceTimeline = eng.call("get_timeline", str(it.get("id", "")))
			if rtl == null or rtl.is_empty():
				continue
			var sl2 := rtl.pct_slice(_day0, _day0 + float(_n_days) * 24.0)
			if (sl2["values"] as PackedFloat32Array).is_empty():
				continue
			var key := "store:" + str(it.get("id", ""))
			_grids[key] = PatternData.hour_grid(sl2["values"], float(sl2["base_t"]), float(sl2["step"]),
				_day0, _n_days)
			_stores.append([str(it.get("id", "")), str((it.get("specs", {}) as Dictionary).get("name", it.get("id", "")))])
	_stores.sort_custom(func(a, b2) -> bool: return str(a[1]) < str(b2[1]))
	_fill_options()
	_fill_carpet()
	_fill_orbit()
	_fill_budget(tl)


func _fill_options() -> void:
	var keep_c: String = str(_carpet_opt.get_item_metadata(_carpet_opt.selected)) if _carpet_opt.selected >= 0 else "soc_pct"
	var keep_o: String = str(_orbit_opt.get_item_metadata(_orbit_opt.selected)) if _orbit_opt.selected >= 0 else ""
	_carpet_opt.clear()
	var chans := [["Battery charge", "soc_pct"], ["Solar", "solar_kw"], ["Load", "load_kw"],
		["Net power (surplus / deficit)", "net_kw"]]
	for s in _stores:
		chans.append(["%s fill" % str(s[1]), "store:" + str(s[0])])
	for i in chans.size():
		_carpet_opt.add_item(str(chans[i][0]))
		_carpet_opt.set_item_metadata(i, str(chans[i][1]))
		if str(chans[i][1]) == str(keep_c):
			_carpet_opt.select(i)
	_orbit_opt.clear()
	_orbit_opt.add_item("Net power")
	_orbit_opt.set_item_metadata(0, "net_kw")
	for j in _stores.size():
		_orbit_opt.add_item("%s fill" % str(_stores[j][1]))
		_orbit_opt.set_item_metadata(j + 1, "store:" + str(_stores[j][0]))
		if "store:" + str(_stores[j][0]) == str(keep_o):
			_orbit_opt.select(j + 1)
	if str(keep_o) == "" and _stores.size() > 0:
		_orbit_opt.select(1)


func _ticks() -> Array:
	var out: Array = []
	var step := 1 if _n_days <= 8 else 2
	for d in range(0, _n_days, step):
		out.append([d, _date_label(d)])
	return out


func _fill_carpet() -> void:
	if _carpet_opt.selected < 0:
		_carpet.set_data(PackedFloat32Array(), 0)
		return
	var ch := str(_carpet_opt.get_item_metadata(_carpet_opt.selected))
	var g: PackedFloat32Array = _grids.get(ch, PackedFloat32Array())
	var o := {"ticks": _ticks(), "day_label": _date_label}
	match ch:
		"soc_pct":
			o["ramp"] = "charge"
			o["range"] = Vector2(0.0, 100.0)
			o["fmt"] = func(v: float) -> String: return "%d %%" % int(round(v))
			_carpet_note.text = "Light = full, dark = empty."
		"solar_kw", "load_kw":
			o["ramp"] = "power"
			o["fmt"] = func(v: float) -> String: return UiText.num(v * 1000.0, "W")
			_carpet_note.text = "Light = the most this window, dark = none."
		"net_kw":
			o["ramp"] = "diverging"
			o["fmt"] = func(v: float) -> String: return ("+" if v > 0.0 else "") + UiText.num(v * 1000.0, "W")
			_carpet_note.text = "Blue = more made than used, red = drawing on the battery, grey = even."
		_:
			o["ramp"] = "water"
			o["range"] = Vector2(0.0, 100.0)
			o["fmt"] = func(v: float) -> String: return "%d %%" % int(round(v))
			_carpet_note.text = "Light = full, dark = empty."
	_carpet.set_data(g, _n_days, o)


func _fill_orbit() -> void:
	var xs: PackedFloat32Array = _grids.get("soc_pct", PackedFloat32Array())
	if _orbit_opt.selected < 0 or xs.is_empty():
		_orbit.set_data(PackedFloat32Array(), PackedFloat32Array())
		_orbit_note.text = ""
		return
	var key := str(_orbit_opt.get_item_metadata(_orbit_opt.selected))
	var ys: PackedFloat32Array = _grids.get(key, PackedFloat32Array())
	var is_net := key == "net_kw"
	var y_name := "net power" if is_net else _orbit_opt.get_item_text(_orbit_opt.selected).to_lower()
	var pct := func(v: float) -> String: return "%d %%" % int(round(v))
	_orbit.set_data(xs, ys, {"x_label": "Battery charge", "y_label": _orbit_opt.get_item_text(_orbit_opt.selected),
		"x_fmt": pct, "y_fmt": (func(v: float) -> String: return UiText.num(v * 1000.0, "W")) if is_net else pct,
		"x_range": Vector2(0.0, 100.0), "y_range": PatternData.finite_range(ys) if is_net else Vector2(0.0, 100.0),
		"color": UITheme.C_PRIMARY,
		"t_label": func(i: int) -> String: return "%s, %02d:00" % [_date_label(floori(i / 24.0)), i % 24]})
	var yr := PatternData.finite_range(ys)
	var drift := PatternData.orbit_drift(xs, ys)
	_orbit_note.text = PatternData.drift_words(drift, Vector2(100.0, 100.0 if not is_net else maxf(yr.y - yr.x, 1e-6)),
		"the battery", y_name) if _n_days >= 2 else "Two days or more draw a loop."


func _fill_budget(tl: EnergyTimeline) -> void:
	for c in _budget_box.get_children():
		if c != _water:
			_budget_box.remove_child(c)
			c.queue_free()
	if tl == null or tl.is_empty() or _n_days == 0:
		_water.set_steps([])
		_budget_note.text = ""
		return
	var t1 := tl.end_abs_hours()
	var su := ServiceLocator.solar_ui()
	# What the sky offered: the raw (uncapped, unclipped) array output.
	var pot := -1.0
	if su != null and su.has_method("evaluate_potential_solar_at"):
		pot = 0.0
		var t := _day0
		while t < t1:
			pot += float(su.call("evaluate_potential_solar_at", t + 0.5)) * minf(1.0, t1 - t)
			t += 1.0
	var f := EnergyRunSankey.flows_from_timeline(tl, maxf(_day0, tl.start_abs_hours()), t1, pot)
	_water.set_steps(PatternData.energy_waterfall(f), EnergyRunSankey.kwh)
	_budget_note.text = EnergyRunSankey.summary(f)
	var v := EnergyRunSankey.make_view(f, 260.0)
	if v != null:
		v.size_flags_stretch_ratio = 1.0
		_budget_box.add_child(v)
