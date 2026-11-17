extends TourStop

## Terraced rice paddies cut into a slope near the start, filled, the water
## spilling step to step.

var _id := ""


func _init() -> void:
	id = "terraces"
	title = "Terraced fields"
	chapter = "Build"
	summary = "Cut a hillside into level steps: rice paddies, reed beds or dry terraces, with water cascading down."
	how = PackedStringArray(["Open the edit toolbar (T), pick Terrace",
		"Hill: click a slope — everything above the click is terraced; or draw an outline",
		"Click a field to change its steps, water, crop and wiring"])
	action = "terrain_edit"
	button = "Terrace"
	world = "mtvernon"
	budget_s = 45.0
	hour = 11.0
	blurb = ("The Terrace tool cuts a slope into level steps that follow its contours. Each " +
		"step is a paddy behind a low bund: water pumped to the top fills it and spills to " +
		"the next, down to the bottom. Rice, reeds or taro grow in flooded steps, potatoes " +
		"or sorghum in dry ones, and each field is one node on the systems graph that " +
		"takes water and gives a harvest.")


func run(ctx: TourContext) -> void:
	var rt: Object = ctx.loader.call("terraces") if ctx.loader != null and ctx.loader.has_method("terraces") else null
	if not ctx.require(rt != null, "the terraces runtime exists"):
		return
	var spot := _slope_spot(ctx, ctx.player_xz(), 150.0)
	if not ctx.require(not spot.is_empty(), "a slope near the start"):
		return
	var at: Vector2 = spot["p"]
	var down: Vector2 = spot["down"]
	var poly: PackedVector2Array = rt.call("hill_outline", at + down * 18.0, 65.0)
	if not ctx.require(poly.size() >= 3, "a hill to terrace"):
		return
	_id = str(rt.call("create", poly, {"crop": "rice", "flooded": true, "labour": "free"}))
	if not ctx.require(not _id.is_empty(), "the field is cut"):
		return
	var c := Vector3(at.x, ctx.ground_y(at.x, at.y), at.y)
	ctx.caption("Terraces follow the slope's contours", 3.0)
	await ctx.wait(2.0)
	rt.call("set_fill", _id, 1.0)
	await ctx.wait(1.5)
	ctx.caption("Each step holds water behind its bund and spills to the next", 3.0)
	await ctx.orbit(c, 60.0, 34.0, 20.0, 80.0, 6.0)
	await ctx.hero()


func _slope_spot(ctx: TourContext, c: Vector2, reach: float) -> Dictionary:
	var best := {}
	var best_s := 0.0
	var step := 12.0
	var n := int(reach / step)
	for j in range(-n, n + 1):
		for i in range(-n, n + 1):
			var p := c + Vector2(i, j) * step
			if p.distance_to(c) > reach:
				continue
			var gx := float(ctx.loader.call("ground_without_terraces", p.x + 10.0, p.y)) \
				- float(ctx.loader.call("ground_without_terraces", p.x - 10.0, p.y))
			var gz := float(ctx.loader.call("ground_without_terraces", p.x, p.y + 10.0)) \
				- float(ctx.loader.call("ground_without_terraces", p.x, p.y - 10.0))
			var s := Vector2(gx, gz).length() / 20.0
			if s > best_s and s >= 0.06 and s <= 0.6:
				best_s = s
				best = {"p": p, "down": -Vector2(gx, gz).normalized()}
	return best


func teardown(ctx: TourContext) -> void:
	if _id.is_empty() or ctx.loader == null:
		return
	var rt: Object = ctx.loader.call("terraces")
	if rt != null:
		rt.call("delete", _id)
	_id = ""
