class_name SimBakeStepper
extends RefCounted

## ONE deterministic simulation step, shared by ChallengeBakeEngine (the
## pre-baked challenges) and SimRenderer (the timeline's Render button). It is
## the loop that used to live inside ChallengeBakeEngine._bake_chunk:
##
##   1. energy  — fill the EnergyTimeline up to the cursor through its
##                evaluator (a pure function of time), read SOC and net;
##   2. people  — NpcPopulationBridge.tick_at in substeps well under its 6 h
##                stochastic catch-up threshold;
##   3. camps   — the view's per-camp power integrator (the challenge bake
##                never ran it, so a camp's processors baked unpowered);
##   4. water   — ResourceFlowEngine.render_step with the AC availability the
##                battery just gave;
##   5. the NEXT step's inputs for the sim-render evaluator: hydro into the
##                battery (the flow engine's graph DC output, one-step lag like
##                the live 0.25 s sync) and whether the inverter serves the
##                loads (SolarUI's floor / resume hysteresis, pure);
##   6. a cache keyframe when one is due.
##
## Everything it touches is handed in (duck-typed), so a headless selftest can
## drive it with a stub SolarUI. The caller owns the clock claim and the
## view's sim-write bracket around a chunk of steps.

enum AcRule {
	FLOOR,       ## the bake's rule: AC while SOC is above the hard floor
	HYSTERESIS,  ## SolarUI's live rule: off at shutdown %, back at resume %
}

var solar: Object = null    ## SolarUI (or a stub with the same surface)
var flow: Object = null     ## ResourceFlowEngine
var bridge: Object = null   ## NpcPopulationBridge, or null
var gv: Object = null       ## SystemGraphView (camp power), or null
var main: Object = null
var model: Object = null
var series: Object = null   ## EnergyTimeline, anchored, evaluator set
var cache: Object = null    ## SimRenderCache, optional

var step_h := 1.0 / 60.0
var pop_substep_h := 0.1
var camp_power := true
## Feed the flow engine's DC generation back into the battery for the next
## step (SimRenderer: yes; the challenge bake keeps its constant aux).
var couple_dc_aux := false
var ac_rule: int = AcRule.FLOOR

## Cost instrumentation, read by the owners' one-line reports.
var pot_solar_kwh := 0.0
var t_solar_us: int = 0
var t_pop_us: int = 0
var t_flow_us: int = 0
var steps: int = 0

var _ac_on := true
var _ac_init := false

const DcPowerWiringScript := preload("res://system_graph/dc_power_wiring.gd")


## Advance everything to `cursor` (one step past the previous call).
## Returns {soc, net, floor_kwh, ac} for failure detection and progress.
func step(cursor: float) -> Dictionary:
	steps += 1
	var t_solar0 := Time.get_ticks_usec()
	series.call("fill_forward_chunk", int(series.call("step_of", cursor)), 1 << 30)
	var s: Dictionary = series.call("sample_at", cursor)
	var soc := float(s.get("soc_kwh", 0.0))
	var net := float(s.get("solar_kw", 0.0)) + float(s.get("aux_kw", 0.0)) \
			- float(s.get("load_kw", 0.0))
	var floor_kwh := float(solar.call("min_battery_kwh"))
	var ac := _ac_for(soc, floor_kwh)
	pot_solar_kwh += float(solar.call("evaluate_potential_solar_at", cursor)) * step_h
	t_solar_us += Time.get_ticks_usec() - t_solar0

	var t_pop0 := Time.get_ticks_usec()
	if bridge != null and bool(bridge.call("has_pop_driven")):
		var t := cursor - step_h
		while t < cursor - 1e-9:
			var sub := minf(pop_substep_h, cursor - t)
			t += sub
			bridge.call("tick_at", model, flow, main, t)
	t_pop_us += Time.get_ticks_usec() - t_pop0

	if camp_power and gv != null and gv.has_method("_tick_camp_power"):
		gv.call("_tick_camp_power", cursor)

	var t_flow0 := Time.get_ticks_usec()
	flow.call("render_step", cursor, step_h, ac)
	t_flow_us += Time.get_ticks_usec() - t_flow0

	if couple_dc_aux:
		var dc_kw := 0.0
		if model != null:
			dc_kw = float(DcPowerWiringScript.sum_graph_dc_generation_kw(model))
		var scene_aux_v: Variant = solar.get("current_aux_generation_kw")
		var scene_aux := float(scene_aux_v) if scene_aux_v != null else 0.0
		solar.set("render_aux_kw", maxf(scene_aux, 0.0) + maxf(dc_kw, 0.0))
		solar.set("render_ac_on", ac)

	if cache != null and bool(cache.call("capture_due", cursor)):
		var internal: Dictionary = flow.call("internal_state_snapshot") \
			if flow.has_method("internal_state_snapshot") else {}
		cache.call("capture", model, flow.call("conn_flow_snapshot"), cursor, internal)
	return {"soc": soc, "net": net, "floor_kwh": floor_kwh, "ac": ac}


## Pure form of SolarUI._apply_soc_hysteresis (the same thresholds SiteProjection
## uses): off once SOC reaches the shutdown %, on again at the resume %.
func _ac_for(soc: float, floor_kwh: float) -> bool:
	if ac_rule == AcRule.FLOOR:
		return soc > floor_kwh + 1e-4
	var cap_v: Variant = solar.get("BATTERY_CAPACITY_KWH")
	var cap := float(cap_v) if cap_v != null else 16.0
	var sd_v: Variant = solar.get("battery_soc_shutdown_pct")
	var rs_v: Variant = solar.get("battery_soc_resume_pct")
	var shutdown_kwh := cap * (float(sd_v) if sd_v != null else 10.0) / 100.0
	var resume_kwh := cap * (float(rs_v) if rs_v != null else 20.0) / 100.0
	if not _ac_init:
		var protect_v: Variant = solar.get("_soc_protect_active")
		_ac_on = not bool(protect_v) if protect_v != null else soc > shutdown_kwh + 1e-6
		_ac_init = true
	elif _ac_on and soc <= shutdown_kwh + 1e-6:
		_ac_on = false
	elif not _ac_on and soc >= resume_kwh - 1e-6:
		_ac_on = true
	return _ac_on


func report_line(label: String, span_h: float) -> String:
	return ("%s: %d steps over %.1f h (solar %.0f ms, population %.0f ms, resources %.0f ms)" % [
		label, steps, span_h, t_solar_us / 1000.0, t_pop_us / 1000.0, t_flow_us / 1000.0])
