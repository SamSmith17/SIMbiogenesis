extends TourStop


func _init() -> void:
	id = "bootcamp"
	title = "Solar Bootcamp"
	chapter = "Systems"
	summary = "Twelve short levels that teach DC electrics by letting you blow things up."
	how = PackedStringArray(["In the graph (G), click 🎓 Bootcamp",
		"Each level runs in a sandbox — your real graph is put back on exit"])
	button = "🎓 Bootcamp"
	world = "burningman"
	budget_s = 30.0
	hour = 14.0
	blurb = ("The tutorial starts with a short circuit and works up through overcharging, " +
		"PWM vs MPPT limits, series/parallel banks, string sizing and 24-hour runs. " +
		"Goals are judged on the circuit itself, and run levels on a pre-baked day.")


func run(ctx: TourContext) -> void:
	if ctx.graph == null:
		ctx.require(false, "the graph exists")
		return
	var td: Variant = ctx.graph.call("_ensure_tutorial_director")
	if not ctx.require(td != null, "the tutorial director exists"):
		return
	td.call("start", "")
	await ctx.wait(2.5)
	ctx.require(bool(td.call("is_active")), "a bootcamp level started")
	ctx.caption("A level: build the circuit the goal asks for", 3.0)
	await ctx.wait(3.0)
	await ctx.hero()
	await ctx.wait(1.0)


func teardown(ctx: TourContext) -> void:
	var td: Variant = ctx.graph.get("_tutorial_director") if ctx.graph != null else null
	if td != null and is_instance_valid(td) and bool(td.call("is_active")):
		td.call("exit_tutorial")
		await ctx.wait(1.0)
	ctx.close_graph()
