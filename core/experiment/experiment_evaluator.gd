class_name ExperimentEvaluator
extends RefCounted

## The inputs an ExperimentEnergyRun steps on: Callable(abs_h) -> {solar_kw,
## raw_kw, aux_kw, load_kw}.
##
## current_world(): the sim of THIS world as configured right now — solar from
## SolarUI's pure evaluator (Meeus sun at the instant + the weather archive /
## forecast at that hour + each placed panel's shade + the graph's DC caps;
## SolarUI holds the array, tilt, inverter and battery the graph pushed to
## it), and for load and hydro / wind a choice:
##   load  "model":    the graph's AC loads as they are switched now
##                     (GraphAcLoad at the run's start, held — automations do
##                     not switch them inside a run yet);
##         "observed": the real load at each hour (the calibration's way to
##                     read the solar + battery model apart from the loads).
##   aux   "held":     today's hydro / wind / other DC output, held;
##         "observed": the real aux readings where Home Assistant has them;
##         "none":     zero.
## A missing observed value falls back to the model at that hour.

const LOAD_MODEL := "model"
const LOAD_OBSERVED := "observed"
const AUX_HELD := "held"
const AUX_OBSERVED := "observed"
const AUX_NONE := "none"


static func current_world(solar_ui: Node, graph_model: Object, observed: ExperimentSeries,
		load_mode: String, aux_mode: String) -> Callable:
	var model_load := model_load_kw(solar_ui, graph_model)
	var held_aux := 0.0
	if aux_mode == AUX_HELD and solar_ui != null and solar_ui.has_method("evaluate_aux_at"):
		held_aux = maxf(float(solar_ui.call("evaluate_aux_at", 0.0)), 0.0)
	return func(abs_h: float) -> Dictionary:
		var pair := Vector2.ZERO
		if solar_ui != null and solar_ui.has_method("evaluate_solar_pair_at"):
			pair = solar_ui.call("evaluate_solar_pair_at", abs_h)
		var load := model_load
		if load_mode == LOAD_OBSERVED and observed != null:
			var v := observed.value_at("load_kw", abs_h)
			if not is_nan(v):
				load = v
		var aux := held_aux
		if aux_mode == AUX_OBSERVED:
			aux = 0.0
			if observed != null:
				var a := observed.value_at("aux_kw", abs_h)
				if not is_nan(a):
					aux = a
		elif aux_mode == AUX_NONE:
			aux = 0.0
		return {"solar_kw": pair.y, "raw_kw": pair.x, "aux_kw": aux, "load_kw": load}


## The graph's wired AC load right now (kW): what the inverter serves, or —
## while low-SOC protection has shed it — what the loads ask for.
static func model_load_kw(solar_ui: Node, graph_model: Object) -> float:
	if graph_model == null:
		return 0.0
	var tree: SceneTree = solar_ui.get_tree() if solar_ui != null else null
	var served := GraphAcLoad.compute_kw(graph_model, tree) if tree != null else 0.0
	if served > 0.0:
		return served
	return GraphAcLoad.demand_watts(graph_model) / 1000.0


## The battery the sim uses: {cap_kwh, ceff, deff, floor_pct, resume_pct}.
static func battery_of(solar_ui: Node) -> Dictionary:
	var out := {"cap_kwh": 16.0, "ceff": 0.95, "deff": 0.95, "floor_pct": 10.0, "resume_pct": 20.0}
	if solar_ui == null:
		return out
	var cap: Variant = solar_ui.get("BATTERY_CAPACITY_KWH")
	if cap != null:
		out["cap_kwh"] = float(cap)
	# AC is shed at the protection's shutdown % (never below the chemistry
	# floor) and comes back at its resume % — SolarUI._apply_soc_hysteresis.
	var fl: Variant = solar_ui.get("MIN_BATTERY_PERCENT")
	var sd: Variant = solar_ui.get("battery_soc_shutdown_pct")
	out["floor_pct"] = maxf(float(fl) if fl != null else 10.0, float(sd) if sd != null else 0.0)
	var rs: Variant = solar_ui.get("battery_soc_resume_pct")
	if rs != null:
		out["resume_pct"] = float(rs)
	out["resume_pct"] = maxf(float(out["resume_pct"]), float(out["floor_pct"]))
	return out
