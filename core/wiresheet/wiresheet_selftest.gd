extends SceneTree

## Wiring-sheet self-test (offline). The bootcamp's trainer panel, MPPT and
## 12 V battery lay out as four DC conductors: red and black, a gauge on the
## battery run from the bank's cable rule, and a callout that the positive
## has no fuse. A fuse on that positive clears it; one on the negative does
## not. A page position moves the device without touching the graph cards.
##
##   Godot --headless --path . --script core/wiresheet/wiresheet_selftest.gd

const GraphModelScript := preload("res://system_graph/data/graph_model.gd")

const EXPECTED_CHECKS := 64

var _n := 0
var _fails := 0


func _ok(cond: bool, what: String) -> void:
	_n += 1
	if cond:
		print("  ok   ", what)
	else:
		_fails += 1
		print("  FAIL ", what)


func _initialize() -> void:
	print("wiresheet selftest")
	_test_size_run()
	_test_bootcamp()
	_test_fuse()
	_test_place()
	_test_svg()
	_test_insert()
	_test_route()
	_test_data()
	_ok(_n == EXPECTED_CHECKS, "ran %d checks (expected %d)" % [_n, EXPECTED_CHECKS])
	print("wiresheet selftest: %s (%d checks, %d failed)" % ["PASS" if _fails == 0 else "FAIL", _n, _fails])
	quit(0 if _fails == 0 else 1)


func _test_size_run() -> void:
	# 30 A at 12 V over 2 m: 8 AWG carries the 37.5 A (125 %), and the drop
	# is just over 1 %, so the run steps up to 6 AWG. A short run stays 8 AWG.
	var long := WireSheet.size_run(30.0, 12.0, 2.0)
	var short := WireSheet.size_run(30.0, 12.0, 0.3)
	_ok(str(long["gauge"]) == "6 AWG" and bool(long["upsized"]) and float(long["drop_pct"]) < 1.0,
		"2 m of 30 A at 12 V is 6 AWG under 1 %% (got %s, %.2f %%)" % [long["gauge"], float(long["drop_pct"])])
	_ok(str(short["gauge"]) == "8 AWG" and not bool(short["upsized"]) and float(short["drop_pct"]) < 1.0,
		"0.3 m of the same current stays 8 AWG (got %s)" % short["gauge"])
	var pv := WireSheet.size_run(9.9, 32.0, 8.0)
	_ok(str(pv["gauge"]) == "10 AWG" and float(pv["drop_pct"]) < 1.0,
		"8 m of a 9.9 A string at 32 V is 10 AWG (got %s, %.2f %%)" % [pv["gauge"], float(pv["drop_pct"])])


func _test_bootcamp() -> void:
	var m := _chain("")
	var lay := WireSheet.layout(m, "ctl")
	var devs: Array = lay["devices"]
	var conds: Array = lay["conductors"]
	_ok(devs.size() == 3, "three devices (got %d)" % devs.size())
	_ok(_kind(devs, "panels") == "Trainer 300W (40 Voc)" and _kind(devs, "controller") == "Trainer MPPT 150V 30A"
		and _kind(devs, "battery") == "12V 100Ah AGM", "names come from the bootcamp presets")
	var px := _box(devs, "panels").position.x
	var cx := _box(devs, "controller").position.x
	var bx := _box(devs, "battery").position.x
	_ok(px < cx and cx < bx, "array, then controller, then battery")
	_ok(conds.size() == 4, "four DC conductors (got %d)" % conds.size())
	var red := 0
	var black := 0
	var landed := true
	var ortho := true
	for c in conds:
		var cd: Dictionary = c
		var col: Color = cd["color"]
		if col.is_equal_approx(CtrlSheet.wire_color("pv1+")):
			red += 1
		elif col.is_equal_approx(CtrlSheet.wire_color("bat-")):
			black += 1
		if not _ends_on_ports(devs, cd):
			landed = false
		if not _ortho(cd):
			ortho = false
	_ok(red == 2 and black == 2, "two red positives and two black negatives (red %d, black %d)" % [red, black])
	_ok(landed, "each conductor starts and ends on its ports")
	_ok(ortho, "each run is orthogonal")
	var bp := _pole(conds, "bat", "positive")
	var pv := _pole(conds, "pnl", "positive")
	_ok(not bp.is_empty() and str(bp["gauge"]) == "6 AWG" and absf(float(bp["amps"]) - 30.0) < 0.01
		and absf(float(bp["length_m"]) - 2.0) < 0.01 and float(bp["drop_pct"]) < 1.0,
		"the battery positive is 6 AWG, 30 A, 2 m (got %s, %.1f A, %.2f m)" % [bp.get("gauge", ""), float(bp.get("amps", -1)), float(bp.get("length_m", -1))])
	_ok(not pv.is_empty() and str(pv["gauge"]) == "10 AWG" and absf(float(pv["amps"]) - 9.9) < 0.01
		and absf(float(pv["length_m"]) - 8.0) < 0.01,
		"the panel positive is 10 AWG, 9.9 A, 8 m (got %s, %.1f A)" % [pv.get("gauge", ""), float(pv.get("amps", -1))])
	var ctl := _dev(devs, "controller")
	var sym: Dictionary = ctl.get("symbol", {})
	var face: Dictionary = sym.get("face", {})
	_ok(str(sym.get("kind", "")) == "face" and str(face.get("face", "")) == "front",
		"the controller is its front face")
	var cp := _port(devs, "controller", "pvPositive")
	var lead := _lead_end(face, "pv1+")
	_ok(not cp.is_empty() and lead != Vector2.INF and (cp["pos"] as Vector2).is_equal_approx(lead),
		"the PV + run leaves the face's PV lead")
	_ok(str((_dev(devs, "panels").get("symbol", {}) as Dictionary).get("caption", "")).begins_with("1S"),
		"the array is one module (%s)" % str((_dev(devs, "panels").get("symbol", {}) as Dictionary).get("caption", "")))
	_ok(str((_dev(devs, "battery").get("symbol", {}) as Dictionary).get("caption", "")) == "12 V · 100 Ah",
		"the battery reads its voltage and amp-hours")
	var cbox: Rect2 = ctl["box"]
	var fbb: Rect2 = face["bounds"]
	_ok(cbox.position.is_equal_approx(fbb.position) and cbox.size.is_equal_approx(fbb.size),
		"the controller box is the face")
	_ok(_codes(lay) == ["no_fuse"] and (lay["checks"] as Array).size() == 1,
		"the only callout is the missing fuse (got %s)" % str(_codes(lay)))
	var text := ""
	for ck in (lay["checks"] as Array):
		if str(ck["code"]) == "no_fuse":
			text = str(ck["text"])
	_ok(text == "Battery: no fuse on the positive.", "the callout names the battery positive")
	var from_p := _ids(WireSheet.layout(m, "pnl"))
	var from_b := _ids(WireSheet.layout(m, "bat"))
	_ok(from_p == _ids(lay) and from_b == _ids(lay), "the same sheet from the panel, the controller or the battery")
	var pb: Rect2 = _box(devs, "panels")
	var bb: Rect2 = _box(devs, "battery")
	_ok(pb.size.is_equal_approx(Vector2(150, 210)) and bb.size.is_equal_approx(Vector2(170, 130)),
		"the module and the battery keep their elevation size")
	# A routed length replaces the 2 m default and the gauge follows.
	for c in m.connections:
		var cd: Dictionary = c
		if str(cd.get("source_handle_id", "")) == "batteryPositive":
			cd["estimated_length"] = 0.3
	var short := _pole(WireSheet.layout(m, "ctl")["conductors"], "bat", "positive")
	_ok(str(short.get("gauge", "")) == "8 AWG" and absf(float(short.get("length_m", -1)) - 0.3) < 0.01,
		"a 0.3 m battery run stays 8 AWG (got %s)" % short.get("gauge", ""))
	_ok((m.get_item("bat") as Dictionary)["x"] == 0.0, "laying out the page does not move the graph card")


func _test_fuse() -> void:
	var pos := WireSheet.layout(_chain("positive"), "ctl")
	var kinds := {}
	for d in (pos["devices"] as Array):
		kinds[str(d["kind"])] = true
	_ok((pos["devices"] as Array).size() == 4 and kinds.has("fuse") and (pos["conductors"] as Array).size() == 5,
		"a fuse on the positive is a device, and the lead is two conductors (%d devices, %d wires)" % [(pos["devices"] as Array).size(), (pos["conductors"] as Array).size()])
	_ok(str((_dev(pos["devices"], "fuse").get("symbol", {}) as Dictionary).get("caption", "")) == "40 A",
		"the fuse is marked 40 A")
	_ok((pos["checks"] as Array).is_empty(), "that fuse clears the callout (got %s)" % str(_codes(pos)))
	var neg := WireSheet.layout(_chain("negative"), "ctl")
	_ok(_codes(neg).has("no_fuse") and (neg["devices"] as Array).size() == 4,
		"a fuse on the negative only leaves the positive callout")
	var lone := WireSheet.layout(_one("Trainer 300W", "pnl"), "pnl")
	_ok((lone["devices"] as Array).size() == 1 and (lone["conductors"] as Array).is_empty() and _codes(lone).is_empty(),
		"a panel on its own is one device and no callout")
	var none := WireSheet.layout(GraphModelScript.new(), "ctl")
	_ok((none["devices"] as Array).is_empty(), "an empty graph is an empty sheet")


func _test_place() -> void:
	var m := _chain("")
	var lay := WireSheet.layout(m, "bat", {"places": {"bat": Vector2(400, 80)}})
	var box: Rect2 = _box(lay["devices"], "battery")
	var port := _port(lay["devices"], "battery", "positive")
	var cond := _pole(lay["conductors"], "bat", "positive")
	var pts: PackedVector2Array = cond["pts"]
	var at: Vector2 = port["pos"]
	_ok(box.position.is_equal_approx(Vector2(400, 80)), "a page position puts the battery there")
	_ok(pts.size() >= 2 and (pts[0].distance_to(at) < 0.01 or pts[pts.size() - 1].distance_to(at) < 0.01),
		"the battery positive still ends on the moved stud")
	var moved := WireSheet.layout(_chain(""), "ctl", {"places": {"ctl": Vector2(40, 20)}})
	var cbox: Rect2 = _box(moved["devices"], "controller")
	var pv := _pole(moved["conductors"], "pnl", "positive")
	_ok(cbox.position.is_equal_approx(Vector2(40, 20)) and _ends_on_ports(moved["devices"], pv),
		"moving the controller moves its face and the PV run follows")
	_ok(absf(float((m.get_item("bat") as Dictionary)["x"])) < 0.01, "the graph card stays where it was")


# ---------------------------------------------------------------------------

func _chain(fuse_pole: String) -> GraphModel:
	var m: GraphModel = GraphModelScript.new()
	_add(m, "pnl", "Trainer 300W")
	_add(m, "ctl", "Trainer MPPT 150/30")
	_add(m, "bat", "12V 100Ah AGM")
	_wire(m, "pnl", "positive", "ctl", "pvPositive", "positive")
	_wire(m, "pnl", "negative", "ctl", "pvNegative", "negative")
	if fuse_pole == "positive":
		_fuse(m, "ctl", "batteryPositive", "bat", "positive")
	else:
		_wire(m, "ctl", "batteryPositive", "bat", "positive", "positive")
	if fuse_pole == "negative":
		_fuse(m, "ctl", "batteryNegative", "bat", "negative")
	else:
		_wire(m, "ctl", "batteryNegative", "bat", "negative", "negative")
	return m


func _one(label: String, id: String) -> GraphModel:
	var m: GraphModel = GraphModelScript.new()
	_add(m, id, label)
	return m


func _add(m: GraphModel, id: String, label: String) -> void:
	var p := TutorialCatalog.find_preset(label)
	m.add_item({
		"id": id, "type": str(p["type"]), "label": label,
		"x": 0.0, "y": 0.0, "width": float(p["width"]), "height": float(p["height"]),
		"scope_id": "root", "specs": (p["specs"] as Dictionary).duplicate(true),
	})


func _wire(m: GraphModel, a: String, ha: String, b: String, hb: String, pol: String) -> void:
	m.add_connection({
		"scope_id": "root", "polarity": pol,
		"source_item_id": a, "source_handle_id": ha,
		"target_item_id": b, "target_handle_id": hb,
	})


func _fuse(m: GraphModel, a: String, ha: String, b: String, hb: String) -> void:
	var pol := "positive" if hb == "positive" or ha.contains("Positive") else "negative"
	m.add_item({
		"id": "brk", "type": "breaker", "label": "Fuse 40 A",
		"x": 0.0, "y": 0.0, "width": 80.0, "height": 48.0, "scope_id": "root",
		"specs": {"name": "Fuse 40 A", "fuse": true, "rating_a": 40.0},
	})
	_wire(m, a, ha, "brk", "input", pol)
	_wire(m, "brk", "output", b, hb, pol)


func _kind(devs: Array, kind: String) -> String:
	for d in devs:
		if str(d["kind"]) == kind:
			return str(d["name"])
	return ""


func _box(devs: Array, kind: String) -> Rect2:
	for d in devs:
		if str(d["kind"]) == kind:
			return d["box"]
	return Rect2()


func _port(devs: Array, kind: String, handle: String) -> Dictionary:
	for d in devs:
		if str(d["kind"]) != kind:
			continue
		for p in (d["ports"] as Array):
			if str(p["handle"]) == handle:
				return p
	return {}


func _pole(conds: Array, device_id: String, handle: String) -> Dictionary:
	for c in conds:
		var cd: Dictionary = c
		if (str(cd["a"]) == device_id and str(cd["ha"]) == handle) or (str(cd["b"]) == device_id and str(cd["hb"]) == handle):
			if str(cd["polarity"]) == ("positive" if handle == "positive" else "negative"):
				return cd
	return {}


func _ends_on_ports(devs: Array, c: Dictionary) -> bool:
	var pts: PackedVector2Array = c["pts"]
	if pts.size() < 2:
		return false
	var pa := _port_on(devs, str(c["a"]), str(c["ha"]))
	var pb := _port_on(devs, str(c["b"]), str(c["hb"]))
	if pa.is_empty() or pb.is_empty():
		return false
	return pts[0].distance_to(pa["pos"]) < 0.01 and pts[pts.size() - 1].distance_to(pb["pos"]) < 0.01


func _port_on(devs: Array, id: String, handle: String) -> Dictionary:
	for d in devs:
		if str(d["id"]) != id:
			continue
		for p in (d["ports"] as Array):
			if str(p["handle"]) == handle:
				return p
	return {}


func _ortho(c: Dictionary) -> bool:
	var pts: PackedVector2Array = c["pts"]
	if pts.size() < 2:
		return false
	for i in range(1, pts.size()):
		var d: Vector2 = pts[i] - pts[i - 1]
		if absf(d.x) > 0.01 and absf(d.y) > 0.01:
			return false
	return true


func _dev(devs: Array, kind: String) -> Dictionary:
	for d in devs:
		if str(d["kind"]) == kind:
			return d
	return {}


func _lead_end(face: Dictionary, role: String) -> Vector2:
	for ld in (face.get("leads", []) as Array):
		if str(ld["role"]) == role:
			return ld["end"]
	return Vector2.INF


func _codes(lay: Dictionary) -> Array:
	var out: Array = []
	for c in (lay["checks"] as Array):
		var code := str(c.get("code", ""))
		if not code.is_empty():
			out.append(code)
	return out


func _test_svg() -> void:
	var lay := WireSheet.layout(_chain(""), "ctl")
	var svg := WireSheet.svg(lay)
	_ok(svg.begins_with("<?xml") and svg.contains("<svg") and svg.ends_with("</svg>"), "the page exports an SVG document")
	_ok(svg.contains("dev_pnl") and svg.contains("dev_ctl") and svg.contains("dev_bat"), "the SVG has the three devices")
	_ok(svg.contains("Trainer MPPT 150V 30A") and svg.contains("12V 100Ah AGM") and svg.contains("6 AWG") and svg.contains("10 AWG"),
		"the SVG names the controller, the battery and both gauges")
	_ok(svg.contains("face_front") and svg.contains("1S × 1P") and svg.contains("100 Ah"),
		"the SVG draws the face, the string and the amp-hours")
	_ok(svg.contains("Battery: no fuse on the positive."), "the SVG includes the missing-fuse callout")
	var red := "#" + CtrlSheet.wire_color("bat+").to_html(false)
	_ok(svg.contains(red), "the positive runs use the controller-face red (%s)" % red)
	var centre: Vector2 = (_box(lay["devices"], "battery") as Rect2).get_center()
	_ok(WireSheet.device_at(lay, centre) == "bat", "a point inside the battery hits the battery")
	_ok(WireSheet.device_at(lay, Vector2(-400, -400)) == "", "empty paper hits nothing")


func _test_insert() -> void:
	var m := _chain("")
	var lay := WireSheet.layout(m, "ctl")
	var bp: Dictionary = _pole(lay["conductors"], "bat", "positive")
	var pts: PackedVector2Array = bp["pts"]
	var on_run: Vector2 = (pts[0] + pts[1]) * 0.5
	_ok(WireSheet.conductor_at(lay, on_run) == str(bp["id"]), "a point on the battery positive hits that run")
	_ok(WireSheet.conductor_at(lay, Vector2(-400, -400)) == "", "empty paper hits no run")
	_ok(WireSheet.insert(m, "missing", "fuse").is_empty(), "an unknown run is left alone")
	var fuse_id := WireSheet.insert(m, str(bp["id"]), "fuse")
	var fused := WireSheet.layout(m, "ctl")
	var fuse := _dev(fused["devices"], "fuse")
	_ok(not fuse_id.is_empty() and _codes(fused).is_empty(), "a fuse dropped on the positive clears the callout")
	_ok(not fuse.is_empty() and str((fuse.get("symbol", {}) as Dictionary).get("caption", "")) == "50 A",
		"the fuse is the next frame above 125 %% of 30 A (got %s)" % str((fuse.get("symbol", {}) as Dictionary).get("caption", "")))
	_ok((m.get_connection(str(bp["id"])) as Dictionary).is_empty(), "the original run is replaced")
	_ok(float((m.get_item("bat") as Dictionary)["x"]) == 0.0 and float((m.get_item("ctl") as Dictionary)["x"]) == 0.0,
		"dropping a fuse does not move the cards")
	var swm := _chain("")
	var sw_run := str(_pole(WireSheet.layout(swm, "ctl")["conductors"], "bat", "positive")["id"])
	_ok(not WireSheet.insert(swm, sw_run, "switch").is_empty() and _codes(WireSheet.layout(swm, "ctl")).has("no_fuse")
		and not _dev(WireSheet.layout(swm, "ctl")["devices"], "switch").is_empty(),
		"a switch in the positive is drawn and the fuse is still missing")
	var bus := _chain("")
	var bus_run := str(_pole(WireSheet.layout(bus, "ctl")["conductors"], "bat", "positive")["id"])
	WireSheet.insert(bus, bus_run, "busbar")
	var bus_lay := WireSheet.layout(bus, "ctl")
	_ok(not _dev(bus_lay["devices"], "busbar").is_empty() and _codes(bus_lay).has("no_fuse"),
		"a busbar in the positive is drawn and the fuse is still missing")
	var dist := _chain("")
	var dist_run := str(_pole(WireSheet.layout(dist, "ctl")["conductors"], "bat", "positive")["id"])
	_ok(not WireSheet.insert(dist, dist_run, "distributor").is_empty(), "a distributor can be dropped on the positive")
	var dlay := WireSheet.layout(dist, "ctl")
	_ok(not _dev(dlay["devices"], "distributor").is_empty() and not _dev(dlay["devices"], "fuse").is_empty()
		and _codes(dlay).is_empty(),
		"the distributor brings a fuse, and that clears the callout")
	var shunt := _chain("")
	var shunt_run := str(_pole(WireSheet.layout(shunt, "ctl")["conductors"], "bat", "positive")["id"])
	_ok(not WireSheet.insert(shunt, shunt_run, "shunt").is_empty(), "a shunt can be dropped on the positive")
	var slay := WireSheet.layout(shunt, "ctl")
	var sh := _dev(slay["devices"], "shunt")
	_ok(not sh.is_empty() and str((sh.get("symbol", {}) as Dictionary).get("caption", "")) == "Shunt"
		and _codes(slay).has("no_fuse"),
		"a shunt is drawn and the fuse is still missing")


## A routed length replaces the estimate, and the gauge follows it.
func _test_route() -> void:
	var m := _chain("")
	var cid := str(_pole(WireSheet.layout(m, "ctl")["conductors"], "bat", "positive")["id"])
	(m.get_connection(cid) as Dictionary)["estimated_length"] = 8.0
	var length := WireAccessory.stamp(m, cid, Vector3(0, 1, 0), Vector3(0.3, 1, 0))
	_ok(absf(length - 0.3) < 0.001, "a straight 0.3 m run is 0.3 m (got %.3f)" % length)
	_ok(WireAccessory.stamp(m, "missing", Vector3.ZERO, Vector3.ONE) < 0.0, "a missing run is not stamped")
	var run := _pole(WireSheet.layout(m, "ctl")["conductors"], "bat", "positive")
	_ok(str(run.get("gauge", "")) == "8 AWG",
		"the sheet sizes the battery positive from the routed 0.3 m (got %s)" % str(run.get("gauge", "")))
	_ok(absf(float(run.get("length_m", -1.0)) - 0.3) < 0.001, "route_length_m wins over the 8 m estimate")


## Comms stay off the power page until asked for, then land in the face's teal.
func _test_data() -> void:
	var m := _chain("")
	m.add_item({
		"id": "gx", "type": "processor", "label": "Cerbo",
		"x": 0.0, "y": 0.0, "width": 80.0, "height": 48.0, "scope_id": "root",
		"specs": {"name": "Cerbo GX"},
	})
	_wire(m, "ctl", "data", "gx", "data", "data")
	var off := WireSheet.layout(m, "ctl")
	_ok((off["conductors"] as Array).size() == 4 and _dev(off["devices"], "monitor").is_empty(),
		"comms stay off the power page")
	var on := WireSheet.layout(m, "ctl", {"show_data": true})
	var data := {}
	for c in (on["conductors"] as Array):
		if str(c["polarity"]) == "data":
			data = c
	var col: Color = data.get("color", Color.BLACK)
	_ok((on["conductors"] as Array).size() == 5 and str(data.get("label", "")) == "RS485"
		and col.is_equal_approx(CtrlSheet.wire_color("ve_direct"))
		and col.is_equal_approx(CtrlSheet.wire_color("ve_bus"))
		and str(data.get("gauge", "x")) == "",
		"the comms run is the face's teal, named, and not a power gauge (got %s)" % str(data.get("label", "")))
	var mon := _dev(on["devices"], "monitor")
	_ok(str(mon.get("name", "")) == "Cerbo GX" and str((mon.get("symbol", {}) as Dictionary).get("caption", "")) == "RS485",
		"the monitor the lead lands on is on the page")
	var bp := _pole(on["conductors"], "bat", "positive")
	_ok(str(bp.get("gauge", "")) == "6 AWG" and _codes(on) == ["no_fuse"],
		"showing comms leaves the battery gauge and the fuse callout")
	_ok(WireSheet.insert(m, str(data.get("id", "")), "fuse").is_empty(),
		"a fuse cannot be dropped on a comms lead")
	var shown := WireSheet.svg(on)
	var hidden := WireSheet.svg(off)
	_ok(shown.contains("Cerbo GX") and not hidden.contains("Cerbo"),
		"the SVG includes the monitor only while data is on")


func _ids(lay: Dictionary) -> Array:
	var out: Array = []
	for d in (lay["devices"] as Array):
		out.append(str(d["id"]))
	out.sort()
	return out
