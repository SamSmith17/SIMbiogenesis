extends TourStop

## Flow you can read: the graph's wires as a Sankey (width in proportion to
## what each carries, in each resource's own scale, streaks moving faster
## where more flows), then the Flows lens: the scope laid out as a loop
## Sankey, sources on top, flow running down, what cycles back returning up
## the sides. The player's flow style and lens are put back.

var _style_was := {}
var _view_was := ""


func _init() -> void:
	id = "flow_lens"
	title = "Flows: a Sankey that can loop"
	chapter = "Systems"
	summary = "Wires as wide as what they carry, and a lens that lays the graph out as a loop Sankey."
	how = PackedStringArray(["Press G, then View options ▾ → Flow: Sankey (or Flow style… to tune it)",
		"Click the Flows lens: sources on top, returns up the sides",
		"Hover a return to light its loop; pick a resource or a time window at the top"])
	action = "system_graph_toggle"
	world = "mtvernon"
	budget_s = 45.0
	hour = 13.0
	blurb = ("Every wire is drawn as a ribbon as wide as what it carries, measured against the " +
		"biggest flow of the same resource on screen, so watts and litres each keep their own " +
		"scale (the legend says what a width means). Streaks move faster where more flows and " +
		"never strobe at speed. The Flows lens lays the scope out as a Sankey that can loop: " +
		"the main stream runs down the page, and what cycles back, water reused, nutrients " +
		"returned to the beds, runs up the sides like field lines, with how much of each " +
		"resource cycles (Finn's cycling index) in the header.")


func run(ctx: TourContext) -> void:
	if not ctx.require(await ctx.open_graph("freeform"), "the graph opened"):
		return
	var g := ctx.graph
	_style_was = g.call("flow_style")
	_view_was = str(g.get("_graph_view_mode"))
	ctx.run_clock(60.0)
	g.call("set_flow_style", {"preset": "sankey"}, false)
	ctx.caption("Each wire as wide as what it carries, in its own resource's scale", 3.5)
	await ctx.wait(2.5)
	await ctx.hero()
	g.call("set_flow_style", {"preset": "bold"}, false)
	ctx.caption("Bold: ribbons stay thick when you zoom out", 3.0)
	await ctx.wait(2.2)
	g.call("_on_mode_chip_pressed", "flows")
	ctx.caption("The Flows lens: sources on top, the stream runs down", 3.5)
	await ctx.wait(3.0)
	var canvas: Variant = g.get("_graph_canvas")
	if canvas != null:
		ctx.caption("What cycles back returns up the sides, like field lines", 3.5)
		canvas.call("set_flows_window", "24h")
		await ctx.wait(3.0)
		canvas.call("set_flows_window", "now")
	await ctx.wait(1.0)


func teardown(ctx: TourContext) -> void:
	var g := ctx.graph
	if g == null:
		return
	if not _style_was.is_empty():
		g.call("set_flow_style", _style_was, false)
	g.call("_on_mode_chip_pressed", _view_was if _view_was != "" else "freeform")
	ctx.run_clock(0.0)
	ctx.close_graph()
