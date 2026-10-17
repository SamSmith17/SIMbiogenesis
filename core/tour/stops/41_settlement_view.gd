extends TourStop


func _init() -> void:
	id = "settlement_view"
	title = "Settlement view"
	chapter = "People"
	summary = "Watch the community work: one camera from eye level up to the whole site."
	how = PackedStringArray(["Click the Settlement chip on the timeline",
		"Wheel zooms from ground to site, drag pans, click a person to follow them",
		"The work dock edits priorities and chores without leaving the view"])
	button = "Settlement"
	world = "walton"
	budget_s = 50.0
	hour = 14.0
	blurb = ("The second play mode: you shape the conditions — spaces, routines, chores, " +
		"site rules — then watch. There are no orders; people decide for themselves " +
		"from their needs, morale and the work on the board, and the camera never " +
		"stops the clock.")


func run(ctx: TourContext) -> void:
	var sv: Variant = await ctx.open_festival()
	if not ctx.require(sv != null, "the settlement view opened"):
		return
	ctx.run_clock(30.0)
	var kitchen: Variant = ctx.space_xz("kitchen")
	var c: Vector2 = kitchen if kitchen is Vector2 else ctx.player_xz()
	ctx.settle_cam(c, 900.0, true)
	ctx.caption("Site", 1.6)
	await ctx.wait(1.8)
	for step in [[280.0, "Camp"], [60.0, "Block"], [14.0, "Street"]]:
		ctx.settle_cam(c, float(step[0]))
		ctx.caption(str(step[1]), 1.6)
		await ctx.wait(2.2)
		if str(step[1]) == "Block":
			await ctx.hero()
	ctx.caption("Click anyone to see what they're doing and why", 3.0)
	await ctx.wait(2.5)


func teardown(ctx: TourContext) -> void:
	if ctx.main.has_method("close_festival_mode"):
		ctx.main.call("close_festival_mode")
