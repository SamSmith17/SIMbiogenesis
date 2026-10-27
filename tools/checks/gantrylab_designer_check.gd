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
	# Mated machines draw every assembly where it sits at the tool's zero, so
	# a node's position IS the jog.
	_ok(car != null and xb != null and absf(car.position.x - 0.1) < 1e-4 and absf(xb.position.z - 0.04) < 1e-4, "carriage at x = 100 mm, beam at y = 40 mm")
	_shot(vp, dir, "kinematics_corexy")
	await _parts_editor(ui, tree, vp, dir)
	await _module_drag(ui, tree, vp, dir)
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
	_ok(beads != null and (mach as GantryLabBuilder).roads_shown() > 0 and (mach as GantryLabBuilder).roads_shown() < beads.multimesh.instance_count, "halfway: some roads laid, not all (%d)" % (mach as GantryLabBuilder).roads_shown())
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
	_ok((mach as GantryLabBuilder).roads_shown() == beads.multimesh.instance_count, "at the end every road is laid")
	_shot(vp, dir, "simulate_end")
	# The roads lie flat, one layer tall: no posts at the corners.
	var flat := true
	for k in mini(beads.multimesh.instance_count, 200):
		var rx := (mach as GantryLabBuilder).road_transform(k)
		if absf(rx.basis.x.normalized().dot(Vector3.UP)) > 0.05 or rx.basis.y.length() > 0.001:
			flat = false
	var cab := beads.multimesh.custom_aabb
	_ok(cab.size.x > 0.019 and cab.size.z > 0.019, "the preview is bounded by the whole print, not its first roads (%s)" % str(cab.size))
	_ok(flat and beads.multimesh.instance_count > 300, "the cube prints as flat roads a layer tall (%d roads)" % beads.multimesh.instance_count)
	# The road being laid ends at the nozzle.
	ui.call("sim_seek", 0.37)
	await _settle(tree, 3)
	var st3: Dictionary = ui.call("sim_state")
	var vis := (mach as GantryLabBuilder).roads_shown()
	var last := (mach as GantryLabBuilder).road_transform(vis - 1)
	var o: Vector3 = (mach as GantryLabBuilder).layout()["bead_origin"]
	var p3: Vector3 = st3["pos"]
	var tip_local := o + Vector3(p3.x, p3.z, p3.y) * 0.001
	var dirv := last.basis.x.normalized()
	var w := last.basis.z.length()
	var road_end_top := last.origin + last.basis.x - dirv * (w * 0.5) + Vector3.UP * (last.basis.y.length() * 0.5)
	_ok(road_end_top.distance_to(tip_local) < 0.0008 or not bool(st3.get("extruding", true)), "the road being laid ends at the nozzle (%.2f mm off)" % (road_end_top.distance_to(tip_local) * 1000.0))
	await _closeup(ui, tree, beads, 0.16, 0.12)
	_shot(vp, dir, "simulate_closeup_37")
	ui.call("sim_seek", 1.0)
	await _closeup(ui, tree, beads, 0.16)
	_shot(vp, dir, "simulate_closeup_end")
	# The Trash Printer's 6 mm flake head: its model on the carriage, 6 mm roads.
	ui.call("load_builtin", "trash_flake_600")
	ui.call("set_tab", 2)
	ui.call("load_sample", "cube")
	await _settle(tree, 6)
	mach = ui.call("machine")
	var model := mach.find_child("Model_*", true, false)
	_ok(model != null or not ResourceLoader.exists("res://Imported Models/Gantry/trash_printer_extruder.glb"), "the flake extruder is drawn from its model")
	ui.call("sim_seek", 0.45)
	await _settle(tree, 6)
	var fb := mach.bead_parent().get_node_or_null("Beads") as MultiMeshInstance3D
	var fw := (mach as GantryLabBuilder).road_transform(0).basis.z.length()
	_ok(fb != null and (mach as GantryLabBuilder).roads_shown() > 0 and absf(fw - 0.00672) < 0.0003, "6 mm flake roads (%.2f mm wide)" % (fw * 1000.0))
	_shot(vp, dir, "simulate_flake")
	await _closeup(ui, tree, fb, 1.3)
	_shot(vp, dir, "simulate_flake_closeup")
	await _closeup(ui, tree, fb, 1.1, 0.12)
	_shot(vp, dir, "simulate_flake_side")
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
	_ok(wb != null and (builder as GantryLabBuilder).roads_shown() > 0, "roads laid on the placed bed (%d)" % (builder as GantryLabBuilder).roads_shown())
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



# ---------------------------------------------------------------------------
# The part editor, with real clicks through the window
# ---------------------------------------------------------------------------

func _screen(ui: Control, local_pt: Vector3) -> Vector2:
	var m: Node3D = ui.call("machine")
	var cam: Camera3D = ui.get("_camera")
	var cont: SubViewportContainer = ui.get("_vp_container")
	var svp: SubViewport = ui.get("_viewport")
	var p := cam.unproject_position(m.global_transform * local_pt)
	return cont.get_global_rect().position + p * (cont.size / Vector2(svp.size))


func _local_of(ui: Control, screen: Vector2) -> Vector2:
	var cont: SubViewportContainer = ui.get("_vp_container")
	return screen - cont.get_global_rect().position


## The first part (of `ids`) that the pointer really picks at its centre.
func _visible_part(ui: Control, ids: Array) -> Dictionary:
	var lay: Dictionary = (ui.call("design") as Dictionary)["layout"]
	var res: Dictionary = lay["assembly"]
	for id in ids:
		if not res["parts"].has(id):
			continue
		var bb := GantryLabAssembly._aabb_of(res["parts"][id]["boxes"])
		var at := _screen(ui, bb.get_center())
		var hit: Dictionary = ui.call("_pick_at", _local_of(ui, at))
		if str(hit.get("id", "")) == str(id):
			return {"id": id, "at": at}
	return {}


func _parts_editor(ui: Control, tree: SceneTree, vp: SubViewport, dir: String) -> void:
	var root := ui.get_viewport()
	ui.call("load_builtin", "i3_220")
	ui.call("set_tab", 0)
	await _settle(tree, 8)
	var parts: RefCounted = ui.get("_parts")
	var lay: Dictionary = (ui.call("design") as Dictionary)["layout"]
	_ok(lay.has("assembly") and (lay["assembly"]["fasteners"] as Array).size() > 100, "the bed-slinger is a mated assembly with its fasteners")
	# Click a mirrored slot part.
	var pick := _visible_part(ui, ["zmount.L", "zmount.R", "ymount", "ucorner.LF", "ucorner.RF", "corner.FL1", "corner.FR1", "xidler", "yplate.L"])
	_ok(not pick.is_empty(), "a slot-mounted part is under the pointer")
	if pick.is_empty():
		return
	var id := str(pick["id"])
	await HarnessInput.click(root, pick["at"])
	await _settle(tree, 4)
	var first_mod := str(parts.get("sel_mod"))
	_ok(not first_mod.is_empty(), "a click picks the module %s is in (%s)" % [id, first_mod])
	# Double-clicks open the module (and its sub-module) down to the part.
	for _i in 3:
		if str(parts.get("sel")) == id:
			break
		await HarnessInput.click(root, pick["at"], true)
		await _settle(tree, 4)
	_ok(str(parts.get("sel")) == id, "double-clicks open down to %s" % id)
	_shot(vp, dir, "parts_selected")
	var res0: Dictionary = (ui.call("design") as Dictionary)["layout"]["assembly"]
	var p0: Dictionary = res0["parts"][id]["part"]
	var twin := str(p0.get("twin", ""))
	var w0: Transform3D = res0["parts"][id]["world"]
	var tw0: Transform3D = res0["parts"][twin]["world"] if not twin.is_empty() else Transform3D.IDENTITY
	# Drag it along its slot: the screen direction of the slot's +x.
	var to := str(p0["mate"]["to"])
	var tf := GantryLabAssembly.feature_of(res0["parts"][to]["part"], str(p0["mate"]["tf"]))
	var fx: Transform3D = (res0["parts"][to]["world"] as Transform3D) * (tf["xf"] as Transform3D)
	var a: Vector2 = pick["at"]
	var b := _screen(ui, w0.origin + fx.basis.x.normalized() * 0.03)
	var dir2 := (b - _screen(ui, w0.origin)).normalized()
	await HarnessInput.drag(root, a, a + dir2 * 30.0, 10)
	await _settle(tree, 12)
	var res1: Dictionary = (ui.call("design") as Dictionary)["layout"]["assembly"]
	var w1: Transform3D = res1["parts"][id]["world"]
	var moved := w1.origin - w0.origin
	_ok(moved.length() > 0.002 and absf(moved.normalized().dot(fx.basis.x.normalized())) > 0.99, "a drag slides %s along its slot (%.1f mm)" % [id, moved.length() * 1000.0])
	if not twin.is_empty():
		var tmoved: Vector3 = (res1["parts"][twin]["world"] as Transform3D).origin - tw0.origin
		_ok(absf(tmoved.x + moved.x) < 0.0008 and absf(tmoved.y - moved.y) < 0.0008 and absf(tmoved.z - moved.z) < 0.0008, "its twin %s follows in mirror" % twin)
	var fz: Dictionary = GantryLabAssembly.fasteners_of(res1, id)
	_ok(not fz.is_empty(), "it is still bolted (%s)" % str(fz))
	_shot(vp, dir, "parts_dragged")
	await HarnessInput.key(root, KEY_Z, true)
	await _settle(tree, 10)
	var res2: Dictionary = (ui.call("design") as Dictionary)["layout"]["assembly"]
	_ok((res2["parts"][id]["world"] as Transform3D).origin.distance_to(w0.origin) < 1e-5, "Ctrl+Z puts it back")
	# The palette: a NEMA 17 L mount onto a slot, a motor onto it.
	var tnuts_before := _count_label(res2, "M5 drop-in T-nut")
	var btn := HarnessInput.find_button(ui, "NEMA17 L")
	_ok(btn != null, "the palette has a NEMA 17 L mount")
	if btn == null:
		return
	await _reveal(btn, tree)
	await HarnessInput.click(root, HarnessInput.center_of(btn))
	_ok(str(parts.get("tool_ref")) == "nema17_mount", "a click on the palette arms the L mount")
	await _settle(tree, 2)
	var spot := _visible_face(ui, res2, "cross.F")
	var placed := ""
	if not spot.is_empty():
		await HarnessInput.mouse_move(root, spot["at"])
		await _settle(tree, 2)
		await HarnessInput.click(root, spot["at"])
		await _settle(tree, 10)
		placed = str(parts.get("sel"))
	var res3: Dictionary = (ui.call("design") as Dictionary)["layout"]["assembly"]
	_ok(placed.begins_with("u") and res3["parts"].has(placed) and str(res3["parts"][placed]["part"]["mate"]["to"]) == "cross.F", "a click puts the L mount on the front cross beam's slot")
	_ok(_count_label(res3, "M5 drop-in T-nut") >= tnuts_before + 2, "its two T-nuts and bolts are made (%d → %d T-nuts)" % [tnuts_before, _count_label(res3, "M5 drop-in T-nut")])
	_shot(vp, dir, "parts_mount_placed")
	if res3["parts"].has(placed):
		var mb := HarnessInput.find_button(ui, "NEMA17")
		if mb != null:
			await _reveal(mb, tree)
			await HarnessInput.click(root, HarnessInput.center_of(mb))
			var mf := GantryLabAssembly.feature_of(res3["parts"][placed]["part"], "motor")
			if mf.is_empty():
				return
			var mat := _screen(ui, (res3["parts"][placed]["world"] as Transform3D) * (mf["xf"] as Transform3D).origin)
			await HarnessInput.mouse_move(root, mat)
			await _settle(tree, 2)
			await HarnessInput.click(root, mat)
			await _settle(tree, 10)
			var res4: Dictionary = (ui.call("design") as Dictionary)["layout"]["assembly"]
			var mot := str(parts.get("sel"))
			_ok(res4["parts"].has(mot) and str(res4["parts"][mot]["part"]["mate"]["to"]) == placed and _count_label(res4, "M3×6 cap screw") >= _count_label(res3, "M3×6 cap screw") + 4,
				"a NEMA 17 snaps onto the mount's 31 mm hole square with four M3 bolts")
			_shot(vp, dir, "parts_motor_placed")
	# Unlink a twin from the card.
	if not twin.is_empty():
		parts.set("sel", id)
		parts.call("_unlink")
		await _settle(tree, 10)
		var sp: Dictionary = ui.call("spec")
		_ok((GantryLabAssembly.edits_of(sp)["unlinked"] as Array).has(id), "Unlink breaks the pair")
	parts.call("_on_reset")
	await _settle(tree, 10)
	_ok(not GantryLabAssembly.has_edits(ui.call("spec")), "Reset parts forgets every edit")


func _count_label(res: Dictionary, label: String) -> int:
	var n := 0
	for f in res["fasteners"]:
		if str((f as Dictionary).get("label", "")) == label:
			n += 1
	return n


## A visible point on a beam's upward / sideways face (where a bracket can land).
func _visible_face(ui: Control, res: Dictionary, beam: String) -> Dictionary:
	if not res["parts"].has(beam):
		return {}
	var w: Transform3D = res["parts"][beam]["world"]
	var p: Dictionary = res["parts"][beam]["part"]
	var L := float((p.get("params", {}) as Dictionary).get("len", 0.3))
	for fid in ["+y", "-z", "+z"]:
		var f := GantryLabAssembly.feature_of(p, fid)
		var fx: Transform3D = w * (f["xf"] as Transform3D)
		if fx.basis.y.normalized().dot(Vector3.DOWN) > 0.5:
			continue
		for t in [0.3, 0.5, 0.7]:
			var pt := fx * Vector3(L * float(t), 0.0005, 0)
			var at := _screen(ui, pt)
			var hit: Dictionary = ui.call("_pick_at", _local_of(ui, at))
			if str(hit.get("id", "")) == beam:
				return {"at": at, "face": fid}
	return {}


func _reveal(c: Control, tree: SceneTree) -> void:
	var n: Node = c.get_parent()
	while n != null and not (n is ScrollContainer):
		n = n.get_parent()
	if n != null:
		(n as ScrollContainer).ensure_control_visible(c)
	await _settle(tree, 3)


## A module moves as one: on the X5S the left Z axis (motor, coupler, screw,
## nut, shafts, bearings, carriage) is dragged along its base beam with REAL
## input, the right one follows in mirror, nothing comes off its mate.
func _module_drag(ui: Control, tree: SceneTree, vp: SubViewport, dir: String) -> void:
	var root := ui.get_viewport()
	ui.call("load_builtin", "tronxy_x5s")
	ui.call("set_tab", 0)
	await _settle(tree, 8)
	var parts: RefCounted = ui.get("_parts")
	_shot(vp, dir, "x5s")
	var res0: Dictionary = (ui.call("design") as Dictionary)["layout"]["assembly"]
	var pick := _visible_part(ui, ["zmotor.L", "zmount.L", "zcoupler.L", "zmotor.R", "zmount.R", "zcoupler.R", "skbF.L", "skbB.L", "skbF.R", "skbB.R"])
	_ok(not pick.is_empty(), "a Z axis part is under the pointer")
	if pick.is_empty():
		return
	var id := str(pick["id"])
	var side := id.substr(id.length() - 1)
	await HarnessInput.click(root, pick["at"])
	await _settle(tree, 4)
	var mid := str(parts.get("sel_mod"))
	_ok(mid == "zaxis." + side, "a click on the %s picks the whole Z axis (%s)" % [id, mid])
	_shot(vp, dir, "x5s_zaxis_selected")
	var mot: Vector3 = res0["parts"]["zmotor." + side]["world"].origin
	var a := _screen(ui, mot)
	var b := _screen(ui, mot + Vector3(0, 0, 0.04))
	var dir2 := (b - a).normalized()
	await HarnessInput.drag(root, pick["at"], pick["at"] + dir2 * 40.0, 12)
	await _settle(tree, 12)
	var res1: Dictionary = (ui.call("design") as Dictionary)["layout"]["assembly"]
	var dz := (res1["parts"]["zmotor." + side]["world"].origin as Vector3) - mot
	_ok(dz.length() > 0.003 and absf(dz.x) < 1e-4 and absf(dz.y) < 1e-4, "the drag moves the Z axis along its beam (%.1f mm)" % (dz.length() * 1000.0))
	var together := true
	for pid in ["zcoupler.", "zscrew.", "znut.", "rodF.", "rodB.", "zcar.", "brg0.", "sktF."]:
		var d0: Vector3 = (res1["parts"][pid + side]["world"].origin as Vector3) - (res0["parts"][pid + side]["world"].origin as Vector3)
		if d0.distance_to(dz) > 0.0015:
			together = false
			print("  %s%s moved %s, motor %s" % [pid, side, str(d0), str(dz)])
	_ok(together, "coupler, screw, nut, shafts, bearings and plate move with the motor")
	var other := "R" if side == "L" else "L"
	var dzo := (res1["parts"]["zmotor." + other]["world"].origin as Vector3) - (res0["parts"]["zmotor." + other]["world"].origin as Vector3)
	_ok(dzo.distance_to(Vector3(-dz.x, dz.y, dz.z)) < 0.0015, "the other Z axis follows in mirror")
	var errs := 0
	for i in res1["issues"]:
		if str(i["level"]) == "error":
			errs += 1
	_ok(errs == 0, "nothing came off its mate (%d errors)" % errs)
	_shot(vp, dir, "x5s_zaxis_moved")
	# Opening it: the drive is a sub-module.
	await HarnessInput.click(root, pick["at"] + dir2 * 40.0, true)
	await _settle(tree, 4)
	_ok(str(parts.get("ctx")) == "zaxis." + side, "a double-click opens the Z axis")
	await HarnessInput.key(root, KEY_ESCAPE)
	await _settle(tree, 2)
	await HarnessInput.key(root, KEY_ESCAPE)
	await _settle(tree, 2)
	_ok(str(parts.get("ctx")).is_empty(), "Esc steps back out")
	await HarnessInput.key(root, KEY_Z, true)
	await _settle(tree, 10)


## Aim the studio camera at the print.
func _closeup(ui: Control, tree: SceneTree, beads: MultiMeshInstance3D, dist: float, pitch: float = 0.45) -> void:
	await _settle(tree, 2)
	if beads == null:
		return
	var c: Vector3 = (ui.call("machine") as GantryLabBuilder).print_centre_global()
	ui.set("_target", c)
	ui.set("_dist", dist)
	ui.set("_pitch", pitch)
	ui.set("_yaw", 0.7)
	ui.call("_update_camera")
	await _settle(tree, 6)
