extends RefCounted

## SCADA Phase 4, second part, on a real world (sandbox): control logic
## everywhere the simulation runs, and the helpers round it.
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/scada_logic_more_check.gd -Label scada_logic_more -Timeout 1200
## - the tri-clamp Process Lab: Control blocks… opens the same window on the
##   design's own tags; a PID on the brew kettle's element holds 65 °C through
##   the whole pre-run;
## - the graph: Suggest gains (a step test on a copy) with a real click, Use
##   these gains, Export for Home Assistant, the duty / standby template;
## - a pre-render runs the logic (the day tank reaches its setpoint in the
##   rendered future), hands the world and the logic's state back, and the
##   replay shows it; nothing counts as an edit;
## - an A/B world runs the same blocks on its own copy;
## - the loop's faceplate carries a small trend.
## Removes what it made. Shots under screenshots/scada_logic_more/.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("scada-logic2 %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func _shot(main: Node, name: String) -> void:
	var dir := "user://screenshots/scada_logic_more"
	DirAccess.make_dir_recursive_absolute(dir)
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [dir, name])


func _specs(model: GraphModel, id: String) -> Dictionary:
	return model.get_item(id).get("specs", {}) as Dictionary


func _click(vp: Viewport, tree: SceneTree, c: Control) -> void:
	await HarnessInput.mouse_move(vp, HarnessInput.center_of(c))
	await _settle(tree, 2)
	await HarnessInput.click(vp, HarnessInput.center_of(c))
	await _settle(tree, 10)


func _run_clock(main: Node, tree: SceneTree, sim_hours: float, scale: float) -> void:
	var h0 := float(main.call("get_absolute_hours"))
	main.set("time_scale", scale)
	var guard := 0
	while float(main.call("get_absolute_hours")) - h0 < sim_hours and guard < 6000:
		await tree.process_frame
		guard += 1
	main.set("time_scale", 0.0)
	await _settle(tree, 20)


func _editor_under(n: Node) -> Node:
	for ch in n.get_children():
		if ch.has_method("add_template") and ch.has_method("block_ids"):
			return ch
	return null


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var vp := main.get_viewport()
	main.set("time_scale", 0.0)
	await _tc_part(main, tree, vp)
	await _graph_part(main, tree, vp)
	return {"ok": _fails.is_empty(), "fails": _fails}


# ── the tri-clamp Process Lab ───────────────────────────────────────────────

func _tc_part(main: Node, tree: SceneTree, vp: Viewport) -> void:
	var ui: Control = main.call("open_tclab", {})
	await _settle(tree, 20)
	if ui == null:
		_ok(false, "the tri-clamp designer opens")
		return
	ui.call("load_builtin", "brew_kettle")
	await _settle(tree, 8)
	var mb := ui.find_child("mode_process", true, false) as Control
	await _click(vp, tree, mb)
	var panel: Node = ui.call("process_panel")
	panel.call("show_right", "control")
	await _settle(tree, 6)
	var lb := ui.find_child("proc_logic_btn", true, false) as Button
	_ok(lb != null, "the Control tab has Control blocks…")
	if lb == null:
		ui.call("close")
		return
	var sc := lb.get_parent()
	while sc != null and not (sc is ScrollContainer):
		sc = sc.get_parent()
	if sc != null:
		(sc as ScrollContainer).ensure_control_visible(lb)
		await _settle(tree, 4)
	await _click(vp, tree, lb)
	var host: Node = panel.get("_logic_host")
	var ed: Node = _editor_under(host) if host != null else null
	_ok(ed != null and bool(ed.call("is_open")), "a click opens the control logic window on the design")
	if ed == null:
		ui.call("close")
		return
	var book: ScadaTags = host.call("book")
	var sim: TcProcSim = panel.get("sim")
	var temp_key := ""
	var power_key := ""
	for e in sim.control_sensors:
		if str(e.get("unit", "")) == "°C" and str(e["key"]).ends_with("_p4"):
			temp_key = str(e["key"])
	for a in sim.control_acts:
		if str(a["kind"]) == "number" and str(a["key"]).ends_with("_power"):
			power_key = str(a["key"])
	_ok(not temp_key.is_empty() and book.has(temp_key) and book.has(power_key), "its tags are the kettle's own thermometer and element")
	await _click(vp, tree, ed.call("button", "add_hold_level_pid"))
	var ids: Array = ed.call("block_ids")
	_ok(ids.size() == 1, "a click on a template adds a block to the design")
	if ids.size() == 1:
		var blk: Dictionary = (host.call("logic_block", str(ids[0])) as Dictionary).duplicate(true)
		blk.merge({"name": "Hold the mash at 65", "pv": temp_key, "out": power_key, "sp": 65.0, "kp": 20.0, "ti_min": 15.0}, true)
		host.call("set_logic_blocks", [blk])
		await _settle(tree, 10)
	_shot(main, "01_tc_logic_window")
	ed = _editor_under(host)
	if ed != null:
		ed.call("close")
	await _settle(tree, 10)
	_ok(((panel.get("proc") as Dictionary).get("logic", []) as Array).size() == 1, "the block is saved on the design's process")
	var pre := ui.find_child("proc_prerun", true, false) as Button
	if pre != null:
		pre.pressed.emit()
	var frames := 0
	await _settle(tree, 5)
	while bool(panel.get("prerunning")) and frames < 9000:
		await tree.process_frame
		frames += 1
	sim = panel.get("sim")
	var temp := float(TcProcControl.read_all(sim, sim.control_sensors, {temp_key: true}).get(temp_key, NAN))
	var hours := sim.t_s / 3600.0
	print("scada-logic2: kettle after %.1f h at %.1f °C, element %.0f W" % [hours, temp, float(sim.heater_w.get("p5", 0.0))])
	_ok(hours > 1.0 and absf(temp - 65.0) < 3.0, "through the whole pre-run the loop holds the kettle at 65 °C (%.1f after %.1f h)" % [temp, hours])
	_shot(main, "02_tc_held")
	# Leave the design as it was.
	panel.call("_edit", ["logic"], [])
	await _settle(tree, 6)
	ui.call("close")
	await _settle(tree, 20)


# ── the graph ───────────────────────────────────────────────────────────────

func _graph_part(main: Node, tree: SceneTree, vp: Viewport) -> void:
	var view: Node = ServiceLocator.graph()
	var hub: Node = view.call("scada_hub")
	var model: GraphModel = view.get("model")
	var saved_logic: Dictionary = hub.call("logic_data")
	var a := "lg2_a"
	var b := "lg2_b"
	var c := "lg2_c"
	var cv := "lg2_cv"
	var dv := "lg2_dv"
	model.add_item({"id": a, "type": "resource", "x": -900.0, "y": -3400.0, "specs": {"name": "Logic2 Cistern",
		"resource_kind": "water", "capacity_qty": 20000.0, "capacity_unit": "L", "level": 0.9}})
	model.add_item({"id": b, "type": "resource", "x": -500.0, "y": -3400.0, "specs": {"name": "Logic2 Day Tank",
		"resource_kind": "water", "capacity_qty": 1000.0, "capacity_unit": "L", "level": 0.2}})
	model.add_item({"id": c, "type": "resource", "x": -100.0, "y": -3400.0, "specs": {"name": "Logic2 Sump",
		"resource_kind": "water", "capacity_qty": 20000.0, "capacity_unit": "L", "level": 0.0}})
	model.add_item({"id": cv, "type": "processor", "x": -700.0, "y": -3400.0,
		"specs": FlowCtl.make_specs("Logic2 Control Valve", FlowCtl.KIND_VALVE, "water", 600.0, {"throttle": true})})
	model.add_item({"id": dv, "type": "processor", "x": -300.0, "y": -3400.0,
		"specs": FlowCtl.make_specs("Logic2 Drain", FlowCtl.KIND_VALVE, "water", 200.0)})
	for w in [[a, "output", cv, "res_in_0"], [cv, "res_out_0", b, "input"], [b, "output", dv, "res_in_0"], [dv, "res_out_0", c, "input"]]:
		model.add_connection({"polarity": "resource", "resource_type": "water", "source_item_id": w[0],
			"source_handle_id": w[1], "target_item_id": w[2], "target_handle_id": w[3]})
	await _settle(tree, 10)
	var open_tag := "valve.%s.open" % cv
	var lvl_tag := "tank.%s.level" % b
	var bid := str(hub.call("new_logic_id"))
	var pid := ScadaLogic.template("hold_level_pid", bid, {"pv": lvl_tag, "out": open_tag})
	pid.merge({"kp": 1.0, "ti_min": 200.0, "mode": "manual", "manual_out": 33.0}, true)
	var band := ScadaLogic.template("hold_level_band", "zz_band", {"pv": "tank.%s.level" % c, "out": "node.%s" % dv})
	band["enabled"] = false
	hub.call("set_logic_blocks", [pid, band])

	# ---- tuning + export + duty, in the window ----
	view.call("open_graph_view")
	await _settle(tree, 20)
	var ed: Node = view.call("open_logic_editor", bid)
	await _settle(tree, 15)
	var tb: Button = ed.call("button", "tune_btn")
	_ok(tb != null, "a PID's form offers Suggest gains")
	var level0 := float(_specs(model, b).get("level", 0.0))
	if tb != null:
		var scr := tb.get_parent()
		while scr != null and not (scr is ScrollContainer):
			scr = scr.get_parent()
		if scr != null:
			(scr as ScrollContainer).ensure_control_visible(tb)
			await _settle(tree, 4)
		var t0 := Time.get_ticks_msec()
		await _click(vp, tree, tb)
		var tune: Dictionary = ed.call("last_tune")
		print("scada-logic2: step test %d ms: %s" % [Time.get_ticks_msec() - t0, str((tune.get("gains", {}) as Dictionary))])
		_ok(bool(tune.get("ok", false)) and str((tune.get("fit", {}) as Dictionary).get("kind", "")) == "integrating", "a click runs a step test on a copy and reads the tank as a ramp")
		_ok(is_equal_approx(float(_specs(model, b).get("level", 0.0)), level0), "the world's own tank did not move")
		var use: Button = ed.call("button", "tune_use")
		_ok(use != null, "it offers Use these gains")
		_shot(main, "03_tune")
		if use != null:
			await _click(vp, tree, use)
			var nb: Dictionary = hub.call("logic_block", bid)
			_ok(float(nb.get("kp", 0.0)) > 1.5 and float(nb.get("ti_min", 0.0)) < 200.0, "a click writes them onto the block (gain %s, Ti %s min)" % [str(nb.get("kp")), str(nb.get("ti_min"))])
	var ex: Button = ed.call("button", "export_btn")
	_ok(ex != null, "the window has Export for Home Assistant")
	if ex != null:
		await _click(vp, tree, ex)
		var er: Dictionary = ed.call("last_export")
		_ok(str(er.get("yaml", "")).contains("platform: pid") and FileAccess.file_exists("user://scada_export/logic.yaml"), "a click writes the YAML (a PID as an ESPHome snippet) and saves it")
		_ok(DisplayServer.clipboard_get().begins_with("# Control logic"), "and copies it")
	await _click(vp, tree, ed.call("button", "add_duty_standby"))
	_ok(ed.call("field", "f_out_a") != null and ed.call("field", "f_swap_h") != null, "the duty / standby template has its two machines and its turn length")
	_shot(main, "04_duty_form")
	var audit: Dictionary = UiAudit.run(tree.root)
	print("scada-logic2: audit %s" % UiAudit.summary_line(audit))
	_ok(int(audit.get("errors", 0)) == 0, "UiAudit finds no errors (%d)" % int(audit.get("errors", 0)))
	ed.call("close")
	await _settle(tree, 10)
	# Only the tuned loop from here.
	var tuned: Dictionary = (hub.call("logic_block", bid) as Dictionary).duplicate(true)
	tuned["mode"] = "auto"
	hub.call("set_logic_blocks", [tuned])
	hub.call("logic_command", bid, "auto")
	view.call("close_graph_view")
	await _settle(tree, 10)

	# ---- an A/B world runs the blocks on its copy ----
	var su: Node = main.get_node_or_null("UILayer/SolarUI")
	var w := ExperimentWorld.from_live(model, su, main.get("clock"))
	w.enable_flow(view)
	_ok(w.logic != null and w.logic.blocks.size() == 1, "an A/B world takes the site's control logic")
	if w.logic != null:
		var t := float(main.call("get_absolute_hours"))
		w.before_step(t, 8.0, true)
		for i in 360:
			t += 1.0 / 60.0
			w.before_step(t, 8.0, true)
		var copy_lvl := ScadaLogicRun.read_model(w.model, lvl_tag)
		_ok(absf(copy_lvl - 50.0) < 5.0, "and its copy of the day tank is held at 50 %% (%.1f)" % copy_lvl)
		_ok(is_equal_approx(float(_specs(model, b).get("level", 0.0)), level0), "while the world's tank stays where it was")

	# ---- the pre-render ----
	var rend: Node = view.call("sim_renderer")
	var now := float(main.call("get_absolute_hours"))
	var rev0 := int(model.get("user_rev"))
	var i0 := float(((hub.get("_logic_state") as Dictionary).get(bid, {}) as Dictionary).get("i", 0.0))
	var res: Dictionary = rend.call("start", now + 6.0)
	_ok(bool(res.get("ok", false)), "a render of the next 6 h starts (%s)" % str(res.get("why", "")))
	if bool(res.get("ok", false)):
		var guard := 0
		while bool(rend.call("is_active")) and guard < 6000:
			await tree.process_frame
			guard += 1
		await _settle(tree, 10)
		_ok(absf(float(_specs(model, b).get("level", 0.0)) - level0) < 0.01, "after it the day tank is back at the playhead's level")
		var i1 := float(((hub.get("_logic_state") as Dictionary).get(bid, {}) as Dictionary).get("i", 0.0))
		_ok(absf(i1 - i0) < 0.5, "and the loop's own integral is as it was (%.2f, was %.2f)" % [i1, i0])
		_ok(int(model.get("user_rev")) == rev0, "the render's logic writes are not edits")
		main.call("set_absolute_hours", now + 5.5)
		await _settle(tree, 40)
		var lvl := float(_specs(model, b).get("level", 0.0)) * 100.0
		var opn := float(_specs(model, cv).get("open", 1.0)) * 100.0
		var stt: Dictionary = (hub.call("logic_status") as Dictionary).get(bid, {}) as Dictionary
		print("scada-logic2: replay at +5.5 h: tank %.1f %%, valve %.1f %%, %s" % [lvl, opn, str(stt.get("text", ""))])
		_ok(bool(view.call("is_replaying")), "inside the range the world replays")
		_ok(absf(lvl - 50.0) < 5.0 and opn > 15.0 and opn < 60.0, "the rendered future has the loop holding 50 %% (%.1f %%, valve %.1f %%)" % [lvl, opn])
		_ok(str(stt.get("text", "")).begins_with("Auto") and absf(float(stt.get("pv", 0.0)) - 50.0) < 5.0, "the loop shows what the render reached there")
		main.call("set_absolute_hours", now)
		await _settle(tree, 20)
		rend.call("invalidate_all")
		await _settle(tree, 10)

	# ---- the faceplate's trend ----
	await _run_clock(main, tree, 1.0, 0.05)
	view.call("open_graph_view")
	await _settle(tree, 20)
	var chips: Dictionary = view.get("_mode_chip_btns")
	await _click(vp, tree, chips["process"])
	await _settle(tree, 20)
	var canvas: Control = view.get("_graph_canvas")
	var lens: Control = canvas.call("process_lens")
	var mimic: Control = lens.get("mimic")
	lens.call("refresh", true)
	lens.call("fit")
	await _settle(tree, 10)
	var bubble: Dictionary = mimic.call("element_by_id", "ins:logic:" + bid)
	_ok(not bubble.is_empty(), "the loop is in the picture")
	if not bubble.is_empty():
		var pb: Vector2 = mimic.get_global_transform() * (mimic.call("element_rect", bubble) as Rect2).get_center()
		await HarnessInput.mouse_move(vp, pb)
		await _settle(tree, 3)
		await HarnessInput.click(vp, pb)
		await _settle(tree, 10)
		var face: PanelContainer = lens.call("faceplate")
		_ok(face != null and face.visible and int(face.call("trend_points")) > 10, "its faceplate draws a trend of the reading and the output (%d points)" % (int(face.call("trend_points")) if face != null else 0))
		_shot(main, "05_faceplate_trend")
		await HarnessInput.key(vp, KEY_ESCAPE)
		await _settle(tree, 6)

	# ---- clean up ----
	hub.call("set_logic_data", saved_logic)
	view.call("_apply_graph_view_mode", GraphSiteLayout.VIEW_FREEFORM)
	for id in [cv, dv, a, b, c]:
		model.remove_item(id)
	view.call("close_graph_view")
	await _settle(tree, 10)
