extends RefCounted

## Living vehicles as homes, on a real world (sandbox):
##   tools\harness.ps1 -World walton -RunScript res://tools/checks/vehicle_housing_probe.gd -Label vehicle_housing -Timeout 1200
## A. Every built-in preset placed in a row: drivable ones get a PlacedVehicle
##    on the design's own profile, the trailer does not; the record keeps its
##    spec; one prop carries a sleep space AND role spaces (kitchen / shower /
##    restroom) with anchors inside its footprint. Shots of the row, close-ups
##    and a cutaway.
## B. The bridge's seat spots for a vehicle's sleep space lie ON the beds
##    (elev = the mattress top, yaw along each bed) and its kitchen stands on
##    the vehicle's floor.
## C. Festival mode, three vehicles parked inside a painted camp: at night the
##    camp's sleepers who own vehicle beds lie in them — inside the footprint,
##    at bed height, along the bed — in whichever tier the camp runs.

var _fails: Array = []
var _dir := ""


func _ok(cond: bool, what: String) -> void:
	print("vehicle-housing %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var loader: Node = main.get_node_or_null("TerrainLoader")
	var gv := ServiceLocator.graph()
	_ok(loader != null and gv != null, "loader + graph view")
	if loader == null or gv == null:
		return {"ok": false, "fails": _fails}
	_dir = "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(_dir)
	main.set("time_scale", 0.0)
	main.set("day_time", 11.0)
	var reg: SpaceRegistry = loader.get("npc_spaces")
	var player := main.get_node_or_null("Player") as Node3D
	var base := Vector2(player.global_position.x, player.global_position.z) if player != null else Vector2.ZERO
	base += Vector2(25.0, 0.0)

	# -- A. every preset in a row ----------------------------------------------
	var placed := {}
	var x := 0.0
	for b in VehiclePresets.builtins():
		var id := str((b as Dictionary)["id"])
		var d := VehicleDesign.solve((b as Dictionary)["spec"])
		var r := PlacedPropService.place_model_at_xz(main, "vehiclelab_" + id, base.x + x, base.y,
			{"yaw": 0.0})
		_ok(bool(r.get("ok", false)), "%s placed" % id)
		placed[id] = str(r.get("prop_id", ""))
		x += float(d["width_m"]) + 5.0
	await _frames(tree, 6)
	for id in placed:
		var pid: String = placed[id]
		var prop := PlacedPropRuntime.find_by_prop_id(main, pid)
		_ok(prop != null, "%s prop node" % id)
		if prop == null:
			continue
		var v: Node = prop.get_node_or_null("PlacedVehicle")
		if id == "trailer":
			_ok(v == null, "a trailer cannot be driven")
		else:
			_ok(v != null and str(v.get("profile_id")) == PlacedVehicle.LIVING, "%s drivable on its design" % id)
		var rec := PlacedPropService.get_prop_record(main, pid)
		_ok(rec.get("vehicle_spec") is Dictionary and not (rec.get("vehicle_spec") as Dictionary).is_empty(),
			"%s record keeps its spec" % id)
	# Spaces on the shuttle bus.
	var sh_pid: String = placed.get("shuttle_bus", "")
	var roles := {}
	if reg != null:
		for sp in reg.spaces:
			var t: Dictionary = (sp as Dictionary).get("target", {})
			if str(t.get("prop_id", "")) == sh_pid:
				roles[str(t.get("role", ""))] = sp
	_ok(roles.has("") and str((roles[""] as Dictionary).get("space_type", "")) == "sleep", "shuttle: a sleep space")
	for role in ["kitchen", "shower", "restroom"]:
		_ok(roles.has(role), "shuttle: a %s space on the same prop" % role)
	var sh_rec := PlacedPropService.get_prop_record(main, sh_pid)
	var sh_d := VehicleDesign.solve(VehicleBuilder.spec_for_record(sh_rec))
	if roles.has("kitchen") and reg != null:
		var kp: Variant = reg.resolve_position(roles["kitchen"], main)
		var c := Vector2(float(sh_rec.get("x", 0.0)), float(sh_rec.get("z", 0.0)))
		_ok(kp is Vector2 and absf((kp as Vector2).x - c.x) < float(sh_d["width_m"]) * 0.5
			and absf((kp as Vector2).y - c.y) < float(sh_d["length_m"]) * 0.5,
			"the kitchen resolves inside the bus (%s)" % str(kp))

	# -- B. the bridge's spots ---------------------------------------------------
	var bridge: Object = gv.call("npc_population_bridge") if gv.has_method("npc_population_bridge") else null
	_ok(bridge != null, "population bridge")
	if bridge != null and roles.has(""):
		bridge.set("_seat_spots_at_ms", 0)
		bridge.call("_resolve_seat_spots", main, reg)
		var sid := str((roles[""] as Dictionary)["id"])
		var bed_top := float(((sh_d["beds"] as Array)[0] as Dictionary)["pos"].y)
		var s0: Dictionary = bridge.call("seat_spot", sid, 0)
		_ok(not s0.is_empty() and str(s0.get("kind", "")) == "lie", "sleep spot 0 is a bed")
		_ok(absf(float(s0.get("elev", 0.0)) - bed_top) < 0.05,
			"sleeper lies at the mattress (elev %.2f vs %.2f)" % [float(s0.get("elev", 0.0)), bed_top])
		_ok(_axis_err(float(s0.get("yaw", 0.0)), 0.0) < deg_to_rad(3.0), "along the bed (yaw %.2f)" % float(s0.get("yaw", 0.0)))
		var kid := str((roles["kitchen"] as Dictionary)["id"]) if roles.has("kitchen") else ""
		var k0: Dictionary = bridge.call("seat_spot", kid, 0) if not kid.is_empty() else {}
		var floor_y := float((sh_d["house"] as Dictionary)["floor_y"])
		_ok(not k0.is_empty() and absf(float(k0.get("elev", 0.0)) - floor_y) < 0.05,
			"the cook stands on the floor (elev %.2f vs %.2f)" % [float(k0.get("elev", 0.0)), floor_y])

	# -- Shots of the row --------------------------------------------------------
	var ui: Node = main.get_node_or_null("UILayer")
	if ui is CanvasLayer:
		(ui as CanvasLayer).visible = false
	var cam := Camera3D.new()
	cam.fov = 45.0
	cam.far = 3000.0
	main.add_child(cam)
	main.call("push_camera_claim", "vehicle_housing", {"camera_id": cam.get_instance_id(), "hide_player_mesh": true})
	var gy := float(TerrainSurfaceQuery.ground_height_at(main, base.x + x * 0.5, base.y))
	var mid := Vector3(base.x + x * 0.5, gy + 1.5, base.y)
	await _shot(cam, "00_row_front3q", mid + Vector3(-x * 0.35, 9.0, -26.0), mid)
	await _shot(cam, "01_row_rear3q", mid + Vector3(x * 0.3, 8.0, 24.0), mid)
	for id in placed:
		var rec := PlacedPropService.get_prop_record(main, placed[id])
		var d := VehicleDesign.solve(VehicleBuilder.spec_for_record(rec))
		var p := Vector3(float(rec.get("x", 0.0)), float(TerrainSurfaceQuery.ground_height_at(main,
			float(rec.get("x", 0.0)), float(rec.get("z", 0.0)))), float(rec.get("z", 0.0)))
		var L := float(d["length_m"])
		# From ahead and a little to its left: the neighbours stand 5 m to the sides.
		await _shot(cam, "10_%s" % id, p + Vector3(-2.2, 2.4, -L * 0.5 - 5.5), p + Vector3(0, 1.4, 0))
		await _shot(cam, "11_%s_rear" % id, p + Vector3(1.8, 2.6, L * 0.5 + 5.0), p + Vector3(0, 1.4, 0))
	# A cutaway of the shuttle: hide its shell, look down into the living box.
	var sh_prop := PlacedPropRuntime.find_by_prop_id(main, sh_pid)
	var shell: Node3D = sh_prop.find_child("Shell", true, false) as Node3D if sh_prop != null else null
	if shell != null:
		shell.visible = false
		var p2 := Vector3(float(sh_rec.get("x", 0.0)), float(TerrainSurfaceQuery.ground_height_at(main,
			float(sh_rec.get("x", 0.0)), float(sh_rec.get("z", 0.0)))), float(sh_rec.get("z", 0.0)))
		await _shot(cam, "20_shuttle_cutaway", p2 + Vector3(3.2, 5.0, 1.5), p2 + Vector3(0, 0.9, 0.5))
		shell.visible = true
	for id in placed:
		if id != "shuttle_bus" and id != "school_bus" and id != "van":
			loader.call("delete_prop_by_id", placed[id])
	await _frames(tree, 4)

	# -- C. festival night in vehicles -------------------------------------------
	await _festival_night(main, loader, gv, bridge, reg, placed, cam)
	for id in ["shuttle_bus", "school_bus", "van"]:
		loader.call("delete_prop_by_id", placed.get(id, ""))
	main.call("pop_camera_claim", "vehicle_housing")
	cam.queue_free()
	if ui is CanvasLayer:
		(ui as CanvasLayer).visible = true
	print("vehicle-housing: %d failure(s)" % _fails.size())
	return {"ok": _fails.is_empty(), "fails": _fails}


func _festival_night(main: Node, loader: Node, gv: Node, bridge: Object, reg: SpaceRegistry,
		placed: Dictionary, cam: Camera3D) -> void:
	var tree := main.get_tree()
	if not main.has_method("open_festival_mode"):
		_ok(false, "festival mode available")
		return
	# The sandbox world may scale its festival down (a couple per camp): run it
	# at its natural headcounts so a camp fills its vehicles (in memory only).
	var was_target := PopTestPrefs.festival_target_people()
	PopTestPrefs.set_festival_target_people(0)
	main.call("open_festival_mode")
	await _frames(tree, 30)
	var layer: Variant = loader.get("camp_areas")
	var camp := {}
	if layer != null:
		for a in layer.get("areas"):
			var ad: Dictionary = a
			if int(ad.get("headcount", 0)) >= 6 and (ad.get("polygon", PackedVector2Array()) as PackedVector2Array).size() >= 3:
				camp = ad
				break
	_ok(not camp.is_empty(), "a populated painted camp")
	if camp.is_empty():
		return
	var poly: PackedVector2Array = camp["polygon"]
	var c := SpaceRegistry.polygon_centroid(Array(poly))
	# Park the three vehicles inside it, side by side along its heading.
	var hd := deg_to_rad(float(camp.get("heading_deg", 0.0)))
	var ids := ["van", "shuttle_bus", "school_bus"]
	var k := 0
	# Side by side: each vehicle's long axis (its local Z) along the camp's
	# heading, the three spaced across it.
	var yaw := hd - PI * 0.5
	var side3 := Vector3(1, 0, 0).rotated(Vector3.UP, yaw)
	for id in ids:
		var spot := c + Vector2(side3.x, side3.z) * (float(k) - 1.0) * 4.0
		if not Geometry2D.is_point_in_polygon(spot, poly):
			spot = c + Vector2(side3.x, side3.z) * (float(k) - 1.0) * 2.8
		PlacedPropService.update_prop_record(main, placed[id], {"x": spot.x, "z": spot.y,
			"yaw": rad_to_deg(yaw)}, true)
		PlacedPropService.tag_vehicle_spaces(main, placed[id])
		k += 1
	await _frames(tree, 10)
	var shelters: Array = loader.call("camp_shelters_in_polygon", poly)
	var vbeds: Array = []
	for s in shelters:
		if (s as Dictionary).has("beds"):
			vbeds.append_array((s as Dictionary)["beds"])
	_ok(vbeds.size() >= 6, "the camp sees the vehicles' beds first (%d)" % vbeds.size())
	_ok(not shelters.is_empty() and (shelters[0] as Dictionary).has("beds"), "vehicle beds come before the tents")
	# Night: park the clock before the festival bedtime and let them go to bed.
	main.set("day_time", 2.0)
	main.set("time_scale", 0.12)
	var seen := 0
	var raised := 0
	var t := 0.0
	var homes := {}   # habitats whose people were seen asleep in the beds
	while t < 90.0:
		await tree.create_timer(0.5).timeout
		t += 0.5
		if float(main.get("day_time")) > 8.5:
			main.set("time_scale", 0.0)
		var dots: Array = bridge.call("agent_dots") if bridge != null else []
		var asleep_in := 0
		var at_height := 0
		for dt in dots:
			var dd: Dictionary = dt
			# Asleep AT a bed (still walking there = not yet within 0.4 m).
			if str(dd.get("activity", "")) != "sleep":
				continue
			var p: Vector2 = dd.get("pos", Vector2.INF)
			for b in vbeds:
				var bd: Dictionary = b
				if p.distance_to(bd["pos"]) < 0.4:
					asleep_in += 1
					var aid := str(dd.get("id", ""))
					homes[aid.substr(0, aid.rfind("_npc_"))] = true
					if absf(float(dd.get("elev", 0.0)) - float(bd["elev"])) < 0.15 \
							and _axis_err(float(dd.get("face_yaw", 0.0)), float(bd["yaw"])) < deg_to_rad(6.0):
						at_height += 1
					break
		if asleep_in > seen:
			seen = asleep_in
			raised = at_height
		if seen >= 6 and float(main.get("day_time")) > 4.0:
			break
	print("vehicle-housing: %d asleep in vehicle beds, %d at bed height and along the bed (of %d beds)" %
		[seen, raised, vbeds.size()])
	_print_near(bridge, c, vbeds)
	# Everyone of the camp that sleeps there (its habitat) should be in a
	# vehicle bed while there are beds for them.
	var camp_people := _habitat_people(bridge, homes)
	var want := mini(camp_people, vbeds.size())
	print("vehicle-housing: the camp's habitat has %d people, %d vehicle beds" % [camp_people, vbeds.size()])
	_ok(seen > 0 and seen >= want, "the camp's people sleep in the vehicle beds (%d of %d)" % [seen, want])
	_ok(seen > 0 and raised == seen, "every one of them lies ON the bed, along it (%d of %d)" % [raised, seen])
	main.set("time_scale", 0.0)
	# Daylight for the shots: still asleep (the festival sleeps till 09:30).
	main.set("day_time", 8.5)
	var vc := c
	var vgy := float(TerrainSurfaceQuery.ground_height_at(main, vc.x, vc.y))
	await _shot(cam, "30_camp_night_vehicles", Vector3(vc.x + 9.0, vgy + 7.0, vc.y + 9.0), Vector3(vc.x, vgy + 1.0, vc.y))
	for id in ids:
		var prop := PlacedPropRuntime.find_by_prop_id(main, placed[id])
		var sh: Node3D = prop.find_child("Shell", true, false) as Node3D if prop != null else null
		if sh != null:
			sh.visible = false
	await _shot(cam, "31_camp_night_cutaway", Vector3(vc.x + 5.0, vgy + 8.0, vc.y + 5.0), Vector3(vc.x, vgy + 1.0, vc.y))
	main.call("close_festival_mode")
	PopTestPrefs.set_festival_target_people(was_target)


## What the people round the vehicles are doing (a debugging line).
func _print_near(bridge: Object, c: Vector2, vbeds: Array) -> void:
	if bridge == null:
		return
	for dt in bridge.call("agent_dots"):
		var dd: Dictionary = dt
		var p: Vector2 = dd.get("pos", Vector2.INF)
		if p.distance_to(c) >= 25.0:
			continue
		var nb := INF
		for b in vbeds:
			nb = minf(nb, p.distance_to((b as Dictionary)["pos"]))
		print("vehicle-housing: near %s %s %s elev %.2f bed %.2f m away, tier %s" % [str(dd.get("id", "")),
			str(dd.get("activity", "")), str(dd.get("state", "")), float(dd.get("elev", 0.0)), nb,
			str(dd.get("tier", "full"))])


func _habitat_people(bridge: Object, homes: Dictionary) -> int:
	var n := 0
	if bridge == null:
		return 0
	for dt in bridge.call("agent_dots"):
		var aid := str((dt as Dictionary).get("id", ""))
		if homes.has(aid.substr(0, aid.rfind("_npc_"))):
			n += 1
	return n


## How far two lying directions are apart, ignoring head-to-foot (mod PI).
func _axis_err(a: float, b: float) -> float:
	var d := fposmod(a - b, PI)
	return minf(d, PI - d)


func _shot(cam: Camera3D, name: String, from: Vector3, at: Vector3) -> void:
	cam.global_position = from
	cam.look_at(at, Vector3.UP)
	for _i in 14:
		await cam.get_tree().process_frame
	await RenderingServer.frame_post_draw
	cam.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [_dir, name])
	print("vehicle-housing: shot %s" % name)
