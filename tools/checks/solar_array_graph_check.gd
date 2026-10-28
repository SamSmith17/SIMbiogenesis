extends RefCounted

## Solar arrays on the graph, played with REAL input (sandbox; the arrays it
## seeds live only in the sandbox). For an imported array and a Solar
## designer array:
##  - the card carries a layout picture (array_cells) and ONE + / − pair,
##    + on the left, both grabbable;
##  - wheel-zooming at the card OPENS it (the scope switches to its inside),
##    with the panels in it, their bounding box shaped like the picture;
##  - wheel-zooming out pops back to the parent;
##  - a double click opens it too.
## Shots under screenshots\<label>\: each card at three zooms, mid-zoom,
## the inside, plus the world's own arrays.
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/solar_array_graph_check.gd -Label solar_arrays

const HI := preload("res://core/terrain/harness/harness_input.gd")

var _fails: Array = []
var _dir := ""


func _ok(cond: bool, what: String) -> void:
	print("solar-array-check %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


func _shot(main: Node, name: String) -> void:
	await main.get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := main.get_viewport().get_texture().get_image()
	if img != null:
		img.save_png("%s/%s.png" % [_dir, name])


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var label := str(harness.get("shots_dir")) if harness != null and harness.get("shots_dir") != null else "solar_arrays"
	_dir = "user://screenshots/%s" % (label if not label.is_empty() else "solar_arrays")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_dir))
	await _frames(tree, 30)
	var gv: Node = main.find_child("SystemGraphView", true, false)
	if gv == null:
		return {"ok": false, "error": "no SystemGraphView"}
	gv.call("open_graph_view")
	await _frames(tree, 10)
	gv.call("_apply_graph_view_mode", GraphSiteLayout.VIEW_FREEFORM)
	await _frames(tree, 20)
	var model: GraphModel = gv.get("model")
	var canvas: Control = gv.get("_graph_canvas")
	# The world's own arrays first (migrated on load).
	for it in model.items:
		var d: Dictionary = it
		if GraphSolarArrays.is_solar_array(d) and str(d.get("scope_id", "")) == "root":
			_ok(GraphSolarArrays.is_materialized(d), "world array %s has its panels inside" % str(d.get("id", "")))
			canvas.call("focus_on_item", str(d.get("id", "")), 0.9)
			await tree.create_timer(0.6).timeout
			await _shot(main, "world_%s" % str(d.get("id", "")))
	# Seed one imported and one designed array, well away from everything.
	var aid := str(gv.call("add_imported_solar_panels", 9, 380.0, "Probe rack", "probe_arr",
		{"show_picker": false, "auto_wire": false, "panel_w_m": 1.052, "panel_h_m": 1.769}))
	model.update_item(aid, {"x": 6000.0, "y": 6000.0})
	var spec: Dictionary = (PvLabPresets.builtins()[1] as Dictionary)["spec"]
	var dids: Array = gv.call("add_designed_solar_array", spec, "probe_design",
		{"auto_wire": false, "name": "Probe design"})
	var did := str(dids[0]) if not dids.is_empty() else ""
	if not did.is_empty():
		model.update_item(did, {"x": 6000.0, "y": 7200.0})
	_ok(not aid.is_empty() and not did.is_empty(), "seeded an imported and a designed array")
	for pair in [["imported", aid], ["designed", did]]:
		await _check_array(main, gv, canvas, model, str(pair[0]), str(pair[1]))
	if str(gv.get("_active_scope_id")) != "root":
		gv.call("_collapse_active_scope", false)
	return {"ok": _fails.is_empty(), "failures": _fails}


func _check_array(main: Node, gv: Node, canvas: Control, model: GraphModel, label: String, cid: String) -> void:
	var tree := main.get_tree()
	var it := model.get_item(cid)
	if it.is_empty():
		_ok(false, "%s array exists" % label)
		return
	var sp: Dictionary = it.get("specs", {}) as Dictionary
	_ok(sp.get("array_cells") is Dictionary and not ((sp["array_cells"] as Dictionary).get("cells", []) as Array).is_empty(),
		"%s array has a layout picture" % label)
	var hs: Array = canvas.call("_resolved_handles", it)
	var ids := []
	var plus_left := false
	for h in hs:
		ids.append(str((h as Dictionary).get("id", "")))
		if str((h as Dictionary).get("id", "")) == "positive":
			plus_left = float((h as Dictionary).get("rx", 1.0)) < 0.5
	ids.sort()
	_ok(ids == ["negative", "positive"] and plus_left, "%s array: one + / − pair, + left (%s)" % [label, ids])
	var infos: Array = canvas.call("_get_interactive_handle_infos", it, canvas.size * 0.5)
	_ok(infos.size() == 2, "%s array: both ports grabbable unwired (%d)" % [label, infos.size()])
	var cs := str(it.get("child_scope_id", ""))
	var kids := model.get_items_in_scope(cs).filter(func(x: Variant) -> bool: return str((x as Dictionary).get("type", "")) == "panel")
	_ok(kids.size() >= 2, "%s array has %d panels inside" % [label, kids.size()])
	# Three zooms of the card.
	var zi := 0
	for z in [0.35, 0.8, 1.6]:
		canvas.call("focus_on_item", cid, z)
		await tree.create_timer(0.5).timeout
		await _shot(main, "%s_card_%d" % [label, zi])
		zi += 1
	# Wheel into it at its centre until it opens.
	canvas.call("focus_on_item", cid, 1.0)
	await tree.create_timer(0.5).timeout
	var vp := main.get_viewport()
	var entered := false
	for _n in 60:
		var c := Vector2(canvas.call("_item_screen_tl", model.get_item(cid), canvas.size * 0.5)) \
			+ Vector2(canvas.call("_item_screen_size", model.get_item(cid))) * 0.5
		var at := canvas.get_global_rect().position + c
		await HI.mouse_move(vp, at)
		await HI.mouse_press(vp, at, true, false, false, false, MOUSE_BUTTON_WHEEL_UP)
		await HI.mouse_press(vp, at, false, false, false, false, MOUSE_BUTTON_WHEEL_UP)
		if str(gv.get("_active_scope_id")) == cs:
			entered = true
			break
	_ok(entered, "%s array opens on wheel zoom" % label)
	if entered:
		await _shot(main, "%s_zoom_mid" % label)
		await tree.create_timer(0.5).timeout
		await _shot(main, "%s_inside" % label)
		var bb: Rect2 = canvas.call("_scope_content_screen_bbox", cs)
		var cells: Dictionary = (model.get_item(cid).get("specs", {}) as Dictionary).get("array_cells", {})
		var a_pic := float(cells.get("w_m", 1.0)) / maxf(float(cells.get("h_m", 1.0)), 0.001)
		var a_in := bb.size.x / maxf(bb.size.y, 0.001)
		_ok(absf(a_in - a_pic) / a_pic < 0.2, "%s array: the inside is shaped like its picture (%.2f vs %.2f)" % [label, a_in, a_pic])
		# Back out by wheeling down.
		var out := false
		for _m in 80:
			var at2 := canvas.get_global_rect().get_center()
			await HI.mouse_press(vp, at2, true, false, false, false, MOUSE_BUTTON_WHEEL_DOWN)
			await HI.mouse_press(vp, at2, false, false, false, false, MOUSE_BUTTON_WHEEL_DOWN)
			if str(gv.get("_active_scope_id")) != cs:
				out = true
				break
		_ok(out, "%s array: wheel out pops back to the parent" % label)
		await tree.create_timer(0.4).timeout
	# A double click opens it too.
	canvas.call("focus_on_item", cid, 0.8)
	await tree.create_timer(0.5).timeout
	var c2 := Vector2(canvas.call("_item_screen_tl", model.get_item(cid), canvas.size * 0.5)) \
		+ Vector2(canvas.call("_item_screen_size", model.get_item(cid))) * Vector2(0.5, 0.45)
	var at3 := canvas.get_global_rect().position + c2
	await HI.mouse_move(vp, at3)
	await HI.mouse_press(vp, at3, true)
	await HI.mouse_press(vp, at3, false)
	await HI.mouse_press(vp, at3, true, true)
	await HI.mouse_press(vp, at3, false)
	await _frames(tree, 4)
	_ok(str(gv.get("_active_scope_id")) == cs, "%s array opens on double click" % label)
	if str(gv.get("_active_scope_id")) == cs:
		gv.call("_collapse_active_scope", false)
		await tree.create_timer(0.3).timeout
