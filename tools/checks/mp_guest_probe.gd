extends RefCounted

## Multiplayer end to end, GUEST half — see mp_host_probe.gd for how to run
## the pair. Joins over 127.0.0.1, then: waits for the host's firepit and
## times it; moves it (a proposal: the sync line must say it is waiting, the
## move must stay on screen); deletes it (declined: it must come back);
## adds a graph node (accepted); tries a move under "view only" (put back at
## once); checks the host's body is the silhouette figure where the host is;
## and that the session runs in the throwaway guest world.

var _fails: Array = []
var _dir := ""


func _ok(cond: bool, what: String) -> void:
	print("mp-guest %s: %s" % ["PASS" if cond else "FAIL", what])
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
	img.save_png("user://screenshots/mp_probe/guest_%s.png" % name)


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	_dir = OS.get_environment("TEMP").path_join("mp_probe")
	var mp: Node = tree.root.get_node("MultiplayerSession")
	var design: Node = mp.get("design")
	mp.call("set_display_name", "Guestie")
	# A fresh h0 from THIS run (the host clears the folder on start).
	await tree.create_timer(3.0).timeout
	var h0 := await _wait_file(tree, "h0.json", 240.0)
	_ok(not h0.is_empty(), "the host is up (h0)")
	if h0.is_empty():
		return {"ok": false}
	var dec: Dictionary = MpJoinCode.decode(str(h0["code"]))
	_ok(bool(dec.get("ok", false)), "the join code decodes")
	var info: Dictionary = dec.get("data", dec) as Dictionary
	info["addrs"] = [{"h": "127.0.0.1", "p": int(h0["port"]), "k": "lan"}]
	var jr: Dictionary = mp.call("join_decoded", info)
	_ok(bool(jr.get("ok", false)), "join started (%s)" % str(jr))
	var t0 := Time.get_ticks_msec()
	while not (bool(design.get("_have_canon"))) and Time.get_ticks_msec() - t0 < 60000:
		await tree.process_frame
	_ok(bool(design.get("_have_canon")), "the host's world arrived (%.1f s)" % ((Time.get_ticks_msec() - t0) / 1000.0))
	_ok(MpGuestWorld.is_active(), "the session runs in the throwaway guest world, not this player's own")
	var sgv: Node = ServiceLocator.graph()
	_ok(str(sgv.model.id_prefix).begins_with("p"), "graph ids are minted under the guest's prefix (%s)" % sgv.model.id_prefix)
	var player := main.get_node("Player") as Node3D
	_write("g0.json", {"x": player.global_position.x, "y": player.global_position.y, "z": player.global_position.z})
	# 1. the host's firepit arrives
	var h1 := await _wait_file(tree, "h1.json", 60.0)
	var pid := str(h1.get("id", ""))
	var seen := false
	var latency := -1.0
	t0 = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 20000:
		if not PlacedPropService.get_prop_record(main, pid).is_empty() \
				and PlacedPropRuntime.find_by_prop_id(main, pid) != null:
			seen = true
			latency = Time.get_unix_time_from_system() - float(h1["t"])
			break
		await tree.process_frame
	_ok(seen, "the host's firepit appeared here (%.2f s)" % latency)
	var hosts: Array = mp.call("remote_avatars")
	_ok(hosts.size() == 1 and hosts[0].get_node_or_null("Body") is NpcSimpleFigure,
		"the host is drawn as the NPC silhouette figure")
	_write("g1.json", {"seen": seen, "latency_s": latency})
	# Step back from the host and look at them, for the picture.
	if hosts.size() == 1:
		var hpos: Vector3 = (hosts[0] as Node3D).global_position
		var back := Vector3(3.0, 0.0, 1.0)
		var gy := TerrainSurfaceQuery.ground_height_at(main, hpos.x + back.x, hpos.z + back.z)
		player.global_position = Vector3(hpos.x + back.x, (gy if not is_nan(gy) else hpos.y) + 0.05, hpos.z + back.z)
		var to := hpos - player.global_position
		player.rotation.y = atan2(-to.x, -to.z)
		var cam := player.get("camera") as Camera3D
		if cam != null:
			cam.rotation.x = -0.12
	await tree.create_timer(1.5).timeout
	_shot(main, "host_body_and_firepit")
	# 2. move it: a proposal; it stays where the guest put it while waiting
	var x0 := float(h1["x"])
	var z0 := float(h1["z"])
	PlacedPropService.move_prop_xz(main, pid, x0 + 8.0, z0)
	await tree.create_timer(1.2).timeout
	var act: Dictionary = design.call("activity_now")
	_ok(str(act.get("text", "")).begins_with("Waiting for"), "the sync line says it is waiting: \"%s\"" % str(act.get("text", "")))
	_ok((design.get("my_pending") as Dictionary).size() == 1, "one change is waiting")
	_shot(main, "waiting_for_host")
	await _wait_file(tree, "h2.json", 30.0)
	await tree.create_timer(0.6).timeout
	act = design.call("activity_now")
	_ok(str(act.get("text", "")).contains("accepted"), "the sync line says accepted: \"%s\"" % str(act.get("text", "")))
	_ok((design.get("my_pending") as Dictionary).is_empty(), "nothing waiting any more")
	var rec := PlacedPropService.get_prop_record(main, pid)
	_ok(absf(float(rec.get("x", 0.0)) - (x0 + 8.0)) < 0.05, "the firepit stays where the guest moved it")
	_shot(main, "accepted")
	# 3. delete it: declined, it comes back
	var loader := main.get_node_or_null("TerrainLoader")
	loader.call("delete_prop_by_id", pid)
	_ok(PlacedPropService.get_prop_record(main, pid).is_empty(), "deleted on the guest's screen")
	await _wait_file(tree, "h3.json", 30.0)
	await tree.create_timer(0.8).timeout
	_ok(not PlacedPropService.get_prop_record(main, pid).is_empty()
		and PlacedPropRuntime.find_by_prop_id(main, pid) != null, "declined: the firepit is back")
	act = design.call("activity_now")
	_ok(str(act.get("text", "")).contains("declined"), "the sync line says declined: \"%s\"" % str(act.get("text", "")))
	_shot(main, "declined")
	# 4. a graph node
	sgv.model.add_item({"type": "battery", "label": "Probe Battery", "x": 40.0, "y": 40.0,
		"specs": {"capacity_kwh": 1.0}})
	await _wait_file(tree, "h4.json", 30.0)
	await tree.create_timer(0.8).timeout
	_ok((design.get("my_pending") as Dictionary).is_empty(), "the graph change was answered")
	# 5. view only
	await _wait_file(tree, "h5.json", 30.0)
	await tree.create_timer(0.8).timeout
	_ok(str(design.get("host_policy")) == "view", "the host's 'view only' reached the guest")
	rec = PlacedPropService.get_prop_record(main, pid)
	var xb := float(rec.get("x", 0.0))
	PlacedPropService.move_prop_xz(main, pid, xb + 5.0, z0)
	await tree.create_timer(1.5).timeout
	rec = PlacedPropService.get_prop_record(main, pid)
	var reverted := absf(float(rec.get("x", 0.0)) - xb) < 0.05
	_ok(reverted, "view only: the move was put back")
	_write("g5.json", {"reverted": reverted})
	_shot(main, "view_only")
	_write("g6.json", {"done": true})
	await tree.create_timer(2.0).timeout
	return {"ok": _fails.is_empty(), "fails": _fails}
