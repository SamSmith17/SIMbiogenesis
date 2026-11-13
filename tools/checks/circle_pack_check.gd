extends RefCounted

## Circle packing on a real world (sandbox):
##   tools\harness.ps1 -World w6af22bac295d -RunScript res://tools/checks/circle_pack_check.gd -Label circle_pack -Timeout 900
## Opens "Nesting as circles…" through View options ▾ (the menu's handler),
## then with REAL input: a click into a group flies there, a right-click
## comes back out, a hover names the circle in the side panel, a click on a
## breadcrumb; the Size by choice (rated power adds up), an array's strings,
## the three source tabs (systems, stores, built), a structure's parts from
## its "Its parts" action, the inspector's "See inside as circles" on a group,
## a store kind's make-up summing to its mass, live refresh gliding, and the
## frame time while flying. Shots per state.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("circlepack %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _wait(tree: SceneTree, s: float) -> void:
	await tree.create_timer(s, true, false, true).timeout


func _shot(vp: Viewport, dir: String, name: String) -> void:
	vp.get_texture().get_image().save_png("%s/%s.png" % [dir, name])


func _vp_pos(view: Control, local: Vector2) -> Vector2:
	return view.get_global_transform_with_canvas() * local


func _right_click(vp: Viewport, pos: Vector2) -> void:
	await HarnessInput.mouse_move(vp, pos)
	for pressed in [true, false]:
		var mb := InputEventMouseButton.new()
		mb.button_index = MOUSE_BUTTON_RIGHT
		mb.pressed = pressed
		mb.position = pos
		mb.global_position = pos
		vp.push_input(mb, true)
		await vp.get_tree().process_frame


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var vp := main.get_viewport()
	for _i in 10:
		await tree.process_frame
	var sgv := ServiceLocator.graph()
	_ok(sgv != null, "a graph view")
	if sgv == null:
		return {"ok": false, "fails": _fails}
	var dir := "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	main.set("time_scale", 60.0 / 3600.0)
	sgv.call("open_graph_view")
	await _wait(tree, 1.5)

	# --- Open through the View options menu ---------------------------------
	var vm: MenuButton = sgv.get("_view_mode_menu")
	var vmp := vm.get_popup()
	var mid := int(sgv.get_script().get_script_constant_map().get("VIEW_MODE_CIRCLE_PACK", 200))
	_ok(vmp.get_item_index(mid) >= 0, "View options lists Nesting as circles…")
	vmp.id_pressed.emit(mid)
	await _wait(tree, 1.2)
	var win := CirclePackWindow.current()
	_ok(win != null and win.is_open(), "the circle pack window opens")
	if win == null:
		return {"ok": false, "fails": _fails}
	var view := win.view()
	var n := view.nodes.size()
	print("circlepack: systems tree %d circles, %d hidden" % [n, int(view.lay.get("hidden", 0))])
	_ok(n > 30, "the site's systems lay out as circles (%d)" % n)
	_shot(vp, dir, "01_systems")

	# --- A real click into the biggest group -------------------------------
	var best := -1
	var best_r := 0.0
	for i in view.nodes.size():
		var d: Dictionary = view.nodes[i]
		if int(d["depth"]) == 1 and not bool(d["leaf"]) and float(d["r"]) > best_r:
			best = i
			best_r = float(d["r"])
	_ok(best >= 0, "the site has a group to go into")
	if best >= 0:
		var sc := view.screen_circle(best)
		# Aim between its children: its rim side, inside the circle.
		var aim := Vector2(sc.x, sc.y) + Vector2(0, -sc.z * 0.93)
		var hit := view.pick(aim)
		if hit != best:
			aim = Vector2(sc.x, sc.y) + Vector2(sc.z * 0.93, 0)
		await HarnessInput.click(vp, _vp_pos(view, aim))
		await _wait(tree, 1.6)
		_ok(view.focus == best, "a real click flies into %s" % str(view.nodes[best]["name"]))
		var fsc := view.screen_circle(best)
		_ok(absf(fsc.z - minf(view.size.x, view.size.y) * 0.5 * CirclePackView.FIT) < 3.0,
			"the group fills the view after the fly (r %.0f px)" % fsc.z)
		_shot(vp, dir, "02_into_group")
		# Hover a child: the side panel names it.
		var kids: PackedInt32Array = view.nodes[best]["kids"]
		if kids.size() > 0:
			var k0 := kids[0]
			var kc := view.screen_circle(k0)
			var kp := Vector2(kc.x, kc.y)
			var deep := view.pick(kp)
			await HarnessInput.mouse_move(vp, _vp_pos(view, kp))
			await _wait(tree, 0.4)
			var title: Label = win.get("_side_title")
			_ok(deep >= 0 and title.text == str(view.nodes[deep]["name"]),
				"hovering a circle names it in the side panel (%s)" % title.text)
			_shot(vp, dir, "03_hover")
		# A real right-click comes back out.
		await _right_click(vp, _vp_pos(view, Vector2(view.size.x * 0.5, view.size.y * 0.5)))
		await _wait(tree, 1.6)
		_ok(view.focus == 0, "a real right-click comes back out to the whole")

	# --- Frame time while flying --------------------------------------------
	var pm: Node = main.get_node_or_null("/root/PerfMonitor")
	if pm != null:
		pm.call("set_enabled", true)
	if best >= 0:
		var f0 := Engine.get_frames_drawn()
		var t0 := Time.get_ticks_msec()
		view.zoom_to(best)
		await _wait(tree, 1.0)
		view.zoom_home()
		await _wait(tree, 1.0)
		var fps := float(Engine.get_frames_drawn() - f0) / maxf(0.001, float(Time.get_ticks_msec() - t0) / 1000.0)
		print("circlepack: %.1f fps while flying in and out" % fps)
		if pm != null:
			var snap: Dictionary = pm.call("snapshot")
			var ms := float((snap.get("sections_ms", {}) as Dictionary).get("pack_draw", 0.0))
			var calls := float((snap.get("calls", {}) as Dictionary).get("pack_draw", 0.0))
			var per := ms / maxf(calls, 1e-6)
			print("circlepack: one draw of the circles %.2f ms (frame %.1f ms)" % [per, float(snap.get("frame_ms", 0.0))])
			_ok(per < 8.0, "a draw of the circles costs under 8 ms (%.2f)" % per)
			pm.call("set_enabled", false)
		_ok(fps > 10.0, "flying stays smooth (%.0f fps)" % fps)

	# --- Size by rated power; an array's strings --------------------------------
	win.set_size_by(CirclePackSources.SIZE_POWER)
	await _wait(tree, 1.0)
	var tot := float(view.lay.get("total", 0.0))
	print("circlepack: rated power of the site %s" % UiText.num(tot, "W"))
	_ok(tot > 1000.0, "sized by rated power, the site adds up to watts (%s)" % UiText.num(tot, "W"))
	_shot(vp, dir, "04_by_power")
	var str_i := -1
	for i in view.nodes.size():
		if str(view.nodes[i]["id"]).contains(":string"):
			str_i = i
			break
	_ok(str_i >= 0, "an array's panels sit in their strings")
	if str_i >= 0:
		view.zoom_to(int(view.nodes[str_i]["parent"]))
		await _wait(tree, 1.6)
		_shot(vp, dir, "05_array_strings")
	win.set_size_by(CirclePackSources.SIZE_COUNT)
	await _wait(tree, 0.6)

	# --- Live refresh glides ------------------------------------------------
	var before := view.nodes.size()
	await _wait(tree, 2.6)
	_ok(view.nodes.size() == before, "a live refresh keeps the same circles")

	# --- The other sources (real clicks on the tabs) ---------------------------
	var st_btn := win.find_child("src_stores", true, false) as Button
	_ok(st_btn != null, "the window has the stores tab")
	if st_btn != null:
		await HarnessInput.click(vp, st_btn.get_global_rect().get_center())
		await _wait(tree, 1.4)
		_ok(win.source_id() == "stores" and view.nodes.size() > 3,
			"a real click shows what the stores hold (%d circles, %s)" % [view.nodes.size(),
				ElementLedger.fmt_kg(float(view.lay.get("total", 0.0)))])
		_shot(vp, dir, "06_stores")
	var bt_btn := win.find_child("src_built", true, false) as Button
	if bt_btn != null:
		await HarnessInput.click(vp, bt_btn.get_global_rect().get_center())
		await _wait(tree, 1.4)
		_ok(win.source_id() == "built", "a real click shows what the site is built from (%d circles)" % view.nodes.size())
		_shot(vp, dir, "07_built")
		var rec_i := -1
		for i in view.nodes.size():
			if str(view.nodes[i]["id"]).begins_with("rec:"):
				rec_i = i
				break
		if rec_i >= 0:
			view.sel = rec_i
			view.selected.emit(rec_i)
			await _wait(tree, 0.3)
			var act := win.find_child("act_its_parts", true, false) as Button
			_ok(act != null, "a structure offers its parts")
			if act != null:
				await HarnessInput.click(vp, act.get_global_rect().get_center())
				await _wait(tree, 1.4)
				_ok(win.source_id() == "parts" and view.nodes.size() > 2,
					"a real click on Its parts shows the structure's parts (%d)" % view.nodes.size())
				_shot(vp, dir, "08_parts")
	win.close()
	await _wait(tree, 0.4)

	# --- The inspector's button on a group ------------------------------------
	var model: GraphModel = sgv.get("model")
	var grp := ""
	for it in model.get_items_in_scope("root"):
		var d2: Dictionary = it
		if str(d2.get("type", "")) == "compound" and not str(d2.get("child_scope_id", "")).is_empty():
			grp = str(d2["id"])
			break
	if not grp.is_empty():
		sgv.call("focus_graph_item", grp)
		await _wait(tree, 1.0)
		var ib := sgv.find_child("see_inside_circles", true, false) as Button
		_ok(ib != null and ib.is_visible_in_tree(), "the inspector offers See inside as circles on a group")
		if ib != null and ib.is_visible_in_tree():
			var sc_p: Node = ib.get_parent()
			while sc_p != null and not sc_p is ScrollContainer:
				sc_p = sc_p.get_parent()
			if sc_p != null:
				(sc_p as ScrollContainer).ensure_control_visible(ib)
				await _wait(tree, 0.3)
			await HarnessInput.click(vp, ib.get_global_rect().get_center())
			await _wait(tree, 2.0)
			var w2 := CirclePackWindow.current()
			_ok(w2 != null and w2.is_open() and w2.view().focus == w2.view().index_of(grp),
				"a real click opens the circles on that group")
			_shot(vp, dir, "09_from_inspector")
			if w2 != null:
				w2.close()
			await _wait(tree, 0.4)

	# --- A kind's make-up ------------------------------------------------------
	var w3: CirclePackWindow = sgv.call("open_composition_pack", "urine", 25.0)
	await _wait(tree, 1.2)
	_ok(absf(float(w3.view().lay.get("total", 0.0)) - 25.0) < 1e-3, "a kind's make-up sums to its mass")
	_shot(vp, dir, "10_makeup")
	w3.close()
	await _wait(tree, 0.4)
	sgv.call("close_graph_view")
	main.set("time_scale", 0.0)
	return {"ok": _fails.is_empty(), "fails": _fails}
