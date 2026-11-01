extends TourStop

## Solar Bootcamp, level 3: the panel through a PWM charge controller into
## the battery. It works — at 120 W of a 300 W panel, which is the lesson.


func _init() -> void:
	id = "bootcamp_controller"
	title = "Bootcamp 3: You've Got Power… Some of It"
	chapter = "Systems"
	summary = "Do it right through a charge controller, then see how much of the panel it can use."
	how = PackedStringArray(["In the graph (G), click 🎓 Bootcamp, then level 3"])
	button = "🎓 Bootcamp"
	world = "burningman"
	budget_s = 45.0
	hour = 14.0
	blurb = ("Panel into the PWM controller's PV inputs, controller into the battery: it " +
		"charges. But a controller delivers at the battery's voltage, capped at its rated " +
		"current — 12 V × 10 A = 120 W of the 300 W panel. The next levels are about " +
		"getting the rest.")


func run(ctx: TourContext) -> void:
	var td: Variant = await TourBootcamp.start_level(ctx, 3)
	if not ctx.require(td != null, "bootcamp level 3 started"):
		return
	ctx.caption("Level 3: now with a PWM charge controller", 3.0)
	await ctx.wait(3.2)
	await TourBootcamp.dismiss_brief(ctx, td)
	await TourBootcamp.frame_circuit(ctx)
	var bats := TourBootcamp.items(ctx, "battery")
	var pans := TourBootcamp.items(ctx, "panel")
	var ctls := TourBootcamp.items(ctx, "controller")
	if not ctx.require(not bats.is_empty() and not pans.is_empty() and not ctls.is_empty(),
			"the level seeded a panel, a controller and a battery"):
		return
	ctx.caption("Panel into the controller's PV inputs…", 2.6)
	await ctx.wait(0.6)
	await TourBootcamp.wire(ctx, pans[0], "positive", ctls[0], "pvPositive", 1.0)
	await TourBootcamp.wire(ctx, pans[0], "negative", ctls[0], "pvNegative", 1.0)
	ctx.caption("…and the controller into the battery", 2.6)
	await TourBootcamp.wire(ctx, ctls[0], "batteryPositive", bats[0], "positive", 1.0)
	await TourBootcamp.wire(ctx, ctls[0], "batteryNegative", bats[0], "negative", 1.0)
	ctx.hide_pointer()
	ctx.caption("Charging — but 12 V × 10 A is only 120 W of the 300 W panel", 3.4)
	await ctx.wait(1.2)
	await ctx.hero()
	ctx.require(await TourBootcamp.wait_state(ctx, td, TourBootcamp.STATE_DEBRIEF, 10.0),
		"level 3 completed (the debrief came up)")
	ctx.caption("Nine more levels: MPPT, bigger banks, strings and 24-hour runs", 3.2)
	await ctx.wait(3.6)


func teardown(ctx: TourContext) -> void:
	await TourBootcamp.finish(ctx)
