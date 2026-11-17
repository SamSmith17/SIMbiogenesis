extends SceneTree

## LoopSankeyLayout selftest (offline). Pins: a chain has no returns and
## flows down layer by layer; a cycle gets exactly one return, on its
## lightest edge; a self loop is a return; returns leave the column and nest
## by span; return paths are continuous from the source's bottom to the
## target's top; node widths are their throughput; each resource keeps its
## own scale; determinism (and input order not mattering); Finn's Cycling
## Index by hand (0 for a chain, r/(z+r) for a two-compartment loop, ~1 for a
## closed loop); boundary flows enter from above and leave below; and a
## 200-node graph within a CPU budget.
##
## Carries EXPECTED_CHECKS: a GDScript runtime error aborts the enclosing test
## function while the suite still prints PASS.
##   godot --headless --path . --script system_graph/loop_sankey_layout_selftest.gd

const EXPECTED_CHECKS := 41

var _checks := 0
var _fails := 0


func _init() -> void:
	_test_chain()
	_test_cycle()
	_test_nested()
	_test_scales()
	_test_determinism()
	_test_fci()
	_test_boundaries()
	_test_tiers()
	_test_budget()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		print("FAIL check count %d != EXPECTED_CHECKS %d (a test function aborted?)" % [_checks, EXPECTED_CHECKS])
	print("LOOP SANKEY LAYOUT SELFTEST %s  (%d checks, %d failed)" % [
		"PASS" if _fails == 0 else "FAIL", _checks, _fails])
	quit(0 if _fails == 0 else 1)


func _ok(cond: bool, what: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		print("  FAIL " + what)


static func _n(ids: Array) -> Array:
	var out: Array = []
	for i in ids:
		out.append({"id": str(i), "label": str(i)})
	return out


static func _e(a: String, b: String, v: float, key: String = "water") -> Dictionary:
	return {"id": "%s>%s" % [a, b], "a": a, "b": b, "value": v, "key": key}


static func _returns(r: Dictionary) -> Array:
	var out: Array = []
	for rb in (r["ribbons"] as Array):
		if str(rb["kind"]) == LoopSankeyLayout.KIND_RETURN:
			out.append(rb)
	return out


func _test_chain() -> void:
	var r := LoopSankeyLayout.layout(_n(["a", "b", "c"]), [_e("a", "b", 5.0), _e("b", "c", 5.0)])
	_ok(_returns(r).is_empty(), "a chain has no returns")
	var N: Dictionary = r["nodes"]
	_ok(int(N["a"]["layer"]) == 0 and int(N["b"]["layer"]) == 1 and int(N["c"]["layer"]) == 2,
		"a chain is one node per layer, top to bottom")
	var down := true
	for rb in (r["ribbons"] as Array):
		var p: PackedVector2Array = rb["path"]
		if p[p.size() - 1].y <= p[0].y:
			down = false
	_ok(down, "every forward ribbon flows down")
	_ok(is_equal_approx(float((r["metrics"]["water"] as Dictionary)["fci"]), 0.0), "a chain cycles nothing")


func _test_cycle() -> void:
	var r := LoopSankeyLayout.layout(_n(["a", "b", "c"]),
		[_e("a", "b", 10.0), _e("b", "c", 10.0), _e("c", "a", 2.0)])
	var rets := _returns(r)
	_ok(rets.size() == 1, "a cycle gets exactly one return")
	_ok(rets.size() == 1 and str(rets[0]["id"]) == "c>a", "the return is the lightest edge")
	_ok((r["loops"] as Array).size() == 1 and ((r["loops"][0] as Dictionary)["nodes"] as Array).size() == 3,
		"one loop of three nodes")
	var lo := INF
	var hi := -INF
	for id in (r["nodes"] as Dictionary):
		var rc: Rect2 = r["nodes"][id]["rect"]
		lo = minf(lo, rc.position.x)
		hi = maxf(hi, rc.end.x)
	var p: PackedVector2Array = rets[0]["path"] if rets.size() == 1 else PackedVector2Array()
	var outside := false
	var max_step := 0.0
	for i in p.size():
		if p[i].x < lo or p[i].x > hi:
			outside = true
		if i > 0:
			max_step = maxf(max_step, p[i].distance_to(p[i - 1]))
	_ok(outside, "a return swings outside the column")
	_ok(p.size() > 4 and max_step < 0.2 * _path_len(p), "a return path is continuous (no jumps)")
	var src: Rect2 = r["nodes"]["c"]["rect"]
	var dst: Rect2 = r["nodes"]["a"]["rect"]
	_ok(p.size() > 1 and absf(p[0].y - src.end.y) < 0.01 and absf(p[p.size() - 1].y - dst.position.y) < 0.01,
		"a return leaves the source's bottom and enters the target's top")
	var s := LoopSankeyLayout.layout(_n(["a"]), [_e("a", "a", 3.0)])
	_ok(_returns(s).size() == 1, "a self loop is a return")


func _test_nested() -> void:
	var r := LoopSankeyLayout.layout(_n(["a", "b", "c", "d"]),
		[_e("a", "b", 10.0), _e("b", "c", 10.0), _e("c", "d", 10.0), _e("d", "c", 1.0), _e("d", "a", 2.0)])
	var rets := _returns(r)
	_ok(rets.size() == 2, "two loops, two returns")
	var ok := true
	for x in rets:
		for y in rets:
			if int(x["side"]) != int(y["side"]):
				continue
			var spx := absf(float(r["nodes"][str(x["a"])]["layer"]) - float(r["nodes"][str(x["b"])]["layer"]))
			var spy := absf(float(r["nodes"][str(y["a"])]["layer"]) - float(r["nodes"][str(y["b"])]["layer"]))
			if spx < spy and _outer(x) > _outer(y) + 0.5:
				ok = false
	_ok(ok, "on one side, a longer loop runs outside a shorter one")
	var N: Dictionary = r["nodes"]
	_ok(int(N["a"]["layer"]) < int(N["b"]["layer"]) and int(N["c"]["layer"]) < int(N["d"]["layer"]),
		"the main stream keeps its order down the page")


static func _path_len(p: PackedVector2Array) -> float:
	var l := 0.0
	for i in range(1, p.size()):
		l += p[i].distance_to(p[i - 1])
	return l


static func _outer(rb: Dictionary) -> float:
	var p: PackedVector2Array = rb["path"]
	var m := 0.0
	for q in p:
		m = maxf(m, absf(q.x))
	return m


func _test_scales() -> void:
	var r := LoopSankeyLayout.layout(_n(["a", "b", "c", "d"]),
		[_e("a", "b", 1000.0, "water"), _e("c", "d", 2.0, "electricity"), _e("a", "d", 500.0, "water")],
		[], [], {"thickness": 30.0})
	var wmax := {}
	var w_half := 0.0
	for rb in (r["ribbons"] as Array):
		wmax[str(rb["key"])] = maxf(float(wmax.get(str(rb["key"]), 0.0)), float(rb["width"]))
		if str(rb["id"]) == "a>d":
			w_half = float(rb["width"])
	_ok(is_equal_approx(float(wmax["water"]), 30.0) and is_equal_approx(float(wmax["electricity"]), 30.0),
		"each resource's biggest flow is the full thickness")
	_ok(is_equal_approx(w_half, 15.0), "half the water is half the width")
	var a_out := 0.0
	for rb in (r["ribbons"] as Array):
		if str(rb["a"]) == "a":
			a_out += float(rb["width"])
	_ok(is_equal_approx(float(r["nodes"]["a"]["through_px"]), a_out), "a node is as wide as what flows through it")


func _test_determinism() -> void:
	var nodes := _n(["p", "q", "r", "s", "t"])
	var edges := [_e("p", "q", 4.0), _e("q", "r", 3.0), _e("r", "p", 1.0), _e("q", "s", 1.0),
		_e("s", "t", 1.0), _e("t", "q", 0.5)]
	var a := LoopSankeyLayout.layout(nodes, edges)
	var b := LoopSankeyLayout.layout(nodes, edges)
	_ok(var_to_str(a) == var_to_str(b), "same input, same layout")
	var en := edges.duplicate()
	en.reverse()
	var nn := nodes.duplicate()
	nn.reverse()
	var c := LoopSankeyLayout.layout(nn, en)
	_ok(var_to_str(a) == var_to_str(c), "input order does not matter")


func _test_fci() -> void:
	var r := LoopSankeyLayout.layout(_n(["a", "b"]), [_e("a", "b", 20.0), _e("b", "a", 10.0)],
		[{"node": "a", "key": "water", "value": 10.0}], [{"node": "b", "key": "water", "value": 10.0}])
	var m: Dictionary = r["metrics"]["water"]
	_ok(absf(float(m["fci"]) - 0.5) < 1e-3, "FCI of a two-compartment loop is r/(z+r) = 0.5 (got %.4f)" % float(m["fci"]))
	_ok(is_equal_approx(float(m["boundary_in"]), 10.0) and is_equal_approx(float(m["boundary_out"]), 10.0),
		"boundary totals")
	_ok(int(m["loops"]) == 1, "one water loop")
	var c := LoopSankeyLayout.layout(_n(["a", "b"]), [_e("a", "b", 5.0), _e("b", "a", 5.0)])
	_ok(float((c["metrics"]["water"] as Dictionary)["fci"]) > 0.99, "a fully closed loop cycles everything")
	var three := LoopSankeyLayout.cycling_metrics(["a", "b", "c"],
		[_e("a", "b", 10.0), _e("b", "c", 10.0)], [{"node": "a", "key": "water", "value": 10.0}],
		[{"node": "c", "key": "water", "value": 10.0}])
	_ok(absf(float(three["water"]["fci"])) < 1e-6, "an open chain with boundaries cycles nothing")


func _test_boundaries() -> void:
	var r := LoopSankeyLayout.layout(_n(["a", "b"]), [_e("a", "b", 5.0)],
		[{"node": "a", "key": "water", "value": 5.0, "label": "rain"}],
		[{"node": "b", "key": "water", "value": 5.0, "label": "to air"}])
	var ins := 0
	var outs := 0
	var ok_dir := true
	for rb in (r["ribbons"] as Array):
		var p: PackedVector2Array = rb["path"]
		if str(rb["kind"]) == LoopSankeyLayout.KIND_IN:
			ins += 1
			ok_dir = ok_dir and p[p.size() - 1].y > p[0].y and str(rb.get("label", "")) == "rain"
		elif str(rb["kind"]) == LoopSankeyLayout.KIND_OUT:
			outs += 1
			ok_dir = ok_dir and p[p.size() - 1].y > p[0].y
	_ok(ins == 1 and outs == 1, "one boundary in, one out")
	_ok(ok_dir, "boundary flows come down from above and leave downward")
	_ok(float(r["nodes"]["a"]["rect"].position.y) >= LoopSankeyLayout.BAND_H - 0.01,
		"room is kept above the top layer for inputs")


## Tiers (the Flows lens's reading order): panels over the inverter over
## the battery whatever the battery is doing; a discharging battery feeds the
## inverter above it with a short UP ribbon from its top to the inverter's
## bottom; per-node sizes; a store's own stock (hide) draws no stub but still
## counts in the metrics; a sunlight flag reaches its ribbon.
func _test_tiers() -> void:
	var nodes := [{"id": "pv", "label": "Array", "tier": 0, "w": 300.0, "h": 120.0},
		{"id": "inv", "label": "Inverter", "tier": 1}, {"id": "bat", "label": "Battery", "tier": 2},
		{"id": "load", "label": "Load"}]
	# Evening: the array makes a little, the battery makes up the rest.
	var edges := [{"id": "e1", "a": "pv", "b": "inv", "key": "electricity", "value": 300.0},
		{"id": "e2", "a": "bat", "b": "inv", "key": "electricity", "value": 900.0},
		{"id": "e3", "a": "inv", "b": "load", "key": "electricity", "value": 1100.0}]
	var bin := [{"node": "pv", "key": "electricity", "value": 300.0, "label": "sunlight", "sun": true},
		{"node": "bat", "key": "electricity", "value": 900.0, "label": "from its charge", "hide": true}]
	var lay := LoopSankeyLayout.layout(nodes, edges, bin, [], {"node_h": 40.0})
	var ly := func(id: String) -> int: return int(lay["nodes"][id]["layer"])
	_ok(ly.call("pv") < ly.call("inv") and ly.call("inv") < ly.call("bat"),
		"tiers: array %d over inverter %d over battery %d" % [ly.call("pv"), ly.call("inv"), ly.call("bat")])
	var up := {}
	var sun := {}
	var n_in := 0
	for rb in lay["ribbons"]:
		if str(rb["kind"]) == LoopSankeyLayout.KIND_UP:
			up = rb
		if str(rb["kind"]) == LoopSankeyLayout.KIND_IN:
			n_in += 1
			if bool(rb.get("sun", false)):
				sun = rb
	_ok(not up.is_empty() and str(up["a"]) == "bat" and str(up["b"]) == "inv", "tiers: the battery feeds its inverter UP")
	var bat_r: Rect2 = lay["nodes"]["bat"]["rect"]
	var inv_r: Rect2 = lay["nodes"]["inv"]["rect"]
	var p: PackedVector2Array = up.get("path", PackedVector2Array())
	_ok(p.size() > 2 and absf(p[0].y - bat_r.position.y) < 0.01 and absf(p[p.size() - 1].y - inv_r.end.y) < 0.01,
		"tiers: the up ribbon runs from the battery's top to the inverter's bottom")
	var mono := true
	for i in range(1, p.size()):
		if p[i].y > p[i - 1].y + 0.01:
			mono = false
	_ok(mono, "tiers: the up ribbon only rises")
	_ok(int(lay.get("returns", -1)) == 0, "tiers: no return round the side for it")
	var pv_r: Rect2 = lay["nodes"]["pv"]["rect"]
	_ok(absf(pv_r.size.x - 300.0) < 0.01 and absf(pv_r.size.y - 120.0) < 0.01, "sizes: the array card is its own size")
	_ok(inv_r.position.y >= pv_r.end.y, "sizes: the next layer starts under the tall card")
	_ok(n_in == 1 and not sun.is_empty(), "boundaries: the battery's own stock draws no stub; the sunlight does")
	_ok(float((lay["metrics"] as Dictionary)["electricity"].get("boundary_in", 0.0)) >= 1199.0,
		"boundaries: hidden stock still counts in the metrics (%s)" % str((lay["metrics"] as Dictionary)["electricity"]))
	# Midday: charging is an ordinary flow down; the battery is still under the inverter.
	var edges2 := [{"id": "e1", "a": "pv", "b": "inv", "key": "electricity", "value": 3000.0},
		{"id": "e2", "a": "inv", "b": "bat", "key": "electricity", "value": 1000.0},
		{"id": "e3", "a": "inv", "b": "load", "key": "electricity", "value": 1900.0}]
	var lay2 := LoopSankeyLayout.layout(nodes, edges2, [], [], {})
	_ok(int(lay2["nodes"]["bat"]["layer"]) == int(lay2["nodes"]["inv"]["layer"]) + 1
		and int(lay2.get("ups", -1)) == 0, "tiers: charging flows down into the battery under the inverter")


func _test_budget() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var ids: Array = []
	for i in 200:
		ids.append("n%03d" % i)
	var edges: Array = []
	for i in 200:
		for k in 2:
			var j := rng.randi_range(0, 199)
			if j != i:
				edges.append({"id": "e%d_%d" % [i, k], "a": ids[i], "b": ids[j],
					"value": rng.randf_range(0.5, 50.0), "key": ["water", "food", "electricity"][k % 3]})
	var t0 := Time.get_ticks_usec()
	var r := LoopSankeyLayout.layout(_n(ids), edges)
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	print("  200 nodes, %d edges: %.1f ms, %d returns, %d layers" % [edges.size(), ms,
		int(r["returns"]), int(r["layers"])])
	_ok((r["nodes"] as Dictionary).size() == 200, "every node is placed")
	_ok(ms < 1500.0, "200 nodes lay out within budget (%.0f ms)" % ms)
	var fwd_down := true
	for rb in (r["ribbons"] as Array):
		if str(rb["kind"]) == LoopSankeyLayout.KIND_FORWARD:
			var p: PackedVector2Array = rb["path"]
			if p[p.size() - 1].y <= p[0].y:
				fwd_down = false
	_ok(fwd_down, "on a tangled graph every forward ribbon still flows down")
	var ovl := false
	var by_layer := {}
	for id in (r["nodes"] as Dictionary):
		var L := int(r["nodes"][id]["layer"])
		if not by_layer.has(L):
			by_layer[L] = []
		(by_layer[L] as Array).append(r["nodes"][id]["rect"])
	for L in by_layer:
		var rs: Array = by_layer[L]
		for i in rs.size():
			for j in range(i + 1, rs.size()):
				if (rs[i] as Rect2).grow(-0.5).intersects((rs[j] as Rect2).grow(-0.5)):
					ovl = true
	_ok(not ovl, "no two nodes overlap")
