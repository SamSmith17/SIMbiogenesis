extends RefCounted

## Time use on a real world (NPC life pass, Phase 9; sandbox, Closed Loop Ten):
##   tools\harness.ps1 -World w6af22bac295d -RunScript res://tools/checks/time_use_check.gd -Label time_use -Timeout 1500
## Runs the clock with the graph closed for two days (a whole day measured); the
## bridge's summary has every person's hours adding to a day, sleep and work
## in it and the rota's planned hours beside the measured; a scrub back is not
## counted. Then the readouts with REAL clicks: the Community schedule's
## Balance tab (tiles, the ATUS chart, a bar per person), the Site Report's
## Time use card, the dashboard's work line. UiAudit on the Balance tab. Shots.

var _fails: Array = []
var _dir := ""


func _ok(cond: bool, what: String) -> void:
	print("tucheck %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


func _shot(vp: Viewport, name: String) -> void:
	vp.get_texture().get_image().save_png("%s/%s.png" % [_dir, name])


func _find(root: Node, nm: String) -> Node:
	return root.find_child(nm, true, false) if root != null else null


func _click(tree: SceneTree, vp: Viewport, c: Control) -> void:
	var p := c.get_parent()
	while p != null:
		if p is ScrollContainer:
			(p as ScrollContainer).ensure_control_visible(c)
			break
		p = p.get_parent()
	await _frames(tree, 3)
	await HarnessInput.click(vp, c.get_global_transform_with_canvas() * (c.size * 0.5))
	await _frames(tree, 3)


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var vp := main.get_viewport()
	_dir = "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_dir))
	var b := ScheduleSources.bridge()
	var t0 := Time.get_ticks_msec()
	while (b == null or b.pop_driven_item_ids().is_empty()) and Time.get_ticks_msec() - t0 < 60000:
		await _frames(tree, 10)
		b = ScheduleSources.bridge()
	_ok(b != null and not b.pop_driven_item_ids().is_empty(), "a simulated camp")
	if b == null:
		return {"ok": false, "fails": _fails}

	# About a day lived with the graph closed (the ambient tick records it).
	main.set("time_scale", 600.0 / 3600.0)
	t0 = Time.get_ticks_msec()
	var h0 := float(main.call("get_absolute_hours"))
	while float(main.call("get_absolute_hours")) - h0 < 50.0 and Time.get_ticks_msec() - t0 < 900000:
		await tree.create_timer(1.0, true, false, true).timeout
	var lived := float(main.call("get_absolute_hours")) - h0
	main.set("time_scale", 0.0)
	await _frames(tree, 5)
	var tu: Dictionary = b.time_use_summary(7, "")
	print("tucheck: lived %.1f h · %d people · %.0f person-h recorded · mean %s" % [lived, int(tu["people"]),
		float(tu["recorded_h"]), str((tu["mean"] as Dictionary).keys().map(func(k): return "%s %.2f" % [k, float(tu["mean"][k])]))])
	print("tucheck: work %.1f h/person/week measured (%s), rota plans %.1f · leisure %.1f h/day" % [
		float(tu["work_h_week"]), str(tu["verdict"]), float(tu.get("planned_h_week", 0.0)), float(tu["leisure_h_day"])])
	_ok(int(tu["people"]) >= 1, "time recorded for the people (%d)" % int(tu["people"]))
	var per_person: float = float(tu["recorded_h"]) / maxf(float(tu["people"]), 1.0)
	_ok(not bool(tu["partial"]) and int(tu["days"]) >= 1, "a whole day measured (%d)" % int(tu["days"]))
	_ok(absf(per_person - 24.0 * float(tu["days"])) < 1.0,
		"each person's measured time is the whole days lived (%.1f h over %d)" % [per_person, int(tu["days"])])
	var sums_ok := true
	for p in tu["per_person"]:
		var s := 0.0
		for c in NpcTimeUse.CATS:
			s += float(p["hours"][c])
		if absf(s - 24.0) > 0.01:
			sums_ok = false
	_ok(sums_ok, "every person's day adds to 24 h")
	var mean: Dictionary = tu["mean"]
	_ok(float(mean["sleep"]) > 4.0 and float(mean["sleep"]) < 13.0, "sleep in a believable range (%.1f h)" % float(mean["sleep"]))
	_ok(float(mean["eat"]) > 0.2, "eating counted (%.2f h)" % float(mean["eat"]))
	_ok(float(tu.get("planned_h_week", 0.0)) > 0.0, "the rota's planned work beside the measured (%.1f h)" % float(tu.get("planned_h_week", 0.0)))
	# A scrub back is not counted (the scrubbed-into day is lived again).
	var rec0 := float(tu["recorded_h"])
	main.call("set_absolute_hours", float(main.call("get_absolute_hours")) - 3.0)
	main.set("time_scale", 60.0 / 3600.0)
	await tree.create_timer(1.5, true, false, true).timeout
	main.set("time_scale", 0.0)
	await _frames(tree, 4)
	var tu2: Dictionary = b.time_use_summary(7, "")
	_ok(float(tu2["recorded_h"]) <= rec0 + 0.5, "a scrub back is not counted as time (%.0f then %.0f person-h)" % [rec0, float(tu2["recorded_h"])])
	_ok(not bool(tu2["partial"]) and absf(float(tu2["mean"]["sleep"]) - float(mean["sleep"])) < 0.5,
		"after the scrub the whole day still answers (sleep %.1f h)" % float(tu2["mean"]["sleep"]))

	# --- the Community schedule's Balance tab ---
	var tlui: Node = ServiceLocator.timeline_ui()
	tlui.call("open_community_schedule", "Balance")
	await _frames(tree, 6)
	var cs: Node = _find(tlui, "CommunityScheduleModal")
	_ok(cs != null and bool(cs.call("is_open")), "the Community schedule opened")
	if cs != null:
		await _click(tree, vp, _find(cs.get("_frame"), "tab_balance") as Control)
		await _frames(tree, 6)
		var tiles := _find(cs, "time_use_tiles") as Control
		var groups := _find(cs, "time_use_groups") as Control
		var people := _find(cs, "time_use_people") as Control
		_ok(tiles != null and groups != null and people != null and groups.is_visible_in_tree(),
			"Balance: time-use tiles, the ATUS chart and a bar per person")
		if groups != null:
			var p := groups.get_parent()
			while p != null and not (p is ScrollContainer):
				p = p.get_parent()
			if p != null:
				(p as ScrollContainer).ensure_control_visible(groups)
			await _frames(tree, 4)
			await HarnessInput.mouse_move(vp, groups.get_global_transform_with_canvas() * Vector2(TimeUseBars.LABEL_W + 20.0, 3.0 + TimeUseBars.BAR_H * 0.5))
			await _frames(tree, 4)
			_ok(not groups.tooltip_text.is_empty(), "hovering the average day names a category (%s)" % groups.tooltip_text)
		_shot(vp, "01_balance")
		var audit := UiAudit.run(vp)
		print("tucheck: audit Balance — %s" % UiAudit.summary_line(audit))
		_ok(int(audit.get("errors", 0)) == 0, "UiAudit: no errors on the Balance tab")
		cs.call("close")
		await _frames(tree, 4)

	# --- the Site Report's card ---
	tlui.call("_on_site_report_pressed")
	var sr: Node = tlui.get("_site_report_panel")
	t0 = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 120000:
		await tree.create_timer(0.5, true, false, true).timeout
		var card := _find(sr, "TimeUseCard") as Control if sr != null else null
		if card != null and card.is_visible_in_tree() and str(sr.get("_time_use_stat").text).begins_with("Work this site takes"):
			break
	var card2 := _find(sr, "TimeUseCard") as Control if sr != null else null
	var stat_txt := str(sr.get("_time_use_stat").text) if sr != null and sr.get("_time_use_stat") != null else ""
	_ok(card2 != null and stat_txt.begins_with("Work this site takes"), "Site Report: the Time use card (%s)" % stat_txt.left(60))
	if card2 != null:
		var p2 := card2.get_parent()
		while p2 != null and not (p2 is ScrollContainer):
			p2 = p2.get_parent()
		if p2 != null:
			(p2 as ScrollContainer).ensure_control_visible(card2)
		await _frames(tree, 6)
		_shot(vp, "02_site_report")
	if sr != null and bool(sr.call("is_open")):
		sr.call("close")
	await _frames(tree, 4)

	# --- the dashboard's work line ---
	var gv := ServiceLocator.graph()
	gv.call("open_graph_view")
	await tree.create_timer(1.5, true, false, true).timeout
	var wl: Label = null
	t0 = Time.get_ticks_msec()
	while wl == null and Time.get_ticks_msec() - t0 < 15000:
		await tree.create_timer(0.5, true, false, true).timeout
		wl = _find(gv, "work_per_person") as Label
	_ok(wl != null and wl.text.begins_with("🔧 Work:"), "dashboard: the work per person line (%s)" % (wl.text if wl != null else ""))
	_shot(vp, "03_dashboard")
	gv.call("close_graph_view")
	await _frames(tree, 4)
	return {"ok": _fails.is_empty(), "fails": _fails}
