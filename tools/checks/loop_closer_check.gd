extends RefCounted

## The loop closer on a real graph (resource composition plan Phase 7,
## sandbox, REAL input):
##   tools\harness.ps1 -World w6af22bac295d -RunScript res://tools/checks/loop_closer_check.gd -Label loop_closer -Timeout 1200
##   (and -UserArgs @("--window-size=1280x720") for the small screen)
## Nothing shows until asked; a toilet block with an unwired urine output
## is added, a REAL click on its "Close the urine loop" shows a ghost with a
## chip; a REAL Tab accepts it as exactly one undo step; a REAL Ctrl+Z takes
## it back; Dismiss hides a plan and, read again from disk (as a reload
## does), the next ask shows another; "Test a week" runs the A vs B window
## and hands the world back (user_rev, clock, battery); Close loops… lists
## the loops; UiAudit on the chip. Shots of each.

var _fails: Array = []
var _dir := ""


func _ok(cond: bool, what: String) -> void:
	print("loopcloser %s: %s" % ["PASS" if cond else "FAIL", what])
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


func _audit(vp: Viewport, what: String) -> void:
	var audit := UiAudit.run(vp)
	print("loopcloser: audit %s — %s" % [what, UiAudit.summary_line(audit)])
	var shown := 0
	for f in audit.get("findings", []):
		if str(f.get("severity", "")) == "error" and shown < 8:
			print("loopcloser:   %s %s \"%s\" %s" % [f.get("kind"), f.get("path"), str(f.get("text", "")).left(50), str(f.get("rect"))])
			shown += 1
	_ok(int(audit.get("errors", 0)) == 0, "UiAudit: no errors (%s)" % what)


func _modal(tree: SceneTree, suffix: String) -> Node:
	for n in tree.root.get_children():
		var s: Script = n.get_script()
		if s != null and s.resource_path.ends_with(suffix):
			return n
	return null


## Select the item and click its inspector button.
func _click_inspector(tree: SceneTree, vp: Viewport, sgv: Node, item_id: String, text: String) -> bool:
	sgv.call("focus_graph_item", item_id)
	await _wait(tree, 1.0)
	var insp_tab: Button = sgv.get("_insp_tab_btn")
	if insp_tab != null and insp_tab.is_visible_in_tree():
		await HarnessInput.click(vp, insp_tab.get_global_rect().get_center())
		await _wait(tree, 0.6)
	var btn := HarnessInput.find_button_revealing(sgv, text)
	if btn == null:
		return false
	var q := btn.get_parent()
	while q != null:
		if q is ScrollContainer:
			(q as ScrollContainer).ensure_control_visible(btn)
		q = q.get_parent()
	await _wait(tree, 0.4)
	await HarnessInput.click(vp, btn.get_global_rect().get_center())
	await _wait(tree, 1.2)
	return true


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var vp := main.get_viewport()
	await _wait(tree, 0.5)
	var sgv := ServiceLocator.graph()
	_ok(sgv != null, "a graph view")
	if sgv == null:
		return {"ok": false, "fails": _fails}
	_dir = "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_dir))
	main.set("time_scale", 0.0)
	sgv.call("open_graph_view")
	await _wait(tree, 1.5)
	var model: GraphModel = sgv.get("model")
	var gc: Node = sgv.get("_graph_canvas")
	var closer: Node = sgv.call("loop_closer")
	# 1. Nothing by itself.
	await _wait(tree, 2.5)
	_ok((gc.get("suggestion") as Dictionary).is_empty() and not bool(closer.call("active")),
		"no ghost appears until asked")
	# 2. A toilet block whose urine goes nowhere.
	var max_x := 0.0
	for it in model.get_items_in_scope("root"):
		max_x = maxf(max_x, float((it as Dictionary).get("x", 0.0)) + float((it as Dictionary).get("width", 120.0)))
	var tid: String = model.generate_item_id()
	model.add_item({"id": tid, "type": "processor", "scope_id": "root", "x": max_x + 300.0, "y": 0.0,
		"width": 160.0, "height": 120.0, "specs": {"name": "Test Toilet Block",
		"inputs": [], "outputs": [{"kind": "urine", "rate": 20.0, "unit": "L/h"}]}})
	await _wait(tree, 0.5)
	for row in closer.call("loops_touching", tid):
		print("loopcloser: the toilet takes part in %s %s %s/h, %s" % [str(row["open"]["side"]), str(row["open"]["kind"]),
			UiText.num(float(row["open"]["kg_h"]), "kg"), UiText.count((row["plans"] as Array).size(), "plan")])
	var clicked := await _click_inspector(tree, vp, sgv, tid, "Close the urine loop")
	_ok(clicked, "the toilet block's inspector offers Close the urine loop")
	print("loopcloser: canvas view %s, scope %s / %s, 3D %s" % [str(gc.get("view_mode")), str(gc.get("active_scope_id")),
		str((closer.call("suggestion") as Dictionary).get("scope", "")), str(gc.call("_v3_on"))])
	_ok(bool(closer.call("active")) and bool(gc.call("suggestion_shown")), "a real click shows a ghost")
	var chip: Control = closer.call("chip")
	_ok(chip != null and chip.is_visible_in_tree(), "the chip is up: %s" % (str((closer.call("suggestion") as Dictionary).get("text", ""))))
	await _wait(tree, 1.0)
	_shot(vp, "01_ghost")
	_audit(vp, "ghost + chip")
	var sugg: Dictionary = closer.call("suggestion")
	var joins := false
	for c in sugg.get("conns", []):
		if str((c as Dictionary)["source"]) == tid:
			joins = true
	_ok(joins, "the ghost takes the toilet block's own urine output")
	var machines := int(sugg.get("machines", 0)) + int(sugg.get("tanks", 0))
	_ok(machines > 0, "the plan has a machine to place (%d)" % machines)
	# 3. Tab accepts: exactly one history entry.
	var hist: Object = sgv.get("_history")
	var depth0 := int(hist.call("undo_depth"))
	var n0 := model.items.size()
	HarnessInput.key(vp, KEY_TAB)
	await _wait(tree, 0.8)
	var depth1 := int(hist.call("undo_depth"))
	_ok(model.items.size() == n0 + machines, "a real Tab adds the %s (%d → %d items)" % [UiText.count(machines, "machine"), n0, model.items.size()])
	_ok(depth1 == depth0 + 1, "… as exactly one undo step (%d → %d)" % [depth0, depth1])
	_ok(not bool(closer.call("active")), "the ghost is gone once accepted")
	_shot(vp, "02_accepted")
	# 4. Ctrl+Z takes it back.
	HarnessInput.key(vp, KEY_Z, true)
	await _wait(tree, 0.8)
	_ok(model.items.size() == n0, "a real Ctrl+Z removes it (%d items)" % model.items.size())
	# 5. Dismiss, then ask again as after a reload.
	clicked = await _click_inspector(tree, vp, sgv, tid, "Close the urine loop")
	var first_sig := str((closer.call("suggestion") as Dictionary).get("sig", ""))
	var dis := HarnessInput.find_button(closer.call("chip"), "Dismiss")
	_ok(dis != null, "the chip has Dismiss")
	if dis != null:
		await HarnessInput.click(vp, dis.get_global_rect().get_center())
		await _wait(tree, 0.6)
	_ok(not bool(closer.call("active")), "a real click on Dismiss hides it")
	var dpath := GraphSuggestions.path_for_view(sgv)
	var on_disk := GraphSuggestions.load_dismissed(dpath)
	_ok(on_disk.has("%s|%s" % [GraphSuggestions.loop_key("root", "urine", "sink"), first_sig]),
		"the dismissal is saved with the world")
	closer.set("_dismissed_path", "-")
	sgv.call("close_loop_for_kind", "urine")
	await _wait(tree, 0.8)
	var second := closer.call("suggestion") as Dictionary
	_ok(not second.is_empty() and str(second.get("sig", "")) != first_sig,
		"read back from disk, the next ask shows another plan (or none): %s" % str(second.get("sig", "")))
	# 6. Test a week, and the world handed back.
	var solar: Node = main.get_node_or_null("UILayer/SolarUI")
	var rev0 := model.user_rev
	var clock0 := float(main.call("get_absolute_hours"))
	var batt0 := float(solar.get("battery_kwh_stored")) if solar != null else NAN
	if not bool(closer.call("active")):
		sgv.call("close_loop_for_kind", "urine")
		await _wait(tree, 0.6)
	var tw := HarnessInput.find_button(closer.call("chip"), "Test a week")
	_ok(tw != null, "the chip has Test a week")
	if tw != null:
		await HarnessInput.click(vp, tw.get_global_rect().get_center())
		await _wait(tree, 2.0)
		var cv: Node = main.get_node_or_null("CompareView")
		_ok(cv != null and str(cv.get("_mode")) == "ab", "Test a week opens Compare in A vs B")
		if cv != null:
			var done := await _until(tree, func() -> bool:
				return not bool(cv.call("is_running")) and not (cv.call("last_result") as Dictionary).is_empty(), 240.0)
			_ok(done, "the week runs")
			_shot(vp, "03_test_a_week")
			var frame: ModalFrame = cv.get("_frame")
			if frame != null:
				frame.close()
			await _wait(tree, 0.8)
	_ok(model.user_rev == rev0, "the world's graph is unchanged (user_rev %d → %d)" % [rev0, model.user_rev])
	_ok(absf(float(main.call("get_absolute_hours")) - clock0) < 1e-6, "the clock is where it was")
	_ok(is_nan(batt0) or absf(float(solar.get("battery_kwh_stored")) - batt0) < 1e-3, "the battery is where it was")
	closer.call("clear")
	# 7. Close loops… lists them.
	sgv.call("open_close_loops")
	await _wait(tree, 1.0)
	var lm := _modal(tree, "close_loops_modal.gd")
	_ok(lm != null, "Close loops… opens")
	if lm != null:
		var show := HarnessInput.find_button(lm, "Show", true)
		_ok(show != null, "it lists plans with Show")
		_shot(vp, "04_close_loops")
		_audit(vp, "Close loops…")
		(lm.get("_frame") as ModalFrame).close()
		await _wait(tree, 0.5)
	# 8. The open-loop badge on a group card: a real click enters it and
	# lists its loops.
	var root_trail: Array[String] = ["root"]
	sgv.call("_set_scope_trail", root_trail)
	await _wait(tree, 1.0)
	# A group of its own with a urine-making block inside (this world's
	# groups are vehicles and arrays, whose insides have no open loops).
	var gid: String = model.generate_item_id()
	var gscope := "scope_" + gid
	model.add_item({"id": gid, "type": "compound", "scope_id": "root", "x": max_x + 300.0, "y": 420.0,
		"width": 240.0, "height": 180.0, "child_scope_id": gscope, "specs": {"name": "Test Wash House"}})
	var inner: String = model.generate_item_id()
	model.add_item({"id": inner, "type": "processor", "scope_id": gscope, "x": 0.0, "y": 0.0,
		"width": 160.0, "height": 120.0, "specs": {"name": "Inner Toilets",
		"inputs": [], "outputs": [{"kind": "urine", "rate": 5.0, "unit": "L/h"}]}})
	gc.call("fit_items_to_view", [gid])
	await _wait(tree, 3.0)
	var badges: Dictionary = gc.get("open_loop_badges")
	var rects: Dictionary = gc.get("_open_loop_badge_rects")
	print("loopcloser: open-loop badges %s, drawn %d" % [str(badges), rects.size()])
	_ok(not badges.is_empty(), "group cards with open loops inside carry a badge")
	if not rects.is_empty():
		var bid := str(rects.keys()[0])
		var r: Rect2 = rects[bid]
		await HarnessInput.click(vp, (gc as Control).get_global_transform() * r.get_center())
		await _wait(tree, 1.5)
		var lm2 := _modal(tree, "close_loops_modal.gd")
		var child := str(model.get_item(bid).get("child_scope_id", ""))
		_ok(lm2 != null and str(sgv.get("_active_scope_id")) == child,
			"a real click on a badge enters that system and lists its loops")
		_shot(vp, "05_badge_list")
		if lm2 != null:
			(lm2.get("_frame") as ModalFrame).close()
			await _wait(tree, 0.5)
		sgv.call("_set_scope_trail", root_trail)
		await _wait(tree, 0.8)
	model.remove_item(inner)
	model.remove_item(gid)
	await _gap_week(main, sgv, model, gc, closer)
	await _replace_group(sgv, model, closer, tid)
	model.remove_item(tid)
	GraphSuggestions.save_dismissed(dpath, {})
	print("loopcloser %s (%d failures)" % ["PASS" if _fails.is_empty() else "FAIL", _fails.size()])
	return {"ok": _fails.is_empty(), "fails": _fails}


func _tank_of(model: GraphModel, kind: String) -> String:
	for it in model.get_items_in_scope("root"):
		var d: Dictionary = it
		if str(d.get("type", "")) == "resource" and ChainWiring.kind(str((d.get("specs", {}) as Dictionary).get("resource_kind", ""))) == kind:
			return str(d["id"])
	return ""


## Phase 8: a gap node on the world's urine, run for a sim week, its brief.
func _gap_week(main: Node, sgv: Node, model: GraphModel, gc: Node, closer: Node) -> void:
	var tree := main.get_tree()
	var vp := main.get_viewport()
	var root_trail: Array[String] = ["root"]
	sgv.call("_set_scope_trail", root_trail)
	await _wait(tree, 0.8)
	var ids0: Dictionary = {}
	for it in model.items:
		ids0[str((it as Dictionary)["id"])] = true
	closer.call("show_gap_for", "root", {"kind": "urine", "side": "sink", "kg_h": 1.0})
	await _wait(tree, 1.0)
	var sugg: Dictionary = closer.call("suggestion")
	_ok(int(sugg.get("gaps", 0)) == 1, "Add a gap node here shows a gap node as a ghost: %s" % str(sugg.get("text", "")))
	_shot(vp, "06_gap_ghost")
	HarnessInput.key(vp, KEY_TAB)
	await _wait(tree, 0.8)
	var gap := ""
	for it2 in model.items:
		var d: Dictionary = it2
		if not ids0.has(str(d["id"])) and DesignGap.is_gap(d.get("specs", {})):
			gap = str(d["id"])
	_ok(not gap.is_empty(), "Tab places the gap node")
	if gap.is_empty():
		return
	# What closing it should give: reclaimed water and nutrients, into the
	# world's own tanks.
	var sp: Dictionary = (model.get_item(gap)["specs"] as Dictionary).duplicate(true)
	sp["outputs"] = [{"kind": "irrigation_water", "rate": 0.0, "unit": "L/h"}, {"kind": "nutrients", "rate": 0.0, "unit": "kg/h"}]
	model.update_item(gap, {"specs": sp})
	var irr := _tank_of(model, "irrigation_water")
	var nut := _tank_of(model, "nutrients")
	_ok(not irr.is_empty() and not nut.is_empty(), "the world has reclaimed-water and nutrient tanks")
	model.add_connection({"polarity": "resource", "resource_type": "irrigation_water", "source_item_id": gap,
		"source_handle_id": "res_out_0", "target_item_id": irr, "target_handle_id": "input"})
	model.add_connection({"polarity": "resource", "resource_type": "nutrients", "source_item_id": gap,
		"source_handle_id": "res_out_1", "target_item_id": nut, "target_handle_id": "input"})
	var h0 := float(main.call("get_absolute_hours"))
	main.set("time_scale", 8.0)
	var ok := await _until(tree, func() -> bool: return float(main.call("get_absolute_hours")) - h0 >= 168.0, 120.0)
	main.set("time_scale", 0.0)
	await _wait(tree, 0.5)
	_ok(ok, "a sim week runs (%.0f h)" % (float(main.call("get_absolute_hours")) - h0))
	var meter: GapMeter = closer.call("gap_meter", gap)
	_ok(meter != null and meter.hours() > 100.0, "the gap node measured the week (%.0f h)" % (meter.hours() if meter != null else 0.0))
	var brief: Dictionary = closer.call("brief_for", gap)
	var text := "\n".join((brief.get("lines", []) as Array).map(func(x): return str(x["text"])))
	print("loopcloser: the brief —\n" + text)
	_ok(text.contains("Process") and text.contains("of urine") and text.contains("Deliver"), "the brief says what it processes and delivers")
	var path: String = closer.call("export_brief", gap)
	_ok(FileAccess.file_exists(path) and FileAccess.file_exists(path.get_basename() + ".json"), "the brief exports (%s)" % path)
	var gb := HarnessInput.find_button_revealing(sgv, "Export brief")
	sgv.call("focus_graph_item", gap)
	await _wait(tree, 1.0)
	gb = HarnessInput.find_button_revealing(sgv, "Export brief")
	_ok(gb != null, "the inspector shows the brief with Export")
	_shot(vp, "07_gap_inspector")
	closer.call("open_challenges")
	await _wait(tree, 1.0)
	var dm := _modal(tree, "design_challenges_modal.gd")
	_ok(dm != null and HarnessInput.find_button(dm, "Look") != null, "Design challenges lists it")
	_shot(vp, "08_challenges")
	_audit(vp, "Design challenges")
	if dm != null:
		(dm.get("_frame") as ModalFrame).close()
		await _wait(tree, 0.5)
	var comp: String = closer.call("design_gap", gap)
	var in_group := not comp.is_empty() and str(model.get_item(gap).get("scope_id", "")) == str(model.get_item(comp).get("child_scope_id", "-"))
	_ok(in_group, "Design this gap puts it in a group of its own")
	if not comp.is_empty():
		model.remove_item(comp)
	for it3 in model.items.duplicate():
		var d3: Dictionary = it3
		if not ids0.has(str(d3["id"])) and str(d3.get("type", "")) == "resource":
			model.remove_item(str(d3["id"]))
	if not model.get_item(gap).is_empty():
		model.remove_item(gap)


## Phase 8: a group's boundary becomes a gap node; Ctrl+Z puts it back.
func _replace_group(sgv: Node, model: GraphModel, closer: Node, toilet: String) -> void:
	var tree := sgv.get_tree()
	var t2: String = model.generate_item_id()
	model.add_item({"id": t2, "type": "resource", "scope_id": "root", "x": 0.0, "y": -400.0, "width": 120.0, "height": 120.0,
		"specs": {"name": "Test Urine Out", "resource_kind": "urine", "capacity_qty": 100.0, "capacity_unit": "L", "level": 0.0}})
	model.add_connection({"polarity": "resource", "resource_type": "urine", "source_item_id": toilet,
		"source_handle_id": "res_out_0", "target_item_id": t2, "target_handle_id": "input"})
	var sel: Array[String] = [toilet]
	sgv.set("_selected_item_ids", sel)
	var comp := str(sgv.call("_group_selected_items", false, "", "Test Toilets", {}, 1))
	await _wait(tree, 0.5)
	_ok(not comp.is_empty(), "a test group with a wire out of it")
	if comp.is_empty():
		model.remove_item(t2)
		return
	var n0 := model.items.size()
	var gid: String = closer.call("replace_with_gap", comp)
	await _wait(tree, 0.5)
	var wired := false
	for c in model.connections:
		var cd: Dictionary = c
		if str(cd.get("source_item_id", "")) == gid and str(cd.get("target_item_id", "")) == t2:
			wired = true
	_ok(not gid.is_empty() and model.get_item(comp).is_empty() and wired,
		"Replace with a gap node: the group is gone, its wire out moved onto the gap node")
	HarnessInput.key(sgv.get_viewport(), KEY_Z, true)
	await _wait(tree, 0.8)
	_ok(not model.get_item(comp).is_empty() and model.get_item(gid).is_empty(), "Ctrl+Z puts the group back")
	model.remove_item(comp)
	model.remove_item(t2)
