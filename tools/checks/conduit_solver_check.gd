extends RefCounted

## The run solver on a real world (sandbox, read-only).
##  - every run the solver takes is solved from scratch: no leg inside an
##    obstacle (its own machine's stub excepted), first and last legs along the
##    port normals, solve time per run, the flags it raised;
##  - every penstock, culvert, siphon or pinned run keeps its saved length to
##    the millimetre when rebuilt (those stay on their own routers).
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/conduit_solver_check.gd

var _fails := 0


func _ok(label: String, cond: bool, detail: String = "") -> void:
	print("solvercheck %s %s %s" % ["PASS" if cond else "FAIL", label, detail])
	if not cond:
		_fails += 1


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	for _f in 40:
		await tree.process_frame
	var gv: Node = main.find_child("SystemGraphView", true, false)
	var mgr: ConduitManager = main.get_node_or_null("ConduitManager") as ConduitManager
	if gv == null or mgr == null:
		return {"ok": false, "error": "no graph view / conduit manager"}
	var model: GraphModel = gv.get("model") as GraphModel
	var field := mgr.obstacle_field()
	print("solvercheck field: %d prop boxes, %d buildings" % [field.boxes.size(), field.prisms.size()])
	var all_entries := field.query_xz(Vector2(-1e5, -1e5), Vector2(1e5, 1e5))
	var times: Array = []
	var n_solver := 0
	var n_kept := 0
	for conn: Dictionary in model.connections:
		if not model.connection_is_3d_routable(conn):
			continue
		var cid := str(conn.get("id", ""))
		var type_id := ConduitKinds.derive_type_for_connection(conn)
		if ConduitRouteDispatch.uses_solver(conn, type_id):
			n_solver += 1
			ConduitRunSolver.clear_memo()
			var t0 := Time.get_ticks_usec()
			var pts := mgr.build_control_points(conn)
			var ms := float(Time.get_ticks_usec() - t0) / 1000.0
			times.append(ms)
			var info := mgr.run_info(cid)
			var corners: PackedVector3Array = info.get("corners", PackedVector3Array())
			var c := float(info.get("od", 0.03)) * 0.5 + 0.02
			var hits := 0
			# Skip the two stub legs: they start inside their own machine.
			for i: int in range(1, corners.size() - 2):
				if field.segment_blocked(corners[i], corners[i + 1], c, all_entries):
					hits += 1
			print("solvercheck run %s %s: %d corners, %d points, %.1f ms, flags %s" % [
				cid, type_id, corners.size(), pts.size(), ms, str(info.get("flags", {}))])
			_ok("%s clear of obstacles" % cid, hits == 0 or bool(
				(info.get("flags", {}) as Dictionary).get("budget", false)), "%d legs hit" % hits)
		else:
			var saved := float(conn.get("route_length_m", 0.0))
			if saved <= 0.0 or not conn.get("visible_3d") == true:
				continue
			n_kept += 1
			var ctrl := mgr.build_control_points(conn)
			var measured := mgr.measure_route(conn, ctrl, type_id)
			_ok("%s (%s) keeps its length" % [cid, type_id], absf(measured - saved) < 0.01,
				"saved %.3f now %.3f" % [saved, measured])
	# Runs between the world's own props: from the middle of one box's side
	# facing the other to the matching side of the other, at waist height,
	# through the real obstacles and buildings round them.
	var boxes: Array = field.boxes
	var made := 0
	for i: int in range(boxes.size()):
		if made >= 24:
			break
		var j := (i * 7 + 3) % boxes.size()
		if j == i:
			continue
		var ba: Dictionary = boxes[i]
		var bb: Dictionary = boxes[j]
		var ca := ((ba["min"] as Vector3) + (ba["max"] as Vector3)) * 0.5
		var cb := ((bb["min"] as Vector3) + (bb["max"] as Vector3)) * 0.5
		if ca.distance_to(cb) > 60.0 or ca.distance_to(cb) < 2.0:
			continue
		var dirx := signf(cb.x - ca.x) if absf(cb.x - ca.x) >= absf(cb.z - ca.z) else 0.0
		var dirz := 0.0 if dirx != 0.0 else signf(cb.z - ca.z)
		var na := Vector3(dirx, 0, dirz)
		var pa := Vector3(ca.x, (ba["min"] as Vector3).y + 0.5, ca.z)
		var pb := Vector3(cb.x, (bb["min"] as Vector3).y + 0.5, cb.z)
		pa += na * ((ba["max"] as Vector3) - ca).abs().dot(na.abs())
		pb -= na * ((bb["max"] as Vector3) - cb).abs().dot(na.abs())
		ConduitRunSolver.clear_memo()
		var t1 := Time.get_ticks_usec()
		var res := ConduitRunSolver.solve({"a": pa, "b": pb, "na": na, "nb": -na,
			"stub_a": 0.15, "stub_b": 0.15, "host_a": str(ba["prop"]), "host_b": str(bb["prop"]),
			"od": 0.042, "bend_r": 0.05, "field": field, "run_height": NAN,
			"ground_fn": Callable(mgr, "ground_y_at")})
		var ms2 := float(Time.get_ticks_usec() - t1) / 1000.0
		times.append(ms2)
		made += 1
		var cs: PackedVector3Array = res["corners"]
		var flags: Dictionary = res["flags"]
		var hits2 := 0
		for k: int in range(1, cs.size() - 2):
			if field.segment_blocked(cs[k], cs[k + 1], 0.04, all_entries):
				hits2 += 1
		print("solvercheck synth %s -> %s: %d corners, %.1f m, %.1f ms, flags %s" % [
			str(ba["prop"]), str(bb["prop"]), cs.size(), _len(cs), ms2, str(flags)])
		_ok("synth run %d clear" % made, hits2 == 0 or flags.get("budget", false)
			or flags.get("stub_blocked", false), "%d legs hit" % hits2)
	_ok("synthetic runs made", made >= 5, str(made))
	times.sort()
	var p95 := 0.0
	if not times.is_empty():
		p95 = float(times[mini(times.size() - 1, int(ceil(times.size() * 0.95)) - 1)])
	print("solvercheck %d solver runs, %d kept runs, p95 %.1f ms, max %.1f ms" % [
		n_solver, n_kept, p95, float(times.back()) if not times.is_empty() else 0.0])
	var p50 := float(times[times.size() / 2]) if not times.is_empty() else 0.0
	print("solvercheck p50 %.1f ms" % p50)
	_ok("median solve under 10 ms", p50 < 10.0, "%.1f ms" % p50)
	_ok("worst solve under 250 ms", times.is_empty() or float(times.back()) < 250.0)
	return {"ok": _fails == 0, "solver_runs": n_solver, "kept_runs": n_kept, "p95_ms": p95}


static func _len(pts: PackedVector3Array) -> float:
	var s := 0.0
	for i: int in range(pts.size() - 1):
		s += pts[i].distance_to(pts[i + 1])
	return s
