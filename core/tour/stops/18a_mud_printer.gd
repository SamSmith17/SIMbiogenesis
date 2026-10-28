extends TourStop

## The large-format mud printer: placed from the library, its 3D print setup
## (slicer + bed preview), the Mud Building Designer that draws rooms, walls and
## doorways and slices them into a toolpath — and then the print itself, rising
## layer by layer on the clock. The stop stops short of the end so no finished
## print is left on the site, and removes the printer.

## How far the print gets before the stop leaves it (a finished mud print
## persists as a prop).
const PRINT_TO := 0.94

var _pid := ""
var _clock := {}


func _init() -> void:
	id = "mud_printer"
	title = "Mud printer"
	chapter = "Build"
	summary = "A gantry printer for mud and clay: design a building, slice it, and watch it print."
	how = PackedStringArray(["Press U for the library → Tools → Mud Printer, and place it",
		"Aim at the printer + Interact: the 3D print setup",
		"Design building… draws rooms, walls and doorways; Print starts the job, Export GRBL writes the G-code"])
	action = "toggle_library"
	world = "burningman"
	budget_s = 70.0
	hour = 13.0
	blurb = ("Additive machines are placed in the world and bound to a node on the " +
		"systems graph. The print setup previews a part on the bed with its toolpath " +
		"layer by layer; the building designer turns a floor plan into cambered, " +
		"infilled walls and exports volumetric GRBL G-code. A started print rises " +
		"bead by bead in the world on the sim clock — scrub the timeline and it " +
		"builds or un-builds — and dries from wet to dry colour in place.")


func run(ctx: TourContext) -> void:
	var p := ctx.preset("TOOLS", "mud_printer")
	if not ctx.require(not p.is_empty(), "the Mud Printer library preset exists"):
		return
	var m := ctx.main
	_clock = ctx.save_clock()
	var f := ctx.player_forward()
	var at := ctx.find_flat(ctx.player_xz() + Vector2(f.x, f.z) * 14.0, 4.0, 120.0, 8.0)
	_pid = await ctx.place_preset(p, at)
	if not ctx.require(not _pid.is_empty(), "the mud printer was placed"):
		return
	var r := f.cross(Vector3.UP)
	var eye := at - f * 7.0 + r * 3.0 + Vector3.UP * 3.5
	ctx.place_camera(eye, at + Vector3.UP * 1.2)
	ctx.caption("Placed from the library, bound to its graph node", 3.0)
	await ctx.orbit(at + Vector3.UP * 1.2, 7.5, 2.6, -25.0, 10.0, 3.0)
	var g := ctx.graph
	if ctx.require(g != null and bool(g.call("open_print_setup_for_prop", _pid)), "the print setup opened"):
		ctx.caption("Print setup: part, slicer, bed preview", 3.0)
		await ctx.wait(3.0)
		await ctx.shot("print_setup")
		var ps: Variant = g.get("_print_setup_modal")
		if ps != null and is_instance_valid(ps):
			ps.call("close")
		await ctx.wait(0.3)
	var item_id := str(ctx.prop_record(_pid).get("graph_item_id", ""))
	if not ctx.require(g != null and bool(g.call("open_mud_building_designer", item_id)), "the building designer opened"):
		return
	ctx.caption("Design a building: plan, walls, camber, infill, doorways", 3.5)
	await ctx.wait(3.5)
	await ctx.shot("designer")
	# Print it: the designer's own Print button (slices, starts the job, closes).
	var des: Variant = g.get("_mud_building_designer")
	m.set("time_scale", 0.0)
	des.call("_on_print_pressed")
	await ctx.frames(3)
	var specs: Dictionary = (ctx.graph.get("model").call("get_item", item_id) as Dictionary).get("specs", {})
	if not ctx.require(bool(specs.get("job_active", false)), "the print job started"):
		return
	var start_h := float(specs.get("job_start_abs_hours", 0.0))
	var dur_h := maxf(float(specs.get("job_duration_hr", 0.0)), 0.01)
	ctx.note("print job %.1f h" % dur_h)
	# Close in on the bed, then let the building rise.
	var bed := at + Vector3.UP * 0.8
	var near := at - f * 5.5 + r * 2.5 + Vector3.UP * 2.6
	ctx.place_camera(near, bed)
	ctx.caption("Printing — %s of beads, layer by layer" % _fmt_h(dur_h), 3.5)
	await _sweep(ctx, start_h, 0.0, PRINT_TO * 0.55, dur_h, 5.0)
	await ctx.hero(true)
	ctx.caption("Wet mud dries to its final colour as the walls rise", 3.0)
	await _sweep(ctx, start_h, PRINT_TO * 0.55, PRINT_TO, dur_h, 4.0)
	await ctx.orbit(bed, 6.0, 2.0, 20.0, 70.0, 3.0)


func _fmt_h(h: float) -> String:
	return "%.0f min" % (h * 60.0) if h < 1.5 else "%.1f h" % h


## Move the clock through the job from fraction u0 to u1 over `seconds`.
func _sweep(ctx: TourContext, start_h: float, u0: float, u1: float, dur_h: float, seconds: float) -> void:
	var span := maxf(seconds * ctx.pace, 0.05)
	var e := 0.0
	while e < span and not ctx.cancelled:
		var u := lerpf(u0, u1, smoothstep(0.0, 1.0, e / span))
		ctx.main.call("set_absolute_hours", start_h + u * dur_h)
		await ctx.tree().process_frame
		e += ctx.host.get_process_delta_time()
	ctx.main.call("set_absolute_hours", start_h + u1 * dur_h)


func teardown(ctx: TourContext) -> void:
	var g := ctx.graph
	if g != null:
		for k in ["_mud_building_designer", "_print_setup_modal"]:
			var mdl: Variant = g.get(k)
			if mdl != null and is_instance_valid(mdl) and bool((mdl as CanvasItem).visible):
				mdl.call("close")
	if not _pid.is_empty():
		ctx.remove_prop(_pid)
	_pid = ""
	ctx.restore_clock(_clock)
	_clock = {}
