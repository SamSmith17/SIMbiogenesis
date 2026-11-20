extends TourStop

## The Battery Lab: a solar battery built from its cells (chemistry, series
## and parallel, BMS, case) and a bank built from those packs (cabinet,
## wall, shelf, cart; cables, fuses), with a BMS bench that runs its real
## protections and a designed bank that sets the live sim's limits.


func _init() -> void:
	id = "battery_lab"
	title = "Battery Lab"
	chapter = "Build"
	summary = "Build a solar battery from its cells and a bank from its packs; watch the BMS protect it on a test bench, then place the bank and its limits drive the live sim."
	how = PackedStringArray(["Library → Designers → Solar batteries, or Design this battery… on a graph battery",
		"Pack: chemistry, cells in series and parallel, BMS, case; the cutaway shows cells, busbars and balance wires",
		"BMS & test: charge, discharge, a frozen morning, an overload, a short; every trip in the log",
		"Bank: packs in a cabinet, on a wall, shelf or cart; cables sized and measured, fuses picked, checks",
		"Place bank in world: its graph battery carries the BMS limits the live sim honours"])
	button = "Solar batteries"
	world = "burningman"
	budget_s = 45.0
	hour = 14.0
	blurb = ("Lead-acid (flooded, AGM, gel) and lithium (LFP, NMC) from real cells and blocks, in every form: " +
		"car batteries, drop-ins, server-rack packs, wall units, rolling units and DIY boxes. The pack is drawn " +
		"down to its cells, busbars, balance leads and BMS. The bench runs the BMS cell by cell: over- and " +
		"under-voltage, charge and discharge current, short circuit, temperature, balancing, each with its " +
		"delay and release. A bank sizes its cables for current and voltage drop, picks fuses that can break " +
		"its fault current, and checks what a real installer would. Placed in the world, its charge and " +
		"discharge limits, and its refusal to charge below freezing, are what the live simulation uses.")


func run(ctx: TourContext) -> void:
	var main := ctx.main
	if not ctx.require(main != null and main.has_method("open_batterylab"), "Main hosts the Battery Lab"):
		return
	var ui: Variant = main.call("open_batterylab", {})
	await ctx.wait(1.5)
	if not ctx.require(ui != null and is_instance_valid(ui) and bool((ui as CanvasItem).visible), "the lab opened"):
		return
	ui.call("load_builtin", "rack_48v_105")
	ui.call("set_cutaway", true)
	ctx.caption("A 48 V server-rack pack: sixteen LFP cells in series, the BMS and its balance leads", 3.0)
	await ctx.wait(3.0)
	ui.call("set_mode", "test")
	var tp: Variant = ui.call("test_panel")
	if tp != null:
		tp.call("run_scenario", "cold")
		tp.call("seek", float(tp.call("duration")) * 0.3)
	ctx.caption("A frozen morning: the BMS blocks charging until the cells warm past 0 °C", 3.0)
	await ctx.wait(3.0)
	ui.call("set_mode", "bank")
	ui.call("edit_bank", "parallel", 4)
	ctx.caption("Four packs in a cabinet: cables sized, a Class T fuse per string for 17,000 A of fault current", 3.0)
	await ctx.wait(1.5)
	await ctx.hero()
	await ctx.wait(1.5)
	var bp: Variant = ui.call("bank_panel")
	if bp != null:
		bp.call("set_view", "bench")
		var bench: Variant = bp.call("bench")
		bench.call("run_scenario", "weak")
		var t_oc := 0.0
		for ev in (bench.get("result")["events"] as Array):
			if str(ev["key"]) == "discharge_oc":
				t_oc = maxf(t_oc, float(ev["t"]))
		bench.call("seek", t_oc + 5.0)
		ctx.caption("The bank bench: one weak cell trips its pack, and the other strings are overloaded in turn", 3.0)
		await ctx.wait(3.0)


func teardown(ctx: TourContext) -> void:
	var main := ctx.main
	if main == null:
		return
	var ui: Variant = main.get("batterylab_ui")
	if ui != null and is_instance_valid(ui):
		ui.call("close")
