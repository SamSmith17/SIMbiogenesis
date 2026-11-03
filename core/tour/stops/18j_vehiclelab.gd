extends TourStop

## The living-vehicle designer: vans, buses, RVs, trucks and trailers people
## live in, built from a chassis and a body picked independently, with roof
## fans, AC, solar and an awning dragged onto the preview.


func _init() -> void:
	id = "vehiclelab"
	title = "Vehicle designer"
	chapter = "Build"
	summary = "Build a twin of your van, skoolie, RV or box truck from its real chassis and body, paint it, bolt fans, AC, Starlink and solar onto it, and park it at camp: people sleep in its beds and cook in its galley."
	how = PackedStringArray(["Library → Vehicles → Vehicle designer…",
		"Pick a type, then its chassis and its body on their own (an E-450 dually under a fiberglass shuttle box)",
		"Set the body's length, width, roof height and roof shape, its windows and doors, its paint or a wrap image",
		"Arm a roof fan, an AC unit, solar panels or an awning and click where it goes; drag it to move it, Del removes it",
		"Cutaway or Plan shows the inside: arm a bed, galley, fridge, shower or battery and click the floor; drag to move, R turns it",
		"The checks want a 50 cm way in from a door to every bed and fixture, room to sit up in bed and to stand in the shower",
		"Its battery, solar, loads and water tanks become one node on the system graph; its shower and galley draw on its own tank",
		"Type the one-way miles: the round trip in gallons (or kWh) and dollars from a road-load model",
		"Place in world: drive it, and the camp's people sleep in its beds"])
	button = "Vehicle designer…"
	world = "burningman"
	budget_s = 46.0
	hour = 14.0
	blurb = ("Eleven kinds of converted vehicle — camper and cargo vans, shuttle and school buses, step vans, " +
		"ambulances, Class C and Class A RVs, box trucks, travel trailers and a semi with a container home — " +
		"each from a real chassis (wheelbase, tyres, duals, tank, weight rating, steering lock) under a body " +
		"you size yourself. Roof items snap to the crown of the roof or the sides, solar comes as real modules " +
		"in rows and columns, and a model of your own vehicle can be laid over the parametric one. Fuel use " +
		"comes from rolling resistance and drag, and lands inside each chassis' real-world mpg.")


func run(ctx: TourContext) -> void:
	var ld := ctx.loader
	if not ctx.require(ld != null and ld.has_method("open_vehiclelab"), "the terrain loader has the designer"):
		return
	ld.call("open_vehiclelab")
	await ctx.wait(1.5)
	var ui: Variant = ld.call("vehiclelab_designer")
	if not ctx.require(ui != null and is_instance_valid(ui) and bool((ui as CanvasItem).visible), "the designer opened"):
		return
	ui.call("load_builtin", "shuttle_bus")
	ctx.caption("A 2006 E-450 dually under a fiberglass shuttle body: 1.6 kW of solar, a fan, an awning", 3.0)
	await ctx.wait(3.0)
	ui.call("set_cutaway", true)
	ctx.caption("Inside: a bed along the back, a galley, a dinette and a wet bath", 3.0)
	await ctx.wait(3.0)
	ui.call("set_plan_view", true)
	ctx.caption("From above: every bed and fixture needs a 50 cm way in from a door", 3.0)
	await ctx.wait(3.0)
	ui.call("set_plan_view", false)
	ui.call("set_cutaway", false)
	ui.call("load_builtin", "rv")
	ctx.caption("A Class C RV with its cab-over bunk, a rooftop AC and a roof fan", 2.5)
	await ctx.wait(2.5)
	ui.call("load_builtin", "semi_container")
	ctx.caption("A day cab hauling a 40 ft container home", 2.5)
	await ctx.wait(2.5)
	ui.call("load_builtin", "school_bus")
	ctx.caption("A skoolie: a roof rack of solar, a ladder, an awning, bunks and a shower inside", 3.0)
	await ctx.wait(1.5)
	await ctx.hero()
	await ctx.wait(1.0)


func teardown(ctx: TourContext) -> void:
	var ld := ctx.loader
	if ld == null or not ld.has_method("vehiclelab_designer"):
		return
	var ui: Variant = ld.call("vehiclelab_designer")
	if ui != null and is_instance_valid(ui):
		ui.call("close")
