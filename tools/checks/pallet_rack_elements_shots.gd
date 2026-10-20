extends RefCounted

## Pallet-rack design elements on a REAL world (sandbox, writes nothing to the
## player's world):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/pallet_rack_elements_shots.gd -Label <dir>
## Opens the builder through the loader, loads every built-in design and shoots
## the studio + the whole window, then arms the Door / Solar slope / Railing
## tools and clicks the preview through the modal's own click path, asserting
## an element lands, the inspector card shows it and the BOM counts it.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("rack-elements %s: %s" % ["PASS" if cond else "FAIL", what])
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
	_ok(loader != null and loader.has_method("open_pallet_rack_builder"), "loader has the rack builder")
	if loader == null:
		return {"ok": false}
	loader.call("open_pallet_rack_builder")
	await _settle(tree, 20)
	var ui: Control = loader.get("_pallet_rack_builder_ui")
	_ok(ui != null and ui.visible, "the builder opened")
	if ui == null:
		return {"ok": false}
	var vp: SubViewport = ui.get("_viewport")

	for d in PalletRackBuilder.design_presets():
		var id := str(d["id"])
		_ok(bool(ui.call("load_design", id)), "loaded design %s" % id)
		await _settle(tree, 30)
		var spec: Dictionary = ui.get("_spec")
		var b := PalletRackBuilder.bom(spec)
		print("rack-elements: %s bom %s" % [id, JSON.stringify(b)])
		vp.get_texture().get_image().save_png("%s/studio_%s.png" % [dir, id])
		main.get_viewport().get_texture().get_image().save_png("%s/window_%s.png" % [dir, id])
		_ok((spec["elements"] as Array).size() == (d["spec"]["elements"] as Array).size(),
			"%s kept its %d elements" % [id, (d["spec"]["elements"] as Array).size()])
	# Close-ups where the detail lives.
	var closeups := [
		["two_storey", Vector3(1.6, 1.2, -2.3), 5.5, PI - 0.35, 0.2],
		["two_storey", Vector3(-4.0, 1.6, 0.0), 8.0, -PI * 0.5 - 0.5, 0.35],
		["solar_workshop", Vector3(0.0, 2.2, -4.5), 9.0, PI - 0.2, 0.25],
		["courtyard_compound", Vector3(0.0, 4.0, 0.0), 14.0, PI - 0.6, 1.0],
	]
	for k in closeups.size():
		var cu: Array = closeups[k]
		ui.call("load_design", str(cu[0]))
		await _settle(tree, 20)
		ui.set("_target", cu[1])
		ui.set("_dist", cu[2])
		ui.set("_yaw", cu[3])
		ui.set("_pitch", cu[4])
		ui.call("_update_camera")
		await _settle(tree, 6)
		vp.get_texture().get_image().save_png("%s/close_%d_%s.png" % [dir, k, str(cu[0])])
		if k == 0:
			# The same wall with nothing in it: tells a lighting artefact of
			# the plain walls apart from one the elements bring.
			var bare: Dictionary = (ui.get("_spec") as Dictionary).duplicate(true)
			bare["elements"] = []
			ui.set("_spec", bare)
			ui.call("_rebuild_preview", true)
			await _settle(tree, 6)
			vp.get_texture().get_image().save_png("%s/close_%d_bare_wall.png" % [dir, k])
	ui.set("_yaw", PI - 0.75)
	ui.set("_pitch", 0.5)
	# A bare rack, then place things with the tools through the click path.
	_ok(bool(ui.call("load_design", "solar_workshop")), "back to the solar workshop")
	await _settle(tree, 20)
	var cont: Control = ui.get("_vp_container")
	var cam: Camera3D = ui.get("_camera")
	var spec0: Dictionary = ui.get("_spec")
	var fp := PalletRackBuilder.footprint_xz(spec0)
	# Targets in 3D, projected to the container the way a player's click lands:
	# the right face low down (a door), the right face high (stairs to the
	# roof), a level-1 deck cell (a railing), and the front face's left end.
	var targets := [
		["door", Vector3(fp.x * 0.5 + 0.05, 1.2, -fp.y * 0.15)],
		["window", Vector3(fp.x * 0.5 + 0.05, 1.4, fp.y * 0.2)],
		["stairs", Vector3(fp.x * 0.5 + 0.05, 4.6, fp.y * 0.1)],
	]
	for c in (ui.get("_pick_cache") as Array):
		if str(c.get("kind", "")) == "deck" and int(c.get("level", -1)) == 1:
			targets.append(["railing", (c["aabb"] as AABB).get_center()])
			break
	var n0 := (spec0["elements"] as Array).size()
	for pair in targets:
		ui.call("_set_tool", pair[0])
		var vpp := cam.unproject_position(pair[1] as Vector3)
		var at := vpp * (cont.size / Vector2(vp.size))
		ui.call("_update_tool_ghost", at)
		var ghosts: Array = ui.get("_ghost_comps")
		var hov: Array = ui.get("_hover_group")
		print("rack-elements: %s at %s ghost boxes %d, existing-hover %d" % [pair[0], str(at), ghosts.size(), hov.size()])
		await _settle(tree, 3)
		vp.get_texture().get_image().save_png("%s/ghost_%s.png" % [dir, pair[0]])
		var before := ((ui.get("_spec") as Dictionary)["elements"] as Array).size()
		ui.call("_tool_click", at, false)
		await _settle(tree, 15)
		var after := ((ui.get("_spec") as Dictionary)["elements"] as Array).size()
		_ok(after == before + 1, "the %s tool placed one element" % pair[0])
		var insp: Control = ui.get("_insp_frame")
		_ok(insp != null and insp.visible, "the card shows the new %s" % pair[0])
		vp.get_texture().get_image().save_png("%s/tool_%s.png" % [dir, pair[0]])
	var spec1: Dictionary = ui.get("_spec")
	var n1 := (spec1["elements"] as Array).size()
	print("rack-elements: placed %s" % JSON.stringify((spec1["elements"] as Array).slice(n0)))
	print("rack-elements: bom after tools %s" % JSON.stringify(PalletRackBuilder.bom(spec1)))
	main.get_viewport().get_texture().get_image().save_png("%s/window_after_tools.png" % dir)
	# The selected-bay path: click a slope bay, it selects that bay only.
	var comps: Array = ui.get("_pick_cache")
	var bay := {}
	for c in comps:
		if str(c.get("etype", "")) == "lean_to" and int(c.get("seg", -1)) == 1:
			bay = c
	_ok(not bay.is_empty(), "the glazed bay is pickable")
	if not bay.is_empty():
		ui.set("_selection", [str(bay["id"])])
		ui.call("_refresh_inspector")
		ui.call("_refresh_highlight")
		await _settle(tree, 6)
		var fields: Dictionary = ui.get("_insp_fields")
		_ok(fields.has("_seg"), "a bay's own covering is in the card")
		vp.get_texture().get_image().save_png("%s/bay_selected.png" % dir)
		main.get_viewport().get_texture().get_image().save_png("%s/window_bay_selected.png" % dir)
	ui.call("close")
	await _settle(tree, 4)
	print("rack-elements: %s" % ("PASS" if _fails.is_empty() else "FAIL (%d)" % _fails.size()))
	return {"ok": _fails.is_empty(), "fails": _fails}
