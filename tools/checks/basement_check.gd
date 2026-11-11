extends RefCounted

## A house with a basement on a real world (sandbox, REAL input for the walk):
##   tools\harness.ps1 -World w6ad922917357 -RunScript res://tools/checks/basement_check.gd -Label basement -Timeout 900
## Places a parametric cottage with a 2.4 m walkout basement through the
## Building Builder's own placement prep: the ground inside reads the
## basement floor, the walkout side is dug down to it with a ramp up, and
## holding Forward walks the player down the ramp, through the basement door
## and in under the house. Then an areaway basement (steps in a narrow trench).
## Shots under screenshots\<label>\. Removes what it placed.

var _fails: Array = []
var _dir := ""


func _ok(cond: bool, what: String) -> void:
	print("basement %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


func _shot(main: Node, name: String) -> void:
	await RenderingServer.frame_post_draw
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [_dir, name])


func _face(player: CharacterBody3D, at: Vector3) -> void:
	var cam := player.get_viewport().get_camera_3d()
	var eye := cam.global_position if cam != null else player.global_position + Vector3(0, 1.7, 0)
	var dir := at - eye
	player.rotation.y = atan2(-dir.x, -dir.z)
	if cam != null:
		cam.rotation.x = atan2(dir.y, Vector2(dir.x, dir.z).length())


func _settle(tree: SceneTree, ew: EarthworksRuntime) -> void:
	var before := ew.rebuild_count
	for _i in 120:
		await tree.process_frame
		if ew.rebuild_count > before:
			break
	await _frames(tree, 30)


func _walk(tree: SceneTree, player: CharacterBody3D, start: Vector3, target: Vector3, done: Callable) -> bool:
	player.global_position = start
	player.velocity = Vector3.ZERO
	_face(player, target)
	await _frames(tree, 15)
	Input.action_press("move_forward")
	var ok := false
	for i in 600:
		await tree.physics_frame
		var pp := player.global_position
		_face(player, Vector3(target.x, pp.y + 1.5, target.z))
		if bool(done.call(pp)):
			ok = true
			break
	Input.action_release("move_forward")
	await _frames(tree, 15)
	return ok


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	_dir = "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(_dir)
	main.set("day_time", 10.0)
	main.set("time_scale", 0.0)
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	var player := main.get_node_or_null("Player") as CharacterBody3D
	_ok(loader != null and player != null, "a TerrainLoader world with a player")
	if loader == null or player == null:
		return {"ok": false, "fails": _fails}
	if main.has_method("settlement_view_open") and bool(main.call("settlement_view_open")):
		(main.get("settlement_view") as Node).call("close")
		await _frames(tree, 20)
	if bool(player.get("is_riding")) and player.has_method("_dismount_vehicle"):
		player.call("_dismount_vehicle")
		await _frames(tree, 30)
	if player.has_method("_apply_camera_mode"):
		player.call("_apply_camera_mode", false)
	var ew: EarthworksRuntime = loader.call("structure_earthworks")
	var p0 := player.global_position
	var at := _clear_spot(main, Vector2(p0.x, p0.z))

	# --- walkout ----------------------------------------------------------------
	var spec := {"width_m": 8.0, "depth_m": 6.0, "height_m": 3.2,
		"basement": {"depth_m": 2.4, "entry": "walkout", "edge": 0, "door_at": 0.3}}
	var pid := PlacedPropService.place_prepped_at(main, BuildingFeatures.MODEL_ID,
		{"record_extra": {"building_spec": spec, "collision_enabled": true}}, at.x, at.y, 0.0)
	_ok(not pid.is_empty(), "a cottage with a basement placed")
	await _frames(tree, 10)
	await _settle(tree, ew)
	var grade := float(loader.call("ground_without_structures", at.x, at.y))
	var floor_y := grade - 2.4
	_ok(ew.holes.size() >= 1, "the basement is an opening")
	_ok(absf(float(loader.call("ground_height_at", at.x + 1.0, at.y)) - floor_y) < 0.05,
		"the ground inside reads the basement floor")
	var dp := BasementBuilder.door_point(BuildingFeatures.footprint_of(spec), BasementBuilder.resolve(spec["basement"]))
	var door := Vector2(at.x + dp.x, at.y + dp.y)
	_ok(absf(float(loader.call("surface_height_at", door.x, door.y - 2.0)) - floor_y) < 0.35,
		"the walkout side is dug down to the floor")
	player.global_position = Vector3(at.x - 9.0, grade + 6.0, at.y - 16.0)
	_face(player, Vector3(at.x, floor_y + 1.0, at.y - 3.0))
	await _frames(tree, 30)
	await _shot(main, "1_walkout_from_above")
	var ramp_top_z := door.y - 4.0 - 2.4 * 3.0 - 1.2
	var inside := await _walk(tree, player, Vector3(door.x, grade + 0.4, ramp_top_z),
		Vector3(door.x, floor_y + 1.0, at.y + 2.0),
		func(pp: Vector3) -> bool: return pp.z > at.y - 2.2 and absf(pp.y - floor_y) < 0.3)
	var pp2 := player.global_position
	_ok(inside, "Forward walks down the ramp and through the door into the basement (at %.2f, %.2f, %.2f; floor %.2f)" % [
		pp2.x - at.x, pp2.y, pp2.z - at.y, floor_y])
	_face(player, Vector3(at.x + 3.0, floor_y + 1.2, at.y + 2.5))
	await _frames(tree, 10)
	await _shot(main, "2_in_the_basement")
	loader.call("delete_prop_by_id", pid)
	await _settle(tree, ew)

	# --- areaway ----------------------------------------------------------------
	var spec2 := {"width_m": 7.0, "depth_m": 6.0, "height_m": 3.0,
		"basement": {"depth_m": 2.2, "entry": "areaway", "edge": 1, "door_at": 0.5}}
	var pid2 := PlacedPropService.place_prepped_at(main, BuildingFeatures.MODEL_ID,
		{"record_extra": {"building_spec": spec2, "collision_enabled": true}}, at.x, at.y, 0.0)
	await _frames(tree, 10)
	await _settle(tree, ew)
	var rec2 := PlacedPropService.get_prop_record(main, pid2)
	var es2 := StructureEarthworks.resolve(StructureEarthworks.spec_for_record(rec2))
	_ok((es2["cuts"] as Array).size() == 1 and str(es2["simple"]["daylight"]) == "+x",
		"an areaway on the right wall")
	player.global_position = Vector3(at.x + 9.0, grade + 4.0, at.y - 7.0)
	_face(player, Vector3(at.x + 3.5, grade - 2.0, at.y))
	await _frames(tree, 30)
	await _shot(main, "3_areaway")
	loader.call("delete_prop_by_id", pid2)
	await _settle(tree, ew)
	_ok(ew.holes.is_empty(), "nothing left open")
	player.global_position = p0
	print("basement: %d failure(s)" % _fails.size())
	return {"ok": _fails.is_empty(), "fails": _fails}


func _clear_spot(main: Node, from: Vector2) -> Vector2:
	var recs: Array = []
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	if loader != null and loader.has_method("placed_prop_records"):
		recs = loader.call("placed_prop_records")
	for ring in range(2, 16):
		for k in 16:
			var a := TAU * float(k) / 16.0
			var c := from + Vector2(cos(a), sin(a)) * (float(ring) * 25.0)
			var ok := true
			for r in recs:
				if Vector2(float(r.get("x", 0.0)), float(r.get("z", 0.0))).distance_to(c) < 35.0:
					ok = false
			if ok:
				return c
	return from + Vector2(0.0, -50.0)
