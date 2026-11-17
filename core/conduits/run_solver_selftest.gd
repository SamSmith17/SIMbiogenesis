extends SceneTree

## Offline: ConduitRunSolver + ConduitFillet + ConduitObstacleField.
##   Godot --headless --path . --script core/conduits/run_solver_selftest.gd

const EXPECTED_CHECKS := 35

var _checks := 0
var _failures := 0


func _initialize() -> void:
	ConduitStylePresets.clear_memory_for_tests()
	_test_field()
	_test_straight_and_stubs()
	_test_round_a_tall_box()
	_test_over_a_low_box()
	_test_round_a_building()
	_test_vias_keep_height()
	_test_determinism()
	_test_wall_hug()
	_test_stub_clears_host()
	_test_no_path_fallback()
	_test_fillet_geometry()
	_test_dispatch_points()
	_test_speed()
	var ok := _failures == 0 and _checks == EXPECTED_CHECKS
	if _checks != EXPECTED_CHECKS:
		print("  FAIL: ran %d checks, expected %d" % [_checks, EXPECTED_CHECKS])
	print("RUN SOLVER SELFTEST %s  (%d checks, %d failed)" % [
		"PASS" if ok else "FAIL", _checks, _failures])
	quit(0 if ok else 1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s %s" % [label, detail])


func _field(boxes: Array, prisms: Array = []) -> ConduitObstacleField:
	var f := ConduitObstacleField.new()
	for b: Variant in boxes:
		var arr: Array = b
		f.add_box(AABB(arr[0] as Vector3, (arr[1] as Vector3) - (arr[0] as Vector3)),
			str(arr[2]) if arr.size() > 2 else "")
	for p: Variant in prisms:
		var pr: Array = p
		f.add_prism(pr[0] as PackedVector2Array, float(pr[1]), float(pr[2]))
	f.build_index()
	return f


func _req(a: Vector3, na: Vector3, b: Vector3, nb: Vector3, f: ConduitObstacleField,
		extra: Dictionary = {}) -> Dictionary:
	var r := {"a": a, "b": b, "na": na, "nb": nb, "stub_a": 0.15, "stub_b": 0.15,
		"od": 0.04, "bend_r": 0.05, "field": f, "run_height": NAN}
	r.merge(extra, true)
	return r


## Every segment of a polyline clear of the field, grown by `c`.
func _clear(pts: PackedVector3Array, f: ConduitObstacleField, c: float) -> bool:
	var all := f.query_xz(Vector2(-1e4, -1e4), Vector2(1e4, 1e4))
	for i: int in range(1, pts.size() - 1):
		if f.segment_blocked(pts[i], pts[i + 1], c, all):
			return false
	return true


func _length(pts: PackedVector3Array) -> float:
	var s := 0.0
	for i: int in range(pts.size() - 1):
		s += pts[i].distance_to(pts[i + 1])
	return s


func _test_field() -> void:
	var f := _field([[Vector3(0, 0, 0), Vector3(1, 1, 1)]],
		[[PackedVector2Array([Vector2(5, 5), Vector2(8, 5), Vector2(8, 8), Vector2(5, 8)]), 0.0, 4.0]])
	var all := f.query_xz(Vector2(-10, -10), Vector2(20, 20))
	_check("field point in box", f.point_blocked(Vector3(0.5, 0.5, 0.5), 0.0, all))
	_check("field point above box is free", not f.point_blocked(Vector3(0.5, 1.2, 0.5), 0.05, all))
	_check("field segment through prism", f.segment_blocked(
		Vector3(4, 1, 6), Vector3(9, 1, 6), 0.0, all))
	_check("field segment over prism", not f.segment_blocked(
		Vector3(4, 4.5, 6), Vector3(9, 4.5, 6), 0.1, all))


func _test_straight_and_stubs() -> void:
	var res := ConduitRunSolver.solve(_req(Vector3(0, 1, 0), Vector3.RIGHT,
		Vector3(10, 1, 0), Vector3.LEFT, _field([])))
	var c: PackedVector3Array = res["corners"]
	_check("open ground runs straight", c.size() == 2, str(c))
	_check("straight length", absf(_length(c) - 10.0) < 1e-3)
	# A target off to the side: the run leaves along +X and arrives along +Z.
	var res2 := ConduitRunSolver.solve(_req(Vector3(0, 1, 0), Vector3.RIGHT,
		Vector3(6, 1, 6), Vector3(0, 0, -1), _field([])))
	var c2: PackedVector3Array = res2["corners"]
	var first := (c2[1] - c2[0])
	var last := (c2[c2.size() - 1] - c2[c2.size() - 2])
	_check("leaves along the port normal", first.normalized().dot(Vector3.RIGHT) > 0.999
		and first.length() >= 0.15 + 0.22 - 1e-4, str(c2))
	_check("arrives against the port normal", last.normalized().dot(Vector3(0, 0, 1)) > 0.999
		and last.length() >= 0.37 - 1e-4, str(c2))
	_check("square corners only", _square(c2))


func _square(pts: PackedVector3Array) -> bool:
	for i: int in range(pts.size() - 1):
		var d := (pts[i + 1] - pts[i]).abs()
		var nonzero := 0
		for k: int in range(3):
			if d[k] > 1e-4:
				nonzero += 1
		if nonzero > 1:
			return false
	return true


func _test_round_a_tall_box() -> void:
	var f := _field([[Vector3(4, 0, -1), Vector3(6, 3, 1)]])
	var res := ConduitRunSolver.solve(_req(Vector3(0, 1, 0), Vector3.RIGHT,
		Vector3(10, 1, 0), Vector3.LEFT, f))
	var c: PackedVector3Array = res["corners"]
	_check("goes round a 3 m box", _clear(c, f, 0.02 + 0.05), str(c))
	var top := -INF
	for p: Vector3 in c:
		top = maxf(top, p.y)
	_check("not over the 3 m box", top < 3.0, "top %.2f" % top)
	var fil := ConduitFillet.apply(c, 0.05)
	_check("filleted run still clear", _clear(fil["points"] as PackedVector3Array, f, 0.02))


func _test_over_a_low_box() -> void:
	# A long low kerb across the way: stepping over beats a 40 m detour.
	var f := _field([[Vector3(4, 0, -20), Vector3(5, 0.4, 20)]])
	var res := ConduitRunSolver.solve(_req(Vector3(0, 0.3, 0), Vector3.RIGHT,
		Vector3(10, 0.3, 0), Vector3.LEFT, f))
	var c: PackedVector3Array = res["corners"]
	var top := -INF
	for p: Vector3 in c:
		top = maxf(top, p.y)
	_check("steps over a 0.4 m kerb", top > 0.4 and top < 1.0, "top %.2f %s" % [top, str(c)])
	_check("kerb crossing clear", _clear(c, f, 0.02 + 0.05))


func _test_round_a_building() -> void:
	var poly := PackedVector2Array([Vector2(3, -4), Vector2(7, -4), Vector2(7, 4), Vector2(3, 4)])
	var f := _field([], [[poly, -1.0, 6.0]])
	var res := ConduitRunSolver.solve(_req(Vector3(0, 1, 0), Vector3.RIGHT,
		Vector3(10, 1, 0), Vector3.LEFT, f))
	var c: PackedVector3Array = res["corners"]
	_check("goes round a building", _clear(c, f, 0.02 + 0.05), str(c))


func _test_vias_keep_height() -> void:
	var via := Vector3(5, 2.5, 3)
	var res := ConduitRunSolver.solve(_req(Vector3(0, 1, 0), Vector3.RIGHT,
		Vector3(10, 1, 0), Vector3.LEFT, _field([]), {"vias": [via]}))
	var c: PackedVector3Array = res["corners"]
	var hit := false
	for p: Vector3 in c:
		if p.distance_to(via) < 1e-3:
			hit = true
	_check("passes through the via at its height", hit, str(c))


func _test_determinism() -> void:
	var boxes := [[Vector3(3, 0, -1), Vector3(4, 2, 1)], [Vector3(6, 0, 0.5), Vector3(7, 3, 3)],
		[Vector3(2, 0, 2), Vector3(3, 1, 4)]]
	var r := _req(Vector3(0, 1, 0), Vector3.RIGHT, Vector3(9, 1, 2), Vector3.LEFT, _field(boxes))
	var c1: PackedVector3Array = ConduitRunSolver.solve(r)["corners"]
	var c2: PackedVector3Array = ConduitRunSolver.solve(r)["corners"]
	_check("same input, same corners", c1 == c2)
	var shuffled := [boxes[2], boxes[0], boxes[1]]
	var r2 := _req(Vector3(0, 1, 0), Vector3.RIGHT, Vector3(9, 1, 2), Vector3.LEFT, _field(shuffled))
	var c3: PackedVector3Array = ConduitRunSolver.solve(r2)["corners"]
	_check("obstacle order does not matter", c1 == c3, "%s vs %s" % [str(c1), str(c3)])


func _test_wall_hug() -> void:
	var wall := [[Vector3(-2, 0, 2), Vector3(22, 3, 2.3)]]
	var r := _req(Vector3(0, 1, 0), Vector3(0, 0, 1), Vector3(20, 1, 0),
		Vector3(0, 0, 1), _field(wall), {"wall_hug": true})
	var c: PackedVector3Array = ConduitRunSolver.solve(r)["corners"]
	var near := 0.0
	var total := 0.0
	for i: int in range(c.size() - 1):
		var d := c[i + 1] - c[i]
		if absf(d.y) > 1e-4:
			continue
		total += d.length()
		var mid := (c[i] + c[i + 1]) * 0.5
		if absf(mid.z - 2.0) <= ConduitRunSolver.WALL_NEAR_M + 0.08:
			near += d.length()
	_check("runs along the wall", total > 0.0 and near / total > 0.7,
		"%.1f of %.1f m %s" % [near, total, str(c)])


func _test_stub_clears_host() -> void:
	var f := _field([[Vector3(-1, 0, -1), Vector3(0.5, 2, 1), "machine"]])
	var res := ConduitRunSolver.solve(_req(Vector3(-0.2, 1, 0), Vector3.RIGHT,
		Vector3(8, 1, 0), Vector3.LEFT, f, {"host_a": "machine"}))
	var sa: Vector3 = res["stub_a"]
	_check("stub pushed out of its own machine", sa.x > 0.5 + 0.08, str(sa))
	_check("stub extension flagged", bool((res["flags"] as Dictionary).get("stub_extended", false)))


func _test_no_path_fallback() -> void:
	# The target sits in a walled courtyard taller than the climb: no path.
	var f := _field([[Vector3(8, 0, -2), Vector3(8.3, 6, 2)], [Vector3(11.7, 0, -2), Vector3(12, 6, 2)],
		[Vector3(8, 0, -2), Vector3(12, 6, -1.7)], [Vector3(8, 0, 1.7), Vector3(12, 6, 2)]])
	var res := ConduitRunSolver.solve(_req(Vector3(0, 1, 0), Vector3.RIGHT,
		Vector3(10, 1, 0), Vector3.ZERO, f))
	_check("no path is flagged", bool((res["flags"] as Dictionary).get("budget", false)))
	_check("fallback still ends at the port",
		(res["corners"] as PackedVector3Array)[-1].distance_to(Vector3(10, 1, 0)) < 1e-4)


func _test_fillet_geometry() -> void:
	var c := PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1)])
	var fil := ConduitFillet.apply(c, 0.2)
	var pts: PackedVector3Array = fil["points"]
	_check("arc starts r before the corner", pts[1].distance_to(Vector3(0.8, 0, 0)) < 1e-4,
		str(pts[1]))
	_check("arc ends r after the corner", pts[pts.size() - 2].distance_to(Vector3(1, 0, 0.2)) < 1e-4)
	var on_circle := true
	for i: int in range(1, pts.size() - 1):
		if absf(pts[i].distance_to(Vector3(0.8, 0, 0.2)) - 0.2) > 1e-4:
			on_circle = false
	_check("arc centred on the bisector at radius r", on_circle)
	_check("full radius not tight", (fil["tight"] as Array).is_empty())
	var tight := ConduitFillet.apply(PackedVector3Array([Vector3.ZERO, Vector3(0.1, 0, 0),
		Vector3(0.1, 0, 0.1)]), 0.5)
	_check("short legs shrink the bend and say so", (tight["tight"] as Array).size() == 1)
	var radii: PackedFloat32Array = tight["radii"]
	_check("shrunk radius fits the leg", radii[0] > 0.0 and radii[0] < 0.11, str(radii))


func _test_dispatch_points() -> void:
	var ends := {"a": Vector3(0, 1, 0), "b": Vector3(4, 1, 4), "out_a": Vector3.RIGHT,
		"out_b": Vector3(0, 0, -1), "stub_a": 0.15, "stub_b": 0.15}
	var kit := ConduitRouteDispatch.solver_points(ends, "pvc_pipe", {}, [], {"field": _field([])})
	var tube := ConduitRouteDispatch.solver_points(ends, "romex", {}, [], {"field": _field([])})
	_check("kit pipe gets sharp corners for its elbows", kit.size() <= 5, str(kit.size()))
	_check("NM cable gets bends", tube.size() > kit.size())
	_check("solver runs: pipe yes, cord no, penstock no",
		ConduitRouteDispatch.uses_solver({}, "pvc_pipe")
		and not ConduitRouteDispatch.uses_solver({}, "extension_cord")
		and not ConduitRouteDispatch.uses_solver({}, "poly_penstock"))
	_check("pinned old runs keep their path",
		not ConduitRouteDispatch.uses_solver({"route_locked": true}, "pvc_pipe")
		and ConduitRouteDispatch.uses_solver({"route_locked": true, "route_solver": "v2"}, "pvc_pipe"))


func _test_speed() -> void:
	var boxes: Array = []
	for i: int in range(30):
		var x := float(i % 6) * 4.0 + 2.0
		var z := float(i / 6) * 4.0 - 8.0
		boxes.append([Vector3(x, 0, z), Vector3(x + 1.5, 1.0 + float(i % 3), z + 1.5)])
	var f := _field(boxes)
	var t0 := Time.get_ticks_usec()
	var res := ConduitRunSolver.solve(_req(Vector3(0, 0.5, 0), Vector3.RIGHT,
		Vector3(26, 0.5, 4), Vector3.LEFT, f))
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	print("  run solver: 30 props, %.1f ms, %d corners" % [ms, (res["corners"] as PackedVector3Array).size()])
	_check("busy yard solves", not bool((res["flags"] as Dictionary).get("budget", false)))
	_check("busy yard clear", _clear(res["corners"] as PackedVector3Array, f, 0.02 + 0.05))
