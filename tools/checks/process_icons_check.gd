extends RefCounted

## The Process lens draws equipment as pictures of its 3D models (sandbox).
##   tools\harness.ps1 -World w6af22bac295d -RunScript res://tools/checks/process_icons_check.gd -Label process_icons -Timeout 900
## - seeds a line: a store → a shredder (has a model) → a store → a
##   biogas digester (has a model) → a store → a greywater filter (no
##   model), and opens the Process lens by a real click on its chip;
## - the two machines with models are drawn as pictures (side view by
##   default) and take their picture's shape; the filter gets a pictogram;
## - the bottom bar's Pictures menu (a real click + a real pick) switches
##   every picture to the front view, then to boxes only, then back;
## - a real click on a pictured machine opens its faceplate; a real click on
##   its picture button switches that one node only;
## - the view is in the graph's save state;
## - shots: side, front, ¾, top, a close-up, the world's own picture.
## Removes what it seeded. Shots under screenshots/process_icons/.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("process-icons %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func _shot(main: Node, name: String) -> void:
	var dir := "user://screenshots/process_icons"
	DirAccess.make_dir_recursive_absolute(dir)
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [dir, name])


func _center(mimic: Control, id: String) -> Vector2:
	var e: Dictionary = mimic.call("element_by_id", id)
	if e.is_empty():
		return Vector2(-1, -1)
	return mimic.get_global_transform() * (mimic.call("element_rect", e) as Rect2).get_center()


## Wait (up to `max_frames`) until `n` pictures are drawn.
func _wait_pictures(tree: SceneTree, lens: Control, mimic: Control, n: int, max_frames: int = 900) -> Vector2i:
	var got := Vector2i.ZERO
	for _i in max_frames:
		await tree.process_frame
		lens.call("refresh")
		got = mimic.call("icons_drawn")
		if got.x >= n:
			break
	return got


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var vp := main.get_viewport()
	var view: Node = ServiceLocator.graph()
	_ok(view != null, "there is a graph view")
	if view == null:
		return {"ok": false, "fails": _fails}
	var model: GraphModel = view.get("model")
	main.set("time_scale", 0.0)

	# ---- the world's own picture first ----
	view.call("open_graph_view")
	await _settle(tree, 20)
	var chips: Dictionary = view.get("_mode_chip_btns")
	var chip: Button = chips.get("process") as Button
	_ok(chip != null, "the lens switcher has a Process chip")
	if chip == null:
		return {"ok": false, "fails": _fails}
	await HarnessInput.click(vp, HarnessInput.center_of(chip))
	await _settle(tree, 30)
	var canvas: Control = view.get("_graph_canvas")
	var lens: Control = canvas.call("process_lens")
	var mimic: Control = lens.get("mimic")
	_ok(str(lens.call("icon_view")) == MimicIcons.VIEW_SIDE, "pictures are side views by default")
	var world_pics: Vector2i = await _wait_pictures(tree, lens, mimic, 1, 600)
	print("process-icons: the world's picture: %d pictures, %d pictograms" % [world_pics.x, world_pics.y])
	mimic.call("fit")
	await _settle(tree, 10)
	_shot(main, "00_world_side")

	# ---- seed a line far from everything ----
	var ids := ["pi_t1", "pi_shred", "pi_t2", "pi_bio", "pi_t3", "pi_filter", "pi_t4"]
	var ox := -6000.0
	var specs_t := func(nm: String) -> Dictionary:
		return {"name": nm, "resource_kind": "water", "capacity_qty": 500.0, "capacity_unit": "L", "level": 0.5}
	model.add_item({"id": "pi_t1", "type": "resource", "x": ox, "y": -6000.0, "width": 120.0, "height": 120.0, "specs": specs_t.call("Icon Test In")})
	model.add_item({"id": "pi_shred", "type": "processor", "x": ox + 200.0, "y": -6000.0, "width": 160.0, "height": 100.0,
		"specs": {"name": "Icon Test Shredder", "model_id": "pp_shredder", "requested_state": "on", "node_state": "running"}})
	model.add_item({"id": "pi_t2", "type": "resource", "x": ox + 400.0, "y": -6000.0, "width": 120.0, "height": 120.0, "specs": specs_t.call("Icon Test Mid")})
	model.add_item({"id": "pi_bio", "type": "processor", "x": ox + 600.0, "y": -6000.0, "width": 160.0, "height": 100.0,
		"specs": {"name": "Icon Test Digester", "model_id": "home_biogas_2", "requested_state": "off"}})
	model.add_item({"id": "pi_t3", "type": "resource", "x": ox + 800.0, "y": -6000.0, "width": 120.0, "height": 120.0, "specs": specs_t.call("Icon Test Grey")})
	model.add_item({"id": "pi_filter", "type": "processor", "x": ox + 1000.0, "y": -6000.0, "width": 160.0, "height": 100.0,
		"specs": {"name": "Icon Test Greywater Filter", "requested_state": "on"}})
	model.add_item({"id": "pi_t4", "type": "resource", "x": ox + 1200.0, "y": -6000.0, "width": 120.0, "height": 120.0, "specs": specs_t.call("Icon Test Out")})
	for k in ids.size() - 1:
		var a: String = ids[k]
		var b: String = ids[k + 1]
		model.add_connection({"id": "pi_w%d" % k, "polarity": "resource", "resource_type": "water",
			"source_item_id": a, "source_handle_id": "hub_out" if a.begins_with("pi_t") else "res_out_0",
			"target_item_id": b, "target_handle_id": "hub_in" if b.begins_with("pi_t") else "res_in_0"})
	await _settle(tree, 10)
	lens.call("refresh", true)
	var got := Vector2i.ZERO
	for _w in 3000:
		await tree.process_frame
		lens.call("refresh")
		var im: Dictionary = mimic.get("icons")
		if im.get("pi_shred") is Texture2D and im.get("pi_bio") is Texture2D:
			break
	got = mimic.call("icons_drawn")
	var e_sh: Dictionary = mimic.call("element_by_id", "pi_shred")
	var e_bio: Dictionary = mimic.call("element_by_id", "pi_bio")
	var e_f: Dictionary = mimic.call("element_by_id", "pi_filter")
	var icons: Dictionary = mimic.get("icons")
	var glyphs: Dictionary = mimic.get("glyphs")
	_ok(icons.get("pi_shred") is Texture2D and icons.get("pi_bio") is Texture2D,
		"the two machines with models are drawn as pictures (%d pictures in all)" % got.x)
	_ok(bool(e_sh.get("icon", false)) and bool(e_bio.get("icon", false)), "and laid out as pictures")
	_ok(glyphs.get("pi_filter") is Texture2D and not bool(e_f.get("icon", false)), "the filter has no model: it gets a pictogram")
	var tex: Texture2D = icons.get("pi_shred")
	if tex != null:
		var asp := MimicIcons.aspect(tex)
		var want: Vector2 = MimicGraphSource.icon_size(asp)
		_ok((e_sh["size"] as Vector2).distance_to(want) < 1.0, "the shredder takes its picture's shape (%s, aspect %.2f)" % [str(e_sh["size"]), asp])
		var img := tex.get_image()
		var grey := 0
		var opaque := 0
		for y in range(0, img.get_height(), 3):
			for x in range(0, img.get_width(), 3):
				var c := img.get_pixel(x, y)
				if c.a > 0.95:
					opaque += 1
					if maxf(absf(c.r - c.g), absf(c.g - c.b)) < 0.12:
						grey += 1
		_ok(opaque > 50 and grey == opaque, "the picture is in the picture's own greys (%d of %d)" % [grey, opaque])
	# Pipes run into the pictures' sides.
	var pipes: Array = (mimic.get("doc") as Dictionary).get("pipes", [])
	var joined := true
	for p in pipes:
		if str(p["id"]) == "pi_w1":
			var pts: PackedVector2Array = p["pts"]
			var left := (e_sh["pos"] as Vector2).x + (e_sh["size"] as Vector2).x * 0.5
			joined = absf(pts[0].x - left) < 1.0
	_ok(joined, "the line out of the shredder leaves its picture's side")
	var cs := _center(mimic, "pi_shred")
	var cb := _center(mimic, "pi_t4")
	# Frame the seeded line.
	mimic.call("fit")
	await _settle(tree, 4)
	var bb := Rect2(cs, Vector2.ZERO).expand(cb)
	print("process-icons: seeded line at %s" % str(bb))
	_shot(main, "01_side_all")
	_frame_on(mimic, ["pi_t1", "pi_t4"])
	await _settle(tree, 4)
	_shot(main, "01b_side_line")
	mimic.call("fit")
	await _settle(tree, 4)
	var cost_pics := await _cost(tree, mimic)

	# ---- the Pictures menu, by real clicks ----
	var opt: OptionButton = lens.get("_icon_opt")
	_ok(opt != null and opt.is_visible_in_tree(), "the bottom bar has a Pictures menu")
	for want_view in [MimicIcons.VIEW_FRONT, MimicIcons.VIEW_3Q, MimicIcons.VIEW_TOP, MimicIcons.VIEW_BOXES, MimicIcons.VIEW_SIDE]:
		await HarnessInput.click(vp, HarnessInput.center_of(opt))
		await _settle(tree, 6)
		var pop := opt.get_popup()
		var idx := -1
		for i in opt.item_count:
			if str(opt.get_item_metadata(i)) == want_view:
				idx = i
		_ok(pop.visible, "a real click opens the Pictures list")
		pop.hide()
		opt.select(idx)
		opt.item_selected.emit(idx)
		await _settle(tree, 6)
		_ok(str(lens.call("icon_view")) == want_view, "Pictures → %s" % str(MimicIcons.LABELS[want_view]))
		if want_view == MimicIcons.VIEW_BOXES:
			lens.call("refresh", true)
			await _settle(tree, 4)
			var none: Vector2i = mimic.call("icons_drawn")
			_ok(none.x == 0 and not bool((mimic.call("element_by_id", "pi_shred") as Dictionary).get("icon", false)),
				"boxes only: no pictures (%d)" % none.x)
			mimic.call("fit")
			await _settle(tree, 4)
			var cost_boxes := await _cost(tree, mimic)
			print("process-icons: one redraw of the whole picture: %.2f ms with pictures, %.2f ms boxes only" % [cost_pics, cost_boxes])
			_ok(cost_pics < cost_boxes + 4.0, "pictures cost little to draw (%.2f vs %.2f ms)" % [cost_pics, cost_boxes])
			_shot(main, "05_boxes")
		elif want_view != MimicIcons.VIEW_SIDE:
			var t_before: Texture2D = (mimic.get("icons") as Dictionary).get("pi_shred")
			_ok(t_before != null, "while the %s picture is drawn, the last one stays (no boxes)" % want_view)
			var t2: Texture2D = null
			var svc: Node = canvas.get("model_preview_service")
			var t_start := Time.get_ticks_msec()
			for _w in 3000:
				await tree.process_frame
				lens.call("refresh")
				t2 = svc.call("get_icon", "pp_shredder", want_view, {}) as Texture2D
				if _w % 120 == 0:
					print("process-icons: %s after %d frames (%d ms): queue %d, busy %s, rendered %d" % [want_view, _w,
						Time.get_ticks_msec() - t_start, (svc.get("_queue") as Array).size(), str(svc.get("_busy")), svc.get("icons_rendered")])
				if t2 != null and (mimic.get("icons") as Dictionary).get("pi_shred") == t2:
					print("process-icons: the %s pictures took %d ms" % [want_view, Time.get_ticks_msec() - t_start])
					break
			_ok(t2 != null and t2 != tex and (mimic.get("icons") as Dictionary).get("pi_shred") == t2, "the %s picture lands" % want_view)
			if want_view == MimicIcons.VIEW_FRONT:
				# Frame time while the rest of the view is drawn vs once it is done.
				var busy_ms := await _frame_ms(tree, lens, 60)
				for _q in 6000:
					await tree.process_frame
					lens.call("refresh")
					if (svc.get("_queue") as Array).is_empty() and not bool(svc.get("_busy")):
						break
				var idle_ms := await _frame_ms(tree, lens, 60)
				print("process-icons: frame median %.1f ms / worst %.1f ms while drawing pictures, %.1f / %.1f ms after (one picture %.0f ms)" % [
					busy_ms.x, busy_ms.y, idle_ms.x, idle_ms.y, float(svc.get("last_icon_ms"))])
			_frame_on(mimic, ["pi_t1", "pi_t4"])
			await _settle(tree, 4)
			_shot(main, "0%d_%s" % [2 + MimicIcons.VIEWS.find(want_view) - 1, want_view])

	# ---- one node's own view: a real click on it, then on its picture button ----
	lens.call("refresh", true)
	await _wait_pictures(tree, lens, mimic, 2, 300)
	mimic.call("fit")
	await _settle(tree, 6)
	var at := _center(mimic, "pi_bio")
	await HarnessInput.mouse_move(vp, at)
	await _settle(tree, 3)
	await HarnessInput.click(vp, at)
	await _settle(tree, 8)
	var face: Control = lens.call("faceplate")
	var btn: Button = face.call("button", "icon_view") if face != null and face.visible else null
	_ok(btn != null, "a pictured machine's faceplate has a picture button")
	if btn != null:
		await HarnessInput.click(vp, HarnessInput.center_of(btn))
		await _settle(tree, 8)
		_ok(str(lens.call("icon_view_of", "pi_bio")) == MimicIcons.VIEW_FRONT and str(lens.call("icon_view_of", "pi_shred")) == MimicIcons.VIEW_SIDE,
			"it switches that node only (%s / %s)" % [str(lens.call("icon_view_of", "pi_bio")), str(lens.call("icon_view_of", "pi_shred"))])
		await _wait_pictures(tree, lens, mimic, 2, 600)
		_shot(main, "06_one_node_front")
	var saved: Dictionary = view.call("collect_save_state")
	var pic: Dictionary = saved.get("process_icons", {}) as Dictionary
	_ok(str(pic.get("view", "")) == MimicIcons.VIEW_SIDE and str((pic.get("per", {}) as Dictionary).get("pi_bio", "")) == MimicIcons.VIEW_FRONT,
		"the views are in the graph's save state")

	# ---- a close-up ----
	_frame_on(mimic, ["pi_shred", "pi_bio"])
	await _settle(tree, 6)
	_shot(main, "07_close")
	print("process-icons: one redraw %.2f ms" % float(mimic.call("draw_cost_ms")))

	# ---- clean up ----
	lens.call("set_node_icon_view", "pi_bio", "")
	for k in ids.size() - 1:
		model.remove_connection("pi_w%d" % k)
	for id in ids:
		model.remove_item(id)
	view.call("_apply_graph_view_mode", GraphSiteLayout.VIEW_FREEFORM)
	await _settle(tree, 6)
	return {"ok": _fails.is_empty(), "fails": _fails}


## Centre the view on these elements, close enough to read them.
func _frame_on(mimic: Control, ids: Array) -> void:
	var r := Rect2()
	var have := false
	for id in ids:
		var e: Dictionary = mimic.call("element_by_id", str(id))
		if e.is_empty():
			continue
		var c: Vector2 = mimic.call("moved_pos", e)
		var er := Rect2(c - (e["size"] as Vector2) * 0.5, e["size"])
		r = er if not have else r.merge(er)
		have = true
	if not have:
		return
	var sz: Vector2 = mimic.size
	mimic.set("_zoom", clampf(minf((sz.x - 120.0) / r.size.x, (sz.y - 120.0) / r.size.y), 0.1, 3.0))
	mimic.set("_pan", r.get_center())
	mimic.queue_redraw()


## Median cost of a redraw of the whole picture (ms).
func _cost(tree: SceneTree, mimic: Control) -> float:
	var vals: Array = []
	for _i in 9:
		mimic.queue_redraw()
		await tree.process_frame
		vals.append(float(mimic.call("draw_cost_ms")))
	vals.sort()
	return float(vals[4])


## Median and worst frame (ms) over `n` frames.
func _frame_ms(tree: SceneTree, lens: Control, n: int) -> Vector2:
	var vals: Array = []
	var t := Time.get_ticks_usec()
	for _i in n:
		await tree.process_frame
		lens.call("refresh")
		var now := Time.get_ticks_usec()
		vals.append(float(now - t) / 1000.0)
		t = now
	vals.sort()
	return Vector2(float(vals[n / 2]), float(vals[n - 1]))
