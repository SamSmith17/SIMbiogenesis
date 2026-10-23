class_name AbExperiment
extends Node

## A vs B: two versions of this world (the live one and / or forks from the
## world's ExperimentStore) simulated over the same span, from the same
## battery, under the same sun and weather — each an ExperimentWorld (its own
## graph copy, its own automations switching its own loads) stepping an
## ExperimentEnergyRun. Nothing live is touched.
##
## Variants: [{id, label, graph}] (graph = GraphModel.serialize()). The
## result carries each sim's series, ExperimentScore.energy, and the
## automation switch log; compare(a, b) and METRICS turn two energy
## summaries into "B is better by …".

signal progress(fraction: float, text: String)
signal finished(result: Dictionary)

const FRAME_BUDGET_MS := 6.0
const MAX_SPAN_H := 24.0 * 62.0

## [key, label, unit, better] — `better` is "lower" or "higher". The first is
## the default headline: what the loads ASKED for is an automation's direct
## saving. What was delivered is capped by the battery — on a short winter
## site a nightly shutdown can save 125 kWh of demand and change delivered
## energy by 2 kWh, the difference showing up as hours with the AC off.
const METRICS := [
	["demand_kwh", "Energy the loads asked for", "kWh", "lower"],
	["served_kwh", "Energy delivered", "kWh", "lower"],
	["unserved_kwh", "Demand not served", "kWh", "lower"],
	["ac_off_h", "Time with AC off", "h", "lower"],
	["curtailed_kwh", "Solar wasted (battery full)", "kWh", "lower"],
	["soc_end_pct", "Battery at the end", "%", "higher"],
	["soc_min_pct", "Lowest battery", "%", "higher"],
	["cycles", "Battery cycles", "", "lower"],
	["tank_empty_h", "Hours tanks sat empty", "h", "lower"],
	["machine_down_h", "Hours machines were blocked or starved", "h", "lower"],
]

var _runs: Array = []
var _span := Vector2.ZERO
var _step := 1.0 / 60.0
var _running := false
var _start_note := ""


func _ready() -> void:
	set_process(false)


func is_running() -> bool:
	return _running


## Returns "" or why it cannot start.
func start(main: Node, start_abs: float, end_abs: float, variants: Array) -> String:
	if _running:
		return "A comparison is already running."
	var su := CalibrationExperiment._find_solar_ui(main)
	var clock: Object = main.get("clock") if main != null else null
	if su == null or clock == null:
		return "This scene has no solar system to simulate."
	if end_abs <= start_abs:
		return "Pick a span that ends after it starts."
	if end_abs - start_abs > MAX_SPAN_H:
		return "Pick a span of at most %d days." % int(MAX_SPAN_H / 24.0)
	if variants.size() < 2:
		return "Pick two versions to compare."
	_span = Vector2(start_abs, end_abs)
	_step = CalibrationExperiment.step_for(end_abs - start_abs)
	var bat := ExperimentEvaluator.battery_of(su)
	var soc0 := float(su.get("battery_kwh_stored")) if su.get("battery_kwh_stored") != null else 0.5 * float(bat["cap_kwh"])
	_start_note = "Both start from the battery as it is now (%s)." % UiText.pct(soc0 / maxf(float(bat["cap_kwh"]), 1e-6))
	_runs.clear()
	var host := main.find_child("SystemGraphView", true, false)
	for v in variants:
		var w := ExperimentWorld.from_graph(v["graph"] as Dictionary, su, clock)
		w.enable_flow(host)
		_runs.append({"id": str(v["id"]), "label": str(v["label"]), "world": w,
			"run": make_run(w, bat, start_abs, end_abs, _step, soc0)})
	_running = true
	set_process(true)
	return ""


## One variant's run on `w` (shared with the selftest).
static func make_run(w: ExperimentWorld, bat: Dictionary, a: float, b: float, step: float,
		soc0: float) -> ExperimentEnergyRun:
	var r := ExperimentEnergyRun.new()
	r.floor_pct = float(bat["floor_pct"])
	r.resume_pct = float(bat["resume_pct"])
	r.ceff = float(bat["ceff"])
	r.deff = float(bat["deff"])
	r.configure(a, b, step, float(bat["cap_kwh"]), soc0, w.inputs_at)
	r.before_step = w.before_step
	return r


func cancel() -> void:
	_running = false
	set_process(false)


func _process(_delta: float) -> void:
	if not _running or _runs.is_empty():
		set_process(false)
		return
	var t0 := Time.get_ticks_usec()
	var all_done := false
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
	progress.emit(f / float(_runs.size()), "Simulating %s for %s…" % [
		UiText.duration(_span.y - _span.x), UiText.count(_runs.size(), "version")])
	if all_done:
		_running = false
		set_process(false)
		finished.emit(result())


func result() -> Dictionary:
	var sims: Array = []
	for e in _runs:
		var r: ExperimentEnergyRun = e["run"]
		var w: ExperimentWorld = e["world"]
		r.series.label = str(e["label"])
		var res := w.resource_summary()
		var en := ExperimentScore.energy(r.series)
		en.merge(res.get("totals", {}), true)
		sims.append({"id": e["id"], "label": e["label"], "series": r.series, "energy": en,
			"resources": res,
			"automation_rules": w.automations.rules.size(), "automation_log": w.automations.log})
	return {"mode": "ab", "span": _span, "step_h": _step, "sims": sims,
		"report": {"start_soc_note": _start_note}}


## B against A on one metric: {a, b, delta (b − a), pct (of a), winner:
## "a" | "b" | "tie"}. A tie is within 0.5 % of the larger value (or 0.01).
static func compare(ea: Dictionary, eb: Dictionary, key: String, better: String) -> Dictionary:
	var a := float(ea.get(key, NAN))
	var b := float(eb.get(key, NAN))
	var out := {"a": a, "b": b, "delta": b - a, "pct": NAN, "winner": "tie"}
	if is_nan(a) or is_nan(b):
		out["winner"] = ""
		return out
	if absf(a) > 1e-9:
		out["pct"] = 100.0 * (b - a) / absf(a)
	var tol := maxf(0.005 * maxf(absf(a), absf(b)), 0.01)
	if absf(b - a) <= tol:
		return out
	var b_better := b < a if better == "lower" else b > a
	out["winner"] = "b" if b_better else "a"
	return out


static func metric(key: String) -> Array:
	for m in METRICS:
		if str(m[0]) == key:
			return m
	return METRICS[0]
