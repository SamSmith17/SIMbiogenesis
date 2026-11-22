extends TourStop

## Controller Lab + solar chain wiring sheet: design charge controllers,
## inverters and hybrids down to their terminals, wiring bay and heatsinks,
## hop across Panels › Controller › Battery, and inspect the chain's wiring
## diagram.


func _init() -> void:
	id = "controller_lab"
	title = "Controller Lab"
	chapter = "Build"
	summary = "Design charge controllers, inverters and hybrids down to their wiring bay and terminals, and inspect the solar chain's wiring sheet."
	how = PackedStringArray(["Library -> Designers -> Solar controllers, or Design this controller... on a graph controller",
		"Unit: enclosure, heatsinks, wiring bay cover, and connectors placed right on the faces",
		"Terminals: 2D front and bay terminal drawing with fanned conductor labels, exportable as SVG",
		"Panels > Controller > Battery bar: hop straight between the linked labs or open the chain's Sheet"])
	button = "Solar controllers"
	world = "mtvernon"
	budget_s = 40.0
	hour = 13.0
	blurb = ("Every library MPPT and hybrid inverter has a real 3D enclosure, heatsink, mounting tabs " +
		"and terminal bay in the Controller Lab. Open the bay cover to see the battery studs, PV MC4s " +
		"or breaker blocks, place or slide connectors from the shared connector kit, switch to the " +
		"Terminals tab for an installer-grade wiring drawing, or open the chain's Sheet to place fuses, " +
		"breakers, shunts and busbars across Panels, Controller and Battery.")


func run(ctx: TourContext) -> void:
	var main := ctx.main
	if not ctx.require(main != null and main.has_method("open_ctrllab"), "Main hosts the Controller Lab"):
		return
	var gid := ""
	if ctx.graph != null and ctx.graph.get("model") != null:
		for it in (ctx.graph.get("model").get("items") as Array):
			var d: Dictionary = it
			if str(d.get("type", "")) == "controller":
				gid = str(d.get("id", ""))
				break
	var opts := {"graph_item_id": gid} if not gid.is_empty() else {}
	var ui: Variant = main.call("open_ctrllab", opts)
	await ctx.wait(1.5)
	if not ctx.require(ui != null and is_instance_valid(ui) and bool((ui as CanvasItem).visible), "the Controller Lab opened"):
		return
	if ui.has_method("set_cover_shown"):
		ui.call("set_cover_shown", false)
	ctx.caption("Inside the wiring bay: battery studs, PV inputs, AC blocks and breaker slots", 3.0)
	await ctx.wait(2.0)
	await ctx.hero()
	await ctx.wait(1.0)
	if ui.has_method("set_tab"):
		ui.call("set_tab", 1)
		ctx.caption("Terminals view: fanned conductor callouts ready to export as an SVG wiring sheet", 2.5)
		await ctx.wait(2.5)


func teardown(ctx: TourContext) -> void:
	var tree := ctx.tree()
	if tree != null:
		var ws := tree.root.get_node_or_null("WireSheetLayer/WireSheetModal")
		if ws != null and ws.has_method("close"):
			ws.call("close")
	if ctx.main == null:
		return
	var ui: Variant = ctx.main.get("ctrllab_ui")
	if ui != null and is_instance_valid(ui):
		ui.call("close")
