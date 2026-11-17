extends RefCounted

## Terraces dug and farmed by the camp's people (sandbox):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/terrace_crew_check.gd -Label terrace_crew -Timeout 1500
## A small population is put beside a slope (supplies taken care of: the
## testing override), then:
## 1. A field marked out to be dug BY HAND: nothing is cut at first; a dig
##    project with one task per step lands on the camp's board, top step
##    first; the crew stands in a line along the step (spread across it, on
##    it) and the cut shows as the job goes; the person-hours match
##    TerraceDig's estimate; "Finish digging now" cuts the rest.
## 2. The farm work: the paddies need preparing; each job is a chore with a
##    row along its paddy; the crew works it; a paddy moves on to planting;
##    the ledger's hours and energy add up (80 Wh a person-hour).
## 3. The tractor: switching the field to machines draws the tractor at the
##    paddy it is tilling, gives the node a fuel port, and people still plant.
## 4. A field cut by the skid steer with a diesel store wired: the skid steer
##    is drawn on the step, the store goes down, and when it runs dry the dig
##    stops and says so.
## Shots under screenshots\<label>\.

const HAB := "tcw_hab"
const TANKS := ["tcw_water", "tcw_food", "tcw_grey", "tcw_black", "tcw_diesel"]

var _fails: Array = []
var _dir := ""
var _cam: Camera3D = null


func _ok(cond: bool, what: String) -> void:
	print("terrace_crew %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


func _shot(main: Node, name: String) -> void:
	await RenderingServer.frame_post_draw
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [_dir, name])


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
			var score := -absf(s - 0.18)
			if s >= 0.08 and s <= 0.3 and (best.is_empty() or score > best_s):
				best_s = score
				best = {"p": p, "slope": s, "down": -Vector2(gx, gz).normalized()}
	return best


func _look(loader: Node, at: Vector2, back_dir: Vector2, dist: float, height: float) -> void:
	var gy := float(loader.call("surface_height_at", at.x, at.y))
	_cam.global_position = Vector3(at.x + back_dir.x * dist, gy + height, at.y + back_dir.y * dist)
	_cam.look_at(Vector3(at.x, gy, at.y), Vector3.UP)


func _seed_people(view: Node, home: Vector2) -> void:
	var model = view.get("model")
	for id in [HAB] + TANKS:
		if not (model.get_item(str(id)) as Dictionary).is_empty():
			model.remove_item(str(id))
	model.add_item({"id": HAB, "type": "processor", "x": -600.0, "y": -400.0, "width": 150.0, "height": 150.0,
		"specs": {"name": "Terrace crew camp", "role": "habitat", "occupants": 14, "pop_driven": true,
			"watts": 0.0, "energy_source": "", "efficiency": 1.0, "home_x": home.x, "home_z": home.y,
			"inputs": [{"kind": "water", "rate": 2.083, "unit": "L/h"}, {"kind": "food", "rate": 0.0625, "unit": "kg/h"}],
			"outputs": [{"kind": "greywater", "rate": 1.666, "unit": "L/h"},
				{"kind": "blackwater", "rate": 0.417, "unit": "L/h"}]}})
	var defs := [["tcw_water", "water", "L", 5000.0, 1.0], ["tcw_food", "food", "kg", 300.0, 1.0],
		["tcw_grey", "greywater", "L", 5000.0, 0.0], ["tcw_black", "blackwater", "L", 2000.0, 0.0]]
	for i in defs.size():
		var t: Array = defs[i]
		model.add_item({"id": str(t[0]), "type": "resource", "x": -800.0 + 120.0 * i, "y": -200.0,
			"width": 90.0, "height": 100.0, "specs": {"name": str(t[1]).capitalize(),
				"resource_kind": str(t[1]), "capacity_qty": float(t[3]), "capacity_unit": str(t[2]),
				"level": float(t[4])}})
	for c in [["tcw_water", "output", HAB, "res_in_0", "water"], ["tcw_food", "output", HAB, "res_in_1", "food"],
			[HAB, "res_out_0", "tcw_grey", "input", "greywater"], [HAB, "res_out_1", "tcw_black", "input", "blackwater"]]:
		model.add_connection({"polarity": "resource", "resource_type": str(c[4]), "source_item_id": str(c[0]),
			"source_handle_id": str(c[1]), "target_item_id": str(c[2]), "target_handle_id": str(c[3])})


## The people working a chore whose key or id starts with `prefix` / is in
## `ids`: [[pos, chore]].
func _workers(bridge: Object, field_id: String) -> Array:
	var out: Array = []
	var engines: Dictionary = bridge.get("_engines")
	var eng: Object = engines.get(HAB)
	if eng == null:
		return out
	var board: Object = eng.get("chore_board")
	for a in eng.get("agents"):
		var cid := str(a.get("chore_id"))
		if cid.is_empty() or int(a.get("state")) != NpcAgent.State.DOING:
			continue
		var ch: Dictionary = board.call("find", cid)
		if str(ch.get("terrace_id", "")) == field_id:
			out.append([a.get("pos") as Vector2, ch])
	return out


## Distance from p to a polyline spine.
static func _to_spine(p: Vector2, spine: Array) -> float:
	var best := INF
	for i in range(1, spine.size()):
		var a := Vector2(float(spine[i - 1][0]), float(spine[i - 1][1]))
		var b := Vector2(float(spine[i][0]), float(spine[i][1]))
		best = minf(best, p.distance_to(Geometry2D.get_closest_point_to_segment(p, a, b)))
	return best


func _check_line(bridge: Object, field_id: String, what: String) -> bool:
	var w := _workers(bridge, field_id)
	if w.size() < 2:
		return false
	var ch: Dictionary = (w[0] as Array)[1]
	var spine: Array = ch.get("row_spine", [])
	var hw := float(ch.get("row_half_w", 2.0))
	var near := 0
	var spread := 0.0
	for e in w:
		var p: Vector2 = (e as Array)[0]
		if _to_spine(p, spine) <= hw + 2.5:
			near += 1
		for e2 in w:
			spread = maxf(spread, p.distance_to((e2 as Array)[0] as Vector2))
	_ok(near >= w.size() - 1, "%s: the crew stands on the work (%d of %d within the plot)" % [what, near, w.size()])
	_ok(spread > 1.2, "%s: spread out in a line, not on one spot (%.1f m across)" % [what, spread])
	return true


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	_dir = "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(_dir)
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	var player := main.get_node_or_null("Player") as Node3D
	var view := ServiceLocator.graph()
	_ok(loader != null and player != null and view != null, "a TerrainLoader world with a graph")
	if loader == null or player == null or view == null:
		return {"ok": false, "fails": _fails}
	if main.has_method("settlement_view_open") and bool(main.call("settlement_view_open")):
		(main.get("settlement_view") as Node).call("close")
		await _frames(tree, 20)
	PopTestPrefs.set_easy_override(true)
	main.set("day_time", 8.2)
	main.set("time_scale", 0.0)
	var rt: TerraceRuntime = loader.call("terraces")
	var p0 := Vector2(player.global_position.x, player.global_position.z)
	var spot := _slope_spot(loader, p0, 160.0)
	_ok(not spot.is_empty(), "a slope near the player")
	if spot.is_empty():
		return {"ok": false, "fails": _fails}
	var at: Vector2 = spot["p"]
	var down: Vector2 = spot["down"]
	_seed_people(view, at + down * 30.0)
	var bridge: Object = view.call("npc_population_bridge")
	main.set("time_scale", 60.0 / 3600.0)
	for _i in 120:
		await tree.process_frame
		var engs: Dictionary = bridge.get("_engines") if bridge != null else {}
		if engs.has(HAB) and not (engs[HAB].get("agents") as Array).is_empty():
			break
	var engs2: Dictionary = bridge.get("_engines")
	_ok(engs2.has(HAB) and not (engs2[HAB].get("agents") as Array).is_empty(), "the crew camp has people")
	_cam = Camera3D.new()
	_cam.fov = 55.0
	_cam.far = 3000.0
	main.add_child(_cam)
	main.call("push_camera_claim", "terrace_crew", {"camera_id": _cam.get_instance_id(), "hide_player_mesh": false})

	# --- 1. dug by hand -----------------------------------------------------
	var poly := rt.hill_outline(at + down * 10.0, 30.0)
	var id := rt.create(poly, {"step_h": TerraceField.auto_step_h(poly, Callable(loader, "ground_without_terraces")),
		"crop": "rice", "flooded": true, "labour": "people", "build_mode": "hand"})
	_ok(not id.is_empty(), "a field marked out to dig by hand (%s)" % rt.last_error)
	if id.is_empty():
		return _done(main, rt, "")
	await _frames(tree, 30)
	var s := rt.solved(id)
	var dsum := rt.dig_summary(id)
	print("terrace_crew: %d steps, %.0f m³, by hand %.0f h, machine %.0f h + %.0f L" % [int(dsum["steps"]),
		float(dsum["vol_m3"]), float((dsum["hand"] as Dictionary)["hours"]),
		float((dsum["machine"] as Dictionary)["machine_h"]), float((dsum["machine"] as Dictionary)["fuel_l"])])
	var steps: Array = (rt.get("_solved")[id] as Dictionary)["dig"]
	_ok(steps.size() >= 2 and float(dsum["vol_m3"]) > 1.0, "the field has steps to dig (%d)" % steps.size())
	var est := 0.0
	for st in steps:
		est += float(TerraceDig.estimate(float(st["vol_m3"]), float(st["floor_m2"]), "hand", float(st["length_m"]))["hours"])
	_ok(absf(est - float((dsum["hand"] as Dictionary)["hours"])) < 0.01, "the hours are TerraceDig's, step by step")
	# Nothing is cut before the crew digs.
	var top: Dictionary = steps[0]
	var probe := NpcRowWork.along(top["spine"], 0.9)["pos"] as Vector2
	var g0 := float(loader.call("ground_without_terraces", probe.x, probe.y))
	var t0 := float(loader.call("surface_height_at", probe.x, probe.y))
	_ok(absf(t0 - g0) < 0.05, "nothing is cut before the crew digs (%.2f m)" % (t0 - g0))
	var rec := rt.record(id)
	var dig: Dictionary = rec.get("dig", {})
	_ok(not str(dig.get("pid", "")).is_empty() and str(dig.get("iid", "")) == HAB,
		"a dig project on the camp's board (%s)" % str(dig))
	var store: Object = bridge.call("project_store_for", HAB)
	var project: Dictionary = store.call("find", str(dig.get("pid", ""))) if store != null else {}
	var tasks: Array = project.get("tasks", [])
	_ok(tasks.size() == steps.size() and str((tasks[0] as Dictionary).get("task_id", "")) == "s%d" % int(top["m"]),
		"one task per step, the top step first")
	_look(loader, NpcRowWork.along(top["spine"], 0.5)["pos"], down, 30.0, 18.0)
	# Run the clock until the top step is a share dug.
	main.set("time_scale", 300.0 / 3600.0)
	var saw_line := false
	var built_top := 0.0
	for k in 360:
		await _frames(tree, 30)
		if not saw_line and _workers(bridge, id).size() >= 3:
			saw_line = _check_line(bridge, id, "digging")
			if saw_line:
				_look(loader, (_workers(bridge, id)[0] as Array)[0], down, 18.0, 10.0)
				await _frames(tree, 8)
				await _shot(main, "01_digging_crew")
		built_top = TerraceField.step_built(rt.record(id), int(top["m"]))
		if saw_line and built_top >= 0.3:
			break
	print("terrace_crew: %s" % str(rt.work_status.get(id, {})))
	_ok(saw_line, "a digging crew came out")
	_ok(built_top > 0.0, "the top step is being dug (%.0f %%)" % (built_top * 100.0))
	if built_top > 0.0 and built_top < 0.999:
		var f0 := NpcRowWork.along(top["spine"], 0.02)["pos"] as Vector2
		var f1 := NpcRowWork.along(top["spine"], 0.98)["pos"] as Vector2
		var d0 := absf(float(loader.call("surface_height_at", f0.x, f0.y)) - float(loader.call("ground_without_terraces", f0.x, f0.y)))
		var d1 := absf(float(loader.call("surface_height_at", f1.x, f1.y)) - float(loader.call("ground_without_terraces", f1.x, f1.y)))
		print("terrace_crew: cut at the step's start %.2f m, at its end %.2f m" % [d0, d1])
		_ok(d0 >= d1, "the cut moves along the step (start %.2f m, end %.2f m)" % [d0, d1])
	_look(loader, NpcRowWork.along(top["spine"], 0.5)["pos"], down, 40.0, 26.0)
	await _frames(tree, 8)
	await _shot(main, "02_step_part_dug")
	main.set("time_scale", 0.0)
	rt.finish_dig_now(id)
	await _frames(tree, 80)
	var all_dug := true
	for st2 in steps:
		if TerraceField.step_built(rt.record(id), int(st2["m"])) < 0.999:
			all_dug = false
	_ok(all_dug, "Finish digging now cuts every step")
	var t1 := float(loader.call("surface_height_at", probe.x, probe.y))
	var want := float(TerraceMesh.sample((s["grid"] as Dictionary), (s["grid"] as Dictionary)["target"], probe))
	_ok(is_nan(want) or absf(t1 - want) < 0.25, "and the ground is the terrace (%.2f vs %.2f)" % [t1, want])
	_ok((project.get("state", "") != "active") or str(store.call("find", str(dig.get("pid", ""))).get("state", "")) != "active",
		"the dig project is closed")

	# --- 2. the farm work ---------------------------------------------------
	main.set("day_time", 8.2)
	main.set("time_scale", 300.0 / 3600.0)
	var jobs: Array = []
	for _j in 60:
		await _frames(tree, 10)
		jobs = (view.call("terrace_node_specs", id) as Dictionary).get("terrace_jobs", [])
		if not jobs.is_empty():
			break
	_ok(not jobs.is_empty() and str(jobs[0]["task"]) == "prep", "the paddies need preparing (%d jobs)" % jobs.size())
	var board: Object = bridge.call("chore_board_for", HAB)
	var keyed := 0
	for _w in 40:
		await _frames(tree, 10)
		var nk := 0
		for c0 in board.get("chores"):
			if str((c0 as Dictionary).get("chore_key", "")).begins_with("terr|%s|" % id):
				nk += 1
		if nk > 0:
			break
	for c in board.get("chores"):
		if str((c as Dictionary).get("chore_key", "")).begins_with("terr|%s|" % id):
			keyed += 1
			if keyed == 1:
				_ok(((c as Dictionary).get("row_spine", []) as Array).size() >= 2 and str((c as Dictionary).get("pose", "")) == "dig",
					"a paddy job is a chore worked in a row, stooping")
	_ok(keyed >= 1, "the jobs are on the camp's board (%d)" % keyed)
	var saw_farm := false
	var saw_tool := false
	var planted := false
	for k2 in 400:
		await _frames(tree, 30)
		if not saw_tool:
			for av in tree.get_nodes_in_group("npc_avatars"):
				if av.has_method("work_tool") and not str(av.call("work_tool")).is_empty():
					saw_tool = true
					print("terrace_crew: a worker holds a %s" % str(av.call("work_tool")))
					break
		if not saw_farm and _workers(bridge, id).size() >= 2:
			saw_farm = _check_line(bridge, id, "farming")
			if saw_farm:
				_look(loader, (_workers(bridge, id)[0] as Array)[0], down, 16.0, 9.0)
				await _frames(tree, 8)
				await _shot(main, "03_farm_crew")
		var pv: Array = (view.call("terrace_node_specs", id) as Dictionary).get("terrace_view", [])
		for e in pv:
			if str((e as Array)[0]) in ["plant", "grow"]:
				planted = true
		if saw_farm and planted:
			break
	_ok(saw_farm, "a farm crew came out to the paddies")
	_ok(saw_tool, "with tools in their hands")
	_ok(planted, "a prepared paddy moves on to planting")
	var led: Dictionary = (view.call("terrace_node_specs", id) as Dictionary).get("farm_ledger", {})
	print("terrace_crew: ledger %s" % str(led))
	_ok(float(led.get("labour_h", 0.0)) > 0.0, "the hours worked are counted (%.1f h)" % float(led.get("labour_h", 0.0)))
	_ok(absf(float(led.get("work_kwh", 0.0)) - float(led.get("labour_h", 0.0)) * 0.08) < 0.01,
		"at 80 Wh of work a person-hour")
	main.set("time_scale", 0.0)
	await _frames(tree, 10)
	_look(loader, at, down, 70.0, 45.0)
	await _frames(tree, 10)
	await _shot(main, "04_field")

	# --- 3. the tractor -------------------------------------------------------
	rt.update(id, {"labour": "machines"})
	main.set("day_time", 9.0)
	main.set("time_scale", 120.0 / 3600.0)
	var saw_tractor := false
	for _k3 in 120:
		await _frames(tree, 15)
		var rg: Dictionary = rt.rigs_debug().get(id, {})
		if str(rg.get("model", "")) == "vehicle_tractor":
			saw_tractor = true
			var tp: Vector3 = rg["pos"]
			_look(loader, Vector2(tp.x, tp.z), down, 14.0, 7.0)
			await _frames(tree, 30)
			await _shot(main, "05_tractor_tilling")
			break
	_ok(saw_tractor, "the tractor comes out to till a paddy")
	var mj: Array = (view.call("terrace_node_specs", id) as Dictionary).get("terrace_machine", [])
	print("terrace_crew: tractor jobs %s · %s" % [str(mj), str(rt.work_status.get(id, {}))])
	var gid := str(view.call("terrace_node_id", id))
	var hs := GraphPortService.resolved_handles((view.get("model")).get_item(gid), {})
	var has_fuel := false
	for h in hs:
		if str((h as Dictionary).get("id", "")) == "fuel_in":
			has_fuel = true
	_ok(has_fuel, "and the node takes fuel")
	main.set("time_scale", 0.0)
	rt.delete(id)
	await _frames(tree, 20)

	# --- 4. the skid steer, on a diesel store -----------------------------------
	var model = view.get("model")
	model.add_item({"id": "tcw_diesel", "type": "resource", "x": -400.0, "y": -200.0, "width": 90.0,
		"height": 100.0, "specs": {"name": "Diesel tote", "resource_kind": "diesel", "capacity_qty": 200.0,
			"capacity_unit": "L", "level": 1.0}})
	var poly2 := rt.hill_outline(at + down * 10.0, 26.0)
	var id2 := rt.create(poly2, {"step_h": TerraceField.auto_step_h(poly2, Callable(loader, "ground_without_terraces")),
		"crop": "rice", "flooded": true, "labour": "people", "build_mode": "skid_steer"})
	_ok(not id2.is_empty(), "a field to cut with the skid steer")
	await _frames(tree, 40)
	_ok(bool(view.call("terrace_wire", id2, "fuel_in", "tcw_diesel")), "its fuel input wired to a diesel tote")
	var steps2: Array = (rt.get("_solved")[id2] as Dictionary).get("dig", [])
	var m0: Dictionary = steps2[0] if not steps2.is_empty() else {}
	var e0 := TerraceDig.estimate(float(m0.get("vol_m3", 0.0)), float(m0.get("floor_m2", 0.0)), "skid_steer",
		float(m0.get("length_m", 1.0)))
	print("terrace_crew: skid steer, step 1: %.0f m³ in %.1f machine-h, %.1f L" % [float(m0.get("vol_m3", 0.0)),
		float(e0["machine_h"]), float(e0["fuel_l"])])
	main.set("day_time", 9.0)
	main.set("time_scale", 300.0 / 3600.0)
	var saw_skid := false
	var lvl0 := float((model.get_item("tcw_diesel")["specs"] as Dictionary).get("level", 1.0))
	for _k4 in 300:
		await _frames(tree, 15)
		var rg2: Dictionary = rt.rigs_debug().get(id2, {})
		if not saw_skid and str(rg2.get("model", "")) == "vehicle_skid_steer":
			saw_skid = true
			var sp2: Vector3 = rg2["pos"]
			await _frames(tree, 60)
			sp2 = rt.rigs_debug().get(id2, {}).get("pos", sp2)
			_look(loader, Vector2(sp2.x, sp2.z), down, 13.0, 7.0)
			await _frames(tree, 20)
			await _shot(main, "06_skid_steer_cutting")
		var dl: Dictionary = (rt.record(id2).get("dig", {}) as Dictionary).get("ledger", {})
		if saw_skid and float(dl.get("fuel_l", 0.0)) > 0.5:
			break
	_ok(saw_skid, "the skid steer comes out to cut the step")
	var lvl1 := float((model.get_item("tcw_diesel")["specs"] as Dictionary).get("level", 1.0))
	var dl2: Dictionary = (rt.record(id2).get("dig", {}) as Dictionary).get("ledger", {})
	print("terrace_crew: dig ledger %s, tote %.3f -> %.3f" % [str(dl2), lvl0, lvl1])
	_ok(float(dl2.get("fuel_l", 0.0)) > 0.0 and lvl1 < lvl0, "it burns the tote's diesel")
	# Empty the tote: the dig stops and says so.
	var dsp: Dictionary = (model.get_item("tcw_diesel")["specs"] as Dictionary).duplicate(true)
	dsp["level"] = 0.0
	model.update_item("tcw_diesel", {"specs": dsp})
	var flow: Object = view.get("_resource_flow")
	if flow != null:
		var tl: ResourceTimeline = flow.call("get_timeline", "tcw_diesel")
		if tl != null:
			tl.set_current_level(float(main.call("get_absolute_hours")), 0.0)
	var stopped := false
	for _k5 in 120:
		await _frames(tree, 15)
		if bool((rt.record(id2).get("dig", {}) as Dictionary).get("no_fuel", false)):
			stopped = true
			break
	_ok(stopped, "out of diesel the dig stops (%s)" % str(rt.work_status.get(id2, {}).get("dig", "")))
	main.set("time_scale", 0.0)
	id = id2
	return _done(main, rt, id)


func _done(main: Node, rt: TerraceRuntime, id: String) -> Dictionary:
	main.set("time_scale", 0.0)
	if not id.is_empty():
		rt.delete(id)
	var view := ServiceLocator.graph()
	if view != null:
		var model = view.get("model")
		for gid in [HAB] + TANKS:
			if not (model.get_item(str(gid)) as Dictionary).is_empty():
				model.remove_item(str(gid))
	PopTestPrefs.set_easy_override(false)
	if main.has_method("pop_camera_claim"):
		main.call("pop_camera_claim", "terrace_crew")
	if _cam != null:
		_cam.queue_free()
	return {"ok": _fails.is_empty(), "fails": _fails}
