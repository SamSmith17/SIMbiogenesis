extends TourStop

## The dome & zome designer: geodesic domes, zomes and helix zomes with any
## of five connector systems, a bill of materials, the strut schedule and
## fabrication files.


func _init() -> void:
	id = "domelab"
	title = "Dome & zome designer"
	chapter = "Build"
	summary = "Design geodesic domes, zomes and helix zomes in conduit, hubs, flat bars, rotegrity slats or folded plates; get the strut schedule, hub templates and cut files."
	how = PackedStringArray(["Library → Structures → Dome & zome designer…",
		"Pick Geodesic or Zome, a connector system, or a built-in design",
		"Set the class, frequency, truncation, radius, the strut stock, the hubs and the covering",
		"Parts lists every strut, hub and panel type; the schedule carries chord factors, cut lengths, bends and hub arm angles",
		"Export writes DXF / SVG per sheet and hub template, the strut and BOM CSVs and the whole design as JSON",
		"Place in world: a dome people can shelter under, which packs to its strut bundle"])
	button = "Dome & zome designer…"
	world = "mtvernon"
	budget_s = 45.0
	hour = 14.0
	blurb = ("A parametric designer for nearly any dome: Class I, II and III geodesic subdivisions of the " +
		"icosahedron, octahedron and tetrahedron, truncated at any ring and stretched into ellipsoids; " +
		"polar-zonohedron zomes of any order; and the helix zome, the zonohedron's smooth limit built from " +
		"continuous curved ribs. Five ways to join them — flattened conduit on a bolt, rigid struts into " +
		"socket or star-plate hubs, flat bars bent to the curve, hubless rotegrity slats, or folded plates " +
		"with no struts at all — each worked out from the geometry alone: dips, bends, hub arm patterns, " +
		"arc lengths, flange folds. The chord factors match the published tables, the bill of materials " +
		"counts stock lengths and bolts, and the files go straight to a saw, a drill press or a CNC.")


func run(ctx: TourContext) -> void:
	var ld := ctx.loader
	if not ctx.require(ld != null and ld.has_method("open_domelab"), "the terrain loader has the designer"):
		return
	ld.call("open_domelab")
	await ctx.wait(1.5)
	var ui: Variant = ld.call("domelab_designer")
	if not ctx.require(ui != null and is_instance_valid(ui) and bool((ui as CanvasItem).visible), "the designer opened"):
		return
	ui.call("load_builtin", "3v_58")
	ctx.caption("A 3V 5/8 conduit dome: 165 struts of three lengths, 61 bolts", 3.0)
	await ctx.wait(3.0)
	ui.call("set_explode", 0.6)
	ctx.caption("Every strut's cut length, end bend and hub pattern comes off the geometry", 2.5)
	await ctx.wait(2.5)
	ui.call("set_explode", 0.0)
	ui.call("set_assembly", 0.0)
	for i in 10:
		ui.call("set_assembly", (i + 1) / 10.0)
		await ctx.wait(0.25)
	ui.call("load_builtin", "helix_zome")
	ctx.caption("A helix zome: ten double helices of curved plywood rib, lapped where they cross", 3.0)
	await ctx.wait(3.0)
	ui.call("load_builtin", "rotegrity")
	ctx.caption("A rotegrity: no hubs, every slat rests on the next", 2.5)
	await ctx.wait(2.5)
	ui.call("load_builtin", "plate_dome")
	ui.call("set_tab", 1)
	ctx.caption("Folded aluminium plates nested on sheets, fold angles on every edge", 2.5)
	await ctx.wait(2.5)
	ui.call("load_builtin", "covered_3v")
	ui.call("set_tab", 0)
	await ctx.wait(1.0)
	await ctx.hero()
	await ctx.wait(1.0)


func teardown(ctx: TourContext) -> void:
	var ld := ctx.loader
	if ld == null or not ld.has_method("domelab_designer"):
		return
	var ui: Variant = ld.call("domelab_designer")
	if ui != null and is_instance_valid(ui):
		ui.call("close")
