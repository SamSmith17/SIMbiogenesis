extends RefCounted

## The Closed Loop Ten greenhouse conversion, verified (sandbox):
##   tools\harness.ps1 -World w6af22bac295d -RunScript res://tools/checks/closed_loop_greenhouse_check.gd -Label clt_greenhouse -Timeout 1800
## Runs tools/fixes/closed_loop_greenhouses.gd on a sandbox copy, then: no
## dome-over-bed pair is left; every greenhouse is one node with its water,
## nutrients, food and residue wires where the beds' were and AC in; its beds
## stand inside it as its own props; moving one moves its beds; a sim day at
## speed runs every house's climate (printed: inside / outside at noon and
## night) and the beds put food in the stores. Shots from the air at noon.

var _fails: Array = []
var _dir := ""


func _ok(cond: bool, what: String) -> void:
	print("clt_greenhouse %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	_dir = "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(_dir)
	var sgv := ServiceLocator.graph()
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	var gm: GraphModel = sgv.get("model")
	main.set("time_scale", 0.0)
	var fix = load("res://tools/fixes/closed_loop_greenhouses.gd").new()
	var res: Dictionary = await fix.run(main, harness)
	_ok(int(res.get("converted", 0)) == 12, "twelve dome + bed pairs converted (%d)" % int(res.get("converted", 0)))
	for nline in res.get("notes", []):
		print("clt_greenhouse note: %s" % str(nline))
	var left := 0
	var ghs: Array = []
	for r in (loader.call("placed_prop_records") as Array):
		var rec: Dictionary = r
		if str(rec.get("model_id", "")) == DomeLabBuilder.MODEL_ID and not str(rec.get("greenhouse_beds", "")).is_empty():
			left += 1
		if GreenhouseWorld.is_greenhouse(rec):
			ghs.append(str(rec["id"]))
	_ok(left == 0, "no dome-over-bed pair is left")
	_ok(ghs.size() == 12, "twelve greenhouses stand (%d)" % ghs.size())
	var wired_ok := 0
	var beds_ok := 0
	var cids: Array = []
	for pid in ghs:
		var cid := str(sgv.call("greenhouse_system_item_id", pid))
		cids.append(cid)
		var handles := {}
		for c in gm.connections:
			var cd: Dictionary = c
			if str(cd.get("target_item_id", "")) == cid:
				handles[str(cd.get("target_handle_id", ""))] = true
			elif str(cd.get("source_item_id", "")) == cid:
				handles[str(cd.get("source_handle_id", ""))] = true
		if handles.has("water_in") and handles.has("nutrients_in") and handles.has("food_out") and handles.has("ac_in"):
			wired_ok += 1
		var parts := GreenhouseWorld.parts_of(main, pid)
		var kids := GreenhouseGraph.children_by_role(gm, cid)
		if not parts.is_empty() and (kids.get("bed", []) as Array).size() == parts.size():
			beds_ok += 1
	_ok(wired_ok == 12, "every greenhouse is wired: water + nutrients in, food out, AC in (%d)" % wired_ok)
	_ok(beds_ok == 12, "every greenhouse's beds stand in it with a node each (%d)" % beds_ok)
	# Move one: its beds follow.
	var p0: String = ghs[0]
	var bed_id := ""
	for k in GreenhouseWorld.parts_of(main, p0):
		bed_id = str((GreenhouseWorld.parts_of(main, p0)[k] as Dictionary)["id"])
		break
	var h0 := PlacedPropService.get_prop_record(main, p0).duplicate(true)
	var b0 := PlacedPropService.get_prop_record(main, bed_id).duplicate(true)
	PlacedPropService.update_prop_record(main, p0, {"x": float(h0["x"]) + 3.0}, true)
	await _frames(tree, 10)
	var b1 := PlacedPropService.get_prop_record(main, bed_id)
	_ok(absf(float(b1["x"]) - float(b0["x"]) - 3.0) < 0.05, "moving a greenhouse moves its beds (%.2f m)" % (float(b1["x"]) - float(b0["x"])))
	PlacedPropService.update_prop_record(main, p0, {"x": float(h0["x"])}, true)
	# A sim day at speed: the climate runs, the beds grow.
	var food0 := _food_kg(gm, cids)
	main.set("day_time", 6.0)
	main.set("time_scale", 2.0)
	var noon_seen := false
	var night_seen := false
	for _i in 4000:
		await tree.process_frame
		var hr := float(main.get("day_time"))
		if not noon_seen and hr >= 13.0 and hr < 14.0:
			noon_seen = true
			_report(gm, cids, "13:00")
			main.set("time_scale", 0.0)
			await _shot_air(main, loader, ghs)
			main.set("time_scale", 2.0)
		if noon_seen and not night_seen and hr >= 2.0 and hr < 3.0:
			night_seen = true
			_report(gm, cids, "02:00")
			break
	main.set("time_scale", 0.0)
	var with_t := 0
	for cid in cids:
		if (gm.get_item(str(cid)).get("specs", {}) as Dictionary).has("gh_t_air"):
			with_t += 1
	_ok(with_t == 12, "every house runs its climate (%d)" % with_t)
	var food1 := _food_kg(gm, cids)
	_ok(food1 > food0, "the beds harvest food over the day (%.1f → %.1f kg in the houses' crates)" % [food0, food1])
	return {"ok": _fails.is_empty(), "fails": _fails}


func _food_kg(gm: GraphModel, cids: Array) -> float:
	var kg := 0.0
	for cid in cids:
		for c in GreenhouseGraph.children_by_role(gm, str(cid)).get("harvest", []):
			var sp: Dictionary = (c as Dictionary)["specs"]
			kg += float(sp.get("level", 0.0)) * float(sp.get("capacity_qty", 0.0))
	return kg


func _report(gm: GraphModel, cids: Array, when: String) -> void:
	var lines: PackedStringArray = PackedStringArray()
	for cid in cids:
		var sp: Dictionary = gm.get_item(str(cid)).get("specs", {})
		lines.append("%s %.0f/%.0f°C %d%% v%d" % [str(sp.get("name", "")).replace("Greenhouse ", "G"),
			float(sp.get("gh_t_air", -99.0)), float(sp.get("gh_t_out", -99.0)), int(sp.get("gh_rh", 0)), int(sp.get("gh_vent_pct", 0))])
	print("clt_greenhouse %s: %s" % [when, " | ".join(lines)])


func _shot_air(main: Node, loader: Node, ghs: Array) -> void:
	var c := Vector2.ZERO
	for pid in ghs:
		var r := PlacedPropService.get_prop_record(main, str(pid))
		c += Vector2(float(r["x"]), float(r["z"]))
	c /= float(ghs.size())
	var player := main.get_node_or_null("Player") as Node3D
	var g := float(loader.call("ground_height_at", c.x, c.y))
	player.global_position = Vector3(c.x, g + 40.0, c.y + 70.0)
	player.look_at(Vector3(c.x, g, c.y), Vector3.UP)
	await _frames(main.get_tree(), 40)
	await RenderingServer.frame_post_draw
	main.get_viewport().get_texture().get_image().save_png("%s/air_noon.png" % _dir)
