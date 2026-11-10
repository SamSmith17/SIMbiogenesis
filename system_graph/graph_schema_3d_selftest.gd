extends SceneTree

## GraphSchema3D + GraphView3D (offline): the ring seen as nested spheres
## (machines on the outer sphere, stores on the inner, people at the centre,
## spaced so no two cards share a spot, each system a band, stores toward
## their machines) and as a torus (machines round the outer circumference in
## the flat ring's order, stores on the inner equator, people in the hole;
## from straight above it IS the flat ring). The projection, the connectors
## bowing inward, and the view: blend in / out, orbit, depth order, state.
##
##   Godot --headless --path . --script system_graph/graph_schema_3d_selftest.gd

const EXPECTED_CHECKS := 41

var _checks := 0
var _fails := 0


class FakeModel:
	extends RefCounted
	var struct_rev := 1
	var user_rev := 1
	var items: Array = []
	var conns: Array = []

	func get_items_in_scope(_s: String) -> Array:
		return items

	func get_connections_in_scope(_s: String) -> Array:
		return conns


func _initialize() -> void:
	var g := _settlement()
	var items: Array = g["items"]
	var conns: Array = g["conns"]
	var side := Callable(self, "_port_side")
	_test_sphere(items, conns, side)
	_test_torus(items, conns, side)
	_test_projection()
	_test_view(items, conns)
	var ok := _fails == 0 and _checks == EXPECTED_CHECKS
	if _checks != EXPECTED_CHECKS:
		print("  FAIL: ran %d checks, expected %d" % [_checks, EXPECTED_CHECKS])
	print("SCHEMA 3D SELFTEST %s  (%d checks, %d failed)" % ["PASS" if ok else "FAIL", _checks, _fails])
	quit(0 if ok else 1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_fails += 1
		print("  FAIL: %s  %s" % [label, detail])


func _port_side(_item: Dictionary, handle_id: String) -> float:
	if handle_id.begins_with("res_in") or handle_id == "input" or handle_id == "power_in":
		return 0.0
	if handle_id.begins_with("res_out") or handle_id == "output" or handle_id == "acOutput":
		return 1.0
	return NAN


func _item(iid: String, type: String, specs: Dictionary, w := 140.0, h := 110.0) -> Dictionary:
	return {"id": iid, "type": type, "x": 0.0, "y": 0.0, "width": w, "height": h, "specs": specs}


func _wire(a: String, b: String, kind: String, ah := "res_out_0", bh := "res_in_0") -> Dictionary:
	return {"id": "%s>%s" % [a, b], "source_item_id": a, "source_handle_id": ah, "target_item_id": b,
		"target_handle_id": bh, "polarity": "resource", "resource_type": kind}


## The schema selftest's settlement, with a few more machines so the
## sphere has a real lattice to spread.
func _settlement() -> Dictionary:
	var items: Array = [
		_item("ctl", "controller", {}), _item("bat", "battery", {}),
		_item("pv1", "panel", {}), _item("pv2", "panel", {}), _item("inv", "acload", {}),
		_item("cistern", "resource", {"resource_kind": "water"}, 90.0, 100.0),
		_item("filter", "processor", {}), _item("potable", "resource", {"resource_kind": "water"}, 90.0, 100.0),
		_item("hab", "processor", {"role": "habitat"}, 150.0, 150.0),
		_item("grey", "resource", {"resource_kind": "greywater"}, 90.0, 100.0),
		_item("gfilter", "processor", {}),
		_item("pantry", "resource", {"resource_kind": "food"}, 90.0, 100.0),
		_item("bed", "processor", {}), _item("bed2", "processor", {}),
		_item("nutr", "resource", {"resource_kind": "nutrients"}, 90.0, 100.0),
		_item("compost", "processor", {}),
		_item("gas", "resource", {"resource_kind": "woodgas"}, 90.0, 100.0), _item("genset", "processor", {}),
		_item("reactor", "processor", {}),
	]
	for i in items.size():
		(items[i] as Dictionary)["x"] = float(i % 4) * 160.0
		(items[i] as Dictionary)["y"] = float(i / 4) * 140.0
	var conns: Array = [
		{"id": "ctl>bat", "source_item_id": "ctl", "source_handle_id": "batteryPositive",
			"target_item_id": "bat", "target_handle_id": "positive", "polarity": "positive"},
		_wire("cistern", "filter", "water", "output"), _wire("filter", "potable", "water", "res_out_0", "input"),
		_wire("potable", "hab", "water", "output"), _wire("hab", "grey", "greywater", "res_out_0", "input"),
		_wire("grey", "gfilter", "greywater", "output"),
		_wire("pantry", "hab", "food", "output", "res_in_1"),
		_wire("cistern", "bed", "water", "output"), _wire("nutr", "bed", "nutrients", "output", "res_in_1"),
		_wire("bed", "pantry", "food", "res_out_0", "input"), _wire("bed2", "pantry", "food", "res_out_0", "input"),
		_wire("compost", "nutr", "nutrients", "res_out_0", "input"),
		_wire("reactor", "gas", "woodgas", "res_out_0", "input"),
		_wire("gas", "genset", "woodgas", "output"),
	]
	return {"items": items, "conns": conns}


func _role_ids(res: Dictionary, role: String) -> Array:
	var out: Array = []
	var rl: Dictionary = res["role"]
	for iid in rl:
		if str(rl[iid]) == role:
			out.append(iid)
	return out


func _min_dist(pos: Dictionary, ids: Array) -> float:
	var m := INF
	for i in ids.size():
		for j in range(i + 1, ids.size()):
			m = minf(m, (pos[ids[i]] as Vector3).distance_to(pos[ids[j]] as Vector3))
	return m


func _test_sphere(items: Array, conns: Array, side: Callable) -> void:
	var res := GraphSchema3D.layout(GraphSchema3D.SPHERE, items, conns, side, {"spacing": 40.0})
	var pos: Dictionary = res["pos"]
	_check("sphere: every node placed", pos.size() == items.size(), "%d of %d" % [pos.size(), items.size()])
	var sh: Array = res["shells"]
	var r_out := float((sh[0] as Dictionary)["r"])
	var r_in := float((sh[1] as Dictionary)["r"])
	var outer := _role_ids(res, "outer")
	var inner := _role_ids(res, "inner")
	var on_out := true
	for iid in outer:
		on_out = on_out and absf((pos[iid] as Vector3).length() - r_out) < 0.5
	_check("sphere: machines on the outer sphere", on_out and outer.size() == 11, "%d machines" % outer.size())
	var on_in := true
	for iid2 in inner:
		on_in = on_in and absf((pos[iid2] as Vector3).length() - r_in) < 0.5
	_check("sphere: stores on the inner sphere", on_in and inner.size() == 7, "%d stores" % inner.size())
	_check("sphere: the people at the centre", (pos["hab"] as Vector3).length() < 0.5)
	_check("sphere: the membrane well outside the nucleus", r_out >= r_in * 1.7, "%.0f vs %.0f" % [r_out, r_in])
	# Cards are ~180 px across: neighbours on the membrane no closer.
	var md := _min_dist(pos, outer)
	_check("sphere: no two machines share a spot", md >= 140.0, "closest %.0f px" % md)
	var md2 := _min_dist(pos, inner)
	_check("sphere: no two stores share a spot", md2 >= 100.0, "closest %.0f px" % md2)
	# The cistern feeds the filter and the bed: it sits on their side.
	var toward := ((pos["filter"] as Vector3).normalized() + (pos["bed"] as Vector3).normalized()).normalized()
	_check("sphere: a store faces the machines it is wired to",
		(pos["cistern"] as Vector3).normalized().dot(toward) > 0.5)
	# Each system a band: the power machines closer to each other than to
	# the rest on average.
	var pw: Array = ["ctl", "pv1", "pv2", "inv"]
	var within := 0.0
	var nw := 0
	var across := 0.0
	var na := 0
	for a in pw:
		for b in outer:
			if a == b:
				continue
			var dd := (pos[a] as Vector3).distance_to(pos[b] as Vector3)
			if pw.has(b):
				within += dd
				nw += 1
			else:
				across += dd
				na += 1
	_check("sphere: a system holds one band of the membrane", within / float(nw) < across / float(na),
		"%.0f within vs %.0f across" % [within / float(nw), across / float(na)])
	var res2 := GraphSchema3D.layout(GraphSchema3D.SPHERE, items, conns, side, {"spacing": 40.0})
	_check("sphere: deterministic", str(res2["pos"]) == str(pos))
	# The lattice itself: unit vectors, evenly spread for any count.
	var ok_unit := true
	var lat: Array = []
	for i in 200:
		var v := GraphSchema3D.fibonacci_dir(i, 200)
		ok_unit = ok_unit and absf(v.length() - 1.0) < 1e-4
		lat.append(v)
	var mn := INF
	for i2 in lat.size():
		for j in range(i2 + 1, lat.size()):
			mn = minf(mn, (lat[i2] as Vector3).distance_to(lat[j] as Vector3))
	# Even spread of 200: mean spacing ~ sqrt(4 pi / 200) = 0.25.
	_check("fibonacci: unit vectors spread evenly", ok_unit and mn > 0.15, "closest %.3f" % mn)


func _test_torus(items: Array, conns: Array, side: Callable) -> void:
	var res := GraphSchema3D.layout(GraphSchema3D.TORUS, items, conns, side, {"spacing": 40.0})
	var pos: Dictionary = res["pos"]
	_check("torus: every node placed", pos.size() == items.size())
	var sd: Dictionary = (res["shells"] as Array)[0]
	var big_r := float(sd["R"])
	var a := float(sd["a"])
	var outer_side := true
	for iid in _role_ids(res, "outer"):
		var p: Vector3 = pos[iid]
		outer_side = outer_side and Vector2(p.x, p.z).length() >= big_r - 0.5
	_check("torus: machines round the outer circumference", outer_side)
	var inner_eq := true
	for iid2 in _role_ids(res, "inner"):
		var p2: Vector3 = pos[iid2]
		# One row on the inner equator, or two either side of it.
		var rad := Vector2(p2.x, p2.z).length()
		inner_eq = inner_eq and rad <= big_r - a * 0.85 and rad >= big_r - a - 0.5 and absf(p2.y) <= a * 0.5
	_check("torus: stores on the inner equator, facing the hole", inner_eq)
	_check("torus: the people in the hole", (pos["hab"] as Vector3).length() < 0.5)
	# From straight above, machines run round in the flat ring's order.
	var ordered: Array = []
	for gd in (res["groups"] as Array):
		ordered.append_array((gd as Dictionary)["ids"])
	var prev := -INF
	var mono := true
	for iid3 in ordered:
		var s := GraphSchema3D.project(pos[iid3] as Vector3, 0.0, PI * 0.5, 1e6)
		var ang := atan2(s.y, s.x)
		while ang < prev - 0.01:
			ang += TAU
		mono = mono and ang >= prev - 0.01
		prev = ang
	_check("torus: from above, the machines keep the ring's order", mono and prev < -PI * 0.5 + TAU + 0.01)
	var md := _min_dist(pos, _role_ids(res, "outer"))
	_check("torus: no two machines share a spot", md >= 100.0, "closest %.0f px" % md)
	var md2 := _min_dist(pos, _role_ids(res, "inner"))
	_check("torus: no two stores share a spot", md2 >= 80.0, "closest %.0f px" % md2)


func _test_projection() -> void:
	var p := Vector3(120.0, -40.0, 75.0)
	var ok := true
	for y in [0.0, 0.7, -2.1]:
		for pt in [0.0, 0.5, -1.2]:
			ok = ok and absf(GraphSchema3D.rotate(p, float(y), float(pt)).length() - p.length()) < 1e-3
	_check("projection: turning keeps distances", ok)
	_check("projection: nearer is bigger", GraphSchema3D.persp(0.0, 100.0) == 1.0
		and GraphSchema3D.persp(30.0, 100.0) > 1.0 and GraphSchema3D.persp(-30.0, 100.0) < 1.0)
	var th := 0.83
	var s := GraphSchema3D.project(GraphSchema3D.torus_point(200.0, 0.0, th, 0.0), 0.0, PI * 0.5, 1e9)
	_check("projection: a torus from above is the flat ring",
		Vector2(s.x, s.y).distance_to(Vector2(cos(th), sin(th)) * 200.0) < 0.05)
	var a := Vector3(300.0, 0.0, 0.0)
	var b := Vector3(0.0, 0.0, 300.0)
	var cp := GraphSchema3D.connector_points(a, b, 0.6, 16)
	_check("connector: ends on its two nodes",
		cp[0].distance_to(a) < 1e-3 and cp[cp.size() - 1].distance_to(b) < 1e-3)
	_check("connector: bows through the inside", cp[8].length() < ((a + b) * 0.5).length() * 0.75)
	# Torus: two neighbours on the outer equator, the wire runs inside the
	# tube (closer to the core circle than the straight chord).
	var ta := GraphSchema3D.torus_point(400.0, 100.0, 0.2, 0.0)
	var tb := GraphSchema3D.torus_point(400.0, 100.0, 0.9, 0.0)
	var tp := GraphSchema3D.connector_points_torus(ta, tb, 400.0, 0.8, 16)
	var core_d := func(p3: Vector3) -> float:
		return Vector2(Vector2(p3.x, p3.z).length() - 400.0, p3.y).length()
	_check("torus connector: runs inside the tube", float(core_d.call(tp[8])) < float(core_d.call((ta + tb) * 0.5)) * 0.7
		and tp[0].distance_to(ta) < 1e-3 and tp[16].distance_to(tb) < 1e-3)
	# The hole stays open: half the ring across.
	_check("torus: an open hole", GraphSchema3D.TUBE_SHARE <= 0.26)


func _test_view(items: Array, conns: Array) -> void:
	var m := FakeModel.new()
	m.items = items
	m.conns = conns
	var v := GraphView3D.new()
	v.set_mode(GraphSchema3D.SPHERE, true, "root")
	v.ensure(m, Callable(self, "_port_side"), 40.0)
	var flat := Rect2(Vector2(10, 20), Vector2(140, 110))
	_check("view: starts flat (blend 0)", v.rect_for("ctl", flat.position, flat.size, Vector2.ZERO, 1.0) == flat)
	for _i in 60:
		v.advance(1.0 / 30.0)
	var r3 := v.rect_for("ctl", flat.position, flat.size, Vector2.ZERO, 1.0)
	_check("view: eases into 3D", v.blend == 1.0 and r3 != flat)
	# Nearer node drawn bigger.
	var ids: Array = ["ctl", "pv1", "pv2", "inv", "filter", "gfilter", "bed", "bed2", "compost", "genset", "reactor"]
	var near_id := ""
	var far_id := ""
	var best := -INF
	var worst := INF
	for iid in ids:
		var z := v.depth_of(iid)
		if z > best:
			best = z
			near_id = iid
		if z < worst:
			worst = z
			far_id = iid
	var rn := v.rect_for(near_id, flat.position, flat.size, Vector2.ZERO, 1.0)
	var rf := v.rect_for(far_id, flat.position, flat.size, Vector2.ZERO, 1.0)
	_check("view: the near side drawn bigger and unfogged",
		rn.size.x > rf.size.x and v.fog_for(near_id) < v.fog_for(far_id))
	v.orbit_by(Vector2(0.0, 10.0))
	_check("view: orbit pitch stays inside its limit", absf(v.pitch) <= GraphSchema3D.PITCH_LIMIT + 1e-6)
	var st := v.state()
	var v2 := GraphView3D.new()
	v2.apply_state(st)
	_check("view: state round trip", v2.mode == GraphSchema3D.SPHERE and is_equal_approx(v2.yaw, v.yaw)
		and is_equal_approx(v2.pitch, v.pitch) and v2.blend == 1.0)
	v.set_mode("", true)
	_check("view: leaving reports flat at once", str(v.state()["mode"]) == "" and v.active())
	for _j in 60:
		v.advance(1.0 / 30.0)
	_check("view: eases out and forgets the layout", not v.active() and v.blend == 0.0)
	_test_drag(items, conns)


## Dragging a card over its shell: the pick lands under the pointer, the
## stored place is honoured by the layout (a placed store is not pushed
## by the relax), and the view keeps to the scope it was opened in.
func _test_drag(items: Array, conns: Array) -> void:
	var p := Vector3(80.0, -30.0, 140.0)
	_check("unrotate undoes rotate",
		GraphSchema3D.unrotate(GraphSchema3D.rotate(p, 0.7, -0.4), 0.7, -0.4).distance_to(p) < 1e-3)
	var m := FakeModel.new()
	m.items = items.duplicate(true)
	m.conns = conns
	var v := GraphView3D.new()
	v.set_mode(GraphSchema3D.SPHERE, false, "root")
	v.ensure(m, Callable(self, "_port_side"), 40.0)
	_check("view: the people in the middle are not dragged", not v.can_drag("hab") and v.can_drag("filter"))
	# A pointer a little off the filter's card, on the near side.
	var r0 := v.rect_for("filter", Vector2.ZERO, Vector2(140, 110), Vector2.ZERO, 1.0)
	var target := v.centre() + Vector2(0.0, 0.0) + (r0.get_center() - v.centre()) * 0.7
	var val: Variant = v.shell_value_at("filter", target, v.is_front("filter"))
	v.set_drag_value("filter", val)
	var r1 := v.rect_for("filter", Vector2.ZERO, Vector2(140, 110), Vector2.ZERO, 1.0)
	_check("sphere drag: the card lands under the pointer", r1.get_center().distance_to(target) < 1.0,
		"%.2f px off" % r1.get_center().distance_to(target))
	var r_out := float(((v.layout["shells"] as Array)[0] as Dictionary)["r"])
	_check("sphere drag: the card stays on its shell",
		absf(((v.layout["pos"] as Dictionary)["filter"] as Vector3).length() - r_out) < 0.5)
	v.end_drag()
	# Stored on the specs, the layout honours it.
	for it in m.items:
		if str((it as Dictionary)["id"]) == "filter":
			(it as Dictionary)["specs"] = {GraphSchema3D.SPEC_KEY: {"sphere": GraphSchema3D.override_to_array(val)}}
		if str((it as Dictionary)["id"]) == "cistern":
			(it as Dictionary)["specs"] = {"resource_kind": "water",
				GraphSchema3D.SPEC_KEY: {"sphere": [0.0, 1.0, 0.0]}}
	m.struct_rev += 1
	v.ensure(m, Callable(self, "_port_side"), 40.0)
	var fp: Vector3 = (v.layout["pos"] as Dictionary)["filter"]
	_check("sphere: a placed machine stays where it was put", fp.normalized().distance_to(val as Vector3) < 1e-3)
	var cp: Vector3 = (v.layout["pos"] as Dictionary)["cistern"]
	_check("sphere: a placed store is not pushed by the others", cp.normalized().distance_to(Vector3.DOWN * -1.0) < 1e-3)
	# Torus.
	var vt := GraphView3D.new()
	vt.set_mode(GraphSchema3D.TORUS, false, "root")
	vt.ensure(m, Callable(self, "_port_side"), 40.0)
	var rt := vt.rect_for("genset", Vector2.ZERO, Vector2(140, 110), Vector2.ZERO, 1.0)
	var tgt := rt.get_center() + Vector2(60.0, 25.0)
	var tv: Variant = vt.shell_value_at("genset", tgt, vt.is_front("genset"))
	vt.set_drag_value("genset", tv)
	var rt2 := vt.rect_for("genset", Vector2.ZERO, Vector2(140, 110), Vector2.ZERO, 1.0)
	_check("torus drag: the card lands near the pointer", tv is Vector2 and rt2.get_center().distance_to(tgt) < 8.0,
		"%.1f px off" % rt2.get_center().distance_to(tgt))
	vt.end_drag()
	# Scope: the view belongs to where it was opened.
	var st := vt.state()
	var v4 := GraphView3D.new()
	v4.apply_state({"mode": GraphSchema3D.TORUS, "scope": "scope_7"})
	_check("view: it belongs to its scope (and saves it)", str(st["scope"]) == "root" and v4.scope_id == "scope_7")
	_check("override: kept as plain arrays", GraphSchema3D.override_to_array(Vector2(1.0, 2.0)) == [1.0, 2.0]
		and GraphSchema3D.override_of({"specs": {GraphSchema3D.SPEC_KEY: {"torus": [1.0, 2.0]}}}, "torus") == Vector2(1.0, 2.0))
