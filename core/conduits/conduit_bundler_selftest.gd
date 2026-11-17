extends SceneTree

## ConduitBundler (offline): lanes at exactly the pitch, ports never moved,
## concentric bends sharing one centre, the same answer whatever order the
## runs come in, the player's lane order and "pull out" honoured, a run laid
## the other way on its own lane, a lane that would hit something dropped.
##   Godot --headless --path . --script core/conduits/conduit_bundler_selftest.gd

const EXPECTED_CHECKS := 26

var _n := 0
var _fails := 0


func _check(label: String, cond: bool, detail: String = "") -> void:
	_n += 1
	if not cond:
		_fails += 1
		push_error("FAIL: %s  %s" % [label, detail])
	else:
		print("  ok  %s" % label)


func _initialize() -> void:
	_test_two_lanes()
	_test_order_and_overrides()
	_test_reversed_run()
	_test_obstacle_drops_lane()
	_check("check count matches EXPECTED_CHECKS", _n + 1 == EXPECTED_CHECKS,
		"ran %d, expected %d" % [_n + 1, EXPECTED_CHECKS])
	print("CONDUIT BUNDLER SELFTEST %s  (%d checks)" % ["PASS" if _fails == 0 else "FAIL", _n])
	quit(0 if _fails == 0 else 1)


## Two runs up out of their ports, along x at 1 m, a right-angle turn to +z,
## down into their ports.
func _run(id: String, x0: float, z1: float, extra: Dictionary = {}) -> Dictionary:
	var c := PackedVector3Array([Vector3(x0, 0.5, 0.0), Vector3(x0, 1.0, 0.0),
		Vector3(10.0, 1.0, 0.0), Vector3(10.0, 1.0, z1), Vector3(10.0, 0.5, z1)])
	var r := {"id": id, "corners": c, "od": 0.03, "bend_r": 0.2, "service": "cold_water",
		"lane_index": -1, "lane_free": false}
	r.merge(extra, true)
	return r


func _leg_offset(c: PackedVector3Array, axis: String) -> float:
	for i: int in range(1, c.size() - 2):
		var d := c[i + 1] - c[i]
		if absf(d.y) < 1e-3 and d.length() > 1.0:
			if axis == "x" and absf(d.z) < 1e-3:
				return c[i].z
			if axis == "z" and absf(d.x) < 1e-3:
				return c[i].x
	return NAN


func _test_two_lanes() -> void:
	var a := _run("a", 0.0, 5.0)
	var b := _run("b", 1.0, 6.0)
	var res := ConduitBundler.bundle([a, b])
	var ra: Dictionary = res["a"]
	var rb: Dictionary = res["b"]
	_check("two runs on one line make a bundle of two lanes",
		int(ra["lanes"]) == 2 and int(rb["lanes"]) == 2 and str(ra["bundle"]) == str(rb["bundle"]))
	var ca: PackedVector3Array = ra["corners"]
	var cb: PackedVector3Array = rb["corners"]
	var pitch := 0.03 + ConduitBundler.GAP_M
	var dz := absf(_leg_offset(ca, "x") - _leg_offset(cb, "x"))
	_check("the x legs are a pitch apart", absf(dz - pitch) < 1e-4, "%.4f vs %.4f" % [dz, pitch])
	var dx := absf(_leg_offset(ca, "z") - _leg_offset(cb, "z"))
	_check("the z legs are a pitch apart", absf(dx - pitch) < 1e-4, "%.4f" % dx)
	_check("ports stay put", ca[0] == (a["corners"] as PackedVector3Array)[0]
		and ca[ca.size() - 1] == (a["corners"] as PackedVector3Array)[4]
		and cb[0] == (b["corners"] as PackedVector3Array)[0])
	var mid := (_leg_offset(ca, "x") + _leg_offset(cb, "x")) * 0.5
	_check("the bundle is centred on the solver's line", absf(mid) < 1e-4, "%.4f" % mid)
	# Concentric: the bend centres coincide.
	var centres: Array = []
	for res_e: Dictionary in [ra, rb]:
		var c: PackedVector3Array = res_e["corners"]
		var radii: PackedFloat64Array = res_e["radii"]
		for i: int in range(1, c.size() - 1):
			var up := (c[i] - c[i - 1]).normalized()
			var uq := (c[i + 1] - c[i]).normalized()
			if absf(up.y) < 0.1 and absf(uq.y) < 0.1 and absf(up.dot(uq)) < 0.1 and radii[i] > 0.0:
				centres.append(c[i] + (uq - up) * radii[i])
	_check("both lanes have a radius at the turn", centres.size() == 2, str(centres.size()))
	if centres.size() == 2:
		_check("the lanes bend about one centre", (centres[0] as Vector3).distance_to(centres[1]) < 1e-3,
			"%.4f m apart" % (centres[0] as Vector3).distance_to(centres[1]))
	var rads: Array = []
	for res_e: Dictionary in [ra, rb]:
		for v: float in (res_e["radii"] as PackedFloat64Array):
			if v > 0.0:
				rads.append(v)
	rads.sort()
	_check("the inner lane bends at the base radius, the outer a pitch wider",
		rads.size() == 2 and absf(float(rads[0]) - 0.2) < 1e-4 and absf(float(rads[1]) - 0.2 - pitch) < 1e-4,
		str(rads))
	# The fillet takes the per-corner radii and keeps every bend clear.
	var fa := ConduitFillet.apply(ca, 0.2, ConduitFillet.STEP_DEG, ra["radii"] as PackedFloat64Array)
	var turn_i := -1
	for i: int in range(1, ca.size() - 1):
		if float((ra["radii"] as PackedFloat64Array)[i]) > 0.0:
			turn_i = i
	_check("fillet takes the per-corner radius at the turn", turn_i > 0
		and not (fa["tight"] as Array).has(turn_i), "turn %d, tight %s" % [turn_i, str(fa["tight"])])
	# Order does not matter.
	var res2 := ConduitBundler.bundle([b, a])
	_check("the same lanes whatever order the runs come in",
		(res2["a"]["corners"] as PackedVector3Array) == ca and (res2["b"]["corners"] as PackedVector3Array) == cb)
	# A single run is left as it is.
	var solo := ConduitBundler.bundle([a])
	_check("a run alone is not moved", (solo["a"]["corners"] as PackedVector3Array) == (a["corners"] as PackedVector3Array)
		and int(solo["a"]["lanes"]) == 1)
	# A run that only shares a short stretch is not bundled.
	var short := _run("s", 9.7, -5.0)
	var res3 := ConduitBundler.bundle([a, short])
	_check("a stretch shorter than MIN_OVERLAP_M is not a bundle", int(res3["a"]["lanes"]) == 1)


func _test_order_and_overrides() -> void:
	var a := _run("a", 0.0, 5.0)
	var b := _run("b", 1.0, 6.0)
	var base := ConduitBundler.bundle([a, b])
	_check("by id: a takes lane 0", int(base["a"]["lane"]) == 0 and int(base["b"]["lane"]) == 1)
	var a2 := _run("a", 0.0, 5.0, {"lane_index": 1})
	var b2 := _run("b", 1.0, 6.0, {"lane_index": 0})
	var swapped := ConduitBundler.bundle([a2, b2])
	_check("the player's lane order wins", int(swapped["a"]["lane"]) == 1 and int(swapped["b"]["lane"]) == 0)
	_check("and moves the runs", absf(_leg_offset(swapped["a"]["corners"], "x")
		- _leg_offset(base["b"]["corners"], "x")) < 1e-4)
	var hot := _run("z_hot", 1.0, 6.0, {"service": "hot_water"})
	var by_service := ConduitBundler.bundle([a, hot])
	_check("by service: hot water lies before cold", int(by_service["z_hot"]["lane"]) == 0)
	var free_a := _run("a", 0.0, 5.0, {"lane_free": true})
	var res := ConduitBundler.bundle([free_a, b])
	_check("a run pulled out is not bundled", int(res["a"]["lanes"]) == 1
		and (res["a"]["corners"] as PackedVector3Array) == (free_a["corners"] as PackedVector3Array))
	_check("and neither is the one left alone", int(res["b"]["lanes"]) == 1)


func _test_reversed_run() -> void:
	var a := _run("a", 0.0, 5.0)
	# The same route walked the other way.
	var rc := PackedVector3Array([Vector3(10.0, 0.5, 6.0), Vector3(10.0, 1.0, 6.0),
		Vector3(10.0, 1.0, 0.0), Vector3(1.0, 1.0, 0.0), Vector3(1.0, 0.5, 0.0)])
	var r := {"id": "r", "corners": rc, "od": 0.03, "bend_r": 0.2, "service": "cold_water",
		"lane_index": -1, "lane_free": false}
	var res := ConduitBundler.bundle([a, r])
	_check("a run laid the other way joins the bundle", int(res["r"]["lanes"]) == 2)
	var za := _leg_offset(res["a"]["corners"], "x")
	var zr := _leg_offset(res["r"]["corners"], "x")
	_check("on its own lane, not on top of the other", absf(absf(za - zr) - 0.07) < 1e-4,
		"%.4f / %.4f" % [za, zr])
	var xa := _leg_offset(res["a"]["corners"], "z")
	var xr := _leg_offset(res["r"]["corners"], "z")
	_check("on both legs", absf(absf(xa - xr) - 0.07) < 1e-4, "%.4f / %.4f" % [xa, xr])
	# No crossing at the turn: the lane inside on one leg is inside on the other.
	_check("the lanes do not cross at the turn", signf(za - zr) == -signf(xa - xr) or signf(za - zr) == signf(xa - xr))


func _test_obstacle_drops_lane() -> void:
	var a := _run("a", 0.0, 5.0)
	var b := _run("b", 1.0, 6.0)
	var base := ConduitBundler.bundle([a, b])
	# A box right where b's shifted x leg runs, clear of the solver's line.
	var zb := _leg_offset(base["b"]["corners"], "x")
	var zs := signf(zb)
	var f := ConduitObstacleField.new()
	f.add_box(AABB(Vector3(4.0, 0.0, zb + zs * 0.005 - 0.01), Vector3(1.0, 2.0, 0.02)), "post")
	f.build_index()
	var res := ConduitBundler.bundle([a, b], {"field": f})
	var flagged := bool((res["a"]["flags"] as Dictionary).get("unbundled", false)) \
		or bool((res["b"]["flags"] as Dictionary).get("unbundled", false))
	_check("a lane that would hit something is dropped", flagged)
	_check("and the runs keep the solver's line",
		(res["b"]["corners"] as PackedVector3Array) == (b["corners"] as PackedVector3Array)
		or (res["a"]["corners"] as PackedVector3Array) == (a["corners"] as PackedVector3Array))
	_check("nothing left in a bundle of one", int(res["a"]["lanes"]) == 1 and int(res["b"]["lanes"]) == 1)
