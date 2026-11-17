extends SceneTree

## ScadaOutputs (pure, offline): what each entity domain is sent, scaling and
## limits, deadband and rate limit, safe states, the heartbeat, the checks and
## the watchdog automation.
##   Godot --headless --path . --script core/scada/scada_outputs_selftest.gd

const EXPECTED_CHECKS := 48

var _pass := 0
var _fail := 0


func _ok(cond: bool, what: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		print("FAIL: %s" % what)


func _initialize() -> void:
	_test_calls()
	_test_due()
	_test_safe()
	_test_checks_and_yaml()
	var total := _pass + _fail
	if total != EXPECTED_CHECKS:
		print("FAIL: ran %d checks, expected %d (a test function aborted?)" % [total, EXPECTED_CHECKS])
		_fail += 1
	print("SCADA OUTPUTS SELFTEST %s  (%d checks, %d failed)" % ["PASS" if _fail == 0 else "FAIL", total, _fail])
	quit(0 if _fail == 0 else 1)


func _link(entity: String, extra: Dictionary = {}) -> Dictionary:
	var l := {"id": "o1", "tag": "node.pump", "entity_id": entity}
	l.merge(extra, true)
	return ScadaOutputs.normalized(l)


func _call(l: Dictionary, v: float, binary: bool) -> Dictionary:
	return ScadaOutputs.call_for(l, ScadaOutputs.value_for(l, v, binary))


func _test_calls() -> void:
	_ok(ScadaOutputs.supported("switch.pump") and ScadaOutputs.supported("input_number.x") and ScadaOutputs.supported("valve.v"), "switches, numbers and valves can be driven")
	_ok(not ScadaOutputs.supported("sensor.temp") and not ScadaOutputs.supported("switch.") and not ScadaOutputs.supported("lock.door") and not ScadaOutputs.supported(""), "sensors, locks and half an id cannot")
	var sw := _link("switch.pump")
	_ok(str(_call(sw, 1.0, true)["service"]) == "turn_on" and str(_call(sw, 0.0, true)["service"]) == "turn_off", "a switch follows an on / off tag")
	var inv := _link("switch.pump", {"invert": true})
	_ok(str(_call(inv, 1.0, true)["service"]) == "turn_off", "inverted, on sends off")
	_ok(str(_call(_link("light.lamp"), 1.0, true)["domain"]) == "light", "the service is the entity's own domain")
	var num := _link("number.valve_pct", {"tag": "valve.v1.open"})
	var c := _call(num, 37.456, false)
	_ok(str(c["service"]) == "set_value" and absf(float(c["data"]["value"]) - 37.46) < 1e-9, "a number is sent set_value, rounded to hundredths")
	var sc := _link("input_number.dac", {"scale": 0.1, "offset": 2.0, "min": 2.0, "max": 10.0})
	_ok(absf(float(_call(sc, 50.0, false)["data"]["value"]) - 7.0) < 1e-9, "scale then offset (50 % → 7.0)")
	_ok(absf(float(_call(sc, 100.0, false)["data"]["value"]) - 10.0) < 1e-9 and absf(float(_call(sc, -50.0, false)["data"]["value"]) - 2.0) < 1e-9, "clamped to its limits")
	var vl := _link("valve.feed")
	_ok(str(_call(vl, 62.4, false)["service"]) == "set_valve_position" and int(_call(vl, 62.4, false)["data"]["position"]) == 62, "a valve takes a position for a number")
	_ok(int(_call(vl, 180.0, false)["data"]["position"]) == 100, "never past 100")
	_ok(str(_call(vl, 1.0, true)["service"]) == "open_valve" and str(_call(vl, 0.0, true)["service"]) == "close_valve", "and open / close for an on / off tag")
	_ok(str(_call(_link("cover.vent"), 40.0, false)["service"]) == "set_cover_position", "a cover takes a position")
	_ok(str(_call(_link("fan.x"), 30.0, false)["service"]) == "turn_on" and str(_call(_link("fan.x"), 0.2, false)["service"]) == "turn_off", "a number onto an on / off entity is on above a half")
	_ok(ScadaOutputs.call_for(_link("sensor.x"), {"binary": true, "on": true}).is_empty(), "nothing is made for an entity that cannot be driven")
	var n := ScadaOutputs.normalized({"id": "a", "tag": "t", "entity_id": " switch.p ", "safe": "banana", "min_interval_s": 0.0})
	_ok(str(n["entity_id"]) == "switch.p" and str(n["safe"]) == "off" and float(n["min_interval_s"]) >= 0.2, "a link is cleaned: trimmed id, a known safe state, a floor on the interval")
	_ok(ScadaOutputs.clean([{"id": "a"}, {"id": "a"}, {"id": ""}, 7]).size() == 1, "duplicate and empty ids are dropped")


func _test_due() -> void:
	var links := [_link("switch.pump", {"id": "p"}), _link("number.v", {"id": "v", "tag": "valve.v1.open", "deadband": 2.0})]
	var bin := {"node.pump": true, "valve.v1.open": false}
	var sent := {}
	var d := ScadaOutputs.due(links, {"node.pump": 1.0, "valve.v1.open": 40.0}, bin, sent, 100.0)
	_ok(d.size() == 2, "the first pass sends every output its value (%d)" % d.size())
	for x in d:
		sent[str(x["id"])] = {"v": float(x["key"]), "t": 100.0}
	_ok(ScadaOutputs.due(links, {"node.pump": 1.0, "valve.v1.open": 40.0}, bin, sent, 110.0).is_empty(), "nothing is sent while nothing changes")
	_ok(ScadaOutputs.due(links, {"node.pump": 1.0, "valve.v1.open": 41.5}, bin, sent, 110.0).is_empty(), "a move inside the deadband is not sent")
	var d2 := ScadaOutputs.due(links, {"node.pump": 1.0, "valve.v1.open": 43.0}, bin, sent, 110.0)
	_ok(d2.size() == 1 and str(d2[0]["id"]) == "v", "a move past the deadband is")
	var d3 := ScadaOutputs.due(links, {"node.pump": 0.0, "valve.v1.open": 40.0}, bin, sent, 110.0)
	_ok(d3.size() == 1 and str(d3[0]["call"]["service"]) == "turn_off", "a switch flip is sent")
	_ok(ScadaOutputs.due(links, {"node.pump": 0.0, "valve.v1.open": 90.0}, bin, sent, 100.5).is_empty(), "never sooner than the minimum interval")
	_ok(ScadaOutputs.due(links, {"node.pump": NAN, "valve.v1.open": NAN}, bin, {}, 100.0).is_empty(), "a tag with no reading sends nothing")
	var off := [_link("switch.pump", {"id": "p", "enabled": false}), _link("sensor.bad", {"id": "b"}), _link("switch.q", {"id": "q", "tag": ""})]
	_ok(ScadaOutputs.due(off, {"node.pump": 1.0}, bin, {}, 0.0).is_empty(), "a disabled link, an undrivable entity and a link with no tag send nothing")
	var many: Array = []
	var vals := {}
	for i in 30:
		many.append(_link("switch.s%d" % i, {"id": "m%d" % i, "tag": "node.n%d" % i}))
		vals["node.n%d" % i] = 1.0
	_ok(ScadaOutputs.due(many, vals, {}, {}, 0.0).size() == ScadaOutputs.MAX_SENDS, "at most %d calls a pass" % ScadaOutputs.MAX_SENDS)
	var two := [_link("number.a", {"id": "a", "tag": "t.a", "deadband": 1.0}), _link("number.b", {"id": "b", "tag": "t.b", "deadband": 1.0})]
	var s2 := {"a": {"v": 10.0, "t": 0.0}, "b": {"v": 10.0, "t": 0.0}}
	var d4 := ScadaOutputs.due(two, {"t.a": 12.0, "t.b": 60.0}, {}, s2, 50.0)
	_ok(d4.size() == 2 and str(d4[0]["id"]) == "b", "the biggest change goes first")


func _test_safe() -> void:
	_ok(str(ScadaOutputs.call_for(_link("switch.p"), ScadaOutputs.safe_what(_link("switch.p")))["service"]) == "turn_off", "a switch's default safe state is off")
	var on := _link("switch.cooling", {"safe": "on"})
	_ok(str(ScadaOutputs.call_for(on, ScadaOutputs.safe_what(on))["service"]) == "turn_on", "a cooling pump can be safe ON")
	_ok(ScadaOutputs.safe_what(_link("switch.p", {"safe": "hold"})).is_empty(), "\"leave as it is\" sends nothing")
	var v := _link("valve.feed", {"safe": 0.0})
	_ok(str(ScadaOutputs.call_for(v, ScadaOutputs.safe_what(v))["service"]) == "set_valve_position" and int(ScadaOutputs.call_for(v, ScadaOutputs.safe_what(v))["data"]["position"]) == 0, "a valve safe at a position")
	var vo := _link("valve.feed", {"safe": "off"})
	_ok(str(ScadaOutputs.call_for(vo, ScadaOutputs.safe_what(vo))["service"]) == "close_valve", "a valve safe \"off\" closes")
	var nm := _link("number.dac", {"safe": "off", "min": 4.0, "max": 20.0})
	_ok(absf(float(ScadaOutputs.call_for(nm, ScadaOutputs.safe_what(nm))["data"]["value"]) - 4.0) < 1e-9, "a number safe \"off\" goes to its minimum")
	var links := [_link("switch.p", {"id": "a"}), _link("switch.q", {"id": "b", "safe": "hold"}), _link("switch.r", {"id": "c", "enabled": false}), _link("sensor.x", {"id": "d"})]
	_ok(ScadaOutputs.safe_calls(links).size() == 1, "safe calls cover enabled, drivable links with a safe state")
	_ok(str(ScadaOutputs.heartbeat_call({"heartbeat_entity": "input_boolean.hb"})["service"]) == "toggle", "an input_boolean heartbeat is toggled")
	_ok(str(ScadaOutputs.heartbeat_call({"heartbeat_entity": "input_button.hb"})["service"]) == "press", "an input_button heartbeat is pressed")
	_ok(ScadaOutputs.heartbeat_call({"heartbeat_entity": "switch.hb"}).is_empty() and ScadaOutputs.heartbeat_call({}).is_empty(), "anything else is no heartbeat")
	_ok(ScadaOutputs.describe({"binary": true, "on": true}) == "on" and ScadaOutputs.describe({"binary": false, "value": 41.26}) == "41.3" and ScadaOutputs.describe({}) == "left as it is", "values read in words")


func _test_checks_and_yaml() -> void:
	var good := [_link("switch.p", {"id": "a"})]
	var st := {"heartbeat_entity": "input_boolean.hb", "heartbeat_s": 10.0, "timeout_s": 45.0}
	_ok(ScadaOutputs.checks(good, st).is_empty(), "a good set has nothing to say")
	_ok(not ScadaOutputs.has_errors(ScadaOutputs.checks(good, {})) and ScadaOutputs.checks(good, {}).size() == 1, "no heartbeat is a warning, not an error")
	_ok(ScadaOutputs.has_errors(ScadaOutputs.checks(good, {"heartbeat_entity": "switch.hb"})), "a heartbeat that is not a helper is an error")
	var dup := [_link("switch.p", {"id": "a"}), _link("switch.p", {"id": "b", "tag": "node.other"})]
	_ok(ScadaOutputs.has_errors(ScadaOutputs.checks(dup, st)), "one entity driven by two outputs is an error")
	_ok(ScadaOutputs.has_errors(ScadaOutputs.checks([_link("sensor.x", {"id": "a"})], st)) and ScadaOutputs.has_errors(ScadaOutputs.checks([_link("", {"id": "a"})], st))
		and ScadaOutputs.has_errors(ScadaOutputs.checks([_link("switch.p", {"id": "a", "tag": ""})], st)), "an undrivable entity, no entity and no tag are errors")
	var hold := ScadaOutputs.checks([_link("switch.p", {"id": "a", "safe": "hold"})], st)
	_ok(hold.size() == 1 and str(hold[0]["level"]) == "warn", "no safe state is a warning")
	var ns := ScadaOutputs.normalized_settings({"heartbeat_s": 0.0, "timeout_s": 1.0})
	_ok(float(ns["heartbeat_s"]) >= 2.0 and float(ns["timeout_s"]) >= 10.0, "the heartbeat's times have floors")
	var y := ScadaOutputs.watchdog_yaml([_link("switch.p", {"id": "a"}), _link("valve.feed", {"id": "b", "safe": 0.0}), _link("switch.keep", {"id": "c", "safe": "hold"})], st)
	_ok(y.contains("entity_id: input_boolean.hb") and y.contains("seconds: 45"), "the watchdog triggers on the heartbeat standing still")
	_ok(y.contains("service: switch.turn_off") and y.contains("entity_id: switch.p") and y.contains("service: valve.set_valve_position") and y.contains("position: 0"), "and puts each output to its safe state")
	_ok(not y.contains("switch.keep"), "an output left as it is stays out of it")
	_ok(not y.contains("\t") and y.ends_with("\n"), "it is spaces-only YAML")
