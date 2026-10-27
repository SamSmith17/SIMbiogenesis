extends RefCounted

## The toroid designer on a REAL world (sandbox; writes nothing to the
## player's world):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/toroidlab_designer_check.gd -Label toroidlab
## Opens the designer through the loader, loads every built-in design and
## shoots the 3D studio plus the section, sheets and schedule views, runs
## UiAudit on the open modal, drives its own controls (rib count, outer
## radius, a bracing row, the canopy switch), exports the fabrication files
## and reads the DXFs back, then places the reference toroid in front of the
## player: a prop with its spec, collision, counted as shade, its panel ring
## a graph array of 24 × 100 W wired 6S × 4P; it packs to its computed bundle
## (the array drops out) and unpacks (it comes back), the designer reopens
## bound to it and Apply with 20 ribs re-seeds the array with 20 panels, and
## deleting it removes the array. Removes what it placed.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("toroidlab %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func _graph_array(main: Node, tag: String) -> Dictionary:
	var sgv := main.get_node_or_null("UILayer/SystemGraphView")
	if sgv == null:
		return {}
	var model: Variant = sgv.get("model")
	if model == null:
		return {}
	for it in model.items:
		if it is Dictionary and str(((it as Dictionary).get("specs", {}) as Dictionary).get("osm_tag", "")) == tag:
			return it
	return {}


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var dir := "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(dir)
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	_ok(loader != null and loader.has_method("open_toroidlab"), "the loader has the designer")
	if loader == null:
		return {"ok": false}
	loader.call("open_toroidlab")
	await _settle(tree, 20)
	var ui: Control = loader.call("toroidlab_designer")
	_ok(ui != null and ui.visible and bool(ui.call("is_open")), "the designer opened")
	if ui == null:
		return {"ok": false}
	var vp: SubViewport = ui.get("_viewport")
	for p in ToroidLabPresets.builtins():
		var id := str(p["id"])
		ui.call("load_builtin", id)
		await _settle(tree, 14)
		var d: Dictionary = ui.call("design")
		var errs: Array = (d["checks"] as Array).filter(func(c): return str(c["level"]) == "error")
		print("toroidlab: %s — %d tubes, %d fittings, %d panels, %s, %d errors" % [id,
			(d["frame"]["members"] as Array).size(), (d["frame"]["fittings"] as Array).size(), int(d["solar"]["count"]),
			ToroidLabSpec.fmt_kg(float(d["bom"]["mass_kg"])), errs.size()])
		_ok(errs.is_empty(), "%s solves without an error" % id)
		var mesh := (ui.get("_holder") as Node3D).get_child(0).get_node_or_null("Mesh") as MeshInstance3D
		_ok(mesh != null and mesh.mesh != null and mesh.mesh.get_surface_count() > 0, "%s drew a mesh" % id)
		vp.get_texture().get_image().save_png("%s/studio_%s.png" % [dir, id])
	ui.call("load_builtin", "overview_toroid")
	await _settle(tree, 14)
	for tab in [1, 2, 3]:
		ui.call("set_tab", tab)
		await _settle(tree, 4)
		main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [dir, ["", "section", "sheets", "schedule"][tab]])
	ui.call("set_tab", 0)
	ui.call("_set_highlight", "A1")
	ui.call("set_explode", 0.6)
	await _settle(tree, 4)
	vp.get_texture().get_image().save_png("%s/studio_exploded_A1.png" % dir)
	_ok(str(ui.call("highlight")) == "A1", "highlighting rib arc class A1")
	ui.call("set_explode", 0.0)
	ui.call("set_assembly", 0.5)
	await _settle(tree, 4)
	vp.get_texture().get_image().save_png("%s/studio_half_built.png" % dir)
	ui.call("set_assembly", 1.0)
	ui.call("_set_highlight", "")
	await _settle(tree, 4)
	main.get_viewport().get_texture().get_image().save_png("%s/modal.png" % dir)
	var audit := UiAudit.run(main.get_viewport())
	print("toroidlab: ui audit — %s" % UiAudit.summary_line(audit))
	_ok(int(audit.get("errors", 0)) == 0, "the open modal has no UI audit errors")
	# The modal's own controls.
	var seg := ui.call("control_for", "torus", "segments") as SpinBox
	_ok(seg != null, "the rib count control")
	if seg != null:
		seg.value = 30
		await _settle(tree, 16)
		var d30: Dictionary = ui.call("design")
		_ok(int(d30["frame"]["n"]) == 30 and int(d30["solar"]["count"]) == 30, "30 ribs → 30 bays of panels (%d)" % int(d30["solar"]["count"]))
		seg.value = 24
		await _settle(tree, 16)
	var outer := ui.call("control_for", "_measure", "outer_r_m") as SpinBox
	_ok(outer != null, "the outer radius control")
	if outer != null:
		outer.value = 4.5
		await _settle(tree, 16)
		var d45: Dictionary = ui.call("design")
		_ok(absf(float(d45["stats"]["outer_r_m"]) - 4.5) < 0.005, "the outer radius reaches the torus (%.3f)" % float(d45["stats"]["outer_r_m"]))
		_ok(absf(float(d45["stats"]["inner_r_m"]) - 0.936) < 0.01, "and keeps the inner radius")
		ui.call("_undo_step")
		await _settle(tree, 10)
	ui.call("_on_add_brace")
	await _settle(tree, 16)
	var db: Dictionary = ui.call("design")
	var lines := (db["frame"]["members"] as Array).filter(func(m): return str(m["kind"]) == "cable").size()
	_ok(lines == 48, "Add bracing puts X tension lines in every bay between the first two rings (%d)" % lines)
	vp.get_texture().get_image().save_png("%s/studio_braced.png" % dir)
	main.get_viewport().get_texture().get_image().save_png("%s/modal_braced.png" % dir)
	var audit_b := UiAudit.run(main.get_viewport())
	_ok(int(audit_b.get("errors", 0)) == 0, "the modal with a bracing row has no UI audit errors")
	ui.call("_on_remove_brace", 0)
	await _settle(tree, 10)
	var cn_chk := ui.call("control_for", "canopy", "enabled") as CheckBox
	if cn_chk != null:
		cn_chk.button_pressed = false
		await _settle(tree, 16)
		_ok(((ui.call("design") as Dictionary)["canopy"]["pieces"] as Array).is_empty(), "unticking the canopy removes it")
		(ui.call("control_for", "canopy", "enabled") as CheckBox).button_pressed = true
		await _settle(tree, 16)
	# Export and read back.
	ui.call("load_builtin", "overview_toroid")
	await _settle(tree, 10)
	var out_dir := ProjectSettings.globalize_path("%s/fab_files" % dir)
	ui.call("export_to", out_dir)
	var kinds := {}
	var good := true
	for f in DirAccess.get_files_at(out_dir):
		kinds[str(f).get_extension()] = int(kinds.get(str(f).get_extension(), 0)) + 1
		if str(f).ends_with(".dxf"):
			var parsed := FlatpackCam.dxf_parse(FileAccess.get_file_as_string(out_dir.path_join(f)))
			good = good and int((parsed["polylines"] as Dictionary).get("OUTSIDE_CUT", 0)) > 0
	print("toroidlab: exported %s" % str(kinds))
	_ok(int(kinds.get("dxf", 0)) >= 1 and good and int(kinds.get("csv", 0)) == 2 and int(kinds.get("svg", 0)) >= 3,
		"exported the sheet DXF / SVG, the bend templates and the CSVs")
	ui.call("close")
	await _settle(tree, 4)
	_ok(not ui.visible, "Close hides the modal")

	# Place the reference toroid in front of the player, by daylight.
	main.set("day_time", 13.0)
	main.set("time_scale", 0.0)
	var player := main.get_node_or_null("Player") as Node3D
	var at := player.global_position if player != null else Vector3.ZERO
	var fwd := -player.global_transform.basis.z if player != null else Vector3.FORWARD
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3.FORWARD
	var pos := at + fwd * 12.0
	var spec := ToroidLabPresets.overview_spec()
	var shade_before: int = (loader.call("shade_footprints") as Array).size()
	var pid := PlacedPropService.place_prepped_at(main, ToroidLabBuilder.MODEL_ID,
		{"record_extra": {"toroid_spec": ToroidLabSpec.to_json_safe(spec), "collision_enabled": true}}, pos.x, pos.z, 0.0)
	await _settle(tree, 14)
	_ok(not pid.is_empty(), "placed the reference toroid")
	if pid.is_empty():
		return {"ok": false, "fails": _fails}
	# place_prepped_at does not run the ghost's commit hooks: seed like a placement.
	PlacedPropService.seed_toroid_graph(main, pid)
	await _settle(tree, 6)
	var rec := PlacedPropService.get_prop_record(main, pid)
	_ok(rec.get("toroid_spec") is Dictionary, "the record carries its design")
	var prop := PlacedPropRuntime.find_by_prop_id(main, pid)
	_ok(prop != null and prop.get_node_or_null("ModelRoot") != null, "the toroid is in the world")
	if prop != null:
		var bb: AABB = prop.get_world_pick_aabb()
		_ok(absf(bb.size.y - 3.19) < 0.3 and absf(bb.size.x - 8.1) < 0.4, "it stands 3.2 m tall and 8.1 m across (%s)" % str(bb.size))
		_ok(prop.get_node_or_null("PropBody") != null, "it has collision")
		for v in [[Vector3(1, 0.55, 1), "world_overview"], [Vector3(0.2, 1.6, 0.1), "world_overview_top"], [Vector3(1, 0.08, 0.3), "world_overview_low"]]:
			var cam := Camera3D.new()
			main.add_child(cam)
			var gy := TerrainSurfaceQuery.ground_height_at(main, pos.x, pos.z)
			var look := Vector3(pos.x, gy + 1.4, pos.z)
			cam.global_position = look + (v[0] as Vector3).normalized() * 13.0
			cam.look_at(look, Vector3.UP)
			var prev := main.get_viewport().get_camera_3d()
			cam.current = true
			await _settle(tree, 10)
			main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [dir, str(v[1])])
			if prev != null and is_instance_valid(prev):
				prev.current = true
			cam.queue_free()
	var shade_after: int = (loader.call("shade_footprints") as Array).size()
	_ok(shade_after >= shade_before + 1, "the toroid counts as shade (%d → %d)" % [shade_before, shade_after])
	var tag := PlacedPropService.toroid_array_tag(pid)
	var arr := _graph_array(main, tag)
	var asp: Dictionary = arr.get("specs", {})
	_ok(not arr.is_empty(), "its panel ring is a graph array")
	_ok(int(asp.get("panel_count", 0)) == 24 and absf(float(asp.get("wmp", 0.0)) - 100.0) < 0.01, "24 × 100 W on the graph (%s × %s)" % [str(asp.get("panel_count")), str(asp.get("wmp"))])
	_ok(str(asp.get("array_topology", "")) == "6S x 4P", "wired 6S × 4P as designed (%s)" % str(asp.get("array_topology", "")))
	if loader.has_method("set_prop_packed"):
		loader.call("set_prop_packed", pid, true)
		await _settle(tree, 10)
		PlacedPropService.seed_toroid_graph(main, pid)
		await _settle(tree, 4)
		var ps := PlacedPropRuntime.packed_spec_for_record(PlacedPropService.get_prop_record(main, pid))
		_ok(str(ps.get("form", "")) == "bundle" and str(ps.get("source", "")) == "computed", "it packs as its computed bundle (%s)" % PackedSpec.format_dims_short(ps))
		_ok(_graph_array(main, tag).is_empty(), "a packed toroid's array leaves the graph")
		loader.call("set_prop_packed", pid, false)
		await _settle(tree, 10)
		PlacedPropService.seed_toroid_graph(main, pid)
		await _settle(tree, 4)
		_ok(not _graph_array(main, tag).is_empty(), "and comes back when unpacked")
	loader.call("open_toroidlab_for_prop", pid)
	await _settle(tree, 14)
	_ok(ui.visible and str((ui.call("spec") as Dictionary)["name"]) == str(spec["name"]), "the designer opens bound to the placed toroid")
	_ok(bool((ui.get("_apply_btn") as Control).visible), "Apply to placed structure is offered")
	var s20 := ToroidLabSpec.resolve(spec)
	s20["torus"]["segments"] = 20
	s20["solar"]["series"] = 5
	ui.set("_spec", s20)
	ui.call("_rebuild_now")
	await _settle(tree, 6)
	ui.call("_on_apply")
	await _settle(tree, 16)
	var rec2 := PlacedPropService.get_prop_record(main, pid)
	_ok(int(((rec2.get("toroid_spec", {}) as Dictionary).get("torus", {}) as Dictionary).get("segments", 0)) == 20, "Apply wrote 20 ribs onto the record")
	var arr2 := _graph_array(main, tag)
	_ok(int((arr2.get("specs", {}) as Dictionary).get("panel_count", 0)) == 20, "and re-seeded the array with 20 panels")
	loader.call("delete_prop_by_id", pid)
	await _settle(tree, 6)
	_ok(_graph_array(main, tag).is_empty(), "deleting the toroid removes its array")
	return {"ok": _fails.is_empty(), "fails": _fails}
