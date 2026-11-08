extends RefCounted

## Walking into a living vehicle through its doors (sandbox, REAL input):
##   tools\harness.ps1 -World burningman -RunScript res://tools/checks/vehicle_walkin_check.gd -Label vehicle_walkin -Timeout 900
## For a shuttle bus, a camper van and a school bus placed on the playa: the
## runtime (VehicleWalkIn) and its door leaves exist; a shut door stops the
## player's body at the doorway; aimed at from outside, the crosshair offers
## "Open …" and the Interact key opens it (the leaf moves, the blocker goes);
## holding Forward walks the player up the ramp and INTO the room (inside the
## walls, standing on the floor, head under the roof); inside, the room has
## standing room along its aisle; Interact away from a door still drives, and
## driving shuts the doors. Shots outside, in the doorway and inside. Removes
## what it placed.

var _fails: Array = []
var _dir := ""


func _ok(cond: bool, what: String) -> void:
	print("vehiclewalkin %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	_dir = "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(_dir)
	main.set("day_time", 10.0)   # the curb (east) side in the sun
	main.set("time_scale", 0.0)
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	var player := main.get_node_or_null("Player") as CharacterBody3D
	_ok(loader != null and player != null, "a map with a player")
	if loader == null or player == null:
		return {"ok": false, "fails": _fails}
	# The world may have been saved with the player riding something.
	if bool(player.get("is_riding")) and player.has_method("_dismount_vehicle"):
		player.call("_dismount_vehicle")
		await _frames(tree, 30)
	if player.has_method("_apply_camera_mode"):
		player.call("_apply_camera_mode", false)
	var p0 := player.global_position
	var placed: Array = []
	var k := 0
	for id in ["shuttle_bus", "van", "school_bus"]:
		var spec := VehicleSpec.to_json_safe(VehiclePresets.builtin(id))
		var vx := p0.x + 14.0 + 9.0 * float(k)
		var vz := p0.z - 6.0
		k += 1
		var vid := PlacedPropService.place_prepped_at(main, VehicleBuilder.MODEL_ID,
			{"record_extra": {"vehicle_spec": spec, "collision_enabled": true}}, vx, vz, 0.0)
		await _frames(tree, 12)
		_ok(not vid.is_empty(), "%s: placed" % id)
		if vid.is_empty():
			continue
		placed.append(vid)
		await _one(main, tree, player, id, vid)
	for pid in placed:
		loader.call("delete_prop_by_id", str(pid))
	player.global_position = p0
	print("vehiclewalkin: %d failure(s)" % _fails.size())
	return {"ok": _fails.is_empty(), "fails": _fails}


func _one(main: Node, tree: SceneTree, player: CharacterBody3D, id: String, vid: String) -> void:
	var prop := PlacedPropRuntime.find_by_prop_id(main, vid)
	var walk: Node = prop.get_node_or_null("VehicleWalkIn") if prop != null else null
	_ok(walk != null and int(walk.call("door_count")) >= 1, "%s: doors a player can work (%d)" % [id,
		int(walk.call("door_count")) if walk != null else 0])
	if walk == null:
		return
	var d := VehicleDesign.solve(VehiclePresets.builtin(id))
	var gaps := VehicleBuilder.door_gaps(d)
	var door := int((gaps[0] as Dictionary)["door"])
	var g: Dictionary = gaps[0]
	var floor_y := float(g["sill"])
	var out_pt: Vector3 = walk.call("door_point", door, 2.3)
	var sill_pt: Vector3 = walk.call("door_point", door, 0.0)
	var in_pt: Vector3 = walk.call("door_point", door, -0.55)
	# Stand outside on the ground, facing the door.
	var ground := sill_pt.y - floor_y
	player.global_position = Vector3(out_pt.x, ground + 0.08, out_pt.z)
	player.velocity = Vector3.ZERO
	var focus: Node = player.get_node_or_null("InteractionFocus")
	for _try in 90:
		_face(player, Vector3(sill_pt.x, ground + floor_y + 1.2, sill_pt.z))
		await tree.physics_frame
		if _try > 20 and focus != null and bool(focus.call("has_door_focus")):
			break
	await _frames(tree, 4)
	await _shot(main, "%s_1_outside_shut" % id)
	# Shut: a body at sill height cannot pass the doorway.
	var from := Transform3D(Basis.IDENTITY, in_pt + Vector3(0, 0.06, 0))
	var through := (walk.call("door_point", door, 1.0) as Vector3) - in_pt
	_ok(player.test_move(from, through), "%s: a shut door stops a body at the doorway" % id)
	_ok(focus != null and bool(focus.call("has_door_focus")), "%s: the crosshair finds the door from 2 m" % id)
	var crosshair := main.get_node_or_null("UILayer/CrosshairUI")
	var prompt := str(crosshair.call("get_prompt_text")) if crosshair != null and crosshair.has_method("get_prompt_text") else ""
	_ok(prompt.contains("Open"), "%s: the prompt offers to open it (\"%s\")" % [id, prompt])
	# The Interact key opens it — and does not start the engine.
	await HarnessInput.press_action("interact")
	await _frames(tree, 50)
	_ok(bool(walk.call("is_open", door)) and float(walk.call("open_fraction", door)) > 0.98,
		"%s: Interact opened the door" % id)
	_ok(not bool(player.get("is_riding")), "%s: opening a door did not drive off" % id)
	var kc := KinematicCollision3D.new()
	var rootd0 := VehicleBuilder._wheel_root(prop.get_node_or_null("ModelRoot") as Node3D)
	# Somewhere across the doorway a body passes (furniture may stand beside it).
	var stopped := true
	var along := (rootd0.global_transform.basis * (Vector3.BACK if str(g["where"]) == "side" else Vector3.RIGHT)).normalized()
	for off in [0.0, -0.2, 0.2, -0.35, 0.35]:
		if not player.test_move(Transform3D(Basis.IDENTITY, from.origin + along * float(off)), through, kc):
			stopped = false
			break
	var rootd := VehicleBuilder._wheel_root(prop.get_node_or_null("ModelRoot") as Node3D)
	_ok(not stopped, "%s: an open doorway lets a body through%s" % [id, "" if not stopped else " (hit at %s local, normal %s, after %.2f m)" % [
		str((rootd.global_transform.affine_inverse() * kc.get_position()).snapped(Vector3(0.01, 0.01, 0.01))),
		str(kc.get_normal().snapped(Vector3(0.01, 0.01, 0.01))), kc.get_travel().length()]])
	await _shot(main, "%s_2_outside_open" % id)
	# Walk in: Forward held, up the ramp, through the doorway.
	Input.action_press("move_forward")
	var inside := false
	var local := Vector3.ZERO
	var root := VehicleBuilder._wheel_root(prop.get_node_or_null("ModelRoot") as Node3D)
	var hw := float((d["body"] as Dictionary)["w"]) * 0.5
	for i in 240:
		await tree.physics_frame
		local = root.global_transform.affine_inverse() * player.global_position
		var across := absf(local.x) if str(g["where"]) == "side" else local.z
		var lim := hw - 0.45 if str(g["where"]) == "side" else float((d["body"] as Dictionary)["z1"]) - 0.45
		if across < lim and absf(local.y - floor_y) < 0.2:
			inside = true
			break
	Input.action_release("move_forward")
	await _frames(tree, 10)
	_ok(inside, "%s: walking forward goes up the ramp and in (at %.2f, %.2f, %.2f; floor %.2f)" % [id,
		local.x, local.y, local.z, floor_y])
	await _shot(main, "%s_3_doorway" % id)
	# Look down the room from the aisle by the door.
	var house: Dictionary = d["house"]
	var aisle := root.global_transform * Vector3(0.0, floor_y + 0.06, clampf(local.z, float(house["z0"]) + 0.5, float(house["z1"]) - 0.5))
	if not player.test_move(Transform3D(Basis.IDENTITY, aisle), Vector3(0, 0.01, 0)):
		player.global_position = aisle
		player.velocity = Vector3.ZERO
		await _frames(tree, 6)
	var far := root.global_transform * Vector3(0.0, floor_y + 1.4, float(house["z1"]) - 0.3)
	_face(player, far)
	await _frames(tree, 12)
	await _shot(main, "%s_4_inside_rear" % id)
	_face(player, root.global_transform * Vector3(0.0, floor_y + 1.3, float((d["body"] as Dictionary)["z0"]) - 2.0))
	await _frames(tree, 12)
	await _shot(main, "%s_5_inside_front" % id)
	# Standing room where the player stands.
	_ok(not player.test_move(player.global_transform, Vector3(0, 0.02, 0)), "%s: headroom where the player stands" % id)
	# Interact away from a door still drives (when the vehicle drives), and
	# driving shuts the doors.
	var veh: Node = prop.get_node_or_null("PlacedVehicle")
	if veh != null:
		_face(player, player.global_position + Vector3(0, 3.0, 0.2))
		await _frames(tree, 8)
		_ok(not bool(focus.call("has_door_focus")), "%s: no door under the crosshair looking at the ceiling" % id)
		player.call("request_mount", veh)
		await _frames(tree, 40)
		_ok(bool(player.get("is_riding")), "%s: it still drives" % id)
		_ok(not bool(walk.call("is_open", door)), "%s: driving shut the door" % id)
		if player.has_method("_dismount_vehicle"):
			player.call("_dismount_vehicle")
		await _frames(tree, 30)
	if player.has_method("_apply_camera_mode"):
		player.call("_apply_camera_mode", false)


## Turn the player (yaw) and its camera (pitch) to look at a world point.
func _face(player: CharacterBody3D, at: Vector3) -> void:
	var cam := player.get_viewport().get_camera_3d()
	var eye := cam.global_position if cam != null else player.global_position + Vector3(0, 1.7, 0)
	var dir := at - eye
	player.rotation.y = atan2(-dir.x, -dir.z)
	if cam != null:
		cam.rotation.x = atan2(dir.y, Vector2(dir.x, dir.z).length())


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


func _shot(main: Node, name: String) -> void:
	await RenderingServer.frame_post_draw
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [_dir, name])
