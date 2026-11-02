extends RefCounted

## A living vehicle's cargo bay on a real world (sandbox, Phase 6):
##   tools\harness.ps1 -World walton -RunScript res://tools/checks/vehicle_cargo_check.gd -Label vehicle_cargo -Timeout 1200
## A box truck is placed and the starter-camp kit is delivered STOWED in its
## bay (TerrainLoader.deliver_kit_in_vehicle): the crates sit inside its floor
## rectangle and a crew unload project is queued. The truck is driven 30 m and
## turned a quarter: every crate rides at its place in the bay, records too.
## Then the clock runs and the crew carries crates out of its door to staging:
## an unloaded crate is no longer stowed and stands on the ground outside.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("vehiclecargo %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var dir := "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(dir)
	main.set("time_scale", 0.001)
	var day0: float = floor(float(main.call("get_absolute_hours")) / 24.0) * 24.0
	main.call("set_absolute_hours", day0 + 9.0)
	await _frames(tree, 10)
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	var player := main.get_node_or_null("Player") as CharacterBody3D
	var sgv := ServiceLocator.graph()
	_ok(loader != null and player != null and sgv != null, "a map with a player and a graph")
	if loader == null or player == null or sgv == null:
		return {"ok": false, "fails": _fails}
	var bridge: Variant = sgv.call("npc_population_bridge")
	if bridge == null or str(bridge.call("first_crewable_habitat")).is_empty():
		if main.has_method("open_festival_mode"):
			main.call("open_festival_mode")
			await _frames(tree, 120)
			if main.has_method("close_settlement_view"):
				main.call("close_settlement_view")
		bridge = sgv.call("npc_population_bridge")
	_ok(bridge != null and not str(bridge.call("first_crewable_habitat")).is_empty(), "a crew on the site")
	var p0 := player.global_position
	var spec := VehicleSpec.to_json_safe(VehiclePresets.builtin("box_truck"))
	var vid := PlacedPropService.place_prepped_at(main, VehicleBuilder.MODEL_ID,
		{"record_extra": {"vehicle_spec": spec, "collision_enabled": true}}, p0.x + 14.0, p0.z, 0.0)
	await _frames(tree, 10)
	_ok(not vid.is_empty(), "a box truck is placed")
	var res: Dictionary = loader.call("deliver_kit_in_vehicle", "starter_camp", vid)
	await _frames(tree, 20)
	var crates: Array = res.get("crate_ids", [])
	_ok(not crates.is_empty(), "the starter camp is delivered into it (%d crates)" % crates.size())
	var d := VehicleDesign.solve(VehiclePresets.builtin("box_truck"))
	var bay := VehicleCargo.bay(d)
	var rect: Dictionary = bay.get("rect", {})
	var vrec := PlacedPropService.get_prop_record(main, vid)
	var stowed: Array = []
	var inside := 0
	for c in crates:
		var crec := PlacedPropService.get_prop_record(main, str(c))
		if str(crec.get("stowed_in", "")) != vid:
			continue
		stowed.append(str(c))
		var sl: Array = crec["stow_local"]
		if float(sl[0]) >= float(rect["x0"]) - 0.01 and float(sl[0]) <= float(rect["x1"]) + 0.01 \
				and float(sl[2]) >= float(rect["z0"]) - 0.01 and float(sl[2]) <= float(rect["z1"]) + 0.01:
			inside += 1
	_ok(stowed.size() > 0 and inside == stowed.size(), "%d crates stowed, all inside the bay's floor" % stowed.size())
	var project := _unload_project(bridge, vid)
	_ok(not project.is_empty(), "a crew unload project is queued at its door")
	# Drive it 30 m and turn a quarter: the crates ride along.
	var vprop := PlacedPropRuntime.find_by_prop_id(main, vid)
	var veh: Node = vprop.get_node_or_null("PlacedVehicle") if vprop != null else null
	if veh != null:
		player.call("request_mount", veh)
		await _frames(tree, 10)
		var start := Vector2(vprop.global_position.x, vprop.global_position.z)
		var s := 0.0
		while s < 30.0:
			s = minf(s + 0.15, 30.0)
			var yaw := clampf((s - 10.0) / 20.0, 0.0, 1.0) * PI * 0.5
			_drive(main, player, start + Vector2(0.0, -s), yaw)
			await tree.process_frame
		await _frames(tree, 4)
		var worst := 0.0
		var vyaw := ((vprop.get_node("ModelRoot")) as Node3D).rotation.y
		var vo := Vector2(vprop.global_position.x, vprop.global_position.z)
		for c2 in stowed:
			var node := PlacedPropRuntime.find_by_prop_id(main, str(c2)) as Node3D
			var crec2 := PlacedPropService.get_prop_record(main, str(c2))
			var sl2: Array = crec2["stow_local"]
			var want := VehicleTow.world_xz(Vector3(float(sl2[0]), 0.0, float(sl2[2])), vo, vyaw)
			if node != null:
				worst = maxf(worst, Vector2(node.global_position.x, node.global_position.z).distance_to(want))
		_ok(worst < 0.1, "driven and turned, every crate rides at its place (worst %.3f m)" % worst)
		player.call("_dismount_vehicle")
		await _frames(tree, 6)
		var moved := 0
		for c3 in stowed:
			var r3 := PlacedPropService.get_prop_record(main, str(c3))
			if Vector2(float(r3.get("x", 0.0)), float(r3.get("z", 0.0))).distance_to(start) > 5.0:
				moved += 1
		_ok(moved == stowed.size(), "their records followed the truck (%d of %d)" % [moved, stowed.size()])
	await RenderingServer.frame_post_draw
	main.get_viewport().get_texture().get_image().save_png("%s/truck_loaded.png" % dir)
	# Let the crew work: they fetch the crates from the truck where it now is.
	var proj2 := _unload_project(bridge, vid)
	var t := 0.0
	var unloaded := 0
	main.set("time_scale", 0.2)
	var crew_iid := ""
	for e in bridge.call("all_site_projects"):
		if str(((e as Dictionary)["project"] as Dictionary).get("id", "")) == str(proj2.get("id", "")):
			crew_iid = str((e as Dictionary)["iid"])
	_ok(not crew_iid.is_empty() and bool(bridge.call("is_all_hands", crew_iid)),
		"the unloading camp is pinned all hands")
	while t < 300.0 and unloaded < stowed.size():
		await tree.create_timer(1.0).timeout
		t += 1.0
		unloaded = 0
		for c4 in stowed:
			var r4 := PlacedPropService.get_prop_record(main, str(c4))
			if str(r4.get("stowed_in", "")).is_empty() and absf(float(r4.get("y_offset", 0.0))) < 0.01:
				unloaded += 1
	_ok(unloaded == stowed.size(), "the crew carried every crate out of its door (%d of %d in %.0f s)" % [unloaded, stowed.size(), t])
	# The project finishes (its gate row), and the camp goes back to its day.
	var t2 := 0.0
	while t2 < 60.0 and not crew_iid.is_empty() and bool(bridge.call("is_all_hands", crew_iid)):
		await tree.create_timer(1.0).timeout
		t2 += 1.0
	main.set("time_scale", 0.001)
	_ok(not crew_iid.is_empty() and not bool(bridge.call("is_all_hands", crew_iid)),
		"the camp is released when the unload is done")
	print("vehiclecargo: project %s" % str(proj2))
	for c5 in crates:
		loader.call("delete_prop_by_id", str(c5))
	loader.call("delete_prop_by_id", vid)
	print("vehiclecargo: %d failure(s)" % _fails.size())
	return {"ok": _fails.is_empty(), "fails": _fails}


func _drive(main: Node, player: CharacterBody3D, xz: Vector2, yaw: float) -> void:
	var gy := TerrainSurfaceQuery.ground_height_at(main, xz.x, xz.y)
	player.global_position = Vector3(xz.x, gy if not is_nan(gy) else player.global_position.y, xz.y)
	player.velocity = Vector3.ZERO
	player.rotation.y = yaw


## The delivery-unload project for this vehicle on any board, {} if none.
func _unload_project(bridge: Variant, vid: String) -> Dictionary:
	if bridge == null:
		return {}
	for e in bridge.call("all_site_projects"):
		var pd: Dictionary = (e as Dictionary)["project"]
		if str(pd.get("kind", "")) == "delivery_unload" and str(pd.get("prop_id", "")) == vid:
			return {"id": str(pd.get("id", "")), "label": str(pd.get("label", ""))}
	return {}
