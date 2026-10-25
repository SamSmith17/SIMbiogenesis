extends RefCounted

## Several racks in one build, the open bay tool and doors in a slope's ends,
## driven with REAL clicks and drags through the window (sandbox, writes
## nothing to the player's world):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/pallet_rack_modules_check.gd -Label rack_modules
## On Chiba 2026 (four joined racks): a click on a faded rack edits it and the
## camera stays put; a drag moves it while the others stay where they stand;
## Ctrl+Z puts it back; a small drag snaps it back onto the frame it shared;
## the turn buttons turn the edited rack a quarter turn about its middle and
## back. On the Build a rack bay design: the Open bay tool clicked on a deck
## opens it and everything above it, the open bay dragged one bay over, a
## slope with doors in both closed ends (and the inspector rows for them).
## Then a placed rack on its own turned a quarter turn and applied: the prop's
## yaw moves, its place does not. A shot per state.

var _fails: Array = []
var _dir := ""
var _ui: Control = null
var _vp: SubViewport = null
var _win: Viewport = null
var _tree: SceneTree = null
var _loader: Node = null
const P := preload("res://core/terrain/pallet_rack_builder.gd")


func _ok(cond: bool, what: String) -> void:
	print("rack-modules %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(frames: int) -> void:
	for _i in frames:
		await _tree.process_frame


func _shot(name: String, window: bool = false) -> void:
	var hl: Node3D = _ui.get("_highlight_holder")
	if hl != null:
		hl.visible = false
	await _settle(4)
	_vp.get_texture().get_image().save_png("%s/%s.png" % [_dir, name])
	if window:
		_win.get_texture().get_image().save_png("%s/%s_window.png" % [_dir, name])
	if hl != null:
		hl.visible = true


func _screen(world: Vector3) -> Vector2:
	var cam: Camera3D = _ui.get("_camera")
	var cont: Control = _ui.get("_vp_container")
	var local := cam.unproject_position(world) * (cont.size / Vector2(_vp.size))
	return cont.get_global_transform_with_canvas() * local


func _view(yaw: float, pitch: float, dist: float, target: Vector3) -> void:
	_ui.set("_yaw", yaw)
	_ui.set("_pitch", pitch)
	_ui.set("_dist", dist)
	_ui.set("_target", target)
	_ui.call("_update_camera")
	await _settle(3)


func _click(world: Vector3) -> void:
	await HarnessInput.click(_win, _screen(world))
	await _settle(8)


func _drag(a: Vector3, b: Vector3) -> void:
	await HarnessInput.drag(_win, _screen(a), _screen(b), 16)
	await _settle(10)


func _press(text: String, partial: bool = false) -> bool:
	var btn := HarnessInput.find_button(_ui, text, partial)
	if btn == null:
		return false
	var p: Node = btn.get_parent()
	while p != null and not (p is ScrollContainer):
		p = p.get_parent()
	if p is ScrollContainer:
		(p as ScrollContainer).ensure_control_visible(btn)
		await _settle(3)
	await HarnessInput.click(_win, HarnessInput.center_of(btn))
	await _settle(10)
	return true


## Each rack's pose in the world the build stands in (the build's own pose
## moved by the turns made in here).
func _worlds() -> Array:
	var root: Transform3D = _ui.get("_root_shift")
	var out: Array = []
	for m in (_ui.get("_modules") as Array):
		out.append(root * (m["xf"] as Transform3D))
	return out


func _yaw_deg(xf: Transform3D) -> float:
	return fposmod(rad_to_deg(xf.basis.get_euler().y), 360.0)


func _same(a: Transform3D, b: Transform3D, tol: float = 0.01) -> bool:
	return a.origin.distance_to(b.origin) < tol and absf(wrapf(_yaw_deg(a) - _yaw_deg(b), -180.0, 180.0)) < 0.5


## The camera's place in the build's own frame (it should not jump when the
## edited rack changes).
func _cam_in_build() -> Vector3:
	var cam: Camera3D = _ui.get("_camera")
	var mods: Array = _ui.get("_modules")
	var xa: Transform3D = mods[int(_ui.get("_active_mod"))]["xf"]
	return xa * cam.global_position


## The middle of rack i's box in the preview, a third of the way up.
func _mod_point(i: int) -> Vector3:
	for mb in (_ui.get("_mod_boxes") as Array):
		if int(mb["i"]) == i:
			var xf: Transform3D = mb["obb_xf"]
			var half: Vector3 = mb["obb_half"]
			return xf.origin - Vector3(0.0, half.y * 0.35, 0.0)
	return Vector3.INF


func run(main: Node, harness: Node) -> Dictionary:
	_tree = main.get_tree()
	_win = main.get_viewport()
	_dir = "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(_dir)
	_loader = TerrainSurfaceQuery.find_terrain_loader(main)
	_ok(_loader != null, "a TerrainLoader map")
	if _loader == null:
		return _finish()
	_loader.call("open_pallet_rack_builder")
	await _settle(20)
	_ui = _loader.get("_pallet_rack_builder_ui")
	_vp = _ui.get("_viewport")

	# ---- Chiba 2026: pick, drag, turn ----
	_ok(bool(_ui.call("load_design", "chiba_2026")), "loaded Chiba 2026")
	await _settle(25)
	var mods: Array = _ui.get("_modules")
	_ok(mods.size() >= 3, "Chiba 2026 is a joined build (%d racks)" % mods.size())
	var fb := P.fused_bounds(_ui.call("_full_spec"), int(_ui.get("_active_mod")))
	var fc := fb.get_center()
	await _view(PI * 0.8, 0.75, maxf(fb.size.x, fb.size.y) * 1.25 + 8.0, Vector3(fc.x, 1.5, fc.y))
	await _shot("01_build", true)
	var before := _worlds()
	var pick := -1
	for mb in (_ui.get("_mod_boxes") as Array):
		var sp := _screen(_mod_point(int(mb["i"])))
		var r := _win.get_visible_rect()
		if r.has_point(sp):
			pick = int(mb["i"])
			break
	_ok(pick >= 0, "a faded rack is on screen to click")
	if pick < 0:
		return _finish()
	var cam0 := _cam_in_build()
	var act0 := int(_ui.get("_active_mod"))
	await _click(_mod_point(pick))
	_ok(int(_ui.get("_active_mod")) == pick, "a click on a faded rack edits it (rack %d)" % (pick + 1))
	var cam1 := _cam_in_build()
	_ok(cam1.distance_to(cam0) < 0.01, "the camera stays put when the edited rack changes (%s vs %s, rack %d -> %d)" % [
		str(cam0), str(cam1), act0 + 1, pick + 1])
	var still := true
	var after := _worlds()
	for k in before.size():
		if not _same(before[k], after[k]):
			still = false
	_ok(still, "editing another rack moves nothing")
	await _shot("02_editing_rack_%d" % (pick + 1), true)

	# Drag another rack 3 m.
	var j := -1
	for mb in (_ui.get("_mod_boxes") as Array):
		if _win.get_visible_rect().has_point(_screen(_mod_point(int(mb["i"])))):
			j = int(mb["i"])
			break
	_ok(j >= 0 and j != pick, "another faded rack to drag")
	if j >= 0:
		var a := _mod_point(j)
		await _drag(a, a + Vector3(3.0, 0.0, 0.0))
		var w1 := _worlds()
		var moved: float = (w1[j] as Transform3D).origin.distance_to((before[j] as Transform3D).origin)
		var others_still := true
		for k in w1.size():
			if k != j and not _same(w1[k], before[k]):
				others_still = false
		_ok(moved > 1.0, "dragging rack %d moves it (%.2f m)" % [j + 1, moved])
		_ok(others_still, "the other racks stay where they stand")
		await _shot("03_dragged_rack_%d" % (j + 1), true)
		_ui.call("_undo")
		await _settle(15)
		_ok(_same(_worlds()[j], before[j]), "Ctrl+Z puts it back")
	# Turn the edited rack and turn it back.
	var act := int(_ui.get("_active_mod"))
	var w_before := _worlds()
	_ok(await _press("⟳ 90°"), "the turn-right button is there")
	await _settle(15)
	var w_t := _worlds()
	var dy := wrapf(_yaw_deg(w_t[act]) - _yaw_deg(w_before[act]), -180.0, 180.0)
	_ok(absf(dy + 90.0) < 0.5, "turn right turns the edited rack a quarter turn (%.1f°)" % dy)
	var others_ok := true
	for k in w_t.size():
		if k != act and not _same(w_t[k], w_before[k]):
			others_ok = false
	_ok(others_ok, "turning one rack leaves the others")
	await _shot("04_turned", true)
	_ok(await _press("⟲ 90°"), "the turn-left button is there")
	await _settle(15)
	_ok(absf(wrapf(_yaw_deg(_worlds()[act]) - _yaw_deg(w_before[act]), -180.0, 180.0)) < 0.5,
		"turn left turns it back")

	# ---- Chiba 2024 (two racks sharing a frame): a small drag snaps back ----
	_ok(bool(_ui.call("load_design", "chiba_2024")), "loaded Chiba 2024")
	await _settle(25)
	var fb4 := P.fused_bounds(_ui.call("_full_spec"), int(_ui.get("_active_mod")))
	var fc4 := fb4.get_center()
	await _view(PI * 0.8, 0.75, maxf(fb4.size.x, fb4.size.y) * 1.25 + 8.0, Vector3(fc4.x, 1.5, fc4.y))
	var b4 := _worlds()
	var j4 := 1 - int(_ui.get("_active_mod"))
	# Look from rack j4's side and grab its far half, clear of the edited rack.
	var a4 := _mod_point(j4)
	var away := Vector3(a4.x, 0.0, a4.z).normalized()
	await _view(atan2(away.x, away.z), 0.55, maxf(fb4.size.x, fb4.size.y) * 1.1 + 6.0, Vector3(fc4.x, 1.5, fc4.y))
	for mb in (_ui.get("_mod_boxes") as Array):
		if int(mb["i"]) == j4:
			var hh: Vector3 = mb["obb_half"]
			a4 += away * minf(hh.x, hh.z) * 0.6
	await _drag(a4, a4 + Vector3(0.25, 0.0, 0.0))
	_ok(_same(_worlds()[j4], b4[j4], 0.02), "a small drag snaps it back onto the frame it shared (%.3f m off)" % [
		(_worlds()[j4] as Transform3D).origin.distance_to((b4[j4] as Transform3D).origin)])
	await _drag(a4, a4 + Vector3(1.6, 0.0, 0.0))
	_ok(not _same(_worlds()[j4], b4[j4], 0.5), "a long drag pulls it off the shared frame")
	await _shot("04b_chiba_2024_pulled_apart", true)

	# ---- Build a rack bay: the open bay tool, its drag, slope end doors ----
	_ok(bool(_ui.call("load_design", "build_bay")), "loaded the build bay")
	await _settle(25)
	# The open bay drag needs bays to move between.
	if int((_ui.get("_spec") as Dictionary).get("bay_count", 1)) < 3:
		_ui.call("_load_full", P.default_spec())
		_ui.call("_sync_controls")
		_ui.call("_queue_rebuild", true)
		await _settle(25)
	var spec0: Dictionary = _ui.get("_spec")
	# The top deck of the first bay (the roof deck covers the decks under it
	# from above): the open bay starts there and the deck under it stays.
	var top_lv := 0
	for sl in P.cell_slots(spec0):
		top_lv = maxi(top_lv, int(sl["level"]))
	var slot := {}
	for sl in P.cell_slots(spec0):
		if int(sl["level"]) == top_lv and int(sl["bay"]) == 0 and int(sl["col"]) == 0:
			slot = sl
	_ok(not slot.is_empty(), "the build bay has a raised deck cell")
	if not slot.is_empty():
		var box: AABB = slot["aabb"]
		var top := box.get_center() + Vector3(0.0, box.size.y * 0.5, 0.0)
		await _view(PI * 0.85, 0.9, 12.0, top)
		_ok(await _press("Open bay"), "the Open bay tool is there")
		await _click(top)
		var opened: Dictionary = (_ui.get("_spec") as Dictionary).get("_open_cells", {})
		_ok(opened.has("0,0,%d" % top_lv) and not opened.has("0,0,%d" % (top_lv - 1)),
			"a click on a deck opens it (%s)" % str(opened.keys()))
		var ob := {}
		for e in ((_ui.get("_spec") as Dictionary).get("elements", []) as Array):
			if str(e.get("type", "")) == "open_bay":
				ob = e
		_ok(not ob.is_empty() and int(ob.get("floor", -9)) == top_lv - 1, "the open bay keeps the deck below it")
		_ui.call("_set_tool", "")
		await _settle(8)
		await _view(PI * 0.85, 0.7, 14.0, top)
		await _shot("05_open_bay", true)
		if not ob.is_empty() and int((_ui.get("_spec") as Dictionary).get("bay_count", 1)) > 1:
			var eid := str(ob["id"])
			_ui.call("select_element", eid)
			await _settle(10)
			var bw := float((_ui.get("_spec") as Dictionary).get("beam_span_ft", 8)) * P.FT + 0.1
			var b_before := int(ob.get("bay0", 0))
			var fl_y := P.floor_y(_ui.get("_spec"), top_lv - 1)
			var start := Vector3(box.get_center().x, fl_y, box.get_center().z)
			# Drive the drag as the gesture code would from a press on the bay.
			_ui.call("_begin_element_drag", "el:" + eid, ob, _vp_local(start))
			_ui.set("_lmb_down", true)
			_ui.set("_lmb_press_pos", _vp_local(start))
			_ui.call("_update_manip", _vp_local(start + Vector3(bw, 0.0, 0.0)))
			_ui.call("_end_gesture", _vp_local(start + Vector3(bw, 0.0, 0.0)))
			await _settle(15)
			var ob2: Dictionary = _ui.call("_element_by_id", eid)
			_ok(int(ob2.get("bay0", 0)) == b_before + 1,
				"dragging the open bay moves it one bay over (bay %d → %d)" % [b_before + 1, int(ob2.get("bay0", 0)) + 1])
			_ok((_ui.get("_spec") as Dictionary).get("_open_cells", {}).has("%d,0,%d" % [b_before + 1, top_lv]),
				"the cells it moved onto are open now")
			await _shot("06_open_bay_moved", true)
	# A slope with doors in both closed ends.
	var doors0 := int(P.bom(_ui.get("_spec"))["doors"])
	var lid := str(_ui.call("add_element", {"type": "lean_to", "face": "front", "ends": "plywood",
		"end_door": "both"}))
	await _settle(20)
	var doors1 := int(P.bom(_ui.get("_spec"))["doors"])
	_ok(doors1 == doors0 + 2, "a slope with doors in both ends adds two doors (%d → %d)" % [doors0, doors1])
	_ui.call("select_element", lid)
	await _settle(12)
	var rows := {}
	for l in _ui.find_children("*", "Label", true, false):
		if (l as Label).is_visible_in_tree():
			rows[(l as Label).text.strip_edges()] = true
	_ok(rows.has("Door in an end") and rows.has("End door width"), "the slope card shows the end-door rows")
	var fp := P.footprint_xz(_ui.get("_spec"))
	await _view(PI * 0.68, 0.3, 13.0, Vector3(0.0, 1.4, -fp.y * 0.5 - 1.5))
	await _shot("07_slope_end_doors", true)
	await _view(PI * 1.32, 0.3, 13.0, Vector3(0.0, 1.4, -fp.y * 0.5 - 1.5))
	await _shot("07b_slope_end_doors", true)
	_ui.call("close")
	await _settle(10)

	# ---- A placed rack on its own: turn, apply ----
	var player: Node3D = main.get_node_or_null("Player") as Node3D
	var base := player.global_position if player != null else Vector3.ZERO
	var res := PlacedPropService.place_model_at_xz(main, P.MODEL_ID, base.x + 14.0, base.z)
	var pid := str(res.get("prop_id", ""))
	_ok(not pid.is_empty(), "placed a rack")
	if not pid.is_empty():
		PlacedPropService.update_prop_record(main, pid, {"yaw": 0.0}, true)
		await _settle(10)
		var r0 := PlacedPropService.get_prop_record(main, pid).duplicate(true)
		_loader.call("open_pallet_rack_builder_for_prop", pid)
		await _settle(25)
		_ok(await _press("⟳ 90°"), "a placed rack on its own can be turned")
		await _settle(10)
		_ui.call("_on_apply_to_prop")
		await _settle(15)
		var r1 := PlacedPropService.get_prop_record(main, pid).duplicate(true)
		_ok(absf(wrapf(float(r1.get("yaw", 0.0)) - float(r0.get("yaw", 0.0)) + 90.0, -180.0, 180.0)) < 0.5,
			"Apply turns the placed rack (%.1f° → %.1f°)" % [float(r0.get("yaw", 0.0)), float(r1.get("yaw", 0.0))])
		_ok(Vector2(float(r1.get("x", 0.0)), float(r1.get("z", 0.0))).distance_to(
			Vector2(float(r0.get("x", 0.0)), float(r0.get("z", 0.0)))) < 0.01, "... about its middle")
		_loader.call("delete_prop_by_id", pid)
	return _finish()


## A point in the preview as the modal's own local mouse position.
func _vp_local(world: Vector3) -> Vector2:
	var cam: Camera3D = _ui.get("_camera")
	var cont: Control = _ui.get("_vp_container")
	return cam.unproject_position(world) * (cont.size / Vector2(_vp.size))


func _finish() -> Dictionary:
	if _ui != null and _ui.visible:
		_ui.call("close")
	print("rack-modules: %s" % ("PASS" if _fails.is_empty() else "FAIL (%d)" % _fails.size()))
	return {"ok": _fails.is_empty(), "fails": _fails}
