extends RefCounted

## The rack builder's second pass, driven with REAL clicks and drags through the
## window (sandbox, writes nothing to the player's world):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/pallet_rack_more_check.gd -Label <dir>
## On the Solar workshop design: the slope stood 4' off the face on joists
## with a plywood cover, glass sealing the gaps round 72-cell modules; the
## slope dragged onto the left face; the Stepped module tool placing steps in
## a roof bay and big steps outside the front; the bay steps dragged to another
## bay; a raised deck bay dragged to another bay; the design surviving close +
## reopen; then two placed racks standing frame to frame joined into one build
## and split apart again. A shot per state.

var _fails: Array = []
var _dir := ""
var _ui: Control = null
var _vp: SubViewport = null
var _win: Viewport = null
var _tree: SceneTree = null
var _loader: Node = null


func _ok(cond: bool, what: String) -> void:
	print("rack-more %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(frames: int) -> void:
	for _i in frames:
		await _tree.process_frame


## Geometry shots: the selection / hover highlight is hidden for the grab.
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


func _part_point(id: String) -> Vector3:
	var boxes := PalletRackBuilder.part_boxes(_ui.get("_tree"), id)
	if boxes.is_empty():
		return Vector3.INF
	var b: Dictionary = boxes[0]
	if b.has("obbs"):
		return ((b["obbs"][0][0]) as Transform3D).affine_inverse().origin
	return (b["aabb"] as AABB).get_center()


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


## Click a sidebar button, scrolled into view first.
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


func _spec() -> Dictionary:
	return _ui.get("_spec")


func _el(id: String) -> Dictionary:
	return _ui.call("_element_by_id", id)


func _els_of(type: String) -> Array:
	var out: Array = []
	for e in (_spec().get("elements", []) as Array):
		if str(e.get("type", "")) == type:
			out.append(e)
	return out


func run(main: Node, harness: Node) -> Dictionary:
	_tree = main.get_tree()
	_win = main.get_viewport()
	_dir = "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(_dir)
	_loader = TerrainSurfaceQuery.find_terrain_loader(main)
	_ok(_loader != null and _loader.has_method("open_pallet_rack_builder"), "loader has the rack builder")
	if _loader == null:
		return {"ok": false}
	_loader.call("open_pallet_rack_builder")
	await _settle(20)
	_ui = _loader.get("_pallet_rack_builder_ui")
	_ok(_ui != null and _ui.visible, "the builder opened")
	if _ui == null:
		return {"ok": false}
	_vp = _ui.get("_viewport")
	_ok(bool(_ui.call("load_design", "solar_workshop")), "loaded the solar workshop")
	await _settle(20)
	var P := PalletRackBuilder
	var h := float(_spec()["upright_height_ft"]) * P.FT
	var fp := P.footprint_xz(_spec())

	# ---- The slope: offset on joists, a plywood cover, glass gap seal, 72-cell modules ----
	var b0 := P.bom(_spec())
	_ui.call("select_element", "e1")
	await _settle(10)
	_ui.call("_on_field_changed", "offset_ft", 4.0)
	await _settle(10)
	var fields: Dictionary = _ui.get("_insp_fields")
	_ok(fields.has("bridge") and fields.has("panel_voc") and fields.has("gap_fill"),
		"the card shows the gap cover and the module fields")
	_ui.call("_on_field_changed", "bridge", "plywood")
	_ui.call("_on_field_changed", "gap_fill", "glazing")
	_ui.call("_on_pv_model", "72cell_400")
	await _settle(12)
	var b1 := P.bom(_spec())
	_ok(int(b1["lumber"]) > int(b0["lumber"]) and int(b1["glazing"]) > int(b0["glazing"]),
		"joists and the glass seal are built (lumber %d → %d, glazing %d → %d)" % [
			int(b0["lumber"]), int(b1["lumber"]), int(b0["glazing"]), int(b1["glazing"])])
	_ok(_approx(float(P.solar_summary(_spec())["voc"]), 48.0), "the 72-cell module's Voc reaches the solar summary")
	await _view(PI - 1.35, 0.35, fp.x * 1.2 + 6.0, Vector3(0, h * 0.4, -fp.y * 0.5 - 1.5))
	await _shot("00_offset_slope_side", true)
	await _view(PI - 0.35, 0.55, fp.x * 1.1 + 6.0, Vector3(0, h * 0.4, -fp.y * 0.5 - 1.0))
	await _shot("01_offset_slope_front")

	# ---- Drag the slope onto the left (+X) face ----
	_ui.call("_set_selection", [])
	await _view(PI - 0.75, 0.45, fp.x * 1.5 + 10.0, Vector3(0, h * 0.4, 0))
	var bay_pt := _part_point("el:e1:0")
	var left_pt := Vector3(fp.x * 0.5 + 0.02, h * 0.45, 0.0)
	await _drag(bay_pt, left_pt)
	_ok(str(_el("e1").get("face", "")) == "left", "dragging the slope onto the left face moves it there (%s)" %
		str(_el("e1").get("face", "")))
	await _shot("02_slope_on_left", true)

	# ---- The Stepped module tool: a roof bay, then big steps outside the front ----
	await _view(PI - 0.4, 0.75, fp.x * 1.3 + 8.0, Vector3(0, h * 0.6, 0))
	_ok(await _press("Stepped module"), "the Stepped module tool is in Add to the structure")
	var roof0 := _part_point("ply:0,0,2:0,0") + Vector3.UP * 0.03
	await _click(roof0)
	var bays := []
	for e in _els_of("stepped"):
		if str(e.get("mode", "")) == "bay":
			bays.append(e)
	_ok(bays.size() == 1 and int(bays[0].get("level", -1)) == 2 and int(bays[0].get("bay", -1)) == 0,
		"a click on a roof bay steps it (%s)" % str(bays))
	await _shot("03_bay_steps", true)
	_ok(await _press("Stepped module"), "armed the tool again")
	var x2 := float((P._layout(P.resolve_spec(_spec()), P._metrics(P.resolve_spec(_spec()))).fx)[2]) + 1.5
	await _click(Vector3(x2, 1.0, -fp.y * 0.5 - 0.02))
	var faces := []
	for e in _els_of("stepped"):
		if str(e.get("mode", "")) == "face":
			faces.append(e)
	_ok(faces.size() == 1 and str(faces[0].get("face", "")) == "front" and int(faces[0].get("to_level", -1)) >= 1,
		"a click on the front face places big steps (%s)" % str(faces))
	await _view(PI - 0.2, 0.3, fp.x * 1.2 + 8.0, Vector3(0, h * 0.3, -fp.y * 0.5 - 1.0))
	await _shot("04_big_steps", true)

	# ---- Drag the roof steps to the third bay ----
	if not bays.is_empty():
		await _view(PI - 0.4, 0.75, fp.x * 1.3 + 8.0, Vector3(0, h * 0.6, 0))
		var sid := str(bays[0]["id"])
		var src := _part_point("el:" + sid)
		var dst := _part_point("ply:2,0,2:0,0") + Vector3.UP * 0.03
		await _drag(src, Vector3(dst.x, P.floor_y(_spec(), 2), dst.z))
		_ok(int(_el(sid).get("bay", -1)) == 2, "dragging the steps moves them to bay 3 (bay %d)" %
			(int(_el(sid).get("bay", -1)) + 1))
		await _shot("05_steps_dragged", true)

	# ---- Drag a raised deck bay to another bay ----
	_ui.call("_push_undo")
	_ui.call("_set_cell_override", "0,0,1", "height_ft", 6.0)
	_ui.call("_set_ctx", ["deck:1"], [])
	await _settle(15)
	await _view(PI - 0.4, 0.55, fp.x * 1.4 + 8.0, Vector3(0, h * 0.35, 0))
	var c0 := _part_point("ply:0,0,1:0,0") + Vector3.UP * 0.03
	var c2 := _part_point("ply:1,0,1:0,0") + Vector3.UP * 0.03
	await _drag(c0, Vector3(c2.x, c0.y, c2.z))
	var cov: Dictionary = _spec().get("cell_overrides", {})
	_ok(float((cov.get("1,0,1", {}) as Dictionary).get("height_ft", 0.0)) == 6.0
		and not (cov.get("0,0,1", {}) as Dictionary).has("height_ft"),
		"dragging the raised bay moves it to bay 2 (%s)" % str(cov))
	await _shot("06_deck_bay_moved", true)
	_ui.call("_step_out")
	await _settle(10)

	# ---- Close and reopen: the design is still there ----
	var before: Dictionary = _ui.call("_full_spec")
	_ui.call("close")
	await _settle(10)
	_loader.call("open_pallet_rack_builder")
	await _settle(25)
	var after: Dictionary = _ui.call("_full_spec")
	_ok((after["elements"] as Array).size() == (before["elements"] as Array).size()
		and str(_el("e1").get("face", "")) == "left"
		and float(_el("e1").get("offset_ft", 0.0)) == 4.0
		and (after["cell_overrides"] as Dictionary).has("1,0,1"),
		"close + reopen keeps the design (%d elements)" % (after["elements"] as Array).size())
	await _shot("07_reopened", true)

	# ---- The Chiba presets, loaded through the Designs list ----
	for pair in [["Chiba 2024", 1], ["Chiba 2026", 2]]:
		var opt: OptionButton = _ui.get("_design_opt")
		var idx := -1
		for i in opt.item_count:
			if opt.get_item_text(i) == str(pair[0]):
				idx = i
		_ok(idx >= 0, "%s is in the Designs list" % str(pair[0]))
		if idx < 0:
			continue
		opt.select(idx)
		_ok(await _press("Load"), "Load")
		await _settle(25)
		_ok((_ui.get("_modules") as Array).size() == int(pair[1]) + 1,
			"%s loads as %d joined racks" % [str(pair[0]), int(pair[1]) + 1])
		var fb := P.fused_bounds(_ui.call("_full_spec"))
		await _view(PI - 0.75, 0.55, maxf(fb.size.x, fb.size.y) * 1.3 + 6.0,
			Vector3(fb.get_center().x, 2.5, fb.get_center().y))
		await _shot("07b_" + str(pair[0]).to_lower().replace(" ", "_"), true)

	# ---- A second slope on a face that already has one ----
	_ok(bool(_ui.call("load_design", "chiba_2024")), "back to Chiba 2024")
	await _settle(20)
	var n_slopes0 := _els_of("lean_to").size()
	await _view(0.0, 0.25, P.footprint_xz(_spec()).x * 1.3 + 10.0, Vector3(0, h * 0.4, 0))
	_ok(await _press("Solar slope"), "armed the Solar slope tool")
	var L24 := P._layout(P.resolve_spec(_spec()), P._metrics(P.resolve_spec(_spec())))
	var bx := (float(L24.fx[2]) + float(L24.fx[3])) * 0.5
	await _click(Vector3(bx, h * 0.6, float(L24.z0) + float(L24.total_z) + 0.02))
	var news := _els_of("lean_to")
	var added: Dictionary = news[-1] if news.size() > n_slopes0 else {}
	_ok(not added.is_empty() and str(added.get("face", "")) == "back"
		and int(added.get("seg_from", -1)) == 2 and int(added.get("seg_to", -1)) == 3,
		"a click on a free bay of the back adds a slope over the free bays (%s)" % str(added))
	await _shot("07c_second_slope", true)
	_ui.call("close")
	await _settle(8)

	# ---- Two placed racks, frame to frame: join, then split ----
	var player: Node3D = main.get_node_or_null("Player") as Node3D
	var base := player.global_position if player != null else Vector3.ZERO
	var ra := {"bay_count": 2, "column_count": 1, "decked": true, "roof_deck": true,
		"upright_height_ft": 8, "deck_levels": 1, "level_heights_ft": [0.5]}
	var w := P.footprint_xz(ra).x
	var ax := base.x + 14.0
	var az := base.z
	var ra_res := PlacedPropService.place_model_at_xz(main, P.MODEL_ID, ax, az)
	var rb_res := PlacedPropService.place_model_at_xz(main, P.MODEL_ID, ax + w + 0.3, az + 0.15)
	var a_id := str(ra_res.get("prop_id", ""))
	var b_id := str(rb_res.get("prop_id", ""))
	_ok(not a_id.is_empty() and not b_id.is_empty(), "placed two racks")
	if a_id.is_empty() or b_id.is_empty():
		return _finish()
	PlacedPropService.update_prop_record(main, a_id, {"rack_spec": P.resolve_spec(ra)}, true)
	PlacedPropService.update_prop_record(main, b_id, {"rack_spec": P.resolve_spec(ra), "yaw": 3.0}, true)
	await _settle(10)
	_loader.call("open_pallet_rack_builder_for_prop", a_id)
	await _settle(25)
	_ok(await _press("Find racks to join"), "the Find racks to join button is there")
	var joined := await _press("Join the rack", true)
	_ok(joined, "the touching rack is offered")
	await _settle(20)
	var rec_a := PlacedPropService.get_prop_record(main, a_id)
	var fused: Array = (rec_a.get("rack_spec", {}) as Dictionary).get("fused", [])
	_ok(fused.size() == 1 and PlacedPropService.get_prop_record(main, b_id).is_empty(),
		"joining folds the other rack into this one (%d fused)" % fused.size())
	_ok(int(P.bom(rec_a.get("rack_spec", {}))["uprights"]) == 2 * int(P.bom(ra)["uprights"]) - 2,
		"the shared frame is drawn once")
	await _view(PI - 0.6, 0.5, w * 2.5 + 6.0, Vector3(w * 0.5, 1.0, 0))
	await _shot("08_joined", true)
	_ui.call("_switch_module", 1)
	await _settle(15)
	await _shot("09_editing_rack_2", true)
	var n_racks0 := _rack_count()
	_ok(await _press("Split off"), "Split off is offered")
	await _settle(20)
	var rec_a2 := PlacedPropService.get_prop_record(main, a_id)
	_ok(_rack_count() == n_racks0 + 1 and ((rec_a2.get("rack_spec", {}) as Dictionary).get("fused", []) as Array).is_empty(),
		"Split off stands the rack on its own again")
	await _shot("10_split", true)
	_ui.call("close")
	# Leave the sandbox as it was.
	for rec in (_loader.call("placed_prop_records") as Array).duplicate():
		var pid := str(rec.get("id", ""))
		if pid == a_id or (str(rec.get("model_id", "")) == P.MODEL_ID and pid != a_id
				and absf(float(rec.get("x", 0.0)) - (ax + w)) < 1.0):
			_loader.call("delete_prop_by_id", pid)
	return _finish()


func _rack_count() -> int:
	var n := 0
	for rec in (_loader.call("placed_prop_records") as Array):
		if str(rec.get("model_id", "")) == PalletRackBuilder.MODEL_ID:
			n += 1
	return n


func _approx(a: float, b: float) -> bool:
	return absf(a - b) < 1e-3


func _finish() -> Dictionary:
	if _ui != null and _ui.visible:
		_ui.call("close")
	print("rack-more: %s" % ("PASS" if _fails.is_empty() else "FAIL (%d)" % _fails.size()))
	return {"ok": _fails.is_empty(), "fails": _fails}
