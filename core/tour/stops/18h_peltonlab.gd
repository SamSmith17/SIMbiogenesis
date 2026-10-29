extends TourStop

## The Pelton wheel designer: one standard cup, a wheel sized round it — cups,
## diameter, hub and bolt pattern, housing, bearings, belt or gears and the
## generator — and what each choice does to the speed and the power.


func _init() -> void:
	id = "peltonlab"
	title = "Pelton wheel designer"
	chapter = "Build"
	summary = "Design a micro-hydro Pelton turbine round the common cup: how many cups, how big the wheel, the side discs, hub and bolt pattern, the jets, the housing, bearings, drive and generator — with the speed, power and strength worked out as you go."
	how = PackedStringArray(["Library → Structures → Pelton wheel designer…, or the Hydro Lab's Design Pelton wheel… on a Pelton turbine",
		"Wheel: the cup count, the overall diameter and the cup size; Set cups by the 15 + m/2 rule",
		"Rotor: the side discs that clamp the cup tabs, the shaft, the hub flange and its bolt pattern",
		"Jets, housing (auto-sized round the wheel), a horizontal or vertical shaft",
		"Shaft, bearings and drive: pillow blocks or flange units, a coupler, V-belt, timing belt or gears; Match the ratio to the generator",
		"Performance: power and speed against the wheel's size and its cups; Apply writes the wheel onto the Hydro Lab's turbine"])
	button = "Pelton wheel designer…"
	world = "mtvernon"
	budget_s = 45.0
	hour = 14.0
	blurb = ("Every wheel here is built from the same cup — the common split bucket with one root tab, " +
		"scaled whole — so the design is about the wheel round it. The cups' pitch circle and the jet set the " +
		"speed (rpm = 60·2·0.46·v / π·PCD): a bigger wheel turns slower with more torque, the same water making " +
		"the same shaft power, and the gearing then decides whether the generator is anywhere near its rated " +
		"speed. The textbook proportions are checked as you go — jet ratio, cup width against the jet, " +
		"15 + m/2 cups, how many fit before their tabs touch — and so is the strength: the pull on the cup " +
		"bolts at runaway, the tabs, the discs, the hub bolts with the jet stalled, the shaft under bending " +
		"and torsion, the bearings' life, the coupler, the belt, the generator's speed limit and whether it " +
		"makes enough volts to charge the bank. Opened from the Hydro Lab it designs that turbine against its " +
		"real head and penstock, and Apply puts the designed machine on the map with its efficiencies on the " +
		"graph; the disc and spacer come out as DXF and SVG cut files with every bolt hole.")


func run(ctx: TourContext) -> void:
	var main := ctx.main
	if not ctx.require(main != null and main.has_method("open_peltonlab"), "Main hosts the designer"):
		return
	var ui: Variant = main.call("open_peltonlab", {})
	await ctx.wait(1.5)
	if not ctx.require(ui != null and is_instance_valid(ui) and bool((ui as CanvasItem).visible), "the designer opened"):
		return
	var presets := ctx.klass("PeltonLabPresets")
	ui.call("set_spec", presets.call("classic_spec"))
	ui.call("_frame_camera")
	ctx.caption("21 cups on a 350 mm wheel, belted up to a 400 W PMA — the wheel turning at its real speed", 3.0)
	await ctx.wait(3.0)
	ui.call("set_tab", 1)
	ctx.caption("Face on: the pitch circle the jet meets, the side discs clamping the cup tabs, the hub's bolt pattern", 3.0)
	await ctx.wait(3.0)
	ui.call("set_tab", 2)
	ctx.caption("A bigger wheel turns slower; too small and the cups crowd — power and speed against size and cup count", 3.5)
	await ctx.wait(3.5)
	ui.call("set_tab", 0)
	ui.call("set_spec", presets.call("vertical_spec"))
	ui.call("_frame_camera")
	ctx.caption("A vertical shaft takes four jets round the wheel, geared down to a hub motor", 3.0)
	await ctx.wait(3.0)
	ui.call("set_spec", presets.call("classic_spec"))
	ui.call("_frame_camera")
	await ctx.wait(1.0)
	await ctx.hero()
	await ctx.wait(1.0)


func teardown(ctx: TourContext) -> void:
	var main := ctx.main
	if main == null:
		return
	var ui: Variant = main.get("peltonlab_ui")
	if ui != null and is_instance_valid(ui):
		ui.call("close")
