class_name CalibrationExperiment
extends Node

## "Does the sim match reality?" for a past span:
##   1. fetch what really happened (Home Assistant history, or the imported
##      CSV clip) onto a grid of the span;
##   2. simulate this world over the same grid, started at the battery the
##      real one had at the span's start — twice when the real load is known:
##        "Sim (model loads)":    the graph's loads, the whole model on trial;
##        "Sim (real loads)":     the real load replayed, so what is left is
##                                the solar + battery model's error alone;
##   3. score each sim against reality (ExperimentScore.calibration).
## The runs step in the background on a frame budget and touch nothing live:
## no clock claim, no model write, no SolarUI state.

signal progress(fraction: float, text: String)
signal finished(result: Dictionary)

const SOURCE_HA := "ha"
const SOURCE_CSV := "csv"
const MAX_SPAN_H := 24.0 * 62.0
const FRAME_BUDGET_MS := 6.0

var _main: Node = null
var _solar_ui: Node = null
var _model: Object = null
var _clock: Object = null
var _span := Vector2.ZERO
var _step := 1.0 / 60.0
var _observed: ExperimentSeries = null
var _report: Dictionary = {}
var _runs: Array = []      # [{id, label, run: ExperimentEnergyRun}]
var _fetch: HaHistoryFetch = null
var _running := false
var _cancelled := false


func _ready() -> void:
	# _process is on by default for a node that defines it; this one steps
	# only once the sims exist (_begin_sims), never while history is fetched.
	set_process(false)


## The sample step for a span: 1 min to two days, 5 min to two weeks, 15 min.
static func step_for(span_h: float) -> float:
	if span_h <= 48.0 + 1e-6:
		return 1.0 / 60.0
	if span_h <= 336.0 + 1e-6:
		return 5.0 / 60.0
	return 0.25


func is_running() -> bool:
	return _running


## `opts`: {source: "ha" | "csv"}. Returns "" or why it cannot start.
func start(main: Node, start_abs: float, end_abs: float, opts: Dictionary = {}) -> String:
	if _running:
		return "A comparison is already running."
	_main = main
	_solar_ui = _find_solar_ui(main)
	var gv := _find(main, "SystemGraphView")
	_model = gv.get("model") if gv != null else null
	_clock = main.get("clock") if main != null else null
	if _solar_ui == null or _clock == null:
		return "This scene has no solar system to simulate."
	if end_abs <= start_abs:
		return "Pick a span that ends after it starts."
	if end_abs - start_abs > MAX_SPAN_H:
		return "Pick a span of at most %d days." % int(MAX_SPAN_H / 24.0)
	var now_abs := SiteTime.unix_to_site_abs(_clock, Time.get_unix_time_from_system())
	if str(opts.get("source", SOURCE_HA)) == SOURCE_HA and start_abs >= now_abs:
		return "Reality has not happened yet for that span — pick one in the past."
	_span = Vector2(start_abs, minf(end_abs, now_abs) if str(opts.get("source", SOURCE_HA)) == SOURCE_HA else end_abs)
	_step = step_for(_span.y - _span.x)
	_cancelled = false
	_running = true
	_runs.clear()
	_observed = null
	var cap := float(ExperimentEvaluator.battery_of(_solar_ui)["cap_kwh"])
	if str(opts.get("source", SOURCE_HA)) == SOURCE_CSV:
		var clip: Node = _solar_ui.get("_clip_player") if "_clip_player" in _solar_ui else null
		if clip == null or not is_instance_valid(clip) or not clip.has_method("get_role_samples"):
			_running = false
			return "No CSV clip is loaded. Import one with 📥 on the timeline first."
		var roles: Dictionary = clip.call("get_role_samples")
		var viw: Variant = _solar_ui.get("ha_values_in_watts")
		_observed = ExperimentObserved.from_csv_roles(roles, _clock, _span.x, _span.y, _step, cap,
			bool(viw) if viw != null else true)
		_observed.label = "Observed (CSV clip)"
		_report = {"channels": {}, "missing": {}, "error": ""}
		call_deferred("_begin_sims")
		return ""
	var svc := get_node_or_null("/root/HomeAssistant")
	var linker := _find(main, "HAEntityLinker")
	_fetch = HaHistoryFetch.new()
	_fetch.name = "HistoryFetch"
	add_child(_fetch)
	_fetch.finished.connect(_on_fetched)
	progress.emit(0.0, "Asking Home Assistant for what happened…")
	_fetch.start(svc, linker, _clock, _span.x, _span.y, _step, cap)
	return ""


func cancel() -> void:
	_cancelled = true
	_running = false
	if _fetch != null and is_instance_valid(_fetch):
		_fetch.cancel()
	set_process(false)


func _on_fetched(series: ExperimentSeries, report: Dictionary) -> void:
	if _cancelled:
		return
	_observed = series
	_report = report
	_begin_sims()


func _begin_sims() -> void:
	if _cancelled:
		return
	var bat := ExperimentEvaluator.battery_of(_solar_ui)
	var start_soc := float(_solar_ui.get("battery_kwh_stored")) if _solar_ui.get("battery_kwh_stored") != null else 0.5 * float(bat["cap_kwh"])
	var soc_note := "the battery as it is now (no real reading at the start)"
	if _observed != null and _observed.has("soc_kwh"):
		for i in mini(_observed.size(), int(ceil(6.0 / _step))):
			var v := _observed.value("soc_kwh", i)
			if not is_nan(v):
				start_soc = v
				soc_note = "the real battery at the start"
				break
	_report["start_soc_note"] = soc_note
	var aux_mode := ExperimentEvaluator.AUX_OBSERVED \
		if _observed != null and _observed.has("aux_kw") else ExperimentEvaluator.AUX_HELD
	var plans := [["model", "Sim · model loads", ExperimentEvaluator.LOAD_MODEL]]
	if _observed != null and _observed.has("load_kw"):
		plans.append(["real_load", "Sim · real loads", ExperimentEvaluator.LOAD_OBSERVED])
	for p in plans:
		# Each sim gets its own copy of the graph, with the graph's automations
		# switching its loads in sim time (ExperimentWorld).
		var w := ExperimentWorld.from_live(_model as GraphModel, _solar_ui, _clock)
		w.observed = _observed
		w.load_mode = str(p[2])
		w.aux_mode = aux_mode
		var r := ExperimentEnergyRun.new()
		r.floor_pct = float(bat["floor_pct"])
		r.resume_pct = float(bat["resume_pct"])
		r.ceff = float(bat["ceff"])
		r.deff = float(bat["deff"])
		r.configure(_span.x, _span.y, _step, float(bat["cap_kwh"]), start_soc, w.inputs_at)
		if str(p[2]) == ExperimentEvaluator.LOAD_MODEL:
			r.before_step = w.before_step
		r.series.label = str(p[1])
		if aux_mode == ExperimentEvaluator.AUX_HELD:
			r.series.notes["aux_kw"] = "hydro / wind held at today's rate"
		_runs.append({"id": str(p[0]), "label": str(p[1]), "run": r, "load_mode": str(p[2]),
			"world": w})
	set_process(true)


func _process(_delta: float) -> void:
	if not _running or _runs.is_empty():
		set_process(false)
		return
	var t0 := Time.get_ticks_usec()
	var all_done := true
	while float(Time.get_ticks_usec() - t0) / 1000.0 < FRAME_BUDGET_MS:
		all_done = true
		for e in _runs:
			var r: ExperimentEnergyRun = e["run"]
			if not r.is_done():
				r.step_chunk(60)
				all_done = all_done and r.is_done()
		if all_done:
			break
	var f := 0.0
	for e in _runs:
		f += (e["run"] as ExperimentEnergyRun).progress()
	f = f / maxf(float(_runs.size()), 1.0)
	progress.emit(f, "Simulating %s…" % UiText.duration(_span.y - _span.x))
	if all_done:
		set_process(false)
		_running = false
		_finish()


func _finish() -> void:
	var sims: Array = []
	for e in _runs:
		var r: ExperimentEnergyRun = e["run"]
		var cal := ExperimentScore.calibration(_observed, r.series) if _observed != null else {}
		var w: ExperimentWorld = e["world"]
		var used_autos := str(e["load_mode"]) == ExperimentEvaluator.LOAD_MODEL
		sims.append({"id": e["id"], "label": e["label"], "series": r.series,
			"energy": ExperimentScore.energy(r.series), "calibration": cal,
			"load_mode": e["load_mode"],
			"automation_rules": w.automations.rules.size() if used_autos else 0,
			"automation_log": w.automations.log if used_autos else []})
	finished.emit({"span": _span, "step_h": _step, "observed": _observed,
		"observed_energy": ExperimentScore.energy(_observed) if _observed != null else {},
		"sims": sims, "report": _report})


static func _find(main: Node, n: String) -> Node:
	if main == null:
		return null
	return main.find_child(n, true, false)


static func _find_solar_ui(main: Node) -> Node:
	if main == null:
		return null
	var su := main.get_node_or_null("UILayer/SolarUI")
	return su if su != null else main.find_child("SolarUI", true, false)
