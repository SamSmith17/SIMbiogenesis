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
	_canvas.free()
	if fails == 0:
		print("GRAPH WIRE ROUTING SELFTEST PASS  (6 checks)")
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
