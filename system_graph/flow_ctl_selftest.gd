extends SceneTree

## Valves and pumps on the graph (offline): FlowCtl's rules (opening, rate,
## height) and the flow engine running store → valve / pump → store: an open
## valve carries its rate, a closed one nothing, a throttled one its share;
## a valve never moves water uphill and a pump does, up to its lift; a pump
## needs power; mass is exact; a full target stops the line.
##
## Carries EXPECTED_CHECKS; --import first.
##   godot --headless --path . --script system_graph/flow_ctl_selftest.gd

const EXPECTED_CHECKS := 27

const _MODEL := preload("res://system_graph/data/graph_model.gd")
const _ENGINE := preload("res://system_graph/resource_flow_engine.gd")

var _checks := 0
var _fails := 0


func _init() -> void:
	_test_rules()
	_test_valve_line()
	_test_heights()
	_test_pump()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		print("FAIL check count %d != EXPECTED_CHECKS %d" % [_checks, EXPECTED_CHECKS])
	print("FLOW CTL SELFTEST %s  (%d checks, %d failed)" % ["PASS" if _fails == 0 else "FAIL", _checks, _fails])
	quit(0 if _fails == 0 else 1)


func _ok(cond: bool, what: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		print("  FAIL " + what)


func _test_rules() -> void:
	var v := FlowCtl.make_specs("Ball valve", FlowCtl.KIND_VALVE, "water", 600.0)
	_ok(FlowCtl.is_flowctl(v) and FlowCtl.kind_of(v) == FlowCtl.KIND_VALVE, "a valve is a flow control")
	_ok(absf(FlowCtl.rate(v) - 600.0) < 1e-9, "open: its full rate")
	v["requested_state"] = "off"
	_ok(FlowCtl.rate(v) == 0.0 and FlowCtl.state_words(v) == "Closed", "closed: nothing, and it says Closed")
	v["requested_state"] = "on"
	v["open"] = 0.4
	_ok(absf(FlowCtl.rate(v) - 600.0) < 1e-9, "an on / off valve has no half-way")
	v["throttle"] = true
	_ok(absf(FlowCtl.rate(v) - 240.0) < 1e-9 and FlowCtl.state_words(v) == "40 % open", "a control valve carries its share")
	_ok(FlowCtl.block_for(v, -2.0) == FlowCtl.BLOCK_UPHILL and FlowCtl.block_for(v, 3.0) == "" and FlowCtl.block_for(v, NAN) == "",
		"a valve is stopped by a climb, never by a drop or unknown heights")
	var p := FlowCtl.make_specs("Pump", FlowCtl.KIND_PUMP, "water", 900.0, {"watts": 250.0, "max_lift_m": 8.0})
	_ok(FlowCtl.block_for(p, -6.0) == "" and FlowCtl.block_for(p, -9.0) == FlowCtl.BLOCK_LIFT, "a pump lifts up to its limit")
	_ok(float(p["watts"]) == 250.0 and str(p["energy_source"]) == "ac" and float(v["watts"]) == 0.0, "a pump draws power, a valve none")
	var c := FlowCtl.make_specs("Check", FlowCtl.KIND_CHECK, "water", 300.0, {"state": "off"})
	_ok(FlowCtl.is_on(c) and FlowCtl.rate(c) == 300.0, "a check valve is always open")
	_ok((p["inputs"] as Array).size() == 1 and str(p["inputs"][0]["kind"]) == "water" and str(p["outputs"][0]["kind"]) == "water",
		"one port in and one out, of the line's kind")
	_ok(FlowCtl.verbs(p)[2] == "Switch on" and FlowCtl.verbs(v)[2] == "Open it", "words per kind")


## store A → ctl → store B; 1000 L each; A starts at 80 %, B at 10 %.
func _line(ctl: Dictionary, elev_a: float = NAN, elev_b: float = NAN, power: bool = true) -> Dictionary:
	var model = _MODEL.new()
	var a := {"id": "a", "type": "resource", "x": 0.0, "y": 0.0,
		"specs": {"name": "A", "resource_kind": "water", "capacity_qty": 1000.0, "capacity_unit": "L", "level": 0.8}}
	var b := {"id": "b", "type": "resource", "x": 400.0, "y": 0.0,
		"specs": {"name": "B", "resource_kind": "water", "capacity_qty": 1000.0, "capacity_unit": "L", "level": 0.1}}
	if not is_nan(elev_a):
		a["elevation_m"] = elev_a
		b["elevation_m"] = elev_b
	model.add_item(a)
	model.add_item(b)
	model.add_item({"id": "c", "type": "processor", "x": 200.0, "y": 0.0, "specs": ctl})
	model.add_connection({"id": "w1", "polarity": "resource", "resource_type": "water",
		"source_item_id": "a", "source_handle_id": "hub_out", "target_item_id": "c", "target_handle_id": "res_in_0"})
	model.add_connection({"id": "w2", "polarity": "resource", "resource_type": "water",
		"source_item_id": "c", "source_handle_id": "res_out_0", "target_item_id": "b", "target_handle_id": "hub_in"})
	if FlowCtl.kind_of(ctl) == FlowCtl.KIND_PUMP:
		model.add_item({"id": "inv", "type": "controller", "x": 200.0, "y": -200.0, "specs": {"name": "Inverter"}})
		model.add_connection({"id": "pw", "polarity": "ac", "source_item_id": "inv", "source_handle_id": "ac_out",
			"target_item_id": "c", "target_handle_id": "power_in"})
	var engine = _ENGINE.new()
	engine.setup(model, null)
	engine.power_available_override = 1 if power else 0
	return {"model": model, "engine": engine}


func _run(g: Dictionary, hours: float) -> void:
	g["engine"].simulate_step_for_test(0.0, 0.0)
	var steps := int(round(hours / 0.1))
	for i in steps:
		g["engine"].simulate_step_for_test(float(i + 1) * 0.1, 0.1)


func _stock(g: Dictionary, id: String) -> float:
	var sp: Dictionary = g["model"].get_item(id).get("specs", {})
	return float(sp.get("level", 0.0)) * float(sp.get("capacity_qty", 0.0))


func _test_valve_line() -> void:
	var g := _line(FlowCtl.make_specs("Valve", FlowCtl.KIND_VALVE, "water", 200.0))
	_run(g, 1.0)
	_ok(absf(_stock(g, "b") - 300.0) < 6.0, "an open valve carries 200 L in an hour (B %.1f L)" % _stock(g, "b"))
	_ok(absf(_stock(g, "a") + _stock(g, "b") - 900.0) < 0.5, "what leaves A reaches B (%.2f L in all)" % (_stock(g, "a") + _stock(g, "b")))
	var closed := FlowCtl.make_specs("Valve", FlowCtl.KIND_VALVE, "water", 200.0, {"state": "off"})
	var g2 := _line(closed)
	_run(g2, 1.0)
	_ok(absf(_stock(g2, "b") - 100.0) < 0.5 and absf(_stock(g2, "a") - 800.0) < 0.5, "a closed valve carries nothing")
	var half := FlowCtl.make_specs("Control valve", FlowCtl.KIND_VALVE, "water", 200.0, {"throttle": true})
	half["open"] = 0.5
	var g3 := _line(half)
	_run(g3, 1.0)
	_ok(absf(_stock(g3, "b") - 200.0) < 6.0, "half open carries half (B %.1f L)" % _stock(g3, "b"))
	# A full target stops the line.
	var big := FlowCtl.make_specs("Valve", FlowCtl.KIND_VALVE, "water", 5000.0)
	var g4 := _line(big)
	_run(g4, 2.0)
	_ok(_stock(g4, "b") <= 1000.5 and _stock(g4, "b") > 850.0, "the line stops when B is full (B %.1f L)" % _stock(g4, "b"))
	_ok(absf(_stock(g4, "a") + _stock(g4, "b") - 900.0) < 1.0, "and nothing is lost (%.2f L)" % (_stock(g4, "a") + _stock(g4, "b")))
	# The wires show the flow.
	var w2: Dictionary = g["model"].connections[1]
	_ok(float(w2.get("flow_rate", 0.0)) > 150.0, "the wire into B carries the flow (%.1f /h)" % float(w2.get("flow_rate", 0.0)))


func _test_heights() -> void:
	var down := _line(FlowCtl.make_specs("Valve", FlowCtl.KIND_VALVE, "water", 200.0), 10.0, 4.0)
	_run(down, 1.0)
	_ok(_stock(down, "b") > 250.0, "downhill a valve flows")
	var up := _line(FlowCtl.make_specs("Valve", FlowCtl.KIND_VALVE, "water", 200.0), 4.0, 10.0)
	_run(up, 1.0)
	_ok(absf(_stock(up, "b") - 100.0) < 0.5, "uphill a valve moves nothing")
	var sp: Dictionary = up["model"].get_item("c").get("specs", {})
	_ok(str(sp.get("ctl_block", "")) == FlowCtl.BLOCK_UPHILL and FlowCtl.state_words(sp).contains("pump"),
		"and the node says it needs a pump")


func _test_pump() -> void:
	var pump := FlowCtl.make_specs("Pump", FlowCtl.KIND_PUMP, "water", 300.0, {"watts": 200.0, "max_lift_m": 8.0})
	var g := _line(pump.duplicate(true), 4.0, 10.0)
	_run(g, 1.0)
	_ok(absf(_stock(g, "b") - 400.0) < 9.0, "a pump lifts 300 L six metres in an hour (B %.1f L)" % _stock(g, "b"))
	var st: Dictionary = g["model"].get_item("c").get("specs", {})
	_ok(str(st.get("node_state", "")) == GraphNodeState.RUNNING, "and reads as running (%s)" % str(st.get("node_state", "")))
	var dark := _line(pump.duplicate(true), 4.0, 10.0, false)
	_run(dark, 1.0)
	_ok(absf(_stock(dark, "b") - 100.0) < 0.5, "with no power it moves nothing")
	var far := _line(pump.duplicate(true), 0.0, 20.0)
	_run(far, 1.0)
	_ok(absf(_stock(far, "b") - 100.0) < 0.5, "past its lift it moves nothing")
	_ok(str((far["model"].get_item("c").get("specs", {}) as Dictionary).get("ctl_block", "")) == FlowCtl.BLOCK_LIFT, "and says why")
	var off := pump.duplicate(true)
	off["requested_state"] = "off"
	var g2 := _line(off, 4.0, 10.0)
	_run(g2, 1.0)
	_ok(absf(_stock(g2, "b") - 100.0) < 0.5, "switched off it moves nothing")
