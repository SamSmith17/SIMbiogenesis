extends RefCounted

## SCADA Phase 7 on a real world (sandbox), against HaFakeServer on 127.0.0.1:
## nothing reaches a real Home Assistant.
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/scada_outputs_check.gd -Label scada_outputs -Timeout 900
## - a seeded pump and control valve, linked to a fake switch and number;
## - arming is refused in a test run, then (allowed for this check) refused
##   outside Live mode: nothing is sent;
## - in Live mode a REAL click on Arm sends each output's value and touches
##   the heartbeat; a change in the game is sent; an unchanged value is not;
## - the lens shows the ARMED bar, the first-person HUD the ARMED chip;
## - leaving Live mode disarms and puts every output to its safe state, and
##   nothing more is sent; a real click on the bar's Disarm does the same;
##   losing Home Assistant disarms;
## - arming is never saved and moves no edit counter;
## - the watchdog automation names the heartbeat and the safe states;
## - operator mode: a real click on Operate folds the sidebars, hides the
##   Add tools, refuses a tool; Esc leaves it;
## - UiAudit. Removes what it made. Shots under screenshots/scada_outputs/.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("scada-out %s: %s" % ["PASS" if cond else "FAIL", what])
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
	var dir := "user://screenshots/scada_outputs"
	DirAccess.make_dir_recursive_absolute(dir)
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [dir, name])


func _click(vp: Viewport, tree: SceneTree, c: Control) -> void:
	await HarnessInput.mouse_move(vp, HarnessInput.center_of(c))
	await _settle(tree, 2)
	await HarnessInput.click(vp, HarnessInput.center_of(c))
	await _settle(tree, 10)


## The calls the fake server got for one entity: ["switch.turn_on", …].
func _calls(srv: HaFakeServer, entity: String) -> Array:
	var out: Array = []
	for c in srv.service_calls:
		if str((c.get("target", {}) as Dictionary).get("entity_id", "")) == entity:
			out.append("%s.%s%s" % [str(c["domain"]), str(c["service"]),
				(" %s" % str((c["service_data"] as Dictionary).values()[0])) if not (c["service_data"] as Dictionary).is_empty() else ""])
	return out


func _go_live(main: Node, tree: SceneTree, on: bool) -> void:
	var ssc := tree.root.get_node_or_null("SimSettingsController")
	var td := tree.root.get_node_or_null("TimeDirector")
	if on:
		if ssc != null:
			ssc.call("set_live_mode", true)
		main.set("time_scale", 1.0 / 3600.0)
	else:
		main.set("time_scale", 60.0 / 3600.0)
	await _until(tree, func() -> bool: return td == null or bool(td.call("is_live")) == on, 4.0)
	await _settle(tree, 10)


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var vp := main.get_viewport()
	var view: Node = ServiceLocator.graph()
	var hub: Node = view.call("scada_hub") if view != null else null
	var svc: Node = tree.root.get_node_or_null("HomeAssistant")
	_ok(hub != null and hub.has_method("arm") and svc != null, "the hub has outputs and the Home Assistant service is up")
	if hub == null or svc == null:
		return {"ok": false, "fails": _fails}
	var model: GraphModel = view.get("model")
	var ts0 := float(main.get("time_scale"))
	var ssc := tree.root.get_node_or_null("SimSettingsController")
	var live0 := bool(ssc.get("live_mode_enabled")) if ssc != null else false
	var td := tree.root.get_node_or_null("TimeDirector")
	main.set("time_scale", 0.0)
	var saved_links: Array = hub.call("output_links")
	var saved_settings: Dictionary = hub.call("output_settings")

	var pump := "out_test_pump"
	var cv := "out_test_cv"
	var a := "out_test_a"
	var b := "out_test_b"
	model.add_item({"id": pump, "type": "acload", "x": -900.0, "y": -4400.0, "specs": {"name": "Output Test Pump", "avg_watts": 120.0, "current_state": "off", "requested_state": "off"}})
	model.add_item({"id": a, "type": "resource", "x": -900.0, "y": -4200.0, "specs": {"name": "Output Test Cistern", "resource_kind": "water", "capacity_qty": 5000.0, "capacity_unit": "L", "level": 0.6}})
	model.add_item({"id": b, "type": "resource", "x": -500.0, "y": -4200.0, "specs": {"name": "Output Test Tank", "resource_kind": "water", "capacity_qty": 1000.0, "capacity_unit": "L", "level": 0.3}})
	model.add_item({"id": cv, "type": "processor", "x": -700.0, "y": -4200.0,
		"specs": FlowCtl.make_specs("Output Test Valve", FlowCtl.KIND_VALVE, "water", 600.0, {"throttle": true})})
	for w in [[a, "output", cv, "res_in_0"], [cv, "res_out_0", b, "input"]]:
		model.add_connection({"polarity": "resource", "resource_type": "water", "source_item_id": w[0],
			"source_handle_id": w[1], "target_item_id": w[2], "target_handle_id": w[3]})
	await _settle(tree, 10)
	hub.call("refresh")
	var vtag := "valve.%s.open" % cv
	_ok(not is_nan(float(hub.call("read_now", vtag))), "the control valve's opening is a tag (%.0f %%)" % float(hub.call("read_now", vtag)))
	hub.call("command", vtag, 40.0)

	# ---- the fake Home Assistant ----
	var tok := "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJwcm9iZTAxMjM0NTY3ODlhYmNkZWYiLCJpYXQiOjE3MDAwMDAwMDB9.probeprobeprobeprobeprobeprobeprobeprobe_-xy"
	var srv := HaFakeServer.new()
	srv.token = tok
	srv.location_name = "Output Probe"
	srv.set_entity("switch.test_pump", "off", {"friendly_name": "Test pump"})
	srv.set_entity("number.test_valve", "0", {"friendly_name": "Test valve", "unit_of_measurement": "%"})
	srv.set_entity("input_boolean.test_heartbeat", "off", {"friendly_name": "Game heartbeat"})
	main.add_child(srv)
	srv.start(38900 + randi() % 300)
	svc.call("connect_with", "127.0.0.1:%d" % srv.port, tok, "Output probe", false)
	var ok := await _until(tree, func() -> bool: return bool(svc.call("is_authed")), 8.0)
	_ok(ok, "connected to the fake Home Assistant on 127.0.0.1:%d" % srv.port)
	await _settle(tree, 20)

	hub.call("set_output_links", [
		{"id": "o1", "tag": "node.%s" % pump, "entity_id": "switch.test_pump", "safe": "off"},
		{"id": "o2", "tag": vtag, "entity_id": "number.test_valve", "safe": 5.0, "deadband": 1.0, "min_interval_s": 0.3}])
	hub.call("set_output_settings", {"heartbeat_entity": "input_boolean.test_heartbeat", "heartbeat_s": 2.0, "timeout_s": 30.0})
	_ok((hub.call("output_checks") as Array).is_empty(), "the two links and the heartbeat pass the checks (%s)" % str(hub.call("output_checks")))

	# ---- refusals ----
	var why := str(hub.call("arm"))
	_ok(why.contains("test run") and not bool(hub.call("outputs_armed")), "arming is refused in a test run (%s)" % why)
	hub.set("test_allow_arm", true)
	await _go_live(main, tree, false)
	why = str(hub.call("arm"))
	_ok(why.contains("Live mode") and not bool(hub.call("outputs_armed")), "outside Live mode arming is refused (%s)" % why)
	await tree.create_timer(1.2).timeout
	_ok(srv.service_calls.is_empty(), "and nothing has been sent (%d)" % srv.service_calls.size())

	# ---- the window, from the lens ----
	view.call("open_graph_view")
	await _settle(tree, 20)
	var chips: Dictionary = view.get("_mode_chip_btns")
	await _click(vp, tree, chips["process"])
	await _settle(tree, 20)
	var canvas: Control = view.get("_graph_canvas")
	var lens: Control = canvas.call("process_lens")
	var hb: Button = lens.find_child("hardware_btn", true, false)
	_ok(hb != null and hb.is_visible_in_tree(), "the lens has a Hardware button")
	await _click(vp, tree, hb)
	var panel: Node = view.get("_outputs_panel")
	_ok(panel != null and is_instance_valid(panel) and bool(panel.call("is_open")), "a click opens the Hardware window")
	if panel == null:
		return await _finish(main, tree, hub, svc, srv, model, [pump, cv, a, b], saved_links, saved_settings, ts0, live0)
	await _settle(tree, 40)
	var arm_btn: Button = panel.call("button", "arm")
	_ok(arm_btn != null and arm_btn.disabled, "Arm is greyed out outside Live mode")
	_ok(panel.call("field", "o_o1_entity_id") != null and panel.call("field", "o_o2_scale") != null and panel.call("field", "hb_entity") != null,
		"it lists both outputs and the heartbeat")
	_shot(main, "01_not_live")
	var audit: Dictionary = UiAudit.run(tree.root)
	print("scada-out: audit (window) %s" % UiAudit.summary_line(audit))
	_ok(int(audit.get("errors", 0)) == 0, "UiAudit finds no errors on the Hardware window (%d)" % int(audit.get("errors", 0)))

	# ---- Live: arm with a real click ----
	await _go_live(main, tree, true)
	_ok(td == null or bool(td.call("is_live")), "1× with Live mode on reads as Live")
	await tree.create_timer(0.8).timeout
	arm_btn = panel.call("button", "arm")
	_ok(arm_btn != null and not arm_btn.disabled, "in Live mode Arm is offered")
	var rev0 := model.user_rev
	if arm_btn != null:
		await _click(vp, tree, arm_btn)
	_ok(bool(hub.call("outputs_armed")), "a REAL click arms the outputs")
	await tree.create_timer(1.6).timeout
	_ok(_calls(srv, "switch.test_pump") == ["switch.turn_off"], "the pump's switch is sent its state (%s)" % str(_calls(srv, "switch.test_pump")))
	_ok(_calls(srv, "number.test_valve") == ["number.set_value 40.0"] or _calls(srv, "number.test_valve") == ["number.set_value 40"], "the valve's number is sent its opening (%s)" % str(_calls(srv, "number.test_valve")))
	_ok(_calls(srv, "input_boolean.test_heartbeat").size() >= 1, "the heartbeat is touched (%d)" % _calls(srv, "input_boolean.test_heartbeat").size())
	_ok(model.user_rev == rev0, "arming and sending are not edits (user_rev %d → %d)" % [rev0, model.user_rev])
	_shot(main, "02_armed_window")
	panel.call("close")
	await _settle(tree, 20)
	var bar: PanelContainer = lens.call("armed_bar")
	var btxt := (bar.find_child("armed_text", true, false) as Label).text if bar != null else ""
	_ok(bar != null and bar.visible and btxt.contains("ARMED") and btxt.contains("2 outputs"), "the lens shows the ARMED bar (%s)" % btxt)
	await tree.create_timer(4.5).timeout
	_shot(main, "03_armed_lens")
	audit = UiAudit.run(tree.root)
	print("scada-out: audit (lens) %s" % UiAudit.summary_line(audit))
	_ok(int(audit.get("errors", 0)) == 0, "UiAudit finds no errors on the lens with the bar up (%d)" % int(audit.get("errors", 0)))

	# ---- changes are sent, repeats are not ----
	var n_before := srv.service_calls.size() - _calls(srv, "input_boolean.test_heartbeat").size()
	await tree.create_timer(1.5).timeout
	_ok(srv.service_calls.size() - _calls(srv, "input_boolean.test_heartbeat").size() == n_before, "an unchanged value is not sent again")
	hub.call("command", "node.%s" % pump, 1.0)
	hub.call("command", vtag, 70.0)
	await tree.create_timer(1.8).timeout
	_ok(_calls(srv, "switch.test_pump").back() == "switch.turn_on", "switching the pump on in the game switches the entity on (%s)" % str(_calls(srv, "switch.test_pump")))
	_ok(str(_calls(srv, "number.test_valve").back()).begins_with("number.set_value 70"), "the valve's new opening is sent (%s)" % str(_calls(srv, "number.test_valve")))
	hub.call("command", vtag, 70.4)
	await tree.create_timer(1.2).timeout
	_ok(_calls(srv, "number.test_valve").size() == 2, "a move inside the deadband is not sent")
	_ok((hub.call("output_journal") as Array).size() >= 4, "the journal lists what was sent (%d lines)" % (hub.call("output_journal") as Array).size())

	# ---- the HUD chip ----
	view.call("close_graph_view")
	await _settle(tree, 50)
	var chip_host: Control = view.call("armed_chip")
	var chip: Button = chip_host.call("chip") if chip_host != null and is_instance_valid(chip_host) else null
	_ok(chip != null and chip.visible and chip.text.contains("ARMED"), "in first person the HUD says ARMED (%s)" % (chip.text if chip != null else "none"))
	_shot(main, "04_hud_chip")

	# ---- leaving Live mode disarms and puts everything safe ----
	await _go_live(main, tree, false)
	await tree.create_timer(1.2).timeout
	_ok(not bool(hub.call("outputs_armed")) and str(hub.call("disarm_reason")).contains("Live"), "leaving Live mode disarms (%s)" % str(hub.call("disarm_reason")))
	_ok(_calls(srv, "switch.test_pump").back() == "switch.turn_off", "the pump is put to its safe state, off")
	_ok(str(_calls(srv, "number.test_valve").back()).begins_with("number.set_value 5"), "the valve to its safe 5 (%s)" % str(_calls(srv, "number.test_valve").back()))
	var n_safe := srv.service_calls.size()
	hub.call("command", vtag, 90.0)
	await tree.create_timer(1.5).timeout
	_ok(srv.service_calls.size() == n_safe, "disarmed, nothing more is sent (not even the heartbeat)")
	_ok(chip != null and not chip.visible, "the HUD chip goes")

	# ---- Disarm by a real click on the lens's bar ----
	await _go_live(main, tree, true)
	_ok(str(hub.call("arm")) == "" and bool(hub.call("outputs_armed")), "armed again in Live mode")
	view.call("open_graph_view")
	await _settle(tree, 40)
	bar = lens.call("armed_bar")
	var dis: Button = bar.find_child("armed_disarm", true, false) if bar != null else null
	_ok(dis != null and dis.is_visible_in_tree(), "the ARMED bar has Disarm")
	if dis != null:
		await _click(vp, tree, dis)
	_ok(not bool(hub.call("outputs_armed")) and str(hub.call("disarm_reason")) == "by hand", "a REAL click on Disarm disarms")
	await _settle(tree, 30)
	_ok(bar != null and not bar.visible, "and the bar goes")

	# ---- editing disarms; losing Home Assistant disarms ----
	_ok(str(hub.call("arm")) == "", "armed once more")
	var links: Array = hub.call("output_links")
	links[0]["safe"] = "hold"
	hub.call("set_output_links", links)
	_ok(not bool(hub.call("outputs_armed")), "editing an output disarms first")
	links[0]["safe"] = "off"
	hub.call("set_output_links", links)
	_ok(str(hub.call("arm")) == "", "armed for the last time")
	svc.call("disconnect_ha")
	await tree.create_timer(1.4).timeout
	_ok(not bool(hub.call("outputs_armed")) and str(hub.call("disarm_reason")).contains("disconnected"), "losing Home Assistant disarms (%s)" % str(hub.call("disarm_reason")))
	_ok(str(hub.call("arm_refusal")) != "", "and arming is refused until it is back (%s)" % str(hub.call("arm_refusal")))

	# ---- armed is never saved; the watchdog ----
	var path := str(hub.get("_out_path"))
	var on_disk := FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""
	_ok(on_disk.contains("switch.test_pump") and not on_disk.contains("armed"), "the links are saved with the world, the armed state is not")
	var y: Dictionary = hub.call("watchdog_yaml")
	var yt := str(y.get("text", ""))
	_ok(yt.contains("input_boolean.test_heartbeat") and yt.contains("switch.turn_off") and yt.contains("number.set_value") and yt.contains("seconds: 30"),
		"the watchdog automation names the heartbeat and each safe state")

	# ---- operator mode ----
	var op: Button = lens.find_child("operate_btn", true, false)
	_ok(op != null and op.is_visible_in_tree(), "the lens has an Operate button")
	var tool_btn: Button = lens.find_child("tool_valve", true, false)
	if op != null:
		await _click(vp, tree, op)
		await _settle(tree, 20)
		_ok(bool(view.call("operator_mode")) and bool(lens.call("operator")), "a REAL click enters operator mode")
		_ok(not bool(view.get("_sidebar_l_open")) and not bool(view.get("_sidebar_r_open")), "the sidebars fold away")
		_ok(tool_btn != null and not tool_btn.is_visible_in_tree(), "the Add tools are gone")
		lens.call("set_tool", "valve")
		_ok(str(lens.call("tool")) == "", "no tool can be armed")
		var n_items := model.items.size()
		lens.call("_on_place", Vector2(0, 0), {})
		_ok(model.items.size() == n_items, "nothing can be placed")
		await tree.create_timer(3.4).timeout
		_shot(main, "05_operator")
		audit = UiAudit.run(tree.root)
		print("scada-out: audit (operator) %s" % UiAudit.summary_line(audit))
		_ok(int(audit.get("errors", 0)) == 0, "UiAudit finds no errors in operator mode (%d)" % int(audit.get("errors", 0)))
		await HarnessInput.key(vp, KEY_ESCAPE)
		await _settle(tree, 20)
		_ok(not bool(view.call("operator_mode")) and bool(view.get("visible")), "Esc leaves operator mode (the graph stays up)")
		_ok(tool_btn != null and tool_btn.is_visible_in_tree(), "and the Add tools are back")
	return await _finish(main, tree, hub, svc, srv, model, [pump, cv, a, b], saved_links, saved_settings, ts0, live0)


func _finish(main: Node, tree: SceneTree, hub: Node, svc: Node, srv: HaFakeServer, model: GraphModel, ids: Array,
		links: Array, settings: Dictionary, ts0: float, live0: bool) -> Dictionary:
	hub.call("disarm", "the check ended")
	hub.set("test_allow_arm", false)
	hub.call("set_output_links", links)
	hub.call("set_output_settings", settings)
	for id in ids:
		model.remove_item(str(id))
	svc.call("disconnect_ha")
	srv.stop()
	srv.queue_free()
	var ssc := tree.root.get_node_or_null("SimSettingsController")
	if ssc != null:
		ssc.call("set_live_mode", live0)
	main.set("time_scale", ts0)
	var view: Node = ServiceLocator.graph()
	if view != null and bool(view.get("visible")):
		view.call("close_graph_view")
	await _settle(tree, 10)
	return {"ok": _fails.is_empty(), "fails": _fails}
