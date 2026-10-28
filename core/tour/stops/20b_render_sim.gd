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
	# Straight after the graph stops, the first click sometimes never reaches
	# the button (the bar is still re-laying itself out as the graph closes):
	# click once more, then press it through its own handler, and say so.
	if not (bool(sr.call("is_active")) or not sr.cache.is_empty()):
		await ctx.wait(0.8)
		await ctx.click_button("📈")
		await ctx.wait(0.6)
	if not (bool(sr.call("is_active")) or not sr.cache.is_empty()):
		var tl0: Node = ctx.main.find_child("TimelineUI", true, false)
		if tl0 != null and tl0.has_method("_on_render_pressed"):
			ctx.note("the 📈 click did not land twice; pressed through the button's handler")
			tl0.call("_on_render_pressed")
			await ctx.wait(0.6)
	if not (bool(sr.call("is_active")) or not sr.cache.is_empty()):
		# The button's own refusal only reaches a toast: name it in the log. An
		# empty refusal with the button enabled means the CLICK never reached
		# the handler (the 2026-10-18 recording — see HarnessInput.click).
		var tl: Node = ctx.main.find_child("TimelineUI", true, false)
		var end_abs := NAN
		if tl != null and tl.has_method("_render_target_end"):
			end_abs = float(tl.call("_render_target_end"))
		var btn := HarnessInput.find_button(ctx.tree().root, "📈")
		ctx.note("render did not start: refusal='%s' end=%.3f play=%.3f button_disabled=%s shift=%s clock_owner='%s' hold='%s'" % [
			str(sr.call("refusal", end_abs)), end_abs, float(ctx.main.call("get_absolute_hours")),
			str(btn.disabled if btn != null else "<no button>"), str(Input.is_key_pressed(KEY_SHIFT)),
			str(ctx.main.call("clock_is_owned")), str(ctx.main.call("clock_hold_owner"))])
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
