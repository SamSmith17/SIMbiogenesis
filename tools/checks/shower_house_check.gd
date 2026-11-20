extends RefCounted
## Shower houses in the world (sandbox, Closed Loop Ten):
##   tools\harness.ps1 -World w6af22bac295d -RunScript res://tools/checks/shower_house_check.gd -Label shower_house -Timeout 1200
##
## The world's shower AREA gets a shower house placed in it (as a restroom
## area gets a toilet bank) and the bridge gives the space its stalls; a
## shower house placed by hand tags itself a shower with one stall per
## shower. Then a day at 600x: never more people in a shower house than its
## stalls, everyone showering stands ON a stall's spot on the deck (seat kind
## stand at the deck's height), and the stall they are in runs its water with
## the curtain drawn. Shots of the house front-on and of a stall in use under
## screenshots\shower_house\. Read-only: a sandbox run.

var _fails: Array = []
var _dir := "user://screenshots/shower_house"


func _ok(cond: bool, what: String, detail: String = "") -> void:
	print("shower-check %s: %s%s" % ["PASS" if cond else "FAIL", what, "" if detail.is_empty() else " (%s)" % detail])
	if not cond:
		_fails.append(what)


## Level ground near `near`, at least 10 m from every placed prop (the
## camp's domes and the toroid are big).
func _open_ground(main: Node, near: Vector2, loader: Node) -> Vector2:
	var recs: Array = loader.call("placed_prop_records") if loader != null and loader.has_method("placed_prop_records") else []
	for r: float in [14.0, 22.0, 30.0, 40.0]:
		for k in 12:
			var a := float(k) * TAU / 12.0
			var p := near + Vector2(cos(a), sin(a)) * r
			var clear := true
			for rec: Dictionary in recs:
				if Vector2(float(rec.get("x", 0.0)), float(rec.get("z", 0.0))).distance_to(p) < 10.0:
					clear = false
					break
			if not clear:
				continue
			var h0 := TerrainSurfaceQuery.ground_height_at(main, p.x, p.y)
			var h1 := TerrainSurfaceQuery.ground_height_at(main, p.x + 3.0, p.y)
			var h2 := TerrainSurfaceQuery.ground_height_at(main, p.x, p.y + 3.0)
			if absf(h1 - h0) < 0.5 and absf(h2 - h0) < 0.5:
				return p
	return near + Vector2(14.0, 0.0)


func _house_runtime(main: Node, pid: String) -> Node:
	var prop := PlacedPropRuntime.find_by_prop_id(main, pid)
	if prop == null:
		return null
	return prop.find_child("ShowerHouseRuntime", true, false)


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	if harness != null and "shots_dir" in harness and str(harness.get("shots_dir")).begins_with("user://"):
		_dir = str(harness.get("shots_dir"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_dir))
	var loader := main.find_child("TerrainLoader", true, false)
	var reg: SpaceRegistry = loader.get("npc_spaces") if loader != null else null
	_ok(reg != null, "the world has a space registry")
	if reg == null:
		return {"ok": false}
	var sgv := ServiceLocator.graph()
	var bridge: Object = sgv.call("npc_population_bridge") if sgv != null else null
	_ok(bridge != null, "the population bridge is up")
	if bridge == null:
		return {"ok": false}
	main.set("time_scale", 1.0 / 3600.0)
	# The shower area's house is placed (and stalls resolved) on the bridge's
	# one-second pass.
	var showers: Array = []
	var area_sid := ""
	var area_house := ""
	var waited := 0.0
	while waited < 30.0:
		await tree.create_timer(0.5).timeout
		waited += 0.5
		showers = reg.spaces_of_type("shower")
		for s: Dictionary in showers:
			if str((s.get("target", {}) as Dictionary).get("kind", "")) == "area":
				area_sid = str(s["id"])
				area_house = str(s.get("bank_prop", ""))
		if not area_sid.is_empty() and reg.stall_count(area_sid) > 0:
			break
	_ok(not area_sid.is_empty(), "the world has a shower area")
	_ok(not area_house.is_empty() and PlacedPropRuntime.find_by_prop_id(main, area_house) != null,
		"the shower area got a shower house", area_house)
	var rec: Dictionary = PlacedPropService.get_prop_record(main, area_house) if not area_house.is_empty() else {}
	_ok(str(rec.get("model_id", "")) == ShowerHouseBuilder.MODEL_ID and str(rec.get("showers_for", "")) == area_sid,
		"it is a shower house placed for that area", str(rec.get("model_id", "")))
	_ok(reg.stall_count(area_sid) == int(ShowerHouseBuilder.resolve(rec.get("shower_spec", {}))["stalls"]),
		"the area has one stall per shower", "%d" % reg.stall_count(area_sid))
	# One placed by hand: a 6-stall house tags itself a shower.
	var anchor: Variant = reg.cached_position(area_sid)
	var spot := _open_ground(main, anchor if anchor is Vector2 else Vector2.ZERO, loader)
	var placed := PlacedPropService.place_model_at_xz(main, ShowerHouseBuilder.MODEL_ID, spot.x, spot.y,
		{"yaw": 0.0, "shower_spec": {"stalls": 6}})
	var own_id := str(placed.get("prop_id", ""))
	_ok(bool(placed.get("ok", false)), "placed a 6-stall shower house", str(spot))
	await tree.create_timer(2.0).timeout
	var own_sid := ""
	for s: Dictionary in reg.spaces_of_type("shower"):
		if str((s.get("target", {}) as Dictionary).get("prop_id", "")) == own_id:
			own_sid = str(s["id"])
	_ok(not own_sid.is_empty() and reg.stall_count(own_sid) == 6, "it is a shower with 6 stalls",
		"%s %d" % [own_sid, reg.stall_count(own_sid) if not own_sid.is_empty() else -1])
	var own_prop := PlacedPropRuntime.find_by_prop_id(main, own_id)
	var curtains := own_prop.find_child("Curtains", true, false) if own_prop != null else null
	_ok(curtains != null and curtains.get_child_count() == 6, "its model has six stalls (the spec reached the builder)")
	# A day at 600x.
	var h := float(main.call("get_absolute_hours"))
	main.call("set_absolute_hours", floor(h / 24.0) * 24.0 + 24.0 + 5.0)
	main.set("time_scale", 600.0 / 3600.0)
	var sids := [area_sid, own_sid]
	var houses := {area_sid: area_house, own_sid: own_id}
	var max_over := -99
	var showering := 0
	var elsewhere := 0
	var on_deck := 0
	var off_deck := 0
	var water_ok := 0
	var water_bad := 0
	var used := {}
	var shot_taken := false
	for k in 600:
		await tree.create_timer(0.25).timeout
		for sid in sids:
			if str(sid).is_empty():
				continue
			var n := reg.stall_count(sid)
			max_over = maxi(max_over, reg.occupant_count(sid) - n)
			if reg.occupant_count(sid) > 0:
				used[sid] = true
				var rt := _house_runtime(main, str(houses[sid]))
				var busy: Array = bridge.call("stalls_busy", str(houses[sid]))
				if rt != null:
					var running: Array = rt.call("running")
					var any_busy := busy.has(true)
					if any_busy and running.has(true):
						water_ok += 1
					elif any_busy and k > 4:
						water_bad += 1
		var house_spots: Array = []
		for pid in [area_house, own_id]:
			var hp := PlacedPropRuntime.find_by_prop_id(main, str(pid))
			if hp != null:
				house_spots.append_array(NpcPopulationBridge.shower_spots(hp))
		for d: Dictionary in bridge.call("agent_dots_full"):
			if str(d.get("activity", "")) != "hygiene" or int(d.get("state", -1)) != NpcAgent.State.DOING:
				continue
			# The camp's living vehicles have showers of their own: only a
			# person showering in a shower house is judged here.
			var at_house := false
			for sp: Dictionary in house_spots:
				if (sp["pos"] as Vector2).distance_to(d.get("pos", Vector2.INF)) < 1.5:
					at_house = true
					break
			if not at_house:
				elsewhere += 1
				continue
			showering += 1
			if str(d.get("seat", "")) == NpcSeatPose.KIND_STAND \
					and is_equal_approx(float(d.get("elev", 0.0)), ShowerHouseBuilder.FLOOR_Y):
				on_deck += 1
				if not shot_taken:
					shot_taken = await _shoot_in_use(main, tree, d)
			else:
				off_deck += 1
		if float(main.call("get_absolute_hours")) > floor(h / 24.0) * 24.0 + 48.0 + 5.0:
			break
	main.set("time_scale", 1.0 / 3600.0)
	print("shower-check: showering in a house %d (on the deck %d, off %d), elsewhere (vehicles) %d; water on %d, off while busy %d; houses used %s"
		% [showering, on_deck, off_deck, elsewhere, water_ok, water_bad, str(used.keys())])
	_ok(max_over <= 0, "never more in a shower house than its stalls", "worst %+d" % max_over)
	_ok(showering > 0, "people shower in the day", "%d samples" % showering)
	_ok(off_deck == 0, "everyone showering stands on a stall's deck", "%d of %d" % [off_deck, showering])
	_ok(water_ok > 0 and water_bad == 0, "a stall in use runs its water", "on %d, off %d" % [water_ok, water_bad])
	await _shoot_front(main, tree, own_id)
	if loader != null and loader.has_method("delete_prop_by_id"):
		loader.call("delete_prop_by_id", own_id)
	var ok := _fails.is_empty()
	print("shower-check %s (%d failed)" % ["PASS" if ok else "FAIL", _fails.size()])
	return {"ok": ok, "fails": _fails}


func _camera(main: Node) -> Camera3D:
	var cam := main.get_node_or_null("ShowerCheckCam") as Camera3D
	if cam == null:
		cam = Camera3D.new()
		cam.name = "ShowerCheckCam"
		cam.fov = 60.0
		main.add_child(cam)
		main.call("push_camera_claim", "shower_check", {"camera_id": cam.get_instance_id(), "hide_player_mesh": true})
	var ui := main.get_node_or_null("UILayer")
	if ui is CanvasLayer:
		(ui as CanvasLayer).visible = false
	return cam


func _shoot_in_use(main: Node, tree: SceneTree, dot: Dictionary) -> bool:
	var p: Vector2 = dot.get("pos", Vector2.ZERO)
	var cam := _camera(main)
	var gy := TerrainSurfaceQuery.ground_height_at(main, p.x, p.y)
	var yaw := float(dot.get("face_yaw", 0.0))
	var back := Vector3(sin(yaw), 0.0, cos(yaw))
	var at := Vector3(p.x, gy + 1.2, p.y)
	main.set("time_scale", 1.0 / 3600.0)
	cam.look_at_from_position(at + back * 3.4 + Vector3(0.0, 0.6, 0.0), at, Vector3.UP)
	await tree.create_timer(1.2).timeout
	main.get_viewport().get_texture().get_image().save_png("%s/02_stall_in_use.png" % _dir)
	main.set("time_scale", 600.0 / 3600.0)
	return true


func _shoot_front(main: Node, tree: SceneTree, pid: String) -> void:
	var prop := PlacedPropRuntime.find_by_prop_id(main, pid)
	if prop == null:
		return
	var model := prop.get_node_or_null("ModelRoot") as Node3D
	if model == null:
		return
	var cam := _camera(main)
	var b := model.global_transform
	var front := b.basis * Vector3(0.0, 0.0, 1.0)
	var side := b.basis * Vector3(1.0, 0.0, 0.0)
	var at := b.origin + Vector3(0.0, 1.3, 0.0)
	main.call("set_absolute_hours", floor(float(main.call("get_absolute_hours")) / 24.0) * 24.0 + 24.0 + 10.5)
	cam.look_at_from_position(at + front * 8.5 + side * 4.0 + Vector3(0.0, 2.2, 0.0), at, Vector3.UP)
	await tree.create_timer(1.5).timeout
	main.get_viewport().get_texture().get_image().save_png("%s/01_house_front.png" % _dir)
	cam.look_at_from_position(at - front * 6.0 + side * 5.0 + Vector3(0.0, 4.5, 0.0), at, Vector3.UP)
	await tree.create_timer(1.0).timeout
	main.get_viewport().get_texture().get_image().save_png("%s/03_house_back_roof.png" % _dir)
	main.call("pop_camera_claim", "shower_check")
	cam.queue_free()
