extends TourStop


func _init() -> void:
	id = "globe_mode"
	title = "Globe mode"
	chapter = "World"
	summary = "A 3D Earth with live clouds, rain, wind and solar zones — fly out from your site and back down."
	how = PackedStringArray(["Press Shift+L in a world, or Globe on the launch hub",
		"Drag to turn, wheel to zoom, right-drag to tilt",
		"Click a place for its solar zone; Create world here or Fly in"])
	action = "toggle_globe"
	world = "burningman"
	budget_s = 50.0
	hour = 11.0
	blurb = ("The globe draws satellite imagery with the real sun and city lights, " +
		"NOAA's live infrared clouds, NASA's IMERG rain and NOAA GFS wind streamlines, " +
		"all at the sim clock's time, over the NASA POWER solar zones. Close to a " +
		"saved world it drapes that world's own photos, with its Sphere of Influence " +
		"and map square drawn round it.")


func _gm(ctx: TourContext) -> GlobeMode:
	var gm: Variant = ctx.main.get("_globe_mode")
	return gm as GlobeMode if gm != null and is_instance_valid(gm) else null


func _await_flight(ctx: TourContext, gm: GlobeMode, limit_s: float) -> void:
	var t := 0.0
	while gm.globe.is_flying() and t < limit_s and not ctx.cancelled:
		await ctx.wait(0.25)
		t += 0.25


func run(ctx: TourContext) -> void:
	ctx.main.call("open_globe_mode")
	var gm := _gm(ctx)
	if not ctx.require(gm != null, "Globe mode opened"):
		return
	var lat := float(ctx.main.get("latitude"))
	var lon := float(ctx.main.get("longitude"))
	gm.globe.look_at_point(lat, lon, 0.004)
	await ctx.wait(2.0)
	ctx.caption("Your site, with its Sphere of Influence", 3.0)
	await ctx.wait(3.0)
	var rain := gm.find_child("RainToggle", true, false) as CheckBox
	if rain != null and not rain.button_pressed:
		rain.button_pressed = true
	# The imagery under the weather reads better than the zone bands.
	var cb := gm.find_child("ColourBy", true, false) as OptionButton
	if cb != null:
		var i := cb.get_item_index(GlobeMode.COLOUR_NONE)
		cb.select(i)
		cb.item_selected.emit(i)
	gm.globe.fly_to(lat - 8.0, lon + 15.0, 2.6, 5.0)
	ctx.caption("Clouds, rain and wind at the sim's time", 4.0)
	await _await_flight(ctx, gm, 8.0)
	var t := 0.0
	while gm.wind_line_segments() == 0 and t < 10.0:
		await ctx.wait(0.5)
		t += 0.5
	await ctx.wait(2.0)
	await ctx.hero()
	ctx.caption("Back down to the world's own photos", 4.0)
	gm.globe.fly_to(lat, lon, 0.0004, 5.0, 55.0)
	await _await_flight(ctx, gm, 8.0)
	await ctx.wait(3.0)


func teardown(ctx: TourContext) -> void:
	var gm := _gm(ctx)
	if gm != null:
		gm.close()
		await ctx.wait(0.3)
