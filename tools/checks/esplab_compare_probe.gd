extends RefCounted

## The ESP board designer's Compare tab against a fake Home Assistant
## (sandbox; nothing reaches a real one):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/esplab_compare_probe.gd -Label esplab_compare
## HaFakeServer on 127.0.0.1 plays the REAL board: every entity the weather
## station's YAML makes, under the ids the naming contract predicts, with a
## day of history that is the twin's own ideal reading, the temperature
## 0.8 °C warm. Real clicks: the Compare tab, Find my board, Compare. Then:
##   - every entity is matched, the temperature reads bias ~0.8 with r ~1,
##     the humidity ~0;
##   - "Calibrate: offset" writes `- offset: -0.8` into the YAML;
##   - the history served again with the calibration applied compares at
##     bias ~0;
##   - UiAudit clean; a shot of the tab.

var _fails: Array = []
var _dir := ""


func _ok(cond: bool, what: String) -> void:
	print("esplab_compare %s: %s" % ["PASS" if cond else "FAIL", what])
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
	await RenderingServer.frame_post_draw
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [_dir, name])


func _find(ui: Node, name: String) -> Control:
	return ui.find_child(name, true, false) as Control


func _click(tree: SceneTree, vp: Viewport, c: Control) -> void:
	var n: Node = c.get_parent()
	while n != null and not (n is ScrollContainer):
		n = n.get_parent()
	if n != null:
		(n as ScrollContainer).ensure_control_visible(c)
	await _settle(tree, 2)
	await HarnessInput.click(vp, HarnessInput.center_of(c))
	await _settle(tree, 3)


## A day of the twin's ideal readings as HA history rows (minimal_response).
func _history(ui: Control, ent: Dictionary, clock: Object, t0: float, t1: float, add: float) -> Array:
	var probe: EspWorldProbe = ui.call("_compare_probe")
	var src := probe.source()
	var d: Dictionary = ui.call("design")
	var s := EspCompare.numeric(EspSim.series(ent, EspSim.unit_key(str(d["node"]), ent), t0, t1, src, 4000, true))
	var rows: Array = []
	for r in s:
		var v := float(r[1])
		var st := "unavailable"
		if not is_nan(v):
			if str(ent["kind"]) == "binary_sensor":
				st = "on" if v > 0.5 else "off"
			else:
				st = str(snappedf(v + add, 0.001))
		rows.append({"s": st, "lu": SiteTime.site_abs_to_unix(clock, float(r[0]))})
	return rows


func _serve(srv: HaFakeServer, ui: Control, clock: Object, temp_add: float) -> void:
	var t1 := SiteTime.unix_to_site_abs(clock, Time.get_unix_time_from_system())
	var t0 := t1 - 25.0
	var d: Dictionary = ui.call("design")
	for e in d["entities"]:
		if str(e["iid"]) == "":
			continue
		var add := temp_add if str(e["part"]) == "bme280" and str(e["k"]) == "temperature" else 0.0
		srv.history[str(e["entity_id"])] = _history(ui, e, clock, t0, t1, add)


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var vp := main.get_viewport()
	_dir = "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(_dir)
	var svc: Node = tree.root.get_node_or_null("HomeAssistant")
	_ok(svc != null, "the HomeAssistant autoload is up")
	if svc == null:
		return {"ok": false, "failures": _fails}
	var clock: Object = main.get("clock")
	var ui: Control = main.call("open_esplab", {})
	await _settle(tree, 6)
	ui.call("load_builtin", "weather_station")
	await _settle(tree, 6)
	var d: Dictionary = ui.call("design")
	var temp := {}
	var hum := {}
	for e in d["entities"]:
		if str(e["part"]) == "bme280" and str(e["k"]) == "temperature":
			temp = e
		if str(e["part"]) == "bme280" and str(e["k"]) == "humidity":
			hum = e
	_ok(not temp.is_empty() and not hum.is_empty(), "the weather station has a BME280")

	# The real board: its entities in HA's catalog, a day of history each.
	var tok := "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJlc3BsYWIwMTIzNDU2Nzg5YWJjIiwiaWF0IjoxNzAwMDAwMDAwfQ.espespespespespespespespespespespespesp_-xy"
	var srv := HaFakeServer.new()
	srv.token = tok
	for e in d["entities"]:
		var attrs := {"friendly_name": "%s %s" % [str(d["friendly"]), str(e["name"])]}
		if str(e["unit"]) != "":
			attrs["unit_of_measurement"] = str(e["unit"])
		srv.set_entity(str(e["entity_id"]), "0", attrs)
	_serve(srv, ui, clock, 0.8)
	main.add_child(srv)
	srv.start(38800 + randi() % 300)
	_ok(srv.port > 0, "fake Home Assistant on 127.0.0.1:%d" % srv.port)
	svc.call("connect_with", srv.url(), tok, "ESP probe", false)
	var authed := await _until(tree, func() -> bool: return bool(svc.call("is_authed")), 8.0)
	_ok(authed, "connected to the fake Home Assistant")
	await _until(tree, func() -> bool: return int(svc.call("catalog_size")) >= (d["entities"] as Array).size(), 4.0)

	# Real clicks: the tab, Find my board, Compare.
	var tab := _find(ui, "tab_compare")
	_ok(tab != null, "the designer has a Compare tab")
	if tab == null:
		return _finish(main, srv, svc, ui)
	await _click(tree, vp, tab)
	var panel := _find(ui, "Compare")
	_ok(panel != null and panel.is_visible_in_tree(), "the Compare tab shows")
	var span := _find(ui, "compare_span") as OptionButton
	_ok(span != null and span.get_item_text(span.selected).contains("24"), "the span defaults to a day")
	await _click(tree, vp, _find(ui, "compare_find"))
	var real: Dictionary = (ui.call("spec") as Dictionary).get("real", {})
	var want := 0
	for e in d["entities"]:
		if str(e["iid"]) != "":
			want += 1
	_ok(real.size() == want, "Find my board matched every entity (%d of %d)" % [real.size(), want])
	_ok(str(real.get(str(temp["entity_id"]), "")) == str(temp["entity_id"]), "the temperature matched by its predicted id")
	await _click(tree, vp, _find(ui, "compare_run"))
	var done := await _until(tree, func() -> bool:
		return not bool(ui.get("_cmp_running")) and not (ui.call("compare_results") as Dictionary).is_empty(), 30.0)
	_ok(done, "the comparison finished")
	_ok(srv.history_requests >= want, "history fetched per entity (%d)" % srv.history_requests)
	var res: Dictionary = ui.call("compare_results")
	var rt: Dictionary = res.get(str(temp["entity_id"]), {})
	var st: Dictionary = rt.get("stats", {})
	print("esplab_compare: temperature %s" % str(st))
	_ok(absf(float(st.get("bias", NAN)) - 0.8) < 0.08, "the temperature reads 0.8 warm (%.3f)" % float(st.get("bias", NAN)))
	_ok(float(st.get("r", 0.0)) > 0.98 or float(st.get("rmse", 9.0)) < 0.85, "and follows the twin (r %.3f, rmse %.3f)" % [float(st.get("r", NAN)), float(st.get("rmse", NAN))])
	_ok(str(rt.get("verdict", "")) == "good", "inside the BME280's ±1 °C (%s)" % str(rt.get("verdict", "")))
	var hst: Dictionary = (res.get(str(hum["entity_id"]), {}) as Dictionary).get("stats", {})
	_ok(absf(float(hst.get("bias", NAN))) < 0.05, "the humidity agrees (%.3f)" % float(hst.get("bias", NAN)))
	var slug := EspEntityNames.ha_slug(str(temp["entity_id"]))
	_ok(_find(ui, "chart_%s" % slug) != null, "the temperature has its chart")
	await _settle(tree, 6)
	await _shot(main, "01_compare")
	var audit := UiAudit.run(vp)
	_ok(int(audit.get("errors", 0)) == 0, "the Compare tab audits clean (%s)" % UiAudit.summary_line(audit))

	# Calibrate: the offset lands in the YAML.
	var cal_btn := _find(ui, "cal_offset_%s" % slug)
	_ok(cal_btn != null, "Calibrate: offset is offered")
	if cal_btn != null:
		await _click(tree, vp, cal_btn)
	var yaml := str(ui.call("yaml_text"))
	_ok(yaml.contains("- offset: -0.8"), "the YAML has the calibration")
	_ok(not yaml.contains("cal:"), "and not its marker")

	# The board reflashed: its history now reads like the twin.
	_serve(srv, ui, clock, 0.0)
	ui.call("run_compare")
	await _until(tree, func() -> bool: return not bool(ui.get("_cmp_running")), 30.0)
	await _settle(tree, 4)
	var st2: Dictionary = ((ui.call("compare_results") as Dictionary).get(str(temp["entity_id"]), {}) as Dictionary).get("stats", {})
	_ok(absf(float(st2.get("bias", NAN))) < 0.08, "after calibration the bias is ~0 (%.3f)" % float(st2.get("bias", NAN)))
	await _shot(main, "02_after_calibration")
	return _finish(main, srv, svc, ui)


func _finish(main: Node, srv: HaFakeServer, svc: Node, ui: Control) -> Dictionary:
	if ui != null and bool(ui.call("is_open")):
		ui.call("close")
	svc.call("disconnect_ha")
	srv.stop()
	srv.queue_free()
	print("esplab_compare: %d failure(s)" % _fails.size())
	return {"ok": _fails.is_empty(), "failures": _fails}
