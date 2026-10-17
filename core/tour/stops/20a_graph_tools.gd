extends TourStop

## The graph's own tools: Tidy (the force layout that puts sources above
## controllers above storage above loads), and the Show ▾ views that keep only
## one kind of flow on screen. The player's layout and view are put back.

var _pos := {}
var _filter := {}


func _init() -> void:
	id = "graph_tools"
	title = "Graph tools: Tidy and show-only views"
	chapter = "Systems"
	summary = "Lay the graph out in one click, then show only the power, or only the water."
	how = PackedStringArray(["Press G, then Layout ▾ → Tidy (Live keeps it laid out as you edit)",
		"Show ▾ → Power / Water / Food & waste / Fuel & heat, or tick your own",
		"Library → In the world: what is built but not on the graph yet"])
	action = "system_graph_toggle"
	world = "mtvernon"
	budget_s = 40.0
	hour = 14.0
	blurb = ("Tidy is a force layout whose direction comes from the ports — inputs on " +
		"top, outputs below — so sources settle above controllers above storage above " +
		"loads, solar arrays move as one block, and pinned nodes stay put. Show-only " +
		"views hide every node and wire outside the chosen kinds of flow without " +
		"removing anything, and the library's In the world drawer lists what is placed " +
		"on the site but not yet on the graph.")


func run(ctx: TourContext) -> void:
	if not ctx.require(await ctx.open_graph("freeform"), "the graph opened"):
		return
	var g := ctx.graph
	var model: Variant = g.get("model")
	var scope := str(g.get("_active_scope_id"))
	_pos = {}
	if model != null:
		for it in model.call("get_items_in_scope", scope if not scope.is_empty() else "root"):
			var d: Dictionary = it
			_pos[str(d.get("id", ""))] = Vector2(float(d.get("x", 0.0)), float(d.get("y", 0.0)))
	_filter = g.call("get_domain_filter")
	await ctx.wait(1.0)
	ctx.caption("Layout ▾ → Tidy: sources above controllers above storage above loads", 3.5)
	ctx.require(bool(g.call("tidy_layout", true, true)), "Tidy laid the graph out")
	# The layout animates in real time whatever the tour's pace; wait it out.
	var drv: Variant = g.get("_layout_driver")
	var t := 0.0
	while drv != null and bool(drv.call("is_animating")) and t < 6.0 and not ctx.cancelled:
		await ctx.frames(1)
		t += ctx.host.get_process_delta_time()
	await ctx.wait(1.0)
	var canvas: Variant = g.get("_graph_canvas")
	if canvas != null and canvas.has_method("fit_scope_to_view"):
		canvas.call("fit_scope_to_view")
	await ctx.wait(1.0)
	var df := ctx.klass("GraphDomainFilter")
	if df != null:
		g.call("set_domain_filter", df.call("preset", "power"))
		ctx.caption("Show ▾ → Power: only the electrical system", 3.0)
		await ctx.wait(2.5)
		await ctx.hero()
		g.call("set_domain_filter", df.call("preset", "water"))
		ctx.caption("Show ▾ → Water: ponds, tanks, pipes and turbines", 3.0)
		await ctx.wait(3.0)
	else:
		await ctx.hero()


func teardown(ctx: TourContext) -> void:
	var g := ctx.graph
	if g == null:
		return
	g.call("set_domain_filter", _filter)
	var model: Variant = g.get("model")
	if model != null:
		for iid in _pos:
			var it: Dictionary = model.call("get_item", str(iid))
			if it.is_empty():
				continue
			var p: Vector2 = _pos[iid]
			it["x"] = p.x
			it["y"] = p.y
	var canvas: Variant = g.get("_graph_canvas")
	if canvas != null:
		(canvas as CanvasItem).queue_redraw()
	_pos = {}
	ctx.close_graph()
