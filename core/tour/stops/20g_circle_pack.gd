extends TourStop

## Circles inside circles: the site's nested systems (groups, camps,
## vehicles, an array's strings of panels) as a zoomable circle pack, then
## what the stores hold, down to the elements in them. Opened from the
## graph's View options; the window is closed again after.


func _init() -> void:
	id = "circle_pack"
	title = "Circles inside circles"
	chapter = "Systems"
	summary = "Everything nested on the site (groups, arrays and their strings, stores and what they hold) as zoomable circles."
	how = PackedStringArray(["Press G, then View options ▾ → Nesting as circles…",
		"Click a circle to fly into it; right-click or Backspace to come back out",
		"Size by one each, rated power or mass; tabs for what the stores hold and what the site is built from",
		"A group's inspector has See inside as circles; a store's has its make-up"])
	action = "system_graph_toggle"
	world = "mtvernon"
	budget_s = 45.0
	hour = 13.0
	blurb = ("Every group on the graph, the camps and vehicles with their own systems, a solar " +
		"array's strings of panels, as circles inside circles. Click one to fly into it, " +
		"right-click to come back out; size them one each, by rated power or by mass. The " +
		"same view shows what the stores hold, each store split into what it is made of down " +
		"to the elements, and what the site's structures are built from, down to their parts.")


func run(ctx: TourContext) -> void:
	if not ctx.require(await ctx.open_graph("freeform"), "the graph opened"):
		return
	var g := ctx.graph
	var win: Variant = g.call("open_circle_pack", "systems", "")
	if not ctx.require(win != null, "the circle pack opened"):
		return
	ctx.caption("The site's systems as circles inside circles", 3.5)
	await ctx.wait(2.5)
	await ctx.hero()
	var view: CirclePackView = win.call("view")
	var best := -1
	var best_r := 0.0
	for i in view.nodes.size():
		var d: Dictionary = view.nodes[i]
		if int(d["depth"]) == 1 and not bool(d["leaf"]) and float(d["r"]) > best_r:
			best = i
			best_r = float(d["r"])
	if best >= 0:
		ctx.caption("Click a circle to fly into it", 3.0)
		view.zoom_to(best)
		await ctx.wait(2.6)
		view.zoom_home()
		await ctx.wait(1.6)
	win.call("set_size_by", CirclePackSources.SIZE_POWER)
	ctx.caption("Sized by rated power", 2.6)
	await ctx.wait(2.4)
	win.call("set_source", "stores")
	ctx.caption("What the stores hold, down to the elements", 3.0)
	await ctx.wait(3.0)
	win.call("set_source", "built")
	ctx.caption("What the site is built from", 2.6)
	await ctx.wait(2.6)


func teardown(ctx: TourContext) -> void:
	var w := CirclePackWindow.current()
	if w != null:
		w.close()
	if ctx.graph != null:
		ctx.close_graph()
