extends RefCounted

## Sandbox: the frame a ground-reusing nav re-bake starts in (what placing a
## prop, repainting a camp or tagging a space does on a big grid). Waits for
## the people's nav grid to be ready, makes its fingerprint stale with the
## ground unchanged, and prints the worst npc_svc_nav / npc_nav_bake / whole
## frame over the next 240 frames, three times.
##   tools\harness.ps1 -World walton -RunScript res://tools/diag/nav_reuse_spike_probe.gd -Timeout 900

func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var sgv: Node = main.find_child("SystemGraphView", true, false)
	if sgv == null:
		return {"ok": false, "why": "no SystemGraphView"}
	var bridge: Object = sgv.call("npc_population_bridge")
	if bridge == null:
		return {"ok": false, "why": "no population bridge"}
	var pm: Node = main.get_node_or_null("/root/PerfMonitor")
	if pm != null:
		pm.call("set_enabled", true)
	var grid: Object = null
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 240000:
		await tree.process_frame
		grid = bridge.get("_nav_grid")
		if grid != null and bool(grid.call("is_ready")):
			break
	if grid == null or not bool(grid.call("is_ready")):
		return {"ok": false, "why": "nav grid never ready"}
	print("navspike: grid %d x %d x %d ready" % [int(grid.get("nx")), int(grid.get("nz")), int(grid.get("layers"))])
	var worst_all := 0.0
	for rep in 3:
		grid = bridge.get("_nav_grid")
		grid.set("_fingerprint", "stale_%d" % rep)
		bridge.set("_nav_fp", "stale_%d" % rep)
		var w_nav := 0.0
		var w_bake := 0.0
		var w_frame := 0.0
		for _i in 240:
			await tree.process_frame
			var lf: Dictionary = pm.get("last_frame") if pm != null else {}
			w_nav = maxf(w_nav, float(lf.get("npc_svc_nav", 0.0)))
			w_bake = maxf(w_bake, float(lf.get("npc_nav_bake", 0.0)))
			w_frame = maxf(w_frame, float(pm.get("last_frame_ms")) if pm != null else 0.0)
		var g2: Object = bridge.get("_nav_grid")
		print("navspike rep %d: worst npc_svc_nav %.2f ms, npc_nav_bake %.2f ms, frame %.1f ms; reused ground %s, ready %s" % [
			rep, w_nav, w_bake, w_frame, str(g2.get("reused_ground")), str(g2.call("is_ready"))])
		worst_all = maxf(worst_all, w_nav)
	print("navspike WORST npc_svc_nav %.2f ms" % worst_all)
	if pm != null:
		pm.call("set_enabled", false)
	return {"ok": true}
