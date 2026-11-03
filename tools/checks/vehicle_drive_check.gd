extends RefCounted

## Living vehicles on the road (sandbox, Phase 5):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/vehicle_drive_check.gd -Label vehicle_drive -Timeout 900
## A camper van parked beside a graph diesel store with a near-empty tank
## fills up when it is driven (the store's level drops by what it took); a
## travel trailer whose coupler stands just behind the van's hitch is hitched
## as the driver gets in (backing up to it); driven round a circle the trailer's
## coupler stays on the hitch and it swings in behind; driven 1 km in a straight
## line towing, the litres burned equal the energy model's (trailer included)
## within 2 % and exceed the solo figure; the dashboard
## shows litres and range; getting out leaves the trailer saved where it stands;
## the prop editor's unhitch clears both records. Everything it places is
## removed again.

var _fails: Array = []
var _dir := ""


func _ok(cond: bool, what: String) -> void:
	print("vehicledrive %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	_dir = "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(_dir)
	main.set("day_time", 13.0)
	main.set("time_scale", 0.0)
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	var player := main.get_node_or_null("Player") as CharacterBody3D
	_ok(loader != null and player != null, "a map with a player")
	if loader == null or player == null:
		return {"ok": false, "fails": _fails}
	var sgv: Node = PlacedPropService._system_graph_view(main)
	var model: GraphModel = sgv.get("model") if sgv != null else null
	var p0 := player.global_position
	# The van, heading north (yaw 0), its tank nearly dry.
	var van_spec := VehicleSpec.to_json_safe(VehiclePresets.builtin("van"))
	var vx := p0.x + 12.0
	var vz := p0.z
	var vid := PlacedPropService.place_prepped_at(main, VehicleBuilder.MODEL_ID,
		{"record_extra": {"vehicle_spec": van_spec, "vehicle_fuel_l": 4.0, "collision_enabled": true}}, vx, vz, 0.0)
	await _frames(tree, 10)
	_ok(not vid.is_empty(), "a van is placed")
	var vd := VehicleDesign.solve(VehiclePresets.builtin("van"))
	var fuel := str(vd["fuel"])
	# A diesel store 4 m to its right.
	var soi := main.get_node_or_null("/root/SoiService")
	var centre: Vector3 = soi.call("world_center") if soi != null and soi.has_method("world_center") else Vector3.ZERO
	var site := GraphSiteLayout.world_xz_to_site(Vector2(vx + 4.0, vz), centre)
	var tank_id := "cap_vd_fuel"
	if model != null:
		model.add_item({"id": tank_id, "type": "resource", "x": 0.0, "y": 0.0, "width": 90.0, "height": 100.0,
			"site_x_m": site.x, "site_z_m": site.y,
			"specs": {"name": "Diesel tote", "resource_kind": fuel, "capacity": "1000 L",
				"capacity_qty": 1000.0, "capacity_unit": "L", "level": 1.0}})
	# A travel trailer whose coupler stands 0.3 m behind the van's hitch.
	var tr_spec := VehicleSpec.to_json_safe(VehiclePresets.builtin("trailer"))
	var td := VehicleDesign.solve(VehiclePresets.builtin("trailer"))
	var hitch := VehicleTow.world_xz(vd["hitch"], Vector2(vx, vz), 0.0) + Vector2(0.0, 0.3)
	var pose := VehicleTow.trailer_pose(td, hitch, hitch + Vector2(0.0, VehicleTow.tongue_m(td)))
	var o: Vector2 = pose["origin"]
	var tid := PlacedPropService.place_prepped_at(main, VehicleBuilder.MODEL_ID,
		{"record_extra": {"vehicle_spec": tr_spec, "collision_enabled": true}}, o.x, o.y, rad_to_deg(float(pose["yaw"])))
	await _frames(tree, 10)
	_ok(not tid.is_empty(), "a travel trailer is placed behind it")
	var vprop := PlacedPropRuntime.find_by_prop_id(main, vid)
	var veh: Node = vprop.get_node_or_null("PlacedVehicle") if vprop != null else null
	_ok(veh != null, "the van is drivable")
	if veh == null:
		return _finish(main, loader, model, [vid, tid], tank_id)
	# Get in: it fills up from the tote and hitches the trailer it backed up to.
	player.call("request_mount", veh)
	await _frames(tree, 30)
	_ok(bool(player.get("is_riding")), "the driver is in")
	var fl: Vector2 = veh.call("get_fuel_litres")
	_ok(fl.x > fl.y - 0.6, "it filled up from the diesel tote (%.1f of %.0f L)" % [fl.x, fl.y])
	var lvl := float((model.get_item(tank_id).get("specs", {}) as Dictionary).get("level", 1.0)) if model != null else 1.0
	_ok(absf((1.0 - lvl) * 1000.0 - (fl.y - 4.0)) < 1.0, "the tote gave what the tank took (%.1f L)" % ((1.0 - lvl) * 1000.0))
	# The driver's seat sees out: while someone drives, the cab and shell
	# draw one-sided (VehicleBuilder.set_inside_view; the sightline itself is
	# pinned offline in vehiclelab_selftest._test_driver_view).
	if player.has_method("_apply_camera_mode"):
		player.call("_apply_camera_mode", false)
	await _frames(tree, 6)
	await _shot(main, "driver_view")
	_ok(_cab_cull(vprop) == BaseMaterial3D.CULL_BACK, "while driving, the cab draws one-sided so the driver sees out")
	var vrec := PlacedPropService.get_prop_record(main, vid)
	var trec := PlacedPropService.get_prop_record(main, tid)
	_ok(str(vrec.get("towing", "")) == tid and str(trec.get("hitched_to", "")) == vid,
		"backing onto the trailer hitched it")
	var ui := main.get_node_or_null("UILayer/EUCUI")
	if ui != null and ui.has_method("show_ui"):
		ui.call("show_ui", veh)
		await _frames(tree, 3)
		var wh := ui.get_node_or_null("Panel/MarginContainer/VBoxContainer/BatteryContainer/BatteryWh") as Label
		var rg := ui.get_node_or_null("Panel/MarginContainer/VBoxContainer/StatsContainer/RangeContainer/RangeValue") as Label
		# The fuel and range follow the one units setting (UnitsPref).
		var fu := " L" if UnitsPref.metric() else " gal"
		var du := " km" if UnitsPref.metric() else " mi"
		_ok(wh != null and wh.text.ends_with(fu) and rg != null and rg.text.ends_with(du),
			"the dashboard shows the tank and range in the player's units (%s · %s)" % [wh.text if wh else "", rg.text if rg else ""])
		UnitsPref.set_metric(not UnitsPref.metric())
		await _frames(tree, 3)
		var fu2 := " L" if UnitsPref.metric() else " gal"
		_ok(wh != null and wh.text.ends_with(fu2), "and switch with the setting (%s)" % (wh.text if wh else ""))
		UnitsPref.set_metric(not UnitsPref.metric())
	# Round a 14 m circle: the coupler rides on the hitch, the trailer swings in.
	var tprop := PlacedPropRuntime.find_by_prop_id(main, tid)
	var R := 14.0
	var c := Vector2(vx - R, vz)
	var worst := 0.0
	var max_art := 0.0
	var ang := 0.0
	while ang < PI * 1.2:
		var dt := tree.root.get_process_delta_time()
		dt = dt if dt > 0.0 else 1.0 / 60.0
		ang += 5.0 * dt / R
		var pos := c + Vector2(R * cos(ang), -R * sin(ang))
		_drive_to(main, player, pos, ang)
		await tree.process_frame
		if tprop != null and is_instance_valid(tprop) and ang > 0.2:
			var vyaw := ((vprop.get_node("ModelRoot")) as Node3D).rotation.y
			var tyaw := ((tprop.get_node("ModelRoot")) as Node3D).rotation.y
			var hw := VehicleTow.world_xz(vd["hitch"], Vector2(vprop.global_position.x, vprop.global_position.z), vyaw)
			var cw := VehicleTow.world_xz(td["coupler"], Vector2(tprop.global_position.x, tprop.global_position.z), tyaw)
			worst = maxf(worst, hw.distance_to(cw))
			max_art = maxf(max_art, absf(rad_to_deg(angle_difference(vyaw, tyaw))))
	_ok(worst < 0.15, "the coupler rides on the hitch all the way round (worst %.3f m)" % worst)
	_ok(max_art > 5.0 and max_art < VehicleTow.MAX_ARTICULATION_DEG + 0.5,
		"the trailer swings in behind the turn (up to %.1f°)" % max_art)
	await _shot(main, "towing")
	# 1 km straight at 10 m/s: litres burned == the energy model's — with the
	# trailer on the hitch (its rolling load and its drag in the wake).
	var used0 := float(veh.get("fuel_used_l"))
	var roll0 := float(veh.get("_roll_m"))
	var start := Vector2(vprop.global_position.x, vprop.global_position.z)
	var heading := ((vprop.get_node("ModelRoot")) as Node3D).rotation.y
	var fwd := Vector2(-sin(heading), -cos(heading))
	var s := 0.0
	while s < 1000.0:
		var dt2 := tree.root.get_process_delta_time()
		dt2 = dt2 if dt2 > 0.0 else 1.0 / 60.0
		s = minf(s + 10.0 * dt2, 1000.0)
		_drive_to(main, player, start + fwd * s, heading)
		await tree.process_frame
	await tree.process_frame
	var burned := float(veh.get("fuel_used_l")) - used0
	var want := float(VehicleDesign.energy_for_distance(vd, 1000.0, 10.0, td)["litres"])
	var solo := float(VehicleDesign.energy_for_distance(vd, 1000.0, 10.0)["litres"])
	_ok(absf(burned - want) <= want * 0.02,
		"1 km at 10 m/s towing burns the model's litres (%.3f vs %.3f L; %.3f solo)" % [burned, want, solo])
	_ok(want > solo * 1.1, "towing the trailer costs more fuel than running solo (%.3f vs %.3f L)" % [want, solo])
	var rolled := float(veh.get("_roll_m")) - roll0
	_ok(absf(rolled - 1000.0) < 5.0, "the wheels rolled the kilometre (%.1f m)" % rolled)
	# Out: the trailer stays saved where it stands.
	player.call("_dismount_vehicle")
	await _frames(tree, 8)
	var trec2 := PlacedPropService.get_prop_record(main, tid)
	var tp := tprop.global_position if tprop != null and is_instance_valid(tprop) else Vector3.ZERO
	_ok(Vector2(float(trec2.get("x", 0.0)), float(trec2.get("z", 0.0))).distance_to(Vector2(tp.x, tp.z)) < 0.2,
		"getting out saves the trailer where it stands")
	_ok(_cab_cull(PlacedPropRuntime.find_by_prop_id(main, vid)) == -1, "getting out puts the cab's shared material back")
	PlacedVehicle.unhitch_prop(main, vid)
	await _frames(tree, 3)
	_ok(str(PlacedPropService.get_prop_record(main, vid).get("towing", "")).is_empty()
		and str(PlacedPropService.get_prop_record(main, tid).get("hitched_to", "")).is_empty(), "unhitching clears both")
	var rc := SiteCost.running_for_record(PlacedPropService.get_prop_record(main, vid))
	_ok(not rc.is_empty(), "the van has a running cost (%s)" % SiteCost.format_usd(float(rc.get("usd", 0.0))))
	return _finish(main, loader, model, [vid, tid], tank_id)


func _drive_to(main: Node, player: CharacterBody3D, xz: Vector2, yaw: float) -> void:
	var gy := TerrainSurfaceQuery.ground_height_at(main, xz.x, xz.y)
	player.global_position = Vector3(xz.x, gy if not is_nan(gy) else player.global_position.y, xz.y)
	player.velocity = Vector3.ZERO
	player.rotation.y = yaw


func _finish(main: Node, loader: Node, model: GraphModel, pids: Array, tank_id: String) -> Dictionary:
	for pid in pids:
		if not str(pid).is_empty():
			loader.call("delete_prop_by_id", str(pid))
	if model != null and not model.get_item(tank_id).is_empty():
		model.remove_item(tank_id)
	print("vehicledrive: %d failure(s)" % _fails.size())
	return {"ok": _fails.is_empty(), "fails": _fails}


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


## The cab's first surface override cull mode (-1 = no override).
func _cab_cull(vprop: Node3D) -> int:
	if vprop == null or not is_instance_valid(vprop):
		return -2
	var root := vprop.get_node_or_null("ModelRoot")
	var cab: MeshInstance3D = null
	if root != null:
		for c in root.find_children("Cab", "MeshInstance3D", true, false):
			cab = c
			break
	if cab == null:
		return -2
	var m := cab.get_surface_override_material(0)
	return (m as BaseMaterial3D).cull_mode if m is BaseMaterial3D else -1


func _shot(main: Node, name: String) -> void:
	await RenderingServer.frame_post_draw
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [_dir, name])
