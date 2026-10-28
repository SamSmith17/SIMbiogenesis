extends TourStop


func _init() -> void:
	id = "building_builder"
	title = "Building builder"
	chapter = "Build"
	summary = "Restyle any OSM building: roof shape and pitch, walls, doors, windows, facades."
	how = PackedStringArray(["Aim at a building and press B (or Interact)",
		"Click the preview walls to place doors and windows",
		"The Library tab swaps the building for a placed model"])
	action = "building_builder"
	world = "burningman"
	budget_s = 35.0
	hour = 14.0
	blurb = ("OSM footprints become buildings with level eaves and real roof geometry " +
		"(gable, hip, pyramid) from their tags, roofs textured from the aerial photo. " +
		"Each building can be restyled in a studio preview and the change is saved " +
		"per site.")


func run(ctx: TourContext) -> void:
	var data: Variant = ctx.loader.get("_buildings_data") if ctx.loader != null else null
	var best := -1
	var bd := INF
	var bc := Vector2.ZERO
	if data is Array:
		for b in data:
			if not (b is Dictionary):
				continue
			var pts: Variant = (b as Dictionary).get("points", PackedVector2Array())
			if not (pts is PackedVector2Array) or (pts as PackedVector2Array).size() < 3:
				continue
			var c := Vector2.ZERO
			for q in pts:
				c += q
			c /= float((pts as PackedVector2Array).size())
			var d := c.distance_to(ctx.player_xz())
			if d < bd:
				bd = d
				best = int((b as Dictionary).get("idx", -1))
				bc = c
	if not ctx.require(best >= 0, "there is a building on this map"):
		return
	var at := Vector3(bc.x, ctx.ground_y(bc.x, bc.y), bc.y)
	var f := ctx.player_forward()
	ctx.place_camera(at - f * 26.0 + Vector3.UP * 12.0, at + Vector3.UP * 3.0)
	if ctx.loader.has_method("set_building_focus_idx"):
		ctx.loader.call("set_building_focus_idx", best)
	ctx.caption("Aim at a building…", 2.0)
	await ctx.wait(2.2)
	ctx.loader.call("open_building_builder", best)
	await ctx.wait(2.0)
	ctx.caption("Roof, walls, colours, doors and windows", 3.0)
	await ctx.wait(2.5)
	await ctx.hero()
	await ctx.wait(1.0)


func teardown(ctx: TourContext) -> void:
	if ctx.loader == null:
		return
	var ui: Variant = ctx.loader.get("_building_builder_ui")
	if ui != null and is_instance_valid(ui) and (ui as Object).has_method("close"):
		ui.call("close")
	if ctx.loader.has_method("set_building_focus_idx"):
		ctx.loader.call("set_building_focus_idx", -1)
