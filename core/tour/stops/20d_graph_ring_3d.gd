extends TourStop

## The ring arrangement in 3D: the graph as a cell (machines on the outer
## sphere, the stores they share on an inner one, the people at the centre,
## the wires through the inside), turned with a real Ctrl+drag; then the
## same ring as a torus. The player's layout, arrangement and view are put
## back.

var _pos := {}
var _schema := ""
var _view3d := {}


func _init() -> void:
	id = "graph_ring_3d"
	title = "The ring in 3D: a cell, or a torus"
	chapter = "Systems"
	summary = "See the ring arrangement as nested spheres or a torus and orbit it with Ctrl+drag."
	how = PackedStringArray(["Press G, then Layout ▾ → Ring in 3D → nested spheres or torus",
		"Ctrl+drag to orbit, drag a card to move it over its shell",
		"Double-click a group to open it; Esc comes back out"])
	action = "system_graph_toggle"
	world = "mtvernon"
	budget_s = 45.0
	hour = 14.0
	blurb = ("The ring arrangement seen in space. As nested spheres the graph reads as a cell: " +
		"the machines spread evenly over an outer membrane, one band per system, the stores " +
		"they share on an inner nucleus, each toward the machines it is wired to, the people " +
		"at the centre and the wires running through the inside. As a torus the machines run " +
		"round its outer circumference at their ring angles and the stores round its inner " +
		"edge. Ctrl+drag orbits; nothing about the flat graph changes.")


func run(ctx: TourContext) -> void:
	if not ctx.require(await ctx.open_graph("freeform"), "the graph opened"):
		return
	var g := ctx.graph
	var model: Variant = g.get("model")
	var canvas: Control = g.get("_graph_canvas")
	_pos = {}
	if model != null:
		for it in model.call("get_items_in_scope", "root"):
			var d: Dictionary = it
			_pos[str(d.get("id", ""))] = Vector2(float(d.get("x", 0.0)), float(d.get("y", 0.0)))
	_schema = str(g.get("_layout_schema"))
	_view3d = canvas.call("view_3d_state")
	var s3 := ctx.klass("GraphSchema3D")
	await ctx.wait(0.8)
	ctx.caption("Layout ▾ → Ring in 3D → nested spheres: the graph as a cell", 3.5)
	g.call("set_graph_3d", "sphere")
	await ctx.wait(1.6)
	ctx.require(str(canvas.call("view_3d_mode")) == "sphere", "the 3D view is up")
	ctx.caption("Machines on the membrane, the stores they share in the nucleus", 3.5)
	await _ctrl_orbit(ctx, canvas, Vector2(260.0, -40.0), 2.6)
	await ctx.wait(0.8)
	await ctx.hero()
	ctx.caption("Ctrl+drag to orbit: the wires run through the inside", 3.0)
	await _ctrl_orbit(ctx, canvas, Vector2(-180.0, 90.0), 2.2)
	await ctx.wait(0.6)
	if s3 != null:
		ctx.caption("The same ring as a torus: stores round the hole", 3.5)
		g.call("set_graph_3d", "torus")
		await ctx.wait(1.6)
		await _ctrl_orbit(ctx, canvas, Vector2(220.0, 30.0), 2.4)
		await ctx.wait(1.0)


## A real Ctrl+drag across empty canvas, with the tour's pointer on it.
func _ctrl_orbit(ctx: TourContext, canvas: Control, delta: Vector2, seconds: float) -> void:
	if ctx.cancelled:
		return
	var vp := ctx.tree().root.get_viewport()
	var a_local := Vector2(canvas.size.x * 0.18, canvas.size.y * 0.78)
	var a := canvas.get_global_transform_with_canvas() * a_local
	var b := a + delta
	await ctx.pointer_to(a)
	if ctx.captions != null:
		ctx.captions.pointer_at(a, true)
	await HarnessInput.mouse_press(vp, a, true, false, true)
	var dur := maxf(seconds * ctx.pace, 0.1)
	var t := 0.0
	while t < dur and not ctx.cancelled:
		var p := a.lerp(b, t / dur)
		if ctx.captions != null:
			ctx.captions.pointer_at(p, true)
		await HarnessInput.mouse_move(vp, p, true, false, true)
		t += ctx.host.get_process_delta_time()
	HarnessInput._push_motion(vp, b, true, false, true)
	await HarnessInput.mouse_press(vp, b, false, false, true)
	if ctx.captions != null:
		ctx.captions.pointer_at(b, false)


func teardown(ctx: TourContext) -> void:
	var g := ctx.graph
	if g == null:
		return
	g.call("set_graph_3d", "", false)
	var canvas: Variant = g.get("_graph_canvas")
	if canvas != null:
		canvas.call("apply_view_3d_state", _view3d)
	var model: Variant = g.get("model")
	if model != null:
		for iid in _pos:
			var it: Dictionary = model.call("get_item", str(iid))
			if it.is_empty():
				continue
			var p: Vector2 = _pos[iid]
			it["x"] = p.x
			it["y"] = p.y
	g.set("_layout_schema", _schema)
	g.call("_sync_layout_regions")
	g.call("_sync_3d_menu_checks")
	if canvas != null:
		(canvas as CanvasItem).queue_redraw()
	_pos = {}
	ctx.close_graph()
