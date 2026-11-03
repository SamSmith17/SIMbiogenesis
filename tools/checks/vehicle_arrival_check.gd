extends RefCounted

## Living vehicles driving in through the site gate (sandbox, Phase 7):
##   tools\harness.ps1 -World walton -RunScript res://tools/checks/vehicle_arrival_check.gd -Label vehicle_arrival -Timeout 1200
## A site gate is placed 90 m out and a camper van parked in a camp. "Drive in
## from the gate" (TerrainLoader.schedule_vehicle_arrivals) gives the van an
## arrival a minute ahead. Before it: the van is not on site and its camp's
## people are away (the bridge does not step or draw them). Mid-drive: the
## van is on the road between the gate and its spot and cannot be got into.
## After: it stands in its spot and its camp is home. Scrubbing the clock back
## before the start sends it (and them) away again. Then (transport polish
## Phase 3) a travel trailer with a kit stowed in it is hitched behind the
## van: driving in and driving out, the trailer's coupler rides on the van's
## hitch and its crates ride in it. Everything placed is removed and the
## arrivals / departures forgotten.

var _fails: Array = []
var _dir := ""


func _ok(cond: bool, what: String) -> void:
	print("vehiclearrival %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


func _settle(tree: SceneTree) -> void:
	await tree.create_timer(1.2).timeout
	await _frames(tree, 4)


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	_dir = "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(_dir)
	var day0: float = floor(float(main.call("get_absolute_hours")) / 24.0) * 24.0
	main.call("set_absolute_hours", day0 + 11.0)
	main.set("time_scale", 1.0 / 36000.0)
	await _frames(tree, 10)
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	var player := main.get_node_or_null("Player") as CharacterBody3D
	var sgv := ServiceLocator.graph()
	_ok(loader != null and player != null and sgv != null, "a map with a player and a graph")
	if loader == null or player == null or sgv == null:
		return {"ok": false, "fails": _fails}
	var bridge: Variant = sgv.call("npc_population_bridge")
	if bridge == null or (bridge.call("crew_summary") as Array).is_empty():
		if main.has_method("open_festival_mode"):
			main.call("open_festival_mode")
			await _frames(tree, 120)
			if main.has_method("close_settlement_view"):
				main.call("close_settlement_view")
		bridge = sgv.call("npc_population_bridge")
	var crews: Array = bridge.call("crew_summary") if bridge != null else []
	_ok(not crews.is_empty(), "camps on the site (%d)" % crews.size())
	if crews.is_empty():
		return {"ok": false, "fails": _fails}
	loader.call("clear_vehicle_arrivals")
	# The van parks beside the first camp's home; the gate stands 90 m out.
	var camp: Dictionary = crews[0]
	var iid := str(camp["iid"])
	var home: Vector2 = camp["home"]
	var park := home + Vector2(9.0, 0.0)
	var vid := PlacedPropService.place_prepped_at(main, VehicleBuilder.MODEL_ID,
		{"record_extra": {"vehicle_spec": VehicleSpec.to_json_safe(VehiclePresets.builtin("van")),
			"collision_enabled": true}}, park.x, park.y, 0.0)
	var gate_xz := park + Vector2(0.0, 90.0)
	# Facing north (-Z), toward the camp: a vehicle passes through heading in.
	var gid := PlacedPropService.place_prepped_at(main, SiteGateBuilder.MODEL_ID, {}, gate_xz.x, gate_xz.y, 0.0)
	await _frames(tree, 12)
	_ok(not vid.is_empty() and not gid.is_empty(), "a van and a site gate are placed")
	var gate: Dictionary = loader.call("site_gate")
	_ok(bool(gate.get("placed", false)) and (gate["pos"] as Vector2).distance_to(gate_xz) < 0.1,
		"the placed gate is the way in")
	var now := float(main.call("get_absolute_hours"))
	var n := int(loader.call("schedule_vehicle_arrivals", now + 1.0 / 60.0))
	var vrec := PlacedPropService.get_prop_record(main, vid)
	var arr: Dictionary = vrec.get("arrival", {})
	_ok(n >= 1 and not arr.is_empty(), "\"drive in from the gate\" gives the van an arrival (%d vehicle(s))" % n)
	if arr.is_empty():
		return _finish(main, loader, [vid, gid])
	var start := float(arr["start_h"])
	var dur := VehicleDrive.duration_h(arr)
	var vprop := PlacedPropRuntime.find_by_prop_id(main, vid) as Node3D
	var veh: Node = vprop.get_node_or_null("PlacedVehicle") if vprop != null else null
	# Before it sets off.
	main.call("set_absolute_hours", start - 0.5 / 60.0)
	await _settle(tree)
	vprop = PlacedPropRuntime.find_by_prop_id(main, vid) as Node3D
	_ok(vprop != null and not vprop.visible, "before it sets off the van is not on site")
	_ok(bool(bridge.call("is_away", iid)), "and its camp's people are away")
	var away_cohort := not (bridge.call("light_cohorts") as Dictionary).has(iid)
	var away_dots := true
	for dd in bridge.call("agent_dots"):
		# People's ids are "<camp>_npc_<i>".
		if str((dd as Dictionary).get("id", "")).begins_with(iid + "_"):
			away_dots = false
	_ok(away_cohort and away_dots, "nobody of theirs is drawn")
	# Mid-drive.
	main.call("set_absolute_hours", start + dur * 0.5)
	await _settle(tree)
	vprop = PlacedPropRuntime.find_by_prop_id(main, vid) as Node3D
	var pos := Vector2(vprop.global_position.x, vprop.global_position.z) if vprop != null else Vector2.INF
	var want: Dictionary = VehicleDrive.pose_at(arr, float(main.call("get_absolute_hours")))
	_ok(vprop != null and vprop.visible and pos.distance_to(want["pos"]) < 1.5,
		"mid-drive the van is on the road where its arrival says (%.2f m off)" % pos.distance_to(want["pos"]))
	_ok(pos.distance_to(park) > 5.0 and pos.distance_to(gate_xz) < gate_xz.distance_to(park) + 20.0,
		"between the gate and its spot (%.0f m from it)" % pos.distance_to(park))
	veh = vprop.get_node_or_null("PlacedVehicle") if vprop != null else null
	_ok(veh != null and not bool(veh.call("can_mount")), "nobody can get into it while it drives in")
	_ok(bool(bridge.call("is_away", iid)), "its camp is still on the way")
	await _shot(main, player, vprop, "driving_in")
	# Parked.
	main.call("set_absolute_hours", start + dur + 1.0 / 60.0)
	await _settle(tree)
	vprop = PlacedPropRuntime.find_by_prop_id(main, vid) as Node3D
	pos = Vector2(vprop.global_position.x, vprop.global_position.z) if vprop != null else Vector2.INF
	_ok(vprop != null and vprop.visible and pos.distance_to(park) < 0.2, "then it stands in its spot (%.2f m)" % pos.distance_to(park))
	_ok(not bool(bridge.call("is_away", iid)), "and its camp is home")
	veh = vprop.get_node_or_null("PlacedVehicle") if vprop != null else null
	_ok(veh != null and bool(veh.call("can_mount")), "and it can be got into")
	await _shot(main, player, vprop, "parked")
	# Rewind before the start: away again.
	main.call("set_absolute_hours", start - 1.0 / 60.0)
	await _settle(tree)
	vprop = PlacedPropRuntime.find_by_prop_id(main, vid) as Node3D
	_ok(vprop != null and not vprop.visible and bool(bridge.call("is_away", iid)),
		"scrubbing back before the start sends it and its camp away again")
	# "Already here": the arrival forgotten, the van and the camp back at once.
	_ok(int(loader.call("clear_vehicle_arrivals")) >= 1, "\"already here\" forgets the arrival")
	await _settle(tree)
	vprop = PlacedPropRuntime.find_by_prop_id(main, vid) as Node3D
	_ok(vprop != null and vprop.visible and not bool(bridge.call("is_away", iid)),
		"and the van and its camp are simply here")
	var extra: Array = await _trailer_phase(main, loader, vid, park)
	var pids: Array = [vid, gid]
	pids.append_array(extra)
	return _finish(main, loader, pids)


## A trailer with cargo hitched behind the van: it follows on the way in and
## on the way out, its crates inside it.
func _trailer_phase(main: Node, loader: Node, vid: String, park: Vector2) -> Array:
	var tree := main.get_tree()
	var vd := VehicleDesign.solve(VehiclePresets.builtin("van"))
	var td := VehicleDesign.solve(VehiclePresets.builtin("trailer"))
	var hitch := VehicleTow.world_xz(vd.get("hitch", Vector3.ZERO), park, 0.0)
	var axle := hitch + Vector2(0.0, VehicleTow.tongue_m(td))
	var tp := VehicleTow.trailer_pose(td, hitch, axle)
	var to: Vector2 = tp["origin"]
	var tid := PlacedPropService.place_prepped_at(main, VehicleBuilder.MODEL_ID,
		{"record_extra": {"vehicle_spec": VehicleSpec.to_json_safe(VehiclePresets.builtin("trailer")),
			"collision_enabled": true}}, to.x, to.y, rad_to_deg(float(tp["yaw"])))
	await _frames(tree, 8)
	PlacedPropService.update_prop_record(main, vid, {"towing": tid}, false)
	PlacedPropService.update_prop_record(main, tid, {"hitched_to": vid}, false)
	var res: Dictionary = loader.call("deliver_kit_in_vehicle", "starter_camp", tid)
	await _frames(tree, 10)
	var stowed: Array = []
	for c in res.get("crate_ids", []):
		if str(PlacedPropService.get_prop_record(main, str(c)).get("stowed_in", "")) == tid:
			stowed.append(str(c))
	var out: Array = [tid]
	out.append_array(res.get("crate_ids", []))
	_ok(not tid.is_empty() and stowed.size() > 0, "a trailer hitched behind the van carries a kit (%d stowed)" % stowed.size())
	if stowed.is_empty():
		return out
	var now := float(main.call("get_absolute_hours"))
	loader.call("schedule_vehicle_arrivals", now + 1.0 / 60.0)
	var arr: Dictionary = PlacedPropService.get_prop_record(main, vid).get("arrival", {})
	_ok(not arr.is_empty() and not PlacedPropService.get_prop_record(main, tid).has("arrival"),
		"the van is given the arrival, the towed trailer follows it")
	# Not here yet: whatever the crew carried out goes back in the trailer.
	await tree.create_timer(2.5).timeout
	var back := 0
	for c in stowed:
		if str(PlacedPropService.get_prop_record(main, str(c)).get("stowed_in", "")) == tid:
			back += 1
	_ok(back == stowed.size(), "before the van arrives the trailer's crates are in it (%d of %d)" % [back, stowed.size()])
	if arr.is_empty():
		return out
	var t_mid := float(arr["start_h"]) + VehicleDrive.duration_h(arr) * 0.5
	main.call("set_absolute_hours", t_mid)
	await _settle(tree)
	_check_train(main, vid, tid, stowed[0], "driving in")
	main.call("set_absolute_hours", VehicleDrive.park_h(arr) + 2.0 / 60.0)
	await _settle(tree)
	loader.call("schedule_vehicle_departures", float(main.call("get_absolute_hours")) + 1.0 / 60.0,
		VehicleDrive.DEFAULT_SPACING_H, "vehiclearrival")
	var vrec := PlacedPropService.get_prop_record(main, vid)
	var leave := VehicleDrive.leave_h(vrec)
	var gone := VehicleDrive.gone_h(vrec)
	_ok(leave < INF, "the van is given a departure")
	main.call("set_absolute_hours", (leave + gone) * 0.5)
	await _settle(tree)
	_check_train(main, vid, tid, stowed[0], "driving out")
	main.call("set_absolute_hours", gone + 0.05)
	await _settle(tree)
	var tprop := PlacedPropRuntime.find_by_prop_id(main, tid) as Node3D
	_ok(tprop != null and not tprop.visible, "the trailer is gone with the van")
	main.call("set_absolute_hours", leave - 0.05)
	await _settle(tree)
	loader.call("clear_vehicle_departures", "vehiclearrival")
	return out


func _check_train(main: Node, vid: String, tid: String, crate: String, leg: String) -> void:
	var vprop := PlacedPropRuntime.find_by_prop_id(main, vid) as Node3D
	var tprop := PlacedPropRuntime.find_by_prop_id(main, tid) as Node3D
	var cnode := PlacedPropRuntime.find_by_prop_id(main, crate) as Node3D
	if vprop == null or tprop == null:
		_ok(false, "%s: the van and the trailer exist" % leg)
		return
	var vd := VehicleDesign.solve(VehiclePresets.builtin("van"))
	var td := VehicleDesign.solve(VehiclePresets.builtin("trailer"))
	var vyaw := (vprop.get_node("ModelRoot") as Node3D).rotation.y
	var tyaw := (tprop.get_node("ModelRoot") as Node3D).rotation.y
	var hitch := VehicleTow.world_xz(vd.get("hitch", Vector3.ZERO), Vector2(vprop.global_position.x, vprop.global_position.z), vyaw)
	var coupler := VehicleTow.world_xz(td.get("coupler", Vector3.ZERO), Vector2(tprop.global_position.x, tprop.global_position.z), tyaw)
	_ok(tprop.visible and hitch.distance_to(coupler) < 0.3,
		"%s: the trailer's coupler is on the van's hitch (%.2f m)" % [leg, hitch.distance_to(coupler)])
	var crec := PlacedPropService.get_prop_record(main, crate)
	var sl: Array = crec.get("stow_local", [0, 0, 0, 0])
	var want := VehicleTow.world_xz(Vector3(float(sl[0]), 0.0, float(sl[2])),
		Vector2(tprop.global_position.x, tprop.global_position.z), tyaw)
	var got := Vector2(cnode.global_position.x, cnode.global_position.z) if cnode != null else Vector2.INF
	_ok(got.distance_to(want) < 0.1, "%s: a crate rides at its place in the trailer (%.2f m)" % [leg, got.distance_to(want)])


func _shot(main: Node, player: CharacterBody3D, target: Node3D, name: String) -> void:
	if target == null:
		return
	var prev := main.get_viewport().get_camera_3d()
	var cam := Camera3D.new()
	main.add_child(cam)
	var t := target.global_position
	cam.global_position = t + Vector3(14.0, 7.0, 10.0)
	cam.look_at(t + Vector3(0.0, 1.2, 0.0), Vector3.UP)
	cam.current = true
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [_dir, name])
	cam.current = false
	cam.queue_free()
	if prev != null and is_instance_valid(prev):
		prev.current = true


func _finish(main: Node, loader: Node, pids: Array) -> Dictionary:
	loader.call("clear_vehicle_arrivals")
	loader.call("clear_vehicle_departures", "vehiclearrival")
	for pid in pids:
		if not str(pid).is_empty():
			loader.call("delete_prop_by_id", str(pid))
	print("vehiclearrival: %d failure(s)" % _fails.size())
	return {"ok": _fails.is_empty(), "fails": _fails}
