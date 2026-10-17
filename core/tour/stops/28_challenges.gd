extends TourStop


func _init() -> void:
	id = "challenges"
	title = "Challenges"
	chapter = "Systems"
	summary = "Keep the lights on through a real day, month or year — computed in seconds."
	how = PackedStringArray(["Click 🎯 on the timeline and pick a challenge",
		"A pre-baked run plays back; retry replays the same days against your edits"])
	button = "🎯"
	world = "mtvernon"
	budget_s = 30.0
	hour = 14.0
	blurb = ("Pre-baked challenges simulate the whole span — energy, water and people — " +
		"before you watch it, then play it back to the moment it failed. Fix the " +
		"system and retry the same segment to see whether it holds.")


func run(ctx: TourContext) -> void:
	ctx.main.call("open_challenge_picker")
	await ctx.wait(2.0)
	var panel: Variant = ctx.timeline.get("_challenge_picker_panel") if ctx.timeline != null else null
	ctx.require(panel != null and is_instance_valid(panel) and bool((panel as CanvasItem).is_visible_in_tree()),
		"the challenge picker opened")
	ctx.caption("Day, month and year challenges on the real weather", 3.0)
	await ctx.wait(3.0)
	await ctx.hero()
	await ctx.wait(1.0)


func teardown(ctx: TourContext) -> void:
	var panel: Variant = ctx.timeline.get("_challenge_picker_panel") if ctx.timeline != null else null
	if panel != null and is_instance_valid(panel) and bool((panel as CanvasItem).visible):
		panel.call("close")
