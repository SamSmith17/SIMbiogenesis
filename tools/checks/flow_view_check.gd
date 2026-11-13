extends RefCounted

## The graph's flow view on a real closed-loop world (sandbox):
##   tools\harness.ps1 -World w6af22bac295d -RunScript res://tools/checks/flow_view_check.gd -Label flow_view -Timeout 900
## Freeform: every flow-style preset through View options ▾ (the menu's own
## handler), the ribbons' widths proportional to their flows inside each
## resource, shots at three zooms and three sim speeds; the Flow style panel
## opened from the menu with a REAL click on a preset. The Flows lens: a REAL
## click on its lens chip, a loop Sankey laid out (nodes, ribbons, returns
## outside the column), the metrics, a REAL hover on a return lighting its
## loop, a REAL click on the "24 h" chip, a REAL double-click into a group
## and back. Prints the numbers a PNG cannot show.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("flowview %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


func _wait(tree: SceneTree, s: float) -> void:
	await tree.create_timer(s, true, false, true).timeout


func _shot(vp: Viewport, dir: String, name: String) -> void:
	vp.get_texture().get_image().save_png("%s/%s.png" % [dir, name])


func _to_vp(c: Control, p: Vector2) -> Vector2:
	return c.get_global_transform_with_canvas() * p


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var vp := main.get_viewport()
	await _frames(tree, 10)
	var sgv := ServiceLocator.graph()
	_ok(sgv != null, "a graph view")
	if sgv == null:
		return {"ok": false, "fails": _fails}
	var dir := "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	# Let the world run so the wires carry something.
	main.set("time_scale", 60.0 / 3600.0)
	sgv.call("open_graph_view")
	await _frames(tree, 6)
	sgv.call("_on_mode_chip_pressed", GraphSiteLayout.VIEW_FREEFORM)
	sgv.call("_jump_to_scope_index", 0)
	await _wait(tree, 2.5)
	var canvas: Control = sgv.get("_graph_canvas")
	var model: GraphModel = sgv.get("model")
	var ids: Array = []
	for it in model.get_items_in_scope("root"):
		ids.append(str((it as Dictionary)["id"]))
	canvas.call("fit_items_to_view", ids, 0.06)
	await _wait(tree, 1.0)

	# --- Presets through View options ▾ --------------------------------
	var vm: MenuButton = sgv.get("_view_mode_menu")
	var vmp := vm.get_popup()
	var base := int(sgv.get_script().get_script_constant_map().get("VIEW_MODE_FLOW_PRESET_BASE", 192))
	for pi in GraphFlowStyle.PRESETS.size():
		var p := str(GraphFlowStyle.PRESETS[pi])
		_ok(vmp.get_item_index(base + pi) >= 0, "View options lists Flow: %s" % p)
		vmp.id_pressed.emit(base + pi)
		await _wait(tree, 1.0)
		var st: Dictionary = canvas.get("flow_style")
		_ok(str(st.get("preset", "")) == p, "the canvas draws with %s" % p)
		var f0 := Engine.get_frames_drawn()
		var t0 := Time.get_ticks_msec()
		await _wait(tree, 2.0)
		print("flowview: %s — %.1f fps in freeform at 60x" % [p,
			float(Engine.get_frames_drawn() - f0) / maxf(0.001, float(Time.get_ticks_msec() - t0) / 1000.0)])
		_shot(vp, dir, "01_freeform_%s" % p)
		if p == GraphFlowStyle.PRESET_CLASSIC:
			continue
		# Widths proportional within each resource (linear presets).
		var est: Dictionary = canvas.get("_flow_est_cache")
		var wc: Dictionary = canvas.get("_ribbon_w_cache")
		var by_key := {}
		for cid in est:
			var e: Dictionary = est[cid]
			var v := float(e.get("_flow_value", 0.0))
			if v <= 0.0 or not wc.has(cid):
				continue
			var k := str(e.get("_flow_key", ""))
			if not by_key.has(k):
				by_key[k] = []
			(by_key[k] as Array).append([v, float(wc[cid])])
		var worst := 0.0
		var pairs := 0
		var minpx := float(st.get("min_px", 2.5)) * 1.05
		if str(st.get("scale", "")) == GraphFlowStyle.SCALE_LINEAR:
			for k in by_key:
				var arr: Array = by_key[k]
				for a in arr:
					for b in arr:
						if float(a[1]) > minpx and float(b[1]) > minpx and float(b[0]) > 0.0:
							var want := float(a[0]) / float(b[0])
							var got := float(a[1]) / float(b[1])
							worst = maxf(worst, absf(got / want - 1.0))
							pairs += 1
			print("flowview: %s — %d resources on screen, %d wire pairs, worst ratio error %.3f" % [
				p, by_key.size(), pairs, worst])
			_ok(pairs == 0 or worst < 0.06, "%s: widths are proportional to flow in each resource" % p)
		print("flowview: %s — %d wires drawn as ribbons" % [p, wc.size()])
		_ok(wc.size() > 0, "%s: wires are drawn as ribbons" % p)

	# --- Zoom and speed ---------------------------------------------------
	sgv.call("set_flow_style", {"preset": GraphFlowStyle.PRESET_BOLD})
	for z in [0.3, 1.0, 2.0]:
		canvas.set("_zoom", z)
		canvas.call("queue_redraw")
		await _wait(tree, 0.6)
		_shot(vp, dir, "02_bold_zoom_%s" % str(z).replace(".", "_"))
	canvas.call("fit_items_to_view", ids, 0.06)
	sgv.call("set_flow_style", {"preset": GraphFlowStyle.PRESET_SANKEY})
	for sp in [1.0, 450.0, 7200.0]:
		main.set("time_scale", sp / 3600.0)
		await _wait(tree, 1.2)
		var fps := Engine.get_frames_per_second()
		print("flowview: %.0fx — %d fps, high-speed LOD %s" % [sp, fps, str(canvas.get("_high_speed_lod"))])
		_shot(vp, dir, "03_speed_%dx" % int(sp))
	main.set("time_scale", 60.0 / 3600.0)

	# --- The Flow style panel, a REAL click on a preset ------------------
	var pop: PopupPanel = sgv.call("open_flow_style_panel")
	await _wait(tree, 0.5)
	_ok(pop != null and pop.visible, "the Flow style panel opens")
	if pop != null:
		var b := pop.find_child("preset_bold", true, false) as Button
		_ok(b != null, "the panel has the Bold preset")
		if b != null:
			# The popup is embedded in the root window: click there, at the
			# button's place in the root (popup position + its rect).
			await HarnessInput.click(vp, Vector2(pop.position) + b.get_global_rect().get_center())
			await _wait(tree, 0.4)
			_ok(str((canvas.get("flow_style") as Dictionary).get("preset", "")) == "bold",
				"a real click on Bold restyles the graph")
		_shot(vp, dir, "04_panel")
		pop.hide()
	sgv.call("set_flow_style", {"preset": GraphFlowStyle.PRESET_SANKEY})

	# A day of flow history for the lens's windows (7200x for ~12 s).
	main.set("time_scale", 7200.0 / 3600.0)
	await _wait(tree, 12.0)
	main.set("time_scale", 60.0 / 3600.0)
	var fh: FlowHistory = sgv.call("flow_history")
	print("flowview: flow history holds %d hourly bins" % (fh.bins.size() if fh != null else -1))
	_ok(fh != null and fh.bins.size() >= 6, "flow history recorded the run")

	# --- The Flows lens ---------------------------------------------------
	var chips: Dictionary = sgv.get("_mode_chip_btns")
	_ok(chips.has("flows"), "the lens switcher has Flows")
	if chips.has("flows"):
		var fb: Button = chips["flows"]
		await HarnessInput.click(vp, fb.get_global_rect().get_center())
	await _wait(tree, 2.0)
	_ok(str(canvas.get("view_mode")) == GraphSiteLayout.VIEW_FLOWS, "a real click opens the Flows lens")
	var lens: GraphFlowLens = canvas.call("flows_lens")
	_ok(lens != null and lens.has_layout(), "the lens laid the scope out")
	var lay: Dictionary = lens.cur if lens != null else {}
	var nn := (lay.get("nodes", {}) as Dictionary).size()
	var rs: Array = lay.get("ribbons", [])
	var rets: Array = []
	for i in rs.size():
		if str((rs[i] as Dictionary)["kind"]) == LoopSankeyLayout.KIND_RETURN:
			rets.append(i)
	print("flowview: lens — %d nodes, %d ribbons, %d returns, %d layers, %d idle" % [
		nn, rs.size(), rets.size(), int(lay.get("layers", 0)), (lay.get("idle", []) as Array).size()])
	var m: Dictionary = lay.get("metrics", {})
	for k in m:
		var mm: Dictionary = m[k]
		print("flowview:   %s — %.0f %% cycled (Finn), %d loops, in %.3f, out %.3f" % [
			str(k), float(mm["fci"]) * 100.0, int(mm.get("loops", 0)), float(mm["boundary_in"]), float(mm["boundary_out"])])
	_ok(nn >= 5 and rs.size() >= 5, "the lens shows the flowing nodes and their ribbons")
	_shot(vp, dir, "05_flows_lens")
	# Returns run outside the column.
	var lo := INF
	var hi := -INF
	for id in (lay.get("nodes", {}) as Dictionary):
		var r: Rect2 = lay["nodes"][id]["rect"]
		lo = minf(lo, r.position.x)
		hi = maxf(hi, r.end.x)
	var outside := 0
	for i in rets:
		var path: PackedVector2Array = (rs[i] as Dictionary)["path"]
		for q in path:
			if q.x < lo or q.x > hi:
				outside += 1
				break
	_ok(rets.is_empty() or outside == rets.size(), "every return swings outside the column (%d of %d)" % [outside, rets.size()])
	# A REAL hover on a return lights its loop.
	if not rets.is_empty():
		var rb: Dictionary = rs[int(rets[0])]
		var path2: PackedVector2Array = rb["path"]
		# The point of the return furthest out (on its lane).
		var far_p := path2[0]
		for q in path2:
			if absf(q.x) > absf(far_p.x):
				far_p = q
		var center := canvas.size * 0.5
		var spt := GraphFlowLens.to_screen(far_p, center, canvas.get("_pan"), float(canvas.get("_zoom")))
		await HarnessInput.mouse_move(vp, _to_vp(canvas, spt))
		await _wait(tree, 0.4)
		_ok(lens.hover_loop == int(rb["loop"]) and lens.hover_loop >= 0,
			"hovering a return lights its loop (%d)" % lens.hover_loop)
		_shot(vp, dir, "06_hover_loop")
	# A REAL click on the 24 h chip.
	var chip24 := {}
	for c in lens.chips:
		if str(c["kind"]) == "window" and str(c["value"]) == "24h":
			chip24 = c
	_ok(not chip24.is_empty(), "the lens offers a 24 h window")
	if not chip24.is_empty():
		await HarnessInput.click(vp, _to_vp(canvas, (chip24["rect"] as Rect2).get_center()))
		await _wait(tree, 1.6)
		_ok(str(canvas.get("flows_window")) == "24h", "a real click on 24 h switches the window")
		var l24: Dictionary = lens.cur
		var r24 := 0
		for rb24 in (l24.get("ribbons", []) as Array):
			if str((rb24 as Dictionary)["kind"]) == LoopSankeyLayout.KIND_RETURN:
				r24 += 1
		print("flowview: 24 h window — %d nodes, %d ribbons, %d returns, %d loops" % [
			(l24.get("nodes", {}) as Dictionary).size(), (l24.get("ribbons", []) as Array).size(), r24,
			(l24.get("loops", []) as Array).size()])
		var m24: Dictionary = l24.get("metrics", {})
		for k24 in m24:
			print("flowview:   24h %s — %.0f %% cycled, %d loops" % [str(k24), float(m24[k24]["fci"]) * 100.0, int(m24[k24].get("loops", 0))])
		# Whether this world closes a cycle inside one day depends on its slow
		# machines; the loop maths is pinned in loop_sankey_layout_selftest.
		print("flowview: 24 h window has %d return ribbons (informational)" % r24)
		_shot(vp, dir, "07_window_24h")
		for c2 in lens.chips:
			if str(c2["kind"]) == "window" and str(c2["value"]) == "now":
				await HarnessInput.click(vp, _to_vp(canvas, (c2["rect"] as Rect2).get_center()))
		await _wait(tree, 1.2)
	# One resource on its own.
	var keys: Array = lens.keys_present
	if keys.size() > 1:
		var one := str(keys[1])
		for c3 in lens.chips:
			if str(c3["kind"]) == "channel" and str(c3["value"]) == one:
				await HarnessInput.click(vp, _to_vp(canvas, (c3["rect"] as Rect2).get_center()))
		await _wait(tree, 1.6)
		_ok(str(canvas.get("flows_channel")) == one, "a real click isolates %s" % one)
		var only := true
		for rb2 in (lens.cur.get("ribbons", []) as Array):
			if str((rb2 as Dictionary)["key"]) != one:
				only = false
		_ok(only, "only %s flows are drawn" % one)
		_shot(vp, dir, "08_only_%s" % one)
		for c4 in lens.chips:
			if str(c4["kind"]) == "channel" and str(c4["value"]) == "":
				await HarnessInput.click(vp, _to_vp(canvas, (c4["rect"] as Rect2).get_center()))
		await _wait(tree, 1.2)
	# A REAL double-click into a group, and back.
	var group := ""
	for id2 in (lens.cur.get("nodes", {}) as Dictionary):
		if str(model.get_item(str(id2)).get("type", "")) == "compound":
			group = str(id2)
			break
	if group != "":
		var center2 := canvas.size * 0.5
		var gr := lens.node_rect(group, center2, canvas.get("_pan"), float(canvas.get("_zoom")))
		await HarnessInput.click(vp, _to_vp(canvas, gr.get_center()), true)
		await _wait(tree, 1.8)
		var child := str(model.get_item(group).get("child_scope_id", ""))
		_ok(str(canvas.get("active_scope_id")) == child, "a real double-click goes into %s" % group)
		_shot(vp, dir, "09_inside_group")
		sgv.call("_jump_to_scope_index", 0)
		await _wait(tree, 1.5)
		_ok(str(canvas.get("active_scope_id")) == "root", "back at the site")
	else:
		print("flowview: no flowing group in the lens; double-click skipped")
	# A synthetic closed nutrient cycle in the window view (the picture the
	# lens draws when a site does close its loops).
	var layer := CanvasLayer.new()
	layer.layer = 90
	main.add_child(layer)
	var lv: Control = (load("res://scenes/ui/loop_sankey_view.gd") as GDScript).new()
	lv.size = vp.get_visible_rect().size
	layer.add_child(lv)
	var ns: Array = []
	for nid in ["Rain", "Cistern", "People", "Urine store", "Recovery", "Nutrients", "Beds", "Pantry", "Kitchen", "Greywater", "Filter"]:
		ns.append({"id": nid, "label": nid})
	var es: Array = []
	for e3 in [["Rain", "Cistern", 40.0], ["Cistern", "People", 50.0], ["People", "Urine store", 6.0],
			["Urine store", "Recovery", 6.0], ["Recovery", "Nutrients", 4.0], ["Nutrients", "Beds", 4.0],
			["Beds", "Pantry", 8.0], ["Pantry", "Kitchen", 8.0], ["Kitchen", "People", 8.0],
			["People", "Greywater", 30.0], ["Greywater", "Filter", 30.0], ["Filter", "Beds", 18.0],
			["Filter", "Cistern", 10.0], ["Recovery", "Cistern", 2.0]]:
		es.append({"id": "%s>%s" % [e3[0], e3[1]], "a": e3[0], "b": e3[1], "key": "water", "value": e3[2]})
	lv.call("set_input", {"nodes": ns, "edges": es,
		"bin": [{"node": "Rain", "key": "water", "value": 40.0, "label": "rain"}],
		"bout": [{"node": "Beds", "key": "water", "value": 14.0, "label": "to the air"}],
		"labels": {}, "types": {}, "keys": ["water"], "opts": {"thickness": 40.0}},
		func(_k: String, v: float) -> String: return "%s/h" % UiText.num(v, "L"),
		func(_k: String) -> Color: return Color(0.30, 0.80, 0.95),
		func(_k: String) -> String: return "Water")
	await _wait(tree, 1.2)
	var syn: Dictionary = (lv.get("lens") as GraphFlowLens).cur
	var sr := 0
	for rb3 in (syn.get("ribbons", []) as Array):
		if str((rb3 as Dictionary)["kind"]) == LoopSankeyLayout.KIND_RETURN:
			sr += 1
	print("flowview: synthetic cycle — %d returns, %.0f %% cycled" % [sr,
		float(((syn.get("metrics", {}) as Dictionary).get("water", {}) as Dictionary).get("fci", 0.0)) * 100.0])
	_ok(sr >= 2, "a closed cycle draws its returns up the sides")
	_shot(vp, dir, "10_synthetic_loops")
	layer.queue_free()

	# Frame cost in the lens.
	var t0 := Time.get_ticks_msec()
	var f0 := Engine.get_frames_drawn()
	await _wait(tree, 2.0)
	var fr := float(Engine.get_frames_drawn() - f0) / maxf(0.001, float(Time.get_ticks_msec() - t0) / 1000.0)
	print("flowview: lens at 60x — %.1f fps" % fr)
	sgv.call("_on_mode_chip_pressed", GraphSiteLayout.VIEW_FREEFORM)
	await _wait(tree, 0.8)
	return {"ok": _fails.is_empty(), "fails": _fails}
