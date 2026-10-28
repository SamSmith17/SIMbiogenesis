extends RefCounted

## Times single graph-view functions on the world's real graph (sandbox,
## read-only apart from the sim writes those functions always make): the
## median of REPS calls each. The bench that finds a section is
## graph_view_bench; this says which function inside it costs what.
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/bench/graph_fn_timing.gd

const REPS := 15


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	for _f in 20:
		await tree.process_frame
	var gv: Node = main.find_child("SystemGraphView", true, false)
	gv.call("open_graph_view")
	for _f2 in 60:
		await tree.process_frame
	var model: GraphModel = gv.get("model")
	var dash: Node = gv.get("_graph_dashboard")
	var out := {}
	var cases := [
		["flat_connections", func() -> void: GraphNesting.flat_connections(model)],
		["walk_items", func() -> void: GraphNesting.walk_items(model, "root")],
		["root_array_aggregate", func() -> void: gv.call("_collect_root_array_aggregate")],
		["refresh_telemetry", func() -> void: gv.call("_refresh_telemetry")],
		["sync_solar_ui_from_graph", func() -> void: gv.call("_sync_solar_ui_from_graph")],
		["sync_ac_fault", func() -> void: gv.call("_sync_graph_controller_ac_fault")],
		["dc_throttle_topology", func() -> void: gv.call("_dc_throttle_topology")],
		["dc_throttle_pass", func() -> void: gv.call("_dc_throttle_pass", true)],
		["sync_energy_from_solar", func() -> void: gv.call("_sync_graph_energy_from_solar")],
		["closure_telemetry", func() -> void: gv.call("_refresh_closure_telemetry")],
		["queue_world_inventory", func() -> void: gv.call("_queue_world_inventory")],
		["dash_power", func() -> void: dash.call("_refresh_power")],
		["dash_closure", func() -> void: dash.call("_refresh_closure")],
		["dash_balance", func() -> void: dash.call("_refresh_balance")],
		["dash_stores", func() -> void: dash.call("_refresh_stores")],
		["solar_evaluate_at", func() -> void:
			var su: Node = main.find_child("SolarUI", true, false)
			su.call("evaluate_solar_at", float(main.call("get_absolute_hours")) + 3.3)],
	]
	for c in cases:
		var t: Array = []
		for i in REPS:
			var a := Time.get_ticks_usec()
			(c[1] as Callable).call()
			t.append(float(Time.get_ticks_usec() - a) / 1000.0)
		t.sort()
		out[str(c[0])] = t[t.size() / 2]
		print("gvtime %-26s median %7.3f ms · max %7.3f ms" % [str(c[0]), float(t[t.size() / 2]), float(t[t.size() - 1])])
	# Card draw cost by type over 30 forced redraws of the freeform lens.
	gv.call("_apply_graph_view_mode", GraphSiteLayout.VIEW_FREEFORM)
	for _f3 in 30:
		await tree.process_frame
	var canvas: Control = gv.get("_graph_canvas")
	var pm: Node = main.get_node_or_null("/root/PerfMonitor")
	if pm != null:
		pm.call("set_enabled", true)
	canvas.set("draw_profile", {})
	canvas.set("draw_profile_on", true)
	var wires_ms := 0.0
	var cards_ms := 0.0
	var draws := 0
	for _d in 30:
		canvas.queue_redraw()
		await tree.process_frame
		await tree.process_frame
		if pm != null:
			var lf: Dictionary = pm.get("last_frame")
			if lf.has("gv_wires"):
				wires_ms += float(lf["gv_wires"])
				cards_ms += float(lf.get("gv_cards", 0.0))
				draws += 1
	canvas.set("draw_profile_on", false)
	var prof: Dictionary = canvas.get("draw_profile")
	print("gvtime draw: %d draws sampled · wires %.2f ms · cards %.2f ms per draw" % [draws,
		wires_ms / maxf(float(draws), 1.0), cards_ms / maxf(float(draws), 1.0)])
	var keys := prof.keys().filter(func(k) -> bool: return not str(k).ends_with("#n"))
	keys.sort_custom(func(a, b) -> bool: return int(prof[a]) > int(prof[b]))
	for k in keys:
		var n := int(prof.get(str(k) + "#n", 1))
		print("gvtime card %-22s %6.3f ms each · %d cards a draw" % [str(k), float(prof[k]) / 1000.0 / float(n),
			n / 30])
	return {"ok": true, "ms": out}
