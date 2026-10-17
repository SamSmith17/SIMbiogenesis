extends TourStop

var _prop_id := ""


func _init() -> void:
	id = "vehicles"
	title = "Vehicles"
	chapter = "Build"
	summary = "Place a golf cart, EUC, skid steer, camper van or tool bus — and drive it."
	how = PackedStringArray(["Library (U) → Vehicles tab → place one",
		"Aim at it and Interact to get in; X to get out",
		"F5 for the chase camera"])
	action = "interact"
	button = "Library → Vehicles"
	world = "walton"
	budget_s = 40.0
	hour = 14.0
	blurb = ("Placed vehicles use the same riding code as the scene vehicles, with a " +
		"real collision footprint, a chase camera in third person, and an electric " +
		"battery that drains with distance and trickle-charges while parked.")


func run(ctx: TourContext) -> void:
	var pps := ctx.klass("PlacedPropService")
	var ppr := ctx.klass("PlacedPropRuntime")
	if not ctx.require(pps != null and ppr != null, "the placed-prop services exist"):
		return
	var at := ctx.ahead(8.0)
	var placed: Dictionary = pps.call("place_model_at_xz", ctx.main, "vehicle_appa", at.x, at.z)
	_prop_id = str(placed.get("prop_id", ""))
	if not ctx.require(not _prop_id.is_empty(), "Appa was placed from the catalog"):
		return
	for _i in 10:
		await ctx.tree().physics_frame
	var prop: Node = ppr.call("find_by_prop_id", ctx.main, _prop_id)
	var veh: Node = prop.get_node_or_null("PlacedVehicle") if prop != null else null
	if not ctx.require(veh != null, "the prop is a drivable vehicle"):
		return
	ctx.caption("Placed from the library…", 2.0)
	await ctx.wait(1.5)
	ctx.klass("PlayerPrefs").call("set_camera_mode", "third")
	ctx.player.call("request_mount", veh)
	await ctx.wait(0.8)
	ctx.require(bool(ctx.player.get("is_riding")), "the player got in")
	ctx.caption("…and driven", 2.5)
	await ctx.hold(["move_forward"], 2.5)
	await ctx.hero(true)
	await ctx.hold(["move_forward", "move_right"], 2.0)
	await ctx.hold(["move_forward"], 1.0)


func teardown(ctx: TourContext) -> void:
	if bool(ctx.player.get("is_riding")):
		ctx.player.call("_dismount_vehicle")
		await ctx.frames(3)
	ctx.klass("PlayerPrefs").call("set_camera_mode", "first")
	if not _prop_id.is_empty() and ctx.loader != null:
		ctx.loader.call("delete_prop_by_id", _prop_id)
	_prop_id = ""
