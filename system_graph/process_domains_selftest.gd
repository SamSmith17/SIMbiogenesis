extends SceneTree

## Phase 3b, second part (offline): breakers that trip (BreakerTrip), the
## design checks (ProcessChecks), wires / cables / breakers made from the lens
## (ProcessEdit), instruments in the picture (MimicGraphSource).
##
## Carries EXPECTED_CHECKS; --import first.
##   godot --headless --path . --script system_graph/process_domains_selftest.gd

const EXPECTED_CHECKS := 51

const _MODEL := preload("res://system_graph/data/graph_model.gd")

const STATIC := {
	"controller": [{"id": "ac_out", "polarity": "ac", "rx": 0.5, "ry": 1.0}, {"id": "pvPositive", "polarity": "positive", "rx": 0.2, "ry": 0.0}],
	"appliance": [{"id": "input", "polarity": "load", "rx": 0.5, "ry": 0.0}, {"id": "inputBottom", "polarity": "load", "rx": 0.5, "ry": 1.0}],
	"acbreaker": [{"id": "input", "polarity": "ac", "rx": 0.5, "ry": 0.0}, {"id": "output", "polarity": "ac", "rx": 0.5, "ry": 1.0}],
	"battery": [{"id": "positive", "polarity": "positive", "rx": 0.3, "ry": 0.0}],
}

var _checks := 0
var _fails := 0


func _init() -> void:
	_test_breaker()
	_test_wiring()
	_test_checks()
	_test_instruments()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		print("FAIL check count %d != EXPECTED_CHECKS %d" % [_checks, EXPECTED_CHECKS])
	print("PROCESS DOMAINS SELFTEST %s  (%d checks, %d failed)" % ["PASS" if _fails == 0 else "FAIL", _checks, _fails])
	quit(0 if _fails == 0 else 1)


func _ok(cond: bool, what: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		print("  FAIL " + what)


func _handles(it: Dictionary) -> Array:
	return GraphPortService.resolved_handles(it, STATIC)


func _test_breaker() -> void:
	var s := BreakerTrip.make_specs("B", 15.0)
	_ok(BreakerTrip.is_closed(s) and is_equal_approx(BreakerTrip.amps(s, 1200.0), 10.0), "breaker: 1200 W at 120 V is 10 A")
	var p := BreakerTrip.step(s, 1200.0, 100.0)
	_ok(not p.has("tripped") and is_equal_approx(float(p.get("live_amps", 0.0)), 10.0), "breaker: under its rating it holds and reads its amps")
	s.merge(p, true)
	# 18 A on 15: over, but not at once.
	p = BreakerTrip.step(s, 2160.0, 100.0)
	_ok(not p.has("tripped") and is_equal_approx(float(p.get("over_since_h", -1.0)), 100.0), "breaker: over its rating starts the count")
	s.merge(p, true)
	p = BreakerTrip.step(s, 2160.0, 100.0 + 10.0 / 3600.0)
	_ok(not p.has("tripped"), "breaker: 10 s over is not yet a trip")
	s.merge(p, true)
	p = BreakerTrip.step(s, 2160.0, 100.0 + 21.0 / 3600.0)
	_ok(bool(p.get("tripped", false)) and p.get("closed", true) == false and is_equal_approx(float(p["trip_amps"]), 18.0), "breaker: 21 s over trips it open")
	s.merge(p, true)
	_ok(BreakerTrip.state_words(s) == "Tripped at 18 A", "breaker: it says so (%s)" % BreakerTrip.state_words(s))
	_ok(BreakerTrip.step(s, 2160.0, 101.0).is_empty(), "breaker: tripped, it stays open")
	s.merge(BreakerTrip.reset(), true)
	_ok(BreakerTrip.is_closed(s) and not bool(s["tripped"]), "breaker: a reset closes it")
	# Back under before the delay: the count clears.
	s.merge(BreakerTrip.step(s, 2160.0, 200.0), true)
	p = BreakerTrip.step(s, 600.0, 200.0 + 5.0 / 3600.0)
	_ok(is_equal_approx(float(p.get("over_since_h", 0.0)), -1.0), "breaker: back under its rating clears the count")
	s.merge(p, true)
	# Twice the rating: at once.
	p = BreakerTrip.step(s, 3600.0, 300.0)
	_ok(bool(p.get("tripped", false)), "breaker: twice its rating trips at once")
	var f := BreakerTrip.make_specs("F", 10.0, true)
	f.merge(BreakerTrip.step(f, 2500.0, 1.0), true)
	_ok(BreakerTrip.state_words(f).begins_with("Blown"), "fuse: it blows")
	var again := BreakerTrip.make_specs("B", 15.0)
	_ok(str(BreakerTrip.step(again, 2160.0, 5.0)) == str(BreakerTrip.step(again, 2160.0, 5.0)), "breaker: deterministic")


func _test_wiring() -> void:
	var model: GraphModel = _MODEL.new()
	model.add_item({"id": "inv", "type": "controller", "x": 0.0, "y": 0.0, "specs": {"name": "Inverter"}})
	model.add_item({"id": "lamp", "type": "appliance", "x": 400.0, "y": 0.0, "specs": {"name": "Lamp", "avg_watts": 60.0}})
	model.add_item({"id": "bat", "type": "battery", "x": 0.0, "y": 300.0, "specs": {"name": "Bank"}})
	var r := ProcessEdit.link_power(model, "inv", "lamp", _handles)
	_ok(bool(r["ok"]), "wire: inverter → lamp")
	var c := model.get_connection(str(r["id"]))
	_ok(str(c.get("polarity", "")) == "ac" and str(c["source_handle_id"]) == "ac_out" and str(c["target_handle_id"]) == "input", "wire: AC, from its outlet to the load's input")
	_ok(not bool(ProcessEdit.link_power(model, "inv", "lamp", _handles)["ok"]), "wire: not twice")
	var r2 := ProcessEdit.link_power(model, "bat", "lamp", _handles)
	_ok(not bool(r2["ok"]) and str(r2["why"]).contains("no AC outlet"), "wire: a battery has no AC outlet, and it says so")
	var r3 := ProcessEdit.link_power(model, "inv", "bat", _handles)
	_ok(not bool(r3["ok"]) and str(r3["why"]).contains("does not take AC"), "wire: a battery does not take AC")
	# A breaker into that wire.
	var sp := ProcessEdit.split_power(model, str(r["id"]), 15.0)
	_ok(bool(sp["ok"]) and BreakerTrip.is_breaker(model.get_item(str(sp["id"]))), "breaker tool: a breaker goes into the wire")
	var bid := str(sp["id"])
	var into := false
	var out := false
	for w in model.get_connections_in_scope("root"):
		if str(w["source_item_id"]) == "inv" and str(w["target_item_id"]) == bid and str(w["target_handle_id"]) == "input":
			into = true
		if str(w["source_item_id"]) == bid and str(w["target_item_id"]) == "lamp" and str(w["source_handle_id"]) == "output" and str(w["target_handle_id"]) == "input":
			out = true
	_ok(into and out and model.get_connections_in_scope("root").size() == 2, "breaker tool: inverter → breaker → lamp")
	_ok(not bool(ProcessEdit.split_power(model, "nope")["ok"]), "breaker tool: no wire, no breaker")
	# From a breaker onward.
	model.add_item({"id": "fan", "type": "appliance", "x": 600.0, "y": 0.0, "specs": {"name": "Fan"}})
	var r4 := ProcessEdit.link_power(model, bid, "fan", _handles)
	_ok(bool(r4["ok"]) and str(model.get_connection(str(r4["id"]))["source_handle_id"]) == "output", "wire: a breaker's output feeds another load")
	# Network cables.
	for pair in [["srv", ScadaNet.ROLE_SERVER], ["sw", ScadaNet.ROLE_SWITCH], ["ap", ScadaNet.ROLE_AP], ["b1", ScadaNet.ROLE_BOARD], ["b2", ScadaNet.ROLE_BOARD]]:
		model.add_item({"id": pair[0], "type": "appliance", "x": 0.0, "y": 600.0, "specs": ScadaNet.make_specs(pair[1], pair[0], 5.0, {"ports": 2})})
	var d1 := ProcessEdit.link_data(model, "srv", "sw", _handles)
	_ok(bool(d1["ok"]) and str(model.get_connection(str(d1["id"]))["target_handle_id"]) == "data_0", "cable: server → the switch's first port")
	var d2 := ProcessEdit.link_data(model, "sw", "b1", _handles)
	_ok(bool(d2["ok"]) and str(model.get_connection(str(d2["id"]))["source_handle_id"]) == "data_1", "cable: the next one takes the next free port")
	var d3 := ProcessEdit.link_data(model, "sw", "ap", _handles)
	_ok(not bool(d3["ok"]) and str(d3["why"]).contains("no free port"), "cable: a full switch says it has no free port")
	var d4 := ProcessEdit.link_data(model, "ap", "b2", _handles)
	_ok(bool(d4["ok"]) and ScadaNet.kind_of(model.get_connection(str(d4["id"]))) == "wireless", "cable: an access point reaches a board by Wi-Fi")
	_ok(not bool(ProcessEdit.link_data(model, "b1", "b2", _handles)["ok"]), "cable: board to board is refused")
	_ok(not bool(ProcessEdit.link_data(model, "lamp", "sw", _handles)["ok"]), "cable: a lamp is not a network device")
	_ok(not bool(ProcessEdit.link_data(model, "b1", "sw", _handles)["ok"]), "cable: not twice (either way round)")
	var reach := ScadaNet.reach(model.items, model.connections)
	_ok(bool(reach["nodes"]["b1"]["ok"]) and not bool(reach["nodes"]["b2"]["ok"]), "cable: what was built reaches b1; the access point has no uplink yet")


func _test_checks() -> void:
	var items := [
		{"id": "a", "type": "resource", "specs": {"name": "A", "resource_kind": "water"}},
		{"id": "b", "type": "resource", "specs": {"name": "B", "resource_kind": "water"}},
		{"id": "g", "type": "resource", "specs": {"name": "Grey", "resource_kind": "greywater"}},
		{"id": "v", "type": "processor", "specs": FlowCtl.make_specs("Valve", FlowCtl.KIND_VALVE, "water", 100.0)},
		{"id": "p", "type": "processor", "specs": FlowCtl.make_specs("Pump", FlowCtl.KIND_PUMP, "water", 100.0)},
		{"id": "inv", "type": "controller", "specs": {"name": "Inverter"}},
		{"id": "lamp", "type": "appliance", "specs": {"name": "Lamp"}},
		{"id": "brk", "type": "acbreaker", "specs": BreakerTrip.make_specs("Breaker", 15.0)},
	]
	_ok(ProcessChecks.run(items, []).size() == 1, "checks: an unwired pump has no power (and nothing else is wrong)")
	(items[3]["specs"] as Dictionary)["ctl_block"] = FlowCtl.BLOCK_UPHILL
	(items[4]["specs"] as Dictionary)["ctl_block"] = FlowCtl.BLOCK_LIFT
	(items[7]["specs"] as Dictionary).merge({"tripped": true, "closed": false, "trip_amps": 22.0}, true)
	var conns := [
		{"id": "w1", "polarity": "ac", "source_item_id": "inv", "target_item_id": "lamp", "overload_ratio": 1.3, "drop_pct": 5.5},
		{"id": "w2", "polarity": "ac", "source_item_id": "inv", "target_item_id": "p", "drop_pct": 1.0},
		{"id": "p1", "polarity": "resource", "resource_type": "water", "source_item_id": "a", "target_item_id": "b",
			"conduit_type": "pex_blue", "flow_rate": 4000.0},
		{"id": "p2", "polarity": "resource", "resource_type": "greywater", "source_item_id": "b", "target_item_id": "g",
			"conduit_type": "abs_dwv", "visible_3d": true, "route_length_m": 10.0, "invert_in_m": 1.0, "invert_out_m": 0.95},
	]
	var cs := ProcessChecks.run(items, conns, [{"level": "error", "text": "Board: not on the network.", "ids": ["x"]}])
	var by := {}
	for c in cs:
		by[str((c["ids"] as Array)[0])] = c
	_ok(str(by["v"]["text"]).contains("needs a pump") and str(by["v"]["level"]) == "error", "checks: an uphill valve needs a pump")
	_ok(str(by["p"]["text"]).contains("cannot lift"), "checks: a pump past its lift")
	_ok(str(by["brk"]["text"]).contains("has tripped") and str(by["brk"]["text"]).contains("22 A"), "checks: a tripped breaker, with what it carried")
	var w1 := cs.filter(func(c: Dictionary) -> bool: return (c["ids"] as Array)[0] == "w1")
	_ok(w1.size() == 2, "checks: the overloaded wire is named for its load and its voltage drop")
	_ok(not by.has("w2"), "checks: a 1 % drop is fine")
	_ok(ConduitKinds.has_type("pex_blue") and ConduitKinds.has_type("abs_dwv"), "checks: (the test's pipe kind exists)")
	_ok(by.has("p1") and str(by["p1"]["text"]).contains("m/s"), "checks: 4000 L/h in half-inch pipe runs too fast")
	_ok(by.has("p2") and str(by["p2"]["text"]).contains("0.5 %"), "checks: a drain that falls 0.5 %% is too flat (%s)" % str(by.get("p2", {}).get("text", "")))
	_ok(str(by["x"]["domain"]) == "data", "checks: the network's are passed through")
	_ok(str(cs[0]["level"]) == "error" and str(cs[cs.size() - 1]["level"]) == "warn", "checks: problems before warnings")
	_ok(ProcessChecks.summary(cs).contains("problems") and ProcessChecks.summary([]) == "Checks pass", "checks: the summary (%s)" % ProcessChecks.summary(cs))


func _test_instruments() -> void:
	var L := MimicGraphSource
	var board := {"id": "brd", "type": "appliance", "x": 300.0, "y": 300.0, "specs": ScadaNet.make_specs(ScadaNet.ROLE_BOARD, "Board", 1.0)}
	var srv := {"id": "srv", "type": "appliance", "x": 0.0, "y": 300.0, "specs": ScadaNet.make_specs(ScadaNet.ROLE_SERVER, "Server", 15.0)}
	var items := [
		{"id": "t1", "type": "resource", "x": 0.0, "y": 0.0, "specs": {"name": "Tank", "resource_kind": "water", "capacity_qty": 500.0, "level": 0.4}},
		{"id": "v", "type": "processor", "x": 200.0, "y": 0.0, "specs": FlowCtl.make_specs("Valve", FlowCtl.KIND_VALVE, "water", 100.0)},
		{"id": "t2", "type": "resource", "x": 400.0, "y": 0.0, "specs": {"name": "Tank 2", "resource_kind": "water", "capacity_qty": 500.0, "level": 0.1}},
		board, srv,
	]
	var conns := [
		{"id": "p1", "polarity": "resource", "resource_type": "water", "source_item_id": "t1", "target_item_id": "v"},
		{"id": "p2", "polarity": "resource", "resource_type": "water", "source_item_id": "v", "target_item_id": "t2"},
		{"id": "n1", "polarity": "data", "source_item_id": "srv", "source_handle_id": "data", "target_item_id": "brd", "target_handle_id": "data"},
	]
	var ins := [
		{"id": "sensor.b_level", "item": "t1", "board": "brd", "src": "tank.t1.distance_m", "label": "Level", "text": "0.60 m", "available": true},
		{"id": "binary_sensor.b_high", "item": "t1", "board": "brd", "src": "tank.t1.high", "label": "High", "text": "off", "available": true},
		{"id": "sensor.gone", "item": "missing", "board": "brd", "src": "tank.missing.distance_m", "label": "X", "text": "", "available": false},
	]
	var doc := L.build(items, conns, {L.LAYER_PIPES: true}, ins)
	var el := {}
	for e in doc["elements"]:
		el[str(e["id"])] = e
	_ok(el.has("ins:sensor.b_level") and el.has("ins:binary_sensor.b_high") and not el.has("ins:sensor.gone"), "instruments: a bubble for each reading of a thing in the picture")
	var bub: Dictionary = el["ins:sensor.b_level"]
	var tank: Dictionary = el["t1"]
	_ok(str(bub["kind"]) == "instr" and str(bub["letters"]) == "LI" and str(el["ins:binary_sensor.b_high"]["letters"]) == "LS", "instruments: their letters")
	_ok((bub["pos"] as Vector2).y < (tank["pos"] as Vector2).y - (tank["size"] as Vector2).y * 0.5
		and absf((bub["pos"] as Vector2).x - (tank["pos"] as Vector2).x) < (tank["size"] as Vector2).x * 0.5, "instruments: standing on top of the tank")
	_ok(not is_equal_approx((bub["pos"] as Vector2).x, (el["ins:binary_sensor.b_high"]["pos"] as Vector2).x), "instruments: two on one thing stand side by side")
	var has_sig := false
	for p in doc["pipes"]:
		if str(p["id"]).begins_with("sig:"):
			has_sig = true
	_ok(not has_sig, "instruments: no signal lines while the Network lines are hidden")
	var doc2 := L.build(items, conns, {L.LAYER_PIPES: true, L.LAYER_DATA: true}, ins)
	var sigs := 0
	for p in doc2["pipes"]:
		if str(p["id"]).begins_with("sig:") and bool(p["dashed"]) and str(p["to"]) == "brd":
			sigs += 1
	_ok(sigs == 2, "instruments: with Network shown, a dashed signal line from each to its board (%d)" % sigs)
	var st := L.state(items, conns, {}, ins)
	_ok(str(st["el"]["ins:sensor.b_level"]["value"]) == "0.60 m" and not bool(st["el"]["ins:sensor.b_level"]["warn"]), "instruments: the reading")
	ins[0]["available"] = false
	ins[0]["text"] = "not on the network"
	st = L.state(items, conns, {}, ins)
	_ok(bool(st["el"]["ins:sensor.b_level"]["warn"]) and bool(st["pipe"]["sig:sensor.b_level"]["warn"]), "instruments: an unheard one warns, and so does its signal line")
	_ok(L.letters_for("load.x.power_w") == "JI" and L.letters_for("item.x.switch") == "XY" and L.letters_for("item.x.voltage") == "EI", "instruments: letters for power, a relay, a voltage")
	var brk := {"id": "k", "type": "acbreaker", "specs": BreakerTrip.make_specs("Breaker", 15.0)}
	(brk["specs"] as Dictionary).merge({"tripped": true, "closed": false, "trip_amps": 30.0}, true)
	var st2 := L.state([brk], [])
	_ok(bool(st2["el"]["k"]["warn"]) and str(st2["el"]["k"]["value"]) == "Tripped at 30 A" and L.glyph_of(brk) == "breaker", "a tripped breaker in the picture")
