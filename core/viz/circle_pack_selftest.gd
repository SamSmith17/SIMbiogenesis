extends SceneTree

## CirclePack + CirclePackSources selftest (offline). Pins the layout's
## geometry (every child inside its parent with the padding, no two siblings
## overlapping, a leaf's AREA proportional to its value, the root at RADIUS),
## the enclosing circle by hand, determinism, dropping empty leaves and
## groups, colour inheritance, path_to / leaf_count, a big tree's time, and
## the sources (composition sums to the quantity and splits into elements,
## the graph tree nests groups and an array's strings, parts by material).
##
## Carries EXPECTED_CHECKS: a runtime error aborts the enclosing test
## function while the suite still prints PASS.
##   godot --headless --path . --script core/viz/circle_pack_selftest.gd

const EXPECTED_CHECKS := 26

var _checks := 0
var _fails := 0


func _init() -> void:
	_test_enclose()
	_test_geometry()
	_test_drops_and_colours()
	_test_big()
	_test_composition()
	_test_graph()
	_test_parts()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		print("FAIL check count %d != EXPECTED_CHECKS %d (a test function aborted?)" % [_checks, EXPECTED_CHECKS])
	print("CIRCLE PACK SELFTEST %s  (%d checks, %d failed)" % ["PASS" if _fails == 0 else "FAIL", _checks, _fails])
	quit(0 if _fails == 0 else 1)


func _ok(cond: bool, what: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		print("FAIL ", what)


func _tree(seed: int, n_groups: int, per: int) -> Dictionary:
	var kids: Array = []
	var s := seed
	for g in n_groups:
		var leaves: Array = []
		for k in per:
			s = (s * 1103515245 + 12345) % 2147483648
			leaves.append({"id": "g%d_l%d" % [g, k], "name": "leaf %d" % k, "value": 1.0 + float(s % 1000) / 37.0})
		if g % 3 == 0:
			leaves.append({"id": "g%d_sub" % g, "name": "sub", "children": [
				{"id": "g%d_s0" % g, "value": 3.0}, {"id": "g%d_s1" % g, "value": 5.0}, {"id": "g%d_s2" % g, "value": 1.0}]})
		kids.append({"id": "g%d" % g, "name": "group %d" % g, "children": leaves})
	return {"id": "root", "name": "root", "children": kids}


func _test_enclose() -> void:
	var e := CirclePack.enclose([{"x": -3.0, "y": 0.0, "r": 1.0}, {"x": 4.0, "y": 0.0, "r": 2.0}])
	_ok(is_equal_approx(float(e["r"]), (7.0 + 1.0 + 2.0) / 2.0), "two circles: r = (d + r1 + r2) / 2 (%.4f)" % float(e["r"]))
	var cs: Array = []
	for i in 9:
		cs.append({"x": cos(i * 0.7) * 10.0, "y": sin(i * 1.3) * 6.0, "r": 1.0 + float(i % 3)})
	var e2 := CirclePack.enclose(cs)
	var inside := true
	var touching := 0
	for c in cs:
		var d := Vector2(float(c["x"]) - float(e2["x"]), float(c["y"]) - float(e2["y"])).length() + float(c["r"])
		if d > float(e2["r"]) + 1e-6:
			inside = false
		if absf(d - float(e2["r"])) < 1e-4:
			touching += 1
	_ok(inside and touching >= 2, "the enclosing circle holds them all and touches at least two (%d)" % touching)
	var sib: Array = []
	for i in 30:
		sib.append({"x": 0.0, "y": 0.0, "r": 1.0 + float(i % 7) * 0.4})
	var r := CirclePack.pack_siblings(sib)
	var over := 0
	for a in sib.size():
		for b in range(a + 1, sib.size()):
			var dd := Vector2(float(sib[a]["x"]) - float(sib[b]["x"]), float(sib[a]["y"]) - float(sib[b]["y"])).length()
			if dd < float(sib[a]["r"]) + float(sib[b]["r"]) - 1e-6:
				over += 1
	_ok(over == 0, "30 packed siblings never overlap")
	var area := 0.0
	for c in sib:
		area += PI * float(c["r"]) * float(c["r"])
	var dens := area / (PI * r * r)
	_ok(dens > 0.5 and dens < 0.92, "front-chain packing is dense (%.2f of the enclosing circle)" % dens)
	var three: Array = [{"x": 0.0, "y": 0.0, "r": 1.0}, {"x": 0.0, "y": 0.0, "r": 1.0}, {"x": 0.0, "y": 0.0, "r": 1.0}]
	_ok(is_equal_approx(CirclePack.pack_siblings(three), 1.0 + 2.0 / sqrt(3.0)), "three equal circles: r = 1 + 2/√3 exactly")


func _test_geometry() -> void:
	var lay := CirclePack.layout(_tree(7, 9, 8), {"padding": 6.0})
	var nodes: Array = lay["nodes"]
	_ok(is_equal_approx(float(nodes[0]["r"]), CirclePack.RADIUS) and nodes[0]["x"] == 0.0, "the root sits at the origin with RADIUS")
	var outside := 0
	var overlap := 0
	for i in nodes.size():
		var n: Dictionary = nodes[i]
		var kids: PackedInt32Array = n["kids"]
		for k in kids:
			var c: Dictionary = nodes[k]
			var d := Vector2(float(c["x"]) - float(n["x"]), float(c["y"]) - float(n["y"])).length()
			if d + float(c["r"]) > float(n["r"]) + 1e-6:
				outside += 1
		for a in kids.size():
			for b in range(a + 1, kids.size()):
				var ca: Dictionary = nodes[kids[a]]
				var cb: Dictionary = nodes[kids[b]]
				var dd := Vector2(float(ca["x"]) - float(cb["x"]), float(ca["y"]) - float(cb["y"])).length()
				if dd < float(ca["r"]) + float(cb["r"]) + 6.0 * 0.999:
					overlap += 1
	_ok(outside == 0, "every child sits inside its parent")
	_ok(overlap == 0, "siblings keep the padding between them")
	var ratio_min := INF
	var ratio_max := 0.0
	for n2 in nodes:
		if bool(n2["leaf"]):
			var q := float(n2["r"]) * float(n2["r"]) / float(n2["value"])
			ratio_min = minf(ratio_min, q)
			ratio_max = maxf(ratio_max, q)
	_ok(ratio_max / ratio_min < 1.0 + 1e-9, "a leaf's area is proportional to its value")
	var lay2 := CirclePack.layout(_tree(7, 9, 8), {"padding": 6.0})
	var same := true
	for i in nodes.size():
		if float(nodes[i]["x"]) != float(lay2["nodes"][i]["x"]) or float(nodes[i]["r"]) != float(lay2["nodes"][i]["r"]):
			same = false
	_ok(same, "the layout is deterministic")
	var g0: Dictionary = nodes[int(lay["index"]["g0"])]
	var sum := 0.0
	for k in (g0["kids"] as PackedInt32Array):
		sum += float(nodes[k]["value"])
	_ok(is_equal_approx(float(g0["value"]), sum), "a group's value is the sum of its children")
	var path := CirclePack.path_to(nodes, int(lay["index"]["g0_s1"]))
	_ok(path.size() == 4 and path[0] == 0, "path_to runs root → group → sub → leaf")
	_ok(CirclePack.leaf_count(nodes, int(lay["index"]["g0"])) == 8 + 3, "leaf_count counts every leaf below")


func _test_drops_and_colours() -> void:
	var t := {"id": "r", "children": [
		{"id": "a", "children": [{"id": "a1", "value": 2.0}, {"id": "a0", "value": 0.0}]},
		{"id": "b", "children": [{"id": "b0", "value": 0.0}]},
		{"id": "c", "value": 1.0, "color": Color.RED}]}
	var lay := CirclePack.layout(t)
	var idx: Dictionary = lay["index"]
	_ok(not idx.has("a0") and not idx.has("b") and int(lay["hidden"]) == 3, "empty leaves and emptied groups are dropped and counted")
	var nodes: Array = lay["nodes"]
	_ok((nodes[idx["c"]]["color"] as Color).is_equal_approx(Color.RED), "a node's own colour is kept")
	_ok((nodes[idx["a1"]]["color"] as Color).is_equal_approx(nodes[idx["a"]]["color"]), "a child takes its group's colour")
	_ok(CirclePack.layout({"id": "x", "children": []})["nodes"].is_empty(), "an empty tree lays out as nothing")


func _test_big() -> void:
	var t0 := Time.get_ticks_msec()
	var lay := CirclePack.layout(_tree(3, 60, 40), {"padding": 4.0})
	var ms := Time.get_ticks_msec() - t0
	print("circle pack: %d nodes laid out in %d ms" % [(lay["nodes"] as Array).size(), ms])
	_ok((lay["nodes"] as Array).size() > 2500 and ms < 1500, "2,500 nodes lay out in under 1.5 s (%d ms)" % ms)


func _test_composition() -> void:
	var t := CirclePackSources.composition("urine", 10.0)
	var lay := CirclePack.layout(t)
	_ok(not (lay["nodes"] as Array).is_empty(), "urine's make-up lays out")
	_ok(absf(float(lay["total"]) - 10.0) < 1e-6, "its components and elements add up to the quantity (%.6f)" % float(lay["total"]))
	var has_n := false
	for n in lay["nodes"]:
		if str(n["name"]) == "Nitrogen" and int(n["depth"]) == 2:
			has_n = true
	_ok(has_n, "a component splits into elements (nitrogen in urine)")


func _test_graph() -> void:
	var m := GraphModel.new()
	m.add_item({"id": "p1", "type": "panel", "scope_id": "root", "specs": {"name": "Panel", "wmp": 400.0}})
	m.add_item({"id": "g", "type": "compound", "scope_id": "root", "child_scope_id": "s_g", "specs": {"name": "Camp"}})
	m.ensure_scope("s_g", "root", "g", "Camp")
	m.add_item({"id": "b1", "type": "battery", "scope_id": "s_g", "specs": {"name": "Bank", "capacity_kwh": 5.0}})
	m.add_item({"id": "l1", "type": "appliance", "scope_id": "s_g", "specs": {"name": "Fridge", "max_watts": 150.0}})
	m.add_item({"id": "arr", "type": "compound", "scope_id": "root", "child_scope_id": "s_arr",
		"specs": {"name": "Array", "compound_kind": "array", "array_generated": true, "array_interior": "panels"}})
	m.ensure_scope("s_arr", "root", "arr", "Array")
	for i in 6:
		m.add_item({"id": "ap%d" % i, "type": "panel", "scope_id": "s_arr",
			"specs": {"name": "P%d" % i, "wmp": 300.0, "array_panel": i, "array_string": i / 3}})
	var t := CirclePackSources.graph(m, "root", CirclePackSources.SIZE_COUNT)
	var lay := CirclePack.layout(t)
	var idx: Dictionary = lay["index"]
	_ok(idx.has("g") and idx.has("b1") and int(lay["nodes"][idx["b1"]]["depth"]) == 2, "a group holds what is inside it")
	_ok(idx.has("arr:string0") and idx.has("arr:string1") and int(lay["nodes"][idx["ap4"]]["parent"]) == int(idx["arr:string1"]),
		"an array's panels sit in their strings")
	var tp := CirclePackSources.graph(m, "root", CirclePackSources.SIZE_POWER)
	var lp := CirclePack.layout(tp)
	_ok(absf(float(lp["total"]) - (400.0 + 150.0 + 6.0 * 300.0)) < 1e-6 and not (lp["index"] as Dictionary).has("b1"),
		"by rated power: the watts add up and the battery (no rating) is left out")


func _test_parts() -> void:
	var rec := {"id": "fp1", "model_id": "flatpack_furniture", "flatpack_spec": FlatpackPresets.builtins()[0]["spec"]}
	var pl := BuiltStock.parts_of_record(rec)
	_ok(pl.size() > 3, "a flat-pack design lists its parts (%d)" % pl.size())
	var t := CirclePackSources.parts(rec)
	var lay := CirclePack.layout(t)
	var o := BuiltStock.of_record(rec)
	_ok(absf(float(lay["total"]) - float(o["kg"])) < 1e-6, "its parts weigh what the built stock says (%.3f kg)" % float(lay["total"]))
