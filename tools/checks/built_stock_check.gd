extends RefCounted

## What is stored in things (resource composition plan Phase 9, sandbox,
## REAL input):
##   tools\harness.ps1 -World w6af22bac295d -RunScript res://tools/checks/built_stock_check.gd -Label built_stock -Timeout 1200
## The dashboard's WATER & NUTRIENTS card lists the site's built stock; a
## timber structure's editor says what it is made of; two REAL clicks on
## Salvage take it down into a lumber store on the graph (the prop is gone,
## the store holds its wood); a REAL click on the store's "Close this loop"
## offers the scrap-lumber kiln; a REAL Tab places it; the clock runs and the
## kiln turns the lumber into biochar. Shots of each.

var _fails: Array = []
var _dir := ""


func _ok(cond: bool, what: String) -> void:
	print("builtstock %s: %s" % ["PASS" if cond else "FAIL", what])
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
	print("builtstock: audit %s — %s" % [what, UiAudit.summary_line(audit)])
	for f in audit.get("findings", []):
		if str(f.get("severity", "")) == "error":
			print("builtstock:   %s %s \"%s\"" % [f.get("kind"), f.get("path"), str(f.get("text", "")).left(50)])
	_ok(int(audit.get("errors", 0)) == 0, "UiAudit: no errors (%s)" % what)


func _click(vp: Viewport, c: Control) -> void:
	await HarnessInput.click(vp, c.get_global_rect().get_center())


func _level_kg(model: GraphModel, sgv: Node, tid: String) -> float:
	var sp: Dictionary = model.get_item(tid).get("specs", {})
	var fe: Object = sgv.get("_resource_flow")
	var main := ServiceLocator.main()
	var lv := float(sp.get("level", 0.0))
	if fe != null and main != null:
		var tl: ResourceTimeline = fe.call("get_timeline", tid)
		if tl != null:
			lv = tl.level_at(float(main.call("get_absolute_hours")))
	return lv * float(sp.get("capacity_qty", 0.0))


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var vp := main.get_viewport()
	await _wait(tree, 0.5)
	_dir = "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_dir))
	main.set("time_scale", 0.0)
	var sgv := ServiceLocator.graph()
	var loader: Node = main.get_node_or_null("Terrain/TerrainLoader")
	if loader == null:
		loader = main.find_child("TerrainLoader", true, false)
	_ok(sgv != null and loader != null, "a graph and a terrain loader")
	if sgv == null or loader == null:
		return {"ok": false, "fails": _fails}
	var model: GraphModel = sgv.get("model")
	# 1. The site's built stock.
	var st: Dictionary = sgv.call("built_stock")
	print("builtstock: %d structures (%d not known), %s, C %s, water %s, %s; mostly %s" % [int(st["structures"]),
		int(st["unknown"]), ElementLedger.fmt_kg(float(st["kg"])),
		ElementLedger.fmt_kg(float((st["elements"] as Dictionary).get("C", 0.0))),
		ElementLedger.fmt_kg(float(st["water_kg"])), ElementLedger.fmt_energy_mj(float(st["energy_mj"])),
		BuiltStock.describe(st["by_material"], 5)])
	_ok(int(st["structures"]) > 0 and float(st["kg"]) > 0.0, "the site has built stock")
	sgv.call("open_graph_view")
	await _wait(tree, 2.0)
	var dash: Node = sgv.find_child("GraphDashboardPanel", true, false)
	if dash == null:
		for n in sgv.find_children("*", "", true, false):
			if n.get_script() != null and str((n.get_script() as Script).resource_path).ends_with("graph_dashboard_panel.gd"):
				dash = n
				break
	var shown := false
	if dash != null:
		dash.call("_refresh_made_of")
		await _wait(tree, 0.3)
		for l in dash.find_children("*", "Label", true, false):
			if (l as Label).text.contains("Built (in structures)") or (l as Label).text.contains("BUILT (IN STRUCTURES)"):
				shown = true
	_ok(shown, "the dashboard lists the built stock")
	_shot(vp, "01_dashboard")
	sgv.call("close_graph_view")
	await _wait(tree, 1.0)
	# 2. A timber structure: a site gate placed for the test.
	var pl: Node = main.find_child("Player", true, false)
	var at: Vector3 = (pl as Node3D).global_position + Vector3(0, 0, -8) if pl is Node3D else Vector3.ZERO
	var pid := str(loader.call("duplicate_prop_record", {"model_id": "site_gate", "x": at.x, "z": at.z, "yaw": 0.0}))
	await _wait(tree, 1.0)
	_ok(not pid.is_empty(), "a timber site gate is placed")
	if pid.is_empty():
		return {"ok": false, "fails": _fails}
	var ui: Control = main.get_node_or_null("UILayer/PlacedPropEditUI")
	_ok(ui != null, "the prop editor exists")
	if ui == null:
		return {"ok": false, "fails": _fails}
	ui.call("open_for_prop", pid)
	await _wait(tree, 1.0)
	var made: Label = ui.find_child("made_of", true, false)
	_ok(made != null and made.visible and made.text.begins_with("Made of") and made.text.contains("lumber"),
		"its editor says what it is made of: %s" % (made.text if made != null else "—"))
	_shot(vp, "02_made_of")
	_audit(vp, "prop editor")
	var expect: Dictionary = BuiltStock.salvage_kinds(BuiltStock.of_record({"model_id": "site_gate"})["materials"])["kinds"]
	var before: Dictionary = {}
	for it in model.items:
		before[str((it as Dictionary)["id"])] = true
	var sb: Button = ui.find_child("salvage", true, false)
	_ok(sb != null and sb.is_visible_in_tree(), "it offers Salvage")
	if sb == null:
		return {"ok": false, "fails": _fails}
	await _click(vp, sb)
	await _wait(tree, 0.5)
	_ok(sb.text.begins_with("Confirm"), "the first click asks")
	await _click(vp, sb)
	await _wait(tree, 1.5)
	_ok((loader.call("get_prop_record", pid) as Dictionary).is_empty(), "the second click takes it down")
	var lumber := ""
	for it2 in model.items:
		var d: Dictionary = it2
		if not before.has(str(d["id"])) and str(d.get("type", "")) == "resource" \
				and str((d.get("specs", {}) as Dictionary).get("resource_kind", "")) == "lumber":
			lumber = str(d["id"])
	var got := _level_kg(model, sgv, lumber) if not lumber.is_empty() else 0.0
	_ok(not lumber.is_empty() and absf(got - float(expect.get("lumber", 0.0))) < 0.5,
		"its wood is in a lumber store on the graph (%.1f of %.1f kg)" % [got, float(expect.get("lumber", 0.0))])
	if lumber.is_empty():
		return {"ok": false, "fails": _fails}
	# 3. Close this loop: the kiln.
	sgv.call("open_graph_view")
	await _wait(tree, 1.5)
	sgv.call("focus_graph_item", lumber)
	await _wait(tree, 1.0)
	var insp_tab: Button = sgv.get("_insp_tab_btn")
	if insp_tab != null and insp_tab.is_visible_in_tree():
		await _click(vp, insp_tab)
		await _wait(tree, 0.6)
	var cb := HarnessInput.find_button_revealing(sgv, "Close this loop")
	_ok(cb != null, "the lumber store offers Close this loop")
	if cb == null:
		return {"ok": false, "fails": _fails}
	var q := cb.get_parent()
	while q != null:
		if q is ScrollContainer:
			(q as ScrollContainer).ensure_control_visible(cb)
		q = q.get_parent()
	await _wait(tree, 0.4)
	await _click(vp, cb)
	await _wait(tree, 1.5)
	var closer: Node = sgv.call("loop_closer")
	var sugg: Dictionary = closer.call("suggestion")
	var has_kiln := false
	for g in (sugg.get("ghosts", []) as Array):
		if str(((g as Dictionary).get("item", {}) as Dictionary).get("specs", {}).get("name", "")).begins_with("Biochar Kiln"):
			has_kiln = true
	if not has_kiln:
		has_kiln = JSON.stringify(sugg.get("plan", {})).contains("Biochar Kiln")
	_ok(has_kiln, "the ghost is the scrap-lumber kiln: %s" % str(sugg.get("text", "")))
	_shot(vp, "03_kiln_ghost")
	var n0 := model.items.size()
	HarnessInput.key(vp, KEY_TAB)
	await _wait(tree, 1.0)
	var kiln := ""
	var char_tank := ""
	for it3 in model.items:
		var d3: Dictionary = it3
		var sp3: Dictionary = d3.get("specs", {})
		if str(sp3.get("name", "")).begins_with("Biochar Kiln") and not before.has(str(d3["id"])):
			kiln = str(d3["id"])
	for c in model.connections:
		var cd: Dictionary = c
		if str(cd.get("source_item_id", "")) == kiln and str(cd.get("resource_type", "")) == "biochar":
			char_tank = str(cd.get("target_item_id", ""))
	_ok(model.items.size() > n0 and not kiln.is_empty(), "a real Tab places the kiln")
	# 4. Run the clock: the lumber goes in, biochar comes out.
	sgv.call("close_graph_view")
	await _wait(tree, 0.5)
	var wood0 := _level_kg(model, sgv, lumber)
	var char0 := _level_kg(model, sgv, char_tank) if not char_tank.is_empty() else 0.0
	var h0 := float(main.call("get_absolute_hours"))
	var run_h := 24.0
	main.set("time_scale", 8.0)
	var states: Dictionary = {}
	await _until(tree, func() -> bool:
		var stn := str((model.get_item(kiln).get("specs", {}) as Dictionary).get("node_state", "?"))
		states[stn] = int(states.get(stn, 0)) + 1
		return float(main.call("get_absolute_hours")) - h0 >= run_h, 120.0)
	print("builtstock: kiln states over the run (frames): %s; specs %s" % [str(states),
		str((model.get_item(kiln).get("specs", {}) as Dictionary).get("inputs", []))])
	main.set("time_scale", 0.0)
	await _wait(tree, 0.5)
	var wood1 := _level_kg(model, sgv, lumber)
	var char1 := _level_kg(model, sgv, char_tank) if not char_tank.is_empty() else 0.0
	var state := str((model.get_item(kiln).get("specs", {}) as Dictionary).get("node_state", ""))
	var ks: Dictionary = model.get_item(kiln).get("specs", {})
	var dbg: Dictionary = {}
	for kk in ks.keys():
		if not (ks[kk] is Array or ks[kk] is Dictionary) or str(kk) in ["inputs", "outputs"]:
			dbg[kk] = ks[kk]
	print("builtstock: kiln specs %s" % JSON.stringify(dbg))
	for c2 in model.connections:
		var cd2: Dictionary = c2
		if str(cd2.get("source_item_id", "")) == kiln or str(cd2.get("target_item_id", "")) == kiln:
			print("builtstock: kiln wire %s:%s → %s:%s %s rate %s" % [str(cd2.get("source_item_id")), str(cd2.get("source_handle_id")),
				str(cd2.get("target_item_id")), str(cd2.get("target_handle_id")), str(cd2.get("resource_type", cd2.get("polarity"))), str(cd2.get("flow_rate", ""))])
	print("builtstock: kiln %s, lumber %.1f → %.1f kg, biochar %.2f → %.2f kg over %.1f h" % [state, wood0, wood1,
		char0, char1, float(main.call("get_absolute_hours")) - h0])
	_ok(wood1 < wood0 - 5.0 and char1 > char0 + 1.0, "the kiln turns the salvaged lumber into biochar")
	sgv.call("open_graph_view")
	await _wait(tree, 1.0)
	sgv.call("focus_graph_item", kiln)
	await _wait(tree, 1.0)
	_shot(vp, "04_kiln_running")
	print("builtstock %s (%d failures)" % ["PASS" if _fails.is_empty() else "FAIL", _fails.size()])
	return {"ok": _fails.is_empty(), "fails": _fails}
