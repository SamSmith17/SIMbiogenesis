extends TourStop

## The TC Process Lab: the tri-clamp designer runs what happens inside an
## assembly — the biochar reactor's batch from wet chips to char, cut open
## mid-batch with the drying and pyrolysis fronts in the charge, gas moving
## to the condensers, a molecule view of what is reacting, and the rules
## that run the elements.


func _init() -> void:
	id = "tc_process"
	title = "TC Process Lab"
	chapter = "Build"
	summary = "Run what happens inside a tri-clamp assembly: heat a charge, watch it dry, pyrolyse, boil and distil, see the gas and liquids move, and automate it with the same rules as Home Assistant."
	how = PackedStringArray(["In the Tri-clamp designer press Process under the 3D view",
		"Play, or Run the whole batch and drag the chart to scrub through it",
		"Section / X-ray show what is inside; click a part to see its contents; Molecules shows them up close",
		"Control: sensors, switches and automations that run in the model; Copy as Home Assistant YAML",
		"Use this run on the graph fits the batch onto a placed reactor's node"])
	button = "Process"
	world = "burningman"
	budget_s = 90.0
	hour = 14.0
	blurb = ("Every part of a tri-clamp design is also a volume of gas and liquid: the lab joins them into a " +
		"network and steps it — heat from the elements spreading through the charge, water boiling off ahead " +
		"of a pyrolysis front, wood breaking into char, tar and gas (Miller & Bellan's kinetics), the pressure " +
		"pushing the vapour into the condensers, water and tar running down to the traps, burnable gas at the " +
		"outlet. The energy and mass ledgers close to a fraction of a percent. Cut it open to see the fronts in " +
		"the charge and the gas in the pipes, look at the molecules reacting, and switch the elements with the " +
		"same rules the rest of the game uses. The same lab distils a wash in the pot still, boils the kettle, " +
		"cracks plastic pellets into oil and wax in the retort, and runs a genset from a gas holder.")


func run(ctx: TourContext) -> void:
	var main := ctx.main
	if not ctx.require(main != null and main.has_method("open_tclab"), "Main hosts the designer"):
		return
	var ui: Variant = main.call("open_tclab", {})
	await ctx.wait(1.0)
	if not ctx.require(ui != null and is_instance_valid(ui) and bool((ui as CanvasItem).visible), "the designer opened"):
		return
	ui.call("load_builtin", "biochar_reactor")
	await ctx.wait(0.5)
	ui.call("set_run_mode", true)
	var panel: Variant = ui.call("process_panel")
	if not ctx.require(panel != null and bool(ui.call("is_process_mode")), "Process mode opened"):
		return
	ctx.caption("10 kg of wet chips round two 600 W elements: the lab runs the whole batch", 3.0)
	panel.call("prerun_batch")
	# Real frames, not ctx.wait: the tour's pace shortens waits, and the
	# pre-run is a fixed amount of work (~10 s of frames).
	var tree := (main as Node).get_tree()
	var frames := 0
	while bool(panel.get("prerunning")) and frames < 4000:
		await tree.process_frame
		frames += 1
	if not ctx.require(not bool(panel.get("prerunning")), "the batch ran to the end"):
		return
	panel.call("seek_h", 2.0)
	panel.call("set_view_mode", "section")
	var sim: Variant = panel.get("sim")
	if sim != null:
		panel.call("select_cv", int(sim.get("vessel_cv")))
	ctx.caption("Two hours in, cut open: the dry ring round each element is charring while the edge still steams", 4.0)
	await ctx.wait(4.0)
	panel.call("set_lens", true)
	ctx.caption("The molecules in the vessel: water boiling off, cellulose breaking into char and gas", 4.0)
	await ctx.wait(3.0)
	await ctx.hero()
	panel.call("set_lens", false)
	panel.call("seek_h", 3.5)
	panel.call("show_right", "control")
	ctx.caption("Sensors, switches and rules that run in the model — and copy out as Home Assistant YAML", 3.5)
	await ctx.wait(3.5)


func teardown(ctx: TourContext) -> void:
	var main := ctx.main
	if main == null:
		return
	var ui: Variant = main.get("tclab_ui")
	if ui != null and is_instance_valid(ui):
		ui.call("close")
