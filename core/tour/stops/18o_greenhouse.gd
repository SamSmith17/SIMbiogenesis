extends TourStop

## The Greenhouse designer: gable, lean-to, hoop, gothic arch and dome houses
## with their beds, lamps, vents, fans, barrels and gutters; a year of its
## climate at the site; placed, the house and its beds move as one, and the
## graph shows it as one node that runs its own climate.

var _pid := ""


func _init() -> void:
	id = "greenhouse"
	title = "Greenhouses"
	chapter = "Build"
	summary = "Design a greenhouse (gable, lean-to, hoop, gothic arch or dome), lay out its beds and crops, add lamps, vents, fans, water barrels and gutters, see a year of the climate inside, and place it: the beds move with the house, and on the graph it is one node that runs its own temperature and humidity."
	how = PackedStringArray(["Library → Designers → Greenhouse designer…",
		"Pick a form and its size, the glazing, vents, fans, heater, shade cloth, how deep it is dug in and how many water barrels it holds",
		"Plan tab: click a bed to set its crops, a FarmBot gantry or grow lamps; drag it to move it, drag on the floor to draw one",
		"Climate tab: a year at the site hour by hour — inside against outside, vent and heater hours, lamp energy, rain off the roof, the harvest",
		"Place in world: the house and every bed, gantry and lamp rack in it move, pack and delete as one",
		"On the graph it is one node (inside °C, RH, light); open it to see its beds, lamps, fans, barrels, roof and tank"])
	button = "Greenhouse designer…"
	world = "burningman"
	budget_s = 70.0
	hour = 11.0
	blurb = ("A greenhouse is a climate you build. The designer draws gable, lean-to, hoop, gothic " +
		"and geodesic houses with their beds inside, and runs a year of weather through the design: " +
		"sun through each pane, heat lost through the skin and to a clear night sky, the earth around " +
		"a sunk house, water barrels storing the day's warmth, vents and fans under a controller, " +
		"the crops' transpiration and the water condensing on the glass. Placed, the beds, FarmBot " +
		"gantries and lamp racks are part of the house; the graph runs the same climate and grows " +
		"each bed from it.")


func run(ctx: TourContext) -> void:
	var pps := ctx.klass("PlacedPropService")
	var gb := ctx.klass("GreenhouseBuilder")
	var gs := ctx.klass("GreenhouseSpec")
	var gp := ctx.klass("GreenhousePresets")
	if not ctx.require(pps != null and gb != null and gs != null and gp != null and ctx.player != null,
			"the Greenhouse designer and a player exist"):
		return
	var modal: Node = load("res://scenes/ui/greenhouselab_modal.gd").call("open", ctx.main.get_tree(), {})
	await ctx.wait(1.5)
	modal.call("select_design", "keyhole_dome")
	ctx.caption("A 10 m dome over keyhole beds, water barrels round the back", 3.0)
	await ctx.wait(3.0)
	await ctx.shot("designer_dome", true)
	modal.call("select_design", "gable_pc")
	var tabs := modal.find_child("views", true, false) as TabBar
	if tabs != null:
		tabs.current_tab = 2
	for _i in 30:
		await ctx.wait(0.3)
		if not (modal.call("year_result") as Dictionary).is_empty():
			break
	ctx.caption("A year at this site: inside against outside, every day's coldest and warmest hour", 3.5)
	await ctx.wait(3.5)
	await ctx.shot("designer_climate", true)
	var spec: Dictionary = (gp.call("builtin", "gable_pc")["spec"] as Dictionary).duplicate(true)
	spec["lights"]["on"] = true
	spec["beds"]["lights"] = true
	modal.call("close")
	await ctx.wait(0.5)
	var start := ctx.player_xz()
	var at3: Vector3 = ctx.find_flat(start + Vector2(0.0, -25.0), 16.0, 160.0, 30.0)
	_pid = str(pps.call("place_prepped_at", ctx.main, gb.get("MODEL_ID"),
		{"record_extra": {gs.get("KEY"): gs.call("to_json_safe", spec), "collision_enabled": true, "walk_in": true}},
		at3.x, at3.z, 0.0))
	await ctx.wait(2.0)
	if not ctx.require(not _pid.is_empty(), "a greenhouse is placed"):
		return
	var grade := ctx.ground_y(at3.x, at3.z)
	ctx.caption("Placed: its beds and lamp racks are part of the house — move it and they go with it", 3.5)
	await ctx.fly([[Vector3(at3.x + 11.0, grade + 7.0, at3.z + 13.0), Vector3(at3.x, grade + 1.0, at3.z)]], 3.0)
	await ctx.wait(1.5)
	await ctx.hero(true)
	await ctx.wait(1.0)


func teardown(ctx: TourContext) -> void:
	if not _pid.is_empty():
		ctx.remove_prop(_pid)
	_pid = ""
