extends RefCounted

## FIRST-PERSON frame cost bench: the graph CLOSED, the player standing where
## the world was saved, every F3 section sampled at 1x, at 60x and paused.
##
## `flow_step_bench` measures the simulation's share of the frame; this one
## measures everything else the player pays for in first person — the hazard
## VFX and ground fog (`main_fx`), the planets push, the season uniforms
## (`terrain_season`), the stream beads, every placed prop runtime
## (`prop_ticks`), the placed lights, the crosshair ladder (`interact_focus`),
## SolarUI / TimelineUI / HudLayout — sections that were not instrumented
## before 2026-10-18, so the F3 HUD could not say where a first-person frame
## went. It also prints the renderer's CPU / GPU split and draw calls, and the
## F4 processing-node histogram once, so a per-instance callback that
## dominates shows up by script name.
##
## Dry run only, sandbox (either world):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/bench/first_person_bench.gd
##   tools\harness.ps1 -World walton   -RunScript res://tools/bench/first_person_bench.gd
## Prints `fpbench …` lines; no shots dir needed. The clock is parked at 12:00
## of the saved date first so lighting and shadows are comparable run to run.

const SAMPLE_S := 10.0
const SAMPLE_DT := 0.1
const SETTLE_S := 3.0
const PARK_HOUR := 12.0
## Sections printed first, in this order; everything else that cost ≥ 0.05 ms
## follows sorted by average cost.
const SECTIONS: Array[String] = [
	"world_env", "main_fx", "planets", "terrain_tick", "terrain_season",
	"stream_tracers", "prop_ticks", "placed_lights", "interact_focus",
	"solar_ui", "timeline_ui", "hud_layout", "conduits_3d",
	"flow_engine", "npc_population", "npc_host", "crowd_render", "camp_power",
	"gv_dc_throttle", "gv_faults", "gv_placeholder", "gv_pond_push", "drone",
]


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	await tree.process_frame
	var pm: Node = main.get_node_or_null("/root/PerfMonitor")
	if pm == null:
		return {"ok": false, "why": "no PerfMonitor"}
	var sgv: Node = main.find_child("SystemGraphView", true, false)
	if sgv != null and bool(sgv.get("visible")) and sgv.has_method("close_graph_view"):
		sgv.call("close_graph_view")
	# Park the clock at noon of the saved date (not persisted — sandbox).
	var clock: Object = main.get("clock")
	if clock != null:
		clock.set("day_time", PARK_HOUR)
	var cam := main.get_viewport().get_camera_3d()
	print("fpbench: graph closed, abs_h %.2f, camera %s, %s" % [
		float(main.call("get_absolute_hours")),
		str(cam.global_position.snapped(Vector3(0.1, 0.1, 0.1))) if cam != null else "none",
		str(DisplayServer.window_get_size())])
	# The park moved the clock by hours: the first ambient tick is a multi-hour
	# catch-up step. Let it pass BEFORE the monitor starts, or its spike is the
	# whole 1x "peak" column (185 ms of flow_engine on Walton was the park).
	await _wait(tree, 5.0)
	_print_bakes("start", sgv)
	pm.call("set_enabled", true)

	main.set("time_scale", 1.0 / 3600.0)
	await _wait(tree, SETTLE_S)
	var at_1x := await _sample(tree, pm)
	_print_table("1x", at_1x)

	main.set("time_scale", 60.0 / 3600.0)
	await _wait(tree, SETTLE_S)
	var at_60x := await _sample(tree, pm)
	_print_table("60x", at_60x)

	main.set("time_scale", 0.0)
	await _wait(tree, SETTLE_S)
	var paused := await _sample(tree, pm)
	_print_table("paused", paused)

	_print_bakes("end", sgv)
	# One histogram of what is actually running per frame, by script.
	if pm.has_method("dump_processing_histogram"):
		pm.call("dump_processing_histogram")
	pm.call("set_enabled", false)
	return {"ok": true, "at_1x": _compact(at_1x), "at_60x": _compact(at_60x),
		"paused": _compact(paused)}


## The two long-running bakes that read as a per-frame cost while they run:
## the nav grid (0.75 m cells over the population region) and the crowd
## renderer's height raster (2 m cells over the same region + 80 m). A
## progress that does not reach 1.0 between "start" and "end" is a bake still
## in flight; one that goes BACK is a restart (a fingerprint that moves).
func _print_bakes(label: String, sgv: Node) -> void:
	if sgv == null:
		return
	var bridge: Object = sgv.get("_npc_population")
	if bridge != null:
		var grid: Object = bridge.get("_nav_grid")
		if grid != null and grid.has_method("bake_progress"):
			print("fpbench bakes %s: nav grid %d x %d cells, progress %.3f%s" % [label,
				int(grid.get("nx")), int(grid.get("nz")), float(grid.call("bake_progress")),
				" (ready)" if bool(grid.call("is_ready")) else ""])
		else:
			print("fpbench bakes %s: no nav grid" % label)
	var cr: Object = sgv.get("_crowd_renderer")
	if cr != null and is_instance_valid(cr) and cr.has_method("height_raster_ready"):
		print("fpbench bakes %s: crowd height raster %d x %d, cursor %d, %s" % [label,
			int(cr.get("_h_nx")), int(cr.get("_h_nz")), int(cr.get("_h_cursor")),
			"ready" if bool(cr.call("height_raster_ready")) else "baking"])


## Smoothed per-frame ms per section (what the F3 HUD shows), the worst 2 s
## peak and the call count, plus the frame / render numbers, over SAMPLE_S.
func _sample(tree: SceneTree, pm: Node) -> Dictionary:
	var acc: Dictionary = {}
	var peak: Dictionary = {}
	var calls: Dictionary = {}
	var frames: Array = []
	var fps: Array = []
	var frame_peak := 0.0
	var render: Dictionary = {}
	var n := int(SAMPLE_S / SAMPLE_DT)
	for i in n:
		await _wait(tree, SAMPLE_DT)
		var snap: Dictionary = pm.call("snapshot")
		var sec: Dictionary = snap.get("sections_ms", {}) as Dictionary
		var pk: Dictionary = snap.get("sections_peak_ms", {}) as Dictionary
		var cl: Dictionary = snap.get("calls", {}) as Dictionary
		for s in sec.keys():
			var key := str(s)
			acc[key] = float(acc.get(key, 0.0)) + float(sec[s])
			peak[key] = maxf(float(peak.get(key, 0.0)), float(pk.get(s, 0.0)))
			calls[key] = float(calls.get(key, 0.0)) + float(cl.get(s, 0.0))
		frames.append(float(snap.get("frame_ms", 0.0)))
		fps.append(float(snap.get("fps", 0.0)))
		frame_peak = maxf(frame_peak, float(snap.get("frame_ms_peak", 0.0)))
		var r: Dictionary = snap.get("render", {}) as Dictionary
		for k in r.keys():
			render[k] = float(render.get(k, 0.0)) + float(r[k])
	frames.sort()
	fps.sort()
	var rows: Dictionary = {}
	var total := 0.0
	for key in acc.keys():
		var avg := float(acc[key]) / float(n)
		total += avg
		rows[key] = {"avg": avg, "peak": float(peak[key]), "calls": float(calls[key]) / float(n)}
	for k in render.keys():
		render[k] = float(render[k]) / float(n)
	return {"rows": rows, "frame_ms": frames[frames.size() / 2], "frame_peak": frame_peak,
		"fps": fps[fps.size() / 2], "sections_total": total, "render": render}


func _print_table(label: String, s: Dictionary) -> void:
	var r: Dictionary = s["render"]
	print("fpbench %s: frame %.1f ms (median) / %.1f ms (2 s peak) · %.0f fps · sections sum %.2f ms" % [
		label, float(s["frame_ms"]), float(s["frame_peak"]), float(s["fps"]),
		float(s["sections_total"])])
	print("fpbench %s: render CPU %.1f ms · GPU %.1f ms · _process %.1f ms · %d draw calls · %d nodes" % [
		label, float(r.get("render_cpu_ms", 0.0)), float(r.get("render_gpu_ms", 0.0)),
		float(r.get("process_ms", 0.0)), int(r.get("draw_calls", 0)), int(r.get("scene_nodes", 0))])
	var rows: Dictionary = s["rows"]
	var listed: Dictionary = {}
	for key in SECTIONS:
		if rows.has(key):
			_print_row(label, key, rows[key])
			listed[key] = true
	var rest: Array = []
	for key in rows.keys():
		if not listed.has(key) and float((rows[key] as Dictionary)["avg"]) >= 0.05:
			rest.append(key)
	rest.sort_custom(func(a, b) -> bool:
		return float((rows[a] as Dictionary)["avg"]) > float((rows[b] as Dictionary)["avg"]))
	for key in rest:
		_print_row(label, str(key), rows[key])


func _print_row(label: String, key: String, r: Dictionary) -> void:
	print("fpbench %s: %-16s avg %6.2f ms · peak %6.2f ms · %.1f calls/frame" % [
		label, key, float(r["avg"]), float(r["peak"]), float(r["calls"])])


func _compact(s: Dictionary) -> Dictionary:
	var out := {"frame_ms": s["frame_ms"], "frame_peak": s["frame_peak"], "fps": s["fps"],
		"sections_total": s["sections_total"], "render": s["render"], "sections": {}}
	var rows: Dictionary = s["rows"]
	for key in rows.keys():
		out["sections"][key] = snappedf(float((rows[key] as Dictionary)["avg"]), 0.001)
	return out


func _wait(tree: SceneTree, s: float) -> void:
	await tree.create_timer(s, true, false, true).timeout
