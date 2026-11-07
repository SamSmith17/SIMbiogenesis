extends RefCounted

## The tri-clamp designer on a real world (sandbox; writes nothing to the
## player's world):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/tclab_designer_check.gd -Label tclab
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/tclab_designer_check.gd -Label tclab_720 -UserArgs @("--window-size=1280x720")
## Opens it through Main, loads every built-in (no error checks, a studio
## shot each), audits the open modal (and the 720 fold), then with REAL
## input: New, a size chip, a palette tool, a click on the floor (a free
## part), a spool snapped onto the elbow's open end, a tee joined by its
## OTHER end after Tab, R rolling the selected part's joint, a 2" spool
## refused on a 1½" face, Delete + Ctrl+Z, a drag that moves a whole group
## and a drag that pulls a part off its joint, a save to the library and a
## forget, the files exported and the GLB read back.

var _fails: Array = []
var _dir := ""


func _ok(cond: bool, what: String) -> void:
	print("tclab %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func _shot(main: Node, name: String) -> void:
	await RenderingServer.frame_post_draw
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [_dir, name])


func _screen(ui: Control, cpos: Vector2) -> Vector2:
	var studio: StudioViewport = ui.call("studio")
	return studio.container.get_global_rect().position + cpos


## Scroll a button inside its ScrollContainer so a real click lands on it.
func _reveal(btn: Control, tree: SceneTree) -> void:
	var n: Node = btn.get_parent()
	while n != null and not (n is ScrollContainer):
		n = n.get_parent()
	if n != null:
		(n as ScrollContainer).ensure_control_visible(btn)
	await tree.process_frame
	await tree.process_frame


func _parts(ui: Control) -> int:
	return ((ui.call("spec") as Dictionary)["parts"] as Array).size()


func _joints(ui: Control) -> int:
	return ((ui.call("spec") as Dictionary)["joints"] as Array).size()


func _open_of(ui: Control, part: String) -> Array:
	var out: Array = []
	for op in (ui.call("design") as Dictionary)["res"]["open"]:
		if str(op["part"]) == part:
			out.append(str(op["ref"]))
	return out


func _part_of_type(ui: Control, type: String) -> String:
	var res: Dictionary = (ui.call("design") as Dictionary)["res"]
	for id in res["order"]:
		if str(res["parts"][id]["built"]["type"]) == type:
			return str(id)
	return ""


func _nozzles(ui: Control, vid: String) -> Array:
	var p := TcSpec.part_of(ui.call("spec"), vid)
	return (TcVessel.resolve(p.get("params", {}))["ports"] as Array) if not p.is_empty() else []


## Phases 4–6 with real input: a vessel off the palette, a nozzle added from
## its card and dragged round the shell, the cutaway, a valve on a nozzle and
## an actuator on its stem, then the biochar reactor preset.
func _vessel_phase(main: Node, ui: Control, vp: Viewport, tree: SceneTree, ds: DesignerShell) -> void:
	ui.call("_on_new")
	await _settle(tree, 4)
	var vbtn := ui.find_child("tool_vessel", true, false) as Button
	if ds != null and ds.is_folded():
		ds.show_left_popup()
		await _settle(tree, 3)
	if vbtn != null and vbtn.is_visible_in_tree():
		await _reveal(vbtn, tree)
		await HarnessInput.click(vp, HarnessInput.center_of(vbtn))
	else:
		ui.call("arm_tool", "vessel", "2")
	await _settle(tree, 3)
	if ds != null and ds.is_folded():
		ds.hide_left_popup()
		await _settle(tree, 2)
	_ok(str(ui.call("tool_id")) == "vessel", "the palette arms the vessel")
	var studio: StudioViewport = ui.call("studio")
	var floor_pt := _screen(ui, studio.container.size * Vector2(0.5, 0.62))
	await HarnessInput.mouse_move(vp, floor_pt)
	await _settle(tree, 2)
	await HarnessInput.click(vp, floor_pt)
	await _settle(tree, 6)
	var vid := _part_of_type(ui, "vessel")
	_ok(not vid.is_empty(), "a click on the floor places a vessel")
	if vid.is_empty():
		return
	ui.call("_frame")
	await _settle(tree, 4)
	# Select it with a real click on its body.
	await HarnessInput.click(vp, _screen(ui, ui.call("part_pos", vid)))
	await _settle(tree, 4)
	var sel: Dictionary = ui.call("selected")
	_ok(str(sel.get("kind", "")) == "part" and str(sel.get("id", "")) == vid, "a click on the vessel selects it (%s)" % str(sel))
	var n0 := _nozzles(ui, vid).size()
	var add_btn := ui.find_child("add_nozzle_tc", true, false) as Button
	if add_btn != null and add_btn.is_visible_in_tree():
		await _reveal(add_btn, tree)
		await HarnessInput.click(vp, HarnessInput.center_of(add_btn))
	await _settle(tree, 5)
	var noz := _nozzles(ui, vid)
	_ok(noz.size() == n0 + 1, "+ Clamp nozzle adds a nozzle (%d → %d)" % [n0, noz.size()])
	await _shot(main, "vessel_nozzle_added")
	if noz.size() == n0 + 1:
		var q: Dictionary = noz[noz.size() - 1]
		var nid := str(q["id"])
		var ref := "%s:%s" % [vid, nid]
		var a0 := float(q["angle_deg"])
		# Drag the nozzle's face to a point on the shell 70° round.
		var pd: Dictionary = (ui.call("design") as Dictionary)["res"]["parts"][vid]
		var vpar: Dictionary = TcVessel.resolve(TcSpec.part_of(ui.call("spec"), vid)["params"])
		var want := deg_to_rad(a0 + 70.0)
		var ty := float(q["h_mm"]) + 60.0
		var rr := TcVessel.r_eff(vpar, ty)
		var tgt_local := Vector3(sin(want) * rr, ty, cos(want) * rr)
		var from := _screen(ui, ui.call("port_pos", ref))
		var to := _screen(ui, ui.call("studio_pos_of", (pd["xf"] as Transform3D) * tgt_local))
		await HarnessInput.drag(vp, from, to, 18)
		await _settle(tree, 6)
		var moved: Dictionary = {}
		for q2 in _nozzles(ui, vid):
			if str(q2["id"]) == nid:
				moved = q2
		var da := absf(wrapf(float(moved.get("angle_deg", a0)) - a0, -180.0, 180.0))
		_ok(da > 20.0, "dragging the nozzle moves it round the shell (%.0f° → %.0f°)" % [a0, float(moved.get("angle_deg", a0))])
		_ok(str((ui.call("selected") as Dictionary).get("kind", "")) == "nozzle", "and selects it")
		await _shot(main, "vessel_nozzle_dragged")
		# A ball valve on that nozzle, then an actuator on its stem.
		ui.call("arm_tool", "ball_valve", str(q["size"]))
		var at := _screen(ui, ui.call("port_pos", ref))
		await HarnessInput.mouse_move(vp, at)
		await _settle(tree, 3)
		await HarnessInput.click(vp, at)
		await _settle(tree, 6)
		var valve := _part_of_type(ui, "ball_valve")
		_ok(not valve.is_empty() and _joints(ui) >= 1, "a ball valve clamps onto the nozzle")
		if not valve.is_empty():
			# Take the handle off so the stem is free for an actuator.
			ui.call("_set_spec", TcAssembly.set_part(ui.call("spec"), valve, {"params": {"manual": false}}))
			await _settle(tree, 4)
			ui.call("_frame")
			await _settle(tree, 3)
			ui.call("arm_tool", "actuator_pneumatic", str(q["size"]))
			var st := _screen(ui, ui.call("port_pos", valve + ":stem"))
			await HarnessInput.mouse_move(vp, st)
			await _settle(tree, 3)
			_ok(str(ui.call("snap_target")) == valve + ":stem", "the actuator's ghost snaps to the valve stem (%s)" % str(ui.call("snap_target")))
			await HarnessInput.click(vp, st)
			await _settle(tree, 6)
			var act := _part_of_type(ui, "actuator_pneumatic")
			var d: Dictionary = ui.call("design")
			_ok(not act.is_empty() and (d["clashes"] as Array).is_empty(), "the actuator mounts on the stem without a clash")
			await _shot(main, "vessel_valve_actuator")
	# Cutaway.
	var cut := ui.find_child("cutaway", true, false) as CheckBox
	if cut != null and cut.is_visible_in_tree():
		await HarnessInput.click(vp, HarnessInput.center_of(cut))
		await _settle(tree, 4)
	_ok(bool(ui.get("_cutaway")), "the Cutaway box cuts the vessels open")
	await _shot(main, "vessel_cutaway")
	# The biochar reactor.
	ui.call("load_builtin", "biochar_reactor")
	await _settle(tree, 8)
	var dr: Dictionary = ui.call("design")
	var closing: Array = dr["res"]["closing"]
	_ok(closing.size() == 1 and float(dr["res"]["joints"][int(closing[0])]["err_mm"]) < 0.1, "the reactor's condenser loop closes in the designer")
	_ok((dr["clashes"] as Array).is_empty(), "the reactor has no clash")
	await _shot(main, "reactor_cutaway")
	if cut != null and cut.is_visible_in_tree():
		await HarnessInput.click(vp, HarnessInput.center_of(cut))
		await _settle(tree, 4)
	await _shot(main, "reactor")


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	_dir = "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(_dir)
	var lib_before := FileAccess.get_file_as_string(TcPresets.LIBRARY_PATH) if FileAccess.file_exists(TcPresets.LIBRARY_PATH) else ""
	_ok(main.has_method("open_tclab"), "Main hosts the designer")
	var ui: Control = main.call("open_tclab", {})
	await _settle(tree, 20)
	_ok(ui != null and bool(ui.call("is_open")), "the designer opened")
	if ui == null:
		return {"ok": false}
	var vp := main.get_viewport()
	var studio: StudioViewport = ui.call("studio")

	# Every built-in.
	for b in TcPresets.builtins():
		var id := str((b as Dictionary)["id"])
		ui.call("load_builtin", id)
		await _settle(tree, 8)
		var d: Dictionary = ui.call("design")
		var errs := (d["checks"] as Array).filter(func(c): return str(c["level"]) == "error")
		_ok(errs.is_empty(), "%s solves without an error" % id)
		var nodes := 0
		var holder := studio.holder.get_node_or_null("Assembly")
		if holder != null:
			nodes = holder.get_child_count()
		_ok(nodes >= (d["res"]["order"] as Array).size(), "%s is drawn (%d nodes)" % [id, nodes])
		await RenderingServer.frame_post_draw
		studio.image().save_png("%s/studio_%s.png" % [_dir, id])
	await _shot(main, "modal")
	var audit := UiAudit.run(vp)
	print("tclab: ui audit — %s" % UiAudit.summary_line(audit))
	_ok(int(audit.get("errors", 0)) == 0, "the open modal audits clean")
	var ds: DesignerShell = null
	for c in ui.get_children():
		if c is DesignerShell:
			ds = c
	var canvas := vp.get_visible_rect().size
	if ds != null:
		_ok(ds.is_folded() == (canvas.x < DesignerShell.FOLD_W),
			"the left column is %s on a %d px canvas" % ["folded" if ds.is_folded() else "a column", int(canvas.x)])
		if ds.is_folded():
			ds.show_left_popup()
			await _settle(tree, 4)
			await _shot(main, "left_flyout")

	# REAL input from here on. New sandbox.
	var new_btn := HarnessInput.find_button(ui, "New")
	_ok(new_btn != null, "the New button is there")
	if new_btn != null and new_btn.is_visible_in_tree():
		await _reveal(new_btn, tree)
		await HarnessInput.click(vp, HarnessInput.center_of(new_btn))
	else:
		ui.call("_on_new")
	await _settle(tree, 4)
	_ok(_parts(ui) == 0, "New empties the sandbox")
	# Size 1½" and the elbow tool, by their buttons.
	var size_btn := ui.find_child("size_1_5", true, false) as Button
	var elbow_btn := ui.find_child("tool_elbow90", true, false) as Button
	if ds != null and ds.is_folded():
		ds.show_left_popup()
		await _settle(tree, 3)
	if size_btn != null and size_btn.is_visible_in_tree():
		await _reveal(size_btn, tree)
		await HarnessInput.click(vp, HarnessInput.center_of(size_btn))
	if elbow_btn != null and elbow_btn.is_visible_in_tree():
		await _reveal(elbow_btn, tree)
		await HarnessInput.click(vp, HarnessInput.center_of(elbow_btn))
	else:
		ui.call("arm_tool", "elbow90", "1.5")
	await _settle(tree, 3)
	if ds != null and ds.is_folded():
		ds.hide_left_popup()
		await _settle(tree, 2)
	_ok(str(ui.call("tool_id")) == "elbow90", "clicking the palette arms the 90° elbow")
	var floor_pt := _screen(ui, studio.container.size * Vector2(0.5, 0.62))
	await HarnessInput.mouse_move(vp, floor_pt)
	await _settle(tree, 2)
	await HarnessInput.click(vp, floor_pt)
	await _settle(tree, 6)
	_ok(_parts(ui) == 1 and _joints(ui) == 0, "a click on the floor places a free elbow (%d parts)" % _parts(ui))
	_ok(str(ui.call("tool_id")).is_empty(), "the tool disarms after one placement")
	var elbow_id := str(((ui.call("spec") as Dictionary)["parts"][0] as Dictionary)["id"])
	var bot := (ui.call("design") as Dictionary)["stats"]["bounds_mm"] as AABB
	_ok(absf(bot.position.y) < 1.0, "it stands on the floor (lowest point %.1f mm)" % bot.position.y)
	ui.call("_frame")
	await _settle(tree, 3)

	# A spool snapped onto the elbow's upper end.
	ui.call("arm_tool", "spool", "1.5")
	var opens := _open_of(ui, elbow_id)
	var target: String = str(opens[0]) if not opens.is_empty() else ""
	# The higher open end is the easier one to see.
	var best_y := -INF
	for op in (ui.call("design") as Dictionary)["res"]["open"]:
		var y := ((op["xf"] as Transform3D).origin).y
		if str(op["part"]) == elbow_id and y > best_y:
			best_y = y
			target = str(op["ref"])
	var at := _screen(ui, ui.call("port_pos", target))
	await HarnessInput.mouse_move(vp, at)
	await _settle(tree, 3)
	_ok(str(ui.call("snap_target")) == target, "hovering the elbow's end snaps the ghost to it (%s)" % str(ui.call("snap_target")))
	await _shot(main, "ghost_snapped")
	await HarnessInput.click(vp, at)
	await _settle(tree, 6)
	_ok(_parts(ui) == 2 and _joints(ui) == 1, "a click joins a spool onto it")
	var spool_id := str(((ui.call("spec") as Dictionary)["parts"][1] as Dictionary)["id"])
	ui.call("_frame")
	await _settle(tree, 3)

	# A tee joined by its OTHER run end after Tab.
	ui.call("arm_tool", "tee", "1.5")
	var sp_open := _open_of(ui, spool_id)
	var at2 := _screen(ui, ui.call("port_pos", sp_open[0] if not sp_open.is_empty() else ""))
	await HarnessInput.mouse_move(vp, at2)
	await _settle(tree, 2)
	await HarnessInput.key(vp, KEY_TAB)
	await _settle(tree, 2)
	await HarnessInput.click(vp, at2)
	await _settle(tree, 6)
	var joints: Array = (ui.call("spec") as Dictionary)["joints"]
	var last: Dictionary = joints[joints.size() - 1] if not joints.is_empty() else {}
	_ok(_parts(ui) == 3 and str(last.get("b", "")).ends_with(":b"), "Tab joins the tee by its second end (%s)" % str(last.get("b", "")))
	var tee_id := str(last.get("b", ":")).get_slice(":", 0)
	ui.call("_frame")
	await _settle(tree, 3)
	await _shot(main, "three_parts")

	# Select the tee with a real click, R rolls its joint.
	var tee_at := _screen(ui, ui.call("part_pos", tee_id))
	await HarnessInput.click(vp, tee_at)
	await _settle(tree, 4)
	var sel: Dictionary = ui.call("selected")
	_ok(str(sel.get("kind", "")) == "part" and str(sel.get("id", "")) == tee_id, "a click selects the tee (%s)" % str(sel))
	await HarnessInput.key(vp, KEY_R)
	await _settle(tree, 4)
	var j2: Array = (ui.call("spec") as Dictionary)["joints"]
	_ok(absf(float((j2[j2.size() - 1] as Dictionary)["roll_deg"]) - 15.0) < 0.01, "R rolls the tee's joint 15°")
	await _shot(main, "tee_rolled")

	# A 2" spool cannot join a 1½" face.
	ui.call("arm_tool", "spool", "2")
	var tee_open := _open_of(ui, tee_id)
	var at3 := _screen(ui, ui.call("port_pos", tee_open[0] if not tee_open.is_empty() else ""))
	await HarnessInput.mouse_move(vp, at3)
	await _settle(tree, 2)
	await HarnessInput.click(vp, at3)
	await _settle(tree, 4)
	_ok(_parts(ui) == 3 and str(ui.call("status_text")).begins_with("Can't join"),
		"a 2\" spool is refused on a 1½\" face (%s)" % str(ui.call("status_text")))
	await HarnessInput.key(vp, KEY_ESCAPE)
	await _settle(tree, 2)
	_ok(str(ui.call("tool_id")).is_empty(), "Esc puts the tool down")

	# Delete + undo.
	tee_at = _screen(ui, ui.call("part_pos", tee_id))
	await HarnessInput.click(vp, tee_at)
	await _settle(tree, 3)
	await HarnessInput.key(vp, KEY_DELETE)
	await _settle(tree, 4)
	_ok(_parts(ui) == 2, "Delete removes the selected tee")
	await HarnessInput.key(vp, KEY_Z, true)
	await _settle(tree, 4)
	_ok(_parts(ui) == 3 and _joints(ui) == 2, "Ctrl+Z brings it back")

	# Drag the elbow (the root): the whole group moves.
	var d0: Dictionary = ui.call("design")
	var tee0: Vector3 = (d0["res"]["parts"][tee_id]["xf"] as Transform3D).origin
	var e_at := _screen(ui, ui.call("part_pos", elbow_id))
	await HarnessInput.drag(vp, e_at, e_at + Vector2(90, 30), 14)
	await _settle(tree, 6)
	var d1: Dictionary = ui.call("design")
	var tee1: Vector3 = (d1["res"]["parts"][tee_id]["xf"] as Transform3D).origin
	_ok(tee1.distance_to(tee0) > 20.0 and _joints(ui) == 2, "dragging the elbow moves its whole run (%.0f mm)" % tee1.distance_to(tee0))
	# Drag the tee off its joint onto the floor.
	tee_at = _screen(ui, ui.call("part_pos", tee_id))
	await HarnessInput.drag(vp, tee_at, _screen(ui, studio.container.size * Vector2(0.85, 0.25)), 16)
	await _settle(tree, 6)
	var res2: Dictionary = (ui.call("design") as Dictionary)["res"]
	_ok(_joints(ui) == 1 and (res2["comps"] as Array).size() == 2, "dragging the tee pulls it off its joint (%d joints)" % _joints(ui))
	await _shot(main, "tee_pulled_off")
	# And back on: drag it by its joined end onto the spool's open end.
	var sp_open2 := _open_of(ui, spool_id)
	if not sp_open2.is_empty():
		tee_at = _screen(ui, ui.call("part_pos", tee_id))
		var drop := _screen(ui, ui.call("port_pos", sp_open2[0]))
		await HarnessInput.drag(vp, tee_at, drop, 16)
		await _settle(tree, 6)
		_ok(_joints(ui) == 2, "dropping it on the spool's end joins it again (%d joints)" % _joints(ui))

	await _vessel_phase(main, ui, vp, tree, ds)

	# Library: save, list, forget.
	if ds != null and ds.name_edit != null:
		ds.name_edit.text = "Harness run"
	var save_btn := HarnessInput.find_button(ui, "Save design")
	if ds != null and ds.is_folded():
		ds.show_left_popup()
		await _settle(tree, 3)
	if save_btn != null and save_btn.is_visible_in_tree():
		await _reveal(save_btn, tree)
		await HarnessInput.click(vp, HarnessInput.center_of(save_btn))
	else:
		ui.call("_on_save_design")
	await _settle(tree, 3)
	var names: Array = TcPresets.load_library().map(func(e): return str(e["name"]))
	_ok("Harness run" in names, "Save design keeps it in the library")
	TcPresets.forget_design("Harness run")
	if ds != null and ds.is_folded():
		ds.hide_left_popup()
		await _settle(tree, 2)

	# Files.
	var exp_btn := HarnessInput.find_button(ui, "Export files")
	if exp_btn != null and exp_btn.is_visible_in_tree():
		await HarnessInput.click(vp, HarnessInput.center_of(exp_btn))
	else:
		ui.call("_on_export")
	await _settle(tree, 4)
	_ok(str(ui.call("status_text")).begins_with("Wrote 4 files"), "Export writes four files (%s)" % str(ui.call("status_text")))
	var dir := TcExport.folder_for(str((ui.call("spec") as Dictionary)["name"]))
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	_ok(doc.append_from_file("%s/%s.glb" % [dir, dir.get_file()], st) == OK and st.get_meshes().size() >= 1, "the GLB reads back")
	await _shot(main, "final")
	var audit2 := UiAudit.run(vp)
	print("tclab: ui audit (after edits) — %s" % UiAudit.summary_line(audit2))
	_ok(int(audit2.get("errors", 0)) == 0, "the modal still audits clean")

	ui.call("close")
	await _settle(tree, 3)
	_ok(not bool(ui.call("is_open")), "it closes")
	if lib_before.is_empty():
		DirAccess.remove_absolute(TcPresets.LIBRARY_PATH)
	print("tclab: %d failures" % _fails.size())
	return {"ok": _fails.is_empty(), "failures": _fails}
