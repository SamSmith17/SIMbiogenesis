extends TourStop


func _init() -> void:
	id = "site_plan"
	title = "Site Plan lens"
	chapter = "Systems"
	summary = "The same graph laid out on the real site, seen through a live 3D camera."
	how = PackedStringArray(["In the graph (G), click the Site Plan lens chip",
		"Drag empty canvas to orbit, wheel to zoom; drag a pin to move the thing in 3D"])
	action = "system_graph_toggle"
	button = "Site Plan lens"
	world = "mtvernon"
	budget_s = 35.0
	hour = 14.0
	blurb = ("Site Plan puts every placed item where it stands in the world, as pins " +
		"over a live render of the site within its Sphere of Influence. Moving a pin " +
		"moves the real object, and wires, streams, tagged spaces and people are " +
		"drawn on the ground.")


func run(ctx: TourContext) -> void:
	if not ctx.require(await ctx.open_graph("site"), "the graph opened on Site Plan"):
		return
	ctx.caption("Placed things as pins on the real site", 3.0)
	await ctx.wait(2.5)
	await ctx.hero()
	ctx.caption("Orbit the live camera", 2.5)
	await ctx.graph_orbit(Vector2(220.0, 70.0), 4.0)
	await ctx.wait(0.8)


func teardown(ctx: TourContext) -> void:
	ctx.reset_graph_orbit()
	ctx.close_graph()
