extends TourStop


func _init() -> void:
	id = "linkage_lab"
	title = "Linkage Lab"
	chapter = "Labs"
	summary = "Design folding scissor-linkage structures — shade, domes, arches — and fold them."
	how = PackedStringArray(["Press N for the Linkage Lab",
		"Fold / Unfold animates the mechanism; 📋 opens the build guide and BOM",
		"Place in world puts the live, foldable structure on the site"])
	action = "toggle_linkage_lab"
	world = "burningman"
	budget_s = 40.0
	hour = 14.0
	blurb = ("A native port of the LinkageLab designer: compound scissor mechanisms " +
		"solved in closed form, with solar panels, hardware assemblies, coverings and " +
		"a full bill of materials, cut list and drill templates. A placed structure " +
		"folds and deploys in the world and its panels join the solar graph.")


func run(ctx: TourContext) -> void:
	ctx.main.call("open_linkage_lab", {})
	await ctx.wait(2.0)
	var lab: Variant = ctx.main.get("linkage_lab_ui")
	if not ctx.require(lab != null and is_instance_valid(lab) and bool((lab as CanvasItem).visible),
			"the Linkage Lab opened"):
		return
	ctx.caption("A parametric folding structure, solved live", 3.0)
	await ctx.wait(2.5)
	await ctx.hero()
	ctx.caption("Fold…", 2.0)
	lab.call("_on_fold_btn")
	await ctx.wait(3.5)
	ctx.caption("…and deploy", 2.0)
	lab.call("_on_unfold_btn")
	await ctx.wait(3.5)


func teardown(ctx: TourContext) -> void:
	var lab: Variant = ctx.main.get("linkage_lab_ui")
	if lab != null and is_instance_valid(lab):
		lab.call("close")
