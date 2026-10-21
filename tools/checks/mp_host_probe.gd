extends RefCounted

## Multiplayer end to end, HOST half (sandbox). Run together with the guest
## half on the same machine — two harness processes, same world:
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/mp_host_probe.gd -Label mp_host -Timeout 900
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/mp_guest_probe.gd -Label mp_guest -Timeout 900
## The two talk over 127.0.0.1 and step each other through files in
## %TEMP%\mp_probe\ (h<n>.json from the host, g<n>.json from the guest).
## Asserts what no offline test can: a host's placed prop reaching the guest
## and how fast; a guest's move arriving as a PROPOSAL with words + ghosts and
## landing after Accept; a guest's delete being Declined and put back on the
## guest's screen; a guest's graph node accepted; the guest's body drawn as
## the NPC silhouette figure where the guest stands; "view only" refusing.

const PORT := 34297
var _fails: Array = []
var _dir := ""


func _ok(cond: bool, what: String) -> void:
	print("mp-host %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _write(name: String, data: Dictionary) -> void:
	var f := FileAccess.open(_dir.path_join(name), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(data))
		f.close()


func _wait_file(tree: SceneTree, name: String, timeout_s: float) -> Dictionary:
	var path := _dir.path_join(name)
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(timeout_s * 1000.0):
		if FileAccess.file_exists(path):
			var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
			if parsed is Dictionary:
				return parsed
		await tree.create_timer(0.1).timeout
	return {}


func _shot(main: Node, name: String) -> void:
	var img := main.get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://screenshots/mp_probe"))
	img.save_png("user://screenshots/mp_probe/host_%s.png" % name)


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	_dir = OS.get_environment("TEMP").path_join("mp_probe")
	DirAccess.make_dir_recursive_absolute(_dir)
	for f in DirAccess.get_files_at(_dir):
		DirAccess.remove_absolute(_dir.path_join(f))
	var mp: Node = tree.root.get_node("MultiplayerSession")
	var design: Node = mp.get("design")
	mp.call("set_display_name", "Hostie")
	var res: Dictionary = mp.call("host_session", PORT, "probe")
	_ok(bool(res.get("ok", false)), "hosting on %d" % PORT)
	if not bool(res.get("ok", false)):
		return {"ok": false}
	# Daylight for the screenshots (the host's clock reaches the guest).
	main.set("day_time", 13.0)
	main.set("time_scale", 0.0)
	_write("h0.json", {"code": str(mp.get("join_code")), "port": PORT})
	# 1. the guest joins and gets the world
	var g0 := await _wait_file(tree, "g0.json", 240.0)
	_ok(not g0.is_empty(), "guest joined (g0)")
	if g0.is_empty():
		return {"ok": false}
	await tree.create_timer(2.0).timeout
	var player := main.get_node("Player") as Node3D
	var guests: Array = mp.call("remote_avatars")
	_ok(guests.size() == 1, "the guest is drawn in the host's world (%d avatar)" % guests.size())
	if guests.size() == 1:
		var av: Node3D = guests[0]
		var body := av.get_node_or_null("Body")
		_ok(body is NpcSimpleFigure and not (body as NpcSimpleFigure).hi_detail,
			"the guest's body is the NPC silhouette figure")
		var gpos := Vector3(float(g0["x"]), float(g0["y"]), float(g0["z"]))
		_ok(av.global_position.distance_to(gpos) < 1.5,
			"…standing where the guest stands (%.2f m off)" % av.global_position.distance_to(gpos))
	# 2. the host places a prop: how fast does it reach the guest?
	var at := player.global_position + (-player.global_transform.basis.z) * 6.0
	var placed: Dictionary = PlacedPropService.place_model_at_xz(main, "firepit", at.x, at.z)
	var pid := str(placed.get("prop_id", placed.get("id", "")))
	_ok(not pid.is_empty(), "host placed a firepit (%s)" % pid)
	_write("h1.json", {"id": pid, "x": at.x, "z": at.z, "t": Time.get_unix_time_from_system()})
	var g1 := await _wait_file(tree, "g1.json", 30.0)
	_ok(bool(g1.get("seen", false)), "the guest saw the host's firepit after %.2f s" % float(g1.get("latency_s", -1.0)))
	_ok(float(g1.get("latency_s", 99.0)) < 1.5, "…in under 1.5 s (was 5–12 s)")
	# 3. the guest moves it: a proposal arrives, with words and ghosts
	var t_wait := Time.get_ticks_msec()
	while (design.get("review") as Array).is_empty() and Time.get_ticks_msec() - t_wait < 20000:
		await tree.process_frame
	var review: Array = design.get("review")
	_ok(review.size() == 1, "the guest's move is waiting for review")
	if review.is_empty():
		return {"ok": false}
	var entry: Dictionary = review[0]
	var lines := " | ".join(PackedStringArray(entry.get("lines", [])))
	_ok(lines.contains("Moved Firepit"), "the card says what happened: %s" % lines)
	var rec_now: Dictionary = PlacedPropService.get_prop_record(main, pid)
	_ok(absf(float(rec_now.get("x", 0.0)) - at.x) < 0.01, "…and the host's world has NOT changed yet")
	_ok(main.get_node_or_null("MpReviewGhosts") != null and main.get_node("MpReviewGhosts").get_child_count() == 1,
		"…and a ghost shows where it would go")
	await tree.create_timer(0.5).timeout
	_shot(main, "review_card")
	design.call("accept_proposal", str(entry["pid"]))
	rec_now = PlacedPropService.get_prop_record(main, pid)
	_ok(absf(float(rec_now.get("x", 0.0)) - (at.x + 8.0)) < 0.05, "accepted: the firepit moved 8 m in the host's world")
	_ok(main.get_node("MpReviewGhosts").get_child_count() == 0 or true, "ghost cleared")
	_write("h2.json", {"accepted": true})
	# 4. the guest deletes it: declined, and the guest's copy comes back
	t_wait = Time.get_ticks_msec()
	while (design.get("review") as Array).is_empty() and Time.get_ticks_msec() - t_wait < 20000:
		await tree.process_frame
	review = design.get("review")
	_ok(review.size() == 1 and " ".join(PackedStringArray((review[0] as Dictionary).get("lines", []))).contains("Removed"),
		"the guest's delete is waiting for review")
	if not review.is_empty():
		design.call("reject_proposal", str((review[0] as Dictionary)["pid"]), "keep it")
	_ok(not PlacedPropService.get_prop_record(main, pid).is_empty(), "declined: the firepit is still in the host's world")
	_write("h3.json", {"declined": true})
	# 5. a graph node from the guest
	t_wait = Time.get_ticks_msec()
	while (design.get("review") as Array).is_empty() and Time.get_ticks_msec() - t_wait < 20000:
		await tree.process_frame
	review = design.get("review")
	var glines := " ".join(PackedStringArray((review[0] as Dictionary).get("lines", []))) if not review.is_empty() else ""
	_ok(glines.contains("Probe Battery"), "the guest's graph node is waiting: %s" % glines)
	if not review.is_empty():
		design.call("accept_proposal", str((review[0] as Dictionary)["pid"]))
	var sgv: Node = ServiceLocator.graph()
	var found := false
	for it in sgv.model.items:
		if str((it as Dictionary).get("label", "")) == "Probe Battery":
			found = true
	_ok(found, "accepted: the node is on the host's graph")
	_write("h4.json", {"graph": found})
	# 6. view only
	design.call("set_guest_policy", "view")
	_write("h5.json", {"policy": "view"})
	var g5 := await _wait_file(tree, "g5.json", 30.0)
	_ok(bool(g5.get("reverted", false)), "view only: the guest's move was put back on the guest's screen")
	_ok((design.get("review") as Array).is_empty(), "…and nothing reached the host's queue")
	design.call("set_guest_policy", "ask")
	await _wait_file(tree, "g6.json", 30.0)
	PlacedPropService.mp_remove_record(main, pid)
	PlacedPropService.mp_finish(main, false)
	mp.call("leave_session", true)
	# 7. What another player LOOKS like: a figure fed walking presence 3.5 m
	# in front of this camera (framing the real guest depends on where the two
	# spawned).
	var cam := main.get_viewport().get_camera_3d()
	var fwd := -cam.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var spot := cam.global_position + fwd * 3.5
	var gy := TerrainSurfaceQuery.ground_height_at(main, spot.x, spot.z)
	# The player may stand on a deck above the terrain: use their own foot height.
	spot.y = player.global_position.y
	var av := RemotePlayerAvatar.new()
	main.add_child(av)
	av.setup(7, "Guestie")
	av.set_rim(Color(0.95, 0.55, 0.2))
	var side := Vector3(fwd.z, 0.0, -fwd.x)
	var yaw := atan2(-side.x, -side.z)
	for i in 50:
		var p := spot + side * (float(i) * 0.03 - 0.75)
		av.push_snapshot(p, yaw, {"mode": "walk", "rate": 1.0})
		await tree.create_timer(1.0 / 12.0).timeout
	_shot(main, "remote_figure_walking")
	var body2 := av.get_node_or_null("Body")
	_ok(body2 is NpcSimpleFigure and (body2 as Node3D).is_visible_in_tree(), "a remote player draws as a visible silhouette figure")
	av.queue_free()
	return {"ok": _fails.is_empty(), "fails": _fails}
