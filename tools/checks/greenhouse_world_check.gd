extends RefCounted

## A placed greenhouse on the graph and in the world (sandbox, Mount Vernon):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/greenhouse_world_check.gd -Label greenhouse_world -Timeout 1200
## Places a gable with beds, lamps, fans, a heater, barrels and a cistern;
## checks ONE graph node holds its beds (bound to the bed props, each prop
## linked back), lamps, fans, heater, barrels, roof + tank; wires the site's AC
## into it; runs the clock with the graph closed and checks the climate on the
## node, the loads following the controller, the card, the world runtime
## (label, vents); moves the house and checks the node's place follows; packs
## it (the node packed); deletes it (the node and its parts gone).

var _fails: Array = []
var _dir := ""


func _ok(cond: bool, what: String) -> void:
	print("greenhouse_world %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


func _shot(main: Node, name: String) -> void:
	await RenderingServer.frame_post_draw
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [_dir, name])


func _spec() -> Dictionary:
	var s: Dictionary = GreenhousePresets.builtin("gable_pc")["spec"].duplicate(true)
	s["heater"] = "electric_5000"
	s["fans"] = {"kind": "fan_24", "count": 2}
	s["lights"]["on"] = true
	s["beds"]["lights"] = true
	s["mass"]["barrels"] = 6
	s["rain"]["gutters"] = true
	s["rain"]["cistern_l"] = 1000.0
	return GreenhouseSpec.to_json_safe(s)


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	_dir = "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(_dir)
	main.set("day_time", 11.0)
	main.set("time_scale", 0.0)
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	var player := main.get_node_or_null("Player") as CharacterBody3D
	var sgv := ServiceLocator.graph()
	_ok(loader != null and player != null and sgv != null, "a TerrainLoader world with a player and a graph")
	if loader == null or player == null or sgv == null:
		return {"ok": false, "fails": _fails}
	var gm: GraphModel = sgv.get("model")
	var p0 := player.global_position
	var at := _clear_spot(main, Vector2(p0.x, p0.z))
	var pid := PlacedPropService.place_prepped_at(main, GreenhouseBuilder.MODEL_ID,
		{"record_extra": {GreenhouseSpec.KEY: _spec(), "collision_enabled": true, "walk_in": true}}, at.x, at.y, 0.0)
	_ok(not pid.is_empty(), "placed a greenhouse")
	await _frames(tree, 40)
	var cid := str(sgv.call("greenhouse_system_item_id", pid))
	_ok(not cid.is_empty(), "it is ONE node on the graph")
	if cid.is_empty():
		return {"ok": false, "fails": _fails}
	var kids := GreenhouseGraph.children_by_role(gm, cid)
	var parts := GreenhouseWorld.parts_of(main, pid)
	var n_beds := 0
	for k in parts:
		if str(k).begins_with("bed:"):
			n_beds += 1
	var bound := 0
	for c in kids.get("bed", []):
		var bp := str(((c as Dictionary).get("specs", {}) as Dictionary).get("bound_prop_id", ""))
		var brec := PlacedPropService.get_prop_record(main, bp)
		if not brec.is_empty() and str(brec.get("graph_item_id", "")) == str((c as Dictionary)["id"]):
			bound += 1
	_ok((kids.get("bed", []) as Array).size() == n_beds and bound == n_beds and n_beds > 0,
		"a bed node per bed (%d), each bound to its bed prop and back" % n_beds)
	_ok(kids.has("lights") and kids.has("fans") and kids.has("heater") and kids.has("barrels") and kids.has("roof") and kids.has("tank"),
		"lamps, fans, heater, barrels, roof and tank inside it")
	_ok(str(PlacedPropService.get_prop_record(main, pid).get("graph_item_id", "")) == cid, "the house's record points at its node")
	# The site's AC into the house: the first controller with an AC output.
	var inv := ""
	for it in gm.get_items_in_scope("root"):
		var sp: Dictionary = (it as Dictionary).get("specs", {})
		if str((it as Dictionary).get("type", "")) == "controller" and float(sp.get("overload_watts", 0.0)) > 0.0:
			inv = str((it as Dictionary)["id"])
			break
	if not inv.is_empty():
		gm.add_connection({"scope_id": "root", "polarity": "ac", "source_item_id": inv, "source_handle_id": "acOutput",
			"target_item_id": cid, "target_handle_id": "ac_in", "line_style": "bezier", "curve_tension": 1.0, "corner_radius": 28.0})
	print("greenhouse_world: site inverter %s" % (inv if not inv.is_empty() else "(none)"))
	# Run the clock with the graph closed: ~6 sim-hours.
	main.set("time_scale", 2.0)
	var sp2: Dictionary = {}
	for _i in 600:
		await tree.process_frame
		sp2 = gm.get_item(cid).get("specs", {})
		if sp2.has("gh_t_air") and float(main.call("get_absolute_hours")) > 0.0:
			break
	await _frames(tree, 200)
	main.set("time_scale", 0.0)
	sp2 = gm.get_item(cid).get("specs", {})
	_ok(sp2.has("gh_t_air"), "the clock runs the climate: inside %.1f °C, outside %.1f °C, %d %% RH, vents %d %%" % [
		float(sp2.get("gh_t_air", -99.0)), float(sp2.get("gh_t_out", -99.0)), int(sp2.get("gh_rh", 0)), int(sp2.get("gh_vent_pct", 0))])
	var fans_state := str((gm.get_item(str(kids["fans"][0]["id"])).get("specs", {}) as Dictionary).get("requested_state", ""))
	_ok((fans_state == "on") == bool(sp2.get("gh_fans", false)), "the fan load follows the controller (%s)" % fans_state)
	var card := GraphCardSpecs.for_item(gm.get_item(cid), {})
	_ok(str(card.get("hero", "")).contains("°C") and str(card.get("chip", "")) == "GREENHOUSE", "its card reads the inside air (%s)" % str(card.get("hero", "")))
	var node := PlacedPropRuntime.find_by_prop_id(main, pid)
	var rt := node.find_child(GreenhouseRuntime.NODE_NAME, true, false) if node != null else null
	_ok(rt != null and not (rt.call("state") as Dictionary).is_empty(), "the house in the world reads its node")
	main.set("day_time", 13.0)
	player.global_position = Vector3(at.x + 10.0, float(loader.call("ground_height_at", at.x, at.y)) + 4.0, at.y + 12.0)
	player.look_at(Vector3(at.x, player.global_position.y - 2.0, at.y), Vector3.UP)
	await _frames(tree, 40)
	await _shot(main, "1_running")
	# Move it: the node's place follows.
	var s0 := GraphSiteLayout.site_xz(gm.get_item(cid))
	PlacedPropService.update_prop_record(main, pid, {"x": at.x + 8.0}, true)
	await _frames(tree, 20)
	var s1 := GraphSiteLayout.site_xz(gm.get_item(cid))
	_ok(s1.distance_to(s0) > 6.0, "moving the house moves its node (%.1f m)" % s1.distance_to(s0))
	_ok(str(sgv.call("greenhouse_system_item_id", pid)) == cid, "a move keeps the same node")
	# Pack: the node is packed.
	loader.call("set_prop_packed", pid, true)
	await _frames(tree, 20)
	_ok(bool((gm.get_item(cid).get("specs", {}) as Dictionary).get("packed_3d", false)), "packing the house packs its node")
	loader.call("set_prop_packed", pid, false)
	await _frames(tree, 20)
	# Delete: node and parts go.
	loader.call("delete_prop_by_id", pid)
	await _frames(tree, 20)
	_ok(str(sgv.call("greenhouse_system_item_id", pid)).is_empty() and gm.get_item(cid).is_empty(), "deleting the house removes its node")
	return {"ok": _fails.is_empty(), "fails": _fails}


func _clear_spot(main: Node, from: Vector2) -> Vector2:
	var recs: Array = []
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	if loader != null and loader.has_method("placed_prop_records"):
		recs = loader.call("placed_prop_records")
	for ring in range(3, 20):
		for k in 16:
			var a := TAU * float(k) / 16.0
			var c := from + Vector2(cos(a), sin(a)) * (float(ring) * 25.0)
			var ok := true
			for r in recs:
				var q := Vector2(float(r.get("x", 0.0)), float(r.get("z", 0.0)))
				if q.distance_to(c) < 40.0:
					ok = false
			if ok:
				return c
	return from + Vector2(0.0, -60.0)
