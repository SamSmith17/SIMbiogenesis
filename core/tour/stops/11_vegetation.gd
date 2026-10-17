extends TourStop

var _saved_month := -1


func _init() -> void:
	id = "vegetation"
	title = "Forests, seasons and growth"
	chapter = "Build"
	summary = "OSM forests become real trees that change with the seasons; paint your own."
	how = PackedStringArray(["Press V for the vegetation tools (Paint / Place / Clear / Select)",
		"Tune look… edits a species with a live preview",
		"Aim at a forest area and Interact to fill it with a chosen species"])
	action = "vegetation_edit"
	world = "mtvernon"
	budget_s = 40.0
	hour = 14.0
	blurb = ("Mapped woods, tree rows and hedges are scattered with species picked for " +
		"the site's climate. Trees leaf out, colour and drop their leaves with the " +
		"real latitude and date, grow on a calendar-driven life cycle, and fade to " +
		"baked impostors in the distance.")


func run(ctx: TourContext) -> void:
	var tb: Variant = ctx.loader.get("_edit_toolbar_ui") if ctx.loader != null else null
	if tb != null and is_instance_valid(tb):
		tb.call("open_with_section", "veg")
	_saved_month = int(ctx.main.get("month"))
	var p := ctx.player.global_position
	var f := ctx.player_forward()
	var eye := p - f * 10.0 + Vector3.UP * 38.0
	var look := p + f * 120.0
	ctx.place_camera(eye, look)
	ctx.caption("Summer", 2.0)
	ctx.main.set("month", 7)
	await ctx.wait(1.5)
	await ctx.fly([[eye, look], [eye + f * 30.0, look + f * 30.0]], 3.0)
	await ctx.hero()
	ctx.caption("Autumn — the same forest in October", 2.5)
	ctx.main.set("month", 10)
	await ctx.wait(3.0)
	ctx.caption("Winter", 2.0)
	ctx.main.set("month", 1)
	await ctx.wait(2.5)


func teardown(ctx: TourContext) -> void:
	if _saved_month > 0:
		ctx.main.set("month", _saved_month)
	var tb: Variant = ctx.loader.get("_edit_toolbar_ui") if ctx.loader != null else null
	if tb != null and is_instance_valid(tb) and bool((tb as Control).visible):
		tb.call("_exit_mode")
