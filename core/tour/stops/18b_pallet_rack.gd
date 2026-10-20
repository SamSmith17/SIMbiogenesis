extends TourStop

## The parametric pallet-rack builder: bays, columns, levels, beams and decking
## rebuilt live in its own studio, then placed as one prop.


func _init() -> void:
	id = "pallet_rack"
	title = "Pallet rack builder"
	chapter = "Build"
	summary = "Design pallet-rack buildings — decks, walls, doors, stairs, railings and solar slopes — and place them."
	how = PackedStringArray(["Press the pallet-rack key, or Library → Structures → Pallet Rack",
		"Change bays, columns, levels and beams; click parts in the preview to edit them",
		"Add to the structure: pick Door, Window, Stairs, Solar slope, Greenhouse, Railing or Courtyard, then click where it goes",
		"Load a built-in design or save your own; save single elements as presets",
		"Place in world; click a placed rack → Edit rack… to change it in place"])
	action = "toggle_pallet_rack"
	world = "mtvernon"
	budget_s = 35.0
	hour = 14.0
	blurb = ("A parametric racking designer with real upright, beam and decking sizes. " +
		"Doors and windows cut their own holes in the plywood walls, stairs climb to any " +
		"deck, railings follow every open deck edge, and a sloped array of solar panels " +
		"or greenhouse glazing can lean on any face, bay by bay. Designs and single " +
		"elements save to a library. The finished rack is placed as one prop with " +
		"collision, and its solar panels join the system graph.")


func run(ctx: TourContext) -> void:
	var ld := ctx.loader
	if not ctx.require(ld != null and ld.has_method("open_pallet_rack_builder"), "the terrain loader has the rack builder"):
		return
	ld.call("open_pallet_rack_builder")
	await ctx.wait(1.5)
	var ui: Variant = ld.get("_pallet_rack_builder_ui")
	if not ctx.require(ui != null and is_instance_valid(ui) and bool((ui as CanvasItem).visible), "the rack builder opened"):
		return
	ctx.caption("A parametric rack, rebuilt as you change it", 3.0)
	await ctx.wait(2.5)
	var bays: Variant = ui.get("_bay_slider")
	if bays is HSlider:
		var s := bays as HSlider
		s.value = minf(s.value + 2.0, s.max_value)
		ctx.caption("More bays…", 2.0)
		await ctx.wait(2.0)
	var levels: Variant = ui.get("_levels_spin")
	if levels is SpinBox:
		var sb := levels as SpinBox
		sb.value = minf(sb.value + 1.0, sb.max_value)
		ctx.caption("…and another level", 2.0)
		await ctx.wait(2.2)
	if ui.has_method("load_design"):
		ui.call("load_design", "two_storey")
		ctx.caption("Doors, stairs and railings", 2.5)
		await ctx.wait(2.8)
		ui.call("load_design", "solar_workshop")
		ctx.caption("A solar slope with a greenhouse bay", 2.5)
		await ctx.wait(2.5)
	await ctx.hero()
	await ctx.wait(1.0)


func teardown(ctx: TourContext) -> void:
	var ld := ctx.loader
	if ld == null:
		return
	var ui: Variant = ld.get("_pallet_rack_builder_ui")
	if ui != null and is_instance_valid(ui):
		ui.call("close")
