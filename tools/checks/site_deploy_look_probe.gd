extends RefCounted
## The LOOK of per-part staging, close up (sandbox, Walton):
##   tools\harness.ps1 -World walton -RunScript res://tools/checks/site_deploy_look_probe.gd -Label site_deploy_look -Timeout 900
## Three packed kits (a shiftpod — a GLB split by mesh; an EZ-up; a dome —
## staged by its own builder) handed to the crew one by one (queue_item, the
## prop editor's path), the settlement camera parked 12 m over each, and a
## shot at each stage: parts laid out in the yard, parts going up, the dome
## half assembled, everything standing. Prints the staging sites' progress
## lines beside each shot. Writes only the sandbox.

var _fails: Array = []
const SHOT_DIR := "user://screenshots/site_deploy_look"


func _ok(cond: bool, what: String) -> void:
	print("site-deploy-look %s: %s" % ["PASS" if cond else "FAIL", what])
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
	print("site-deploy-look shot: %s" % name)


func _until(tree: SceneTree, secs: float, pred: Callable) -> bool:
	var t := 0.0
	while t < secs:
		if bool(pred.call()):
			return true
		await tree.create_timer(0.25).timeout
		t += 0.25
	return bool(pred.call())


func _aim(main: Node, at: Vector2, h: float) -> void:
	var view: Variant = main.get("settlement_view")
	var cam: Variant = view.get("_cam") if view != null else null
	if cam == null:
		return
	# Height AND focus set outright (both ease otherwise, and a shot a few
	# frames later still shows the pan half-way across the site).
	cam.set("_h_target", h)
	cam.set("_h", h)
	cam.set("focus", at)
	cam.set("_focus_target", at)


## Open ground near the marker: outside every painted camp and clear of
## buildings, roads and water for a 30 m square, searched on a spiral.
func _free_spot(loader: Node, centre: Vector2) -> Vector2:
	for r in [0.0, 30.0, 50.0, 70.0, 90.0, 120.0, 150.0]:
		for k in 12:
			var a := float(k) * TAU / 12.0
			var c: Vector2 = centre + Vector2(cos(a), sin(a)) * float(r)
			var ok := true
			for dx in [-14.0, 0.0, 14.0]:
				for dz in [-6.0, 6.0]:
					var q: Vector2 = c + Vector2(float(dx), float(dz))
					if not str(loader.call("camp_area_at", q)).is_empty():
						ok = false
			if ok and loader.has_method("festival_ground_free") and not bool(loader.call("festival_ground_free", c, 16.0)):
				ok = false
			if ok:
				return c
	return centre


func _packed(main: Node, pid: String) -> bool:
	return bool(PlacedPropService.get_prop_record(main, pid).get("packed", false))


func _line(main: Node, pid: String) -> String:
	var ss := AssemblyBuildSite.site_for(main, pid)
	return ss.progress_line() if ss != null else "no site"


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
	main.call("set_absolute_hours", day0 + 10.0)
	# The kits go on the festival field at the site marker, not beside the
	# player: Walton's saved pose is in the forest, and a close-up there is
	# all canopy.
	var spot := _free_spot(loader, SiteCentre.xz(main))
	var px := spot.x
	var pz := spot.y
	print("site-deploy-look: kits at (%.0f, %.0f)" % [px, pz])
	var kits := {}
	var k := 0
	for mid in ["shiftpod", "ez_up", DomeLabBuilder.MODEL_ID]:
		var r: Dictionary = PlacedPropService.place_model_at_xz(main, mid, px - 12.0 + 12.0 * k, pz, {"packed": true})
		if bool(r.get("ok", false)):
			kits[mid] = str(r.get("prop_id", ""))
		k += 1
	_ok(kits.size() == 3, "three packed kits placed")
	main.call("open_festival_mode")
	for _i in 900:
		await tree.process_frame
		if bool(main.call("festival_mode_active")):
			break
	await _settle(tree, 30)
	var bridge: Variant = sgv.call("npc_population_bridge")
	var queued := 0
	for mid in kits:
		var q: Dictionary = sd.queue_item("prop", str(kits[mid]), SiteDeploySchedule.ACTION_DEPLOY)
		if bool(q.get("ok", false)):
			queued += 1
	_ok(queued == 3, "every kit handed to the crew (%d)" % queued)
	main.set("time_scale", 0.2)
	var pod := str(kits.get("shiftpod", ""))
	var dome := str(kits.get(DomeLabBuilder.MODEL_ID, ""))
	var pod_pos := Vector2(px - 12.0, pz)
	var dome_pos := Vector2(px + 12.0, pz)
	_aim(main, pod_pos, 40.0)
	var laid := await _until(tree, 300.0, func() -> bool:
		var ss := AssemblyBuildSite.site_for(main, pod)
		return ss != null and float(ss.get("_laid_t")) > 0.4)
	_ok(laid, "shiftpod parts laid out — %s" % _line(main, pod))
	_aim(main, pod_pos, 40.0)
	await tree.create_timer(1.0).timeout
	await _shot(main, "01_pod_laid_out")
	# The dome is quick with a crew of six: catch its builder staging it
	# before the shiftpod's slower two-person seating.
	_aim(main, dome_pos, 45.0)
	var dome_mid := await _until(tree, 300.0, func() -> bool:
		var ds := AssemblyBuildSite.site_for(main, dome)
		var staged_now := ds != null and ds.get_node_or_null("Staged") != null and float(ds.get("_assembled_t")) > 0.15
		return staged_now or not _packed(main, dome))
	_ok(dome_mid, "dome staged by its builder — %s" % _line(main, dome))
	_aim(main, dome_pos, 45.0)
	await tree.create_timer(1.0).timeout
	await _shot(main, "03_dome_half")
	_aim(main, pod_pos, 40.0)
	var seating := await _until(tree, 300.0, func() -> bool:
		var ss := AssemblyBuildSite.site_for(main, pod)
		var mid_way := ss != null and float(ss.get("_assembled_t")) > 0.2
		return mid_way or not _packed(main, pod))
	_ok(seating, "shiftpod parts going up (or already up) — %s" % _line(main, pod))
	_aim(main, pod_pos, 40.0)
	await tree.create_timer(1.0).timeout
	await _shot(main, "02_pod_seating")
	var done := await _until(tree, 600.0, func() -> bool: return not bool(sd.status().get("active", false)))
	_ok(done, "all three built: %s" % str(sd.status().get("line", "")))
	await tree.create_timer(3.0).timeout
	_aim(main, (pod_pos + dome_pos) * 0.5, 55.0)
	await tree.create_timer(1.0).timeout
	await _shot(main, "04_all_up")
	main.set("time_scale", 0.001)
	return {"ok": _fails.is_empty(), "failures": _fails}
