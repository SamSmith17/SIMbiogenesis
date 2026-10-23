extends RefCounted

## ⧉ Compare, A vs B, end to end on a REAL world (sandbox):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/compare_ab_probe.gd -Label compare_ab
##
## 1. A graph load gets a nightly shutdown (off 22:00 / on 06:00). The
##    automation card's "A/B this automation" (Main.ab_test_automation) makes
##    a fork without the "off" rule, opens Compare in A vs B and runs the
##    next week: the world (A) must use less energy than the fork (B), and
##    the window must say A wins.
## 2. Edit the fork (Main.edit_experiment_fork): the fork is on the canvas,
##    the clock is held, HA links and the live automation engine stand down;
##    a change to the fork, Done → the world's graph is back byte for byte on
##    that load, the HA links all survived, the fork kept the change, Compare
##    reopened on it.
## 3. The Solar Bootcamp sandbox no longer prunes the world's HA links.
## 4. UiAudit 0 errors; shots under screenshots/compare_ab/. Everything the
##    probe added is removed again.

var _fails: Array = []
var _dir := "user://screenshots/compare_ab"


func _ok(cond: bool, what: String) -> void:
	print("ab-check %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func _until(tree: SceneTree, cond: Callable, timeout_s: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while not bool(cond.call()):
		if (Time.get_ticks_msec() - t0) / 1000.0 > timeout_s:
			return false
		await tree.process_frame
	return true


func _shot(main: Node, name: String) -> void:
	DirAccess.make_dir_recursive_absolute(_dir)
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [_dir, name])


func _audit(main: Node, what: String) -> void:
	var audit := UiAudit.run(main.get_viewport())
	print("ab-check: audit %s — %s" % [what, UiAudit.summary_line(audit)])
	var shown := 0
	for f in audit.get("findings", []):
		if str(f.get("severity", "")) == "error" and shown < 8:
			print("ab-check:   %s %s \"%s\" %s" % [f.get("kind"), f.get("path"), str(f.get("text", "")).left(50), str(f.get("rect"))])
			shown += 1
	_ok(int(audit.get("errors", 0)) == 0, "UiAudit: no errors (%s)" % what)


func _wait_result(tree: SceneTree, view: Node) -> Dictionary:
	await _settle(tree, 2)
	var ok := await _until(tree, func() -> bool:
		return not bool(view.call("is_running")) and not (view.call("last_result") as Dictionary).is_empty(), 120.0)
	_ok(ok, "the A/B run finishes")
	var res: Dictionary = view.call("last_result")
	view.set("_result", {})
	return res


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var gv := ServiceLocator.graph()
	var model: GraphModel = gv.get("model") if gv != null else null
	var linker: Node = gv.get("_ha_linker") if gv != null else null
	_ok(model != null and linker != null, "graph + HA linker")
	if model == null:
		return {"ok": false, "fails": _fails}
	var exp_path := ExperimentStore.path_for_view(gv)
	var had_store := FileAccess.file_exists(exp_path)
	var store_bytes := FileAccess.get_file_as_string(exp_path) if had_store else ""
	var load_id := ""
	var best_w := 0.0
	for it in model.items:
		var sp: Dictionary = it.get("specs", {})
		if str(it.get("type", "")) in ["appliance", "acload"] and str(sp.get("requested_state", "on")) != "off":
			var w := float(sp.get("avg_watts", sp.get("watts", 0.0)))
			if w > best_w:
				best_w = w
				load_id = str(it["id"])
	_ok(not load_id.is_empty() and best_w > 0.0, "a switched-on load to schedule (%s, %.0f W)" % [load_id, best_w])
	if load_id.is_empty():
		return {"ok": false, "fails": _fails}
	var specs0: Dictionary = (model.get_item(load_id)["specs"] as Dictionary).duplicate(true)
	# A probe link on the load, so link survival is measured even on a world
	# with none.
	linker.call("link_entity", "sensor.ab_probe_power", HaTargets.item_target_id(load_id, "power"))
	var links0 := (linker.call("links") as Array).size()
	var ts0 := float(main.get("time_scale"))
	main.set("time_scale", 0.0)

	# ---- 1. the automation card's A/B ----
	var specs := specs0.duplicate(true)
	var autos: Array = (specs.get("graph_automations", []) as Array).duplicate(true)
	autos.append({"id": "ab_probe_off", "alias": "Probe off at 22", "enabled": true,
		"triggers": [{"kind": "time", "at_hour": 22.0}], "conditions": [],
		"actions": [{"kind": "scene_node", "command": "turn_off"}]})
	autos.append({"id": "ab_probe_on", "alias": "Probe on at 6", "enabled": true,
		"triggers": [{"kind": "time", "at_hour": 6.0}], "conditions": [],
		"actions": [{"kind": "scene_node", "command": "turn_on"}]})
	specs["graph_automations"] = autos
	model.update_item(load_id, {"specs": specs})
	var live_before: Dictionary = model.serialize()
	main.call("ab_test_automation", load_id, "ab_probe_off")
	await _settle(tree, 5)
	var view: Node = main.get_node_or_null("CompareView")
	_ok(view != null and str(view.get("_mode")) == "ab", "the shortcut opens Compare in A vs B")
	if view == null:
		return await _cleanup(main, gv, model, linker, load_id, specs0, exp_path, had_store, store_bytes, ts0)
	var res := await _wait_result(tree, view)
	var sims: Array = res.get("sims", [])
	_ok(sims.size() == 2, "two versions simulated")
	var store := ExperimentStore.load_from(exp_path)
	var fid := store.find_by_name("Without “Probe off at 22”")
	_ok(not fid.is_empty(), "the fork was saved in the world's experiments file")
	if sims.size() == 2:
		var ea: Dictionary = sims[0]["energy"]
		var eb: Dictionary = sims[1]["energy"]
		print("ab-check: A used %.1f kWh (AC off %.1f h), B used %.1f kWh (AC off %.1f h); A switched %d, B %d" % [
			float(ea["served_kwh"]), float(ea["ac_off_h"]), float(eb["served_kwh"]), float(eb["ac_off_h"]),
			(sims[0]["automation_log"] as Array).size(), (sims[1]["automation_log"] as Array).size()])
		_ok(float(ea["demand_kwh"]) < float(eb["demand_kwh"]) - 1.0,
			"the nightly shutdown lowers what the loads ask for (A %.1f < B %.1f kWh)" % [float(ea["demand_kwh"]), float(eb["demand_kwh"])])
		_ok((sims[0]["automation_log"] as Array).size() > (sims[1]["automation_log"] as Array).size(),
			"A's automations switch more often than B's")
		var banner: AlertBanner = view.get("_banner")
		print("ab-check: banner \"%s\"" % str(banner.get("_text")))
		_ok(banner.visible and str(banner.get("_text")).begins_with("A ·") and "wins" in str(banner.get("_text")),
			"the window says A (with the shutdown) wins on its default score")
	await _settle(tree, 20)
	_shot(main, "01_ab_result")
	_audit(main, "A vs B")
	var fr: Variant = view.get("_frame")
	var body: Control = fr.get("body") if fr != null else null
	if body != null and body.get_parent() is ScrollContainer:
		(body.get_parent() as ScrollContainer).scroll_vertical = 100000
		await _settle(tree, 8)
		_shot(main, "02_ab_table")

	# ---- 2. edit the fork ----
	var eng: Node = tree.root.get_node_or_null("AutomationEngine")
	var ok_edit := bool(main.call("edit_experiment_fork", fid))
	await _settle(tree, 10)
	_ok(ok_edit and str(gv.call("fork_edit_id")) == fid, "editing the fork")
	_ok(main.get_node_or_null("CompareView") == null, "Compare closed while editing")
	_ok(eng != null and not eng.is_processing(), "the live automation engine stands down")
	_ok(bool(linker.get("suspended")), "the HA links stand down")
	_ok(main.has_method("clock_hold_owner") == false or str(main.call("clock_hold_owner")) in ["fork_edit", ""],
		"the clock is held by the fork edit")
	var fl := model.get_item(load_id)
	var off_enabled := true
	for a in (fl["specs"] as Dictionary).get("graph_automations", []):
		if str(a.get("id", "")) == "ab_probe_off":
			off_enabled = bool(a.get("enabled", true))
	_ok(not off_enabled, "the canvas holds the fork (its 'off' rule is disabled)")
	var fsp: Dictionary = (fl["specs"] as Dictionary).duplicate(true)
	fsp["avg_watts"] = 321.0
	model.update_item(load_id, {"specs": fsp})
	await _settle(tree, 20)
	_shot(main, "03_fork_edit")
	var bar: Node = main.get_node_or_null("ForkEditBar")
	_ok(bar != null, "the fork bar is up")
	if bar != null:
		bar.call("finish", true)
	await _settle(tree, 20)
	_ok(str(gv.call("fork_edit_id")).is_empty(), "fork editing ended")
	var back_specs: Dictionary = model.get_item(load_id)["specs"]
	var orig_specs: Dictionary = {}
	for it in live_before["items"]:
		if str(it["id"]) == load_id:
			orig_specs = it["specs"]
	_ok(is_equal_approx(float(back_specs.get("avg_watts", -1.0)), float(orig_specs.get("avg_watts", -2.0))) \
		and JSON.stringify(back_specs.get("graph_automations", [])) == JSON.stringify(orig_specs.get("graph_automations", [])),
		"the world's load is back as it was")
	_ok(model.items.size() == (live_before["items"] as Array).size(), "the world has all its items back")
	_ok((linker.call("links") as Array).size() == links0, "every HA link survived the fork edit (%d)" % links0)
	_ok(eng != null and eng.is_processing() and not bool(linker.get("suspended")), "engine and links back on")
	var f2 := ExperimentStore.load_from(exp_path).get_fork(fid)
	var kept := 0.0
	for it in (f2.get("graph", {}) as Dictionary).get("items", []):
		if str(it["id"]) == load_id:
			kept = float((it["specs"] as Dictionary).get("avg_watts", 0.0))
	_ok(is_equal_approx(kept, 321.0), "the fork kept its change (%.0f W)" % kept)
	view = main.get_node_or_null("CompareView")
	_ok(view != null and str(view.get("_mode")) == "ab", "Done reopened Compare in A vs B")
	if view != null:
		view.call("run_ab_with", ExperimentStore.CURRENT, fid, floorf(float(main.call("get_absolute_hours"))),
			floorf(float(main.call("get_absolute_hours"))) + 24.0, "served_kwh")
		var res2 := await _wait_result(tree, view)
		_ok((res2.get("sims", []) as Array).size() == 2, "A/B with the edited fork runs")
		await _settle(tree, 15)
		_shot(main, "04_ab_edited_fork")
		var fr2: Variant = view.get("_frame")
		if fr2 != null:
			fr2.call("close")
		await _settle(tree, 5)

	# ---- 3. the bootcamp sandbox keeps the world's links ----
	if gv.has_method("begin_tutorial_sandbox") and bool(gv.call("begin_tutorial_sandbox")):
		await _settle(tree, 10)
		gv.call("end_tutorial_sandbox")
		await _settle(tree, 10)
		_ok((linker.call("links") as Array).size() == links0, "the bootcamp sandbox no longer prunes HA links")
	return await _cleanup(main, gv, model, linker, load_id, specs0, exp_path, had_store, store_bytes, ts0)


func _cleanup(main: Node, gv: Node, model: GraphModel, linker: Node, load_id: String, specs0: Dictionary,
		exp_path: String, had_store: bool, store_bytes: String, ts0: float) -> Dictionary:
	if not str(gv.call("fork_edit_id")).is_empty():
		gv.call("end_fork_edit", false)
	model.update_item(load_id, {"specs": specs0})
	var eng: Node = main.get_tree().root.get_node_or_null("AutomationEngine")
	if eng != null:
		for aid in ["ab_probe_off", "ab_probe_on"]:
			eng.call("unregister_automation", aid)
	linker.call("unlink_target", HaTargets.item_target_id(load_id, "power"))
	if had_store:
		var f := FileAccess.open(exp_path, FileAccess.WRITE)
		f.store_string(store_bytes)
	elif FileAccess.file_exists(exp_path):
		DirAccess.remove_absolute(exp_path)
	main.set("time_scale", ts0)
	return {"ok": _fails.is_empty(), "fails": _fails}
