extends TourStop


func _init() -> void:
	id = "hydro_lab"
	title = "Hydro Lab"
	chapter = "Systems"
	summary = "Design a micro-hydro turbine on its real penstock: head, flow, jet, speed, watts."
	how = PackedStringArray(["In the graph, double-click a hydro turbine (or Inspector → Open Hydro Lab)",
		"Drag the intake, nozzle and outlet on the cross-section; dial a test flow"])
	button = "Inspector → Open Hydro Lab"
	world = "mtvernon"
	budget_s = 40.0
	hour = 14.0
	blurb = ("The Lab draws the turbine's water path in section over the real ground — " +
		"pond or stream intake, routed penstock or siphon, the runner and the outlet — " +
		"and solves it with the same physics the world runs: Darcy–Weisbach losses, " +
		"Pelton jet and bucket relations, siphon crest limits and cavitation.")


func run(ctx: TourContext) -> void:
	var turbines := ctx.graph_items(func(it: Dictionary) -> bool:
		var sp: Variant = it.get("specs", {})
		return sp is Dictionary and str((sp as Dictionary).get("role", "")) == "siphon_hydro")
	if not ctx.require(not turbines.is_empty(), "there is a hydro turbine on this site"):
		return
	# Prefer a nozzle (Pelton) turbine: its close-up is the showier one.
	var pick: Dictionary = turbines[0]
	for t in turbines:
		var kind := str(((t as Dictionary).get("specs", {}) as Dictionary).get("turbine_kind", ""))
		if kind.find("pelton") >= 0:
			pick = t
			break
	if not ctx.require(await ctx.open_graph(""), "the graph opened"):
		return
	ctx.graph.call("open_siphon_lab", str(pick.get("id", "")))
	await ctx.wait(2.5)
	var lab: Variant = ctx.graph.get("_siphon_lab_modal")
	ctx.require(lab != null and is_instance_valid(lab) and bool((lab as CanvasItem).is_visible_in_tree()),
		"the Hydro Lab opened")
	ctx.caption("%s — solved on its routed penstock" % str((pick.get("specs", {}) as Dictionary).get("name", "Turbine")), 3.5)
	await ctx.wait(3.5)
	await ctx.hero()
	await ctx.wait(1.5)


func teardown(ctx: TourContext) -> void:
	if ctx.graph != null:
		ctx.graph.call("close_hydro_lab")
		await ctx.wait(0.5)
	ctx.close_graph()
