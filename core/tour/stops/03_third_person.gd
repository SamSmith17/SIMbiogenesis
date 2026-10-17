extends TourStop


func _init() -> void:
	id = "third_person"
	title = "Third person"
	chapter = "World"
	summary = "A follow camera over the shoulder, with a body that walks, runs and drives."
	how = PackedStringArray(["Press F5 to switch between first and third person",
		"Settings → Player for distance, shoulder and body"])
	action = "toggle_third_person"
	world = "mtvernon"
	budget_s = 30.0
	hour = 14.0
	blurb = ("Third person keeps every tool working: the crosshair, interaction and " +
		"vehicles all read the same camera. The player's figure is posed procedurally " +
		"for walking, running, jumping, driving and using tools.")


func run(ctx: TourContext) -> void:
	var pp := ctx.klass("PlayerPrefs")
	pp.call("set_camera_mode", "third")
	await ctx.wait(1.0)
	ctx.require(str(pp.call("camera_mode")) == "third", "the camera switched to third person")
	ctx.caption("The follow camera sits behind and over the shoulder", 3.0)
	await ctx.hold(["move_forward"], 2.4)
	await ctx.hero(true)
	await ctx.hold(["move_forward", "move_right"], 1.6)
	await ctx.hold(["move_forward"], 1.5)


func teardown(ctx: TourContext) -> void:
	var pp := ctx.klass("PlayerPrefs")
	if pp != null:
		pp.call("set_camera_mode", "first")
