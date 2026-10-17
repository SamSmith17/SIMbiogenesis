extends TourStop


func _init() -> void:
	id = "festival_mode"
	title = "Festival mode"
	chapter = "People"
	summary = "One button: every painted camp gets people, venues are seeded, and the crowd comes alive."
	how = PackedStringArray(["Click the Festival chip on the timeline",
		"The settlement view opens over the camps; Evening / Morning jump the clock",
		"Leave keeps the camps; Clear seeded removes the venues it added"])
	button = "Festival"
	world = "walton"
	budget_s = 75.0
	hour = 20.4
	blurb = ("Festival mode runs the crowd simulation on easy supplies: hundreds of " +
		"people with needs, friend groups and tastes, living a festival day between " +
		"their camps, kitchens, portapotties, the bass stage and the temple. Nearby " +
		"people are full agents; the distant crowd is simulated as events and drawn " +
		"on the GPU.")


func run(ctx: TourContext) -> void:
	ctx.caption("Populating the camps and seeding the venues…", 3.0)
	var sv: Variant = await ctx.open_festival()
	if not ctx.require(sv != null, "festival mode opened the settlement view"):
		return
	ctx.run_clock(90.0)
	var stage: Variant = ctx.space_xz("stage")
	var where: Vector2 = stage if stage is Vector2 else ctx.player_xz()
	ctx.settle_cam(where, 420.0, true)
	ctx.caption("Hundreds of people, each with their own day", 3.0)
	await ctx.wait(3.0)
	ctx.settle_cam(where, 70.0)
	ctx.caption("The evening set at the bass stage", 3.0)
	await ctx.wait(5.0)
	await ctx.hero()
	ctx.settle_cam(where, 28.0)
	await ctx.wait(3.0)


func teardown(ctx: TourContext) -> void:
	if ctx.main.has_method("close_festival_mode"):
		ctx.main.call("close_festival_mode")
