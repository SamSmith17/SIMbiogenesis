extends TourStop

## The Flows lens as a torus: energy runs down a central axis and leaves as
## heat, and the loops that energy keeps turning sit on shells either side,
## like the field round a magnet. Then a node is dragged along its shell.
## The player's lens shape, moved nodes and view are put back.

var _view_was := ""
var _shape_was := ""
var _pins_was := {}


func _init() -> void:
	id = "flow_torus"
	title = "Flows as a torus"
	chapter = "Systems"
	summary = "Sunlight down the middle, heat out the bottom, and the loops it drives turning either side."
	how = PackedStringArray(["Press G and click the Flows lens",
		"Click Torus in its header (Column goes back)",
		"Drag a node to move it along its shell; right-click puts it back"])
	action = "system_graph_toggle"
	world = "mtvernon"
	budget_s = 40.0
	hour = 13.0
	blurb = ("A site is a heat engine: sunlight comes in, does work and leaves as heat. The " +
		"torus shape of the Flows lens draws that. Everything that only handles electricity " +
		"stands on a central axis, sources at the top, and what is used leaves the bottom as " +
		"heat. Everything that handles water, food or nutrients sits on one of two lobes. " +
		"Each closed loop gets its own shell, smaller loops inside bigger ones, and round " +
		"every shell the flow runs down beside the axis and back up the far side. Wires " +
		"from the axis out to a machine are the work that keeps its loop turning.")


func run(ctx: TourContext) -> void:
	if not ctx.require(await ctx.open_graph("freeform"), "the graph opened"):
		return
	var g := ctx.graph
	_view_was = str(g.get("_graph_view_mode"))
	var canvas: Variant = g.get("_graph_canvas")
	if not ctx.require(canvas != null, "the graph has a canvas"):
		return
	_shape_was = str(canvas.get("flows_shape"))
	_pins_was = canvas.call("flows_pins_data")
	ctx.run_clock(60.0)
	g.call("_on_mode_chip_pressed", "flows")
	canvas.call("set_flows_shape", "column")
	ctx.caption("The Flows lens: the graph as a Sankey that can loop", 3.0)
	await ctx.wait(2.5)
	canvas.call("set_flows_shape", "torus")
	ctx.caption("Torus: energy runs down the middle and leaves as heat", 3.5)
	await ctx.wait(3.0)
	var lens: Variant = canvas.call("flows_lens")
	ctx.require(lens != null and str(lens.get("cur").get("shape", "")) == "torus", "the scope is laid out as a torus")
	await ctx.hero()
	ctx.caption("What it drives sits on shells either side, turning the same way", 3.5)
	await ctx.wait(3.0)
	canvas.call("set_flows_window", "24h")
	ctx.caption("Over a day, what cycles back closes its shell", 3.5)
	await ctx.wait(3.0)
	canvas.call("set_flows_window", "now")
	await ctx.wait(1.0)


func teardown(ctx: TourContext) -> void:
	var g := ctx.graph
	if g == null:
		return
	var canvas: Variant = g.get("_graph_canvas")
	if canvas != null:
		canvas.call("set_flows_pins_data", _pins_was)
		canvas.call("set_flows_shape", _shape_was if _shape_was != "" else "column")
	g.call("_on_mode_chip_pressed", _view_was if _view_was != "" else "freeform")
	ctx.run_clock(0.0)
	ctx.close_graph()
