extends RefCounted

## Nested (SketchUp-style) selection in the pallet-rack builder, driven with
## REAL clicks, double-clicks and keys through the window (sandbox, writes
## nothing to the player's world):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/pallet_rack_nested_check.gd -Label <dir>
## On the Solar workshop design: a click on the roof selects the roof deck, a
## double-click opens it (the rest fades) so a click selects a bay, a second
## double-click opens the bay so a click selects one plywood sheet, Shift-click
## adds a second, a colour and Del land on just those sheets, Esc steps out a
## level at a time, the breadcrumb closes back to the rack; then the solar
## slope opens into bays and a bay into modules, one module is hidden, and
## "Show hidden" brings everything back. A shot per level.

var _fails: Array = []
var _dir := ""
var _ui: Control = null
var _vp: SubViewport = null
var _win: Viewport = null
var _tree: SceneTree = null


func _ok(cond: bool, what: String) -> void:
	print("rack-nested %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(frames: int) -> void:
	for _i in frames:
		await _tree.process_frame


func _shot(name: String, window: bool = false) -> void:
	await _settle(4)
	_vp.get_texture().get_image().save_png("%s/%s.png" % [_dir, name])
	if window:
		_win.get_texture().get_image().save_png("%s/%s_window.png" % [_dir, name])


## Where a world point lands in the window, in viewport coordinates (what a
## player's click on the preview would report).
func _screen(world: Vector3) -> Vector2:
	var cam: Camera3D = _ui.get("_camera")
	var cont: Control = _ui.get("_vp_container")
	var local := cam.unproject_position(world) * (cont.size / Vector2(_vp.size))
	return cont.get_global_transform_with_canvas() * local


## A point on a part the camera can see: its box centre lifted along the
## view, so the click lands on the face nearest the camera.
func _part_point(id: String) -> Vector3:
	var boxes := PalletRackBuilder.part_boxes(_ui.get("_tree"), id)
	if boxes.is_empty():
		return Vector3.INF
	var b: Dictionary = boxes[0]
	if b.has("obbs"):
		return ((b["obbs"][0][0]) as Transform3D).affine_inverse().origin
	return (b["aabb"] as AABB).get_center()


func _click(world: Vector3, shift: bool = false) -> void:
	var p := _screen(world)
	if shift:
		await HarnessInput.mouse_move(_win, p, false, true)
		await HarnessInput.mouse_press(_win, p, true, false, false, true)
		await HarnessInput.mouse_press(_win, p, false, false, false, true)
	else:
		await HarnessInput.click(_win, p)
	await _settle(6)


func _double(world: Vector3) -> void:
	var p := _screen(world)
	await HarnessInput.click(_win, p)
	await HarnessInput.click(_win, p, true)
	await _settle(8)


func _ctx() -> Array:
	return _ui.get("_ctx")


func _sel() -> Array:
	return _ui.get("_sel_nodes")


func _bom() -> Dictionary:
	return PalletRackBuilder.bom(_ui.get("_spec"))


func _view(yaw: float, pitch: float, dist: float, target: Vector3) -> void:
	_ui.set("_yaw", yaw)
	_ui.set("_pitch", pitch)
	_ui.set("_dist", dist)
	_ui.set("_target", target)
	_ui.call("_update_camera")
	await _settle(3)


func run(main: Node, harness: Node) -> Dictionary:
	_tree = main.get_tree()
	_win = main.get_viewport()
	_dir = "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(_dir)
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	_ok(loader != null and loader.has_method("open_pallet_rack_builder"), "loader has the rack builder")
	if loader == null:
		return {"ok": false}
	loader.call("open_pallet_rack_builder")
	await _settle(20)
	_ui = loader.get("_pallet_rack_builder_ui")
	_ok(_ui != null and _ui.visible, "the builder opened")
	if _ui == null:
		return {"ok": false}
	_vp = _ui.get("_viewport")
	_ok(bool(_ui.call("load_design", "solar_workshop")), "loaded the solar workshop")
	await _settle(20)
	var h := float((_ui.get("_spec") as Dictionary)["upright_height_ft"]) * PalletRackBuilder.FT

	# ---- The roof deck: rack → deck → bay → sheet ----
	await _view(PI - 0.6, 0.95, 16.0, Vector3(0, h * 0.7, 0))
	var tree: Dictionary = _ui.get("_tree")
	var sheets: Array = []
	for k in (tree["nodes"]["cell:1,0,2"]["children"] as Array):
		if str(k).begins_with("ply:"):
			sheets.append(str(k))
	_ok(sheets.size() >= 2, "the roof's middle bay has sheets (%d)" % sheets.size())
	if sheets.size() < 2:
		return _finish()
	var s0 := _part_point(sheets[0]) + Vector3.UP * 0.02
	var s1 := _part_point(sheets[1]) + Vector3.UP * 0.02
	await _shot("00_rack", true)
	await _click(s0)
	_ok(_ctx().is_empty() and _sel() == ["deck:2"], "a click on the roof selects the roof deck (%s)" % str(_sel()))
	await _shot("01_deck_selected", true)
	await _double(s0)
	_ok(_ctx() == ["deck:2"], "a double-click opens the roof deck (%s)" % str(_ctx()))
	await _click(s0)
	_ok(_sel() == ["cell:1,0,2"], "inside the deck a click selects the bay (%s)" % str(_sel()))
	await _shot("02_deck_open_bay_selected", true)
	await _double(s0)
	_ok(_ctx() == ["deck:2", "cell:1,0,2"], "a double-click opens the bay (%s)" % str(_ctx()))
	await _click(s0)
	_ok(_sel() == [sheets[0]], "inside the bay a click selects one sheet (%s)" % str(_sel()))
	await _click(s1, true)
	_ok(_sel().size() == 2 and _sel().has(sheets[1]), "Shift-click adds the second sheet (%s)" % str(_sel()))
	var fields: Dictionary = _ui.get("_insp_fields")
	_ok(fields.has("_color"), "the card offers a colour for the sheets")
	_ui.call("_on_parts_color", "#3d6b8f")
	await _settle(8)
	var po: Dictionary = (_ui.get("_spec") as Dictionary)["part_overrides"]
	_ok(str(po.get(sheets[0], {}).get("color", "")) == "#3d6b8f"
		and str(po.get(sheets[1], {}).get("color", "")) == "#3d6b8f" and po.size() == 2,
		"the colour lands on exactly those two sheets (%s)" % JSON.stringify(po))
	var crumbs: Control = _ui.get("_crumb_row")
	await _shot("03_sheets_selected_painted", true)
	var ply0 := int(_bom()["plywood"])
	await HarnessInput.key(_win, KEY_DELETE)
	await _settle(8)
	_ok(int(_bom()["plywood"]) == ply0 - 2, "Del hides the two sheets (%d -> %d)" % [ply0, int(_bom()["plywood"])])
	_ok(_ctx().size() == 2, "the bay stays open after the edit")
	var show_btn: Button = _ui.get("_show_hidden_btn")
	_ok(show_btn != null and show_btn.visible, "the breadcrumb offers Show hidden")
	await _shot("04_sheets_hidden", true)
	await HarnessInput.key(_win, KEY_ESCAPE)
	await _settle(6)
	_ok(_ctx() == ["deck:2"] and _sel() == ["cell:1,0,2"], "Esc steps out to the deck, the bay selected")
	await HarnessInput.key(_win, KEY_ESCAPE)
	await _settle(6)
	_ok(_ctx().is_empty() and _sel() == ["deck:2"], "Esc again closes the deck, the deck selected")
	await _shot("05_back_at_rack")
	# The breadcrumb: open the deck and the bay, click "Rack". (The two roof
	# sheets are hidden now, so the same spot reaches the deck below.)
	await _double(s0)
	await _double(s0)
	var opened := _ctx().duplicate()
	_ok(opened.size() == 2, "opened two levels again (%s)" % str(opened))
	await _shot("06_two_levels_open", true)
	var rack_btn := HarnessInput.find_button(crumbs, "Rack")
	_ok(rack_btn != null, "the breadcrumb starts with Rack")
	if rack_btn != null:
		await HarnessInput.click(_win, HarnessInput.center_of(rack_btn))
		await _settle(8)
		_ok(_ctx().is_empty() and opened.size() == 2 and _sel() == [opened[0]],
			"clicking Rack closes back to the top, %s selected (%s)" % [str(opened.slice(0, 1)), str(_sel())])

	# A drag on a whole deck level raises every bay and beam in it, one undo step.
	var lvl := str(_sel()[0]) if not _sel().is_empty() else ""
	var undo_n := (_ui.get("_undo_stack") as Array).size()
	var p0 := _screen(s0)
	await HarnessInput.drag(_win, p0, p0 + Vector2(0, -60), 10)
	await _settle(10)
	var cov: Dictionary = (_ui.get("_spec") as Dictionary)["cell_overrides"]
	var li := lvl.get_slice(":", 1)
	var hs := {}
	for k in cov.keys():
		if str(k).get_slice(",", 2) == li and (cov[k] as Dictionary).has("height_ft"):
			hs[float(cov[k]["height_ft"])] = true
	var bov: Dictionary = (_ui.get("_spec") as Dictionary)["beam_overrides"]
	var moved_beams := 0
	for k in bov.keys():
		if str(k).get_slice(",", 0) == li and float((bov[k] as Dictionary).get("dy_in", 0.0)) > 0.0:
			moved_beams += 1
	_ok(lvl.begins_with("deck:") and hs.size() == 1 and moved_beams > 0,
		"dragging %s raised its bays together (%s) and %d beams" % [lvl, str(hs.keys()), moved_beams])
	_ok((_ui.get("_undo_stack") as Array).size() == undo_n + 1, "the drag is one undo step")
	await _shot("06b_level_dragged", true)
	await HarnessInput.key(_win, KEY_Z, true)
	await _settle(8)

	# ---- The solar slope: element → bay → module ----
	await _view(PI - 0.25, 0.3, 13.0, Vector3(0, h * 0.35, -2.0))
	tree = _ui.get("_tree")
	var bay0 := "el:e1:0"
	var mods: Array = []
	for k in (tree["nodes"][bay0]["children"] as Array):
		if PalletRackBuilder.part_kind(str(k)) == "module":
			mods.append(str(k))
	_ok(not mods.is_empty(), "the first slope bay has modules (%d)" % mods.size())
	if mods.is_empty():
		return _finish()
	var m0 := _part_point(mods[0])
	var nv: Vector3 = ((tree["boxes"] as Array).filter(func(b): return (b["path"] as Array).has(mods[0]))[0]
		["obbs"][0][0] as Transform3D).affine_inverse().basis.y
	m0 += nv.normalized() * 0.03
	await _click(m0)
	_ok(_sel() == ["el:e1"], "a click on the slope selects the whole array (%s)" % str(_sel()))
	await _shot("07_slope_selected", true)
	await _double(m0)
	_ok(_ctx() == ["el:e1"], "a double-click opens the array (%s)" % str(_ctx()))
	await _click(m0)
	_ok(_sel() == [bay0], "inside the array a click selects the bay (%s)" % str(_sel()))
	_ok((_ui.get("_insp_fields") as Dictionary).has("_seg"), "the bay's covering is in the card")
	await _shot("08_slope_bay_selected", true)
	await _double(m0)
	_ok(_ctx() == ["el:e1", bay0], "a double-click opens the bay (%s)" % str(_ctx()))
	await _click(m0)
	_ok(_sel() == [mods[0]], "inside the bay a click selects one module (%s)" % str(_sel()))
	await _shot("09_module_selected", true)
	var pv0 := int(_bom()["solar_panels"])
	await HarnessInput.key(_win, KEY_DELETE)
	await _settle(8)
	_ok(int(_bom()["solar_panels"]) == pv0 - 1, "Del hides just that module (%d -> %d)" % [pv0, int(_bom()["solar_panels"])])
	_ok(int(PalletRackBuilder.solar_summary(_ui.get("_spec"))["count"]) == pv0 - 1, "the solar summary agrees")
	await _shot("10_module_hidden", true)
	# Click away from the rack: one level out each time.
	var cont: Control = _ui.get("_vp_container")
	var away := cont.get_global_transform_with_canvas() * Vector2(40.0, 40.0)
	print("rack-nested: clicking away at %s" % str(away))
	await HarnessInput.click(_win, away)
	await _settle(6)
	_ok(_ctx() == ["el:e1"], "a click outside steps out of the bay (%s)" % str(_ctx()))
	await HarnessInput.click(_win, away)
	await _settle(6)
	_ok(_ctx().is_empty(), "a second click outside closes the array")
	# Show hidden at the top brings back the sheets and the module.
	show_btn = _ui.get("_show_hidden_btn")
	_ok(show_btn.visible, "Show hidden is offered at the top (%s)" % show_btn.text)
	await HarnessInput.click(_win, HarnessInput.center_of(show_btn))
	await _settle(10)
	_ok(int(_bom()["plywood"]) == ply0 and int(_bom()["solar_panels"]) == pv0,
		"Show hidden brings back both sheets and the module")
	# Undo (Ctrl+Z) takes that back: one step.
	await HarnessInput.key(_win, KEY_Z, true)
	await _settle(8)
	_ok(int(_bom()["solar_panels"]) == pv0 - 1, "Ctrl+Z undoes Show hidden in one step")
	await _shot("11_final", true)
	return _finish()


func _finish() -> Dictionary:
	if _ui != null:
		_ui.call("close")
	print("rack-nested: %s" % ("PASS" if _fails.is_empty() else "FAIL (%d)" % _fails.size()))
	return {"ok": _fails.is_empty(), "fails": _fails}
