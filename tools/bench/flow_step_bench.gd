extends RefCounted

## Graph-CLOSED simulation cost bench + the flow engine's accuracy pin.
##
## The user's complaint is first-person FPS with the 2D graph closed, so this
## measures exactly that regime on the real world: PerfMonitor's per-frame
## sections while the clock runs at 60x, then paused. The cascade sections
## added for this (gv_dc_throttle, gv_faults, gv_placeholder, gv_pond_push)
## were invisible on the F3 HUD before; `flow_engine` alone never was the whole
## cost.
##
## Then the ACCURACY PIN: a fixed 24 h of ResourceFlowEngine.render_step at
## 1-minute steps from a fixed clock, hashed over every tank level, every
## connection's flow and the hydro / habitat telemetry. Every live-sim
## optimization in the pre-render plan must leave this hash unchanged — print
## it before, print it after, compare. (The render loop also times the pure
## per-step engine cost, which the smoothed sections cannot show.)
##
## Dry run only, sandbox:
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/bench/flow_step_bench.gd
## Prints `flowbench …` lines; no shots dir needed.

const SECTIONS: Array[String] = [
	"flow_engine", "npc_population", "camp_power", "crowd_sim", "crowd_render",
	"gv_dcsync", "gv_dc_throttle", "gv_faults", "gv_placeholder", "gv_pond_push",
	"conduits_3d", "npc_nav_bake", "prop_ticks", "world_env",
]
const SAMPLE_S := 10.0
const SAMPLE_DT := 0.1
## The accuracy pin's clock: 2026-07-15 10:00 local, in absolute hours. Fixed
## so two runs of the sandbox hash the same day whatever the save's clock says.
const PIN_YEAR := 2026
const PIN_MONTH := 7
const PIN_DAY := 15
const PIN_HOUR := 10.0
const PIN_STEPS := 1440
const PIN_STEP_H := 1.0 / 60.0


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	await tree.process_frame
	var sgv: Node = main.find_child("SystemGraphView", true, false)
	var pm: Node = main.get_node_or_null("/root/PerfMonitor")
	if sgv == null or pm == null:
		return {"ok": false, "why": "no graph view / PerfMonitor"}
	var model: Object = sgv.get("model")
	var flow: Object = sgv.call("resource_flow_engine")
	if model == null or flow == null:
		return {"ok": false, "why": "no model / flow engine"}
	# Graph CLOSED is the regime under test.
	if bool(sgv.get("visible")) and sgv.has_method("close_graph_view"):
		sgv.call("close_graph_view")
	await _wait(tree, 0.5)
	var n_items: int = (model.get("items") as Array).size()
	var n_conns: int = (model.get("connections") as Array).size()
	print("flowbench: graph closed, %d items / %d connections, abs_h %.2f" % [
		n_items, n_conns, float(main.call("get_absolute_hours"))])

	pm.call("set_enabled", true)
	main.set("time_scale", 60.0 / 3600.0)
	await _wait(tree, 3.0)
	# user_rev must NOT move while only the simulation writes (the pre-render
	# cache is valid against it): any stray writer outside the sim-write
	# bracket shows up here as a non-zero delta with the graph closed.
	var rev0: Variant = model.get("user_rev")
	var running := await _sample(tree, pm)
	var rev1: Variant = model.get("user_rev")
	main.set("time_scale", 0.0)
	await _wait(tree, 2.0)
	var paused := await _sample(tree, pm)
	_print_table("running 60x", running)
	_print_table("paused", paused)
	if rev0 != null and rev1 != null:
		var drev := int(rev1) - int(rev0)
		print("flowbench user_rev: %d -> %d over %.0f s of sim-only writes (graph closed): %s" % [
			int(rev0), int(rev1), SAMPLE_S, "PASS" if drev == 0 else "FAIL (a non-sim writer moved it)"])

	# ── Accuracy pin: 24 h of render_step from a fixed clock, hashed. ──
	var was_susp := false
	if sgv.has_method("set_ambient_flow_suspended"):
		sgv.call("set_ambient_flow_suspended", true)
		was_susp = true
	var start_abs := _pin_start_abs(main)
	main.call("set_absolute_hours", start_abs)
	await tree.process_frame
	var was_suppress: bool = bool(sgv.get("_history_suppress"))
	var was_bulk: bool = bool(sgv.get("_sim_bulk_update"))
	sgv.set("_history_suppress", true)
	sgv.set("_sim_bulk_update", true)
	if flow.has_method("clear_timelines"):
		flow.call("clear_timelines")
	var t0 := Time.get_ticks_usec()
	var t := start_abs
	for i in PIN_STEPS:
		t += PIN_STEP_H
		flow.call("render_step", t, PIN_STEP_H, true)
	var dt_us := Time.get_ticks_usec() - t0
	var digest := _state_digest(model)
	sgv.set("_history_suppress", was_suppress)
	sgv.set("_sim_bulk_update", was_bulk)
	if sgv.has_method("_flush_sim_bulk_update"):
		sgv.call("_flush_sim_bulk_update")
	if was_susp:
		sgv.call("set_ambient_flow_suspended", false)
	var per_step_ms := dt_us / 1000.0 / float(PIN_STEPS)
	print("flowbench pin: %d render_steps (24 h @ 1 min) from abs_h %.2f in %.0f ms = %.3f ms/step" % [
		PIN_STEPS, start_abs, dt_us / 1000.0, per_step_ms])
	print("flowbench pin: state hash %s over %d values (tanks %d, conns %d, telemetry %d)" % [
		str(digest["hash"]), int(digest["n"]), int(digest["tanks"]), int(digest["conns"]),
		int(digest["telemetry"])])
	pm.call("set_enabled", false)
	return {"ok": true, "running": running, "paused": paused, "pin_hash": str(digest["hash"]),
		"pin_ms_per_step": per_step_ms, "items": n_items, "connections": n_conns}


## Smoothed per-frame ms (what the F3 HUD shows), the worst 2 s-window peak
## and the per-frame call count, for every section of interest, over SAMPLE_S.
func _sample(tree: SceneTree, pm: Node) -> Dictionary:
	var acc: Dictionary = {}
	var peak: Dictionary = {}
	var calls: Dictionary = {}
	var frames: Array = []
	var fps: Array = []
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
	frames.sort()
	fps.sort()
	var rows: Dictionary = {}
	for key in acc.keys():
		rows[key] = {"avg": float(acc[key]) / float(n), "peak": float(peak[key]),
			"calls": float(calls[key]) / float(n)}
	return {"rows": rows, "frame_ms": frames[frames.size() / 2],
		"frame_peak": frames[frames.size() - 1], "fps": fps[fps.size() / 2]}


func _print_table(label: String, s: Dictionary) -> void:
	print("flowbench %s: frame %.1f ms (median) / %.1f ms (worst) · %.0f fps" % [
		label, float(s["frame_ms"]), float(s["frame_peak"]), float(s["fps"])])
	var rows: Dictionary = s["rows"]
	# Sections of interest first (in order), then anything else that cost ≥ 0.05 ms.
	var listed: Dictionary = {}
	for key in SECTIONS:
		if rows.has(key):
			_print_row(label, key, rows[key])
			listed[key] = true
	var rest: Array = []
	for key in rows.keys():
		if not listed.has(key) and float((rows[key] as Dictionary)["avg"]) >= 0.05:
			rest.append(key)
	rest.sort()
	for key in rest:
		_print_row(label, str(key), rows[key])


func _print_row(label: String, key: String, r: Dictionary) -> void:
	print("flowbench %s: %-16s avg %6.2f ms · peak %6.2f ms · %.1f calls/frame" % [
		label, key, float(r["avg"]), float(r["peak"]), float(r["calls"])])


## Absolute hours for the pin's fixed calendar point, derived through the
## clock's own date → abs conversion so it matches what the sim reads.
func _pin_start_abs(main: Node) -> float:
	var clock: Object = main.get("clock")
	if clock == null:
		return float(main.call("get_absolute_hours"))
	# Walk from the current abs hours to the pin date: abs_hours_to_date gives
	# {year, month, day, day_time}; the clock exposes day-granular arithmetic
	# through set_absolute_hours only, so bracket by binary search over ±400 d.
	var cur := float(main.call("get_absolute_hours"))
	var lo := cur - 24.0 * 400.0
	var hi := cur + 24.0 * 400.0
	for i in 64:
		var mid := (lo + hi) * 0.5
		var d: Dictionary = clock.call("abs_hours_to_date", mid)
		var key := int(d.get("year", 0)) * 10000 + int(d.get("month", 0)) * 100 + int(d.get("day", 0))
		var want := PIN_YEAR * 10000 + PIN_MONTH * 100 + PIN_DAY
		if key < want or (key == want and float(d.get("day_time", 0.0)) < PIN_HOUR):
			lo = mid
		else:
			hi = mid
	return snappedf(hi, 1.0 / 3600.0)


## One number over the sim state a flow optimization must not change.
## Tanks: level (6 dp) + stock. Connections: flow rate (4 dp) + culvert Q.
## Processors: hydro / power telemetry, prime state, starved kinds, node state.
func _state_digest(model: Object) -> Dictionary:
	var parts: Array = []
	var n_tanks := 0
	var n_conns := 0
	var n_tel := 0
	var items: Array = (model.get("items") as Array).duplicate()
	items.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.get("id", "")) < str(b.get("id", "")))
	for it in items:
		var item: Dictionary = it
		var iid := str(item.get("id", ""))
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		match str(item.get("type", "")):
			"resource":
				parts.append([iid, "%.6f" % float(specs.get("level", 0.0)),
					"%.3f" % float(specs.get("stock_l", 0.0)),
					"%.4f" % float(specs.get("inflow_rate", 0.0)),
					"%.4f" % float(specs.get("outflow_rate", 0.0))])
				n_tanks += 1
			"processor", "catchment", "plant", "pbi":
				var row: Array = [iid]
				for key in ["live_power_w", "live_q_lps", "live_regime", "siphon_primed",
						"live_rpm", "live_supply_lps", "node_state", "is_active",
						"thermal_output_kw", "deficit_qty"]:
					if specs.has(key):
						var v: Variant = specs[key]
						row.append("%s=%s" % [key, ("%.4f" % float(v)) if (v is float or v is int) else str(v)])
				var starved: Array = specs.get("starved_kinds", []) as Array
				if not starved.is_empty():
					row.append("starved=" + ",".join(starved.map(func(s: Variant) -> String: return str(s))))
				for io_key in ["inputs", "outputs"]:
					var ios: Array = specs.get(io_key, []) as Array
					for k in ios.size():
						var io: Dictionary = ios[k]
						if io.has("rate"):
							row.append("%s%d=%.4f" % [io_key, k, float(io["rate"])])
				if row.size() > 1:
					parts.append(row)
					n_tel += 1
	var conns: Array = (model.get("connections") as Array).duplicate()
	conns.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.get("id", "")) < str(b.get("id", "")))
	for c in conns:
		var conn: Dictionary = c
		var row: Array = [str(conn.get("id", ""))]
		if conn.has("flow_rate"):
			row.append("%.4f" % float(conn["flow_rate"]))
		if conn.has("live_q_lps"):
			row.append("q=%.4f" % float(conn["live_q_lps"]))
		if conn.has("needs_pump"):
			row.append("pump=%s" % str(conn["needs_pump"]))
		if row.size() > 1:
			parts.append(row)
			n_conns += 1
	var text := JSON.stringify(parts)
	return {"hash": text.sha256_text().substr(0, 16), "n": parts.size(),
		"tanks": n_tanks, "conns": n_conns, "telemetry": n_tel}


func _wait(tree: SceneTree, s: float) -> void:
	await tree.create_timer(s, true, false, true).timeout
