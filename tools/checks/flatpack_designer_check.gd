extends RefCounted

## The flat-pack furniture designer on a REAL world (sandbox; writes nothing
## to the player's world):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/flatpack_designer_check.gd -Label flatpack
## Opens the designer through the loader, loads every built-in design and
## shoots the 3D studio + the sheets view (and the side-profile editor for the
## chairs), runs UiAudit on the open modal, exports the CNC files and reads
## the DXFs back, then places a bench and a daybed in front of the player:
## each is a prop with its spec, tagged as a place to sit / sleep with seat
## spots ON the furniture at the right height; packs to a flat stack and
## unpacks again. Removes what it placed.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("flatpack %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var dir := "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(dir)
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	_ok(loader != null and loader.has_method("open_flatpack_designer"), "the loader has the designer")
	if loader == null:
		return {"ok": false}
	loader.call("open_flatpack_designer")
	await _settle(tree, 20)
	var ui: Control = loader.call("flatpack_designer")
	_ok(ui != null and ui.visible and bool(ui.call("is_open")), "the designer opened")
	if ui == null:
		return {"ok": false}
	var vp: SubViewport = ui.get("_viewport")
	for p in FlatpackPresets.builtins():
		var id := str(p["id"])
		ui.call("load_builtin", id)
		await _settle(tree, 12)
		var d: Dictionary = ui.call("design")
		var clashes := 0
		var poses: Array = [""] if (d["poses"] as Array).is_empty() else (d["poses"] as Array).map(func(x): return str(x["id"]))
		for pose in poses:
			clashes += FlatpackJoints.interference(d, pose).size()
		print("flatpack: %s — %d parts, %d sheets, %d warnings, %d clashes" % [id,
			(d["parts"] as Array).size(), int(d["bom"]["sheets"]), (d["warnings"] as Array).size(), clashes])
		_ok((d["warnings"] as Array).is_empty() and clashes == 0, "%s solves clean" % id)
		vp.get_texture().get_image().save_png("%s/studio_%s.png" % [dir, id])
		ui.call("set_tab", 1)
		await _settle(tree, 4)
		main.get_viewport().get_texture().get_image().save_png("%s/sheets_%s.png" % [dir, id])
		if str(d["type"]) in ["chair", "lounger"]:
			ui.call("set_tab", 2)
			await _settle(tree, 4)
			main.get_viewport().get_texture().get_image().save_png("%s/profile_%s.png" % [dir, id])
		ui.call("set_tab", 0)
	# The whole modal, audited.
	ui.call("load_builtin", "daybed")
	await _settle(tree, 12)
	ui.set("_explode", 0.6)
	ui.call("_rebuild_studio")
	await _settle(tree, 4)
	vp.get_texture().get_image().save_png("%s/studio_daybed_exploded.png" % dir)
	ui.set("_explode", 0.0)
	ui.call("_rebuild_studio")
	await _settle(tree, 4)
	main.get_viewport().get_texture().get_image().save_png("%s/modal.png" % dir)
	var audit := UiAudit.run(main.get_viewport())
	print("flatpack: ui audit — %s" % UiAudit.summary_line(audit))
	_ok(int(audit.get("errors", 0)) == 0, "the open modal has no UI audit errors")
	# Export and read back.
	var out_dir := ProjectSettings.globalize_path("%s/cut_files" % dir)
	ui.call("_write_files", out_dir)
	var dxfs := 0
	var good := true
	for f in DirAccess.get_files_at(out_dir):
		if str(f).ends_with(".dxf"):
			dxfs += 1
			var parsed := FlatpackCam.dxf_parse(FileAccess.get_file_as_string(out_dir.path_join(f)))
			good = good and int((parsed["polylines"] as Dictionary).get("OUTSIDE_CUT", 0)) > 0
	_ok(dxfs == 4 and good, "exported 3 sheet DXFs + the coupon, each with outlines (%d)" % dxfs)
	ui.call("close")
	await _settle(tree, 4)
	_ok(not ui.visible, "Close hides the modal")

	# Place a bench and a daybed in front of the player, by daylight (the
	# sandbox world may be at night; nothing here is saved).
	main.set("day_time", 13.0)
	main.set("time_scale", 0.0)
	var player := main.get_node_or_null("Player") as Node3D
	var at := player.global_position if player != null else Vector3.ZERO
	var fwd := -player.global_transform.basis.z if player != null else Vector3.FORWARD
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3.FORWARD
	var placed: Array = []
	var bench := FlatpackPresets.builtin("bench")["spec"] as Dictionary
	var daybed := (FlatpackPresets.builtin("daybed")["spec"] as Dictionary).duplicate(true)
	daybed["pose"] = "daybed"
	var targets := [[bench, at + fwd * 4.0, "quiet", 2], [daybed, at + fwd * 8.0, "sleep", 2]]
	for tg in targets:
		var spec: Dictionary = tg[0]
		var pos: Vector3 = tg[1]
		var pid := PlacedPropService.place_prepped_at(main, FlatpackBuilder.MODEL_ID,
			{"record_extra": {"flatpack_spec": FlatpackSpec.to_json_safe(spec), "collision_enabled": true}},
			pos.x, pos.z, 30.0)
		await _settle(tree, 10)
		_ok(not pid.is_empty(), "placed %s" % str(spec["name"]))
		if pid.is_empty():
			continue
		placed.append(pid)
		var rec := PlacedPropService.get_prop_record(main, pid)
		_ok(rec.get("flatpack_spec") is Dictionary, "the record carries its design")
		var prop := PlacedPropRuntime.find_by_prop_id(main, pid)
		_ok(prop != null and prop.get_node_or_null("ModelRoot") != null, "the piece is in the world")
		var reg: SpaceRegistry = loader.get("npc_spaces")
		var space := reg.space_for_target({"kind": "prop", "prop_id": pid}) if reg != null else {}
		_ok(str(space.get("space_type", "")) == str(tg[2]), "%s is tagged %s (%s)" % [str(spec["name"]), str(tg[2]),
			str(space.get("space_type", "none"))])
		if prop != null:
			var spots := NpcPopulationBridge.furniture_spots(prop)
			var hmin := INF
			var hmax := 0.0
			for sp in spots:
				hmin = minf(hmin, float(sp["elev"]))
				hmax = maxf(hmax, float(sp["elev"]))
			print("flatpack: %s spots %s" % [str(spec["name"]), str(spots)])
			_ok(spots.size() >= int(tg[3]) and hmin > 0.2 and hmax < 0.6,
				"%s offers %d spots on top of it (%.2f–%.2f m up)" % [str(spec["name"]), spots.size(), hmin, hmax])
			# Shots from beside it.
			var cam := Camera3D.new()
			main.add_child(cam)
			var gy := TerrainSurfaceQuery.ground_height_at(main, pos.x, pos.z)
			var look := Vector3(pos.x, gy + 0.4, pos.z)
			cam.global_position = look + Vector3(1.9, 1.3, 1.9)
			cam.look_at(look, Vector3.UP)
			var prev := main.get_viewport().get_camera_3d()
			cam.current = true
			await _settle(tree, 8)
			main.get_viewport().get_texture().get_image().save_png("%s/world_%s.png" % [dir,
				FlatpackCam.safe_name(str(spec["name"]))])
			if prev != null and is_instance_valid(prev):
				prev.current = true
			cam.queue_free()
	if not placed.is_empty() and loader.has_method("set_prop_packed"):
		var pid0 := str(placed[0])
		loader.call("set_prop_packed", pid0, true)
		await _settle(tree, 10)
		var spec := PlacedPropRuntime.packed_spec_for_record(PlacedPropService.get_prop_record(main, pid0))
		_ok(str(spec.get("form", "")) == "panel_stack" and str(spec.get("source", "")) == "computed",
			"the bench packs as its computed flat stack (%s)" % PackedSpec.format_dims_short(spec))
		loader.call("set_prop_packed", pid0, false)
		await _settle(tree, 10)
		_ok(not bool(PlacedPropService.get_prop_record(main, pid0).get("packed", false)), "and unpacks again")
	for pid in placed:
		loader.call("delete_prop_by_id", str(pid))
	await _settle(tree, 4)
	return {"ok": _fails.is_empty(), "fails": _fails}
