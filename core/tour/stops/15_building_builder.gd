extends TourStop

var _saved_style: Dictionary = {}
var _styled_idx := -1
var _had_style := false


func _init() -> void:
	id = "building_builder"
	title = "Building builder"
	chapter = "Build"
	summary = "Restyle an OSM building or design a house: roof, walls, doors, windows and a porch."
	how = PackedStringArray(["Aim at a building and press B, or open Building designer…",
		"Place a door, a window and a porch on the wall",
		"Place in world drops the house on the map"])
	action = "building_builder"
	world = "burningman"
	budget_s = 35.0
	hour = 14.0
	blurb = ("OSM footprints become buildings with level eaves and real roof geometry " +
		"(gable, hip, pyramid) from their tags, roofs textured from the aerial photo. " +
		"Doors and windows cut the wall, a porch runs along a face, and the same " +
		"designer places a house of its own.")


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
	var features := ctx.klass("BuildingFeatures")
	var presets := ctx.klass("BuildingPresets")
	if not ctx.require(features != null and presets != null, "the building designer is loaded"):
		return
	var saved: Dictionary = ctx.loader.call("get_building_style", best)
	_saved_style = saved.duplicate(true)
	_styled_idx = best
	_had_style = not saved.is_empty()
	var spec: Dictionary = presets.call("cottage")
	var wall: PackedVector2Array = PackedVector2Array()
	if data is Array:
		for b in data:
			if b is Dictionary and int((b as Dictionary).get("idx", -1)) == best:
				var raw: Variant = (b as Dictionary).get("points", PackedVector2Array())
				if raw is PackedVector2Array:
					wall = raw
				break
	if wall.size() >= 3:
		spec["elements"] = features.call("fit_elements", spec, wall)
	ctx.loader.call("apply_building_style", best, features.call("public_style", spec))
	var at := Vector3(bc.x, ctx.ground_y(bc.x, bc.y), bc.y)
	var f := ctx.player_forward()
	ctx.place_camera(at - f * 26.0 + Vector3.UP * 12.0, at + Vector3.UP * 3.0)
	if ctx.loader.has_method("set_building_focus_idx"):
		ctx.loader.call("set_building_focus_idx", best)
	ctx.caption("Aim at a building…", 2.0)
	await ctx.wait(2.2)
	ctx.loader.call("open_building_builder", best)
	await ctx.wait(2.0)
	ctx.caption("A porch, and openings cut through the wall", 3.0)
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
	if _styled_idx >= 0:
		if _had_style:
			ctx.loader.call("apply_building_style", _styled_idx, _saved_style)
		elif ctx.loader.has_method("clear_building_style"):
			ctx.loader.call("clear_building_style", _styled_idx)
		_styled_idx = -1
