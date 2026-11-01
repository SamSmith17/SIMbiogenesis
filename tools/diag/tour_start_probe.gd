extends RefCounted

## Where should the feature tour stand on this world? (sandbox, read-only):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/diag/tour_start_probe.gd -Label tour_starts
## Tries the saved player spot, the site centre and two rings round the centre
## (8 bearings at 40 m and 90 m, facing the centre), plus 8 headings at the
## saved spot and at the centre. Per candidate: a screenshot
## (screenshots\tour_starts\<world>\NN.png) and one line — the clear view
## ahead (eye-height ray, 0..400 m), the ground's slope round the spot, and
## the people within 15 m (a start in the middle of a crowd is a wall of
## bodies). Pick one and put it in TourDirector.WORLD_STARTS.

var _out := ""


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var player := main.find_child("Player", true, false) as Node3D
	if player == null:
		print("tourstart: no player")
		return {"ok": false}
	# The tour's stops run by day: judge the views at 14:00, clock held.
	main.set("day_time", 14.0)
	main.set("time_scale", 0.0)
	# The tour's own reset (TourDirector._baseline): a world saved with the
	# drone up, festival mode or the settlement view open shows none of the
	# player's view.
	if bool(player.get("is_fpv_drone_mode")) and player.has_method("toggle_remote_drone_view"):
		player.call("toggle_remote_drone_view")
	if main.has_method("close_festival_mode"):
		main.call("close_festival_mode")
	var sv: Variant = main.get("settlement_view")
	if sv != null and is_instance_valid(sv) and bool(sv.call("is_open")):
		sv.call("close")
	var pp: Variant = load("res://core/player_prefs.gd")
	if pp != null and str(pp.call("camera_mode")) != "first":
		pp.call("set_camera_mode", "first")
	for _f in 10:
		await tree.process_frame
	var world := "world"
	for arg in OS.get_cmdline_user_args():
		if str(arg).begins_with("--world="):
			world = str(arg).substr(8)
	_out = "user://screenshots/tour_starts/%s" % world
	DirAccess.make_dir_recursive_absolute(_out)
	var cam := player.get_node_or_null("CameraArm/Camera3D") as Camera3D
	var p0 := player.global_position
	var yaw0 := rad_to_deg(player.rotation.y)
	var pitch0 := rad_to_deg(cam.rotation.x) if cam != null else 0.0
	var c := SiteCentre.xz(main)
	print("tourstart: saved player at (%.1f, %.1f) yaw %.0f° pitch %.0f° · site centre (%.1f, %.1f) · shots %s" % [
		p0.x, p0.z, yaw0, pitch0, c.x, c.y, ProjectSettings.globalize_path(_out)])
	var cands: Array = []
	# Refining round the saved spot: --probe-mode=out steps D m along each of
	# 8 headings and looks on outward (out from under a roof); =in steps out
	# and looks back at the spot (a crowd seen from its edge). --probe-d=4,8.
	var mode := ""
	var dists: Array = []
	for arg in OS.get_cmdline_user_args():
		var s := str(arg)
		if s.begins_with("--probe-mode="):
			mode = s.substr(13)
		elif s.begins_with("--probe-d="):
			for v in s.substr(10).split(","):
				dists.append(float(v))
	if mode == "out" or mode == "in":
		for d: float in dists:
			for k in 8:
				var y := deg_to_rad(float(k * 45))
				var q := Vector2(p0.x, p0.z) + Vector2(-sin(y), -cos(y)) * d
				var face := float(k * 45) if mode == "out" else float(k * 45 + 180)
				cands.append({"label": "%s%d_h%d" % [mode, int(d), k * 45], "xz": q, "yaw": fmod(face, 360.0)})
	else:
		cands = _default_candidates(p0, c)
	await _shoot(main, tree, player, cam, cands)
	print("tourstart: %s — %d candidates" % [world, cands.size()])
	return {"ok": true}


func _default_candidates(p0: Vector3, c: Vector2) -> Array:
	var cands: Array = []
	for k in 8:
		cands.append({"label": "saved_h%d" % (k * 45), "xz": Vector2(p0.x, p0.z), "yaw": float(k * 45)})
	for k in 8:
		cands.append({"label": "centre_h%d" % (k * 45), "xz": c, "yaw": float(k * 45)})
	for r: float in [40.0, 90.0]:
		for k in 8:
			var a := deg_to_rad(float(k * 45))
			var q := c + Vector2(sin(a), -cos(a)) * r
			var d := c - q
			cands.append({"label": "ring%d_b%d" % [int(r), k * 45], "xz": q,
				"yaw": rad_to_deg(atan2(-d.x, -d.y))})
	return cands


func _shoot(main: Node, tree: SceneTree, player: Node3D, cam: Camera3D, cands: Array) -> void:
	var i := 0
	for cd: Dictionary in cands:
		var q: Vector2 = cd["xz"]
		var gy := TerrainSurfaceQuery.ground_height_at(main, q.x, q.y)
		player.global_transform = Transform3D(Basis(Vector3.UP, deg_to_rad(float(cd["yaw"]))), Vector3(q.x, gy + 0.1, q.y))
		if player is CharacterBody3D:
			(player as CharacterBody3D).velocity = Vector3.ZERO
		if cam != null:
			cam.rotation.x = 0.0
		for _f in 24:
			await tree.process_frame
		var eye := cam.global_position if cam != null else Vector3(q.x, gy + 1.7, q.y)
		var fwd := -player.global_transform.basis.z
		var view := _ray(main, eye, fwd, 400.0, player)
		var slope := _slope(main, q)
		var npcs := _people_near(main, q, 15.0)
		var file := "%s/%02d_%s.png" % [_out, i, str(cd["label"])]
		var img := main.get_viewport().get_texture().get_image()
		img.resize(640, 360, Image.INTERPOLATE_BILINEAR)
		img.save_png(file)
		print("tourstart %02d %-14s at (%7.1f, %7.1f) yaw %4.0f° · clear view %5.1f m · slope %4.1f m over 20 m · %d people within 15 m" % [
			i, str(cd["label"]), q.x, q.y, float(cd["yaw"]), view, slope, npcs])
		i += 1


func _ray(main: Node, from: Vector3, dir: Vector3, max_d: float, skip: Node3D) -> float:
	var space := (main as Node3D).get_world_3d().direct_space_state
	var excl: Array[RID] = []
	if skip is CollisionObject3D:
		excl.append((skip as CollisionObject3D).get_rid())
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * max_d)
	q.exclude = excl
	var hit := space.intersect_ray(q)
	return max_d if hit.is_empty() else from.distance_to(hit["position"])


func _slope(main: Node, c: Vector2) -> float:
	var lo := INF
	var hi := -INF
	for k in 9:
		var q := c
		if k > 0:
			var a := TAU * float(k) / 8.0
			q = c + Vector2(cos(a), sin(a)) * 10.0
		var y := TerrainSurfaceQuery.ground_height_at(main, q.x, q.y)
		lo = minf(lo, y)
		hi = maxf(hi, y)
	return hi - lo


func _people_near(main: Node, c: Vector2, r: float) -> int:
	var sgv := main.find_child("SystemGraphView", true, false)
	var br: Variant = sgv.get("_npc_population") if sgv != null else null
	if br == null:
		return 0
	var n := 0
	for d in br.call("agent_dots"):
		var p: Variant = (d as Dictionary).get("pos")
		var xz := Vector2.INF
		if p is Vector3:
			xz = Vector2(p.x, p.z)
		elif p is Vector2:
			xz = p
		if xz != Vector2.INF and xz.distance_to(c) <= r:
			n += 1
	return n
