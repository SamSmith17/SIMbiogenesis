extends TourStop


func _init() -> void:
	id = "arrival"
	title = "Any place on Earth"
	chapter = "World"
	summary = "Real terrain, aerial imagery and OpenStreetMap buildings for the site you pick."
	how = PackedStringArray(["Pick or create a world in the launch hub",
		"Walk with WASD, look with the mouse"])
	button = "Play → pick a world"
	world = "mtvernon"
	budget_s = 40.0
	hour = 14.0
	blurb = ("Every world stands on a real map: an elevation model, aerial imagery " +
		"draped at up to native county resolution, and the buildings, roads, water " +
		"and forests from OpenStreetMap. The sun, sky and weather follow the site's " +
		"real latitude, date and archived weather.")


func run(ctx: TourContext) -> void:
	var p := ctx.player.global_position
	var f := ctx.player_forward()
	var look := ctx.ahead(60.0)
	# High and well back: a lower end point lands inside the canopy.
	var high := p - f * 260.0 + Vector3.UP * 170.0
	var mid := p - f * 110.0 + Vector3.UP * 70.0
	ctx.hud(false)
	ctx.place_camera(high, look)
	await ctx.frames(2)
	ctx.caption("Elevation, aerial imagery and OSM content for a real site", 3.5)
	await ctx.fly([[high, look], [mid, look]], 6.0)
	await ctx.hero()
	ctx.release_camera()
	ctx.hud(true)
	ctx.aim_player_at(look + Vector3.UP * 2.0)
	ctx.caption("Walk it in first person", 2.5)
	await ctx.turn_player(55.0, 3.0)
	await ctx.turn_player(-55.0, 2.0)


func teardown(ctx: TourContext) -> void:
	ctx.hud(true)
