extends RefCounted

## What is in a tank as it really is (resource composition plan Phase 10,
## sandbox, REAL input):
##   tools\harness.ps1 -World w6af22bac295d -RunScript res://tools/checks/make_up_check.gd -Label make_up -Timeout 1200
## A REAL click turns on "Track what is in it" for the world's urine store
## and nutrient store; the urine is diluted (as if rain got in); a sim day
## runs and the nutrients come out N-poorer, the wire out of the machine
## carrying its derived make-up and the inspector showing it beside the
## kind's own; scrubbing back rewinds it; a rain wire into a drinking-water
## store shows the grade warning. Shots of each.

var _fails: Array = []
var _dir := ""


func _ok(cond: bool, what: String) -> void:
	print("makeup %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _wait(tree: SceneTree, s: float) -> void:
	await tree.create_timer(s, true, false, true).timeout


func _until(tree: SceneTree, cond: Callable, timeout_s: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while not bool(cond.call()):
		if (Time.get_ticks_msec() - t0) / 1000.0 > timeout_s:
			return false
		await tree.process_frame
	return true


func _shot(vp: Viewport, name: String) -> void:
	vp.get_texture().get_image().save_png("%s/%s.png" % [_dir, name])


func _find(model: GraphModel, pred: Callable) -> String:
	for it in model.items:
		var d: Dictionary = it
		if bool(pred.call(d)):
			return str(d["id"])
	return ""


func _inspect(tree: SceneTree, vp: Viewport, sgv: Node, item_id: String) -> void:
	sgv.call("focus_graph_item", item_id)
	await _wait(tree, 1.0)
	var insp_tab: Button = sgv.get("_insp_tab_btn")
	if insp_tab != null and insp_tab.is_visible_in_tree():
		await HarnessInput.click(vp, insp_tab.get_global_rect().get_center())
		await _wait(tree, 0.6)


func _click_track(tree: SceneTree, vp: Viewport, sgv: Node) -> bool:
	var cb: CheckBox = sgv.find_child("track_composition", true, false)
	if cb == null or not cb.is_visible_in_tree():
		return false
	var q := cb.get_parent()
	while q != null:
		if q is ScrollContainer:
			(q as ScrollContainer).ensure_control_visible(cb)
		q = q.get_parent()
	await _wait(tree, 0.4)
	await HarnessInput.click(vp, cb.get_global_rect().get_center())
	await _wait(tree, 0.8)
	return true


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var vp := main.get_viewport()
	await _wait(tree, 0.5)
	_dir = "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_dir))
	main.set("time_scale", 0.0)
	var sgv := ServiceLocator.graph()
	_ok(sgv != null, "a graph view")
	if sgv == null:
		return {"ok": false, "fails": _fails}
	var model: GraphModel = sgv.get("model")
	sgv.call("open_graph_view")
	await _wait(tree, 1.5)
	var unr := _find(model, func(d: Dictionary) -> bool:
		return str((d.get("specs", {}) as Dictionary).get("name", "")) == "Urine Nutrient Recovery")
	var urine := ""
	var nut := ""
	for c in model.connections:
		var cd: Dictionary = c
		if str(cd.get("target_item_id", "")) == unr and str(cd.get("resource_type", "")) == "urine":
			urine = str(cd.get("source_item_id", ""))
		if str(cd.get("source_item_id", "")) == unr and str(cd.get("resource_type", "")) == "nutrients":
			nut = str(cd.get("target_item_id", ""))
	_ok(not unr.is_empty() and not urine.is_empty() and not nut.is_empty(),
		"the world's Urine Nutrient Recovery, its urine store and its nutrient store")
	if urine.is_empty() or nut.is_empty():
		return {"ok": false, "fails": _fails}
	# 1. REAL clicks: track both stores.
	await _inspect(tree, vp, sgv, urine)
	var c1 := await _click_track(tree, vp, sgv)
	await _inspect(tree, vp, sgv, nut)
	var c2 := await _click_track(tree, vp, sgv)
	_ok(c1 and c2 and bool((model.get_item(urine)["specs"] as Dictionary).get("track_composition", false))
		and bool((model.get_item(nut)["specs"] as Dictionary).get("track_composition", false)),
		"a real click turns on Track what is in it for both stores")
	# 2. Dilute the urine store: half its N, as if rain had got in.
	var ku := MakeUp.of_kind("urine")
	var thin := ku.duplicate()
	thin["N"] = float(ku["N"]) * 0.5
	var usp: Dictionary = (model.get_item(urine)["specs"] as Dictionary).duplicate()
	usp["make_up"] = thin
	model.update_item(urine, {"specs": usp})
	# The world's own rule switches this machine; keep it on for the test.
	var psp: Dictionary = (model.get_item(unr)["specs"] as Dictionary).duplicate()
	psp["requested_state"] = "on"
	psp["graph_automations"] = []
	model.update_item(unr, {"specs": psp})
	sgv.call("close_graph_view")
	await _wait(tree, 0.5)
	var h0 := float(main.call("get_absolute_hours"))
	main.set("time_scale", 2.0)
	await _until(tree, func() -> bool: return float(main.call("get_absolute_hours")) - h0 >= 1.0, 60.0)
	var early := 1.0
	for ce in model.connections:
		var ced: Dictionary = ce
		if str(ced.get("source_item_id", "")) == unr and str(ced.get("resource_type", "")) == "nutrients" and ced.get("make_up") is Dictionary:
			early = float((ced["make_up"] as Dictionary).get("N", 0.0)) / maxf(float(MakeUp.of_kind("nutrients")["N"]), 1e-9)
	print("makeup: after 1 h the nutrients wire carries ×%.2f of the kind's N" % early)
	_ok(early < 0.8, "fed diluted urine, the machine's nutrients come out N-poor (×%.2f)" % early)
	var states: Dictionary = {}
	await _until(tree, func() -> bool:
		var s0 := str((model.get_item(unr)["specs"] as Dictionary).get("node_state", "?")) + "/" 			+ str((model.get_item(unr)["specs"] as Dictionary).get("node_state_reason", ""))
		states[s0] = int(states.get(s0, 0)) + 1
		return float(main.call("get_absolute_hours")) - h0 >= 24.0, 120.0)
	print("makeup: machine states over the day (frames): %s" % str(states))
	main.set("time_scale", 0.0)
	await _wait(tree, 0.5)
	var st := str((model.get_item(unr)["specs"] as Dictionary).get("node_state", ""))
	var nmu: Dictionary = (model.get_item(nut)["specs"] as Dictionary).get("make_up", {})
	var kn := MakeUp.of_kind("nutrients")
	var ratio := float(nmu.get("N", 0.0)) / maxf(float(kn["N"]), 1e-9) if not nmu.is_empty() else -1.0
	print("makeup: machine %s; nutrient store N %.4f vs its kind %.4f (×%.2f)" % [st, float(nmu.get("N", 0.0)), float(kn["N"]), ratio])
	# The store already held a lot and fresh urine keeps arriving, so it
	# drifts down only a little: the mix by mass.
	_ok(ratio > 0.0 and ratio < 0.999, "after a day the nutrient store's mix has drifted N-poorer (×%.3f of the kind's)" % ratio)
	var wire_mu := false
	for c2c in model.connections:
		var cc: Dictionary = c2c
		if str(cc.get("source_item_id", "")) == unr and str(cc.get("resource_type", "")) == "nutrients" and cc.has("make_up"):
			wire_mu = true
	_ok(wire_mu, "the machine's nutrients wire carries its derived make-up")
	# 3. The inspector shows it beside the kind's own.
	sgv.call("open_graph_view")
	await _wait(tree, 1.0)
	await _inspect(tree, vp, sgv, nut)
	var shown := false
	for l in sgv.find_children("*", "Label", true, false):
		if (l as Label).is_visible_in_tree() and (l as Label).text.contains("(its kind:"):
			shown = true
	_ok(shown, "the nutrient store's inspector shows its own make-up beside its kind's")
	_shot(vp, "01_tracked_store")
	# 4. Scrub back: the make-up rewinds.
	var fe: Object = sgv.get("_resource_flow")
	var tr: CompositionTrack = fe.call("composition_track", nut)
	var then := tr.at(h0 + 2.0) if tr != null else {}
	main.call("set_absolute_hours", h0 + 2.0)
	await _wait(tree, 1.5)
	var back: Dictionary = (model.get_item(nut)["specs"] as Dictionary).get("make_up", {})
	_ok(tr != null and not then.is_empty() and MakeUp.same(back, then, 1e-3),
		"scrubbing back reads the make-up it had then")
	# 5. A rain wire into a drinking-water store: the grade warning.
	var rain_conn := ""
	for c3 in model.connections:
		var c3d: Dictionary = c3
		if str(c3d.get("resource_type", "")) == "rainwater":
			var t3 := model.get_item(str(c3d.get("target_item_id", "")))
			if str((t3.get("specs", {}) as Dictionary).get("resource_kind", "")) == "water":
				rain_conn = str(c3d.get("id", ""))
				break
	if rain_conn.is_empty():
		print("makeup: no rain → drinking-water wire in this world; warning not shown")
	else:
		sgv.call("select_connection_by_id", rain_conn)
		await _wait(tree, 1.0)
		var gw: Label = sgv.find_child("grade_warning", true, false)
		_ok(gw != null and gw.is_visible_in_tree() and gw.text.contains("grade 4"),
			"a rain wire into a drinking-water store warns: %s" % (gw.text if gw != null else "—"))
		_shot(vp, "02_grade_warning")
	print("makeup %s (%d failures)" % ["PASS" if _fails.is_empty() else "FAIL", _fails.size()])
	return {"ok": _fails.is_empty(), "fails": _fails}
