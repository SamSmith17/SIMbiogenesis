extends TourStop


func _init() -> void:
	id = "light_studio"
	title = "Light Studio"
	chapter = "Build"
	summary = "Place lamps, spots, string lights, neon and moving heads; animate them."
	how = PackedStringArray(["Press J for the Light Studio dock",
		"Omni / Spot / String tools; drag the gumball to move",
		"Linked styles restyle every light that shares them"])
	action = "place_light"
	world = "walton"
	budget_s = 40.0
	hour = 21.5
	blurb = ("Lights are placed on surfaces, strung between pins or hung as moving " +
		"fixtures with programmed sweeps. Strings run LED chases on the GPU in step " +
		"with real lights, and any light can react to the music at a stage.")


func run(ctx: TourContext) -> void:
	var dark := ctx.hour_for_sun(-12.0, true)
	if not is_nan(dark):
		ctx.set_hour(dark + 0.3)
	var pls := ctx.klass("PlacedLightService")
	if not ctx.require(pls != null, "PlacedLightService exists"):
		return
	var layer: Variant = pls.call("get_layer", ctx.main)
	var at := ctx.ahead(10.0)
	if layer != null:
		var best := {}
		var bd := INF
		for l in layer.get("lights"):
			var p := Vector2(float(l.get("x", 0.0)), float(l.get("z", 0.0)))
			var d := p.distance_to(ctx.player_xz())
			if d < bd:
				bd = d
				best = l
		if not best.is_empty():
			at = Vector3(float(best.get("x", 0.0)), float(best.get("y", 0.0)), float(best.get("z", 0.0)))
		else:
			ctx.note("no placed lights on this map — showing the dock only")
	var f := ctx.player_forward()
	var eye := at - f * 14.0 + Vector3.UP * 5.0
	ctx.place_camera(eye, at)
	pls.call("toggle_studio", ctx.main)
	await ctx.wait(1.5)
	ctx.require(bool(pls.call("is_studio_open")), "the Light Studio dock opened")
	ctx.caption("Strings, spots and movers — with LED effects", 3.0)
	await ctx.orbit(at, 14.0, 5.0, 0.0, 50.0, 5.0)
	await ctx.hero()


func teardown(ctx: TourContext) -> void:
	var pls := ctx.klass("PlacedLightService")
	if pls != null and bool(pls.call("is_studio_open")):
		pls.call("toggle_studio", ctx.main)
