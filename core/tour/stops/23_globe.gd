extends TourStop


func _init() -> void:
	id = "globe"
	title = "Globe lens"
	chapter = "Systems"
	summary = "The Sphere of Influence as a snowglobe you orbit inside the graph."
	how = PackedStringArray(["In the graph (G), click the Globe lens chip",
		"Drag to orbit, wheel to zoom, double-click to re-fit"])
	action = "system_graph_toggle"
	button = "Globe lens"
	world = "mtvernon"
	budget_s = 30.0
	hour = 14.0
	blurb = ("The Globe lens frames the site's Sphere of Influence — the area the " +
		"community draws its resources from — as a glass globe with the real sun on " +
		"its rim and the strata of the ground below. Pins on it are the same items " +
		"as in every other lens.")


func run(ctx: TourContext) -> void:
	if not ctx.require(await ctx.open_graph("globe"), "the graph opened on the Globe"):
		return
	ctx.caption("The Sphere of Influence", 2.5)
	await ctx.wait(2.0)
	await ctx.graph_orbit(Vector2(260.0, 30.0), 4.0)
	await ctx.hero()
	await ctx.graph_orbit(Vector2(140.0, -40.0), 2.0)


func teardown(ctx: TourContext) -> void:
	ctx.reset_graph_orbit()
	ctx.close_graph()
