extends RefCounted

## The edit toolbar's ROUTE section driven with REAL clicks (sandbox):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/conduit_tool_check.gd -Label conduit_tool
##   (and -UserArgs @("--window-size=1280x720") for the small screen)
## Finds two machines with compatible ports a few metres apart, looks at them
## from a fixed camera, opens Route (Shift+R), and:
##  - Connect: clicks a port, then the other; the ghost shown before the
##    second click is the run the click builds (same points);
##  - Bend: picks the run, clicks it to add a bend point, drags the point,
##    Ctrl+Z puts it back;
##  - Height: drags the run up; the preferred height lands on the style;
##  - Open in Process: the graph opens in the Process lens with the run
##    selected; its pipe card's "Show in 3D" comes back to the Route tools on
##    the same run.
## Shots under screenshots\conduit_tool\.

const HarnessInputScript := preload("res://core/terrain/harness/harness_input.gd")

var _fails: Array = []
var _dir := "user://screenshots/conduit_tool"


func _ok(cond: bool, what: String) -> void:
	print("conduittool %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


func _shot(main: Node, name: String) -> void:
	await main.get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := main.get_viewport().get_texture().get_image()
	if img != null:
		img.save_png(ProjectSettings.globalize_path("%s/%s.png" % [_dir, name]))


## A second run on the same ports lies on the same line: the two make a
## bundle of two lanes, side by side. A REAL Lane drag swaps them; a drag well
## clear takes one out; Ctrl+Z puts it back.
func _test_lanes(main: Node, tb: Control, gv: Node, mgr: ConduitManager, model: GraphModel,
		cam: Camera3D, cid: String) -> void:
	var tree := main.get_tree()
	var vp := main.get_viewport()
	var c0 := model.get_connection(cid)
	if c0.is_empty():
		_ok(false, "lanes: the first run is still there")
		return
	var copy := c0.duplicate(true)
	copy.erase("id")
	var st: Dictionary = (copy.get("conduit_style", {}) as Dictionary).duplicate()
	st.erase("run_height_m")
	copy["conduit_style"] = st
	(c0.get("conduit_style", {}) as Dictionary).erase("run_height_m")
	model.update_connection(cid, {"conduit_style": st.duplicate(), "route_3d": []})
	copy["route_3d"] = []
	model.add_connection(copy)
	var cid2 := str(copy.get("id", ""))
	_ok(not cid2.is_empty() and not model.get_connection(cid2).is_empty(), "lanes: a second run on the same ports")
	if cid2.is_empty():
		return
	mgr.force_remesh(cid)
	mgr.force_remesh(cid2)
	await _frames(tree, 40)
	var b := mgr.bundle_of(cid)
	_ok(int(b.get("lanes", 1)) == 2 and (b.get("members", []) as Array).has(cid2),
		"lanes: the two runs share a bundle of two lanes (%s)" % str(b))
	var p1 := mgr.get_sample_points(cid)
	var p2 := mgr.get_sample_points(cid2)
	var apart := INF
	if p1.size() > 4 and p2.size() > 4:
		apart = p1[p1.size() / 2].distance_to(p2[p2.size() / 2])
	_ok(apart > 0.03 and apart < 0.5, "lanes: side by side, not on top of each other (%.3f m)" % apart)
	await _shot(main, "07_bundle")
	if b.is_empty():
		return
	# Drag the first lane's run onto the other lane.
	tb.call("_set_active_tool", "route_lane")
	await _frames(tree, 3)
	var first := str((b["members"] as Array)[0])
	var pts := mgr.get_sample_points(first)
	var at := pts[pts.size() / 2]
	# Toward the other lane, measured off the two runs as drawn.
	var other := str((b["members"] as Array)[1])
	var po := mgr.get_sample_points(other)
	var near := po[0]
	for q: Vector3 in po:
		if q.distance_to(at) < near.distance_to(at):
			near = q
	var side := near - at
	side.y = 0.0
	side = side.normalized() if side.length() > 1e-4 else Vector3.RIGHT
	var pitch := float(mgr.run_info(first).get("od", 0.03)) + ConduitBundler.GAP_M
	# Lanes lie a few pixels apart: the run is picked first (the picked run
	# wins a tie), then dragged for real.
	var rt: RefCounted = tb.call("route_tools")
	rt.call("_pick_run", first)
	# Close up: the lanes are centimetres apart.
	var cam_dir := side.cross(Vector3.UP).normalized()
	cam.global_position = at + cam_dir * 1.6 + Vector3.UP * 1.1
	cam.look_at(at, Vector3.UP)
	await _frames(tree, 6)
	var s0 := cam.unproject_position(at)
	var s1 := cam.unproject_position(at + side * pitch * 1.1)
	await HarnessInputScript.drag(vp, s0, s1, 10)
	await _frames(tree, 40)
	var b2 := mgr.bundle_of(first)
	var stat: Label = tb.get("_status") as Label
	print("conduittool info — after the lane drag: status '%s', lane_index %s / %s, picked %s, drag %s -> %s" % [
		stat.text if stat != null else "?",
		str((model.get_connection(first).get("conduit_style", {}) as Dictionary).get("lane_index", "-")),
		str((model.get_connection(other).get("conduit_style", {}) as Dictionary).get("lane_index", "-")),
		str(rt.get("_picked")), str(s0), str(s1)])
	_ok(int(b2.get("lane", -1)) == 1, "lanes: a sideways drag moves the run to the other lane (%s)" % str(b2))
	await _shot(main, "08_lane_swapped")
	# Well clear: out of the bundle.
	pts = mgr.get_sample_points(first)
	at = pts[pts.size() / 2]
	s0 = cam.unproject_position(at)
	s1 = cam.unproject_position(at + side * 2.5)
	await HarnessInputScript.drag(vp, s0, s1, 12)
	await _frames(tree, 40)
	var st1: Dictionary = model.get_connection(first).get("conduit_style", {})
	_ok(bool(st1.get("lane_free", false)) and mgr.bundle_of(first).is_empty(),
		"lanes: dragging well clear takes it out of the bundle")
	await _shot(main, "09_pulled_out")
	await HarnessInputScript.key(vp, KEY_Z, true)
	await _frames(tree, 40)
	var st2: Dictionary = model.get_connection(first).get("conduit_style", {})
	_ok(not bool(st2.get("lane_free", false)), "lanes: Ctrl+Z puts it back in the bundle")
	model.remove_connection(cid2)


func _hash_pts(pts: Array) -> String:
	var parts: PackedStringArray = []
	for p: Variant in pts:
		if p is Vector3:
			var v := p as Vector3
			parts.append("%.2f,%.2f,%.2f" % [v.x, v.y, v.z])
	return ",".join(parts)


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	if harness != null and "shots_dir" in harness and str(harness.get("shots_dir")).begins_with("user://"):
		_dir = str(harness.get("shots_dir"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_dir))
	await _frames(tree, 30)
	var loader: Node = main.find_child("TerrainLoader", true, false)
	var tb: Control = main.find_child("EditToolbarUI", true, false)
	var gv: Node = main.find_child("SystemGraphView", true, false)
	var mgr: ConduitManager = main.get_node_or_null("ConduitManager") as ConduitManager
	_ok(loader != null and tb != null and gv != null and mgr != null, "loader, toolbar, graph, conduits")
	if loader == null or tb == null or gv == null or mgr == null:
		return {"ok": false}
	main.set("time_scale", 0.0)
	main.set("day_time", 13.0)
	var model: GraphModel = gv.get("model") as GraphModel
	# Two ports on two different machines, 4..30 m apart, compatible.
	var ports: Array = mgr.gather_world_ports()
	var pa := {}
	var pb := {}
	var best := INF
	for i: int in range(ports.size()):
		for j: int in range(ports.size()):
			var a: Dictionary = ports[i]
			var b: Dictionary = ports[j]
			if str(a["item_id"]) == str(b["item_id"]):
				continue
			var d := (a["world_pos"] as Vector3).distance_to(b["world_pos"] as Vector3)
			if d < 4.0 or d > 30.0 or not ConduitPlugLogic.ports_compatible(a, b):
				continue
			var score := absf(d - 10.0)
			if score < best:
				best = score
				pa = a
				pb = b
	_ok(not pa.is_empty(), "found two compatible ports (%d ports on the map)" % ports.size())
	if pa.is_empty():
		return {"ok": false, "fails": _fails}
	var wa: Vector3 = pa["world_pos"]
	var wb: Vector3 = pb["world_pos"]
	var mid := (wa + wb) * 0.5
	var span := wa.distance_to(wb)
	var side := (wb - wa).cross(Vector3.UP).normalized()
	var cam := Camera3D.new()
	cam.far = 2000.0
	cam.fov = 55.0
	main.add_child(cam)
	cam.global_position = mid + side * maxf(span * 0.9, 7.0) + Vector3.UP * maxf(span * 0.55, 5.0)
	cam.look_at(mid, Vector3.UP)
	main.call("push_camera_claim", "conduit_tool_check", {"camera_id": cam.get_instance_id()})
	await _frames(tree, 10)
	var vp := main.get_viewport()
	# Open Route with its key (Shift+R).
	await HarnessInputScript.key(vp, KEY_R, false, true)
	await _frames(tree, 4)
	if not bool(tb.call("is_panel_open")):
		tb.call("open_with_section", "route")
	tb.call("_set_active_tool", "route_connect")
	await _frames(tree, 4)
	var rt: RefCounted = tb.call("route_tools")
	_ok(rt != null and str(rt.get("tool")) == "route_connect", "Route section open on Connect")
	rt.set("new_kind", "pvc_pipe")
	var n0 := model.connections.size()
	var sa := cam.unproject_position(wa)
	var sb := cam.unproject_position(wb)
	await HarnessInputScript.click(vp, sa)
	await _frames(tree, 3)
	_ok(not (rt.get("_src") as Dictionary).is_empty(), "first click picked a port")
	await HarnessInputScript.mouse_move(vp, sb)
	await _frames(tree, 12)
	var ghost: PackedVector3Array = rt.get("_ghost")
	var ghost_hash := _hash_pts(Array(ghost))
	_ok(ghost.size() >= 2, "a ghost runs to the hovered port (%d points)" % ghost.size())
	await _shot(main, "01_connect_ghost")
	await HarnessInputScript.click(vp, sb)
	await _frames(tree, 6)
	_ok(model.connections.size() == n0 + 1, "the second click made one run")
	if model.connections.size() != n0 + 1:
		return {"ok": false, "fails": _fails}
	var conn: Dictionary = model.connections.back()
	var cid := str(conn.get("id", ""))
	_ok(str(conn.get("route_solver", "")) == "v2" and conn.get("visible_3d") == true,
		"the run is on the solver and drawn")
	await _frames(tree, 10)
	# The ghost is drawn through the build's own samples: the committed run's.
	# Kit pipes: the ghost is the corner list the fittings are seated on.
	# Everything else: the build's own samples (a cord draped on the ground).
	var tid := ConduitKinds.derive_type_for_connection(conn)
	var built_pts := PackedVector3Array()
	if ConduitKinds.uses_pipe_kit(tid) or ConduitKinds.uses_culvert_kit(tid):
		for q: Variant in mgr.build_control_points(model.get_connection(cid)):
			if q is Vector3:
				built_pts.append(q as Vector3)
	else:
		built_pts = mgr.get_sample_points(cid)
	var worst := INF
	if built_pts.size() == ghost.size():
		worst = 0.0
		for i: int in range(ghost.size()):
			worst = maxf(worst, ghost[i].distance_to(built_pts[i]))
	_ok(worst < 0.05, "the ghost is the committed run (%d vs %d points, worst %.3f m)"
		% [ghost.size(), built_pts.size(), worst])
	await _shot(main, "02_connected")
	# Bend: pick the run, click it to add a bend point.
	tb.call("_set_active_tool", "route_bend")
	await _frames(tree, 3)
	var pts := mgr.get_sample_points(cid)
	_ok(pts.size() >= 2, "the run has samples")
	var on_run := cam.unproject_position(pts[pts.size() / 2])
	await HarnessInputScript.click(vp, on_run)
	await _frames(tree, 3)
	_ok(str(rt.get("_picked")) == cid, "a click picks the run")
	await HarnessInputScript.click(vp, on_run)
	await _frames(tree, 6)
	var vias: Array = model.get_connection(cid).get("route_3d", [])
	_ok(vias.size() == 1, "a second click adds a bend point (%d)" % vias.size())
	if vias.size() == 1:
		var v0 := Vector3(float(vias[0]["x"]), float(vias[0]["y"]), float(vias[0]["z"]))
		var sv := cam.unproject_position(v0)
		await HarnessInputScript.drag(vp, sv, sv + Vector2(70, 0), 14)
		await _frames(tree, 6)
		var vias2: Array = model.get_connection(cid).get("route_3d", [])
		var v1 := Vector3(float(vias2[0]["x"]), float(vias2[0]["y"]), float(vias2[0]["z"]))
		_ok(v1.distance_to(v0) > 0.2 and absf(v1.y - v0.y) < 0.01,
			"dragging the bend point moves it level (%.2f m)" % v1.distance_to(v0))
		await _shot(main, "03_bend_dragged")
		await HarnessInputScript.key(vp, KEY_Z, true)
		await _frames(tree, 6)
		var vias3: Array = model.get_connection(cid).get("route_3d", [])
		var v3 := Vector3(float(vias3[0]["x"]), float(vias3[0]["y"]), float(vias3[0]["z"])) \
			if vias3.size() == 1 else Vector3.INF
		_ok(v3.distance_to(v0) < 0.01, "Ctrl+Z puts the bend point back")
	# Height: drag the run up.
	tb.call("_set_active_tool", "route_height")
	await _frames(tree, 3)
	pts = mgr.get_sample_points(cid)
	var hp := cam.unproject_position(pts[pts.size() / 3])
	await HarnessInputScript.drag(vp, hp, hp + Vector2(0, -90), 14)
	await _frames(tree, 8)
	var st: Dictionary = model.get_connection(cid).get("conduit_style", {})
	_ok(st.has("run_height_m"), "dragging the run up sets its height (%s)" % str(st.get("run_height_m", "-")))
	await _shot(main, "04_height")
	# Open in Process.
	var proc_btn := HarnessInputScript.find_button(tb, "Open in Process")
	_ok(proc_btn != null, "Open in Process is on the options bar")
	if proc_btn != null:
		await HarnessInputScript.click(vp, HarnessInputScript.center_of(proc_btn))
		await _frames(tree, 20)
		_ok(gv.visible and str(gv.get("_graph_view_mode")) == GraphSiteLayout.VIEW_PROCESS,
			"the graph opened in the Process lens")
		var canvas: Node = gv.get("_graph_canvas")
		_ok(canvas != null and str(canvas.get("selected_connection_id")) == cid, "with the run selected")
		await _shot(main, "05_process")
		var lens: Node = canvas.call("process_lens") if canvas != null else null
		var face: Node = lens.call("faceplate") if lens != null else null
		var show_btn: Button = face.find_child("show3d", true, false) as Button if face != null else null
		_ok(show_btn != null and (show_btn as Control).is_visible_in_tree(), "the pipe card has Show in 3D")
		if show_btn != null:
			await HarnessInputScript.click(vp, HarnessInputScript.center_of(show_btn))
			await _frames(tree, 20)
			_ok(not gv.visible, "Show in 3D closed the graph")
			_ok(bool(tb.call("is_panel_open")) and str(rt.get("_picked")) == cid,
				"and the Route tools are on the same run")
			await _shot(main, "06_back_in_3d")
	await _test_lanes(main, tb, gv, mgr, model, cam, cid)
	tb.call("_exit_mode")
	main.call("pop_camera_claim", "conduit_tool_check")
	cam.queue_free()
	print("conduittool %d failures" % _fails.size())
	return {"ok": _fails.is_empty(), "fails": _fails}
