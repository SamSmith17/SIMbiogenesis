extends TourStop

var _prop_id := ""
var _rig: Node = null


func _init() -> void:
	id = "forklift"
	title = "Forklift"
	chapter = "Build"
	summary = "Drive a forklift, lift pallets and crates; crews use it to unload heavy deliveries."
	how = PackedStringArray(["Library (U) → Vehicles tab → Forklift",
		"Aim at it and Interact to get in; PgUp / PgDn raise and lower the forks",
		"Crews unload anything over 200 kg with it"])
	action = "interact"
	button = "Library → Vehicles"
	world = "burningman"
	budget_s = 40.0
	hour = 14.0
	blurb = ("A 2.5 t counterbalance forklift with a working mast. Drive the forks under a " +
		"pallet and lift it, or let a crew run a delivery: heavy crates come off the " +
		"container on the forks while the light ones are carried by hand.")


func run(ctx: TourContext) -> void:
	var pps := ctx.klass("PlacedPropService")
	var ppr := ctx.klass("PlacedPropRuntime")
	if not ctx.require(pps != null and ppr != null, "the placed-prop services exist"):
		return
	var at := ctx.ahead(8.0)
	var placed: Dictionary = pps.call("place_model_at_xz", ctx.main, "vehicle_forklift", at.x, at.z)
	_prop_id = str(placed.get("prop_id", ""))
	if not ctx.require(not _prop_id.is_empty(), "the forklift was placed from the catalog"):
		return
	for _i in 10:
		await ctx.tree().physics_frame
	var prop: Node = ppr.call("find_by_prop_id", ctx.main, _prop_id)
	var veh: Node = prop.get_node_or_null("PlacedVehicle") if prop != null else null
	_rig = prop.get_node_or_null("ForkliftRig") if prop != null else null
	if not ctx.require(veh != null, "the forklift is drivable"):
		return
	ctx.require(_rig != null, "the forklift has a mast rig")
	ctx.caption("A forklift from the library…", 2.0)
	await ctx.wait(1.5)
	ctx.klass("PlayerPrefs").call("set_camera_mode", "third")
	ctx.player.call("request_mount", veh)
	await ctx.wait(0.8)
	ctx.require(bool(ctx.player.get("is_riding")), "the player got in")
	await ctx.hold(["move_forward"], 2.0)
	ctx.caption("…with forks that lift (PgUp / PgDn)", 2.5)
	if _rig != null:
		for k in 8:
			_rig.call("set_operated", float(k + 1) / 8.0 * 1.5, false)
			await ctx.wait(0.15)
	await ctx.hero(true)
	if _rig != null:
		for k in 8:
			_rig.call("set_operated", (1.0 - float(k + 1) / 8.0) * 1.5, false)
			await ctx.wait(0.1)


func teardown(ctx: TourContext) -> void:
	if _rig != null and is_instance_valid(_rig):
		_rig.call("release_operated")
	_rig = null
	if bool(ctx.player.get("is_riding")):
		ctx.player.call("_dismount_vehicle")
		await ctx.frames(3)
	ctx.klass("PlayerPrefs").call("set_camera_mode", "first")
	if not _prop_id.is_empty() and ctx.loader != null:
		ctx.loader.call("delete_prop_by_id", _prop_id)
	_prop_id = ""
