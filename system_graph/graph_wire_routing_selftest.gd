extends SceneTree

## Offline geometry checks for wire routing + port presentation on the graph
## canvas. These are pure-math contracts behind things you can only otherwise
## catch by eye — the bezier control points that decide whether a wire loops
## through open canvas or cuts across the node body, and the port-dot styling
## rules. Both silently regressed once; hence the guard.

const GraphCanvasScript := preload("res://system_graph/graph_canvas.gd")

var _canvas: Control = null


func _initialize() -> void:
	_canvas = GraphCanvasScript.new() as Control
	_canvas.set("_zoom", 1.0)
	var fails := 0
	fails += _test_same_edge_loops_outward()
	fails += _test_facing_ports_unchanged()
	fails += _test_direction_fallback_pulls_back()
	fails += _test_ambient_doc_handles()
	fails += _test_dc_port_styling()
	fails += _test_dc_terminal_side_convention()
	fails += _test_circuit_gating()
	fails += _test_bundle_six_into_one_port()
	fails += _test_bundle_single_wire_untouched()
	fails += _test_bundle_skip_and_both_ends()
	fails += _test_bundle_deterministic_ties()
	fails += _test_bundle_spread_capped()
	fails += _test_bundle_canvas_pref_off()
	_canvas.free()
	if fails == 0:
		print("GRAPH WIRE ROUTING SELFTEST PASS  (13 checks)")
		quit(0)
	else:
		print("GRAPH WIRE ROUTING SELFTEST FAIL  (%d failed)" % fails)
		quit(1)


func _controls(from: Vector2, from_t: Vector2, to: Vector2, to_t: Vector2) -> Dictionary:
	return _canvas.call("_wire_bezier_controls", from, from_t, to, to_t, 1.0)


## Two ports on the SAME edge (series-wiring two panels side by side): both
## face down, so the wire must bow DOWN through open canvas — a U. Control
## points above the ports would tuck the curve behind the node bodies, which is
## the flat "~" this guards against.
func _test_same_edge_loops_outward() -> int:
	var down := Vector2(0.0, 1.0)
	var from := Vector2(100.0, 200.0)
	var to := Vector2(300.0, 200.0)
	var c := _controls(from, down, to, down)
	var c1: Vector2 = c["c1"]
	var c2: Vector2 = c["c2"]
	# Screen space: +y is down. Both handles must sit BELOW their ports.
	if c1.y <= from.y + 1.0:
		push_error("same-edge: source control should bow below the port, got %s" % str(c1))
		return 1
	if c2.y <= to.y + 1.0:
		push_error("same-edge: target control should bow below the port (the '~' bug), got %s" % str(c2))
		return 1
	# And the bow should be a real loop, not a hairline.
	var depth := minf(c1.y, c2.y) - from.y
	if depth < 30.0:
		push_error("same-edge: loop too shallow to read (%.1f px)" % depth)
		return 1
	# Symmetric pair → symmetric U.
	if absf((c1.y - from.y) - (c2.y - to.y)) > 1.0:
		push_error("same-edge: U should be symmetric, got %s / %s" % [str(c1), str(c2)])
		return 1
	return 0


## The common vertical case (panel's bottom port down into a controller's top
## port) must be untouched by the fix: each control point sits outside its own
## node, giving the classic S.
func _test_facing_ports_unchanged() -> int:
	var from := Vector2(200.0, 100.0)   # panel bottom edge, faces down
	var to := Vector2(200.0, 400.0)     # controller top edge, faces up
	var c := _controls(from, Vector2(0.0, 1.0), to, Vector2(0.0, -1.0))
	var c1: Vector2 = c["c1"]
	var c2: Vector2 = c["c2"]
	if c1.y <= from.y:
		push_error("facing: source control should sit below the source port, got %s" % str(c1))
		return 1
	if c2.y >= to.y:
		push_error("facing: target control should sit above the target port, got %s" % str(c2))
		return 1
	# Both controls stay between the endpoints — no overshoot past either port.
	if c1.y > to.y or c2.y < from.y:
		push_error("facing: controls overshot the span (%s, %s)" % [str(c1), str(c2)])
		return 1
	return 0


## Endpoints with no real port (free wire drag, waypoint-derived tangents) pass
## the reversed travel direction; the far control must be pulled BACK toward the
## source rather than shooting past the target.
func _test_direction_fallback_pulls_back() -> int:
	var from := Vector2(100.0, 100.0)
	var to := Vector2(400.0, 100.0)
	var dir := from.direction_to(to)
	var c := _controls(from, dir, to, _canvas.call("_incoming_tangent", dir))
	var c2: Vector2 = c["c2"]
	if c2.x >= to.x:
		push_error("fallback: target control overshot past the endpoint, got %s" % str(c2))
		return 1
	if c2.x <= from.x:
		push_error("fallback: target control collapsed back onto the source, got %s" % str(c2))
		return 1
	return 0


## Ambient sunlight/wind inputs are documentary — the sim never needs the wire —
## so they are classified for hiding while the real circuit ports are not.
func _test_ambient_doc_handles() -> int:
	var cases := [
		["panel", "sunlight_in", true],
		["plant", "sunlight_in", true],
		["wind", "wind_in", true],
		["panel", "positive", false],
		["panel", "negative", false],
		["plant", "water_in", false],
		["battery", "positive", false],
		["controller", "pvPositive", false],
	]
	for c_v in cases:
		var c: Array = c_v
		var got: bool = bool(GraphCanvasScript.is_ambient_doc_handle(str(c[0]), str(c[1])))
		if got != bool(c[2]):
			push_error("ambient classification wrong for %s.%s (got %s)" % [c[0], c[1], str(got)])
			return 1
	return 0


## A wire only animates when it belongs to a COMPLETE circuit. The old test was
## "is an endpoint a panel, and is the array producing?", where array output is
## computed from insolation with no reference to wiring — so a single wire
## dangling off an unconnected panel animated and reported the whole array's
## watts. That is the regression this pins.
func _test_circuit_gating() -> int:
	var GC := GraphCanvasScript
	# A published circuit: controller "ctrl" fed by panel "p1", bank "b1".
	var hint := {
		"circuits": {"ctrl": {"bus_v": 48.0, "delivered_w": 900.0, "array_voc": 120.0}},
		"circuit_of": {"p1": "ctrl", "b1": "ctrl"},
	}
	# Wires that touch the circuit are live...
	if not GC.dc_circuit_live(hint, "p1", "ctrl"):
		panic_msg("panel on a complete circuit should be live")
		return 1
	if not GC.dc_circuit_live(hint, "ctrl", "b1"):
		panic_msg("battery on a complete circuit should be live")
		return 1
	# ...and a stray panel wired to nothing is NOT, even though the array is
	# producing (that is the whole bug).
	if GC.dc_circuit_live(hint, "p_stray", "p_other"):
		panic_msg("wire off a panel outside any circuit must not animate")
		return 1
	# The virtual solar_bridge chain has no real controller — keep it working.
	if not GC.dc_circuit_live(hint, "virtual_solar_array", "virtual_controller", true):
		panic_msg("legacy virtual chain should stay permissive")
		return 1
	# Nothing published yet (fresh load / no real controller) → permissive, so
	# freeplay graphs are unchanged.
	if not GC.dc_circuit_live({}, "anything", "at_all"):
		panic_msg("with no published circuits the old behaviour must be kept")
		return 1
	# Voltage: PV side reports string Voc, battery side the bank bus.
	if absf(GC.dc_circuit_volts(hint, "p1", "ctrl", true) - 120.0) > 0.01:
		panic_msg("PV-side wire should report the array string Voc")
		return 1
	if absf(GC.dc_circuit_volts(hint, "ctrl", "b1", false) - 48.0) > 0.01:
		panic_msg("battery-side wire should report the bank bus voltage")
		return 1
	if absf(GC.dc_circuit_volts(hint, "p_stray", "p_other", true)) > 0.01:
		panic_msg("a wire outside any circuit has no known voltage")
		return 1
	return 0


func panic_msg(msg: String) -> void:
	push_error(msg)


## Every node type carrying a +/− pair on ONE edge must put positive on the
## left. Generators used to be mirrored against batteries/controllers, so the
## two wires of a panel→controller link crossed — the commonest link in the
## game. This pins the convention across all types at once, including any added
## later.
func _test_dc_terminal_side_convention() -> int:
	var checked := 0
	for type_id in GraphCanvasScript.HANDLES:
		var pos: Dictionary = {}
		var neg: Dictionary = {}
		for h_v in (GraphCanvasScript.HANDLES[type_id] as Array):
			var h: Dictionary = h_v
			match str(h.get("id", "")):
				"positive":
					pos = h
				"negative":
					neg = h
		if pos.is_empty() or neg.is_empty():
			continue
		# Only meaningful when the pair shares an edge (same ry).
		if absf(float(pos.get("ry", -1.0)) - float(neg.get("ry", -2.0))) > 0.001:
			continue
		checked += 1
		if float(pos.get("rx", 1.0)) >= float(neg.get("rx", 0.0)):
			push_error("'%s': positive (rx %.2f) must sit LEFT of negative (rx %.2f)" % [
				str(type_id), float(pos.get("rx", -1.0)), float(neg.get("rx", -1.0))])
			return 1
	if checked < 4:
		push_error("expected at least 4 types with a same-edge +/− pair, saw %d" % checked)
		return 1
	return 0


## DC ports are the only ones drawn as solid discs with a polarity glyph, and
## DC− must be lifted off the canvas background so it does not read as the same
## dark dot as DC+ at low zoom.
func _test_dc_port_styling() -> int:
	if not GraphCanvasScript.is_dc_polarity("positive") \
			or not GraphCanvasScript.is_dc_polarity("negative"):
		push_error("positive/negative must be DC polarities")
		return 1
	for pol in ["ac", "load", "resource", "smart_battery"]:
		if GraphCanvasScript.is_dc_polarity(str(pol)):
			push_error("'%s' must not be treated as a DC port" % str(pol))
			return 1
	var neg: Color = GraphCanvasScript.PORT_COLORS["negative"]
	var pos: Color = GraphCanvasScript.PORT_COLORS["positive"]
	var neg_fill: Color = GraphCanvasScript.dc_port_fill(neg, "negative")
	var pos_fill: Color = GraphCanvasScript.dc_port_fill(pos, "positive")
	if neg_fill.get_luminance() <= neg.get_luminance() + 0.01:
		push_error("DC− fill should be lifted off the wire colour for legibility")
		return 1
	if not pos_fill.is_equal_approx(pos):
		push_error("DC+ fill should stay the authored red")
		return 1
	# The two dots must be clearly distinguishable from each other.
	var sep := absf(pos_fill.r - neg_fill.r) + absf(pos_fill.g - neg_fill.g) \
			+ absf(pos_fill.b - neg_fill.b)
	if sep < 0.3:
		push_error("DC+ and DC− fills are too close to tell apart (%.2f)" % sep)
		return 1
	return 0


# --- Parallel-wire bundling (GraphWireBundles) -------------------------------

## Six panel leads (the bootcamp 3S2P's string ends, say) landing on ONE
## controller PV + port on its top edge. Before bundling all six left the same
## pixel and read as a knot.
func _six_into_one() -> Array:
	var wires: Array = []
	var port := Vector2(500.0, 400.0)
	for i: int in 6:
		# Panels in a row above, deliberately listed out of x order.
		var x := [700.0, 300.0, 520.0, 160.0, 860.0, 420.0][i] as float
		wires.append({"id": "c%d" % i, "src_key": "p%d|negative" % i, "tgt_key": "ctrl|pvPositive",
			"src_pos": Vector2(x, 120.0), "tgt_pos": port,
			"src_tan": Vector2.DOWN, "tgt_tan": Vector2.UP})
	return wires


func _test_bundle_six_into_one_port() -> int:
	var wires := _six_into_one()
	var plan: Dictionary = GraphWireBundles.plan(wires, 1.0)
	var teeth: Array = []
	var trunk := Vector2.INF
	for w: Dictionary in wires:
		var b: Dictionary = plan.get(w["id"], {})
		if not b.has("tgt") or b.has("src"):
			push_error("bundle: %s should be bundled at the controller end only, got %s" % [w["id"], str(b.keys())])
			return 1
		var e: Dictionary = b["tgt"]
		if trunk == Vector2.INF:
			trunk = e["trunk"]
		elif not (e["trunk"] as Vector2).is_equal_approx(trunk):
			push_error("bundle: the six wires must share ONE trunk")
			return 1
		# The trunk and teeth go OUT of the port (up, the port faces up).
		if (e["trunk"] as Vector2).y >= 400.0 or (e["tooth"] as Vector2).y >= (e["trunk"] as Vector2).y:
			push_error("bundle: comb must leave along the port's outward normal, got %s" % str(e))
			return 1
		teeth.append([(w["src_pos"] as Vector2).x, (e["tooth"] as Vector2).x])
	# Lanes are ordered like the far ends: no two lanes cross in the fan.
	teeth.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	var lane := GraphWireBundles.lane_px(6, 1.0)
	for i: int in range(1, teeth.size()):
		var gap := float(teeth[i][1]) - float(teeth[i - 1][1])
		if absf(gap - lane) > 0.01:
			push_error("bundle: lanes must be evenly spaced in far-end order (gap %.2f vs %.2f)" % [gap, lane])
			return 1
	# Centred on the port.
	var mid := (float(teeth[0][1]) + float(teeth[5][1])) * 0.5
	if absf(mid - 500.0) > 0.01:
		push_error("bundle: comb should be centred on the port, centre %.2f" % mid)
		return 1
	return 0


func _test_bundle_single_wire_untouched() -> int:
	var plan: Dictionary = GraphWireBundles.plan([{"id": "a", "src_key": "p|negative",
		"tgt_key": "c|pvNegative", "src_pos": Vector2(0, 0), "tgt_pos": Vector2(0, 300),
		"src_tan": Vector2.DOWN, "tgt_tan": Vector2.UP}], 1.0)
	if not plan.is_empty():
		push_error("bundle: a port with one wire must not get a comb, got %s" % str(plan))
		return 1
	return 0


## Hub ports (round tanks) spread their own wires; a wire bundled at BOTH ends
## (a parallel jumper between two shared terminals) gets two combs.
func _test_bundle_skip_and_both_ends() -> int:
	var wires := [
		{"id": "a", "src_key": "b1|positive", "tgt_key": "b2|positive", "src_pos": Vector2(0, 0),
			"tgt_pos": Vector2(300, 0), "src_tan": Vector2.UP, "tgt_tan": Vector2.UP},
		{"id": "b", "src_key": "b1|positive", "tgt_key": "b2|positive", "src_pos": Vector2(0, 0),
			"tgt_pos": Vector2(300, 0), "src_tan": Vector2.UP, "tgt_tan": Vector2.UP},
		{"id": "h1", "src_key": "tank|res_out_0", "tgt_key": "m1|res_in_0", "src_pos": Vector2(0, 500),
			"tgt_pos": Vector2(100, 700), "src_tan": Vector2.DOWN, "tgt_tan": Vector2.UP, "src_skip": true},
		{"id": "h2", "src_key": "tank|res_out_0", "tgt_key": "m2|res_in_0", "src_pos": Vector2(0, 500),
			"tgt_pos": Vector2(-100, 700), "src_tan": Vector2.DOWN, "tgt_tan": Vector2.UP, "src_skip": true},
	]
	var plan: Dictionary = GraphWireBundles.plan(wires, 1.0)
	for id: String in ["a", "b"]:
		var b: Dictionary = plan.get(id, {})
		if not (b.has("src") and b.has("tgt")):
			push_error("bundle: jumper %s should be combed at both ends, got %s" % [id, str(b)])
			return 1
	if plan.has("h1") or plan.has("h2"):
		push_error("bundle: hub-port ends (skip) must never be combed")
		return 1
	return 0


## Two wires whose far ends coincide: the lane order falls back to the id, so
## the same model always draws the same comb.
func _test_bundle_deterministic_ties() -> int:
	var w := [
		{"id": "zz", "src_key": "x|o", "tgt_key": "y|i", "src_pos": Vector2(0, 0), "tgt_pos": Vector2(0, 200),
			"src_tan": Vector2.DOWN, "tgt_tan": Vector2.UP},
		{"id": "aa", "src_key": "x|o", "tgt_key": "z|i", "src_pos": Vector2(0, 0), "tgt_pos": Vector2(0, 200),
			"src_tan": Vector2.DOWN, "tgt_tan": Vector2.UP},
	]
	var p1: Dictionary = GraphWireBundles.plan(w, 1.0)
	var w2 := [w[1], w[0]]
	var p2: Dictionary = GraphWireBundles.plan(w2, 1.0)
	for id: String in ["aa", "zz"]:
		var t1: Vector2 = (p1[id]["src"] as Dictionary)["tooth"]
		var t2: Vector2 = (p2[id]["src"] as Dictionary)["tooth"]
		if not t1.is_equal_approx(t2):
			push_error("bundle: lane of %s depends on input order (%s vs %s)" % [id, str(t1), str(t2)])
			return 1
	if int(p1["aa"]["src"]["index"]) != 0:
		push_error("bundle: ties should break on the connection id")
		return 1
	return 0


## Thirty wires on one terminal: the comb still fits MAX_SPREAD_PX.
func _test_bundle_spread_capped() -> int:
	var wires: Array = []
	for i: int in 30:
		wires.append({"id": "w%02d" % i, "src_key": "s%d|o" % i, "tgt_key": "bus|in",
			"src_pos": Vector2(float(i) * 40.0, 0.0), "tgt_pos": Vector2(600, 500),
			"src_tan": Vector2.DOWN, "tgt_tan": Vector2.UP})
	for z: float in [0.5, 1.0, 2.0]:
		var plan: Dictionary = GraphWireBundles.plan(wires, z)
		var lo := INF
		var hi := -INF
		for w: Dictionary in wires:
			var x: float = ((plan[w["id"]]["tgt"] as Dictionary)["tooth"] as Vector2).x
			lo = minf(lo, x)
			hi = maxf(hi, x)
		if hi - lo > GraphWireBundles.MAX_SPREAD_PX * z + 0.01:
			push_error("bundle: comb %.1f px wide at zoom %.1f exceeds the cap" % [hi - lo, z])
			return 1
	return 0


## The Display pref switches the comb off on the canvas.
func _test_bundle_canvas_pref_off() -> int:
	_canvas.set("wire_bundling", false)
	var plan: Dictionary = _canvas.call("_build_bundle_plan", [{}, {}], Vector2.ZERO)
	_canvas.set("wire_bundling", true)
	if not plan.is_empty():
		push_error("bundle: wire_bundling = false must give an empty plan")
		return 1
	return 0
