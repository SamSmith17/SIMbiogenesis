extends RefCounted

## The Solar designer on a REAL world (sandbox; writes nothing to the
## player's world):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/pvlab_designer_check.gd -Label pvlab
## Opens the designer through the loader, loads every built-in array and
## shoots the Cell / Panel / Array tabs, runs UiAudit on the open modal,
## paints a string with REAL clicks on modules in the studio, runs a test
## shadow; then places arrays in the world and checks:
##   - on the ground: one graph compound per MPPT input with its strings of
##     panels inside, one + / − pair, SolarUI given its plane;
##   - a box set between the sun and one module: the live substring shading
##     drops the array's factor, and moving the box away brings it back;
##   - on an OSM roof (the aim marches the roof surface): the array lies in
##     the roof plane (normal within 2°), flush-mounted;
##   - on a placed pallet rack: hosted by the rack, and moving the rack
##     carries it;
##   - a tracker: its heads face east in the morning and west in the
##     afternoon.
## Removes what it placed.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("pvlab %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func _sgv(main: Node) -> Node:
	return main.get_node_or_null("UILayer/SystemGraphView")


func _shoot(main: Node, tree: SceneTree, dir: String, name: String, at: Vector3, from: Vector3) -> void:
	var cam := Camera3D.new()
	main.add_child(cam)
	cam.global_position = from
	cam.look_at(at, Vector3.UP)
	var prev := main.get_viewport().get_camera_3d()
	cam.current = true
	await _settle(tree, 8)
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [dir, name])
	if prev != null and is_instance_valid(prev):
		prev.current = true
	cam.queue_free()


func _array_node(main: Node, pid: String) -> Node3D:
	var prop := PlacedPropRuntime.find_by_prop_id(main, pid)
	if prop == null:
		return null
	var stack: Array = [prop]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Node3D and n.has_meta("pvlab_spec"):
			return n as Node3D
		for c in n.get_children():
			stack.append(c)
	return null


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var dir := "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(dir)
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	_ok(loader != null and loader.has_method("open_pvlab"), "the loader has the Solar designer")
	if loader == null:
		return {"ok": false}
	loader.call("open_pvlab")
	await _settle(tree, 20)
	var ui: Control = loader.call("pvlab_designer")
	_ok(ui != null and ui.visible and bool(ui.call("is_open")), "the designer opened")
	if ui == null:
		return {"ok": false}
	var vp: SubViewport = ui.get("_viewport")
	for p in PvLabPresets.builtins():
		var id := str(p["id"])
		ui.call("load_builtin", id)
		await _settle(tree, 12)
		var d: Dictionary = ui.call("design")
		var errs: Array = (d["checks"] as Array).filter(func(c): return str(c["level"]) == "error")
		print("pvlab: %s — %d modules, %d strings on %d inputs, %.0f W, %d errors" % [id,
			(d["layout"]["panels"] as Array).size(), (d["strings"] as Array).size(), (d["groups"] as Array).size(),
			float(d["totals"]["wmp"]), errs.size()])
		_ok(errs.is_empty(), "%s solves without an error" % id)
		var holder := ui.get("_holder") as Node3D
		_ok(holder.get_child_count() > 0, "%s drew the array" % id)
		vp.get_texture().get_image().save_png("%s/studio_%s.png" % [dir, id])
	ui.call("load_builtin", "backyard_2x4")
	await _settle(tree, 10)
	for tab in [0, 1, 2]:
		ui.call("set_tab", tab)
		await _settle(tree, 10)
		main.get_viewport().get_texture().get_image().save_png("%s/tab_%s.png" % [dir, ["cell", "panel", "array"][tab]])
		var audit := UiAudit.run(main.get_viewport())
		print("pvlab: ui audit (%s) — %s" % [["cell", "panel", "array"][tab], UiAudit.summary_line(audit)])
		_ok(int(audit.get("errors", 0)) == 0, "the %s tab has no UI audit errors" % ["cell", "panel", "array"][tab])
	# Paint a string with REAL clicks on modules in the studio.
	ui.call("set_tab", 2)
	await _settle(tree, 6)
	ui.call("_on_clear_strings")
	await _settle(tree, 4)
	(ui.get("_paint_btn") as Button).button_pressed = true
	await _settle(tree, 6)
	var cont := ui.call("studio_container") as Control
	var root_vp := main.get_viewport()
	for idx in [0, 1, 2]:
		var sp: Vector2 = ui.call("module_screen_pos", idx)
		await HarnessInput.click(root_vp, cont.get_global_rect().position + sp)
		await _settle(tree, 4)
	await _settle(tree, 6)
	var dp: Dictionary = ui.call("design")
	var painted: Array = (dp["strings"] as Array)[0] if not (dp["strings"] as Array).is_empty() else []
	_ok(painted.size() == 3, "three clicks painted a string of three modules (%s)" % str(painted))
	vp.get_texture().get_image().save_png("%s/studio_painted.png" % dir)
	(ui.get("_paint_btn") as Button).button_pressed = false
	await _check_types_and_moire(ui, main, tree, dir, vp)
	await _check_search(ui, tree)
	await _check_parts(ui, main, tree, dir, vp)
	ui.call("load_builtin", "backyard_2x4")
	await _settle(tree, 8)
	ui.call("set_shade_test", "module")
	await _settle(tree, 4)
	var lt := str(ui.call("live_text"))
	_ok(lt.contains("costs"), "the test shadow reports its cost")
	print("pvlab: live — %s" % lt.replace("\n", " | "))
	main.get_viewport().get_texture().get_image().save_png("%s/tab_array_shaded.png" % dir)
	ui.call("set_shade_test", "none")
	ui.call("close")
	await _settle(tree, 4)
	_ok(not ui.visible, "Close hides the modal")

	# --- in the world -----------------------------------------------------------
	main.set("time_scale", 0.0)
	main.set("day_time", 13.0)
	var player := main.get_node_or_null("Player") as Node3D
	var at := player.global_position if player != null else Vector3.ZERO
	var fwd := -player.global_transform.basis.z if player != null else Vector3.FORWARD
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3.FORWARD
	var placed: Array = []
	var pos := at + fwd * 14.0
	var spec: Dictionary = PvLabPresets.builtin("backyard_2x4")["spec"]
	var pid := PlacedPropService.place_prepped_at(main, PvLabBuilder.MODEL_ID,
		{"record_extra": {"pvlab_spec": PvLabSpec.to_json_safe(spec), "collision_enabled": true}}, pos.x, pos.z, 0.0)
	await _settle(tree, 10)
	_ok(not pid.is_empty(), "placed a designed array on the ground")
	if pid.is_empty():
		return {"ok": false, "fails": _fails}
	placed.append(pid)
	PlacedPropService.seed_pvlab_graph(main, pid)
	await _settle(tree, 6)
	var sgv := _sgv(main)
	var model: GraphModel = sgv.get("model")
	var tag := PlacedPropService.pvlab_array_tag(pid)
	var comps := GraphPvLabArrays.find(model, tag)
	_ok(comps.size() == 1, "one graph compound for its one MPPT input (%d)" % comps.size())
	if comps.size() == 1:
		var c: Dictionary = model.get_item(str(comps[0]))
		var kids: Array = model.get_items_in_scope(str(c["child_scope_id"]))
		_ok(kids.size() == 12, "the compound holds its 12 panels (%d)" % kids.size())
		_ok(((c["specs"] as Dictionary).get("exposed_ports", []) as Array).size() == 2, "one + / − pair outside")
		_ok(absf(float((c["specs"] as Dictionary).get("tilt_deg", 0.0)) - 30.0) < 1.0, "its plane: 30° (%.1f)" % float((c["specs"] as Dictionary).get("tilt_deg", 0.0)))
	var solar_ui := main.get_node_or_null("UILayer/SolarUI")
	if solar_ui != null:
		_ok((solar_ui.get("_graph_planes") as Array).size() >= 1, "SolarUI sums the designed array's own plane")
	var an := _array_node(main, pid)
	_ok(an != null and an.get_node_or_null("Panels") != null, "the array is in the world with its modules")
	if an != null:
		var c0 := an.global_position
		await _shoot(main, tree, dir, "world_ground", c0 + Vector3(0, 1, 0), c0 + Vector3(-5, 4, 8))
		# A box between the sun and the first module.
		var clock: Object = main.get("clock")
		var sun_dir: Vector3 = clock.call("get_sun_direction") if clock != null and clock.has_method("get_sun_direction") else Vector3(0.3, 0.8, 0.5).normalized()
		var d: Dictionary = PvLabDesign.solve(an.get_meta("pvlab_spec"))
		var mxf := an.global_transform * PvLabArray.panel_xf(d["layout"], (d["layout"]["panels"] as Array)[0], 0.0)
		var box_at := mxf.origin + sun_dir.normalized() * 2.5
		var gy := TerrainSurfaceQuery.ground_height_at(main, box_at.x, box_at.z)
		var bid := PlacedPropService.place_prepped_at(main, ModelCatalog.GENERIC_BOX_ID,
			{"record_extra": {"box_spec": {"w_m": 1.0, "d_m": 1.0, "h_m": 1.0}, "collision_enabled": true}},
			box_at.x, box_at.z, 0.0)
		await _settle(tree, 6)
		if not bid.is_empty():
			placed.append(bid)
			PlacedPropService.update_prop_record(main, bid, {"y_offset": box_at.y - gy - 0.5}, true)
			await _settle(tree, 6)
			var world := (main as Node3D).get_world_3d()
			for _k in 12:
				sgv.call("_tick_pvlab_shading", main, world.direct_space_state, sun_dir)
				await _settle(tree, 1)
			var f := float(sgv.call("designed_array_shade", tag))
			var flags: PackedByteArray = (sgv.get("_pvlab_shade") as RefCounted).call("lit_flags", tag)
			print("pvlab: box shade — %d of %d samples shaded, factor %.3f" % [flags.count(0), flags.size(), f])
			_ok(f < 0.995 and f > 0.4, "a box over one module costs about a substring or a module (factor %.3f)" % f)
			await _shoot(main, tree, dir, "world_ground_shaded", mxf.origin, mxf.origin + sun_dir * 6.0 + Vector3(2, 0, 2))
			loader.call("delete_prop_by_id", bid)
			placed.erase(bid)
			await _settle(tree, 6)
			for _k in 12:
				sgv.call("_tick_pvlab_shading", main, world.direct_space_state, sun_dir.rotated(Vector3.UP, 0.02))
				await _settle(tree, 1)
			_ok(float(sgv.call("designed_array_shade", tag)) > 0.995, "with the box gone the array is unshaded again")

	# --- an OSM roof -----------------------------------------------------------------
	var roof_pid := ""
	var bdata: Array = loader.get("_buildings_data")
	var best := {}
	var best_d := INF
	for b in bdata:
		var pts: PackedVector2Array = (b as Dictionary).get("points", PackedVector2Array())
		if pts.size() < 3:
			continue
		var cen := Vector2.ZERO
		for q in pts:
			cen += q
		cen /= float(pts.size())
		var dd := cen.distance_to(Vector2(at.x, at.z))
		if dd < best_d:
			best_d = dd
			best = {"c": cen, "pts": pts}
	if not best.is_empty():
		var cen2: Vector2 = best["c"]
		var origin := Vector3(cen2.x + 1.2, at.y + 60.0, cen2.y + 0.8)
		var aim := PvSurfaceAim.pick_ray(main, origin, Vector3.DOWN)
		_ok(bool(aim.get("valid", false)) and str((aim.get("host", {}) as Dictionary).get("kind", "")) == "building",
			"aiming down onto the nearest house hits its roof (%s)" % str(aim.get("host", {})))
		if bool(aim.get("valid", false)):
			var rspec: Dictionary = PvLabPresets.builtin("roof_flush_rail")["spec"].duplicate(true)
			rspec["array"]["cols"] = 2
			rspec["array"]["stack"] = 1
			rspec["strings"]["size"] = 2
			var xf := PvSurfaceAim.mount_transform(aim, 0.0)
			var pr := PvSurfaceAim.record_patch_for(main, PvLabBuilder.MODEL_ID, xf)
			roof_pid = PlacedPropService.place_prepped_at(main, PvLabBuilder.MODEL_ID,
				{"record_extra": {"pvlab_spec": PvLabSpec.to_json_safe(rspec), "collision_enabled": true,
					"mount_host": {"kind": "building", "id": str(aim["host"]["id"])}}},
				float(pr["x"]), float(pr["z"]), float(pr["yaw"]))
			await _settle(tree, 6)
			if not roof_pid.is_empty():
				placed.append(roof_pid)
				PlacedPropService.update_prop_record(main, roof_pid, {"y_offset": pr["y_offset"], "pitch": pr["pitch"],
					"roll": pr["roll"], "yaw": pr["yaw"]}, true)
				await _settle(tree, 8)
				var rn := _array_node(main, roof_pid)
				if rn != null:
					var up := rn.global_transform.basis.y.normalized()
					var nrm: Vector3 = aim["normal"]
					var ang := rad_to_deg(up.angle_to(nrm)) if bool(aim.get("pitched", false)) else rad_to_deg(up.angle_to(Vector3.UP))
					_ok(ang < 2.0, "the roof array lies in the roof plane (%.2f° off)" % ang)
					_ok(absf(rn.global_position.y - (aim["position"] as Vector3).y) < 0.05, "and sits on the roof surface")
					await _shoot(main, tree, dir, "world_roof", rn.global_position, rn.global_position + Vector3(6, 6, 6))
				PlacedPropService.seed_pvlab_graph(main, roof_pid)
				await _settle(tree, 4)
				var rc := GraphPvLabArrays.find(model, PlacedPropService.pvlab_array_tag(roof_pid))
				if rc.size() > 0:
					var rsp: Dictionary = model.get_item(str(rc.values()[0]))["specs"]
					var rt := float(rsp.get("tilt_deg", 0.0))
					var want := rad_to_deg(acos(clampf((aim["normal"] as Vector3).y, -1.0, 1.0)))
					_ok(absf(rt - want) < 2.0, "its graph plane is the roof's pitch (%.1f vs %.1f°)" % [rt, want])

	# --- on a placed pallet rack ----------------------------------------------------
	var rack_at := at + fwd * 14.0 + fwd.cross(Vector3.UP).normalized() * 12.0
	var rack_pid := PlacedPropService.place_prepped_at(main, PalletRackBuilder.MODEL_ID,
		{"record_extra": {"collision_enabled": true}}, rack_at.x, rack_at.z, 0.0)
	await _settle(tree, 10)
	if not rack_pid.is_empty():
		placed.append(rack_pid)
		var rack_prop := PlacedPropRuntime.find_by_prop_id(main, rack_pid)
		var bb: AABB = rack_prop.get_world_pick_aabb() if rack_prop != null else AABB()
		var top := Vector3(bb.get_center().x, bb.end.y + 5.0, bb.get_center().z)
		var aim2 := PvSurfaceAim.pick_ray(main, top, Vector3.DOWN)
		var host2: Dictionary = aim2.get("host", {})
		_ok(str(host2.get("kind", "")) == "prop" and str(host2.get("id", "")) == rack_pid,
			"aiming down onto the rack hits the rack (%s)" % str(host2))
		if bool(aim2.get("valid", false)):
			var sspec: Dictionary = PvLabPresets.builtin("flex_laid")["spec"]
			var xf2 := PvSurfaceAim.mount_transform(aim2, 0.0)
			var pr2 := PvSurfaceAim.record_patch_for(main, PvLabBuilder.MODEL_ID, xf2)
			var host_rec := PlacedPropService.get_prop_record(main, rack_pid)
			var local := PlacedPropService._xf_to_array(PvSurfaceAim.record_xf(main, host_rec).affine_inverse() * xf2)
			var spid := PlacedPropService.place_prepped_at(main, PvLabBuilder.MODEL_ID,
				{"record_extra": {"pvlab_spec": PvLabSpec.to_json_safe(sspec), "collision_enabled": true,
					"mount_host": {"kind": "prop", "id": rack_pid, "local": local}}},
				float(pr2["x"]), float(pr2["z"]), float(pr2["yaw"]))
			await _settle(tree, 6)
			if not spid.is_empty():
				placed.append(spid)
				PlacedPropService.update_prop_record(main, spid, {"y_offset": pr2["y_offset"]}, true)
				await _settle(tree, 6)
				var before := _array_node(main, spid).global_position
				var rack_before := PlacedPropRuntime.find_by_prop_id(main, rack_pid).global_position
				await _shoot(main, tree, dir, "world_on_rack", before, before + Vector3(5, 5, 5))
				var rrec := PlacedPropService.get_prop_record(main, rack_pid)
				PlacedPropService.update_prop_record(main, rack_pid, {"x": float(rrec["x"]) + 3.0}, true)
				await _settle(tree, 8)
				var after := _array_node(main, spid).global_position
				var rack_after := PlacedPropRuntime.find_by_prop_id(main, rack_pid).global_position
				# The rack re-grounds at its new spot; the array keeps its place on it.
				_ok(((after - before) - (rack_after - rack_before)).length() < 0.05,
					"moving the rack carries the array on it (array moved %s, rack %s)" % [str(after - before), str(rack_after - rack_before)])

	# --- a tracker ---------------------------------------------------------------------
	var tpos := at + fwd * 32.0
	var tspec: Dictionary = PvLabPresets.builtin("tracker_1p")["spec"].duplicate(true)
	tspec["array"]["rows"] = 2
	tspec["array"]["cols"] = 6
	tspec["strings"]["size"] = 6
	tspec["strings"]["inputs"] = 1
	var tpid := PlacedPropService.place_prepped_at(main, PvLabBuilder.MODEL_ID,
		{"record_extra": {"pvlab_spec": PvLabSpec.to_json_safe(tspec), "collision_enabled": true}}, tpos.x, tpos.z, 0.0)
	await _settle(tree, 10)
	if not tpid.is_empty():
		placed.append(tpid)
		var tn := _array_node(main, tpid)
		var rt := PlacedPropRuntime.find_by_prop_id(main, tpid).get_node_or_null("PvTrackerRuntime")
		_ok(rt != null, "the tracker has its runtime")
		main.set("day_time", 9.0)
		await _settle(tree, 50)
		var morning := PvLabBuilder.tracker_angle(tn) if tn != null else 0.0
		await _shoot(main, tree, dir, "world_tracker_morning", tn.global_position + Vector3(0, 1.5, 0),
			tn.global_position + Vector3(-9, 4, 9))
		main.set("day_time", 16.0)
		await _settle(tree, 50)
		var afternoon := PvLabBuilder.tracker_angle(tn) if tn != null else 0.0
		await _shoot(main, tree, dir, "world_tracker_afternoon", tn.global_position + Vector3(0, 1.5, 0),
			tn.global_position + Vector3(-9, 4, 9))
		_ok(morning < -10.0 and afternoon > 10.0, "the tracker faces east in the morning (%.1f°) and west in the afternoon (%.1f°)" % [morning, afternoon])
	for p2 in placed:
		loader.call("delete_prop_by_id", str(p2))
	await _settle(tree, 6)
	_ok(GraphPvLabArrays.find(model, tag).is_empty(), "deleting the array removes its graph compounds")
	return {"ok": _fails.is_empty(), "fails": _fails}


## The Panel tab's Type picker changes the build (frame, thickness, sheet);
## the face at medium distance for the moiré, and the frame lip close up.
func _check_types_and_moire(ui: Control, main: Node, tree: SceneTree, dir: String, vp: SubViewport) -> void:
	ui.call("load_builtin", "backyard_2x4")
	await _settle(tree, 8)
	ui.call("set_tab", 1)
	await _settle(tree, 8)
	var opt := ui.call("control_for", "module", "type") as OptionButton
	_ok(opt != null, "the Panel tab has a Type picker")
	if opt == null:
		return
	for t in PvLabModule.TYPES:
		var idx := -1
		for i in opt.item_count:
			if str(opt.get_item_metadata(i)) == str(t):
				idx = i
		opt.select(idx)
		opt.item_selected.emit(idx)
		await _settle(tree, 14)
		opt = ui.call("control_for", "module", "type") as OptionButton
		var m: Dictionary = (ui.call("spec") as Dictionary)["module"]
		print("pvlab: type %s — frame %s, %.1f mm, %s front, %s back, %s" % [t, str(m["frame"]["style"]),
			float(m["dims_mm"]["t"]), str(m["glass"]), str(m["backsheet"]["back"]), str(m["cells"]["tech"])])
		_ok(str(m["type"]) == str(t), "Type %s took" % t)
		var hh := float(m["dims_mm"]["h"]) * 0.001
		ui.call("studio_view", Vector3(0, 1.0, 0), 0.45, 0.3, maxf(hh * 1.5, 1.2))
		await _settle(tree, 6)
		vp.get_texture().get_image().save_png("%s/type_%s.png" % [dir, t])
		# The back too (junction boxes, a clear rear's cell backs).
		ui.set("_show_back", true)
		ui.call("_rebuild_studio")
		await _settle(tree, 6)
		vp.get_texture().get_image().save_png("%s/type_%s_back.png" % [dir, t])
		ui.set("_show_back", false)
		ui.call("_rebuild_studio")
	var flex: Dictionary = (ui.call("spec") as Dictionary)["module"]
	_ok(true, "types shot")
	# Back to the rigid JA module for the face shots.
	ui.call("load_builtin", "backyard_2x4")
	await _settle(tree, 8)
	ui.call("set_tab", 1)
	await _settle(tree, 8)
	var m2: Dictionary = (ui.call("spec") as Dictionary)["module"]
	var h := float(m2["dims_mm"]["h"]) * 0.001
	var w := float(m2["dims_mm"]["w"]) * 0.001
	# The studio holds the module at (0, 1, 0) tilted 65°; look at it from in
	# front at medium distances, then at its frame's corner.
	for dist in [1.2, 2.5, 4.0, 7.0]:
		ui.call("studio_view", Vector3(0, 1.0, 0), 0.0, 0.55, dist)
		await _settle(tree, 6)
		vp.get_texture().get_image().save_png("%s/face_%dcm.png" % [dir, int(dist * 100.0)])
	var corner := Vector3(0, 1.0, 0) + Basis(Vector3.RIGHT, deg_to_rad(65.0)) * Vector3(w * 0.5, 0.0175, -h * 0.5)
	ui.call("studio_view", corner, 0.35, 0.75, 0.22)
	await _settle(tree, 6)
	vp.get_texture().get_image().save_png("%s/frame_corner.png" % dir)
	ui.call("set_tab", 0)
	await _settle(tree, 8)
	vp.get_texture().get_image().save_png("%s/cell_close.png" % dir)


func _check_search(ui: Control, tree: SceneTree) -> void:
	var se := ui.get("_search_edit") as LineEdit
	_ok(se != null, "the list has a search box")
	if se == null:
		return
	se.text = "jinko neo"
	se.text_changed.emit(se.text)
	await _settle(tree, 4)
	var lst := ui.get("_list") as ItemList
	var hits: Array = []
	for i in lst.item_count:
		if not lst.is_item_disabled(i):
			hits.append(i)
	_ok(hits.size() == 1, "searching 'jinko neo' lists one panel (%d)" % hits.size())
	if not hits.is_empty():
		lst.select(int(hits[0]))
		lst.item_selected.emit(int(hits[0]))
		await _settle(tree, 10)
		var m: Dictionary = (ui.call("spec") as Dictionary)["module"]
		var e := PvLabModule.electrical(m)
		print("pvlab: picked %s — %.0f W, Voc %.2f, %s %s cells %s" % [str(m["name"]), float(e["wmp"]), float(e["voc"]),
			str(m["cells"]["format"]), str(m["cells"]["tech"]), str(m["frame"]["style"])])
		_ok(str(m["name"]).contains("Tiger Neo") and is_equal_approx(float(e["wmp"]), 420.0),
			"the search result is the Tiger Neo 420 W with its data sheet")
	se.text = ""
	se.text_changed.emit("")
	await _settle(tree, 2)


## Hide the modules, click a mid clamp with a REAL click: it is selected,
## the card names it, the BOM counts it.
func _check_parts(ui: Control, main: Node, tree: SceneTree, dir: String, vp: SubViewport) -> void:
	ui.call("load_builtin", "roof_flush_rail")
	await _settle(tree, 8)
	ui.call("set_tab", 2)
	await _settle(tree, 8)
	(ui.get("_modules_btn") as Button).button_pressed = false
	await _settle(tree, 8)
	var d: Dictionary = ui.call("design")
	var mi := -1
	for i in (d["parts"] as Array).size():
		if str(d["parts"][i]["type"]) == "mid_clamp":
			mi = i
			break
	_ok(mi >= 0, "the roof array has mid clamps")
	var pt: Dictionary = d["parts"][mi]
	var xf: Transform3D = pt["xf"]
	ui.call("studio_view", xf.origin + Vector3(0, 0.02, 0), 0.5, 0.7, 0.9)
	await _settle(tree, 8)
	var cont := ui.call("studio_container") as Control
	var sp: Vector2 = ui.call("part_screen_pos", mi)
	await HarnessInput.click(main.get_viewport(), cont.get_global_rect().position + sp)
	await _settle(tree, 8)
	var sel: Dictionary = ui.call("selection")
	var card := str(ui.call("part_card_text"))
	print("pvlab: clicked part %s — %s" % [str(sel), card.replace("\n", " | ")])
	_ok(str(sel["kind"]) == "part" and str(d["parts"][int(sel["index"])]["type"]) in ["mid_clamp", "end_clamp"],
		"a real click on a clamp selects it")
	_ok(card.contains("clamp"), "the card names the clamp")
	vp.get_texture().get_image().save_png("%s/part_clamp.png" % dir)
	for b in [["roof_flush_rail", "rack_roof"], ["backyard_2x4", "rack_lumber"], ["unistrut_ground", "rack_unistrut"],
			["tracker_1p", "rack_tracker"], ["ballast_flat", "rack_ballast"], ["pole_100", "rack_pole"]]:
		ui.call("load_builtin", str(b[0]))
		await _settle(tree, 8)
		var dd: Dictionary = ui.call("design")
		var pc := PvLabHardware.counts(dd["parts"])
		print("pvlab: %s parts — %s" % [str(b[0]), str(pc)])
		_ok(not pc.is_empty(), "%s is drawn down to the part" % str(b[0]))
		var fp: Rect2 = dd["layout"]["footprint"]
		var aim := Vector3(fp.position.x + 0.4, 0.5, fp.end.y)
		if str(b[0]) == "tracker_1p":
			var hd: Dictionary = (dd["layout"]["heads"] as Array)[0]
			aim = (hd["pos"] as Vector3) + Vector3(0, -0.2, 0)
		ui.call("studio_view", aim, 0.7, 0.35, 3.0)
		await _settle(tree, 8)
		vp.get_texture().get_image().save_png("%s/%s.png" % [dir, str(b[1])])
	(ui.get("_modules_btn") as Button).button_pressed = true
	await _settle(tree, 4)
