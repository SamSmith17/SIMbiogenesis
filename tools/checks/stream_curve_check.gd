extends RefCounted

## Stream curves + the toolbar's reopen memory on a REAL world (sandbox):
##   tools\harness.ps1 -World <id> -RunScript res://tools/checks/stream_curve_check.gd -Label <dir>
## Aerial of the streams as saved, then with the map-wide Smoothing / Meander
## turned up (WaterNetwork.set_curve_defaults, what the View tool's sliders
## call): every feature's centreline is longer than its waypoint line, starts
## and ends on its waypoints, the re-carve lands, and the channel bed sits on
## the curved centreline. Then the edit toolbar: Water -> Edit, close, V
## reopens on Water -> Edit; Veg Select, then T, then V comes back to Select.
## Shots: 00_before.png, 01_curved.png, 02_curved_low.png.

var _fails: Array = []
var _dir := "user://screenshots/stream_curve"


func _ok(cond: bool, what: String) -> void:
	print("curve-check %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


func _shot(main: Node, name: String) -> void:
	await _frames(main.get_tree(), 20)
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [_dir, name])


func _wait_carve(main: Node, wn: Node) -> void:
	var t0 := Time.get_ticks_msec()
	await _frames(main.get_tree(), 10)
	while bool(wn.call("is_busy")) and Time.get_ticks_msec() - t0 < 60000:
		await main.get_tree().process_frame
	await _frames(main.get_tree(), 30)


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	if harness != null and "shots_dir" in harness and str(harness.get("shots_dir")).begins_with("user://"):
		_dir = str(harness.get("shots_dir"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_dir))
	var loader: Node = main.find_child("TerrainLoader", true, false)
	var wn: Node = loader.call("water_network") if loader != null else null
	_ok(wn != null, "water network")
	if wn == null:
		return {"ok": false}
	await _wait_carve(main, wn)
	var feats: Array = wn.call("features")
	_ok(not feats.is_empty(), "the world has streams (%d)" % feats.size())
	if feats.is_empty():
		return {"ok": false}
	# Frame the longest stream from above.
	var longest: Dictionary = feats[0]
	for f in feats:
		if StreamNetwork.polyline_length((f as Dictionary)["points"]) > StreamNetwork.polyline_length(longest["points"]):
			longest = f
	var ctrl0: PackedVector2Array = longest.get("ctrl_points", longest["points"])
	var mid := ctrl0[ctrl0.size() / 2]
	var gy := float(loader.call("ground_height_at", mid.x, mid.y))
	main.set("time_scale", 0.0)
	main.set("day_time", 16.5)
	var cam := Camera3D.new()
	cam.far = 6000.0
	main.add_child(cam)
	cam.global_position = Vector3(mid.x - 120.0, gy + 420.0, mid.y + 260.0)
	cam.look_at(Vector3(mid.x, gy, mid.y), Vector3.UP)
	main.call("push_camera_claim", "curve_check", {"camera_id": cam.get_instance_id()})
	await _shot(main, "00_before")

	var lens_before := {}
	for f in feats:
		lens_before[(f as Dictionary)["id"]] = StreamNetwork.polyline_length((f as Dictionary)["points"])
	wn.call("set_curve_defaults", 0.8, 0.55)
	await _frames(tree, 5)
	# request_rebuild is debounced; wait for it to start and finish.
	var t0 := Time.get_ticks_msec()
	while not bool(wn.call("is_busy")) and Time.get_ticks_msec() - t0 < 5000:
		await tree.process_frame
	await _wait_carve(main, wn)
	feats = wn.call("features")
	var all_longer := true
	var ends_ok := true
	for f_v in feats:
		var f: Dictionary = f_v
		var pts: PackedVector2Array = f["points"]
		var ctrl: PackedVector2Array = f.get("ctrl_points", pts)
		var l1 := StreamNetwork.polyline_length(pts)
		if l1 <= float(lens_before.get(f["id"], 0.0)) * 1.05:
			all_longer = false
			print("curve-check: %s %.0f m -> %.0f m" % [f["id"], float(lens_before.get(f["id"], 0.0)), l1])
		if pts[0].distance_to(ctrl[0]) > 0.01:
			ends_ok = false
		# A tributary's end may be snapped onto the channel it joins.
		if pts[pts.size() - 1].distance_to(ctrl[ctrl.size() - 1]) > 0.01 \
				and pts[pts.size() - 2].distance_to(ctrl[ctrl.size() - 1]) > 0.01:
			ends_ok = false
		print("curve-check: %s  %d waypoints -> %d centreline points, %.0f m (was %.0f m)" % [
			f["id"], ctrl.size(), pts.size(), l1, float(lens_before.get(f["id"], 0.0))])
	_ok(all_longer, "every stream got longer (it meanders)")
	_ok(ends_ok, "every centreline starts and ends on its waypoints")
	# The carve follows the centreline: the ground at centreline stations is
	# the channel bed (below the base ground).
	var prof: Dictionary = wn.call("profile", str(longest["id"]))
	var ppts: PackedVector2Array = prof.get("points", PackedVector2Array())
	var bed: PackedFloat32Array = prof.get("bed", PackedFloat32Array())
	var cut := 0
	var n := 0
	for i in range(0, ppts.size(), 25):
		if i >= bed.size():
			break
		n += 1
		var g := float(loader.call("ground_height_at", ppts[i].x, ppts[i].y))
		if absf(g - bed[i]) < 0.25:
			cut += 1
	_ok(n > 0 and float(cut) / float(n) > 0.8, "the carved bed follows the curved centreline (%d of %d stations)" % [cut, n])
	await _shot(main, "01_curved")
	cam.global_position = Vector3(mid.x - 160.0, gy + 60.0, mid.y + 40.0)
	cam.look_at(Vector3(mid.x, gy, mid.y), Vector3.UP)
	await _shot(main, "02_curved_low")
	main.call("pop_camera_claim", "curve_check")
	cam.queue_free()

	# The edit toolbar's reopen memory, through its own calls.
	var tb: Node = main.find_child("EditToolbarUI", true, false)
	if tb == null:
		for n2 in main.find_children("*", "Control", true, false):
			if (n2 as Node).has_method("toggle_section") and (n2 as Node).has_method("open_with_section"):
				tb = n2
				break
	_ok(tb != null, "edit toolbar found")
	if tb != null:
		var st: Object = tb.get("_state")
		tb.call("open_with_section", "water")
		tb.call("_set_active_tool", "water_edit")
		await _frames(tree, 3)
		tb.call("_exit_mode")
		await _frames(tree, 3)
		tb.call("toggle_section", "veg")
		await _frames(tree, 3)
		_ok(bool(tb.call("is_panel_open")) and str(st.get("active_tool")) == "water_edit",
			"V reopens on Water -> Edit (got %s)" % str(st.get("active_tool")))
		tb.call("toggle_section", "veg")   # open on water: V switches to veg
		await _frames(tree, 3)
		tb.call("_set_active_tool", "veg_select")
		tb.call("toggle_section", "terrain")
		await _frames(tree, 3)
		tb.call("toggle_section", "veg")
		await _frames(tree, 3)
		_ok(str(st.get("active_tool")) == "veg_select",
			"switching back to Vegetation lands on its last tool (got %s)" % str(st.get("active_tool")))
		tb.call("_exit_mode")
	return {"ok": _fails.is_empty(), "failures": _fails}
