extends TourStop


func _init() -> void:
	id = "drone_view"
	title = "Survey drone"
	chapter = "World"
	summary = "Take off from where you stand and fly the site."
	how = PackedStringArray(["Press Tab to take off from your current view",
		"WASD to fly, Space / Ctrl to climb and descend, Tab or X to land"])
	action = "drone_view"
	world = "mtvernon"
	budget_s = 35.0
	hour = 14.0
	blurb = ("The drone lifts off from the player's own camera, so the view starts " +
		"exactly where you were looking. It is the quickest way to read a site's " +
		"layout before building on it.")


func run(ctx: TourContext) -> void:
	var ok := bool(ctx.player.call("toggle_remote_drone_view"))
	if not ctx.require(ok and bool(ctx.player.get("is_fpv_drone_mode")), "the drone took off"):
		return
	await ctx.hold(["drone_ascend"], 2.2)
	ctx.caption("Fly anywhere on the map", 3.0)
	await ctx.hold(["move_forward", "drone_ascend"], 2.0)
	await ctx.hold(["move_forward"], 2.5)
	await ctx.hero(true)
	await ctx.hold(["move_forward", "look_right"], 2.0)


func teardown(ctx: TourContext) -> void:
	if bool(ctx.player.get("is_fpv_drone_mode")):
		ctx.player.call("toggle_remote_drone_view")
