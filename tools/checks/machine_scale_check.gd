extends RefCounted
## Workshop machines at true size (sandbox):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/machine_scale_check.gd -Label machine_scale
## The Trash Printer and the three Precious Plastic machines are authored at
## true size (SimLab inches under a 0.0254 node); height fits in the catalog
## used to scale them ~1.6–1.8× on top. Places each and asserts its world
## height is the file's own, and a part with a real size measures it. Then
## drives the sheet press closed: the lower platen rises by the gap it
## measured, meets the fixed top platen, and the sheet rides on it.
## Shots under screenshots\machine_scale\. Deletes what it placed.

var _fails: Array = []
const SHOT_DIR := "user://screenshots/machine_scale"
## File heights (m) from glb_dump_diag's WHOLE AABB.
const FILE_H := {"trash_printer": 1.115, "pp_shredder": 1.007, "pp_beam_extruder": 1.062, "pp_sheet_press": 1.2375}


func _ok(cond: bool, what: String) -> void:
	print("machine-scale %s: %s" % ["PASS" if cond else "FAIL", what])
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
	print("machine-scale shot: %s" % name)


static func _world_aabb(root: Node3D, visible_only: bool = true) -> AABB:
	var out := AABB()
	var first := true
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null or (visible_only and not mi.is_visible_in_tree()):
			continue
		var b := mi.global_transform * mi.mesh.get_aabb()
		out = b if first else out.merge(b)
		first = false
	return out


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	await _settle(tree, 20)
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	main.set("time_scale", 0.0)
	var now := float(main.call("get_absolute_hours"))
	main.call("set_absolute_hours", floor(now / 24.0) * 24.0 + 11.0)
	var player := main.find_child("Player", true, false) as Node3D
	var base := player.global_position if player != null else Vector3.ZERO
	var placed := {}
	var i := 0
	for mid in FILE_H:
		var r := PlacedPropService.place_model_at_xz(main, mid, base.x - 4.5 + 3.0 * i, base.z + 5.0, {})
		placed[mid] = str(r.get("prop_id", ""))
		i += 1
	await _settle(tree, 40)
	var props := {}
	for mid in placed:
		var prop := PlacedPropRuntime.find_by_prop_id(main, placed[mid])
		_ok(prop != null, "%s placed" % mid)
		if prop == null:
			continue
		props[mid] = prop
		var model := prop.get_node_or_null("ModelRoot") as Node3D
		var box := _world_aabb(model)
		_ok(absf(box.size.y - float(FILE_H[mid])) < float(FILE_H[mid]) * 0.02,
			"%s stands %.3f m tall, its file's %.3f m (scale %.3f)" % [mid, box.size.y, float(FILE_H[mid]), ModelCatalog.resolved_scale(mid, 1.0)])
	# Parts with a real size.
	if props.has("trash_printer"):
		var bed := (props["trash_printer"] as Node3D).find_child("Z bed", true, false) as Node3D
		var bb := _world_aabb(bed) if bed != null else AABB()
		var a := maxf(bb.size.x, bb.size.z)
		var b := minf(bb.size.x, bb.size.z)
		_ok(absf(a - 0.8128) < 0.005 and absf(b - 0.5413) < 0.005, "trash printer bed plate %.1f × %.1f mm (32 × 21.3 in)" % [a * 1000.0, b * 1000.0])
	if props.has("pp_sheet_press"):
		var press := props["pp_sheet_press"] as Node3D
		var sheet := press.find_child("Recycled Plastic Sheet", true, false) as Node3D
		var rt := press.get_node_or_null("PpSheetPressRuntime")
		if sheet != null:
			sheet.visible = true
		var sb := _world_aabb(sheet, false) if sheet != null else AABB()
		_ok(absf(maxf(sb.size.x, sb.size.z) - 1.245) < 0.005, "the press's sheet is %.3f m across (49 in)" % maxf(sb.size.x, sb.size.z))
		var ds: Dictionary = rt.call("debug_state") if rt != null else {}
		print("machine-scale debug press: %s" % str(ds))
		_ok(rt != null and float(ds.get("sign", 0.0)) > 0.0 and absf(float(ds.get("gap_m", 0.0)) - 0.208) < 0.01 and bool(ds.get("sheet_rides", false)),
			"the press closes upward by the measured %.0f mm gap, the sheet riding" % (float(ds.get("gap_m", 0.0)) * 1000.0))
		var top := press.find_child("plate#2", true, false) as Node3D
		var cam := Camera3D.new()
		main.add_child(cam)
		main.call("push_camera_claim", "machine_scale", {"camera_id": cam.get_instance_id()})
		var pc := _world_aabb(press).get_center()
		cam.global_position = pc + Vector3(1.6, 0.6, 2.2)
		cam.look_at(pc, Vector3.UP)
		for comp in [0.0, 1.0]:
			if rt != null:
				rt.set("force_compression", comp)
			await _settle(tree, 4)
			if sheet != null:
				sheet.visible = true
			await _settle(tree, 1)
			var st := _world_aabb(sheet, false) if sheet != null else AABB()
			var tp := _world_aabb(top) if top != null else AABB()
			var gap := tp.position.y - st.end.y
			print("machine-scale debug press at %.0f: sheet top %.4f, top platen bottom %.4f, gap %.1f mm" % [comp, st.end.y, tp.position.y, gap * 1000.0])
			if comp >= 1.0:
				_ok(absf(gap) < 0.003, "closed, the sheet meets the top platen (%.1f mm)" % (gap * 1000.0))
			else:
				_ok(gap > 0.19, "open, %.0f mm between the sheet and the top platen" % (gap * 1000.0))
			await _shot(main, "press_%d" % int(comp))
		if rt != null:
			rt.set("force_compression", -1.0)
		cam.global_position = base + Vector3(0.0, 2.2, 1.0)
		cam.look_at(base + Vector3(0.0, 0.7, 5.0), Vector3.UP)
		await _shot(main, "machines")
		main.call("pop_camera_claim", "machine_scale")
		cam.queue_free()
	for mid in placed:
		if loader != null and loader.has_method("delete_prop_by_id"):
			loader.call("delete_prop_by_id", placed[mid])
	await _settle(tree, 5)
	print("machine-scale RESULT: %s (%d fails)" % ["PASS" if _fails.is_empty() else "FAIL", _fails.size()])
	return {"ok": _fails.is_empty(), "fails": _fails}
