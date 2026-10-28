extends RefCounted
## A Linkage Lab structure built by a crew on the shared crew build site
## (sandbox, either world):
##   tools\harness.ps1 -World walton -RunScript res://tools/checks/linkage_crew_build_check.gd -Label linkage_crew -Timeout 1200
## A StarShade (SOAK 2026 design) placed deployed, then the prop editor's
## rehearsal on a held clock moved by hand: nothing stands at the start; the
## folded frame the crew puts up stands on the DEPLOYED ring's middle (the
## solver hangs the ring off module 0 and its middle used to swing round as it
## folded, so the folded frame and the opened structure stood apart); half
## way pieces stand; after the last piece the real structure opens about that
## same middle; at the end it stands at the pose it was placed in; scrubbing
## back puts the pieces back. Then the build played on a running clock at
## speed, with frame times (median / worst) — and ending the rehearsal hands
## the structure back as it was. Shots under screenshots\linkage_crew\.
## Env LCB_DESIGN = a res:// preset (default the SOAK 2026 StarShade).

var _fails: Array = []
const SHOT_DIR := "user://screenshots/linkage_crew"
var _cam: Camera3D = null


func _ok(cond: bool, what: String) -> void:
	print("linkage-crew %s: %s" % ["PASS" if cond else "FAIL", what])
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
	print("linkage-crew shot: %s" % name)


func _look(main: Node, at: Vector3, r: float) -> void:
	if _cam == null:
		_cam = Camera3D.new()
		_cam.name = "LinkageCrewCheckCam"
		_cam.fov = 55.0
		main.add_child(_cam)
		main.call("push_camera_claim", "linkage_crew_check", {"camera_id": _cam.get_instance_id()})
	var target := at + Vector3(0, 1.5, 0)
	var eye := target + Vector3(r * 0.85, r * 0.6, r * 0.75)
	eye.y = maxf(eye.y, TerrainSurfaceQuery.ground_height_at(main, eye.x, eye.z) + 3.0)
	_cam.global_transform = Transform3D(Basis.looking_at(target - eye, Vector3.UP), eye)


func _goto(main: Node, tree: SceneTree, h0: float, t: float) -> void:
	main.call("set_absolute_hours", h0 + t / 3600.0)
	await _settle(tree, 4)


## Frame times while the clock runs at `ts` for `secs` (or until the site
## ends): {frames, median_ms, p95_ms, worst_ms, site_ms (the build_site span,
## avg), sections (the 4 costliest, avg ms)}.
func _frames(main: Node, tree: SceneTree, ts: float, secs: float, site: Variant, pm: Node) -> Dictionary:
	var frames: Array = []
	var acc := {}
	main.set("time_scale", ts)
	var t := 0.0
	while t < secs:
		await tree.process_frame
		var d := tree.root.get_process_delta_time()
		frames.append(d * 1000.0)
		t += d
		if pm != null:
			var lf: Dictionary = pm.get("last_frame")
			for k in lf:
				acc[k] = float(acc.get(k, 0.0)) + float(lf[k])
		if site != null and not (site as PalletRackBuildSite).is_running():
			break
	main.set("time_scale", 0.0)
	frames.sort()
	var n := maxi(frames.size(), 1)
	var top: Array = acc.keys()
	top.sort_custom(func(a, c): return float(acc[a]) > float(acc[c]))
	var secs_out := {}
	for k in top.slice(0, 5):
		secs_out[k] = snappedf(float(acc[k]) / n, 0.01)
	return {"frames": frames.size(),
		"median_ms": snappedf(float(frames[frames.size() / 2]), 0.1) if not frames.is_empty() else 0.0,
		"p95_ms": snappedf(float(frames[int(frames.size() * 0.95)]), 0.1) if not frames.is_empty() else 0.0,
		"worst_ms": snappedf(float(frames.back()), 0.1) if not frames.is_empty() else 0.0,
		"site_ms": snappedf(float(acc.get("build_site", 0.0)) / n, 0.01), "sections": secs_out}


## The ring's middle in the world: the builder's plan middle at its pose.
func _ring_world(b: LinkageStructureBuilder) -> Vector3:
	var c := LinkageStructureBuilder.plan_centre_of(b.last_frame()) + b.frame_offset() * Vector3(1, 0, 1)
	return b.global_transform * c


func _installed(site: PalletRackBuildSite) -> Vector2i:
	var units: Dictionary = site.last_state().get("units", {})
	var n := 0
	for id in units:
		var s: Dictionary = units[id]
		if float(s["g"]) <= 0.001 and (s["xf"] as Transform3D).is_equal_approx(Transform3D()):
			n += 1
	return Vector2i(n, units.size())


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	await _settle(tree, 20)
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	_ok(loader != null, "the terrain loader is up")
	main.set("time_scale", 0.0)
	var day0: float = floor(float(main.call("get_absolute_hours")) / 24.0) * 24.0
	var h0 := day0 + 11.0
	main.call("set_absolute_hours", h0)
	var design := OS.get_environment("LCB_DESIGN")
	if design.is_empty():
		design = "res://core/linkage/presets/ll_starshade_v1_soak_2026.json"
	var cfg: Variant = JSON.parse_string(FileAccess.get_file_as_string(design))
	_ok(cfg is Dictionary, "the design loads (%s)" % design.get_file())
	if not (cfg is Dictionary):
		return {"ok": false, "failures": _fails}
	var player := main.find_child("Player", true, false) as Node3D
	var base := SiteCentre.xz(main)
	if player != null:
		base = Vector2(player.global_position.x, player.global_position.z) + Vector2(18.0, 6.0)
	var r: Dictionary = PlacedPropService.place_model_at_xz(main, LinkageStructureBuilder.MODEL_ID, base.x, base.y,
		{"linkage_spec": cfg, "yaw": 30.0})
	var pid := str(r.get("prop_id", ""))
	_ok(not pid.is_empty(), "a deployed StarShade placed")
	if pid.is_empty():
		return {"ok": false, "failures": _fails}
	await _settle(tree, 10)
	var prop := PlacedPropService._find_prop_node(main, pid)
	var b := prop.get_node_or_null("ModelRoot") as LinkageStructureBuilder if prop != null else null
	_ok(b != null and b.centre_fixed, "the placed structure keeps its middle as it folds (centre_fixed)")
	if b == null:
		return {"ok": false, "failures": _fails}
	var fold0 := b.get_fold_angle()
	var mid0 := _ring_world(b)
	# The fold about its middle, measured on the live builder.
	var worst := 0.0
	for u in [0.0, 0.5, 1.0]:
		b.set_fold_angle(lerpf(maxf(b.min_fold_angle(), LinkageKinematics.MIN_FOLD_ANGLE), fold0, u))
		worst = maxf(worst, _ring_world(b).distance_to(mid0))
	b.set_fold_angle(fold0)
	_ok(worst < 0.01, "folding keeps the ring on its middle (worst %.3f m)" % worst)
	# --- The rehearsal, on a held clock ---
	_ok(PalletRackBuildSite.start_rehearsal(main, pid, 12, h0), "the rehearsal starts")
	await _settle(tree, 6)
	var site := PalletRackBuildSite.site_for(main, pid)
	_ok(site != null and site.is_running(), "the crew build site runs on the structure")
	if site == null:
		return {"ok": false, "failures": _fails}
	var tl := site.timeline()
	var mk := float(tl.get("makespan", 0.0))
	var tail := PalletRackBuildSite.LINKAGE_DEPLOY_S
	print("linkage-crew plan: %s" % PalletRackBuildPlan.summary(tl))
	# The ring itself: the scissor beams' pieces (supports and hardware are not
	# symmetric about it).
	var all_units: Dictionary = site.get_node("RackUnits").get_meta("units", {})
	var ring := {}
	for id in all_units:
		var w: Array = all_units[id].get("words", [])
		if not w.is_empty() and str(w[1]) in ["bottom-ring beams", "V-module beams", "top-ring beams"]:
			ring[id] = all_units[id]
	var ub := PalletRackBuildPlan.units_bounds(ring)
	var cut_mid := site.global_transform * (ub.get_center() * Vector3(1, 0, 1))
	var off := Vector2(cut_mid.x - mid0.x, cut_mid.z - mid0.z).length()
	_ok(off < 0.1, "the part-open frame the crew builds stands on the deployed ring's middle (%.3f m off)" % off)
	var size := b.frame_aabb().size
	_look(main, mid0, clampf(maxf(size.x, size.z) * 1.1, 8.0, 40.0))
	await _goto(main, tree, h0, 1.0)
	var c0 := _installed(site)
	_ok(c0.x == 0 and c0.y > 0, "nothing stands at the start (%d of %d)" % [c0.x, c0.y])
	_ok(not b.visible, "the finished structure is hidden while the crew builds")
	await _shot(main, "00_start")
	await _goto(main, tree, h0, mk * 0.5)
	var c1 := _installed(site)
	_ok(c1.x > 0 and c1.x < c1.y, "half way, part of it stands (%d of %d)" % [c1.x, c1.y])
	print("linkage-crew half: %s" % site.progress_line())
	await _shot(main, "01_half")
	await _goto(main, tree, h0, mk)
	var c2 := _installed(site)
	_ok(c2.x >= c2.y - 1, "the whole part-open frame stands before it opens (%d of %d)" % [c2.x, c2.y])
	await _shot(main, "02_folded")
	_look(main, mid0, 4.5)
	await _settle(tree, 2)
	await _shot(main, "02b_folded_close")
	_look(main, mid0, clampf(maxf(size.x, size.z) * 1.1, 8.0, 40.0))
	await _goto(main, tree, h0, mk + tail * 0.5)
	var folding := b.get_fold_angle()
	var fold_from := LinkageStructureBuilder.crew_pose_angle(b.params)
	_ok(b.visible and not site.get_node("RackUnits").visible, "after the last piece the real structure is shown")
	_ok(folding > fold_from + 0.01 and folding < fold0 - 0.01,
		"half way through the unfold it is half open (%.1f° of %.1f°..%.1f°)" % [rad_to_deg(folding), rad_to_deg(fold_from), rad_to_deg(fold0)])
	var drift := _ring_world(b).distance_to(mid0)
	_ok(drift < 0.01, "it opens about the same middle (%.3f m)" % drift)
	print("linkage-crew unfold: %s" % site.progress_line())
	await _shot(main, "03_opening")
	await _goto(main, tree, h0, mk + tail + PalletRackBuildSite.LINGER_S + 5.0)
	_ok(not site.is_running() and b.visible, "the rehearsal ends with the structure standing")
	_ok(absf(b.get_fold_angle() - fold0) < 1e-3, "at the pose it was placed in")
	await _shot(main, "04_done")
	await _goto(main, tree, h0, mk * 0.5)
	var c3 := _installed(site)
	_ok(site.is_running() and not b.visible and c3.x == c1.x,
		"scrubbing back puts the pieces back (%d of %d, as before)" % [c3.x, c3.y])
	# --- Played at speed on a running clock (against the same clock with the
	# site parked past its end: the world's own cost) ---
	var pm: Node = main.get_node_or_null("/root/PerfMonitor")
	if pm != null:
		pm.call("set_enabled", true)
	var ts := (mk + tail) / 3600.0 / 8.0   # the whole build in ~8 s
	await _goto(main, tree, h0, mk + tail + PalletRackBuildSite.LINGER_S + 3600.0)
	var idle := await _frames(main, tree, ts, 3.0, null, pm)
	await _goto(main, tree, h0, 0.0)
	var run := await _frames(main, tree, ts, 12.0, site, pm)
	print("linkage-crew speed: baseline (no site) %s" % str(idle))
	print("linkage-crew speed: building at %.0fx  %s" % [ts * 3600.0, str(run)])
	_ok(int(run["frames"]) > 0 and not site.is_running(), "the build plays to its end at speed")
	_ok(float(run["site_ms"]) < 6.0, "the build site costs %.2f ms a frame at speed (avg)" % float(run["site_ms"]))
	# --- Ending the rehearsal ---
	PalletRackBuildSite.clear_rehearsal(main, pid)
	await _settle(tree, 4)
	_ok(b.visible and absf(b.get_fold_angle() - fold0) < 1e-3
		and not PlacedPropService.get_prop_record(main, pid).has(PalletRackBuildSite.RECORD_KEY),
		"ending the rehearsal hands the structure back as it was")
	if loader != null and loader.has_method("delete_prop_by_id"):
		loader.call("delete_prop_by_id", pid)
	main.call("pop_camera_claim", "linkage_crew_check")
	if _cam != null:
		_cam.queue_free()
	return {"ok": _fails.is_empty(), "failures": _fails}
