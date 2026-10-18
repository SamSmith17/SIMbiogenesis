extends SceneTree

## Headless self-test for the sim pre-render substrate (CLAUDE.md "Sim
## pre-render + playback"): SimBakeStepper's contract (step order, population
## substeps, the AC rules, hydro-into-battery coupling, keyframe cadence) over
## stubs, plus the pieces the flow selftest does not reach. The real engine
## integration is pinned in power_system/sources/resource_flow_selftest.gd
## (_test_replay_truncate_and_snapshots, _test_sim_render_cache) and end to
## end by tools/checks/sim_render_probe.gd on the Mount Vernon sandbox.
## Run (--import first so the class_names register):
##   Godot.exe.exe --headless --path . --script core/sim/sim_render_selftest.gd
##
## Carries EXPECTED_CHECKS: a Godot runtime error aborts the enclosing test
## function while the suite still prints PASS.

const EXPECTED_CHECKS := 27

const StepperScript := preload("res://core/sim/sim_bake_stepper.gd")
const CacheScript := preload("res://core/sim/sim_render_cache.gd")
const GraphModelScript := preload("res://system_graph/data/graph_model.gd")

var _checks := 0
var _failures := 0


class StubSolar extends RefCounted:
	var BATTERY_CAPACITY_KWH := 16.0
	var battery_soc_shutdown_pct := 10.0
	var battery_soc_resume_pct := 20.0
	var _soc_protect_active := false
	var current_aux_generation_kw := 0.3
	var render_aux_kw := NAN
	var render_ac_on := true
	var solar_after_h := INF   ## the evaluator's sun comes up at this hour
	func min_battery_kwh() -> float:
		return BATTERY_CAPACITY_KWH * 0.1
	func evaluate_potential_solar_at(_t: float) -> float:
		return 2.0
	func evaluator() -> Callable:
		return func(t: float) -> Dictionary:
			var aux := 0.0 if is_nan(render_aux_kw) else render_aux_kw
			return {"solar_kw": 3.0 if t >= solar_after_h else 0.0, "aux_kw": aux,
				"load_kw": 1.0 if render_ac_on else 0.0}


class StubFlow extends RefCounted:
	var calls: Array = []
	func render_step(t: float, dt: float, ac: bool) -> void:
		calls.append([t, dt, ac])
	func conn_flow_snapshot() -> Dictionary:
		return {"w1": {"rate": float(calls.size()), "active": true, "kind": "water"}}


class StubBridge extends RefCounted:
	var ticks: Array = []
	var pop := true
	func has_pop_driven() -> bool:
		return pop
	func tick_at(_model, _flow, _main, t: float) -> void:
		ticks.append(t)


class StubView extends RefCounted:
	var camp_ticks: Array = []
	func _tick_camp_power(t: float) -> void:
		camp_ticks.append(t)


func _initialize() -> void:
	_test_step_order_and_substeps()
	_test_ac_hysteresis_and_coupling()
	_test_keyframes_and_cost()
	if _checks != EXPECTED_CHECKS:
		_failures += 1
		print("  FAIL: check count %d != EXPECTED_CHECKS %d (a runtime error aborted a test?)" % [
			_checks, EXPECTED_CHECKS])
	if _failures == 0:
		print("SIM RENDER SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("SIM RENDER SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


func _make(solar: StubSolar, soc0: float) -> Dictionary:
	var et := EnergyTimeline.new()
	et.step_hours = 1.0 / 60.0
	et.configure(16.0, 0.95, 0.95, 1.6)
	et.init_anchor(1000.0, soc0, 0.0, 0.0, 1.0)
	et.set_evaluator(solar.evaluator())
	var st = StepperScript.new()
	st.solar = solar
	st.flow = StubFlow.new()
	st.bridge = StubBridge.new()
	st.gv = StubView.new()
	st.model = GraphModelScript.new()
	st.series = et
	st.step_h = 1.0 / 60.0
	return {"stepper": st, "series": et}


func _test_step_order_and_substeps() -> void:
	var solar := StubSolar.new()
	var g := _make(solar, 8.0)
	var st = g["stepper"]
	var et: EnergyTimeline = g["series"]
	# Six 1-minute steps.
	var last := {}
	for i in range(1, 7):
		last = st.step(1000.0 + float(i) / 60.0)
	_check("steps counted", st.steps == 6)
	_check("energy filled to the cursor", et.last_step() == et.step_of(1000.0 + 6.0 / 60.0),
		"last=%d want=%d" % [et.last_step(), et.step_of(1000.0 + 6.0 / 60.0)])
	_check("one render_step per step", (st.flow as StubFlow).calls.size() == 6)
	_check("render_step got the cursor + dt", absf(float((st.flow as StubFlow).calls[5][0]) - (1000.0 + 0.1)) < 1e-9
		and absf(float((st.flow as StubFlow).calls[5][1]) - 1.0 / 60.0) < 1e-12)
	# Population substeps: a 1-min step is below the 0.1 h substep → one tick.
	_check("population ticked once per short step", (st.bridge as StubBridge).ticks.size() == 6,
		"%d" % (st.bridge as StubBridge).ticks.size())
	_check("camp power stepped each step", (st.gv as StubView).camp_ticks.size() == 6)
	_check("step reports soc/net/floor/ac", last.has("soc") and last.has("net")
		and absf(float(last["floor_kwh"]) - 1.6) < 1e-9 and bool(last["ac"]))
	_check("net = solar + aux - load (0 + 0 - 1)", absf(float(last["net"]) + 1.0) < 1e-9,
		"%.4f" % float(last["net"]))
	# A 1 h step is cut into ten 0.1 h population substeps.
	var g2 := _make(solar, 8.0)
	var st2 = g2["stepper"]
	st2.step_h = 1.0
	st2.step(1001.0)
	var ticks: Array = (st2.bridge as StubBridge).ticks
	_check("1 h step → 10 population substeps", ticks.size() == 10, "%d" % ticks.size())
	_check("substeps end exactly on the cursor", absf(float(ticks[ticks.size() - 1]) - 1001.0) < 1e-9)
	(st2.bridge as StubBridge).pop = false
	st2.step(1002.0)
	_check("no pop-driven habitat → no population ticks", (st2.bridge as StubBridge).ticks.size() == 10)
	_check("pot_solar accumulates 2 kW × dt", absf(st2.pot_solar_kwh - 4.0) < 1e-9, "%.4f" % st2.pot_solar_kwh)


func _test_ac_hysteresis_and_coupling() -> void:
	# FLOOR rule (the bake): AC while SOC > floor.
	var solar := StubSolar.new()
	var g := _make(solar, 1.7)   # just above the 1.6 floor, draining 1 kW
	var st = g["stepper"]
	var r: Dictionary = st.step(1000.0 + 1.0 / 60.0)
	_check("FLOOR rule: AC on above the floor", bool(r["ac"]))
	for i in range(2, 20):
		r = st.step(1000.0 + float(i) / 60.0)
	_check("FLOOR rule: AC off once pinned at the floor", not bool(r["ac"])
		and absf(float(r["soc"]) - 1.6) < 1e-6, "soc=%.4f ac=%s" % [float(r["soc"]), str(r["ac"])])
	_check("FLOOR rule never touches the render inputs", is_nan(solar.render_aux_kw) and solar.render_ac_on)
	# HYSTERESIS rule (the sim render): off at 10 %, loads shed, back at 20 %.
	var solar2 := StubSolar.new()
	var g2 := _make(solar2, 2.0)   # 12.5 %, draining 1 kW
	var st2 = g2["stepper"]
	st2.ac_rule = StepperScript.AcRule.HYSTERESIS
	st2.couple_dc_aux = true
	var t := 1000.0
	var ac_off_at := NAN
	for i in range(1, 181):   # 3 h
		t = 1000.0 + float(i) / 60.0
		var rr: Dictionary = st2.step(t)
		if not bool(rr["ac"]) and is_nan(ac_off_at):
			ac_off_at = t
	_check("HYSTERESIS: AC trips off when SOC reaches 10 %", not is_nan(ac_off_at)
		and ac_off_at > 1000.3 and ac_off_at < 1000.6, "off at %.3f" % ac_off_at)
	_check("coupling wrote render_ac_on = false for the next step", not solar2.render_ac_on)
	var et2: EnergyTimeline = g2["series"]
	var load_after := float(et2.sample_at(1002.0).get("load_kw", 1.0))
	_check("loads shed in the series while AC is off", load_after < 1e-9, "%.3f" % load_after)
	_check("coupling wrote render_aux_kw = scene aux + graph DC (0.3 + 0)",
		absf(solar2.render_aux_kw - 0.3) < 1e-9, "%.4f" % solar2.render_aux_kw)
	_check("render_step received AC off", not bool((st2.flow as StubFlow).calls[(st2.flow as StubFlow).calls.size() - 1][2]))
	# Sun comes up: SOC climbs back and AC returns at 20 %, not at 10 %.
	solar2.solar_after_h = t
	var ac_on_at := NAN
	var soc_at_on := NAN
	for i in range(1, 241):   # 4 more hours of 3 kW sun (+0.3 aux)
		var tt := t + float(i) / 60.0
		var rr: Dictionary = st2.step(tt)
		if bool(rr["ac"]) and is_nan(ac_on_at):
			ac_on_at = tt
			soc_at_on = float(rr["soc"])
	_check("HYSTERESIS: AC back on", not is_nan(ac_on_at))
	_check("… at the resume threshold (20 % = 3.2 kWh), not the floor",
		not is_nan(soc_at_on) and soc_at_on >= 3.2 - 0.06 and soc_at_on < 3.4, "soc at on %.3f" % soc_at_on)


func _test_keyframes_and_cost() -> void:
	var solar := StubSolar.new()
	var g := _make(solar, 8.0)
	var st = g["stepper"]
	var cache = CacheScript.new()
	cache.begin_range(1000.0, 1, 8.0)
	cache.capture(st.model, (st.flow as StubFlow).conn_flow_snapshot(), 1000.0)
	st.cache = cache
	for i in range(1, 61):   # one hour
		st.step(1000.0 + float(i) / 60.0)
	_check("keyframes every 15 sim-min over an hour (1 + 4)", cache.keyframe_count() == 5,
		"%d" % cache.keyframe_count())
	_check("range extended by the captures", cache.covers(1001.0) and not cache.covers(1001.3))
	var last_kf: Dictionary = cache.keyframes[cache.keyframe_count() - 1]
	_check("keyframe carries the conn flow snapshot",
		(last_kf["conns"] as Dictionary).has("w1"))
	var line: String = st.report_line("probe", 1.0)
	_check("report line names the step count", line.contains("60 steps"), line)
	_check("cost counters advanced", st.t_solar_us >= 0 and st.t_flow_us >= 0 and st.t_pop_us >= 0)
