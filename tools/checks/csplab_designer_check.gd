extends RefCounted

## The solar concentrator designer on a REAL world (sandbox; writes nothing
## to the player's world):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/csplab_designer_check.gd -Label csplab
## Opens the designer through Main, shoots every built-in in the 3D studio
## with its rays at the site's sun, runs UiAudit, switches every type through
## its own buttons, shoots the 2D section (rays landing), the structure view
## and a site year, plays the sun across the day (the tracker turns), runs
## the optimizer (a too-big receiver shrinks and the heat rises), then places
## a dish and a trough through the graph's own placement (graph node role
## csplab bound, CspLabRuntime turning it, heat at noon from the direct beam).
## Shots under screenshots\<label>\.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("csplab %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func _shoot(main: Node, path: String) -> void:
	main.get_viewport().get_texture().get_image().save_png(path)


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var dir := "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(dir)
	_ok(main.has_method("open_csplab"), "Main hosts the designer")
	var ui: Control = main.call("open_csplab", {})
	await _settle(tree, 20)
	_ok(ui != null and ui.visible and bool(ui.call("is_open")), "the designer opened")
	if ui == null:
		return {"ok": false, "fails": _fails}
	var studio: StudioViewport = ui.call("studio")
	ui.call("set_moment", 6, 21, 12.5)
	for p in CspLabPresets.builtins():
		var id := str((p as Dictionary)["id"])
		ui.call("set_spec", (p as Dictionary)["spec"])
		# A fixed trough tilted to the latitude faces the equinox sun; at the
		# June solstice a narrow CPC rightly sees nothing (23° across it).
		var fixed := str(((p as Dictionary)["spec"]["tracking"] as Dictionary)["mode"]) == "fixed"
		ui.call("set_moment", 3 if fixed else 6, 20 if fixed else 21, 12.5)
		await _settle(tree, 14)
		var d: Dictionary = ui.call("design")
		var c := CspLabDesign.check_counts(d)
		var at: Dictionary = ui.call("at_sun")
		print("csplab: %s — optical %.1f %%, %.0f suns, %.2f kW useful, %d errors, %d warnings; at the sun captured %.2f" % [id,
			float(d["eta_opt"]) * 100.0, float(d["suns_mean"]), float(d["q_useful_kw"]), int(c["error"]), int(c["warn"]),
			float(at.get("captured", -1.0))])
		_ok(int(c["error"]) == 0, "%s solves without an error" % id)
		var b: CspLabBuilder = ui.call("builder")
		_ok(b != null and b.find_child("Receiver", true, false) != null, "%s drew its receiver" % id)
		_ok(float(at.get("captured", 0.0)) > 0.0, "%s catches the site's noon sun" % id)
		studio.viewport.get_texture().get_image().save_png("%s/studio_%s.png" % [dir, id])
	ui.call("set_spec", CspLabPresets.by_id("dish_cooker"))
	ui.call("set_moment", 6, 21, 12.5)
	await _settle(tree, 12)
	_shoot(main, "%s/modal.png" % dir)
	var audit := UiAudit.run(main.get_viewport())
	print("csplab: ui audit — %s" % UiAudit.summary_line(audit))
	_ok(int(audit.get("errors", 0)) == 0, "the open modal has no UI audit errors")
	# The type buttons: every type builds its settings rows.
	for t in CspLabSpec.TYPES:
		ui.call("_on_type_pressed", t)
		await _settle(tree, 6)
		_ok(str((ui.call("spec") as Dictionary)["type"]) == t, "the %s button switches the type" % t)
		var want := "focal_m" if t in ["lens", "fresnel_lens", "water_lens", "parabolic_trough", "parabolic_dish"] else "aperture_m"
		if t == "linear_fresnel":
			want = "rows"
		elif t == "tower":
			want = "heliostats"
		_ok(ui.call("control_for", "optic", want) != null, "%s shows its %s row" % [t, want])
	# The 2D section, the structure and the year on a trough.
	ui.call("set_spec", CspLabPresets.by_id("eurotrough"))
	await _settle(tree, 8)
	ui.call("set_tab", 1)
	await _settle(tree, 6)
	var sc: Vector2i = ui.call("section_counts")
	_ok(sc.y > 10 and sc.x > sc.y / 2, "the section's rays land on the tube (%d of %d)" % [sc.x, sc.y])
	_shoot(main, "%s/section_trough.png" % dir)
	# The compound parabolic trough (the string-and-square "W"): the section
	# with its acceptance lines, rays landing; a sun 20° across bounces back
	# out; the profile option rebuilds the rows; the 1:1 template.
	ui.call("set_spec", CspLabPresets.by_id("cpc_pipe"))
	await _settle(tree, 8)
	var sc2: Vector2i = ui.call("section_counts")
	_ok(sc2.y > 10 and sc2.x >= sc2.y * 0.9, "the CPC's section rays land on the pipe, bar the gap under it (%d of %d)" % [sc2.x, sc2.y])
	_shoot(main, "%s/section_cpc_pipe.png" % dir)
	_ok(ui.call("control_for", "optic", "accept_deg") != null and ui.call("control_for", "optic", "focal_m") == null,
		"a CPC shows its acceptance angle, not a focal length")
	var gcp: Dictionary = (ui.call("design") as Dictionary)["geo"]
	var off := CspLabOptics.trace_section(gcp, Vector3(sin(deg_to_rad(20.0)), cos(deg_to_rad(20.0)), 0.0), 28, {})
	var back := 0
	for pth in off:
		if str((pth as Dictionary)["fate"]) == "spill":
			back += 1
	_ok(back > 0, "a sun 20° across (outside ±15°) bounces some rays back out (%d of %d)" % [back, off.size()])
	var tpl := str(ui.call("export_template"))
	_ok(not tpl.is_empty() and FileAccess.file_exists(tpl), "the 1:1 profile template is written (%s)" % tpl.get_file())
	ui.call("set_tab", 0)
	ui.call("set_moment", 6, 21, 12.5)
	await _settle(tree, 10)
	_shoot(main, "%s/cpc_pipe_3d.png" % dir)
	ui.call("set_tab", 2)
	await _settle(tree, 6)
	_shoot(main, "%s/cpc_pipe_structure.png" % dir)
	ui.call("set_tab", 1)
	ui.call("set_spec", CspLabPresets.by_id("cpc_flat"))
	await _settle(tree, 6)
	_shoot(main, "%s/section_cpc_flat.png" % dir)
	var prof_opt := ui.call("control_for", "optic", "profile") as OptionButton
	_ok(prof_opt != null, "the trough's profile option")
	if prof_opt != null:
		for i in prof_opt.item_count:
			if str(prof_opt.get_item_metadata(i)) == "parabola":
				prof_opt.select(i)
				prof_opt.item_selected.emit(i)
		await _settle(tree, 20)
		_ok(CspLabSpec.profile_of(ui.call("spec") as Dictionary) == "parabola" and ui.call("control_for", "optic", "focal_m") != null,
			"switching the profile back to a parabola brings its focal length row")
	ui.call("set_spec", CspLabPresets.by_id("fresnel_cooker"))
	await _settle(tree, 4)
	(ui.get("_sec_bands") as CheckBox).button_pressed = true
	await _settle(tree, 6)
	_shoot(main, "%s/section_fresnel_wavelengths.png" % dir)
	ui.call("set_spec", CspLabPresets.by_id("tower_poleward"))
	await _settle(tree, 6)
	_shoot(main, "%s/section_tower.png" % dir)
	ui.call("set_tab", 2)
	ui.call("set_spec", CspLabPresets.by_id("stirling_dish"))
	ui.call("set_moment", 6, 21, 9.0)
	await _settle(tree, 10)
	var b2: CspLabBuilder = ui.call("builder")
	var stage := b2.find_child("Stage", true, false) as Node3D
	var basis_am: Basis = stage.basis if stage != null else Basis.IDENTITY
	_shoot(main, "%s/structure_dish_morning.png" % dir)
	ui.call("set_moment", 6, 21, 16.0)
	await _settle(tree, 10)
	_ok(stage != null and not stage.basis.is_equal_approx(basis_am), "the dish turns from morning to afternoon")
	_ok(b2.find_child("Axes", true, false).get_child_count() > 0, "the structure view shows the tracking axes")
	_shoot(main, "%s/structure_dish_afternoon.png" % dir)
	ui.call("set_spec", CspLabPresets.by_id("eurotrough"))
	ui.call("set_moment", 6, 21, 10.0)
	await _settle(tree, 10)
	_shoot(main, "%s/structure_trough.png" % dir)
	# Polish pass: every mount's structure, the member under the pointer
	# named, the headline tiles, month names, the sun marker, the section's
	# zoom, the CPC credit.
	for sid in ["glass_lens", "water_lens", "cpc_pipe", "lfr_small", "tower_poleward", "stirling_dish"]:
		ui.call("set_spec", CspLabPresets.by_id(sid))
		ui.call("set_moment", 6, 21, 10.0)
		await _settle(tree, 10)
		var stc: Dictionary = (ui.call("design") as Dictionary)["structure"]
		_ok(float(stc.get("concrete_kg", 0.0)) > 0.0, "%s stands on concrete footings" % sid)
		_shoot(main, "%s/structure_%s.png" % [dir, sid])
	var b4: CspLabBuilder = ui.call("builder")
	var post: Dictionary = {}
	for mv in ((ui.call("design") as Dictionary)["structure"]["members"] as Array):
		if str((mv as Dictionary).get("label", "")) == "Pedestal post":
			post = mv
	var base_n := b4.find_child("Base", true, false) as Node3D
	if not post.is_empty() and base_n != null:
		var mid: Vector3 = base_n.global_transform * (((post["a"] as Vector3) + (post["b"] as Vector3)) * 0.4)
		var vp_px := studio.camera.unproject_position(mid)
		var cs := studio.container.size
		var vs := Vector2(studio.viewport.size)
		var cpos := vp_px * (cs / vs)
		studio.hovered.emit(cpos)
		await _settle(tree, 4)
		var ml: Label = ui.get("_member_lbl")
		print("csplab: hover over the post reads \"%s\"" % ml.text)
		_ok(ml.visible and not ml.text.is_empty() and b4.find_child("Highlight", true, false) != null,
			"pointing at a member names it and lights it (%s)" % ml.text)
		_shoot(main, "%s/structure_hover.png" % dir)
	_ok(int(((ui.call("design") as Dictionary)["structure"] as Dictionary).get("counterweight_kg", 0.0)) > 0, "the Stirling dish carries counterweights")
	var kpi: Dictionary = ui.get("_kpi")
	_ok((kpi["heat"] as Label).text != "—" and (kpi["suns"] as Label).text.ends_with("suns"), "the headline tiles are filled (%s, %s)" % [(kpi["heat"] as Label).text, (kpi["suns"] as Label).text])
	_ok((ui.get("_month_opt") as OptionButton).selected == 5 and (ui.get("_month_opt") as OptionButton).get_item_text(5) == "Jun", "the month reads as a name")
	ui.call("set_tab", 0)
	await _settle(tree, 4)
	var sm := b4.find_child("SunMarker", true, false)
	_ok(sm != null and sm.get_child_count() > 0, "the 3D view marks the sun")
	_ok(not (ui.get("_cpc_credit") as Control).visible, "the CPC credit hides for a dish")
	ui.call("set_spec", CspLabPresets.by_id("cpc_pipe"))
	await _settle(tree, 4)
	_ok((ui.get("_cpc_credit") as Control).visible, "a CPC credits NightHawkInLight with the video")
	ui.call("set_tab", 1)
	await _settle(tree, 4)
	var sec: Control = ui.get("_section")
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	wheel.position = sec.size * 0.5
	for _k in 4:
		sec.call("_gui_input", wheel)
	await _settle(tree, 3)
	_ok(float(sec.get("zoom")) > 1.5, "the wheel zooms the section (×%.2f)" % float(sec.get("zoom")))
	_shoot(main, "%s/section_zoomed.png" % dir)
	sec.call("reset_view")
	ui.call("set_tab", 2)
	ui.call("set_tab", 3)
	ui.call("set_spec", CspLabPresets.by_id("dish_cooker"))
	await _settle(tree, 4)
	var yr: Dictionary = ui.call("run_year_now")
	await _settle(tree, 6)
	print("csplab: year — %.0f kWh heat, DNI %.0f kWh/m², GHI %.0f kWh/m², direct share %.0f %%" % [float(yr.get("annual_kwh", 0.0)),
		float(yr.get("annual_dni", 0.0)), float(yr.get("annual_ghi", 0.0)), float(yr.get("direct_share", 0.0)) * 100.0])
	_ok(float(yr.get("annual_kwh", 0.0)) > 0.0, "the site year makes heat")
	_ok(float(yr.get("annual_dni", 0.0)) < float(yr.get("annual_ghi", 0.0)) * 1.6, "direct and global light both counted")
	_shoot(main, "%s/year_dish.png" % dir)
	# Optimize: a dish with a far-too-big receiver at 400 °C.
	ui.call("set_tab", 0)
	var big := CspLabPresets.by_id("dish_cooker")
	(big["receiver"] as Dictionary)["size_m"] = 0.6
	(big["site"] as Dictionary)["op_temp_c"] = 400.0
	ui.call("set_spec", big)
	await _settle(tree, 6)
	var before := float((ui.call("design") as Dictionary)["q_net_kw"])
	var res: Dictionary = ui.call("optimize_now")
	await _settle(tree, 6)
	var after := float((ui.call("design") as Dictionary)["q_net_kw"])
	print("csplab: optimize — %.2f → %.2f kW net (search %s)" % [before, after, str(res)])
	_ok(after > before, "the optimizer raises the net heat")
	_ok(float(((ui.call("spec") as Dictionary)["receiver"] as Dictionary)["size_m"]) < 0.6, "…by shrinking the receiver")
	_shoot(main, "%s/optimized.png" % dir)
	ui.call("close")
	await _settle(tree, 4)
	_ok(not ui.visible, "the designer closes")
	# --- Placed through the graph's own placement.
	var sgv := main.get_node_or_null("UILayer/SystemGraphView")
	var model: GraphModel = sgv.get("model") if sgv != null else null
	_ok(sgv != null and model != null, "the systems graph")
	if sgv == null:
		return {"ok": _fails.is_empty(), "fails": _fails}
	main.set("day_time", 12.5)
	main.set("time_scale", 1.0 / 3600.0)
	var player := ServiceLocator.player() as Node3D
	var at0 := player.global_position + Vector3(5.0, 0.0, -4.0) if player != null else Vector3(5.0, 0.0, -4.0)
	for pv in [["dish_cooker", Vector3.ZERO], ["diy_trough", Vector3(-7.0, 0.0, 3.0)]]:
		var id2 := str(pv[0])
		var before_ids := _prop_ids(main)
		var preset := ComponentPresets.designed_csp_preset(CspLabPresets.by_id(id2))
		_ok(not preset.is_empty(), "%s: the designed preset" % id2)
		sgv.call("_on_lib_place_model_requested", preset, "", at0 + (pv[1] as Vector3))
		var pid := _new_prop(main, before_ids)
		await _settle(tree, 90)
		_ok(not pid.is_empty(), "%s is placed (%s)" % [id2, pid])
		var rec := PlacedPropService.get_prop_record(main, pid)
		var gid := str(rec.get("graph_item_id", ""))
		var item := model.get_item(gid)
		var sp: Dictionary = item.get("specs", {}) as Dictionary
		_ok(str(sp.get("role", "")) == "csplab" and str(rec.get("kind", "")) == "csplab", "%s: a csplab graph node, bound" % id2)
		var prop := PlacedPropRuntime.find_by_prop_id(main, pid)
		_ok(prop != null and prop.get_node_or_null("CspLabRuntime") != null, "%s: CspLabRuntime turns it" % id2)
		var b3: CspLabBuilder = null
		if prop != null:
			for n in prop.find_children("*", "Node3D", true, false):
				if n is CspLabBuilder:
					b3 = n as CspLabBuilder
		_ok(b3 != null and bool(b3.last_pose.get("up", false)), "%s faces the noon sun" % id2)
		print("csplab: %s in the world — DNI %.0f W/m², %.3f kW, steam %.2f kg/h" % [id2, float(sp.get("dni_wm2", 0.0)),
			float(sp.get("thermal_output_kw", 0.0)), float(sp.get("steam_kg_h", 0.0))])
		# The world is saved on a clear October noon: the graph is closed, and
		# its concentrator tick must still have run (DNI read, heat made).
		_ok(float(sp.get("dni_wm2", 0.0)) > 0.0, "%s: the tick ran with the graph closed (DNI %.0f)" % [id2, float(sp.get("dni_wm2", 0.0))])
		_ok(float(sp.get("dni_wm2", 0.0)) <= 0.0 or float(sp.get("thermal_output_kw", 0.0)) > 0.0, "%s makes heat whenever there is direct sun" % id2)
		if prop != null:
			await _world_shot(main, tree, prop, Vector3(3.5, 2.4, 4.0), Vector3(0, 1.2, 0), "%s/world_%s.png" % [dir, id2])
	return {"ok": _fails.is_empty(), "fails": _fails}


func _prop_ids(main: Node) -> Dictionary:
	var out := {}
	var loader := main.find_child("TerrainLoader", true, false)
	if loader != null and loader.has_method("placed_prop_records"):
		for r in loader.call("placed_prop_records"):
			out[str((r as Dictionary).get("id", ""))] = true
	return out


func _new_prop(main: Node, before: Dictionary) -> String:
	var now := _prop_ids(main)
	for id in now:
		if not before.has(id):
			return str(id)
	return ""


func _world_shot(main: Node, tree: SceneTree, prop: Node3D, off: Vector3, look: Vector3, path: String) -> void:
	var cam := Camera3D.new()
	main.add_child(cam)
	var a: Vector3 = prop.global_position
	cam.look_at_from_position(a + off, a + look, Vector3.UP)
	main.call("push_camera_claim", "csplab_check", {"camera_id": cam.get_instance_id()})
	await _settle(tree, 30)
	_shoot(main, path)
	main.call("pop_camera_claim", "csplab_check")
	cam.queue_free()
