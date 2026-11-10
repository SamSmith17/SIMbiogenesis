extends RefCounted

## The ring in 3D on a real graph (sandbox), with REAL input:
##   tools\harness.ps1 -World w6af22bac295d -RunScript res://tools/checks/graph_3d_view_check.gd -Label graph_3d -Timeout 900
## Layout ▾ → 3D: nested spheres through the menu's own handler: the ring
## arrangement under it, the cards eased off their flat places, the near
## side drawn on top, nothing written to x/y. A real Ctrl+drag orbits (yaw
## moves, the picture moves, the cards' x/y do not); a Ctrl-click that does
## not move still toggles a node in the selection; a plain press selects and
## drags nothing. Then the torus (and from straight above it is the flat
## ring), the 3D state in the save, Flat ring easing back. A shot per state.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("graph3d %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


func _wait(tree: SceneTree, s: float) -> void:
	await tree.create_timer(s, true, false, true).timeout


func _shot(vp: Viewport, dir: String, name: String) -> void:
	vp.get_texture().get_image().save_png("%s/%s.png" % [dir, name])


func _xy(model: GraphModel) -> Dictionary:
	var out := {}
	for it in model.get_items_in_scope("root"):
		var d: Dictionary = it
		out[str(d["id"])] = Vector2(float(d.get("x", 0.0)), float(d.get("y", 0.0)))
	return out


func _same_xy(a: Dictionary, b: Dictionary) -> bool:
	for k in a:
		if not b.has(k) or (a[k] as Vector2).distance_to(b[k] as Vector2) > 0.01:
			return false
	return true


func _screen_rect(canvas: Control, it: Dictionary) -> Rect2:
	var c := canvas.size * 0.5
	return Rect2(canvas.call("_item_screen_tl", it, c), canvas.call("_item_screen_size", it))


## Canvas-local point -> viewport point (what push_input wants).
func _vp(canvas: Control, p: Vector2) -> Vector2:
	return canvas.get_global_transform_with_canvas() * p


## A canvas point with no card under it, near `want`.
func _empty_point(canvas: Control, want: Vector2) -> Vector2:
	for r in [0.0, 40.0, 80.0, 140.0, 200.0, 280.0]:
		for k in 12:
			var p := want + Vector2(cos(TAU * k / 12.0), sin(TAU * k / 12.0)) * float(r)
			if Rect2(Vector2(20, 60), canvas.size - Vector2(40, 120)).has_point(p) \
					and (canvas.call("_item_at_screen", p) as Dictionary).is_empty():
				return p
	return want


## Mean frame time while the camera turns every frame (the worst case:
## every card re-projected, the shells and wires redrawn).
func _orbit_ms(tree: SceneTree, canvas: Control, v3: GraphView3D) -> float:
	await tree.process_frame
	var t0 := Time.get_ticks_usec()
	for _i in 60:
		v3.orbit_by(Vector2(0.03, 0.0))
		canvas.queue_redraw()
		await tree.process_frame
	return float(Time.get_ticks_usec() - t0) / 60000.0


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
	var consts: Dictionary = sgv.get_script().get_script_constant_map()
	var id_sphere := int(consts.get("LAYOUT_3D_SPHERE", 25))
	var id_torus := int(consts.get("LAYOUT_3D_TORUS", 26))
	var id_flat := int(consts.get("LAYOUT_3D_FLAT", 27))
	_ok(pm.get_item_index(id_sphere) >= 0 and pm.get_item_index(id_torus) >= 0
		and pm.get_item_index(id_flat) >= 0, "Layout ▾ lists the 3D views and Flat ring")
	var n_cards := model.get_items_in_scope("root").size()
	print("graph3d: %d root cards" % n_cards)

	var ms_flat := await _orbit_ms(tree, canvas, GraphView3D.new())
	print("graph3d: flat graph %.1f ms a frame (baseline)" % ms_flat)

	# --- Nested spheres --------------------------------------------------
	var t0 := Time.get_ticks_usec()
	pm.id_pressed.emit(id_sphere)
	var enter_ms := (Time.get_ticks_usec() - t0) / 1000.0
	await _wait(tree, 0.3)
	_shot(vp, dir, "00_sphere_blending")
	await _wait(tree, 1.0)
	_ok(str(canvas.call("view_3d_mode")) == GraphSchema3D.SPHERE, "3D: nested spheres is up")
	_ok(str(sgv.get("_layout_schema")) == GraphSchemaLayout.RING, "the ring arrangement is under it")
	_ok(pm.is_item_checked(pm.get_item_index(id_sphere)), "the menu shows it checked")
	var v3: GraphView3D = canvas.get("_v3")
	var lay: Dictionary = v3.layout
	var placed := (lay.get("pos", {}) as Dictionary).size()
	print("graph3d: sphere layout of %d nodes in %.0f ms (enter)" % [placed, enter_ms])
	var n_layout := GraphLayout.filter_layout_items(model.get_items_in_scope("root")).size()
	_ok(placed == n_layout, "every laid-out root card is in the 3D layout (%d of %d)" % [placed, n_layout])
	var xy0 := _xy(model)
	# Cards: projected (not at their flat x/y), near side drawn last.
	var vis: Array = canvas.call("_visible_items")
	var off_flat := 0
	var c := canvas.size * 0.5
	var pan: Vector2 = canvas.get("_pan")
	var zoom := float(canvas.get("_zoom"))
	for it in vis:
		var d: Dictionary = it
		var flat_tl := c + pan + Vector2(float(d["x"]), float(d["y"])) * zoom
		if (canvas.call("_item_screen_tl", d, c) as Vector2).distance_to(flat_tl) > 4.0:
			off_flat += 1
	_ok(off_flat > vis.size() / 2, "the cards stand in 3D, off their flat places (%d of %d)" % [off_flat, vis.size()])
	var depth_ok := true
	for k in range(1, vis.size()):
		var za := v3.depth_of(str((vis[k - 1] as Dictionary)["id"]))
		var zb := v3.depth_of(str((vis[k] as Dictionary)["id"]))
		if za != -INF and zb != -INF and za > zb + 1e-3:
			depth_ok = false
	_ok(depth_ok, "the cards are drawn far side first, near side on top")
	# Nothing on screen? The fit should hold the whole cell.
	var on_screen := 0
	for it2 in vis:
		if Rect2(Vector2.ZERO, canvas.size).encloses(_screen_rect(canvas, it2 as Dictionary)):
			on_screen += 1
	_ok(on_screen >= vis.size() * 0.8, "the fit holds the cell on screen (%d of %d)" % [on_screen, vis.size()])
	_shot(vp, dir, "01_sphere")
	var ms_s := await _orbit_ms(tree, canvas, v3)
	print("graph3d: sphere orbiting %.1f ms a frame" % ms_s)
	_ok(ms_s < maxf(ms_flat * 1.6, ms_flat + 12.0), "the sphere orbits smoothly (%.1f ms a frame)" % ms_s)

	# REAL Ctrl+drag on empty canvas: orbits.
	var yaw0 := v3.yaw
	var pitch0 := v3.pitch
	var probe: Dictionary = vis[vis.size() - 1]
	var probe_r0 := _screen_rect(canvas, probe)
	var a := _empty_point(canvas, canvas.size * 0.5 + Vector2(-260, 120))
	await HarnessInput.drag(vp, _vp(canvas, a), _vp(canvas, a + Vector2(320, -90)), 16, true)
	await _frames(tree, 3)
	print("graph3d: yaw %.3f -> %.3f, pitch %.3f -> %.3f" % [yaw0, v3.yaw, pitch0, v3.pitch])
	_ok(absf(v3.yaw - yaw0) > 0.5, "Ctrl+drag turns the camera (yaw %.2f rad)" % (v3.yaw - yaw0))
	_ok(absf(v3.pitch - pitch0) > 0.1, "Ctrl+drag tilts the camera (pitch %.2f rad)" % (v3.pitch - pitch0))
	_ok(_screen_rect(canvas, probe).get_center().distance_to(probe_r0.get_center()) > 20.0,
		"the cards move with the orbit")
	_ok(_same_xy(xy0, _xy(model)), "orbiting writes nothing to the cards' x/y")
	await _wait(tree, 0.8)
	_shot(vp, dir, "02_sphere_orbited")

	# A Ctrl-click that does not move toggles a node in the selection.
	vis = canvas.call("_visible_items")
	var near: Dictionary = vis[vis.size() - 1]
	var np := _screen_rect(canvas, near).get_center()
	canvas.call("_select_item", "")
	await _frames(tree, 2)
	await HarnessInput.mouse_move(vp, _vp(canvas, np), true)
	await HarnessInput.mouse_press(vp, _vp(canvas, np), true, false, true)
	await HarnessInput.mouse_press(vp, _vp(canvas, np), false, false, true)
	await _frames(tree, 2)
	var sel: Array = canvas.get("selected_item_ids")
	_ok(sel.has(str(near["id"])), "a Ctrl-click on the nearest card selects it (%s)" % str(near["id"]))
	_ok(absf(v3.yaw - yaw0) > 0.5 and _same_xy(xy0, _xy(model)), "the Ctrl-click neither orbits nor moves")
	# A plain drag on a machine card moves it over its shell: it follows the
	# pointer, stays on the sphere, x/y untouched, no wire started from a
	# card behind it, ONE undo step, and Reset 3D placements puts it back.
	var n_conn := model.connections.size()
	vis = canvas.call("_visible_items")
	var mv: Dictionary = {}
	for k0 in range(vis.size() - 1, -1, -1):
		var cand: Dictionary = vis[k0]
		if str((v3.layout.get("role", {}) as Dictionary).get(str(cand["id"]), "")) == "outer":
			mv = cand
			break
	var mv_id := str(mv.get("id", ""))
	var mp := _screen_rect(canvas, mv).get_center()
	var r_shell := ((v3.layout["pos"] as Dictionary)[mv_id] as Vector3).length()
	var to := mp + Vector2(110, 50)
	await HarnessInput.drag(vp, _vp(canvas, mp), _vp(canvas, to), 12)
	await _frames(tree, 3)
	var after := _screen_rect(canvas, model.get_item(mv_id)).get_center()
	var stored: Variant = GraphSchema3D.override_of(model.get_item(mv_id), GraphSchema3D.SPHERE)
	print("graph3d: dragged %s %.0f px (%.0f px off the pointer), stored %s" % [
		mv_id, after.distance_to(mp), after.distance_to(to), str(stored)])
	_ok(not mv_id.is_empty() and after.distance_to(to) < 40.0, "a plain drag carries the card over its shell (%.0f px off the pointer)" % after.distance_to(to))
	_ok(absf(((v3.layout["pos"] as Dictionary)[mv_id] as Vector3).length() - r_shell) < 1.0, "the dragged card stays on its sphere")
	_ok(stored is Vector3 and _same_xy(xy0, _xy(model)) and model.connections.size() == n_conn,
		"the place is kept on the card, x/y untouched, no wire made")
	_ok(str(canvas.get("selected_item_id")) == mv_id, "the dragged card is selected")
	_shot(vp, dir, "02b_sphere_card_dragged")
	sgv.call("_do_undo")
	await _frames(tree, 4)
	_ok(GraphSchema3D.override_of(model.get_item(mv_id), GraphSchema3D.SPHERE) == null,
		"undo puts the card back on the lattice")
	sgv.call("_do_redo")
	await _frames(tree, 4)
	_ok(GraphSchema3D.override_of(model.get_item(mv_id), GraphSchema3D.SPHERE) is Vector3, "redo brings the place back")
	pm.id_pressed.emit(int(consts.get("LAYOUT_3D_RESET", 28)))
	await _frames(tree, 4)
	_ok(GraphSchema3D.override_of(model.get_item(mv_id), GraphSchema3D.SPHERE) == null,
		"Reset 3D placements clears it")
	var near_id := mv_id
	# Frame the selection (F): framed as drawn in 3D.
	canvas.call("fit_items_to_view", [near_id])
	await _wait(tree, 0.6)
	var fr := _screen_rect(canvas, model.get_item(near_id))
	print("graph3d: framed %s at %s, canvas centre %s, zoom %.3f, has %s" % [near_id, str(fr.get_center()),
		str(canvas.size * 0.5), float(canvas.get("_zoom")), str(v3.has(near_id))])
	_ok(fr.get_center().distance_to(canvas.size * 0.5) < 60.0, "framing a node centres it as drawn in 3D")
	_shot(vp, dir, "03_sphere_framed")

	# --- Into a group and back ---------------------------------------------
	var grp: Dictionary = {}
	# The nearest group card (the list is far side first).
	for it6 in canvas.call("_visible_items"):
		var d6: Dictionary = it6
		var sp6: Dictionary = d6.get("specs", {}) if d6.get("specs", {}) is Dictionary else {}
		# A plain group (a vehicle / camp card has a Watch button of its own).
		if str(d6.get("type", "")) == "compound" and not str(d6.get("child_scope_id", "")).is_empty() 				and v3.has(str(d6["id"])) and not sp6.has("vehicle_prop_id") and not sp6.has("camp_lot_id"):
			grp = d6
	if grp.is_empty():
		_ok(false, "a group card to open")
	else:
		canvas.call("fit_items_to_view", [str(grp["id"])], 0.3)
		# A long move flies out and back in (up to ~1 s): let it land.
		await _wait(tree, 1.6)
		var gp := _screen_rect(canvas, grp)
		# A point of the card nothing else covers.
		var gpc := gp.get_center()
		for fy in [0.5, 0.35, 0.65, 0.2, 0.8]:
			var found := false
			for fx in [0.5, 0.3, 0.7, 0.15, 0.85]:
				var pt := gp.position + gp.size * Vector2(float(fx), float(fy))
				if str((canvas.call("_item_at_screen", pt) as Dictionary).get("id", "")) == str(grp["id"]) 						and (canvas.call("_port_at_screen", pt, "", "", 14.0) as Dictionary).is_empty():
					gpc = pt
					found = true
					break
			if found:
				break
		print("graph3d: before the clicks, on top at %s: %s; group rect %s; type %s/%s" % [str(gpc),
			str((canvas.call("_item_at_screen", gpc) as Dictionary).get("id", "")), str(gp),
			str(grp.get("type", "")), str((grp.get("specs", {}) as Dictionary).get("compound_kind", ""))])
		var top_before := str((canvas.call("_item_at_screen", gpc) as Dictionary).get("id", ""))
		print("graph3d: yaw %.4f pitch %.4f, depth grp %.1f, zoom %.3f pan %s" % [v3.yaw, v3.pitch, v3.depth_of(str(grp["id"])),
			float(canvas.get("_zoom")), str(canvas.get("_pan"))])
		await HarnessInput.mouse_move(vp, _vp(canvas, gpc))
		print("graph3d: after the move: on top %s, yaw %.4f, zoom %.3f pan %s" % [
			str((canvas.call("_item_at_screen", gpc) as Dictionary).get("id", "")), v3.yaw,
			float(canvas.get("_zoom")), str(canvas.get("_pan"))])
		await HarnessInput.click(vp, _vp(canvas, gpc))
		print("graph3d: after one click selected=%s scope=%s consumed=%s resize=%s marquee=%s" % [
			str(canvas.get("selected_item_id")), str(sgv.get("_active_scope_id")), str(canvas.get("_press_consumed")),
			str(canvas.get("_resize_dragging")), str(canvas.get("_marquee_selecting"))])
		await HarnessInput.click(vp, _vp(canvas, gpc), true)
		await _wait(tree, 1.0)
		var sc := str(sgv.get("_active_scope_id"))
		print("graph3d: group %s at %s (on top there: %s), scope now %s" % [str(grp["id"]), str(gpc),
			str((canvas.call("_item_at_screen", gpc) as Dictionary).get("id", "")), sc])
		_ok(sc != "root" and not bool(canvas.call("_v3_on")) and str(canvas.call("view_3d_mode")) == GraphSchema3D.SPHERE,
			"double-clicking a group from 3D opens it, flat inside (%s)" % str(grp.get("name", grp["id"])))
		_shot(vp, dir, "03b_inside_group")
		await HarnessInput.key(vp, KEY_ESCAPE)
		await _wait(tree, 1.0)
		var back := _screen_rect(canvas, model.get_item(str(grp["id"])))
		_ok(str(sgv.get("_active_scope_id")) == "root" and bool(canvas.call("_v3_on")),
			"Esc comes back out to the 3D view")
		_ok(Rect2(Vector2.ZERO, canvas.size).intersects(back), "the group just left is in view as drawn in 3D")
		_shot(vp, dir, "03c_back_out")
		var xy1 := _xy(model)
		var moved_ids: Array = []
		for k7 in xy0:
			if xy1.has(k7) and (xy0[k7] as Vector2).distance_to(xy1[k7] as Vector2) > 0.01:
				moved_ids.append("%s %s->%s" % [k7, str(xy0[k7]), str(xy1[k7])])
		print("graph3d: x/y moved by the group round trip: %s" % str(moved_ids))

	# --- Torus -------------------------------------------------------------
	# Live layout (on in this world) settles the flat ring once it is shown
	# again; for the "back where it was" check below, hold it off.
	var live0 := bool(sgv.get("_layout_live"))
	print("graph3d: Live layout was %s (held still while in 3D: round trip above)" % ("on" if live0 else "off"))
	sgv.call("set_live_layout", false)
	xy0 = _xy(model)
	pm.id_pressed.emit(id_torus)
	await _wait(tree, 1.3)
	_ok(str(canvas.call("view_3d_mode")) == GraphSchema3D.TORUS, "3D: torus is up")
	_shot(vp, dir, "04_torus")
	var ms_t := await _orbit_ms(tree, canvas, v3)
	print("graph3d: torus orbiting %.1f ms a frame" % ms_t)
	_ok(ms_t < maxf(ms_flat * 1.6, ms_flat + 12.0), "the torus orbits smoothly (%.1f ms a frame)" % ms_t)
	v3.yaw = float(GraphSchema3D.DEFAULT_VIEW[GraphSchema3D.TORUS]["yaw"])
	v3.orbit_by(Vector2.ZERO)
	v3.yaw = 0.0
	v3.pitch = PI * 0.5 - 0.001
	v3.orbit_by(Vector2.ZERO)
	canvas.queue_redraw()
	await _frames(tree, 3)
	_shot(vp, dir, "05_torus_from_above")
	# From above, the machines run round in the same order as the flat ring.
	var ids_ring: Array = []
	for gd in (v3.layout.get("groups", []) as Array):
		ids_ring.append_array((gd as Dictionary)["ids"])
	var centre_scr: Vector2 = c + (canvas.get("_pan") as Vector2) + v3.centre() * float(canvas.get("_zoom"))
	# Unwrapped round the circle, one lap at most: a machine out of order
	# would cost a second lap.
	var prev := -INF
	var first := INF
	for iid in ids_ring:
		var it3 := model.get_item(str(iid))
		var ang := (_screen_rect(canvas, it3).get_center() - centre_scr).angle()
		while ang < prev - 0.05:
			ang += TAU
		if first == INF:
			first = ang
		prev = ang
	_ok(prev - first < TAU + 0.2, "the torus from above keeps the ring's order (%.2f rad round)" % (prev - first))
	await HarnessInput.drag(vp, _vp(canvas, _empty_point(canvas, canvas.size * 0.5 + Vector2(0, 260))),
		_vp(canvas, _empty_point(canvas, canvas.size * 0.5 + Vector2(0, 260)) + Vector2(0, 260)), 14, true)
	await _wait(tree, 0.8)
	_shot(vp, dir, "06_torus_tilted")

	# --- Save + flat --------------------------------------------------------
	var save: Dictionary = sgv.call("collect_save_state")
	var g3: Dictionary = save.get("graph_3d", {}) if save.get("graph_3d", {}) is Dictionary else {}
	_ok(str(g3.get("mode", "")) == GraphSchema3D.TORUS, "the save carries the 3D view (%s)" % str(g3))
	pm.id_pressed.emit(id_flat)
	await _wait(tree, 0.25)
	_shot(vp, dir, "07_flattening")
	await _wait(tree, 1.0)
	_ok(str(canvas.call("view_3d_mode")).is_empty() and not v3.active(), "Flat ring brings the 2D graph back")
	_ok(_same_xy(xy0, _xy(model)), "the flat ring is where it was")
	_shot(vp, dir, "08_flat")
	pm.id_pressed.emit(id_sphere)
	await _wait(tree, 0.4)
	sgv.call("tidy_layout", false, true)
	await _wait(tree, 1.0)
	_ok(not v3.active(), "Tidy leaves the 3D view")
	sgv.call("set_live_layout", live0)
	sgv.call("close_graph_view")
	await _frames(tree, 4)
	print("graph3d: %s" % ("PASS" if _fails.is_empty() else "FAIL %s" % str(_fails)))
	return {"ok": _fails.is_empty(), "fails": _fails}
