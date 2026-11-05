extends RefCounted

## Graph systems Phase 2 (plans/GRAPH_SYSTEMS_UX_PLAN.md) on the Walton
## festival world (sandbox, REAL wheel input where it matters):
##   tools\harness.ps1 -World walton -RunScript res://tools/checks/graph_festival_check.gd -Label graph_festival -Timeout 900
## 1. Layout ▾ "Arrange systems by site": no two system cards overlap, none
##    sits on the site's own nodes, and west-to-east on the map stays
##    west-to-east on the canvas.
## 2. Zoomed out, every camp is a festival tile (status ring + name).
## 3. Zoomed in, a camp card shows its live peek, and entering it starts the
##    child canvas exactly where the peek drew it (no jump); a real wheel
##    zoom-in commits into the camp.
## 4. Site Plan inside the camp: every item has a place on the map, all of
##    them on screen; Esc goes back out framed on the camp.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("graphfest %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


func _wait(tree: SceneTree, s: float) -> void:
	await tree.create_timer(s, true, false, true).timeout


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


func _card_rect(canvas: Control, it: Dictionary) -> Rect2:
	return Rect2(canvas.call("_item_screen_tl", it, canvas.size * 0.5) as Vector2,
		canvas.call("_item_screen_size", it) as Vector2)


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
	await _wait(tree, 1.0)
	var model: GraphModel = sgv.get("model")
	var canvas: Control = sgv.get("_graph_canvas")

	# --- 1. arrange by site -------------------------------------------------
	var menu: MenuButton = sgv.get("_layout_menu")
	var pm := menu.get_popup()
	var by_site := int(sgv.get_script().get_script_constant_map().get("LAYOUT_BY_SITE", 15))
	_ok(pm.get_item_index(by_site) >= 0, "Layout ▾ has \"Arrange systems by site\"")
	pm.id_pressed.emit(by_site)
	await _wait(tree, 0.8)
	var cards: Array = []
	var home := Rect2()
	var have_home := false
	for it in model.get_items_in_scope("root"):
		var d: Dictionary = it
		var r := Rect2(float(d.get("x", 0.0)), float(d.get("y", 0.0)),
			float(d.get("width", 150.0)), float(d.get("height", 120.0)))
		if GraphSystems.is_power_island(d) and GraphSiteLayout.has_site_coords(d):
			cards.append([d, r])
		elif not bool(d.get("is_virtual", false)):
			home = r if not have_home else home.merge(r)
			have_home = true
	var overlaps := 0
	for i in cards.size():
		var ri: Rect2 = cards[i][1]
		if have_home and ri.intersects(home):
			overlaps += 1
		for j in range(i + 1, cards.size()):
			if ri.intersects(cards[j][1] as Rect2):
				overlaps += 1
	print("graphfest: %d system cards arranged, %d overlaps" % [cards.size(), overlaps])
	_ok(cards.size() >= 10 and overlaps == 0, "no system card overlaps another or the site's nodes")
	# Map order kept: Spearman-ish — share of pairs ordered the same way in x.
	var same := 0
	var pairs := 0
	for i in cards.size():
		for j in range(i + 1, cards.size()):
			var sx := GraphSiteLayout.site_xz(cards[i][0]).x - GraphSiteLayout.site_xz(cards[j][0]).x
			if absf(sx) < 20.0:
				continue
			var cx := (cards[i][1] as Rect2).get_center().x - (cards[j][1] as Rect2).get_center().x
			pairs += 1
			if signf(sx) == signf(cx):
				same += 1
	var frac := float(same) / maxf(1.0, float(pairs))
	print("graphfest: %d of %d camp pairs keep their east-west order" % [same, pairs])
	_ok(frac >= 0.85, "west to east on the map stays west to east on the canvas (%.0f %%)" % (frac * 100.0))

	# --- 2. festival tiles ---------------------------------------------------
	canvas.call("fit_scope_to_view")
	await _wait(tree, 0.6)
	await _frames(tree, 2)
	var camps: Array = sgv.call("festival_camps")
	var tile_max := float(canvas.get_script().get_script_constant_map().get("TILE_MAX_PX", 96.0))
	var tiles := 0
	for c in camps:
		var it: Dictionary = model.get_item(str((c as Dictionary)["id"]))
		if _card_rect(canvas, it).size.x < tile_max:
			tiles += 1
	var labels: Array = canvas.get("_tile_labels")
	print("graphfest: zoom %.3f, %d of %d camps drawn as tiles, %d tile labels queued" % [
		float(canvas.get("_zoom")), tiles, camps.size(), labels.size()])
	_ok(camps.size() > 0 and tiles == camps.size() and labels.size() >= camps.size(),
		"zoomed out, every camp is a festival tile")
	_shot(vp, dir, "01_tiles")

	# --- 3. peek and a seamless enter ---------------------------------------
	var camp: Dictionary = model.get_item(str((camps[camps.size() / 2] as Dictionary)["id"]))
	var cid := str(camp.get("id", ""))
	var cscope := str(camp.get("child_scope_id", ""))
	var gc := Vector2(float(camp.get("x", 0.0)) + float(camp.get("width", 220.0)) * 0.5,
		float(camp.get("y", 0.0)) + float(camp.get("height", 150.0)) * 0.5)
	var z := canvas.size.x * 0.4 / float(camp.get("width", 220.0))
	canvas.call("stop_fly")
	canvas.set("_zoom", z)
	canvas.set("_pan", -gc * z)
	canvas.queue_redraw()
	await _frames(tree, 3)
	var rect := _card_rect(canvas, camp)
	_ok(bool(canvas.call("draws_peek", camp, rect)), "a big camp card shows its live interior (%.0f px)" % rect.size.x)
	_shot(vp, dir, "02_peek")
	# Where the peek draws each item...
	var pr: Rect2 = canvas.call("card_peek_rect", rect)
	var gb: Rect2 = canvas.call("_scope_content_graph_bbox", cscope)
	var m: Dictionary = canvas.call("_view_for_bbox_in_rect", gb, pr)
	var origin: Vector2 = canvas.size * 0.5 + (m["pan"] as Vector2)
	var kid: Dictionary = model.get_items_in_scope(cscope)[0]
	var peek_tl := origin + Vector2(float(kid.get("x", 0.0)), float(kid.get("y", 0.0))) * float(m["zoom"])
	# ...is where the child canvas starts after the swap (same frame).
	sgv.call("_enter_compound_animated", cid)
	var start_tl: Vector2 = canvas.call("_item_screen_tl", kid, canvas.size * 0.5)
	print("graphfest: peek drew %s at %s, child canvas starts it at %s" % [
		str(kid.get("id", "")), str(peek_tl), str(start_tl)])
	_ok(str(sgv.get("_active_scope_id")) == cscope and peek_tl.distance_to(start_tl) < 1.5,
		"entering starts the camp's canvas exactly where the peek drew it")
	await _wait(tree, 0.6)
	_shot(vp, dir, "03_inside")
	sgv.call("_jump_to_scope_index", 0)
	await _wait(tree, 0.6)
	# A real wheel zoom from the peek all the way in commits into the camp.
	canvas.call("stop_fly")
	canvas.set("_zoom", z)
	canvas.set("_pan", -gc * z)
	canvas.queue_redraw()
	await _frames(tree, 3)
	var mid := canvas.get_global_rect().get_center()
	await HarnessInput.mouse_move(vp, mid)
	var notches := 0
	while str(sgv.get("_active_scope_id")) == "root" and notches < 30:
		await _wheel(vp, mid, false)
		notches += 1
	print("graphfest: %d wheel notches in from the peek to the camp" % notches)
	_ok(str(sgv.get("_active_scope_id")) == cscope, "wheeling in through the peek enters the camp")
	await _wait(tree, 0.5)

	# --- 4. Site Plan inside the camp ---------------------------------------
	sgv.call("_on_mode_chip_pressed", GraphSiteLayout.VIEW_SITE)
	await _wait(tree, 1.2)
	sgv.call("_set_scope_trail", sgv.call("_trail_to_scope", cscope), "")
	await _wait(tree, 1.0)
	var kids := model.get_items_in_scope(cscope)
	var placed := 0
	var on_screen := 0
	var view := Rect2(Vector2.ZERO, canvas.size)
	for k in kids:
		var kd: Dictionary = k
		if GraphSiteLayout.has_site_coords(kd):
			placed += 1
			var c: Vector2 = (canvas.call("_item_screen_tl", kd, canvas.size * 0.5) as Vector2) \
				+ (canvas.call("_item_screen_size", kd) as Vector2) * 0.5
			if view.has_point(c):
				on_screen += 1
	print("graphfest: Site Plan inside %s: %d items, %d placed, %d on screen" % [
		str((camp.get("specs", {}) as Dictionary).get("name", "")), kids.size(), placed, on_screen])
	_ok(placed == kids.size(), "every item in the camp has a place on the map")
	_ok(on_screen == kids.size(), "Site Plan frames the camp's items")
	_shot(vp, dir, "04_site_inside")
	sgv.call("_on_mode_chip_pressed", GraphSiteLayout.VIEW_GLOBE)
	await _wait(tree, 1.5)
	_shot(vp, dir, "05_globe_inside")
	sgv.call("_on_mode_chip_pressed", GraphSiteLayout.VIEW_SITE)
	await _wait(tree, 1.0)
	await HarnessInput.mouse_move(vp, mid)
	await HarnessInput.key(vp, KEY_ESCAPE)
	await _wait(tree, 0.8)
	var cr := _card_rect(canvas, model.get_item(cid))
	_ok(str(sgv.get("_active_scope_id")) == "root" and view.has_point(cr.get_center()),
		"Esc goes back out on the map with the camp in view")
	_shot(vp, dir, "06_site_out")

	sgv.call("_on_mode_chip_pressed", GraphSiteLayout.VIEW_FREEFORM)
	sgv.call("close_graph_view")
	return {"ok": _fails.is_empty(), "fails": _fails}
