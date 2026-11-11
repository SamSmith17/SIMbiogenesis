extends RefCounted

## Structure earthworks on a real world (sandbox, REAL input for the walk):
##   tools\harness.ps1 -World w6ad922917357 -RunScript res://tools/checks/earthworks_check.gd -Label earthworks -Timeout 900
## 1. A sunken pit (a firepit prop asking for an opening with a slab, walls
##    on three sides, a daylight cut across the front and an entry ramp):
##    the ground query reads the floor inside, the drawn terrain is cut out
##    (the mask is on the material), the terrain collider under the room is
##    pulled down, the collar carries the ground beside the walls, and
##    holding Forward walks the player from the ground, down the ramp and
##    onto the pit floor.
## 2. A buried cargo container (sunk, bermed to its roof on three sides): the
##    container stands at grade minus its sink, the berms reach its roof.
## 3. Moving the pit moves its earthworks and gives the old spot its ground
##    back; deleting both leaves no structure tiles and no holes.
## Shots under screenshots\<label>\.

var _fails: Array = []
var _dir := ""


func _ok(cond: bool, what: String) -> void:
	print("earthworks %s: %s" % ["PASS" if cond else "FAIL", what])
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
	for _i in 90:
		await tree.process_frame
		if ew.rebuild_count > before:
			break
	await _frames(tree, 20)


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	_dir = "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(_dir)
	main.set("day_time", 9.5)
	main.set("time_scale", 0.0)
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	var player := main.get_node_or_null("Player") as CharacterBody3D
	_ok(loader != null and player != null, "a TerrainLoader world with a player")
	if loader == null or player == null:
		return {"ok": false, "fails": _fails}
	if bool(player.get("is_riding")) and player.has_method("_dismount_vehicle"):
		player.call("_dismount_vehicle")
		await _frames(tree, 30)
	# A world saved in the settlement view or festival mode: back to first person.
	if main.has_method("settlement_view_open") and bool(main.call("settlement_view_open")):
		(main.get("settlement_view") as Node).call("close")
		await _frames(tree, 20)
	var ew: EarthworksRuntime = loader.call("structure_earthworks")
	var p0 := player.global_position
	var at := _clear_spot(main, Vector2(p0.x, p0.z))
	print("earthworks: test site at %s (player at %s)" % [at, Vector2(p0.x, p0.z)])

	# --- 1. the pit ----------------------------------------------------------
	# The firepit sits on the pit floor: the model's y0 is sunk 1.6 m.
	var pit_spec := {"rect": [-4.0, -3.0, 4.0, 3.0], "sink_m": 1.6, "floor_y": 0.0, "roof_y": 1.8,
		"slab": true, "walls": true, "wall_sides": ["-z", "+x", "-x"]}
	pit_spec["cuts"] = [StructureEarthworks.daylight_cut(pit_spec, "+z", 3.0, 1.5)]
	pit_spec["ramps"] = [{"a": [2.0, 12.0], "b": [2.0, 5.5], "ya": 0.0, "yb": 0.0, "w": 2.0, "run": 1.5}]
	var placed := PlacedPropService.place_model_at_xz(main, FirepitBuilder.MODEL_ID, at.x, at.y)
	var pit := str(placed.get("prop_id", ""))
	_ok(not pit.is_empty(), "the pit's prop placed")
	PlacedPropService.update_prop_record(main, pit, {"yaw": 0.0, StructureEarthworks.KEY: pit_spec}, true)
	await _settle(tree, ew)
	print("earthworks: ", ew.debug_line())
	ew.ground_rev += 1
	await _settle(tree, ew)
	print("earthworks: a second rebuild (nothing moved) ", ew.debug_line())
	_ok(ew.holes.size() >= 1, "the pit is an opening (%d)" % ew.holes.size())
	_ok(ew.mask_count() >= 1, "the opening's mask is on the terrain material")
	var grade := float(loader.call("ground_without_structures", at.x, at.y))
	var floor_y := grade - 1.6
	_ok(absf(float(loader.call("ground_height_at", at.x, at.y)) - floor_y) < 0.02,
		"the ground inside reads the pit floor (%.2f vs %.2f)" % [
			float(loader.call("ground_height_at", at.x, at.y)), floor_y])
	_ok(absf(float(loader.call("surface_height_at", at.x, at.y + 4.5)) - floor_y) < 0.35,
		"the daylight cut is dug to the floor")
	_ok(absf(float(loader.call("surface_height_at", at.x, at.y + 12.0)) - grade) < 0.5,
		"the ramp starts at the ground")
	var space := (main as Node3D).get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(Vector3(at.x - 2.5, floor_y + 1.0, at.y - 1.5),
		Vector3(at.x - 2.5, floor_y - 6.0, at.y - 1.5))
	var hit := space.intersect_ray(q)
	_ok(not hit.is_empty() and absf((hit["position"] as Vector3).y - floor_y) < 0.1,
		"the first thing under the room is the floor slab (%s, %s)" % [str(hit.get("position", "nothing")),
			(hit["collider"] as Node).get_path() if not hit.is_empty() else ""])
	var hf := (main.get_node_or_null("Terrain") as Node3D).get_node_or_null("HeightField")
	var terrain_above := false
	var hq := PhysicsRayQueryParameters3D.create(Vector3(at.x + 1.0, grade + 3.0, at.y - 1.0),
		Vector3(at.x + 1.0, floor_y - 0.5, at.y - 1.0))
	hq.exclude = _rids_of(ew)
	var hh := space.intersect_ray(hq)
	if not hh.is_empty() and hf != null and (hh["collider"] as Node).get_parent() == hf:
		terrain_above = true
	_ok(not terrain_above, "no terrain collider stands in the room")
	var side := Vector2(at.x - 4.0 - 0.6, at.y)
	var cq := PhysicsRayQueryParameters3D.create(Vector3(side.x, grade + 3.0, side.y),
		Vector3(side.x, grade - 4.0, side.y))
	var ch := space.intersect_ray(cq)
	var side_y := float(loader.call("surface_height_at", side.x, side.y))
	_ok(not ch.is_empty() and absf((ch["position"] as Vector3).y - side_y) < 0.2,
		"beside the wall you stand on the ground (%s vs %.2f)" % [str(ch.get("position", "nothing")), side_y])

	# Walk in: from the ground up the ramp, Forward held, down onto the floor.
	if player.has_method("_apply_camera_mode"):
		player.call("_apply_camera_mode", false)
	var start := Vector3(at.x + 2.0, grade + 0.3, at.y + 14.0)
	player.global_position = start
	player.velocity = Vector3.ZERO
	_face(player, Vector3(at.x, floor_y + 1.0, at.y))
	await _frames(tree, 20)
	await _shot(main, "1_pit_from_the_ground")
	Input.action_press("move_forward")
	var reached := false
	for i in 420:
		await tree.physics_frame
		var pp := player.global_position
		_face(player, Vector3(at.x + 2.0, pp.y + 1.5, at.y - 10.0))
		if absf(pp.x - at.x) < 3.5 and pp.z < at.y + 2.0 and absf(pp.y - floor_y) < 0.3:
			reached = true
			break
	Input.action_release("move_forward")
	await _frames(tree, 20)
	var pp2 := player.global_position
	_ok(reached, "Forward walks the player down the ramp onto the pit floor (at %.2f, %.2f, %.2f; floor %.2f)" % [
		pp2.x - at.x, pp2.y, pp2.z - at.y, floor_y])
	_face(player, Vector3(at.x, floor_y + 1.4, at.y - 6.0))
	await _frames(tree, 10)
	await _shot(main, "2_pit_inside")

	# --- 2. a buried container ----------------------------------------------
	var cat := Vector2(at.x + 22.0, at.y)
	var cplaced := PlacedPropService.place_model_at_xz(main, CargoContainerBuilder.MODEL_ID, cat.x, cat.y)
	var cid := str(cplaced.get("prop_id", ""))
	_ok(not cid.is_empty(), "a container placed")
	PlacedPropService.update_prop_record(main, cid, {"yaw": 0.0}, true)
	await _frames(tree, 10)
	var cnode := PlacedPropRuntime.find_by_prop_id(main, cid)
	var bb := cnode.get_world_pick_aabb() if cnode != null else AABB()
	var o := Vector3(cat.x, 0.0, cat.y)
	var lx0 := bb.position.x - o.x
	var lx1 := bb.end.x - o.x
	var lz0 := bb.position.z - o.z
	var lz1 := bb.end.z - o.z
	var hgt := bb.size.y
	var sink := hgt - 1.4
	var cspec := {"rect": [lx0 - 0.05, lz0 - 0.05, lx1 + 0.05, lz1 + 0.05], "sink_m": sink,
		"floor_y": 0.0, "roof_y": hgt,
		"berm": {"-z": {"h": -1.0, "run": 1.5, "crest": 0.8}, "+x": {"h": -1.0, "run": 1.5, "crest": 0.8},
			"-x": {"h": -1.0, "run": 1.5, "crest": 0.8}}}
	cspec["cuts"] = [StructureEarthworks.daylight_cut(cspec, "+z", 3.5, 1.5)]
	PlacedPropService.update_prop_record(main, cid, {StructureEarthworks.KEY: cspec}, true)
	await _settle(tree, ew)
	var cgrade := float(loader.call("ground_without_structures", cat.x, cat.y))
	cnode = PlacedPropRuntime.find_by_prop_id(main, cid)
	_ok(cnode != null and absf(cnode.global_position.y - (cgrade - sink)) < 0.05,
		"the container stands at grade minus its sink (%.2f vs %.2f)" % [
			cnode.global_position.y if cnode != null else NAN, cgrade - sink])
	var back := Vector2(cat.x, cat.y + lz0 - 0.8)
	var back_y := float(loader.call("surface_height_at", back.x, back.y))
	_ok(absf(back_y - (cgrade - sink + hgt)) < 0.35,
		"the back berm reaches the roof (%.2f vs %.2f; rect %s, h %.2f)" % [back_y, cgrade - sink + hgt,
			str(cspec["rect"]), hgt])
	player.global_position = Vector3(cat.x + 6.0, cgrade + 4.0, cat.y + 12.0)
	_face(player, Vector3(cat.x, cgrade, cat.y))
	await _frames(tree, 30)
	await _shot(main, "3_buried_container")

	# --- 3. move, then delete ------------------------------------------------
	PlacedPropService.update_prop_record(main, pit, {"x": at.x - 20.0}, true)
	await _settle(tree, ew)
	var back_to := float(loader.call("ground_height_at", at.x, at.y))
	_ok(absf(back_to - grade) < 0.05, "the old spot has its ground back (%.2f vs %.2f)" % [back_to, grade])
	var moved_floor := float(loader.call("ground_height_at", at.x - 20.0, at.y))
	_ok(moved_floor < float(loader.call("ground_without_structures", at.x - 20.0, at.y)) - 1.0,
		"the opening moved with the pit")
	loader.call("delete_prop_by_id", pit)
	loader.call("delete_prop_by_id", cid)
	await _settle(tree, ew)
	_ok(ew.holes.is_empty(), "no openings once deleted")
	var layer: TerrainEditTiles = loader.call("structure_tile_layer")
	_ok(layer.is_empty(), "no structure tiles once deleted")
	player.global_position = p0
	print("earthworks: %d failure(s)" % _fails.size())
	return {"ok": _fails.is_empty(), "fails": _fails}


## Open ground near the player: no placed prop within 30 m of the pit or of
## the container 22 m east of it, nor of the 20 m move.
func _clear_spot(main: Node, from: Vector2) -> Vector2:
	var recs: Array = []
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	if loader != null and loader.has_method("placed_prop_records"):
		recs = loader.call("placed_prop_records")
	for ring in range(2, 14):
		for k in 16:
			var a := TAU * float(k) / 16.0
			var c := from + Vector2(cos(a), sin(a)) * (float(ring) * 25.0)
			var ok := true
			for r in recs:
				var q := Vector2(float(r.get("x", 0.0)), float(r.get("z", 0.0)))
				for off in [Vector2.ZERO, Vector2(22, 0), Vector2(-20, 0)]:
					if q.distance_to(c + off) < 30.0:
						ok = false
			if ok:
				return c
	return from + Vector2(6.0, -22.0)


func _rids_of(ew: Node) -> Array[RID]:
	var out: Array[RID] = []
	for c in ew.get_children():
		if c is CollisionObject3D:
			out.append((c as CollisionObject3D).get_rid())
	return out
