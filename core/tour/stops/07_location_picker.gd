extends TourStop


func _init() -> void:
	id = "location_picker"
	title = "Choose a location"
	chapter = "World"
	summary = "A world map with solar resource data — click anywhere to build a site there."
	how = PackedStringArray(["Press L for the location picker",
		"Click the map, search an address or type coordinates",
		"\"Create map here\" builds a new world on that spot"])
	action = "toggle_location_picker"
	world = "mtvernon"
	budget_s = 30.0
	hour = 11.0
	blurb = ("The picker shows the NASA POWER solar-irradiance grid over a world map. " +
		"Any coordinate becomes a playable map: elevation, imagery and OSM content are " +
		"fetched and cached for it, and the world's sun and weather follow it.")


func run(ctx: TourContext) -> void:
	var lp: Variant = ctx.main.get("location_picker")
	if not ctx.require(lp != null and is_instance_valid(lp), "the location picker exists"):
		return
	ctx.main.call("_toggle_location_picker")
	await ctx.wait(2.5)
	ctx.require(bool((lp as CanvasItem).visible) if lp is CanvasItem else true, "the picker opened")
	ctx.caption("Solar resource over a world map", 3.0)
	await ctx.wait(3.0)
	await ctx.hero()
	await ctx.wait(1.5)


func teardown(ctx: TourContext) -> void:
	var lp: Variant = ctx.main.get("location_picker")
	if lp != null and is_instance_valid(lp) and lp is CanvasItem and (lp as CanvasItem).visible:
		ctx.main.call("_toggle_location_picker")
