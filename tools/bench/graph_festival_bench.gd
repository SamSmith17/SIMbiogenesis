extends RefCounted

## Graph view at FESTIVAL SCALE (plans/GRAPH_SYSTEMS_UX_PLAN.md Phase 6): the
## Walton world's graph open at 60x in four views, every F3 section sampled.
##   tools\harness.ps1 -World walton -RunScript res://tools/bench/graph_festival_bench.gd -Timeout 900
## Views: the root zoomed out (every camp a tile), the root zoomed in on one
## corner (most cards off screen: culling), Site Plan at the root with every
## person drawn, and inside one camp. Prints `gfbench …` lines; per view the
## frame median / fps, and `gv_draw_all` PER REDRAW (avg ÷ calls) — the
## canvas does not redraw every frame, so the per-frame average reads low.
## GFBENCH_SPEED=<multiple> (default 60).

const FP := preload("res://tools/bench/first_person_bench.gd")
const GV := preload("res://tools/bench/graph_view_bench.gd")
const SETTLE_S := 2.5


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	await tree.process_frame
	var pm: Node = main.get_node_or_null("/root/PerfMonitor")
	var sgv: Node = ServiceLocator.graph()
	if pm == null or sgv == null:
		return {"ok": false, "why": "no PerfMonitor / graph view"}
	var fp: RefCounted = FP.new()
	var gv: RefCounted = GV.new()
	if OS.get_environment("GFBENCH_FESTIVAL") == "1" and main.has_method("open_festival_mode"):
		# The whole festival's people: the sandbox's population target is a
		# test value (60); 0 = every camp's natural headcount.
		var fm: Object = main.call("open_festival_mode")
		await fp._wait(tree, 4.0)
		fm.call("set_target_people", int(OS.get_environment("GFBENCH_PEOPLE")) if not OS.get_environment("GFBENCH_PEOPLE").is_empty() else 0)
		await fp._wait(tree, 10.0)
		var sv: Variant = main.get("settlement_view")
		if sv is Object and is_instance_valid(sv) and (sv as Object).has_method("close"):
			(sv as Object).call("close")
		await fp._wait(tree, 1.0)
	var speed := float(OS.get_environment("GFBENCH_SPEED")) if not OS.get_environment("GFBENCH_SPEED").is_empty() else 60.0
	sgv.call("open_graph_view")
	await fp._wait(tree, 1.0)
	sgv.call("_on_mode_chip_pressed", GraphSiteLayout.VIEW_FREEFORM)
	sgv.call("_jump_to_scope_index", 0)
	await fp._wait(tree, 1.5)
	var model: GraphModel = sgv.get("model")
	var canvas: Control = sgv.get("_graph_canvas")
	var dots: Array = []
	var br: Object = sgv.get("_npc_population")
	if br != null and br.has_method("agent_dots"):
		dots = br.call("agent_dots")
	var camps: Array = sgv.call("festival_camps")
	if br != null:
		var away: Variant = br.call("away_camps") if br.has_method("away_camps") else []
		print("gfbench: away camps %d · cohorts %d · engines %d" % [(away as Dictionary).size() if away is Dictionary else -1,
			(br.get("_cohorts") as Dictionary).size(), (br.get("_engines") as Dictionary).size()])
	print("gfbench: %d items · %d wires · %d camps · %d people · window %s · %sx" % [model.items.size(),
		model.connections.size(), camps.size(), dots.size(), str(DisplayServer.window_get_size()), str(speed)])
	pm.call("set_enabled", true)
	main.set("time_scale", speed / 3600.0)
	var out := {}
	# 1. root, everything framed
	var root_ids: Array = []
	for it in model.get_items_in_scope("root"):
		root_ids.append(str((it as Dictionary).get("id", "")))
	canvas.call("stop_fly")
	canvas.call("fit_items_to_view", root_ids, 0.05)
	out["root_fit"] = await _view(tree, fp, gv, pm, canvas, "root_fit")
	# 2. root zoomed in on one camp (most cards off screen)
	if not camps.is_empty():
		canvas.call("stop_fly")
		canvas.call("fit_items_to_view", [str((camps[0] as Dictionary).get("id", ""))], 0.2)
		out["root_zoom"] = await _view(tree, fp, gv, pm, canvas, "root_zoom")
	# 3. Site Plan at the root with every person
	sgv.call("_on_mode_chip_pressed", GraphSiteLayout.VIEW_SITE)
	await fp._wait(tree, 2.0)
	canvas.call("stop_fly")
	canvas.call("frame_site_items", root_ids)
	out["site"] = await _view(tree, fp, gv, pm, canvas, "site")
	if not camps.is_empty():
		canvas.call("stop_fly")
		canvas.call("frame_site_items", [str((camps[0] as Dictionary).get("id", ""))], 60.0)
		out["site_zoom"] = await _view(tree, fp, gv, pm, canvas, "site_zoom")
		canvas.call("stop_fly")
		canvas.call("frame_site_items", root_ids)
		await fp._wait(tree, 1.0)
	# Where Site Plan's per-point time goes: the projection key across
	# frames, one projection, one ground lookup.
	var svc: Object = sgv.get("_soi_preview")
	var keys: Dictionary = {}
	for _f in 240:
		await tree.process_frame
		keys[int(svc.call("projection_key"))] = true
	var nr: Object = canvas.get("_npc_site_renderer")
	var marks: Array = (canvas.get("npc_spaces_provider") as Callable).call()
	var nverts := 0
	var nmax := 0
	for m in marks:
		var pn := ((m as Dictionary).get("poly", PackedVector2Array()) as PackedVector2Array).size()
		nverts += pn
		nmax = maxi(nmax, pn)
	var td := Time.get_ticks_usec()
	for _r in 5:
		for m in marks:
			for wp in ((m as Dictionary).get("poly", PackedVector2Array()) as PackedVector2Array):
				nr.call("project", wp)
	print("gfbench site probe: %d spaces · %d outline vertices (max %d) · projecting them all %.2f ms" % [marks.size(), nverts, nmax,
		float(Time.get_ticks_usec() - td) / 5000.0])
	var t0 := Time.get_ticks_usec()
	for i in 500:
		svc.call("world_to_canvas", Vector3(float(i), 0.0, 0.0))
	var t1 := Time.get_ticks_usec()
	for i in 500:
		nr.call("project", Vector2(float(i) * 0.37, 3.0))
	var t2 := Time.get_ticks_usec()
	var soi: Node = main.get_node_or_null("/root/SoiService")
	for i in 500:
		soi.call("ground_y_at", float(i) * 0.53, 7.0)
	var t3 := Time.get_ticks_usec()
	print("gfbench site probe: %d projection keys over 240 frames · world_to_canvas %.1f µs · project (uncached xz) %.1f µs · ground_y_at %.1f µs" % [
		keys.size(), float(t1 - t0) / 500.0, float(t2 - t1) / 500.0, float(t3 - t2) / 500.0])
	# 4. inside one camp (freeform)
	sgv.call("_on_mode_chip_pressed", GraphSiteLayout.VIEW_FREEFORM)
	await fp._wait(tree, 1.0)
	if not camps.is_empty():
		sgv.call("focus_graph_item", str((camps[0] as Dictionary).get("id", "")), true)
		await fp._wait(tree, 2.5)
		out["camp"] = await _view(tree, fp, gv, pm, canvas, "camp")
	main.set("time_scale", 0.0)
	# Tidy at the festival root (synchronous): its cost in one go.
	var drv: Object = sgv.call("_ensure_layout_driver")
	if drv != null:
		sgv.call("_jump_to_scope_index", 0)
		await fp._wait(tree, 0.5)
		var t_tidy := Time.get_ticks_usec()
		var worst := 0.0
		var t_call := Time.get_ticks_usec()
		sgv.call("tidy_layout", true, true)
		worst = float(Time.get_ticks_usec() - t_call) / 1000.0
		var frames := 0
		while bool(drv.call("is_tidying")) and frames < 600:
			var tf := Time.get_ticks_usec()
			await tree.process_frame
			worst = maxf(worst, float(Time.get_ticks_usec() - tf) / 1000.0)
			frames += 1
		print("gfbench tidy: root (%d items) settled over %d frames · %.0f ms in all · worst frame %.1f ms" % [
			(drv.call("scope_items", "root") as Array).size(), frames,
			float(Time.get_ticks_usec() - t_tidy) / 1000.0, worst])
	pm.call("set_enabled", false)
	return {"ok": true, "views": out}


func _view(tree: SceneTree, fp: RefCounted, gv: RefCounted, pm: Node, canvas: Control, label: String) -> Dictionary:
	var only := OS.get_environment("GFBENCH_ONLY")
	if not only.is_empty() and not (label in only.split(",")):
		return {}
	canvas.queue_redraw()
	await fp._wait(tree, SETTLE_S)
	var dir := "user://screenshots/graph_festival_bench"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	canvas.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [dir, label])
	var slow := {}
	canvas.set("draw_profile", {})
	canvas.set("draw_profile_on", true)
	var s: Dictionary = await gv._sample(fp, tree, pm, slow)
	canvas.set("draw_profile_on", false)
	var prof: Dictionary = canvas.get("draw_profile")
	var keys: Array = prof.keys().filter(func(k) -> bool: return not str(k).ends_with("#n"))
	keys.sort_custom(func(a, b) -> bool: return int(prof[a]) > int(prof[b]))
	for k in keys.slice(0, 6):
		var n := maxi(1, int(prof.get(str(k) + "#n", 1)))
		print("gfbench %s: cards %-28s %.0f µs per card · %d drawn" % [label, str(k), float(prof[k]) / float(n), n])
	gv._print(fp, "gf " + label, s)
	var rows: Dictionary = s["rows"]
	var da: Dictionary = rows.get("gv_draw_all", {})
	var per := float(da.get("avg", 0.0)) / maxf(float(da.get("calls", 0.0)), 1e-6)
	var npc_r: Object = canvas.get("_npc_site_renderer")
	print("gfbench %s: zoom %.3f · draw %.2f ms per redraw · %.1f redraws/frame · fps %.0f · frame %.1f ms · cards %d · groups %d · spaces %d · ring misses %d · agents %d · px/m %.2f" % [label,
		float(canvas.get("_zoom")), per, float(da.get("calls", 0.0)), float(s["fps"]), float(s["frame_ms"]),
		int(canvas.get("cards_drawn")), int(npc_r.get("groups_drawn")) if npc_r != null else -1, int(npc_r.get("spaces_seen")) if npc_r != null else -1,
		int(npc_r.get("ring_misses")) if npc_r != null else -1, int(npc_r.get("agents_drawn")) if npc_r != null else -1,
		GraphSiteLayout.px_per_m(float(canvas.get("_zoom")))])
	gv._print_slow("gf " + label, slow)
	return {"fps": float(s["fps"]), "frame_ms": float(s["frame_ms"]), "draw_ms": per}
