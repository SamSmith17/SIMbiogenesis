extends RefCounted
## Tool Camp 26 put up by the crew, checked and filmed (sandbox, Walton):
##   tools\harness.ps1 -World walton -RunScript res://tools/checks/tool_camp_build_video.gd -Label tool_camp_build -Timeout 3600
## A packed Tool Camp 26 on open ground by the festival field, handed to the
## nearest crew (queue_item, the prop editor's "Crew: build" path), the clock
## run through the build. Asserts what the user asked for: no finished rack
## (the ghost / "twin") is ever drawn while the crew works, every piece starts
## in the yard and goes up piece by piece, the racking (frames + beams) before
## any deck, roof, wall or bench, and the rack stands for real at the end.
## Then the video: a second Tool Camp is queued and the 🎬 export renders its
## build round an orbiting camera.
## Env: TCV_VIDEO=0 skips the export; TCV_DIR = output folder (default the
## user's Videos folder); TCV_SPAN_H = sim hours filmed (default 10);
## TCV_HPS = sim hours per video second (default: the span in ~50 s);
## TCV_CHECK=0 skips the checked build.

var _fails: Array = []
const SHOT_DIR := "user://screenshots/tool_camp_build"


func _ok(cond: bool, what: String) -> void:
	print("tool-camp-build %s: %s" % ["PASS" if cond else "FAIL", what])
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
	print("tool-camp-build shot: %s" % name)


func _aim(main: Node, at: Vector2, h: float) -> void:
	var view: Variant = main.get("settlement_view")
	var cam: Variant = view.get("_cam") if view != null else null
	if cam == null:
		return
	cam.set("_h_target", h)
	cam.set("_h", h)
	cam.set("focus", at)
	cam.set("_focus_target", at)


## Open ground: outside every painted camp, clear of buildings, roads and
## water for a `half` m square, searched on a spiral out from `centre`.
func _free_spot(loader: Node, centre: Vector2, half: float, avoid: Array = []) -> Vector2:
	for r in [0.0, 40.0, 60.0, 80.0, 100.0, 130.0, 160.0, 200.0, 250.0]:
		for k in 16:
			var a := float(k) * TAU / 16.0
			var c: Vector2 = centre + Vector2(cos(a), sin(a)) * float(r)
			var ok := true
			for q in avoid:
				if c.distance_to(q) < half * 3.0:
					ok = false
			for dx in [-half, 0.0, half]:
				for dz in [-half, 0.0, half]:
					if not ok:
						break
					if not str(loader.call("camp_area_at", c + Vector2(float(dx), float(dz)))).is_empty():
						ok = false
			if ok and loader.has_method("festival_ground_free") and not bool(loader.call("festival_ground_free", c, half)):
				ok = false
			if ok:
				return c
	return Vector2.INF


func _place_kit(main: Node, at: Vector2) -> String:
	var r: Dictionary = PlacedPropService.place_model_at_xz(main, PalletRackBuilder.MODEL_ID, at.x, at.y,
		{"packed": true, "rack_spec": PalletRackBuilder.resolve_spec(PalletRackBuilder.tool_camp_26_spec())})
	return str(r.get("prop_id", "")) if bool(r.get("ok", false)) else ""


## Counts over the live site: units visible, installed in place, still on
## the ground (yard / carried / set down); and whether the ghost model shows.
func _census(site: PalletRackBuildSite) -> Dictionary:
	var st := site.last_state()
	var out := {"installed": 0, "ground": 0, "total": 0, "heads": {}, "model": false, "crate": false}
	var units: Dictionary = st.get("units", {})
	for id in units:
		var s: Dictionary = units[id]
		out["total"] = int(out["total"]) + 1
		var inst := float(s["g"]) <= 0.001 and (s["xf"] as Transform3D).is_equal_approx(Transform3D())
		if inst:
			out["installed"] = int(out["installed"]) + 1
			var leaf := str(id).get_slice("|", 1) if str(id).contains("|") else str(id)
			var h := leaf.get_slice(":", 0)
			(out["heads"] as Dictionary)[h] = int((out["heads"] as Dictionary).get(h, 0)) + 1
		else:
			out["ground"] = int(out["ground"]) + 1
	var prop := site.get_parent()
	var model := prop.get_node_or_null("ModelRoot") as Node3D
	out["model"] = model != null and model.is_visible_in_tree()
	var crate := prop.get_node_or_null("KitCrate") as Node3D
	out["crate"] = crate != null and crate.is_visible_in_tree()
	# Unit nodes the plan never moves would stand finished from the first frame.
	var root := site.get_node_or_null("RackUnits")
	var unplanned := 0
	if root != null:
		for c in root.get_children():
			if not units.has(str(c.get_meta("unit_id", ""))) and (c as Node3D).visible:
				unplanned += 1
	out["unplanned"] = unplanned
	return out


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
	main.set("time_scale", 0.001)
	var day0: float = floor(float(main.call("get_absolute_hours")) / 24.0) * 24.0
	# Walton's valley fog lies until late morning: start at noon. The
	# festival's natural headcount (the sandbox may carry a small target),
	# so each camp's crew is a real crew.
	main.call("set_absolute_hours", day0 + float(OS.get_environment("TCV_START_H")) if not OS.get_environment("TCV_START_H").is_empty() else day0 + 12.0)
	PopTestPrefs.set_festival_target_people(int(OS.get_environment("TCV_PEOPLE")) if not OS.get_environment("TCV_PEOPLE").is_empty() else 0)
	main.call("open_festival_mode")
	for _i in 900:
		await tree.process_frame
		if bool(main.call("festival_mode_active")):
			break
	await _settle(tree, 30)
	# The target only reaches the camps through the loader's graph sync (the
	# rosters then resize in place on the next ticks).
	var pop: Dictionary = loader.call("apply_festival_population_target") if loader.has_method("apply_festival_population_target") else {}
	print("tool-camp-build: festival population %s" % str(pop))
	main.set("time_scale", 0.02)
	await tree.create_timer(4.0).timeout
	main.set("time_scale", 0.001)
	var centre := SiteCentre.xz(main)
	var spot_a := _free_spot(loader, centre, 22.0)
	_ok(spot_a != Vector2.INF, "open ground for the rack at (%.0f, %.0f)" % [spot_a.x, spot_a.y])
	if spot_a == Vector2.INF:
		return {"ok": false}
	var bridge: Variant = sgv.call("npc_population_bridge")
	var do_check := OS.get_environment("TCV_CHECK") != "0"
	if do_check:
		await _checked_build(main, tree, sd, spot_a)
	if OS.get_environment("TCV_VIDEO") != "0":
		var spot_b := spot_a if not do_check else _free_spot(loader, centre, 22.0, [spot_a])
		_ok(spot_b != Vector2.INF, "open ground for the filmed rack")
		if spot_b != Vector2.INF:
			await _filmed_build(main, tree, sd, loader, spot_b)
	return {"ok": _fails.is_empty(), "failures": _fails}


func _checked_build(main: Node, tree: SceneTree, sd: SiteDeployDirector, at: Vector2) -> void:
	var pid := _place_kit(main, at)
	_ok(not pid.is_empty(), "packed Tool Camp 26 placed")
	if pid.is_empty():
		return
	await _settle(tree, 10)
	var q: Dictionary = sd.queue_item("prop", pid, SiteDeploySchedule.ACTION_DEPLOY)
	_ok(bool(q.get("ok", false)), "handed to the crew (%s)" % str(q.get("error", "")))
	await _settle(tree, 10)
	var site := PalletRackBuildSite.site_for(main, pid)
	var t_wait := 0.0
	while site == null and t_wait < 30.0:
		await tree.create_timer(0.25).timeout
		t_wait += 0.25
		site = PalletRackBuildSite.site_for(main, pid)
	_ok(site != null, "a labour build site runs on the rack")
	if site == null:
		return
	_aim(main, at, 45.0)
	await tree.create_timer(1.0).timeout
	var c0 := _census(site)
	print("tool-camp-build start: %s" % str(c0))
	_ok(not bool(c0["model"]), "no ghost of the finished rack at the start")
	_ok(int(c0["unplanned"]) == 0, "every piece is in the plan (%d drawn finished)" % int(c0["unplanned"]))
	_ok(int(c0["installed"]) == 0, "nothing stands at the start (%d of %d up)" % [int(c0["installed"]), int(c0["total"])])
	_ok(not bool(c0["crate"]), "the kit crate is unpacked into the yard")
	await _shot(main, "00_yard")
	var h_start := float(main.call("get_absolute_hours"))
	main.set("time_scale", 0.4)
	var ghost_seen := 0
	var deck_before_racking := false
	var max_inst := 0
	var shots := {0.15: "01_frames", 0.35: "02_racking", 0.6: "03_decks", 0.85: "04_roof_walls"}
	var t := 0.0
	var done := false
	while t < 1500.0:
		await tree.create_timer(0.5).timeout
		t += 0.5
		if not bool(PlacedPropService.get_prop_record(main, pid).get("packed", false)):
			done = true
			break
		site = PalletRackBuildSite.site_for(main, pid)
		if site == null:
			continue
		var c := _census(site)
		if bool(c["model"]):
			ghost_seen += 1
		var heads: Dictionary = c["heads"]
		var deck_n := int(heads.get("joist", 0)) + int(heads.get("ply", 0)) + int(heads.get("wall", 0)) + int(heads.get("el", 0))
		var racking_n := int(heads.get("post", 0)) + int(heads.get("beam", 0))
		if deck_n > 0 and racking_n < 28 + 106:
			deck_before_racking = true
		max_inst = maxi(max_inst, int(c["installed"]))
		var frac := float(c["installed"]) / maxf(float(c["total"]), 1.0)
		for f in shots.keys():
			if frac >= float(f) and not str(shots[f]).is_empty():
				_aim(main, at, 45.0)
				print("tool-camp-build %s: %s · %s" % [shots[f], str(heads), site.progress_line()])
				await _shot(main, str(shots[f]))
				shots[f] = ""
	_ok(ghost_seen == 0, "the ghost rack never showed during the build (%d samples)" % ghost_seen)
	_ok(not deck_before_racking, "every frame and beam up before the first deck, roof, wall or bench")
	_ok(done, "the crew finished: the rack is deployed (%.0f s real, %.2f sim-hours)" % [t,
		float(main.call("get_absolute_hours")) - h_start])
	await _settle(tree, 30)
	var prop := PlacedPropService._find_prop_node(main, pid)
	var model := prop.get_node_or_null("ModelRoot") as Node3D if prop != null else null
	_ok(model != null and model.is_visible_in_tree() and not bool(prop.get_meta("under_construction", false)),
		"the real rack stands at the end")
	_aim(main, at, 45.0)
	await tree.create_timer(1.0).timeout
	await _shot(main, "05_done")
	if done and OS.get_environment("TCV_PACKUP") != "0":
		await _checked_packup(main, tree, sd, at, pid)


## The same rack taken down by the crew: the fit-out (decks, roof, walls,
## benches, stairs) comes off AND goes back to the yard before the first
## beam or upright frame comes down; the racking is the last thing struck.
func _checked_packup(main: Node, tree: SceneTree, sd: SiteDeployDirector, at: Vector2, pid: String) -> void:
	main.set("time_scale", 0.001)
	var q: Dictionary = sd.queue_item("prop", pid, SiteDeploySchedule.ACTION_PACKUP)
	_ok(bool(q.get("ok", false)), "pack-up handed to the crew (%s)" % str(q.get("error", "")))
	await _settle(tree, 10)
	var site := PalletRackBuildSite.site_for(main, pid)
	var t_wait := 0.0
	while site == null and t_wait < 30.0:
		await tree.create_timer(0.25).timeout
		t_wait += 0.25
		site = PalletRackBuildSite.site_for(main, pid)
	_ok(site != null, "a labour site takes the rack down")
	if site == null:
		return
	await tree.create_timer(1.0).timeout
	var c0 := _census(site)
	_ok(int(c0["installed"]) == int(c0["total"]) and int(c0["total"]) > 0,
		"everything stands at the start of the pack-up (%d of %d)" % [int(c0["installed"]), int(c0["total"])])
	main.set("time_scale", 0.4)
	var racking_ids := {}
	var fit_ids := {}
	for id in (site.timeline()["unit"] as Dictionary):
		var leaf := str(id).get_slice("|", 1) if str(id).contains("|") else str(id)
		if leaf.get_slice(":", 0) in ["post", "beam"]:
			racking_ids[id] = true
		else:
			fit_ids[id] = true
	var fit_up_while_racking := 0
	var fit_out_while_racking := 0
	var first_racking_t := -1.0
	var shots := {0.25: "06_strip", 0.5: "07_strip", 0.8: "08_racking"}
	var t := 0.0
	var packed := false
	while t < 1500.0:
		await tree.create_timer(0.5).timeout
		t += 0.5
		if bool(PlacedPropService.get_prop_record(main, pid).get("packed", false)):
			packed = true
			break
		site = PalletRackBuildSite.site_for(main, pid)
		if site == null:
			continue
		var st := site.last_state()
		var units: Dictionary = st.get("units", {})
		var tl := site.timeline()
		var racking_moved := false
		for id in racking_ids:
			var s: Dictionary = units.get(id, {})
			if not s.is_empty() and not (float(s["g"]) <= 0.001 and (s["xf"] as Transform3D).is_equal_approx(Transform3D())):
				racking_moved = true
				break
		if racking_moved:
			if first_racking_t < 0.0:
				first_racking_t = t
				print("tool-camp-packup: first beam / frame off at %.1f s · %s" % [t, site.progress_line()])
			var up := 0
			var out := 0
			for id in fit_ids:
				var s: Dictionary = units.get(id, {})
				if s.is_empty():
					continue
				var xf: Transform3D = s["xf"]
				if float(s["g"]) <= 0.001 and xf.is_equal_approx(Transform3D()):
					up += 1
				elif not xf.is_equal_approx((tl["unit"][id] as Dictionary)["pile"]):
					out += 1
			fit_up_while_racking = maxi(fit_up_while_racking, up)
			fit_out_while_racking = maxi(fit_out_while_racking, out)
		var c := _census(site)
		var frac := 1.0 - float(c["installed"]) / maxf(float(c["total"]), 1.0)
		for f in shots.keys():
			if frac >= float(f) and not str(shots[f]).is_empty():
				_aim(main, at, 45.0)
				print("tool-camp-packup %s: %s · %s" % [shots[f], str(c["heads"]), site.progress_line()])
				await _shot(main, str(shots[f]))
				shots[f] = ""
	_ok(fit_up_while_racking == 0, "no deck, roof, wall or bench still up once the racking starts coming down (%d)" % fit_up_while_racking)
	_ok(fit_out_while_racking == 0, "the fit-out is back in the yard before the racking comes down (%d not yet)" % fit_out_while_racking)
	_ok(packed, "the crew packed the rack (%.0f s real)" % t)


func _filmed_build(main: Node, tree: SceneTree, sd: SiteDeployDirector, loader: Node, at: Vector2) -> void:
	var ffmpeg := ClimelapseVideoEncoder.find_ffmpeg()
	_ok(not ffmpeg.is_empty(), "ffmpeg found")
	if ffmpeg.is_empty():
		return
	main.set("time_scale", 0.001)
	var pid := _place_kit(main, at)
	_ok(not pid.is_empty(), "packed Tool Camp 26 placed for the film")
	if pid.is_empty():
		return
	await _settle(tree, 10)
	var q: Dictionary = sd.queue_item("prop", pid, SiteDeploySchedule.ACTION_DEPLOY)
	_ok(bool(q.get("ok", false)), "film rack handed to the crew")
	_aim(main, at, 45.0)
	await _settle(tree, 20)
	# How long the crew needs: the rows' person-hours over their crews.
	var rec := PlacedPropService.get_prop_record(main, pid)
	var est_h := 0.0
	var item := {"kind": "prop", "id": pid, "model_id": PalletRackBuilder.MODEL_ID,
		"mass_kg": float(PlacedPropRuntime.packed_spec_for_record(rec).get("mass_kg", -1.0)), "label": "Tool Camp"}
	for r in SiteDeployPlanner.rows_for(item, SiteDeploySchedule.ACTION_DEPLOY, 10):
		est_h += float(r["chore_hours"]) / float(maxi(1, int(r["max_workers"])))
	# The rows' sum is far under what the crew really takes (people sleep,
	# eat and walk; the checked build of 2026-10-27 took ~9 sim-hours with
	# 60 people on Walton), so the film spans TCV_SPAN_H (default 10 h).
	var span_h := float(OS.get_environment("TCV_SPAN_H")) if not OS.get_environment("TCV_SPAN_H").is_empty() else 10.0
	var now_h := float(main.call("get_absolute_hours"))
	var hps := float(OS.get_environment("TCV_HPS")) if not OS.get_environment("TCV_HPS").is_empty() else span_h / 50.0
	print("tool-camp-build film: crew estimate %.2f h, filming %.2f h at %.3f h per video second" % [est_h, span_h, hps])
	# Camera: a slow orbit round the build site (rack + yard), framed on the
	# plan's own bounds.
	var site := PalletRackBuildSite.site_for(main, pid)
	var rad := 14.0
	var target := Vector3(at.x, TerrainSurfaceQuery.ground_height_at(main, at.x, at.y) + 3.0, at.y)
	if site != null and not site.timeline().is_empty():
		var bb: AABB = site.timeline()["bounds"]
		rad = maxf(bb.size.x, bb.size.z) * 0.5
		var c := site.global_transform * bb.get_center()
		target = Vector3(c.x, TerrainSurfaceQuery.ground_height_at(main, c.x, c.z) + 2.5, c.z)
	var orbit := rad * 1.7 + 10.0
	print("tool-camp-build film: rack half-size %.1f m, orbit %.1f m" % [rad, orbit])
	var keys: ClimelapseKeyframes = loader.call("climelapse_keys")
	keys.clear()
	for k in 5:
		var a := deg_to_rad(200.0 + 40.0 * float(k))
		var eye := target + Vector3(cos(a) * orbit, orbit * 0.42 - float(k), sin(a) * orbit)
		var xf := Transform3D(Basis.looking_at(target - eye, Vector3.UP), eye)
		keys.set_key(now_h + span_h * float(k) / 4.0, xf, 55.0)
	loader.call("_save_climelapse_keys")
	var solar: Node = main.get_node_or_null("UILayer/SolarUI")
	var tl_ui: Node = main.get_node_or_null("UILayer/TimelineUI")
	solar.call("set_selection_abs", now_h, now_h + span_h)
	tl_ui.call("_on_export_clim_mp4_pressed")
	await _settle(tree, 4)
	var dlg: Node = tl_ui.get("_clim_options_dialog")
	_ok(dlg != null and is_instance_valid(dlg), "export dialog open")
	if dlg == null:
		return
	(dlg.get("_speed_spin") as SpinBox).value = hps
	var res_opt: OptionButton = dlg.get("_res_opt")
	res_opt.select(2)
	dlg.call("_on_res_preset", 2)
	var fps_opt: OptionButton = dlg.get("_fps_opt")
	fps_opt.select(ClimelapseExportOptions.FPS_CHOICES.find(30))
	var out_dir := OS.get_environment("TCV_DIR")
	if out_dir.is_empty():
		out_dir = OS.get_environment("USERPROFILE").path_join("Videos")
	out_dir = out_dir.replace("\\", "/")
	DirAccess.make_dir_recursive_absolute(out_dir)
	(dlg.get("_folder_edit") as LineEdit).text = out_dir
	var fname := "tool_camp_26_build_%s.mp4" % Time.get_datetime_string_from_system().replace(":", "").replace("T", "_")
	(dlg.get("_file_edit") as LineEdit).text = fname
	dlg.call("_on_changed")
	var o: Dictionary = dlg.call("current_options")
	print("tool-camp-build film options: %d×%d %d fps, %.3f h/s, %d frames" % [int(o["width"]), int(o["height"]),
		int(o["fps"]), float(o["hours_per_second"]), ClimelapseExportOptions.frame_count(o)])
	var out_mp4 := ClimelapseExportOptions.output_path(o)
	var t0 := Time.get_ticks_msec()
	dlg.call("_on_export")
	await _settle(tree, 3)
	var ghost_frames := 0
	var samples := 0
	var guard := 0
	var last_print := 0
	while bool(loader.call("is_climelapse_exporting")) and guard < 60 * 3000:
		await tree.process_frame
		guard += 1
		if guard % 30 == 0:
			var ws := PalletRackBuildSite.site_for(main, pid)
			if ws != null and ws.is_inside_tree():
				var c := _census(ws)
				samples += 1
				if bool(c["model"]) and bool(PlacedPropService._find_prop_node(main, pid).get_meta("under_construction", false)):
					ghost_frames += 1
				if Time.get_ticks_msec() - last_print > 15000:
					last_print = Time.get_ticks_msec()
					print("tool-camp-build film: %s · %d of %d up · %s" % [str(c["heads"]), int(c["installed"]),
						int(c["total"]), ws.progress_line()])
	var st: Dictionary = loader.call("get_climelapse_export_stats")
	print("tool-camp-build film result: %s — %s (%.0f s)" % [str(st.get("result")), str(st.get("message")),
		float(Time.get_ticks_msec() - t0) / 1000.0])
	_ok(str(st.get("result")) == "ok", "video exported: %s" % out_mp4)
	_ok(ghost_frames == 0, "no ghost rack during the filmed build (%d of %d samples)" % [ghost_frames, samples])
	var built := not bool(PlacedPropService.get_prop_record(main, pid).get("packed", false))
	print("tool-camp-build film: rack %s at the end of the film" % ("deployed" if built else "still being built"))
