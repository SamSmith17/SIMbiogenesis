extends TourStop


func _init() -> void:
	id = "snowglobe"
	title = "Full-screen globe"
	chapter = "Systems"
	summary = "Step out to the whole site as a globe, full screen, with the clock still running."
	how = PackedStringArray(["Interact with the SoI marker in the world, or",
		"the full-globe button on the graph's Globe lens; Esc to return"])
	button = "SoI marker / full globe"
	world = "mtvernon"
	budget_s = 30.0
	hour = 14.0
	blurb = ("The full-screen globe renders the real world inside the Sphere of " +
		"Influence from outside it. No view freezes the clock, so clouds, people " +
		"and the sun keep moving while you look.")


func run(ctx: TourContext) -> void:
	var soi := ctx.autoload("SoiService")
	if not ctx.require(soi != null, "SoiService exists"):
		return
	soi.call("enter_snowglobe")
	await ctx.wait(1.5)
	if not ctx.require(bool(soi.get("snowglobe_active")), "the globe opened"):
		return
	var cam: Variant = soi.get("_snowglobe")
	ctx.caption("The site from outside its Sphere of Influence", 3.0)
	var dur := 6.0 * ctx.pace
	var t := 0.0
	var shot := false
	while t < dur and not ctx.cancelled:
		var dt := ctx.host.get_process_delta_time()
		if cam != null:
			cam.set("_orbit_yaw", float(cam.get("_orbit_yaw")) + dt * 0.35 / ctx.pace)
		if not shot and t > dur * 0.55:
			shot = true
			await ctx.hero()
		await ctx.frames(1)
		t += dt
	if not shot:
		await ctx.hero()


func teardown(ctx: TourContext) -> void:
	var soi := ctx.autoload("SoiService")
	if soi != null and bool(soi.get("snowglobe_active")):
		soi.call("exit_snowglobe")
		await ctx.wait(0.8)
