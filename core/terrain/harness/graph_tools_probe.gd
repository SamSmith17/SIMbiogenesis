extends Node

## `--capture=graphtools`: the graph's show-only views, the library's "In the
## world, not on the graph" drawer and the graph <-> world handoff, end to end
## on a real world. Everything it adds (two J lights, their graph loads) is
## removed again; the run is in the harness sandbox anyway.
##
## Lines are "graphtools PASS|FAIL — …"; one per assertion.

var main: Node = null
var shots_dir := "user://screenshots/graphtools"
var _fails := 0


func _check(ok: bool, what: String) -> void:
	if not ok:
		_fails += 1
	print("graphtools %s — %s" % ["PASS" if ok else "FAIL", what])


func _shot(name: String) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	if img != null:
		img.save_png("%s/%s.png" % [shots_dir, name])


func _wait(s: float) -> void:
	await get_tree().create_timer(s).timeout


func run() -> Dictionary:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(shots_dir))
	var gv := main.get_node_or_null("UILayer/SystemGraphView")
	if gv == null:
		_check(false, "SystemGraphView found")
		return {"failures": _fails}
	gv.call("open_graph_view")
	gv.call("_on_mode_chip_pressed", "freeform")
	await _wait(1.0)
	await _test_filter(gv)
	await _test_world_drawer(gv)
	await _test_handoff(gv)
	await _test_globe_connect(gv)
	await _test_globe_continuity(gv)
	gv.call("set_domain_filter", {})
	gv.call("close_graph_view")
	return {"failures": _fails}


func _test_filter(gv: Node) -> void:
	var canvas: Node = gv.get("_graph_canvas")
	var all_n := (canvas.call("_compute_visible_items") as Array).size()
	var all_c := (canvas.call("_compute_visible_connections") as Array).size()
	await _shot("filter_00_all")
	gv.call("set_domain_filter", GraphDomainFilter.preset("power"))
	await _wait(0.3)
	var vis: Array = canvas.call("_compute_visible_items")
	var conns: Array = canvas.call("_compute_visible_connections")
	var bad := 0
	for c in conns:
		if GraphDomainFilter.conn_domain(c as Dictionary) == GraphDomainFilter.WATER:
			bad += 1
	print("graphtools info — scope %d nodes / %d wires; Power shows %d / %d" % [all_n, all_c, vis.size(), conns.size()])
	_check(vis.size() <= all_n and conns.size() <= all_c, "Power shows a subset")
	_check(bad == 0, "no water wire under Power (%d)" % bad)
	var hidden := int(canvas.call("domain_hidden_count"))
	_check(hidden == all_n - vis.size(), "hidden count matches (%d)" % hidden)
	var model: GraphModel = gv.get("model")
	_check(model.items.size() > 0 and (canvas.call("domain_visible_ids") as Dictionary).size() == vis.size(),
		"the model is untouched; visible id set matches")
	var menu := gv.get("_show_menu") as MenuButton
	_check(menu != null and str(menu.get_meta("full_text", "")).contains("Power"),
		"the Show menu says what is shown (%s)" % (str(menu.get_meta("full_text", "")) if menu else "—"))
	await _shot("filter_01_power")
	gv.call("set_domain_filter", GraphDomainFilter.preset("water"))
	await _wait(0.3)
	await _shot("filter_02_water")
	var save: Dictionary = gv.call("collect_save_state")
	_check((save.get("view_filter", []) as Array) == ["water"], "the filter rides the save state")
	gv.call("set_domain_filter", {})
	await _wait(0.3)
	_check((canvas.call("_compute_visible_items") as Array).size() == all_n, "Everything restores every node")


func _test_world_drawer(gv: Node) -> void:
	var p := Vector3.ZERO
	var player := main.get_node_or_null("Player") as Node3D
	if player != null:
		p = player.global_position + Vector3(3, 2, 0)
	var a := PlacedLightService.add_point_light(main, "omni", p, Vector3.ZERO)
	var b := PlacedLightService.add_point_light(main, "omni", p + Vector3(2, 0, 0), Vector3.ZERO)
	PlacedLightService.notify()
	await _wait(1.2)
	var rows := GraphWorldInventory.collect(gv)
	var ids := {}
	for r in rows:
		ids[str((r as Dictionary).get("id", ""))] = true
	print("graphtools info — %d untracked world objects" % rows.size())
	_check(ids.has("light:" + a) and ids.has("light:" + b), "both new J lights are listed as untracked")
	var lib: Node = gv.get("_lib_panel")
	var drawer: Node = lib.get("_world_box") if lib != null else null
	_check(drawer != null and is_instance_valid(drawer), "the library drawer is built")
	await _shot("drawer_00")
	var model: GraphModel = gv.get("model")
	var n0 := model.items.size()
	for r in rows:
		if str((r as Dictionary).get("id", "")) == "light:" + a:
			((r as Dictionary)["add"] as Callable).call()
	await _wait(1.2)
	_check(model.items.size() == n0 + 1, "Add put exactly one node on the graph")
	_check(not str(gv.call("placed_light_item_id", a)).is_empty(), "the light is now tracked")
	var rows2 := GraphWorldInventory.collect(gv)
	var still := false
	for r in rows2:
		if str((r as Dictionary).get("id", "")) == "light:" + a:
			still = true
	_check(not still, "the added light left the drawer")
	PlacedLightService.delete_ids(main, [a, b])
	await _wait(0.6)
	_check(model.items.size() == n0, "deleting the lights removed their graph load")


func _test_handoff(gv: Node) -> void:
	var model: GraphModel = gv.get("model")
	var target := ""
	for it in model.get_items_in_scope("root"):
		if not str(((it as Dictionary).get("specs", {}) as Dictionary).get("bound_prop_id", "")).is_empty():
			target = str((it as Dictionary).get("id", ""))
			break
	if target.is_empty():
		print("graphtools info — no prop-bound node; handoff check skipped")
		return
	var paused_before := bool(main.get("gameplay_mechanics_paused"))
	gv.call("close_graph_view")
	await _wait(0.2)
	var paused_closed := bool(main.get("gameplay_mechanics_paused"))
	gv.call("open_graph_view")
	gv.call("select_item_by_id", target)
	await _wait(0.3)
	_check(bool(gv.call("locate_item_in_world", target)), "Locate in 3D opens the world view")
	await _wait(0.6)
	_check(not bool(gv.get("visible")), "the graph closed for it")
	_check(bool(main.get("gameplay_mechanics_paused")) == paused_closed,
		"pause state is the closed-graph state (not left paused)")
	await _shot("handoff_00_world")
	var sv: Node = main.get("settlement_view")
	if sv != null:
		sv.call("close")   # = Esc
	await _wait(0.6)
	_check(bool(gv.get("visible")), "Esc in the world view comes back to the graph")
	var sel: Array = (gv.get("_graph_canvas") as Node).get("selected_item_ids")
	_check(target in sel, "on the same node")
	await _shot("handoff_01_back")
	_check(bool(gv.call("walk_to_item", target)), "Walk to it")
	await _wait(0.4)
	_check(not bool(gv.get("visible")) and bool(main.get("gameplay_mechanics_paused")) == paused_closed,
		"Walk to it closes the graph properly")
	gv.call("open_graph_view")
	print("graphtools info — paused before %s, closed %s" % [paused_before, paused_closed])


func _to_vp(canvas: Control, p: Vector2) -> Vector2:
	return canvas.get_global_transform_with_canvas() * p


func _click_canvas(canvas: Control, p: Vector2) -> void:
	await HarnessInput.click(get_viewport(), _to_vp(canvas, p))
	await _wait(0.15)
	# The tool asks (several ports fit / "Place it here"): take the first
	# offered. A placement asks for the port next, hence the loop.
	for _k in 3:
		var menu: PopupMenu = canvas.get("_ct_menu")
		if menu == null or not is_instance_valid(menu) or not menu.visible:
			break
		var first := -1
		for i in menu.item_count:
			if not menu.is_item_separator(i):
				first = menu.get_item_id(i)
				break
		menu.hide()
		menu.id_pressed.emit(first)
		await _wait(0.25)


## The Globe's Connect tool with REAL clicks: a pin, a bend on the ground, the
## other pin -> a 3D run with the bend locked as its route, measured.
func _test_globe_connect(gv: Node) -> void:
	gv.call("open_graph_view")
	gv.call("_on_mode_chip_pressed", "globe")
	await _wait(3.0)
	var canvas := gv.get("_graph_canvas") as Control
	var model: GraphModel = gv.get("model")
	gv.call("set_connect_tool", true)
	_check(bool(canvas.get("connect_tool_active")), "C / the lens button turns the connect tool on")
	canvas.queue_redraw()
	await _wait(0.3)
	var pins: Dictionary = canvas.get("_globe_pin_px")
	# A source with a startable port and a target that takes a wire from it.
	var pair: Array = []
	for a in pins.keys():
		var ia := model.get_item(str(a))
		if not model.item_has_3d_anchor(ia):
			continue
		for ha in canvas.call("_ct_ports", ia):
			for b in pins.keys():
				if str(b) == str(a):
					continue
				var ib := model.get_item(str(b))
				if not model.item_has_3d_anchor(ib):
					continue
				var tp: Array = canvas.call("_ct_ports", ib, ia, str((ha as Dictionary).get("id", "")))
				if not tp.is_empty() and (pins[a] as Vector2).distance_to(pins[b] as Vector2) > 60.0:
					pair = [str(a), str(b)]
					break
			if not pair.is_empty():
				break
		if not pair.is_empty():
			break
	if pair.is_empty():
		print("graphtools info — no two pins on screen with compatible ports; globe connect skipped")
		gv.call("set_connect_tool", false)
		return
	var n0 := model.connections.size()
	var pa: Vector2 = pins[pair[0]]
	var pb: Vector2 = pins[pair[1]]
	await _click_canvas(canvas, pa)
	_check(not str(canvas.get("_ct_src_item")).is_empty(), "clicking a pin starts the run from it")
	var bend := (pa + pb) * 0.5 + Vector2(0.0, 40.0)
	await _click_canvas(canvas, bend)
	_check((canvas.get("_ct_waypoints") as Array).size() == 1, "clicking the ground drops a bend")
	await _shot("globe_00_connecting")
	await _click_canvas(canvas, pb)
	await _wait(0.8)
	_check(model.connections.size() == n0 + 1, "clicking the other pin makes one connection")
	var conn: Dictionary = model.connections[model.connections.size() - 1] if model.connections.size() > n0 else {}
	_check(conn.get("visible_3d") == true and (conn.get("route_3d", []) as Array).size() == 1
		and bool(conn.get("route_locked", false)), "the run is shown in 3D with its bend locked as its route")
	_check(float(conn.get("route_length_m", 0.0)) > 0.0,
		"the run is built and measured (%s)" % ConduitLength.format(float(conn.get("route_length_m", 0.0))))
	await _shot("globe_01_connected")
	gv.call("set_connect_tool", false)
	if not conn.is_empty():
		await _test_run_edit(gv, canvas, model, str(conn.get("id", "")))
		model.remove_connection(str(conn.get("id", "")))
	await _test_place_here(gv, canvas, model)


func _route_pt(model: GraphModel, cid: String, k: int) -> Vector3:
	var r: Array = model.get_connection(cid).get("route_3d", []) as Array
	if k < 0 or k >= r.size() or not (r[k] is Dictionary):
		return Vector3.INF
	var d: Dictionary = r[k]
	return Vector3(float(d.get("x", 0.0)), float(d.get("y", 0.0)), float(d.get("z", 0.0)))


func _redraw(canvas: Control) -> void:
	canvas.queue_redraw()
	await _wait(0.25)


## A point on the run's drawn line clear of its handles and of every pin.
func _line_point(canvas: Control, cid: String) -> Vector2:
	var px: PackedVector2Array = (canvas.get("_run_px") as Dictionary).get(cid, PackedVector2Array())
	if px.size() < 2:
		return Vector2.INF
	var handles: Array = canvas.get("_run_handle_px")
	var pins: Dictionary = canvas.get("_globe_pin_px")
	for f in [0.25, 0.35, 0.65, 0.75, 0.15, 0.85, 0.5]:
		var p := px[clampi(int(round(f * float(px.size() - 1))), 0, px.size() - 1)]
		var ok := true
		for h in handles:
			if (h as Vector2).distance_to(p) < 24.0:
				ok = false
		for q in pins.values():
			if (q as Vector2).distance_to(p) < 24.0 or ((q as Vector2) + Vector2(0, 16)).distance_to(p) < 24.0:
				ok = false
		if ok:
			return p
	return Vector2.INF


## The selected run's bends in the Globe, with REAL clicks: select it by its
## line, drag the bend over the ground (one undo step, re-measured), drag the
## line to insert a bend, double-click a bend to remove it; the lens pill
## carries the run's length.
func _test_run_edit(gv: Node, canvas: Control, model: GraphModel, cid: String) -> void:
	canvas.call("_select_item", "")
	await _redraw(canvas)
	var len0 := float(model.get_connection(cid).get("route_length_m", 0.0))
	var want := ConduitLength.format(len0)
	var pill_ok := false
	for pl in canvas.get("_run_pills"):
		if str((pl as Array)[1]).contains(want):
			pill_ok = true
	_check(pill_ok, "the lens wire pill carries the run length (%s)" % want)
	var lp := _line_point(canvas, cid)
	if not is_finite(lp.x):
		_check(false, "the new run is drawn in the lens (no line point)")
		return
	await HarnessInput.click(get_viewport(), _to_vp(canvas, lp))
	await _redraw(canvas)
	_check(str(canvas.get("selected_connection_id")) == cid, "clicking the run's line selects it")
	var handles: Array = canvas.get("_run_handle_px")
	_check(handles.size() == 1, "the selected run shows its bend as a handle (%d)" % handles.size())
	if handles.size() != 1 or not is_finite((handles[0] as Vector2).x):
		return
	await _shot("globe_02_run_selected")
	# Drag the bend over the ground.
	var b0 := _route_pt(model, cid, 0)
	var h0: Vector2 = handles[0]
	await HarnessInput.drag(get_viewport(), _to_vp(canvas, h0), _to_vp(canvas, h0 + Vector2(60.0, 35.0)), 12)
	await _wait(0.6)
	var b1 := _route_pt(model, cid, 0)
	var len1 := float(model.get_connection(cid).get("route_length_m", 0.0))
	_check(is_finite(b1.x) and b1.distance_to(b0) > 0.5,
		"dragging the bend moves it over the ground (%.1f m)" % (b1.distance_to(b0) if is_finite(b1.x) else -1.0))
	_check(absf(len1 - len0) > 0.01, "the run is re-measured (%s → %s)" % [
		ConduitLength.format(len0), ConduitLength.format(len1)])
	var gy := float(canvas.call("_pin_ground_y", Vector2(b1.x, b1.z) - Vector2(
		(canvas.call("_soi_world_center") as Vector3).x, (canvas.call("_soi_world_center") as Vector3).z)))
	_check(is_nan(gy) or absf(b1.y - gy) < 1.5, "the moved bend sits on the ground (%.2f m off)" % (b1.y - gy))
	gv.call("_do_undo")
	await _wait(0.4)
	var bu := _route_pt(model, cid, 0)
	_check(is_finite(bu.x) and bu.distance_to(b0) < 0.05, "one undo puts the bend back")
	gv.call("_do_redo")
	await _wait(0.4)
	_check(_route_pt(model, cid, 0).distance_to(b1) < 0.05, "redo moves it again")
	await _shot("globe_03_bend_moved")
	# Insert: press on the line, drag.
	canvas.call("_select_connection", cid)
	await _redraw(canvas)
	var lp2 := _line_point(canvas, cid)
	if not is_finite(lp2.x):
		_check(false, "a line point to insert at")
		return
	await HarnessInput.drag(get_viewport(), _to_vp(canvas, lp2), _to_vp(canvas, lp2 + Vector2(0.0, -45.0)), 10)
	await _wait(0.6)
	var r2: Array = model.get_connection(cid).get("route_3d", []) as Array
	_check(r2.size() == 2, "dragging the run's line inserts a bend (%d)" % r2.size())
	var len2 := float(model.get_connection(cid).get("route_length_m", 0.0))
	_check(absf(len2 - len1) > 0.01, "re-measured after the insert (%s)" % ConduitLength.format(len2))
	await _redraw(canvas)
	await _shot("globe_04_bend_inserted")
	# Remove the bend just inserted: double-click its handle.
	var hs: Array = canvas.get("_run_handle_px")
	var idx := -1
	# The inserted one is the bend that is not b1.
	for k in r2.size():
		if _route_pt(model, cid, k).distance_to(b1) > 0.05:
			idx = k
	if idx < 0 or idx >= hs.size() or not is_finite((hs[idx] as Vector2).x):
		_check(false, "the inserted bend has a handle")
		return
	var hp: Vector2 = hs[idx]
	await HarnessInput.click(get_viewport(), _to_vp(canvas, hp))
	await HarnessInput.click(get_viewport(), _to_vp(canvas, hp), true)
	await _wait(0.6)
	var r3: Array = model.get_connection(cid).get("route_3d", []) as Array
	_check(r3.size() == 1 and _route_pt(model, cid, 0).distance_to(b1) < 0.05,
		"double-clicking a bend removes it (%d left)" % r3.size())


## "Place it here": a node with no 3D twin, selected, Connect on, a click on
## the ground → its model is placed there, bound to THIS node, and the run
## starts from it.
func _test_place_here(gv: Node, canvas: Control, model: GraphModel) -> void:
	var preset := ComponentPresets.create_default_preset("battery", "Probe battery")
	var item := {
		"id": model.generate_item_id(),
		"type": "battery", "x": 40.0, "y": 40.0, "width": 120.0, "height": 100.0,
		"scope_id": "root", "specs": (preset["specs"] as Dictionary).duplicate(true),
		"is_virtual": false,
	}
	model.add_item(item)
	var iid := str(item.get("id", ""))
	if iid.is_empty():
		_check(false, "probe node added")
		return
	var n_items := model.items.size()
	canvas.call("_select_item", iid)
	gv.call("set_connect_tool", true)
	await _redraw(canvas)
	var it0 := model.get_item(iid)
	_check(not model.item_has_3d_anchor(it0), "the probe node starts with no 3D twin (scene %s, prop %s)" % [
		model.item_scene_path(it0), str((it0.get("specs", {}) as Dictionary).get("bound_prop_id", ""))])
	# Empty ground: away from every pin and run.
	var spot := Vector2.INF
	var pins: Dictionary = canvas.get("_globe_pin_px")
	for f in [Vector2(0.3, 0.6), Vector2(0.7, 0.6), Vector2(0.5, 0.7), Vector2(0.4, 0.4), Vector2(0.6, 0.45)]:
		var p: Vector2 = canvas.size * (f as Vector2)
		var clear := true
		for q in pins.values():
			if (q as Vector2).distance_to(p) < 40.0:
				clear = false
		if clear and str(canvas.call("_run_at", p)).is_empty() \
				and not (canvas.call("_pin_ground_hit", p) as Dictionary).is_empty():
			spot = p
			break
	if not is_finite(spot.x):
		print("graphtools info — no clear ground on screen; place-it-here skipped")
		gv.call("set_connect_tool", false)
		model.remove_item(iid)
		return
	await _click_canvas(canvas, spot)
	await _wait(0.6)
	var it := model.get_item(iid)
	var pid := str((it.get("specs", {}) as Dictionary).get("bound_prop_id", ""))
	_check(model.item_has_3d_anchor(it) and not pid.is_empty(),
		"Place it here binds a prop to THIS node (%s)" % pid)
	_check(model.items.size() == n_items, "no duplicate node was made")
	var hit: Dictionary = canvas.call("_pin_ground_hit", spot)
	if GraphSiteLayout.has_site_coords(it) and not hit.is_empty():
		var d := GraphSiteLayout.site_xz(it).distance_to(hit["site"] as Vector2)
		_check(d < 2.0, "it stands where the ground was clicked (%.2f m off)" % d)
	_check(str(canvas.get("_ct_src_item")) == iid, "the run carries on from the placed node")
	await _shot("globe_05_placed_here")
	gv.call("set_connect_tool", false)
	var loader := main.find_child("TerrainLoader", true, false)
	if not pid.is_empty() and loader != null and loader.has_method("delete_prop_by_id"):
		loader.call("delete_prop_by_id", pid)
	await _wait(0.3)
	if not model.get_item(iid).is_empty():
		model.remove_item(iid)


## The full-screen globe continues the Globe lens's view and hands it back.
func _test_globe_continuity(gv: Node) -> void:
	var before: Dictionary = gv.call("globe_orbit_state")
	if before.is_empty():
		print("graphtools info — Globe lens not live; continuity check skipped")
		return
	var soi := get_node_or_null("/root/SoiService")
	if soi == null:
		return
	soi.call("enter_snowglobe")
	await _wait(1.0)
	var sg: Node = soi.get("_snowglobe")
	var st: Dictionary = sg.call("orbit_state") if sg != null else {}
	_check(not st.is_empty() and absf(float(st["yaw"]) - float(before["yaw"])) < 0.01
		and absf(float(st["pitch"]) - float(before["pitch"])) < 0.01,
		"the full-screen globe opens on the lens's view (yaw %.2f / %.2f)" % [
			float(st.get("yaw", NAN)), float(before["yaw"])])
	await _shot("globe_02_fullscreen")
	sg.set("_orbit_yaw", float(st["yaw"]) + 0.5)
	soi.call("exit_snowglobe")
	await _wait(1.0)
	var after: Dictionary = gv.call("globe_orbit_state")
	_check(bool(gv.get("visible")) and not after.is_empty()
		and absf(float(after["yaw"]) - (float(st["yaw"]) + 0.5)) < 0.02,
		"exiting hands the orbit back to the Globe lens")
