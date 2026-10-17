extends TourStop


func _init() -> void:
	id = "window_wall"
	title = "Window Wall"
	chapter = "Labs"
	summary = "Several monitors become windows onto the world, with one physically correct view."
	how = PackedStringArray(["Settings ⚙ → Window Wall to lay out the monitors",
		"Press F11 to open it; Esc to close"])
	action = "toggle_window_wall"
	world = "mtvernon"
	budget_s = 30.0
	# Opens native fullscreen windows on every monitor — not for a normal run.
	optional = true
	hour = 14.0
	blurb = ("Built for a row of monitors in a bus: one eye point and one orientation " +
		"with an off-axis frustum per screen, so the horizon lines up across the " +
		"bezels and the screens read as windows rather than three cameras.")


func run(ctx: TourContext) -> void:
	ctx.main.call("open_window_wall_view")
	await ctx.wait(3.0)
	ctx.require(bool(ctx.main.call("window_wall_view_open")), "the Window Wall opened")
	await ctx.hero()
	await ctx.wait(1.5)


func teardown(ctx: TourContext) -> void:
	if bool(ctx.main.call("window_wall_view_open")):
		ctx.main.call("close_window_wall_view")
		await ctx.wait(1.5)
