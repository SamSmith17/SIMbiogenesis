extends RefCounted
## The CNC gantry designer on a REAL world (sandbox; writes nothing to the
## player's world):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/gantrylab_designer_check.gd -Label gantrylab
## Opens the designer through the loader, loads every built-in design (no
## error-level check, a machine drawn, a PNG each), jogs the tool and reads
## the motor readouts (CoreXY A = X + Y pinned on the live modal), plays the
## sample program through the planner (the tool moves, beads appear, the
## scrub reaches the end), UiAudit on the open modal, the export round trip,
## then places a CoreXY in the world: the record carries the spec, a
## GantryLabBuilder with the three drivers exists, a cartesian_machine graph
## node is bound, a job sent from the lab runs it (the drivers move in true
## mm, beads land on the bed), packed → bundle, "Edit gantry…" rebinds,
## Apply re-syncs the graph node's watts. Deletes what it placed.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("gantrylab %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func _shot(vp: SubViewport, dir: String, name: String) -> void:
	var img := vp.get_texture().get_image()
	if img != null:
		img.save_png("%s/%s.png" % [dir, name])


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var dir := "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	_ok(loader != null and loader.has_method("open_gantrylab"), "the loader has the designer")
	if loader == null:
		return {"ok": false, "fails": _fails}
	loader.call("open_gantrylab")
	await _settle(tree, 20)
	var ui: Control = loader.call("gantrylab_designer")
	_ok(ui != null and ui.visible and bool(ui.call("is_open")), "the designer opened")
	if ui == null:
		return {"ok": false, "fails": _fails}
	var vp: SubViewport = ui.get("_viewport")
	for p in GantryLabPresets.builtins():
		ui.call("load_builtin", str(p["id"]))
		await _settle(tree, 6)
		var d: Dictionary = ui.call("design")
		var errors := 0
		for c in d["checks"]:
			if str(c["level"]) == "error":
				errors += 1
		var m: GantryLabBuilder = ui.call("machine")
		var mesh := m.get_node_or_null("Mesh") as MeshInstance3D if m != null else null
		_ok(errors == 0 and mesh != null and mesh.mesh != null and mesh.mesh.get_surface_count() >= 2, "preset %s: clean checks, machine drawn" % str(p["id"]))
		_shot(vp, dir, "preset_%s" % str(p["id"]))
	# Kinematics: CoreXY A = X + Y on the live modal.
	ui.call("load_builtin", "corexy_300")
	ui.call("set_tab", 1)
	ui.call("jog", Vector3(100.0, 40.0, 20.0))
	await _settle(tree, 4)
	var mp := GantryLabKinematics.motor_positions(ui.call("spec"), Vector3(100.0, 40.0, 20.0))
	_ok(absf(float(mp[0]["mm"]) - 140.0) < 1e-6 and absf(float(mp[1]["mm"]) - 60.0) < 1e-6, "jog 100/40: A = 140, B = 60")
	var mach: GantryLabBuilder = ui.call("machine")
	var car := mach.get_node_or_null("XBeam/XCarriage") as Node3D
	var xb := mach.get_node_or_null("XBeam") as Node3D
	_ok(car != null and xb != null and absf(car.position.x - ((mach.layout()["origin"] as Vector3).x + 0.1)) < 1e-4 and absf(xb.position.z - (-0.15 + 0.04)) < 1e-4, "carriage at x = 100 mm, beam at y = 40 mm")
	_shot(vp, dir, "kinematics_corexy")
	# Delta: carriages differ, effector where asked.
	ui.call("load_builtin", "kossel_mini")
	ui.call("jog", Vector3(30.0, 0.0, 50.0))
	await _settle(tree, 4)
	mach = ui.call("machine")
	var eff := mach.get_node_or_null("Effector") as Node3D
	var ca := mach.get_node_or_null("CarriageA") as Node3D
	var cb := mach.get_node_or_null("CarriageB") as Node3D
	_ok(eff != null and absf(eff.position.x - 0.03) < 1e-4 and absf(eff.position.y - (mach.layout()["anchors"]["bed_top"] as float) - 0.05) < 1e-4, "delta effector at (30, 0, 50)")
	_ok(ca != null and cb != null and absf(ca.position.y - cb.position.y) > 0.001, "delta carriages at different heights off-centre")
	_shot(vp, dir, "kinematics_delta")
	# Simulate: the sample plays, the tool moves, the beads appear.
	ui.call("load_builtin", "i3_220")
	ui.call("set_tab", 2)
	ui.call("load_sample", "cube")
	await _settle(tree, 4)
	var st0: Dictionary = ui.call("sim_state")
	_ok(not st0.is_empty() and float(st0["total_s"]) > 60.0 and int(st0["moves"]) > 100, "cube program planned: %s s, %d moves" % [str(st0.get("total_s", 0)), int(st0.get("moves", 0))])
	ui.call("sim_seek", 0.5)
	await _settle(tree, 3)
	var st1: Dictionary = ui.call("sim_state")
	mach = ui.call("machine")
	var beads := mach.bead_parent().get_node_or_null("Beads") as MultiMeshInstance3D
	_ok(beads != null and beads.multimesh.visible_instance_count > 0 and beads.multimesh.visible_instance_count < beads.multimesh.instance_count, "halfway: some beads laid, not all (%s)" % str(beads.multimesh.visible_instance_count if beads != null else -1))
	var tool_pos: Vector3 = st1["pos"]
	_ok(tool_pos.z > 1.0 and tool_pos.z < 20.0, "tool mid-print at z = %.1f mm" % tool_pos.z)
	_shot(vp, dir, "simulate_half")
	ui.call("sim_play", true)
	await _settle(tree, 30)
	var st2: Dictionary = ui.call("sim_state")
	_ok(float(st2["t"]) > float(st1["t"]), "playing advances time")
	ui.call("sim_play", false)
	ui.call("sim_seek", 1.0)
	await _settle(tree, 3)
	_ok(beads.multimesh.visible_instance_count == beads.multimesh.instance_count, "at the end every bead is laid")
	_shot(vp, dir, "simulate_end")
	# Config tab + audit.
	ui.call("set_tab", 3)
	await _settle(tree, 3)
	ui.call("set_tab", 0)
	await _settle(tree, 3)
	var audit: Dictionary = UiAudit.run(main.get_viewport())
	print("gantrylab: ui audit — %s" % UiAudit.summary_line(audit))
	_ok(int(audit.get("errors", 0)) == 0, "the open modal has no UI audit errors")
	# Export round trip.
	var out_dir := "user://gantrylab_check_export"
	ui.call("_write_files", out_dir)
	var files := DirAccess.get_files_at(out_dir)
	_ok(files.size() == 6, "six design files written")
	for f in files:
		DirAccess.remove_absolute(out_dir.path_join(f))
	DirAccess.remove_absolute(out_dir)
	ui.call("close")
	await _settle(tree, 3)
	_ok(not ui.visible, "closed")
	# Place a CoreXY in the world.
	var spec: Dictionary = GantryLabPresets.builtin("corexy_300")["spec"]
	var player := main.get_node_or_null("Player") as Node3D
	var at := player.global_position + Vector3(3, 0, 3) if player != null else Vector3(3, 0, 3)
	var pid: String = PlacedPropService.place_prepped_at(main, GantryLabBuilder.MODEL_ID,
		{"record_extra": {"gantry_spec": GantryLabSpec.to_json_safe(spec), "kind": "gantry_machine", "collision_enabled": true}}, at.x, at.z, 0.0)
	await _settle(tree, 10)
	var rec := PlacedPropService.get_prop_record(main, pid)
	_ok(not pid.is_empty() and rec.get("gantry_spec") is Dictionary and str(rec.get("kind", "")) == "gantry_machine", "placed: record carries the spec and the gantry kind")
	var prop := PlacedPropService._find_prop_node(main, pid)
	var builder: Node = null
	if prop != null:
		for n in prop.find_children("*", "GantryLabBuilder", true, false):
			builder = n
			break
	_ok(builder != null and builder.get_node_or_null("XDrive") != null and builder.get_node_or_null("ZDrive") != null, "a GantryLabBuilder with drivers stands in the world")
	_ok(prop != null and prop.get_node_or_null("GantryRuntime") != null and prop.get_node_or_null("CncMachineRuntime") == null, "the gantry runtime attached, the GLB runtime did not")
	_ok(prop != null and prop.get_node_or_null("PropBody") != null, "collision body")
	var iid := str(PlacedPropService.get_prop_record(main, pid).get("graph_item_id", ""))
	var sgv := ServiceLocator.graph()
	var item: Dictionary = sgv.model.get_item(iid) if sgv != null and not iid.is_empty() else {}
	_ok(not item.is_empty() and str(item["specs"]["role"]) == "cartesian_machine" and str(item["specs"]["model_id"]) == "gantry_machine", "bound to a cartesian_machine graph node")
	# Send a job from the lab and watch it run.
	loader.call("open_gantrylab_for_prop", pid)
	await _settle(tree, 20)
	_ok(ui.visible and bool((ui.get("_apply_btn") as Button).visible), "reopened bound to the placed machine")
	ui.call("set_tab", 2)
	ui.call("load_sample", "cube")
	await _settle(tree, 4)
	ui.call("_on_send_job")
	await _settle(tree, 5)
	item = sgv.model.get_item(iid)
	_ok(bool(item["specs"]["job_active"]) and float(item["specs"]["job_duration_hr"]) > 0.01, "job scheduled on the graph: %.2f h" % float(item["specs"].get("job_duration_hr", 0.0)))
	var ts_before: float = float(main.get("time_scale"))
	# 0.004 sim-h per real second: ~1 % of a cube print in the 90 frames.
	main.set("time_scale", 0.004)
	await _settle(tree, 90)
	main.set("time_scale", ts_before)
	var rt := prop.get_node_or_null("GantryRuntime")
	var ds: Dictionary = rt.call("debug_state") if rt != null else {}
	var zd := builder.get_node_or_null("ZDrive") as Node3D
	var xd := builder.get_node_or_null("XDrive") as Node3D
	_ok(not ds.is_empty() and int(ds["points"]) > 10, "runtime loaded the job: %d points" % int(ds.get("points", 0)))
	var job_prog := float(sgv.model.get_item(iid)["specs"].get("job_progress", 0.0))
	_ok(zd != null and zd.position.y > 0.0001 and zd.position.y < 0.012 and xd.position.x > 0.0, "drivers moved in true mm: x %.1f mm, z %.1f mm at %.1f %% of the job" % [xd.position.x * 1000.0, zd.position.y * 1000.0, job_prog * 100.0])
	var wb := (builder as GantryLabBuilder).bead_parent().get_node_or_null("Beads") as MultiMeshInstance3D
	_ok(wb != null and wb.multimesh.visible_instance_count > 0, "beads laid on the placed bed (%d)" % (wb.multimesh.visible_instance_count if wb != null else -1))
	if prop != null and main.has_method("push_camera_claim"):
		# The player camera re-aims every frame: shoot through a claimed one.
		var size: Vector3 = builder.get_meta("size_m")
		var reach := maxf(maxf(size.x, size.z), size.y) * 2.2 + 0.5
		main.set("day_time", 14.0)
		var cam := Camera3D.new()
		cam.name = "GantryCheckCam"
		main.add_child(cam)
		cam.global_position = (prop as Node3D).global_position + Vector3(reach * 0.7, size.y * 0.9 + 0.4, reach * 0.7)
		cam.look_at((prop as Node3D).global_position + Vector3(0, size.y * 0.4, 0), Vector3.UP)
		main.call("push_camera_claim", "gantry_check", {"camera_id": cam.get_instance_id()})
		await _settle(tree, 8)
		var img := main.get_viewport().get_texture().get_image()
		if img != null:
			img.save_png("%s/world_job.png" % dir)
		main.call("pop_camera_claim", "gantry_check")
		cam.queue_free()
	# Packing.
	loader.call("set_prop_packed", pid, true)
	await _settle(tree, 5)
	var ps := PlacedPropRuntime.packed_spec_for_record(PlacedPropService.get_prop_record(main, pid))
	_ok(str(ps.get("form", "")) == "bundle" and str(ps.get("source", "")) == "computed", "packed → extrusion bundle (computed)")
	loader.call("set_prop_packed", pid, false)
	await _settle(tree, 5)
	# Apply re-syncs the graph node.
	var sp2: Dictionary = (ui.call("spec") as Dictionary).duplicate(true)
	sp2["tool"]["id"] = "router_1250w"
	sp2["tool"]["bed"] = "spoilboard"
	ui.set("_spec", sp2)
	ui.call("_rebuild_now")
	ui.call("_on_apply")
	await _settle(tree, 10)
	item = sgv.model.get_item(iid)
	var rec2 := PlacedPropService.get_prop_record(main, pid)
	_ok(str((rec2.get("gantry_spec", {}) as Dictionary).get("tool", {}).get("id", "")) == "router_1250w" and str(item["specs"]["machine_role"]) == "cnc_router" and float(item["specs"]["watts"]) > 1200.0, "Apply: record and graph node follow the new tool")
	if loader.has_method("delete_prop_by_id"):
		loader.call("delete_prop_by_id", pid)
	await _settle(tree, 5)
	return {"ok": _fails.is_empty(), "fails": _fails}
