extends SceneTree

## Control blocks (offline): ScadaLogic's band, PID (against a hand tank
## model: settles, no wind-up, bumpless manual → auto, the same answer at 10 s
## and 60 s steps), interlock (wins, latches, fails safe), timer, counter,
## sequence (advances, waits, times out, holds, repeats), snapshots, scrubs.
##
## Carries EXPECTED_CHECKS; --import first.
##   godot --headless --path . --script core/scada/scada_logic_selftest.gd

const EXPECTED_CHECKS := 64

var _checks := 0
var _fails := 0
var _vals: Dictionary = {}


func _init() -> void:
	_test_band()
	_test_pid()
	_test_interlock()
	_test_timer_counter()
	_test_sequence()
	_test_misc()
	_test_picture()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		print("FAIL check count %d != EXPECTED_CHECKS %d" % [_checks, EXPECTED_CHECKS])
	print("SCADA LOGIC SELFTEST %s  (%d checks, %d failed)" % ["PASS" if _fails == 0 else "FAIL", _checks, _fails])
	quit(0 if _fails == 0 else 1)


func _ok(cond: bool, what: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		print("  FAIL " + what)


func _read(tag: String) -> float:
	return float(_vals.get(tag, NAN))


func _test_band() -> void:
	var b := ScadaLogic.make("band", "b")
	b.merge({"pv": "lvl", "out": "pump", "low": 30.0, "high": 80.0}, true)
	var st := {}
	_vals = {"lvl": 20.0}
	var r := ScadaLogic.step([b], st, _read, 0.0)
	_ok(float(r["writes"]["pump"]) == 1.0, "band: below the low mark it switches on")
	_vals["lvl"] = 55.0
	r = ScadaLogic.step([b], r["state"], _read, 0.1)
	_ok(float(r["writes"]["pump"]) == 1.0, "band: between the marks it stays on")
	_vals["lvl"] = 81.0
	r = ScadaLogic.step([b], r["state"], _read, 0.2)
	_ok(float(r["writes"]["pump"]) == 0.0, "band: above the high mark it switches off")
	_vals["lvl"] = 55.0
	r = ScadaLogic.step([b], r["state"], _read, 0.3)
	_ok(float(r["writes"]["pump"]) == 0.0, "band: and stays off on the way down")
	_vals.erase("lvl")
	r = ScadaLogic.step([b], r["state"], _read, 0.4)
	_ok(not (r["writes"] as Dictionary).has("pump") and str(r["status"]["b"]["level"]) == "warn", "band: with no reading it holds and says so")
	b["direction"] = "drain"
	_vals["lvl"] = 90.0
	r = ScadaLogic.step([b], {}, _read, 0.0)
	_ok(float(r["writes"]["pump"]) == 1.0, "band: a drain band switches on above the high mark")
	b["enabled"] = false
	r = ScadaLogic.step([b], {}, _read, 0.0)
	_ok((r["writes"] as Dictionary).is_empty() and str(r["status"]["b"]["text"]) == "Off", "a block switched off writes nothing")


## A tank: level % rises 0.2 %/h per % of valve, falls `drain` %/h.
func _run_tank(b: Dictionary, st: Dictionary, level: float, hours: float, dt_s: float, drain: float, t0: float = 0.0) -> Array:
	var t := t0
	var out := float((st.get(str(b["id"]), {}) as Dictionary).get("out", 0.0))
	var peak := level
	var n := int(round(hours * 3600.0 / dt_s))
	var state := st
	for _i in n:
		_vals["lvl"] = level
		var r := ScadaLogic.step([b], state, _read, t)
		state = r["state"]
		out = float((r["writes"] as Dictionary).get("valve", out))
		level = clampf(level + (0.2 * out - drain) * dt_s / 3600.0, 0.0, 100.0)
		peak = maxf(peak, level)
		t += dt_s / 3600.0
	return [level, out, state, peak, t]


func _test_pid() -> void:
	var b := ScadaLogic.make("pid", "p")
	b.merge({"pv": "lvl", "out": "valve", "sp": 50.0, "kp": 6.0, "ti_min": 20.0}, true)
	var a := _run_tank(b, {}, 20.0, 8.0, 10.0, 8.0)
	_ok(absf(float(a[0]) - 50.0) < 0.5, "pid: the level settles on its setpoint (%.2f)" % float(a[0]))
	_ok(absf(float(a[1]) - 40.0) < 1.5, "pid: at the output that balances the drain (%.1f %%, 40 by hand)" % float(a[1]))
	_ok(float(a[3]) < 62.0, "pid: without a wild overshoot (peak %.1f)" % float(a[3]))
	var c := _run_tank(b, {}, 20.0, 8.0, 60.0, 8.0)
	_ok(absf(float(c[0]) - float(a[0])) < 0.5, "pid: 60 s steps land where 10 s steps do (%.2f vs %.2f)" % [float(c[0]), float(a[0])])
	# Wind-up: a drain it cannot beat for 3 h, then the drain eases.
	var w := _run_tank(b, {}, 50.0, 3.0, 10.0, 30.0)
	_ok(is_equal_approx(float(w[1]), 100.0) and float(w[0]) < 30.0, "pid: against a drain it cannot beat the output pins at 100 %%")
	var integ := float(((w[2] as Dictionary)["p"] as Dictionary)["i"])
	_ok(integ < 110.0, "pid: and the integral does not wind up (%.1f)" % integ)
	var rec := _run_tank(b, w[2], float(w[0]), 10.0, 10.0, 8.0, float(w[4]))
	_ok(float(rec[3]) < 62.0 and absf(float(rec[0]) - 50.0) < 1.5, "pid: so it recovers without a big overshoot (peak %.1f, ends %.2f)" % [float(rec[3]), float(rec[0])])
	# Manual, then bumpless back to auto.
	var st: Dictionary = ScadaLogic.command([b], a[2], "p", "manual")
	st = ScadaLogic.command([b], st, "p", "out", 25.0)
	_vals["lvl"] = 50.0
	var r := ScadaLogic.step([b], st, _read, 100.0)
	_ok(is_equal_approx(float(r["writes"]["valve"]), 25.0) and str(r["status"]["p"]["mode"]) == "manual", "pid: in manual the output is the operator's")
	st = ScadaLogic.command([b], r["state"], "p", "auto")
	r = ScadaLogic.step([b], st, _read, 100.01)
	_ok(absf(float(r["writes"]["valve"]) - 25.0) < 1.0, "pid: back to auto it starts from there (%.1f)" % float(r["writes"]["valve"]))
	# Setpoint from the operator, then from the block.
	st = ScadaLogic.command([b], r["state"], "p", "sp", 70.0)
	r = ScadaLogic.step([b], st, _read, 100.02)
	_ok(is_equal_approx(float(r["status"]["p"]["sp"]), 70.0), "pid: an operator's setpoint")
	var b2 := b.duplicate(true)
	b2["sp"] = 40.0
	r = ScadaLogic.step([b2], r["state"], _read, 100.03)
	_ok(is_equal_approx(float(r["status"]["p"]["sp"]), 40.0), "pid: editing the block's setpoint wins")
	# Reverse acting: more output brings the reading DOWN.
	var rv := ScadaLogic.make("pid", "r")
	rv.merge({"pv": "lvl", "out": "valve", "sp": 50.0, "kp": 2.0, "ti_min": 0.0, "reverse": true}, true)
	_vals["lvl"] = 70.0
	r = ScadaLogic.step([rv], {}, _read, 0.0)
	_ok(is_equal_approx(float(r["writes"]["valve"]), 40.0), "pid: reverse acting opens when the reading is high (%.1f)" % float(r["writes"]["valve"]))
	_vals.erase("lvl")
	r = ScadaLogic.step([b], a[2], _read, 200.0)
	_ok(absf(float(r["writes"]["valve"]) - float(a[1])) < 1e-6 and str(r["status"]["p"]["level"]) == "warn", "pid: with no reading it holds its output")
	# A jump or a scrub integrates nothing.
	_vals["lvl"] = 30.0
	var s0: Dictionary = a[2]
	var j := ScadaLogic.step([b], s0, _read, float(s0["_last_h"]) + 50.0)
	_ok(is_equal_approx(float((j["state"]["p"] as Dictionary)["i"]), float((s0["p"] as Dictionary)["i"])), "pid: a 50 h jump adds nothing to the integral")
	var k := ScadaLogic.step([b], s0, _read, float(s0["_last_h"]) - 1.0)
	_ok(is_equal_approx(float((k["state"]["p"] as Dictionary)["i"]), float((s0["p"] as Dictionary)["i"])), "pid: nor does a scrub back")


func _test_interlock() -> void:
	var band := ScadaLogic.make("band", "b")
	band.merge({"pv": "lvl", "out": "pump", "low": 30.0, "high": 80.0}, true)
	var lock := ScadaLogic.make("interlock", "k")
	lock.merge({"when": [{"tag": "src", "op": "<=", "value": 5.0}], "out": "pump", "safe": 0.0}, true)
	_vals = {"lvl": 10.0, "src": 50.0}
	var r := ScadaLogic.step([band, lock], {}, _read, 0.0)
	_ok(float(r["writes"]["pump"]) == 1.0 and not bool(r["status"]["k"]["tripped"]), "interlock: clear, the band has the pump")
	_vals["src"] = 3.0
	r = ScadaLogic.step([band, lock], r["state"], _read, 0.1)
	_ok(float(r["writes"]["pump"]) == 0.0 and bool(r["status"]["k"]["tripped"]), "interlock: tripped, it forces the pump off over the band")
	r = ScadaLogic.step([lock, band], r["state"], _read, 0.2)
	_ok(float(r["writes"]["pump"]) == 0.0, "interlock: whatever order the blocks are in")
	_vals["src"] = 50.0
	r = ScadaLogic.step([band, lock], r["state"], _read, 0.3)
	_ok(float(r["writes"]["pump"]) == 1.0, "interlock: clear again, the band has it back")
	lock["latch"] = true
	_vals["src"] = 3.0
	r = ScadaLogic.step([band, lock], {}, _read, 0.0)
	_vals["src"] = 50.0
	r = ScadaLogic.step([band, lock], r["state"], _read, 0.1)
	_ok(float(r["writes"]["pump"]) == 0.0 and bool(r["status"]["k"]["tripped"]) and bool(r["status"]["k"]["clear"]), "interlock: latched, it stays tripped once clear")
	var st := ScadaLogic.command([band, lock], r["state"], "k", "reset")
	r = ScadaLogic.step([band, lock], st, _read, 0.2)
	_ok(float(r["writes"]["pump"]) == 1.0, "interlock: until it is reset")
	_vals.erase("src")
	lock["latch"] = false
	r = ScadaLogic.step([band, lock], {}, _read, 0.0)
	_ok(bool(r["status"]["k"]["tripped"]), "interlock: no reading counts as tripped (fail safe)")
	var both := ScadaLogic.make("interlock", "a")
	both.merge({"when": [{"tag": "x", "op": ">", "value": 1.0}, {"tag": "y", "op": ">", "value": 1.0}], "match": "all", "out": "pump", "safe": 1.0}, true)
	_vals = {"x": 2.0, "y": 0.0}
	_ok(not bool(ScadaLogic.step([both], {}, _read, 0.0)["status"]["a"]["tripped"]), "interlock: 'all' needs every condition")
	_vals["y"] = 2.0
	_ok(float(ScadaLogic.step([both], {}, _read, 0.0)["writes"]["pump"]) == 1.0, "interlock: and forces its safe value, here on")


func _test_timer_counter() -> void:
	var t := ScadaLogic.make("timer", "t")
	t.merge({"out": "fan", "on_min": 15.0, "off_min": 45.0}, true)
	_ok(ScadaLogic.timer_on(t, 10.0 + 5.0 / 60.0) and not ScadaLogic.timer_on(t, 10.0 + 20.0 / 60.0) and ScadaLogic.timer_on(t, 11.0 + 14.0 / 60.0),
		"timer: on for 15 minutes of each hour")
	t["offset_min"] = 30.0
	_ok(not ScadaLogic.timer_on(t, 10.0 + 5.0 / 60.0) and ScadaLogic.timer_on(t, 10.0 + 35.0 / 60.0), "timer: an offset moves the cycle")
	_ok(float(ScadaLogic.step([t], {}, _read, 10.0 + 35.0 / 60.0)["writes"]["fan"]) == 1.0, "timer: it writes its output")
	var c := ScadaLogic.make("counter", "c")
	c.merge({"pv": "door", "op": ">", "value": 0.5}, true)
	var st := {}
	var seq := [0.0, 1.0, 1.0, 0.0, 1.0, 0.0, 1.0]
	var r := {}
	for i in seq.size():
		_vals = {"door": seq[i]}
		r = ScadaLogic.step([c], st, _read, float(i) * 0.01)
		st = r["state"]
	_ok(int(r["status"]["c"]["count"]) == 3, "counter: three rising edges (%d)" % int(r["status"]["c"]["count"]))
	st = ScadaLogic.command([c], st, "c", "reset")
	_vals = {"door": 1.0}
	_ok(int(ScadaLogic.step([c], st, _read, 1.0)["status"]["c"]["count"]) == 0, "counter: reset; a level that was already high is not an edge")


func _test_sequence() -> void:
	var q := ScadaLogic.template("fill_wait_drain", "q", {"pv": "lvl", "out": "inlet", "out2": "drain"})
	_vals = {"lvl": 10.0}
	var r := ScadaLogic.step([q], {}, _read, 0.0)
	_ok((r["writes"] as Dictionary).is_empty() and str(r["status"]["q"]["run"]) == "idle", "sequence: idle until started")
	var st := ScadaLogic.command([q], r["state"], "q", "start")
	r = ScadaLogic.step([q], st, _read, 1.0)
	_ok(float(r["writes"]["inlet"]) == 1.0 and float(r["writes"]["drain"]) == 0.0 and int(r["status"]["q"]["step"]) == 0, "sequence: step 1 opens the inlet")
	_vals["lvl"] = 60.0
	r = ScadaLogic.step([q], r["state"], _read, 1.5)
	_ok(int(r["status"]["q"]["step"]) == 0, "sequence: it waits for the level")
	_vals["lvl"] = 82.0
	r = ScadaLogic.step([q], r["state"], _read, 1.6)
	r = ScadaLogic.step([q], r["state"], _read, 1.6 + 1.0 / 3600.0)
	_ok(int(r["status"]["q"]["step"]) == 1 and float(r["writes"]["inlet"]) == 0.0, "sequence: at 80 %% it moves on and shuts the inlet")
	r = ScadaLogic.step([q], r["state"], _read, 1.6 + 300.0 / 3600.0)
	_ok(int(r["status"]["q"]["step"]) == 1, "sequence: the wait step holds for its 10 minutes")
	var held := ScadaLogic.command([q], r["state"], "q", "hold")
	r = ScadaLogic.step([q], held, _read, 5.0)
	_ok(str(r["status"]["q"]["run"]) == "held" and int(r["status"]["q"]["step"]) == 1, "sequence: held, hours pass and it stays put")
	st = ScadaLogic.command([q], r["state"], "q", "resume")
	r = ScadaLogic.step([q], st, _read, 5.0 + 200.0 / 3600.0)
	_ok(int(r["status"]["q"]["step"]) == 1, "sequence: resumed, the held time did not count (200 s more is not enough)")
	r = ScadaLogic.step([q], r["state"], _read, 5.0 + 320.0 / 3600.0)
	r = ScadaLogic.step([q], r["state"], _read, 5.0 + 321.0 / 3600.0)
	_ok(int(r["status"]["q"]["step"]) == 2 and float(r["writes"]["drain"]) == 1.0, "sequence: then the drain opens")
	# The drain never empties it: a timeout.
	r = ScadaLogic.step([q], r["state"], _read, 5.0 + 3.0)
	_ok(str(r["status"]["q"]["run"]) == "timeout" and str(r["status"]["q"]["level"]) == "warn", "sequence: a step that never finishes times out")
	_ok((ScadaLogic.step([q], r["state"], _read, 9.0)["writes"] as Dictionary).is_empty(), "sequence: and then writes nothing")
	# A clean run to the end.
	st = ScadaLogic.command([q], {}, "q", "start")
	var t := 0.0
	var lv := [10.0, 85.0, 85.0, 85.0, 5.0, 5.0, 5.0, 5.0]
	var last := {}
	for i in lv.size():
		_vals = {"lvl": lv[i]}
		last = ScadaLogic.step([q], st, _read, t)
		st = last["state"]
		t += 0.2
	_ok(str(last["status"]["q"]["run"]) == "done", "sequence: a clean run finishes (%s)" % str(last["status"]["q"]["text"]))
	q["repeat"] = true
	st = ScadaLogic.command([q], {}, "q", "start")
	t = 0.0
	for i in lv.size():
		_vals = {"lvl": lv[i]}
		last = ScadaLogic.step([q], st, _read, t)
		st = last["state"]
		t += 0.2
	_ok(str(last["status"]["q"]["run"]) == "running" and int((st["q"] as Dictionary).get("runs", 0)) == 1, "sequence: with repeat it starts again")
	st = ScadaLogic.command([q], st, "q", "abort")
	_ok(str(ScadaLogic.step([q], st, _read, t)["status"]["q"]["run"]) == "aborted", "sequence: abort stops it")
	_ok(str(ScadaLogic.step([ScadaLogic.make("sequence", "e")], {}, _read, 0.0)["status"]["e"]["text"]) == "No steps yet", "sequence: an empty one says so")


func _test_misc() -> void:
	var p := ScadaLogic.make("pid", "p")
	p.merge({"pv": "lvl", "out": "valve"}, true)
	_vals = {"lvl": 40.0}
	var r1 := ScadaLogic.step([p], {}, _read, 0.0)
	var snap: Dictionary = (r1["state"] as Dictionary).duplicate(true)
	var a := ScadaLogic.step([p], r1["state"], _read, 0.1)
	var b := ScadaLogic.step([p], snap, _read, 0.1)
	_ok(str(a["state"]) == str(b["state"]) and str(a["writes"]) == str(b["writes"]), "a snapshot restores exactly")
	_ok(str(JSON.parse_string(JSON.stringify(snap))) != "" and (JSON.parse_string(JSON.stringify(snap)) as Dictionary).has("p"), "state is plain data (it goes through JSON)")
	var tg := ScadaLogic.tags([p], a["status"])
	_ok(tg.size() == 2 and str(tg[0]["id"]) == "logic.p.out" and is_equal_approx(float(tg[0]["value"]), float(a["writes"]["valve"])), "a PID offers its output and setpoint as tags")
	var u := ScadaLogic.tags_used(ScadaLogic.template("fill_wait_drain", "q", {"pv": "lvl", "out": "in", "out2": "dr"}))
	_ok("lvl" in (u["reads"] as Array) and "in" in (u["writes"] as Array) and "dr" in (u["writes"] as Array), "tags_used lists what a sequence reads and writes")
	var all_ok := true
	for row in ScadaLogic.TEMPLATES:
		var t := ScadaLogic.template(str(row[0]), "x", {"pv": "a", "out": "b", "out2": "c"})
		if not (str(t.get("kind", "")) in ScadaLogic.KINDS) or str(t.get("name", "")).is_empty():
			all_ok = false
	_ok(all_ok and ScadaLogic.TEMPLATES.size() == 8, "every template makes a block")
	_ok(ScadaLogic.compare(2.0, ">=", 2.0) and not ScadaLogic.compare(2.0, "<", 2.0) and ScadaLogic.compare(1.0, "!=", 2.0), "compare")


## Controllers as instruments for the Process lens.
func _test_picture() -> void:
	_ok(MimicGraphSource.item_of_tag("tank.t1.level") == "t1", "a tank tag names its tank")
	_ok(MimicGraphSource.item_of_tag("valve.v1.open") == "v1" and MimicGraphSource.item_of_tag("node.p1") == "p1", "valve and node tags name their items")
	_ok(MimicGraphSource.item_of_tag("sensor.battery_level") == "", "a site tag names none")
	var pid := ScadaLogic.template("hold_level_pid", "b1", {"pv": "tank.t1.level", "out": "valve.v1.open"})
	var lock := ScadaLogic.template("overfill", "b2", {"pv": "tank.t1.level", "out": "node.p1"})
	var loose := ScadaLogic.make("timer", "b3", "Nothing bound")
	var rows := MimicGraphSource.logic_instruments([pid, lock, loose], {"b1": {"text": "Auto", "level": "ok"}, "b2": {"text": "Tripped", "level": "warn"}})
	_ok(rows.size() == 2, "blocks bound to nothing on the graph are left out")
	var r0: Dictionary = rows[0]
	_ok(str(r0["id"]) == "logic:b1" and str(r0["item"]) == "t1" and str(r0["board"]) == "v1", "a loop stands on what it reads, with a line to what it drives")
	_ok(str(r0["letters"]) == "LIC" and bool(r0["link"]) and str(r0["logic"]) == "b1", "a level loop is LIC")
	_ok(str(rows[1]["letters"]) == "I" and not bool(rows[1]["available"]), "a tripped interlock is an I bubble in warning")
	_ok(str(r0["text"]) == "Auto", "and carries its status text")
