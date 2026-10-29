extends RefCounted

## The Pelton wheel designer on a REAL world (sandbox; writes nothing to the
## player's world):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/peltonlab_designer_check.gd -Label peltonlab
## Opens the designer through Main (no turbine), shoots every built-in in
## the studio plus the Wheel and Performance tabs, runs UiAudit on the open
## modal, drives its own controls (the cup count and the wheel's size move
## the speed the right way), then finds a nozzle-governed turbine on the
## graph, opens the designer from it (as the Hydro Lab does), applies the
## classic wheel and checks what the turbine became: its kind, PCD and
## efficiencies, the graph's power == the designer's, the prop rebuilt as the
## designed machine with its runner turning; shoots it in the world and in
## the Hydro Lab's close-up.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("peltonlab %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var dir := "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(dir)
	_ok(main.has_method("open_peltonlab"), "Main hosts the designer")
	var ui: Control = main.call("open_peltonlab", {})
	await _settle(tree, 20)
	_ok(ui != null and ui.visible and bool(ui.call("is_open")), "the designer opened on its own")
	if ui == null:
		return {"ok": false}
	var vp: SubViewport = ui.get("_viewport")
	for p in PeltonLabPresets.builtins():
		var id := str(p["id"])
		ui.call("set_spec", p["spec"])
		ui.call("_frame_camera")
		await _settle(tree, 16)
		var d: Dictionary = ui.call("design")
		var errs: Array = (d["checks"] as Array).filter(func(c): return str(c["level"]) == "error")
		print("peltonlab: %s — %d cups, PCD %.0f mm, %d rpm, %.0f W, %d errors" % [id, int(d["runner"]["cups"]),
			float(d["runner"]["pcd_mm"]), int(d["perf"]["rpm"]), float(d["perf"]["p_elec_w"]), errs.size()])
		_ok(errs.is_empty(), "%s solves without an error" % id)
		var b: PeltonLabBuilder = ui.call("builder")
		_ok(b != null and b.get_node_or_null("Machine/Runner/Cups") != null, "%s drew its cups" % id)
		vp.get_texture().get_image().save_png("%s/studio_%s.png" % [dir, id])
	ui.call("set_spec", PeltonLabPresets.classic_spec())
	await _settle(tree, 12)
	for tab in [1, 2]:
		ui.call("set_tab", tab)
		await _settle(tree, 4)
		main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [dir, ["", "wheel", "performance"][tab]])
	ui.call("set_tab", 0)
	await _settle(tree, 6)
	main.get_viewport().get_texture().get_image().save_png("%s/modal.png" % dir)
	var audit := UiAudit.run(main.get_viewport())
	print("peltonlab: ui audit — %s" % UiAudit.summary_line(audit))
	_ok(int(audit.get("errors", 0)) == 0, "the open modal has no UI audit errors")
	var sw: Dictionary = ui.call("sweeps")
	_ok((sw["diameter"] as Array).size() == 17 and (sw["cups"] as Array).size() > 10, "the performance sweeps are filled")
	# The modal's own controls.
	var rpm0 := float((ui.call("design") as Dictionary)["perf"]["rpm"])
	var od := ui.call("control_for", "runner", "overall_d_mm") as SpinBox
	_ok(od != null, "the overall diameter control")
	if od != null:
		od.value = 500.0
		await _settle(tree, 16)
		var d1: Dictionary = ui.call("design")
		_ok(float(d1["perf"]["rpm"]) < rpm0 * 0.75, "a bigger wheel turns slower (%d → %d rpm)" % [int(rpm0), int(d1["perf"]["rpm"])])
	var cups := ui.call("control_for", "runner", "cups") as SpinBox
	if cups != null:
		cups.value = 26
		await _settle(tree, 16)
		_ok(int((ui.call("design") as Dictionary)["runner"]["cups"]) == 26, "the cup count control")
	vp.get_texture().get_image().save_png("%s/studio_edited.png" % dir)
	ui.call("close")
	await _settle(tree, 4)
	_ok(not ui.visible, "the designer closes")
	# --- Bound to a turbine, as the Hydro Lab opens it.
	var sgv := main.get_node_or_null("UILayer/SystemGraphView")
	var model: GraphModel = sgv.get("model") if sgv != null else null
	var tid := ""
	if model != null:
		for it in model.items:
			var sp: Dictionary = (it as Dictionary).get("specs", {}) as Dictionary
			if str(sp.get("role", "")) == "siphon_hydro" and not str(sp.get("bound_prop_id", "")).is_empty() \
					and bool(HydroSource.kind_meta(str(sp.get("turbine_kind", ""))).get("uses_nozzle_model", false)):
				tid = str((it as Dictionary)["id"])
				break
	_ok(not tid.is_empty(), "a nozzle turbine on the graph (%s)" % tid)
	if tid.is_empty():
		return {"ok": _fails.is_empty(), "fails": _fails}
	_ok(bool(sgv.call("open_pelton_designer", tid)), "the graph opens the designer on it")
	await _settle(tree, 16)
	_ok(ui.visible and str(ui.get("_turbine_id")) == tid, "the designer is bound to the turbine")
	var item := model.get_item(tid)
	var sp0: Dictionary = item["specs"]
	var site: Dictionary = (ui.call("spec") as Dictionary)["site"]
	_ok(absf(float(site["gross_head_m"]) - maxf(float(sp0.get("gross_head_m", 0.0)), 0.5)) < 1e-6, "the site is the turbine's head (%.1f m)" % float(site["gross_head_m"]))
	ui.call("set_spec", PeltonLabPresets.classic_spec())
	await _settle(tree, 8)
	var msg := str(ui.call("apply"))
	await _settle(tree, 20)
	print("peltonlab: apply — %s" % msg)
	item = model.get_item(tid)
	var sp: Dictionary = item["specs"]
	var d2: Dictionary = ui.call("design")
	_ok(str(sp.get("turbine_kind", "")) == "designed_pelton", "the turbine is a designed Pelton")
	_ok(absf(float(sp.get("runner_pcd_m", 0.0)) - float(d2["runner"]["pcd_mm"]) * 0.001) < 1e-6, "…with the wheel's PCD")
	_ok(absf(float(sp.get("turbine_efficiency", 0.0)) - float(d2["rules"]["eta_runner"])) < 1e-6, "…and its runner efficiency")
	var kw := HydroSource.power_kw_from_graph_specs(sp, 6)
	print("peltonlab: graph %.1f W, designer %.1f W" % [kw * 1000.0, float(d2["perf"]["p_elec_w"])])
	_ok(absf(kw * 1000.0 - float(d2["perf"]["p_elec_w"])) <= maxf(0.02 * float(d2["perf"]["p_elec_w"]), 1.0), "the graph makes the designer's power")
	var pid := str(sp.get("bound_prop_id", ""))
	var rec := PlacedPropService.get_prop_record(main, pid)
	_ok(str(rec.get("model_id", "")) == PeltonLabBuilder.MODEL_ID and (rec.get("pelton_spec", {}) as Dictionary).size() > 0,
		"the prop wears the designed machine")
	var prop := PlacedPropRuntime.find_by_prop_id(main, pid)
	var machine: Node = prop.find_child("Machine", true, false) if prop != null else null
	_ok(machine != null and machine.get_node_or_null("Runner") != null, "the placed prop has the runner")
	_ok(prop != null and prop.get_node_or_null("SiphonTurbineSpin") != null, "…and the turbine spin runtime")
	ui.call("close")
	await _settle(tree, 4)
	# --- In the world: a camera beside it.
	if prop != null:
		main.set("day_time", 13.0)
		var cam := Camera3D.new()
		main.add_child(cam)
		var a: Vector3 = (prop as Node3D).global_position
		cam.look_at_from_position(a + Vector3(1.6, 1.1, -1.8), a + Vector3(0, 0.35, 0), Vector3.UP)
		main.call("push_camera_claim", "peltonlab_check", {"camera_id": cam.get_instance_id()})
		await _settle(tree, 30)
		main.get_viewport().get_texture().get_image().save_png("%s/world.png" % dir)
		main.call("pop_camera_claim", "peltonlab_check")
		cam.queue_free()
	# --- The Hydro Lab's close-up builds the designed wheel.
	if sgv.has_method("open_siphon_lab"):
		sgv.call("open_graph_view")
		await _settle(tree, 10)
		sgv.call("open_siphon_lab", tid)
		await _settle(tree, 30)
		var lab: Control = sgv.get("_siphon_lab_modal")
		if lab != null and lab.has_method("_set_lab_view"):
			lab.call("_set_lab_view", "closeup")
			await _settle(tree, 40)
			main.get_viewport().get_texture().get_image().save_png("%s/closeup.png" % dir)
			var cu: Node = lab.get("_closeup")
			_ok(cu != null and str(cu.get("_model_id")) == PeltonLabBuilder.MODEL_ID, "the close-up wears the designed machine")
			_ok(cu != null and cu.get("_runner") != null, "…and found its runner")
			var btn: Button = lab.get("_pelton_btn")
			_ok(btn != null and btn.visible, "the Lab shows Design Pelton wheel…")
			lab.call("_set_lab_view", "section")
		sgv.call("close_graph_view")
		await _settle(tree, 6)
	print("peltonlab RESULT %s (%d failures)" % ["PASS" if _fails.is_empty() else "FAIL", _fails.size()])
	return {"ok": _fails.is_empty(), "fails": _fails}
