extends RefCounted

## Sandbox, read-only: which code lands in the SLOW frames. Graph closed, the
## clock parked at noon, then 1x and 60x for SAMPLE_S each. Every frame's
## length and its F3 sections (PerfMonitor.last_frame) are recorded; prints
## the frame-time spread and, per section, how often and how much it shows up
## in frames over SLOW_MS, plus the twelve slowest frames spelled out.
##   tools\harness.ps1 -World walton -RunScript res://tools/bench/frame_spike_bench.gd
## Sections nest (gv_process holds gv_ambient, which holds flow_engine and
## npc_population...), so read the leaves.

const SAMPLE_S := 20.0
const SETTLE_S := 3.0
const SLOW_MS := 25.0
const SPEEDS := [1.0, 60.0]


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	await tree.process_frame
	var pm: Node = main.get_node_or_null("/root/PerfMonitor")
	if pm == null:
		return {"ok": false, "why": "no PerfMonitor"}
	var sgv: Node = main.find_child("SystemGraphView", true, false)
	if sgv != null and bool(sgv.get("visible")) and sgv.has_method("close_graph_view"):
		sgv.call("close_graph_view")
	var clock: Object = main.get("clock")
	if clock != null:
		clock.set("day_time", 12.0)
	await _wait(tree, 6.0)
	if OS.get_environment("SPIKE_PACER") == "0":
		FramePacer.enabled = false
	var probe_a: Node = load("res://tools/bench/frame_phase_probe.gd").new()
	var probe_b: Node = load("res://tools/bench/frame_phase_probe.gd").new()
	probe_b.set("last", true)
	main.add_child(probe_a)
	main.add_child(probe_b)
	_probe = probe_a
	pm.call("set_enabled", true)
	RenderingServer.viewport_set_measure_render_time(tree.root.get_viewport_rid(), true)
	_print_nav(sgv, "start")
	var only := OS.get_environment("SPIKE_SPEEDS")
	var speeds: Array = SPEEDS
	if not only.is_empty():
		speeds = []
		for t in only.split(","):
			speeds.append(float(t))
	for sp in speeds:
		main.set("time_scale", float(sp) / 3600.0)
		await _wait(tree, SETTLE_S)
		await _sample(tree, pm, "%dx" % int(sp))
		_print_nav(sgv, "after %dx" % int(sp))
	pm.call("set_enabled", false)
	return {"ok": true}


var _probe: Node = null


func _sample(tree: SceneTree, pm: Node, label: String) -> void:
	var frames: Array = []
	FramePacer.waits = 0
	FramePacer.forced = 0
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(SAMPLE_S * 1000.0):
		await tree.process_frame
		var secs := (pm.get("last_frame") as Dictionary).duplicate()
		secs["~process"] = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		secs["~physics"] = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		var rid := tree.root.get_viewport_rid()
		secs["~render_cpu"] = RenderingServer.viewport_get_measured_render_time_cpu(rid) + RenderingServer.get_frame_setup_time_cpu()
		secs["~render_gpu"] = RenderingServer.viewport_get_measured_render_time_gpu(rid)
		if _probe != null:
			var ph: Dictionary = _probe.call("phases")
			for k in ph:
				secs["@" + str(k)] = float(ph[k])
		frames.append([float(pm.get("last_frame_ms")), secs])
	var times: Array = []
	for f in frames:
		times.append(float(f[0]))
	times.sort()
	var n := times.size()
	var over33 := 0
	var over50 := 0
	for t in times:
		if float(t) > 33.3:
			over33 += 1
		if float(t) > 50.0:
			over50 += 1
	print("spike %s: %d frames, p50 %.1f p90 %.1f p99 %.1f max %.1f ms; %d over 33 ms, %d over 50 ms" % [
		label, n, float(times[n / 2]), float(times[int(n * 0.9)]), float(times[int(n * 0.99)]),
		float(times[n - 1]), over33, over50])
	print("spike %s: frame pacer %s, %d waits, %d ran late anyway" % [label,
		"on" if FramePacer.enabled else "off", FramePacer.waits, FramePacer.forced])
	# Per section: average every frame, and in slow frames.
	var all_sum := {}
	var slow_sum := {}
	var slow_hits := {}
	var slow_max := {}
	var slow_n := 0
	for f in frames:
		var secs: Dictionary = f[1]
		var slow := float(f[0]) > SLOW_MS
		if slow:
			slow_n += 1
		for k in secs:
			var ms := float(secs[k])
			all_sum[k] = float(all_sum.get(k, 0.0)) + ms
			if slow:
				slow_sum[k] = float(slow_sum.get(k, 0.0)) + ms
				if ms >= 1.0:
					slow_hits[k] = int(slow_hits.get(k, 0)) + 1
				slow_max[k] = maxf(float(slow_max.get(k, 0.0)), ms)
	var keys := slow_sum.keys()
	keys.sort_custom(func(a, b) -> bool: return float(slow_sum[a]) > float(slow_sum[b]))
	print("spike %s: %d frames over %.0f ms; sections by time spent in them:" % [label, slow_n, SLOW_MS])
	for k in keys.slice(0, 24):
		print("spike %s:   %-22s in slow frames %7.1f ms total, >=1 ms in %4d, max %6.1f  | every frame avg %.2f" % [
			label, str(k), float(slow_sum[k]), int(slow_hits.get(k, 0)), float(slow_max[k]),
			float(all_sum.get(k, 0.0)) / maxf(float(n), 1.0)])
	# The slowest frames, spelled out.
	var idx: Array = range(frames.size())
	idx.sort_custom(func(a, b) -> bool: return float(frames[a][0]) > float(frames[b][0]))
	for j in idx.slice(0, 12):
		var secs: Dictionary = frames[j][1]
		var ks := secs.keys()
		ks.sort_custom(func(a, b) -> bool: return float(secs[a]) > float(secs[b]))
		var parts: Array = []
		for k in ks.slice(0, 9):
			parts.append("%s %.1f" % [str(k), float(secs[k])])
		print("spike %s: frame %.1f ms = %s" % [label, float(frames[j][0]), ", ".join(parts)])


func _wait(tree: SceneTree, secs: float) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(secs * 1000.0):
		await tree.process_frame


func _print_nav(sgv: Node, label: String) -> void:
	if sgv == null:
		return
	var hf: Node = sgv.get_tree().root.find_child("HeightField", true, false)
	if hf != null:
		print("spike tiles %s: %d tiles waiting to rebuild" % [label,
			(hf.get("_rebuild_queue") as Array).size()])
	var bridge: Object = sgv.get("_npc_population")
	if bridge == null:
		return
	var grid: Object = bridge.get("_nav_grid")
	if grid != null and grid.has_method("bake_progress"):
		print("spike nav %s: %d x %d cells, progress %.3f%s, rebakes %s" % [label,
			int(grid.get("nx")), int(grid.get("nz")), float(grid.call("bake_progress")),
			" (ready)" if bool(grid.call("is_ready")) else "",
			str(bridge.get("_nav_rebakes")) if "_nav_rebakes" in bridge else "?"])
	var people := 0
	for e in (bridge.get("_engines") as Dictionary).values():
		people += (e.get("agents") as Array).size()
	print("spike people %s: %d full-tier in %d camps, %d light camps" % [label, people,
		(bridge.get("_engines") as Dictionary).size(), (bridge.get("_cohorts") as Dictionary).size()])
