extends RefCounted

## The Earthship designer on a real world (sandbox, REAL input for the walk):
##   tools\harness.ps1 -World w6ad922917357 -RunScript res://tools/checks/earthship_check.gd -Label earthship -Timeout 1200
## Opens the designer (UiAudit, shot), places the Global Model on open ground
## through the designer's own placement prep, and checks the record carries
## its design's earthworks (the opening over the rooms, berms, the front cut
## and the ramp at the door), that the ground inside reads the room floor,
## and that holding Forward walks the player from the ground down the ramp,
## through the door, across the greenhouse and into a room. Apply with four
## rooms re-solves the earthworks. Then the detailed Earthship GLB (when the
## art is installed): placed, its catalog earthworks open the ground over it.
## Shots under screenshots\<label>\. Removes what it placed.

var _fails: Array = []
var _dir := ""


func _ok(cond: bool, what: String) -> void:
	print("earthship %s: %s" % ["PASS" if cond else "FAIL", what])
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
	var ew: EarthworksRuntime = loader.call("structure_earthworks")

	# --- the designer ---------------------------------------------------------
	var modal: Node = load("res://scenes/ui/earthshiplab_modal.gd").call("open", tree, {})
	await _frames(tree, 40)
	_ok(modal != null and bool(modal.call("is_open")), "the designer opens")
	var audit := UiAudit.run(main.get_viewport())
	print("earthship: ui audit — %s" % UiAudit.summary_line(audit))
	_ok(int(audit.get("errors", 0)) == 0, "the designer passes the UI audit")
	await _shot(main, "0_designer")
	var spec: Dictionary = modal.call("current_spec")
	modal.call("close")
	await _frames(tree, 10)

	# --- placed ------------------------------------------------------------------
	var p0 := player.global_position
	var at := _clear_spot(main, Vector2(p0.x, p0.z))
	var pid := PlacedPropService.place_prepped_at(main, EarthshipBuilder.MODEL_ID,
		{"record_extra": {EarthshipSpec.KEY: EarthshipSpec.to_json_safe(spec), "collision_enabled": true}},
		at.x, at.y, 0.0)
	_ok(not pid.is_empty(), "placed through the designer's prep")
	await _frames(tree, 10)
	await _settle(tree, ew)
	var rec := PlacedPropService.get_prop_record(main, pid)
	_ok(StructureEarthworks.is_on(rec), "the record carries the design's earthworks")
	_ok(bool(rec.get("walk_in", false)), "walk-in (the nav grid keeps it open)")
	var d := EarthshipDesign.solve(spec)
	var fr: Dictionary = d["frame"]
	var grade := float(loader.call("ground_without_structures", at.x, at.y))
	var floor_y := grade + float(fr["yf"])
	var room: Dictionary = d["rooms"][0]
	var room_mid := Vector2(at.x + (float(room["x0"]) + float(room["x1"])) * 0.5, at.y - 2.0)
	_ok(absf(float(loader.call("ground_height_at", room_mid.x, room_mid.y)) - floor_y) < 0.05,
		"the ground in a room reads the room floor")
	var back := Vector2(at.x, at.y + float(fr["z_back"]) - 0.8)
	var back_y := float(loader.call("surface_height_at", back.x, back.y))
	_ok(back_y > grade + float(fr["roof"]) - 0.6, "the back berm rises to the roof (%.2f, roof at %.2f)" % [
		back_y - grade, float(fr["roof"])])
	var front := Vector2(at.x + float(d["entry_x"]), at.y + float(fr["z_front"]) + 1.0)
	_ok(absf(float(loader.call("surface_height_at", front.x, front.y)) - floor_y) < 0.35,
		"the front cut is dug to the floor")
	player.global_position = Vector3(at.x + 14.0, grade + 9.0, at.y + 22.0)
	_face(player, Vector3(at.x, grade, at.y - 2.0))
	await _frames(tree, 30)
	await _shot(main, "1_earthship_above")

	# Walk in: from the ground at the top of the ramp, Forward held.
	if player.has_method("_apply_camera_mode"):
		player.call("_apply_camera_mode", false)
	var ex := at.x + float(d["entry_x"])
	var ramp_top := float(fr["z_front"]) + float(spec["front_cut"]) + float(d["earthworks_simple"]["ramp_len"]) + 1.5
	player.global_position = Vector3(ex, grade + 0.4, at.y + ramp_top)
	player.velocity = Vector3.ZERO
	_face(player, Vector3(ex, floor_y + 1.4, at.y))
	await _frames(tree, 20)
	await _shot(main, "2_front_from_the_ramp")
	Input.action_press("move_forward")
	var in_green := false
	var in_room := false
	for i in 600:
		await tree.physics_frame
		var pp := player.global_position
		_face(player, Vector3(ex, pp.y + 1.5, at.y - 20.0))
		var lz := pp.z - at.y
		if lz < float(fr["door_z"]) - 0.6 and absf(pp.y - floor_y) < 0.3:
			in_green = true
		if lz < -1.0 and absf(pp.y - floor_y) < 0.3:
			in_room = true
			break
	Input.action_release("move_forward")
	await _frames(tree, 20)
	var pp2 := player.global_position
	_ok(in_green, "Forward walks down the ramp and through the door into the greenhouse (at %.2f, %.2f, %.2f; floor %.2f)" % [
		pp2.x - at.x, pp2.y, pp2.z - at.y, floor_y])
	_ok(in_room, "and on into a room")
	_face(player, Vector3(ex, floor_y + 1.6, at.y + 6.0))
	await _frames(tree, 10)
	await _shot(main, "3_room_looking_out")
	player.global_position = Vector3(ex + 3.0, floor_y + 0.1, at.y + float(fr["door_z"]) - 1.2)
	_face(player, Vector3(ex - 6.0, floor_y + 1.3, at.y + 0.5))
	await _frames(tree, 30)
	await _shot(main, "4_greenhouse")

	# People find their way in: a nav grid over it with the opening's walls and
	# door (what the population bridge collects), a path from the ramp top
	# into a room that passes the door.
	var grid := NpcNavGrid.new()
	grid.configure_region(Vector2(at.x, at.y), 55.0)
	grid.begin_bake(func(x: float, z: float) -> float: return float(loader.call("ground_height_at", x, z)),
		loader.call("earthworks_nav_entries"), "earthship_check")
	var guard := 0
	while not grid.bake_step(4000) and guard < 2000:
		guard += 1
	var nq := NpcNavQuery.new()
	nq.setup(grid)
	var p_from := Vector2(ex, at.y + ramp_top)
	var far_room: Dictionary = d["rooms"][(d["rooms"] as Array).size() - 1]
	var p_room := Vector2(at.x + (float(far_room["x0"]) + float(far_room["x1"])) * 0.5, at.y - 2.0)
	var path := nq.find_path(p_from, p_room)
	var door_w := StructureEarthworks.to_world(Vector2(float(d["entry_x"]), float(fr["z_front"])),
		Vector2(at.x, at.y), 0.0)
	var near_door := false
	var prev := p_from
	for q in path:
		if Geometry2D.get_closest_point_to_segment(door_w, prev, q).distance_to(door_w) < 1.2:
			near_door = true
		prev = q
	_ok(path.size() > 0 and path[path.size() - 1].distance_to(p_room) < 1.5 and near_door,
		"people path from the ramp top through the door into a room (%d points, by the door %s)" % [path.size(), str(near_door)])
	var p_side := Vector2(at.x + float(fr["x1"]) + 6.0, at.y - 2.0)
	var side_path := nq.find_path(p_side, p_room)
	var through_wall := false
	if side_path.size() > 1:
		through_wall = side_path[0].distance_to(p_room) + 1.0 > NpcNavQuery.path_length(side_path, p_side)
	_ok(not through_wall, "and never through the bermed end wall")

	# Apply four rooms: the earthworks follow.
	var spec4 := spec.duplicate(true)
	spec4["modules"] = 4
	PlacedPropService.update_prop_record(main, pid, {EarthshipSpec.KEY: EarthshipSpec.to_json_safe(spec4)}, true)
	PlacedPropService.sync_earthship(main, pid)
	await _settle(tree, ew)
	var rect4: Array = PlacedPropService.get_prop_record(main, pid)[StructureEarthworks.KEY]["rect"]
	var d4 := EarthshipDesign.solve(spec4)
	_ok(absf((float(rect4[2]) - float(rect4[0])) - float(d4["stats"]["length_m"])) < 0.01,
		"Apply with four rooms widens the opening")

	# --- the detailed GLB, when its art is installed ----------------------------
	if not ModelCatalog.find("earthship_detail").is_empty() and ModelCatalog.is_installed(ModelCatalog.find("earthship_detail")):
		var at2 := at + Vector2(0.0, 120.0)
		var placed := PlacedPropService.place_model_at_xz(main, "earthship_detail", at2.x, at2.y)
		var gid := str(placed.get("prop_id", ""))
		await _frames(tree, 30)
		await _settle(tree, ew)
		var grec := PlacedPropService.get_prop_record(main, gid)
		_ok(StructureEarthworks.is_on(grec), "the detailed Earthship opens the ground over itself")
		player.global_position = Vector3(at2.x + 30.0, grade + 18.0, at2.y + 60.0)
		_face(player, Vector3(at2.x, grade, at2.y + 30.0))
		await _frames(tree, 40)
		await _shot(main, "5_detail_glb")
		loader.call("delete_prop_by_id", gid)
	loader.call("delete_prop_by_id", pid)
	await _settle(tree, ew)
	_ok(ew.holes.is_empty(), "nothing left open once deleted")
	player.global_position = p0
	print("earthship: %d failure(s)" % _fails.size())
	return {"ok": _fails.is_empty(), "fails": _fails}


## Open ground: no placed prop within 45 m of the site or of the GLB spot.
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
				if q.distance_to(c) < 45.0 or q.distance_to(c + Vector2(0, 120)) < 90.0:
					ok = false
			if ok:
				return c
	return from + Vector2(0.0, -60.0)
