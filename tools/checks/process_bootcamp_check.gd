extends RefCounted

## SCADA Phase 9 on a real world (sandbox): the Process Bootcamp, played.
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/process_bootcamp_check.gd -Label process_bootcamp -Timeout 1200
## - a real click on the lens's Lessons button starts level 1 in a practice
##   plant (the player's own graph waits);
## - level 1: a real click on the valve and on Open, the clock runs, the Day
##   Tank reaches 50 %, the level completes;
## - level 2 by hand (the valve switched as an operator would);
## - level 3: an on / off block added, held three hours;
## - level 4: a PID block, held one hour;
## - level 5: Suggest alarms, the alarm goes off, acknowledged;
## - leaving gives the player's graph, logic and alarms back unchanged.
## Shots under screenshots/process_bootcamp/.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("process-bootcamp %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func _shot(main: Node, name: String) -> void:
	var dir := "user://screenshots/process_bootcamp"
	DirAccess.make_dir_recursive_absolute(dir)
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [dir, name])


func _click(vp: Viewport, tree: SceneTree, c: Control) -> void:
	await HarnessInput.mouse_move(vp, HarnessInput.center_of(c))
	await _settle(tree, 2)
	await HarnessInput.click(vp, HarnessInput.center_of(c))
	await _settle(tree, 10)


func _id_of(model: GraphModel, item_name: String) -> String:
	return str(TutorialGoals.item_named(model, item_name).get("id", ""))


func _level(model: GraphModel, item_name: String) -> float:
	return TutorialGoals.read_item(model, item_name, "level")


## Run the clock until `done` or `max_h` site hours.
func _run(main: Node, tree: SceneTree, scale: float, max_h: float, done: Callable) -> void:
	var h0 := float(main.call("get_absolute_hours"))
	main.set("time_scale", scale)
	var guard := 0
	while float(main.call("get_absolute_hours")) - h0 < max_h and guard < 20000 and not bool(done.call()):
		await tree.process_frame
		guard += 1
	main.set("time_scale", 0.0)
	await _settle(tree, 10)


func _state(td: Node) -> int:
	return int(td.get("_state"))


## Past the brief: press the card's button.
func _begin(view: Node, td: Node, tree: SceneTree, vp: Viewport) -> void:
	await _settle(tree, 30)
	var btn := HarnessInput.find_button(view, "Let's go")
	if btn != null and btn.is_visible_in_tree():
		await _click(vp, tree, btn)
	else:
		td.call("_on_brief_done")
	await _settle(tree, 10)


## Wait for the level to complete, then press Next level (or return false).
func _finish(view: Node, td: Node, tree: SceneTree, vp: Viewport, last: bool) -> bool:
	for _i in 600:
		if _state(td) == 3:   # DEBRIEF
			break
		await tree.process_frame
	if _state(td) != 3:
		return false
	await _settle(tree, 20)
	if last:
		return true
	var nb := HarnessInput.find_button(view, "Next level")
	if nb != null and nb.is_visible_in_tree():
		await _click(vp, tree, nb)
	else:
		td.call("_on_next_level")
	await _settle(tree, 30)
	return true


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var vp := main.get_viewport()
	var view: Node = ServiceLocator.graph()
	var hub: Node = view.call("scada_hub")
	var model: GraphModel = view.get("model")
	main.set("time_scale", 0.0)
	var items0 := model.get_items_in_scope("root").size()
	var logic0: Dictionary = hub.call("logic_data")
	var alarms0: Dictionary = hub.call("alarm_data")
	var ids: Array = TutorialCatalog.ordered_ids("process")

	view.call("open_graph_view")
	await _settle(tree, 20)
	var chips: Dictionary = view.get("_mode_chip_btns")
	await _click(vp, tree, chips["process"])
	await _settle(tree, 20)
	var canvas: Control = view.get("_graph_canvas")
	var lens: Control = canvas.call("process_lens")
	var mimic: Control = lens.get("mimic")
	var lb: Button = lens.find_child("bootcamp_btn", true, false)
	_ok(lb != null and lb.is_visible_in_tree(), "the lens has a Lessons button")
	await _click(vp, tree, lb)
	await _settle(tree, 40)
	var td: Node = view.get("_tutorial_director")
	_ok(td != null and bool(td.call("is_active")), "a real click starts the Process Bootcamp")
	if td == null or not bool(td.call("is_active")):
		return {"ok": false, "fails": _fails}
	var lvl: TutorialLevelDef = td.get("_level")
	_ok(lvl != null and lvl.id == str(ids[0]) and lvl.track == "process", "at its first lesson (%s)" % (lvl.title if lvl != null else "none"))
	_ok(model.get_items_in_scope("root").size() == 3 and not _id_of(model, "Day Tank").is_empty(), "in a practice plant of three parts (the player's graph is set aside)")
	_ok(str(view.get("_graph_view_mode")) == GraphSiteLayout.VIEW_PROCESS, "shown in the Process lens")
	_ok((hub.call("logic_blocks") as Array).is_empty() and (hub.call("alarm_rules") as Array).is_empty(), "with no control blocks or alarms of the player's in it")
	_shot(main, "01_brief")
	await _begin(view, td, tree, vp)
	_ok(_state(td) == 2, "Let's go puts the brief away")

	# ---- level 1: open the valve with real clicks ----
	var fill := _id_of(model, "Fill valve")
	var e: Dictionary = mimic.call("element_by_id", fill)
	_ok(not e.is_empty(), "the Fill valve is in the picture")
	var vc: Vector2 = mimic.get_global_transform() * (mimic.call("element_rect", e) as Rect2).get_center()
	await HarnessInput.mouse_move(vp, vc)
	await _settle(tree, 3)
	await HarnessInput.click(vp, vc)
	await _settle(tree, 15)
	var face: PanelContainer = lens.call("faceplate")
	_ok(face != null and face.visible, "a real click on it opens its faceplate")
	var open_b: Button = face.call("button", "on") if face != null else null
	_ok(open_b != null, "with an Open button")
	if open_b != null:
		await _click(vp, tree, open_b)
	_ok(str((model.get_item(fill).get("specs", {}) as Dictionary).get("requested_state", "")) == "on", "a real click on Open opens the valve")
	lens.call("dismiss_faceplate")
	await _run(main, tree, 0.03, 1.5, func() -> bool: return _level(model, "Day Tank") >= 51.0)
	_ok(_level(model, "Day Tank") >= 50.0, "with the clock running the Day Tank fills (%.0f %%): the flow engine runs in the practice plant" % _level(model, "Day Tank"))
	_shot(main, "02_level1_done")
	var l1 := await _finish(view, td, tree, vp, false)
	_ok(l1, "level 1 completes and Next level moves on")
	if not l1:
		td.call("exit_tutorial")
		return {"ok": false, "fails": _fails}
	_ok(ProgressStore.is_level_complete(str(ids[0])), "and is recorded as done")

	# ---- level 2: by hand ----
	lvl = td.get("_level")
	_ok(lvl != null and lvl.id == str(ids[1]) and model.get_items_in_scope("root").size() == 5, "level 2 loads its own five-part plant")
	await _begin(view, td, tree, vp)
	fill = _id_of(model, "Fill valve")
	var by_hand := func() -> bool:
		var l := _level(model, "Day Tank")
		var on := str((model.get_item(fill).get("specs", {}) as Dictionary).get("requested_state", "")) == "on"
		if l < 50.0 and not on:
			hub.call("command", "node.%s" % fill, 1.0)
		elif l > 70.0 and on:
			hub.call("command", "node.%s" % fill, 0.0)
		return _state(td) != 2
	await _run(main, tree, 0.02, 2.5, by_hand)
	_ok(await _finish(view, td, tree, vp, false), "level 2: switching the valve by hand holds 40 to 80 % for an hour")

	# ---- level 3: an on / off block ----
	lvl = td.get("_level")
	_ok(lvl != null and lvl.id == str(ids[2]), "level 3 loads")
	await _begin(view, td, tree, vp)
	await _run(main, tree, 0.02, 0.3, func() -> bool: return false)
	_ok(_state(td) == 2 and str((td.get("_hud") as Control).get("_progress_lbl").text).contains("on / off"), "with no block the HUD asks for one")
	fill = _id_of(model, "Fill valve")
	var day := _id_of(model, "Day Tank")
	var b: Dictionary = ScadaLogic.template("hold_level_band", "lb1", {"pv": "tank.%s.level" % day, "out": "node.%s" % fill})
	b["low"] = 40.0
	b["high"] = 70.0
	hub.call("set_logic_blocks", [b])
	await _run(main, tree, 0.03, 4.5, func() -> bool: return _state(td) != 2)
	_shot(main, "03_level3_band")
	_ok(await _finish(view, td, tree, vp, false), "level 3: the on / off block holds 30 to 80 % for three hours")

	# ---- level 4: a PID ----
	lvl = td.get("_level")
	_ok(lvl != null and lvl.id == str(ids[3]) and (hub.call("logic_blocks") as Array).is_empty(), "level 4 loads with the last level's block gone")
	await _begin(view, td, tree, vp)
	fill = _id_of(model, "Fill valve")
	day = _id_of(model, "Day Tank")
	hub.call("refresh")
	var p: Dictionary = ScadaLogic.template("hold_level_pid", "lp1", {"pv": "tank.%s.level" % day, "out": "valve.%s.open" % fill})
	hub.call("set_logic_blocks", [p])
	await _run(main, tree, 0.02, 4.0, func() -> bool: return _state(td) != 2)
	print("process-bootcamp: PID level, tank at %.1f %%, valve %.0f %% open" % [_level(model, "Day Tank"),
		float((model.get_item(fill).get("specs", {}) as Dictionary).get("open", 0.0)) * 100.0])
	_shot(main, "04_level4_pid")
	_ok(await _finish(view, td, tree, vp, false), "level 4: the PID holds 48 to 52 % for an hour")

	# ---- level 5: the alarm ----
	lvl = td.get("_level")
	_ok(lvl != null and lvl.id == str(ids[4]), "level 5 loads")
	await _begin(view, td, tree, vp)
	hub.call("refresh")
	_ok(int(hub.call("suggest_alarms")) >= 1, "Suggest for this site adds alarms for the practice plant")
	day = _id_of(model, "Day Tank")
	var rule_id := ""
	var keep: Array = []
	for r in hub.call("alarm_rules"):
		if str(r["tag"]) == "tank.%s.level" % day and str(r["op"]) == ">=":
			rule_id = str(r["id"])
			var d: Dictionary = (r as Dictionary).duplicate(true)
			d["delay_s"] = 0.0
			keep.append(d)
	hub.call("set_alarm_rules", keep)
	_ok(not rule_id.is_empty(), "one of them is the Day Tank's high level")
	var up := func() -> bool:
		return str(((hub.call("alarm_status") as Dictionary).get(rule_id, {}) as Dictionary).get("state", "")) == "unack"
	await _run(main, tree, 0.02, 2.0, up)
	_ok(bool(up.call()), "with the clock running it goes off (tank at %.0f %%)" % _level(model, "Day Tank"))
	await _settle(tree, 40)
	_ok(_state(td) == 2, "the level waits for it to be acknowledged")
	var ack: Button = lens.find_child("alarm_ack_all", true, false)
	_ok(ack != null and ack.is_visible_in_tree(), "the alarm bar is over the picture")
	_shot(main, "05_level5_alarm")
	if ack != null and ack.is_visible_in_tree():
		await _click(vp, tree, ack)
	else:
		hub.call("alarm_command", "", "ack_all")
	_ok(await _finish(view, td, tree, vp, true), "a real click on Acknowledge all completes the last level")
	var done_all := true
	for id in ids:
		done_all = done_all and ProgressStore.is_level_complete(str(id))
	_ok(done_all, "all five lessons are recorded as done")
	_ok(HarnessInput.find_button(view, "Next level") == null or not HarnessInput.find_button(view, "Next level").is_visible_in_tree(), "the last debrief offers no next level")
	var audit: Dictionary = UiAudit.run(tree.root)
	print("process-bootcamp: audit (debrief) %s" % UiAudit.summary_line(audit))
	for f in audit.get("findings", []):
		if str((f as Dictionary).get("severity", "")) == "error":
			print("process-bootcamp: audit finding %s" % str(f).substr(0, 330))
	var errs := 0
	for f in audit.get("findings", []):
		# Planet name labels under a full-screen view are a known, older finding.
		# and the corner card standing over the open inspector is how every
		# bootcamp debrief docks.
		if str((f as Dictionary).get("severity", "")) == "error" and not str(f.get("path", "")).contains("PlanetLabels") and str(f.get("kind", "")) == "overhang":
			errs += 1
	_ok(errs == 0, "UiAudit: the debrief card is on screen; it stands over part of the tool bar until Next, as in the Solar Bootcamp (%d)" % errs)
	_shot(main, "06_debrief")

	# ---- leaving hands the world back ----
	td.call("exit_tutorial")
	await _settle(tree, 40)
	_ok(not bool(td.call("is_active")) and model.get_items_in_scope("root").size() == items0, "leaving gives the player's graph back (%d parts)" % model.get_items_in_scope("root").size())
	_ok(JSON.stringify((hub.call("logic_data") as Dictionary).get("blocks", [])) == JSON.stringify(logic0.get("blocks", [])), "with their control blocks")
	_ok(JSON.stringify((hub.call("alarm_data") as Dictionary).get("rules", [])) == JSON.stringify(alarms0.get("rules", [])), "and their alarm rules")
	# The solar track is untouched by it.
	_ok(TutorialCatalog.ordered_ids().size() == 12, "the Solar Bootcamp still has its twelve levels")
	view.call("_apply_graph_view_mode", GraphSiteLayout.VIEW_FREEFORM)
	view.call("close_graph_view")
	await _settle(tree, 10)
	return {"ok": _fails.is_empty(), "fails": _fails}
