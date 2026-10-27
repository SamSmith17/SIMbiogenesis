extends RefCounted
## The site deployment schedule end to end on a REAL festival world (sandbox):
##   tools\harness.ps1 -World walton -RunScript res://tools/checks/site_deploy_probe.gd -Label site_deploy -Timeout 1500
##
## 1. festival mode populates the camps; four packed kits are placed by the
##    player (shiftpod, EZ-up, pallet rack, a dome) beside a cargo container;
## 2. "Pack everything now" (no crew) strikes every painted camp — no beds
##    left in them — and packs every packable prop;
## 3. a DEPLOY event at the playhead + 3 min: when the clock crosses it the
##    director pins crews as ALL HANDS, projects land on their boards, people
##    are seen DOING them, camps reveal household by household, and the run
##    ends with the kits unpacked and the camps standing;
## 4. the clock scrubbed back past the event puts it all back at once and
##    clears the stamp;
## 5. a PACK-UP event does the reverse with the crew — the packed crates are
##    carried to the container's door — and the schedule file round-trips
##    through the director;
## 6. the prop editor's path: one crate handed to the crew on its own
##    (queue_item), built with the generic staging site (parts laid out,
##    then seated), a dome staged by its own builder.
## Shots under screenshots\site_deploy\. Writes only the sandbox.

var _fails: Array = []
const SHOT_DIR := "user://screenshots/site_deploy"


func _ok(cond: bool, what: String) -> void:
	print("site-deploy %s: %s" % ["PASS" if cond else "FAIL", what])
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
	print("site-deploy shot: %s" % name)


func _now(main: Node) -> float:
	return float(main.call("get_absolute_hours"))


func _packed(main: Node, pid: String) -> bool:
	return bool(PlacedPropService.get_prop_record(main, pid).get("packed", false))


func _camps_built(loader: Node) -> Dictionary:
	var built := 0
	var total := 0
	var layer: Variant = loader.get("camp_areas")
	if layer == null:
		return {"built": 0, "total": 0}
	for a in layer.areas:
		if int(loader.call("camp_area_structure_count", str((a as Dictionary)["id"]))) <= 0:
			continue
		total += 1
		if bool((a as Dictionary).get("built", true)):
			built += 1
	return {"built": built, "total": total}


## People DOING a site deploy / pack-up chore right now, over every board.
func _working(bridge: Variant) -> int:
	var n := 0
	for iid in bridge.call("habitat_ids"):
		var board: Variant = bridge.call("chore_board_for", str(iid))
		if board == null:
			continue
		for c in board.chores:
			var chore: Dictionary = c
			var op := str((chore.get("effect", {}) as Dictionary).get("op", ""))
			if op in ["unpack_prop", "pack_prop", "set_camp_built", "set_build_phase", "seed_graph"] \
					or str(chore.get("label", "")).begins_with("Raise") or str(chore.get("label", "")).begins_with("Lay out"):
				n += (chore.get("workers", []) as Array).size()
	return n


## Wait (real seconds) until `pred` holds; returns true if it did.
func _until(tree: SceneTree, secs: float, pred: Callable) -> bool:
	var t := 0.0
	while t < secs:
		if bool(pred.call()):
			return true
		await tree.create_timer(0.25).timeout
		t += 0.25
	return bool(pred.call())


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	await _settle(tree, 20)
	var sgv := ServiceLocator.graph()
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	_ok(sgv != null and loader != null, "graph view + terrain loader are up")
	if sgv == null or loader == null:
		return {"ok": false}
	var sd: SiteDeployDirector = sgv.call("site_deploy")
	_ok(sd != null, "the director exists")
	sd.clear()
	# Daytime, so the crews are up; a slow clock while things are set up.
	main.set("time_scale", 0.001)
	var day0: float = floor(_now(main) / 24.0) * 24.0
	main.call("set_absolute_hours", day0 + 10.0)
	await _settle(tree, 5)

	# --- kits the player placed, packed ----------------------------------
	var player := main.find_child("Player", true, false) as Node3D
	var px := player.global_position.x if player != null else 0.0
	var pz := player.global_position.z if player != null else 0.0
	var kits := {}
	var k := 0
	for mid in ["shiftpod", "ez_up", PalletRackBuilder.MODEL_ID, DomeLabBuilder.MODEL_ID]:
		var r: Dictionary = PlacedPropService.place_model_at_xz(main, mid, px + 6.0 + 7.0 * k, pz + 6.0, {"packed": true})
		if bool(r.get("ok", false)):
			kits[mid] = str(r.get("prop_id", ""))
		k += 1
	_ok(kits.size() == 4, "four packed kits placed (%s)" % str(kits.keys()))
	# A container in reach: a pack-up carries the crates to its door.
	var cont: Dictionary = PlacedPropService.place_model_at_xz(main, "cargo_container", px - 14.0, pz + 6.0, {"yaw": 0.0})
	_ok(bool(cont.get("ok", false)), "a cargo container stands in reach")
	var door := Vector2(px - 14.0, pz + 6.0 + 5.0)
	await _settle(tree, 5)

	# --- festival mode: the people ---------------------------------------
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
	var cb0 := _camps_built(loader)
	_ok(int(cb0["total"]) > 0 and int(cb0["built"]) == int(cb0["total"]),
		"every painted camp stands before the test (%d)" % int(cb0["total"]))
	var layer: Variant = loader.get("camp_areas")
	var camp0 := ""
	for a in layer.areas:
		if int(loader.call("camp_area_structure_count", str((a as Dictionary)["id"]))) > 0:
			camp0 = str((a as Dictionary)["id"])
			break
	var poly0: PackedVector2Array = layer.get_area(camp0).get("polygon", PackedVector2Array())
	var beds0: int = (loader.call("camp_shelters_in_polygon", poly0) as Array).size()

	# --- 2. pack everything now, no crew ---------------------------------
	var inv_p: Array = sd.inventory(SiteDeploySchedule.ACTION_PACKUP)
	print("site-deploy: pack-up inventory %d items" % inv_p.size())
	var n_inst: int = sd.apply_instant(SiteDeploySchedule.ACTION_PACKUP)
	_ok(n_inst == inv_p.size() and n_inst >= int(cb0["total"]), "instant pack-up took every item (%d)" % n_inst)
	await tree.create_timer(4.0).timeout   # linkage fold sweeps are 3 s
	await _settle(tree, 10)
	var cb1 := _camps_built(loader)
	_ok(int(cb1["built"]) == 0, "every camp struck (%d of %d standing)" % [int(cb1["built"]), int(cb1["total"])])
	_ok((loader.call("camp_shelters_in_polygon", poly0) as Array).is_empty() and beds0 > 0,
		"a struck camp offers no beds (had %d)" % beds0)
	_ok(bool(loader.call("camp_area_structure_count", camp0) > 0), "a struck camp still knows its structure count")
	var left_standing := sd.inventory(SiteDeploySchedule.ACTION_PACKUP).size()
	_ok(left_standing == 0, "nothing packable left standing (%d)" % left_standing)
	await _shot(main, "00_packed")

	# --- 3. a deploy event the clock crosses -----------------------------
	var at := _now(main) + 0.05
	var ev_id: String = sd.add_event(SiteDeploySchedule.ACTION_DEPLOY, at)
	_ok(not ev_id.is_empty() and sd.events().size() == 1, "deploy event scheduled at +3 min")
	_ok(FileAccess.file_exists(str(loader.call("deploy_schedule_path"))), "the schedule file exists")
	main.set("time_scale", 0.2)   # 720x
	var fired := await _until(tree, 30.0, func() -> bool: return sd.is_fired(ev_id))
	_ok(fired, "the event fired when the clock crossed it")
	await _settle(tree, 5)
	var pinned: Array = bridge.call("all_hands_ids")
	_ok(not pinned.is_empty(), "crews pinned as ALL HANDS (%d)" % pinned.size())
	var got_projects := await _until(tree, 30.0, func() -> bool:
		return int(sd.status().get("total", 0)) > 0 and int(sd.status().get("pending", 0)) < int(sd.status().get("total", 0)))
	var st: Dictionary = sd.status()
	_ok(got_projects, "projects on the boards: %s" % str(st.get("line", "")))
	_ok(bool(st.get("active", false)) and str(st.get("action", "")) == SiteDeploySchedule.ACTION_DEPLOY, "status reads deploying")
	var working := await _until(tree, 60.0, func() -> bool: return _working(bridge) > 0)
	_ok(working, "people are DOING deploy chores (%d now)" % _working(bridge))
	# Per-part staging: the shiftpod's generic site lays its parts out and
	# seats them; the dome's site rebuilds the dome at its assembly fraction.
	var pod_id := str(kits.get("shiftpod", ""))
	var dome_id := str(kits.get(DomeLabBuilder.MODEL_ID, ""))
	# These two are over quickly (a camp is pitched in minutes at 720x, the
	# dome's builder stages it as soon as its crew starts), so they are
	# checked FIRST, before the slower shiftpod waits.
	var partial := await _until(tree, 90.0, func() -> bool:
		for a in layer.areas:
			var f: float = loader.get("_camp_area_runtime").built_fraction(str((a as Dictionary)["id"]))
			if f > 0.0 and f < 1.0:
				return true
		return false)
	_ok(partial, "a camp seen half-pitched (live fraction)")
	var dome_staged := await _until(tree, 240.0, func() -> bool:
		var ds := AssemblyBuildSite.site_for(main, dome_id)
		return (ds != null and ds.get_node_or_null("Staged") != null) or not _packed(main, dome_id))
	_ok(dome_staged, "the dome is staged by its own builder (a Staged node) or already up")
	var site_up := await _until(tree, 120.0, func() -> bool:
		var ss := AssemblyBuildSite.site_for(main, pod_id)
		return ss != null and ss.owns_visuals())
	_ok(site_up, "the shiftpod has a staging site that owns its picture")
	var pod_site := AssemblyBuildSite.site_for(main, pod_id)
	_ok(pod_site != null and (pod_site.get_node_or_null("Parts") as Node) != null
		and (pod_site.get_node("Parts") as Node).get_child_count() > 0,
		"split mode cut the shiftpod into parts (%d)" % ((pod_site.get_node("Parts") as Node).get_child_count() if pod_site != null and pod_site.get_node_or_null("Parts") != null else 0))
	var staged := await _until(tree, 240.0, func() -> bool:
		var ss := AssemblyBuildSite.site_for(main, pod_id)
		return ss != null and float(ss.get("_laid_t")) > 0.05)
	_ok(staged, "the shiftpod's parts are being laid out (%s)" % (str(AssemblyBuildSite.site_for(main, pod_id).progress_line()) if AssemblyBuildSite.site_for(main, pod_id) != null else "no site"))
	# Close-ups of the staging: the settlement camera low over the shiftpod
	# while its parts are laid out, then once they are going up.
	var pod_rec0 := PlacedPropService.get_prop_record(main, pod_id)
	var pod_pos := Vector2(float(pod_rec0.get("x", 0.0)), float(pod_rec0.get("z", 0.0)))
	var view: Variant = main.get("settlement_view")
	var cam: Variant = view.get("_cam") if view != null else null
	if cam != null:
		# The camera eases _h onto _h_target; writing _h alone is undone next frame.
		cam.set("_h_target", 14.0)
		cam.set("_h", 14.0)
		cam.call("look_at_xz", pod_pos)
	await _settle(tree, 12)
	await _shot(main, "01b_staging_laid_out")
	var seating := await _until(tree, 240.0, func() -> bool:
		var ss := AssemblyBuildSite.site_for(main, pod_id)
		return ss != null and float(ss.get("_assembled_t")) > 0.3)
	_ok(seating, "the shiftpod's parts are being seated (%s)" % (str(AssemblyBuildSite.site_for(main, pod_id).progress_line()) if AssemblyBuildSite.site_for(main, pod_id) != null else "no site"))
	if cam != null:
		cam.call("look_at_xz", pod_pos)
	await _settle(tree, 12)
	await _shot(main, "01c_staging_seating")
	await _shot(main, "01_deploying")
	var done := await _until(tree, 600.0, func() -> bool: return not bool(sd.status().get("active", false)))
	st = sd.status()
	_ok(done, "deploy finished: %s" % str(st.get("line", "")))
	await tree.create_timer(4.0).timeout
	await _settle(tree, 10)
	var cb2 := _camps_built(loader)
	_ok(int(cb2["built"]) == int(cb2["total"]), "every camp stands again (%d of %d)" % [int(cb2["built"]), int(cb2["total"])])
	_ok((loader.call("camp_shelters_in_polygon", poly0) as Array).size() == beds0, "the camp's beds are back")
	for mid in kits:
		_ok(not _packed(main, str(kits[mid])), "%s unpacked by the crew" % mid)
	var rack_rec := PlacedPropService.get_prop_record(main, str(kits.get(PalletRackBuilder.MODEL_ID, "")))
	_ok(not (rack_rec.get("build_state") is Dictionary) and not (rack_rec.get(PalletRackBuildSite.RECORD_KEY) is Dictionary),
		"the rack's construction state is cleared")
	_ok(AssemblyBuildSite.site_for(main, pod_id) == null, "the deployed shiftpod carries no staging site")
	_ok((bridge.call("all_hands_ids") as Array).is_empty(), "ALL HANDS released")
	await _shot(main, "02_deployed")

	# --- 4. scrub back past the event: instant undo ----------------------
	main.set("time_scale", 0.001)
	main.call("set_absolute_hours", at - 1.0)
	var undone := await _until(tree, 20.0, func() -> bool: return not sd.is_fired(ev_id))
	_ok(undone, "scrubbing back clears the stamp")
	await tree.create_timer(4.0).timeout
	await _settle(tree, 10)
	var cb3 := _camps_built(loader)
	_ok(int(cb3["built"]) == 0, "camps struck again by the rewind (%d standing)" % int(cb3["built"]))
	var repacked := 0
	for mid in kits:
		if _packed(main, str(kits[mid])):
			repacked += 1
	_ok(repacked == kits.size(), "kits packed again by the rewind (%d of %d)" % [repacked, kits.size()])
	# Forward across it again: it fires again (a moved / rewound event is a new promise).
	main.set("time_scale", 0.2)
	var refired := await _until(tree, 30.0, func() -> bool: return sd.is_fired(ev_id))
	_ok(refired, "crossing it forward again fires it again")
	# Leave it: clear the schedule (releases the crews, cancels the projects) and
	# restore the site instantly for the pack-up test.
	sd.clear()
	await _settle(tree, 5)
	_ok((bridge.call("all_hands_ids") as Array).is_empty(), "clearing the schedule releases ALL HANDS")
	main.set("time_scale", 0.001)
	sd.apply_instant(SiteDeploySchedule.ACTION_DEPLOY)
	await tree.create_timer(4.0).timeout
	await _settle(tree, 10)
	_ok(int(_camps_built(loader)["built"]) == int(cb0["total"]), "instant deploy stands every camp")

	# --- 5. a pack-up event with the crew --------------------------------
	var at2 := _now(main) + 0.05
	var ev2: String = sd.add_event(SiteDeploySchedule.ACTION_PACKUP, at2)
	main.set("time_scale", 0.2)
	var fired2 := await _until(tree, 30.0, func() -> bool: return sd.is_fired(ev2))
	_ok(fired2, "the pack-up event fired")
	var working2 := await _until(tree, 90.0, func() -> bool: return _working(bridge) > 0)
	_ok(working2, "people are DOING pack-up chores")
	await _shot(main, "03_packing")
	var done2 := await _until(tree, 600.0, func() -> bool: return not bool(sd.status().get("active", false)))
	_ok(done2, "pack-up finished: %s" % str(sd.status().get("line", "")))
	await tree.create_timer(4.0).timeout
	await _settle(tree, 10)
	_ok(int(_camps_built(loader)["built"]) == 0, "every camp struck by the crew")
	var packed2 := 0
	for mid in kits:
		if _packed(main, str(kits[mid])):
			packed2 += 1
	_ok(packed2 == kits.size(), "every kit packed by the crew (%d of %d)" % [packed2, kits.size()])
	var pod_rec := PlacedPropService.get_prop_record(main, pod_id)
	var pod_at := Vector2(float(pod_rec.get("x", 0.0)), float(pod_rec.get("z", 0.0)))
	_ok(pod_at.distance_to(door) < 3.0, "the packed shiftpod was carried to the container's door (%.1f m off)" % pod_at.distance_to(door))
	# The record round-trips through the director's own file.
	var fresh := SiteDeployDirector.new()
	fresh.bind(main, bridge)
	_ok(fresh.events().size() == 1 and fresh.is_fired(ev2), "the schedule file carries the event and its stamp")
	await _shot(main, "04_packed_by_crew")

	# --- 6. one structure on its own (the prop editor's Crew: build) ------
	sd.clear()
	await _settle(tree, 5)
	var q: Dictionary = sd.queue_item("prop", pod_id, SiteDeploySchedule.ACTION_DEPLOY)
	_ok(bool(q.get("ok", false)), "queue_item accepted the shiftpod (%s)" % str(q.get("error", "")))
	var mst: Dictionary = sd.status()
	_ok(bool(mst.get("active", false)) and bool(mst.get("manual", false)), "status reads the manual run: %s" % str(mst.get("line", "")))
	var mdone := await _until(tree, 300.0, func() -> bool: return not bool(sd.status().get("active", false)))
	_ok(mdone, "the single build finished: %s" % str(sd.status().get("line", "")))
	await tree.create_timer(2.0).timeout
	await _settle(tree, 10)
	_ok(not _packed(main, pod_id), "the shiftpod stands again, built on its own")
	_ok((bridge.call("all_hands_ids") as Array).is_empty(), "the manual run released its crew")
	await _shot(main, "05_single_build")
	main.set("time_scale", 0.001)
	return {"ok": _fails.is_empty(), "failures": _fails}
