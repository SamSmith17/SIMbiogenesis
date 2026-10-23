extends RefCounted

## ⧉ Compare (sim vs reality) end to end on a REAL world (sandbox), against
## HaFakeServer on 127.0.0.1 — nothing reaches a real Home Assistant:
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/compare_calibration_probe.gd -Label compare_probe
##
## 1. "Reality" for the last 3 days is MADE BY THE SIM: this world simulated
##    with the same evaluator, its battery %, solar W and load W served as
##    Home Assistant history (5-min readings, Unix times through SiteTime).
##    Linked to site.battery_soc / solar_kw / load_kw, the Compare window must
##    then call the sim a match (NMBE ≈ 0, CV(RMSE) ≈ 0) — which only holds if
##    the history lands on the right hours (the time-zone pin) and units
##    convert (W → kW).
## 2. Reality with 25 % less solar: the solar channel is no longer "good" and
##    the sim reads about a third high on solar energy.
## 3. The live world never moved: user_rev, the clock, the battery.
## 4. The window: opened through the timeline's ⧉ handler, UiAudit 0 errors,
##    a shot of each result. Shots under screenshots/compare_probe/.

var _fails: Array = []
var _shots_dir := "user://screenshots/compare_probe"


func _ok(cond: bool, what: String) -> void:
	print("compare-check %s: %s" % ["PASS" if cond else "FAIL", what])
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
	DirAccess.make_dir_recursive_absolute(_shots_dir)
	var img := main.get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [_shots_dir, name])


## The sim of this world over [a, b) at `step`, as Home Assistant rows.
func _reality(main: Node, a: float, b: float, step: float, solar_scale: float) -> Dictionary:
	var su: Node = main.get_node_or_null("UILayer/SolarUI")
	var gv := ServiceLocator.graph()
	var model: Object = gv.get("model") if gv != null else null
	var bat := ExperimentEvaluator.battery_of(su)
	var ev := ExperimentEvaluator.current_world(su, model, null, ExperimentEvaluator.LOAD_MODEL,
		ExperimentEvaluator.AUX_HELD)
	var scaled := func(t: float) -> Dictionary:
		var d: Dictionary = ev.call(t)
		d["solar_kw"] = float(d["solar_kw"]) * solar_scale
		d["raw_kw"] = float(d["raw_kw"]) * solar_scale
		return d
	var r := ExperimentEnergyRun.new()
	r.floor_pct = float(bat["floor_pct"])
	r.resume_pct = float(bat["resume_pct"])
	r.configure(a, b, step, float(bat["cap_kwh"]), 0.6 * float(bat["cap_kwh"]), scaled)
	r.step_chunk(1000000)
	var clock: Object = main.get("clock")
	var soc_rows: Array = []
	var solar_rows: Array = []
	var load_rows: Array = []
	for i in r.series.size():
		var tu := SiteTime.site_abs_to_unix(clock, r.series.time_of(i))
		soc_rows.append({"s": "%.3f" % r.series.value("soc_pct", i), "lu": tu})
		solar_rows.append({"s": "%.1f" % (r.series.value("solar_kw", i) * 1000.0), "lu": tu})
		load_rows.append({"s": "%.1f" % (r.series.value("load_kw", i) * 1000.0), "lu": tu})
	return {"soc": soc_rows, "solar": solar_rows, "load": load_rows,
		"solar_kwh": r.series.integrate("solar_kw"), "load_kwh": r.series.integrate("load_kw")}


func _run_compare(tree: SceneTree, view: Node, a: float, b: float) -> Dictionary:
	view.call("run_with", a, b, "ha")
	await _settle(tree, 2)
	var ok := await _until(tree, func() -> bool:
		return not bool(view.call("is_running")) and not (view.call("last_result") as Dictionary).is_empty(), 120.0)
	_ok(ok, "the comparison finishes")
	var res: Dictionary = view.call("last_result")
	var o: Variant = res.get("observed", null)
	print("compare-check: report %s, observed channels %s" % [str(res.get("report", {})),
		str((o as ExperimentSeries).data.keys()) if o != null else "none"])
	view.set("_result", {})
	return res


func _sim_stats(res: Dictionary, sim_id: String, ch: String) -> Dictionary:
	for sm in res.get("sims", []):
		if str(sm["id"]) == sim_id:
			return ((sm["calibration"] as Dictionary).get("channels", {}) as Dictionary).get(ch, {})
	return {}


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var svc: Node = tree.root.get_node_or_null("HomeAssistant")
	var gv := ServiceLocator.graph()
	var linker: Node = gv.get("_ha_linker") if gv != null else null
	var su: Node = main.get_node_or_null("UILayer/SolarUI")
	var clock: Object = main.get("clock")
	_ok(svc != null and linker != null and su != null and clock != null, "HA service, linker, SolarUI and clock exist")
	if svc == null or linker == null or su == null or clock == null:
		return {"ok": false, "fails": _fails}

	# Span: the last 3 whole days before now (site clock), 5-min samples.
	var now_abs := SiteTime.unix_to_site_abs(clock, Time.get_unix_time_from_system())
	var b := floorf(now_abs)
	var a := b - 72.0
	var step := CalibrationExperiment.step_for(b - a)
	_ok(is_equal_approx(step, 5.0 / 60.0), "3 days are simulated every 5 min")
	var real := _reality(main, a, b, step, 1.0)
	print("compare-check: reality solar %.2f kWh, load %.2f kWh" % [real["solar_kwh"], real["load_kwh"]])
	_ok(float(real["solar_kwh"]) > 0.5, "this world makes solar over 3 days")

	var tok := "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJjb21wYXJlMDEyMzQ1Njc4OWFiY2RlZiIsImlhdCI6MTcwMDAwMDAwMH0.compareprobecompareprobecompareprobe_-xy"
	var srv := HaFakeServer.new()
	srv.token = tok
	srv.set_entity("sensor.cmp_battery_soc", "60", {"unit_of_measurement": "%", "device_class": "battery"})
	srv.set_entity("sensor.cmp_pv_power", "0", {"unit_of_measurement": "W", "device_class": "power"})
	srv.set_entity("sensor.cmp_ac_power", "0", {"unit_of_measurement": "W", "device_class": "power"})
	srv.history["sensor.cmp_battery_soc"] = real["soc"]
	srv.history["sensor.cmp_pv_power"] = real["solar"]
	srv.history["sensor.cmp_ac_power"] = real["load"]
	main.add_child(srv)
	srv.start(38800 + randi() % 300)
	_ok(srv.port > 0, "fake Home Assistant on 127.0.0.1:%d" % srv.port)
	svc.call("connect_with", srv.url(), tok, "Compare probe", false)
	var conn := await _until(tree, func() -> bool:
		return bool(svc.call("is_authed")) and int(svc.call("catalog_size")) >= 3, 8.0)
	_ok(conn, "connected to the fake Home Assistant")

	# Remember the links so the world is left as found.
	var saved_links: Array = (linker.call("links") as Array).duplicate(true)
	for tid in ["site.battery_soc", "site.solar_kw", "site.load_kw"]:
		linker.call("unlink_target", tid)
	linker.call("link_entity", "sensor.cmp_battery_soc", "site.battery_soc")
	linker.call("link_entity", "sensor.cmp_pv_power", "site.solar_kw")
	linker.call("link_entity", "sensor.cmp_ac_power", "site.load_kw")

	# The live world, before.
	var model: GraphModel = gv.get("model")
	var rev0 := int(model.user_rev)
	var clock0 := float(main.call("get_absolute_hours"))
	var bat0 := float(su.get("battery_kwh_stored"))
	var ts0 := float(main.get("time_scale"))
	main.set("time_scale", 0.0)

	# ---- 1. open through the timeline's ⧉ handler; reality == the sim ----
	var timeline: Node = main.get_node_or_null("UILayer/TimelineUI")
	if timeline != null:
		timeline.call("_on_compare_pressed")
	await _settle(tree, 10)
	var view: Node = main.get_node_or_null("CompareView")
	_ok(view != null, "⧉ opens the Compare window")
	if view == null:
		return await _finish(main, srv, svc, linker, saved_links, ts0)
	var res := await _run_compare(tree, view, a, b)
	var obs: ExperimentSeries = res.get("observed", null)
	_ok(obs != null and obs.has("soc_kwh") and obs.has("solar_kw") and obs.has("load_kw"),
		"Home Assistant history became an observed series (battery, solar, load)")
	if obs != null:
		_ok(obs.coverage("solar_kw") > 0.98, "solar readings cover the span (%s)" % UiText.pct(obs.coverage("solar_kw")))
		_ok(absf(obs.integrate("solar_kw") - float(real["solar_kwh"])) < 0.02 * maxf(float(real["solar_kwh"]), 1.0),
			"observed solar kWh == what was served (%.3f vs %.3f) — W → kW" % [obs.integrate("solar_kw"), real["solar_kwh"]])
	var s1 := _sim_stats(res, "model", "solar_kw")
	print("compare-check: identical solar " + str(s1))
	_ok(not s1.is_empty() and absf(float(s1.get("nmbe_pct", 99.0))) < 1.0 and float(s1.get("cvrmse_pct", 99.0)) < 2.0,
		"sim vs its own replay: solar NMBE ≈ 0 and CV(RMSE) ≈ 0 (the hours line up)")
	var b1 := _sim_stats(res, "model", "soc_pct")
	_ok(not b1.is_empty() and float(b1.get("mae", 99.0)) < 0.5, "battery within half a point (%.2f)" % float(b1.get("mae", NAN)))
	_ok(_sim_stats(res, "real_load", "load_kw").get("verdict", "") == "good", "the real-load sim replays the load exactly")
	await _settle(tree, 20)
	_shot(main, "01_match")
	var audit := UiAudit.run(main.get_viewport())
	print("compare-check: audit " + UiAudit.summary_line(audit))
	var shown := 0
	for f in audit.get("findings", []):
		if str(f.get("severity", "")) == "error" and shown < 8:
			print("compare-check:   %s %s \"%s\" %s" % [f.get("kind"), f.get("path"), str(f.get("text", "")).left(50), str(f.get("rect"))])
			shown += 1
	_ok(int(audit.get("errors", 0)) == 0, "UiAudit finds no errors in the window")

	# ---- 2. reality made 25 % less solar ----
	var dim := _reality(main, a, b, step, 0.75)
	srv.history["sensor.cmp_battery_soc"] = dim["soc"]
	srv.history["sensor.cmp_pv_power"] = dim["solar"]
	srv.history["sensor.cmp_ac_power"] = dim["load"]
	var res2 := await _run_compare(tree, view, a, b)
	var s2 := _sim_stats(res2, "model", "solar_kw")
	print("compare-check: dim solar " + str(s2))
	_ok(not s2.is_empty() and str(s2.get("verdict", "")) != "good", "25 % less real solar is not called a match")
	_ok(float(s2.get("kwh_err_pct", 0.0)) > 20.0, "the sim reads ~33 %% high on solar (%.1f %%)" % float(s2.get("kwh_err_pct", NAN)))
	await _settle(tree, 20)
	_shot(main, "02_dim_solar")
	var fr: Variant = view.get("_frame")
	var body: Control = fr.get("body") if fr != null else null
	if body != null and body.get_parent() is ScrollContainer:
		(body.get_parent() as ScrollContainer).scroll_vertical = 100000
		await _settle(tree, 10)
		_shot(main, "03_table")

	# ---- 3. the live world did not move ----
	_ok(int(model.user_rev) == rev0, "GraphModel.user_rev unchanged (%d → %d)" % [rev0, int(model.user_rev)])
	_ok(absf(float(main.call("get_absolute_hours")) - clock0) < 1e-6, "the clock did not move")
	_ok(absf(float(su.get("battery_kwh_stored")) - bat0) < 1e-6, "the battery did not move")
	var frame: Variant = view.get("_frame")
	if frame != null:
		frame.call("close")
	await _settle(tree, 5)
	_ok(main.get_node_or_null("CompareView") == null, "closing frees the window")
	return await _finish(main, srv, svc, linker, saved_links, ts0)


func _finish(main: Node, srv: HaFakeServer, svc: Node, linker: Node, saved: Array, ts0: float) -> Dictionary:
	for tid in ["site.battery_soc", "site.solar_kw", "site.load_kw"]:
		linker.call("unlink_target", tid)
	for l in saved:
		if str(l.get("target_id", "")).begins_with("site."):
			linker.call("link_entity", str(l["entity_id"]), str(l["target_id"]))
	svc.call("disconnect_ha")
	srv.stop()
	srv.queue_free()
	main.set("time_scale", ts0)
	return {"ok": _fails.is_empty(), "fails": _fails}
