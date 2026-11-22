extends TourStop


func _init() -> void:
	id = "community_schedule"
	title = "Community schedule"
	chapter = "People"
	summary = "Everyone's day, the week's events and the rota on one calendar, exported as .ics."
	how = PackedStringArray(["Click the people button on the timeline (or Schedule… in Routines)",
		"Day: a row per person; click one to see their week and edit their profile",
		"Week: drag a deploy, a burn or a set to move it; Export calendars for any calendar app"])
	button = "Community schedule"
	world = "walton"
	budget_s = 45.0
	hour = 10.0
	blurb = ("Each person lives their own day: their body clock moves their night, the " +
		"weekly rota names who does which recurring job and when, and nobody is planned " +
		"to work in their sleep. The week shows every scheduled thing on the site in one " +
		"place — deploys, arrivals, burns, stage sets, meals — and you can move them " +
		"there. Export writes a calendar for the group and one per person.")


var _cs: Node = null


func run(ctx: TourContext) -> void:
	var sv: Variant = await ctx.open_festival()
	if not ctx.require(sv != null, "festival mode opened (people to schedule)"):
		return
	ctx.run_clock(30.0)
	await ctx.wait(2.0)
	var tl: Node = ctx.main.get_node_or_null("UILayer/TimelineUI")
	if not ctx.require(tl != null and tl.has_method("open_community_schedule"), "the timeline"):
		return
	_cs = tl.call("open_community_schedule", "Day")
	if not ctx.require(_cs != null and bool(_cs.call("is_open")), "the Community schedule opened"):
		return
	await ctx.wait(1.0)
	ctx.caption("A row per person: their own night, meals, work and rota shifts", 3.0)
	await ctx.wait(2.6)
	await ctx.hero()
	await ctx.click_button("Week")
	ctx.caption("The week: every deploy, arrival, burn, set and meal — drag one to move it", 3.0)
	await ctx.wait(3.0)
	await ctx.click_button("Balance")
	ctx.caption("How evenly the work is spread", 2.4)
	await ctx.wait(2.4)


func teardown(ctx: TourContext) -> void:
	if _cs != null and is_instance_valid(_cs) and bool(_cs.call("is_open")):
		_cs.call("close")
	if ctx.main.has_method("close_festival_mode"):
		ctx.main.call("close_festival_mode")
