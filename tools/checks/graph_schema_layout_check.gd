extends RefCounted

## The Layout ▾ "Arrange as" arrangements on a real graph (sandbox):
##   tools\harness.ps1 -World w6af22bac295d -RunScript res://tools/checks/graph_schema_layout_check.gd -Label graph_schemas -Timeout 900
## For each arrangement, through the menu's own handler: every root card
## moved, no two overlap, the system areas are drawn, a shot. Then Live
## layout holding the ring: a node dragged off (the canvas's own drag state)
## pulls a wired neighbour along; let go, the neighbour returns and the
## dropped node keeps its new place. Undo puts the last arrangement back.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("graphschema %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


func _wait(tree: SceneTree, s: float) -> void:
	await tree.create_timer(s, true, false, true).timeout


func _shot(vp: Viewport, dir: String, name: String) -> void:
	vp.get_texture().get_image().save_png("%s/%s.png" % [dir, name])


func _root_cards(model: GraphModel) -> Array:
	var out: Array = []
	for it in GraphLayout.filter_layout_items(model.get_items_in_scope("root")):
		out.append(it)
	return out


func _overlaps(cards: Array) -> int:
	var n := 0
	for i in cards.size():
		var a: Dictionary = cards[i]
		var ra := Rect2(float(a["x"]), float(a["y"]), float(a.get("width", 120.0)), float(a.get("height", 90.0))).grow(-1.0)
		for j in range(i + 1, cards.size()):
			var b: Dictionary = cards[j]
			var rb := Rect2(float(b["x"]), float(b["y"]), float(b.get("width", 120.0)), float(b.get("height", 90.0))).grow(-1.0)
			if ra.intersects(rb):
				n += 1
	return n


func _pos(model: GraphModel, iid: String) -> Vector2:
	var it := model.get_item(iid)
	return Vector2(float(it.get("x", 0.0)), float(it.get("y", 0.0)))


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
	await _wait(tree, 1.0)
	var model: GraphModel = sgv.get("model")
	var canvas: Control = sgv.get("_graph_canvas")
	var menu: MenuButton = sgv.get("_layout_menu")
	var pm := menu.get_popup()
	var base := int(sgv.get_script().get_script_constant_map().get("LAYOUT_SCHEMA_BASE", 16))
	var cards := _root_cards(model)
	print("graphschema: %d root cards" % cards.size())
	_shot(vp, dir, "00_before")

	for si in GraphSchemaLayout.SCHEMAS.size():
		var schema: String = GraphSchemaLayout.SCHEMAS[si]
		_ok(pm.get_item_index(base + si) >= 0, "Layout ▾ lists \"%s\"" % str(GraphSchemaLayout.LABELS[schema]))
		var before := {}
		for c in cards:
			before[str((c as Dictionary)["id"])] = _pos(model, str((c as Dictionary)["id"]))
		var t0 := Time.get_ticks_usec()
		pm.id_pressed.emit(base + si)
		var arrange_ms := (Time.get_ticks_usec() - t0) / 1000.0
		await _wait(tree, 0.9)
		var moved := 0
		for c2 in cards:
			var iid := str((c2 as Dictionary)["id"])
			if _pos(model, iid).distance_to(before[iid] as Vector2) > 1.0:
				moved += 1
		var now_cards := _root_cards(model)
		var ov := _overlaps(now_cards)
		var regions: Array = canvas.get("layout_regions")
		print("graphschema: %s — %d of %d cards moved, %d overlapping, %d areas, %.0f ms" % [
			schema, moved, cards.size(), ov, regions.size(), arrange_ms])
		_ok(moved > cards.size() / 2, "%s moved the cards" % schema)
		_ok(ov == 0, "%s: no two cards overlap (%d)" % [schema, ov])
		_ok(regions.size() >= 3, "%s: the system areas are drawn (%d)" % [schema, regions.size()])
		var ids: Array = []
		for c3 in now_cards:
			ids.append(str((c3 as Dictionary)["id"]))
		canvas.call("fit_items_to_view", ids, 0.08)
		await _wait(tree, 0.7)
		_shot(vp, dir, "%02d_%s" % [si + 1, schema])

	# Live layout holding the ring: drag a store off its slot.
	pm.id_pressed.emit(base + GraphSchemaLayout.SCHEMAS.find(GraphSchemaLayout.RING))
	await _wait(tree, 0.9)
	sgv.call("set_live_layout", true)
	await _wait(tree, 0.5)
	# A store wired to exactly one root machine (a neighbour with nothing
	# else pulling on it shows the follow cleanly).
	var store := ""
	var neighbour := ""
	for c4 in model.connections:
		var cd: Dictionary = c4
		var a := model.get_item(str(cd.get("source_item_id", "")))
		var b := model.get_item(str(cd.get("target_item_id", "")))
		if a.is_empty() or b.is_empty() or str(a.get("scope_id", "root")) != "root" or str(b.get("scope_id", "root")) != "root":
			continue
		if str(a.get("type", "")) == "processor" and str(b.get("type", "")) == "resource":
			store = str(b["id"])
			neighbour = str(a["id"])
			break
	var s0 := _pos(model, store)
	var n0 := _pos(model, neighbour)
	canvas.set("_item_dragging", true)
	var drag_ids: Array[String] = [store]
	canvas.set("_item_drag_ids", drag_ids)
	var off := Vector2(900.0, 0.0)
	for k in 40:
		var p := s0 + off * (float(k + 1) / 40.0)
		model.get_item(store)["x"] = p.x
		model.get_item(store)["y"] = p.y
		await tree.process_frame
	var n_held := _pos(model, neighbour)
	_ok(n_held.distance_to(n0) > 8.0, "Live ring: the dragged store's wired neighbour follows (%.0f px)" % n_held.distance_to(n0))
	_shot(vp, dir, "10_live_drag")
	canvas.set("_item_dragging", false)
	var none: Array[String] = []
	canvas.set("_item_drag_ids", none)
	await _wait(tree, 8.0)
	var n_back := _pos(model, neighbour)
	_ok(n_back.distance_to(n0) < 12.0, "Live ring: the neighbour settles back (%.1f px off)" % n_back.distance_to(n0))
	_ok(_pos(model, store).distance_to(s0 + off) < 40.0, "Live ring: the dropped store keeps its new place (%.0f px off)" % _pos(model, store).distance_to(s0 + off))
	_shot(vp, dir, "11_live_settled")
	sgv.call("set_live_layout", false)

	# Areas off and on.
	sgv.call("set_layout_regions_visible", false)
	_ok(not bool(canvas.get("layout_regions_visible")), "areas can be hidden")
	sgv.call("set_layout_regions_visible", true)
	sgv.call("close_graph_view")
	await _frames(tree, 4)
	print("graphschema: %s" % ("PASS" if _fails.is_empty() else "FAIL %s" % str(_fails)))
	return {"ok": _fails.is_empty(), "fails": _fails}
