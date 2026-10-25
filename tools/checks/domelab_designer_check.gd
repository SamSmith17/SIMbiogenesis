extends RefCounted

## The dome & zome designer on a REAL world (sandbox; writes nothing to the
## player's world):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/domelab_designer_check.gd -Label domelab
## Opens the designer through the loader, loads every built-in design and
## shoots the 3D studio (plus the sheets, hubs and schedule views for the
## first few), runs UiAudit on the open modal, exports the fabrication files
## and reads the DXFs back, then places a 2V conduit dome and a plywood zome
## in front of the player: each is a prop with its spec, counted as shade by
## the comfort model, packs to its computed bundle and unpacks again, and a
## click on the placed dome reopens the designer bound to it. Removes what
## it placed.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("domelab %s: %s" % ["PASS" if cond else "FAIL", what])
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
	_ok(loader != null and loader.has_method("open_domelab"), "the loader has the designer")
	if loader == null:
		return {"ok": false}
	loader.call("open_domelab")
	await _settle(tree, 20)
	var ui: Control = loader.call("domelab_designer")
	_ok(ui != null and ui.visible and bool(ui.call("is_open")), "the designer opened")
	if ui == null:
		return {"ok": false}
	var vp: SubViewport = ui.get("_viewport")
	var views_shot := 0
	for p in DomeLabPresets.builtins():
		var id := str(p["id"])
		ui.call("load_builtin", id)
		await _settle(tree, 14)
		var d: Dictionary = ui.call("design")
		var errs: Array = (d["checks"] as Array).filter(func(c): return str(c["level"]) == "error")
		print("domelab: %s — %d struts, %d hub types, %d panels, %s, %d errors" % [id,
			(d["struts"] as Array).size(), (d["hub_types"] as Array).size(),
			((d["panels"] as Dictionary).get("panels", []) as Array).size(),
			DomeLabSpec.fmt_kg(float(d["bom"]["mass_kg"])), errs.size()])
		_ok(errs.is_empty(), "%s solves without an error" % id)
		var mesh := (ui.get("_holder") as Node3D).get_child(0).get_node_or_null("Mesh") as MeshInstance3D
		_ok(mesh != null and mesh.mesh.get_surface_count() > 0, "%s drew a mesh" % id)
		vp.get_texture().get_image().save_png("%s/studio_%s.png" % [dir, id])
		if views_shot < 4 and (id in ["3v_58", "triacon_4v", "covered_3v", "plate_dome", "zome_8", "helix_zome"]):
			views_shot += 1
			for tab in [1, 2, 3]:
				ui.call("set_tab", tab)
				await _settle(tree, 4)
				main.get_viewport().get_texture().get_image().save_png("%s/%s_%s.png" % [dir,
					["", "sheets", "hubs", "schedule"][tab], id])
			ui.call("set_tab", 0)
	# The whole modal, audited, with a highlight and an explode.
	ui.call("load_builtin", "3v_58")
	await _settle(tree, 14)
	ui.call("_set_highlight", "B")
	ui.call("set_explode", 0.5)
	await _settle(tree, 4)
	vp.get_texture().get_image().save_png("%s/studio_3v_exploded_B.png" % dir)
	_ok(str(ui.call("highlight")) == "B", "highlighting strut class B")
	ui.call("set_explode", 0.0)
	ui.call("set_assembly", 0.45)
	await _settle(tree, 4)
	vp.get_texture().get_image().save_png("%s/studio_3v_half_built.png" % dir)
	ui.call("set_assembly", 1.0)
	ui.call("_set_highlight", "")
	await _settle(tree, 4)
	main.get_viewport().get_texture().get_image().save_png("%s/modal.png" % dir)
	var audit := UiAudit.run(main.get_viewport())
	print("domelab: ui audit — %s" % UiAudit.summary_line(audit))
	_ok(int(audit.get("errors", 0)) == 0, "the open modal has no UI audit errors")
	# The chord factors on the schedule are the published ones.
	var d3: Dictionary = ui.call("design")
	var cf: Dictionary = d3["stats"]["chord_factors"]
	var found := 0
	for want in [0.34862, 0.40355, 0.41241]:
		for k in cf:
			if absf(float(cf[k]) - float(want)) < 2e-5:
				found += 1
				break
	_ok(found == 3, "the three published 3V chord factors are on the schedule (%s)" % str(cf))
	# Export and read back (a plate dome has sheets + a conduit dome has strut templates).
	ui.call("load_builtin", "plate_dome")
	await _settle(tree, 10)
	var out_dir := ProjectSettings.globalize_path("%s/fab_files" % dir)
	ui.call("_write_files", out_dir)
	var dxfs := 0
	var good := true
	var kinds := {}
	for f in DirAccess.get_files_at(out_dir):
		kinds[str(f).get_extension()] = int(kinds.get(str(f).get_extension(), 0)) + 1
		if str(f).ends_with(".dxf"):
			dxfs += 1
			var parsed := FlatpackCam.dxf_parse(FileAccess.get_file_as_string(out_dir.path_join(f)))
			good = good and int((parsed["polylines"] as Dictionary).get("OUTSIDE_CUT", 0)) > 0
	print("domelab: exported %s" % str(kinds))
	_ok(dxfs >= 1 and good and int(kinds.get("csv", 0)) == 2 and int(kinds.get("json", 0)) == 1,
		"exported sheet DXFs with outlines, the CSVs and the JSON (%d dxf)" % dxfs)
	ui.call("close")
	await _settle(tree, 4)
	_ok(not ui.visible, "Close hides the modal")

	# Place a 2V conduit dome and a plywood zome in front of the player, by
	# daylight (the sandbox world may be at night; nothing here is saved).
	main.set("day_time", 13.0)
	main.set("time_scale", 0.0)
	var player := main.get_node_or_null("Player") as Node3D
	var at := player.global_position if player != null else Vector3.ZERO
	var fwd := -player.global_transform.basis.z if player != null else Vector3.FORWARD
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3.FORWARD
	var side := fwd.cross(Vector3.UP)
	var placed: Array = []
	var dome := (DomeLabPresets.builtin("2v_conduit")["spec"] as Dictionary).duplicate(true)
	var zome := (DomeLabPresets.builtin("zome_8")["spec"] as Dictionary).duplicate(true)
	var targets := [[dome, at + fwd * 8.0 - side * 4.0, "bundle"], [zome, at + fwd * 8.0 + side * 4.5, "bundle"]]
	var shade_before: int = (loader.call("shade_footprints") as Array).size()
	for tg in targets:
		var spec: Dictionary = tg[0]
		var pos: Vector3 = tg[1]
		var pid := PlacedPropService.place_prepped_at(main, DomeLabBuilder.MODEL_ID,
			{"record_extra": {"domelab_spec": DomeLabSpec.to_json_safe(spec), "collision_enabled": true}},
			pos.x, pos.z, 0.0)
		await _settle(tree, 12)
		_ok(not pid.is_empty(), "placed %s" % str(spec["name"]))
		if pid.is_empty():
			continue
		placed.append(pid)
		var rec := PlacedPropService.get_prop_record(main, pid)
		_ok(rec.get("domelab_spec") is Dictionary, "the record carries its design")
		var prop := PlacedPropRuntime.find_by_prop_id(main, pid)
		_ok(prop != null and prop.get_node_or_null("ModelRoot") != null, "the structure is in the world")
		if prop != null:
			var bb: AABB = prop.get_world_pick_aabb()
			var want_h := float(DomeLabDesign.solve(spec)["stats"]["height_m"])
			_ok(absf(bb.size.y - want_h) < 0.3, "%s stands %.2f m tall in the world (design %.2f)" % [str(spec["name"]), bb.size.y, want_h])
			_ok(prop.get_node_or_null("PropBody") != null, "%s has collision" % str(spec["name"]))
			var cam := Camera3D.new()
			main.add_child(cam)
			var gy := TerrainSurfaceQuery.ground_height_at(main, pos.x, pos.z)
			var look := Vector3(pos.x, gy + want_h * 0.45, pos.z)
			cam.global_position = look + Vector3(1, 0.5, 1).normalized() * (want_h * 2.6 + 4.0)
			cam.look_at(look, Vector3.UP)
			var prev := main.get_viewport().get_camera_3d()
			cam.current = true
			await _settle(tree, 8)
			main.get_viewport().get_texture().get_image().save_png("%s/world_%s.png" % [dir,
				DomeLabCam.safe_name(str(spec["name"]))])
			if prev != null and is_instance_valid(prev):
				prev.current = true
			cam.queue_free()
	var shade_after: int = (loader.call("shade_footprints") as Array).size()
	_ok(shade_after >= shade_before + placed.size(), "the domes count as shade for the comfort model (%d → %d)" % [shade_before, shade_after])
	if not placed.is_empty() and loader.has_method("set_prop_packed"):
		var pid0 := str(placed[0])
		loader.call("set_prop_packed", pid0, true)
		await _settle(tree, 10)
		var ps := PlacedPropRuntime.packed_spec_for_record(PlacedPropService.get_prop_record(main, pid0))
		_ok(str(ps.get("form", "")) == "bundle" and str(ps.get("source", "")) == "computed" and float(ps.get("w_m", 0.0)) > 1.5,
			"the dome packs as its computed strut bundle (%s)" % PackedSpec.format_dims_short(ps))
		loader.call("set_prop_packed", pid0, false)
		await _settle(tree, 10)
		_ok(not bool(PlacedPropService.get_prop_record(main, pid0).get("packed", false)), "and unpacks again")
		# The designer bound to the placed dome.
		loader.call("open_domelab_for_prop", pid0)
		await _settle(tree, 14)
		_ok(ui.visible and str((ui.call("spec") as Dictionary)["name"]) == str(dome["name"]),
			"the designer opens bound to the placed dome")
		_ok(bool((ui.get("_apply_btn") as Control).visible), "Apply to placed structure is offered")
		ui.set("_spec", DomeLabSpec.resolve(dome).merged({"radius_m": 3.6}, true))
		ui.call("_rebuild_now")
		await _settle(tree, 6)
		ui.call("_on_apply")
		await _settle(tree, 12)
		var rec2 := PlacedPropService.get_prop_record(main, pid0)
		_ok(absf(float((rec2.get("domelab_spec", {}) as Dictionary).get("radius_m", 0.0)) - 3.6) < 1e-6,
			"Apply wrote the new radius onto the record")
		var prop2 := PlacedPropRuntime.find_by_prop_id(main, pid0)
		_ok(prop2 != null and absf((prop2.get_world_pick_aabb() as AABB).size.x - 7.2) < 0.4,
			"and the world dome grew to 7.2 m across (%.2f)" % ((prop2.get_world_pick_aabb() as AABB).size.x if prop2 else -1.0))
	for pid in placed:
		loader.call("delete_prop_by_id", str(pid))
	await _settle(tree, 4)
	return {"ok": _fails.is_empty(), "fails": _fails}
