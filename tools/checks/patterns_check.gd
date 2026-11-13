extends RefCounted

## The pattern charts and run Sankeys on a real world (sandbox):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/patterns_check.gd -Label patterns -Timeout 900
## Renders two days ahead (the sim pre-render), then opens Patterns from the
## timeline: the carpet plot has the days, a REAL click on a window button,
## the net-power channel, a REAL hover naming a cell; the phase orbit has its
## hours and a drift line; the energy budget lands its waterfall on what did
## work beside a Sankey. Then the challenge result card and a tutorial card
## carrying the energy split, the Compare window's "Show B − A" with a REAL
## click, and the Site Report's year carpets. Shots of each.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("patterns %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


func _wait(tree: SceneTree, s: float) -> void:
	await tree.create_timer(s, true, false, true).timeout


func _shot(vp: Viewport, dir: String, name: String) -> void:
	vp.get_texture().get_image().save_png("%s/%s.png" % [dir, name])


func _mid(c: Control) -> Vector2:
	return c.get_global_transform_with_canvas() * (c.size * 0.5)


func _find(root: Node, nm: String) -> Node:
	if root == null:
		return null
	return root.find_child(nm, true, false)


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var vp := main.get_viewport()
	await _frames(tree, 10)
	var dir := "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var sgv := ServiceLocator.graph()
	var su := ServiceLocator.solar_ui()
	_ok(sgv != null and su != null, "a graph view and SolarUI")
	if sgv == null or su == null:
		return {"ok": false, "fails": _fails}
	# Two days rendered ahead fill the energy timeline.
	var sr: Node = sgv.call("sim_renderer")
	var now := float(main.call("get_absolute_hours"))
	var res: Dictionary = sr.call("start", now + 48.0)
	_ok(bool(res.get("ok", true)), "the render started (%s)" % str(res.get("why", "")))
	var t0 := Time.get_ticks_msec()
	while bool(sr.call("is_active")) and Time.get_ticks_msec() - t0 < 120000:
		await _frames(tree, 5)
	var tl: EnergyTimeline = su.get("energy_timeline")
	_ok(tl != null and tl.end_abs_hours() - tl.start_abs_hours() >= 40.0,
		"two days recorded (%.1f h)" % (tl.end_abs_hours() - tl.start_abs_hours() if tl != null else 0.0))

	var tlui: Node = main.get_node_or_null("UILayer/TimelineUI")
	var pm: Node = tlui.call("open_patterns") if tlui != null else null
	_ok(pm != null and bool(pm.call("is_open")), "Patterns opened from the timeline")
	if pm == null:
		return {"ok": false, "fails": _fails}
	await _frames(tree, 8)
	var carpet: CarpetPlot = pm.get("_carpet")
	_ok(carpet != null and carpet.days >= 2, "the carpet has the days (%d)" % (carpet.days if carpet != null else 0))
	var finite := 0
	for v in carpet.values:
		if not is_nan(v):
			finite += 1
	_ok(finite >= 40, "%d hours with data" % finite)
	var w3 := _find(pm, "win_3") as Button
	if w3 != null:
		HarnessInput.click(vp, _mid(w3))
		await _frames(tree, 6)
	_ok(int(pm.get("_days")) == 3, "a real click on 3 days")
	var opt: OptionButton = pm.get("_carpet_opt")
	for i in opt.item_count:
		if str(opt.get_item_metadata(i)) == "net_kw":
			opt.select(i)
			opt.item_selected.emit(i)
	await _frames(tree, 4)
	_ok(carpet.is_diverging(), "net power draws on the diverging scale")
	HarnessInput.mouse_move(vp, _mid(carpet))
	await _frames(tree, 4)
	_ok((carpet.get("_hover") as Vector2i).x >= 0, "a real hover names a cell")
	_shot(vp, dir, "01_patterns_carpet")
	var orbit: PhaseOrbit = pm.get("_orbit")
	_ok(orbit != null and orbit.xs.size() >= 24, "the orbit has its hours (%d)" % (orbit.xs.size() if orbit != null else 0))
	var onote: Label = pm.get("_orbit_note")
	print("patterns orbit: %s" % onote.text)
	_ok(onote.text.length() > 10, "the orbit says how it drifts")
	var water: WaterfallChart = pm.get("_water")
	_ok(water != null and water.steps.size() >= 2 and str(water.steps[-1]["kind"]) == "total",
		"the budget waterfall ends on what did work")
	var box: HBoxContainer = pm.get("_budget_box")
	_ok(box.get_child_count() >= 2, "a Sankey beside the waterfall")
	print("patterns budget: %s" % (pm.get("_budget_note") as Label).text)
	var scroll := (pm.get("_frame") as ModalFrame).body.get_parent()
	if scroll is ScrollContainer:
		(scroll as ScrollContainer).scroll_vertical = 100000
		await _frames(tree, 4)
	_shot(vp, dir, "02_patterns_orbit_budget")
	(pm.get("_frame") as ModalFrame).close()
	await _frames(tree, 4)

	# The challenge result card and a tutorial card carry the energy split.
	var t1 := tl.end_abs_hours()
	var flows := EnergyRunSankey.flows_from_timeline(tl, t1 - 24.0, t1)
	_ok(not flows.is_empty() and float(flows["load"]) > 0.0, "a day's energy split (%s)" % EnergyRunSankey.summary(flows))
	var picker: Node = tlui.call("ensure_challenge_picker")
	picker.call("show_result", "keep_lights_on_day", true, {"score": 812.0, "energy_flows": flows,
		"utilization_pct": 64.0})
	await _frames(tree, 8)
	var rf := picker.get("_result_flows") as Control
	_ok(rf != null and rf.visible and _find(rf, "EnergySankey") != null, "the result card shows where the energy went")
	_shot(vp, dir, "03_result_card")
	picker.call("close_result")
	await _frames(tree, 3)
	sgv.call("open_graph_view")
	await _frames(tree, 8)
	sgv.call("show_tutorial_card", {"title": "Survived — now optimize", "placement": "corner",
		"body": "The day completed. Here is where the sun went.", "energy_flows": flows})
	await _frames(tree, 8)
	var fcm: Node = sgv.get("_fault_card_modal")
	var cf := _find(fcm, "CardFlows") as Control
	_ok(cf != null and cf.is_visible_in_tree(), "the tutorial card shows the energy split")
	var cpanel := fcm.get("_panel") as Control
	var bar_top := vp.get_visible_rect().size.y - HudLayout.timeline_height()
	var cbot := cpanel.get_global_rect().end.y if cpanel != null else 1e9
	_ok(cbot <= bar_top + 2.0, "the card stays above the timeline (bottom %.0f, bar %.0f)" % [cbot, bar_top])
	_shot(vp, dir, "04_tutorial_card")
	fcm.call("dismiss_all")
	sgv.call("close_graph_view")
	await _frames(tree, 6)

	# Compare: Show B − A.
	var cv: Node = main.call("open_compare_view")
	await _frames(tree, 6)
	var fa := {"nodes": [{"id": "t", "label": "Cistern"}, {"id": "p", "label": "People"},
			{"id": "g", "label": "Greywater"}, {"id": "b", "label": "Beds"}],
		"edges": [{"id": "1", "a": "t", "b": "p", "key": "water", "value": 40.0},
			{"id": "2", "a": "p", "b": "g", "key": "greywater", "value": 30.0},
			{"id": "3", "a": "t", "b": "b", "key": "water", "value": 25.0}],
		"bin": [], "bout": [], "labels": {"t": "Cistern", "p": "People", "g": "Greywater", "b": "Beds"},
		"opts": {"thickness": 26.0, "layer_gap": 60.0, "node_h": 30.0, "min_node_w": 130.0}}
	var fb := fa.duplicate(true)
	fb["nodes"].append({"id": "f", "label": "Filter"})
	fb["edges"] = [{"id": "1", "a": "t", "b": "p", "key": "water", "value": 40.0},
		{"id": "2", "a": "p", "b": "g", "key": "greywater", "value": 30.0},
		{"id": "4", "a": "g", "b": "f", "key": "greywater", "value": 28.0},
		{"id": "5", "a": "f", "b": "b", "key": "irrigation_water", "value": 26.0},
		{"id": "3", "a": "t", "b": "b", "key": "water", "value": 2.0}]
	fb["labels"]["f"] = "Filter"
	cv.call("_fill_ab_flows", [{"label": "As it is", "flows": fa}, {"label": "With a greywater filter", "flows": fb}])
	await _frames(tree, 4)
	var db := cv.get("_flows_diff_btn") as CheckButton
	if db != null and db.is_visible_in_tree():
		var fr := cv.get("_frame") as ModalFrame
		var sc := fr.body.get_parent()
		if sc is ScrollContainer:
			(sc as ScrollContainer).ensure_control_visible(db)
			await _frames(tree, 4)
		HarnessInput.click(vp, _mid(db))
		await _frames(tree, 6)
	var dview := cv.get("_flows_diff_view") as Control
	_ok(db != null and db.button_pressed and dview.is_visible_in_tree() and bool(dview.call("has_picture")),
		"a real click shows B − A")
	print("patterns diff: %s" % (cv.get("_flows_diff_cap") as Label).text)
	var fr2 := cv.get("_frame") as ModalFrame
	var sc2 := fr2.body.get_parent()
	if sc2 is ScrollContainer:
		(sc2 as ScrollContainer).ensure_control_visible(dview)
		await _frames(tree, 6)
	_shot(vp, dir, "05_compare_difference")
	fr2.close()
	await _frames(tree, 4)

	# The Site Report's year carpets.
	tlui.call("_on_site_report_pressed")
	var sp: Node = tlui.get("_site_report_panel")
	var t2 := Time.get_ticks_msec()
	var cp: CarpetPlot = null
	while Time.get_ticks_msec() - t2 < 180000:
		await _wait(tree, 1.0)
		cp = sp.get("_carpet_pv") as CarpetPlot if sp != null else null
		if cp != null and cp.days > 0:
			break
		if cp != null and (sp.get("_carpet_note") as Label).text.begins_with("Recompute"):
			var rb := HarnessInput.find_button(sp, "Recompute", true)
			if rb != null:
				rb.pressed.emit()
	_ok(cp != null and cp.days >= 365, "the Site Report has the year hour by hour (%d days)" % (cp.days if cp != null else 0))
	if cp != null:
		var sc3 := cp.get_parent()
		while sc3 != null and not (sc3 is ScrollContainer):
			sc3 = sc3.get_parent()
		if sc3 is ScrollContainer:
			(sc3 as ScrollContainer).ensure_control_visible(cp)
			await _frames(tree, 6)
	_shot(vp, dir, "06_site_report_carpets")
	sp.call("close")
	return {"ok": _fails.is_empty(), "fails": _fails}
