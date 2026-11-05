extends TourStop


func _init() -> void:
	id = "festival_systems"
	title = "A festival of systems"
	chapter = "Systems"
	summary = "Every camp and vehicle is its own power system: see them all at once, then scroll into one."
	how = PackedStringArray(["Press G: each camp is a tile with a status ring",
		"Scroll into a camp to see its own tanks and power; Esc comes back out",
		"View ▾ → Festival board lists what is going wrong, worst first"])
	action = "system_graph_toggle"
	world = "walton"
	budget_s = 45.0
	hour = 14.0
	blurb = ("A festival site holds dozens of power systems: the player's own, every camp's " +
		"and every living vehicle's. Far out each one is a tile whose ring shows power, " +
		"water, food and people; closer in a card shows its interior live, and one more " +
		"scroll goes inside with no jump. The dashboard follows the system you are in, " +
		"and the Festival board ranks every system by what needs attention.")


func run(ctx: TourContext) -> void:
	if not ctx.require(await ctx.open_graph("freeform"), "the graph opened"):
		return
	var graph: Node = ctx.graph
	graph.call("_jump_to_scope_index", 0)
	ctx.graph_sidebars(true, false)
	var camps: Array = graph.call("festival_camps")
	if not ctx.require(not camps.is_empty(), "the world has festival camps"):
		return
	var canvas: Variant = graph.get("_graph_canvas")
	canvas.call("fit_scope_to_view")
	await ctx.wait(2.0)
	ctx.caption("Every camp is its own power system: a tile, its ring shows power, water, food and people", 4.0)
	await ctx.wait(3.0)
	await ctx.hero()
	var camp_id := str((camps[camps.size() / 2] as Dictionary)["id"])
	graph.call("focus_graph_item", camp_id, true)
	await ctx.wait(1.5)
	ctx.caption("Inside a camp: its own tanks, its own battery", 3.5)
	await ctx.wait(3.0)
	graph.call("_collapse_active_scope", true)
	await ctx.wait(1.5)
	graph.call("open_board_fullscreen", "attention")
	ctx.caption("The Festival board: what is going wrong, worst first", 3.5)
	await ctx.wait(3.0)
	graph.call("toggle_board_fullscreen")
	await ctx.wait(0.8)


func teardown(ctx: TourContext) -> void:
	if ctx.graph != null and bool(ctx.graph.call("board_fullscreen_open")):
		ctx.graph.call("toggle_board_fullscreen")
	ctx.close_graph()
