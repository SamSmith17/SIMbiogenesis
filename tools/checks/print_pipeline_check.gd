extends RefCounted
## The print pipeline on a REAL world (sandbox; writes nothing to the
## player's world):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/print_pipeline_check.gd -Label print_pipeline -Timeout 900
## Places a Trash Printer and a Mud Printer beside the player, opens the
## print setup on each through the graph view's own entry point, slices a
## dome hub STL (×4) in the modal, scrubs the studio and asserts the real
## machine's tool follows (preview_tool_mm), exports G-code and reads it
## back, starts the print, runs the world clock and asserts what a PNG
## cannot: the roads grow move by move, the nozzle in WORLD space sits on
## the road being laid (trash: the bed drops and carries the print under
## the fixed nozzle; mud: the head rises), the planned time is the job's
## duration, completion credits the part (trash) or leaves a printed object
## on the map (mud). Shots under screenshots\print_pipeline\. Deletes what it
## placed.

var _fails: Array = []
const SHOT_DIR := "user://screenshots/print_pipeline"


func _ok(cond: bool, what: String) -> void:
	print("print-pipeline %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func _shot(main: Node, name: String) -> void:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := main.get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
	img.save_png("%s/%s.png" % [SHOT_DIR, name])
	print("print-pipeline shot: %s" % name)


func _until(tree: SceneTree, secs: float, pred: Callable) -> bool:
	var t := 0.0
	while t < secs:
		if bool(pred.call()):
			return true
		await tree.create_timer(0.2).timeout
		t += 0.2
	return bool(pred.call())


## The settlement view over the machine (the probes' shot camera): height
## and focus set outright, both ease otherwise.
func _look_at(main: Node, target: Vector3, _from: Vector3, h: float = 8.0) -> void:
	var view: Variant = main.get("settlement_view")
	if (view == null or not bool(view.call("is_open"))) and main.has_method("open_settlement_view"):
		main.call("open_settlement_view", Vector2(target.x, target.z), h)
		await main.get_tree().process_frame
		view = main.get("settlement_view")
	var cam: Variant = view.get("_cam") if view != null else null
	if cam == null:
		return
	cam.set("_h_target", h)
	cam.set("_h", h)
	cam.set("focus", Vector2(target.x, target.z))
	cam.set("_focus_target", Vector2(target.x, target.z))


func _place(main: Node, model_id: String, x: float, z: float) -> String:
	var r := PlacedPropService.place_model_at_xz(main, model_id, x, z, {
		"kind": "cartesian_machine",
		"machine_profile": CartesianMachineProfile.get_profile(model_id).to_dict(),
	})
	return str(r.get("prop_id", ""))


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	await _settle(tree, 20)
	var sgv := ServiceLocator.graph()
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	_ok(sgv != null and loader != null, "graph view + loader")
	if sgv == null or loader == null:
		return {"ok": false, "fails": _fails}
	var player := main.find_child("Player", true, false) as Node3D
	var px := player.global_position.x if player != null else 0.0
	var pz := player.global_position.z if player != null else 0.0
	main.set("time_scale", 0.0)

	# ---- Trash printer ------------------------------------------------------
	var trash := _place(main, "trash_printer", px + 6.0, pz + 2.0)
	_ok(not trash.is_empty(), "trash printer placed")
	await _settle(tree, 30)
	var tprop := PlacedPropRuntime.find_by_prop_id(main, trash)
	var trt: CncMachineRuntime = tprop.get_node_or_null("CncMachineRuntime") if tprop != null else null
	_ok(trt != null, "the GLB runtime attached")
	var opened := bool(sgv.call("open_print_setup_for_prop", trash))
	await _settle(tree, 10)
	var modal: Control = sgv.get("_print_setup_modal")
	_ok(opened and modal != null and modal.visible, "print setup opened on the trash printer")
	if modal == null or trt == null:
		return {"ok": false, "fails": _fails}
	var iid := str(trt.graph_item_id)
	_ok(not iid.is_empty() and not (sgv.model.get_item(iid) as Dictionary).is_empty(), "the printer is bound to a graph node")
	modal.call("load_stl", DomeParts.STL[DomeParts.PART_HUB_4])
	modal.call("set_slicer", {"scale": 4.0, "infill_pct": 25.0, "layer_height_mm": 0.8})
	await _settle(tree, 5)
	var job: Dictionary = modal.call("job")
	_ok(bool(job.get("ok", false)) and int(job.get("layers", 0)) >= 6 and float(job.get("total_s", 0.0)) > 60.0,
		"sliced: %s, %s, %s" % [UiText.count(int(job.get("layers", 0)), "layer"), UiText.count((job.get("moves", []) as Array).size(), "move"), GantryLabMotion.fmt_duration(float(job.get("total_s", 0.0)))])
	var ds: Dictionary = trt.debug_state()
	_ok(bool(ds.get("bed_lowering", false)) and bool(ds.get("frame_valid", false)), "trash printer: a lowering bed, frame measured (work %s)" % str(ds.get("work")))
	_ok(trt.has_print_preview(), "the ghost of the print is on the real bed")
	# Scrub the studio: the real machine's tool follows.
	modal.call("sim_seek", 0.5)
	await _settle(tree, 3)
	var st: Dictionary = modal.call("sim_state")
	var want: Vector3 = st.get("pos", Vector3.ZERO)
	ds = trt.debug_state()
	_ok((ds["pos_mm"] as Vector3).distance_to(want) < 0.5, "scrubbing the studio moved the real tool to %s (studio %s)" % [str(ds["pos_mm"]), str(want)])
	await _shot(main, "01_trash_setup")
	# Export and read back.
	var gpath := "user://screenshots/print_pipeline/hub_trash.gcode"
	var written: String = modal.call("export_gcode", gpath)
	var f := FileAccess.open(gpath, FileAccess.READ)
	var back := GantryLabGcode.parse(f.get_as_text()) if f != null else {}
	_ok(not written.is_empty() and bool(back.get("ok", false)) and absi((back["moves"] as Array).size() - (job["moves"] as Array).size() - 1) <= 2,
		"G-code exported and read back: %d moves" % int((back.get("moves", []) as Array).size()))
	modal.call("start_print")
	await _settle(tree, 5)
	var item := sgv.model.get_item(iid) as Dictionary
	var specs: Dictionary = item.get("specs", {})
	_ok(bool(specs.get("job_active", false)) and absf(float(specs.get("job_total_s", 0.0)) - float(job["total_s"])) < 1e-3 and absf(float(specs.get("job_duration_hr", 0.0)) * 3600.0 - float(job["total_s"])) < 0.5,
		"job scheduled: %.0f s planned = %.0f s duration" % [float(specs.get("job_total_s", 0.0)), float(specs.get("job_duration_hr", 0.0)) * 3600.0])
	_ok(not modal.visible, "the modal closed on start")
	# Run the clock: 60× for a minute of real time covers the print.
	var total_s := float(job["total_s"])
	await _look_at(main, tprop.global_position + Vector3(0, 1.0, 0), tprop.global_position + Vector3(2.5, 1.6, 2.5))
	main.set("time_scale", total_s / 3600.0 / 24.0)   # the whole job in ~24 s
	print("print-pipeline debug clock: time_scale %s hold '%s'" % [str(main.get("time_scale")), str(main.call("clock_hold_owner"))])
	var mid_ok := await _until(tree, 20.0, func() -> bool:
		var it := sgv.model.get_item(iid) as Dictionary
		return float((it.get("specs", {}) as Dictionary).get("job_progress", 0.0)) >= 0.45)
	await _settle(tree, 12)
	ds = trt.debug_state()
	var it2 := sgv.model.get_item(iid) as Dictionary
	var prog := float((it2.get("specs", {}) as Dictionary).get("job_progress", 0.0))
	_ok(mid_ok and bool(ds["loaded"]) and int(ds["roads_shown"]) > 0 and int(ds["roads_shown"]) < int(ds["roads"]), "mid-print: %d of %d roads laid at %.0f %%" % [int(ds["roads_shown"]), int(ds["roads"]), prog * 100.0])
	# The nozzle in WORLD space sits on the road being laid.
	var pl := PrintJobPlayer.new()
	pl.load(str(ds["job_id"]), specs)
	var smp := pl.sample(prog)
	var pos: Vector3 = smp["pos"]
	var roads: PrintRoads = trt.roads()
	var road_pt: Vector3 = roads.global_transform * (Vector3(pos.x, pos.z, pos.y) * 0.001)
	var tip: Vector3 = trt._tool_tip_world()
	var gap := tip.distance_to(road_pt)
	print("print-pipeline debug trash: tip %s road %s delta %s pos_mm %s mpl %s centre %s soft %s..%s" % [str(tip), str(road_pt), str(tip - road_pt), str(pos), str(ds.get("mpl")), str(ds.get("centre_u")), str(ds.get("soft_min")), str(ds.get("soft_max"))])
	print("print-pipeline debug trash axes: %s" % JSON.stringify(ds.get("axes", {})))
	_ok(gap < 0.08, "trash: the nozzle is on the road being laid (%.1f cm off)" % (gap * 100.0))
	var zn: Node3D = trt._axis_nodes.get("z")
	var zrest: Vector3 = trt._axis_rest.get("z", Vector3.ZERO)
	_ok(zn != null and zn.position.distance_to(zrest) > 1e-5, "trash: the bed has moved off its rest pose")
	_ok(absf(tip.y - road_pt.y) < 0.05, "trash: the nozzle stays at one height, the bed drops (%.1f cm)" % (absf(tip.y - road_pt.y) * 100.0))
	await _shot(main, "02_trash_printing")
	var done := await _until(tree, 40.0, func() -> bool:
		var it := sgv.model.get_item(iid) as Dictionary
		return bool((it.get("specs", {}) as Dictionary).get("job_completed", false)))
	await _settle(tree, 10)
	var inv: PartInventory = loader.call("get_part_inventory")
	var part_id := str(specs.get("job_part_id", ""))
	_ok(done and inv != null and inv.count(part_id) >= 1, "trash: the print completed and credited '%s' to the inventory" % part_id)
	ds = trt.debug_state()
	_ok(int(ds["roads_shown"]) == int(ds["roads"]), "trash: the finished part stays on the bed, every road laid")
	await _shot(main, "03_trash_done")
	main.set("time_scale", 0.0)

	# ---- Mud printer --------------------------------------------------------
	var mud := _place(main, "mud_printer", px - 10.0, pz + 8.0)
	_ok(not mud.is_empty(), "mud printer placed")
	await _settle(tree, 30)
	var mprop := PlacedPropRuntime.find_by_prop_id(main, mud)
	var mrt: CncMachineRuntime = mprop.get_node_or_null("CncMachineRuntime") if mprop != null else null
	_ok(mrt != null and bool(sgv.call("open_print_setup_for_prop", mud)), "print setup opened on the mud printer")
	await _settle(tree, 10)
	if mrt == null:
		return {"ok": false, "fails": _fails}
	var miid := str(mrt.graph_item_id)
	modal.call("load_stl", DomeParts.STL[DomeParts.PART_HUB_4])
	modal.call("set_slicer", {"scale": 40.0, "mode": "solid", "infill_pct": 0.0, "walls": 2, "layer_height_mm": 25.0, "line_width_mm": 76.2})
	await _settle(tree, 5)
	var mjob: Dictionary = modal.call("job")
	var mds: Dictionary = mrt.debug_state()
	_ok(bool(mjob.get("ok", false)) and not bool(mds.get("bed_lowering", true)), "mud: sliced at 76 mm lines (%s, %s), a fixed bed" % [UiText.count(int(mjob.get("layers", 0)), "layer"), GantryLabMotion.fmt_duration(float(mjob.get("total_s", 0.0)))])
	var printed_before := _printed_count(main)
	modal.call("start_print")
	await _settle(tree, 5)
	var mitem := sgv.model.get_item(miid) as Dictionary
	var mspecs: Dictionary = mitem.get("specs", {})
	_ok(bool(mspecs.get("job_active", false)) and bool(mspecs.get("print_persist", false)), "mud job scheduled, persists")
	var mtotal := float(mjob.get("total_s", 1.0))
	await _look_at(main, mprop.global_position + Vector3(0, 1.5, 0), mprop.global_position + Vector3(7.0, 3.0, 7.0), 14.0)
	main.set("time_scale", mtotal / 3600.0 / 24.0)
	var mmid := await _until(tree, 20.0, func() -> bool:
		var it := sgv.model.get_item(miid) as Dictionary
		return float((it.get("specs", {}) as Dictionary).get("job_progress", 0.0)) >= 0.5)
	await _settle(tree, 12)
	mds = mrt.debug_state()
	var mit2 := sgv.model.get_item(miid) as Dictionary
	var mprog := float((mit2.get("specs", {}) as Dictionary).get("job_progress", 0.0))
	var mpl := PrintJobPlayer.new()
	mpl.load(str(mds["job_id"]), mspecs)
	var msmp := mpl.sample(mprog)
	var mpos: Vector3 = msmp["pos"]
	var mroads: PrintRoads = mrt.roads()
	var mroad_pt: Vector3 = mroads.global_transform * (Vector3(mpos.x, mpos.z, mpos.y) * 0.001) if mroads != null else Vector3.INF
	var mtip: Vector3 = mrt._tool_tip_world()
	var mgap := mtip.distance_to(mroad_pt)
	print("print-pipeline debug mud: tip %s road %s delta %s pos_mm %s mpl %s centre %s soft %s..%s" % [str(mtip), str(mroad_pt), str(mtip - mroad_pt), str(mpos), str(mds.get("mpl")), str(mds.get("centre_u")), str(mds.get("soft_min")), str(mds.get("soft_max"))])
	print("print-pipeline debug mud axes: %s" % JSON.stringify(mds.get("axes", {})))
	_ok(mmid and mroads != null and int(mds["roads_shown"]) > 0, "mud mid-print: %d of %d roads laid at %.0f %%" % [int(mds["roads_shown"]), int(mds["roads"]), mprog * 100.0])
	_ok(mgap < 0.25, "mud: the nozzle is on the road being laid (%.1f cm off)" % (mgap * 100.0))
	var mzn: Node3D = mrt._axis_nodes.get("z")
	var mzrest: Vector3 = mrt._axis_rest.get("z", Vector3.ZERO)
	_ok(mzn != null and mzn.position.distance_to(mzrest) > 1e-4, "mud: the head has risen off its rest pose")
	await _shot(main, "04_mud_printing")
	var mdone := await _until(tree, 40.0, func() -> bool:
		var it := sgv.model.get_item(miid) as Dictionary
		return bool((it.get("specs", {}) as Dictionary).get("job_completed", false)))
	await _settle(tree, 15)
	_ok(mdone and _printed_count(main) == printed_before + 1, "mud: the finished print is a placed object on the map (%d → %d)" % [printed_before, _printed_count(main)])
	_ok(mrt.roads() == null, "mud: the runtime handed its roads over")
	await _shot(main, "05_mud_done")
	main.set("time_scale", 0.0)

	# ---- Clean up -----------------------------------------------------------
	for pid in [trash, mud]:
		if loader.has_method("delete_prop_by_id"):
			loader.call("delete_prop_by_id", pid)
	await _settle(tree, 5)
	print("print-pipeline RESULT: %s (%d fails)" % ["PASS" if _fails.is_empty() else "FAIL", _fails.size()])
	return {"ok": _fails.is_empty(), "fails": _fails}


func _printed_count(main: Node) -> int:
	var terrain := main.get_node_or_null("Terrain")
	if terrain == null:
		return 0
	var root := terrain.get_node_or_null("PrintedObjects")
	return root.get_child_count() if root != null else 0
