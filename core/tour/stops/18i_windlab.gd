extends TourStop

## The wind turbine designer: Ugrinsky, Savonius, Lenz2, Darrieus, helical,
## propeller and farm rotors — one cut and scored from a single 18 × 24 in
## lawn sign — with the power curve, the start-up wind, the gearing and the
## generator matched to the site's wind, and the files to cut and print it.


func _init() -> void:
	id = "windlab"
	title = "Wind turbine designer"
	chapter = "Build"
	summary = "Design a small wind turbine — Ugrinsky, Savonius, Lenz2, Darrieus, helical, a propeller or a farm windmill — and see its power curve, the wind it starts in, the gearing and generator that suit your site, and the sheets to cut and score or the blades to print."
	how = PackedStringArray(["Library → Structures → Wind turbine designer…, or Design wind turbine… on a wind node's inspector",
		"Pick a built-in — the Lawn-sign Ugrinsky comes out of one 18 × 24 in corrugated plastic sign",
		"Rotor: size it, and its own proportions (the Ugrinsky's semicircle S and tail arc L, a Savonius's overlap, a propeller's tip speed ratio and airfoil)",
		"Made from, mount, drive: sheet or printed blades, the mast, a timing belt or gears; Match the gearing",
		"Generator and load: steppers to PMAs into a battery, an MPPT or a dump load; Rank every generator",
		"Power, Cut & print, Gearing & motors tabs; Export files, Make on a machine…, Apply / Place in world"])
	button = "Wind turbine designer…"
	world = "burningman"
	budget_s = 50.0
	hour = 14.0
	blurb = ("A rotor turns a fraction Cp of the wind's ½ρAv³ into shaft power at its best tip speed ratio: " +
		"drag rotors like the Savonius and the Ugrinsky near λ 0.5–1, lift rotors like the Darrieus and the " +
		"propeller near λ 3–7. The designer works each one out — the Ugrinsky from the published optimisation " +
		"of its semicircle and tail arc, the propeller's tapered, twisted blades from blade element theory — " +
		"then finds where the rotor's torque meets the generator's at every wind speed: a stepper's cogging " +
		"decides the wind it starts in, its inductance caps its current, a battery holds a PMA's speed and can " +
		"stall a Darrieus, an MPPT holds the rotor at its best. The power curve and the site's wind give the " +
		"year's energy; Match the gearing and Rank every generator find the drive and motor that make the " +
		"most there. The lawn-sign build — two scored S-blades and two hub discs clamping a NEMA 17, all from " +
		"one sign — scales to any size, nested on whatever sheet you have. Out come DXF and SVG cut sheets with " +
		"the score lines, printable STLs, and a power curve the systems graph runs on.")


func run(ctx: TourContext) -> void:
	var main := ctx.main
	if not ctx.require(main != null and main.has_method("open_windlab"), "Main hosts the designer"):
		return
	var ui: Variant = main.call("open_windlab", {})
	await ctx.wait(1.5)
	if not ctx.require(ui != null and is_instance_valid(ui) and bool((ui as CanvasItem).visible), "the designer opened"):
		return
	var presets := ctx.klass("WindLabPresets")
	ui.call("set_spec", presets.call("lawn_sign_spec"))
	ui.call("_frame_camera")
	ctx.caption("One 18 × 24 in lawn sign: two scored Ugrinsky blades and two hub discs on a NEMA 17", 3.0)
	await ctx.wait(3.0)
	ui.call("set_tab", 3)
	ctx.caption("Cut red, score green: both blades and both discs nest on the one sign", 3.0)
	await ctx.wait(3.0)
	ui.call("set_tab", 2)
	ctx.caption("Power and speed against the wind, Cp against tip speed ratio, the generator's volts and amps", 3.5)
	await ctx.wait(3.5)
	ui.call("set_spec", presets.call("ugrinsky_1m_spec"))
	ui.call("match_gearing")
	ui.call("set_tab", 4)
	ctx.caption("Scaled up: the drive ratio that makes the most energy a year at this site", 3.0)
	await ctx.wait(3.0)
	ui.call("set_tab", 0)
	ui.call("set_spec", presets.call("hawt_printed_spec"))
	ui.call("_frame_camera")
	ctx.caption("A propeller with twisted, tapered SG6043 blades to print", 2.5)
	await ctx.wait(2.5)
	ui.call("set_spec", presets.call("lawn_sign_spec"))
	ui.call("_frame_camera")
	await ctx.wait(1.0)
	await ctx.hero()
	await ctx.wait(1.0)


func teardown(ctx: TourContext) -> void:
	var main := ctx.main
	if main == null:
		return
	var ui: Variant = main.get("windlab_ui")
	if ui != null and is_instance_valid(ui):
		ui.call("close")
