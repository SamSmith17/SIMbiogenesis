extends TourStop

## The flat-pack furniture designer: slotted plywood ("PlayaTech") sofas,
## benches, stools, tables and chairs, nested onto sheets and written out as
## CNC files.


func _init() -> void:
	id = "flatpack"
	title = "Flat-pack furniture"
	chapter = "Build"
	summary = "Design slotted plywood furniture, see it nested on 4×8 sheets, and export DXF / SVG cut files."
	how = PackedStringArray(["Library → Structures → Flat-pack furniture designer…",
		"Pick a sofa, bench, stool, table, chair or lounger, or one of the built-in designs",
		"Change the sizes, the plywood, the bit and the joinery; every slot is worked out from the assembly",
		"Sheets shows the parts nested as they will be cut; Export DXF + SVG writes the files",
		"Place in world: people sit on benches and sleep on the daybed"])
	button = "Flat-pack furniture designer…"
	world = "mtvernon"
	budget_s = 40.0
	hour = 14.0
	blurb = ("A parametric designer for the slot-together plywood furniture seen all over Burning " +
		"Man. Each piece is a set of flat parts; the designer intersects them in 3D and cuts the " +
		"half-lap slots, mortises and wedge holes where they meet, sized to the plywood's real " +
		"thickness plus clearance, with dogbones for the router bit. The parts nest onto sheets, " +
		"the cut list gives every size, and one DXF and SVG per sheet goes straight to a CNC. The " +
		"sample sofa sets up upright, reclined or flat as a daybed from the same twelve parts.")


func run(ctx: TourContext) -> void:
	var ld := ctx.loader
	if not ctx.require(ld != null and ld.has_method("open_flatpack_designer"), "the terrain loader has the designer"):
		return
	ld.call("open_flatpack_designer")
	await ctx.wait(1.5)
	var ui: Variant = ld.call("flatpack_designer")
	if not ctx.require(ui != null and is_instance_valid(ui) and bool((ui as CanvasItem).visible), "the designer opened"):
		return
	ui.call("load_builtin", "daybed")
	ctx.caption("Twelve parts of plywood, slotted together", 3.0)
	await ctx.wait(3.0)
	ui.set("_explode", 0.7)
	ui.call("_rebuild_studio")
	ctx.caption("Every slot is found where two parts meet", 2.5)
	await ctx.wait(2.5)
	ui.set("_explode", 0.0)
	ui.call("_rebuild_studio")
	ui.call("set_tab", 1)
	ctx.caption("Nested onto three 4×8 sheets, ready for the router", 3.0)
	await ctx.wait(3.0)
	ui.call("load_builtin", "lounger")
	ui.call("set_tab", 2)
	ctx.caption("Drag the side profile to reshape a lounger", 2.5)
	await ctx.wait(2.5)
	ui.call("load_builtin", "daybed")
	ui.call("set_tab", 0)
	await ctx.wait(1.0)
	await ctx.hero()
	await ctx.wait(1.0)


func teardown(ctx: TourContext) -> void:
	var ld := ctx.loader
	if ld == null or not ld.has_method("flatpack_designer"):
		return
	var ui: Variant = ld.call("flatpack_designer")
	if ui != null and is_instance_valid(ui):
		ui.call("close")
