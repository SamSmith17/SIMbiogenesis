extends RefCounted

## SCADA Phase 9 on a real world (sandbox): process templates and share codes.
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/process_templates_check.gd -Label process_templates -Timeout 900
## - a real click on the lens's Templates button opens the window;
## - a real click on a built-in's Add to the graph drops in its parts, pipes,
##   control block, alarms and widgets, as ONE undo step for the graph;
## - the loop it brought runs: the tank settles on the setpoint;
## - Save the selection keeps the parts selected; Copy code / paste it back;
##   a second copy from the code gets its own ids and its own loop;
## - a .simproc file is written; garbage is refused in words.
## Removes what it made (the sandbox's library file too). Shots under
## screenshots/process_templates/.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("process-templates %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func _shot(main: Node, name: String) -> void:
	var dir := "user://screenshots/process_templates"
	DirAccess.make_dir_recursive_absolute(dir)
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [dir, name])


func _click(vp: Viewport, tree: SceneTree, c: Control) -> void:
	await HarnessInput.mouse_move(vp, HarnessInput.center_of(c))
	await _settle(tree, 2)
	await HarnessInput.click(vp, HarnessInput.center_of(c))
	await _settle(tree, 10)


func _find_with(root: Node, method: String) -> Node:
	for i in range(root.get_child_count() - 1, -1, -1):
		var c := root.get_child(i)
		if c.has_method(method) and not c.is_queued_for_deletion():
			return c
	return null


func _named(model: GraphModel, item_name: String) -> Array:
	var out: Array = []
	for it in model.get_items_in_scope("root"):
		if str(((it as Dictionary).get("specs", {}) as Dictionary).get("name", "")) == item_name:
			out.append(str(it["id"]))
	return out


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var vp := main.get_viewport()
	var view: Node = ServiceLocator.graph()
	var hub: Node = view.call("scada_hub")
	var model: GraphModel = view.get("model")
	main.set("time_scale", 0.0)
	var canvas: Control = view.get("_graph_canvas")
	var items0 := model.get_items_in_scope("root").size()
	var conns0 := model.connections.size()
	var logic0: Array = (hub.call("logic_blocks") as Array).duplicate(true)
	var alarms0: Array = (hub.call("alarm_rules") as Array).duplicate(true)
	var screens0: Dictionary = (canvas.call("process_screens_data") as Dictionary).duplicate(true)
	var lib0 := ProcessLibrary.load_all()

	view.call("open_graph_view")
	await _settle(tree, 20)
	var chips: Dictionary = view.get("_mode_chip_btns")
	await _click(vp, tree, chips["process"])
	await _settle(tree, 20)
	var lens: Control = canvas.call("process_lens")
	var tb: Button = lens.find_child("templates_btn", true, false)
	_ok(tb != null and tb.is_visible_in_tree(), "the lens has a Templates button")
	await _click(vp, tree, tb)
	await _settle(tree, 15)
	var win := _find_with(view, "status_text")
	_ok(win != null and bool(win.call("is_open")), "a real click opens the templates window")
	if win == null:
		return {"ok": false, "fails": _fails}
	_ok((win.call("rows") as Array).size() >= ProcessPack.TEMPLATES.size(), "it lists the built-in processes")
	_shot(main, "01_window")
	var audit: Dictionary = UiAudit.run(tree.root)
	print("process-templates: audit (window) %s" % UiAudit.summary_line(audit))
	_ok(int(audit.get("errors", 0)) == 0, "UiAudit finds no errors on the window (%d)" % int(audit.get("errors", 0)))

	# ---- add a built-in with a real click ----
	var pid_i := -1
	for i in ProcessPack.TEMPLATES.size():
		if str(ProcessPack.TEMPLATES[i][0]) == "level_pid":
			pid_i = i
	var rev0 := int(view.call("history_depth")) if view.has_method("history_depth") else -1
	await _click(vp, tree, win.call("button", "add_t%d" % pid_i))
	await _settle(tree, 30)
	_ok(model.get_items_in_scope("root").size() == items0 + 5 and model.connections.size() == conns0 + 4, "a real click on Add to the graph drops in five parts and four pipes")
	_ok((hub.call("logic_blocks") as Array).size() == logic0.size() + 1 and (hub.call("alarm_rules") as Array).size() == alarms0.size() + 2, "with its PID block and two alarms")
	_ok(win == null or not is_instance_valid(win) or not bool(win.call("is_open")), "and the window closes")
	var day_ids := _named(model, "Day tank")
	var fv_ids := _named(model, "Fill valve")
	_ok(day_ids.size() == 1 and fv_ids.size() == 1, "its parts are named as in the template")
	var day := str(day_ids[0]) if not day_ids.is_empty() else ""
	var blk := {}
	for b in hub.call("logic_blocks"):
		if str(b.get("pv", "")) == "tank.%s.level" % day:
			blk = b
	_ok(not blk.is_empty() and str(blk.get("out", "")) == "valve.%s.open" % (str(fv_ids[0]) if not fv_ids.is_empty() else ""), "the block reads the new tank and drives the new valve")
	await _settle(tree, 20)
	var ws: Array = lens.call("widgets")
	var mine := 0
	for w in ws:
		if str(w["tag"]) == "tank.%s.level" % day:
			mine += 1
	_ok(mine == 2, "its gauge and trend are on the picture, bound to the new tank (%d)" % mine)
	lens.call("fit")
	await _settle(tree, 20)
	_shot(main, "02_inserted")
	# ---- the loop runs ----
	var h0 := float(main.call("get_absolute_hours"))
	main.set("time_scale", 0.03)
	var guard := 0
	while float(main.call("get_absolute_hours")) - h0 < 3.0 and guard < 12000:
		await tree.process_frame
		guard += 1
	main.set("time_scale", 0.0)
	await _settle(tree, 30)
	var lvl := ScadaLogicRun.read_model(model, "tank.%s.level" % day)
	_ok(absf(lvl - 50.0) < 3.0, "with the clock running the loop holds the tank near 50 %% (%.1f)" % lvl)
	_shot(main, "03_running")
	# ---- one undo step takes the parts out ----
	view.call("_do_undo")
	await _settle(tree, 20)
	_ok(model.get_items_in_scope("root").size() == items0, "one Ctrl+Z takes its parts and pipes out again")
	view.call("_do_redo")
	await _settle(tree, 20)
	_ok(model.get_items_in_scope("root").size() == items0 + 5, "and redo puts them back")

	# ---- save the selection, copy its code, paste it ----
	day_ids = _named(model, "Day tank")
	fv_ids = _named(model, "Fill valve")
	var src_ids := _named(model, "Supply")
	var sel: Array[String] = []
	for x in [src_ids[0], fv_ids[0], day_ids[0]]:
		sel.append(str(x))
	canvas.set("selected_item_ids", sel)
	await _click(vp, tree, tb)
	await _settle(tree, 15)
	win = _find_with(view, "status_text")
	(win.call("field", "sel_name") as LineEdit).text = "Check line"
	await _click(vp, tree, win.call("button", "save_sel"))
	var lib := ProcessLibrary.load_all()
	var saved := ProcessLibrary.find("Check line")
	_ok(lib.size() == lib0.size() + 1 and (saved.get("items", []) as Array).size() == 3, "Save the selection keeps the three selected parts (%s)" % str(win.call("status_text")))
	_ok((saved.get("logic", []) as Array).size() == 1 and (saved.get("conns", []) as Array).size() == 2, "with the block that drives them and the pipes between them")
	var mi := -1
	var rws: Array = win.call("rows")
	var u := 0
	for r in rws:
		if bool(r["mine"]):
			if str(r["name"]) == "Check line":
				mi = u
			u += 1
	_ok(mi >= 0 and win.call("button", "copy_u%d" % mi) != null, "it is listed under Yours with Copy code")
	await _click(vp, tree, win.call("button", "copy_u%d" % mi))
	var code := DisplayServer.clipboard_get()
	_ok(code.begins_with(ProcessPack.PREFIX), "a real click on Copy code puts a share code on the clipboard (%d characters)" % code.length())
	await _click(vp, tree, win.call("button", "file_u%d" % mi))
	_ok(FileAccess.file_exists("user://process_export/check_line.simproc"), "Save file writes a .simproc file")
	(win.call("field", "code_edit") as LineEdit).text = "not a code"
	await _click(vp, tree, win.call("button", "paste_btn"))
	_ok(str(win.call("status_text")).contains("SMPR1") and ProcessLibrary.load_all().size() == lib0.size() + 1, "garbage is refused in words and adds nothing")
	(win.call("field", "code_edit") as LineEdit).text = code
	await _click(vp, tree, win.call("button", "paste_btn"))
	_ok(ProcessLibrary.load_all().size() == lib0.size() + 2 and not ProcessLibrary.find("Check line (2)").is_empty(), "pasting the code adds it to the list under its own name")
	_shot(main, "04_saved")
	audit = UiAudit.run(tree.root)
	print("process-templates: audit (saved) %s" % UiAudit.summary_line(audit))
	_ok(int(audit.get("errors", 0)) == 0, "UiAudit finds no errors with saved processes listed (%d)" % int(audit.get("errors", 0)))
	# A second copy from the pasted one: its own ids, its own loop.
	win.call("close")
	await _settle(tree, 10)
	var res: Dictionary = view.call("process_insert", ProcessLibrary.find("Check line (2)"), Vector2(0.0, 600.0))
	await _settle(tree, 20)
	_ok(bool(res.get("ok", false)) and _named(model, "Day tank").size() == 2, "a second copy goes in beside the first")
	var outs := {}
	for b in hub.call("logic_blocks"):
		if str(b.get("kind", "")) == "pid" and str(b.get("pv", "")).begins_with("tank."):
			outs[str(b["pv"])] = str(b["id"])
	_ok(outs.size() >= 2, "each copy has its own block on its own tank")
	_ok(not bool((view.call("process_insert", {"items": []}) as Dictionary).get("ok", true)), "an empty pack is refused")

	# ---- clean up ----
	for nm in ["Supply", "Fill valve", "Day tank", "Outlet", "To use"]:
		for iid in _named(model, nm):
			model.remove_item(str(iid))
	hub.call("set_logic_blocks", logic0)
	hub.call("set_alarm_rules", alarms0)
	canvas.call("set_process_screens_data", screens0)
	ProcessLibrary.save_all(lib0)
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://process_export/check_line.simproc"))
	await _settle(tree, 20)
	_ok(model.get_items_in_scope("root").size() == items0, "everything the check added is gone")
	view.call("_apply_graph_view_mode", GraphSiteLayout.VIEW_FREEFORM)
	view.call("close_graph_view")
	await _settle(tree, 10)
	return {"ok": _fails.is_empty(), "fails": _fails}
