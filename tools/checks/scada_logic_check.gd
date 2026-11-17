extends RefCounted

## SCADA Phase 4 on a real world (sandbox): control logic running live on the
## graph, with REAL clicks in the logic window and the Process lens.
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/scada_logic_check.gd -Label scada_logic -Timeout 900
## - a seeded line: cistern → control valve → day tank → drain valve → sump;
##   the control valve's opening is a tag;
## - the lens's Logic button opens the window; "Hold a level (PID)" adds a
##   block; its reading is picked through the tag list with real clicks;
## - the clock runs: the loop brings the day tank to its 50 % setpoint and
##   holds it with the valve part open; none of that counts as an edit;
## - the loop is a bubble on the tank in the picture; its faceplate's Manual
##   freezes the valve;
## - an interlock on the same valve forces it shut over the loop;
## - the logic is saved with the graph; UiAudit on the window.
## Removes what it made. Shots under screenshots/scada_logic/.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("scada-logic %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func _shot(main: Node, name: String) -> void:
	var dir := "user://screenshots/scada_logic"
	DirAccess.make_dir_recursive_absolute(dir)
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [dir, name])


func _specs(model: GraphModel, id: String) -> Dictionary:
	return model.get_item(id).get("specs", {}) as Dictionary


func _run_clock(main: Node, tree: SceneTree, sim_hours: float, scale: float) -> void:
	var h0 := float(main.call("get_absolute_hours"))
	main.set("time_scale", scale)
	var guard := 0
	while float(main.call("get_absolute_hours")) - h0 < sim_hours and guard < 6000:
		await tree.process_frame
		guard += 1
	main.set("time_scale", 0.0)
	await _settle(tree, 20)


func _click(vp: Viewport, tree: SceneTree, c: Control) -> void:
	await HarnessInput.mouse_move(vp, HarnessInput.center_of(c))
	await _settle(tree, 2)
	await HarnessInput.click(vp, HarnessInput.center_of(c))
	await _settle(tree, 10)


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var vp := main.get_viewport()
	var view: Node = ServiceLocator.graph()
	var hub: Node = view.call("scada_hub") if view != null else null
	_ok(hub != null and hub.has_method("logic_tick"), "the hub runs control logic")
	if hub == null:
		return {"ok": false, "fails": _fails}
	var model: GraphModel = view.get("model")
	main.set("time_scale", 0.0)
	var saved_logic: Dictionary = hub.call("logic_data")

	# ---- seed the line ----
	var a := "lg_test_a"
	var b := "lg_test_b"
	var c := "lg_test_c"
	var cv := "lg_test_cv"
	var dv := "lg_test_dv"
	model.add_item({"id": a, "type": "resource", "x": -900.0, "y": -3000.0, "specs": {"name": "Logic Test Cistern",
		"resource_kind": "water", "capacity_qty": 20000.0, "capacity_unit": "L", "level": 0.9}})
	model.add_item({"id": b, "type": "resource", "x": -500.0, "y": -3000.0, "specs": {"name": "Logic Test Day Tank",
		"resource_kind": "water", "capacity_qty": 1000.0, "capacity_unit": "L", "level": 0.2}})
	model.add_item({"id": c, "type": "resource", "x": -100.0, "y": -3000.0, "specs": {"name": "Logic Test Sump",
		"resource_kind": "water", "capacity_qty": 20000.0, "capacity_unit": "L", "level": 0.0}})
	model.add_item({"id": cv, "type": "processor", "x": -700.0, "y": -3000.0,
		"specs": FlowCtl.make_specs("Logic Test Control Valve", FlowCtl.KIND_VALVE, "water", 600.0, {"throttle": true})})
	model.add_item({"id": dv, "type": "processor", "x": -300.0, "y": -3000.0,
		"specs": FlowCtl.make_specs("Logic Test Drain", FlowCtl.KIND_VALVE, "water", 200.0)})
	for w in [[a, "output", cv, "res_in_0"], [cv, "res_out_0", b, "input"], [b, "output", dv, "res_in_0"], [dv, "res_out_0", c, "input"]]:
		model.add_connection({"polarity": "resource", "resource_type": "water", "source_item_id": w[0],
			"source_handle_id": w[1], "target_item_id": w[2], "target_handle_id": w[3]})
	await _settle(tree, 10)
	hub.call("refresh")
	var book: ScadaTags = hub.call("book")
	var open_tag := "valve.%s.open" % cv
	var lvl_tag := "tank.%s.level" % b
	_ok(book.has(open_tag) and bool(book.tag(open_tag).get("writable", false)), "the control valve's opening is a tag that can be driven")
	_ok(not book.has("valve.%s.open" % dv), "a plain valve has none")

	# ---- the window, from the lens ----
	view.call("open_graph_view")
	await _settle(tree, 20)
	var chips: Dictionary = view.get("_mode_chip_btns")
	await _click(vp, tree, chips["process"])
	await _settle(tree, 20)
	var canvas: Control = view.get("_graph_canvas")
	var lens: Control = canvas.call("process_lens")
	var mimic: Control = lens.get("mimic")
	var lb: Button = lens.find_child("logic_btn", true, false)
	_ok(lb != null and lb.is_visible_in_tree(), "the lens has a Logic button")
	await _click(vp, tree, lb)
	var ed: Node = null
	for ch in view.get_children():
		if ch.has_method("add_template") and ch.has_method("block_ids"):
			ed = ch
	_ok(ed != null and bool(ed.call("is_open")), "a click opens the control logic window")
	if ed == null:
		return {"ok": false, "fails": _fails}
	var n0: int = (ed.call("block_ids") as Array).size()
	await _click(vp, tree, ed.call("button", "add_hold_level_pid"))
	var ids: Array = ed.call("block_ids")
	_ok(ids.size() == n0 + 1, "a click on Hold a level (PID) adds a block")
	var bid := str(ids[ids.size() - 1])
	_ok(str(ed.call("selected")) == bid and ed.call("field", "f_sp") != null, "and shows its form")
	# Its reading, picked through the tag list.
	await _click(vp, tree, ed.call("field", "f_pv"))
	var br: Node = null
	for ch in view.get_children():
		if ch.has_method("row_button") and ch.has_method("set_search"):
			br = ch
	_ok(br != null, "Reads opens the tag list")
	if br != null:
		br.call("set_search", "Logic Test Day")
		await _settle(tree, 10)
		var pick: Button = br.call("row_button", lvl_tag, "pick")
		_ok(pick != null, "the day tank's level is on it")
		if pick != null:
			await _click(vp, tree, pick)
	await _settle(tree, 10)
	_ok(str((hub.call("logic_block", bid) as Dictionary).get("pv", "")) == lvl_tag, "a click on Use sets what the loop reads")
	# What it drives and its numbers.
	var blk: Dictionary = (hub.call("logic_block", bid) as Dictionary).duplicate(true)
	blk.merge({"pv": lvl_tag, "out": open_tag, "sp": 50.0, "kp": 6.0, "ti_min": 20.0}, true)
	var all: Array = (hub.call("logic_blocks") as Array).duplicate(true)
	for i in all.size():
		if str(all[i]["id"]) == bid:
			all[i] = blk
	hub.call("set_logic_blocks", all)
	ed.call("select", bid)
	await _settle(tree, 10)
	_shot(main, "01_logic_window")
	var audit: Dictionary = UiAudit.run(tree.root)
	print("scada-logic: audit %s" % UiAudit.summary_line(audit))
	_ok(int(audit.get("errors", 0)) == 0, "UiAudit finds no errors on the window (%d)" % int(audit.get("errors", 0)))
	ed.call("close")
	await _settle(tree, 10)

	# ---- it runs ----
	var rev0 := int(model.get("user_rev"))
	await _run_clock(main, tree, 5.0, 0.1)
	var level := float(_specs(model, b).get("level", 0.0)) * 100.0
	var opening := float(_specs(model, cv).get("open", 1.0)) * 100.0
	var st: Dictionary = (hub.call("logic_status") as Dictionary).get(bid, {}) as Dictionary
	print("scada-logic: after 5 h the day tank is at %.1f %%, the valve %.1f %% open; %s" % [level, opening, str(st.get("text", ""))])
	_ok(absf(level - 50.0) < 5.0, "the loop holds the day tank near its 50 %% setpoint (%.1f %%)" % level)
	_ok(opening > 15.0 and opening < 60.0, "with the valve part open (%.1f %%; a third balances the drain)" % opening)
	_ok(int(model.get("user_rev")) == rev0, "none of the loop's writes counts as an edit")
	hub.call("refresh")
	_ok(book.has("logic.%s.out" % bid) and absf(book.value("logic.%s.out" % bid) - opening) < 3.0, "the loop's output is a tag")

	# ---- in the picture ----
	lens.call("refresh", true)
	lens.call("fit")
	await _settle(tree, 10)
	var bubble: Dictionary = mimic.call("element_by_id", "ins:logic:" + bid)
	_ok(not bubble.is_empty() and str(bubble.get("letters", "")) == "LIC" and str(bubble.get("reads", "")) == b, "the loop is a LIC bubble on the day tank")
	var has_line := false
	for p in (mimic.get("doc") as Dictionary).get("pipes", []):
		if str(p["id"]) == "sig:logic:" + bid and str(p.get("to", "")) == cv:
			has_line = true
	_ok(has_line, "with a dashed line to the valve it drives")
	_shot(main, "02_loop_in_picture")
	if not bubble.is_empty():
		var pb: Vector2 = mimic.get_global_transform() * (mimic.call("element_rect", bubble) as Rect2).get_center()
		await HarnessInput.mouse_move(vp, pb)
		await _settle(tree, 3)
		await HarnessInput.click(vp, pb)
		await _settle(tree, 10)
		var face: PanelContainer = lens.call("faceplate")
		var man: Button = face.call("button", "manual") if face != null and face.visible else null
		_ok(man != null and not man.disabled, "a click on the bubble opens its faceplate, with Manual")
		_shot(main, "03_loop_faceplate")
		if man != null:
			await _click(vp, tree, man)
			var st2: Dictionary = (hub.call("logic_status") as Dictionary).get(bid, {}) as Dictionary
			_ok(str(st2.get("mode", "")) == "manual", "Manual puts the loop in manual")
			var held := float(_specs(model, cv).get("open", 0.0))
			await _run_clock(main, tree, 0.5, 0.1)
			_ok(absf(float(_specs(model, cv).get("open", 0.0)) - held) < 0.005, "and the valve stays where it was")
			hub.call("logic_command", bid, "auto")
		await HarnessInput.key(vp, KEY_ESCAPE)
		await _settle(tree, 6)

	# ---- an interlock wins ----
	var kid := str(hub.call("new_logic_id"))
	var lock := ScadaLogic.template("overfill", kid, {"pv": lvl_tag, "out": open_tag})
	(lock["when"] as Array)[0]["value"] = 10.0
	all = (hub.call("logic_blocks") as Array).duplicate(true)
	all.append(lock)
	hub.call("set_logic_blocks", all)
	await _run_clock(main, tree, 0.3, 0.1)
	var kst: Dictionary = (hub.call("logic_status") as Dictionary).get(kid, {}) as Dictionary
	_ok(bool(kst.get("tripped", false)) and float(_specs(model, cv).get("open", 1.0)) < 0.005, "an interlock on the same valve forces it shut over the loop")

	# ---- saved with the graph ----
	var saved: Dictionary = view.call("collect_save_state")
	var sl: Dictionary = saved.get("scada_logic", {}) as Dictionary
	_ok((sl.get("blocks", []) as Array).size() >= 2 and (sl.get("state", {}) as Dictionary).has(bid), "the logic and its state are saved with the graph")
	hub.call("set_logic_data", {})
	_ok((hub.call("logic_blocks") as Array).is_empty(), "cleared")
	hub.call("set_logic_data", sl)
	_ok(str((hub.call("logic_block", bid) as Dictionary).get("out", "")) == open_tag, "and comes back from what was saved")
	var cost_t0 := Time.get_ticks_usec()
	for _i in 50:
		hub.call("logic_tick")
	print("scada-logic: one logic pass %.3f ms" % (float(Time.get_ticks_usec() - cost_t0) / 50000.0))

	# ---- clean up ----
	hub.call("set_logic_data", saved_logic)
	view.call("_apply_graph_view_mode", GraphSiteLayout.VIEW_FREEFORM)
	for id in [cv, dv, a, b, c]:
		model.remove_item(id)
	view.call("close_graph_view")
	await _settle(tree, 10)
	return {"ok": _fails.is_empty(), "fails": _fails}
