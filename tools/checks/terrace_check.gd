extends RefCounted

## Terraced fields on a real world (sandbox, REAL clicks):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/terrace_check.gd -Label terraces -Timeout 1200
## 1. The T toolbar's Terrace tool with the Hill shape: a real click on the
##    steepest slope near the player cuts a field (one paddy per step), the
##    editor dock opens on it, the ground under every floor is level at its
##    step's height, the field has a graph node.
## 2. Water: a full cistern wired to its intake and a pond to its overflow
##    through the graph; with the clock running the TOP step fills first;
##    "Fill now" fills every step, the spills show, the overflow store gets
##    water.
## 3. Editing: a taller step re-cuts with fewer steps; dry steps hide the
##    water; a reed bed rebuilds the crop.
## 4. A real click inside the field selects it, Delete removes it (the
##    hillside comes back, its graph node goes), Ctrl+Z brings it back.
## Shots under screenshots\<label>\.

var _fails: Array = []
var _dir := ""
var _cam: Camera3D = null


func _ok(cond: bool, what: String) -> void:
	print("terraces %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


func _shot(main: Node, name: String) -> void:
	await RenderingServer.frame_post_draw
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [_dir, name])


func _settle(tree: SceneTree, rt: TerraceRuntime) -> void:
	var before := rt.rebuild_count
	for _i in 120:
		await tree.process_frame
		if rt.rebuild_count > before:
			break
	await _frames(tree, 40)


## The steepest point within `reach` of `c` (ground without terraces, sampled
## every 12 m, slope over ±10 m), with a slope between 6 % and 60 %.
func _slope_spot(loader: Node, c: Vector2, reach: float) -> Dictionary:
	var best := {}
	var best_s := 0.0
	var step := 12.0
	var n := int(reach / step)
	for j in range(-n, n + 1):
		for i in range(-n, n + 1):
			var p := c + Vector2(i, j) * step
			if p.distance_to(c) > reach:
				continue
			var gx := float(loader.call("ground_without_terraces", p.x + 10.0, p.y)) \
				- float(loader.call("ground_without_terraces", p.x - 10.0, p.y))
			var gz := float(loader.call("ground_without_terraces", p.x, p.y + 10.0)) \
				- float(loader.call("ground_without_terraces", p.x, p.y - 10.0))
			var s := Vector2(gx, gz).length() / 20.0
			# A farmable slope: 10–35 % (steeper is cliff work).
			var score := -absf(s - 0.22)
			if s >= 0.1 and s <= 0.35 and (best.is_empty() or score > best_s):
				best_s = score
				best = {"p": p, "slope": s, "down": -Vector2(gx, gz).normalized()}
	return best


func _look(main: Node, loader: Node, at: Vector2, back_dir: Vector2, dist: float, height: float) -> void:
	var gy := float(loader.call("surface_height_at", at.x, at.y))
	var eye := Vector3(at.x + back_dir.x * dist, gy + height, at.y + back_dir.y * dist)
	_cam.global_position = eye
	_cam.look_at(Vector3(at.x, gy, at.y), Vector3.UP)


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	_dir = "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(_dir)
	main.set("day_time", 10.5)
	main.set("time_scale", 0.0)
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	var player := main.get_node_or_null("Player") as Node3D
	_ok(loader != null and player != null, "a TerrainLoader world with a player")
	if loader == null or player == null:
		return {"ok": false, "fails": _fails}
	if main.has_method("settlement_view_open") and bool(main.call("settlement_view_open")):
		(main.get("settlement_view") as Node).call("close")
		await _frames(tree, 20)
	var rt: TerraceRuntime = loader.call("terraces")
	var view := ServiceLocator.graph()
	_ok(view != null and view.has_method("sync_terrace_node"), "the graph view is there")
	var p0 := Vector2(player.global_position.x, player.global_position.z)
	var spot := _slope_spot(loader, p0, 160.0)
	_ok(not spot.is_empty(), "a slope near the player")
	if spot.is_empty():
		return {"ok": false, "fails": _fails}
	var at: Vector2 = spot["p"]
	var down: Vector2 = spot["down"]
	print("terraces: slope %.0f%% at %s" % [float(spot["slope"]) * 100.0, at])
	# Click a little down the slope so the field takes the hill above it.
	var click_at := at + down * 20.0
	_cam = Camera3D.new()
	_cam.fov = 60.0
	_cam.far = 4000.0
	main.add_child(_cam)
	main.call("push_camera_claim", "terrace_check", {"camera_id": _cam.get_instance_id(), "hide_player_mesh": false})
	_look(main, loader, at, down, 95.0, 70.0)
	await _frames(tree, 10)
	await _shot(main, "00_slope_before")

	# --- 1. the Hill tool, a real click ------------------------------------
	var tb: Control = loader.get("_edit_toolbar_ui")
	_ok(tb != null, "the edit toolbar exists")
	tb.call("open_with_section", "terrain")
	tb.call("_set_active_tool", "terrace")
	var st: RefCounted = tb.get("_state")
	st.call("set_tool_param", "terrace", "hill_r_m", 70.0)
	st.call("set_tool_param", "terrace", "step_h", 0.0)
	st.set("terrace_crop", "rice")
	st.set("terrace_flooded", true)
	st.set("terrace_build", "instant")
	st.set("terrace_labour", "free")
	tb.call("_set_shape", "hill")
	await _frames(tree, 10)
	var vp := main.get_viewport()
	var px := HarnessInput.ground_screen(_cam, loader, click_at, 0.2)
	HarnessInput.mouse_move(vp, px)
	await _frames(tree, 25)
	await _shot(main, "01_hill_preview")
	HarnessInput.click(vp, px)
	await _frames(tree, 5)
	var id := rt.selected
	_ok(not id.is_empty(), "a click with Hill cuts a field (%s)" % id)
	if id.is_empty():
		_cleanup(main, tb)
		return {"ok": false, "fails": _fails}
	await _settle(tree, rt)
	var dock: Variant = tb.get("_terrace_tools").call("dock")
	_ok(dock != null and (dock as Control).visible, "the editor dock opens on the new field")
	var s := rt.solved(id)
	var npad := (s.get("paddies", []) as Array).size()
	_ok(npad >= 3, "the field has several steps (%d paddies, %s)" % [npad, str(s.get("stats", {}))])
	# Every floor sample's ground is at its step's level.
	var g: Dictionary = s.get("grid", {})
	var worst := 0.0
	var checked := 0
	if not g.is_empty():
		var lab: PackedInt32Array = g["label"]
		var dd: PackedFloat32Array = g["d"]
		var fl: PackedFloat32Array = g["flat"]
		var cols := int(g["cols"])
		var cell := float(g["cell"])
		var pads: Array = s["paddies"]
		var k := 0
		while k < lab.size() and checked < 400:
			if lab[k] >= 0 and absf(dd[k]) < fl[k] - 0.05:
				var x := float(int(g["i0"]) + k % cols) * cell
				var z := float(int(g["j0"]) + k / cols) * cell
				var fy := float((pads[lab[k]] as Dictionary)["floor_y"])
				worst = maxf(worst, absf(float(loader.call("ground_height_at", x, z)) - fy))
				checked += 1
			k += 7
	_ok(checked > 50 and worst < 0.05, "the ground under the floors is level at each step (%d samples, worst %.3f m)" % [checked, worst])
	var gid := str(view.call("terrace_node_id", id))
	_ok(not gid.is_empty(), "the field has a graph node")
	_look(main, loader, at, down, 85.0, 55.0)
	await _frames(tree, 20)
	await _shot(main, "02_cut")

	# --- 2. water through the graph -----------------------------------------
	var model: Variant = view.get("model")
	var cid: String = model.call("generate_item_id")
	model.call("add_item", {"id": cid, "type": "resource", "x": 0.0, "y": 0.0, "width": 90.0, "height": 100.0,
		"scope_id": "root", "specs": {"name": "Check cistern", "resource_kind": "water",
			"capacity_qty": 5.0e6, "capacity_unit": "L", "level": 1.0}})
	var pid: String = model.call("generate_item_id")
	model.call("add_item", {"id": pid, "type": "resource", "x": 0.0, "y": 300.0, "width": 90.0, "height": 100.0,
		"scope_id": "root", "specs": {"name": "Check pond", "resource_kind": "water",
			"capacity_qty": 5.0e6, "capacity_unit": "L", "level": 0.0}})
	_ok(bool(view.call("terrace_wire", id, "water_in", cid)), "the cistern wires to the intake")
	_ok(bool(view.call("terrace_wire", id, "water_out", pid)), "the pond wires to the overflow")
	rt.update(id, {"inflow_mode": "pump", "inflow_lph": 60000.0})
	await _frames(tree, 30)
	main.set("time_scale", 0.4)
	await _frames(tree, 240)
	main.set("time_scale", 0.0)
	var fills: Array = (view.call("terrace_node_specs", id) as Dictionary).get("terrace_fill", [])
	print("terraces: fills after pumping %s" % str(fills))
	_ok(fills.size() == npad and float(fills[0]) > 0.0, "pumped water reaches the top step")
	var last_f := float(fills[fills.size() - 1]) if fills.size() > 0 else 1.0
	_ok(fills.size() > 1 and float(fills[0]) >= last_f, "the top fills before the bottom")
	rt.set_fill(id, 1.0)
	main.set("time_scale", 0.05)
	await _frames(tree, 90)
	main.set("time_scale", 0.0)
	await _frames(tree, 30)
	var ns: Dictionary = view.call("terrace_node_specs", id)
	print("terraces: after Fill now — out %.0f L/h, held %.0f L" % [float(ns.get("outflow_lph", 0.0)), float(ns.get("water_held_l", 0.0))])
	_ok(float(ns.get("outflow_lph", 0.0)) > 0.0, "a full field spills out of the bottom")
	var pond_level := float((model.call("get_item", pid)["specs"] as Dictionary).get("level", 0.0))
	_ok(pond_level > 0.0, "the overflow store takes the spill (%.5f)" % pond_level)
	var vis: Dictionary = rt.get("_vis").get(id, {})
	var wet := 0
	for w in vis.get("waters", []):
		if w is MeshInstance3D and (w as MeshInstance3D).visible:
			wet += 1
	var spilling := 0
	for f in vis.get("falls", []):
		if f is MeshInstance3D and (f as MeshInstance3D).visible:
			spilling += 1
	_ok(wet >= npad - 1, "every step shows its water (%d of %d)" % [wet, npad])
	_ok(spilling > 0, "the spills show running down the risers (%d)" % spilling)
	_look(main, loader, at, down, 60.0, 30.0)
	await _frames(tree, 20)
	await _shot(main, "03_flooded")
	_look(main, loader, at + down * 10.0, Vector2(-down.y, down.x), 22.0, 6.0)
	await _frames(tree, 20)
	await _shot(main, "04_flooded_close")
	# Late in the crop: rice ripening gold.
	var plant_h := float(rt.record(id).get("plant_abs_h", 0.0))
	rt.update(id, {"plant_abs_h": plant_h - 24.0 * 100.0})
	await _frames(tree, 40)
	await _shot(main, "05_ripening_close")
	_look(main, loader, at, down, 90.0, 45.0)
	await _frames(tree, 20)
	await _shot(main, "06_ripening")

	# --- 3. editing -----------------------------------------------------------
	var h0 := float(rt.record(id).get("step_h", 1.0))
	_ok(h0 >= 0.5 and h0 <= 3.5, "Auto picks a step height for the slope (%.1f m)" % h0)
	rt.update(id, {"step_h": h0 * 2.0})
	await _settle(tree, rt)
	var npad2 := (rt.solved(id).get("paddies", []) as Array).size()
	_ok(npad2 < npad, "taller steps make fewer of them (%d → %d)" % [npad, npad2])
	rt.update(id, {"flooded": false, "crop": "potato"})
	await _frames(tree, 30)
	vis = rt.get("_vis").get(id, {})
	var any_water := false
	for w in vis.get("waters", []):
		if w is MeshInstance3D:
			any_water = true
	_ok(not any_water, "dry steps have no standing water")
	rt.update(id, {"flooded": true, "crop": "reed", "step_h": h0})
	await _settle(tree, rt)
	vis = rt.get("_vis").get(id, {})
	_ok(int(vis.get("tufts", 0)) > 0, "a reed bed is planted (%d clumps drawn)" % int(vis.get("tufts", 0)))
	_look(main, loader, at, down, 70.0, 35.0)
	await _frames(tree, 20)
	await _shot(main, "07_reeds")

	# --- 4. select, delete, undo with real input -----------------------------
	tb.get("_terrace_tools").call("deselect")
	await _frames(tree, 5)
	var inside := click_at - down * 15.0
	if rt.field_at(inside) != id:
		inside = Vector2(float((rt.solved(id)["paddies"][0] as Dictionary)["cx"]),
			float((rt.solved(id)["paddies"][0] as Dictionary)["cz"]))
	_look(main, loader, at, down, 95.0, 70.0)
	await _frames(tree, 10)
	var px2 := HarnessInput.ground_screen(_cam, loader, inside, 0.2)
	HarnessInput.mouse_move(vp, px2)
	await _frames(tree, 5)
	HarnessInput.click(vp, px2)
	await _frames(tree, 5)
	_ok(rt.selected == id, "a real click inside the field selects it")
	HarnessInput.key(vp, KEY_DELETE)
	await _frames(tree, 5)
	_ok(rt.record(id).is_empty(), "Delete removes the field")
	await _settle(tree, rt)
	_ok(str(view.call("terrace_node_id", id)).is_empty(), "its graph node goes with it")
	var back := absf(float(loader.call("ground_height_at", inside.x, inside.y))
		- float(loader.call("ground_without_terraces", inside.x, inside.y)))
	_ok(back < 0.01, "the hillside comes back (%.3f m)" % back)
	HarnessInput.key(vp, KEY_Z, true)
	await _frames(tree, 5)
	_ok(not rt.record(id).is_empty(), "Ctrl+Z brings the field back")
	await _settle(tree, rt)
	_ok(not str(view.call("terrace_node_id", id)).is_empty(), "and its graph node")
	print(rt.debug_line())
	# Leave nothing behind (it is a sandbox, but a clean exit shows delete works).
	for fid in rt.field_ids():
		rt.delete(str(fid))
	await _settle(tree, rt)
	_ok(rt.get("_keys").is_empty(), "no terrace tiles left once every field is gone")
	model.call("remove_item", cid)
	model.call("remove_item", pid)
	_cleanup(main, tb)
	return {"ok": _fails.is_empty(), "fails": _fails}


func _cleanup(main: Node, tb: Control) -> void:
	if tb != null:
		tb.call("_exit_mode")
	main.call("pop_camera_claim", "terrace_check")
	if _cam != null:
		_cam.queue_free()
