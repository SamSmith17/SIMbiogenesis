extends SceneTree

## PvGridSnap (solar grid snap) + GraphPvWiring's string grid. Offline:
##   godot --headless --path . --script core/placed_models/pv_grid_snap_selftest.gd

const EXPECTED_CHECKS := 17

var _checks := 0
var _fails := 0


func _ok(cond: bool, what: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		print("  FAIL: ", what)


func _near(a: float, b: float, eps: float = 0.005) -> bool:
	return absf(a - b) <= eps


func _initialize() -> void:
	_test_row_snap()
	_test_yaw_lock()
	_test_pitch()
	_test_priority_and_radius()
	_test_grid_layout()
	_test_string_grid()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		print("  FAIL: ran %d checks, expected %d (a runtime error aborted a test?)" % [_checks, EXPECTED_CHECKS])
	print("PV GRID SNAP SELFTEST %s  (%d checks, %d failed)" % ["PASS" if _fails == 0 else "FAIL", _checks, _fails])
	quit(0 if _fails == 0 else 1)


func _rect(id: String, x: float, z: float, yaw: float = 0.0, w: float = 2.0, d: float = 1.0, key: String = "") -> Dictionary:
	return {"id": id, "key": key, "x": x, "z": z, "yaw": yaw, "w": w, "d": d, "h_top": 0.0}


func _test_row_snap() -> void:
	var res := PvGridSnap.snap(_rect("m", 2.3, 0.1), [_rect("n", 0.0, 0.0)], {"radius": 1.0, "gap": 0.02})
	_ok(bool(res["snapped"]) and str(res["kind"]) == "row", "a rack dropped beside another snaps into its row")
	_ok(_near(float(res["x"]), 2.02) and _near(float(res["z"]), 0.0), "edge to edge with the gap (x %.3f z %.3f)" % [res["x"], res["z"]])
	# Turned 90°: the row runs along world -Z (local +X = (cos90, -sin90)).
	var r2 := PvGridSnap.snap(_rect("m", 0.1, -2.2, 90.0), [_rect("n", 0.0, 0.0, 90.0)], {"radius": 1.0, "gap": 0.0})
	_ok(bool(r2["snapped"]) and _near(float(r2["x"]), 0.0) and _near(float(r2["z"]), -2.0),
		"the row follows the neighbour's yaw (x %.3f z %.3f)" % [r2["x"], r2["z"]])


func _test_yaw_lock() -> void:
	var a := PvGridSnap.snap(_rect("m", 2.1, 0.0, 8.0), [_rect("n", 0.0, 0.0)], {"radius": 1.0})
	_ok(bool(a["snapped"]) and _near(float(a["yaw"]), 0.0), "8° off locks to the neighbour's yaw")
	var b := PvGridSnap.snap(_rect("m", 2.1, 0.0, 20.0), [_rect("n", 0.0, 0.0)], {"radius": 1.0})
	_ok(not bool(b["snapped"]), "20° off does not snap")


func _test_pitch() -> void:
	# One portrait JA module (1.769 m), 30° tilt, at 48.3°N. Winter noon sun
	# 90 - 48.3 - 23.44 = 18.26°; pitch = L cos t + L sin t / tan(alt)
	# = 1.5320 + 0.8845 / 0.32993 = 4.2128 m front edge to front edge.
	var r := PvGridSnap.rect_for_pv_spec({"count": 1, "cols": 1, "tilt_deg": 30.0}, 0.0, 0.0, 0.0)
	_ok(_near(float(r["d"]), 1.769 * cos(deg_to_rad(30.0)), 0.001), "rack depth in plan")
	var p := PvGridSnap.row_pitch(r, r, {"lat": 48.3, "gap": 0.02})
	_ok(_near(p, 4.2128, 0.002), "auto row pitch at 48.3°N, 30° tilt (%.4f m)" % p)
	_ok(_near(PvGridSnap.winter_noon_altitude_deg(80.0), 10.0), "the winter sun floors at 10°")
	var forced := PvGridSnap.row_pitch(r, r, {"lat": 48.3, "row_pitch": 6.0})
	_ok(_near(forced, 6.0), "a forced pitch wins")
	var snapped := PvGridSnap.snap(_rect("m", 0.0, -4.0), [r], {"radius": 1.0, "lat": 48.3})
	var r_m := _rect("m", 0.0, -4.0)
	r_m["d"] = float(r["d"])
	r_m["h_top"] = float(r["h_top"])
	var s2 := PvGridSnap.snap(r_m, [r], {"radius": 1.0, "lat": 48.3})
	_ok(bool(s2["snapped"]) and str(s2["kind"]) == "behind" and _near(float(s2["z"]), -4.2128, 0.003),
		"a rack dropped behind lands at the no-shade pitch (z %.3f)" % s2["z"])
	_ok(snapped.has("snapped"), "snap returns a result shape")


func _test_priority_and_radius() -> void:
	var foreign := _rect("f", 0.0, 0.0, 0.0, 2.0, 1.0, "ctrl_b")
	var own := _rect("o", 4.6, 0.0, 0.0, 2.0, 1.0, "ctrl_a")
	# Moving sits 0.25 m from the foreign rack's slot and 0.35 m from its own
	# array's slot: the own array wins.
	var m := _rect("m", 2.27, 0.0, 0.0, 2.0, 1.0, "ctrl_a")
	var res := PvGridSnap.snap(m, [foreign, own], {"radius": 1.0, "gap": 0.02})
	_ok(str(res["target_id"]) == "o", "its own array's rack wins a near tie (%s)" % res["target_id"])
	var far := PvGridSnap.snap(_rect("m", 6.0, 3.0), [_rect("n", 0.0, 0.0)], {"radius": 1.0})
	_ok(not bool(far["snapped"]), "nothing in reach, no snap")


func _test_grid_layout() -> void:
	var anchor := _rect("a", 10.0, 5.0)
	var rects := [_rect("b", 0.0, 0.0), _rect("c", 30.0, 1.0), _rect("d", -4.0, 9.0)]
	var lay := PvGridSnap.grid_layout(anchor, rects, {"gap": 0.1}, 2)
	_ok(_near(float(lay["a"]["x"]), 10.0) and _near(float(lay["a"]["z"]), 5.0), "the anchor keeps its place")
	var boxes: Array = []
	for id in lay:
		boxes.append(Rect2(float(lay[id]["x"]) - 1.0, float(lay[id]["z"]) - 0.5, 2.0, 1.0))
	var overlap := false
	for i in boxes.size():
		for j in range(i + 1, boxes.size()):
			if (boxes[i] as Rect2).grow(-0.01).intersects(boxes[j] as Rect2):
				overlap = true
	var zs := {}
	for id in lay:
		zs[snappedf(float(lay[id]["z"]), 0.01)] = true
	_ok(not overlap and zs.size() == 2, "two per row: two rows, no overlap")


func _test_string_grid() -> void:
	var model := GraphModel.new()
	var ids: Array = []
	for i in 18:
		var id := "p%d" % i
		model.add_item({"id": id, "type": "panel", "x": float(i * 37 % 500), "y": float(i * 53 % 300),
			"width": 120.0, "height": 90.0, "scope_id": "root"})
		ids.append(id)
	model.add_item({"id": "ctrl", "type": "controller", "x": 0.0, "y": 600.0, "width": 160.0,
		"height": 104.0, "scope_id": "root"})
	GraphPvWiring.wire_series(model, ids.slice(0, 9), "ctrl", "root")
	GraphPvWiring.wire_series(model, ids.slice(9, 18), "ctrl", "root")
	var rows := GraphPvWiring.string_rows(model, ids, "root")
	_ok(rows.size() == 2 and (rows[0] as Array).size() == 9 and (rows[1] as Array).size() == 9,
		"9S×2P splits into two 9-panel strings")
	GraphPvWiring.layout_panels_grid(model, rows, 24.0, 28.0)
	var ys := {}
	var overlap := false
	var rs: Array = []
	for id in ids:
		var it := model.get_item(str(id))
		ys[float(it["y"])] = true
		rs.append(Rect2(float(it["x"]), float(it["y"]), 120.0, 90.0))
	for i in rs.size():
		for j in range(i + 1, rs.size()):
			if (rs[i] as Rect2).intersects(rs[j] as Rect2):
				overlap = true
	_ok(ys.size() == 2 and not overlap, "laid out as 2 rows × 9, no overlap")
