extends RefCounted

## Sandbox, read-only: what one hover motion over the open graph (freeform)
## costs, piece by piece: the V2 canvas's item hit test, path focus, hover
## emit, port hit test, and the whole motion event; over a node and over
## empty canvas. Median of 40 calls each.
##   tools\harness.ps1 -World walton -RunScript res://tools/diag/graph_hover_cost_probe.gd

const HI := preload("res://core/terrain/harness/harness_input.gd")


func _time(c: Callable, n: int = 40) -> float:
	c.call()
	var ts: Array = []
	for i in n:
		var t := Time.get_ticks_usec()
		c.call()
		ts.append(float(Time.get_ticks_usec() - t) / 1000.0)
	ts.sort()
	return float(ts[ts.size() / 2])


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	for _i in 200:
		await tree.process_frame
	var v: Node = main.find_child("SystemGraphView", true, false)
	if v == null:
		return {"ok": false, "why": "no SystemGraphView"}
	v.call("open_graph_view")
	for _i in 60:
		await tree.process_frame
	v.call("_apply_graph_view_mode", GraphSiteLayout.VIEW_FREEFORM)
	for _i in 90:
		await tree.process_frame
	var canvas: Control = v.get("_graph_canvas")
	var model: GraphModel = v.get("model")
	var vp := main.get_viewport()
	var center := canvas.size * 0.5
	var node_pos := Vector2.ZERO
	for it: Dictionary in model.get_items_in_scope(str(canvas.get("active_scope_id"))):
		var tl: Vector2 = canvas.call("_item_screen_tl", it, center)
		var sz: Vector2 = canvas.call("_item_screen_size", it)
		var c := tl + sz * 0.5
		if sz.x > 30.0 and Rect2(Vector2(100, 100), canvas.size - Vector2(200, 200)).has_point(c):
			node_pos = c
			break
	var empty_pos := Vector2(40.0, canvas.size.y - 40.0)
	var r: float = canvas.call("_port_grab_radius")
	for spot in [["node", node_pos], ["empty", empty_pos]]:
		var p: Vector2 = spot[1]
		var hov := str((canvas.call("_item_at_screen", p) as Dictionary).get("id", ""))
		var gp := canvas.get_global_transform() * p
		var parts := {
			"_item_at_screen": func() -> void: canvas.call("_item_at_screen", p),
			"set_path_focus": func() -> void: canvas.call("set_path_focus", hov),
			"_set_hover_item": func() -> void: canvas.call("_set_hover_item", hov),
			"_port_at_screen": func() -> void: canvas.call("_port_at_screen", p, "", "", r),
			"whole motion event": func() -> void: HI._push_motion(vp, gp, false, false, false),
		}
		for k in parts.keys():
			print("graphhover %-6s %-22s median %7.3f ms" % [str(spot[0]), k, _time(parts[k])])
	print("graphhover: %d items, %d wires" % [model.items.size(), model.connections.size()])
	# The cull against a full scan: the same port (or none) at every point of
	# a grid over the canvas, and near every port; then the time both ways.
	var ok := true
	var worst_out := 0.0
	var pts: Array = []
	for gx in 48:
		for gy in 28:
			pts.append(Vector2((gx + 0.5) * canvas.size.x / 48.0, (gy + 0.5) * canvas.size.y / 28.0))
	for it: Dictionary in canvas.call("_visible_items"):
		var tl: Vector2 = canvas.call("_item_screen_tl", it, center)
		var sz: Vector2 = canvas.call("_item_screen_size", it)
		var rect := Rect2(tl, sz).abs()
		for h: Dictionary in canvas.call("_get_all_handle_infos", it, center):
			var hp: Vector2 = h["pos"]
			var out := 0.0
			if not rect.has_point(hp):
				var cp := Vector2(clampf(hp.x, rect.position.x, rect.end.x), clampf(hp.y, rect.position.y, rect.end.y))
				out = cp.distance_to(hp) / maxf(maxf(sz.x, sz.y), 1.0)
			worst_out = maxf(worst_out, out)
			for o in [Vector2.ZERO, Vector2(r * 0.6, 0.0), Vector2(0.0, -r * 0.9), Vector2(-r * 0.3, r * 0.3)]:
				pts.append(hp + o)
	var diffs := 0
	for q: Vector2 in pts:
		canvas.set("port_hit_cull", true)
		var a1: Dictionary = canvas.call("_port_at_screen", q, "", "", r)
		canvas.set("port_hit_cull", false)
		var b1: Dictionary = canvas.call("_port_at_screen", q, "", "", r)
		var ka := str(a1.get("item_id", "")) + "|" + str(a1.get("handle_id", ""))
		var kb := str(b1.get("item_id", "")) + "|" + str(b1.get("handle_id", ""))
		if ka != kb:
			diffs += 1
	canvas.set("port_hit_cull", true)
	ok = diffs == 0
	print("graphhover: %d points, %d with a different port (%s); furthest port outside its card %.2f card sizes" % [
		pts.size(), diffs, "PASS" if ok else "FAIL", worst_out])
	for mode in [true, false]:
		canvas.set("port_hit_cull", mode)
		var p2: Vector2 = node_pos
		print("graphhover cull %-5s _port_at_screen over a node median %.3f ms" % [str(mode),
			_time(func() -> void: canvas.call("_port_at_screen", p2, "", "", r))])
	canvas.set("port_hit_cull", true)
	return {"ok": ok}
