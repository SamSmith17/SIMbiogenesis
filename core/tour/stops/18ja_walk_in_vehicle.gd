extends TourStop

## Walking into a living vehicle: aim at a door, Interact opens it, walk up
## and in (VehicleWalkIn), look round the room the designer laid out.

var _vid := ""


func _init() -> void:
	id = "walk_in_vehicle"
	title = "Step inside"
	chapter = "Build"
	summary = "Open a van's or a bus's door and walk through the rooms you designed."
	how = PackedStringArray(["Library → Vehicles → place a van, bus, RV or trailer",
		"Aim at one of its doors and press Interact: it opens",
		"Walk up and in; Interact on a door again shuts it",
		"Interact anywhere else on the vehicle drives it (the doors shut themselves)"])
	action = "interact"
	button = ""
	world = "burningman"
	budget_s = 40.0
	hour = 10.0
	blurb = ("Every living vehicle is a real room. Its doors are leaves that swing, fold or " +
		"slide open, its windows are glass you can see through from both sides, and the bed, " +
		"galley and benches from the designer stand where you put them. Open a door, walk in, " +
		"and look out at the camp from where the people who live there do.")


func run(ctx: TourContext) -> void:
	var pps := ctx.klass("PlacedPropService")
	var vs := ctx.klass("VehicleSpec")
	var vp := ctx.klass("VehiclePresets")
	var ppr := ctx.klass("PlacedPropRuntime")
	if not ctx.require(pps != null and vs != null and vp != null and ppr != null and ctx.player != null,
			"the vehicle services and a player exist"):
		return
	var at := ctx.ahead(11.0, -2.0)
	_vid = str(pps.call("place_prepped_at", ctx.main, "vehiclelab_vehicle",
		{"record_extra": {"vehicle_spec": vs.call("to_json_safe", vp.call("builtin", "shuttle_bus")),
			"collision_enabled": true}}, at.x, at.z, 0.0))
	await ctx.frames(12)
	if not ctx.require(not _vid.is_empty(), "a shuttle bus is placed"):
		return
	var prop: Node = ppr.call("find_by_prop_id", ctx.main, _vid)
	var walk: Node = prop.get_node_or_null("VehicleWalkIn") if prop != null else null
	if not ctx.require(walk != null and int(walk.call("door_count")) > 0, "the bus has doors to open"):
		return
	var gaps: Array = (walk.get("_gaps") as Array)
	var door := int((gaps[0] as Dictionary)["door"])
	var sill := float((gaps[0] as Dictionary)["sill"])
	var outp: Vector3 = walk.call("door_point", door, 4.5)
	var doorp: Vector3 = walk.call("door_point", door, 0.0)
	var ground := doorp.y - sill
	ctx.player.global_position = Vector3(outp.x, ground + 0.08, outp.z)
	ctx.aim_player_at(doorp + Vector3(0, 1.0, 0))
	await ctx.wait(1.2)
	ctx.caption("A shuttle bus someone lives in. Aim at its door…", 3.0)
	await ctx.hold(["move_forward"], 0.9)
	ctx.aim_player_at(doorp + Vector3(0, 0.9, 0))
	await ctx.wait(0.8)
	var focus: Node = ctx.player.get_node_or_null("InteractionFocus")
	ctx.require(focus != null and bool(focus.call("has_door_focus")), "the crosshair offers the door")
	ctx.caption("…and %s opens it" % ctx.key_label("interact"), 2.5)
	await ctx.press("interact")
	await ctx.wait(1.4)
	ctx.require(bool(walk.call("is_open", door)), "the door opened")
	ctx.caption("Walk up and in", 2.5)
	await ctx.hold(["move_forward"], 2.6)
	var root: Node3D = walk.get("_root")
	var local: Vector3 = root.global_transform.affine_inverse() * ctx.player.global_position
	ctx.require(absf(local.y - sill) < 0.25 and absf(local.x) < 1.0, "the player is standing inside")
	var house: Dictionary = root.get_meta("house_box", {})
	var rear: Vector3 = root.global_transform * Vector3(0.0, sill + 1.2, float(house.get("z1", 3.0)) - 0.4)
	ctx.aim_player_at(rear)
	await ctx.wait(0.4)
	ctx.caption("The room the designer laid out, lit and lived in", 3.5)
	await ctx.turn_player(-28.0, 2.0)
	await ctx.turn_player(40.0, 2.5)
	await ctx.hero(true)
	await ctx.wait(1.0)


func teardown(ctx: TourContext) -> void:
	ctx.release_held()
	if ctx.loader != null and not _vid.is_empty():
		ctx.loader.call("delete_prop_by_id", _vid)
	_vid = ""
