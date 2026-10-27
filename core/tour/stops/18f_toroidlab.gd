extends TourStop

## The toroid designer: bent-tube toroids on structural pipe fittings, with
## rings, bracing and tension lines, a pleated origami canopy and a solar
## ring that joins the systems graph.


func _init() -> void:
	id = "toroidlab"
	title = "Toroid designer"
	chapter = "Build"
	summary = "Design bent-tube toroids on pipe fittings: size, ribs, rings, bracing and tension lines, a pleated correx canopy and a ring of solar panels; get the cut list with every bend, bend templates and the canopy's cut sheets."
	how = PackedStringArray(["Library → Structures → Toroid designer…",
		"Set the inner and outer radius, the height, the rib count and the tube",
		"Add rings by their angle on the rib circle, and X, diagonal or zigzag bracing or tension lines between any two",
		"Shape the origami canopy (edges, peak, pleat depths, flange, bolts) and see its pieces nested on 4' × 8' sheets",
		"Pick the panels and their wiring (series × parallel); placed in the world they join the graph",
		"Export writes the canopy sheets as DXF / SVG, a full-size bend template per tube, the CSVs and the cut sheet"])
	button = "Toroid designer…"
	world = "mtvernon"
	budget_s = 40.0
	hour = 14.0
	blurb = ("A parametric designer for ring-shaped shade structures. Every rib is the same circle swept round " +
		"the axis and cut by the ground, bent from tube in a few equal arcs and joined with tees, crosses, " +
		"couplers and crossover clamps; rings run round it at any angle, and braces or tension lines tie any " +
		"two rings together. Under the ribs hangs an origami canopy: each bay a diamond pleat folded from scored " +
		"corrugated plastic, flanged and bolted to its neighbours. Over the crown, flexible panels bend to the " +
		"frame and wire into strings that land on the systems graph. The reference build — 24 ribs of 1\" " +
		"mild steel, 48 sheets of 10 mm correx and 24 × 100 W panels in 6S × 4P — is a built-in design.")


func run(ctx: TourContext) -> void:
	var ld := ctx.loader
	if not ctx.require(ld != null and ld.has_method("open_toroidlab"), "the terrain loader has the designer"):
		return
	ld.call("open_toroidlab")
	await ctx.wait(1.5)
	var ui: Variant = ld.call("toroidlab_designer")
	if not ctx.require(ui != null and is_instance_valid(ui) and bool((ui as CanvasItem).visible), "the designer opened"):
		return
	ui.call("load_builtin", "overview_toroid")
	ctx.caption("24 ribs of 1\" steel, a pleated correx canopy, 24 × 100 W panels in 6S × 4P", 3.0)
	await ctx.wait(3.0)
	ui.call("set_assembly", 0.0)
	for i in 14:
		ui.call("set_assembly", (i + 1) / 14.0)
		await ctx.wait(0.2)
	ui.call("set_explode", 0.6)
	ctx.caption("The canopy and the panels lift off the frame", 2.0)
	await ctx.wait(2.0)
	ui.call("set_explode", 0.0)
	ui.call("set_tab", 1)
	ctx.caption("The section: one rib circle, its rings, the canopy's pleat and a panel", 2.5)
	await ctx.wait(2.5)
	ui.call("set_tab", 2)
	ctx.caption("Each half-bay is one 4' × 8' sheet, scored and folded, with a bolted flange", 2.5)
	await ctx.wait(2.5)
	ui.call("set_tab", 0)
	ui.call("load_builtin", "braced_toroid")
	ctx.caption("Tension lines and tube braces between any two rings", 2.0)
	await ctx.wait(1.5)
	await ctx.hero()
	await ctx.wait(1.0)


func teardown(ctx: TourContext) -> void:
	var ld := ctx.loader
	if ld == null or not ld.has_method("toroidlab_designer"):
		return
	var ui: Variant = ld.call("toroidlab_designer")
	if ui != null and is_instance_valid(ui):
		ui.call("close")
