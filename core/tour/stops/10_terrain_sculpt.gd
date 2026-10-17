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
	# Open level ground, so the mound and the pond read against flat land.
	var site := ctx.find_flat(ctx.player_xz(), 22.0, 180.0)
	var f := ctx.player_forward()
	var r := f.cross(Vector3.UP)
	var mound := site - f * 8.0
	var pc := site + f * 14.0
	# Low and grazing: a mound only silhouettes from near ground level.
	var eye := site - f * 46.0 + r * 10.0 + Vector3.UP * 9.0
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
	var eye2 := site - f * 30.0 - r * 22.0 + Vector3.UP * 16.0
	await ctx.fly([[eye, site + Vector3.UP * 1.5], [eye2, site + f * 4.0]], 3.5)
	await ctx.hero()


func teardown(ctx: TourContext) -> void:
	for _i in _undos:
		if not bool(ctx.loader.call("undo_terrain_sculpt")):
			break
	_undos = 0
	var tb: Variant = ctx.loader.get("_edit_toolbar_ui") if ctx.loader != null else null
	if tb != null and is_instance_valid(tb) and bool((tb as Control).visible):
		tb.call("_exit_mode")
