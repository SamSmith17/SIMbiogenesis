extends RefCounted

## ⧉ Compare — "Did a change save?" / "Would a change have saved?" end to end
## on a REAL world (sandbox), against HaFakeServer on 127.0.0.1:
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/compare_savings_probe.gd -Label compare_savings
##
## A load gets a nightly shutdown (off 22:00 / on 06:00); a fork is made
## without it. "Reality" for the last 3 days is MADE BY THE SIM of the world
## with the shutdown (its own resources and automations) and served as Home
## Assistant history. Then, through the real window:
##   Did it save (reality ran = this world, without it = the fork): the
##   estimate = real + (fork sim − world sim) must come out equal to the
##   fork's own sim (reality IS the world's sim), the reality sim must be
##   called a good match, and the window must state a result.
##   Would it have saved: the same pair, worded as a what-if.
## The live world never moved; UiAudit 0 errors; everything added is removed.

var _fails: Array = []
var _dir := "user://screenshots/compare_savings"


func _ok(cond: bool, what: String) -> void:
	print("save-check %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func _until(tree: SceneTree, cond: Callable, timeout_s: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while not bool(cond.call()):
		if (Time.get_ticks_msec() - t0) / 1000.0 > timeout_s:
			return false
		await tree.process_frame
	return true


func _shot(main: Node, name: String) -> void:
	DirAccess.make_dir_recursive_absolute(_dir)
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [_dir, name])


func _wait(tree: SceneTree, view: Node) -> Dictionary:
	await _settle(tree, 2)
	var ok := await _until(tree, func() -> bool:
		return not bool(view.call("is_running")) and not (view.call("last_result") as Dictionary).is_empty(), 180.0)
	_ok(ok, "the run finishes")
	var res: Dictionary = view.call("last_result")
	view.set("_result", {})
	return res


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var svc: Node = tree.root.get_node_or_null("HomeAssistant")
	var gv := ServiceLocator.graph()
	var model: GraphModel = gv.get("model") if gv != null else null
	var linker: Node = gv.get("_ha_linker") if gv != null else null
	var su: Node = main.get_node_or_null("UILayer/SolarUI")
	var clock: Object = main.get("clock")
	_ok(svc != null and model != null and linker != null and su != null, "HA service, graph, linker, SolarUI")
	if model == null or svc == null:
		return {"ok": false, "fails": _fails}
	var exp_path := ExperimentStore.path_for_view(gv)
	var had_store := FileAccess.file_exists(exp_path)
	var store_bytes := FileAccess.get_file_as_string(exp_path) if had_store else ""
	var saved_links: Array = (linker.call("links") as Array).duplicate(true)
	var ts0 := float(main.get("time_scale"))
	main.set("time_scale", 0.0)

	# The change: a nightly shutdown on the biggest switched-on load.
	var load_id := ""
	var best := 0.0
	for it in model.items:
		var sp: Dictionary = it.get("specs", {})
		if str(it.get("type", "")) in ["appliance", "acload"] and str(sp.get("requested_state", "on")) != "off":
			var w := float(sp.get("avg_watts", sp.get("watts", 0.0)))
			if w > best:
				best = w
				load_id = str(it["id"])
	_ok(not load_id.is_empty(), "a load to schedule (%s, %.0f W)" % [load_id, best])
	if load_id.is_empty():
		return {"ok": false, "fails": _fails}
	var specs0: Dictionary = (model.get_item(load_id)["specs"] as Dictionary).duplicate(true)
	var specs := specs0.duplicate(true)
	var autos: Array = (specs.get("graph_automations", []) as Array).duplicate(true)
	autos.append({"id": "sv_probe_off", "alias": "Probe off at 22", "enabled": true,
		"triggers": [{"kind": "time", "at_hour": 22.0}], "conditions": [],
		"actions": [{"kind": "scene_node", "command": "turn_off"}]})
	autos.append({"id": "sv_probe_on", "alias": "Probe on at 6", "enabled": true,
		"triggers": [{"kind": "time", "at_hour": 6.0}], "conditions": [],
		"actions": [{"kind": "scene_node", "command": "turn_on"}]})
	specs["graph_automations"] = autos
	model.update_item(load_id, {"specs": specs})
	var world_graph: Dictionary = model.serialize()
	var store := ExperimentStore.load_from(exp_path)
	var fid := store.add_fork("Probe without the shutdown",
		ExperimentStore.without_automation(world_graph, load_id, "sv_probe_off"))
	store.save_to(exp_path)

	# Reality: the world's own sim over the last 3 days, served as HA history.
	var now_abs := SiteTime.unix_to_site_abs(clock, Time.get_unix_time_from_system())
	var b := floorf(now_abs)
	var a := b - 72.0
	var step := CalibrationExperiment.step_for(b - a)
	var bat := ExperimentEvaluator.battery_of(su)
	var w := ExperimentWorld.from_graph(world_graph, su, clock)
	w.enable_flow(gv)
	var r := AbExperiment.make_run(w, bat, a, b, step, 0.6 * float(bat["cap_kwh"]))
	r.step_chunk(1000000)
	var rows := {"soc": [], "solar": [], "load": []}
	for i in r.series.size():
		var tu := SiteTime.site_abs_to_unix(clock, r.series.time_of(i))
		(rows["soc"] as Array).append({"s": "%.4f" % r.series.value("soc_pct", i), "lu": tu})
		(rows["solar"] as Array).append({"s": "%.2f" % (r.series.value("solar_kw", i) * 1000.0), "lu": tu})
		(rows["load"] as Array).append({"s": "%.2f" % (r.series.value("load_kw", i) * 1000.0), "lu": tu})
	var tok := "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzYXZpbmdzMDEyMzQ1Njc4OWFiY2RlZiIsImlhdCI6MTcwMDAwMDAwMH0.savingsprobesavingsprobesavingsprobe_-xy"
	var srv := HaFakeServer.new()
	srv.token = tok
	srv.set_entity("sensor.sv_soc", "60", {"unit_of_measurement": "%"})
	srv.set_entity("sensor.sv_pv", "0", {"unit_of_measurement": "W"})
	srv.set_entity("sensor.sv_load", "0", {"unit_of_measurement": "W"})
	srv.history = {"sensor.sv_soc": rows["soc"], "sensor.sv_pv": rows["solar"], "sensor.sv_load": rows["load"]}
	main.add_child(srv)
	srv.start(39100 + randi() % 300)
	svc.call("connect_with", srv.url(), tok, "Savings probe", false)
	_ok(await _until(tree, func() -> bool: return bool(svc.call("is_authed")) and int(svc.call("catalog_size")) >= 3, 8.0),
		"connected to the fake Home Assistant")
	for tid in ["site.battery_soc", "site.solar_kw", "site.load_kw"]:
		linker.call("unlink_target", tid)
	linker.call("link_entity", "sensor.sv_soc", "site.battery_soc")
	linker.call("link_entity", "sensor.sv_pv", "site.solar_kw")
	linker.call("link_entity", "sensor.sv_load", "site.load_kw")
	var rev0 := int(model.user_rev)
	var bat0 := float(su.get("battery_kwh_stored"))

	# The fork's own sim, the number the estimate must reproduce.
	var wf := ExperimentWorld.from_graph(store.get_fork(fid)["graph"], su, clock)
	wf.enable_flow(gv)
	var rf := AbExperiment.make_run(wf, bat, a, b, step, 0.6 * float(bat["cap_kwh"]))
	rf.step_chunk(1000000)
	var fork_used := rf.series.integrate("load_kw")
	var real_used := r.series.integrate("load_kw")
	print("save-check: world sim used %.2f kWh, fork sim %.2f kWh (asked %.1f vs %.1f)" % [
		real_used, fork_used, ExperimentScore.energy(r.series)["demand_kwh"], ExperimentScore.energy(rf.series)["demand_kwh"]])

	var view: Node = main.call("open_compare_view", Vector2(NAN, NAN), {"mode": "did"})
	await _settle(tree, 5)
	_ok(view != null and str(view.get("_mode")) == "did", "Compare opens in 'Did a change save?'")
	view.call("run_savings_with", "did", ExperimentStore.CURRENT, fid, a, b, "ha")
	print("save-check: window span '%s' → '%s' = %s; probe a=%s (%s)" % [(view.get("_start_edit") as LineEdit).text,
		(view.get("_end_edit") as LineEdit).text, str(view.call("_span")), str(a), SiteTime.format_abs(clock, a)])
	var vs: PackedFloat64Array = view.call("_span")
	_ok(vs[0] == a and vs[1] == b, "the window's span is exact to the hour (a Vector2 rounded it to 2 h)")
	var res := await _wait(tree, view)
	var sv: Dictionary = view.call("last_savings")
	print("save-check: did → %s" % str(sv))
	var o: ExperimentSeries = res.get("observed", null)
	if o != null:
		var gaps: Array = []
		for i in o.size():
			if is_nan(o.value("load_kw", i)):
				gaps.append(i)
		print("save-check: observed n=%d start=%s r.n=%d r.start=%s gaps=%s first readings %s" % [o.size(),
			SiteTime.format_abs(clock, o.start_abs), r.series.size(), SiteTime.format_abs(clock, r.series.start_abs),
			str(gaps.slice(0, 20)) + (" …%d" % gaps.size() if gaps.size() > 20 else ""), str((rows["load"] as Array).slice(0, 2))])
		var simr: ExperimentSeries = (res.get("sims", [])[0] as Dictionary)["series"]
		var worst := 0.0
		var wi := -1
		for i in mini(o.size(), r.series.size()):
			var d := absf(o.value("load_kw", i) - r.series.value("load_kw", i))
			if d > worst:
				worst = d
				wi = i
		print("save-check: obs vs served worst %.3f kW at %d (%s); window sim vs probe sim at that i: %.3f vs %.3f" % [
			worst, wi, SiteTime.format_abs(clock, o.time_of(maxi(wi, 0))), simr.value("load_kw", maxi(wi, 0)), r.series.value("load_kw", maxi(wi, 0))])
	var ld: Dictionary = sv.get("load_kw", {})
	_ok(absf(float(ld.get("real_kwh", -1.0)) - real_used) < 0.01 * maxf(real_used, 1.0),
		"reality = the history served (%.2f vs %.2f kWh)" % [float(ld.get("real_kwh", NAN)), real_used])
	_ok(absf(float(ld.get("est_kwh", -1.0)) - fork_used) < 0.01 * maxf(fork_used, 1.0),
		"the estimate without the change = the fork's own sim (%.2f vs %.2f kWh)" % [float(ld.get("est_kwh", NAN)), fork_used])
	var sims: Array = res.get("sims", [])
	var cal: Dictionary = sims[0].get("calibration", {}) if not sims.is_empty() else {}
	_ok(str(cal.get("overall", "")) == "good", "the sim of reality's setup is a good match (%s)" % str(cal.get("overall", "")))
	var banner: AlertBanner = view.get("_banner")
	print("save-check: banner \"%s\"" % str(banner.get("_text")))
	_ok(banner.visible and (str(banner.get("_text")).begins_with("The change") or str(banner.get("_text")).begins_with("Over")),
		"the window states what the change did")
	await _settle(tree, 20)
	_shot(main, "01_did_save")
	var audit := UiAudit.run(main.get_viewport())
	print("save-check: audit " + UiAudit.summary_line(audit))
	_ok(int(audit.get("errors", 0)) == 0, "UiAudit: no errors")
	var fr: Variant = view.get("_frame")
	var body: Control = fr.get("body") if fr != null else null
	if body != null and body.get_parent() is ScrollContainer:
		(body.get_parent() as ScrollContainer).scroll_vertical = 100000
		await _settle(tree, 8)
		_shot(main, "02_did_table")
		(body.get_parent() as ScrollContainer).scroll_vertical = 0

	view.call("run_savings_with", "would", ExperimentStore.CURRENT, fid, a, b, "ha")
	await _wait(tree, view)
	var t2 := str(banner.get("_text"))
	print("save-check: would banner \"%s\"" % t2)
	_ok(t2.contains("would"), "'Would a change have saved?' words it as a what-if")
	await _settle(tree, 15)
	_shot(main, "03_would_save")

	_ok(int(model.user_rev) == rev0, "the live graph was not written by the runs (user_rev %d → %d)" % [rev0, int(model.user_rev)])
	_ok(absf(float(su.get("battery_kwh_stored")) - bat0) < 1e-6, "the battery did not move")
	if fr != null:
		fr.call("close")
	await _settle(tree, 5)

	# Clean up.
	model.update_item(load_id, {"specs": specs0})
	var eng: Node = tree.root.get_node_or_null("AutomationEngine")
	if eng != null:
		for aid in ["sv_probe_off", "sv_probe_on"]:
			eng.call("unregister_automation", aid)
	for tid in ["site.battery_soc", "site.solar_kw", "site.load_kw"]:
		linker.call("unlink_target", tid)
	for l in saved_links:
		if str(l.get("target_id", "")).begins_with("site."):
			linker.call("link_entity", str(l["entity_id"]), str(l["target_id"]))
	svc.call("disconnect_ha")
	srv.stop()
	srv.queue_free()
	if had_store:
		var f := FileAccess.open(exp_path, FileAccess.WRITE)
		f.store_string(store_bytes)
	elif FileAccess.file_exists(exp_path):
		DirAccess.remove_absolute(exp_path)
	main.set("time_scale", ts0)
	return {"ok": _fails.is_empty(), "fails": _fails}
