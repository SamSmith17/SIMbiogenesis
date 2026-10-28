extends RefCounted
## The print setup's frames and scale on a REAL world (sandbox):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/print_scale_frame_check.gd -Label print_frames -Timeout 900
## Places a Trash Printer (a GLB machine) and a designed flake gantry (the
## parametric one) side by side and slices the SAME asymmetric model (an L,
## turned 37°) on each, then asserts what a screenshot cannot:
##   - in the studio every road the slicer laid lies inside the model ghost
##     (the ghost used to be a mirror image of the print, turning the other way);
##   - the print is the same size on both machines, at true scale in the
##     world (a road the job says is 120 mm long is 120 mm in the world);
##   - the world work frame is right-handed on both (X × Y = up: a print is
##     not a mirror image of its model);
##   - the size row: typing a width sets the scale; the scale reaches past 4×.
## Shots under screenshots\print_frames\. Deletes what it placed.

var _fails: Array = []
const SHOT_DIR := "user://screenshots/print_frames"
const STL_PATH := "user://print_frames_L.stl"
## The L in file mm: two rectangles, 20 mm tall.
const RECTS := [Rect2(0, 0, 120, 30), Rect2(0, 30, 30, 70)]


func _ok(cond: bool, what: String) -> void:
	print("print-frames %s: %s" % ["PASS" if cond else "FAIL", what])
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
	print("print-frames shot: %s" % name)


static func _box(size: Vector3, origin: Vector3) -> Array:
	var v := []
	for z in [0.0, size.z]:
		for y in [0.0, size.y]:
			for x in [0.0, size.x]:
				v.append(origin + Vector3(x, y, z))
	var f := [[0, 2, 3, 1], [4, 5, 7, 6], [0, 1, 5, 4], [2, 6, 7, 3], [0, 4, 6, 2], [1, 3, 7, 5]]
	var tris := []
	for q in f:
		tris.append([v[q[0]], v[q[1]], v[q[2]]])
		tris.append([v[q[0]], v[q[2]], v[q[3]]])
	return tris


func _write_l_stl() -> void:
	var tris: Array = []
	for r in RECTS:
		var rr: Rect2 = r
		tris += _box(Vector3(rr.size.x, rr.size.y, 20.0), Vector3(rr.position.x, rr.position.y, 0.0))
	var f := FileAccess.open(STL_PATH, FileAccess.WRITE)
	f.store_line("solid L")
	for t in tris:
		var a: Vector3 = t[0]
		var b: Vector3 = t[1]
		var c: Vector3 = t[2]
		var n := (b - a).cross(c - a).normalized()
		f.store_line("facet normal %f %f %f" % [n.x, n.y, n.z])
		f.store_line("outer loop")
		for p in [a, b, c]:
			f.store_line("vertex %f %f %f" % [p.x, p.y, p.z])
		f.store_line("endloop")
		f.store_line("endfacet")
	f.store_line("endsolid L")
	f.close()


static func _inside_l(x: float, y: float, tol: float) -> bool:
	for r in RECTS:
		var rr: Rect2 = r
		if x >= rr.position.x - tol and x <= rr.end.x + tol and y >= rr.position.y - tol and y <= rr.end.y + tol:
			return true
	return false


## Every extruding move end, mapped into the studio the way the roads are,
## then back through the model ghost into the file's own mm: inside the L?
func _studio_alignment(modal: Control, label: String) -> void:
	var st: Dictionary = modal.call("studio_state")
	var ghost: MeshInstance3D = st["ghost"]
	var roads: PrintRoads = st["roads"]
	var wxf: Transform3D = st["work_xf"]
	_ok(ghost != null and roads != null, "%s studio: ghost and roads drawn" % label)
	if ghost == null or roads == null:
		return
	_ok(roads.transform.is_equal_approx(wxf), "%s studio: the roads sit in the studio's work frame" % label)
	var job: Dictionary = modal.call("job")
	var pm := PrintMoves.from_any(job["moves"])
	var inv := ghost.transform.affine_inverse()
	var inside := 0
	var tot := 0
	var worst := 0.0
	for i in range(0, pm.size(), maxi(pm.size() / 4000, 1)):
		if pm.e[i] <= 0.0:
			continue
		var p: Vector3 = pm.p1[i]
		var studio := wxf * (Vector3(p.x, p.z, p.y) * 0.001)
		var m := inv * studio
		# build_mesh: (x − cx, z − base, −(y − cy)) · 0.001, cx, cy = the L's box centre (60, 50).
		var fx := m.x * 1000.0 + 60.0
		var fy := -m.z * 1000.0 + 50.0
		tot += 1
		if _inside_l(fx, fy, 0.6):
			inside += 1
		else:
			worst = maxf(worst, minf(absf(fx - clampf(fx, 0, 120)) + absf(fy - clampf(fy, 0, 100)), 1e6))
	_ok(tot > 50 and inside == tot, "%s studio: every road lies inside the model ghost (%d of %d; worst %.1f mm out)" % [label, inside, tot, worst])


func _world_frame(roads: PrintRoads, job: Dictionary, label: String) -> void:
	if roads == null:
		_ok(false, "%s world: no roads on the machine" % label)
		return
	var g := roads.global_transform
	var wx := g.basis * Vector3(1, 0, 0)
	var wy := g.basis * Vector3(0, 0, 1)
	var wz := g.basis * Vector3(0, 1, 0)
	_ok(wx.cross(wy).dot(wz) > 0.0, "%s world: the work frame is right-handed (X × Y = up)" % label)
	_ok(absf(wx.length() - 1.0) < 1e-3 and absf(wy.length() - 1.0) < 1e-3 and absf(wz.length() - 1.0) < 1e-3,
		"%s world: true scale (%.4f %.4f %.4f m per local m)" % [label, wx.length(), wy.length(), wz.length()])
	var b := roads.bounds_local()
	var jsz: Vector3 = (job["bounds_max"] as Vector3) - (job["bounds_min"] as Vector3)
	# bounds pad each side by (w + h); the job's are the road centrelines.
	var pad := (float(job["line_width_mm"]) + float(job["layer_height_mm"]))
	var wsz := Vector3(b.size.x, b.size.z, b.size.y) * 1000.0 - Vector3(pad, pad, pad) * 2.0
	print("print-frames debug %s: job %s mm, world roads %s mm" % [label, str(jsz), str(wsz)])
	_ok(absf(wsz.x - jsz.x) < 1.0 and absf(wsz.y - jsz.y) < 1.0, "%s world: the print is its job's size (%.1f × %.1f vs %.1f × %.1f mm)" % [label, wsz.x, wsz.y, jsz.x, jsz.y])


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	await _settle(tree, 20)
	var sgv := ServiceLocator.graph()
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	_ok(sgv != null and loader != null, "graph view + loader")
	if sgv == null or loader == null:
		return {"ok": false, "fails": _fails}
	main.set("time_scale", 0.0)
	var now := float(main.call("get_absolute_hours"))
	main.call("set_absolute_hours", floor(now / 24.0) * 24.0 + 10.0)
	_write_l_stl()
	var player := main.find_child("Player", true, false) as Node3D
	var px := player.global_position.x if player != null else 0.0
	var pz := player.global_position.z if player != null else 0.0

	var trash := str(PlacedPropService.place_model_at_xz(main, "trash_printer", px + 5.0, pz + 2.0, {
		"kind": "cartesian_machine", "machine_profile": CartesianMachineProfile.get_profile("trash_printer").to_dict()}).get("prop_id", ""))
	var spec: Dictionary = GantryLabPresets.builtin("trash_flake_600")["spec"]
	var gantry: String = PlacedPropService.place_prepped_at(main, GantryLabBuilder.MODEL_ID,
		{"record_extra": {"gantry_spec": GantryLabSpec.to_json_safe(spec), "kind": "gantry_machine", "collision_enabled": true}}, px - 5.0, pz + 2.0, 0.0)
	await _settle(tree, 40)
	_ok(not trash.is_empty() and not gantry.is_empty(), "a Trash Printer and a flake gantry placed")
	var tprop := PlacedPropRuntime.find_by_prop_id(main, trash)
	var gprop := PlacedPropRuntime.find_by_prop_id(main, gantry)
	var trt: CncMachineRuntime = tprop.get_node_or_null("CncMachineRuntime") if tprop != null else null
	var grt: GantryRuntime = gprop.get_node_or_null("GantryRuntime") if gprop != null else null
	_ok(trt != null and grt != null, "both runtimes attached")
	if trt == null or grt == null:
		return {"ok": false, "fails": _fails}
	var jobs := {}
	for which in ["trash", "gantry"]:
		var pid := trash if which == "trash" else gantry
		var opened := bool(sgv.call("open_print_setup_for_prop", pid))
		await _settle(tree, 10)
		var modal: Control = sgv.get("_print_setup_modal")
		_ok(opened and modal != null and modal.visible, "%s: print setup opened" % which)
		if modal == null:
			continue
		modal.call("load_stl", STL_PATH)
		modal.call("set_slicer", {"scale": 1.0, "rotation_deg": 37.0, "infill_pct": 15.0})
		await _settle(tree, 4)
		var job: Dictionary = modal.call("job")
		_ok(bool(job.get("ok", false)), "%s: the L sliced (%s, %s)" % [which, UiText.count(int(job.get("layers", 0)), "layer"), UiText.count(PrintMoves.count(job.get("moves", [])), "move")])
		jobs[which] = job
		_studio_alignment(modal, which)
		# The scale reaches past 4×, and typing a width sets it.
		var st: Dictionary = modal.call("studio_state")
		_ok(float(st["scale_max"]) >= 100.0, "%s: the scale slider reaches %.0f×" % [which, float(st["scale_max"])])
		modal.call("set_slicer", {"width_mm": 240.0})
		st = modal.call("studio_state")
		_ok(absf(float(st["scale"]) - 2.0) < 1e-3 and absf((st["size"] as Vector3).x - 240.0) < 0.01, "%s: a 240 mm width sets scale 2 (%.3f, size %s)" % [which, float(st["scale"]), str(st["size"])])
		var j2: Dictionary = modal.call("job")
		var p2: Dictionary = st["parse"]
		var msz := (p2["model_max"] as Vector3) - (p2["model_min"] as Vector3)
		_ok(absf(msz.z - 40.0) < 0.01, "%s: the scaled model is 40 mm tall (%.2f)" % [which, msz.z])
		_studio_alignment(modal, which + " ×2")
		await _shot(main, "%s_studio" % which)
		modal.call("set_slicer", {"scale": 1.0})
		await _settle(tree, 4)
		jobs[which] = modal.call("job")
		# The machine's own preview of the job (its world roads).
		await _settle(tree, 6)
		var wroads: PrintRoads = trt.get("_ghost") if which == "trash" else (gprop.find_children("*", "GantryLabBuilder", true, false)[0] as GantryLabBuilder).roads()
		_world_frame(wroads, jobs[which], which)
		# A bed-wide print previewed on the real machine, shot close.
		modal.call("set_slicer", {"width_mm": 560.0, "rotation_deg": 0.0})
		await _settle(tree, 6)
		var prop := tprop if which == "trash" else gprop
		wroads = trt.get("_ghost") if which == "trash" else (gprop.find_children("*", "GantryLabBuilder", true, false)[0] as GantryLabBuilder).roads()
		if wroads != null:
			var c := wroads.global_transform * wroads.bounds_local().get_center()
			var cam := Camera3D.new()
			main.add_child(cam)
			main.call("push_camera_claim", "print_frames", {"camera_id": cam.get_instance_id()})
			var away := (c - prop.global_position)
			away.y = 0.0
			cam.global_position = c + Vector3(1.3, 1.1, 1.6)
			cam.look_at(c, Vector3.UP)
			modal.visible = false
			await _settle(tree, 4)
			await _shot(main, "%s_world_560" % which)
			modal.visible = true
			main.call("pop_camera_claim", "print_frames")
			cam.queue_free()
		modal.call("close")
		await _settle(tree, 4)
	if jobs.has("trash") and jobs.has("gantry"):
		var a: Dictionary = jobs["trash"]
		var b: Dictionary = jobs["gantry"]
		var sa := (a["bounds_max"] as Vector3) - (a["bounds_min"] as Vector3)
		var sb := (b["bounds_max"] as Vector3) - (b["bounds_min"] as Vector3)
		print("print-frames debug: trash line %.2f layer %.2f, gantry line %.2f layer %.2f" % [float(a["line_width_mm"]), float(a["layer_height_mm"]), float(b["line_width_mm"]), float(b["layer_height_mm"])])
		_ok(absf(sa.x - sb.x) < 1.0 and absf(sa.y - sb.y) < 1.0, "the same model is the same size on both (%.1f × %.1f vs %.1f × %.1f mm)" % [sa.x, sa.y, sb.x, sb.y])
		_ok(absf(float(a["line_width_mm"]) - float(b["line_width_mm"])) < 0.01, "both 6 mm heads slice 6 mm roads (%.2f vs %.2f)" % [float(a["line_width_mm"]), float(b["line_width_mm"])])
	# The physical bed against the work volume (a report, not a gate).
	var ds: Dictionary = trt.debug_state()
	var bed_box: AABB = trt._subtree_aabb(trt._axis_nodes.get("z")) if trt._axis_nodes.has("z") else AABB()
	print("print-frames debug trash bed: work %s mm, bed node box %s m" % [str(ds.get("work")), str(bed_box.size)])
	var mpl: Dictionary = ds.get("mpl", {})
	var smin: Dictionary = ds.get("soft_min", {})
	var smax: Dictionary = ds.get("soft_max", {})
	for k in ["x", "y", "z"]:
		if mpl.has(k):
			print("print-frames debug trash axis %s: soft travel %.0f mm (profile window)" % [k, (float(smax.get(k, 0.0)) - float(smin.get(k, 0.0))) * float(mpl[k]) * 1000.0])
	# Shots of both machines with their previews.
	if player != null:
		var cam := Camera3D.new()
		main.add_child(cam)
		main.call("push_camera_claim", "print_frames", {"camera_id": cam.get_instance_id()})
		cam.global_position = Vector3(px, player.global_position.y + 3.2, pz + 6.5)
		cam.look_at(Vector3(px, player.global_position.y + 0.8, pz + 2.0), Vector3.UP)
		await _shot(main, "machines")
		main.call("pop_camera_claim", "print_frames")
		cam.queue_free()
	for pid in [trash, gantry]:
		if loader.has_method("delete_prop_by_id"):
			loader.call("delete_prop_by_id", pid)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(STL_PATH))
	await _settle(tree, 5)
	print("print-frames RESULT: %s (%d fails)" % ["PASS" if _fails.is_empty() else "FAIL", _fails.size()])
	return {"ok": _fails.is_empty(), "fails": _fails}
