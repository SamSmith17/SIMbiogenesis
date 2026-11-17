extends SceneTree
## Control logic away from the live hub (plans/SCADA_PROCESS_PLAN.md Phase 4,
## second part): the duty / standby block, ScadaLogicRun on a bare model (the
## A/B worlds, a simkit year), tag remapping for design files, ScadaTune on
## synthetic responses with known answers, ScadaStepTest on a copy of a small
## graph, the Home Assistant export, and blocks inside the tri-clamp Process
## Lab's model (a PID holding a kettle's temperature with its element).
## Carries EXPECTED_CHECKS; --import first.
##   Godot --headless --path . --script core/scada/scada_logic_run_selftest.gd

const EXPECTED_CHECKS := 53

var _checks := 0
var _fails := 0
var _vals: Dictionary = {}


func _init() -> void:
	_test_duty()
	_test_run_on_model()
	_test_remap()
	_test_tune()
	_test_step_test()
	_test_export()
	_test_tc()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		print("FAIL check count %d != EXPECTED_CHECKS %d" % [_checks, EXPECTED_CHECKS])
	print("SCADA LOGIC RUN SELFTEST %s  (%d checks, %d failed)" % ["PASS" if _fails == 0 else "FAIL", _checks, _fails])
	quit(0 if _fails == 0 else 1)


func _ok(cond: bool, what: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		print("  FAIL " + what)


func _read(tag: String) -> float:
	return float(_vals.get(tag, NAN))


func _test_duty() -> void:
	var d := ScadaLogic.template("duty_standby", "d", {"pv": "lvl", "out": "pa", "out2": "pb"})
	d["swap_h"] = 1.0
	var st := {}
	_vals = {"lvl": 60.0}
	var r := ScadaLogic.step([d], st, _read, 0.0)
	_ok(float(r["writes"]["pa"]) == 0.0 and float(r["writes"]["pb"]) == 0.0, "no demand: both off")
	_vals = {"lvl": 30.0}
	r = ScadaLogic.step([d], r["state"], _read, 0.1)
	_ok(float(r["writes"]["pa"]) == 1.0 and float(r["writes"]["pb"]) == 0.0, "demand: the lead runs, the standby does not")
	_vals = {"lvl": 10.0}
	r = ScadaLogic.step([d], r["state"], _read, 0.2)
	_ok(float(r["writes"]["pa"]) == 1.0 and float(r["writes"]["pb"]) == 1.0, "under the assist mark both run")
	# An hour and a half of running, then a stop and a new start: B leads.
	_vals = {"lvl": 30.0}
	var s2: Dictionary = r["state"]
	var t := 0.2
	for i in 15:
		t += 0.1
		s2 = ScadaLogic.step([d], s2, _read, t)["state"]
	_ok(float((s2["d"] as Dictionary)["run_h"]) > 1.0 and int((s2["d"] as Dictionary)["lead"]) == 0, "the lead does not change while it runs")
	_vals = {"lvl": 60.0}
	s2 = ScadaLogic.step([d], s2, _read, t + 0.1)["state"]
	_vals = {"lvl": 30.0}
	r = ScadaLogic.step([d], s2, _read, t + 0.2)
	_ok(float(r["writes"]["pb"]) == 1.0 and float(r["writes"]["pa"]) == 0.0, "past its hours the other one leads at the next start")
	var st3 := ScadaLogic.command([d], r["state"], "d", "swap")
	_ok(int((st3["d"] as Dictionary)["lead"]) == 0, "swap changes the lead by hand")
	var u := ScadaLogic.tags_used(d)
	_ok("pa" in (u["writes"] as Array) and "pb" in (u["writes"] as Array) and "lvl" in (u["reads"] as Array), "tags_used lists both machines")


func _model() -> GraphModel:
	var m := GraphModel.new()
	m.add_item({"id": "a", "type": "resource", "specs": {"name": "A", "resource_kind": "water", "capacity_qty": 20000.0, "capacity_unit": "L", "level": 0.9}})
	m.add_item({"id": "b", "type": "resource", "specs": {"name": "B", "resource_kind": "water", "capacity_qty": 1000.0, "capacity_unit": "L", "level": 0.2}})
	m.add_item({"id": "c", "type": "resource", "specs": {"name": "C", "resource_kind": "water", "capacity_qty": 20000.0, "capacity_unit": "L", "level": 0.0}})
	m.add_item({"id": "cv", "type": "processor", "specs": FlowCtl.make_specs("CV", FlowCtl.KIND_VALVE, "water", 600.0, {"throttle": true})})
	m.add_item({"id": "dv", "type": "processor", "specs": FlowCtl.make_specs("DV", FlowCtl.KIND_VALVE, "water", 200.0)})
	for w in [["a", "output", "cv", "res_in_0"], ["cv", "res_out_0", "b", "input"], ["b", "output", "dv", "res_in_0"], ["dv", "res_out_0", "c", "input"]]:
		m.add_connection({"polarity": "resource", "resource_type": "water", "source_item_id": w[0], "source_handle_id": w[1],
			"target_item_id": w[2], "target_handle_id": w[3]})
	return m


func _test_run_on_model() -> void:
	var m := _model()
	_ok(is_equal_approx(ScadaLogicRun.read_model(m, "tank.b.level"), 20.0) and is_equal_approx(ScadaLogicRun.read_model(m, "tank.b.stock"), 200.0), "a tank reads off the model")
	_ok(is_equal_approx(ScadaLogicRun.read_model(m, "valve.cv.open"), 100.0) and is_nan(ScadaLogicRun.read_model(m, "tank.zz.level")), "a valve reads its opening; a missing item reads nothing")
	var pid := ScadaLogic.template("hold_level_pid", "p", {"pv": "tank.b.level", "out": "valve.cv.open"})
	var lock := ScadaLogic.template("dry_run", "k", {"pv": "tank.a.level", "out": "node.dv"})
	var run := ScadaLogicRun.from_data({"blocks": [pid, lock, {"kind": "nonsense", "id": "x"}]})
	_ok(run.blocks.size() == 2, "unknown kinds are dropped")
	var flow := ResourceFlowEngine.new()
	flow.setup(m, null)
	var t := 1000.0
	flow.render_step(t, 0.0, true)
	var switched: Array = []
	for i in 300:
		t += 1.0 / 60.0
		run.step(m, t, {}, func(id: String, cmd: String) -> void:
			switched.append([id, cmd])
			var sp: Dictionary = m.get_item(id)["specs"]
			sp["requested_state"] = "on" if cmd == "turn_on" else "off"
			sp["current_state"] = sp["requested_state"])
		flow.render_step(t, 1.0 / 60.0, true)
	var lvl := ScadaLogicRun.read_model(m, "tank.b.level")
	var opn := ScadaLogicRun.read_model(m, "valve.cv.open")
	_ok(absf(lvl - 50.0) < 5.0, "a PID on a bare model holds the tank at 50 %% (%.1f)" % lvl)
	_ok(opn > 15.0 and opn < 60.0, "with the valve part open (%.1f %%)" % opn)
	_ok(run.writes_n > 5 and int(run.switches.get("p", 0)) > 5, "its writes are counted per block")
	_ok(switched.is_empty(), "an interlock that never trips switches nothing")
	(m.get_item("a")["specs"] as Dictionary)["level"] = 0.02
	run.step(m, t + 0.01, {}, func(id: String, cmd: String) -> void: switched.append([id, cmd]))
	_ok(switched.size() == 1 and str(switched[0][0]) == "dv" and str(switched[0][1]) == "turn_off", "a tripped interlock switches through the world's own callback")
	_ok(run.read(m, "sensor.battery_level", {"sensor.battery_level": 62.0}) == 62.0, "extra numbers are readable")
	var sm := run.summary()
	_ok(sm.size() == 2 and str(sm[1]["text"]).begins_with("TRIPPED"), "the summary says what each block is doing")
	# Loop performance: how long the PID's reading was within its band.
	_ok(sm[0].has("in_band_pct") and float(sm[0]["in_band_pct"]) > 40.0 and float(sm[0]["in_band_pct"]) < 100.0 and not sm[1].has("in_band_pct"),
		"the summary says how long a PID's reading was near its setpoint (%s %%); an interlock has no such figure" % str(sm[0].get("in_band_pct", "?")))
	var band := ScadaLogic.template("hold_level_band", "bb", {"pv": "tank.b.level", "out": "node.dv"})
	band.merge({"low": 40.0, "high": 60.0}, true)
	var r2 := ScadaLogicRun.from_data({"blocks": [band]})
	var cb := func(_id: String, _cmd: String) -> void: pass
	(m.get_item("b")["specs"] as Dictionary)["level"] = 0.5
	r2.step(m, 10.0, {}, cb)
	r2.step(m, 10.25, {}, cb)
	(m.get_item("b")["specs"] as Dictionary)["level"] = 0.9
	r2.step(m, 10.5, {}, cb)
	r2.step(m, 10.75, {}, cb)
	r2.step(m, 20.0, {}, cb)
	_ok(absf(float(r2.summary()[0]["in_band_pct"]) - 33.3) < 0.2, "a band's time between its marks: 0.25 h of 0.75 h judged; a 9 h jump is not counted (%s %%)" % str(r2.summary()[0]["in_band_pct"]))
	# Alarms over a run with nobody there.
	var ar := ScadaAlarmRun.from_rules([{"id": "hi", "name": "High", "tag": "tank.b.level", "op": ">=", "limit": 80.0}, {"id": "", "tag": "x"}, {"id": "nt"}])
	_ok(ar.rules.size() == 1, "alarm run: rules with no id or no tag are dropped")
	var lv := [0.5]
	var rd := func(_tag: String) -> float: return lv[0] * 100.0
	var th := 100.0
	for i in 40:
		lv[0] = 0.9 if (i >= 4 and i < 12) or (i >= 20 and i < 24) else 0.5
		ar.step(rd, th)
		th += 0.25
	var asum := ar.summary()
	_ok(int(asum[0]["raised"]) == 2, "alarm run: it went off twice (%d)" % int(asum[0]["raised"]))
	_ok(absf(float(asum[0]["active_h"]) - 3.0) < 0.3, "alarm run: about 3 h in alarm (%.2f)" % float(asum[0]["active_h"]))


func _test_remap() -> void:
	var blocks := [ScadaLogic.template("hold_level_pid", "p", {"pv": "tank.day.level", "out": "valve.inlet.open"}),
		ScadaLogic.template("fill_wait_drain", "q", {"pv": "tank.day.level", "out": "node.pump", "out2": "node.drain"})]
	var out := ScadaLogicRun.remap(blocks, {"day": ["item_7"], "inlet": ["item_9", "item_10"], "pump": "item_3"})
	_ok(str(out[0]["pv"]) == "tank.item_7.level" and str(out[0]["out"]) == "valve.item_9.open", "design ids become graph ids (the first of a counted node)")
	_ok(str(out[1]["steps"][0]["set"][0]["tag"]) == "node.item_3" and str(out[1]["steps"][0]["set"][1]["tag"]) == "node.drain", "inside steps too; unknown ids stay")
	_ok(str(blocks[0]["pv"]) == "tank.day.level", "the design's own blocks are not touched")


func _test_tune() -> void:
	# First order + delay: k 0.8 per %, tau 0.5 h, delay 0.05 h, step +10 %.
	var t: Array = []
	var y: Array = []
	for i in 400:
		var th := float(i) * 0.01
		t.append(th)
		y.append(20.0 + (8.0 * (1.0 - exp(-(th - 0.05) / 0.5)) if th > 0.05 else 0.0))
	var f := ScadaTune.fit(t, y, 10.0)
	_ok(str(f["kind"]) == "self_regulating" and absf(float(f["gain"]) - 0.8) < 0.03, "a settling response: gain 0.8 per %% (%.3f)" % float(f["gain"]))
	_ok(absf(float(f["tau_h"]) - 0.5) < 0.06 and absf(float(f["delay_h"]) - 0.05) < 0.04, "time constant 0.5 h and delay 0.05 h (%.3f, %.3f)" % [float(f["tau_h"]), float(f["delay_h"])])
	var g := ScadaTune.gains(f, 0.05)
	var th2 := float(f["delay_h"])
	var want_kp := float(f["tau_h"]) / (float(f["gain"]) * (maxf(th2, 0.05) + th2))
	_ok(absf(float(g["kp"]) - want_kp) < 0.02 and absf(float(g["ti_min"]) - minf(float(f["tau_h"]), 4.0 * (maxf(th2, 0.05) + th2)) * 60.0) < 0.2, "SIMC: Kc = tau / (k (tc + theta)), Ti = min(tau, 4 (tc + theta))")
	# An integrator: 6 per hour per %, falling (reverse), with a drift before.
	t = []
	y = []
	for i in 200:
		var th3 := float(i) * 0.01
		t.append(th3)
		y.append(50.0 + 2.0 * th3 - 6.0 * 5.0 * th3)
	var fi := ScadaTune.fit(t, y, 5.0, 2.0)
	_ok(str(fi["kind"]) == "integrating" and absf(float(fi["gain"]) - 6.0) < 0.05 and bool(fi["reverse"]), "a ramp: 6 per hour per %%, the drift taken out, falling = reverse")
	var gi := ScadaTune.gains(fi, 0.1)
	_ok(absf(float(gi["kp"]) - 1.0 / (6.0 * 0.1)) < 0.02 and absf(float(gi["ti_min"]) - 24.0) < 0.2, "SIMC for an integrator: Kc = 1 / (k' tc), Ti = 4 tc")
	_ok(not bool(ScadaTune.fit([0.0, 0.1, 0.2, 0.3, 0.4, 0.5], [5.0, 5.0, 5.0, 5.0, 5.0, 5.0], 10.0)["ok"]), "a reading that never moves gives no fit")
	_ok(not bool(ScadaTune.gains({"ok": false, "why": "x"})["ok"]), "and no gains")


func _test_step_test() -> void:
	var m := _model()
	(m.get_item("b")["specs"] as Dictionary)["level"] = 0.5
	(m.get_item("cv")["specs"] as Dictionary)["open"] = 0.33
	var before := m.serialize().duplicate(true)
	var pid := ScadaLogic.template("hold_level_pid", "p", {"pv": "tank.b.level", "out": "valve.cv.open"})
	var r := ScadaStepTest.run(m, null, pid, 2000.0)
	_ok(bool(r["ok"]), "a step test on a copy gives gains (%s)" % str(r.get("why", "")))
	_ok(str(m.serialize()) == str(before), "the model itself is not touched")
	# +10 % of a 600 L/h valve into 1000 L = 6 % per hour per 1 %... per 10 %: 0.6 per hour per %.
	var f: Dictionary = r.get("fit", {})
	_ok(str(f.get("kind", "")) == "integrating" and absf(float(f.get("gain", 0.0)) - 0.6) < 0.08, "the tank ramps 0.6 %% per hour per %% of valve (%.3f)" % float(f.get("gain", 0.0)))
	_ok(not bool(f.get("reverse", true)) and float((r["gains"] as Dictionary).get("kp", 0.0)) > 1.0, "more valve raises the level; a usable gain comes out")
	var bad := ScadaStepTest.run(m, null, {"pv": "sensor.x", "out": "valve.cv.open"}, 2000.0)
	_ok(not bool(bad["ok"]), "a reading off the graph is refused in words")
	# The suggested gains hold the level.
	pid.merge({"kp": float(r["gains"]["kp"]), "ti_min": float(r["gains"]["ti_min"]), "sp": 60.0}, true)
	var run := ScadaLogicRun.from_data({"blocks": [pid]})
	var flow := ResourceFlowEngine.new()
	flow.setup(m, null)
	var t := 3000.0
	flow.render_step(t, 0.0, true)
	var worst := 0.0
	for i in 480:
		t += 1.0 / 60.0
		run.step(m, t)
		flow.render_step(t, 1.0 / 60.0, true)
		if i > 300:
			worst = maxf(worst, absf(ScadaLogicRun.read_model(m, "tank.b.level") - 60.0))
	_ok(worst < 3.0, "with those gains the loop reaches 60 %% and stays within 3 (worst %.2f)" % worst)


func _test_export() -> void:
	var blocks := [
		ScadaLogic.template("hold_level_band", "b1", {"pv": "tank.t1.level", "out": "node.p1"}),
		ScadaLogic.template("overfill", "b2", {"pv": "sensor.shed_tank_level", "out": "switch.shed_pump"}),
		ScadaLogic.template("fill_wait_drain", "b3", {"pv": "tank.t1.level", "out": "node.p1", "out2": "valve.v1.open"}),
		ScadaLogic.template("hold_level_pid", "b4", {"pv": "tank.t1.level", "out": "valve.v1.open"}),
		ScadaLogic.template("cycle", "b5", {"out": "node.fan"}),
	]
	var r := ScadaLogicExport.export(blocks)
	var y := str(r["yaml"])
	_ok(int(r["automations"]) == 4 and int(r["scripts"]) == 1, "a band is two automations, an interlock and a timer one each, a sequence a script")
	_ok(y.contains("entity_id: sensor.tank_t1_level") and y.contains("below: 30") and y.contains("service: switch.turn_on"), "the band: below the low mark, switch on")
	_ok(y.contains("entity_id: sensor.shed_tank_level") and y.contains("entity_id: switch.shed_pump"), "ids that already are entity ids are kept")
	_ok(y.contains("wait_template: \"{{ states('sensor.tank_t1_level') | float(0) >= 80 }}\"") and y.contains("continue_on_timeout: false"), "a sequence step waits on its condition with its timeout")
	_ok(y.contains("service: number.set_value") and y.contains("entity_id: number.valve_v1_open"), "a number is set, not switched")
	_ok(y.contains("#   - platform: pid") and y.contains("#       kp: 0.06"), "a PID is an ESPHome snippet in comments, gains per unit of 0..1 output")
	_ok(not y.contains("\t") and y.begins_with("# Control logic"), "plain YAML: no tabs")
	var mapped := ScadaLogicExport.export([blocks[0]], func(tag: String) -> String: return "sensor.my_level" if tag == "tank.t1.level" else "")
	_ok(str(mapped["yaml"]).contains("entity_id: sensor.my_level") and str(mapped["yaml"]).contains("entity_id: switch.p1"), "a caller's entity map wins; the rest fall back")
	_ok(ScadaLogicExport.default_entity("valve.v 1.open") == "number.valve_v_1_open", "ids are slugged")


func _test_tc() -> void:
	var pr := TcProcSpec.defaults()
	pr["charge"] = {"feed": "water", "mass_kg": 40.0, "moisture": 0.0, "bulk_kg_m3": 0.0}
	pr["heaters"]["default_w"] = 3000.0
	var pid := ScadaLogic.make("pid", "t1", "Hold the mash at 65")
	pid.merge({"pv": "sensor.brew_kettle_50_l_p4", "out": "number.brew_kettle_50_l_p5_power", "sp": 65.0, "kp": 20.0, "ti_min": 15.0}, true)
	pr["logic"] = [pid]
	pr = TcProcSpec.resolve(pr)
	_ok((pr.get("logic", []) as Array).size() == 1, "the process block keeps its control blocks")
	var d := TcDesign.solve(TcPresets.builtin("brew_kettle"))
	var sim := TcProcSim.create(d, pr)
	sim.run_for(3.0 * 3600.0, 10.0)
	var temp := float(TcProcControl.read_all(sim, sim.control_sensors, {"sensor.brew_kettle_50_l_p4": true})["sensor.brew_kettle_50_l_p4"])
	var watts := float(sim.heater_w.get("p5", 0.0))
	_ok(absf(temp - 65.0) < 2.5, "a PID on the element holds the kettle at 65 °C (%.1f)" % temp)
	_ok(watts > 30.0 and watts < 2500.0, "at part power (%.0f W of 3000)" % watts)
	_ok(str((sim.logic_status.get("t1", {}) as Dictionary).get("mode", "")) == "auto", "its status is the model's")
	var snap := sim.snapshot()
	sim.run_for(600.0, 10.0)
	var after: Dictionary = (sim.logic_state["t1"] as Dictionary).duplicate()
	sim.restore(snap)
	sim.run_for(600.0, 10.0)
	_ok(is_equal_approx(float(after["i"]), float((sim.logic_state["t1"] as Dictionary)["i"])), "the loop's state is in the snapshot: a replay is the same")
	# Without the block the kettle boils.
	pr["logic"] = []
	var free := TcProcSim.create(d, pr)
	free.run_for(3.0 * 3600.0, 10.0)
	var t2 := float(TcProcControl.read_all(free, free.control_sensors, {"sensor.brew_kettle_50_l_p4": true})["sensor.brew_kettle_50_l_p4"])
	_ok(t2 > 90.0, "without it the same kettle goes on to the boil (%.1f)" % t2)
