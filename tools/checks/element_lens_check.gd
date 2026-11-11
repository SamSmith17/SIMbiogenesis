extends RefCounted

## The element lens, "Where it goes" and the water & nutrients tracks on a
## real graph (resource composition plan Phase 4, sandbox):
##   tools\harness.ps1 -World w6af22bac295d -RunScript res://tools/checks/element_lens_check.gd -Label element_lens -Timeout 900
## Through Show ▾'s own handler: Nitrogen colours the wires (flux pushed,
## air stubs for the nodes that trade N with the air), Water and Carbon
## too; the clock runs so the history records; Where it goes… opens the
## Sankey with sources, machines and destinations, over the last 24 h and
## right now; the stock and recovery tracks answer; the lens off clears it;
## Site Plan colours the 3D runs. Shots of each.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("elementlens %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


func _wait(tree: SceneTree, s: float) -> void:
	await tree.create_timer(s, true, false, true).timeout


func _shot(vp: Viewport, dir: String, name: String) -> void:
	vp.get_texture().get_image().save_png("%s/%s.png" % [dir, name])


func _lens_id(sgv: Node, lens: String) -> int:
	var base := int(sgv.get_script().get_script_constant_map().get("SHOW_LENS_BASE", 441))
	for i in ElementLens.LENSES.size():
		if str(ElementLens.LENSES[i]["id"]) == lens:
			return base + i
	return -1


func _find_sankey(tree: SceneTree) -> Node:
	for n in tree.root.get_children():
		var s: Script = n.get_script()
		if s != null and s.resource_path.ends_with("element_sankey_modal.gd"):
			return n
	return null


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
	# 60x so the machines stamp live flows on their wires.
	main.set("time_scale", 60.0 / 3600.0)
	sgv.call("open_graph_view")
	await _frames(tree, 6)
	sgv.call("_on_mode_chip_pressed", GraphSiteLayout.VIEW_FREEFORM)
	sgv.call("_jump_to_scope_index", 0)
	await _wait(tree, 2.0)
	var model: GraphModel = sgv.get("model")
	var canvas: Control = sgv.get("_graph_canvas")
	var ids: Array = []
	for it in model.get_items_in_scope("root"):
		ids.append(str((it as Dictionary)["id"]))
	canvas.call("fit_items_to_view", ids, 0.06)
	await _wait(tree, 0.8)
	var pm: PopupMenu = (sgv.get("_show_menu") as MenuButton).get_popup()
	_ok(pm.get_item_index(_lens_id(sgv, "N")) >= 0, "Show ▾ lists Nitrogen")

	var t0 := Time.get_ticks_usec()
	var led: Dictionary = sgv.call("element_ledger", "root")
	print("elementlens: ledger %.2f ms, %d edges, %d nodes" % [(Time.get_ticks_usec() - t0) / 1000.0,
		(led["edges"] as Array).size(), (led["nodes"] as Dictionary).size()])

	for lens in ["N", "water", "C"]:
		pm.id_pressed.emit(_lens_id(sgv, lens))
		await _wait(tree, 1.6)
		var air: Dictionary = canvas.get("element_air")
		print("elementlens: %s — max %s, %d nodes trading with the air" % [lens,
			ElementLens.fmt_rate(float(canvas.get("element_flux_max")), lens), air.size()])
		_ok(str(canvas.get("element_lens")) == lens, "%s is the canvas lens" % ElementLens.label(lens))
		_ok(float(canvas.get("element_flux_max")) > 0.0, "%s: some wire carries it" % ElementLens.label(lens))
		if lens != "N":
			_ok(air.size() > 0, "%s: air stubs on the nodes that trade it" % ElementLens.label(lens))
		_ok(str(sgv.call("element_lens")) == lens, "the view keeps %s for the save" % lens)
		_shot(vp, dir, "0%d_lens_%s" % [["N", "water", "C"].find(lens) + 1, lens])

	# Run the clock so the history has something over a window: ~6 sim-hours.
	main.set("time_scale", 1800.0 / 3600.0)
	await _wait(tree, 12.0)
	main.set("time_scale", 60.0 / 3600.0)
	await _wait(tree, 1.2)
	var hist: ElementHistory = sgv.call("element_history")
	var w := hist.window(hist.last_hour() - 24.0, hist.last_hour() + 1e-6)
	print("elementlens: history %d bins, %.2f sim-h in the last 24 h" % [hist.bin_count(), float(w["hours"])])
	_ok(float(w["hours"]) > 1.0, "the history records while the clock runs")

	pm.id_pressed.emit(_lens_id(sgv, "N"))
	await _wait(tree, 1.2)
	pm.id_pressed.emit(int(sgv.get_script().get_script_constant_map().get("SHOW_WHERE", 452)))
	await _wait(tree, 1.0)
	var sk_node := _find_sankey(tree)
	_ok(sk_node != null, "Where it goes… opens its window")
	if sk_node != null:
		var view: Control = sk_node.get("_sankey")
		var data: Dictionary = view.get("data")
		var cols := [0, 0, 0]
		for n in data.get("nodes", []):
			cols[int(n["col"])] += 1
		print("elementlens: Sankey N over 24 h — %d sources, %d machines, %d destinations, %d ribbons" % [
			cols[0], cols[1], cols[2], (data.get("links", []) as Array).size()])
		_ok(int(cols[0]) > 0 and int(cols[1]) > 0 and int(cols[2]) > 0, "the Sankey has all three columns")
		_ok(not bool(view.get("per_hour")), "the window is totals over the last 24 h")
		_shot(vp, dir, "04_sankey_N_24h")
		var lens_opt: OptionButton = sk_node.get("_lens_opt")
		var wi := 0
		for i in ElementLens.LENSES.size():
			if str(ElementLens.LENSES[i]["id"]) == "water":
				wi = i
		lens_opt.select(wi)
		lens_opt.item_selected.emit(wi)
		var win_opt: OptionButton = sk_node.get("_win_opt")
		win_opt.select(0)
		win_opt.item_selected.emit(0)
		await _wait(tree, 0.5)
		_ok(bool(view.get("per_hour")) and str(view.get("lens")) == "water", "Right now, water")
		_shot(vp, dir, "05_sankey_water_now")
		var frame: ModalFrame = sk_node.get("_frame")
		frame.close()
		await _wait(tree, 0.4)

	var now_h := float(main.call("get_absolute_hours"))
	var i0 := int(floor(now_h)) - 24
	for ch in ["comp_water", "comp_N", "comp_recovery"]:
		var b: Dictionary = sgv.call("composition_track_bins", ch, 1.0, i0, 26)
		var r := TimelineBinning.value_range(b)
		print("elementlens: track %s range %s" % [ch, str(r)])
		_ok(not is_nan(r.x), "the %s track has values" % ch)
	var tl := ServiceLocator.timeline_ui()
	if tl != null:
		var layout: TimelineTrackLayout = tl.get("_track_layout")
		layout.add_composition_track("comp_N")
		layout.add_composition_track("comp_recovery")
		tl.call("queue_redraw")
		await _wait(tree, 0.8)
		_shot(vp, dir, "06_tracks")

	sgv.call("_on_mode_chip_pressed", GraphSiteLayout.VIEW_SITE)
	await _wait(tree, 2.5)
	sgv.call("_push_element_lens")
	await _wait(tree, 0.5)
	var cm: Node = sgv.get("_conduit_manager")
	var lit := 0
	var runs := 0
	if cm != null:
		for inst in (cm.get("_instances") as Dictionary).values():
			if inst is MeshInstance3D and is_instance_valid(inst):
				runs += 1
				if (inst as MeshInstance3D).material_overlay != null:
					lit += 1
	print("elementlens: Site Plan — %d of %d 3D runs coloured" % [lit, runs])
	_ok(runs == 0 or lit > 0, "Site Plan colours the 3D runs that carry nitrogen")
	_shot(vp, dir, "07_site_plan_N")
	sgv.call("_on_mode_chip_pressed", GraphSiteLayout.VIEW_FREEFORM)
	await _wait(tree, 1.0)

	pm.id_pressed.emit(int(sgv.get_script().get_script_constant_map().get("SHOW_LENS_OFF", 440)))
	await _wait(tree, 0.4)
	_ok(str(canvas.get("element_lens")).is_empty(), "No element colours clears the lens")
	var left := 0
	if cm != null:
		for inst2 in (cm.get("_instances") as Dictionary).values():
			if inst2 is MeshInstance3D and is_instance_valid(inst2) and (inst2 as MeshInstance3D).material_overlay != null:
				left += 1
	_ok(left == 0, "no 3D run keeps a lens colour")
	main.set("time_scale", 0.0)
	print("elementlens %s (%d failures)" % ["PASS" if _fails.is_empty() else "FAIL", _fails.size()])
	return {"ok": _fails.is_empty(), "fails": _fails}
