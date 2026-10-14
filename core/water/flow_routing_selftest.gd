extends SceneTree

## Offline selftest for FlowRouting (core/water/flow_routing.gd): Priority-
## Flood+ε drains a pitted surface to the map edge (no interior sinks left),
## accumulation conserves the cell count, a V-valley's channel lands on its
## axis, a Y of two valleys reaches Strahler order 2, burning pulls the network
## onto a mapped line, the Trace path runs downhill to the edge, RDP collapses a
## straight run, and the whole analysis is deterministic.
##
## Run: Godot.exe.exe --headless --path . --script core/water/flow_routing_selftest.gd

const EXPECTED_CHECKS := 12

var _fails := 0
var _checks := 0


func _check(name: String, cond: bool, detail: String = "") -> void:
	_checks += 1
	if not cond:
		_fails += 1
		push_error("FAIL: %s  %s" % [name, detail])


func _initialize() -> void:
	_test_pits()
	_test_valley()
	_test_strahler()
	_test_burn()
	_test_misc()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		push_error("FAIL: ran %d checks, expected %d (a runtime error aborted a test?)"
				% [_checks, EXPECTED_CHECKS])
	if _fails == 0:
		print("FLOW ROUTING SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("FLOW ROUTING SELFTEST FAIL  (%d of %d checks failed)" % [_fails, _checks])
	quit(1 if _fails > 0 else 0)


func _test_pits() -> void:
	# A tilted plane with a 3 m pit and some speckle: without filling, the pit
	# and every speckle low would be its own sink.
	var g := func(x: float, z: float) -> float:
		return 50.0 + 0.02 * x - 3.0 * exp(-(x * x + z * z) / 400.0) \
			+ 0.3 * sin(x * 0.7) * cos(z * 0.9)
	var res := FlowRouting.analyze(g, 100.0, 5.0)
	var n := int(res["n"])
	var recv: PackedInt32Array = res["recv"]
	var sinks := 0
	for r in range(1, n - 1):
		for c in range(1, n - 1):
			if recv[r * n + c] < 0:
				sinks += 1
	_check("no interior sinks after Priority-Flood+e", sinks == 0, "%d sinks" % sinks)
	var acc: PackedFloat32Array = res["acc"]
	var outlet_sum := 0.0
	for i in recv.size():
		if recv[i] < 0:
			outlet_sum += acc[i]
	_check("accumulation conserves cells", is_equal_approx(outlet_sum, float(n * n)),
		"%.0f vs %d" % [outlet_sum, n * n])
	var path := FlowRouting.trace(res, Vector2(0, 0))
	var last := path[path.size() - 1]
	_check("trace from the pit reaches the map edge",
		maxf(absf(last.x), absf(last.y)) >= 100.0 - 5.0 - 1e-3, str(last))
	# The plane falls toward −x, so the pit spills out that way.
	_check("trace leaves downhill (toward -x)", last.x < -50.0, str(last))


func _test_valley() -> void:
	var g := func(x: float, z: float) -> float:
		return 30.0 - 0.02 * x + 0.15 * absf(z - 10.0)
	var res := FlowRouting.analyze(g, 150.0, 5.0)
	var chans := FlowRouting.channels(res, 6000.0)
	var best: Dictionary = {}
	for ch in chans:
		if best.is_empty() or float(ch["area_m2"]) > float(best["area_m2"]):
			best = ch
	_check("valley yields a channel", not best.is_empty())
	var on_axis := true
	if not best.is_empty():
		for p in (best["points"] as PackedVector2Array):
			if absf(p.y - 10.0) > 5.01:
				on_axis = false
	_check("main channel lies on the valley axis", on_axis)


func _test_strahler() -> void:
	# Two valleys meeting at the origin and continuing as one toward +x.
	var g := func(x: float, z: float) -> float:
		var d := absf(z) if x >= 0.0 else minf(absf(z - 0.6 * x), absf(z + 0.6 * x))
		return 40.0 - 0.03 * x + 0.2 * d
	var res := FlowRouting.analyze(g, 150.0, 5.0)
	var chans := FlowRouting.channels(res, 12000.0)
	var max_order := 0
	for ch in chans:
		max_order = maxi(max_order, int(ch["order"]))
	_check("Y junction reaches Strahler order 2", max_order == 2, "max %d" % max_order)


func _test_burn() -> void:
	# A plain tilt has no channels of its own; a burned line becomes one. On a
	# perfectly planar tilt only the two rows beside the trench turn into it
	# (nothing further out has a lateral gradient), so ~3x one row's area.
	var g := func(x: float, _z: float) -> float: return 20.0 - 0.01 * x
	var line := PackedVector2Array([Vector2(-140, 40), Vector2(0, 40), Vector2(140, 40)])
	var res := FlowRouting.analyze(g, 150.0, 5.0, [line])
	var a_on := FlowRouting.area_at(res, Vector2(120, 40))
	var a_off := FlowRouting.area_at(res, Vector2(120, -60))
	_check("burned line collects the flow", a_on > a_off * 2.5, "%.0f vs %.0f" % [a_on, a_off])


func _test_misc() -> void:
	var straight := PackedVector2Array()
	for i in 20:
		straight.append(Vector2(float(i), 0.5 * float(i)))
	_check("RDP collapses a straight run", FlowRouting.rdp(straight, 0.1).size() == 2)
	var g := func(x: float, z: float) -> float:
		return 10.0 + 0.01 * x + 0.5 * sin(x * 0.3 + z * 0.2)
	var a := FlowRouting.analyze(g, 60.0, 4.0)
	var b := FlowRouting.analyze(g, 60.0, 4.0)
	_check("deterministic", a["acc"] == b["acc"] and a["recv"] == b["recv"])
	var res := FlowRouting.analyze(g, 60.0, 4.0)
	_check("area_at is positive inside", FlowRouting.area_at(res, Vector2(0, 0)) >= 16.0)
	_check("area_at outside the grid is 0", FlowRouting.area_at(res, Vector2(500, 0)) == 0.0)
