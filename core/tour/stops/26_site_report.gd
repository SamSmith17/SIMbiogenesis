extends TourStop


func _init() -> void:
	id = "site_report"
	title = "Site Report"
	chapter = "Systems"
	summary = "A month-by-month year of sun, wind, rain, temperature and your system's output."
	how = PackedStringArray(["Press K, or 📊 on the timeline"])
	action = "toggle_site_report"
	button = "📊"
	world = "mtvernon"
	budget_s = 45.0
	hour = 14.0
	blurb = ("The report runs a representative year of the site's real weather through " +
		"the current graph: solar resource and PV yield, a windrose, rainfall, " +
		"temperature bands, hydro potential, and what it would take to pack the site " +
		"into a truck.")


func run(ctx: TourContext) -> void:
	if not ctx.require(ctx.timeline != null, "the timeline exists"):
		return
	ctx.timeline.call("_on_site_report_pressed")
	var panel: Variant = ctx.timeline.get("_site_report_panel")
	if not ctx.require(panel != null and bool(panel.call("is_open")), "the Site Report opened"):
		return
	ctx.caption("A representative year, month by month", 3.0)
	# Wait for the compute overlay to clear (a cached report opens at once).
	var waited := 0.0
	while waited < 20.0 and bool(panel.get("_building")) and not ctx.cancelled:
		await ctx.wait(0.5)
		waited += 0.5
	await ctx.wait(2.0)
	await ctx.hero()
	var scroll := panel.find_children("*", "ScrollContainer", true, false) as Array
	if not scroll.is_empty():
		var sc := scroll[0] as ScrollContainer
		ctx.caption("Wind, rain, temperature, hydro, packing", 3.0)
		var dur := 3.5 * ctx.pace
		var t := 0.0
		while t < dur and not ctx.cancelled:
			sc.scroll_vertical += int(ctx.host.get_process_delta_time() * 420.0 / ctx.pace)
			await ctx.frames(1)
			t += ctx.host.get_process_delta_time()


func teardown(ctx: TourContext) -> void:
	var panel: Variant = ctx.timeline.get("_site_report_panel") if ctx.timeline != null else null
	if panel != null and bool(panel.call("is_open")):
		panel.call("close")
