extends TourStop

## The CNC gantry designer: CoreXY, delta, bed-slinger, router — pick a
## pattern, size it, jog it, play real G-code through the motion planner,
## read the checks and the bill of materials, export the firmware config.


func _init() -> void:
	id = "gantrylab"
	title = "CNC gantry designer"
	chapter = "Build"
	summary = "Design a 3D printer, router, laser or plotter from V-slot extrusion: seven kinematics, real parts, the motor maths, G-code played at true speed, a priced BOM and a Klipper / Marlin / grbl config."
	how = PackedStringArray(["Library → Structures → CNC gantry designer…",
		"Pick what it is for, or a pattern (bed-slinger, Cartesian XY, CoreXY, CoreXZ, H-bot, delta, router) or a built-in machine",
		"Size the work volume; choose the extrusion, guides, drives, motors, board, tool and bed",
		"Kinematics: jog the tool and read what each motor does (A = X + Y on a CoreXY)",
		"Simulate: a sample program or your own .gcode plays through the planner at real speed; send it to the placed machine",
		"Checks: step rate, torque, belt stretch, gantry sag, screw whip, delta reach; Files: printer.cfg, Configuration.h, grbl $, BOM, cut list"])
	button = "CNC gantry designer…"
	world = "mtvernon"
	budget_s = 50.0
	hour = 14.0
	blurb = ("A parametric designer for CNC gantries in the OpenBuilds / RepRap vocabulary: V-slot 2020 to " +
		"C-Beam, V-wheels or linear rails, GT2 belts, lead and ball screws, NEMA 17 to 34, the boards from " +
		"RAMPS to Klipper, hotends, pellet and clay extruders, spindles and lasers. Seven kinematic patterns " +
		"each with their reasons, and the maths behind them made visible: jog the tool and watch the CoreXY " +
		"motors turn against each other, the delta carriages climb their towers. Real G-code — a calibration " +
		"cube, a spiral vase, a router pocket, your own file — runs through a trapezoid motion planner at " +
		"true speed, with every corner slow-down, so the machine's limits can be seen before it is built. " +
		"The checks are the engineering: step rate against the board, torque against the moving mass, belt " +
		"stretch, gantry sag, screw whip, delta reach. The bill of materials prices every part and packs the " +
		"cut list into stock lengths; the exported printer.cfg, Configuration.h and grbl settings carry the " +
		"same numbers the simulation ran on. Placed in the world, the machine runs the job on the site's " +
		"clock, drawing filament, flake or clay and power on the systems graph.")


func run(ctx: TourContext) -> void:
	var ld := ctx.loader
	if not ctx.require(ld != null and ld.has_method("open_gantrylab"), "the terrain loader has the designer"):
		return
	ld.call("open_gantrylab")
	await ctx.wait(1.5)
	var ui: Variant = ld.call("gantrylab_designer")
	if not ctx.require(ui != null and is_instance_valid(ui) and bool((ui as CanvasItem).visible), "the designer opened"):
		return
	ui.call("load_builtin", "corexy_300")
	ctx.caption("A Voron-class CoreXY: two fixed motors share one belt loop, nothing heavy moves with the head", 3.0)
	await ctx.wait(3.0)
	ui.call("set_tab", 1)
	ctx.caption("Jog it: A = X + Y, B = X − Y — a pure X move turns both motors together", 1.0)
	for i in 12:
		ui.call("jog", Vector3(20.0 + 22.0 * i, 150.0, 40.0))
		await ctx.wait(0.18)
	for i in 10:
		ui.call("jog", Vector3(262.0, 150.0 - 13.0 * i, 40.0))
		await ctx.wait(0.18)
	ui.call("set_tab", 2)
	ui.call("load_sample", "cube")
	ui.call("sim_play", true)
	ctx.caption("A calibration cube through the motion planner at true speed: every corner slows to the jerk limit", 4.0)
	await ctx.wait(4.0)
	ui.call("sim_play", false)
	ui.call("load_builtin", "kossel_mini")
	ui.call("set_tab", 1)
	ctx.caption("A delta: three carriages climb their towers, six arms, every move is all three motors", 1.0)
	for i in 16:
		var a := TAU * float(i) / 16.0
		ui.call("jog", Vector3(cos(a) * 60.0, sin(a) * 60.0, 60.0))
		await ctx.wait(0.16)
	ui.call("load_builtin", "lead_750")
	ui.call("set_tab", 0)
	ctx.caption("A C-Beam router on lead screws: built heavy, because a cutter pushes back", 2.5)
	await ctx.wait(2.5)
	ui.call("load_builtin", "corexy_300")
	ui.call("set_tab", 0)
	await ctx.wait(1.0)
	await ctx.hero()
	await ctx.wait(1.0)


func teardown(ctx: TourContext) -> void:
	var ld := ctx.loader
	if ld == null or not ld.has_method("gantrylab_designer"):
		return
	var ui: Variant = ld.call("gantrylab_designer")
	if ui != null and is_instance_valid(ui):
		ui.call("close")
