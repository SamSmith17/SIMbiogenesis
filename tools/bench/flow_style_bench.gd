extends RefCounted

## Flow-wire draw cost (sandbox; the world's own graph, nothing saved):
##   tools\harness.ps1 -World w6af22bac295d -RunScript res://tools/bench/flow_style_bench.gd -Timeout 900
## For every flow-style preset, at the framed zoom and zoomed out, the cost of
## the canvas's wire pass PER REDRAW (PerfMonitor `gv_wires` ÷ calls) and of
## the whole draw (`gv_draw_all`), with the clock running so the flow
## animates; then the Flows lens. Prints `flowbench …` lines.
## FLOWBENCH_SPEED (default 60) is the sim speed.

const SAMPLE_S := 3.0


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	for _i in 10:
		await tree.process_frame
	var sgv := ServiceLocator.graph()
	var pm: Node = main.get_node_or_null("/root/PerfMonitor")
	if sgv == null or pm == null:
		return {"ok": false, "why": "no graph view / PerfMonitor"}
	var speed := 60.0
	if not OS.get_environment("FLOWBENCH_SPEED").is_empty():
		speed = float(OS.get_environment("FLOWBENCH_SPEED"))
	sgv.call("open_graph_view")
	await _wait(tree, 1.0)
	sgv.call("_on_mode_chip_pressed", GraphSiteLayout.VIEW_FREEFORM)
	sgv.call("_jump_to_scope_index", 0)
	await _wait(tree, 1.0)
	var canvas: Control = sgv.get("_graph_canvas")
	var model: GraphModel = sgv.get("model")
	var ids: Array = []
	for it in model.get_items_in_scope("root"):
		ids.append(str((it as Dictionary).get("id", "")))
	print("flowbench: %d items in view · %d wires · %sx" % [ids.size(), model.connections.size(), str(speed)])
	# The indexed delivered watts must answer exactly as the plain form.
	var ix := GraphAcLoad.delivered_index(model, tree)
	var worst := 0.0
	var n_ac := 0
	var t_plain := 0
	var t_ix := 0
	for c: Dictionary in model.connections:
		if not GraphAcLoad._is_ac_power_connection(c):
			continue
		n_ac += 1
		var t0 := Time.get_ticks_usec()
		var a := GraphAcLoad.connection_delivered_watts(model, c, tree)
		var t1 := Time.get_ticks_usec()
		var b := GraphAcLoad.delivered_watts_indexed(model, ix, c)
		t_plain += t1 - t0
		t_ix += Time.get_ticks_usec() - t1
		worst = maxf(worst, absf(a - b))
	print("flowbench parity: %d AC wires · worst difference %.6f W · plain %.2f ms · indexed %.2f ms %s" % [
		n_ac, worst, t_plain / 1000.0, t_ix / 1000.0, "PASS" if worst < 1e-6 else "FAIL"])
	pm.call("set_enabled", true)
	main.set("time_scale", speed / 3600.0)
	var style_was: Dictionary = sgv.call("flow_style")
	var out := {}
	for preset in GraphFlowStyle.PRESETS:
		sgv.call("set_flow_style", {"preset": preset}, false)
		for zl in [["fit", 0.0], ["far", 0.3]]:
			canvas.call("stop_fly")
			canvas.call("fit_items_to_view", ids, 0.05)
			if float(zl[1]) > 0.0:
				canvas.set("_zoom", float(zl[1]))
			canvas.queue_redraw()
			await _wait(tree, 1.0)
			var s := await _sample(tree, pm)
			out["%s_%s" % [preset, zl[0]]] = s
			print("flowbench %-8s %-4s zoom %.2f · wires %.2f ms per redraw · draw %.2f ms per redraw · %.1f redraws/s · frame %.1f ms" % [
				preset, str(zl[0]), float(canvas.get("_zoom")), float(s["wires"]), float(s["draw"]),
				float(s["redraws"]), float(s["frame"])])
	sgv.call("set_flow_style", {"preset": "sankey"}, false)
	sgv.call("_on_mode_chip_pressed", GraphSiteLayout.VIEW_FLOWS)
	await _wait(tree, 2.0)
	var sl := await _sample(tree, pm)
	print("flowbench lens: draw %.2f ms per redraw · %.1f redraws/s · frame %.1f ms" % [
		float(sl["draw"]), float(sl["redraws"]), float(sl["frame"])])
	sgv.call("_on_mode_chip_pressed", GraphSiteLayout.VIEW_FREEFORM)
	sgv.call("set_flow_style", style_was, false)
	main.set("time_scale", 0.0)
	pm.call("set_enabled", false)
	return {"ok": true, "out": out}


func _wait(tree: SceneTree, s: float) -> void:
	await tree.create_timer(s, true, false, true).timeout


## Per-redraw cost of the wire pass and of the whole draw, averaged over
## SAMPLE_S (PerfMonitor sections are per-frame averages: ÷ calls per frame).
func _sample(tree: SceneTree, pm: Node) -> Dictionary:
	var w_ms := 0.0
	var w_calls := 0.0
	var d_ms := 0.0
	var d_calls := 0.0
	var frame := 0.0
	var parts := {}
	var n := 0
	var t_end := Time.get_ticks_msec() + int(SAMPLE_S * 1000.0)
	while Time.get_ticks_msec() < t_end:
		await _wait(tree, 0.1)
		var snap: Dictionary = pm.call("snapshot")
		var sec: Dictionary = snap.get("sections_ms", {})
		var cl: Dictionary = snap.get("calls", {})
		for k in ["gv_w_sums", "gv_w_bundle", "gv_w_prep", "gv_w_trunk", "gv_w_render"]:
			parts[k] = float(parts.get(k, 0.0)) + float(sec.get(k, 0.0))
		w_ms += float(sec.get("gv_wires", 0.0))
		w_calls += float(cl.get("gv_wires", 0.0))
		d_ms += float(sec.get("gv_draw_all", 0.0))
		d_calls += float(cl.get("gv_draw_all", 0.0))
		frame += float(snap.get("frame_ms", 0.0))
		n += 1
	var fps := 1000.0 / maxf(frame / maxf(float(n), 1.0), 1e-3)
	var line := "flowbench parts:"
	for k in parts:
		line += " %s %.2f" % [str(k).trim_prefix("gv_w_"), float(parts[k]) / maxf(w_calls, 1e-6)]
	print(line)
	return {"wires": w_ms / maxf(w_calls, 1e-6), "draw": d_ms / maxf(d_calls, 1e-6),
		"redraws": d_calls / maxf(float(n), 1.0) * fps, "frame": frame / maxf(float(n), 1.0)}
