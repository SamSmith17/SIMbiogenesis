extends TourStop


func _init() -> void:
	id = "day_night"
	title = "Time, sun and sky"
	chapter = "World"
	summary = "Scrub the clock: the real sun path, sunsets and twilight for the site's date."
	how = PackedStringArray(["Drag the timeline at the bottom of the screen",
		"Space plays and pauses; the speed buttons run time faster"])
	button = "the timeline"
	world = "burningman"
	budget_s = 40.0
	hour = 15.0
	blurb = ("The clock is reversible: sun, moon, sky, weather and even the battery " +
		"scrub backwards along exactly the curve they followed forwards. The " +
		"sunlight, skylight and colour all come from one daylight model, so a sunrise " +
		"fades in instead of switching on.")


func run(ctx: TourContext) -> void:
	var set_h := ctx.hour_for_sun(1.5, true)
	if is_nan(set_h):
		set_h = 19.0
	# Look toward the setting sun.
	ctx.set_hour(set_h)
	var clock: Variant = ctx.main.get("clock")
	var sd: Vector3 = clock.call("get_sun_direction") if clock != null else Vector3(-1, 0, 0)
	var flat := Vector3(sd.x, 0.0, sd.z).normalized() if Vector2(sd.x, sd.z).length() > 1e-3 else Vector3.LEFT
	var p := ctx.player.global_position
	var eye := p + Vector3.UP * 14.0 - flat * 30.0
	ctx.place_camera(eye, eye + flat * 100.0 + Vector3.UP * 6.0)
	ctx.set_hour(set_h - 3.0)
	await ctx.frames(2)
	ctx.caption("Afternoon to sunset, on the site's real date", 3.0)
	await ctx.scrub(set_h - 3.0, set_h - 0.05, 6.0)
	await ctx.wait(0.4)
	await ctx.hero(true)
	ctx.caption("…and into twilight", 2.5)
	await ctx.scrub(set_h - 0.05, set_h + 1.2, 4.0)
	await ctx.wait(0.8)
