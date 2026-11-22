extends TourStop

var _undos := 0


func _init() -> void:
	id = "terrain_sculpt"
	title = "Terrain sculpting"
	chapter = "Build"
	summary = "Raise, lower, smooth, level pads, cut ramps and dig ponds at 1.5 m resolution."
	how = PackedStringArray(["Press T for the edit toolbar's terrain tools",
		"Pick Raise / Lower / Smooth / Level / Ramp / Pond on the left strip",
		"Each tool keeps its own radius, strength and shape"])
	action = "terrain_edit"
	world = "mtvernon"
	budget_s = 45.0
	hour = 14.0
	blurb = ("Edits are sparse height tiles over the real DEM, drawn as their own hi-res " +
		"meshes with colliders, with region-scoped undo. The toolbar is a tool " +
		"overlay, not a modal: you keep walking and looking while you sculpt.")


func run(ctx: TourContext) -> void:
	var tb: Variant = ctx.loader.get("_edit_toolbar_ui") if ctx.loader != null else null
	if not ctx.require(tb != null and is_instance_valid(tb), "the edit toolbar exists"):
		return
	tb.call("open_with_section", "terrain")
	if tb.has_method("_select_tool"):
		tb.call("_select_tool", "raise")
	# Sculpt in front of the start clearing and shoot from above the Douglas-fir canopy.
	var f := ctx.player_forward()
	var r := f.cross(Vector3.UP)
	var site := _clear_flat(ctx, ctx.player_xz() + Vector2(f.x, f.z) * 28.0, 18.0, 90.0)
	var mound := site - f * 8.0
	var pc := site + f * 14.0
	var eye := site - f * 44.0 + r * 12.0 + Vector3.UP * 36.0
	ctx.place_camera(eye, site + Vector3.UP * 1.5)
	await ctx.wait(1.5)
	ctx.caption("Raise: one brush stroke", 3.0)
	ctx.loader.call("begin_terrain_tile_edit")
	for i in 70:
		if ctx.cancelled:
			break
		var u := float(i) / 69.0
		ctx.loader.call("brush_stamp", "raise", mound + r * lerpf(-12.0, 12.0, u), 9.0, 0.11, 0.5, NAN)
		await ctx.frames(1)
	ctx.loader.call("end_terrain_tile_edit")
	_undos += 1
	await ctx.wait(1.0)
	ctx.caption("Pond: a lasso dug and filled", 3.0)
	var pond := PackedVector2Array()
	for i in 24:
		var a := TAU * float(i) / 24.0
		pond.append(Vector2(pc.x, pc.z) + Vector2(cos(a), sin(a)) * 10.0)
	if bool(ctx.loader.call("pond_command", pond, 2.5, "Tour pond")):
		_undos += 1
	var eye2 := site - f * 34.0 - r * 18.0 + Vector3.UP * 40.0
	await ctx.fly([[eye, site + Vector3.UP * 1.5], [eye2, site + f * 4.0]], 3.5)
	await ctx.hero()


func _clear_flat(ctx: TourContext, around: Vector2, radius: float, search_m: float) -> Vector3:
	var polys: Array = []
	if ctx.loader != null and "_auto_veg_data" in ctx.loader:
		var av: Variant = ctx.loader.get("_auto_veg_data")
		if av is Dictionary and (av as Dictionary).has("polygons"):
			polys = (av as Dictionary)["polygons"] as Array
	var best := around
	var best_score := INF
	var step := 14.0
	var r := 0.0
	while r <= search_m:
		var n := 1 if r == 0.0 else int(ceil(TAU * r / step))
		for i in n:
			var a := TAU * float(i) / float(n)
			var c := around + Vector2(cos(a), sin(a)) * r
			var wooded := false
			for pv in polys:
				var pd: Dictionary = pv
				var pts: Variant = pd.get("points_xz", pd.get("polygon", PackedVector2Array()))
				if pts is PackedVector2Array and (pts as PackedVector2Array).size() >= 3:
					if Geometry2D.is_point_in_polygon(c, pts as PackedVector2Array):
						wooded = true
						break
			var lo := INF
			var hi := -INF
			for k in 9:
				var q := c if k == 0 else c + Vector2(cos(TAU * float(k) / 8.0), sin(TAU * float(k) / 8.0)) * radius
				var y := ctx.ground_y(q.x, q.y)
				lo = minf(lo, y)
				hi = maxf(hi, y)
			var score := (hi - lo) + r * 0.004 + (25.0 if wooded else 0.0)
			if score < best_score:
				best_score = score
				best = c
		r += step
	return Vector3(best.x, ctx.ground_y(best.x, best.y), best.y)


func teardown(ctx: TourContext) -> void:
	for _i in _undos:
		if not bool(ctx.loader.call("undo_terrain_sculpt")):
			break
	_undos = 0
	var tb: Variant = ctx.loader.get("_edit_toolbar_ui") if ctx.loader != null else null
	if tb != null and is_instance_valid(tb) and bool((tb as Control).visible):
		tb.call("_exit_mode")
