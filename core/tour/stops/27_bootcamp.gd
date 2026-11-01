extends TourStop

## Solar Bootcamp, level 1 played through: the brief, a wire from the
## battery's + to its −, the short circuit, the debrief. Levels 2 and 3 are
## the next two stops (27a, 27b).


func _init() -> void:
	id = "bootcamp"
	title = "Solar Bootcamp"
	chapter = "Systems"
	summary = "Twelve short levels that teach DC electrics by letting you blow things up. Level 1: a short circuit."
	how = PackedStringArray(["In the graph (G), click 🎓 Bootcamp",
		"Each level runs in a sandbox — your real graph is put back on exit"])
	button = "🎓 Bootcamp"
	world = "burningman"
	budget_s = 40.0
	hour = 14.0
	blurb = ("The tutorial starts with a short circuit and works up through overcharging, " +
		"PWM vs MPPT limits, series/parallel banks, string sizing and 24-hour runs. " +
		"Goals are judged on the circuit itself, and run levels on a pre-baked day.")


func run(ctx: TourContext) -> void:
	var td: Variant = await TourBootcamp.start_level(ctx, 1)
	if not ctx.require(td != null, "bootcamp level 1 started"):
		return
	ctx.caption("Level 1 of 12: “Don't Do This”", 3.0)
	await ctx.wait(3.2)
	await TourBootcamp.dismiss_brief(ctx, td)
	await TourBootcamp.frame_circuit(ctx)
	var bats := TourBootcamp.items(ctx, "battery")
	if not ctx.require(not bats.is_empty(), "the level seeded a battery"):
		return
	ctx.caption("The mission: wire the battery's + straight to its −", 3.0)
	await ctx.wait(1.0)
	await TourBootcamp.wire(ctx, bats[0], "positive", bats[0], "negative", 1.3)
	ctx.hide_pointer()
	ctx.caption("A short circuit: hundreds of amps through bare wire", 3.0)
	await ctx.wait(1.0)
	await ctx.hero()
	ctx.require(await TourBootcamp.wait_state(ctx, td, TourBootcamp.STATE_DEBRIEF, 8.0),
		"level 1 completed (the debrief came up)")
	ctx.caption("The debrief explains it — and unlocks solar panels", 3.0)
	await ctx.wait(3.5)


func teardown(ctx: TourContext) -> void:
	await TourBootcamp.finish(ctx)
