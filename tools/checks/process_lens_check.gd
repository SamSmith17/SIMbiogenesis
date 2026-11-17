extends RefCounted

## SCADA Phase 3 on a real world (sandbox): the Process lens and the graph's
## valves and pumps, with REAL input.
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/process_lens_check.gd -Label process_lens -Timeout 900
## - a seeded line: store A → valve → store B → machine-less; the Process
##   chip (a real click) shows it as a picture, left to right;
## - the clock runs: B fills through the open valve, the line shows flow;
## - a real click on the valve opens its faceplate and selects it in the
##   graph; "Close it" shuts it (an operator's edit: user_rev moves) and B
##   stops filling; "Open it" starts it again;
## - Esc puts the faceplate away;
## - a store's faceplate shuts its own way out;
## - dragging the valve moves it in the picture only (the node's x / y do
##   not change) and the move is in the graph's save state;
## - editing: the Valve tool + a click on a pipe puts a valve in it (one
##   Ctrl+Z takes it out again); the Store tool + a click on open space sets
##   a store down there; the Pipe tool dragged from one to the other pipes
##   them; Esc drops an armed tool; Delete removes the selected part;
## - back to Freeform hides the lens; draw cost printed; UiAudit.
## Removes what it seeded. Shots under screenshots/process_lens/.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("process-lens %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func _shot(main: Node, name: String) -> void:
	var dir := "user://screenshots/process_lens"
	DirAccess.make_dir_recursive_absolute(dir)
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [dir, name])


func _center(mimic: Control, id: String) -> Vector2:
	var e: Dictionary = mimic.call("element_by_id", id)
	if e.is_empty():
		return Vector2(-1, -1)
	return mimic.get_global_transform() * (mimic.call("element_rect", e) as Rect2).get_center()


func _level(model: GraphModel, id: String) -> float:
	return float((model.get_item(id).get("specs", {}) as Dictionary).get("level", 0.0))


## Wires seen carrying flow WHILE the clock ran (the engine stamps a wire idle
## once the clock is held, so a reading taken after the run was a coin toss).
var _watch_model: GraphModel = null
var _watch_conn := ""
var _saw_flow := false


func _run_clock(main: Node, tree: SceneTree, sim_hours: float) -> void:
	var h0 := float(main.call("get_absolute_hours"))
	main.set("time_scale", 1.0)        # 1 sim-hour a second
	var guard := 0
	while float(main.call("get_absolute_hours")) - h0 < sim_hours and guard < 1200:
		await tree.process_frame
		guard += 1
		if _watch_model != null and float(_watch_model.get_connection(_watch_conn).get("flow_rate", 0.0)) > 0.0:
			_saw_flow = true
	main.set("time_scale", 0.0)
	await _settle(tree, 20)


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var vp := main.get_viewport()
	var view: Node = ServiceLocator.graph()
	_ok(view != null, "there is a graph view")
	if view == null:
		return {"ok": false, "fails": _fails}
	var model: GraphModel = view.get("model")
	main.set("time_scale", 0.0)

	# ---- seed A → valve → B ----
	var a := "pl_test_a"
	var b := "pl_test_b"
	var v := "pl_test_valve"
	model.add_item({"id": a, "type": "resource", "x": -900.0, "y": -900.0, "width": 120.0, "height": 120.0,
		"specs": {"name": "Lens Test Cistern", "resource_kind": "water", "capacity_qty": 2000.0, "capacity_unit": "L", "level": 0.9}})
	model.add_item({"id": b, "type": "resource", "x": -500.0, "y": -900.0, "width": 120.0, "height": 120.0,
		"specs": {"name": "Lens Test Day Tank", "resource_kind": "water", "capacity_qty": 1000.0, "capacity_unit": "L", "level": 0.1}})
	model.add_item({"id": v, "type": "processor", "x": -700.0, "y": -900.0, "width": 160.0, "height": 100.0,
		"specs": FlowCtl.make_specs("Lens Test Valve", FlowCtl.KIND_VALVE, "water", 60.0)})
	model.add_connection({"id": "pl_test_w1", "polarity": "resource", "resource_type": "water",
		"source_item_id": a, "source_handle_id": "hub_out", "target_item_id": v, "target_handle_id": "res_in_0"})
	model.add_connection({"id": "pl_test_w2", "polarity": "resource", "resource_type": "water",
		"source_item_id": v, "source_handle_id": "res_out_0", "target_item_id": b, "target_handle_id": "hub_in"})
	await _settle(tree, 6)
	var vx0 := float(model.get_item(v).get("x", 0.0))

	# ---- the lens, by a real click on its chip ----
	view.call("open_graph_view")
	await _settle(tree, 20)
	var chips: Dictionary = view.get("_mode_chip_btns")
	var chip: Button = chips.get("process") as Button
	_ok(chip != null and chip.is_visible_in_tree(), "the lens switcher has a Process chip")
	if chip == null:
		return {"ok": false, "fails": _fails}
	await HarnessInput.click(vp, HarnessInput.center_of(chip))
	await _settle(tree, 30)
	var canvas: Control = view.get("_graph_canvas")
	_ok(str(canvas.get("view_mode")) == GraphSiteLayout.VIEW_PROCESS, "a click on it switches to the Process lens")
	var lens: Control = canvas.call("process_lens")
	_ok(lens != null and lens.is_visible_in_tree(), "the lens is up")
	if lens == null:
		return {"ok": false, "fails": _fails}
	var mimic: Control = lens.get("mimic")
	var doc: Dictionary = mimic.get("doc")
	print("process-lens: %d elements, %d lines in the picture" % [(doc.get("elements", []) as Array).size(), (doc.get("pipes", []) as Array).size()])
	var ea: Dictionary = mimic.call("element_by_id", a)
	var ev: Dictionary = mimic.call("element_by_id", v)
	var eb: Dictionary = mimic.call("element_by_id", b)
	_ok(not ea.is_empty() and not ev.is_empty() and not eb.is_empty(), "the seeded stores and valve are in the picture")
	_ok(str(ev.get("kind", "")) == "valve" and str(ea.get("kind", "")) == "tank", "drawn as a valve and a tank")
	var pa := _center(mimic, a)
	var pv := _center(mimic, v)
	var pb := _center(mimic, b)
	_ok(pa.x < pv.x and pv.x < pb.x, "flow reads left to right (%.0f < %.0f < %.0f)" % [pa.x, pv.x, pb.x])
	var vis := Rect2(Vector2.ZERO, vp.get_visible_rect().size)
	_ok(vis.has_point(pa) and vis.has_point(pv) and vis.has_point(pb), "all of it is on screen")
	_shot(main, "01_lens")

	# ---- water moves ----
	var b0 := _level(model, b)
	_watch_model = model
	_watch_conn = "pl_test_w2"
	_saw_flow = false
	await _run_clock(main, tree, 2.0)
	_watch_model = null
	var b1 := _level(model, b)
	_ok(b1 > b0 + 0.05, "the day tank fills through the open valve (%.2f → %.2f)" % [b0, b1])
	var st: Dictionary = mimic.get("state")
	_ok(int(((st.get("pipe", {}) as Dictionary).get("pl_test_w2", {}) as Dictionary).get("flow", 0)) == 1
		or float(model.get_connection("pl_test_w2").get("flow_rate", 0.0)) > 0.0 or _saw_flow, "the line into it carried flow")
	_ok(absf(float(((st.get("el", {}) as Dictionary).get(b, {}) as Dictionary).get("level", -1.0)) - b1) < 0.02, "the picture's level is the tank's")
	_shot(main, "02_flowing")

	# ---- the valve's faceplate ----
	pv = _center(mimic, v)
	await HarnessInput.mouse_move(vp, pv)
	await _settle(tree, 3)
	var hov := vp.gui_get_hovered_control()
	print("process-lens: under the pointer: %s" % (str(hov.get_path()) if hov != null else "nothing"))
	await HarnessInput.click(vp, pv)
	await _settle(tree, 10)
	var face: PanelContainer = lens.call("faceplate")
	_ok(face != null and face.visible and str(face.call("shown_for")) == v, "a click on the valve opens its faceplate")
	_ok(str(canvas.get("selected_item_id")) == v, "and selects it in the graph")
	_shot(main, "03_faceplate")
	if face != null and face.visible:
		var off: Button = face.call("button", "off")
		_ok(off != null and off.text == "Close it" and not off.disabled, "it offers Close it")
		var rev0 := int(model.get("user_rev"))
		if off != null:
			await HarnessInput.click(vp, HarnessInput.center_of(off))
			await _settle(tree, 12)
		_ok(not FlowCtl.is_on(model.get_item(v).get("specs", {})), "Close it shuts the valve")
		_ok(int(model.get("user_rev")) > rev0, "as an operator's edit (user_rev moved)")
		var c0 := _level(model, b)
		await _run_clock(main, tree, 2.0)
		var c1 := _level(model, b)
		_ok(absf(c1 - c0) < 0.005, "nothing more reaches the day tank (%.3f → %.3f)" % [c0, c1])
		_ok(not bool(((mimic.get("state").get("el", {}) as Dictionary).get(v, {}) as Dictionary).get("open", true)), "the picture shows it shut")
		_shot(main, "04_closed")
		face = lens.call("faceplate")
		var on: Button = face.call("button", "on") if face != null and face.visible else null
		_ok(on != null and not on.disabled, "the faceplate now offers Open it")
		if on != null:
			await HarnessInput.click(vp, HarnessInput.center_of(on))
			await _settle(tree, 12)
		_ok(FlowCtl.is_on(model.get_item(v).get("specs", {})), "Open it opens it again")
		await HarnessInput.key(vp, KEY_ESCAPE)
		await _settle(tree, 8)
		_ok(face == null or not face.visible, "Esc puts the faceplate away")
		_ok(view.visible, "and the graph stays open")

	# ---- a store's own valves ----
	await HarnessInput.click(vp, _center(mimic, b))
	await _settle(tree, 10)
	face = lens.call("faceplate")
	_ok(face != null and face.visible and str(face.call("shown_for")) == b, "a click on a store opens its faceplate")
	var outlet: Button = face.call("button", "outlet") if face != null and face.visible else null
	_ok(outlet != null, "with its way out")
	if outlet != null:
		await HarnessInput.click(vp, HarnessInput.center_of(outlet))
		await _settle(tree, 12)
		_ok(not bool((model.get_item(b).get("specs", {}) as Dictionary).get("output_valve_open", true)), "Shut the way out shuts the store's outlet")
		_shot(main, "05_store_outlet_shut")
	await HarnessInput.key(vp, KEY_ESCAPE)
	await _settle(tree, 8)

	# ---- editing: a valve into a pipe ----
	var ids0 := {}
	for it in model.get_items_in_scope("root"):
		ids0[str(it["id"])] = true
	var n_conn0 := model.get_connections_in_scope("root").size()
	var tv: Button = lens.call("tool_button", "valve")
	_ok(tv != null and tv.is_visible_in_tree(), "the lens has an Add palette")
	if tv != null:
		await HarnessInput.click(vp, HarnessInput.center_of(tv))
		await _settle(tree, 6)
		_ok(str(lens.call("tool")) == "valve", "a click arms the Valve tool")
		var on_pipe: Vector2 = mimic.get_global_transform() * (mimic.call("pipe_screen_point", "pl_test_w2", 0.5) as Vector2)
		await HarnessInput.mouse_move(vp, on_pipe)
		await _settle(tree, 3)
		_shot(main, "05b_valve_tool")
		await HarnessInput.click(vp, on_pipe)
		await _settle(tree, 14)
		var added := ""
		for it in model.get_items_in_scope("root"):
			if not ids0.has(str(it["id"])):
				added = str(it["id"])
		_ok(not added.is_empty() and FlowCtl.is_flowctl(model.get_item(added).get("specs", {})), "a click on the pipe puts a valve in it")
		_ok(model.get_connection("pl_test_w2").is_empty() and model.get_connections_in_scope("root").size() == n_conn0 + 1, "the pipe became two")
		_ok(str(lens.call("tool")) == "", "and the tool is put down")
		var pn := _center(mimic, added)
		_ok(pn.x > _center(mimic, v).x and pn.x < _center(mimic, b).x, "the new valve stands between the two in the picture")
		_shot(main, "05c_valve_in_pipe")
		await HarnessInput.key(vp, KEY_Z, true)
		await _settle(tree, 14)
		_ok(model.get_item(added).is_empty() and not model.get_connection("pl_test_w2").is_empty(), "one Ctrl+Z takes it out again")

	# ---- editing: a store on open space, then a pipe to it ----
	var ts: Button = lens.call("tool_button", "store")
	var new_store := ""
	if ts != null:
		await HarnessInput.click(vp, HarnessInput.center_of(ts))
		await _settle(tree, 6)
		# Open space: the first spot with nothing under it.
		var spot := Vector2(-1, -1)
		for fy in [0.12, 0.88, 0.5]:
			for fx in [0.9, 0.1, 0.75, 0.25]:
				var lp := Vector2(mimic.size.x * fx, mimic.size.y * fy)
				if spot.x < 0.0 and (mimic.call("pick_element", lp) as Dictionary).is_empty() \
						and (mimic.call("pick_pipe", lp) as Dictionary).is_empty():
					spot = mimic.get_global_transform() * lp
		await HarnessInput.mouse_move(vp, spot)
		await _settle(tree, 3)
		await HarnessInput.click(vp, spot)
		await _settle(tree, 14)
		for it in model.get_items_in_scope("root"):
			if not ids0.has(str(it["id"])) and str(it.get("type", "")) == "resource":
				new_store = str(it["id"])
		_ok(not new_store.is_empty(), "the Store tool + a click on open space sets a store down")
		if not new_store.is_empty():
			var ps := _center(mimic, new_store)
			_ok(ps.distance_to(spot) < 60.0, "where it was clicked (%.0f px off)" % ps.distance_to(spot))
			var tp: Button = lens.call("tool_button", "pipe")
			await HarnessInput.click(vp, HarnessInput.center_of(tp))
			await _settle(tree, 6)
			await HarnessInput.drag(vp, _center(mimic, b), _center(mimic, new_store), 12)
			await _settle(tree, 14)
			var piped := false
			for c in model.get_connections_in_scope("root"):
				if str(c.get("source_item_id", "")) == b and str(c.get("target_item_id", "")) == new_store:
					piped = true
			_ok(piped, "the Pipe tool dragged from the day tank to it pipes them")
			_shot(main, "05d_piped")
			await HarnessInput.key(vp, KEY_ESCAPE)
			await _settle(tree, 6)
			_ok(str(lens.call("tool")) == "" and view.visible, "Esc puts the tool down (and leaves the graph open)")
			lens.call("fit")
			await _settle(tree, 6)
			var pin_now := _center(mimic, new_store)
			_ok(pin_now.x > _center(mimic, b).x and vis.has_point(pin_now), "piped, the store takes its place in the line, right of the day tank")
			await HarnessInput.mouse_move(vp, pin_now)
			await _settle(tree, 3)
			await HarnessInput.click(vp, _center(mimic, new_store))
			await _settle(tree, 8)
			await HarnessInput.key(vp, KEY_ESCAPE)
			await _settle(tree, 4)
			await HarnessInput.key(vp, KEY_DELETE)
			await _settle(tree, 14)
			_ok(model.get_item(new_store).is_empty() and (mimic.call("element_by_id", new_store) as Dictionary).is_empty(), "Delete removes the selected store, from the picture too")

	# ---- UiAudit ----
	var audit: Dictionary = UiAudit.run(tree.root)
	var errs := int(audit.get("errors", 0))
	print("process-lens: audit %s" % UiAudit.summary_line(audit))
	_ok(errs == 0, "UiAudit finds no errors on the lens (%d)" % errs)

	# ---- drag: the picture moves, the graph does not ----
	pv = _center(mimic, v)
	var offs0 := {}
	for e in (mimic.get("doc") as Dictionary).get("elements", []):
		offs0[str(e["id"])] = mimic.call("offset_of", str(e["id"]))
	await HarnessInput.drag(vp, pv, pv + Vector2(0, -90), 10)
	await _settle(tree, 12)
	var pv2 := _center(mimic, v)
	_ok(pv2.y < pv.y - 40.0, "dragging the valve moves it in the picture (%.0f → %.0f)" % [pv.y, pv2.y])
	var sq: Array = _square_lines(mimic)
	_ok(int(sq[0]) >= 2 and int(sq[1]) == 0, "the valve's lines follow it with right-angle bends (%d moved, %d bent)" % [int(sq[0]), int(sq[1])])
	var others := 0
	for e in (mimic.get("doc") as Dictionary).get("elements", []):
		if str(e["id"]) != v and str(e["kind"]) != "widget" and str(e.get("reads", "")) != v \
				and (mimic.call("offset_of", str(e["id"])) as Vector2) != (offs0.get(str(e["id"]), Vector2.ZERO) as Vector2):
			others += 1
	_ok(others == 0, "the things next to it stay where they are (%d moved)" % others)
	_ok(is_equal_approx(float(model.get_item(v).get("x", 0.0)), vx0), "the node's own place on the graph is untouched")
	var saved: Dictionary = view.call("collect_save_state")
	var pins: Dictionary = saved.get("process_pins", {}) as Dictionary
	var found := false
	for scope in pins:
		if (pins[scope] as Dictionary).has(v):
			found = true
	_ok(found, "the move is saved with the graph")
	_shot(main, "06_dragged")

	# ---- cost ----
	var cost := float(mimic.call("draw_cost_ms")) if mimic.has_method("draw_cost_ms") else -1.0
	print("process-lens: one redraw %.2f ms" % cost)
	_ok(cost < 8.0, "a redraw costs under 8 ms (%.2f)" % cost)

	# ---- back to freeform ----
	var ff: Button = chips.get("freeform") as Button
	if ff != null:
		await HarnessInput.mouse_move(vp, HarnessInput.center_of(ff))
		await _settle(tree, 3)
		await HarnessInput.click(vp, HarnessInput.center_of(ff))
		await _settle(tree, 20)
	_ok(str(canvas.get("view_mode")) == GraphSiteLayout.VIEW_FREEFORM and not lens.is_visible_in_tree(), "Freeform hides the lens (mode %s, lens shown %s)" % [str(canvas.get("view_mode")), str(lens.is_visible_in_tree())])

	# ---- clean up ----
	lens.call("reset_layout")
	for it in model.get_items_in_scope("root").duplicate():
		if not ids0.has(str(it["id"])):
			model.remove_item(str(it["id"]))
	model.remove_item(v)
	model.remove_item(a)
	model.remove_item(b)
	view.call("close_graph_view")
	await _settle(tree, 6)
	return {"ok": _fails.is_empty(), "fails": _fails}


## After a drag: every line whose end moved is still square (each leg along
## an axis or along a leg it had) and still ends on the thing it joins.
## [lines that moved, lines that broke].
func _square_lines(canvas: Control) -> Array:
	var moved := 0
	var bad := 0
	for p in (canvas.get("doc") as Dictionary).get("pipes", []):
		var ends: Array = canvas.call("pipe_ends", str(p["id"]))
		var da: Vector2 = canvas.call("offset_of", str(ends[0]))
		var db: Vector2 = canvas.call("offset_of", str(ends[1]))
		if da == Vector2.ZERO and db == Vector2.ZERO:
			continue
		moved += 1
		var c0: PackedVector2Array = p.get("corners", p["pts"])
		var c: PackedVector2Array = canvas.call("pipe_corners", p)
		var dirs: Array = []
		for i in range(1, c0.size()):
			dirs.append((c0[i] - c0[i - 1]).normalized())
		var ok := c.size() >= 2 and c[0].distance_to(c0[0] + da) < 0.5 and c[c.size() - 1].distance_to(c0[c0.size() - 1] + db) < 0.5
		for i in range(1, c.size()):
			var d := (c[i] - c[i - 1]).normalized()
			var leg_ok := absf(d.x) < 0.002 or absf(d.y) < 0.002
			for q in dirs:
				if absf(d.cross(q as Vector2)) < 0.002:
					leg_ok = true
			if not leg_ok:
				ok = false
		if not ok:
			bad += 1
			print("  bent line %s: %s" % [str(p["id"]), str(c)])
	return [moved, bad]
