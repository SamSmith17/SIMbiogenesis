extends RefCounted

## Graph navigation, Phase 1 (plans/GRAPH_SYSTEMS_UX_PLAN.md), on the Walton
## festival world with REAL input (sandbox):
##   tools\harness.ps1 -World walton -RunScript res://tools/checks/graph_navigation_check.gd -Label graph_nav -Timeout 900
## 1. The systems outliner lists every camp; Ctrl+F puts the cursor in its
##    search; typing a camp's name + Enter flies to it (selected, at root).
## 2. F frames the selection; a real double-click on the camp's tree row
##    opens it; Esc returns to the camera the player had at root.
## 3. The breadcrumb's sibling menu jumps camp to camp; Home goes back to the
##    site; Alt+Left goes up one level.
## 4. Wheel pop-out resists: the content must be under a quarter of the view
##    and the wheel must push out POP_PUSH_NOTCHES more times.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("graphnav %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


func _wait(tree: SceneTree, s: float) -> void:
	await tree.create_timer(s, true, false, true).timeout


func _key_alt(vp: Viewport, code: Key) -> void:
	for pressed in [true, false]:
		var ev := InputEventKey.new()
		ev.keycode = code
		ev.physical_keycode = code
		ev.pressed = pressed
		ev.alt_pressed = true
		vp.push_input(ev, true)
		await Engine.get_main_loop().process_frame


func _wheel(vp: Viewport, pos: Vector2, down: bool) -> void:
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_WHEEL_DOWN if down else MOUSE_BUTTON_WHEEL_UP
		ev.pressed = pressed
		ev.factor = 1.0
		ev.position = pos
		ev.global_position = pos
		vp.push_input(ev, true)
	await Engine.get_main_loop().process_frame


func _type(vp: Viewport, text: String) -> void:
	for ch in text:
		for pressed in [true, false]:
			var ev := InputEventKey.new()
			ev.unicode = ch.unicode_at(0)
			ev.pressed = pressed
			if ch == " ":
				ev.keycode = KEY_SPACE
			vp.push_input(ev, true)
		await Engine.get_main_loop().process_frame


func _row_of(tree: Tree, id: String) -> TreeItem:
	var stack: Array = [tree.get_root()]
	while not stack.is_empty():
		var ti: TreeItem = stack.pop_back()
		if ti == null:
			continue
		if str(ti.get_metadata(0)) == id:
			return ti
		var ch := ti.get_first_child()
		while ch != null:
			stack.append(ch)
			ch = ch.get_next()
	return null


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var vp := main.get_viewport()
	await _frames(tree, 10)
	var sgv := ServiceLocator.graph()
	_ok(sgv != null, "a graph view")
	if sgv == null:
		return {"ok": false, "fails": _fails}
	var dir := "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	main.set("time_scale", 0.0)
	sgv.call("open_graph_view")
	await _frames(tree, 6)
	sgv.call("_on_mode_chip_pressed", GraphSiteLayout.VIEW_FREEFORM)
	if not bool(sgv.get("_sidebar_l_open")):
		sgv.call("_on_left_toggle")
	sgv.call("_jump_to_scope_index", 0)
	await _wait(tree, 1.2)
	var model: GraphModel = sgv.get("model")
	var canvas: Control = sgv.get("_graph_canvas")
	var outl: GraphSystemsOutliner = sgv.call("systems_outliner")
	_ok(outl != null and canvas != null, "the systems outliner is in the left sidebar")
	if outl == null or canvas == null:
		return {"ok": false, "fails": _fails}

	# --- 1. outliner lists the camps; Ctrl+F + typing + Enter ---------------
	var camps: Array = sgv.call("festival_camps")
	var shown := outl.shown_ids()
	var listed := 0
	for c in camps:
		if shown.has(str((c as Dictionary)["id"])):
			listed += 1
	print("graphnav: %d camps, %d listed in the outliner (%d rows)" % [camps.size(), listed, shown.size()])
	_ok(camps.size() > 0 and listed == camps.size(), "every camp is in the outliner")
	vp.get_texture().get_image().save_png("%s/01_outliner.png" % dir)
	await HarnessInput.key(vp, KEY_F, true)
	await _frames(tree, 3)
	var search := outl.find_child("SystemsSearch", true, false) as LineEdit
	_ok(vp.gui_get_focus_owner() == search, "Ctrl+F puts the cursor in the systems search")
	var camp: Dictionary = model.get_item(str((camps[3 % camps.size()] as Dictionary)["id"]))
	var camp_id := str(camp.get("id", ""))
	var camp_name := GraphSystemsOutliner._name_of(camp)
	search.text = ""
	await _type(vp, camp_name)
	await _frames(tree, 3)
	print("graphnav: typed '%s' -> search '%s', %d rows" % [camp_name, search.text, outl.shown_ids().size()])
	vp.get_texture().get_image().save_png("%s/02_search.png" % dir)
	await HarnessInput.key(vp, KEY_ENTER)
	await _wait(tree, 0.6)
	var sel: Array = sgv.get("_selected_item_ids")
	_ok(sel.has(camp_id) and str(sgv.get("_active_scope_id")) == "root",
		"Enter flies to '%s' (selected at root)" % camp_name)

	# --- 2. F frames it; double-click its row opens it; Esc comes back -------
	search.text = ""
	outl.search("")
	canvas.grab_focus()
	await HarnessInput.key(vp, KEY_F)
	await _wait(tree, 0.5)
	var z0 := float(canvas.get("_zoom"))
	var p0: Vector2 = canvas.get("_pan")
	var c_rect := Rect2(Vector2(float(camp.get("x", 0.0)), float(camp.get("y", 0.0))),
		Vector2(float(camp.get("width", 220.0)), float(camp.get("height", 150.0))))
	var on_screen := Rect2(canvas.size * 0.5 + p0 + c_rect.position * z0, c_rect.size * z0)
	_ok(Rect2(Vector2.ZERO, canvas.size).encloses(on_screen) and on_screen.size.x > canvas.size.x * 0.15,
		"F frames the selected camp (%.0f px wide)" % on_screen.size.x)
	var t := outl.tree()
	var row := _row_of(t, camp_id)
	_ok(row != null, "the camp has a tree row")
	if row != null:
		var parent := row.get_parent()
		while parent != null:
			parent.collapsed = false
			parent = parent.get_parent()
		await _frames(tree, 2)
		t.scroll_to_item(row)
		await _frames(tree, 2)
		var ar := t.get_item_area_rect(row, 0)
		var pos := t.get_global_transform_with_canvas() * (ar.position + Vector2(ar.size.x * 0.5, ar.size.y * 0.5))
		await HarnessInput.click(vp, pos)
		await _frames(tree, 2)
		var hit := vp.gui_get_hovered_control() if vp.has_method("gui_get_hovered_control") else null
		print("graphnav: row click at %s -> hovered %s, selected row '%s', view selection %s" % [
			str(pos), str(hit), (t.get_selected().get_text(0) if t.get_selected() != null else "<none>"),
			str(sgv.get("_selected_item_ids"))])
		await HarnessInput.click(vp, pos, true)
		await _wait(tree, 0.6)
	var cscope := str(camp.get("child_scope_id", ""))
	_ok(str(sgv.get("_active_scope_id")) == cscope, "double-clicking the row opens the camp")
	vp.get_texture().get_image().save_png("%s/03_inside_camp.png" % dir)
	await HarnessInput.mouse_move(vp, canvas.get_global_rect().get_center())
	await HarnessInput.key(vp, KEY_ESCAPE)
	await _wait(tree, 0.6)
	var z1 := float(canvas.get("_zoom"))
	var p1: Vector2 = canvas.get("_pan")
	print("graphnav: root camera before %.3f %s after %.3f %s" % [z0, str(p0), z1, str(p1)])
	_ok(str(sgv.get("_active_scope_id")) == "root" and absf(z1 - z0) < 0.02 * z0 \
		and p1.distance_to(p0) < 4.0, "Esc returns to the camera the player had at root")

	# --- 3. sibling jump, Home, Alt+Left -------------------------------------
	sgv.call("focus_graph_item", camp_id, true)
	await _wait(tree, 0.6)
	var crumb: HBoxContainer = sgv.get("_scope_breadcrumb")
	var menu: MenuButton = null
	for ch in crumb.get_children():
		if ch is MenuButton:
			menu = ch
	_ok(menu != null and menu.get_popup().item_count > 1, "the breadcrumb offers the other camps")
	if menu != null:
		var pm := menu.get_popup()
		var pick := 0 if pm.is_item_disabled(0) == false else 1
		var other_name := pm.get_item_text(pick)
		pm.id_pressed.emit(pm.get_item_id(pick))
		await _wait(tree, 0.6)
		var act := str(sgv.get("_active_scope_id"))
		var owner := model.get_item(str(model.get_scope(act).get("owner_compound_id", "")))
		_ok(act != cscope and GraphSystemsOutliner._name_of(owner) == other_name,
			"the sibling menu jumps to '%s'" % other_name)
		vp.get_texture().get_image().save_png("%s/04_sibling.png" % dir)
	await HarnessInput.key(vp, KEY_HOME)
	await _wait(tree, 0.5)
	_ok(str(sgv.get("_active_scope_id")) == "root", "Home goes back to the site")
	sgv.call("focus_graph_item", camp_id, true)
	await _wait(tree, 0.6)
	await _key_alt(vp, KEY_LEFT)
	await _wait(tree, 0.5)
	_ok(str(sgv.get("_active_scope_id")) == "root", "Alt+Left goes up one level")

	# --- 4. wheel pop-out resistance -----------------------------------------
	sgv.call("focus_graph_item", camp_id, true)
	await _wait(tree, 0.6)
	var mid := canvas.get_global_rect().get_center()
	await HarnessInput.mouse_move(vp, mid)
	var notches := 0
	while int(canvas.call("pop_push_count")) == 0 and str(sgv.get("_active_scope_id")) == cscope \
			and notches < 40:
		await _wheel(vp, mid, true)
		notches += 1
	print("graphnav: %d wheel notches out to reach the pop-out floor" % notches)
	_ok(str(sgv.get("_active_scope_id")) == cscope and int(canvas.call("pop_push_count")) == 1,
		"reaching the floor does not leave the camp yet")
	vp.get_texture().get_image().save_png("%s/05_pop_resist.png" % dir)
	var push_n := int(canvas.get_script().get_script_constant_map().get("POP_PUSH_NOTCHES", 3))
	for _k in push_n - 1:
		await _wheel(vp, mid, true)
	_ok(str(sgv.get("_active_scope_id")) == cscope, "still inside after %d more notches" % (push_n - 1))
	await _wheel(vp, mid, true)
	await _wait(tree, 0.5)
	_ok(str(sgv.get("_active_scope_id")) == "root", "one more notch pops out to the site")

	sgv.call("close_graph_view")
	return {"ok": _fails.is_empty(), "fails": _fails}
