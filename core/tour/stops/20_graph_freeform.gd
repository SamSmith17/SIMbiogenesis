extends TourStop


func _init() -> void:
	id = "graph_freeform"
	title = "The systems graph"
	chapter = "Systems"
	summary = "Every panel, battery, tank, turbine and habitat as nodes, with power and water flowing."
	how = PackedStringArray(["Press G to open the graph",
		"Drag parts from the library on the left; wire ports together",
		"Click a node for its inspector; Ctrl+G groups into a super-node"])
	action = "system_graph_toggle"
	world = "mtvernon"
	budget_s = 35.0
	hour = 14.0
	blurb = ("The graph is the core game surface: a schematic of the resource flows on " +
		"the site. Solar strings are checked against the controller's voltage window, " +
		"batteries form real series/parallel banks, water moves through tanks, ponds " +
		"and turbines, and it all keeps simulating with the graph closed.")


func run(ctx: TourContext) -> void:
	if not ctx.require(await ctx.open_graph("freeform"), "the graph opened"):
		return
	await ctx.wait(1.5)
	ctx.caption("The site's power and water, as a live schematic", 3.0)
	await ctx.wait(2.5)
	var picks := ctx.graph_items(func(it: Dictionary) -> bool:
		return str(it.get("type", "")) in ["controller", "battery", "smartbattery"])
	if not picks.is_empty():
		ctx.graph_select(str((picks[0] as Dictionary).get("id", "")))
		ctx.caption("Click a node: live readouts and settings", 3.0)
		await ctx.wait(2.0)
	await ctx.hero()
	await ctx.wait(1.5)


func teardown(ctx: TourContext) -> void:
	ctx.close_graph()
