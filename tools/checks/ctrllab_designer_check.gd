extends RefCounted

## The Controller Lab on a REAL world (sandbox; writes nothing to the world):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/ctrllab_designer_check.gd -Label ctrllab
## Run it at 1080 and with -UserArgs @("--window-size=1280x720").
## Opens the designer through Main, clicks every built-in in the gallery,
## runs UiAudit, types a width and undoes it, adds a USB-C port from the
## connector flyout with a REAL click on the unit's front, drags it along the
## face, turns it with R, deletes it with Delete, takes the wiring bay's cover
## off and clicks the battery stud, saves to the library and forgets it again
## (the library file is restored).

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("ctrllab %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func _reveal(c: Control) -> void:
	var p := c.get_parent()
	while p != null:
		if p is Collapsible:
			(p as Collapsible).set_open(true)
		if p is ScrollContainer:
			(p as ScrollContainer).ensure_control_visible(c)
		p = p.get_parent()


func _left(ui: Control, tree: SceneTree) -> void:
	var shell: DesignerShell = ui.call("shell")
	if shell != null and shell.is_folded() and not shell.left_popup_shown():
		shell.show_left_popup()
		await _settle(tree, 4)


func _hide_left(ui: Control, tree: SceneTree) -> void:
	var shell: DesignerShell = ui.call("shell")
	if shell != null and shell.left_popup_shown():
		shell.hide_left_popup()
		await _settle(tree, 4)


## Where a point of the unit (local mm) is on the screen.
func _screen_of(studio: StudioViewport, b: CtrlBuilder, mm: Vector3) -> Vector2:
	var w := b.global_transform * (mm * CtrlBuilder.MM)
	var vpx := studio.camera.unproject_position(w)
	var cs := studio.container.size
	var vs := Vector2(studio.viewport.size)
	return studio.screen_pos(vpx * (cs / vs))


func _gallery_index(ui: Control, id: String) -> int:
	var entries: Array = ui.get("_entries")
	for i in entries.size():
		if str((entries[i] as Dictionary)["id"]) == id:
			return i
	return -1


func _click_design(ui: Control, tree: SceneTree, vp: Viewport, i: int) -> void:
	var gallery: DesignGallery = ui.call("gallery")
	await _left(ui, tree)
	var btn := gallery.row_button(i)
	for attempt in 3:
		_reveal(btn)
		await _settle(tree, 6)
		_reveal(btn)
		await _settle(tree, 2)
		await HarnessInput.click(vp, HarnessInput.center_of(btn))
		await _settle(tree, 10)
		if gallery.get_selected_items() == PackedInt32Array([i]):
			break
		var sc: Control = btn.get_parent()
		while sc != null and not (sc is ScrollContainer):
			sc = sc.get_parent()
		print("ctrllab: the click on row %d landed on %s; row %s, row before %s, scroll %s, hovered %s" % [i, str(gallery.get_selected_items()),
			str(btn.get_global_rect()), str(gallery.row_button(i - 1).get_global_rect()) if i > 0 else "",
			str(sc.get_global_rect()) if sc != null else "-", (vp.gui_get_hovered_control().get_path() if vp.gui_get_hovered_control() != null else "-")])
	await _hide_left(ui, tree)


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var vp := main.get_viewport()
	var dir := "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(dir)
	var lib_path := CtrlPresets.LIBRARY_FILE
	var lib_had := FileAccess.file_exists(lib_path)
	var lib_old := FileAccess.get_file_as_string(lib_path) if lib_had else ""
	# World toasts draw above every modal and take clicks: keep them out of the way.
	var toasts := main.get_node_or_null("UILayer/ToastUI")
	if toasts != null:
		toasts.set("visible", false)
	_ok(main.has_method("open_ctrllab"), "Main hosts the Controller Lab")
	var ui: Control = main.call("open_ctrllab", {})
	await _settle(tree, 20)
	_ok(ui != null and bool(ui.call("is_open")), "the Controller Lab opened")
	if ui == null:
		return {"ok": false, "fails": _fails}
	var studio: StudioViewport = ui.call("studio")
	# --- Every built-in through a REAL click on its gallery row.
	var entries: Array = ui.get("_entries")
	var loaded := 0
	var drawn := 0
	for i in entries.size():
		var e: Dictionary = entries[i]
		if not bool(e["builtin"]):
			continue
		await _click_design(ui, tree, vp, i)
		var s: Dictionary = ui.call("spec")
		if str(s["name"]) == str((e["spec"] as Dictionary)["name"]):
			loaded += 1
		else:
			print("ctrllab: %s did not load (shows %s)" % [e["id"], s["name"]])
		var b: CtrlBuilder = ui.call("builder")
		if b != null and b.get_node_or_null("Mesh") != null:
			drawn += 1
		if str(e["id"]) in ["victron_multiplus_12_3000", "victron_ss_100_30", "growatt_spf_5000es", "eg4_6000xp", "powmr_5000"]:
			studio.viewport.get_texture().get_image().save_png("%s/studio_%s.png" % [dir, e["id"]])
	var n_built := CtrlPresets.builtins().size()
	_ok(loaded == n_built, "a click on each of the %d built-ins loads it (%d)" % [n_built, loaded])
	_ok(drawn == n_built, "every built-in draws a body (%d)" % drawn)
	# The 6000XP for the rest.
	await _click_design(ui, tree, vp, _gallery_index(ui, "eg4_6000xp"))
	_ok(str((ui.call("spec") as Dictionary)["id"]) == "eg4_6000xp", "the 6000XP is loaded")
	main.get_viewport().get_texture().get_image().save_png("%s/modal.png" % dir)
	var audit := UiAudit.run(vp)
	print("ctrllab: ui audit — %s" % UiAudit.summary_line(audit))
	_ok(int(audit.get("errors", 0)) == 0, "the open modal has no UI audit errors")
	# --- Width typed into its spin box, then Ctrl+Z.
	var w0 := float((ui.call("spec") as Dictionary)["body"]["w"])
	var wrow := ui.find_child("body_w", true, false)
	var sb: SpinBox = (wrow as FormRow).control as SpinBox if wrow is FormRow else wrow as SpinBox
	_ok(sb != null, "the width spin box")
	if sb != null:
		_reveal(sb)
		await _settle(tree, 3)
		var le := sb.get_line_edit()
		await HarnessInput.click(vp, HarnessInput.center_of(le))
		await _settle(tree, 2)
		le.text = str(int(w0 + 60.0))
		le.text_submitted.emit(le.text)
		await _settle(tree, 14)
		var w1 := float((ui.call("spec") as Dictionary)["body"]["w"])
		_ok(absf(w1 - (w0 + 60.0)) < 0.5, "typing a width widens the unit (%.0f → %.0f mm)" % [w0, w1])
		vp.gui_release_focus()
		await HarnessInput.key(vp, KEY_Z, true)
		await _settle(tree, 10)
		var w2 := float((ui.call("spec") as Dictionary)["body"]["w"])
		_ok(absf(w2 - w0) < 0.5, "Ctrl+Z puts the width back (%.0f mm)" % w2)
	# --- Front view, then a USB-C port from the flyout onto the front.
	var front := ui.find_child("view_front", true, false) as Button
	await HarnessInput.click(vp, HarnessInput.center_of(front))
	await _settle(tree, 8)
	var n0 := ((ui.call("spec") as Dictionary)["ports"] as Array).size()
	var fly := ui.find_child("flyout_ports", true, false) as Button
	_ok(fly != null, "the Add port button")
	if fly != null:
		await HarnessInput.click(vp, HarnessInput.center_of(fly))
		await _settle(tree, 6)
		var shell: DesignerShell = ui.call("shell")
		_ok(shell.flyout_shown() == "ports", "Add port opens the connector kit")
		var cb := ui.find_child("conn_usb_c", true, false) as Button
		_reveal(cb)
		await _settle(tree, 3)
		await HarnessInput.click(vp, HarnessInput.center_of(cb))
		await _settle(tree, 6)
		_ok(str(ui.call("tool")) == "usb_c" and shell.flyout_shown() == "", "picking USB-C arms it and closes the kit")
		var d: Dictionary = ui.call("design")
		var b2: CtrlBuilder = ui.call("builder")
		var f: Dictionary = d["faces"]["front"]
		var size: Vector2 = f["size"]
		var target_mm: Vector3 = (f["xf"] as Transform3D) * Vector3(size.x * 0.3, size.y * 0.12, 0.0)
		var at := _screen_of(studio, b2, target_mm)
		await HarnessInput.mouse_move(vp, at)
		await _settle(tree, 4)
		await HarnessInput.click(vp, at)
		await _settle(tree, 10)
		var ps: Array = (ui.call("spec") as Dictionary)["ports"]
		var added: Dictionary = ps[ps.size() - 1] if ps.size() > n0 else {}
		_ok(ps.size() == n0 + 1 and str(added.get("connector", "")) == "usb_c" and str(added.get("face", "")) == "front",
			"a click on the front places a USB-C there (%d → %d ports)" % [n0, ps.size()])
		_ok(str(added.get("group", "")) == "usb" and str(ui.call("selected_port")) == str(added.get("id", "")),
			"it is selected and its job guessed (USB)")
		_ok(absf(float(added.get("u", 0)) - size.x * 0.3) < 15.0 and absf(float(added.get("v", 0)) - size.y * 0.12) < 15.0,
			"it lands where the click was (u %.0f v %.0f)" % [float(added.get("u", 0)), float(added.get("v", 0))])
		studio.viewport.get_texture().get_image().save_png("%s/port_added.png" % dir)
		# --- Drag it along the face.
		var pid := str(added.get("id", ""))
		var u0 := float(added.get("u", 0))
		var d2: Dictionary = ui.call("design")
		var b3: CtrlBuilder = ui.call("builder")
		var pxf := Transform3D()
		for p in (d2["ports"] as Array):
			if str(p["id"]) == pid:
				pxf = p["xf"]
		var from := _screen_of(studio, b3, pxf.origin)
		var to := _screen_of(studio, b3, pxf.origin + (f["x"] as Vector3) * 40.0)
		await HarnessInput.drag(vp, from, to)
		await _settle(tree, 10)
		var p2: Dictionary = ui.call("port_spec", pid)
		_ok(float(p2.get("u", 0)) - u0 > 25.0 and str(p2.get("face", "")) == "front",
			"dragging it slides it along the front (%.0f → %.0f mm)" % [u0, float(p2.get("u", 0))])
		_ok(absf(studio.yaw) < 0.05, "the drag did not orbit the view")
		# --- R turns it, Delete removes it.
		vp.gui_release_focus()
		await HarnessInput.key(vp, KEY_R)
		await _settle(tree, 6)
		_ok(absf(float((ui.call("port_spec", pid) as Dictionary).get("rot", 0)) - 90.0) < 0.1, "R turns it a quarter turn")
		await HarnessInput.key(vp, KEY_DELETE)
		await _settle(tree, 6)
		_ok(((ui.call("spec") as Dictionary)["ports"] as Array).size() == n0 and (ui.call("port_spec", pid) as Dictionary).is_empty(),
			"Delete removes it")
		await HarnessInput.key(vp, KEY_Z, true)
		await _settle(tree, 6)
		_ok(((ui.call("spec") as Dictionary)["ports"] as Array).size() == n0 + 1, "Ctrl+Z brings it back")
		await HarnessInput.key(vp, KEY_Z, true)
		await _settle(tree, 6)
	# --- Cover off, then a click on the battery stud selects it.
	var cov := ui.find_child("cover", true, false) as Button
	await HarnessInput.click(vp, HarnessInput.center_of(cov))
	await _settle(tree, 6)
	var b4: CtrlBuilder = ui.call("builder")
	_ok(not b4.cover_visible(), "Cover off takes the bay's cover off")
	var d4: Dictionary = ui.call("design")
	var bat_xf := Transform3D()
	for p in (d4["ports"] as Array):
		if str(p["id"]) == "bat_p":
			bat_xf = p["xf"]
	await HarnessInput.click(vp, _screen_of(studio, b4, bat_xf.origin + bat_xf.basis.z * 8.0))
	await _settle(tree, 6)
	_ok(str(ui.call("selected_port")) == "bat_p", "a click on BAT + through the open bay selects it (%s)" % str(ui.call("selected_port")))
	var card := ui.find_child("port_card", true, false) as Control
	_ok(card != null and card.visible, "its card shows")
	studio.viewport.get_texture().get_image().save_png("%s/bay_open.png" % dir)
	main.get_viewport().get_texture().get_image().save_png("%s/modal_port.png" % dir)
	var audit2 := UiAudit.run(vp)
	print("ctrllab: ui audit with a port selected — %s" % UiAudit.summary_line(audit2))
	_ok(int(audit2.get("errors", 0)) == 0, "no UI audit errors with a port selected")
	# --- The Terminals tab: the front sheet with its bay.
	var tabs := ui.find_child("lab_tabs", true, false) as TabBar
	await HarnessInput.click(vp, tabs.get_global_transform() * tabs.get_tab_rect(1).get_center())
	await _settle(tree, 10)
	_ok(str(ui.call("mode")) == "terminals", "a click on Terminals shows the wiring view")
	var sv: Control = ui.call("sheet")
	var lay: Dictionary = sv.get("lay")
	_ok(str(lay.get("face", "")) == "front" and bool(lay.get("has_bay", false)) and (lay["leads"] as Array).size() > 10,
		"it draws the front with the wiring bay and %d leads" % (lay.get("leads", []) as Array).size())
	main.get_viewport().get_texture().get_image().save_png("%s/terminals_front.png" % dir)
	var audit3 := UiAudit.run(vp)
	print("ctrllab: ui audit, Terminals — %s" % UiAudit.summary_line(audit3))
	_ok(int(audit3.get("errors", 0)) == 0, "no UI audit errors on the Terminals view")
	# A click on BAT − in the drawing selects it; a drag moves it; Ctrl+Z.
	var pl: Dictionary = sv.call("port_layout", "bat_n")
	var at2: Vector2 = sv.call("screen_of", pl["centre"])
	await HarnessInput.click(vp, at2)
	await _settle(tree, 6)
	_ok(str(ui.call("selected_port")) == "bat_n", "a click on BAT − in the drawing selects it (%s)" % str(ui.call("selected_port")))
	var bu := float((ui.call("port_spec", "bat_n") as Dictionary)["u"])
	var to2: Vector2 = sv.call("screen_of", (pl["centre"] as Vector2) + Vector2(12, 0))
	await HarnessInput.drag(vp, at2, to2)
	await _settle(tree, 8)
	var bu2 := float((ui.call("port_spec", "bat_n") as Dictionary)["u"])
	_ok(absf(bu2 - bu - 12.0) < 2.0, "dragging it in the drawing moves it 12 mm (%.1f → %.1f)" % [bu, bu2])
	vp.gui_release_focus()
	await HarnessInput.key(vp, KEY_Z, true)
	await _settle(tree, 8)
	_ok(absf(float((ui.call("port_spec", "bat_n") as Dictionary)["u"]) - bu) < 0.1, "Ctrl+Z puts it back")
	# A connector placed by a click in the drawing.
	var n1 := ((ui.call("spec") as Dictionary)["ports"] as Array).size()
	var fly2 := ui.find_child("flyout_ports", true, false) as Button
	await HarnessInput.click(vp, HarnessInput.center_of(fly2))
	await _settle(tree, 6)
	var mc := ui.find_child("conn_mc4_panel", true, false) as Button
	_reveal(mc)
	await _settle(tree, 3)
	await HarnessInput.click(vp, HarnessInput.center_of(mc))
	await _settle(tree, 6)
	var rr: Rect2 = lay["rect"]
	var spot := Vector2(rr.position.x + rr.size.x * 0.2, rr.end.y - rr.size.y * 0.3)
	await HarnessInput.click(vp, sv.call("screen_of", spot))
	await _settle(tree, 8)
	var ps2: Array = (ui.call("spec") as Dictionary)["ports"]
	var np: Dictionary = ps2[ps2.size() - 1] if ps2.size() > n1 else {}
	_ok(ps2.size() == n1 + 1 and str(np.get("connector", "")) == "mc4_panel" and str(np.get("face", "")) == "front"
		and absf(float(np.get("u", 0)) - spot.x) < 2.0 and absf(float(np.get("v", 0)) - spot.y) < 2.0,
		"an MC4 clicked onto the drawing lands there (u %.0f v %.0f)" % [float(np.get("u", 0)), float(np.get("v", 0))])
	await HarnessInput.key(vp, KEY_DELETE)
	await _settle(tree, 6)
	_ok(((ui.call("spec") as Dictionary)["ports"] as Array).size() == n1, "Delete takes it off again")
	# Another face from the picker.
	var fo := ui.find_child("sheet_face", true, false) as OptionButton
	for i in fo.item_count:
		if str(fo.get_item_metadata(i)) == "bottom":
			fo.select(i)
			fo.item_selected.emit(i)
	await _settle(tree, 6)
	_ok(str(ui.call("sheet_face")) == "bottom" and str((sv.get("lay") as Dictionary).get("face", "")) == "bottom",
		"the face picker shows the underside")
	# Export.
	var exb := ui.find_child("sheet_export", true, false) as Button
	await HarnessInput.click(vp, HarnessInput.center_of(exb))
	await _settle(tree, 6)
	var exdir := "user://ctrllab_designs/eg4_6000xp_hybrid"
	var svg := FileAccess.get_file_as_string(exdir + "/wiring.svg")
	_ok(svg.contains("<svg") and svg.contains("BAT +") and FileAccess.file_exists(exdir + "/terminals_bottom.png"),
		"Export writes wiring.svg (%d bytes) and the view as a PNG" % svg.length())
	# --- Back to the unit: the close-up, labelled.
	await HarnessInput.click(vp, tabs.get_global_transform() * tabs.get_tab_rect(0).get_center())
	await _settle(tree, 6)
	var cu := ui.find_child("close_up", true, false) as Button
	await HarnessInput.click(vp, HarnessInput.center_of(cu))
	await _settle(tree, 12)
	var co: Array = ui.call("callouts")
	var texts: Array = co.map(func(x): return str(x["text"]))
	_ok(str(ui.call("mode")) == "unit" and not (ui.call("builder") as CtrlBuilder).cover_visible() and texts.has("BAT +") and texts.size() >= 8,
		"Close-up opens the bay and labels its terminals (%d: %s)" % [texts.size(), ", ".join(texts.slice(0, 8))])
	studio.viewport.get_texture().get_image().save_png("%s/close_up.png" % dir)
	main.get_viewport().get_texture().get_image().save_png("%s/close_up_modal.png" % dir)
	# --- Save to the library, then forget.
	var save := HarnessInput.find_button(ui, "Save design")
	await HarnessInput.click(vp, HarnessInput.center_of(save))
	await _settle(tree, 8)
	var lib := CtrlPresets.load_library()
	_ok(lib.size() >= 1, "Save design writes the library (%d)" % lib.size())
	var mine := -1
	var es: Array = ui.get("_entries")
	for i in es.size():
		if not bool((es[i] as Dictionary)["builtin"]):
			mine = i
	_ok(mine >= 0, "the saved design is in the gallery")
	if mine >= 0:
		await _click_design(ui, tree, vp, mine)
		await _left(ui, tree)
		var forget := ui.find_child("forget", true, false) as Button
		_reveal(forget)
		await _settle(tree, 4)
		await HarnessInput.click(vp, HarnessInput.center_of(forget))
		await _settle(tree, 6)
		await _hide_left(ui, tree)
		_ok(CtrlPresets.load_library().size() == lib.size() - 1, "Forget removes it (%s; selected %s)" % [
			(ui.get("_status_lbl") as Label).text, str((ui.call("gallery") as DesignGallery).get_selected_items())])
	# Restore the library file.
	if lib_had:
		var fw := FileAccess.open(lib_path, FileAccess.WRITE)
		fw.store_string(lib_old)
	elif FileAccess.file_exists(lib_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(lib_path))
	ui.call("close")
	await _settle(tree, 4)
	if toasts != null:
		toasts.set("visible", true)
	_ok(not bool(ui.call("is_open")), "the Controller Lab closes")
	return {"ok": _fails.is_empty(), "fails": _fails}
