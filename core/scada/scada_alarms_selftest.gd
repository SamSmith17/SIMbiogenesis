extends SceneTree
## Alarms on tags (plans/SCADA_PROCESS_PLAN.md Phase 5): the condition with
## its deadband, the delay in sim time, the ISA-18.2 states (new, seen,
## cleared before seen, shelved), commands, the list order, the summary, the
## rules' own tags, the suggested set, scrub back and jumps. Carries
## EXPECTED_CHECKS; --import first.
##   Godot --headless --path . --script core/scada/scada_alarms_selftest.gd

const EXPECTED_CHECKS := 42

var _checks := 0
var _fails := 0
var _vals: Dictionary = {}


func _init() -> void:
	_test_condition()
	_test_states()
	_test_delay_and_time()
	_test_shelve()
	_test_lists()
	_test_suggest()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		print("FAIL check count %d != EXPECTED_CHECKS %d" % [_checks, EXPECTED_CHECKS])
	print("SCADA ALARMS SELFTEST %s  (%d checks, %d failed)" % ["PASS" if _fails == 0 else "FAIL", _checks, _fails])
	quit(0 if _fails == 0 else 1)


func _ok(cond: bool, what: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		print("  FAIL " + what)


func _read(tag: String) -> float:
	return float(_vals.get(tag, NAN))


func _state(r: Dictionary, id: String) -> String:
	return str((r["status"][id] as Dictionary)["state"])


func _test_condition() -> void:
	var hi := ScadaAlarms.make("a", "High", "lvl", ">=", 90.0)
	hi["deadband"] = 3.0
	_ok(ScadaAlarms.condition(hi, 90.0, false) and not ScadaAlarms.condition(hi, 89.9, false), "at or above the limit raises")
	_ok(ScadaAlarms.condition(hi, 87.5, true) and not ScadaAlarms.condition(hi, 86.9, true), "once in alarm it clears only past the deadband")
	var lo := ScadaAlarms.make("b", "Low", "lvl", "<=", 10.0)
	lo["deadband"] = 2.0
	_ok(ScadaAlarms.condition(lo, 10.0, false) and ScadaAlarms.condition(lo, 11.5, true) and not ScadaAlarms.condition(lo, 12.1, true), "a low limit mirrors it")
	_ok(ScadaAlarms.condition(ScadaAlarms.make("c", "", "x", "on", 0.0), 1.0, false) and ScadaAlarms.condition(ScadaAlarms.make("c", "", "x", "off", 0.0), 0.0, false), "on / off read a switch")
	_ok(ScadaAlarms.condition(ScadaAlarms.make("d", "", "x", "lost", 0.0), NAN, false) and not ScadaAlarms.condition(ScadaAlarms.make("d", "", "x", "lost", 0.0), 3.0, true), "lost is a missing reading")
	_ok(not ScadaAlarms.condition(hi, NAN, false) and ScadaAlarms.condition(hi, NAN, true), "a limit with no reading holds what it was")
	_ok(str(ScadaAlarms.make("e", "", "x", "nonsense", 0.0, "urgent")["op"]) == ">=" and str(ScadaAlarms.make("e", "", "x", ">=", 0.0, "urgent")["priority"]) == "medium", "unknown ops and priorities fall back")


func _test_states() -> void:
	var rules := [ScadaAlarms.make("a", "Tank high", "lvl", ">=", 90.0, "high")]
	_vals = {"lvl": 50.0}
	var r := ScadaAlarms.step(rules, {}, _read, 100.0)
	_ok(_state(r, "a") == "normal" and (r["events"] as Array).is_empty(), "below the limit: normal")
	_vals = {"lvl": 95.0}
	r = ScadaAlarms.step(rules, r["state"], _read, 100.1)
	_ok(_state(r, "a") == "unack" and (r["events"] as Array).size() == 1 and str(r["events"][0]["what"]) == "raised", "over it: raised, new, one event")
	_ok(str(r["events"][0]["text"]) == "95.0 (limit 90.0)" and str(r["events"][0]["priority"]) == "high", "the event says the value and the limit")
	r = ScadaAlarms.step(rules, r["state"], _read, 100.2)
	_ok(_state(r, "a") == "unack" and (r["events"] as Array).is_empty(), "it is not raised twice")
	var st := ScadaAlarms.command(r["state"], "a", "ack")
	r = ScadaAlarms.step(rules, st, _read, 100.3)
	_ok(_state(r, "a") == "acked" and bool(r["status"]["a"]["active"]), "acknowledged: still in alarm, seen")
	_vals = {"lvl": 60.0}
	r = ScadaAlarms.step(rules, r["state"], _read, 100.4)
	_ok(_state(r, "a") == "normal" and str(r["events"][0]["what"]) == "cleared", "seen and gone: normal, a cleared event")
	# Cleared before anyone saw it.
	_vals = {"lvl": 95.0}
	r = ScadaAlarms.step(rules, r["state"], _read, 100.5)
	_vals = {"lvl": 60.0}
	r = ScadaAlarms.step(rules, r["state"], _read, 100.6)
	_ok(_state(r, "a") == "rtn" and not bool(r["status"]["a"]["active"]), "gone before it was seen: stays listed as cleared")
	st = ScadaAlarms.command(r["state"], "a", "ack")
	r = ScadaAlarms.step(rules, st, _read, 100.7)
	_ok(_state(r, "a") == "normal", "acknowledging that returns it to normal")
	# Back over while unseen-cleared: new again.
	_vals = {"lvl": 95.0}
	r = ScadaAlarms.step(rules, r["state"], _read, 100.8)
	_vals = {"lvl": 60.0}
	r = ScadaAlarms.step(rules, r["state"], _read, 100.9)
	_vals = {"lvl": 95.0}
	r = ScadaAlarms.step(rules, r["state"], _read, 101.0)
	_ok(_state(r, "a") == "unack" and str(r["events"][0]["what"]) == "raised", "over again while still listed: raised again")
	var off := rules.duplicate(true)
	off[0]["enabled"] = false
	r = ScadaAlarms.step(off, r["state"], _read, 101.1)
	_ok(_state(r, "a") == "normal" and str(r["status"]["a"]["text"]) == "Off", "a rule switched off is normal")


func _test_delay_and_time() -> void:
	var rule := ScadaAlarms.make("a", "Slow", "lvl", ">=", 90.0)
	rule["delay_s"] = 360.0   # 0.1 h
	_vals = {"lvl": 95.0}
	var r := ScadaAlarms.step([rule], {}, _read, 10.0)
	_ok(_state(r, "a") == "normal", "inside the delay nothing raises")
	r = ScadaAlarms.step([rule], r["state"], _read, 10.05)
	_ok(_state(r, "a") == "normal", "still inside it")
	r = ScadaAlarms.step([rule], r["state"], _read, 10.11)
	_ok(_state(r, "a") == "unack" and is_equal_approx(float(r["status"]["a"]["since_h"]), 10.11), "after the delay it raises, stamped with the hour")
	# A dip restarts the delay.
	_vals = {"lvl": 95.0}
	var r2 := ScadaAlarms.step([rule], {}, _read, 20.0)
	_vals = {"lvl": 50.0}
	r2 = ScadaAlarms.step([rule], r2["state"], _read, 20.06)
	_vals = {"lvl": 95.0}
	r2 = ScadaAlarms.step([rule], r2["state"], _read, 20.08)
	r2 = ScadaAlarms.step([rule], r2["state"], _read, 20.15)
	_ok(_state(r2, "a") == "normal", "a dip under the limit restarts the delay")
	r2 = ScadaAlarms.step([rule], r2["state"], _read, 20.19)
	_ok(_state(r2, "a") == "unack", "and it raises a full delay after the dip")
	# A scrub back raises nothing and drops what was pending.
	var r3 := ScadaAlarms.step([rule], {}, _read, 30.0)
	r3 = ScadaAlarms.step([rule], r3["state"], _read, 29.0)
	_ok(_state(r3, "a") == "normal" and (r3["events"] as Array).is_empty(), "a scrub back raises nothing")
	r3 = ScadaAlarms.step([rule], r3["state"], _read, 29.05)
	_ok(_state(r3, "a") == "normal", "and the delay starts again from there")
	# A long jump restarts delays too.
	var r4 := ScadaAlarms.step([rule], {}, _read, 40.0)
	r4 = ScadaAlarms.step([rule], r4["state"], _read, 45.0)
	_ok(_state(r4, "a") == "normal", "a jump of hours is not a delay served")
	var same_a := ScadaAlarms.step([rule], {}, _read, 50.0)
	var same_b := ScadaAlarms.step([rule], {}, _read, 50.0)
	_ok(str(same_a) == str(same_b), "the same inputs give the same answer")


func _test_shelve() -> void:
	var rules := [ScadaAlarms.make("a", "Tank high", "lvl", ">=", 90.0)]
	_vals = {"lvl": 95.0}
	var r := ScadaAlarms.step(rules, {}, _read, 5.0)
	var st := ScadaAlarms.command(r["state"], "a", "shelve", 5.0, 1.0)
	r = ScadaAlarms.step(rules, st, _read, 5.5)
	_ok(_state(r, "a") == "shelved" and not bool(r["status"]["a"]["active"]) and (r["events"] as Array).is_empty(), "shelved: it raises nothing")
	_ok(float(ScadaAlarms.tags(rules, r["status"])[0]["value"]) == 0.0, "and its tag reads clear")
	r = ScadaAlarms.step(rules, r["state"], _read, 6.01)
	_ok(_state(r, "a") == "unack" and str(r["events"][0]["what"]) == "raised", "past its hour it comes back and raises")
	st = ScadaAlarms.command(r["state"], "a", "shelve", 6.01, 4.0)
	st = ScadaAlarms.command(st, "a", "unshelve")
	r = ScadaAlarms.step(rules, st, _read, 6.1)
	_ok(_state(r, "a") == "unack", "brought back by hand it raises at once")


func _test_lists() -> void:
	var rules := [ScadaAlarms.make("a", "Low one", "x", ">=", 1.0, "low"), ScadaAlarms.make("b", "High one", "y", ">=", 1.0, "high"),
		ScadaAlarms.make("c", "Medium one", "z", ">=", 1.0, "medium"), ScadaAlarms.make("d", "Quiet", "q", ">=", 1.0, "high")]
	_vals = {"x": 5.0, "y": 5.0, "z": 5.0, "q": 0.0}
	var r := ScadaAlarms.step(rules, {}, _read, 1.0)
	var st := ScadaAlarms.command(r["state"], "b", "ack")
	r = ScadaAlarms.step(rules, st, _read, 1.1)
	var list := ScadaAlarms.active_list(rules, r["status"])
	_ok(list.size() == 3 and str(list[0]["id"]) == "c" and str(list[1]["id"]) == "a" and str(list[2]["id"]) == "b", "new ones first, by priority; seen ones after")
	var sm := ScadaAlarms.summary(rules, r["status"])
	_ok(int(sm["active"]) == 3 and int(sm["unack"]) == 2 and str(sm["worst"]) == "high" and int(sm["count"]) == 3, "the summary counts them and names the worst priority")
	_ok(str(sm["text"]).begins_with("Medium one: 5.0 (limit 1.0)") and str(sm["text"]).ends_with("(+2 more)"), "and words the first one")
	var tg := ScadaAlarms.tags(rules, r["status"])
	_ok(tg.size() == 4 and str(tg[1]["id"]) == "alarm.b" and float(tg[1]["value"]) == 1.0 and float(tg[3]["value"]) == 0.0, "every rule is a tag")
	st = ScadaAlarms.ack_all(r["state"], rules)
	r = ScadaAlarms.step(rules, st, _read, 1.2)
	_ok(int(ScadaAlarms.summary(rules, r["status"])["unack"]) == 0, "acknowledge all leaves none new")
	_ok(str(ScadaAlarms.summary(rules, {})["text"]) == "No alarms" and str(ScadaAlarms.summary(rules, {})["worst"]) == "", "nothing in alarm reads so")
	_ok(str(ScadaAlarms.describe(ScadaAlarms.make("s", "", "x", "on", 0.0), 1.0)) == "is on" and ScadaAlarms.describe(ScadaAlarms.make("s", "", "x", "lost", 0.0), NAN) == "no reading", "switches and lost readings are worded")


func _test_suggest() -> void:
	var rows := [{"id": "tank.t1.level", "group": "Day Tank"}, {"id": "tank.t1.stock", "group": "Day Tank"},
		{"id": "logic.b2.tripped", "group": "Logic: Stop on overfill"}, {"id": "sensor.battery_level", "group": "Site power"},
		{"id": "node.p1", "group": "Pump"}]
	var n := [0]
	var next := func() -> String:
		n[0] += 1
		return "a%d" % n[0]
	var out := ScadaAlarms.suggest(rows, [], next)
	_ok(out.size() == 4, "a store gets a high and a low, an interlock a trip, the battery a low (%d)" % out.size())
	_ok(str(out[0]["name"]) == "Day Tank nearly full" and float(out[0]["limit"]) == 95.0 and float(out[0]["deadband"]) == 2.0 and float(out[0]["delay_s"]) == 60.0, "the high level has a deadband and a delay")
	_ok(str(out[2]["name"]) == "Stop on overfill tripped" and str(out[2]["op"]) == "on" and str(out[2]["priority"]) == "high", "a trip is high priority")
	var again := ScadaAlarms.suggest(rows, out, next)
	_ok(again.is_empty(), "what is already covered is not suggested twice")
	var some := ScadaAlarms.suggest(rows, [ScadaAlarms.make("x", "Mine", "tank.t1.level", ">=", 80.0)], next)
	_ok(some.size() == 3 and str(some[0]["op"]) == "<=", "a rule of the player's on that tag is left alone")
