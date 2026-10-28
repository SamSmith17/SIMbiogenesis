extends TourStop


func _init() -> void:
	id = "weather"
	title = "Weather and extreme events"
	chapter = "World"
	summary = "Archived and forecast weather drive the sky; smoke, dust and heat can be simulated."
	how = PackedStringArray(["Weather follows Open-Meteo automatically (the 🌤 / 🌎 indicator)",
		"Settings ⚙ → Extreme Weather → Preview a hazard",
		"🌫 on the timeline calibrates local fog and wind"])
	button = "⚙ → Extreme Weather"
	world = "burningman"
	budget_s = 40.0
	hour = 14.0
	blurb = ("Clouds, wind, temperature and rain come from the real hourly record for " +
		"the site, so solar output and the look of the day match what happened. " +
		"Wildfire smoke, dust storms, damaging wind and heatwaves are resolved from " +
		"alert and air-quality data — and can be previewed on demand.")


func run(ctx: TourContext) -> void:
	var xw := ctx.autoload("ExtremeWeather")
	if not ctx.require(xw != null, "the ExtremeWeather service exists"):
		return
	var p := ctx.player.global_position
	var f := ctx.player_forward()
	var eye := p + Vector3.UP * 20.0 - f * 20.0
	var look := p + f * 600.0 + Vector3.UP * 10.0
	ctx.place_camera(eye, look)
	ctx.caption("A clear day on the archived weather", 2.5)
	await ctx.wait(2.5)
	ctx.caption("Preview: wildfire smoke", 3.0)
	xw.call("force_hazard", "wildfire_smoke", 0.75, 24.0)
	await ctx.fly([[eye, look], [eye + f * 30.0 + Vector3.UP * 6.0, look]], 4.0)
	await ctx.hero(true)
	ctx.caption("Preview: dust storm", 3.0)
	xw.call("force_hazard", "dust_storm", 0.7, 24.0)
	await ctx.wait(3.5)


func teardown(ctx: TourContext) -> void:
	var xw := ctx.autoload("ExtremeWeather")
	if xw != null:
		xw.call("clear_forced")
