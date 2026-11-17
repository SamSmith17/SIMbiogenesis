extends SceneTree

## Process picture selftest (offline): MimicLayout (the side-elevation
## projection, the drag warp, line helpers) and MimicTcSource (a tri-clamp
## design's network as a picture, and its live state).
##
## Carries EXPECTED_CHECKS; --import first.
##   godot --headless --path . --script core/scada/mimic_selftest.gd

const EXPECTED_CHECKS := 128

var _checks := 0
var _fails := 0


func _init() -> void:
	_test_projection()
	_test_warp()
	_test_lines()
	_test_reactor_picture()
	_test_live_state()
	_test_other_designs()
	_test_graph_picture()
	_test_graph_down()
	_test_graph_layers()
	_test_reroute()
	_test_reroute_pictures()
	_test_icons()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		print("FAIL check count %d != EXPECTED_CHECKS %d" % [_checks, EXPECTED_CHECKS])
	print("MIMIC SELFTEST %s  (%d checks, %d failed)" % ["PASS" if _fails == 0 else "FAIL", _checks, _fails])
	quit(0 if _fails == 0 else 1)


func _ok(cond: bool, what: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		print("  FAIL " + what)


func _test_projection() -> void:
	# A run along x: x is across.
	var along_x := PackedVector3Array([Vector3(0, 0, 0), Vector3(1000, 0, 0), Vector3(2000, 100, 50)])
	var pr := MimicLayout.projection_for(along_x)
	_ok(pr.across == Vector3.RIGHT, "a run along x is drawn left to right")
	var a := pr.to_2d(Vector3(0, 0, 0))
	var b := pr.to_2d(Vector3(1000, 0, 0))
	_ok(absf((b.x - a.x) - 1000.0) < 1e-3 and absf(b.y - a.y) < 1e-3, "a metre across is a metre in the picture")
	var up := pr.to_2d(Vector3(0, 500, 0))
	_ok(up.y < a.y and absf((a.y - up.y) - 500.0) < 1e-3 and absf(up.x - a.x) < 1e-3, "higher is higher on the page, and straight up")
	# Depth is drawn up and to the right, shortened.
	var back := pr.to_2d(Vector3(0, 0, 0) + pr.depth * 100.0)
	_ok(absf((back.x - a.x) - 100.0 * MimicLayout.DEPTH_K) < 1e-3 and absf((a.y - back.y) - 100.0 * MimicLayout.DEPTH_K) < 1e-3,
		"what stands behind is drawn up and to the right at the depth factor")
	_ok(absf(pr.depth_of(Vector3(0, 0, 0) + pr.depth * 100.0) - pr.depth_of(Vector3.ZERO) - 100.0) < 1e-3, "depth_of measures along the depth axis")
	var along_z := PackedVector3Array([Vector3(0, 0, 0), Vector3(20, 0, 900), Vector3(0, 0, 1800)])
	_ok(MimicLayout.projection_for(along_z).across == Vector3.BACK, "a run along z turns the view")
	# One far fitting does not decide the side: most of the points do.
	var mostly_z := PackedVector3Array([Vector3(0, 0, 0), Vector3(1200, 0, 0)])
	for i in 30:
		mostly_z.append(Vector3(0, float(i) * 20.0, -400.0 + float(i % 2) * 800.0))
	_ok(MimicLayout.projection_for(mostly_z).across == Vector3.BACK, "the side is chosen by where most of the pipework is")


func _test_warp() -> void:
	var pins := [{"c": Vector2(0, 0), "r": 100.0, "off": Vector2(50, -20)}]
	_ok(MimicLayout.warp(Vector2(10, 10), pins).distance_to(Vector2(60, -10)) < 1e-4, "inside a pin's radius a point moves with it")
	_ok(MimicLayout.warp(Vector2(100.0 * MimicLayout.FALLOFF + 1.0, 0), pins).distance_to(Vector2(100.0 * MimicLayout.FALLOFF + 1.0, 0)) < 1e-4,
		"beyond the falloff nothing moves")
	var mid := MimicLayout.warp(Vector2(200, 0), pins)
	_ok(mid.x > 200.0 and mid.x < 250.0, "between, it moves part of the way (%.1f)" % mid.x)
	# Continuity: no jump at the radius.
	var just_in := MimicLayout.warp(Vector2(99.9, 0), pins)
	var just_out := MimicLayout.warp(Vector2(100.1, 0), pins)
	_ok(just_in.distance_to(just_out) < 1.0, "the field is continuous at the radius")
	_ok(MimicLayout.warp(Vector2(5, 5), []) == Vector2(5, 5), "no pins, no move")
	# Two pins pulling opposite ways: the middle goes nowhere far.
	var two := [{"c": Vector2(-50, 0), "r": 100.0, "off": Vector2(-40, 0)}, {"c": Vector2(50, 0), "r": 100.0, "off": Vector2(40, 0)}]
	_ok(MimicLayout.warp(Vector2(0, 0), two).length() < 1e-4, "overlapping pins share a point out (never more than one whole move)")
	var line := MimicLayout.warp_line(PackedVector2Array([Vector2(0, 0), Vector2(1000, 0)]), pins)
	_ok(line[0].distance_to(Vector2(50, -20)) < 1e-4 and line[1].distance_to(Vector2(1000, 0)) < 1e-4,
		"a pipe's near end follows the dragged thing, its far end stays")


func _test_lines() -> void:
	var pts := PackedVector2Array([Vector2(0, 0), Vector2(100, 0), Vector2(100, 50)])
	_ok(absf(MimicLayout.length_of(pts) - 150.0) < 1e-4, "length of a polyline")
	var at := MimicLayout.point_at(pts, 120.0)
	_ok((at[0] as Vector2).distance_to(Vector2(100, 20)) < 1e-4 and (at[1] as Vector2).distance_to(Vector2(0, 1)) < 1e-4, "the point and direction along it")
	var dense := MimicLayout.densify(pts, 20.0)
	_ok(dense.size() == 1 + 5 + 3 and absf(MimicLayout.length_of(dense) - 150.0) < 1e-3, "densify keeps the corners and the length")
	_ok(absf(MimicLayout.distance_to_line(Vector2(50, 30), pts) - 30.0) < 1e-4, "distance to a polyline")


func _design(id: String) -> Dictionary:
	return TcDesign.solve(TcPresets.builtin(id))


func _test_reactor_picture() -> void:
	var d := _design("biochar_reactor")
	var net := TcProcNet.build(d)
	var doc := MimicTcSource.build(d, net)
	var els: Array = doc["elements"]
	var by_kind := {}
	for e in els:
		by_kind[str(e["kind"])] = int(by_kind.get(str(e["kind"]), 0)) + 1
	_ok(int(by_kind.get("vessel", 0)) == 1, "one vessel")
	_ok(int(by_kind.get("heater", 0)) == 2, "two heating elements")
	_ok(int(by_kind.get("valve", 0)) >= 1, "the drain's butterfly valve")
	_ok(int(by_kind.get("end", 0)) == (net["boundaries"] as Array).size(), "one end per open port")
	var ids := {}
	var dup := false
	for e in els:
		if ids.has(e["id"]):
			dup = true
		ids[e["id"]] = true
	_ok(not dup, "element ids are unique")
	var pipes: Array = doc["pipes"]
	_ok(pipes.size() >= 10, "the pipework is drawn (%d lines)" % pipes.size())
	var shells := 0
	var bad := false
	for p in pipes:
		if int(p["shell"]) >= 0:
			shells += 1
			if str(net["cvs"][int(p["shell"])]["role"]) != "coolant":
				bad = true
		if (p["pts"] as PackedVector2Array).size() < 2 or float(p["w"]) < MimicTcSource.MIN_PIPE_W_MM - 1e-6:
			bad = true
		if str(net["cvs"][int(p["cv"])]["role"]) in ["coolant", "jacket", "vessel"]:
			bad = true
	_ok(shells >= 2 and not bad, "condensers carry their cooling water as a shell; no coolant or vessel is a line (%d shells)" % shells)
	# The vessel stands on its base, upright, as tall as its shell.
	var v: Dictionary = {}
	for e in els:
		if str(e["kind"]) == "vessel":
			v = e
	_ok(absf(float(v["shell_h"]) - 650.0) < 1.0 and absf(float(v["shell_w"]) - 340.0) < 6.0, "the vessel's shell is its real size (Ø340 less its wall × 650 mm): %s × %s" % [v["shell_w"], v["shell_h"]])
	_ok(int(v["jacket_cv"]) >= 0, "and knows its jacket")
	var rect := Rect2((v["pos"] as Vector2) - (v["size"] as Vector2) * 0.5, v["size"] as Vector2)
	_ok(rect.grow(40.0).has_point(v["base"] as Vector2) and (v["base"] as Vector2).y > rect.get_center().y,
		"the shell's base is at the bottom of the part")
	# Heaters reach INTO the vessel (up from the bottom).
	var into := true
	for e in els:
		if str(e["kind"]) == "heater" and (e["to"] as Vector2).y >= (e["from"] as Vector2).y:
			into = false
	_ok(into, "the elements point up into the charge")
	# Far things are listed first.
	var sorted_ok := true
	for i in range(1, pipes.size()):
		if float(pipes[i]["depth"]) > float(pipes[i - 1]["depth"]) + 1e-6:
			sorted_ok = false
	_ok(sorted_ok, "pipes are ordered far to near")
	var b: Rect2 = doc["bounds"]
	_ok(b.size.x > 400.0 and b.size.y > 800.0 and b.size.x < 4000.0, "the picture's bounds are the reactor's size (%d × %d mm)" % [int(b.size.x), int(b.size.y)])
	# Every valve lies along a direction.
	var dirs := true
	for e in els:
		if str(e["kind"]) == "valve" and not e.has("dir"):
			dirs = false
	_ok(dirs, "a valve knows which way its bore runs")
	# Deterministic.
	var doc2 := MimicTcSource.build(d, net)
	_ok(var_to_str(doc2["bounds"]) == var_to_str(doc["bounds"]) and (doc2["elements"] as Array).size() == els.size(), "building twice gives the same picture")


func _test_live_state() -> void:
	var d := _design("biochar_reactor")
	var sim := TcProcSim.create(d)
	var doc := MimicTcSource.build(d, sim.net)
	var s0 := MimicTcSource.state(sim, doc)
	_ok((s0["cv"] as Dictionary).size() == sim.n_cv, "a state per volume")
	_ok((s0["heater"] as Dictionary).size() == 2, "and per element")
	_ok(not (s0["bed"] as Dictionary).is_empty() and float(s0["bed"]["height_mm"]) > 50.0, "the charge has a height")
	var h0 := float(s0["bed"]["height_mm"])
	sim.run_for(3.0 * 3600.0)
	var s1 := MimicTcSource.state(sim, doc)
	_ok(float(s1["bed"]["t_max_c"]) > 300.0 and float(s1["bed"]["dry"]) > 0.9, "three hours in the charge is dry and hot")
	_ok(float(s1["bed"]["height_mm"]) < h0, "and has settled")
	var hot := 0
	for i in sim.n_cv:
		if float(s1["cv"][i]["t_c"]) > 60.0:
			hot += 1
	_ok(hot >= 2, "the vessel and the vapour line are hot (%d volumes)" % hot)
	var moving := 0
	for p in doc["pipes"]:
		if MimicTcSource.flow_sign(sim, doc, p) != 0:
			moving += 1
	_ok(moving >= 1, "gas is moving in the pipes (%d lines)" % moving)
	# A switched-off element reads off.
	var pid := str(sim.heater_parts[0])
	sim.set_actuator("heater:%s" % pid, false)
	var s2 := MimicTcSource.state(sim, doc)
	_ok(not bool(s2["heater"][pid]["on"]), "an element switched off reads off")
	# A closed valve reads closed.
	var vlink := -1
	for li in (sim.net["links"] as Array).size():
		if str(sim.net["links"][li]["kind"]) == "valve":
			vlink = li
	sim.set_actuator("valve:%s" % str(sim.net["links"][vlink]["part"]), true)
	_ok(bool(MimicTcSource.state(sim, doc)["link"][vlink]["open"]), "an opened valve reads open")
	sim.set_actuator("valve:%s" % str(sim.net["links"][vlink]["part"]), false)
	_ok(not bool(MimicTcSource.state(sim, doc)["link"][vlink]["open"]), "and closed again")


func _test_other_designs() -> void:
	var d := _design("biochar_genset")
	var sim := TcProcSim.create(d)
	var doc := MimicTcSource.build(d, sim.net)
	var kinds := {}
	for e in doc["elements"]:
		kinds[str(e["kind"])] = true
	_ok(kinds.has("holder") and kinds.has("engine") and kinds.has("dryer"), "the genset chain draws its gasometer, dryer and generator")
	var st := MimicTcSource.state(sim, doc)
	_ok((st["unit"] as Dictionary).size() >= 3, "each unit has a state")
	var still := _design("pot_still")
	var sim2 := TcProcSim.create(still)
	var doc2 := MimicTcSource.build(still, sim2.net)
	sim2.run_for(600.0)
	var st2 := MimicTcSource.state(sim2, doc2)
	_ok(float(st2["cv"][sim2.vessel_cv]["level"]) > 0.3 and (st2["bed"] as Dictionary).is_empty(),
		"a pot still's vessel shows its wash as a level, with no charge")
	# Every built-in with a vessel builds a picture without error.
	var all_ok := true
	for id in ["plastic_retort", "brew_kettle", "tc_condenser", "filter_train"]:
		var dd := _design(id)
		var nn := TcProcNet.build(dd)
		var dc := MimicTcSource.build(dd, nn)
		if (dc["pipes"] as Array).is_empty() and (dc["elements"] as Array).is_empty():
			all_ok = false
	_ok(all_ok, "the other built-ins build a picture too")


# ── the graph as a process picture (MimicGraphSource, Phase 3) ──────────────

func _g_item(id: String, type: String, x: float, specs: Dictionary) -> Dictionary:
	return {"id": id, "type": type, "x": x, "y": 0.0, "specs": specs}


func _g_wire(id: String, a: String, b: String, kind: String, rate: float = 0.0) -> Dictionary:
	return {"id": id, "source_item_id": a, "target_item_id": b, "polarity": "resource",
		"resource_type": kind, "flow_rate": rate, "flow_active": rate > 0.0}


func _test_graph_picture() -> void:
	var valve := FlowCtl.make_specs("Valve", FlowCtl.KIND_VALVE, "water", 100.0)
	var pump := FlowCtl.make_specs("Pump", FlowCtl.KIND_PUMP, "greywater", 60.0)
	var items := [
		_g_item("t1", "resource", 0.0, {"name": "Cistern", "resource_kind": "water", "capacity_qty": 1000.0, "capacity_unit": "L", "level": 0.5}),
		_g_item("v1", "processor", 100.0, valve),
		_g_item("t2", "resource", 200.0, {"name": "Day tank", "resource_kind": "water", "capacity_qty": 100.0, "capacity_unit": "L", "level": 0.25, "output_valve_open": false}),
		_g_item("m1", "processor", 300.0, {"name": "Washer", "node_state": "running"}),
		_g_item("t3", "resource", 400.0, {"name": "Grey", "resource_kind": "greywater", "capacity_qty": 200.0, "capacity_unit": "L", "level": 0.1}),
		_g_item("p1", "processor", 500.0, pump),
		_g_item("g1", "compound", 600.0, {"name": "Camp"}),
		_g_item("b1", "battery", 700.0, {"name": "Bank"}),
		_g_item("lone", "resource", 800.0, {"name": "Unpiped", "resource_kind": "water"}),
		_g_item("v2", "processor", 900.0, FlowCtl.make_specs("Spare", FlowCtl.KIND_CHECK, "water", 10.0)),
	]
	var conns := [
		_g_wire("w1", "t1", "v1", "water", 100.0),
		_g_wire("w2", "v1", "t2", "water", 100.0),
		_g_wire("w3", "t2", "m1", "water"),
		_g_wire("w4", "m1", "t3", "greywater", 5.0),
		_g_wire("w5", "t3", "p1", "greywater"),
		_g_wire("w6", "p1", "t1", "greywater"),      # closes the loop: a return
		_g_wire("w7", "m1", "g1", "water"),
		{"id": "e1", "source_item_id": "b1", "target_item_id": "m1", "polarity": "ac"},
	]
	var doc := MimicGraphSource.build(items, conns)
	var el := {}
	for e in doc["elements"]:
		el[str(e["id"])] = e
	var pp := {}
	for p in doc["pipes"]:
		pp[str(p["id"])] = p
	_ok(el.has("t1") and el.has("m1") and el.has("p1") and el.has("g1"), "graph picture: piped nodes are in it")
	_ok(not el.has("b1") and not pp.has("e1"), "graph picture: a battery and its power wire are not")
	_ok(not el.has("lone"), "graph picture: an unpiped store is left out")
	_ok(el.has("v2"), "graph picture: an unpiped valve is shown so it can be found")
	_ok(str(el["t1"]["kind"]) == "tank" and str(el["v1"]["kind"]) == "valve" and str(el["p1"]["kind"]) == "pump"
		and str(el["m1"]["kind"]) == "machine" and str(el["g1"]["kind"]) == "group" and str(el["v2"]["kind"]) == "check",
		"graph picture: kinds")
	_ok(pp.size() == 7, "graph picture: seven lines (got %d)" % pp.size())
	var x := func(id: String) -> float: return (el[id]["pos"] as Vector2).x
	_ok(x.call("t1") < x.call("v1") and x.call("v1") < x.call("t2") and x.call("t2") < x.call("m1")
		and x.call("m1") < x.call("t3") and x.call("t3") < x.call("p1"), "graph picture: flow runs left to right")
	_ok(bool(pp["w6"]["returns"]) and not bool(pp["w1"]["returns"]), "graph picture: the loop-closing line is the return")
	var low := 0.0
	for id in el:
		low = maxf(low, (el[id]["pos"] as Vector2).y + (el[id]["size"] as Vector2).y * 0.5)
	var ret_low := 0.0
	for q in (pp["w6"]["pts"] as PackedVector2Array):
		ret_low = maxf(ret_low, q.y)
	_ok(ret_low > low + 20.0, "graph picture: the return runs under everything")
	# Lines start and end on their elements' sides.
	var w1: PackedVector2Array = pp["w1"]["pts"]
	var t1r := (el["t1"]["pos"] as Vector2).x + (el["t1"]["size"] as Vector2).x * 0.5
	var v1l := (el["v1"]["pos"] as Vector2).x - (el["v1"]["size"] as Vector2).x * 0.5
	_ok(absf(w1[0].x - t1r) < 1.0 and absf(w1[w1.size() - 1].x - v1l) < 1.0, "graph picture: a line joins the two sides")
	# No two elements overlap.
	var clash := 0
	var ids := el.keys()
	for i in ids.size():
		for j in range(i + 1, ids.size()):
			var ra := Rect2((el[ids[i]]["pos"] as Vector2) - (el[ids[i]]["size"] as Vector2) * 0.5, el[ids[i]]["size"])
			var rb := Rect2((el[ids[j]]["pos"] as Vector2) - (el[ids[j]]["size"] as Vector2) * 0.5, el[ids[j]]["size"])
			if ra.intersects(rb):
				clash += 1
	_ok(clash == 0, "graph picture: nothing overlaps (%d)" % clash)
	_ok((el["t1"]["size"] as Vector2).y > (el["t2"]["size"] as Vector2).y, "graph picture: a bigger store is drawn bigger")
	var doc2 := MimicGraphSource.build(items, conns)
	_ok(str(doc2["elements"]) == str(doc["elements"]), "graph picture: two builds agree")
	_ok((doc["bounds"] as Rect2).size.x > 600.0, "graph picture: bounds cover it")
	# State.
	var st := MimicGraphSource.state(items, conns)
	_ok(is_equal_approx(float(st["el"]["t1"]["level"]), 0.5) and str(st["el"]["t1"]["value"]).begins_with("50 %"), "graph state: a store's level")
	_ok(not bool(st["el"]["t2"]["out_open"]) and bool(st["el"]["t2"]["in_open"]), "graph state: a shut outlet")
	_ok(bool(st["el"]["v1"]["open"]) and str(st["el"]["v1"]["value"]) == "Open", "graph state: an open valve")
	_ok(bool(st["el"]["m1"]["running"]) and str(st["el"]["m1"]["value"]) == "Running", "graph state: a running machine")
	_ok(int(st["pipe"]["w1"]["flow"]) == 1 and int(st["pipe"]["w3"]["flow"]) == 0, "graph state: which lines carry")
	var shut := valve.duplicate(true)
	shut["requested_state"] = "off"
	items[1] = _g_item("v1", "processor", 100.0, shut)
	var st2 := MimicGraphSource.state(items, conns)
	_ok(not bool(st2["el"]["v1"]["open"]) and str(st2["el"]["v1"]["value"]) == "Closed", "graph state: a closed valve")
	_ok(MimicGraphSource.build([], []).get("elements", [1]).is_empty(), "graph picture: an empty scope is an empty picture")


# ── power and network layers (Phase 3b) ─────────────────────────────────────

func _e_wire(id: String, a: String, b: String, pol: String, extra: Dictionary = {}) -> Dictionary:
	var c := {"id": id, "source_item_id": a, "target_item_id": b, "polarity": pol,
		"source_handle_id": "data", "target_handle_id": "data"}
	c.merge(extra, true)
	return c


func _net_item(id: String, role: String, x: float, on: bool = true) -> Dictionary:
	var s := ScadaNet.make_specs(role, id, 5.0)
	s["current_state"] = "on" if on else "off"
	return {"id": id, "type": "appliance", "x": x, "y": 300.0, "specs": s}


## Top to bottom: the same picture turned over its diagonal. Flow runs down,
## things keep their own shapes, lines leave a thing's bottom and arrive at
## the next one's top, and the return runs down the right side.
func _test_graph_down() -> void:
	var items := [
		_g_item("t1", "resource", 0.0, {"name": "Cistern", "resource_kind": "water", "capacity_qty": 1000.0}),
		_g_item("m1", "processor", 100.0, {"name": "Washer"}),
		_g_item("t3", "resource", 200.0, {"name": "Grey", "resource_kind": "greywater", "capacity_qty": 200.0}),
	]
	var conns := [_g_wire("w1", "t1", "m1", "water"), _g_wire("w2", "m1", "t3", "greywater"),
		_g_wire("w3", "t3", "t1", "greywater")]
	var right := MimicGraphSource.build(items, conns)
	var down := MimicGraphSource.build(items, conns, {}, [], {"flow": "down"})
	var el := {}
	var er := {}
	for x in down["elements"]:
		el[str(x["id"])] = x
	for x in right["elements"]:
		er[str(x["id"])] = x
	var y := func(id: String) -> float: return (el[id]["pos"] as Vector2).y
	_ok(y.call("t1") < y.call("m1") and y.call("m1") < y.call("t3") and str(down.get("flow", "")) == "down",
		"top to bottom: flow runs down")
	_ok((el["m1"]["size"] as Vector2).is_equal_approx(er["m1"]["size"] as Vector2), "top to bottom: things keep their shapes")
	var w1: PackedVector2Array = []
	var w3: PackedVector2Array = []
	for p in down["pipes"]:
		if str(p["id"]) == "w1":
			w1 = p["corners"]
		if str(p["id"]) == "w3":
			w3 = p["corners"]
	var t1b := (el["t1"]["pos"] as Vector2).y + (el["t1"]["size"] as Vector2).y * 0.5
	var m1t := (el["m1"]["pos"] as Vector2).y - (el["m1"]["size"] as Vector2).y * 0.5
	_ok(w1.size() >= 2 and absf(w1[0].y - t1b) < 0.5 and absf(w1[w1.size() - 1].y - m1t) < 0.5,
		"top to bottom: a line leaves the bottom and arrives at the top")
	var right_edge := -INF
	for id in el:
		right_edge = maxf(right_edge, (el[id]["pos"] as Vector2).x + (el[id]["size"] as Vector2).x * 0.5)
	var ret_x := -INF
	for q in w3:
		ret_x = maxf(ret_x, q.x)
	_ok(ret_x > right_edge + 20.0, "top to bottom: the return runs down the right side")


func _test_graph_layers() -> void:
	var items := [
		_g_item("pv", "panel", 0.0, {"name": "Panel"}),
		_g_item("cc", "controller", 100.0, {"name": "Inverter"}),
		_g_item("bat", "battery", 200.0, {"name": "Bank", "soc": 0.5}),
		_g_item("pump", "processor", 300.0, FlowCtl.make_specs("Pump", FlowCtl.KIND_PUMP, "water", 60.0)),
		_g_item("t1", "resource", 0.0, {"name": "A", "resource_kind": "water", "capacity_qty": 100.0, "level": 0.5}),
		_g_item("t2", "resource", 400.0, {"name": "B", "resource_kind": "water", "capacity_qty": 100.0, "level": 0.5}),
		_net_item("srv", ScadaNet.ROLE_SERVER, 0.0),
		_net_item("sw", ScadaNet.ROLE_SWITCH, 100.0),
		_net_item("ap", ScadaNet.ROLE_AP, 200.0),
		_net_item("b1", ScadaNet.ROLE_BOARD, 300.0),
		_net_item("b2", ScadaNet.ROLE_BOARD, 400.0),
		_net_item("b3", ScadaNet.ROLE_BOARD, 500.0),
	]
	var conns := [
		_e_wire("d1", "pv", "cc", "positive"),
		_e_wire("d2", "pv", "cc", "negative"),
		_e_wire("d3", "cc", "bat", "positive"),
		_e_wire("a1", "cc", "pump", "ac", {"carried_amps": 12.0, "drop_pct": 2.4, "route_length_m": 18.0, "visible_3d": true, "flow_active": true}),
		_e_wire("a2", "cc", "sw", "ac", {"overload_ratio": 1.4}),
		_g_wire("p1", "t1", "pump", "water", 60.0),
		_g_wire("p2", "pump", "t2", "water", 60.0),
		_e_wire("n1", "srv", "sw", "data"),
		_e_wire("n2", "sw", "b1", "data", {"route_length_m": 30.0, "visible_3d": true}),
		_e_wire("n3", "sw", "ap", "data"),
		_e_wire("n4", "ap", "b2", "data", {"source_handle_id": "wifi"}),
	]
	var L := MimicGraphSource
	var pipes := L.build(items, conns)
	var kinds := {}
	for e in pipes["elements"]:
		kinds[str(e["id"])] = str(e["kind"])
	_ok(kinds.size() == 3 and not kinds.has("pv") and not kinds.has("srv"), "layers: pipes alone show only the piped things (%d)" % kinds.size())
	_ok((pipes["pipes"] as Array).size() == 2, "layers: and only the pipes")
	var power := L.build(items, conns, {L.LAYER_POWER: true})
	var pk := {}
	var glyph := {}
	for e in power["elements"]:
		pk[str(e["id"])] = str(e["kind"])
		glyph[str(e["id"])] = str(e.get("glyph", ""))
	var pl := {}
	for p in power["pipes"]:
		pl[str(p["id"])] = p
	_ok(pk.has("pv") and pk.has("cc") and pk.has("bat") and pk.has("pump") and pk.has("sw") and not pk.has("t1"), "power layer: what is on a power wire, not the stores")
	_ok(str(pk["pv"]) == "device" and str(glyph["pv"]) == "panel" and str(glyph["cc"]) == "inverter" and str(glyph["bat"]) == "battery"
		and str(glyph["sw"]) == "switch", "power layer: single-line symbols")
	_ok(str(pk["pump"]) == "pump", "power layer: a pump is still drawn as a pump")
	_ok(pl.size() == 4 and pl.has("d1") and not pl.has("d2"), "power layer: a + / − pair is one line (%d lines)" % pl.size())
	_ok(str(pl["d1"]["style"]) == "power" and str(pl["d1"]["label"]) == "DC" and str(pl["a1"]["label"]) == "AC", "power layer: DC and AC lines")
	_ok(float(pl["a1"]["w"]) < L.PIPE_W, "power layer: a wire is drawn thinner than a pipe")
	var data := L.build(items, conns, {L.LAYER_DATA: true})
	var dl := {}
	for p in data["pipes"]:
		dl[str(p["id"])] = p
	var de := {}
	for e in data["elements"]:
		de[str(e["id"])] = e
	_ok(dl.size() == 4 and bool(dl["n4"]["dashed"]) and not bool(dl["n2"]["dashed"]), "network layer: Wi-Fi is dashed, cable is not")
	_ok(de.has("b1") and de.has("b2") and de.has("b3") and bool(de["b3"]["loose"]) and not bool(de["b1"]["loose"]),
		"network layer: an unwired board waits under the picture, ready to be cabled")
	_ok(str(de["srv"]["glyph"]) == "server" and str(de["ap"]["glyph"]) == "ap" and str(de["b1"]["glyph"]) == "board", "network layer: its symbols")
	_ok((de["srv"]["pos"] as Vector2).x < (de["sw"]["pos"] as Vector2).x and (de["sw"]["pos"] as Vector2).x < (de["b1"]["pos"] as Vector2).x, "network layer: server, then switch, then boards")
	var all := L.build(items, conns, {L.LAYER_PIPES: true, L.LAYER_POWER: true, L.LAYER_DATA: true})
	_ok((all["pipes"] as Array).size() == 10 and (all["elements"] as Array).size() == 12, "all layers: every line and thing once (%d, %d)" % [(all["pipes"] as Array).size(), (all["elements"] as Array).size()])
	var clash := 0
	var els: Array = all["elements"]
	for i in els.size():
		for j in range(i + 1, els.size()):
			var ra := Rect2((els[i]["pos"] as Vector2) - (els[i]["size"] as Vector2) * 0.5, els[i]["size"])
			var rb := Rect2((els[j]["pos"] as Vector2) - (els[j]["size"] as Vector2) * 0.5, els[j]["size"])
			if ra.intersects(rb):
				clash += 1
	_ok(clash == 0, "all layers: nothing overlaps (%d)" % clash)
	# State.
	var st := L.state(items, conns, ScadaNet.reach(items, conns))
	_ok(str(st["pipe"]["a1"]["text"]).contains("18 m") and str(st["pipe"]["a1"]["text"]).contains("12 A")
		and str(st["pipe"]["a1"]["text"]).contains("2.4 % drop"), "wire text: length, amps and drop (%s)" % str(st["pipe"]["a1"]["text"]))
	_ok(bool(st["pipe"]["a2"]["warn"]) and str(st["pipe"]["a2"]["text"]).contains("overloaded 140 %"), "wire text: an overloaded run warns")
	_ok(int(st["pipe"]["a1"]["flow"]) == 1 and int(st["pipe"]["d1"]["flow"]) == 0, "wire state: which runs carry")
	_ok(str(st["pipe"]["n2"]["text"]) == "Ethernet · 30 m" and str(st["pipe"]["n4"]["text"]) == "Wi-Fi", "data text: the link and its length")
	_ok(str(st["el"]["b1"]["value"]) == "Heard" and not bool(st["el"]["b1"].get("warn", false)), "network state: a reachable board is heard")
	_ok(bool(st["el"]["b3"]["warn"]) and str(st["el"]["b3"]["value"]) == "Not on the network", "network state: an unwired board says so")
	_ok(str(st["pipe"]["p1"]["text"]).begins_with("Potable Water") or str(st["pipe"]["p1"]["text"]).begins_with("Water"), "pipe text: starts with what it carries (%s)" % str(st["pipe"]["p1"]["text"]))


# ── re-routing after a drag (right angles kept) ─────────────────────────────

## Every segment runs along a picture axis.
func _axis_only(pts: PackedVector2Array) -> bool:
	for i in range(1, pts.size()):
		var d := pts[i] - pts[i - 1]
		if absf(d.x) > 0.01 and absf(d.y) > 0.01:
			return false
	return true


## Every segment runs along an axis or along one of `dirs` (a drawn depth run).
func _dirs_only(pts: PackedVector2Array, dirs: Array) -> bool:
	for i in range(1, pts.size()):
		var d := (pts[i] - pts[i - 1]).normalized()
		var ok := absf(d.x) < 0.001 or absf(d.y) < 0.001
		for q in dirs:
			if absf(d.cross(q as Vector2)) < 0.001:
				ok = true
		if not ok:
			return false
	return true


func _no_backtrack(pts: PackedVector2Array) -> bool:
	for i in range(1, pts.size() - 1):
		var d0 := (pts[i] - pts[i - 1]).normalized()
		var d1 := (pts[i + 1] - pts[i]).normalized()
		if d0.dot(d1) < -0.99:
			return false
	return true


func _test_reroute() -> void:
	var z := PackedVector2Array([Vector2(0, 0), Vector2(100, 0), Vector2(100, 200), Vector2(300, 200)])
	var r1 := MimicLayout.reroute(z, Vector2.ZERO, Vector2(0, 80), 30.0)
	_ok(r1.size() == 4 and _axis_only(r1) and r1[3].distance_to(Vector2(300, 280)) < 1e-3 and absf(r1[1].x - 100.0) < 1e-3,
		"reroute: the far end moved down: the riser stays, the last run slides (%s)" % str(r1))
	var r1b := MimicLayout.reroute(z, Vector2(0, -60), Vector2.ZERO, 30.0)
	_ok(r1b.size() == 4 and _axis_only(r1b) and r1b[0].distance_to(Vector2(0, -60)) < 1e-3, "reroute: the near end moved up")
	var r2 := MimicLayout.reroute(z, Vector2.ZERO, Vector2(-250, 0), 30.0)
	_ok(_axis_only(r2) and _no_backtrack(r2) and r2[0] == Vector2.ZERO and r2[r2.size() - 1].distance_to(Vector2(50, 200)) < 1e-3,
		"reroute: the target moved behind the source: routed round with right angles (%s)" % str(r2))
	_ok(r2[1].x > r2[0].x and r2[r2.size() - 1].x > r2[r2.size() - 2].x, "reroute: it still leaves to the right and arrives from the left")
	var r2b := MimicLayout.reroute(z, Vector2.ZERO, Vector2(-40, 0), 30.0)
	_ok(_axis_only(r2b) and r2b.size() == 4 and (r2b[3] - r2b[2]).x >= 29.9, "reroute: a target pulled near the riser keeps its stub")
	var straight := PackedVector2Array([Vector2(0, 0), Vector2(400, 0)])
	var r3 := MimicLayout.reroute(straight, Vector2.ZERO, Vector2(0, 120), 30.0)
	_ok(r3.size() == 4 and _axis_only(r3) and r3[3].distance_to(Vector2(400, 120)) < 1e-3, "reroute: a straight run moved sideways gets a jog")
	var r3b := MimicLayout.reroute(straight, Vector2(0, 50), Vector2(0, 50), 30.0)
	_ok(r3b.size() == 2 and r3b[0].distance_to(Vector2(0, 50)) < 1e-3 and r3b[1].distance_to(Vector2(400, 50)) < 1e-3,
		"reroute: both ends moved together: the run moves whole")
	var r3c := MimicLayout.reroute(straight, Vector2(-80, 0), Vector2.ZERO, 30.0)
	_ok(r3c.size() == 2 and r3c[0].distance_to(Vector2(-80, 0)) < 1e-3, "reroute: moved along its own line it just gets longer")
	var ell := PackedVector2Array([Vector2(0, 0), Vector2(200, 0), Vector2(200, 150)])
	var r4 := MimicLayout.reroute(ell, Vector2(0, 40), Vector2.ZERO, 30.0)
	_ok(r4.size() == 3 and r4[1].distance_to(Vector2(200, 40)) < 1e-3, "reroute: an L keeps one corner, where the runs now meet")
	# A run with a drawn depth leg (the oblique 45°): every leg keeps its direction.
	var dk := Vector2(1, -1).normalized()
	var obl := PackedVector2Array([Vector2(0, 0), Vector2(100, 0), Vector2(100, 0) + dk * 150.0, Vector2(100, 0) + dk * 150.0 + Vector2(0, -200)])
	var r5 := MimicLayout.reroute(obl, Vector2(0, 30), Vector2.ZERO, 30.0)
	_ok(_dirs_only(r5, [dk]) and r5[0].distance_to(Vector2(0, 30)) < 1e-3 and r5[r5.size() - 1] == obl[3],
		"reroute: a depth leg keeps its slant, the moved end its own run")
	var ret := PackedVector2Array([Vector2(0, 0), Vector2(40, 0), Vector2(40, 300), Vector2(-400, 300), Vector2(-400, 20), Vector2(-360, 20)])
	var r6 := MimicLayout.reroute(ret, Vector2(0, 60), Vector2(0, -30), 30.0)
	_ok(_axis_only(r6) and _no_backtrack(r6) and r6[0].distance_to(Vector2(0, 60)) < 1e-3 and r6[r6.size() - 1].distance_to(Vector2(-360, -10)) < 1e-3,
		"reroute: a return line keeps its run under everything")
	# A sweep of drags: always right angles, ends where the things are, no doubling back.
	var bad := 0
	for i in 40:
		var da := Vector2(float((i * 37) % 300) - 150.0, float((i * 53) % 260) - 130.0)
		var db := Vector2(float((i * 71) % 500) - 250.0, float((i * 29) % 300) - 150.0)
		for route in [z, straight, ell, ret]:
			var r := MimicLayout.reroute(route, da, db, 30.0)
			if not _axis_only(r) or not _no_backtrack(r) or r[0].distance_to((route as PackedVector2Array)[0] + da) > 1e-3 \
					or r[r.size() - 1].distance_to((route as PackedVector2Array)[(route as PackedVector2Array).size() - 1] + db) > 1e-3:
				bad += 1
	_ok(bad == 0, "reroute: 160 drags, every route square and joined (%d bad)" % bad)
	# The fresh router on its own.
	var c1 := MimicLayout.connector(Vector2(0, 0), Vector2.RIGHT, Vector2(-200, 0), Vector2.RIGHT, 30.0)
	_ok(_axis_only(c1) and _no_backtrack(c1) and c1.size() >= 5, "connector: behind on one level goes round")
	var c2 := MimicLayout.connector(Vector2(0, 0), Vector2.RIGHT, Vector2(200, 300), Vector2.DOWN, 30.0)
	_ok(c2.size() == 3 and c2[1] == Vector2(200, 0), "connector: across each other is one corner")
	var c3 := MimicLayout.connector(Vector2(0, 0), Vector2.RIGHT, Vector2(-100, -300), Vector2.DOWN, 30.0)
	_ok(_axis_only(c3) and _no_backtrack(c3) and (c3[1] - c3[0]).x > 0.0 and (c3[c3.size() - 1] - c3[c3.size() - 2]).y > 0.0,
		"connector: a corner that does not fit goes out through the stubs")
	# A sampled elbow becomes one corner.
	var arc := PackedVector2Array()
	for i in 11:
		arc.append(Vector2(float(i) * 30.0, 0.0))
	for k in range(1, 9):
		var a := PI * 0.5 * float(k) / 8.0
		arc.append(Vector2(300.0 + sin(a) * 60.0, 60.0 - cos(a) * 60.0))
	for i in range(1, 8):
		arc.append(Vector2(360.0, 60.0 + float(i) * 40.0))
	var sc := MimicLayout.simplify_corners(arc, 8.0)
	_ok(sc.size() == 3 and sc[1].distance_to(Vector2(360, 0)) < 2.0 and _axis_only(sc),
		"simplify_corners: a sampled elbow is one corner (%s)" % str(sc))


func _test_reroute_pictures() -> void:
	# Every line of a built picture can be re-routed: its corners run end to end.
	var d := _design("biochar_reactor")
	var doc := MimicTcSource.build(d, TcProcNet.build(d))
	var missing := 0
	var off_end := 0
	for p in doc["pipes"]:
		var c: PackedVector2Array = p.get("corners", PackedVector2Array())
		var pts: PackedVector2Array = p["pts"]
		if c.size() < 2:
			missing += 1
			continue
		if c[0].distance_to(pts[0]) > 0.01 or c[c.size() - 1].distance_to(pts[pts.size() - 1]) > 0.01:
			off_end += 1
	_ok(missing == 0 and off_end == 0, "pictures: every reactor pipe has corners from end to end (%d missing, %d off)" % [missing, off_end])
	# Most of a tri-clamp run is straight legs: corners are few.
	var dense := 0
	var few := 0
	for p in doc["pipes"]:
		dense += (p["pts"] as PackedVector2Array).size()
		few += (p["corners"] as PackedVector2Array).size()
	_ok(few * 2 < dense, "pictures: a reactor pipe's corners are far fewer than its drawn points (%d of %d)" % [few, dense])
	var g := MimicGraphSource.build([
		_g_item("t1", "resource", 0.0, {"name": "A", "resource_kind": "water", "capacity_qty": 100.0, "capacity_unit": "L"}),
		_g_item("m1", "processor", 100.0, {"name": "M"}),
		_g_item("t2", "resource", 200.0, {"name": "B", "resource_kind": "water", "capacity_qty": 100.0, "capacity_unit": "L"}),
	], [_g_wire("w1", "t1", "m1", "water"), _g_wire("w2", "m1", "t2", "water"), _g_wire("w3", "t2", "t1", "water")])
	var square := 0
	var joined := 0
	for p in g["pipes"]:
		var c2: PackedVector2Array = p["corners"]
		if _axis_only(c2):
			square += 1
		var r := MimicLayout.reroute(c2, Vector2.ZERO, Vector2(-170, 95), float(p["stub"]))
		if _axis_only(r) and r[r.size() - 1].distance_to(c2[c2.size() - 1] + Vector2(-170, 95)) < 1e-3:
			joined += 1
	_ok(square == 3 and joined == 3, "pictures: graph lines are square and stay square after a drag (%d, %d)" % [square, joined])
	_ok(str(g["pipes"][0].get("from", "")) != "" and g["pipes"][0].has("to"), "pictures: graph lines name the things they join")


# ── equipment pictures (MimicIcons) ─────────────────────────────────────────

func _test_icons() -> void:
	# A shaded disc on a clear background, as a model render comes back.
	var src := Image.create(128, 128, false, Image.FORMAT_RGBA8)
	src.fill(Color(0, 0, 0, 0))
	for y in 128:
		for x in 128:
			var d := Vector2(x - 70, y - 60).length()
			if d < 30.0:
				var shade := clampf(0.25 + 0.6 * float(x - 40) / 60.0, 0.0, 1.0)
				src.set_pixel(x, y, Color(shade * 0.9, shade * 0.5, shade * 0.2, 1.0))
	var ic := MimicIcons.stylize(src)
	_ok(not ic.is_empty() and absf(ic.get_width() - (60 + 2 * MimicIcons.PAD)) <= 2.0 and absf(ic.get_height() - (60 + 2 * MimicIcons.PAD)) <= 2.0,
		"icons: cropped to the silhouette (%dx%d)" % [ic.get_width(), ic.get_height()])
	var grey := true
	var tones := {}
	for y in ic.get_height():
		for x in ic.get_width():
			var c := ic.get_pixel(x, y)
			if c.a < 0.95:
				continue
			if maxf(absf(c.r - c.g), absf(c.g - c.b)) > 0.12:
				grey = false
			tones["%.2f" % c.v] = true
	_ok(grey, "icons: the colour is gone (grey tones only)")
	_ok(tones.size() >= 3, "icons: the shading reads as several bands (%d)" % tones.size())
	_ok(ic.get_pixel(0, 0).a < 0.01 and ic.get_pixel(ic.get_width() - 1, ic.get_height() - 1).a < 0.01, "icons: clear round the thing")
	var mid_row := int(ic.get_height() / 2)
	var first := -1
	for x in ic.get_width():
		if ic.get_pixel(x, mid_row).a > 0.95:
			first = x
			break
	_ok(first >= 0 and ic.get_pixel(first, mid_row).v > 0.75, "icons: a light outline round the silhouette")
	_ok(MimicIcons.stylize(Image.create(16, 16, false, Image.FORMAT_RGBA8)).is_empty(), "icons: an empty render gives no picture")
	_ok(absf(MimicIcons.aspect(ic) - 1.0) < 0.05, "icons: aspect of a round thing is 1")
	# Views.
	_ok(int(MimicIcons.camera(MimicIcons.VIEW_SIDE)["yaw"]) == 90 and int(MimicIcons.camera(MimicIcons.VIEW_SIDE)["pitch"]) == 0,
		"icons: the side view looks straight across")
	_ok(float(MimicIcons.camera(MimicIcons.VIEW_TOP)["pitch"]) > 80.0 and MimicIcons.next_view(MimicIcons.VIEW_TOP) == MimicIcons.VIEW_SIDE,
		"icons: the top view looks down; the views go round")
	# Pictograms for nodes with no model.
	var g := func(name: String, type: String = "processor") -> String:
		return MimicIcons.glyph_for({"type": type, "specs": {"name": name}})
	_ok(g.call("Greywater Filter 1") == "droplet" and g.call("Battery Bank A", "battery") == "battery"
		and g.call("Inverter A (EG4 6000XP)", "controller") == "cpu" and g.call("Woodgas DC Generator") == "zap",
		"icons: a filter, a battery, an inverter and a generator each get their pictogram")
	_ok(g.call("Kitchen") == "flame" and g.call("PP Injection Molder") == "hammer" and g.call("Breaker panel", "breaker_panel") == "plug"
		and g.call("Embedded thing") == "wrench", "icons: a kitchen, a molder, a breaker panel; unknown machines a wrench")
	# A pictured node takes its picture's shape, and its lines still meet it.
	var items := [
		_g_item("t1", "resource", 0.0, {"name": "A", "resource_kind": "water", "capacity_qty": 100.0, "capacity_unit": "L"}),
		_g_item("m1", "processor", 100.0, {"name": "Tall thing"}),
		_g_item("m2", "processor", 200.0, {"name": "Long thing"}),
	]
	var conns := [_g_wire("w1", "t1", "m1", "water"), _g_wire("w2", "m1", "m2", "water")]
	var doc := MimicGraphSource.build(items, conns, {}, [], {"aspect": {"m1": 0.2, "m2": 4.0}})
	var el := {}
	for e in doc["elements"]:
		el[str(e["id"])] = e
	var s1: Vector2 = el["m1"]["size"]
	var s2: Vector2 = el["m2"]["size"]
	_ok(bool(el["m1"].get("icon", false)) and not bool(el["t1"].get("icon", false)), "icons: only pictured machines are marked")
	_ok(is_equal_approx(s1.y, MimicGraphSource.ICON_H) and is_equal_approx(s1.x, MimicGraphSource.ICON_W_MIN),
		"icons: a tall picture keeps the machine height, no narrower than the floor (%s)" % str(s1))
	_ok(is_equal_approx(s2.x, MimicGraphSource.ICON_W_MAX) and s2.y < MimicGraphSource.ICON_H and s2.y >= MimicGraphSource.ICON_H_MIN,
		"icons: a long picture is capped in width and drawn shorter (%s)" % str(s2))
	var w2: PackedVector2Array = (doc["pipes"] as Array)[1]["pts"]
	var m2l := (el["m2"]["pos"] as Vector2).x - s2.x * 0.5
	_ok(absf(w2[w2.size() - 1].x - m2l) < 1.0, "icons: the line runs into the picture's side")
