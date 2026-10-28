extends TourStop

## The Solar designer: digital twins of real solar modules — cells, size,
## frame, junction box and leads — on racks or trackers, with strings and
## live A / V / W, placed on the ground, a roof or a structure.


func _init() -> void:
	id = "pvlab"
	title = "Solar designer"
	chapter = "Build"
	summary = "Build an exact twin of your real solar panels — cells, size in mm, frame, backsheet, junction box, leads and connector — then rack them (2x4s, Unistrut, aluminium rail or a tracker), wire the strings and watch the amps, volts and watts, shade included."
	how = PackedStringArray(["Library → Structures → Solar designer…",
		"Cell tab: technology, wafer size, half-cut or full, busbars, colour",
		"Panel tab: size in mm, frame, backsheet, glass, junction box, leads, the data sheet's numbers",
		"Array tab: rows, mount, rack material, tilt or tracker; click modules to paint strings",
		"Pick the controller and each string's cold-morning Voc and hot-noon Vmp are checked against it",
		"Place it on the ground, a roof or a structure; on the graph each MPPT input is one node with its strings inside"])
	button = "Solar designer…"
	world = "mtvernon"
	budget_s = 40.0
	hour = 13.0
	blurb = ("A parametric designer for the solar you actually own. Every cell is drawn to the millimetre by a " +
		"shader — mono or poly, half-cut or full, busbars and fingers — and the module's electrics come from its " +
		"cells or from the data sheet you type in. Arrays sit on racks of real members (2x4s, Unistrut, aluminium " +
		"rail) with a span check, or on single-axis trackers that follow the sun and backtrack. Shade is checked " +
		"substring by substring and run through a bypass-diode I–V model, so one leaf on one cell costs what it " +
		"really does. Placed on the ground, a roof or a structure, the array lands on the systems graph as one " +
		"node per MPPT input with every string of panels inside.")


func run(ctx: TourContext) -> void:
	var ld := ctx.loader
	if not ctx.require(ld != null and ld.has_method("open_pvlab"), "the terrain loader has the designer"):
		return
	ld.call("open_pvlab")
	await ctx.wait(1.5)
	var ui: Variant = ld.call("pvlab_designer")
	if not ctx.require(ui != null and is_instance_valid(ui) and bool((ui as CanvasItem).visible), "the designer opened"):
		return
	ui.call("load_builtin", "backyard_2x4")
	ui.call("set_tab", 0)
	ctx.caption("Half-cut mono PERC cells, nine wire busbars, drawn to the millimetre", 2.5)
	await ctx.wait(2.5)
	ui.call("set_tab", 1)
	ctx.caption("JA Solar 380 W: 1769 × 1052 mm, its data sheet's Voc, Vmp, Isc, Imp", 2.5)
	await ctx.wait(2.5)
	ui.call("set_tab", 2)
	ctx.caption("Twelve modules on a 2x4 rack, two strings of six", 2.0)
	await ctx.wait(2.0)
	ui.call("set_shade_test", "edge")
	ctx.caption("A shadow along the front row's edge: the half-cut halves keep working", 2.5)
	await ctx.wait(2.0)
	await ctx.hero()
	ui.call("set_shade_test", "none")
	ui.call("load_builtin", "tracker_1p")
	ctx.caption("Single-axis trackers, backtracking so no row shades the next", 2.0)
	await ctx.wait(2.0)


func teardown(ctx: TourContext) -> void:
	var ld := ctx.loader
	if ld == null or not ld.has_method("pvlab_designer"):
		return
	var ui: Variant = ld.call("pvlab_designer")
	if ui != null and is_instance_valid(ui):
		ui.call("close")
