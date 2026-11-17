extends RefCounted

## SCADA Phase 5 on a real world (sandbox): alarms, with REAL clicks.
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/scada_alarm_check.gd -Label scada_alarms -Timeout 900
## - a seeded line: cistern → valve → day tank; the lens's Alarms button opens
##   the window; Suggest for this site makes a high and a low for each store;
## - the clock runs, the day tank fills past its limit: the alarm raises once
##   (a toast, the journal), the tank is outlined in the picture, the alarm
##   bar says so, the rule's tag reads 1;
## - Acknowledge with a real click; Shelve puts it aside; an interlock block
##   reading the alarm's tag shuts the valve;
## - the first-person HUD chip shows while something is in alarm;
## - saved with the graph; none of it counts as an edit; UiAudit.
## Removes what it made. Shots under screenshots/scada_alarms/.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("scada-alarm %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func _shot(main: Node, name: String) -> void:
	var dir := "user://screenshots/scada_alarms"
	DirAccess.make_dir_recursive_absolute(dir)
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [dir, name])


func _specs(model: GraphModel, id: String) -> Dictionary:
	return model.get_item(id).get("specs", {}) as Dictionary


func _click(vp: Viewport, tree: SceneTree, c: Control) -> void:
	await HarnessInput.mouse_move(vp, HarnessInput.center_of(c))
	await _settle(tree, 2)
	await HarnessInput.click(vp, HarnessInput.center_of(c))
	await _settle(tree, 10)


func _run_until(main: Node, tree: SceneTree, scale: float, max_h: float, done: Callable) -> void:
	var h0 := float(main.call("get_absolute_hours"))
	main.set("time_scale", scale)
	var guard := 0
	while float(main.call("get_absolute_hours")) - h0 < max_h and guard < 8000 and not bool(done.call()):
		await tree.process_frame
		guard += 1
	main.set("time_scale", 0.0)
	await _settle(tree, 20)


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var vp := main.get_viewport()
	var view: Node = ServiceLocator.graph()
	var hub: Node = view.call("scada_hub") if view != null else null
	_ok(hub != null and hub.has_method("alarm_tick"), "the hub runs alarms")
	if hub == null:
		return {"ok": false, "fails": _fails}
	var model: GraphModel = view.get("model")
	main.set("time_scale", 0.0)
	var saved_alarms: Dictionary = hub.call("alarm_data")
	var saved_logic: Dictionary = hub.call("logic_data")
	hub.call("set_alarm_data", {})

	var a := "al_test_a"
	var b := "al_test_b"
	var cv := "al_test_cv"
	model.add_item({"id": a, "type": "resource", "x": -900.0, "y": -3800.0, "specs": {"name": "Alarm Test Cistern",
		"resource_kind": "water", "capacity_qty": 20000.0, "capacity_unit": "L", "level": 0.6}})
	model.add_item({"id": b, "type": "resource", "x": -500.0, "y": -3800.0, "specs": {"name": "Alarm Test Day Tank",
		"resource_kind": "water", "capacity_qty": 1000.0, "capacity_unit": "L", "level": 0.85}})
	model.add_item({"id": cv, "type": "processor", "x": -700.0, "y": -3800.0,
		"specs": FlowCtl.make_specs("Alarm Test Valve", FlowCtl.KIND_VALVE, "water", 600.0)})
	for w in [[a, "output", cv, "res_in_0"], [cv, "res_out_0", b, "input"]]:
		model.add_connection({"polarity": "resource", "resource_type": "water", "source_item_id": w[0],
			"source_handle_id": w[1], "target_item_id": w[2], "target_handle_id": w[3]})
	# Valve shut for now.
	hub.call("refresh")
	hub.call("command", "node.%s" % cv, 0.0)
	await _settle(tree, 10)

	# ---- the window, from the lens ----
	view.call("open_graph_view")
	await _settle(tree, 20)
	var chips: Dictionary = view.get("_mode_chip_btns")
	await _click(vp, tree, chips["process"])
	await _settle(tree, 20)
	var canvas: Control = view.get("_graph_canvas")
	var lens: Control = canvas.call("process_lens")
	var mimic: Control = lens.get("mimic")
	var ab: Button = lens.find_child("alarms_btn", true, false)
	_ok(ab != null and ab.is_visible_in_tree(), "the lens has an Alarms button")
	await _click(vp, tree, ab)
	var panel: Node = view.get("_alarm_panel")
	_ok(panel != null and is_instance_valid(panel) and bool(panel.call("is_open")) and str(panel.call("tab")) == "rules", "a click opens the alarm window, on Rules while there are none")
	if panel == null:
		return {"ok": false, "fails": _fails}
	await _click(vp, tree, panel.call("button", "suggest"))
	var rules: Array = hub.call("alarm_rules")
	var hi_id := ""
	var lo_n := 0
	for r in rules:
		if str(r["tag"]) == "tank.%s.level" % b and str(r["op"]) == ">=":
			hi_id = str(r["id"])
		if str(r["tag"]) == "tank.%s.level" % b and str(r["op"]) == "<=":
			lo_n += 1
	_ok(not hi_id.is_empty() and lo_n == 1, "Suggest for this site makes a high and a low for the day tank (%d rules in all)" % rules.size())
	_ok(panel.call("field", "r_%s_limit" % hi_id) != null, "each rule has its form")
	_shot(main, "01_rules")
	var audit: Dictionary = UiAudit.run(tree.root)
	print("scada-alarm: audit (rules) %s" % UiAudit.summary_line(audit))
	_ok(int(audit.get("errors", 0)) == 0, "UiAudit finds no errors on the rules (%d)" % int(audit.get("errors", 0)))
	# Only the day tank's high alarm from here, with no delay, medium.
	var keep: Array = []
	for r in rules:
		if str(r["id"]) == hi_id:
			var d: Dictionary = (r as Dictionary).duplicate(true)
			d["delay_s"] = 0.0
			keep.append(d)
	hub.call("set_alarm_rules", keep)
	panel.call("close")
	await _settle(tree, 10)

	# ---- it raises ----
	var rev0 := int(model.get("user_rev"))
	var raised: Array = []
	var on_raise := func(e: Dictionary) -> void: raised.append(e)
	hub.connect("alarm_raised", on_raise)
	hub.call("command", "node.%s" % cv, 1.0)
	rev0 = int(model.get("user_rev"))
	await _run_until(main, tree, 0.05, 1.0, func() -> bool: return not raised.is_empty())
	var st: Dictionary = (hub.call("alarm_status") as Dictionary).get(hi_id, {}) as Dictionary
	print("scada-alarm: day tank at %.1f %%, alarm %s: %s" % [float(_specs(model, b).get("level", 0.0)) * 100.0, str(st.get("state", "")), str(st.get("text", ""))])
	_ok(raised.size() == 1 and str(st.get("state", "")) == "unack", "the tank passes 95 %: the alarm raises, once")
	_ok(int(model.get("user_rev")) == rev0, "raising it is not an edit")
	var j: Array = hub.call("alarm_journal")
	_ok(not j.is_empty() and str(j[j.size() - 1]["what"]) == "raised", "the journal has it")
	hub.call("refresh")
	var book: ScadaTags = hub.call("book")
	_ok(book.has("alarm.%s" % hi_id) and book.value("alarm.%s" % hi_id) == 1.0, "the rule's tag reads 1")
	lens.call("refresh", true)
	await _settle(tree, 15)
	_ok(int(mimic.call("alarms_drawn")) == 1, "the tank is outlined in the picture")
	var bar: PanelContainer = lens.call("alarm_bar")
	var txt := (bar.find_child("alarm_text", true, false) as Label).text if bar != null else ""
	_ok(bar != null and bar.visible and txt.contains("Alarm Test Day Tank"), "the alarm bar names it (%s)" % txt)
	_ok(ab.text == "Alarms (1)", "the Alarms button counts it")
	# The graph's own toast for the alarm stands over the palette for a few
	# seconds: look after it has gone.
	await tree.create_timer(5.5).timeout
	_shot(main, "02_raised_in_lens")
	audit = UiAudit.run(tree.root)
	print("scada-alarm: audit (lens) %s" % UiAudit.summary_line(audit))
	_ok(int(audit.get("errors", 0)) == 0, "UiAudit finds no errors on the lens with the bar up (%d)" % int(audit.get("errors", 0)))

	# ---- an interlock reads the alarm ----
	var kid := str(hub.call("new_logic_id"))
	var lock := ScadaLogic.make("interlock", kid, "Shut the inlet on a high alarm")
	lock.merge({"when": [{"tag": "alarm.%s" % hi_id, "op": ">=", "value": 0.5}], "out": "node.%s" % cv, "safe": 0.0}, true)
	hub.call("set_logic_blocks", [lock])
	await _settle(tree, 20)
	_ok(str(_specs(model, cv).get("requested_state", "")) == "off", "a control block reading the alarm's tag shuts the valve")

	# ---- acknowledge, shelve ----
	await _click(vp, tree, bar.find_child("alarm_open", true, false) as Button)
	panel = view.get("_alarm_panel")
	_ok(panel != null and bool(panel.call("is_open")) and str(panel.call("tab")) == "active", "the bar's Alarms… opens the window on Now")
	var ack: Button = panel.call("button", "ack_%s" % hi_id)
	_ok(ack != null and not ack.disabled, "the alarm is listed with Acknowledge")
	_shot(main, "03_now")
	if ack != null:
		await _click(vp, tree, ack)
		await _settle(tree, 30)
		_ok(str(((hub.call("alarm_status") as Dictionary).get(hi_id, {}) as Dictionary).get("state", "")) == "acked", "a click acknowledges it: still in alarm, seen")
	var sh: Button = panel.call("button", "shelve_%s" % hi_id)
	if sh != null:
		await _click(vp, tree, sh)
		await _settle(tree, 30)
		_ok(str(((hub.call("alarm_status") as Dictionary).get(hi_id, {}) as Dictionary).get("state", "")) == "shelved", "a click shelves it")
		_ok(int((hub.call("alarm_summary") as Dictionary).get("count", 1)) == 0, "shelved, nothing is in alarm")
		var back: Button = panel.call("button", "unshelve_%s" % hi_id)
		_ok(back != null, "it is listed to bring back")
		if back != null:
			await _click(vp, tree, back)
			await _settle(tree, 30)
			_ok(str(((hub.call("alarm_status") as Dictionary).get(hi_id, {}) as Dictionary).get("state", "")) == "unack", "brought back, it raises again")
	await _click(vp, tree, panel.call("button", "tab_journal"))
	_shot(main, "04_journal")
	_ok((hub.call("alarm_journal") as Array).size() >= 5, "the journal has every step (%d)" % (hub.call("alarm_journal") as Array).size())
	panel.call("close")
	await _settle(tree, 10)

	# ---- saved ----
	var saved: Dictionary = view.call("collect_save_state")
	var sa: Dictionary = saved.get("scada_alarms", {}) as Dictionary
	_ok((sa.get("rules", []) as Array).size() == 1 and (sa.get("state", {}) as Dictionary).has(hi_id), "the rules and their states are saved with the graph")
	hub.call("set_alarm_data", {})
	hub.call("set_alarm_data", sa)
	_ok(str((hub.call("alarm_rule", hi_id) as Dictionary).get("tag", "")) == "tank.%s.level" % b, "and come back from what was saved")
	var t0 := Time.get_ticks_usec()
	for _i in 100:
		hub.call("alarm_tick")
	print("scada-alarm: one alarm pass %.3f ms" % (float(Time.get_ticks_usec() - t0) / 100000.0))

	# ---- the HUD chip ----
	view.call("_apply_graph_view_mode", GraphSiteLayout.VIEW_FREEFORM)
	view.call("close_graph_view")
	await _settle(tree, 90)
	var chip_host: Control = view.call("alarm_chip")
	var chip: Button = chip_host.call("chip") if chip_host != null and is_instance_valid(chip_host) else null
	_ok(chip != null and chip.is_visible_in_tree() and chip.text.contains("1 alarm"), "in first person a chip says an alarm is up (%s)" % (chip.text if chip != null else "no chip"))
	_shot(main, "05_hud_chip")
	hub.call("alarm_command", hi_id, "shelve", 1.0)
	await _settle(tree, 60)
	_ok(chip != null and not chip.visible, "and goes when nothing is in alarm")

	# ---- clean up ----
	hub.disconnect("alarm_raised", on_raise)
	hub.call("set_alarm_data", saved_alarms)
	hub.call("set_logic_data", saved_logic)
	for id in [cv, a, b]:
		model.remove_item(id)
	await _settle(tree, 10)
	return {"ok": _fails.is_empty(), "fails": _fails}
