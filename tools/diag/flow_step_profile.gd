extends RefCounted

## Sandbox: where one live flow step (ResourceFlowEngine._simulate_step, as
## the ambient tick runs it) spends its time. Runs the step's stages one by
## one, in its order, inside the view's sim-write bracket, at 60x, for
## FSP_STEPS steps (default 40), and prints per stage the mean and worst ms,
## the item counts by type, and the items that cost the most.
##   tools\harness.ps1 -World walton -RunScript res://tools/diag/flow_step_profile.gd -Timeout 900

var _stage_us: Dictionary = {}
var _stage_max: Dictionary = {}
var _item_us: Dictionary = {}   # id -> total us
var _item_label: Dictionary = {}


func _t(stage: String, us: int) -> void:
	_stage_us[stage] = int(_stage_us.get(stage, 0)) + us
	_stage_max[stage] = maxi(int(_stage_max.get(stage, 0)), us)


func _step(fe: Object, model: GraphModel, abs_h: float, dt_h: float) -> void:
	var u := Time.get_ticks_usec()
	fe.get("_conn_flow").clear()
	for conn: Dictionary in model.connections:
		conn["flow_active"] = false
		conn["flow_rate"] = 0.0
	_t("tick: reset wires", Time.get_ticks_usec() - u)
	u = Time.get_ticks_usec()
	fe.call("_ensure_timelines")
	_t("tick: ensure timelines", Time.get_ticks_usec() - u)
	u = Time.get_ticks_usec()
	fe.call("_rebuild_conn_index")
	_t("conn index", Time.get_ticks_usec() - u)
	u = Time.get_ticks_usec()
	fe.call("_refresh_ambient_cache")
	_t("ambient cache", Time.get_ticks_usec() - u)
	fe.set("_pond_tank_index_valid", false)
	(fe.get("_pond_budget") as Dictionary).clear()
	fe.set("_stream_catch_m2", {})
	fe.set("_stream_catch_valid", false)
	var net_rates: Dictionary = {}
	u = Time.get_ticks_usec()
	for item: Dictionary in model.items_of_type("compound"):
		if bool((item.get("specs", {}) as Dictionary).get("greenhouse_system", false)):
			fe.call("_process_greenhouse", item, dt_h, abs_h)
			fe.call("_gh_exchange", item, net_rates, dt_h, abs_h)
	_t("greenhouses", Time.get_ticks_usec() - u)
	var u_all := Time.get_ticks_usec()
	for item: Dictionary in model.items:
		var ty: String = str(item.get("type", ""))
		var ui := Time.get_ticks_usec()
		var stage := ""
		if ty == "pbi":
			fe.call("_process_pbi", item, abs_h)
			stage = "items: pbi"
		elif ty == "catchment":
			fe.call("_process_catchment", item, net_rates, dt_h, abs_h)
			stage = "items: catchment"
		elif ty == "processor":
			var role := str((item.get("specs", {}) as Dictionary).get("role", "?"))
			fe.call("_process_processor", item, net_rates, dt_h, abs_h)
			stage = "items: processor/" + role
		elif ty == "plant":
			fe.call("_process_plant", item, net_rates, dt_h, abs_h)
			stage = "items: plant"
		if stage.is_empty():
			continue
		var d := Time.get_ticks_usec() - ui
		_t(stage, d)
		var iid := str(item.get("id", ""))
		_item_us[iid] = int(_item_us.get(iid, 0)) + d
		_item_label[iid] = "%s %s" % [stage.trim_prefix("items: "), str(item.get("label", iid))]
	_t("items (all)", Time.get_ticks_usec() - u_all)
	for pair in [["culverts", "_process_culvert_stage_discharge"], ["siphon hydro", "_process_siphon_hydro"],
			["jit transfers", "_process_jit_transfers"], ["stream inflows", "_credit_stream_inflows"]]:
		u = Time.get_ticks_usec()
		fe.call(pair[1], net_rates, dt_h, abs_h)
		_t(pair[0], Time.get_ticks_usec() - u)
	u = Time.get_ticks_usec()
	fe.call("_apply_external_flows", net_rates, dt_h)
	_t("external flows", Time.get_ticks_usec() - u)
	u = Time.get_ticks_usec()
	fe.call("_pond_budget_pass", net_rates, dt_h, abs_h)
	_t("pond budget", Time.get_ticks_usec() - u)
	u = Time.get_ticks_usec()
	fe.call("_prepare_composition")
	_t("composition prep", Time.get_ticks_usec() - u)
	u = Time.get_ticks_usec()
	var timelines: Dictionary = fe.get("_timelines")
	var mu_active := bool(fe.get("_mu_active"))
	for item: Dictionary in model.items_of_type("resource"):
		var iid: String = str(item.get("id", ""))
		var specs: Dictionary = fe.call("_tank_specs_view", item)
		if bool(specs.get("allow_negative", false)):
			fe.call("_integrate_deficit_tank", iid, fe.call("_tank_specs_copy", item), net_rates, dt_h)
			continue
		if not timelines.has(iid):
			continue
		var tl: ResourceTimeline = timelines[iid] as ResourceTimeline
		tl.configure(float(fe.call("_effective_capacity_qty", specs)))
		var net: float = float(net_rates.get(iid, 0.0))
		var mixed: Dictionary = {}
		if mu_active and bool(specs.get("track_composition", false)):
			mixed = fe.call("_mix_tank", iid, fe.call("_tank_specs_copy", item), net, dt_h)
		tl.record_step(abs_h, net, maxf(net, 0.0), maxf(-net, 0.0))
		var sample := tl.sample_at(abs_h)
		fe.call("_apply_tank_sample", item, sample, tl, abs_h)
		if not mixed.is_empty():
			fe.call("_store_make_up", iid, mixed, abs_h)
	_t("tanks integrate", Time.get_ticks_usec() - u)
	u = Time.get_ticks_usec()
	fe.call("_ledger_step", dt_h)
	_t("ledger", Time.get_ticks_usec() - u)
	fe.set("_last_abs_hours", abs_h)


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	for _i in 300:
		await tree.process_frame
	var view: Node = main.find_child("SystemGraphView", true, false)
	if view == null:
		return {"ok": false, "why": "no SystemGraphView"}
	var fe: Object = view.get("_resource_flow")
	var model: GraphModel = view.get("model")
	if fe == null or model == null:
		return {"ok": false, "why": "no flow engine"}
	main.set("time_scale", 60.0 / 3600.0)
	for _i in 120:
		await tree.process_frame
	var counts := {}
	for it in model.items:
		var ty := str((it as Dictionary).get("type", ""))
		counts[ty] = int(counts.get(ty, 0)) + 1
	print("flowprof: %d items, %d wires; by type %s" % [model.items.size(), model.connections.size(), str(counts)])
	# Stop the ambient tick stepping the engine itself while we drive it.
	view.set("_ambient_flow_suspended", true)
	var n := int(OS.get_environment("FSP_STEPS")) if OS.get_environment("FSP_STEPS") != "" else 40
	var total_us := 0
	var worst := 0
	for k in n:
		await tree.process_frame
		await tree.process_frame
		var abs_h := float(main.call("get_absolute_hours"))
		var last := float(fe.get("_last_abs_hours"))
		var dt_h := abs_h - last if last >= 0.0 else 0.0
		if dt_h <= 0.0:
			continue
		var u := Time.get_ticks_usec()
		view.call("_begin_sim_writes")
		var host: Object = view.get("_sim_load_host")
		if host != null and host.has_method("begin_bulk_sync"):
			host.call("begin_bulk_sync")
		_step(fe, model, abs_h, dt_h)
		if host != null and host.has_method("end_bulk_sync"):
			host.call("end_bulk_sync")
		var u2 := Time.get_ticks_usec()
		view.call("_end_sim_writes")
		_t("end sim writes", Time.get_ticks_usec() - u2)
		var d := Time.get_ticks_usec() - u
		total_us += d
		worst = maxi(worst, d)
	view.set("_ambient_flow_suspended", false)
	print("flowprof: %d steps, mean %.2f ms, worst %.2f ms" % [n, float(total_us) / 1000.0 / float(n), float(worst) / 1000.0])
	var rows: Array = []
	for st in _stage_us.keys():
		rows.append([float(_stage_us[st]) / float(n) / 1000.0, st])
	rows.sort_custom(func(a, b): return a[0] > b[0])
	for r in rows:
		print("flowprof:   %-38s mean %6.3f ms  worst %6.3f ms" % [r[1], r[0], float(_stage_max[r[1]]) / 1000.0])
	var items: Array = []
	for iid in _item_us.keys():
		items.append([float(_item_us[iid]) / float(n) / 1000.0, str(_item_label[iid])])
	items.sort_custom(func(a, b): return a[0] > b[0])
	for k in mini(15, items.size()):
		print("flowprof:   item %-46s %6.3f ms" % [items[k][1], items[k][0]])
	return {"ok": true}
