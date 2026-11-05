extends RefCounted

## Graph systems Phase 3 (plans/GRAPH_SYSTEMS_UX_PLAN.md) on the Walton
## festival world (sandbox, REAL clicks on the panels):
##   tools\harness.ps1 -World walton -RunScript res://tools/checks/graph_board_check.gd -Label graph_board -Timeout 900
## 1. The board's rows: one per system plus the site's own, the dashboard on
##    "Whole festival" by default.
## 2. A camp loses its power: after the latch's hold it lands on the alerts
##    rail; a real click on the entry flies to the camp.
## 3. Inside the camp the dashboard shows THAT camp (name, "no power").
## 4. The Board tab: real clicks on a filter chip and a row; the full-screen
##    board opens and Esc closes it.
## 5. Colour systems by battery: every system gets a value, the legend shows,
##    a real click on a legend band hides those systems.
## 6. The cost of one board refresh.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("graphboard %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


func _wait(tree: SceneTree, s: float) -> void:
	await tree.create_timer(s, true, false, true).timeout


func _shot(vp: Viewport, dir: String, name: String) -> void:
	vp.get_texture().get_image().save_png("%s/%s.png" % [dir, name])


func _click(vp: Viewport, c: Control) -> void:
	var p := c.get_global_rect().get_center()
	await HarnessInput.mouse_move(vp, p)
	await HarnessInput.click(vp, p)


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
	sgv.call("set_system_overlay", "none")
	if not bool(sgv.get("_sidebar_l_open")):
		sgv.call("_on_left_toggle")
	await _wait(tree, 2.5)
	var model: GraphModel = sgv.get("model")
	var canvas: Control = sgv.get("_graph_canvas")
	var dash: GraphDashboardPanel = sgv.get("_graph_dashboard")

	# --- 1. rows + default tab ----------------------------------------------
	var systems := GraphSystems.list(model)
	var rows: Array = sgv.call("system_board_rows")
	print("graphboard: %d systems, %d rows" % [systems.size(), rows.size()])
	_ok(systems.size() >= 10 and rows.size() == systems.size() + 1
		and str((rows[0] as Dictionary)["kind"]) == "site", "one row per system plus the site's own first")
	var levels := {}
	var why := {}
	for r: Dictionary in rows:
		levels[r["level"]] = int(levels.get(r["level"], 0)) + 1
		for w: Variant in (r["reasons"] as Array):
			why[str(w).get_slice(" ", 0)] = int(why.get(str(w).get_slice(" ", 0), 0)) + 1
	print("graphboard: levels %s, reasons %s" % [str(levels), str(why)])
	_ok(dash.current_tab() == "festival", "the dashboard opens on the whole festival")
	_shot(vp, dir, "01_festival_tab")

	# --- 2. a camp loses its power -> the alerts rail ------------------------
	var camps: Array = sgv.call("festival_camps")
	# A camp that is fine now, so its turn for the worse is news.
	var pick: Dictionary = camps[camps.size() / 3]
	for c: Dictionary in camps:
		if str((sgv.call("system_board_row", str(c["id"])) as Dictionary).get("level", "")) == "ok":
			pick = c
			break
	var cid := str(pick["id"])
	var cname := str(pick["name"])
	var cpow: Dictionary = sgv.call("camp_power_states")
	if not cpow.has(cid):
		cpow[cid] = CampPowerModel.make_state({"battery_kwh": 10.0}, 0.5)
	var saved: Dictionary = (cpow[cid] as Dictionary).duplicate()
	(cpow[cid] as Dictionary)["ac_available"] = false
	sgv.call("_refresh_system_board")
	var row: Dictionary = sgv.call("system_board_row", cid)
	_ok(str(row.get("level", "")) == "crit" and (row.get("reasons", []) as Array).has("no power"),
		"%s without power reads critical on the board" % cname)
	await _wait(tree, 2.6)
	sgv.call("_refresh_system_board")
	await _frames(tree, 2)
	var rail: Control = sgv.get("_alerts_rail")
	var entry: Control = rail.find_child("Alert_" + cid, true, false) if rail != null else null
	print("graphboard: alerts rail shows %d entries" % (rail.get_child_count() if rail != null else 0))
	_ok(entry != null and rail.visible, "after the hold the camp is on the alerts rail")
	_shot(vp, dir, "02_alert")
	if entry != null:
		await _click(vp, entry.find_child("Go", true, false) as Control)
		await _wait(tree, 0.8)
	var sel: Array = sgv.get("_selected_item_ids")
	_ok(sel.has(cid), "a real click on the alert flies to the camp")

	# --- 3. inside the camp ---------------------------------------------------
	sgv.call("focus_graph_item", cid, true)
	await _wait(tree, 1.2)
	dash.refresh(true)
	await _frames(tree, 2)
	var title: Label = dash.find_child("SystemTitle", true, false)
	var verdict: Label = dash.find_child("SystemVerdict", true, false)
	print("graphboard: inside — tab %s, title %s, verdict %s" % [dash.current_tab(),
		title.text if title != null else "-", verdict.text if verdict != null else "-"])
	_ok(dash.current_tab() == "system" and title != null and title.is_visible_in_tree()
		and title.text.contains(cname), "inside the camp the dashboard shows that camp")
	_ok(verdict != null and verdict.text.contains("no power"), "and says what is wrong with it")
	_shot(vp, dir, "03_inside_system")
	sgv.call("_jump_to_scope_index", 0)
	await _wait(tree, 0.8)

	# --- 4. the board -----------------------------------------------------------
	dash.refresh(true)
	var tab_board: Button = dash.find_child("Tab_board", true, false)
	await _click(vp, tab_board)
	await _wait(tree, 0.4)
	_ok(dash.current_tab() == "board", "a real click opens the Board tab")
	var board: GraphFestivalBoard = dash.board()
	var chip: Button = board.find_child("Filter_attention", true, false)
	await _click(vp, chip)
	await _wait(tree, 0.4)
	var att := GraphSystemBoard.filtered(sgv.call("system_board_rows") as Array, "attention")
	var row_box: Node = board.find_child("Row_" + cid, true, false)
	_ok(board.current_filter() == "attention" and row_box != null,
		"the attention filter lists the dark camp (%d need attention)" % att.size())
	_shot(vp, dir, "04_board_tab")
	sgv.call("_on_canvas_item_selected", "")
	if row_box != null:
		var scroll := dash.get_parent().get_parent() as ScrollContainer
		if scroll != null:
			scroll.ensure_control_visible(row_box as Control)
			await _frames(tree, 2)
		await _click(vp, row_box as Control)
		await _wait(tree, 0.8)
	sel = sgv.get("_selected_item_ids")
	_ok(sel.has(cid), "a real click on its board row flies to it")
	sgv.call("_on_view_menu_id", int(sgv.get_script().get_script_constant_map()["VIEW_BOARD_FULL"]))
	await _wait(tree, 0.5)
	_ok(bool(sgv.call("board_fullscreen_open")), "View ▾ opens the full-screen board")
	_shot(vp, dir, "05_board_full")
	await HarnessInput.key(vp, KEY_ESCAPE)
	await _wait(tree, 0.3)
	_ok(not bool(sgv.call("board_fullscreen_open")) and str(sgv.get("_active_scope_id")) == "root",
		"Esc closes it and stays at the site")
	var tab_fest: Button = dash.find_child("Tab_festival", true, false)
	await _click(vp, tab_fest)

	# --- 5. colour systems by battery ------------------------------------------
	var base := int(sgv.get_script().get_script_constant_map()["VIEW_OVERLAY_BASE"])
	sgv.call("_on_view_menu_id", base + GraphSystemBoard.OVERLAYS.find("soc"))
	canvas.call("fit_scope_to_view")
	await _wait(tree, 0.8)
	var ov: Dictionary = canvas.get("system_overlay")
	_ok(str(ov.get("mode", "")) == "soc" and (ov.get("values", {}) as Dictionary).size() == systems.size(),
		"every system has a battery colour")
	var legend: Control = sgv.get("_overlay_legend")
	_ok(legend != null and legend.visible, "the legend shows")
	var bin0: Button = legend.find_child("LegendBin0", true, false) if legend != null else null
	_shot(vp, dir, "06_overlay_soc")
	if bin0 != null:
		await _click(vp, bin0)
		await _wait(tree, 0.3)
	var hidden: Dictionary = sgv.call("overlay_hidden_bins")
	_ok(hidden.has(0) and ((canvas.get("system_overlay") as Dictionary).get("hidden", {}) as Dictionary).has(0),
		"a real click on a legend band hides those systems")
	_shot(vp, dir, "07_overlay_filtered")
	sgv.call("toggle_overlay_bin", 0)
	sgv.call("_on_mode_chip_pressed", GraphSiteLayout.VIEW_SITE)
	await _wait(tree, 1.5)
	_shot(vp, dir, "08_overlay_site_plan")
	sgv.call("_on_mode_chip_pressed", GraphSiteLayout.VIEW_FREEFORM)

	# --- 6. cost ----------------------------------------------------------------
	var times: Array = []
	for i in 7:
		var t0 := Time.get_ticks_usec()
		sgv.call("_refresh_system_board")
		times.append(float(Time.get_ticks_usec() - t0) / 1000.0)
	times.sort()
	print("graphboard: one board refresh %.2f ms (median of 7, %d systems)" % [times[3], systems.size()])
	var ti := Time.get_ticks_usec()
	var bsc := GraphNesting.scope_index(model)
	var ti2 := Time.get_ticks_usec()
	for sys: Dictionary in systems:
		if not str(sys["child_scope"]).is_empty():
			CampLedger.compute(model, str(sys["child_scope"]), {}, GraphNesting.walk_in_index(bsc, str(sys["child_scope"])))
	var ti3 := Time.get_ticks_usec()
	var tv := Time.get_ticks_usec()
	sgv.call("_push_system_overlay")
	var tv2 := Time.get_ticks_usec()
	print("graphboard: index %.2f ms, indexed ledgers %.2f ms, overlay push %.2f ms, items %d" % [
		float(ti2 - ti) / 1000.0, float(ti3 - ti2) / 1000.0, float(tv2 - tv) / 1000.0, model.items.size()])
	_ok(float(times[3]) < 10.0, "one board refresh is cheap (%.1f ms, once a second)" % times[3])

	# Put things back.
	cpow[cid] = saved
	sgv.call("set_system_overlay", "none")
	sgv.call("close_graph_view")
	return {"ok": _fails.is_empty(), "fails": _fails}
