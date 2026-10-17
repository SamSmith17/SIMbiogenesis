extends TourStop


func _init() -> void:
	id = "elevation"
	title = "Elevation lens"
	chapter = "Systems"
	summary = "A cut through the ground: heads, pipes, ponds and the soil profile in section."
	how = PackedStringArray(["In the graph (G), click the Elevation lens chip",
		"Hover the cut face to read the soil horizon and the water table"])
	action = "system_graph_toggle"
	button = "Elevation lens"
	world = "mtvernon"
	budget_s = 30.0
	hour = 14.0
	blurb = ("Elevation slices the Sphere of Influence like a cutaway: the terrain " +
		"profile, buried pipes and every item at its true height, over a solid cut " +
		"face painted with a Pacific-Northwest soil profile down to the water table. " +
		"It is where hydro head is read and designed.")


func run(ctx: TourContext) -> void:
	# Through Site Plan first: opened straight onto Elevation the section
	# inherits the freeform zoom and frames nothing but the cut face.
	if not ctx.require(await ctx.open_graph("site"), "the graph opened"):
		return
	await ctx.wait(1.0)
	# The saved world remembers the player's last Elevation camera (often deep
	# in the cut face). A lens with no saved camera auto-fits on entry.
	var canvas: Variant = ctx.graph.get("_graph_canvas")
	if canvas != null and canvas.get("_view_cam") is Dictionary:
		(canvas.get("_view_cam") as Dictionary).erase("elevation")
	# On a site with hydro, turn the cut along the water's path (heading and
	# slice only — set_camera false keeps the auto-fit framing).
	var hydro := ctx.graph_items(func(it: Dictionary) -> bool:
		var sp: Variant = it.get("specs", {})
		return sp is Dictionary and str((sp as Dictionary).get("role", "")) == "siphon_hydro")
	ctx.graph.call("_on_mode_chip_pressed", "elevation")
	await ctx.wait(0.6)
	if not hydro.is_empty():
		ctx.graph.call("frame_elevation_for_siphon", str((hydro[0] as Dictionary).get("id", "")), false)
	# Frame the whole SoI section explicitly: the elevation frame is world-Y
	# metres, and the remembered anchor can sit tens of metres underground.
	var soi := ctx.autoload("SoiService")
	if canvas != null and soi != null and soi.has_method("radius_m") and soi.has_method("world_center"):
		var rad := maxf(float(soi.call("radius_m")), 20.0)
		var cy := float((soi.call("world_center") as Vector3).y)
		canvas.call("frame_elevation_window", -rad, rad, cy - rad * 0.45, cy + rad * 0.3,
			(canvas as Control).size, 0.06)
	await ctx.wait(0.4)
	if not hydro.is_empty():
		ctx.caption("Cut along the hydro run: intake, penstock, turbine, outlet", 3.0)
	else:
		ctx.caption("Every item at its true height above the cut", 3.0)
	await ctx.wait(3.5)
	await ctx.hero()
	await ctx.wait(1.5)


func teardown(ctx: TourContext) -> void:
	ctx.close_graph()
