extends SceneTree

## Headless self-test for AutomationSim (the graph's automations in sim time)
## and ExperimentWorld (a graph copy whose loads they switch): crossings incl.
## midnight, the SAME switches at 1-minute and 1-hour steps, numeric edges and
## `for` in sim seconds, delays, conditions (time window, weekday, sun,
## numeric), sun triggers, and a real GraphAcLoad reading on a copied graph
## following an 18:00-on / 23:00-off rule while the live model is untouched.
## Run (--import first):
##   Godot.exe.exe --headless --path . --script power_system/automation/automation_sim_selftest.gd

const EXPECTED_CHECKS := 27

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_test_crossed()
	_test_step_independence()
	_test_numeric_and_for()
	_test_delay_and_conditions()
	_test_world()
	if _checks != EXPECTED_CHECKS:
		_failures += 1
		print("  FAIL: check count %d != EXPECTED_CHECKS %d (a runtime error aborted a test?)" % [
			_checks, EXPECTED_CHECKS])
	if _failures == 0:
		print("AUTOMATION SIM SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("AUTOMATION SIM SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


const DAY0 := 24.0 * 739000.0   # an arbitrary midnight


func _rule(alias: String, triggers: Array, actions: Array, conditions: Array = []) -> Dictionary:
	return {"item_id": "load", "alias": alias, "id": alias, "triggers": triggers,
		"conditions": conditions, "actions": actions}


func _sim(rules: Array) -> AutomationSim:
	var s := AutomationSim.new()
	s.rules = rules
	return s


func _drive(s: AutomationSim, t0: float, t1: float, step: float, ctx_fn: Callable) -> Array:
	var out: Array = []
	var t := t0
	var prev := t0
	while t <= t1 + 1e-9:
		s.step(prev, t, ctx_fn.call(t), func(_id: String, cmd: String) -> void: out.append([t, cmd]))
		prev = t
		t += step
	return out


func _test_crossed() -> void:
	_check("crossed: inside the step", AutomationSim.crossed(18.0, DAY0 + 17.9, DAY0 + 18.1))
	_check("crossed: at the step's end counts", AutomationSim.crossed(18.0, DAY0 + 17.0, DAY0 + 18.0))
	_check("crossed: at the step's start does not", not AutomationSim.crossed(18.0, DAY0 + 18.0, DAY0 + 19.0))
	_check("crossed: over midnight", AutomationSim.crossed(0.5, DAY0 + 23.5, DAY0 + 24.75))
	_check("crossed: not when the clock stands still", not AutomationSim.crossed(18.0, DAY0 + 18.0, DAY0 + 18.0))
	_check("weekday: 2026-10-22 is a Thursday", AutomationSim.weekday_of(_abs(2026, 10, 22)) == 4,
		str(AutomationSim.weekday_of(_abs(2026, 10, 22))))


func _abs(y: int, m: int, d: int) -> float:
	var c := CelestialClock.new()
	c.year = y
	c.month = m
	c.day = d
	c.day_time = 12.0
	return c.get_absolute_hours()


func _test_step_independence() -> void:
	var rules := [
		_rule("on 18", [{"kind": "time", "at_hour": 18.0}], [{"kind": "scene_node", "command": "turn_on"}]),
		_rule("off 23:30", [{"kind": "time", "at_hour": 23.5}], [{"kind": "scene_node", "command": "turn_off"}]),
		_rule("sunset +1", [{"kind": "sun", "event": "sunset", "offset_hours": 1.0}], [{"kind": "scene_node", "command": "toggle"}]),
	]
	var ctx := func(_t: float) -> Dictionary: return {"sun": Vector2(6.5, 19.25)}
	var fine := _drive(_sim(rules), DAY0, DAY0 + 48.0, 1.0 / 60.0, ctx)
	var coarse := _drive(_sim(rules), DAY0, DAY0 + 48.0, 1.0, ctx)
	_check("steps: 6 switches over two days at 1 min", fine.size() == 6, str(fine.size()))
	_check("steps: the same 6 at 1 h steps", coarse.size() == 6, str(coarse.size()))
	var same_order := fine.size() == coarse.size()
	for i in mini(fine.size(), coarse.size()):
		same_order = same_order and fine[i][1] == coarse[i][1]
	_check("steps: in the same order", same_order)
	_check("steps: 1-min switch lands on the minute", absf(float(fine[0][0]) - (DAY0 + 18.0)) < 1.0 / 60.0 + 1e-6)


func _test_numeric_and_for() -> void:
	var rules := [
		_rule("dump on", [{"kind": "numeric", "entity_id": "sensor.battery_level", "above": 99.0}],
			[{"kind": "scene_node", "command": "turn_on"}]),
		_rule("pump on after 30 min sun", [{"kind": "numeric", "entity_id": "sensor.solar_power", "above": 500.0, "for_seconds": 1800.0}],
			[{"kind": "scene_node", "command": "toggle"}]),
	]
	var soc := func(t: float) -> float:
		var h := t - DAY0
		return 99.5 if (h >= 2.0 and h < 3.0) or h >= 5.0 else 50.0
	var ctx := func(t: float) -> Dictionary:
		var h := t - DAY0
		return {"numeric": {"sensor.battery_level": soc.call(t), "sensor.solar_power": 800.0 if h >= 1.0 else 0.0}}
	var out := _drive(_sim(rules), DAY0, DAY0 + 6.0, 0.25, ctx)
	var ons := out.filter(func(e: Array) -> bool: return e[1] == "turn_on")
	var toggles := out.filter(func(e: Array) -> bool: return e[1] == "toggle")
	_check("numeric: fires on each entry into range (2)", ons.size() == 2, str(ons))
	_check("numeric: for 30 min of SIM time", toggles.size() == 1 and absf(float(toggles[0][0]) - (DAY0 + 1.5)) < 1e-6, str(toggles))
	var first := _drive(_sim([rules[0]]), DAY0 + 2.0, DAY0 + 2.5, 0.25, ctx)
	_check("numeric: already in range at the first step fires (as the live engine)", first.size() == 1)


func _test_delay_and_conditions() -> void:
	var rules := [
		_rule("pulse", [{"kind": "time", "at_hour": 6.0}],
			[{"kind": "scene_node", "command": "turn_on"}, {"kind": "delay", "delay_seconds": 1800.0},
			{"kind": "scene_node", "command": "turn_off"}]),
	]
	var out := _drive(_sim(rules), DAY0, DAY0 + 8.0, 1.0 / 12.0, func(_t: float) -> Dictionary: return {})
	_check("delay: on then off", out.size() == 2 and out[0][1] == "turn_on" and out[1][1] == "turn_off", str(out))
	_check("delay: 30 sim-minutes apart", out.size() == 2 and absf(float(out[1][0]) - float(out[0][0]) - 0.5) < 1.0 / 12.0 + 1e-6)
	var cond_rules := [
		_rule("only evenings", [{"kind": "numeric", "entity_id": "x", "above": 1.0}],
			[{"kind": "scene_node", "command": "turn_on"}],
			[{"kind": "time", "after_hour": 17.0, "before_hour": 2.0}]),
	]
	var flip := func(t: float) -> Dictionary:
		return {"numeric": {"x": 2.0 if int(floor((t - DAY0) * 2.0)) % 2 == 1 else 0.0}}
	var ev := _drive(_sim(cond_rules), DAY0, DAY0 + 24.0, 0.5, flip)
	var outside := ev.filter(func(e: Array) -> bool:
		var h := fposmod(float(e[0]), 24.0)
		return h >= 2.0 and h < 17.0)
	_check("conditions: a wrapping time window", not ev.is_empty() and outside.is_empty(), str(ev.size()))
	var wd := [_rule("weekdays", [{"kind": "time", "at_hour": 9.0}], [{"kind": "scene_node", "command": "turn_on"}],
		[{"kind": "time", "after_hour": 0.0, "before_hour": 24.0, "weekdays": [1, 2, 3, 4, 5]}])]
	var week := _drive(_sim(wd), DAY0, DAY0 + 24.0 * 7.0, 1.0,
		func(t: float) -> Dictionary: return {"weekday": AutomationSim.weekday_of(t)})
	_check("conditions: weekdays only (5 of 7)", week.size() == 5, str(week.size()))
	var night := [_rule("dark", [{"kind": "time", "at_hour": 21.0}, {"kind": "time", "at_hour": 12.0}],
		[{"kind": "scene_node", "command": "turn_on"}], [{"kind": "sun", "state": "below_horizon"}])]
	var dk := _drive(_sim(night), DAY0, DAY0 + 24.0, 1.0, func(_t: float) -> Dictionary: return {"sun": Vector2(6.0, 19.0)})
	_check("conditions: sun below horizon", dk.size() == 1 and absf(fposmod(float(dk[0][0]), 24.0) - 21.0) < 1e-6)


func _model() -> GraphModel:
	var m := GraphModel.new()
	m.add_item({"id": "ctrl", "type": "controller", "specs": {"name": "Ctrl"}})
	m.add_item({"id": "heater", "type": "appliance", "specs": {"name": "Heater", "avg_watts": 1500.0,
		"requested_state": "off", "current_state": "off",
		"graph_automations": [
			{"id": "a1", "alias": "Heater on at 18", "enabled": true,
				"triggers": [{"kind": "time", "at_hour": 18.0}], "conditions": [],
				"actions": [{"kind": "scene_node", "command": "turn_on"}]},
			{"id": "a2", "alias": "Heater off at 23", "enabled": true,
				"triggers": [{"kind": "time", "at_hour": 23.0}], "conditions": [],
				"actions": [{"kind": "scene_node", "command": "turn_off"}]},
			{"id": "a3", "alias": "disabled", "enabled": false,
				"triggers": [{"kind": "time", "at_hour": 12.0}], "conditions": [],
				"actions": [{"kind": "scene_node", "command": "turn_on"}]},
		]}})
	m.add_connection({"id": "c1", "polarity": "ac", "source_item_id": "ctrl", "source_handle_id": "acOutput",
		"target_item_id": "heater", "target_handle_id": "power_in"})
	return m


func _test_world() -> void:
	var live := _model()
	var w := ExperimentWorld.from_live(live, null, null)
	_check("world: two enabled rules collected", w.automations.rules.size() == 2)
	_check("world: a copy, not the live model", w.model != live)
	_check("world: heater off at the start", is_equal_approx(float(w.inputs_at(DAY0 + 12.0)["load_kw"]), 0.0))
	var loads := {}
	var t := DAY0
	while t <= DAY0 + 24.0:
		w.before_step(t, 5.0, true)
		loads[snappedf(t - DAY0, 0.25)] = float(w.inputs_at(t)["load_kw"])
		t += 0.25
	_check("world: on at 18:00", is_equal_approx(float(loads[18.0]), 1.5), str(loads[18.0]))
	_check("world: still on at 22:45", is_equal_approx(float(loads[22.75]), 1.5))
	_check("world: off at 23:00", is_equal_approx(float(loads[23.0]), 0.0))
	_check("world: the log names both switches", w.automations.log.size() == 2)
	var live_heater: Dictionary = live.get_item("heater")
	_check("world: the live model never moved", str((live_heater["specs"] as Dictionary)["requested_state"]) == "off")
	# Removing the rule (an A/B 'without' world) leaves the heater off all day.
	var data := live.serialize()
	for it in data["items"]:
		if str(it["id"]) == "heater":
			(it["specs"] as Dictionary)["graph_automations"] = []
	var w2 := ExperimentWorld.from_graph(data, null, null)
	w2.before_step(DAY0 + 18.0, 5.0, true)
	w2.before_step(DAY0 + 18.5, 5.0, true)
	_check("world: without the automation the heater stays off", is_equal_approx(float(w2.inputs_at(DAY0 + 18.5)["load_kw"]), 0.0))
