extends RefCounted

## Home Assistant end to end on a REAL world (sandbox), against HaFakeServer
## on 127.0.0.1 — nothing reaches a real Home Assistant:
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/ha_link_probe.gd
## 1. Settings → Home Assistant: fill the page, CLICK Connect (real input), and
##    read the status card's four steps.
## 2. Live links: link a fake battery sensor to the site battery, a fake
##    power sensor (W) to a graph load, a °F temperature to the weather.
## 3. At 1× (Live) a state change drives SolarUI's battery, the load's watts
##    and the temperature (converted), and GraphModel.user_rev does NOT move.
## 4. At 60× the readings are recorded but nothing is driven.
## 5. Unlink: the badge cache is gone. The Live links window opens, lists
##    values and entities, and passes UiAudit. Shots under screenshots/ha_probe/.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("ha-check %s: %s" % ["PASS" if cond else "FAIL", what])
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
	var dir := "user://screenshots/ha_probe"
	DirAccess.make_dir_recursive_absolute(dir)
	var img := main.get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [dir, name])


func _find(root: Node, pred: Callable) -> Node:
	if bool(pred.call(root)):
		return root
	for c in root.get_children():
		var r := _find(c, pred)
		if r != null:
			return r
	return null


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var svc: Node = tree.root.get_node_or_null("HomeAssistant")
	_ok(svc != null, "the HomeAssistant autoload is up")
	if svc == null:
		return {"ok": false, "fails": _fails}
	_ok(main.get_node_or_null("HAClient") != null and ServiceLocator.ha_client() != null, "Main/HAClient facade registered")
	var tok := "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJwcm9iZTAxMjM0NTY3ODlhYmNkZWYiLCJpYXQiOjE3MDAwMDAwMDB9.probeprobeprobeprobeprobeprobeprobeprobe_-xy"
	var srv := HaFakeServer.new()
	srv.token = tok
	srv.location_name = "Probe Home"
	srv.set_entity("sensor.probe_battery_soc", "64", {"unit_of_measurement": "%", "device_class": "battery", "friendly_name": "Probe battery"})
	srv.set_entity("sensor.probe_house_power", "1500", {"unit_of_measurement": "W", "device_class": "power", "friendly_name": "Probe house power"})
	srv.set_entity("sensor.probe_outdoor_temp", "50", {"unit_of_measurement": "°F", "device_class": "temperature", "friendly_name": "Probe outdoor temperature"})
	srv.set_entity("switch.probe_pump", "off", {"friendly_name": "Probe pump"})
	srv.set_entity("switch.shellyplus1pm_probe_switch_0", "on", {"friendly_name": "Probe plug"})
	srv.set_entity("sensor.shellyplus1pm_probe_switch_0_power", "321", {"unit_of_measurement": "W", "device_class": "power", "friendly_name": "Probe plug power"})
	var now_u := Time.get_unix_time_from_system()
	srv.history["sensor.probe_battery_soc"] = [{"s": "50", "lu": now_u - 3600.0}, {"s": "55", "lu": now_u - 1800.0}]
	main.add_child(srv)
	srv.start(38500 + randi() % 300)
	_ok(srv.port > 0, "fake Home Assistant on 127.0.0.1:%d" % srv.port)

	# ---- 1. the settings page, with real clicks ----
	var ts0 := float(main.get("time_scale"))
	main.call("open_settings_page", "Home Assistant")
	await _settle(tree, 20)
	var tab: Node = _find(tree.root, func(n: Node) -> bool:
		return n.get_script() != null and str((n.get_script() as Script).resource_path).ends_with("ha_settings_tab.gd"))
	_ok(tab != null, "Settings → Home Assistant page is built")
	if tab != null:
		var opt: OptionButton = tab.get("_profile_opt")
		opt.select(opt.item_count - 1)
		opt.item_selected.emit(opt.item_count - 1)
		await _settle(tree, 3)
		var name_ed: LineEdit = tab.get("_name_ed")
		var url_ed: LineEdit = tab.get("_url_ed")
		var tok_ed: LineEdit = tab.get("_token_ed")
		name_ed.text = "Probe"
		url_ed.text = "127.0.0.1:%d" % srv.port
		url_ed.text_changed.emit(url_ed.text)
		tok_ed.text = "  " + tok + "\n"
		tok_ed.text_changed.emit(tok_ed.text)
		await _settle(tree, 3)
		var prev: Label = tab.get("_url_preview")
		_ok(prev.text.contains("ws://127.0.0.1:%d/api/websocket" % srv.port), "the address preview shows the WebSocket URL (%s)" % prev.text)
		var btn: Button = tab.get("_connect_btn")
		await _settle(tree, 2)
		_shot(main, "01_settings_before")
		HarnessInput.click(main.get_viewport(), HarnessInput.center_of(btn))
		var ok := await _until(tree, func() -> bool: return int(svc.get("state")) == HomeAssistantService.State.CONNECTED, 6.0)
		_ok(ok, "clicking Connect connects (%s)" % str(svc.call("status_text")))
		await _until(tree, func() -> bool: return int(svc.call("catalog_size")) == 6, 3.0)
		await _settle(tree, 40)
		var steps: Array = tab.get("_steps")
		var lines: Array = []
		for l in steps:
			lines.append((l as Label).text)
		print("ha-check: steps " + str(lines))
		_ok(str(lines[0]).begins_with("✓") and str(lines[1]).begins_with("✓") and str(lines[2]).begins_with("✓") and str(lines[3]).begins_with("✓"),
			"all four steps green")
		_ok(str(lines[1]).contains("2026.10.1") and str(lines[3]).contains("6 entities"), "version + entity count shown")
		var chip: Button = (main.get_node_or_null("UILayer/TimelineUI") as Node).get("_ha_chip")
		_ok(chip != null and chip.text.begins_with("HA"), "timeline HA chip present (%s)" % (chip.text if chip != null else "none"))
		_shot(main, "02_settings_connected")
	var timeline: Node = main.get_node_or_null("UILayer/TimelineUI")
	var panel: Variant = timeline.get("_settings_panel") if timeline != null else null
	if panel != null and (panel as Object).has_method("close"):
		panel.call("close")
	elif panel != null and (panel as Object).has_method("toggle"):
		panel.call("toggle")
	await _settle(tree, 10)

	# ---- 2. links ----
	var gv := ServiceLocator.graph()
	var linker: Node = gv.get("_ha_linker") if gv != null else null
	_ok(linker != null, "the graph's link runtime exists")
	if linker == null:
		return _finish(main, srv, svc, ts0)
	var model: GraphModel = gv.get("model")
	var load_id := ""
	for it in model.items:
		if str(it.get("type", "")) in ["appliance", "acload"]:
			load_id = str(it["id"])
			break
	var added_load := false
	if load_id.is_empty():
		load_id = "probe_ha_load"
		model.add_item({"id": load_id, "type": "acload", "label": "Probe load", "x": 0, "y": 0,
			"specs": {"avg_watts": 100.0, "current_state": "on"}})
		added_load = true
	linker.call("link_entity", "sensor.probe_battery_soc", "site.battery_soc")
	linker.call("link_entity", "sensor.probe_house_power", HaTargets.item_target_id(load_id, "power"))
	linker.call("link_entity", "sensor.probe_outdoor_temp", "weather.temp_c")
	await _settle(tree, 30)
	var path := str(linker.get("_store_path"))
	_ok(not path.is_empty() and FileAccess.file_exists(path), "links saved in the world's file (%s)" % path)
	var hist_ok := await _until(tree, func() -> bool: return int(linker.call("observed_count", "site.battery_soc")) >= 3, 4.0)
	_ok(hist_ok, "Home Assistant's history fills in the battery's recorded track (%d readings)" % int(linker.call("observed_count", "site.battery_soc")))
	var now_h := HaObservedStore.now_abs_hours()
	var hb: PackedFloat32Array = linker.call("observed_bins", "site.battery_soc", now_h - 2.0, now_h + 0.1, 21)
	var finite := 0
	for v in hb:
		if not is_nan(v):
			finite += 1
	# 21 bins over the last 2.1 h: bin 12 is ~50 min ago, bin 17 ~20 min ago.
	_ok(finite >= 9 and absf(hb[12] - 50.0) < 0.6 and absf(hb[17] - 55.0) < 0.6,
		"the recorded track holds HA's history: 50 %% then 55 %% (%s)" % str(hb))
	var tl_ui: Node = main.get_node_or_null("UILayer/TimelineUI")
	var layout: Variant = tl_ui.get("_track_layout") if tl_ui != null else null
	if layout != null:
		layout.call("add_ha_track", "site.battery_soc", "Battery state of charge")
		var tr_ctl: Variant = tl_ui.get("_track")
		if tr_ctl is CanvasItem:
			(tr_ctl as CanvasItem).queue_redraw()
		# The same calls the Tracks menu makes after adding a track.
		if tl_ui.has_method("_sync_scrubber_row_height"):
			tl_ui.call("_sync_scrubber_row_height")
		if tl_ui.has_method("_request_bar_layout"):
			tl_ui.call("_request_bar_layout")
		await _settle(tree, 20)
		_shot(main, "05_timeline_ha_track")
		var found := false
		for t in layout.get("tracks"):
			if t is TimelineTrackDef and (t as TimelineTrackDef).source == "ha":
				found = true
		_ok(found, "an HA observed track is on the timeline")

	# ---- 3. live at 1× (Live mode on, as a player would switch it) ----
	var ssc := tree.root.get_node_or_null("SimSettingsController")
	var live0 := bool(ssc.get("live_mode_enabled")) if ssc != null else false
	var st_off: Dictionary = linker.call("link_status", "site.battery_soc")
	_ok(not bool(st_off.get("applies", true)) or live0, "with Live mode off a link only records")
	if ssc != null:
		ssc.call("set_live_mode", true)
	main.set("time_scale", 1.0 / 3600.0)
	var td := tree.root.get_node_or_null("TimeDirector")
	await _until(tree, func() -> bool: return td == null or bool(td.call("is_live")), 4.0)
	_ok(td == null or bool(td.call("is_live")), "1× reads as Live")
	await _settle(tree, 20)
	var rev0 := model.user_rev
	srv.push_state("sensor.probe_battery_soc", "72")
	srv.push_state("sensor.probe_house_power", "2345")
	srv.push_state("sensor.probe_outdoor_temp", "50")
	var sol := ServiceLocator.solar_ui()
	var ok2 := await _until(tree, func() -> bool:
		return absf(float(model.get_item(load_id).get("specs", {}).get("avg_watts", 0.0)) - 2345.0) < 0.5, 3.0)
	_ok(ok2, "a W sensor drives the load's watts (%.1f)" % float(model.get_item(load_id).get("specs", {}).get("avg_watts", 0.0)))
	var cap := float(sol.get("BATTERY_CAPACITY_KWH"))
	var soc := float(sol.get("battery_kwh_stored")) / cap * 100.0 if cap > 0.0 else -1.0
	_ok(absf(soc - 72.0) < 0.6, "the site battery follows the sensor (%.1f %%)" % soc)
	_ok(absf(float(sol.get("_ha_temperature_override")) - 10.0) < 0.05, "50 °F arrives as 10 °C (%.2f)" % float(sol.get("_ha_temperature_override")))
	var st: Dictionary = linker.call("link_status", "site.battery_soc")
	_ok(bool(st.get("applies", false)), "the link reports that it drives the simulation")
	_ok(model.user_rev == rev0, "user_rev did not move (%d → %d): live readings are sim writes" % [rev0, model.user_rev])
	_ok(int(svc.call("live_link_count")) >= 2, "the service counts live links (%d)" % int(svc.call("live_link_count")))
	await _settle(tree, 20)
	var ae := tree.root.get_node_or_null("AutomationEngine")
	var ctx: Dictionary = ae.get("_context") if ae != null else {}
	var nv: Dictionary = ctx.get("numeric_values", {})
	_ok(absf(float(nv.get("sensor.probe_house_power", -1.0)) - 2345.0) < 0.5, "automations see the real sensor (sensor.probe_house_power = %s)" % str(nv.get("sensor.probe_house_power", "missing")))

	# ---- 4. at 60×: recorded, not driven ----
	if ssc != null:
		ssc.call("set_live_mode", live0)
	main.set("time_scale", 60.0 / 3600.0)
	await _until(tree, func() -> bool: return td == null or not bool(td.call("is_live")), 4.0)
	await _settle(tree, 10)
	var w_before := float(model.get_item(load_id).get("specs", {}).get("avg_watts", 0.0))
	srv.push_state("sensor.probe_house_power", "999")
	await _until(tree, func() -> bool:
		return absf(float((linker.call("link_status", HaTargets.item_target_id(load_id, "power")) as Dictionary).get("value", 0.0)) - 999.0) < 0.5, 3.0)
	var st2: Dictionary = linker.call("link_status", HaTargets.item_target_id(load_id, "power"))
	_ok(absf(float(st2.get("value", 0.0)) - 999.0) < 0.5, "at 60× the reading is still recorded (%.0f W)" % float(st2.get("value", 0.0)))
	_ok(absf(float(model.get_item(load_id).get("specs", {}).get("avg_watts", 0.0)) - w_before) < 0.5 and not bool(st2.get("applies", true)),
		"…but does not drive the load")

	# ---- 5. the window, then unlink ----
	main.call("open_ha_links", "site.battery_soc")
	await _settle(tree, 40)
	var modal: Node = main.get_node_or_null("HaLinksModal")
	_ok(modal != null and bool(modal.call("is_open")), "the Live links window opens")
	if modal != null:
		var rows: Dictionary = modal.get("_target_rows")
		var ents: VBoxContainer = modal.get("_ent_list")
		_ok(rows.size() >= 10, "it lists the tracked values (%d)" % rows.size())
		_ok(ents.get_child_count() >= 1, "and the compatible entities for the battery (%d)" % ents.get_child_count())
		_shot(main, "03_live_links")
		var audit := UiAudit.run(main.get_viewport())
		print("ha-check: audit " + UiAudit.summary_line(audit))
		var shown := 0
		for f in audit.get("findings", []):
			if str(f.get("severity", "")) == "error" and shown < 8:
				print("ha-check:   %s %s \"%s\" %s %s" % [f.get("kind"), f.get("path"), str(f.get("text", "")).left(50), str(f.get("rect")), str(f.get("other", ""))])
				shown += 1
		_ok(int(audit.get("errors", 0)) == 0, "UiAudit finds no errors in the window")
		modal.call("_select", HaTargets.item_target_id(load_id, "power"))
		await _settle(tree, 10)
		_shot(main, "04_live_links_load")
		var frame: Variant = modal.get("_frame")
		if frame != null:
			frame.call("close")
	# Presets: the single-relay Shelly is found and links the load in one go.
	main.call("open_ha_presets", "")
	await _settle(tree, 20)
	var pm: Node = _find(main, func(n: Node) -> bool:
		return n.get_script() != null and str((n.get_script() as Script).resource_path).ends_with("ha_presets_modal.gd"))
	_ok(pm != null, "the presets window opens")
	if pm != null:
		var popt: OptionButton = pm.get("_preset_opt")
		for i in popt.item_count:
			if popt.get_item_text(i).begins_with("Shelly plug"):
				popt.select(i)
				popt.item_selected.emit(i)
		await _settle(tree, 5)
		var lopt: OptionButton = (pm.get("_item_opts") as Dictionary).get("acload", null)
		if lopt != null:
			var ids: Array = (pm.get("_item_ids") as Dictionary)["acload"]
			var li := ids.find(load_id)
			if li >= 0:
				lopt.select(li)
				lopt.item_selected.emit(li)
		await _settle(tree, 5)
		var plan: Array = pm.get("_plan")
		_ok(plan.size() == 2, "the plug preset plans power + switch for the load (%d)" % plan.size())
		_shot(main, "06_presets")
		var ab: Button = pm.get("_apply_btn")
		HarnessInput.click(main.get_viewport(), HarnessInput.center_of(ab))
		await _settle(tree, 20)
		var pl2: Dictionary = linker.call("link_for_target", HaTargets.item_target_id(load_id, "power"))
		_ok(str(pl2.get("entity_id", "")) == "sensor.shellyplus1pm_probe_switch_0_power", "Make links linked the plug's power to the load")
	linker.call("unlink_target", HaTargets.item_target_id(load_id, "switch"))
	linker.call("unlink_target", HaTargets.item_target_id(load_id, "power"))
	await _settle(tree, 5)
	var hl: Dictionary = model.get_item(load_id).get("specs", {}).get("ha_live", {})
	_ok(not hl.has("power"), "unlinking clears the node's live badge")
	if added_load:
		model.remove_item(load_id)
	return _finish(main, srv, svc, ts0)


func _finish(main: Node, srv: HaFakeServer, svc: Node, ts0: float) -> Dictionary:
	svc.call("disconnect_ha")
	srv.stop()
	srv.queue_free()
	main.set("time_scale", ts0)
	return {"ok": _fails.is_empty(), "fails": _fails}
