extends Node

## ⧉ Compare. Two modes:
##
## SIM VS REALITY — "does the sim match reality?"
## Pick a past span and where reality comes from (this world's Home Assistant
## sensors, or an imported CSV clip); Run simulates this world over the same
## span from the battery the real one had at the start and lays the curves on
## one time axis with the error numbers (ExperimentScore.calibration: ASHRAE
## Guideline 14 hourly NMBE / CV(RMSE) per energy channel, mean error in
## points for the battery). Two sims when the real load is known: the graph's
## own loads, and the real loads replayed, so a gap in solar / battery can be
## told apart from a gap in the loads.
##
## A VS B — two versions of this world (the world as it is, and forks from
## the world's ExperimentStore) simulated over the same span from the same
## battery (AbExperiment), each with its own automations, scored on a
## headline metric with every other metric beside it. Forks are made, edited
## (Main.edit_experiment_fork: the graph view on the fork, Done comes back
## here), renamed and deleted from this window; the inspector's "A/B this
## automation" opens it on a fork without that automation.
##
## Opened by TimelineUI's ⧉ button (Main.open_compare_view). Runs in the
## background and never touches the clock, the graph or the battery.

const MODE_CAL := "calibration"
const MODE_AB := "ab"
const MODES := [["Sim vs reality", MODE_CAL], ["A vs B — two versions of this world", MODE_AB]]
## [label, hours (- = before the anchor, + = after), key]. Calibration spans
## end at the real now; A/B spans run from the playhead.
const CAL_SPANS := [
	["Last 24 hours", -24.0, "last_24h"], ["Last 3 days", -72.0, "last_3d"],
	["Last 7 days", -168.0, "last_7d"], ["Last 14 days", -336.0, "last_14d"],
	["Timeline selection", 0.0, "selection"], ["Custom", 0.0, "custom"],
]
const AB_SPANS := [
	["Next 24 hours", 24.0, "next_24h"], ["Next 7 days", 168.0, "next_7d"],
	["Last 7 days", -168.0, "last_7d"], ["Timeline selection", 0.0, "selection"],
	["Custom", 0.0, "custom"],
]
const SOURCES := [["Home Assistant history", CalibrationExperiment.SOURCE_HA],
	["Imported CSV clip", CalibrationExperiment.SOURCE_CSV]]
const C_OBS := Color(0.93, 0.95, 0.98)
const SIM_COLORS := [UITheme.C_AMBER, UITheme.C_PRIMARY, UITheme.C_LAVENDER]
const VERDICT_WORDS := {"good": "Matches", "fair": "Roughly", "poor": "Off", "n/a": "—"}

var _main: Node = null
var _selection := Vector2(NAN, NAN)
var _frame: ModalFrame = null
var _exp: CalibrationExperiment = null
var _ab: AbExperiment = null
var _result: Dictionary = {}
var _mode := MODE_CAL
var _store: ExperimentStore = ExperimentStore.new()
var _store_path := ""
var _variant_ids: Array = []
var _delete_armed := false

var _mode_opt: OptionButton = null
var _source_row: HBoxContainer = null
var _ab_box: VBoxContainer = null
var _a_opt: OptionButton = null
var _b_opt: OptionButton = null
var _metric_opt: OptionButton = null
var _edit_btn: Button = null
var _rename_btn: Button = null
var _delete_btn: Button = null
var _rename_row: HBoxContainer = null
var _rename_edit: LineEdit = null
var _forks_note: Label = null
var _table_header: SectionHeader = null
var _days_header: SectionHeader = null

var _source_opt: OptionButton = null
var _span_opt: OptionButton = null
var _start_edit: LineEdit = null
var _end_edit: LineEdit = null
var _range_note: Label = null
var _run_btn: Button = null
var _progress: ProgressBar = null
var _status: Label = null
var _banner: AlertBanner = null
var _notes: Label = null
var _legend: HBoxContainer = null
var _chart: ExperimentCompareChart = null
var _table: GridContainer = null
var _days: GridContainer = null
var _autos_header: SectionHeader = null
var _autos: GridContainer = null


func open_on(main: Node, selection: Vector2, opts: Dictionary = {}) -> void:
	_main = main
	_selection = selection
	var gv := main.find_child("SystemGraphView", true, false) if main != null else null
	_store_path = ExperimentStore.path_for_view(gv)
	_store = ExperimentStore.load_from(_store_path)
	_build()
	var o := opts.duplicate()
	if not o.has("mode") and not _store.last.is_empty():
		o["mode"] = str(_store.last.get("mode", MODE_CAL))
	_frame.open()
	apply_opts(o)


## {mode, a, b, span (a span key), metric, run}.
func apply_opts(opts: Dictionary) -> void:
	_set_mode(str(opts.get("mode", _mode)))
	if _mode == MODE_AB:
		_refresh_variants(str(opts.get("a", _store.last.get("a", ExperimentStore.CURRENT))),
			str(opts.get("b", _store.last.get("b", ""))))
		if opts.has("metric") or _store.last.has("metric"):
			_select_metric(str(opts.get("metric", _store.last.get("metric", ""))))
	var key := str(opts.get("span", ""))
	if key.is_empty():
		key = "selection" if not is_nan(_selection.x) else ("next_7d" if _mode == MODE_AB else "last_7d")
	_select_span(key)
	if bool(opts.get("run", false)):
		_on_run()


func close() -> void:
	if _frame != null:
		_frame.close()


func _clock() -> Object:
	return _main.get("clock") if _main != null else null


# --- build ------------------------------------------------------------------------

func _build() -> void:
	_frame = ModalFrame.create("Compare sim with reality",
		"Simulate this world over a past span and lay it over what really happened.",
		Vector2(1180, 900), "experiment_compare")
	add_child(_frame)
	_frame.closed.connect(_on_closed)
	var b := _frame.body

	var r0 := _row(b)
	_lbl(r0, "Compare")
	_mode_opt = OptionButton.new()
	for m in MODES:
		_mode_opt.add_item(str(m[0]))
	_mode_opt.item_selected.connect(func(i: int) -> void:
		_set_mode(str(MODES[i][1]))
		if _mode == MODE_AB:
			_refresh_variants(ExperimentStore.CURRENT, "")
		_select_span("next_7d" if _mode == MODE_AB else "last_7d"))
	r0.add_child(_mode_opt)

	_ab_box = VBoxContainer.new()
	_ab_box.add_theme_constant_override("separation", 6)
	b.add_child(_ab_box)
	_build_ab(_ab_box)

	b.add_child(SectionHeader.make("Span", "calendar"))
	var r1 := _row(b)
	_source_row = HBoxContainer.new()
	_source_row.add_theme_constant_override("separation", 8)
	r1.add_child(_source_row)
	_lbl(_source_row, "Reality from")
	_source_opt = OptionButton.new()
	for s in SOURCES:
		_source_opt.add_item(str(s[0]))
	_source_opt.item_selected.connect(func(_i: int) -> void: _refresh_range_note())
	_source_row.add_child(_source_opt)
	_lbl(r1, "Span")
	_span_opt = OptionButton.new()
	_span_opt.item_selected.connect(_on_span_preset)
	r1.add_child(_span_opt)
	var r2 := _row(b)
	_lbl(r2, "From")
	_start_edit = _line(r2, "YYYY-MM-DD HH:MM")
	_lbl(r2, "to")
	_end_edit = _line(r2, "YYYY-MM-DD HH:MM")
	for e in [_start_edit, _end_edit]:
		(e as LineEdit).text_changed.connect(func(_t: String) -> void:
			_span_opt.select(_spans().size() - 1)
			_refresh_range_note())
	_range_note = _note(b, "")

	var pr := _row(b)
	_progress = ProgressBar.new()
	_progress.custom_minimum_size = Vector2(220, 8)
	_progress.show_percentage = false
	_progress.visible = false
	UITheme.style_progress(_progress)
	_progress.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	pr.add_child(_progress)
	_status = _lbl(pr, "")

	_banner = AlertBanner.new()
	b.add_child(_banner)
	_notes = _note(b, "")
	_notes.visible = false

	b.add_child(SectionHeader.make("Curves", "chart-column", "hover for values"))
	_legend = _row(b)
	_chart = ExperimentCompareChart.new()
	_chart.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_child(_chart)

	_table_header = SectionHeader.make("How close", "target",
		"energy: ASHRAE Guideline 14 hourly NMBE ≤ 10 %, CV(RMSE) ≤ 30 %")
	b.add_child(_table_header)
	_table = GridContainer.new()
	_table.add_theme_constant_override("h_separation", 18)
	_table.add_theme_constant_override("v_separation", 4)
	b.add_child(_table)

	_days_header = SectionHeader.make("Day by day", "calendar")
	b.add_child(_days_header)
	_days = GridContainer.new()
	_days.add_theme_constant_override("h_separation", 18)
	_days.add_theme_constant_override("v_separation", 3)
	b.add_child(_days)

	_autos_header = SectionHeader.make("Automations in the sim", "workflow")
	b.add_child(_autos_header)
	_autos = GridContainer.new()
	_autos.columns = 4
	_autos.add_theme_constant_override("h_separation", 18)
	_autos.add_theme_constant_override("v_separation", 3)
	b.add_child(_autos)

	_frame.add_button("Close", ModalFrame.SECONDARY, _frame.close)
	_run_btn = _frame.add_button("Run comparison", ModalFrame.PRIMARY, _on_run)
	_show_empty()


# --- span -------------------------------------------------------------------------

func _spans() -> Array:
	return AB_SPANS if _mode == MODE_AB else CAL_SPANS


func _select_span(key: String) -> void:
	var sp := _spans()
	for i in sp.size():
		if str(sp[i][2]) == key and not _span_opt.is_item_disabled(i):
			_span_opt.select(i)
			_on_span_preset(i)
			return
	_span_opt.select(1)
	_on_span_preset(1)


func _on_span_preset(idx: int) -> void:
	var clock := _clock()
	if clock == null:
		return
	var sp: Array = _spans()[idx]
	var hours := float(sp[1])
	var a := NAN
	var e := NAN
	if str(sp[2]) == "selection" and not is_nan(_selection.x):
		a = _selection.x
		e = _selection.y
	elif hours != 0.0:
		# Calibration: the past up to the real now. A / B: from the playhead,
		# where the battery the runs start from is. Whole hours, so two runs a
		# few minutes apart match.
		var anchor := SiteTime.unix_to_site_abs(clock, Time.get_unix_time_from_system())
		if _mode == MODE_AB and _main != null and _main.has_method("get_absolute_hours"):
			anchor = float(_main.call("get_absolute_hours"))
		anchor = floorf(anchor)
		a = minf(anchor, anchor + hours)
		e = maxf(anchor, anchor + hours)
	if not is_nan(a):
		_start_edit.set_block_signals(true)
		_end_edit.set_block_signals(true)
		_start_edit.text = SiteTime.format_abs(clock, a)
		_end_edit.text = SiteTime.format_abs(clock, e)
		_start_edit.set_block_signals(false)
		_end_edit.set_block_signals(false)
	_refresh_range_note()


func _span() -> Vector2:
	var a := _parse_abs(_start_edit.text)
	var e := _parse_abs(_end_edit.text)
	return Vector2(a, e)


func _refresh_range_note() -> void:
	var s := _span()
	if is_nan(s.x) or is_nan(s.y):
		_range_note.text = "Type dates as 2026-10-15 06:00 (this site's clock)."
		_range_note.add_theme_color_override("font_color", UITheme.C_WARN)
		return
	if s.y <= s.x:
		_range_note.text = "The span must end after it starts."
		_range_note.add_theme_color_override("font_color", UITheme.C_WARN)
		return
	var step := CalibrationExperiment.step_for(s.y - s.x)
	_range_note.text = "%s, simulated every %s. Times are this site's clock." % [
		UiText.duration(s.y - s.x), UiText.duration(step)]
	_range_note.add_theme_color_override("font_color", UITheme.C_TEXT_S)


# --- run --------------------------------------------------------------------------

func _on_run() -> void:
	if is_running():
		if _exp != null:
			_exp.cancel()
		if _ab != null:
			_ab.cancel()
		_set_running(false)
		_status.text = "Stopped."
		return
	var s := _span()
	if is_nan(s.x) or is_nan(s.y):
		_refresh_range_note()
		return
	if _mode == MODE_AB:
		_run_ab(s)
		return
	if _exp == null:
		_exp = CalibrationExperiment.new()
		_exp.name = "CalibrationExperiment"
		add_child(_exp)
		_exp.progress.connect(_on_progress)
		_exp.finished.connect(_on_finished)
	var src := str(SOURCES[_source_opt.selected][1])
	var err := _exp.start(_main, s.x, s.y, {"source": src})
	if not err.is_empty():
		_banner.show_alert(AlertBanner.WARN, err)
		return
	_banner.clear()
	_set_running(true)


func _set_running(on: bool) -> void:
	_progress.visible = on
	_progress.value = 0.0
	_run_btn.text = "Stop" if on else "Run comparison"


func _on_progress(f: float, text: String) -> void:
	_progress.value = f * 100.0
	_status.text = text


func _on_finished(result: Dictionary) -> void:
	_set_running(false)
	_status.text = ""
	_result = result
	if str(result.get("mode", "")) == MODE_AB:
		_show_ab_result(result)
	else:
		_show_result(result)


# --- results ----------------------------------------------------------------------

func _show_empty() -> void:
	_chart.set_data([], Vector2.ZERO, _clock())
	for c in _table.get_children():
		c.queue_free()
	for c in _days.get_children():
		c.queue_free()


func _show_result(res: Dictionary) -> void:
	var obs: ExperimentSeries = res.get("observed", null)
	var sims: Array = res.get("sims", [])
	var report: Dictionary = res.get("report", {})
	var span: Vector2 = res.get("span", Vector2.ZERO)
	# Verdict.
	var err := str(report.get("error", ""))
	var have_obs := obs != null and (obs.has("soc_kwh") or obs.has("solar_kw") or obs.has("load_kw"))
	if not have_obs:
		_banner.show_alert(AlertBanner.ERROR, err if not err.is_empty() else
			"No real readings for that span. Check the span and this world's Live links.")
	else:
		var best := ""
		for sm in sims:
			var ov := str((sm["calibration"] as Dictionary).get("overall", ""))
			if best.is_empty() or _rank(ov) < _rank(best):
				best = ov
		var lvl := {"good": AlertBanner.OK, "fair": AlertBanner.WARN, "poor": AlertBanner.ERROR}
		var words := {"good": "The sim matches reality over this span.",
			"fair": "The sim is roughly right over this span — see which channel drifts below.",
			"poor": "The sim is off over this span — see which channel below."}
		_banner.show_alert(int(lvl.get(best, AlertBanner.INFO)),
			str(words.get(best, "Compared — not enough overlapping readings to judge.")) +
			("" if err.is_empty() else "  " + err))
	# Notes: start, missing links, coverage, held values.
	var notes: Array = []
	if not str(report.get("start_soc_note", "")).is_empty():
		notes.append("Sims start from %s." % str(report["start_soc_note"]))
	for ch in (report.get("missing", {}) as Dictionary):
		notes.append(str(report["missing"][ch]))
	if obs != null:
		for ch in ["soc_kwh", "solar_kw", "load_kw", "aux_kw"]:
			if obs.has(ch):
				var cov := obs.coverage(ch)
				if cov < 0.95:
					notes.append("%s: real readings cover %s of the span." % [_ch_name(ch), UiText.pct(cov)])
			if obs.notes.has(ch):
				notes.append("%s: %s." % [_ch_name(ch), str(obs.notes[ch])])
	if not sims.is_empty():
		var s0: ExperimentSeries = sims[0]["series"]
		if s0.notes.has("aux_kw"):
			notes.append("Hydro / wind: %s (no real readings linked)." % str(s0.notes["aux_kw"]))
		var nrules := int(sims[0].get("automation_rules", 0))
		var nfired := (sims[0].get("automation_log", []) as Array).size()
		if nrules > 0:
			notes.append("Model loads start as switched now and follow this world's %s (%s in the span)." % [
				UiText.count(nrules, "automation"), UiText.count(nfired, "switch", "switches")])
		else:
			notes.append("Model loads are the graph's loads as they are switched now (this world has no automations).")
	_notes.text = "\n".join(notes)
	_notes.visible = not notes.is_empty()
	# Chart.
	var items: Array = []
	for c in _legend.get_children():
		c.queue_free()
	if obs != null:
		items.append({"series": obs, "color": C_OBS, "band": true})
		_legend_item(obs.label, C_OBS)
	for k in sims.size():
		var col: Color = SIM_COLORS[k % SIM_COLORS.size()]
		items.append({"series": sims[k]["series"], "color": col})
		_legend_item(str(sims[k]["label"]), col)
	_chart.set_data(items, span, _clock())
	_fill_table(obs, sims)
	_fill_days(obs, sims)
	_fill_autos(sims)


func _fill_table(obs: ExperimentSeries, sims: Array) -> void:
	for c in _table.get_children():
		c.queue_free()
	_table.columns = 1 + 1 + sims.size()
	_cell(_table, "", true)
	_cell(_table, "Reality", true, C_OBS)
	for k in sims.size():
		_cell(_table, str(sims[k]["label"]), true, SIM_COLORS[k % SIM_COLORS.size()])
	# Energy totals with the per-channel error.
	for row in [["solar_kw", "Solar made"], ["load_kw", "Energy used"], ["aux_kw", "Hydro / wind"]]:
		var ch := str(row[0])
		_cell(_table, str(row[1]))
		_cell(_table, UiText.num(obs.integrate(ch), "kWh") if obs != null and obs.has(ch) else "no sensor",
			false, UITheme.C_TEXT if obs != null and obs.has(ch) else UITheme.C_TEXT_M)
		for sm in sims:
			var s: ExperimentSeries = sm["series"]
			var st: Dictionary = ((sm["calibration"] as Dictionary).get("channels", {}) as Dictionary).get(ch, {})
			var txt := UiText.num(s.integrate(ch), "kWh")
			var tone := UITheme.C_TEXT
			if not st.is_empty():
				var e := float(st.get("kwh_err_pct", NAN))
				if not is_nan(e):
					txt += "  (%s%.0f %%)" % ["+" if e >= 0.0 else "", e]
				txt += "  · %s" % _g14_text(st)
				tone = _verdict_color(str(st.get("verdict", "")))
			_cell(_table, txt, false, tone)
	# Battery.
	_cell(_table, "Battery")
	if obs != null and obs.has("soc_kwh"):
		_cell(_table, "%s → %s" % [_pct(obs.value("soc_pct", _first_known(obs, "soc_kwh"))),
			_pct(obs.value("soc_pct", _last_known(obs, "soc_kwh")))])
	else:
		_cell(_table, "no sensor", false, UITheme.C_TEXT_M)
	for sm in sims:
		var s: ExperimentSeries = sm["series"]
		var st: Dictionary = ((sm["calibration"] as Dictionary).get("channels", {}) as Dictionary).get("soc_pct", {})
		var txt := "%s → %s" % [_pct(s.value("soc_pct", 0)), _pct(s.value("soc_pct", s.size() - 1))]
		var tone := UITheme.C_TEXT
		if not st.is_empty():
			txt += "  · off by %.0f pts on average" % float(st.get("mae", NAN))
			tone = _verdict_color(str(st.get("verdict", "")))
		_cell(_table, txt, false, tone)
	# Time with AC off (sims know; reality only if the inverter's output reads 0).
	_cell(_table, "AC off")
	_cell(_table, "—", false, UITheme.C_TEXT_M)
	for sm in sims:
		_cell(_table, UiText.duration(float((sm["energy"] as Dictionary).get("ac_off_h", 0.0))))
	_cell(_table, "Solar wasted (battery full)")
	_cell(_table, "—", false, UITheme.C_TEXT_M)
	for sm in sims:
		_cell(_table, UiText.num(float((sm["energy"] as Dictionary).get("curtailed_kwh", 0.0)), "kWh"))


func _fill_days(obs: ExperimentSeries, sims: Array) -> void:
	for c in _days.get_children():
		c.queue_free()
	if obs == null or sims.is_empty():
		return
	var cal: Dictionary = sims[0]["calibration"]
	var rows: Array = cal.get("days", [])
	if rows.is_empty():
		return
	_days.columns = 5
	for h in ["Day", "Solar real / sim", "Use real / sim", "Battery at end real / sim", "Readings"]:
		_cell(_days, h, true)
	var clock := _clock()
	for d in rows:
		var dd: Dictionary = d
		var date := ""
		if clock != null:
			var dt: Dictionary = clock.call("abs_hours_to_date", float(dd["start_abs"]))
			date = "%d/%d" % [int(dt["month"]), int(dt["day"])]
		_cell(_days, date)
		_cell(_days, _pair(dd, "solar_kw", "kWh"))
		_cell(_days, _pair(dd, "load_kw", "kWh"))
		_cell(_days, "%s / %s" % [_pct(float(dd.get("obs_soc_end_pct", NAN))), _pct(float(dd.get("sim_soc_end_pct", NAN)))])
		var cov := float(dd.get("obs_cov_solar_kw", dd.get("obs_cov_load_kw", NAN)))
		_cell(_days, UiText.pct(cov) if not is_nan(cov) else "—", false,
			UITheme.C_TEXT_M if is_nan(cov) or cov >= 0.95 else UITheme.C_WARN)


## What the world's automations switched in the model-loads sim.
func _fill_autos(sims: Array) -> void:
	for c in _autos.get_children():
		c.queue_free()
	var lg: Array = []
	for sm in sims:
		if str(sm.get("load_mode", "")) == ExperimentEvaluator.LOAD_MODEL:
			lg = sm.get("automation_log", [])
	_autos_header.visible = not lg.is_empty()
	_autos.visible = not lg.is_empty()
	var clock := _clock()
	var names := {}
	var gv := _main.find_child("SystemGraphView", true, false) if _main != null else null
	var m: Object = gv.get("model") if gv != null else null
	var shown := 0
	for e in lg:
		if shown >= 40:
			_cell(_autos, "… and %s more" % UiText.count(lg.size() - shown, "switch", "switches"), false, UITheme.C_TEXT_M)
			for _k in 3:
				_cell(_autos, "")
			break
		var iid := str(e["item_id"])
		if not names.has(iid):
			var it: Dictionary = m.call("get_item", iid) if m != null else {}
			names[iid] = str((it.get("specs", {}) as Dictionary).get("name", iid)) if not it.is_empty() else iid
		_cell(_autos, "")
		_cell(_autos, SiteTime.format_abs(clock, float(e["t"])) if clock != null else "")
		_cell(_autos, "%s %s" % [str(names[iid]), {"turn_on": "on", "turn_off": "off", "toggle": "toggled"}.get(str(e["command"]), str(e["command"]))],
			false, UITheme.C_OK if str(e["command"]) == "turn_on" else UITheme.C_TEXT)
		_cell(_autos, str(e["alias"]), false, UITheme.C_TEXT_S)
		shown += 1


# --- small helpers ----------------------------------------------------------------

func _pair(d: Dictionary, ch: String, unit: String) -> String:
	var o := float(d.get("obs_" + ch, NAN))
	var s := float(d.get("sim_" + ch, NAN))
	return "%s / %s" % [UiText.num(o, unit) if not is_nan(o) else "—", UiText.num(s, unit) if not is_nan(s) else "—"]


static func _g14_text(st: Dictionary) -> String:
	var nm := float(st.get("nmbe_pct", NAN))
	var cv := float(st.get("cvrmse_pct", NAN))
	var v := str(st.get("verdict", ""))
	if is_nan(nm) or is_nan(cv):
		return str(VERDICT_WORDS.get(v, "—"))
	return "%s (NMBE %.0f %%, CV %.0f %%)" % [str(VERDICT_WORDS.get(v, v)), nm, cv]


static func _rank(v: String) -> int:
	return {"good": 0, "fair": 1, "poor": 2}.get(v, 3)


static func _verdict_color(v: String) -> Color:
	match v:
		"good": return UITheme.C_OK
		"fair": return UITheme.C_WARN
		"poor": return UITheme.C_ERROR
	return UITheme.C_TEXT


static func _ch_name(ch: String) -> String:
	return {"soc_kwh": "Battery", "solar_kw": "Solar", "load_kw": "Power use", "aux_kw": "Hydro / wind"}.get(ch, ch)


static func _pct(v: float) -> String:
	return "—" if is_nan(v) else "%.0f %%" % v


static func _first_known(s: ExperimentSeries, ch: String) -> int:
	for i in s.size():
		if not is_nan(s.value(ch, i)):
			return i
	return 0


static func _last_known(s: ExperimentSeries, ch: String) -> int:
	for i in range(s.size() - 1, -1, -1):
		if not is_nan(s.value(ch, i)):
			return i
	return 0


func _legend_item(text: String, col: Color) -> void:
	var sw := ColorRect.new()
	sw.color = col
	sw.custom_minimum_size = Vector2(14, 4)
	sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_legend.add_child(sw)
	var l := _lbl(_legend, text)
	l.add_theme_color_override("font_color", UITheme.C_TEXT)


func _cell(grid: GridContainer, text: String, head: bool = false, col: Color = UITheme.C_TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", UITheme.font("semibold" if head else "regular", not head))
	l.add_theme_font_size_override("font_size", UITheme.FONT_XS if head else UITheme.FONT_SM)
	l.add_theme_color_override("font_color", UITheme.C_TEXT_S if head and col == UITheme.C_TEXT else col)
	grid.add_child(l)
	return l


func _row(parent: Control) -> HBoxContainer:
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", 8)
	parent.add_child(r)
	return r


func _lbl(parent: Control, text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	parent.add_child(l)
	return l


func _note(parent: Control, text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	parent.add_child(l)
	return l


func _line(parent: Control, placeholder: String) -> LineEdit:
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(e)
	return e


## "2026-10-15 06:00" (time optional) on the site clock → absolute hours, NAN
## if unreadable (the video export dialog's parser).
static func _parse_abs(text: String) -> float:
	var t := text.strip_edges().replace("T", " ")
	var parts := t.split(" ", false)
	if parts.is_empty():
		return NAN
	var d := parts[0].split("-")
	if d.size() != 3 or not d[0].is_valid_int() or not d[1].is_valid_int() or not d[2].is_valid_int():
		return NAN
	var hours := 0.0
	if parts.size() > 1:
		var hm := parts[1].split(":")
		if hm.is_empty() or not hm[0].is_valid_int():
			return NAN
		hours = float(int(hm[0]))
		if hm.size() > 1 and hm[1].is_valid_int():
			hours += float(int(hm[1])) / 60.0
	var c := CelestialClock.new()
	c.year = int(d[0])
	c.month = clampi(int(d[1]), 1, 12)
	c.day = clampi(int(d[2]), 1, c.get_days_in_month(c.month, c.year))
	c.day_time = clampf(hours, 0.0, 23.999)
	return c.get_absolute_hours()


func _on_closed() -> void:
	if _exp != null and _exp.is_running():
		_exp.cancel()
	if _ab != null and _ab.is_running():
		_ab.cancel()
	queue_free()


## For the harness: the last result (empty until a run finishes).
func last_result() -> Dictionary:
	return _result


func is_running() -> bool:
	return (_exp != null and _exp.is_running()) or (_ab != null and _ab.is_running())


## For the harness: set the span and source, then run.
func run_with(start_abs: float, end_abs: float, source: String) -> void:
	var clock := _clock()
	_start_edit.text = SiteTime.format_abs(clock, start_abs)
	_end_edit.text = SiteTime.format_abs(clock, end_abs)
	_span_opt.select(_spans().size() - 1)
	_refresh_range_note()
	for i in SOURCES.size():
		if str(SOURCES[i][1]) == source:
			_source_opt.select(i)
	_on_run()


# --- A vs B -----------------------------------------------------------------------

func _set_mode(m: String) -> void:
	_mode = MODE_AB if m == MODE_AB else MODE_CAL
	for i in MODES.size():
		if str(MODES[i][1]) == _mode:
			_mode_opt.select(i)
	_source_row.visible = _mode == MODE_CAL
	_ab_box.visible = _mode == MODE_AB
	_table_header.visible = _mode == MODE_CAL
	_ab_table_header.visible = _mode == MODE_AB
	if _mode == MODE_AB:
		_frame.set_title("Compare two versions of this world",
			"Simulate A and B over the same span from the same battery, and see which scores higher.")
	else:
		_frame.set_title("Compare sim with reality",
			"Simulate this world over a past span and lay it over what really happened.")
	_span_opt.clear()
	var sp := _spans()
	for i in sp.size():
		_span_opt.add_item(str(sp[i][0]))
		if str(sp[i][2]) == "selection":
			_span_opt.set_item_disabled(i, is_nan(_selection.x))
	_banner.clear()
	_notes.visible = false
	_show_empty()


var _ab_table_header: SectionHeader = null


func _build_ab(box: VBoxContainer) -> void:
	var r := _row(box)
	var la := _lbl(r, "A")
	la.add_theme_color_override("font_color", SIM_COLORS[0])
	_a_opt = OptionButton.new()
	_a_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_a_opt.item_selected.connect(func(_i: int) -> void: _refresh_fork_buttons())
	r.add_child(_a_opt)
	var lb := _lbl(r, "B")
	lb.add_theme_color_override("font_color", SIM_COLORS[1])
	_b_opt = OptionButton.new()
	_b_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_b_opt.item_selected.connect(func(_i: int) -> void: _refresh_fork_buttons())
	r.add_child(_b_opt)
	_lbl(r, "Score by")
	_metric_opt = OptionButton.new()
	for m in AbExperiment.METRICS:
		_metric_opt.add_item(str(m[1]))
	r.add_child(_metric_opt)
	var r2 := _row(box)
	var nb := _button(r2, "New fork of this world", _on_new_fork)
	nb.tooltip_text = "A copy of this world's graph you can change without touching the world"
	_edit_btn = _button(r2, "Edit B…", _on_edit_fork)
	_rename_btn = _button(r2, "Rename B…", _on_rename_toggle)
	_delete_btn = _button(r2, "Delete B", _on_delete_fork)
	_forks_note = _lbl(r2, "")
	_rename_row = _row(box)
	_lbl(_rename_row, "New name")
	_rename_edit = _line(_rename_row, "Fork name")
	_rename_edit.text_submitted.connect(func(_t: String) -> void: _on_rename_confirm())
	_button(_rename_row, "Rename", _on_rename_confirm)
	_rename_row.visible = false
	_ab_table_header = SectionHeader.make("Scores", "target", "B − A; the better side is marked")
	_ab_table_header.visible = false
	# Shown in the results area just above the table (moved in place by
	# _place_ab_header once the table exists).
	call_deferred("_place_ab_header")


func _place_ab_header() -> void:
	if _table == null or _ab_table_header.get_parent() != null:
		return
	var parent := _table.get_parent()
	parent.add_child(_ab_table_header)
	parent.move_child(_ab_table_header, _table.get_index())


func _button(parent: Control, text: String, cb: Callable) -> Button:
	var bt := Button.new()
	bt.text = text
	bt.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(bt)
	bt.pressed.connect(cb)
	parent.add_child(bt)
	return bt


## Rebuild the A / B pickers: "This world as it is" + every fork.
func _refresh_variants(a_id: String, b_id: String) -> void:
	_variant_ids = [ExperimentStore.CURRENT]
	for f in _store.forks:
		_variant_ids.append(str(f["id"]))
	for opt in [_a_opt, _b_opt]:
		(opt as OptionButton).clear()
		for id in _variant_ids:
			(opt as OptionButton).add_item(_variant_label(str(id)))
	if b_id.is_empty() or not (b_id in _variant_ids):
		b_id = str(_variant_ids[1]) if _variant_ids.size() > 1 else ExperimentStore.CURRENT
	if not (a_id in _variant_ids):
		a_id = ExperimentStore.CURRENT
	_a_opt.select(_variant_ids.find(a_id))
	_b_opt.select(_variant_ids.find(b_id))
	_refresh_fork_buttons()


func _variant_label(id: String) -> String:
	if id == ExperimentStore.CURRENT:
		return "This world as it is"
	var f := _store.get_fork(id)
	if f.is_empty():
		return id
	return "%s · %s" % [str(f["name"]), UiText.count(ExperimentStore.automation_count(f["graph"]), "automation")]


func _variant_name(id: String) -> String:
	if id == ExperimentStore.CURRENT:
		return "This world"
	var f := _store.get_fork(id)
	return str(f.get("name", id))


func _sel_id(opt: OptionButton) -> String:
	var i := opt.selected
	return str(_variant_ids[i]) if i >= 0 and i < _variant_ids.size() else ExperimentStore.CURRENT


## The fork the buttons act on: B, or A when B is the world itself.
func _target_fork() -> String:
	var b := _sel_id(_b_opt)
	if b != ExperimentStore.CURRENT:
		return b
	var a := _sel_id(_a_opt)
	return a if a != ExperimentStore.CURRENT else ""


func _refresh_fork_buttons() -> void:
	var t := _target_fork()
	var which := "B" if t == _sel_id(_b_opt) else "A"
	for pair in [[_edit_btn, "Edit %s…"], [_rename_btn, "Rename %s…"], [_delete_btn, "Delete %s"]]:
		var bt: Button = pair[0]
		bt.text = str(pair[1]) % which
		bt.disabled = t.is_empty()
		bt.tooltip_text = "" if not t.is_empty() else "Pick a fork in A or B — this world itself is edited in the graph as usual"
	_delete_armed = false
	_forks_note.text = "%s in this world" % UiText.count(_store.forks.size(), "fork")
	_rename_row.visible = false


func _save_store() -> void:
	if not _store.save_to(_store_path) and _main != null and _main.has_method("show_toast"):
		_main.call("show_toast", "Could not save this world's experiments.")


func _current_graph() -> Dictionary:
	var gv := _main.find_child("SystemGraphView", true, false) if _main != null else null
	var m: Object = gv.get("model") if gv != null else null
	return m.call("serialize") if m != null else {}


func _variant_graph(id: String) -> Dictionary:
	if id == ExperimentStore.CURRENT:
		return _current_graph()
	return _store.get_fork(id).get("graph", {})


func _on_new_fork() -> void:
	if _store_path.is_empty():
		_banner.show_alert(AlertBanner.WARN, "Forks need a world — load one first.")
		return
	var id := _store.add_fork("Fork of this world", _current_graph())
	_save_store()
	_refresh_variants(_sel_id(_a_opt), id)
	_banner.show_alert(AlertBanner.INFO,
		"Made “%s”. Edit it to change what differs — add an automation, resize the battery, …" % _variant_name(id))


func _on_edit_fork() -> void:
	var t := _target_fork()
	if t.is_empty() or _main == null or not _main.has_method("edit_experiment_fork"):
		return
	_main.call("edit_experiment_fork", t)


func _on_rename_toggle() -> void:
	var t := _target_fork()
	if t.is_empty():
		return
	_rename_row.visible = not _rename_row.visible
	_rename_edit.text = _variant_name(t)
	if _rename_row.visible:
		_rename_edit.grab_focus()


func _on_rename_confirm() -> void:
	var t := _target_fork()
	if t.is_empty() or not _store.rename(t, _rename_edit.text):
		return
	_save_store()
	_refresh_variants(_sel_id(_a_opt), _sel_id(_b_opt))


func _on_delete_fork() -> void:
	var t := _target_fork()
	if t.is_empty():
		return
	if not _delete_armed:
		_delete_armed = true
		_delete_btn.text = "Click again to delete “%s”" % _variant_name(t)
		return
	_store.remove(t)
	_save_store()
	_refresh_variants(ExperimentStore.CURRENT, "")


func _select_metric(key: String) -> void:
	for i in AbExperiment.METRICS.size():
		if str(AbExperiment.METRICS[i][0]) == key:
			_metric_opt.select(i)
			return


func _metric_key() -> String:
	return str(AbExperiment.METRICS[maxi(_metric_opt.selected, 0)][0])


func _run_ab(s: Vector2) -> void:
	var a := _sel_id(_a_opt)
	var b := _sel_id(_b_opt)
	if a == b:
		_banner.show_alert(AlertBanner.WARN, "A and B are the same version — pick two different ones.")
		return
	var variants: Array = []
	for pair in [[a, "A"], [b, "B"]]:
		var g := _variant_graph(str(pair[0]))
		if g.is_empty():
			_banner.show_alert(AlertBanner.WARN, "%s has no graph to simulate." % str(pair[1]))
			return
		variants.append({"id": str(pair[0]), "label": "%s · %s" % [str(pair[1]), _variant_name(str(pair[0]))], "graph": g})
	if _ab == null:
		_ab = AbExperiment.new()
		_ab.name = "AbExperiment"
		add_child(_ab)
		_ab.progress.connect(_on_progress)
		_ab.finished.connect(_on_finished)
	var err := _ab.start(_main, s.x, s.y, variants)
	if not err.is_empty():
		_banner.show_alert(AlertBanner.WARN, err)
		return
	_store.last = {"mode": MODE_AB, "a": a, "b": b, "metric": _metric_key()}
	_save_store()
	_banner.clear()
	_set_running(true)


func _show_ab_result(res: Dictionary) -> void:
	var sims: Array = res.get("sims", [])
	if sims.size() < 2:
		return
	var span: Vector2 = res.get("span", Vector2.ZERO)
	var ea: Dictionary = sims[0]["energy"]
	var eb: Dictionary = sims[1]["energy"]
	var m := AbExperiment.metric(_metric_key())
	var c := AbExperiment.compare(ea, eb, str(m[0]), str(m[3]))
	var unit := str(m[2])
	var head := ""
	match str(c["winner"]):
		"tie":
			head = "No real difference in %s over %s (A %s, B %s)." % [str(m[1]).to_lower(),
				UiText.duration(span.y - span.x), _fmt_metric(float(c["a"]), unit), _fmt_metric(float(c["b"]), unit)]
		"a", "b":
			var w := str(c["winner"]).to_upper()
			var who: String = str(sims[0 if w == "A" else 1]["label"])
			head = "%s wins on %s over %s: A %s, B %s (B − A %s%s)." % [who, str(m[1]).to_lower(),
				UiText.duration(span.y - span.x), _fmt_metric(float(c["a"]), unit),
				_fmt_metric(float(c["b"]), unit), _signed(float(c["delta"]), unit),
				"" if is_nan(float(c["pct"])) else ", %+.0f %%" % float(c["pct"])]
		_:
			head = "Not enough to compare on %s." % str(m[1]).to_lower()
	_banner.show_alert(AlertBanner.OK if str(c["winner"]) in ["a", "b"] else AlertBanner.INFO, head)
	var notes: Array = [str((res.get("report", {}) as Dictionary).get("start_soc_note", ""))]
	for sm in sims:
		var n := int(sm.get("automation_rules", 0))
		notes.append("%s: %s, %s in the span." % [str(sm["label"]), UiText.count(n, "automation"),
			UiText.count((sm.get("automation_log", []) as Array).size(), "switch", "switches")])
	notes.append("Same sun, weather and starting battery for both; tanks and machines held as they are now.")
	_notes.text = "\n".join(notes)
	_notes.visible = true
	for ch in _legend.get_children():
		ch.queue_free()
	var items: Array = []
	for k in 2:
		items.append({"series": sims[k]["series"], "color": SIM_COLORS[k]})
		_legend_item(str(sims[k]["label"]), SIM_COLORS[k])
	_chart.set_data(items, span, _clock())
	_fill_ab_table(sims)
	_fill_ab_days(sims)
	_fill_ab_autos(sims)


func _fill_ab_table(sims: Array) -> void:
	for ch in _table.get_children():
		ch.queue_free()
	_table.columns = 5
	_cell(_table, "", true)
	_cell(_table, str(sims[0]["label"]), true, SIM_COLORS[0])
	_cell(_table, str(sims[1]["label"]), true, SIM_COLORS[1])
	_cell(_table, "B − A", true)
	_cell(_table, "Better", true)
	var ea: Dictionary = sims[0]["energy"]
	var eb: Dictionary = sims[1]["energy"]
	var head_key := _metric_key()
	var rows: Array = AbExperiment.METRICS.duplicate()
	rows.insert(1, ["solar_kwh", "Solar made", "kWh", "higher"])
	for m in rows:
		var c := AbExperiment.compare(ea, eb, str(m[0]), str(m[3]))
		var bold := str(m[0]) == head_key
		var name_lbl := _cell(_table, str(m[1]) + ("  ◀ score" if bold else ""), bold)
		if bold:
			name_lbl.add_theme_color_override("font_color", UITheme.C_TEXT)
		_cell(_table, _fmt_metric(float(c["a"]), str(m[2])))
		_cell(_table, _fmt_metric(float(c["b"]), str(m[2])))
		var d := float(c["delta"])
		_cell(_table, _signed(d, str(m[2])) + ("" if is_nan(float(c["pct"])) or absf(float(c["pct"])) < 0.5 else "  (%+.0f %%)" % float(c["pct"])),
			false, UITheme.C_TEXT_S)
		var w := str(c["winner"])
		var col := SIM_COLORS[0] if w == "a" else (SIM_COLORS[1] if w == "b" else UITheme.C_TEXT_M)
		_cell(_table, {"a": "A", "b": "B", "tie": "same"}.get(w, "—"), false, col)


func _fill_ab_days(sims: Array) -> void:
	for ch in _days.get_children():
		ch.queue_free()
	var da: Array = (sims[0]["energy"] as Dictionary).get("days", [])
	var db: Array = (sims[1]["energy"] as Dictionary).get("days", [])
	_days.columns = 5
	for h in ["Day", "Asked for A / B", "Delivered A / B", "AC off A / B", "Battery at end A / B"]:
		_cell(_days, h, true)
	var clock := _clock()
	for i in mini(da.size(), db.size()):
		var a: Dictionary = da[i]
		var b: Dictionary = db[i]
		var date := ""
		if clock != null:
			var dt: Dictionary = clock.call("abs_hours_to_date", float(a.get("start_abs", 0.0)))
			date = "%d/%d" % [int(dt["month"]), int(dt["day"])]
		_cell(_days, date)
		_cell(_days, "%s / %s" % [UiText.num(float(a["demand_kwh"]), "kWh"), UiText.num(float(b["demand_kwh"]), "kWh")])
		_cell(_days, "%s / %s" % [UiText.num(float(a["served_kwh"]), "kWh"), UiText.num(float(b["served_kwh"]), "kWh")])
		_cell(_days, "%s / %s" % [UiText.duration(float(a["ac_off_h"])), UiText.duration(float(b["ac_off_h"]))])
		_cell(_days, "%s / %s" % [_pct(float(a["soc_end_pct"])), _pct(float(b["soc_end_pct"]))])


func _fill_ab_autos(sims: Array) -> void:
	for ch in _autos.get_children():
		ch.queue_free()
	var any := false
	var clock := _clock()
	for k in 2:
		var lg: Array = sims[k].get("automation_log", [])
		var g := _variant_graph(str(sims[k]["id"]))
		var names := {}
		for it in g.get("items", []):
			names[str(it.get("id", ""))] = str((it.get("specs", {}) as Dictionary).get("name", it.get("id", "")))
		var shown := 0
		for e in lg:
			if shown >= 24:
				_cell(_autos, ["A", "B"][k], false, SIM_COLORS[k])
				_cell(_autos, "… and %s more" % UiText.count(lg.size() - shown, "switch", "switches"), false, UITheme.C_TEXT_M)
				_cell(_autos, "")
				_cell(_autos, "")
				break
			any = true
			_cell(_autos, ["A", "B"][k], false, SIM_COLORS[k])
			_cell(_autos, SiteTime.format_abs(clock, float(e["t"])) if clock != null else "")
			var nm := str(names.get(str(e["item_id"]), e["item_id"]))
			_cell(_autos, "%s %s" % [nm, {"turn_on": "on", "turn_off": "off", "toggle": "toggled"}.get(str(e["command"]), str(e["command"]))],
				false, UITheme.C_OK if str(e["command"]) == "turn_on" else UITheme.C_TEXT)
			_cell(_autos, str(e["alias"]), false, UITheme.C_TEXT_S)
			shown += 1
	_autos_header.visible = any
	_autos.visible = any


static func _fmt_metric(v: float, unit: String) -> String:
	if is_nan(v):
		return "—"
	match unit:
		"h":
			return UiText.duration(v)
		"%":
			return "%.0f %%" % v
		"":
			return "%.2f" % v
	return UiText.num(v, unit)


static func _signed(v: float, unit: String) -> String:
	if is_nan(v):
		return "—"
	var sgn := "+" if v > 0.0 else ("−" if v < 0.0 else "±")
	var mag := absf(v)
	match unit:
		"h":
			return sgn + UiText.duration(mag)
		"%":
			return "%s%.0f pts" % [sgn, mag]
		"":
			return "%s%.2f" % [sgn, mag]
	return sgn + UiText.num(mag, unit)


## For the harness: A / B by variant id over [start, end), then run.
func run_ab_with(a_id: String, b_id: String, start_abs: float, end_abs: float, metric_key: String = "") -> void:
	_set_mode(MODE_AB)
	_store = ExperimentStore.load_from(_store_path)
	_refresh_variants(a_id, b_id)
	if not metric_key.is_empty():
		_select_metric(metric_key)
	var clock := _clock()
	_start_edit.text = SiteTime.format_abs(clock, start_abs)
	_end_edit.text = SiteTime.format_abs(clock, end_abs)
	_span_opt.select(_spans().size() - 1)
	_refresh_range_note()
	_on_run()
