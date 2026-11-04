extends RefCounted

## The site deployment schedule's ROUND TRIP on a real festival world (sandbox):
##   tools\harness.ps1 -World walton -RunScript res://tools/checks/deploy_roundtrip_check.gd -Label deploy_roundtrip -Timeout 2400
##
## The 2026-11-04 improvement pass, end to end:
## 1. a packed shiftpod beside a cargo container; festival mode for the crews;
##    a DEPLOY event builds it where it stands (home);
## 2. a PACK-UP event strips, packs, carries it to the container and stows it
##    (deploy_home = home recorded); a LEAVE event is added by the pack-up;
## 3. a stale `delivery` blob naming the stowed crate does NOT re-unload it to
##    a staging slot (the relocation bug);
## 4. a second DEPLOY event builds it AT HOME again, out of the container;
## 5. the clock scrubbed INTO the finished deploy's window replays the build
##    (construction state + a replay fraction on the site), past the window the
##    finished state is back, before the event the EXACT before-state is back
##    (packed, stowed in the container, deploy_home kept);
## 6. a stale build_state with no job behind it is counted stuck and healed by
##    the inventory;
## 7. an ARRIVE event writes a parked van's arrival from its hour and puts the
##    vehicle-less camps away until then; removing it brings everyone back;
## 8. "Set the gate where I stand" places / moves the site gate.
## Writes only the sandbox.

var _fails: Array = []
const SHOT_DIR := "user://screenshots/deploy_roundtrip"


func _ok(cond: bool, what: String) -> void:
	print("deploy-roundtrip %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func _shot(main: Node, name: String) -> void:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := main.get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
	img.save_png("%s/%s.png" % [SHOT_DIR, name])
	print("deploy-roundtrip shot: %s" % name)


func _until(tree: SceneTree, secs: float, pred: Callable) -> bool:
	var t := 0.0
	while t < secs:
		if bool(pred.call()):
			return true
		await tree.create_timer(0.25).timeout
		t += 0.25
	return bool(pred.call())


func _now(main: Node) -> float:
	return float(main.call("get_absolute_hours"))


func _rec(main: Node, pid: String) -> Dictionary:
	return PlacedPropService.get_prop_record(main, pid)


func _xz(rec: Dictionary) -> Vector2:
	return Vector2(float(rec.get("x", 0.0)), float(rec.get("z", 0.0)))


func _camps_built(loader: Node) -> int:
	var built := 0
	var layer: Variant = loader.get("camp_areas")
	if layer == null:
		return 0
	for a in layer.areas:
		if int(loader.call("camp_area_structure_count", str((a as Dictionary)["id"]))) <= 0:
			continue
		if bool((a as Dictionary).get("built", true)):
			built += 1
	return built


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	await _settle(tree, 20)
	var sgv := ServiceLocator.graph()
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	_ok(sgv != null and loader != null, "graph view + terrain loader are up")
	if sgv == null or loader == null:
		return {"ok": false}
	var sd: SiteDeployDirector = sgv.call("site_deploy")
	sd.clear()
	loader.call("clear_vehicle_arrivals")
	loader.call("clear_vehicle_departures")
	main.set("time_scale", 0.001)
	var day0: float = floor(_now(main) / 24.0) * 24.0
	main.call("set_absolute_hours", day0 + 10.0)
	await _settle(tree, 5)

	# --- 1. the kit, the container, the people ----------------------------
	var player := main.find_child("Player", true, false) as Node3D
	var px := player.global_position.x if player != null else 0.0
	var pz := player.global_position.z if player != null else 0.0
	var home := Vector2(px + 8.0, pz + 6.0)
	var r: Dictionary = PlacedPropService.place_model_at_xz(main, "shiftpod", home.x, home.y, {"packed": true, "yaw": 37.0})
	var pod := str(r.get("prop_id", ""))
	_ok(not pod.is_empty(), "a packed shiftpod stands at its home (%.1f, %.1f)" % [home.x, home.y])
	var cont: Dictionary = PlacedPropService.place_model_at_xz(main, "cargo_container", px - 14.0, pz + 6.0, {"yaw": 0.0})
	var cid := str(cont.get("prop_id", ""))
	_ok(not cid.is_empty(), "a cargo container stands in reach")
	# A second kit for the stuck-build test, left alone by the events (hidden
	# from the inventory until step 6 by a non-schedule build_state preview).
	var r2: Dictionary = PlacedPropService.place_model_at_xz(main, "ez_up", px + 8.0, pz - 8.0,
		{"packed": true, "build_state": {"phase": "", "ghost": 0.2, "preview": true}})
	var ez := str(r2.get("prop_id", ""))
	await _settle(tree, 5)
	main.call("open_festival_mode")
	for _i in 900:
		await tree.process_frame
		if bool(main.call("festival_mode_active")):
			break
	_ok(bool(main.call("festival_mode_active")), "festival mode opened")
	await _settle(tree, 30)
	var bridge: Variant = sgv.call("npc_population_bridge")
	var crews: Array = bridge.call("crew_summary")
	_ok(not crews.is_empty(), "the bridge sees camps as crews (%d)" % crews.size())
	var camps_total := 0
	var layer: Variant = loader.get("camp_areas")
	for a in layer.areas:
		if int(loader.call("camp_area_structure_count", str((a as Dictionary)["id"]))) > 0:
			camps_total += 1
	_ok(_camps_built(loader) == camps_total and camps_total > 0, "every painted camp stands (%d)" % camps_total)

	# --- the first deploy: the pod goes up where it stands -----------------
	var inv0: Array = sd.inventory(SiteDeploySchedule.ACTION_DEPLOY)
	_ok(inv0.size() == 1 and str((inv0[0] as Dictionary).get("id", "")) == pod,
		"the deploy inventory is the pod alone (%d)" % inv0.size())
	var at1 := _now(main) + 0.05
	var ev1: String = sd.add_event(SiteDeploySchedule.ACTION_DEPLOY, at1)
	main.set("time_scale", 0.2)
	var fired1 := await _until(tree, 30.0, func() -> bool: return sd.is_fired(ev1))
	_ok(fired1, "the first deploy fired")
	var done1 := await _until(tree, 400.0, func() -> bool: return not bool(sd.status().get("active", false)))
	_ok(done1, "the first deploy finished: %s" % str(sd.status().get("line", "")))
	await tree.create_timer(3.0).timeout
	await _settle(tree, 10)
	var rec1 := _rec(main, pod)
	_ok(not bool(rec1.get("packed", false)), "the pod stands")
	_ok(_xz(rec1).distance_to(home) < 0.5, "built where it stood (%.2f m off)" % _xz(rec1).distance_to(home))
	_ok(absf(fposmod(float(rec1.get("yaw", 0.0)) - 37.0 + 180.0, 360.0) - 180.0) < 1.0, "facing as placed (yaw %.1f)" % float(rec1.get("yaw", 0.0)))
	# The `after` snapshot settles once the deferred unpack has landed.
	var settled := await _until(tree, 20.0, func() -> bool:
		return (SiteDeploySchedule.fired_info(sd.record(), ev1).get("after", {}) as Dictionary).has(pod))
	_ok(settled, "the after snapshot settled")
	var info1 := SiteDeploySchedule.fired_info(sd.record(), ev1)
	_ok(info1.has("done_h") and (info1.get("after", {}) as Dictionary).has(pod) and (info1.get("before", {}) as Dictionary).has(pod),
		"the stamp carries before / after snapshots and the finish hour")
	_ok(bool(((info1.get("before", {}) as Dictionary).get(pod, {}) as Dictionary).get("packed", false))
		and not ((info1.get("after", {}) as Dictionary).get(pod, {}) as Dictionary).get("packed", false),
		"before = packed, after = standing")
	await _shot(main, "01_deployed_at_home")

	# --- 2. the pack-up: into the container, home remembered ---------------
	var at2 := _now(main) + 0.05
	var ev2: String = sd.add_event(SiteDeploySchedule.ACTION_PACKUP, at2)
	var fired2 := await _until(tree, 30.0, func() -> bool: return sd.is_fired(ev2))
	_ok(fired2, "the pack-up fired")
	var done2 := await _until(tree, 900.0, func() -> bool: return not bool(sd.status().get("active", false)))
	_ok(done2, "the pack-up finished: %s" % str(sd.status().get("line", "")))
	await tree.create_timer(3.0).timeout
	await _settle(tree, 10)
	var rec2 := _rec(main, pod)
	_ok(bool(rec2.get("packed", false)), "the pod is packed")
	_ok(str(rec2.get("stowed_in", "")) == cid, "and stowed in the container (in %s)" % str(rec2.get("stowed_in", "")))
	var dh: Variant = rec2.get("deploy_home")
	_ok(dh is Dictionary and Vector2(float((dh as Dictionary).get("x", 0.0)), float((dh as Dictionary).get("z", 0.0))).distance_to(home) < 0.5,
		"its home is remembered on the record")
	_ok(_camps_built(loader) == 0, "every camp struck by the crew")
	var leave_ev: Dictionary = sd.event_of(SiteDeploySchedule.ACTION_LEAVE)
	_ok(not leave_ev.is_empty() and float(leave_ev.get("at_h", 0.0)) > at2, "the pack-up added a LEAVE event to the timeline")
	var info2 := SiteDeploySchedule.fired_info(sd.record(), ev2)
	_ok(str(info2.get("auto_leave", "")) == str(leave_ev.get("id", "")), "and the stamp knows it added it")
	await _shot(main, "02_packed_into_container")

	# --- 3. a stale delivery blob must not re-unload the schedule's kit ----
	PlacedPropService.update_prop_record(main, cid, {"delivery": {"scenario_id": "fake", "crate_ids": [pod],
		"unload_pending": true, "unload_project": ""}}, false)
	await tree.create_timer(3.0).timeout
	var dl: Variant = _rec(main, cid).get("delivery")
	var dl_proj := str((dl as Dictionary).get("unload_project", "")) if dl is Dictionary else ""
	_ok(dl_proj.is_empty() and str(_rec(main, pod).get("stowed_in", "")) == cid,
		"a delivery naming the stowed kit queues no unload for it (it is the schedule's)")
	PlacedPropService.update_prop_record(main, cid, {"delivery": null}, false)

	# --- 4. the second deploy: back out of the container, built AT HOME ----
	main.set("time_scale", 0.001)
	# The LEAVE is in the past now; take it off so the camps are home.
	sd.remove_event(str(leave_ev.get("id", "")))
	var at3 := _now(main) + 0.05
	var ev3: String = sd.add_event(SiteDeploySchedule.ACTION_DEPLOY, at3)
	main.set("time_scale", 0.2)
	var fired3 := await _until(tree, 30.0, func() -> bool: return sd.is_fired(ev3))
	_ok(fired3, "the second deploy fired")
	var done3 := await _until(tree, 900.0, func() -> bool: return not bool(sd.status().get("active", false)))
	_ok(done3, "the second deploy finished: %s" % str(sd.status().get("line", "")))
	await tree.create_timer(3.0).timeout
	await _settle(tree, 10)
	var rec3 := _rec(main, pod)
	_ok(not bool(rec3.get("packed", false)) and str(rec3.get("stowed_in", "")).is_empty(), "the pod stands, out of the container")
	_ok(_xz(rec3).distance_to(home) < 0.5, "REBUILT AT ITS HOME (%.2f m off)" % _xz(rec3).distance_to(home))
	_ok(absf(fposmod(float(rec3.get("yaw", 0.0)) - 37.0 + 180.0, 360.0) - 180.0) < 1.0, "facing as it was (yaw %.1f)" % float(rec3.get("yaw", 0.0)))
	_ok(not (rec3.get("deploy_home") is Dictionary), "the home is forgotten once it is back")
	_ok(_camps_built(loader) == camps_total, "every camp pitched again")
	await _shot(main, "03_redeployed_at_home")

	# --- 5. scrub: replay inside the window, after, before ------------------
	main.set("time_scale", 0.001)
	var info3 := SiteDeploySchedule.fired_info(sd.record(), ev3)
	var done_h3 := float(info3.get("done_h", at3))
	_ok(done_h3 > at3, "the deploy's window is [%.3f, %.3f]" % [at3, done_h3])
	var mid := (at3 + done_h3) * 0.5
	main.call("set_absolute_hours", mid)
	var replaying := await _until(tree, 20.0, func() -> bool: return bool(sd.status().get("replaying", false)))
	_ok(replaying, "scrubbed into the window: the director replays (%s)" % str(sd.status().get("line", "")))
	await tree.create_timer(1.5).timeout
	await _settle(tree, 5)
	var rec_mid := _rec(main, pod)
	var run_mid: Variant = rec_mid.get(PalletRackBuildSite.RECORD_KEY)
	_ok(rec_mid.get("build_state") is Dictionary and run_mid is Dictionary and (run_mid as Dictionary).has("replay_frac"),
		"the pod is under construction with a replay fraction (%s)" % str((run_mid as Dictionary).get("replay_frac", "?") if run_mid is Dictionary else "no run"))
	_ok(bool(rec_mid.get("packed", false)) and _xz(rec_mid).distance_to(home) < 0.5,
		"the replayed build is at the home, from the crate")
	var site_mid := PalletRackBuildSite.site_for(main, pod)
	_ok(site_mid != null and site_mid.owns_visuals(), "a crew site draws the replay")
	var camps_mid := _camps_built(loader)
	print("deploy-roundtrip: camps standing mid-replay = %d of %d" % [camps_mid, camps_total])
	await _shot(main, "04_replay_mid_build")
	# Past the window: the finished state is back.
	main.call("set_absolute_hours", done_h3 + 0.02)
	var exited := await _until(tree, 20.0, func() -> bool: return not bool(sd.status().get("replaying", false)))
	_ok(exited, "scrubbed past the window: the replay ends")
	await tree.create_timer(3.0).timeout
	await _settle(tree, 10)
	var rec_after := _rec(main, pod)
	_ok(not bool(rec_after.get("packed", false)) and not (rec_after.get("build_state") is Dictionary)
		and _xz(rec_after).distance_to(home) < 0.5, "the finished pod stands at home again")
	_ok(_camps_built(loader) == camps_total, "the camps stand again")
	# Before the event: the EXACT before-state.
	main.call("set_absolute_hours", at3 - 0.5)
	var undone := await _until(tree, 20.0, func() -> bool: return not sd.is_fired(ev3))
	_ok(undone, "scrubbed back past the event: the stamp is cleared")
	await tree.create_timer(4.0).timeout
	await _settle(tree, 10)
	var rec_before := _rec(main, pod)
	_ok(bool(rec_before.get("packed", false)), "the pod is a crate again")
	_ok(str(rec_before.get("stowed_in", "")) == cid, "stowed back in the container (exact undo)")
	var dh2: Variant = rec_before.get("deploy_home")
	_ok(dh2 is Dictionary and Vector2(float((dh2 as Dictionary).get("x", 0.0)), float((dh2 as Dictionary).get("z", 0.0))).distance_to(home) < 0.5,
		"its home is remembered again")
	_ok(_camps_built(loader) == 0, "the camps are struck again")
	_ok(not (rec_before.get("build_state") is Dictionary), "no construction state left on it")
	await _shot(main, "05_undone_exactly")
	# Leave the site deployed for the rest: no crew, instantly.
	sd.clear()
	await _settle(tree, 5)
	sd.apply_instant(SiteDeploySchedule.ACTION_DEPLOY)
	await tree.create_timer(3.0).timeout
	await _settle(tree, 10)
	_ok(_xz(_rec(main, pod)).distance_to(home) < 0.5 and not bool(_rec(main, pod).get("packed", false)),
		"the instant deploy also carries the crate home first")

	# --- 6. a stuck build is healed ----------------------------------------
	PlacedPropService.update_prop_record(main, ez, {"build_state": {"phase": "", "ghost": 0.14},
		PalletRackBuildSite.RECORD_KEY: {"mode": "labour", "action": "deploy", "iid": "nobody", "project_id": "gone", "crew_n": 4}}, true)
	await _settle(tree, 5)
	_ok(sd.stuck_count() == 1, "a ghost with no job behind it counts as stuck (%d)" % sd.stuck_count())
	var inv_h: Array = sd.inventory(SiteDeploySchedule.ACTION_DEPLOY)
	var ez_in := false
	for it in inv_h:
		if str((it as Dictionary).get("id", "")) == ez:
			ez_in = true
	_ok(ez_in, "the inventory heals it and takes it")
	var ez_rec := _rec(main, ez)
	_ok(not (ez_rec.get("build_state") is Dictionary) and not (ez_rec.get(PalletRackBuildSite.RECORD_KEY) is Dictionary)
		and bool(ez_rec.get("packed", false)), "the construction state is gone, the crate stays a crate")
	_ok(sd.stuck_count() == 0, "nothing stuck afterwards")

	# --- 7. ARRIVE / LEAVE events drive the vehicles and the people --------
	var spec := VehicleSpec.to_json_safe(VehiclePresets.builtin("van"))
	var vid := PlacedPropService.place_prepped_at(main, VehicleBuilder.MODEL_ID,
		{"record_extra": {"vehicle_spec": spec, "collision_enabled": true}}, px + 18.0, pz + 2.0, 0.0)
	await _settle(tree, 10)
	_ok(not vid.is_empty(), "a camper van is parked")
	var now7 := _now(main)
	var arr_id: String = sd.add_event(SiteDeploySchedule.ACTION_ARRIVE, now7 + 1.0)
	await _settle(tree, 5)
	var vrec := _rec(main, vid)
	var arr: Variant = vrec.get("arrival")
	_ok(arr is Dictionary and absf(float((arr as Dictionary).get("start_h", 0.0)) - (now7 + 1.0)) < 1e-6,
		"the ARRIVE event wrote the van's arrival at its hour")
	_ok(not bool(sd.people_present_at(now7)) and bool(sd.people_present_at(now7 + 2.0)), "people are away before it, here after")
	var away := await _until(tree, 10.0, func() -> bool: return not (bridge.call("away_camps") as Dictionary).is_empty())
	_ok(away, "the camps with no vehicle are away until the arrive (%d away)" % (bridge.call("away_camps") as Dictionary).size())
	_ok(sd.add_event(SiteDeploySchedule.ACTION_ARRIVE, now7 + 1.5) == arr_id
		and absf(float(sd.event_of(SiteDeploySchedule.ACTION_ARRIVE).get("at_h", 0.0)) - (now7 + 1.5)) < 1e-6,
		"a second ARRIVE retimes the first")
	await _settle(tree, 5)
	_ok(absf(float((_rec(main, vid).get("arrival", {}) as Dictionary).get("start_h", 0.0)) - (now7 + 1.5)) < 1e-6,
		"and the van's arrival follows")
	sd.remove_event(arr_id)
	await _settle(tree, 5)
	_ok(not (_rec(main, vid).get("arrival") is Dictionary), "removing the event clears the arrival")
	var home_again := await _until(tree, 10.0, func() -> bool: return (bridge.call("away_camps") as Dictionary).is_empty())
	_ok(home_again, "everyone is here again")
	var lv_id: String = sd.add_event(SiteDeploySchedule.ACTION_LEAVE, now7 + 3.0)
	await _settle(tree, 5)
	var dep: Variant = _rec(main, vid).get("departure")
	_ok(dep is Dictionary and absf(float((dep as Dictionary).get("start_h", 0.0)) - (now7 + 3.0)) < 1e-6
		and str((dep as Dictionary).get("by", "")) == "schedule", "the LEAVE event wrote the van's departure")
	sd.remove_event(lv_id)
	await _settle(tree, 5)
	_ok(not (_rec(main, vid).get("departure") is Dictionary), "removing it clears the departure")

	# --- 8. the gate where I stand -----------------------------------------
	var g0: Dictionary = loader.call("site_gate")
	var pose: Dictionary = SiteGateBuilder.pose_from_player(main)
	var gid := str(loader.call("set_site_gate_here", float(pose["x"]), float(pose["z"]), float(pose["yaw_deg"])))
	await _settle(tree, 5)
	var g1: Dictionary = loader.call("site_gate")
	_ok(not gid.is_empty() and bool(g1.get("placed", false)) and (g1["pos"] as Vector2).distance_to(Vector2(float(pose["x"]), float(pose["z"]))) < 0.1,
		"the gate is placed where I stand (was placed: %s)" % str(g0.get("placed", false)))
	var gid2 := str(loader.call("set_site_gate_here", float(pose["x"]) + 5.0, float(pose["z"]), 90.0))
	await _settle(tree, 5)
	var g2: Dictionary = loader.call("site_gate")
	_ok(gid2 == gid and absf(float(g2.get("yaw_deg", 0.0)) - 90.0) < 0.1 and (g2["pos"] as Vector2).x > float(pose["x"]) + 4.9,
		"setting it again MOVES the one gate")
	await _shot(main, "06_gate_set")
	for pid in [vid, gid, ez, pod, cid]:
		if not str(pid).is_empty():
			loader.call("delete_prop_by_id", str(pid))
	sd.clear()
	main.set("time_scale", 0.001)
	return {"ok": _fails.is_empty(), "failures": _fails}
