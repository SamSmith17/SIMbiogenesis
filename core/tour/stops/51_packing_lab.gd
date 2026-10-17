extends TourStop

const MODAL_SCRIPT := "res://scenes/ui/packing_lab_modal.gd"


func _init() -> void:
	id = "packing_lab"
	title = "Packing Lab"
	chapter = "Labs"
	summary = "Will the whole site fit in the truck? Auto-pack it into real vehicle interiors."
	how = PackedStringArray(["Press Q for the Packing Lab (or Site Report → packing card)",
		"Pick a truck, trailer or container; Auto-pack, or place boxes by hand",
		"🚚 Deliver kit drops the packed crates on the site"])
	action = "toggle_packing_lab"
	world = "mtvernon"
	budget_s = 35.0
	hour = 14.0
	blurb = ("Everything on the site has a packed shipping size and mass. The Lab packs " +
		"the site's cargo into U-Haul, trailer and ISO container interiors with door " +
		"apertures and payload limits, and reports the load's centre of mass.")


func run(ctx: TourContext) -> void:
	var script := load(MODAL_SCRIPT) as Script
	if not ctx.require(script != null, "the Packing Lab script loads"):
		return
	script.call("open_site_cargo", ctx.tree())
	await ctx.wait(1.5)
	var modal := _modal(ctx)
	if not ctx.require(modal != null, "the Packing Lab opened"):
		return
	ctx.caption("The site's cargo, by real packed size and mass", 3.0)
	await ctx.wait(2.0)
	modal.call("_on_autopack")
	ctx.caption("Auto-pack into the truck", 2.5)
	await ctx.wait(3.0)
	await ctx.hero()
	await ctx.wait(1.5)


func _modal(ctx: TourContext) -> Node:
	for c in ctx.tree().root.get_children():
		var s: Variant = c.get_script()
		if s is Script and (s as Script).resource_path == MODAL_SCRIPT and bool(c.get("visible")):
			return c
	return null


func teardown(ctx: TourContext) -> void:
	var m := _modal(ctx)
	if m != null:
		m.call("close")
