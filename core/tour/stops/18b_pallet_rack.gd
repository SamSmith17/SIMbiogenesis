extends TourStop

## The parametric pallet-rack builder: bays, columns, levels, beams and decking
## rebuilt live in its own studio, then placed as one prop.


func _init() -> void:
	id = "pallet_rack"
	title = "Pallet rack builder"
	chapter = "Build"
	summary = "Design warehouse racking — bays, levels, stepped and U layouts — and place it."
	how = PackedStringArray(["Press the pallet-rack key, or Library → Structures → Pallet Rack",
		"Change bays, columns, levels and beams; click parts in the preview to edit them",
		"Place in world; click a placed rack → Edit rack… to change it in place"])
	action = "toggle_pallet_rack"
	world = "mtvernon"
	budget_s = 35.0
	hour = 14.0
	blurb = ("A parametric racking designer with real upright, beam and decking sizes. " +
		"Layouts can be stepped or U-shaped, single parts can be picked and changed in " +
		"the preview, and the finished rack is placed as one prop with collision, a " +
		"packed shipping size and an NPC space tag.")


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
	await ctx.hero()
	await ctx.wait(1.0)


func teardown(ctx: TourContext) -> void:
	var ld := ctx.loader
	if ld == null:
		return
	var ui: Variant = ld.get("_pallet_rack_builder_ui")
	if ui != null and is_instance_valid(ui):
		ui.call("close")
