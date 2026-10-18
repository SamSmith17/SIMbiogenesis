extends TourStop


func _init() -> void:
	id = "render_sim"
	title = "Render the simulation ahead"
	chapter = "Systems"
	summary = "Pre-compute the next day of the whole site, then play it back from the cache."
	how = PackedStringArray(["Ctrl-drag a range on the timeline (or leave it: the next 24 h)",
		"Click 📈 Render on the timeline bar",
		"The green strip above the clips is what plays back without computing"])
	button = "📈"
	world = "mtvernon"
	budget_s = 45.0
	hour = 10.0
	blurb = ("The simulation is a deterministic function of sim time, so a stretch of it " +
		"can be rendered ahead — battery, tanks, hydro, camp power and the people's " +
		"supplies — and then scrubbed or played back from the cache while you explore " +
		"in first person. A green strip above the clips marks what is rendered; " +
		"editing the graph cuts it at the playhead, as Premiere drops a stale preview.")


func run(ctx: TourContext) -> void:
	var sgv: Node = ctx.main.find_child("SystemGraphView", true, false)
	if not ctx.require(sgv != null and sgv.has_method("sim_renderer"), "the graph view is up"):
		return
	ctx.caption("One click renders the next 24 hours of the site", 3.0)
	await ctx.wait(1.0)
	var clicked: bool = await ctx.click_button("📈")
	if not ctx.require(clicked, "the Render button was found"):
		return
	var sr: Node = sgv.call("sim_renderer")
	await ctx.wait(0.6)
	if not ctx.require(bool(sr.call("is_active")) or not sr.cache.is_empty(), "the render started"):
		return
	# Catch it mid-render: the progress card and the strip filling in.
	var t0 := Time.get_ticks_msec()
	while bool(sr.call("is_active")) and float(sr.call("progress")) < 0.35 \
			and Time.get_ticks_msec() - t0 < 20000:
		await ctx.frames(1)
	ctx.caption("Battery, water, hydro, camps and people, all pre-computed", 4.0)
	await ctx.hero()
	t0 = Time.get_ticks_msec()
	while bool(sr.call("is_active")) and Time.get_ticks_msec() - t0 < 30000:
		await ctx.frames(1)
	ctx.require(not sr.cache.is_empty(), "a rendered range exists")
	ctx.caption("Green = rendered. Scrub or play: it reads the cache instead of simulating", 4.0)
	ctx.run_clock(600.0)
	await ctx.wait(3.0)
	ctx.run_clock(0.0)


func teardown(ctx: TourContext) -> void:
	var sgv: Node = ctx.main.find_child("SystemGraphView", true, false)
	if sgv != null:
		var v: Variant = sgv.get("_sim_renderer")
		if v is Node and is_instance_valid(v):
			if bool((v as Node).call("is_active")):
				(v as Node).call("cancel")
			(v as Node).call("invalidate_all")
