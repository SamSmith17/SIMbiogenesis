extends TourStop

var _camp_id := ""


func _init() -> void:
	id = "camps"
	title = "Painted camps"
	chapter = "Build"
	summary = "Paint where people camp and the area fills with tents, shade and vehicles."
	how = PackedStringArray(["Press C for the camp tools",
		"Camp: brush, rectangle, lasso or polygon; Erase; Plots; Edit",
		"Tune look… authors a camp style and its layouts"])
	action = "camp_scatter"
	world = "mtvernon"
	budget_s = 40.0
	hour = 14.0
	blurb = ("Camps are households on a world-anchored lattice — an RV with its awning " +
		"and car, tents round a canopy — kept clear of buildings, roads, water and " +
		"steep ground. Painting a camp bigger adds households without moving any " +
		"already standing.")


func run(ctx: TourContext) -> void:
	var tb: Variant = ctx.loader.get("_edit_toolbar_ui") if ctx.loader != null else null
	if tb != null and is_instance_valid(tb):
		tb.call("open_with_section", "camps")
	# Open level ground: a camp refuses slopes, buildings and roads, so on the
	# wooded hillside in front of the player it placed almost nothing.
	var c := ctx.find_flat(ctx.player_xz(), 26.0, 220.0)
	var f := ctx.player_forward()
	var r := f.cross(Vector3.UP)
	var eye := c - f * 48.0 + r * 6.0 + Vector3.UP * 22.0
	ctx.place_camera(eye, c)
	await ctx.wait(1.2)
	var rect := func(half_w: float, half_d: float) -> PackedVector2Array:
		var out := PackedVector2Array()
		for s: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
			var q := c + r * (s.x * half_w) + f * (s.y * half_d)
			out.append(Vector2(q.x, q.z))
		return out
	ctx.caption("Paint a camp…", 2.5)
	_camp_id = str(ctx.loader.call("paint_camp_area", rect.call(16.0, 12.0), {"style": "mixed", "density": 1.0}))
	if not ctx.require(not _camp_id.is_empty(), "the camp was painted"):
		return
	await ctx.wait(2.5)
	ctx.caption("…paint it bigger: nothing already standing moves", 3.0)
	ctx.loader.call("paint_camp_area", rect.call(30.0, 20.0), {"style": "mixed", "density": 1.0})
	await ctx.fly([[eye, c], [c - f * 36.0 + r * 24.0 + Vector3.UP * 16.0, c]], 3.5)
	await ctx.hero()


func teardown(ctx: TourContext) -> void:
	if not _camp_id.is_empty():
		ctx.loader.call("delete_camp_area", _camp_id)
	_camp_id = ""
	var tb: Variant = ctx.loader.get("_edit_toolbar_ui") if ctx.loader != null else null
	if tb != null and is_instance_valid(tb) and bool((tb as Control).visible):
		tb.call("_exit_mode")
