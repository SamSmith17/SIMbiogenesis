extends SceneTree

## ToroidFlowLayout selftest (offline), plus the two pieces the Flows lens
## gained with it: LoopSankeyLayout.wire_path (wire styles) and apply_pins
## (nodes the player moved).
##
## Pins: the ring curve (a closed rounded rectangle, where the fractions
## sit, the left lobe a mirror); a heat engine (energy nodes on the trunk
## top to bottom, energy in from the top, heat out below, the driven loop
## one ring drawn as one band, the work a thin link); the circulation (down
## beside the trunk on both lobes); loops spread over both lobes and nest;
## a chain as a through-flow ring with a tail and an arrow head; store flows
## shown on the node; the same cycling index as the column; no two nodes on
## one spot; flows between the lobes round the trunk's ends; determinism; a
## 200-node budget; wire styles; pins.
##
## Carries EXPECTED_CHECKS: a GDScript runtime error aborts the enclosing test
## function while the suite still prints PASS.
##   godot --headless --path . --script system_graph/toroid_flow_layout_selftest.gd

const EXPECTED_CHECKS := 59

var _checks := 0
var _fails := 0


func _init() -> void:
	_test_curve()
	_test_heat_engine()
	_test_circulation()
	_test_lobes()
	_test_through_flow()
	_test_metrics_and_determinism()
	_test_spacing_and_budget()
	_test_wire_path()
	_test_pins()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		print("FAIL check count %d != EXPECTED_CHECKS %d (a test function aborted?)" % [_checks, EXPECTED_CHECKS])
	print("TOROID FLOW LAYOUT SELFTEST %s  (%d checks, %d failed)" % [
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


static func _rib(r: Dictionary, id: String) -> Dictionary:
	for rb in (r["ribbons"] as Array):
		if str(rb["id"]) == id:
			return rb
	return {}


static func _centre(r: Dictionary, id: String) -> Vector2:
	return (r["nodes"][id]["rect"] as Rect2).get_center()


## Panels, a battery and a lamp on electricity; a pump on electricity that
## turns a water loop: tank -> pump -> bed -> tank.
static func _engine() -> Dictionary:
	var nodes := _n(["panel", "battery", "lamp", "pump", "tank", "bed"])
	var edges := [
		_e("panel", "battery", 900.0, "electricity"), _e("battery", "lamp", 300.0, "electricity"),
		_e("battery", "pump", 500.0, "electricity"),
		_e("tank", "pump", 40.0), _e("pump", "bed", 40.0), _e("bed", "tank", 30.0)]
	var bin := [{"node": "panel", "key": "electricity", "value": 900.0, "label": "made"},
		{"node": "tank", "key": "water", "value": 10.0, "label": "from store"}]
	var bout := [{"node": "lamp", "key": "electricity", "value": 300.0, "label": "used"},
		{"node": "pump", "key": "electricity", "value": 500.0, "label": "used"},
		{"node": "bed", "key": "water", "value": 10.0, "label": "used"},
		{"node": "battery", "key": "electricity", "value": 100.0, "label": "into store"}]
	return ToroidFlowLayout.layout(nodes, edges, bin, bout)


func _test_curve() -> void:
	var a := 400.0
	var rg := {"side": 1, "hw": 80.0, "hh": 150.0, "r": 50.0}
	var per := ToroidFlowLayout.ring_perimeter(rg)
	var worst := 0.0
	var prev := ToroidFlowLayout.ring_pt(a, rg, 0.0)
	var length := 0.0
	for k in range(1, 2001):
		var p := ToroidFlowLayout.ring_pt(a, rg, float(k) / 2000.0)
		worst = maxf(worst, p.distance_to(prev))
		length += p.distance_to(prev)
		prev = p
	_ok(worst < per / 2000.0 * 1.5 and prev.distance_to(ToroidFlowLayout.ring_pt(a, rg, 0.0)) < 0.01,
		"a ring is one closed curve with no jumps")
	_ok(absf(length - per) < per * 0.002, "its length is the rounded rectangle's perimeter")
	var top := ToroidFlowLayout.ring_pt(a, rg, 0.0)
	var inner := ToroidFlowLayout.ring_pt(a, rg, 0.25)
	var bottom := ToroidFlowLayout.ring_pt(a, rg, 0.5)
	var outer := ToroidFlowLayout.ring_pt(a, rg, 0.75)
	_ok(is_equal_approx(top.x, a) and is_equal_approx(top.y, -150.0), "fraction 0 is the top centre")
	_ok(is_equal_approx(inner.x, a - 80.0) and absf(inner.y) < 0.01, "a quarter round is the side beside the trunk")
	_ok(is_equal_approx(bottom.y, 150.0) and is_equal_approx(outer.x, a + 80.0), "then the bottom, then the far side")
	var l := ToroidFlowLayout.ring_pt(a, {"side": -1, "hw": 80.0, "hh": 150.0, "r": 50.0}, 0.25)
	_ok(is_equal_approx(l.x, -inner.x) and is_equal_approx(l.y, inner.y), "the left lobe mirrors the right")


func _test_heat_engine() -> void:
	var r := _engine()
	var N: Dictionary = r["nodes"]
	_ok(str(r.get("shape", "")) == "torus", "the layout says it is a torus")
	_ok(str(N["panel"]["shape"]) == "card" and str(N["battery"]["shape"]) == "card" and str(N["lamp"]["shape"]) == "card",
		"nodes that only touch electricity stand on the trunk")
	_ok(absf(_centre(r, "panel").x) < 1.0 and _centre(r, "panel").y < _centre(r, "battery").y \
		and _centre(r, "battery").y < _centre(r, "lamp").y, "the trunk runs source, store, load from the top down")
	_ok(str(N["pump"]["shape"]) == "disc" and str(N["tank"]["shape"]) == "disc" and str(N["bed"]["shape"]) == "disc",
		"nodes that handle a material sit on a ring")
	var ein := _rib(r, "in:0")
	var p_in: PackedVector2Array = ein.get("path", PackedVector2Array())
	_ok(bool(ein.get("major", false)) and p_in.size() > 1 and is_equal_approx(p_in[0].y, float(r["axis"]["y0"])),
		"what the top of the trunk makes comes in from the top edge")
	var heat := {}
	for rb in (r["ribbons"] as Array):
		if str(rb["kind"]) == LoopSankeyLayout.KIND_OUT:
			heat[str(rb["a"])] = rb
	_ok(str((heat.get("lamp", {}) as Dictionary).get("label", "")) == "heat" \
		and bool((heat.get("lamp", {}) as Dictionary).get("major", false)),
		"electricity a load uses leaves the bottom of the trunk as heat")
	_ok(not heat.has("battery") and float(N["battery"].get("store_flow", 0.0)) > 0.0 \
		and float(N["tank"].get("store_flow", 0.0)) < 0.0,
		"a store filling or emptying shows on the node, not as a ribbon")
	_ok(int(N["pump"]["ring"]) == int(N["tank"]["ring"]) and int(N["tank"]["ring"]) == int(N["bed"]["ring"]) \
		and int(N["pump"]["loop"]) >= 0, "the water loop shares one ring")
	_ok((r["loops"] as Array).size() == 1, "one loop")
	var bands: Array = []
	var rets := 0
	for rb2 in (r["ribbons"] as Array):
		if bool(rb2.get("band", false)):
			bands.append(rb2)
			if str(rb2["kind"]) == LoopSankeyLayout.KIND_RETURN:
				rets += 1
	var one_w := bands.size() == 3
	for bnd in bands:
		if not is_equal_approx(float(bnd["width"]), float(bands[0]["width"])):
			one_w = false
	_ok(one_w and rets == 1, "the loop is three stretches of one band, one of them closing it")
	_ok(bands.size() > 0 and float(bands[0]["width"]) >= ToroidFlowLayout.BAND_MIN, "a band is bold")
	var work := _rib(r, "battery>pump")
	var wp: PackedVector2Array = work.get("path", PackedVector2Array())
	_ok(bool(work.get("link", false)) and float(work.get("width", 99.0)) <= ToroidFlowLayout.LINK_MAX \
		and wp.size() > 4 and wp[wp.size() - 1].distance_to(_centre(r, "pump")) < 1.0 \
		and absf(wp[0].y - _centre(r, "battery").y) < 1.0,
		"the work is a thin link from the trunk node's side to the machine it drives")
	_ok(is_equal_approx(float(r["axis"]["energy_in"]), 900.0) and is_equal_approx(float(r["axis"]["heat_out"]), 800.0),
		"energy in and heat out are summed off the trunk's resource")


func _test_circulation() -> void:
	var r := _engine()
	var a := float(r["lobe_a"])
	var side := int(r["nodes"]["pump"]["side"])
	var ring := int(r["nodes"]["pump"]["ring"])
	var on_ring := true
	var down_inside := true
	var seen_inside := false
	var total := 0.0
	var c := Vector2(float(side) * a, 0.0)
	var inner_x := float((r["rings"] as Array)[ring]["hw"])
	for rb in (r["ribbons"] as Array):
		if not bool(rb.get("band", false)):
			continue
		var p: PackedVector2Array = rb["path"]
		for i in p.size():
			if float(ToroidFlowLayout.nearest_on_ring(r, ring, p[i])[1]) > 1.5:
				on_ring = false
			if i > 0:
				total += (p[i - 1] - c).cross(p[i] - c)
				# On the straight beside the trunk the flow must run DOWN.
				if absf(absf(p[i].x - c.x) - inner_x) < 0.5 and absf(p[i].x) < absf(c.x) \
						and absf(p[i - 1].x - p[i].x) < 0.01:
					seen_inside = true
					if p[i].y < p[i - 1].y - 0.01:
						down_inside = false
		_ok(p[0].distance_to(_centre(r, str(rb["a"]))) < 1.0 and p[p.size() - 1].distance_to(_centre(r, str(rb["b"]))) < 1.0,
			"a band runs from node centre to node centre (%s)" % str(rb["id"]))
	_ok(on_ring, "the loop's band stays on its ring")
	_ok(seen_inside and down_inside, "beside the trunk the loop runs down, with the energy")
	_ok(signf(total) == -float(side), "seen on screen the %s lobe turns %s" % [
		"right" if side > 0 else "left", "anticlockwise" if side > 0 else "clockwise"])


func _test_lobes() -> void:
	# Three separate loops of different sizes.
	var nodes := _n(["a1", "a2", "b1", "b2", "b3", "c1", "c2", "c3", "c4"])
	var edges := [_e("a1", "a2", 9.0), _e("a2", "a1", 9.0),
		_e("b1", "b2", 5.0), _e("b2", "b3", 5.0), _e("b3", "b1", 5.0),
		_e("c1", "c2", 7.0), _e("c2", "c3", 7.0), _e("c3", "c4", 7.0), _e("c4", "c1", 7.0)]
	var r := ToroidFlowLayout.layout(nodes, edges)
	var N: Dictionary = r["nodes"]
	_ok((r["loops"] as Array).size() == 3, "three loops found")
	var sides := {}
	for id in N:
		sides[int(N[id]["side"])] = true
	_ok(sides.has(-1) and sides.has(1), "loops are spread over both lobes")
	var same_ring := int(N["a1"]["ring"]) == int(N["a2"]["ring"]) and int(N["b1"]["ring"]) == int(N["b3"]["ring"]) \
		and int(N["c1"]["ring"]) == int(N["c4"]["ring"])
	var apart := int(N["a1"]["ring"]) != int(N["b1"]["ring"]) and int(N["b1"]["ring"]) != int(N["c1"]["ring"])
	_ok(same_ring and apart, "each loop has its own ring")
	# Two loops on one lobe nest: the smaller loop is the inner ring, and
	# the outer ring clears it everywhere.
	var R: Array = r["rings"]
	var nested := true
	var checked := false
	for x in ["a1", "b1", "c1"]:
		for y in ["a1", "b1", "c1"]:
			if x == y or int(N[x]["side"]) != int(N[y]["side"]):
				continue
			checked = true
			var rx: Dictionary = R[int(N[x]["ring"])]
			var ry: Dictionary = R[int(N[y]["ring"])]
			var nx := ((r["loops"][int(N[x]["loop"])] as Dictionary)["nodes"] as Array).size()
			var ny := ((r["loops"][int(N[y]["loop"])] as Dictionary)["nodes"] as Array).size()
			if nx < ny and (float(rx["hw"]) >= float(ry["hw"]) or float(rx["hh"]) >= float(ry["hh"])):
				nested = false
	_ok(checked and nested, "on one lobe the smaller loop is the inner ring")
	_ok((r["guides"] as Array).size() == 3 and (r["rings"] as Array).size() == 3, "every ring has its track")
	# One big component with two cycles through a shared node is cut in two.
	var r2 := ToroidFlowLayout.layout(_n(["h", "p", "q", "s", "t"]),
		[_e("h", "p", 8.0), _e("p", "q", 8.0), _e("q", "h", 6.0), _e("h", "s", 4.0), _e("s", "t", 4.0), _e("t", "h", 3.0)])
	_ok((r2["loops"] as Array).size() == 2, "a component with two cycles becomes two loops")
	var sd := {}
	for id2 in (r2["nodes"] as Dictionary):
		sd[int(r2["nodes"][id2]["side"])] = true
	_ok(sd.size() == 1, "and both stay on one lobe")
	var r3 := ToroidFlowLayout.layout(_n(["h", "p", "q", "s", "t"]),
		[_e("h", "p", 8.0), _e("p", "q", 8.0), _e("q", "h", 6.0), _e("h", "s", 4.0), _e("s", "t", 4.0), _e("t", "h", 3.0)],
		[], [], {"mirror": true})
	var flipped := true
	for id3 in (r2["nodes"] as Dictionary):
		var c2 := _centre(r2, str(id3))
		var c3 := _centre(r3, str(id3))
		if int(r3["nodes"][id3]["side"]) != -int(r2["nodes"][id3]["side"]) or absf(c3.x + c2.x) > 0.01 or absf(c3.y - c2.y) > 0.01:
			flipped = false
	_ok(flipped, "mirror swaps the lobes: every node at the mirror image of its place")


func _test_through_flow() -> void:
	var r := ToroidFlowLayout.layout(_n(["rain", "tank", "tap", "drain"]),
		[_e("rain", "tank", 5.0), _e("tank", "tap", 5.0), _e("tap", "drain", 5.0)],
		[{"node": "rain", "key": "water", "value": 5.0, "label": "made"}],
		[{"node": "drain", "key": "water", "value": 5.0, "label": "used"}])
	var N: Dictionary = r["nodes"]
	_ok((r["loops"] as Array).is_empty() and int(N["rain"]["loop"]) < 0, "a chain is no loop")
	_ok(int(N["rain"]["ring"]) == int(N["drain"]["ring"]) and not bool((r["rings"] as Array)[int(N["rain"]["ring"])]["closed"]),
		"it gets an open ring of its own")
	_ok(_centre(r, "rain").y < _centre(r, "tank").y and _centre(r, "tank").y < _centre(r, "tap").y \
		and _centre(r, "tap").y < _centre(r, "drain").y, "it runs from the top down")
	var tail := _rib(r, "in:r%d" % int(N["rain"]["ring"]))
	var head := _rib(r, "out:r%d" % int(N["rain"]["ring"]))
	_ok(bool(tail.get("tail", false)) and bool(head.get("arrow", false)) and bool(tail.get("band", false)),
		"what comes in is its tail, what leaves is its arrow head")
	var tp: PackedVector2Array = tail.get("path", PackedVector2Array())
	var hp: PackedVector2Array = head.get("path", PackedVector2Array())
	var a := float(r["lobe_a"])
	var side := float(int(N["rain"]["side"]))
	_ok(tp.size() > 2 and hp.size() > 2 and tp[0].y < _centre(r, "rain").y + 1.0 and hp[hp.size() - 1].y > _centre(r, "drain").y - 1.0 \
		and absf(tp[0].x) > absf(_centre(r, "tank").x) and absf(hp[hp.size() - 1].x) > absf(_centre(r, "tank").x),
		"it comes in over the top from the far side and leaves under the bottom toward it")
	var beside := true
	for id in ["tank", "tap"]:
		if absf(_centre(r, id).x) > absf(side * a):
			beside = false
	_ok(beside, "its middle runs down the trunk's side of the lobe")
	_ok(ToroidFlowLayout.layout([], []).get("nodes", {"x": 1}).is_empty(), "nothing in, nothing out")


func _test_metrics_and_determinism() -> void:
	var nodes := _n(["a", "b", "c", "d", "e"])
	var edges := [_e("a", "b", 10.0), _e("b", "c", 8.0), _e("c", "a", 6.0), _e("c", "d", 2.0), _e("d", "e", 2.0)]
	var bin := [{"node": "a", "key": "water", "value": 4.0, "label": "made"}]
	var bout := [{"node": "e", "key": "water", "value": 2.0, "label": "used"}]
	var t := ToroidFlowLayout.layout(nodes, edges, bin, bout)
	var c := LoopSankeyLayout.layout(nodes, edges, bin, bout)
	_ok(is_equal_approx(float(t["metrics"]["water"]["fci"]), float(c["metrics"]["water"]["fci"])) \
		and float(t["metrics"]["water"]["fci"]) > 0.1, "the cycling index is the column's")
	var n2 := nodes.duplicate()
	n2.reverse()
	var e2 := edges.duplicate()
	e2.reverse()
	var t2 := ToroidFlowLayout.layout(n2, e2, bin, bout)
	var same := true
	for id in (t["nodes"] as Dictionary):
		if not (t["nodes"][id]["rect"] as Rect2).is_equal_approx(t2["nodes"][id]["rect"] as Rect2):
			same = false
	_ok(same and (t["ribbons"] as Array).size() == (t2["ribbons"] as Array).size(),
		"the same input in another order gives the same picture")
	var b: Rect2 = t["bounds"]
	var inside := true
	for rb in (t["ribbons"] as Array):
		for p in (rb["path"] as PackedVector2Array):
			if not b.grow(1.0).has_point(p):
				inside = false
	_ok(inside, "the bounds hold every ribbon")


func _test_spacing_and_budget() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var ids: Array = []
	for i in 200:
		ids.append("n%03d" % i)
	var edges: Array = []
	for i2 in 200:
		edges.append({"id": "c%d" % i2, "a": ids[i2], "b": ids[(i2 + 1) % 200], "value": rng.randf_range(1.0, 9.0),
			"key": "electricity" if i2 % 9 == 0 else "water"})
	for k in 160:
		var x := rng.randi_range(0, 199)
		var y := rng.randi_range(0, 199)
		if x != y:
			edges.append({"id": "x%d" % k, "a": ids[x], "b": ids[y], "value": rng.randf_range(0.5, 5.0),
				"key": ["water", "food", "electricity"][k % 3]})
	var t0 := Time.get_ticks_msec()
	var r := ToroidFlowLayout.layout(_n(ids), edges)
	var ms := Time.get_ticks_msec() - t0
	_ok((r["nodes"] as Dictionary).size() == 200, "200 nodes laid out")
	_ok(ms < 2500, "200 nodes and 360 flows within the budget (%d ms)" % ms)
	var closest := INF
	var cs: Array = []
	for id in (r["nodes"] as Dictionary):
		cs.append(_centre(r, str(id)))
	for i3 in cs.size():
		for j in range(i3 + 1, cs.size()):
			closest = minf(closest, (cs[i3] as Vector2).distance_to(cs[j] as Vector2))
	_ok(closest > 20.0, "no two nodes on one spot (closest %.1f)" % closest)
	var finite := true
	for rb in (r["ribbons"] as Array):
		for p in (rb["path"] as PackedVector2Array):
			if is_nan(p.x) or is_nan(p.y) or is_inf(p.x) or is_inf(p.y):
				finite = false
	_ok(finite, "every ribbon path is finite")
	# A flow from one lobe to the other goes round an end of the trunk.
	var ax: Dictionary = r["axis"]
	var crossers := 0
	var through := 0
	for rb2 in (r["ribbons"] as Array):
		if str(rb2["a"]) == "" or str(rb2["b"]) == "":
			continue
		var na: Dictionary = r["nodes"][str(rb2["a"])]
		var nb: Dictionary = r["nodes"][str(rb2["b"])]
		if int(na["side"]) * int(nb["side"]) != -1:
			continue
		crossers += 1
		var p2: PackedVector2Array = rb2["path"]
		for i4 in range(1, p2.size()):
			if (p2[i4 - 1].x <= 0.0) != (p2[i4].x <= 0.0):
				var yx := (p2[i4 - 1].y + p2[i4].y) * 0.5
				if yx > float(ax["y0"]) and yx < float(ax["y1"]):
					through += 1
	_ok(crossers > 0 and through == 0, "flows between the lobes go round the trunk, not through it (%d of %d through)" % [through, crossers])


func _test_wire_path() -> void:
	var way := PackedVector2Array([Vector2(0.0, 0.0), Vector2(60.0, 100.0), Vector2(70.0, 200.0), Vector2(10.0, 300.0)])
	var bez := LoopSankeyLayout.wire_path(way, "bezier")
	var mono := true
	var hits := 0
	var lo := INF
	var hi := -INF
	for i in bez.size():
		if i > 0 and bez[i].y <= bez[i - 1].y:
			mono = false
		lo = minf(lo, bez[i].x)
		hi = maxf(hi, bez[i].x)
		for w in way:
			if bez[i].distance_to(w) < 0.01:
				hits += 1
	_ok(mono and hits == 4, "the smooth wire passes every waypoint, always heading down")
	_ok(lo >= -0.01 and hi <= 70.01, "and never swings past them (%.1f..%.1f)" % [lo, hi])
	var met := LoopSankeyLayout.wire_path(way, "metro")
	var metro_ok := true
	for i2 in range(1, met.size()):
		var d := met[i2] - met[i2 - 1]
		if d.length() < 0.01:
			continue
		if not (absf(d.x) < 0.01 or absf(absf(d.x) - absf(d.y)) < 0.01):
			metro_ok = false
	_ok(metro_ok, "a metro wire is only vertical and 45 degree runs")
	var orth := LoopSankeyLayout.wire_path(PackedVector2Array([Vector2(0.0, 0.0), Vector2(80.0, 100.0)]), "orthogonal")
	var has_flat := false
	for i3 in range(1, orth.size()):
		if absf(orth[i3].y - orth[i3 - 1].y) < 0.01 and absf(orth[i3].x - orth[i3 - 1].x) > 10.0:
			has_flat = true
	_ok(has_flat and orth[0] == Vector2(0.0, 0.0) and orth[orth.size() - 1] == Vector2(80.0, 100.0),
		"an orthogonal wire goes down, across, down")
	var nodes := _n(["a", "b", "c"])
	var edges := [_e("a", "b", 10.0), _e("b", "c", 10.0), _e("c", "a", 2.0), _e("a", "c", 3.0)]
	var same_nodes := true
	var a := LoopSankeyLayout.layout(nodes, edges, [], [], {"wire": "bezier"})
	var o := LoopSankeyLayout.layout(nodes, edges, [], [], {"wire": "orthogonal"})
	for id in (a["nodes"] as Dictionary):
		if (a["nodes"][id]["rect"] as Rect2) != (o["nodes"][id]["rect"] as Rect2):
			same_nodes = false
	_ok(same_nodes and (_rib(a, "c>a")["path"] as PackedVector2Array) != (_rib(o, "c>a")["path"] as PackedVector2Array),
		"the wire style reshapes the ribbons and leaves the nodes where they are")


func _test_pins() -> void:
	var r := _engine()
	_ok(is_same(LoopSankeyLayout.apply_pins(r, {}), r), "no pins: the layout itself comes back")
	var want := _centre(r, "pump") + Vector2(120.0, -40.0)
	var before_work: PackedVector2Array = _rib(r, "battery>pump")["path"]
	var before_other: PackedVector2Array = _rib(r, "panel>battery")["path"]
	var m := LoopSankeyLayout.apply_pins(r, {"pump": want, "gone": Vector2.ZERO})
	_ok(_centre(m, "pump").distance_to(want) < 0.01 and bool(m["nodes"]["pump"].get("pinned", false)),
		"a pinned node stands where it was dragged")
	var after_work: PackedVector2Array = _rib(m, "battery>pump")["path"]
	_ok(after_work[0].distance_to(before_work[0]) < 0.01 \
		and after_work[after_work.size() - 1].distance_to(before_work[before_work.size() - 1] + Vector2(120.0, -40.0)) < 0.01,
		"its ribbons follow: the far end stays, the near end moves with it")
	_ok((_rib(m, "panel>battery")["path"] as PackedVector2Array) == before_other \
		and _centre(r, "pump").distance_to(want) > 100.0, "nothing else moves, and the source layout is untouched")
	var m2 := LoopSankeyLayout.apply_pins(r, {"lamp": _centre(r, "lamp") + Vector2(70.0, 0.0)})
	var heat_before: PackedVector2Array = PackedVector2Array()
	var heat_after: PackedVector2Array = PackedVector2Array()
	for rb in (r["ribbons"] as Array):
		if str(rb["kind"]) == LoopSankeyLayout.KIND_OUT and str(rb["a"]) == "lamp":
			heat_before = rb["path"]
	for rb2 in (m2["ribbons"] as Array):
		if str(rb2["kind"]) == LoopSankeyLayout.KIND_OUT and str(rb2["a"]) == "lamp":
			heat_after = rb2["path"]
	_ok(heat_after.size() > 0 and heat_after[heat_after.size() - 1].distance_to(heat_before[heat_before.size() - 1] + Vector2(70.0, 0.0)) < 0.01,
		"a boundary flow moves whole with its node")
	_ok((m["bounds"] as Rect2).grow(1.0).has_point(want), "the bounds grow to hold the moved node")
