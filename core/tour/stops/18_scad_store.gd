extends TourStop


func _init() -> void:
	id = "scad_store"
	title = "Parametric hardware store"
	chapter = "Build"
	summary = "Customise OpenSCAD parts, render them to STL and place them in the world."
	how = PackedStringArray(["Press H for the store",
		"Pick a part, adjust its parameters, render, place"])
	action = "toggle_scad_store"
	world = "burningman"
	budget_s = 50.0
	hour = 14.0
	blurb = ("A catalogue of licence-checked OpenSCAD designs with their Customizer " +
		"parameters exposed as controls. Parts render through headless OpenSCAD to " +
		"STL meshes that can be placed like any other model.")


func run(ctx: TourContext) -> void:
	ctx.main.call("open_scad_store")
	await ctx.wait(1.5)
	var ui: Variant = ctx.main.get("scad_store_ui")
	if not ctx.require(ui != null and is_instance_valid(ui) and bool((ui as CanvasItem).is_visible_in_tree()),
			"the store opened"):
		return
	var parts: Variant = ui.get("_part_list")
	if parts is ItemList and (parts as ItemList).item_count > 0:
		var pick := 0
		for i in (parts as ItemList).item_count:
			if (parts as ItemList).get_item_text(i).begins_with("●"):
				pick = i
				break
		(parts as ItemList).select(pick)
		ui.call("_on_part_selected", pick)
		ctx.caption("A parametric part and its Customizer parameters", 3.0)
		await ctx.wait(2.0)
		ui.call("_on_generate")
		ctx.caption("Rendered by OpenSCAD to an STL you can place", 3.0)
		# A CGAL render takes a few seconds; wait for it (bounded).
		var t := 0.0
		while bool(ui.get("_rendering")) and t < 25.0 and not ctx.cancelled:
			await ctx.wait(0.5)
			t += 0.5
		if str(ui.get("_last_stl")).is_empty():
			ctx.note("the render did not finish (is OpenSCAD installed?) — showing the parameters")
		await ctx.wait(1.0)
	else:
		ctx.note("the part catalogue is empty")
	await ctx.hero()


func teardown(ctx: TourContext) -> void:
	var ui: Variant = ctx.main.get("scad_store_ui")
	if ui != null and is_instance_valid(ui) and (ui as Object).has_method("close"):
		ui.call("close")
