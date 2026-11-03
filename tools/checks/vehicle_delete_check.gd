extends RefCounted

## Deleting and duplicating vehicles and their ties (sandbox, transport
## polish Phase 3):
##   tools\harness.ps1 -World walton -RunScript res://tools/checks/vehicle_delete_check.gd -Label vehicle_delete -Timeout 600
## A box truck with the starter camp stowed in it is deleted: every crate is
## set down outside its door, on the ground, collision on, no longer stowed.
## A van towing a trailer is deleted: the trailer is unhitched. A forklift
## holding a crate: deleting the crate empties its forks. A truck carrying a
## delivery, an arrival, a departure and a hitch is duplicated: the copy has
## none of them. Everything placed is removed.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("vehicledelete %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


func _place(main: Node, preset: String, x: float, z: float) -> String:
	return PlacedPropService.place_prepped_at(main, VehicleBuilder.MODEL_ID,
		{"record_extra": {"vehicle_spec": VehicleSpec.to_json_safe(VehiclePresets.builtin(preset)),
			"collision_enabled": true}}, x, z, 0.0)


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	main.set("time_scale", 0.001)
	await _frames(tree, 10)
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	var player := main.get_node_or_null("Player") as Node3D
	_ok(loader != null and player != null, "a map with a player")
	if loader == null or player == null:
		return {"ok": false, "fails": _fails}
	var p0 := Vector2(player.global_position.x, player.global_position.z)
	var cleanup: Array = []
	# 1. A loaded truck deleted: its crates are set down at its door.
	var tid := _place(main, "box_truck", p0.x + 20.0, p0.y)
	await _frames(tree, 6)
	var res: Dictionary = loader.call("deliver_kit_in_vehicle", "starter_camp", tid)
	var crates: Array = res.get("crate_ids", [])
	cleanup.append_array(crates)
	var door := VehicleCargo.door_xz(PlacedPropService.get_prop_record(main, tid))
	_ok(not crates.is_empty() and not door.is_empty(), "a box truck with %d crates in it" % crates.size())
	loader.call("delete_prop_by_id", tid)
	await _frames(tree, 6)
	var down := 0
	var near := 0
	for c in crates:
		var r := PlacedPropService.get_prop_record(main, str(c))
		if r.is_empty():
			continue
		if str(r.get("stowed_in", "")).is_empty() and not r.has("stow_local") \
				and absf(float(r.get("y_offset", 0.0))) < 0.01 and bool(r.get("collision_enabled", false)):
			down += 1
		if Vector2(float(r.get("x", 0.0)), float(r.get("z", 0.0))).distance_to(
				Vector2(float(door["x"]), float(door["z"]))) < 12.0:
			near += 1
	_ok(down == crates.size(), "deleted, every crate is set down on the ground, no longer stowed (%d of %d)" % [down, crates.size()])
	_ok(near == crates.size(), "beside where its door was (%d of %d)" % [near, crates.size()])
	# 2. A van towing a trailer deleted: the trailer is unhitched.
	var vid := _place(main, "van", p0.x - 20.0, p0.y)
	var trid := _place(main, "trailer", p0.x - 20.0, p0.y + 9.0)
	cleanup.append(trid)
	await _frames(tree, 6)
	PlacedPropService.update_prop_record(main, vid, {"towing": trid}, false)
	PlacedPropService.update_prop_record(main, trid, {"hitched_to": vid}, false)
	loader.call("delete_prop_by_id", vid)
	await _frames(tree, 6)
	_ok(str(PlacedPropService.get_prop_record(main, trid).get("hitched_to", "")).is_empty(),
		"the van deleted, its trailer is unhitched")
	# 3. A forklift's load deleted: its forks are empty.
	var placed: Dictionary = PlacedPropService.place_model_at_xz(main, ForkliftBuilder.MODEL_ID,
		p0.x, p0.y + 22.0, {})
	var fid := str(placed.get("prop_id", ""))
	cleanup.append(fid)
	await _frames(tree, 6)
	var load_id := str(crates[0]) if not crates.is_empty() else ""
	PlacedPropService.update_prop_record(main, fid, {"fork_load_id": load_id, "fork_lift_m": 0.5}, false)
	loader.call("delete_prop_by_id", load_id)
	cleanup.erase(load_id)
	await _frames(tree, 6)
	var fr := PlacedPropService.get_prop_record(main, fid)
	_ok(not fid.is_empty() and str(fr.get("fork_load_id", "")).is_empty() and float(fr.get("fork_lift_m", 1.0)) < 0.01,
		"the forklift's load deleted, its forks are empty and down")
	# 4. Duplicating a vehicle copies none of its ties.
	var did := _place(main, "box_truck", p0.x + 20.0, p0.y + 20.0)
	cleanup.append(did)
	await _frames(tree, 6)
	PlacedPropService.update_prop_record(main, did, {"delivery": {"crate_ids": ["x"]},
		"arrival": {"start_h": 1.0}, "departure": {"start_h": 2.0}, "towing": trid,
		"fork_load_id": "y", "camp_id": "c"}, false)
	var copy := PlacedPropService.get_prop_record(main, did).duplicate(true)
	copy["x"] = float(copy.get("x", 0.0)) + 12.0
	var cid := str(loader.call("duplicate_prop_record", copy))
	cleanup.append(cid)
	await _frames(tree, 6)
	var cr := PlacedPropService.get_prop_record(main, cid)
	var clean := not cid.is_empty()
	for k in ["delivery", "arrival", "departure", "towing", "fork_load_id", "camp_id"]:
		if cr.has(k):
			clean = false
	_ok(clean, "a duplicated vehicle carries no delivery, schedule, hitch or load")
	_ok(cr.get("vehicle_spec") is Dictionary, "but it is the same vehicle")
	PlacedPropService.update_prop_record(main, did, {"towing": null}, false)
	for pid in cleanup:
		if not str(pid).is_empty():
			loader.call("delete_prop_by_id", str(pid))
	print("vehicledelete: %d failure(s)" % _fails.size())
	return {"ok": _fails.is_empty(), "fails": _fails}
