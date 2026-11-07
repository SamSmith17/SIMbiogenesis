extends TourStop

## The tri-clamp designer: standard sanitary fittings snapped end to end into
## process runs, vessels with nozzles you drag round the shell, valves with
## actuators on their stems, and the biochar reactor with its three-column
## condenser — placed on the map as one prop whose labelled ends are pipe
## ports and the graph's Biochar Reactor node.


func _init() -> void:
	id = "tclab"
	title = "Tri-clamp designer"
	chapter = "Build"
	summary = "Snap standard tri-clamp fittings together into process runs, design vessels with nozzles you drag round the shell, and place the result — like the biochar reactor and its condenser — on the map with its ends as pipe ports."
	how = PackedStringArray(["Library → Structures → Tri-clamp designer…, or Edit tri-clamp assembly… on a placed one",
		"Pick a clamp size and a part, then click an open end: it snaps on with a gasket and a clamp (Tab: which end, R: roll)",
		"Vessel / tank: shell, heads, lid, jacket, legs and internals; + Clamp nozzle, then drag the nozzle round the shell",
		"Label an open end and say what it carries; On the graph turns the assembly into a graph node",
		"Cutaway to see inside; Export files; Place in world"])
	button = "Tri-clamp designer…"
	world = "burningman"
	budget_s = 45.0
	hour = 14.0
	blurb = ("Tri-clamp (sanitary) fittings join on a clamp face: two ferrules, a gasket and a hinged clamp. " +
		"The designer draws every part from the ASME BPE inch sizes — spools, 90° and 45° elbows, tees, " +
		"crosses, reducers, adapters, sight glasses, dephlegmators, butterfly and ball valves with their " +
		"actuators, gauges, strainers and cartridge housings — and snaps them end to end, checking that clamp " +
		"faces match, that loops close and that nothing runs into anything. Vessels are parts too: a shell, " +
		"heads and a lid, a jacket, legs and what is inside, with nozzles you drag round the shell. The " +
		"biochar reactor preset rebuilds a real jacketed boiler with its retort can and its three-column " +
		"condenser to within a few millimetres of the model it came from. Placed on the map it is one prop: " +
		"its labelled ends are pipe ports, and it is the graph's Biochar Reactor node, so the woodgas line you " +
		"draw in 3D starts on the woodgas fitting.")


func run(ctx: TourContext) -> void:
	var main := ctx.main
	if not ctx.require(main != null and main.has_method("open_tclab"), "Main hosts the designer"):
		return
	var ui: Variant = main.call("open_tclab", {})
	await ctx.wait(1.5)
	if not ctx.require(ui != null and is_instance_valid(ui) and bool((ui as CanvasItem).visible), "the designer opened"):
		return
	ui.call("load_builtin", "filter_train")
	ctx.caption("Standard 1½\" fittings, clamped end to end: a strainer, a gauge tee, a cartridge housing", 3.0)
	await ctx.wait(3.0)
	ui.call("load_builtin", "pot_still")
	ctx.caption("A pot still: dished boiler, sight glass, packed column, dephlegmator and condenser", 3.0)
	await ctx.wait(3.0)
	ui.call("load_builtin", "biochar_reactor")
	ctx.caption("The biochar reactor: a jacketed boiler and its three-column condenser", 3.0)
	await ctx.wait(3.0)
	ui.set("_cutaway", true)
	ui.call("_rebuild_studio")
	ctx.caption("Cut away: the retort can of wood inside the jacketed shell", 3.0)
	await ctx.wait(3.0)
	ui.set("_cutaway", false)
	ui.call("_rebuild_studio")
	ui.call("_frame")
	ctx.caption("Placed, its labelled ends are pipe ports and it is the graph's Biochar Reactor", 3.0)
	await ctx.wait(1.5)
	await ctx.hero()
	await ctx.wait(1.0)


func teardown(ctx: TourContext) -> void:
	var main := ctx.main
	if main == null:
		return
	var ui: Variant = main.get("tclab_ui")
	if ui != null and is_instance_valid(ui):
		ui.call("close")
