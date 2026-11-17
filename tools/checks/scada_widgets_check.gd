extends RefCounted

## SCADA Phase 8 on a real world (sandbox): dashboard widgets, screens and the
## Trends window, with REAL input.
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/scada_widgets_check.gd -Label scada_widgets -Timeout 900
## - a seeded line: cistern → control valve → day tank;
## - the lens's Widgets menu arms a gauge, a real click sets it down, the tag
##   list opens in pick mode and a real click on Use binds it;
## - one of every widget kind; a real click on the push button switches the
##   valve, a real click along the slider sets its opening, the lamp follows;
## - a real drag moves a widget; "click to edit" + real clicks on Bigger and
##   Scale…; Remove;
## - screens: + adds a board, a nav button goes there with a real click, the
##   tab comes back; rename; the picture on / off;
## - the Trends window: pens, the wheel zooms, the cursor reads, Back to now;
## - operator mode: nothing moves, buttons still work;
## - saved with the graph, not an edit of the model; UiAudit; draw cost.
## Removes what it made. Shots under screenshots/scada_widgets/.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("scada-widgets %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func _shot(main: Node, name: String) -> void:
	var dir := "user://screenshots/scada_widgets"
	DirAccess.make_dir_recursive_absolute(dir)
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [dir, name])


func _specs(model: GraphModel, id: String) -> Dictionary:
	return model.get_item(id).get("specs", {}) as Dictionary


func _click(vp: Viewport, tree: SceneTree, c: Control) -> void:
	await HarnessInput.mouse_move(vp, HarnessInput.center_of(c))
	await _settle(tree, 2)
	await HarnessInput.click(vp, HarnessInput.center_of(c))
	await _settle(tree, 10)


func _click_at(vp: Viewport, tree: SceneTree, p: Vector2) -> void:
	await HarnessInput.mouse_move(vp, p)
	await _settle(tree, 2)
	await HarnessInput.click(vp, p)
	await _settle(tree, 10)


## Where a widget stands on screen (viewport pixels).
func _wrect(mimic: Control, wid: String) -> Rect2:
	var e: Dictionary = mimic.call("element_by_id", "w:" + wid)
	if e.is_empty():
		return Rect2()
	var r: Rect2 = mimic.call("element_rect", e)
	return mimic.get_global_transform() * r


func _find_with(root: Node, method: String) -> Node:
	for i in range(root.get_child_count() - 1, -1, -1):
		var c := root.get_child(i)
		if c.has_method(method) and not c.is_queued_for_deletion():
			return c
	return null


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var vp := main.get_viewport()
	var view: Node = ServiceLocator.graph()
	var hub: Node = view.call("scada_hub") if view != null else null
	_ok(hub != null and hub.has_method("trend_span"), "the hub serves trends")
	if hub == null:
		return {"ok": false, "fails": _fails}
	var model: GraphModel = view.get("model")
	main.set("time_scale", 0.0)
	var canvas: Control = view.get("_graph_canvas")
	var saved_screens: Dictionary = (canvas.call("process_screens_data") as Dictionary).duplicate(true)
	var saved_trends: Dictionary = hub.call("trend_data")

	var a := "wg_test_a"
	var b := "wg_test_b"
	var cv := "wg_test_cv"
	model.add_item({"id": a, "type": "resource", "x": -900.0, "y": -4200.0, "specs": {"name": "Widget Test Cistern",
		"resource_kind": "water", "capacity_qty": 20000.0, "capacity_unit": "L", "level": 0.6}})
	model.add_item({"id": b, "type": "resource", "x": -500.0, "y": -4200.0, "specs": {"name": "Widget Test Day Tank",
		"resource_kind": "water", "capacity_qty": 1000.0, "capacity_unit": "L", "level": 0.3}})
	model.add_item({"id": cv, "type": "processor", "x": -700.0, "y": -4200.0,
		"specs": FlowCtl.make_specs("Widget Test Valve", FlowCtl.KIND_VALVE, "water", 600.0, {"throttle": true, "state": "off"})})
	for w in [[a, "output", cv, "res_in_0"], [cv, "res_out_0", b, "input"]]:
		model.add_connection({"polarity": "resource", "resource_type": "water", "source_item_id": w[0],
			"source_handle_id": w[1], "target_item_id": w[2], "target_handle_id": w[3]})
	hub.call("refresh")
	await _settle(tree, 10)
	var level_tag := "tank.%s.level" % b
	var sw_tag := "node.%s" % cv
	var open_tag := "valve.%s.open" % cv

	view.call("open_graph_view")
	await _settle(tree, 20)
	var chips: Dictionary = view.get("_mode_chip_btns")
	await _click(vp, tree, chips["process"])
	await _settle(tree, 20)
	var lens: Control = canvas.call("process_lens")
	var mimic: Control = lens.get("mimic")
	lens.call("set_screens_data", {})
	await _settle(tree, 10)

	# ---- place a gauge from the menu, bind it in the tag list ----
	var menu: MenuButton = lens.find_child("widgets_menu", true, false)
	_ok(menu != null and menu.is_visible_in_tree(), "the lens has a Widgets menu")
	_ok(menu.get_popup().item_count == MimicWidgets.KINDS.size() + 2, "it lists every widget kind and the edit switch")
	menu.get_popup().id_pressed.emit(MimicWidgets.KINDS.find("gauge"))
	await _settle(tree, 5)
	_ok(str(lens.call("widget_tool")) == "gauge" and str(mimic.get("tool")) == "place", "picking Dial gauge arms the place tool")
	var rev0 := int(model.get("user_rev"))
	var srev0 := int(model.get("struct_rev"))
	var spot := mimic.get_global_transform() * Vector2(mimic.size.x * 0.62, mimic.size.y * 0.12)
	await _click_at(vp, tree, spot)
	await _settle(tree, 10)
	var ws: Array = lens.call("widgets")
	_ok(ws.size() == 1 and str(ws[0]["kind"]) == "gauge", "a real click on open space sets the gauge down")
	var gid := str(ws[0]["id"]) if not ws.is_empty() else ""
	_ok(str(lens.call("widget_tool")) == "", "and the tool is put away")
	var picker := _find_with(view, "set_search")
	_ok(picker != null and bool(picker.call("is_open")), "the tag list opens to pick what it shows")
	if picker != null:
		picker.call("set_search", "Widget Test Day Tank")
		await _settle(tree, 10)
		var use: Button = picker.find_child("pick", true, false)
		_ok(use != null and use.is_visible_in_tree(), "the day tank's tags are listed with a Use button")
		if use != null:
			await _click(vp, tree, use)
	await _settle(tree, 10)
	var gtag := str((lens.call("widget", gid) as Dictionary).get("tag", ""))
	_ok(gtag.contains(b), "a real click on Use binds the gauge (%s)" % gtag)
	lens.call("set_widget", gid, {"tag": level_tag})
	await _settle(tree, 20)
	var gst: Dictionary = lens.call("widget_state", gid)
	_ok(bool(gst.get("avail", false)) and absf(float(gst.get("value", 0.0)) - 30.0) < 0.5 and str(gst.get("text", "")).ends_with("%"), "the gauge reads the tank: %s" % str(gst.get("text", "")))
	_ok(int(mimic.call("widgets_drawn")) == 1, "and is drawn on the picture")
	_ok(int(model.get("user_rev")) == rev0 and int(model.get("struct_rev")) == srev0, "a widget is not an edit of the graph model")

	# ---- one of every kind ----
	var gp := Vector2(float(ws[0]["x"]), float(ws[0]["y"]))
	var ids := {"gauge": gid}
	var k_i := 0
	for kind in ["bar", "value", "trend", "lamp", "button", "slider", "text", "nav"]:
		k_i += 1
		var at := gp + Vector2(-190.0 * float((k_i + 1) / 2 % 2) - (380.0 if k_i > 4 else 0.0), 150.0 * float((k_i + 1) / 2))
		ids[kind] = str(lens.call("add_widget", kind, at))
	# A tidy block to the right of the picture: two columns.
	var maxw := 0.0
	for kk in ids:
		maxw = maxf(maxw, float((lens.call("widget", ids[kk]) as Dictionary)["w"]))
	var col_x := [gp.x - maxw - 24.0, gp.x]
	var order := ["value", "gauge", "bar", "trend", "lamp", "button", "slider", "text", "nav"]
	var yy := [gp.y, gp.y]
	for i in order.size():
		var w: Dictionary = lens.call("widget", ids[order[i]])
		var c := i % 2
		lens.call("set_widget", ids[order[i]], {"x": col_x[c], "y": yy[c] + float(w["h"]) * 0.5})
		yy[c] += float(w["h"]) + 24.0
	lens.call("set_widget", ids["bar"], {"tag": level_tag})
	lens.call("set_widget", ids["value"], {"tag": "tank.%s.stock" % b})
	lens.call("set_widget", ids["trend"], {"tag": level_tag})
	lens.call("set_widget", ids["lamp"], {"tag": sw_tag, "label": "Valve open"})
	lens.call("set_widget", ids["button"], {"tag": sw_tag, "label": "Fill valve"})
	lens.call("set_widget", ids["slider"], {"tag": open_tag, "label": "Opening"})
	lens.call("set_widget", ids["text"], {"text": "Day tank"})
	await _settle(tree, 30)
	_ok((lens.call("widgets") as Array).size() == 9 and int(mimic.call("widgets_drawn")) == 9, "nine widgets, one of every kind, all drawn (%d)" % int(mimic.call("widgets_drawn")))
	var overlap := 0
	for i in order.size():
		for j in range(i + 1, order.size()):
			if _wrect(mimic, ids[order[i]]).grow(-2.0).intersects(_wrect(mimic, ids[order[j]]).grow(-2.0)):
				overlap += 1
	_ok(overlap == 0, "none of them overlap")
	_shot(main, "01_widgets")
	print("scada-widgets: picture with 9 widgets draws in %.2f ms" % float(mimic.call("draw_cost_ms")))
	_ok(float(mimic.call("draw_cost_ms")) < 8.0, "the picture with nine widgets redraws in under 8 ms")

	# ---- operate: the push button, the slider ----
	_ok(str(_specs(model, cv).get("requested_state", "")) == "off" and not bool((lens.call("widget_state", ids["lamp"]) as Dictionary).get("on", true)), "the valve starts shut and the lamp is dark")
	await _click_at(vp, tree, _wrect(mimic, ids["button"]).get_center())
	await _settle(tree, 20)
	_ok(str(_specs(model, cv).get("requested_state", "")) == "on", "a real click on the push button opens the valve")
	_ok(bool((lens.call("widget_state", ids["lamp"]) as Dictionary).get("on", false)), "and the lamp lights")
	var sr := _wrect(mimic, ids["slider"])
	var s_local: Rect2 = mimic.call("element_rect", mimic.call("element_by_id", "w:" + ids["slider"]))
	# 30 % along the track.
	var want_x := 0.0
	for px in range(int(s_local.position.x), int(s_local.end.x)):
		if MimicSymbols.slider_frac(s_local, float(px)) >= 0.30:
			want_x = float(px)
			break
	await _click_at(vp, tree, mimic.get_global_transform() * Vector2(want_x, s_local.get_center().y + s_local.size.y * 0.2))
	await _settle(tree, 20)
	var opened := float(_specs(model, cv).get("open", 1.0)) * 100.0
	_ok(absf(opened - 30.0) <= 2.0, "a real click 30 %% along the slider sets the valve's opening (%.0f %%)" % opened)
	_ok(absf(float((lens.call("widget_state", ids["slider"]) as Dictionary).get("frac", 0.0)) - 0.30) < 0.03, "and its knob stands there")
	_ok(sr.size.x > 20.0, "the slider is on screen")
	# The clock runs: the tank fills, the gauge and the trend follow.
	var h0 := float(main.call("get_absolute_hours"))
	main.set("time_scale", 0.02)
	var guard := 0
	while float(main.call("get_absolute_hours")) - h0 < 0.6 and guard < 6000:
		await tree.process_frame
		guard += 1
	main.set("time_scale", 0.0)
	await _settle(tree, 40)
	gst = lens.call("widget_state", gid)
	_ok(float(gst.get("value", 0.0)) > 33.0, "with the clock running the tank fills and the gauge follows (%s)" % str(gst.get("text", "")))
	var tst: Dictionary = lens.call("widget_state", ids["trend"])
	var tn := 0
	for v in (tst.get("trend", PackedFloat32Array()) as PackedFloat32Array):
		if not is_nan(v):
			tn += 1
	_ok(tn >= 3, "the trend widget has readings to draw (%d)" % tn)
	_shot(main, "02_running")

	# ---- a reading cannot be commanded ----
	lens.call("set_widget", ids["button"], {"tag": level_tag})
	await _settle(tree, 20)
	var lvl0 := float(_specs(model, b).get("level", 0.0))
	await _click_at(vp, tree, _wrect(mimic, ids["button"]).get_center())
	await _settle(tree, 10)
	_ok(absf(float(_specs(model, b).get("level", 0.0)) - lvl0) < 1e-6, "a push button on a reading changes nothing (it says why)")
	lens.call("set_widget", ids["button"], {"tag": sw_tag})
	await _settle(tree, 20)

	# ---- drag ----
	var gr := _wrect(mimic, gid)
	var gx0 := float((lens.call("widget", gid) as Dictionary)["x"])
	await HarnessInput.drag(vp, gr.get_center(), gr.get_center() + Vector2(-70.0, 0.0))
	await _settle(tree, 20)
	var gx1 := float((lens.call("widget", gid) as Dictionary)["x"])
	_ok(gx1 < gx0 - 10.0, "a real drag moves the gauge (%.0f → %.0f)" % [gx0, gx1])
	await HarnessInput.drag(vp, _wrect(mimic, gid).get_center(), _wrect(mimic, gid).get_center() + Vector2(70.0, 0.0))
	await _settle(tree, 20)

	# ---- reading faceplate, then edit mode ----
	await _click_at(vp, tree, _wrect(mimic, gid).get_center())
	var face: PanelContainer = lens.call("faceplate")
	_ok(face != null and face.visible and face.call("button", "w_trends") != null and face.call("button", "w_remove") == null, "a click on a gauge shows its reading with Open in Trends, and nothing to edit")
	_ok(face != null and int(face.call("trend_points")) >= 3, "with its last two hours")
	lens.call("dismiss_faceplate")
	menu.get_popup().id_pressed.emit(100)
	await _settle(tree, 5)
	_ok(bool(lens.call("widget_edit")), "the menu's \"Click a widget to edit it\" switches edit clicks on")
	await _click_at(vp, tree, _wrect(mimic, gid).get_center())
	face = lens.call("faceplate")
	_ok(face != null and face.visible and face.call("button", "w_bigger") != null and face.call("button", "w_tag") != null, "now a click shows Tag…, Name…, Scale…, Smaller, Bigger, Remove")
	await _settle(tree, 420)
	_shot(main, "03_edit_faceplate")
	var audit: Dictionary = UiAudit.run(tree.root)
	for f in audit.get("findings", []):
		if str((f as Dictionary).get("severity", "")) == "error":
			print("scada-widgets: audit finding %s" % str(f).substr(0, 300))
	print("scada-widgets: audit (edit faceplate) %s" % UiAudit.summary_line(audit))
	_ok(int(audit.get("errors", 0)) == 0, "UiAudit finds no errors with the faceplate up (%d)" % int(audit.get("errors", 0)))
	var w0 := float((lens.call("widget", gid) as Dictionary)["w"])
	await _click(vp, tree, face.call("button", "w_bigger"))
	_ok(float((lens.call("widget", gid) as Dictionary)["w"]) > w0 * 1.15, "a real click on Bigger grows it")
	face = lens.call("faceplate")
	await _click(vp, tree, face.call("button", "w_smaller"))
	face = lens.call("faceplate")
	await _click(vp, tree, face.call("button", "w_range"))
	await _settle(tree, 10)
	var dlg: ConfirmationDialog = lens.call("ask_dialog")
	_ok(dlg != null and dlg.visible, "Scale… asks for the ends of the scale")
	if dlg != null:
		(dlg.find_child("ask_text", true, false) as LineEdit).text = "0 to 50"
		dlg.get_ok_button().pressed.emit()
		await _settle(tree, 15)
	var gw: Dictionary = lens.call("widget", gid)
	_ok(float(gw["lo"]) == 0.0 and float(gw["hi"]) == 50.0, "\"0 to 50\" sets it")
	_ok(float((lens.call("widget_state", gid) as Dictionary).get("frac", 0.0)) > 0.6, "and the needle stands further round")
	face = lens.call("faceplate")
	_ok(face != null and face.visible and str(face.call("shown_for")) == "w:" + gid, "its card is back up after the answer")
	lens.call("dismiss_faceplate")
	await _click_at(vp, tree, _wrect(mimic, ids["text"]).get_center())
	face = lens.call("faceplate")
	_ok(face != null and face.visible and face.call("button", "w_remove") != null, "the text widget has its own card")
	await _click(vp, tree, face.call("button", "w_remove"))
	_ok((lens.call("widgets") as Array).size() == 8, "a real click on Remove takes it away")
	menu.get_popup().id_pressed.emit(100)
	await _settle(tree, 5)

	# ---- screens ----
	var bar: PanelContainer = lens.call("screen_bar")
	_ok(bar != null and bar.is_visible_in_tree() and bar.find_child("screen_s1", true, false) != null, "the screen tabs show Overview")
	await _click(vp, tree, bar.find_child("screen_add", true, false))
	await _settle(tree, 20)
	var scs: Array = lens.call("screens")
	_ok(scs.size() == 2 and str(lens.call("screen_id")) == "s2" and not bool(scs[1]["picture"]), "a real click on + adds a blank board and shows it")
	_ok((lens.call("widgets") as Array).is_empty() and (lens.find_child("empty_note", true, false) as Label).visible, "the board is empty and says how to fill it")
	var t2 := str(lens.call("add_widget", "trend", Vector2.ZERO))
	lens.call("set_widget", t2, {"tag": level_tag, "w": 480.0, "h": 220.0})
	var g2 := str(lens.call("add_widget", "gauge", Vector2(420.0, 0.0)))
	lens.call("set_widget", g2, {"tag": open_tag, "w": 300.0, "h": 240.0})
	mimic.call("fit")
	await _settle(tree, 30)
	var plain := 0
	for e in (mimic.get("doc") as Dictionary).get("elements", []):
		if str(e["kind"]) != "widget":
			plain += 1
	_ok(plain == 0 and int(mimic.call("widgets_drawn")) == 2, "the board holds only its widgets")
	_shot(main, "04_board")
	lens.call("rename_screen", "s2", "Trends board")
	await _settle(tree, 10)
	_ok((bar.find_child("screen_s2", true, false) as Button).text == "Trends board", "renaming shows on its tab")
	await _click(vp, tree, bar.find_child("screen_s1", true, false))
	await _settle(tree, 20)
	_ok(str(lens.call("screen_id")) == "s1" and (lens.call("widgets") as Array).size() == 8, "a real click on the Overview tab comes back")
	# The nav button: unbound, a click offers its card; pointed at s2, a click goes.
	lens.call("set_widget", ids["nav"], {"screen": "s2"})
	await _settle(tree, 20)
	_ok(str((lens.call("widget_state", ids["nav"]) as Dictionary).get("text", "")) == "Trends board", "the nav button shows where it goes")
	await _click_at(vp, tree, _wrect(mimic, ids["nav"]).get_center())
	await _settle(tree, 20)
	_ok(str(lens.call("screen_id")) == "s2", "a real click on it opens that screen")
	lens.call("set_screen_picture", "s2", true)
	await _settle(tree, 20)
	plain = 0
	for e in (mimic.get("doc") as Dictionary).get("elements", []):
		if str(e["kind"]) != "widget":
			plain += 1
	_ok(plain >= 3, "\"Show the process picture on it\" puts the picture under the board's widgets")
	lens.call("set_screen_picture", "s2", false)
	lens.call("set_screen", "s1")
	await _settle(tree, 20)

	# ---- saved with the graph ----
	var saved: Dictionary = view.call("collect_save_state")
	var ps: Dictionary = saved.get("process_screens", {}) as Dictionary
	var scope := str(canvas.get("active_scope_id"))
	_ok(ps.has(scope) and ((ps[scope] as Dictionary)["screens"] as Array).size() == 2, "the screens are saved with the graph")
	var json_back: Variant = JSON.parse_string(JSON.stringify(ps))
	lens.call("set_screens_data", {})
	await _settle(tree, 10)
	_ok((lens.call("widgets") as Array).is_empty(), "cleared")
	lens.call("set_screens_data", json_back)
	await _settle(tree, 20)
	_ok((lens.call("widgets") as Array).size() == 8 and float((lens.call("widget", gid) as Dictionary)["hi"]) == 50.0, "and come back from what was saved, scale and all")

	# ---- operator mode ----
	view.call("set_operator_mode", true)
	await _settle(tree, 30)
	_ok(not menu.is_visible_in_tree() and bar.find_child("screen_add", true, false) == null and bar.is_visible_in_tree(), "operator mode: no Widgets menu, no +, the tabs stay")
	gx0 = float((lens.call("widget", gid) as Dictionary)["x"])
	await HarnessInput.drag(vp, _wrect(mimic, gid).get_center(), _wrect(mimic, gid).get_center() + Vector2(-60.0, 0.0))
	await _settle(tree, 20)
	_ok(absf(float((lens.call("widget", gid) as Dictionary)["x"]) - gx0) < 0.01, "a drag moves nothing")
	_ok(str(lens.call("add_widget", "lamp", Vector2.ZERO)) == "", "nothing can be added")
	var st_before := str(_specs(model, cv).get("requested_state", ""))
	await _click_at(vp, tree, _wrect(mimic, ids["button"]).get_center())
	await _settle(tree, 20)
	_ok(str(_specs(model, cv).get("requested_state", "")) != st_before, "the push button still works (%s → %s)" % [st_before, str(_specs(model, cv).get("requested_state", ""))])
	_shot(main, "05_operator")
	audit = UiAudit.run(tree.root)
	print("scada-widgets: audit (operator) %s" % UiAudit.summary_line(audit))
	_ok(int(audit.get("errors", 0)) == 0, "UiAudit finds no errors in operator mode (%d)" % int(audit.get("errors", 0)))
	view.call("set_operator_mode", false)
	await _settle(tree, 30)

	# ---- the Trends window ----
	var tb: Button = lens.find_child("trends_btn", true, false)
	_ok(tb != null and tb.is_visible_in_tree(), "the lens has a Trends button")
	await _click(vp, tree, tb)
	await _settle(tree, 20)
	var tw := _find_with(view, "chart")
	_ok(tw != null and bool(tw.call("is_open")), "a real click opens the Trends window")
	if tw != null:
		hub.call("set_trend_pens", [level_tag, open_tag, sw_tag])
		await _settle(tree, 40)
		var chart: TrendChart = tw.call("chart")
		_ok(chart.pens.size() == 3 and chart.points(0) >= 3, "three pens; the level has readings (%d)" % chart.points(0))
		_ok(chart.scale_of(0) == chart.scale_of(1) and chart.scale_of(2) == Vector2(-0.15, 1.15), "the two % pens share a scale; the switch is on / off")
		_ok(bool(hub.call("is_watched", level_tag)), "a pen's tag is watched (its history is kept long and saved)")
		var pr := chart.plot_rect()
		var mid := chart.get_global_transform() * pr.get_center()
		await HarnessInput.mouse_move(vp, mid)
		await _settle(tree, 5)
		var span0 := chart.span_h
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_WHEEL_UP
		ev.pressed = true
		ev.position = mid
		ev.global_position = mid
		vp.push_input(ev, true)
		var ev_up := ev.duplicate() as InputEventMouseButton
		ev_up.pressed = false
		vp.push_input(ev_up, true)
		await _settle(tree, 10)
		_ok(chart.span_h < span0, "the wheel zooms in (%.2f h → %.2f h)" % [span0, chart.span_h])
		await HarnessInput.drag(vp, mid, mid + Vector2(140.0, 0.0))
		await _settle(tree, 10)
		_ok(not chart.following(), "a drag looks back in time")
		var nowb: Button = tw.call("button", "now")
		_ok(nowb != null and not nowb.disabled, "and Back to now lights up")
		await _click(vp, tree, nowb)
		_ok(chart.following(), "a real click on it returns to the live edge")
		await _click(vp, tree, tw.call("button", "span_1"))
		_ok(absf(chart.span_h - 1.0) < 0.01, "the 1 h button sets the span")
		await HarnessInput.mouse_move(vp, mid)
		await _settle(tree, 10)
		var cur: Dictionary = chart.cursor_at(pr.end.x - 4.0)
		_ok((cur["values"] as Array).size() == 3 and not is_nan(float(cur["values"][0])), "the cursor reads every pen where it stands (%s %%)" % MimicWidgets.fmt(float(cur["values"][0])))
		print("scada-widgets: trend chart draws in %.2f ms" % chart.draw_cost_ms())
		_ok(chart.draw_cost_ms() < 6.0, "the chart redraws in under 6 ms")
		_shot(main, "06_trends")
		audit = UiAudit.run(tree.root)
		print("scada-widgets: audit (trends) %s" % UiAudit.summary_line(audit))
		_ok(int(audit.get("errors", 0)) == 0, "UiAudit finds no errors on the Trends window (%d)" % int(audit.get("errors", 0)))
		await _click(vp, tree, tw.call("button", "pen_2_remove"))
		_ok((hub.call("trend_pens") as Array).size() == 2, "a real click on a pen's × removes it")
		_ok(((view.call("collect_save_state") as Dictionary).get("scada_trends", {}) as Dictionary).get("pens", []) == [level_tag, open_tag], "the pens are saved with the graph")
		tw.call("close")
		await _settle(tree, 10)

	# ---- clean up ----
	lens.call("set_screens_data", saved_screens)
	hub.call("set_trend_data", saved_trends)
	hub.call("unwatch", level_tag)
	hub.call("unwatch", open_tag)
	hub.call("unwatch", sw_tag)
	view.call("_apply_graph_view_mode", GraphSiteLayout.VIEW_FREEFORM)
	view.call("close_graph_view")
	for id in [cv, a, b]:
		model.remove_item(id)
	await _settle(tree, 10)
	return {"ok": _fails.is_empty(), "fails": _fails}
