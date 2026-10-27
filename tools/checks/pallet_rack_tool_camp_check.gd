extends RefCounted

## The rack builder's Tool Camp pass, driven through the modal with REAL
## clicks (sandbox, writes nothing to the player's world):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/pallet_rack_tool_camp_check.gd -Label <dir>
## Loads Tool Camp 26 (two racks: the main block and its extension) and shoots
## it; then on the default rack: the "Stairs inside" tool clicked on a loft
## bay (a stairwell is cut), the "Workbench" tool clicked on a frame, the roof
## pitched from the Levels controls, the front wall run 4' past its end from
## the parts card, and a section added on the back. A shot per state.

var _fails: Array = []
var _dir := ""
var _ui: Control = null
var _vp: SubViewport = null
var _win: Viewport = null
var _tree: SceneTree = null
var _loader: Node = null


func _ok(cond: bool, what: String) -> void:
	print("rack-toolcamp %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(frames: int) -> void:
	for _i in frames:
		await _tree.process_frame


func _shot(name: String) -> void:
	var hl: Node3D = _ui.get("_highlight_holder")
	if hl != null:
		hl.visible = false
	await _settle(4)
	_vp.get_texture().get_image().save_png("%s/%s.png" % [_dir, name])
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


func _press(text: String) -> bool:
	var btn := HarnessInput.find_button(_ui, text, false)
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
		return _finish()
	_loader.call("open_pallet_rack_builder")
	await _settle(20)
	_ui = _loader.get("_pallet_rack_builder_ui")
	_ok(_ui != null and _ui.visible, "the builder opened")
	if _ui == null:
		return _finish()
	_vp = _ui.get("_viewport")
	var P := PalletRackBuilder

	# ---- Tool Camp 26 ----
	_ok(bool(_ui.call("load_design", "tool_camp_26")), "loaded Tool Camp 26")
	await _settle(20)
	_ok((_ui.get("_modules") as Array).size() == 2, "Tool Camp 26 is the main block + its extension")
	var fp := P.footprint_xz(_spec())
	await _view(PI - 0.75, 0.45, 26.0, Vector3(0.0, 2.0, 4.0))
	await _shot("00_tool_camp_front")
	await _view(0.75, 0.42, 26.0, Vector3(0.0, 2.0, 4.0))
	await _shot("01_tool_camp_back")
	await _view(PI - 1.2, 0.12, 9.0, Vector3(-fp.x * 0.5 + 1.5, 1.4, -1.0))
	await _shot("02_tool_camp_inside")

	# ---- A fresh rack: the default ----
	_ui.call("_load_full", P.default_spec())
	_ui.call("_sync_controls")
	_ui.call("_queue_rebuild", true)
	await _settle(20)
	var s := P.resolve_spec(_spec())
	var L := P._layout(s, P._metrics(s))
	var fx: Array = L.fx
	var rz: Array = L.rz
	var fd: float = L.frame_depth
	var h := float(L.height)
	await _view(PI - 0.6, 0.85, 22.0, Vector3(0.0, 2.5, 0.0))

	# Stairs inside: click the loft over bay 2, column 1 (the roof deck off,
	# or the click lands on the roof above it).
	(_ui.get("_roof_chk") as CheckBox).button_pressed = false
	await _settle(20)
	_ok(await _press("Stairs inside"), "the Stairs inside tool is in Add to the structure")
	var loft_y := P.floor_y(_spec(), 1)
	var mid_x := (float(fx[1]) + float(fx[2])) * 0.5
	var gap_z := (float(rz[0]) + fd + float(rz[1])) * 0.5
	await _click(Vector3(mid_x, loft_y, gap_z))
	var st := _els_of("stair")
	_ok(st.size() == 1 and str(st[0].get("run", "")) == "inside" and int(st[0].get("bay", -1)) == 1
		and int(st[0].get("to_level", -1)) == 1,
		"a click on the loft puts stairs inside that bay (%s)" % str(st))
	var s2 := P.resolve_spec(_spec())
	_ok(P._deck_holes(s2, P._layout(s2, P._metrics(s2)), 1).size() == 1, "the loft gets a stairwell")
	await _view(PI - 0.6, 0.9, 16.0, Vector3(mid_x, loft_y, gap_z))
	await _shot("03_stairwell_from_above")
	await _view(PI - 1.4, 0.15, 10.0, Vector3(mid_x, 1.2, gap_z))
	await _shot("04_stairs_inside")

	# Workbench: click the front frame (rack row 1) in bay 1.
	await _view(PI, 0.25, 14.0, Vector3(0.0, 1.2, 0.0))
	_ok(await _press("Workbench"), "the Workbench tool is in Add to the structure")
	var bx := (float(fx[0]) + float(fx[1])) * 0.5
	await _click(Vector3(bx, 0.9, float(rz[0]) + fd * 0.5))
	var bn := _els_of("bench")
	_ok(bn.size() == 1 and int(bn[0].get("row", -1)) == 0 and int(bn[0].get("bay0", -1)) == 0,
		"a click on a frame puts a workbench between its uprights (%s)" % str(bn))
	await _view(PI - 0.9, 0.25, 7.0, Vector3(bx, 0.9, float(rz[0])))
	await _shot("05_workbench")
	if not bn.is_empty():
		_ui.call("_on_field_changed", "height_in", 42.0)
		await _settle(8)
		_ok(absf(float(_els_of("bench")[0].get("height_in", 0.0)) - 42.0) < 0.01, "the bench card sets the work height")

	# The roof, pitched from the Levels controls.
	var pitch: SpinBox = _ui.get("_pitch_spin")
	var eave: SpinBox = _ui.get("_eave_spin")
	_ok(pitch != null and eave != null, "the Levels section has the roof pitch")
	(_ui.get("_roof_chk") as CheckBox).button_pressed = true
	await _settle(10)
	if pitch != null:
		pitch.value = 10.0
		eave.value = 2.0
		await _settle(20)
		_ok(float(_spec().get("roof_pitch_deg", 0.0)) > 9.9 and P.roof_peak_y(_spec()) > h + 1.0,
			"the roof pitches (peak %.2f m over %.2f m frames)" % [P.roof_peak_y(_spec()), h])
	await _view(PI - 1.5, 0.2, 24.0, Vector3(0.0, h * 0.6, 0.0))
	await _shot("06_pitched_roof")

	# The front wall, run 4' past its end from the parts card.
	(_ui.get("_wall_chks")["front"] as CheckBox).button_pressed = true
	await _settle(20)
	_ui.call("_set_selection", ["wallface:front"])
	await _settle(10)
	var fields: Dictionary = _ui.get("_insp_fields")
	_ok(fields.has("_edge_a1"), "the wall's card has its size")
	if fields.has("_edge_a1"):
		(fields["_edge_a1"] as SpinBox).value = 48.0
		await _settle(12)
		var po: Dictionary = (_spec().get("part_overrides", {}) as Dictionary).get("wallface:front", {})
		_ok(absf(float((po.get("edges", {}) as Dictionary).get("a1", 0.0)) - 48.0) < 0.01,
			"the front wall runs 4' past its end")
	_ui.call("_set_selection", [])
	await _view(PI - 0.2, 0.3, 22.0, Vector3(0.0, h * 0.4, -2.0))
	await _shot("07_wall_past_end")

	# A section on the back.
	var face_opt: OptionButton = _ui.get("_sec_face_opt")
	for i in face_opt.item_count:
		if str(face_opt.get_item_metadata(i)) == "back":
			face_opt.select(i)
	_ok(await _press("Add section"), "the Add section button")
	_ok((_ui.get("_modules") as Array).size() == 2 and int(_ui.get("_active_mod")) == 1,
		"a section is added on the back and edited")
	await _view(0.6, 0.45, 30.0, Vector3(0.0, 2.0, 0.0))
	await _shot("08_section_added")
	return _finish()


func _finish() -> Dictionary:
	if _ui != null and _ui.visible:
		_ui.call("close")
	print("rack-toolcamp: %s" % ("PASS" if _fails.is_empty() else "FAIL (%d)" % _fails.size()))
	return {"ok": _fails.is_empty(), "fails": _fails}
