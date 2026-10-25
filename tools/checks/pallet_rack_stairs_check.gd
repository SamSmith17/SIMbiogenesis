extends RefCounted

## Stairs with turns and flights, and the rack's shading, in the real rack
## builder (sandbox, writes nothing to the player's world):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/pallet_rack_stairs_check.gd -Label rack_stairs
## On the "Build a rack bay" design: the stair picked, then every Flights
## choice made through the inspector's own dropdown — the turn and landing
## rows show only where they mean something, the stair rebuilds with the
## right number of flights and landings, a turn picked going up swaps the
## lower flight to the other side, the landing height moves the landing. A
## shot per shape. Then the lighting: the deck's top face, seen from above in
## the studio's sun, must be brighter than its underside (the rack was built
## inside out until 2026-10-24 and every face lit from behind).

var _fails: Array = []
var _dir := ""
var _ui: Control = null
var _vp: SubViewport = null
var _tree: SceneTree = null


func _ok(cond: bool, what: String) -> void:
	print("rack-stairs %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(frames: int) -> void:
	for _i in frames:
		await _tree.process_frame


func _shot(name: String) -> void:
	var hl: Node3D = _ui.get("_highlight_holder")
	if hl != null:
		hl.visible = false
	await _settle(5)
	_vp.get_texture().get_image().save_png("%s/%s.png" % [_dir, name])
	if hl != null:
		hl.visible = true


func _view(yaw: float, pitch: float, dist: float, target: Vector3) -> void:
	_ui.set("_yaw", yaw)
	_ui.set("_pitch", pitch)
	_ui.set("_dist", dist)
	_ui.set("_target", target)
	_ui.call("_update_camera")
	await _settle(3)


## The inspector row whose label reads `label`: its control, or null.
func _row_control(label: String) -> Control:
	for l in _ui.find_children("*", "Label", true, false):
		if (l as Label).text.strip_edges() == label and (l as Label).is_visible_in_tree():
			var p := (l as Label).get_parent()
			var i := l.get_index()
			if i + 1 < p.get_child_count():
				return p.get_child(i + 1) as Control
	return null


## Picks `value` in an inspector dropdown the way a click does (item_selected).
func _pick(label: String, value: String) -> bool:
	var opt := _row_control(label) as OptionButton
	if opt == null:
		return false
	for i in opt.item_count:
		if str(opt.get_item_metadata(i)) == value:
			opt.select(i)
			opt.item_selected.emit(i)
			await _settle(12)
			return true
	return false


func _stair() -> Dictionary:
	for e in ((_ui.get("_spec") as Dictionary).get("elements", []) as Array):
		if str(e.get("type", "")) == "stair":
			return e
	return {}


func _geo() -> Dictionary:
	var s := PalletRackBuilder.resolve_spec(_ui.get("_spec"))
	var L := PalletRackBuilder._layout(s, PalletRackBuilder._metrics(s))
	for e in (s.get("elements", []) as Array):
		if str(e.get("type", "")) == "stair":
			return PalletRackBuilder._stair_geo(L, e)
	return {}


func run(main: Node, harness: Node) -> Dictionary:
	_tree = main.get_tree()
	_dir = "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(_dir)
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	_ok(loader != null, "a TerrainLoader map")
	if loader == null:
		return _finish()
	loader.call("open_pallet_rack_builder")
	await _settle(20)
	_ui = loader.get("_pallet_rack_builder_ui")
	_vp = _ui.get("_viewport")
	_ok(bool(_ui.call("load_design", "build_bay")), "loaded the build bay")
	await _settle(20)
	var st := _stair()
	_ok(not st.is_empty(), "the design has a stair")
	if st.is_empty():
		return _finish()
	_ui.call("select_element", str(st["id"]))
	await _settle(12)
	_ok(_row_control("Flights") != null, "the stair card has a Flights row")
	_ok(_row_control("Turns, going up") == null, "no turn row on a straight stair")
	var bb := PalletRackBuilder.footprint_xz(_ui.get("_spec"))
	var target := Vector3(0.0, 1.0, -bb.y * 0.5 - 1.5)

	var want := {"straight": [1, 0], "landing": [2, 1], "l": [2, 1], "u": [2, 1], "wrap": [3, 2]}
	for shape in want:
		_ok(await _pick("Flights", shape), "picked %s in the Flights dropdown" % shape)
		var g := _geo()
		var nf := (g.get("flights", []) as Array).size()
		var nl := (g.get("landings", []) as Array).size()
		_ok(nf == int(want[shape][0]) and nl == int(want[shape][1]),
			"%s: %d flights, %d landings" % [shape, nf, nl])
		var turn_row := _row_control("Turns, going up") != null
		_ok(turn_row == (shape in ["l", "u", "wrap"]), "%s: the turn row shows only for a turning stair" % shape)
		_ok((_row_control("Landing height") != null) == (shape != "straight"),
			"%s: the landing-height row shows only with a landing" % shape)
		await _view(PI * 0.82, 0.55, 9.5, target)
		await _shot("stair_%s" % shape)
		await _view(PI * 1.18, 0.35, 9.5, target)
		await _shot("stair_%s_b" % shape)
		await _view(PI * 0.5, 0.18, 11.0, target)
		await _shot("stair_%s_side" % shape)

	# Turning the other way puts the lower flight on the other side.
	await _pick("Flights", "l")
	var h_left: Vector3 = (_geo()["flights"] as Array)[1]["h"]
	_ok(await _pick("Turns, going up", "right"), "picked right in the turn dropdown")
	var h_right: Vector3 = (_geo()["flights"] as Array)[1]["h"]
	_ok((h_left + h_right).length() < 1e-3, "turning right sends the lower flight the other way")
	await _view(PI * 0.82, 0.55, 9.5, target)
	await _shot("stair_l_right")
	# The landing height moves the landing.
	var y_before: float = (_geo()["landings"] as Array)[0]["y"]
	var spin := _row_control("Landing height") as SpinBox
	_ok(spin != null, "the landing height is a number field")
	if spin != null:
		spin.value = 30.0
		await _settle(12)
		var y_after: float = (_geo()["landings"] as Array)[0]["y"]
		_ok(y_after < y_before - 0.05, "a lower landing height lowers the landing (%.2f -> %.2f m)" % [y_before, y_after])

	# Lighting: the deck's top, lit from above, brighter than its underside.
	await _pick("Flights", "straight")
	await _view(PI * 0.82, 1.15, 8.0, Vector3(0.0, 1.8, 0.0))
	var top_l := await _centre_luma()
	await _view(PI * 0.82, -0.35, 6.0, Vector3(0.0, 1.6, 0.0))
	var under_l := await _centre_luma()
	_ok(top_l > under_l + 0.05, "the deck's top reads brighter than its underside (%.2f vs %.2f)" % [top_l, under_l])
	await _view(PI * 0.82, 0.55, 9.5, target)
	await _shot("lit")
	_ui.call("close")
	return _finish()


## Mean luminance of the middle tenth of the studio picture.
func _centre_luma() -> float:
	await _settle(6)
	var img := _vp.get_texture().get_image()
	var w := img.get_width()
	var h := img.get_height()
	var sum := 0.0
	var n := 0
	for y in range(int(h * 0.45), int(h * 0.55), 2):
		for x in range(int(w * 0.45), int(w * 0.55), 2):
			sum += img.get_pixel(x, y).get_luminance()
			n += 1
	return sum / float(maxi(n, 1))


func _finish() -> Dictionary:
	print("rack-stairs %s (%d failure(s))" % ["PASS" if _fails.is_empty() else "FAIL", _fails.size()])
	return {"ok": _fails.is_empty(), "failures": _fails}
