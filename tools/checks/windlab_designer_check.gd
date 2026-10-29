extends RefCounted

## The wind turbine designer on a REAL world (sandbox; writes nothing to the
## player's world):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/windlab_designer_check.gd -Label windlab
## Opens the designer through Main, shoots every built-in in the studio and
## the lawn sign's Blade / Power / Cut & print / Gearing tabs, runs UiAudit,
## drives its controls (a bigger rotor makes more), matches the gearing and
## ranks the generators, exports the files; places a lawn-sign turbine and a
## printed propeller through the graph's own placement (graph node bound,
## WindLabRuntime spinning it, the graph's watts == the design's power curve
## at the runtime's wind), applies a new design onto a placed turbine from
## the graph's side, keeps a shipped GLB turbine's model while giving it a
## designed curve, and hands a blade STL to a placed machine's print setup
## when there is one. Shots under screenshots\<label>\.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("windlab %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func _shoot(main: Node, path: String) -> void:
	main.get_viewport().get_texture().get_image().save_png(path)


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var dir := "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(dir)
	_ok(main.has_method("open_windlab"), "Main hosts the designer")
	var ui: Control = main.call("open_windlab", {})
	await _settle(tree, 20)
	_ok(ui != null and ui.visible and bool(ui.call("is_open")), "the designer opened on its own")
	if ui == null:
		return {"ok": false}
	var vp: SubViewport = ui.get("_viewport")
	for p in WindLabPresets.builtins():
		var id := str(p["id"])
		ui.call("set_spec", p["spec"])
		ui.call("_frame_camera")
		await _settle(tree, 16)
		var d: Dictionary = ui.call("design")
		var errs: Array = (d["checks"] as Array).filter(func(c): return str(c["level"]) == "error")
		print("windlab: %s — %s, peak %.1f W, %.2f kWh/yr, starts %.1f m/s, %d errors" % [id, WindLabSpec.describe(d["spec"]),
			float(d["peak_w"]), float(d["aep_kwh"]), float(d["start_ms"]), errs.size()])
		_ok(errs.is_empty(), "%s solves without an error" % id)
		var b: WindLabBuilder = ui.call("builder")
		_ok(b != null and b.find_child("RotorParts", true, false) != null, "%s drew its rotor" % id)
		vp.get_texture().get_image().save_png("%s/studio_%s.png" % [dir, id])
	ui.call("set_spec", WindLabPresets.lawn_sign_spec())
	ui.call("_frame_camera")
	await _settle(tree, 12)
	_shoot(main, "%s/modal.png" % dir)
	var audit := UiAudit.run(main.get_viewport())
	print("windlab: ui audit — %s" % UiAudit.summary_line(audit))
	_ok(int(audit.get("errors", 0)) == 0, "the open modal has no UI audit errors")
	for tab in [1, 2, 3]:
		ui.call("set_tab", tab)
		await _settle(tree, 4)
		_shoot(main, "%s/tab_%s.png" % [dir, ["", "blade", "power", "cut"][tab]])
	# Gearing & motors: the ranking.
	var rk: Array = ui.call("rank_generators")
	await _settle(tree, 6)
	_shoot(main, "%s/tab_gearing.png" % dir)
	_ok(rk.size() == WindLabParts.GENERATORS.size(), "every generator ranked (%s first)" % (str(rk[0]["label"]) if not rk.is_empty() else "-"))
	# The modal's own controls: a bigger rotor makes more.
	ui.call("set_spec", WindLabPresets.ugrinsky_1m_spec())
	await _settle(tree, 8)
	var e0 := float((ui.call("design") as Dictionary)["aep_kwh"])
	var dsp := ui.call("control_for", "rotor", "d_mm") as SpinBox
	_ok(dsp != null, "the diameter control")
	if dsp != null:
		dsp.value = 800.0
		await _settle(tree, 20)
		var e1 := float((ui.call("design") as Dictionary)["aep_kwh"])
		_ok(e1 > e0, "a bigger rotor makes more a year (%.1f → %.1f kWh)" % [e0, e1])
	var before := float((ui.call("design") as Dictionary)["aep_kwh"])
	var mg: Dictionary = ui.call("match_gearing")
	await _settle(tree, 8)
	var after := float((ui.call("design") as Dictionary)["aep_kwh"])
	print("windlab: match gearing — ratio %.2f, %.1f → %.1f kWh" % [float((ui.call("design") as Dictionary)["ratio"]), before, after])
	_ok(not mg.is_empty() and after >= before * 0.97, "matching the gearing keeps or raises the year's energy")
	ui.call("set_tab", 4)
	await _settle(tree, 10)
	_shoot(main, "%s/tab_gearing_ladder.png" % dir)
	_ok((ui.call("ladder") as Array).size() > 3, "the ratio sweep is drawn")
	ui.call("set_tab", 0)
	# Files.
	var r: Dictionary = ui.call("_on_export")
	_ok(bool(r.get("ok", false)) and (r["files"] as Array).size() >= 8, "the files are written (%d)" % (r.get("files", []) as Array).size())
	ui.call("close")
	await _settle(tree, 4)
	_ok(not ui.visible, "the designer closes")
	# --- Placed through the graph's own placement.
	var sgv := main.get_node_or_null("UILayer/SystemGraphView")
	var model: GraphModel = sgv.get("model") if sgv != null else null
	_ok(sgv != null and model != null, "the systems graph")
	if sgv == null:
		return {"ok": false, "fails": _fails}
	var player := ServiceLocator.player() as Node3D
	var at := player.global_position + Vector3(4.0, 0.0, -3.0) if player != null else Vector3(4.0, 0.0, -3.0)
	var pid_sign := _place(main, sgv, WindLabPresets.lawn_sign_spec(), at)
	await _settle(tree, 20)
	_ok(not pid_sign.is_empty(), "the lawn-sign turbine is placed (%s)" % pid_sign)
	var rec := PlacedPropService.get_prop_record(main, pid_sign)
	var gid := str(rec.get("graph_item_id", ""))
	var item := model.get_item(gid)
	_ok(not item.is_empty() and str(item.get("type", "")) == "wind", "…with a wind node on the graph")
	var sp: Dictionary = item.get("specs", {}) as Dictionary
	_ok(sp.get("power_curve_w", null) is Array and str(rec.get("kind", "")) == "windlab", "…carrying the designed curve")
	var prop := PlacedPropRuntime.find_by_prop_id(main, pid_sign)
	var rt: Node = prop.get_node_or_null("WindLabRuntime") if prop != null else null
	_ok(rt != null and prop.get_node_or_null("WindTurbineSpin") == null, "WindLabRuntime drives it (not the GLB spin)")
	var ports := ConnectionPortDefs.resolve_ports_for_prop(main, pid_sign)
	_ok(ports.size() == 2, "DC + / − ports on the prop")
	# The world's real wind may be calm: give the node a flat 120 rpm / 5 W
	# curve so the runtime has something to turn and report, whatever the
	# weather, then read it back.
	main.set("time_scale", 1.0 / 3600.0)
	var specs2 := sp.duplicate(true)
	specs2["power_curve_w"] = [[0.1, 5.0], [40.0, 5.0]]
	specs2["rpm_curve"] = [[0.1, 120.0], [40.0, 120.0]]
	specs2["cut_out_ms"] = 40.0
	model.update_item(gid, {"specs": specs2})
	await _settle(tree, 60)
	if rt != null:
		var v := float(rt.get("last_wind_ms"))
		var w := float(rt.get("last_w"))
		var want := WindTurbineSource.curve_at(specs2["power_curve_w"], v)
		print("windlab: runtime — wind %.2f m/s, %.0f rpm, %.2f W (curve %.2f W)" % [v, float(rt.get("last_rpm")), w, want])
		_ok(is_finite(v) and absf(w - want) <= maxf(want * 0.02, 0.05), "the runtime's watts are the curve's at its wind")
		var kw := float((model.get_item(gid).get("specs", {}) as Dictionary).get("current_output_kw", -1.0))
		_ok(absf(kw * 1000.0 - w) <= maxf(w * 0.05, 0.05), "the graph node shows them (%.2f W)" % (kw * 1000.0))
		var b2 := _builder_of(prop)
		var a0: Basis = b2.rotor().transform.basis if b2 != null else Basis.IDENTITY
		await _settle(tree, 20)
		var turning := b2 != null and not b2.rotor().transform.basis.is_equal_approx(a0)
		_ok(b2 != null and turning and float(rt.get("last_rpm")) > 100.0, "the rotor turns at the curve's speed (%.0f rpm)" % float(rt.get("last_rpm")))
		_ok(absf(w - 5.0) < 0.01, "and reports the curve's 5 W")
	# The camera beside it.
	await _world_shot(main, tree, prop, Vector3(1.2, 0.9, -1.4), Vector3(0, 0.7, 0), "%s/world_lawn_sign.png" % dir)
	# A propeller: it yaws.
	var pid_hawt := _place(main, sgv, WindLabPresets.hawt_printed_spec(), at + Vector3(-6.0, 0.0, 4.0))
	await _settle(tree, 30)
	print("windlab: propeller prop %s" % pid_hawt)
	var hprop := PlacedPropRuntime.find_by_prop_id(main, pid_hawt)
	var hb := _builder_of(hprop)
	_ok(hb != null and hb.yaw_node() != null, "the propeller is placed with its nacelle")
	await _world_shot(main, tree, hprop, Vector3(4.0, 3.0, -6.0), Vector3(0, 5.5, 0), "%s/world_hawt.png" % dir)
	# --- From the graph's side: Design wind turbine… on the placed node, Apply.
	_ok(bool(sgv.call("open_wind_designer", gid)), "the graph opens the designer on its wind node")
	await _settle(tree, 16)
	_ok(ui.visible and str(ui.get("_turbine_id")) == gid, "bound to the turbine")
	ui.call("set_spec", WindLabPresets.by_id("oil_drum"))
	await _settle(tree, 8)
	var msg := str(ui.call("apply"))
	await _settle(tree, 20)
	print("windlab: apply — %s" % msg)
	var sp3: Dictionary = model.get_item(gid).get("specs", {}) as Dictionary
	var d3: Dictionary = ui.call("design")
	_ok(absf(float(sp3.get("aep_kwh", -1.0)) - float(d3["aep_kwh"])) < 0.01, "the node carries the new design")
	var rec3 := PlacedPropService.get_prop_record(main, pid_sign)
	_ok(str((rec3.get("windlab_spec", {}) as Dictionary).get("type", "")) == "savonius", "and the prop is rebuilt as it")
	ui.call("close")
	await _settle(tree, 4)
	# --- A shipped GLB turbine keeps its model, gains the curve.
	var glb_preset := ComponentPresets.find_preset_by_label("Small HAWT 500W (3D)")
	var pid_glb := ""
	if not glb_preset.is_empty():
		var n_before := _prop_ids(main)
		sgv.call("_on_lib_place_model_requested", glb_preset, "", at + Vector3(8.0, 0.0, 8.0))
		await _settle(tree, 20)
		pid_glb = _new_prop(main, n_before)
	_ok(not pid_glb.is_empty(), "a shipped small HAWT is placed")
	if not pid_glb.is_empty():
		var gid2 := str(PlacedPropService.get_prop_record(main, pid_glb).get("graph_item_id", ""))
		sgv.call("open_wind_designer", gid2)
		await _settle(tree, 16)
		_ok(bool((ui.get("_keep_chk") as CheckBox).visible), "the designer offers to keep its model")
		ui.call("set_spec", WindLabPresets.by_id("air30_class"))
		await _settle(tree, 6)
		ui.call("apply")
		await _settle(tree, 20)
		var rg := PlacedPropService.get_prop_record(main, pid_glb)
		_ok(str(rg.get("model_id", "")) == "small_hawt" and (rg.get("wind_specs", {}) as Dictionary).get("rpm_curve", null) is Array,
			"it keeps the GLB and turns on the designed speed curve")
		ui.call("close")
		await _settle(tree, 4)
	# --- A part on a placed machine (if the world has one).
	ui.call("open", {"spec": WindLabPresets.hawt_printed_spec()})
	await _settle(tree, 10)
	var path := str(ui.call("send_part_to_machine", "hawt_blade"))
	await _settle(tree, 20)
	_ok(not path.is_empty() and FileAccess.file_exists(path), "the blade STL is written (%s)" % path.get_file())
	var ps: Variant = sgv.get("_print_setup_modal")
	if ps != null and (ps as Control).visible:
		print("windlab: the print setup opened with the blade")
		_shoot(main, "%s/print_setup.png" % dir)
		(ps as Object).call("close")
	else:
		print("windlab: no placed printer / router in this world — the STL is written for one")
		if ui.visible:
			ui.call("close")
	await _settle(tree, 4)
	# Clean up what was placed (the sandbox would drop it anyway).
	var loader := main.find_child("TerrainLoader", true, false)
	for pid in [pid_sign, pid_hawt, pid_glb]:
		if not str(pid).is_empty() and loader != null and loader.has_method("delete_prop_by_id"):
			loader.call("delete_prop_by_id", str(pid))
	print("windlab RESULT %s (%d failures)" % ["PASS" if _fails.is_empty() else "FAIL", _fails.size()])
	return {"ok": _fails.is_empty(), "fails": _fails}


## The placed prop's designed machine (ModelCatalog may rename the root).
func _builder_of(prop: Node) -> WindLabBuilder:
	if prop == null:
		return null
	if prop is WindLabBuilder:
		return prop as WindLabBuilder
	for n in prop.find_children("*", "Node3D", true, false):
		if n is WindLabBuilder:
			return n as WindLabBuilder
	return null


func _place(main: Node, sgv: Node, spec: Dictionary, at: Vector3) -> String:
	var before := _prop_ids(main)
	var preset := ComponentPresets.designed_wind_preset(spec)
	sgv.call("_on_lib_place_model_requested", preset, "", at)
	return _new_prop(main, before)


func _prop_ids(main: Node) -> Dictionary:
	var out := {}
	var loader := main.find_child("TerrainLoader", true, false)
	if loader != null and loader.has_method("placed_prop_records"):
		for r in loader.call("placed_prop_records"):
			out[str((r as Dictionary).get("id", ""))] = true
	return out


func _new_prop(main: Node, before: Dictionary) -> String:
	var now := _prop_ids(main)
	for id in now:
		if not before.has(id):
			return str(id)
	return ""


func _world_shot(main: Node, tree: SceneTree, prop: Node3D, off: Vector3, look: Vector3, path: String) -> void:
	if prop == null:
		return
	main.set("day_time", 13.0)
	var cam := Camera3D.new()
	main.add_child(cam)
	var a: Vector3 = prop.global_position
	cam.look_at_from_position(a + off, a + look, Vector3.UP)
	main.call("push_camera_claim", "windlab_check", {"camera_id": cam.get_instance_id()})
	await _settle(tree, 30)
	_shoot(main, path)
	main.call("pop_camera_claim", "windlab_check")
	cam.queue_free()
