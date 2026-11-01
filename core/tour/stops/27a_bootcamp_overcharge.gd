extends TourStop

## Solar Bootcamp, level 2: a 40 V panel wired straight to a 12 V battery
## boils it. The lesson that makes a charge controller necessary.


func _init() -> void:
	id = "bootcamp_overcharge"
	title = "Bootcamp 2: Panels Push Too Hard"
	chapter = "Systems"
	summary = "Wire a solar panel straight to a battery and find out why nobody does."
	how = PackedStringArray(["In the graph (G), click 🎓 Bootcamp, then level 2"])
	button = "🎓 Bootcamp"
	world = "burningman"
	budget_s = 40.0
	hour = 14.0
	blurb = ("A 300 W panel's open-circuit voltage is 40 V; a 12 V battery must never see more " +
		"than about 14.6 V. Wired directly, the panel drives the cells past their ceiling " +
		"and the battery is ruined, which unlocks the charge controller.")


func run(ctx: TourContext) -> void:
	var td: Variant = await TourBootcamp.start_level(ctx, 2)
	if not ctx.require(td != null, "bootcamp level 2 started"):
		return
	ctx.caption("Level 2: a 300 W panel and a 12 V battery", 3.0)
	await ctx.wait(3.2)
	await TourBootcamp.dismiss_brief(ctx, td)
	await TourBootcamp.frame_circuit(ctx)
	var bats := TourBootcamp.items(ctx, "battery")
	var pans := TourBootcamp.items(ctx, "panel")
	if not ctx.require(not bats.is_empty() and not pans.is_empty(), "the level seeded a panel and a battery"):
		return
	ctx.caption("Panel + to battery +, panel − to battery −", 3.0)
	await ctx.wait(0.8)
	await TourBootcamp.wire(ctx, pans[0], "positive", bats[0], "positive", 1.2)
	await TourBootcamp.wire(ctx, pans[0], "negative", bats[0], "negative", 1.2)
	ctx.hide_pointer()
	ctx.caption("40 V into a battery that stops at 14.6 V: it boils", 3.0)
	await ctx.wait(1.0)
	await ctx.hero()
	ctx.require(await TourBootcamp.wait_state(ctx, td, TourBootcamp.STATE_DEBRIEF, 8.0),
		"level 2 completed (the debrief came up)")
	ctx.caption("Panels never go straight to batteries — unlocked: charge controllers", 3.2)
	await ctx.wait(3.6)


func teardown(ctx: TourContext) -> void:
	await TourBootcamp.finish(ctx)
