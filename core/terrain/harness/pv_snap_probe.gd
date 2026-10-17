extends Node

## `--capture=pvsnap`: solar grid snap end to end on a real world.
##   3D — two racks of one array: a rack dropped 0.6 m off another lands edge
##        to edge with its yaw; one dropped behind lands at the no-shade row
##        pitch; "Line up this array" puts four racks in one grid.
##   Graph — a panel dragged near its array's panels snaps into line; Tidy
##        moves an array as one block in a string-per-row grid.
## Everything it places is removed again (and the run is sandboxed).

var main: Node = null
var shots_dir := "user://screenshots/pvsnap"
var _fails := 0
var _props: Array = []
var _cam: Camera3D = null


func _check(ok: bool, what: String) -> void:
	if not ok:
		_fails += 1
	print("pvsnap %s — %s" % ["PASS" if ok else "FAIL", what])


func _wait(s: float) -> void:
	await get_tree().create_timer(s).timeout


func _shot(name: String) -> void:
	for i in 4:
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	if img != null:
		img.save_png("%s/%s.png" % [shots_dir, name])


func run() -> Dictionary:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(shots_dir))
	var loader := main.get_node_or_null("TerrainLoader")
	var gv := main.get_node_or_null("UILayer/SystemGraphView")
	if loader == null or gv == null:
		_check(false, "TerrainLoader + graph present")
		return {"failures": _fails}
	PvGridSnap.set_pref("enabled", true)
	await _test_world(loader, gv)
	await _test_graph(gv)
	for pid in _props:
		loader.call("delete_prop_by_id", str(pid))
	if _cam != null:
		main.call("pop_camera_claim", "pvsnap")
		_cam.queue_free()
	return {"failures": _fails}


func _add_rack(loader: Node, x: float, z: float, yaw: float, spec: Dictionary) -> String:
	var layer: PlacedPropLayer = loader.get("_placed_prop_layer")
	var gy := TerrainSurfaceQuery.ground_height_at(main, x, z)
	var pid := layer.add_free_prop(PvArrayBuilder.MODEL_ID, x, NAN, z, yaw, 0.0, 0.0, 1.0, gy)
	layer.update_prop(pid, {"pv_array_spec": spec.duplicate(true)})
	_props.append(pid)
	return pid


func _rec(pid: String) -> Dictionary:
	return PlacedPropService.get_prop_record(main, pid)


func _test_world(loader: Node, gv: Node) -> void:
	var player := main.get_node_or_null("Player") as Node3D
	# Open ground away from the house the player spawns beside.
	var base := (player.global_position if player != null else Vector3.ZERO) + Vector3(-32.0, 0.0, 26.0)
	var spec := {"count": 6, "cols": 6, "rows": 1, "tilt_deg": 30.0}
	var yaw := 12.0
	var a := _add_rack(loader, base.x + 8.0, base.z - 6.0, yaw, spec)
	loader.call("_rebuild_placed_props")
	await _wait(0.5)
	gv.call("bind_pv_array_prop", a)
	await _wait(0.3)
	var ra := _rec(a)
	var rect_a := PvGridSnap.rect_for_pv_spec(spec, float(ra["x"]), float(ra["z"]), yaw)
	var ax: Array = PvGridSnap.axes(yaw)
	# Drop a second rack 0.6 m past where it would sit edge to edge, 4° off.
	var want: Vector2 = Vector2(float(ra["x"]), float(ra["z"])) + (ax[0] as Vector2) * (float(rect_a["w"]) + float(PvGridSnap.prefs()["gap_m"]))
	var drop: Vector2 = want + (ax[0] as Vector2) * 0.6 + (ax[1] as Vector2) * 0.2
	var res := PlacedPropService.pv_snap(main, spec, drop.x, drop.y, yaw + 4.0)
	_check(bool(res.get("snapped", false)) and str(res.get("kind", "")) == "row", "a rack dropped 0.6 m off snaps into the row")
	_check(Vector2(float(res["x"]), float(res["z"])).distance_to(want) < 0.01 and absf(float(res["yaw"]) - yaw) < 0.01,
		"edge to edge, same yaw (off by %.3f m)" % Vector2(float(res["x"]), float(res["z"])).distance_to(want))
	var b := _add_rack(loader, float(res["x"]), float(res["z"]), float(res["yaw"]), spec)
	# One dropped behind the first lands at the no-shade pitch.
	var lat := float(main.get("latitude"))
	var pitch := PvGridSnap.row_pitch(rect_a, rect_a, PvGridSnap.world_opts(lat))
	var behind := Vector2(float(ra["x"]), float(ra["z"])) - (ax[1] as Vector2) * (pitch + 0.4)
	var rb := PlacedPropService.pv_snap(main, spec, behind.x, behind.y, yaw)
	var want_b := Vector2(float(ra["x"]), float(ra["z"])) - (ax[1] as Vector2) * pitch
	_check(bool(rb.get("snapped", false)) and Vector2(float(rb["x"]), float(rb["z"])).distance_to(want_b) < 0.01,
		"a rack dropped behind lands at the %.2f m no-shade pitch at %.1f°" % [pitch, lat])
	var c := _add_rack(loader, base.x + 2.0, base.z + 9.0, 70.0, spec)
	var d := _add_rack(loader, base.x - 6.0, base.z + 3.0, 200.0, spec)
	loader.call("_rebuild_placed_props")
	await _wait(0.5)
	for pid in [b, c, d]:
		gv.call("bind_pv_array_prop", pid)
	await _wait(0.5)
	var key_a := PlacedPropService.pv_array_key(main, str(_rec(a).get("graph_item_id", "")))
	var key_c := PlacedPropService.pv_array_key(main, str(_rec(c).get("graph_item_id", "")))
	print("pvsnap info — rack array keys a=%s c=%s" % [key_a, key_c])
	await _aim_camera(_centroid([a, b, c, d]))
	await _shot("world_00_scattered")
	var moved := PlacedPropService.line_up_pv_array(main, a)
	await _wait(0.6)
	var all_ok := moved == 3
	for pid in [b, c, d]:
		if absf(wrapf(float(_rec(pid)["yaw"]) - yaw, -180.0, 180.0)) > 0.01:
			all_ok = false
	_check(all_ok, "Line up this array moved %d racks onto the anchor's yaw" % moved)
	await _aim_camera(_centroid([a, b, c, d]))
	await _shot("world_01_lined_up")


func _centroid(ids: Array) -> Vector3:
	var c := Vector3.ZERO
	for pid in ids:
		var r := _rec(str(pid))
		c += Vector3(float(r.get("x", 0.0)), 0.0, float(r.get("z", 0.0)))
	return c / maxf(float(ids.size()), 1.0)


func _aim_camera(at: Vector3) -> void:
	if _cam == null:
		_cam = Camera3D.new()
		main.add_child(_cam)
	var gy := TerrainSurfaceQuery.ground_height_at(main, at.x, at.z)
	_cam.global_position = Vector3(at.x, gy + 20.0, at.z + 12.0)
	_cam.look_at(Vector3(at.x, gy, at.z), Vector3.UP)
	main.call("push_camera_claim", "pvsnap", {"camera_id": _cam.get_instance_id(), "hide_player_mesh": true})
	await _wait(0.5)


func _test_graph(gv: Node) -> void:
	gv.call("open_graph_view")
	gv.call("_on_mode_chip_pressed", "freeform")
	await _wait(0.5)
	var model: GraphModel = gv.get("model")
	var canvas: Node = gv.get("_graph_canvas")
	var ids: Array = []
	for i in 6:
		var id := "cap_pvs_%d" % i
		model.add_item({"id": id, "type": "panel", "x": -900.0 + float(i * 173 % 400), "y": 900.0 + float(i * 97 % 260),
			"width": 120.0, "height": 90.0, "scope_id": "root", "specs": {"wmp": 380.0, "voc": 41.6, "vmp": 34.8}})
		ids.append(id)
	model.add_item({"id": "cap_pvs_ctrl", "type": "controller", "x": -800.0, "y": 1300.0, "width": 160.0,
		"height": 104.0, "scope_id": "root", "specs": {"max_voc": 500.0}})
	GraphPvWiring.wire_series(model, ids.slice(0, 3), "cap_pvs_ctrl", "root")
	GraphPvWiring.wire_series(model, ids.slice(3, 6), "cap_pvs_ctrl", "root")
	await _wait(0.3)
	# Arrange as grid: two rows of three.
	gv.set("_selected_item_ids", ["cap_pvs_ctrl"] as Array[String])
	var ok: bool = gv.call("arrange_array_as_grid")
	var ys := {}
	for id in ids:
		ys[float(model.get_item(id)["y"])] = true
	_check(ok and ys.size() == 2, "Arrange array as grid: one row per string (%d rows)" % ys.size())
	# Drag snap: put panel 0 0.5 card-widths off to the right of panel 2 and
	# run the canvas's snap with a synthetic drag.
	var p2 := model.get_item(ids[2])
	var target := Vector2(float(p2["x"]) + 120.0 + float(canvas.get("pv_snap_gap_px")), float(p2["y"]))
	var free := target + Vector2(12.0, 9.0)
	var p0 := model.get_item(ids[0])
	var start := Vector2(float(p0["x"]), float(p0["y"]))
	canvas.set("_item_drag_id", ids[0])
	canvas.set("_item_drag_ids", [ids[0]] as Array[String])
	canvas.set("_item_drag_start_map", {ids[0]: start})
	var d: Vector2 = canvas.call("_pv_snap_delta", free - start)
	var landed := start + d
	_check(landed.distance_to(target) < 0.5, "a dragged panel snaps edge to edge (off %.2f)" % landed.distance_to(target))
	canvas.set("_item_drag_id", "")
	canvas.set("_item_drag_ids", [] as Array[String])
	canvas.set("_item_drag_start_map", {})
	# Tidy keeps the array as one block.
	gv.call("tidy_layout", false)
	await _wait(0.5)
	var rows := {}
	var xs_by_row := {}
	for id in ids:
		var it := model.get_item(id)
		rows[snappedf(float(it["y"]), 0.5)] = true
	_check(rows.size() == 2, "after Tidy the array is still a 2-row grid (%d rows)" % rows.size())
	await _shot("graph_00_tidied")
	for id in ids:
		model.remove_item(id)
	model.remove_item("cap_pvs_ctrl")
	gv.call("close_graph_view")
