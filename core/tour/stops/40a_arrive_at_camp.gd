extends TourStop

## A camp arriving: a box truck with a kit in its bay drives in through the
## site gate (VehicleDrive, a function of the clock), parks in its camp and
## the crew carries the crates out of its door.

var _ids: Array = []
var _clock: Dictionary = {}


func _init() -> void:
	id = "arrive_at_camp"
	title = "Arrive at camp"
	chapter = "People"
	summary = "Vehicles drive in through the site gate with their cargo; the camp's crew unloads them."
	how = PackedStringArray(["Library → Structures → Site gate (optional: else the far end of a road)",
		"Deploy chip → Vehicles drive in from the gate",
		"Packing Lab → pick a vehicle's bay → Load into <vehicle>",
		"Back up slowly onto a trailer's coupler to hitch it; a fuel tank within 12 m refuels"])
	action = ""
	button = "Deploy chip → Vehicles drive in from the gate"
	world = "walton"
	budget_s = 70.0
	hour = 13.0
	blurb = ("Living vehicles arrive the way a real camp does: one by one through the site " +
		"gate, along the festival road, nose first into their spot. Whatever was loaded in " +
		"the cargo bay rides along, and once the vehicle is parked the camp's crew carries " +
		"the crates out of its door. After a pack-up they drive out again.")


func run(ctx: TourContext) -> void:
	var pps := ctx.klass("PlacedPropService")
	var vs := ctx.klass("VehicleSpec")
	var vp := ctx.klass("VehiclePresets")
	var vd := ctx.klass("VehicleDrive")
	if not ctx.require(pps != null and vs != null and vp != null and vd != null and ctx.loader != null,
			"the vehicle services and a terrain loader exist"):
		return
	_clock = ctx.save_clock()
	var bridge: Variant = ctx.population_bridge()
	if bridge == null or str(bridge.call("first_crewable_habitat")).is_empty():
		await ctx.open_festival()
		if ctx.main.has_method("close_settlement_view"):
			ctx.main.call("close_settlement_view")
	var park := ctx.ahead(16.0, 4.0)
	var gate_at := ctx.ahead(95.0)
	var gid := str(pps.call("place_prepped_at", ctx.main, "site_gate", {}, gate_at.x, gate_at.z, 0.0))
	var vid := str(pps.call("place_prepped_at", ctx.main, "vehiclelab_vehicle",
		{"record_extra": {"vehicle_spec": vs.call("to_json_safe", vp.call("builtin", "box_truck")),
			"collision_enabled": true}}, park.x, park.z, 0.0))
	_ids = [gid, vid]
	await ctx.frames(8)
	if not ctx.require(not vid.is_empty(), "a box truck is placed"):
		return
	var res: Dictionary = ctx.loader.call("deliver_kit_in_vehicle", "starter_camp", vid)
	_ids.append_array(res.get("crate_ids", []))
	ctx.require(not (res.get("crate_ids", []) as Array).is_empty(), "a kit is loaded in its bay")
	var now := float(ctx.main.call("get_absolute_hours"))
	ctx.loader.call("schedule_vehicle_arrivals", now + 1.0 / 60.0)
	var arr: Dictionary = ctx.prop_record(vid).get("arrival", {})
	if not ctx.require(not arr.is_empty(), "the truck is given an arrival through the gate"):
		return
	var t0 := float(arr["start_h"])
	var dur := float(vd.call("duration_h", arr))
	ctx.run_clock(0.0)
	ctx.caption("A camp's truck comes in through the site gate…", 3.0)
	var steps := 90
	for k in steps + 1:
		var t := t0 + dur * float(k) / float(steps)
		ctx.main.call("set_absolute_hours", t)
		var pose: Dictionary = vd.call("pose_at", arr, t)
		var p: Vector2 = pose["pos"]
		var yaw := float(pose["yaw"])
		var behind := p - Vector2(-sin(yaw), -cos(yaw)) * 16.0
		ctx.place_camera(Vector3(behind.x, ctx.ground_y(behind.x, behind.y) + 7.0, behind.y),
			Vector3(p.x, ctx.ground_y(p.x, p.y) + 1.5, p.y))
		await ctx.wait(0.08)
	ctx.caption("…parks in its spot, nose first", 2.5)
	ctx.main.call("set_absolute_hours", t0 + dur + 1.0 / 60.0)
	ctx.place_camera(park + Vector3(12.0, 6.0, 12.0), park + Vector3(0.0, 1.5, 0.0))
	await ctx.wait(1.5)
	await ctx.hero(true)
	ctx.caption("…and the camp's crew carries the crates out of its door", 3.5)
	ctx.run_clock(150.0)
	await ctx.wait(6.0)
	ctx.run_clock(0.0)


func teardown(ctx: TourContext) -> void:
	if ctx.loader != null:
		ctx.loader.call("clear_vehicle_arrivals")
		for pid in _ids:
			if not str(pid).is_empty():
				ctx.loader.call("delete_prop_by_id", str(pid))
	_ids = []
	ctx.release_camera()
	if not _clock.is_empty():
		ctx.restore_clock(_clock)
	_clock = {}
