extends RefCounted

## Graph systems Phase 4 (plans/GRAPH_SYSTEMS_UX_PLAN.md): the graph <-> 3D
## hand-offs on the Walton festival world (sandbox, REAL input):
##   tools\harness.ps1 -World walton -RunScript res://tools/checks/graph_twin_check.gd -Label graph_twin -Timeout 900
## 1. Hovering a camp card lights its painted outline in 3D; moving off puts
##    it out.
## 2. Twin badges: a camp card says "on the map"; a node inside a camp
##    "inside its camp"; a real click on the camp's badge looks at it from the
##    settlement camera, and Esc comes back to the graph on the same camp.
## 3. Open in graph lands inside the right scope; the camp's own Open in graph
##    finds its compound.
## 4. Site Plan pins carry names at rest (decluttered).
## 5. The freeform site inset: a dot per system; a real click on one flies
##    there; View ▾ turns it off.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("graphtwin %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


func _wait(tree: SceneTree, s: float) -> void:
	await tree.create_timer(s, true, false, true).timeout


func _shot(vp: Viewport, dir: String, name: String) -> void:
	vp.get_texture().get_image().save_png("%s/%s.png" % [dir, name])


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
	sgv.call("_jump_to_scope_index", 0)
	sgv.call("set_site_inset", true)
	await _wait(tree, 2.5)
	var model: GraphModel = sgv.get("model")
	var canvas: Control = sgv.get("_graph_canvas")
	var loader: Node = main.get_node_or_null("Terrain/TerrainLoader")
	if loader == null:
		loader = main.find_child("TerrainLoader", true, false)
	var camps: Array = sgv.call("festival_camps")
	var camp: Dictionary = model.get_item(str((camps[camps.size() / 2] as Dictionary)["id"]))
	var cid := str(camp.get("id", ""))
	var lot := str((camp.get("specs", {}) as Dictionary).get("camp_lot_id", ""))
	var area := lot.substr(5) if lot.begins_with("camp:") else str(loader.call("camp_area_for_lot", lot))

	# Frame the camp card at about 220 px.
	var gc := Vector2(float(camp.get("x", 0.0)) + float(camp.get("width", 220.0)) * 0.5,
		float(camp.get("y", 0.0)) + float(camp.get("height", 150.0)) * 0.5)
	var z := 220.0 / float(camp.get("width", 220.0))
	canvas.set("_zoom", z)
	canvas.set("_pan", -gc * z)
	canvas.queue_redraw()
	await _frames(tree, 3)
	var crect := Rect2(canvas.call("_item_screen_tl", camp, canvas.size * 0.5) as Vector2,
		canvas.call("_item_screen_size", camp) as Vector2)
	var cglob := canvas.get_global_rect().position

	# --- 1. hover lights the camp in 3D ----------------------------------------
	await HarnessInput.mouse_move(vp, cglob + crect.get_center())
	await _frames(tree, 3)
	print("graphtwin: hovered %s, loader camp focus %s (camp %s)" % [
		str(sgv.call("hovered_twin_id")), str(loader.get("_camp_focus_id")), area])
	_ok(str(sgv.call("hovered_twin_id")) == cid and str(loader.get("_camp_focus_id")) == area,
		"hovering the camp card lights its outline in 3D")
	_shot(vp, dir, "01_hover_card")
	var empty := Vector2(30.0, canvas.size.y * 0.5)
	for gy in range(1, 12):
		for gx in range(1, 16):
			var q := Vector2(canvas.size.x * gx / 16.0, canvas.size.y * gy / 12.0)
			if (canvas.call("_item_at_screen", q) as Dictionary).is_empty():
				empty = q
				break
		if empty.x != 30.0:
			break
	await HarnessInput.mouse_move(vp, cglob + empty)
	await _frames(tree, 3)
	_ok(str(sgv.call("hovered_twin_id")) == "" and str(loader.get("_camp_focus_id")) == "",
		"moving off puts it out")

	# --- 2. twin badges ----------------------------------------------------------
	_ok(GraphSystems.twin_kind(model, camp) == "map", "the camp card's badge says it is on the map")
	var kids := model.get_items_in_scope(str(camp.get("child_scope_id", "")))
	var kid: Dictionary = kids[0]
	var kid_kind := GraphSystems.twin_kind(model, kid)
	print("graphtwin: inside %s, %s is \"%s\"" % [str((camp["specs"] as Dictionary).get("name", "")),
		str(kid.get("id", "")), kid_kind])
	_ok(kid_kind == "owner" or kid_kind == "3d", "a node inside the camp follows its camp's place")
	var at: Vector2 = sgv.call("_item_world_xz_for_handoff", kid)
	_ok(at != Vector2.INF, "and Locate / Walk have somewhere to go for it")
	var rects: Dictionary = canvas.get("_twin_badge_rects")
	_ok(rects.has(cid), "the camp card draws its badge")
	_shot(vp, dir, "02_badge")
	if rects.has(cid):
		var bp := cglob + (rects[cid] as Rect2).get_center()
		await HarnessInput.mouse_move(vp, bp)
		await HarnessInput.click(vp, bp)
		await _wait(tree, 1.2)
	_ok(not sgv.visible and bool(main.call("settlement_view_open")),
		"a real click on the badge looks at the camp in the world")
	_shot(vp, dir, "03_located")
	await HarnessInput.key(vp, KEY_ESCAPE)
	await _wait(tree, 1.2)
	var sel: Array = sgv.get("_selected_item_ids")
	_ok(sgv.visible and sel.has(cid), "Esc comes back to the graph on the same camp")

	# --- 3. open in graph enters scopes ---------------------------------------
	sgv.call("_jump_to_scope_index", 0)
	await _wait(tree, 0.5)
	sgv.call("open_node_in_graph", str(kid.get("id", "")))
	await _wait(tree, 0.8)
	sel = sgv.get("_selected_item_ids")
	_ok(str(sgv.get("_active_scope_id")) == str(camp.get("child_scope_id", "")) and sel.has(str(kid.get("id", ""))),
		"Open in graph on a node inside a camp goes into the camp and selects it")
	sgv.call("_jump_to_scope_index", 0)
	await _wait(tree, 0.5)
	_ok(bool(sgv.call("open_camp_in_graph", area)) and (sgv.get("_selected_item_ids") as Array).has(cid),
		"the camp's own Open in graph finds its system")

	# --- 4. pins with names --------------------------------------------------------
	sgv.call("_on_canvas_item_selected", "")
	sgv.call("_on_mode_chip_pressed", GraphSiteLayout.VIEW_SITE)
	await _wait(tree, 1.0)
	canvas.call("fit_scope_to_view")
	await _wait(tree, 1.5)
	canvas.queue_redraw()
	await _frames(tree, 3)
	print("graphtwin: Site Plan pins mode %s, pin names drawn: %d" % [
		str(canvas.call("_pins_mode_active")), int(canvas.get("pin_labels_drawn"))])
	_ok(int(canvas.get("pin_labels_drawn")) >= 5, "Site Plan pins carry names at rest")
	_shot(vp, dir, "04_pins")
	sgv.call("_on_mode_chip_pressed", GraphSiteLayout.VIEW_FREEFORM)
	await _wait(tree, 0.6)

	# --- 5. the site inset ------------------------------------------------------------
	canvas.call("fit_scope_to_view")
	await _wait(tree, 0.6)
	await _frames(tree, 2)
	var dots: Array = canvas.get("_inset_dots")
	var irect: Rect2 = canvas.get("_inset_rect")
	print("graphtwin: inset %s with %d dots" % [str(irect), dots.size()])
	_ok(irect.has_area() and dots.size() == camps.size() + 1, "the site inset has a dot per system and home")
	_shot(vp, dir, "05_inset")
	var target := ""
	var tpos := Vector2.ZERO
	for d: Array in dots:
		if not str(d[0]).is_empty() and str(d[0]) != cid:
			# A dot with no neighbour within 12 px, so the click is unambiguous.
			var alone := true
			for e: Array in dots:
				if e != d and (e[1] as Vector2).distance_to(d[1] as Vector2) < 12.0:
					alone = false
			if alone:
				target = str(d[0])
				tpos = d[1]
				break
	if not target.is_empty():
		await HarnessInput.mouse_move(vp, cglob + tpos)
		await HarnessInput.click(vp, cglob + tpos)
		await _wait(tree, 0.8)
	_ok(not target.is_empty() and (sgv.get("_selected_item_ids") as Array).has(target),
		"a real click on an inset dot flies to that system")
	sgv.call("_on_view_menu_id", int(sgv.get_script().get_script_constant_map()["VIEW_SITE_INSET"]))
	canvas.queue_redraw()
	await _frames(tree, 3)
	_ok(not (canvas.get("_inset_rect") as Rect2).has_area(), "View ▾ turns the inset off")
	sgv.call("set_site_inset", true)
	sgv.call("close_graph_view")
	return {"ok": _fails.is_empty(), "fails": _fails}
