extends SceneTree

## GraphForceLayout selftest (offline). Pins: no overlap at rest, determinism,
## pinned nodes never move, the flow order (sources above sinks) on the
## bootcamp's 3S2P graph, edge-direction rules, cycle-safe layering, bounded
## energy on a random graph, a 120-node settle within a CPU budget, and that
## stepping by hand (Live) lands exactly where tidy() does.
##
## Carries EXPECTED_CHECKS: a GDScript runtime error aborts the enclosing test
## function while the suite still prints PASS.
##   godot --headless --path . --script system_graph/graph_force_layout_selftest.gd

const EXPECTED_CHECKS := 23

## Vertical port positions (0 top, 1 bottom) — the shape of graph_canvas HANDLES.
const PORT_RY := {
	"panel": {"positive": 1.0, "negative": 1.0},
	"battery": {"positive": 0.0, "negative": 0.0},
	"controller": {"pvPositive": 0.0, "pvNegative": 0.0, "batteryPositive": 1.0,
		"batteryNegative": 1.0, "acOutput": 1.0},
	"appliance": {"input": 0.0},
}

var _checks := 0
var _fails := 0


func _init() -> void:
	_test_edge_direction()
	_test_layers_cycle_safe()
	_test_bootcamp_3s2p()
	_test_determinism_and_live()
	_test_pinned()
	_test_stacked_start()
	_test_unwired_keeps_shape()
	_test_random_bounded()
	_test_large_budget()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		print("FAIL check count %d != EXPECTED_CHECKS %d (a test function aborted?)" % [_checks, EXPECTED_CHECKS])
	print("GRAPH FORCE LAYOUT SELFTEST %s  (%d checks, %d failed)" % [
		"PASS" if _fails == 0 else "FAIL", _checks, _fails])
	quit(0 if _fails == 0 else 1)


func _ok(cond: bool, what: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		print("  FAIL " + what)


func _port_side(item: Dictionary, handle_id: String) -> float:
	var t: Dictionary = PORT_RY.get(str(item.get("type", "")), {})
	return float(t.get(handle_id, NAN))


static func _item(id: String, type: String, x: float, y: float, w: float, h: float) -> Dictionary:
	return {"id": id, "type": type, "x": x, "y": y, "width": w, "height": h}


static func _wire(a: String, ah: String, b: String, bh: String) -> Dictionary:
	return {"source_item_id": a, "source_handle_id": ah, "target_item_id": b, "target_handle_id": bh}


## The bootcamp level 8 seed: 6 panels pre-wired 3S2P into an MPPT, the MPPT
## into one 48 V battery — deliberately started tangled (all near the origin).
static func _l8() -> Array:
	var items: Array = [_item("bat", "battery", -70.0, 280.0, 80.0, 112.0)]
	for k in 6:
		items.append(_item("p%d" % k, "panel", -510.0 + 190.0 * k, -260.0, 190.0, 84.0))
	items.append(_item("mppt", "controller", -70.0, 20.0, 124.0, 104.0))
	var conns: Array = [
		_wire("p0", "positive", "p1", "negative"), _wire("p1", "positive", "p2", "negative"),
		_wire("p3", "positive", "p4", "negative"), _wire("p4", "positive", "p5", "negative"),
		_wire("p2", "positive", "mppt", "pvPositive"), _wire("p5", "positive", "mppt", "pvPositive"),
		_wire("p0", "negative", "mppt", "pvNegative"), _wire("p3", "negative", "mppt", "pvNegative"),
		_wire("mppt", "batteryPositive", "bat", "positive"),
		_wire("mppt", "batteryNegative", "bat", "negative"),
	]
	return [items, conns]


static func _overlaps(items: Array, pos: Dictionary, pad: float) -> int:
	var n := 0
	for i in items.size():
		for j in range(i + 1, items.size()):
			var a: Dictionary = items[i]
			var b: Dictionary = items[j]
			var ra := Rect2(pos[a["id"]] as Vector2, Vector2(a["width"], a["height"])).grow(pad * 0.5 - 0.5)
			var rb := Rect2(pos[b["id"]] as Vector2, Vector2(b["width"], b["height"])).grow(pad * 0.5 - 0.5)
			if ra.intersects(rb):
				n += 1
	return n


func _test_edge_direction() -> void:
	_ok(GraphForceLayout.edge_direction(1.0, 0.0) == 1, "bottom output → top input orders the source above")
	_ok(GraphForceLayout.edge_direction(0.0, 1.0) == -1, "a wire dragged from the input end reverses")
	_ok(GraphForceLayout.edge_direction(0.0, 0.0) == 0, "top-to-top (series batteries) sets no order")
	_ok(GraphForceLayout.edge_direction(NAN, 0.0) == 0, "an unknown port sets no order")


func _test_layers_cycle_safe() -> void:
	var lay := GraphForceLayout.layers_for(3, [[0, 1, 1], [1, 2, 1], [2, 0, 1]])
	_ok(lay.size() == 3 and lay[0] < 3 and lay[1] < 3 and lay[2] < 3, "a directed cycle still layers (no runaway)")
	var lay2 := GraphForceLayout.layers_for(4, [[0, 1, 1], [1, 2, 1], [2, 3, 0]])
	_ok(lay2[0] == 0 and lay2[1] == 1 and lay2[2] == 2 and lay2[3] == 2,
		"longest-path layers; unordered neighbours share a layer (%s)" % str(lay2))


func _test_bootcamp_3s2p() -> void:
	var g := _l8()
	var items: Array = g[0]
	var f := GraphForceLayout.new()
	f.setup(items, g[1], Callable(self, "_port_side"))
	var steps := f.run_to_rest()
	var pos := f.positions()
	_ok(_overlaps(items, pos, f.spacing) == 0, "no two cards overlap at rest (%d pairs)" % _overlaps(items, pos, f.spacing))
	var panels_above := true
	for k in 6:
		if f.center_of("p%d" % k).y >= f.center_of("mppt").y:
			panels_above = false
	_ok(panels_above, "every panel settles above the controller")
	_ok(f.center_of("mppt").y < f.center_of("bat").y, "the controller settles above the battery")
	var ys: Array = []
	for k in 6:
		ys.append(f.center_of("p%d" % k).y)
	_ok(float(ys.max()) - float(ys.min()) < 24.0,
		"all six panels share one row, mid-string panels included (spread %.1f px)" % (float(ys.max()) - float(ys.min())))
	_ok(f.layer_of("p0") == 0 and f.layer_of("mppt") == 1 and f.layer_of("bat") == 2,
		"layers panel 0 / controller 1 / battery 2")
	_ok(steps > 10 and steps <= 400, "settles within the step budget (%d steps)" % steps)


func _test_determinism_and_live() -> void:
	var g := _l8()
	var a := GraphForceLayout.tidy(g[0], g[1], Callable(self, "_port_side"))
	var b := GraphForceLayout.tidy(g[0], g[1], Callable(self, "_port_side"))
	var same := true
	for k in a:
		if not (a[k] as Vector2).is_equal_approx(b[k] as Vector2):
			same = false
	_ok(same, "tidy() is deterministic")
	var live := GraphForceLayout.new()
	live.setup(g[0], g[1], Callable(self, "_port_side"))
	while not live.is_settled():
		live.step()
	live.run_to_rest()
	var lp := live.positions()
	var match_live := true
	for k in a:
		if (a[k] as Vector2).distance_to(lp[k] as Vector2) > 0.01:
			match_live = false
	_ok(match_live, "stepping by hand (Live) lands where tidy() does")


func _test_pinned() -> void:
	var g := _l8()
	var items: Array = g[0]
	var pin_tl := Vector2(float((items[0] as Dictionary)["x"]), float((items[0] as Dictionary)["y"]))
	var pos := GraphForceLayout.tidy(items, g[1], Callable(self, "_port_side"), {}, {"bat": true})
	_ok((pos["bat"] as Vector2).is_equal_approx(pin_tl), "a pinned node never moves")
	_ok(_overlaps(items, pos, GraphForceLayout.new().spacing) == 0, "the others clear a pinned node")


func _test_stacked_start() -> void:
	var items: Array = []
	for k in 8:
		items.append(_item("s%d" % k, "battery", 0.0, 0.0, 80.0, 110.0))
	var pos := GraphForceLayout.tidy(items, [])
	_ok(_overlaps(items, pos, GraphForceLayout.new().spacing) == 0, "eight cards stacked on one spot separate")


func _test_unwired_keeps_shape() -> void:
	var items: Array = []
	for k in 4:
		items.append(_item("u%d" % k, "panel", -420.0 + 190.0 * k, -240.0, 190.0, 84.0))
	var pos := GraphForceLayout.tidy(items, [])
	var ys := []
	for k in 4:
		ys.append((pos["u%d" % k] as Vector2).y)
	_ok(float(ys.max()) - float(ys.min()) < 1.0 and _overlaps(items, pos, GraphForceLayout.new().spacing) == 0,
		"an unwired row stays a row (only its overlaps are removed)")


func _test_random_bounded() -> void:
	var items: Array = []
	var conns: Array = []
	var seed := 12345
	for k in 40:
		seed = (seed * 1103515245 + 12345) & 0x7fffffff
		var x := float(seed % 900)
		seed = (seed * 1103515245 + 12345) & 0x7fffffff
		var y := float(seed % 700)
		items.append(_item("r%d" % k, ["panel", "battery", "controller", "appliance"][k % 4], x, y,
			100.0 + float(k % 3) * 60.0, 80.0 + float(k % 2) * 40.0))
		if k > 0:
			conns.append(_wire("r%d" % (k - 1), "positive", "r%d" % k, "negative"))
	var f := GraphForceLayout.new()
	f.setup(items, conns, Callable(self, "_port_side"))
	var worst := 0.0
	for _i in 300:
		worst = maxf(worst, f.step())
	f.run_to_rest()
	var pos := f.positions()
	var finite := true
	for k in pos:
		var v: Vector2 = pos[k]
		if is_nan(v.x) or is_nan(v.y) or absf(v.x) > 1.0e6 or absf(v.y) > 1.0e6:
			finite = false
	_ok(finite, "a random 40-node graph stays finite and in range")
	_ok(worst <= GraphForceLayout.MAX_STEP_PX + 400.0, "no step explodes (worst %.1f px)" % worst)
	_ok(_overlaps(items, pos, f.spacing) == 0, "random graph: no overlap at rest")


func _test_large_budget() -> void:
	var items: Array = []
	var conns: Array = []
	for k in 120:
		items.append(_item("n%d" % k, "battery", float(k % 12) * 40.0, float(k / 12) * 30.0, 120.0, 90.0))
		if k % 3 != 0:
			conns.append(_wire("n%d" % (k - 1), "positive", "n%d" % k, "negative"))
	var t0 := Time.get_ticks_msec()
	var pos := GraphForceLayout.tidy(items, conns)
	var ms := Time.get_ticks_msec() - t0
	_ok(_overlaps(items, pos, GraphForceLayout.new().spacing) == 0, "120 nodes: no overlap at rest")
	_ok(ms < 8000, "120 nodes settle within the CPU budget (%d ms)" % ms)
	print("  120-node tidy: %d ms" % ms)
