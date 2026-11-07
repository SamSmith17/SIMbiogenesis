extends SceneTree

## Headless self-test for AutomationSim (the graph's automations in sim time)
## and ExperimentWorld (a graph copy whose loads they switch): crossings incl.
## midnight, the SAME switches at 1-minute and 1-hour steps, numeric edges and
## `for` in sim seconds, delays, conditions (time window, weekday, sun,
## numeric), sun triggers, and a real GraphAcLoad reading on a copied graph
## following an 18:00-on / 23:00-off rule while the live model is untouched;
## set_value actions and targeted scene_node actions (the Dictionary command
## shape behind rich_commands, the old String shape left exactly as it was),
## their live-engine actions + HA export, and the shared card editor
## (scenes/ui/automation_card_editor.gd) authoring them.
## Run (--import first):
##   Godot.exe.exe --headless --path . --script power_system/automation/automation_sim_selftest.gd

const EXPECTED_CHECKS := 56

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_test_crossed()
	_test_step_independence()
	_test_numeric_and_for()
	_test_delay_and_conditions()
	_test_world()
	_test_set_value_and_targets()
	_test_live_actions()
	_test_card_editor()
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


## A reactor's bed temperature as a slow triangle: up through 450 °C, down
## through 420 °C, twice a day.
func _bed_c(t: float) -> float:
	var ph := fposmod((t - DAY0) / 12.0, 1.0)
	return 300.0 + 200.0 * (1.0 - absf(2.0 * ph - 1.0))


func _reactor_rules() -> Array:
	return [
		_rule("element 1 off hot", [{"kind": "numeric", "entity_id": "sensor.r_bed", "above": 450.0}],
			[{"kind": "scene_node", "command": "turn_off", "target": "e1"},
			{"kind": "set_value", "entity_id": "number.r_e2_power", "value": 0.0}]),
		_rule("element 1 on cool", [{"kind": "numeric", "entity_id": "sensor.r_bed", "below": 420.0}],
			[{"kind": "scene_node", "command": "turn_on", "target": "e1"},
			{"kind": "set_value", "entity_id": "number.r_e2_power", "value": 600.0}]),
	]


func _drive_rich(s: AutomationSim, t0: float, t1: float, step: float) -> Array:
	s.rich_commands = true
	var out: Array = []
	var t := t0
	var prev := t0
	while t <= t1 + 1e-9:
		var tc := t
		s.step(prev, t, {"numeric": {"sensor.r_bed": _bed_c(t)}},
			func(id: String, cmd: Variant) -> void: out.append([tc, id, cmd]))
		prev = t
		t += step
	return out


func _test_set_value_and_targets() -> void:
	# Legacy callers (rich_commands off) see exactly the old String commands.
	var legacy := _sim(_reactor_rules())
	var got: Array = []
	var t := DAY0
	var prev := DAY0
	while t <= DAY0 + 24.0 + 1e-9:
		legacy.step(prev, t, {"numeric": {"sensor.r_bed": _bed_c(t)}},
			func(_id: String, cmd: Variant) -> void: got.append(cmd))
		prev = t
		t += 1.0 / 60.0
	var all_strings := not got.is_empty()
	for c in got:
		all_strings = all_strings and c is String
	_check("legacy: only String commands reach an old caller", all_strings, str(got))
	_check("legacy: a targeted action still switches the item (turn_on/turn_off strings)",
		got.has("turn_on") and got.has("turn_off"))
	_check("legacy: set_value is skipped, not applied", legacy.skipped == got.size() and legacy.skipped > 0,
		"%d skipped, %d applied" % [legacy.skipped, got.size()])
	var logged_sv := legacy.log.filter(func(e: Dictionary) -> bool: return str(e["command"]) == "set_value")
	_check("legacy: a skipped set_value is not in the log", logged_sv.is_empty())

	# Rich callers: Dictionary commands, the same at any step size.
	var fine := _drive_rich(_sim(_reactor_rules()), DAY0, DAY0 + 24.0, 1.0 / 60.0)
	var coarse := _drive_rich(_sim(_reactor_rules()), DAY0, DAY0 + 24.0, 0.5)
	# The bed starts cool (300 °C): the "below 420" rule is in range at the
	# first step and fires then (as the live engine does), then 2 crossings
	# each way: 5 firings x 2 actions.
	_check("rich: first step + 2 crossings each way = 10 commands", fine.size() == 10, str(fine.size()))
	var same := fine.size() == coarse.size()
	for i in mini(fine.size(), coarse.size()):
		same = same and JSON.stringify(fine[i][2]) == JSON.stringify(coarse[i][2])
	_check("rich: the same commands in the same order at 1 min and 30 min steps", same)
	var c0: Variant = fine[2][2] if fine.size() > 2 else {}
	_check("rich: a targeted action names its actuator",
		c0 is Dictionary and str((c0 as Dictionary).get("cmd")) == "turn_off" and str((c0 as Dictionary).get("target")) == "e1",
		str(c0))
	var c1: Variant = fine[3][2] if fine.size() > 3 else {}
	_check("rich: set_value carries entity and value",
		c1 is Dictionary and str((c1 as Dictionary).get("cmd")) == "set_value"
			and str((c1 as Dictionary).get("entity_id")) == "number.r_e2_power"
			and is_equal_approx(float((c1 as Dictionary).get("value", -1.0)), 0.0), str(c1))
	# The bed passes 450 °C at 0.75 of its 6 h rise.
	var hot_h := DAY0 + 6.0 * 0.75
	_check("rich: the 1-min switch lands on the minute of the crossing",
		fine.size() > 2 and absf(float(fine[2][0]) - hot_h) <= 1.0 / 60.0 + 1e-6,
		"%.4f vs %.4f" % [float(fine[2][0]) - DAY0 if fine.size() > 2 else -1.0, hot_h - DAY0])
	var cool_sv := fine.filter(func(e: Array) -> bool:
		return e[2] is Dictionary and str(e[2].get("cmd")) == "set_value" and float(e[2].get("value")) > 1.0)
	_check("rich: the first step + 2 cooling crossings set 600 W", cool_sv.size() == 3, str(cool_sv.size()))
	# An untargeted action in rich mode: target "" = the whole item.
	var plain := _sim([_rule("on 18", [{"kind": "time", "at_hour": 18.0}], [{"kind": "scene_node", "command": "turn_on"}])])
	var pl := _drive_rich(plain, DAY0, DAY0 + 24.0, 1.0)
	_check("rich: an untargeted action has an empty target",
		pl.size() == 1 and str((pl[0][2] as Dictionary).get("target")) == ""
			and str((pl[0][2] as Dictionary).get("cmd")) == "turn_on")
	var s2 := _sim(_reactor_rules())
	_drive_rich(s2, DAY0, DAY0 + 12.0, 0.25)
	var e0: Dictionary = s2.log[0] if not s2.log.is_empty() else {}   # the first-step "on e1"
	_check("rich: the log names the target", str(e0.get("target", "")) == "e1", str(e0))
	_check("rich: the log names the set entity",
		s2.log.size() > 1 and str((s2.log[1] as Dictionary).get("entity_id", "")) == "number.r_e2_power")

	# from_specs: a design's own automation list, no graph around it.
	var autos := [
		{"id": "x1", "alias": "a", "enabled": true, "triggers": [{"kind": "time", "at_hour": 1.0}],
			"conditions": [], "actions": [{"kind": "set_value", "entity_id": "number.v", "value": 0.5}]},
		{"id": "x2", "alias": "b", "enabled": false, "triggers": [], "conditions": [], "actions": []},
	]
	var fs := AutomationSim.from_specs(autos, "reactor")
	_check("from_specs: enabled rules on the named item",
		fs.rules.size() == 1 and str(fs.rules[0]["item_id"]) == "reactor")


func _test_live_actions() -> void:
	var sv := ServiceAction.make_set_value("number.r_e1_power", 450.0)
	var d := sv.to_ha_dict()
	_check("live: set_value exports as number.set_value",
		str(d.get("service")) == "number.set_value"
			and str((d.get("target", {}) as Dictionary).get("entity_id")) == "number.r_e1_power"
			and is_equal_approx(float((d.get("data", {}) as Dictionary).get("value", -1.0)), 450.0), str(d))
	var di := ServiceAction.make_set_value("input_number.setpoint", 12.5).to_ha_dict()
	_check("live: an input_number entity exports as input_number.set_value",
		str(di.get("service")) == "input_number.set_value", str(di))
	_check("live: set_value is recognised for the card round trip",
		sv.is_set_value() and not ServiceAction.new().is_set_value())
	var aut := Automation.new()
	aut.automation_id = "t"
	aut.alias = "t"
	aut.actions.append(sv)
	_check("live: the automation's HA YAML carries the set_value", aut.to_ha_yaml().contains("number.set_value"))

	# A targeted scene-node action reaches the node's actuator, not the node.
	var gs := GDScript.new()
	gs.source_code = "extends Node\nvar got: Array = []\nvar whole := 0\nfunc apply_target_command(t: String, c: String) -> bool:\n\tgot.append([t, c])\n\treturn true\nfunc turn_on() -> void:\n\twhole += 1\n"
	gs.reload()
	var n := Node.new()
	n.name = "Reactor"
	n.set_script(gs)
	root.add_child(n)
	var a := SceneNodeAction.new()
	a.node_path = "Reactor"
	a.target = "e2"
	a.command = SceneNodeAction.NodeCommand.TURN_ON
	var ok := a.execute({"scene_tree": self})
	var g: Array = n.get("got")
	_check("live: a targeted action calls apply_target_command",
		ok and g.size() == 1 and str(g[0][0]) == "e2" and str(g[0][1]) == "turn_on" and int(n.get("whole")) == 0,
		str(g))
	a.target = ""
	a.execute({"scene_tree": self})
	_check("live: no target = the whole node, as before", int(n.get("whole")) == 1)
	var bare := Node.new()
	bare.name = "Bare"
	root.add_child(bare)
	var a2 := SceneNodeAction.new()
	a2.node_path = "Bare"
	a2.target = "e1"
	_check("live: a node without targets refuses a targeted action", not a2.execute({"scene_tree": self}))
	n.free()
	bare.free()


func _test_card_editor() -> void:
	var ed_script: GDScript = load("res://scenes/ui/automation_card_editor.gd")
	var ed: VBoxContainer = ed_script.new()
	var changes: Array = []
	var rebuilds: Array = []
	ed.connect("automations_changed", func(arr: Array) -> void: changes.append(arr))
	ed.connect("rebuild_requested", func() -> void: rebuilds.append(1))
	var autos := [{"id": "r1", "alias": "Hot", "enabled": true,
		"triggers": [{"kind": "numeric", "entity_id": "sensor.r_bed", "above": 450.0}], "conditions": [],
		"actions": [{"kind": "scene_node", "command": "turn_off", "target": "e1"},
			{"kind": "set_value", "entity_id": "number.r_e2_power", "value": 0.0}]}]
	var provider := {
		"numeric": func() -> Array: return [{"label": "Bed °C", "key": "sensor.r_bed"}, {"label": "Custom", "key": "__custom__"}],
		"targets": func() -> Array: return [{"label": "Whole reactor", "key": ""}, {"label": "Element 1", "key": "e1"}],
		"settable": func() -> Array: return [{"label": "Element 2 power", "key": "number.r_e2_power",
			"min": 0.0, "max": 1200.0, "step": 10.0, "unit": "W"}],
	}
	ed.set("expanded", {"r1": true})
	ed.call("setup", autos, provider)
	var labels: Array = []
	for l in ed.find_children("*", "Label", true, false):
		labels.append((l as Label).text)
	_check("editor: an open card shows the Target row", labels.has("Target"), str(labels))
	_check("editor: and the set_value Entity + Value rows", labels.has("Entity") and labels.has("Value (W)"))
	var picked := ""
	for o in ed.find_children("*", "OptionButton", true, false):
		var ob := o as OptionButton
		if ob.selected >= 0 and ob.get_item_text(ob.selected) == "Element 1":
			picked = "Element 1"
	_check("editor: the Target picker shows the saved actuator", picked == "Element 1")
	var vspin: SpinBox = null
	for sp in ed.find_children("*", "SpinBox", true, false):
		if is_equal_approx((sp as SpinBox).max_value, 1200.0):
			vspin = sp as SpinBox
	_check("editor: the value spin takes the settable's range", vspin != null)
	if vspin != null:
		# Outside the tree a SpinBox does not emit on .value =: emit as a
		# player's edit would.
		vspin.value_changed.emit(300.0)
	var last: Array = changes[changes.size() - 1] if not changes.is_empty() else []
	var act: Dictionary = ((last[0] as Dictionary)["actions"] as Array)[1] if not last.is_empty() else {}
	_check("editor: a value edit commits the whole array, no rebuild",
		is_equal_approx(float(act.get("value", -1.0)), 300.0) and rebuilds.is_empty(), str(act))
	ed.call("patch_field", 0, ["actions", 0, "target"], null, true)
	var last2: Array = changes[changes.size() - 1]
	var a0: Dictionary = ((last2[0] as Dictionary)["actions"] as Array)[0]
	_check("editor: clearing the target erases the key (the whole item)",
		not a0.has("target") and rebuilds.size() == 1, str(a0))
	var kinds: Array = ed.call("kind_options", "action")
	var keys: Array = []
	for k in kinds:
		keys.append(str((k as Dictionary)["key"]))
	_check("editor: the THEN menu offers set_value", keys.has("set_value") and keys.has("scene_node"))
	var summ := str(ed.call("summarize", autos[0]))
	_check("editor: summary names the target and the value",
		summ.contains("turn off e1") and summ.contains("number.r_e2_power"), summ)
	ed.free()
