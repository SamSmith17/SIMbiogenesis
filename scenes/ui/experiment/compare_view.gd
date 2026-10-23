extends Node

## ⧉ Compare — "does the sim match reality?"
##
## Pick a past span and where reality comes from (this world's Home Assistant
## sensors, or an imported CSV clip); Run simulates this world over the same
## span from the battery the real one had at the start and lays the curves on
## one time axis with the error numbers (ExperimentScore.calibration: ASHRAE
## Guideline 14 hourly NMBE / CV(RMSE) per energy channel, mean error in
## points for the battery). Two sims when the real load is known: the graph's
## own loads, and the real loads replayed, so a gap in solar / battery can be
## told apart from a gap in the loads.
##
## Opened by TimelineUI's ⧉ button (Main.open_compare_view). Runs in the
## background and never touches the clock, the graph or the battery.

const SPANS := [
	["Last 24 hours", 24.0], ["Last 3 days", 72.0], ["Last 7 days", 168.0],
	["Last 14 days", 336.0], ["Timeline selection", -1.0], ["Custom", 0.0],
]
const SPAN_SELECTION := 4
const SPAN_CUSTOM := 5
const SOURCES := [["Home Assistant history", CalibrationExperiment.SOURCE_HA],
	["Imported CSV clip", CalibrationExperiment.SOURCE_CSV]]
const C_OBS := Color(0.93, 0.95, 0.98)
const SIM_COLORS := [UITheme.C_AMBER, UITheme.C_PRIMARY, UITheme.C_LAVENDER]
const VERDICT_WORDS := {"good": "Matches", "fair": "Roughly", "poor": "Off", "n/a": "—"}

var _main: Node = null
var _selection := Vector2(NAN, NAN)
var _frame: ModalFrame = null
var _exp: CalibrationExperiment = null
var _result: Dictionary = {}

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


func open_on(main: Node, selection: Vector2) -> void:
	_main = main
	_selection = selection
	_build()
	_span_opt.select(SPAN_SELECTION if not is_nan(selection.x) else 2)
	_on_span_preset(_span_opt.selected)
	_frame.open()


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

	b.add_child(SectionHeader.make("Span and source", "calendar"))
	var r1 := _row(b)
	_lbl(r1, "Reality from")
	_source_opt = OptionButton.new()
	for s in SOURCES:
		_source_opt.add_item(str(s[0]))
	_source_opt.item_selected.connect(func(_i: int) -> void: _refresh_range_note())
	r1.add_child(_source_opt)
	_lbl(r1, "Span")
	_span_opt = OptionButton.new()
	for s in SPANS:
		_span_opt.add_item(str(s[0]))
	_span_opt.set_item_disabled(SPAN_SELECTION, is_nan(_selection.x))
	_span_opt.item_selected.connect(_on_span_preset)
	r1.add_child(_span_opt)
	var r2 := _row(b)
	_lbl(r2, "From")
	_start_edit = _line(r2, "YYYY-MM-DD HH:MM")
	_lbl(r2, "to")
	_end_edit = _line(r2, "YYYY-MM-DD HH:MM")
	for e in [_start_edit, _end_edit]:
		(e as LineEdit).text_changed.connect(func(_t: String) -> void:
			_span_opt.select(SPAN_CUSTOM)
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

	b.add_child(SectionHeader.make("How close", "target",
		"energy: ASHRAE Guideline 14 hourly NMBE ≤ 10 %, CV(RMSE) ≤ 30 %"))
	_table = GridContainer.new()
	_table.add_theme_constant_override("h_separation", 18)
	_table.add_theme_constant_override("v_separation", 4)
	b.add_child(_table)

	b.add_child(SectionHeader.make("Day by day", "calendar"))
	_days = GridContainer.new()
	_days.add_theme_constant_override("h_separation", 18)
	_days.add_theme_constant_override("v_separation", 3)
	b.add_child(_days)

	_autos_header = SectionHeader.make("Automations in the sim", "workflow")
	b.add_child(_autos_header)
	_autos = GridContainer.new()
	_autos.columns = 3
	_autos.add_theme_constant_override("h_separation", 18)
	_autos.add_theme_constant_override("v_separation", 3)
	b.add_child(_autos)

	_frame.add_button("Close", ModalFrame.SECONDARY, _frame.close)
	_run_btn = _frame.add_button("Run comparison", ModalFrame.PRIMARY, _on_run)
	_show_empty()


# --- span -------------------------------------------------------------------------

func _on_span_preset(idx: int) -> void:
	var clock := _clock()
	if clock == null:
		return
	var hours := float(SPANS[idx][1])
	var a := NAN
	var e := NAN
	if idx == SPAN_SELECTION and not is_nan(_selection.x):
		a = _selection.x
		e = _selection.y
	elif hours > 0.0:
		var now := SiteTime.unix_to_site_abs(clock, Time.get_unix_time_from_system())
		# End on the last whole hour so two runs a few minutes apart match.
		e = floorf(now)
		a = e - hours
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
	if _exp != null and _exp.is_running():
		_exp.cancel()
		_set_running(false)
		_status.text = "Stopped."
		return
	var s := _span()
	if is_nan(s.x) or is_nan(s.y):
		_refresh_range_note()
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
			break
		var iid := str(e["item_id"])
		if not names.has(iid):
			var it: Dictionary = m.call("get_item", iid) if m != null else {}
			names[iid] = str((it.get("specs", {}) as Dictionary).get("name", iid)) if not it.is_empty() else iid
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
	queue_free()


## For the harness: the last result (empty until a run finishes).
func last_result() -> Dictionary:
	return _result


func is_running() -> bool:
	return _exp != null and _exp.is_running()


## For the harness: set the span and source, then run.
func run_with(start_abs: float, end_abs: float, source: String) -> void:
	var clock := _clock()
	_start_edit.text = SiteTime.format_abs(clock, start_abs)
	_end_edit.text = SiteTime.format_abs(clock, end_abs)
	_span_opt.select(SPAN_CUSTOM)
	_refresh_range_note()
	for i in SOURCES.size():
		if str(SOURCES[i][1]) == source:
			_source_opt.select(i)
	_on_run()
