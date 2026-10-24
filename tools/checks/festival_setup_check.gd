extends RefCounted

## Festival mode on a REAL world whose location marker was moved (sandbox):
##   tools\harness.ps1 -World w6ad922917357 -RunScript res://tools/checks/festival_setup_check.gd -Label festival_setup
## Bombay Beach's marker sits ~1.4 km from the origin, and its saved festival
## (a demo zone seeded round the origin before the marker was respected) is
## the case this check exists for:
##   1. festival mode opens; "Move festival to marker" puts the camps' cluster
##      on the marker and every camp compound's site_x/z is marker-relative;
##   2. Clear seeded removes the demo zone, its camps and every seeded venue
##      even though this session never seeded them (the ids were memory-only).
## Writes only the sandbox.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("festival-setup %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func _push(tree: SceneTree, ev: InputEvent) -> void:
	tree.root.push_input(ev, true)
	await tree.process_frame


func _click(tree: SceneTree, _view: Node, at: Vector2) -> void:
	var mv := InputEventMouseMotion.new()
	mv.position = at
	await _push(tree, mv)
	for pressed in [true, false]:
		var mb := InputEventMouseButton.new()
		mb.button_index = MOUSE_BUTTON_LEFT
		mb.pressed = pressed
		mb.position = at
		await _push(tree, mb)
	await tree.process_frame


func _drag(tree: SceneTree, _view: Node, a: Vector2, b: Vector2) -> void:
	var mb := InputEventMouseButton.new()
	mb.button_index = MOUSE_BUTTON_LEFT
	mb.pressed = true
	mb.position = a
	await _push(tree, mb)
	for i in range(1, 13):
		var mv := InputEventMouseMotion.new()
		mv.position = a.lerp(b, float(i) / 12.0)
		mv.button_mask = MOUSE_BUTTON_MASK_LEFT
		await _push(tree, mv)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = b
	await _push(tree, up)
	await tree.process_frame


func _key(tree: SceneTree, _view: Node, k: Key) -> void:
	for pressed in [true, false]:
		var ev := InputEventKey.new()
		ev.keycode = k
		ev.physical_keycode = k
		ev.pressed = pressed
		await _push(tree, ev)


func _shot(main: Node, name: String) -> void:
	await main.get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := main.get_viewport().get_texture().get_image()
	var dir := "user://screenshots/festival_setup"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	img.save_png("%s/%s.png" % [dir, name])
	print("festival-setup shot: %s" % name)


func _camp_polys(sgv: Node, loader: Node) -> Array:
	var out: Array = []
	for c in sgv.call("festival_camps"):
		var poly: PackedVector2Array = loader.call("camp_lot_polygon", str((c as Dictionary)["lot_id"]))
		if poly.size() >= 3:
			out.append(poly)
	return out


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	await _settle(tree, 20)
	var sgv := ServiceLocator.graph()
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	_ok(sgv != null and loader != null, "graph view + terrain loader are up")
	if sgv == null or loader == null:
		return {"ok": false}
	var marker := SiteCentre.xz(main)
	print("festival-setup: marker at (%.1f, %.1f)" % [marker.x, marker.y])

	# --- 1. open + move to the marker --------------------------------------
	main.call("open_festival_mode")
	for _i in 600:
		await tree.process_frame
		if bool(main.call("festival_mode_active")):
			break
	_ok(bool(main.call("festival_mode_active")), "festival mode opened")
	var fm: Node = main.get("festival_mode")
	await _settle(tree, 10)
	var polys := _camp_polys(sgv, loader)
	_ok(not polys.is_empty(), "the world has festival camps (%d)" % polys.size())
	var before: Vector2 = FestivalSeedLayout.cluster(polys)["centre"]
	print("festival-setup: cluster at (%.1f, %.1f), %.0f m from the marker" % [
		before.x, before.y, before.distance_to(marker)])
	fm.call("move_to_marker")
	await _settle(tree, 8)
	polys = _camp_polys(sgv, loader)
	var after: Vector2 = FestivalSeedLayout.cluster(polys)["centre"] if not polys.is_empty() else Vector2.INF
	_ok(after.distance_to(marker) < 30.0, "cluster on the marker after the move (%.1f m off)" % after.distance_to(marker))
	var reg: SpaceRegistry = loader.get("npc_spaces")
	var far := 0
	var seeded := 0
	if reg != null:
		for rec in reg.spaces:
			var r: Dictionary = rec
			if not FestivalSeedLayout.is_seeded_space(r) or str((r.get("target", {}) as Dictionary).get("kind", "")) != "area":
				continue
			seeded += 1
			var p: Variant = reg.resolve_position(r, main)
			if p is Vector2 and (p as Vector2).distance_to(marker) > 600.0:
				far += 1
	_ok(seeded > 0 and far == 0, "seeded venues moved with the camps (%d seeded, %d still far)" % [seeded, far])
	var site_ok := true
	for c in sgv.call("festival_camps"):
		var comp: Dictionary = (sgv.get("model") as Object).call("get_item", str((c as Dictionary)["id"]))
		var sp: Dictionary = comp.get("specs", {})
		var poly: PackedVector2Array = loader.call("camp_lot_polygon", str((c as Dictionary)["lot_id"]))
		if poly.size() < 3:
			continue
		var want := CampAreaLayer._inner_point(poly) - marker
		if Vector2(float(sp.get("site_x_m", 0.0)), float(sp.get("site_z_m", 0.0))).distance_to(want) > 1.0:
			site_ok = false
	_ok(site_ok, "camp compounds' site_x/z are marker-relative")

	# --- 2. Clear seeded after a reload-equivalent (ids forgotten) ---------
	fm.set("_seeded_zone_id", "")
	fm.set("_seeded_road_id", "")
	fm.call("clear_seeded")
	await _settle(tree, 8)
	var placement: Variant = loader.get("placement")
	var demo_left := 0
	for z in (placement.get("zones") as Array):
		if str((z as Dictionary).get("name", "")) == FestivalMode.DEMO_ZONE_NAME:
			demo_left += 1
	_ok(demo_left == 0, "Clear removed the demo zone found by name")
	var prefixed := 0
	if reg != null:
		for rec2 in reg.spaces:
			if FestivalSeedLayout.is_seeded_space(rec2 as Dictionary):
				prefixed += 1
	_ok(prefixed == 0, "Clear removed every seeded venue (%d left)" % prefixed)
	_ok((sgv.call("festival_camps") as Array).is_empty(), "no festival camps left on the graph")

	# --- 3. the setup card: six named camps of ten, exact -----------------
	main.call("open_festival_mode")
	for _i in 300:
		await tree.process_frame
		if bool(main.call("festival_mode_active")):
			break
	var names := ["Dust Devils", "Salt Flats", "Sea Glass", "Rust Belt", "Night Owls", "Low Tide"]
	var spec := {"camps": [], "venues": ["restroom", "water_point", "shower", "stage"], "supply": "infinite"}
	for nm in names:
		(spec["camps"] as Array).append({"name": nm, "people": 10, "style": "mixed"})
	var placed: int = await fm.call("setup_gathering", spec)
	await _settle(tree, 10)
	_ok(placed == 6, "the setup card placed 6 camps (%d)" % placed)
	var camps: Array = sgv.call("festival_camps")
	var total := 0
	var named := 0
	for c in camps:
		total += int((c as Dictionary)["headcount"])
		if names.has(str((c as Dictionary)["name"])):
			named += 1
	_ok(camps.size() == 6 and total == 60, "6 camps, exactly 60 people on the graph (%d camps, %d people)" % [camps.size(), total])
	_ok(named == 6, "every camp carries its name (%d)" % named)
	polys = _camp_polys(sgv, loader)
	var cen: Vector2 = FestivalSeedLayout.cluster(polys)["centre"]
	_ok(cen.distance_to(marker) < 30.0, "the gathering is centred on the marker (%.1f m)" % cen.distance_to(marker))
	var linked := 0
	for rec3 in reg.spaces:
		if not str((rec3 as Dictionary).get("camp_id", "")).is_empty():
			linked += 1
	_ok(linked == 12, "every camp has its own linked beds + kitchen (%d)" % linked)

	# --- 4. edit in the festival view with REAL clicks ---------------------
	var view: Node = main.get("settlement_view")
	_ok(view != null and bool(view.call("is_open")), "the settlement view is open")
	view.call("set_editing", true)
	await _settle(tree, 4)
	var ed: Control = view.call("site_editor")
	_ok(ed != null and bool(ed.get("active")), "the site editor is on")
	var dock: Control = ed.get("_dock")
	print("festival-setup: editor rect %s visible %s layer %s · dock rect %s in-tree-visible %s min %s" % [
		str(ed.get_global_rect()), str(ed.is_visible_in_tree()), str((ed.get_parent() as CanvasLayer).layer),
		str(dock.get_global_rect()), str(dock.is_visible_in_tree()), str(dock.get_combined_minimum_size())])
	_ok(dock.is_visible_in_tree() and ed.get_global_rect().encloses(dock.get_global_rect()),
		"the editor's dock is on screen (%s)" % str(dock.get_global_rect()))
	var cam: Node = view.call("camera")
	var first: Dictionary = camps[0]
	var cpoly: PackedVector2Array = loader.call("camp_lot_polygon", str(first["lot_id"]))
	var cpt := CampAreaLayer._inner_point(cpoly)
	# Centre the camp on screen: the HUD's panels sit along the top edge.
	cam.call("look_at_xz", cpt)
	await _settle(tree, 40)
	var sp: Variant = ed.call("_screen", cpt)
	print("festival-setup: camp at screen %s, ground back %s (want %s)" % [str(sp),
		str(ed.call("_ground", sp)) if sp is Vector2 else "-", str(cpt)])
	_ok(sp is Vector2 and sp != Vector2.INF, "the camp projects to the screen")
	if sp is Vector2 and sp != Vector2.INF:
		await _click(tree, view, sp as Vector2)
		var sel: Dictionary = ed.call("selection")
		_ok(str(sel.get("kind", "")) == "camp", "a click selects the camp (%s)" % str(sel))
		# Drag it 20 m east.
		var to_v: Variant = ed.call("_screen", cpt + Vector2(20.0, 0.0))
		if to_v is Vector2:
			await _drag(tree, view, sp as Vector2, to_v as Vector2)
		var cpoly2: PackedVector2Array = loader.call("camp_lot_polygon", str(first["lot_id"]))
		var moved_by := CampAreaLayer._inner_point(cpoly2) - cpt
		_ok(absf(moved_by.x - 20.0) < 3.0 and absf(moved_by.y) < 3.0, "a drag moved the camp 20 m east (%s)" % str(moved_by))
		var beds_ok := false
		for rec4 in reg.spaces:
			var r4: Dictionary = rec4
			if str(r4.get("camp_id", "")) == str(first["lot_id"]) and str(r4.get("space_type", "")) == "sleep":
				var bp := SpaceRegistry.poly_points((r4.get("target", {}) as Dictionary).get("poly", []))
				beds_ok = bp == cpoly2
		_ok(beds_ok, "its beds followed the camp")
		ed.call("undo")
		await _settle(tree, 4)
		var cpoly3: PackedVector2Array = loader.call("camp_lot_polygon", str(first["lot_id"]))
		_ok(CampAreaLayer._inner_point(cpoly3).distance_to(cpt) < 1.0, "Ctrl+Z put it back")
	# Draw a new space: a shade area on the marker.
	cam.call("look_at_xz", marker)
	await _settle(tree, 40)
	ed.call("set_tool", "draw")
	ed.set("new_space_type", "shade")
	var n_before := reg.spaces.size()
	for corner in [Vector2(-8, -8), Vector2(8, -8), Vector2(8, 8), Vector2(-8, 8)]:
		var cs: Variant = ed.call("_screen", marker + corner)
		if cs is Vector2:
			await _click(tree, view, cs as Vector2)
	await _key(tree, view, KEY_ENTER)
	_ok(reg.spaces.size() == n_before + 1, "drawing four corners + Enter added a space")
	var drawn: Dictionary = ed.call("selection")
	_ok(str(drawn.get("kind", "")) == "space"
		and str(reg.find_by_id(str(drawn.get("id", ""))).get("space_type", "")) == "shade", "it is a shade space, selected")
	await _shot(main, "festival_setup_edit")
	view.call("set_editing", false)

	# --- 5. per-camp supply and the meter -----------------------------------
	sgv.call("set_camp_supply", str((camps[0] as Dictionary)["lot_id"]), {"inputs": "own", "wastes": "own"})
	sgv.call("set_camp_supply", str((camps[1] as Dictionary)["lot_id"]), {"inputs": "shared", "wastes": "shared"})
	var m0: Dictionary = sgv.call("camp_supply_modes", str((camps[1] as Dictionary)["lot_id"]))
	_ok(str(m0.get("inputs", "")) == "shared", "a camp's supply mode is set (%s)" % str(m0))
	var model: Object = sgv.get("model")
	_ok(not (model.call("get_item", "fest_depot_water") as Dictionary).is_empty(), "the shared site depots exist")
	var lvl0 := float(((model.call("get_item", "fest_depot_water") as Dictionary).get("specs", {}) as Dictionary).get("level", 1.0))
	main.set("time_scale", 0.25)
	for _i in 900:
		await tree.process_frame
	main.set("time_scale", 0.0)
	await _settle(tree, 10)
	var rows: Array = sgv.call("festival_camp_rows")
	var metered := 0
	for r5 in rows:
		for mrow in ((r5 as Dictionary)["meter"] as Array):
			if str((mrow as Dictionary)["key"]) == "in:water" and float((mrow as Dictionary)["total"]) > 0.0:
				metered += 1
	_ok(metered >= 4, "camps metered their water (%d of %d)" % [metered, rows.size()])
	var lvl1 := float(((model.call("get_item", "fest_depot_water") as Dictionary).get("specs", {}) as Dictionary).get("level", 1.0))
	_ok(lvl1 < lvl0, "the shared camp drew on the site water depot (%.4f -> %.4f)" % [lvl0, lvl1])
	var cid0 := str((camps[0] as Dictionary)["id"])
	_ok(not CampLoopClosure.apply(model, cid0, "Greywater Filter").is_empty(), "a loop closer drops into a camp")
	_ok(float((CampLoopClosure.score(model, cid0)["kinds"] as Dictionary).get("greywater", 0.0)) >= 0.999,
		"that camp's greywater loop reads closed")
	for r6 in rows:
		print("festival-setup camp: %s · %d people · %s" % [(r6 as Dictionary)["name"], (r6 as Dictionary)["headcount"],
			str(((r6 as Dictionary)["meter"] as Array).slice(0, 4))])
	# --- 6. the same editor in Site Plan ------------------------------------
	if bool(view.call("is_open")):
		view.call("close")
	await _settle(tree, 4)
	sgv.call("open_graph_view")
	sgv.call("_apply_graph_view_mode", GraphSiteLayout.VIEW_SITE)
	await _settle(tree, 30)
	sgv.call("set_site_editing", true)
	var canvas: Control = sgv.get("_graph_canvas")
	var sed: Control = canvas.get("site_editor")
	_ok(sed != null and bool(sed.get("active")), "Site Plan's ✎ Edit site is on")
	if canvas.has_method("center_site_on"):
		canvas.call("center_site_on", cpt)
	await _settle(tree, 40)
	var cs2: Variant = canvas.call("site_editor_to_canvas", cpt)
	var back: Variant = canvas.call("site_editor_ground_at", cs2) if cs2 is Vector2 else Vector2.INF
	_ok(back is Vector2 and (back as Vector2).distance_to(cpt) < 3.0,
		"Site Plan maps a camp to the screen and back (%s vs %s)" % [str(back), str(cpt)])
	if cs2 is Vector2 and (cs2 as Vector2) != Vector2.INF:
		await _click(tree, view, canvas.get_global_transform() * (cs2 as Vector2))
		var ssel: Dictionary = sed.call("selection")
		_ok(str(ssel.get("kind", "")) == "camp", "a click in Site Plan selects the camp (%s)" % str(ssel))
	await _shot(main, "festival_setup_site_plan_edit")
	sgv.call("set_site_editing", false)
	sgv.call("close_graph_view")
	await _settle(tree, 6)

	sgv.call("open_camps_panel", Callable())
	await _settle(tree, 8)
	await _shot(main, "festival_setup_camps_panel")

	print("festival-setup %s (%d failures)" % ["PASS" if _fails.is_empty() else "FAIL", _fails.size()])
	return {"ok": _fails.is_empty(), "failures": _fails}
