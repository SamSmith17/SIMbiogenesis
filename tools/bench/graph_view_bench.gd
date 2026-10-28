extends RefCounted

## GRAPH-OPEN frame cost bench: the world's own graph open in the freeform
## lens, every F3 section sampled at 1x, 60x, 450x, 1440x and 7200x (the
## timeline's Max) and paused. `flow_step_bench` measures the graph CLOSED and
## `graph_draw_bench` a synthetic graph's draw; this is what the player pays
## for with their real graph on screen while the clock runs fast.
## Dry run only, sandbox:
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/bench/graph_view_bench.gd
## Prints `gvbench …` lines. GVBENCH_LENS=site|elevation|globe for another lens.

const FP := preload("res://tools/bench/first_person_bench.gd")
const SAMPLE_S := 6.0
## A frame this long is a stutter worth naming.
const SLOW_MS := 30.0
const SETTLE_S := 2.5
const SPEEDS := [["1x", 1.0], ["60x", 60.0], ["450x", 450.0], ["1440x", 1440.0], ["7200x", 7200.0],
	["paused", 0.0]]


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	await tree.process_frame
	var pm: Node = main.get_node_or_null("/root/PerfMonitor")
	var sgv: Node = main.find_child("SystemGraphView", true, false)
	if pm == null or sgv == null:
		return {"ok": false, "why": "no PerfMonitor / SystemGraphView"}
	var fp: RefCounted = FP.new()
	sgv.call("open_graph_view")
	await fp._wait(tree, 1.0)
	var lens := OS.get_environment("GVBENCH_LENS")
	sgv.call("_apply_graph_view_mode", lens if not lens.is_empty() else GraphSiteLayout.VIEW_FREEFORM)
	await fp._wait(tree, 3.0)
	var model: GraphModel = sgv.get("model")
	print("gvbench: lens %s · %d items · %d wires · window %s" % [str(sgv.get("_graph_view_mode")),
		model.items.size(), model.connections.size(), str(DisplayServer.window_get_size())])
	pm.call("set_enabled", true)
	var out := {}
	for sp in SPEEDS:
		main.set("time_scale", float(sp[1]) / 3600.0)
		await fp._wait(tree, SETTLE_S)
		var slow := {}
		var svc: Object = sgv.get("_soi_preview")
		var fr0 := int(svc.get("frames_rendered")) if svc != null else -1
		var s: Dictionary = await _sample(fp, tree, pm, slow)
		_print(fp, str(sp[0]), s)
		var rr: Dictionary = s["render"]
		print("gvbench %s: render CPU %.1f ms · GPU %.1f ms · preview captures %.1f/s (live %s)" % [str(sp[0]),
			float(rr.get("render_cpu_ms", 0.0)), float(rr.get("render_gpu_ms", 0.0)),
			float(int(svc.get("frames_rendered")) - fr0) / SAMPLE_S if svc != null else -1.0,
			str(svc.get("_preview_live")) if svc != null else "?"])
		_print_slow(str(sp[0]), slow)
		out[str(sp[0])] = fp._compact(s)
	main.set("time_scale", 0.0)
	if pm.has_method("dump_processing_histogram"):
		pm.call("dump_processing_histogram")
	pm.call("set_enabled", false)
	return {"ok": true, "speeds": out}


func _print(fp: RefCounted, label: String, s: Dictionary) -> void:
	var r: Dictionary = s["render"]
	print("gvbench %s: frame %.1f ms (median) / %.1f ms (2 s peak) · %.0f fps · sections sum %.2f ms · _process %.1f ms · draw calls %d" % [
		label, float(s["frame_ms"]), float(s["frame_peak"]), float(s["fps"]),
		float(s["sections_total"]), float(r.get("process_ms", 0.0)), int(r.get("draw_calls", 0))])
	var rows: Dictionary = s["rows"]
	var keys: Array = rows.keys().filter(func(k) -> bool:
		return float((rows[k] as Dictionary)["avg"]) >= 0.05 or float((rows[k] as Dictionary)["peak"]) >= 1.0)
	keys.sort_custom(func(a, b) -> bool:
		return float((rows[a] as Dictionary)["avg"]) > float((rows[b] as Dictionary)["avg"]))
	for k in keys:
		var rr: Dictionary = rows[k]
		print("gvbench %s: %-18s avg %6.2f ms · peak %6.2f ms · %.1f calls/frame" % [
			label, str(k), float(rr["avg"]), float(rr["peak"]), float(rr["calls"])])


## first_person_bench's sampler over SAMPLE_S here.
func _sample(fp: RefCounted, tree: SceneTree, pm: Node, slow: Dictionary) -> Dictionary:
	var acc: Dictionary = {}
	var peak: Dictionary = {}
	var calls: Dictionary = {}
	var frames: Array = []
	var fps: Array = []
	var frame_peak := 0.0
	var render: Dictionary = {}
	var n := int(SAMPLE_S / 0.1)
	for i in n:
		# Every frame in between: a frame over SLOW_MS has its sections summed
		# into `slow` (what the spikes spend), from PerfMonitor.last_frame.
		var t_end := Time.get_ticks_msec() + 100
		var t_prev := Time.get_ticks_usec()
		while Time.get_ticks_msec() < t_end:
			await tree.process_frame
			var now_us := Time.get_ticks_usec()
			var dt_ms := float(now_us - t_prev) / 1000.0
			t_prev = now_us
			slow["frames"] = int(slow.get("frames", 0)) + 1
			if dt_ms >= SLOW_MS:
				slow["slow"] = int(slow.get("slow", 0)) + 1
				slow["slow_ms"] = float(slow.get("slow_ms", 0.0)) + dt_ms
				var lf: Dictionary = pm.get("last_frame")
				var secs: Dictionary = slow.get("secs", {})
				for k in lf:
					secs[k] = float(secs.get(k, 0.0)) + float(lf[k])
				slow["secs"] = secs
		var snap: Dictionary = pm.call("snapshot")
		var sec: Dictionary = snap.get("sections_ms", {}) as Dictionary
		var pk: Dictionary = snap.get("sections_peak_ms", {}) as Dictionary
		var cl: Dictionary = snap.get("calls", {}) as Dictionary
		for k in sec.keys():
			acc[k] = float(acc.get(k, 0.0)) + float(sec[k])
			peak[k] = maxf(float(peak.get(k, 0.0)), float(pk.get(k, 0.0)))
			calls[k] = float(calls.get(k, 0.0)) + float(cl.get(k, 0.0))
		frames.append(float(snap.get("frame_ms", 0.0)))
		fps.append(float(snap.get("fps", 0.0)))
		frame_peak = maxf(frame_peak, float(snap.get("frame_ms_peak", 0.0)))
		var r: Dictionary = snap.get("render", {}) as Dictionary
		for k2 in r.keys():
			render[k2] = float(render.get(k2, 0.0)) + float(r[k2])
	frames.sort()
	fps.sort()
	var rows: Dictionary = {}
	var total := 0.0
	for key in acc.keys():
		var avg := float(acc[key]) / float(n)
		total += avg
		rows[key] = {"avg": avg, "peak": float(peak[key]), "calls": float(calls[key]) / float(n)}
	for k3 in render.keys():
		render[k3] = float(render[k3]) / float(n)
	return {"rows": rows, "frame_ms": frames[frames.size() / 2], "frame_peak": frame_peak,
		"fps": fps[fps.size() / 2], "sections_total": total, "render": render}


func _print_slow(label: String, slow: Dictionary) -> void:
	var n := int(slow.get("slow", 0))
	print("gvbench %s: %d of %d frames over %.0f ms (avg %.1f ms)" % [label, n, int(slow.get("frames", 0)),
		SLOW_MS, float(slow.get("slow_ms", 0.0)) / maxf(float(n), 1.0)])
	if n == 0:
		return
	var secs: Dictionary = slow.get("secs", {})
	var keys := secs.keys()
	keys.sort_custom(func(a, b) -> bool: return float(secs[a]) > float(secs[b]))
	for k in keys.slice(0, 14):
		if float(secs[k]) / float(n) >= 0.3:
			print("gvbench %s:   slow frame spends %-20s %6.2f ms" % [label, str(k), float(secs[k]) / float(n)])
