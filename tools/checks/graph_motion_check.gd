extends RefCounted

## Graph systems Phase 5 (plans/GRAPH_SYSTEMS_UX_PLAN.md): the visual
## language on the Walton festival world (sandbox, REAL clicks):
##   tools\harness.ps1 -World walton -RunScript res://tools/checks/graph_motion_check.gd -Label graph_motion -Timeout 900
## 1. Festival trunks: a water depot wired to four camps draws as ONE trunk
##    at the site level (its four wires not drawn one by one).
## 2. Status motion: a critical tile keeps the canvas redrawing (the beat)
##    while motion is allowed.
## 3. The fly-to: a long jump zooms out on the way (a dip); a short one
##    does not.
## 4. The coach mark shows at the site level and a real click on Got it
##    puts it away for good.
## 5. Hints & shortcuts fits on screen and lists the festival tools.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("graphmotion %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


func _wait(tree: SceneTree, s: float) -> void:
	await tree.create_timer(s, true, false, true).timeout


func _shot(vp: Viewport, dir: String, name: String) -> void:
	vp.get_texture().get_image().save_png("%s/%s.png" % [dir, name])


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
	main.set("time_scale", 0.0)
	sgv.call("open_graph_view")
	await _frames(tree, 6)
	sgv.call("_on_mode_chip_pressed", GraphSiteLayout.VIEW_FREEFORM)
	sgv.call("_jump_to_scope_index", 0)
	await _wait(tree, 2.5)
	var model: GraphModel = sgv.get("model")
	var canvas: Control = sgv.get("_graph_canvas")
	canvas.set("flow_when_paused", true)

	# --- 4 first: the coach mark (it is a first-run thing) -------------------
	canvas.call("fit_scope_to_view")
	await _wait(tree, 0.6)
	var seen_before := bool(sgv.call("coach_mark_seen"))
	print("graphmotion: coach mark seen before %s, visible %s" % [str(seen_before), str(sgv.call("coach_mark_visible"))])
	_ok(seen_before or bool(sgv.call("coach_mark_visible")), "the coach mark shows at the site level the first time")
	_shot(vp, dir, "01_coach")
	var coach: Node = sgv.get("_coach")
	if coach != null and bool(sgv.call("coach_mark_visible")):
		var got: Button = coach.find_child("GotIt", true, false)
		var p := got.get_global_rect().get_center()
		await HarnessInput.mouse_move(vp, p)
		await HarnessInput.click(vp, p)
		await _frames(tree, 3)
	_ok(bool(sgv.call("coach_mark_seen")) and not bool(sgv.call("coach_mark_visible")),
		"a real click on Got it puts it away for good")

	# --- 1. trunks -------------------------------------------------------------
	var camps: Array = sgv.call("festival_camps")
	var depot := {"id": "cap_depot", "type": "resource", "label": "Water depot",
		"x": -200.0, "y": 300.0, "width": 140.0, "height": 140.0, "scope_id": "root",
		"specs": {"name": "Water depot", "resource_kind": "water", "capacity_qty": 20000.0,
			"capacity_unit": "L", "level": 0.8}}
	model.add_item(depot)
	var conns: Array = []
	for i in mini(4, camps.size()):
		var cid := str((camps[i] as Dictionary)["id"])
		var c := {"id": "cap_trunk_%d" % i, "source_item_id": "cap_depot", "source_handle_id": "output",
			"target_item_id": cid, "target_handle_id": "water_in", "polarity": "resource",
			"resource_type": "water", "scope_id": "root"}
		model.add_connection(c)
		conns.append(str(c["id"]))
	canvas.call("fit_scope_to_view")
	await _wait(tree, 0.8)
	canvas.queue_redraw()
	await _frames(tree, 3)
	print("graphmotion: trunks drawn %d" % int(canvas.get("trunks_drawn")))
	_ok(int(canvas.get("trunks_drawn")) >= 1, "a depot wired to four camp tiles draws as one trunk")
	_shot(vp, dir, "02_trunk")
	for cid2: String in conns:
		model.remove_connection(cid2)
	model.remove_item("cap_depot")

	# --- 2. status motion --------------------------------------------------------
	var rows: Array = sgv.call("system_board_rows")
	var crit := 0
	for r: Dictionary in rows:
		if str(r["level"]) == "crit":
			crit += 1
	canvas.queue_redraw()
	await _frames(tree, 3)
	print("graphmotion: %d critical systems, canvas pulsing %s" % [crit, str(canvas.get("_alert_nodes_present"))])
	_ok(crit == 0 or bool(canvas.get("_alert_nodes_present")), "critical tiles keep the canvas beating")
	canvas.set("flow_when_paused", false)
	canvas.call("tick", 0.016, 0.0)
	canvas.queue_redraw()
	await _frames(tree, 3)
	var t0 := float(canvas.call("_status_t"))
	for _i in 10:
		canvas.call("tick", 0.05, 0.0)
	_ok(is_equal_approx(t0, float(canvas.call("_status_t"))) or not bool(canvas.get("_alert_nodes_present")),
		"paused, with animate-when-paused off, nothing moves")
	canvas.set("flow_when_paused", true)

	# --- 3. fly-to -------------------------------------------------------------------
	var far: Dictionary = model.get_item(str((camps[camps.size() - 1] as Dictionary)["id"]))
	var near: Dictionary = model.get_item(str((camps[0] as Dictionary)["id"]))
	canvas.call("focus_on_item", str(near.get("id", "")), 1.2)
	await _wait(tree, 0.9)
	canvas.call("focus_on_item", str(far.get("id", "")), 1.2)
	var dip := float(canvas.get("last_fly_dip"))
	var min_zoom := 99.0
	for _i in 40:
		await tree.process_frame
		min_zoom = minf(min_zoom, float(canvas.get("_zoom")))
	await _wait(tree, 0.5)
	print("graphmotion: long fly dip %.2f, lowest zoom on the way %.3f (start/end 1.2)" % [dip, min_zoom])
	_ok(dip > 0.0 and min_zoom < 1.0, "a long jump zooms out on the way")
	canvas.call("focus_on_item", str(far.get("id", "")), 1.0)
	_ok(float(canvas.get("last_fly_dip")) == 0.0, "a short move does not")
	await _wait(tree, 0.5)

	# --- 5. hints ----------------------------------------------------------------------
	sgv.call("_on_show_hints")
	await _frames(tree, 3)
	var hp: Control = sgv.get("_hints_panel")
	var vr := canvas.get_global_rect()
	var text := ""
	for l in hp.find_children("*", "Label", true, false):
		text += (l as Label).text + "\n"
	print("graphmotion: hints rect %s in %s" % [str(hp.get_global_rect()), str(vr)])
	_ok(vr.encloses(hp.get_global_rect()), "Hints & shortcuts fits on the canvas (above the timeline)")
	_ok(text.contains("Festival board") and text.contains("Colours") or text.contains("COLOURS"),
		"it lists the festival tools and the colour key")
	_shot(vp, dir, "03_hints")
	sgv.call("_on_show_hints")
	sgv.call("close_graph_view")
	return {"ok": _fails.is_empty(), "fails": _fails}
