extends RefCounted

## The Process lens's "As built" picture with REAL input (sandbox):
##   tools\harness.ps1 -World w6af22bac295d -RunScript res://tools/checks/process_iso_check.gd -Label process_iso
## Makes a solver run between two placed machines, opens the graph in the
## Process lens, clicks "As built": machines at their world places, the run
## along its 3D corners, service colours on the pipes. Clicks the run, drags
## one of its bends: the run in the world gains a bend point there (one undo
## step, Ctrl+Z takes it back). Shots under screenshots\process_iso\.

const HarnessInputScript := preload("res://core/terrain/harness/harness_input.gd")

var _fails: Array = []
var _dir := "user://screenshots/process_iso"


func _ok(cond: bool, what: String) -> void:
	print("processiso %s: %s" % ["PASS" if cond else "FAIL", what])
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


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	if harness != null and "shots_dir" in harness and str(harness.get("shots_dir")).begins_with("user://"):
		_dir = str(harness.get("shots_dir"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_dir))
	await _frames(tree, 30)
	var gv: Node = main.find_child("SystemGraphView", true, false)
	var mgr: ConduitManager = main.get_node_or_null("ConduitManager") as ConduitManager
	var model: GraphModel = gv.get("model") as GraphModel
	main.set("time_scale", 0.0)
	# A solver run between two placed machines (water if the ports allow).
	var ports: Array = mgr.gather_world_ports()
	var pa := {}
	var pb := {}
	var best := INF
	for a: Dictionary in ports:
		for b: Dictionary in ports:
			if str(a["item_id"]) == str(b["item_id"]) or not ConduitPlugLogic.ports_compatible(a, b):
				continue
			# Both ends process parts in one group, so the picture draws the pipe.
			var ia := model.get_item(str(a["item_id"]))
			var ib := model.get_item(str(b["item_id"]))
			if ia.is_empty() or ib.is_empty() or str(ia.get("scope_id", "root")) != str(ib.get("scope_id", "root")):
				continue
			if not (str(ia.get("type", "")) in MimicGraphSource.TYPES and str(ib.get("type", "")) in MimicGraphSource.TYPES):
				continue
			var d := (a["world_pos"] as Vector3).distance_to(b["world_pos"] as Vector3)
			if d < 3.0 or d > 60.0:
				continue
			# A pipe (both ends carry a resource) beats a power wire.
			var ka := str((a.get("port", {}) as Dictionary).get("resource_kind", ""))
			var kb := str((b.get("port", {}) as Dictionary).get("resource_kind", ""))
			var score := absf(d - 12.0) + (0.0 if not ka.is_empty() and not kb.is_empty() else 1000.0)
			if score < best:
				best = score
				pa = a
				pb = b
	_ok(not pa.is_empty(), "two machines to join")
	if pa.is_empty():
		return {"ok": false, "fails": _fails}
	var spec := ConduitPlugLogic.build_connection_spec(pa, pb, "pvc_pipe", [])
	spec["route_solver"] = "v2"
	spec["visible_3d"] = true
	var cid := mgr.create_plug_connection(spec)
	await _frames(tree, 20)
	var conn := model.get_connection(cid)
	_ok(not conn.is_empty(), "a solver run between them")
	# The graph in the Process lens, on the run's scope.
	gv.call("open_run_in_process", cid)
	await _frames(tree, 30)
	var canvas: Node = gv.get("_graph_canvas")
	var lens: Node = canvas.call("process_lens")
	# Power lines show only on the Power layer.
	if str(conn.get("polarity", "")) != "resource":
		lens.call("set_layer", MimicGraphSource.LAYER_POWER, true)
		await _frames(tree, 10)
	var vp := main.get_viewport()
	var btn: Button = lens.find_child("view_built", true, false) as Button
	_ok(btn != null and btn.is_visible_in_tree(), "the As built button is on the bar")
	if btn == null:
		return {"ok": false, "fails": _fails}
	await HarnessInputScript.click(vp, HarnessInputScript.center_of(btn))
	await _frames(tree, 30)
	_ok(bool(lens.call("built")), "a click turns As built on")
	var doc: Dictionary = lens.get("_doc")
	_ok(bool(doc.get("built", false)), "the picture is the As built one")
	var pipe := {}
	for p: Dictionary in doc.get("pipes", []):
		if str(p["id"]) == cid:
			pipe = p
	if pipe.is_empty():
		var ids: Array = []
		for p2: Dictionary in doc.get("pipes", []):
			ids.append(str(p2["id"]))
		print("processiso info — %s (%s) not in the pipes %s" % [cid, str(conn.get("polarity", "")), str(ids)])
	_ok(pipe.has("world") and pipe.has("bends"), "the run is drawn along its 3D corners, with its bends")
	var mimic: Control = lens.get("mimic")
	var st: Dictionary = (mimic.get("state") as Dictionary).get("pipe", {})
	var svc: Variant = (st.get(cid, {}) as Dictionary).get("service")
	_ok(svc is Color and (svc as Color).a > 0.0, "the pipe wears its service colour")
	# Opened on a run, As built frames that run (no fit by hand).
	if not pipe.is_empty():
		var on_screen := 0
		var line0: PackedVector2Array = pipe["pts"]
		for q: Vector2 in line0:
			var sq := mimic.call("to_screen", q) as Vector2
			if Rect2(Vector2.ZERO, mimic.size).has_point(sq):
				on_screen += 1
		print("processiso info — framed: zoom %.3f, %d of %d points on screen, first %s" % [
			float(mimic.call("zoom")), on_screen, line0.size(), str(mimic.call("to_screen", line0[0]))])
		_ok(on_screen * 2 >= line0.size(), "As built opens framed on the run (%d of %d points on screen)" % [on_screen, line0.size()])
	await _shot(main, "00_framed")
	mimic.call("fit")
	await _frames(tree, 6)
	await _shot(main, "01_as_built")
	if not pipe.has("bends") or (pipe["bends"] as PackedVector2Array).is_empty():
		_ok(false, "the run has a bend to drag")
		return {"ok": false, "fails": _fails}
	# Click the run (its middle), then drag its first bend.
	var line: PackedVector2Array = pipe["pts"]
	var mid := mimic.call("to_screen", line[line.size() / 2]) as Vector2
	await HarnessInputScript.click(vp, mimic.get_global_transform() * mid)
	await _frames(tree, 6)
	_ok(str(mimic.get("selected_id")) == cid, "a click on the run selects it")
	var n_vias := (model.get_connection(cid).get("route_3d", []) as Array).size()
	var bend: Vector2 = (pipe["bends"] as PackedVector2Array)[0]
	var bs := mimic.get_global_transform() * (mimic.call("to_screen", bend) as Vector2)
	await HarnessInputScript.drag(vp, bs, bs + Vector2(60, 25), 12)
	await _frames(tree, 30)
	var vias := model.get_connection(cid).get("route_3d", []) as Array
	_ok(vias.size() == n_vias + 1, "dragging a bend gives the run a bend point (%d)" % vias.size())
	_ok(str(model.get_connection(cid).get("route_solver", "")) == "v2", "the run stays on the solver")
	await _shot(main, "02_bend_dragged")
	await HarnessInputScript.key(vp, KEY_Z, true)
	await _frames(tree, 20)
	_ok((model.get_connection(cid).get("route_3d", []) as Array).size() == n_vias, "Ctrl+Z takes it back")
	# Back to the schematic.
	await HarnessInputScript.click(vp, HarnessInputScript.center_of(btn))
	await _frames(tree, 20)
	_ok(not bool(lens.call("built")) and not bool((lens.get("_doc") as Dictionary).get("built", false)),
		"a second click puts the schematic back")
	await _shot(main, "03_schematic")
	print("processiso %d failures" % _fails.size())
	return {"ok": _fails.is_empty(), "fails": _fails}
