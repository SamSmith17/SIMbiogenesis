extends RefCounted

## A basin dug across a stream fills before the water goes on (sandbox):
##   tools\harness.ps1 -World <id> -RunScript res://tools/checks/stream_basin_check.gd -Label <dir>
## "Dry between storms" on, a 25 m bowl carved across the longest stream about
## 1.5 km down (TerrainLoader.pond_command, no water seeded), a 40-minute
## storm over the stream's head (WaterNetwork.add_storm). Asserts the bowl is
## found as a basin on that stream, the station just below it stays dry until
## the basin is full, then carries water; the basin holds water after the
## storm and drains slowly. Shots: basin_filling.png, basin_spilling.png.

var _fails: Array = []
var _dir := "user://screenshots/stream_basin"


func _ok(cond: bool, what: String) -> void:
	print("basin-check %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


func _settle(main: Node, wn: Node) -> void:
	var tree := main.get_tree()
	await _frames(tree, 20)
	var t0 := Time.get_ticks_msec()
	while (bool(wn.call("is_busy")) or bool(wn.get("_drain_pending")) or int(wn.get("_drain_task")) >= 0) \
			and Time.get_ticks_msec() - t0 < 90000:
		await tree.process_frame
	await _frames(tree, 30)


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	if harness != null and "shots_dir" in harness and str(harness.get("shots_dir")).begins_with("user://"):
		_dir = str(harness.get("shots_dir"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_dir))
	var loader: Node = main.find_child("TerrainLoader", true, false)
	var wn: Node = loader.call("water_network")
	wn.call("set_display_mode", "all")
	wn.call("set_dry_between_storms", true)
	# A known start whatever the saved world holds: the beds as drawn (no
	# saved flood cuts) and no weather rain (the clock may sit in a storm).
	wn.set("rain_override_mmh", 0.0)
	wn.call("reset_erosion")
	main.set("time_scale", 0.0)
	main.set("day_time", 13.0)
	await _settle(main, wn)
	var feats: Array = wn.call("features")
	var f: Dictionary = feats[0]
	for g in feats:
		if StreamNetwork.polyline_length((g as Dictionary)["points"]) > StreamNetwork.polyline_length(f["points"]):
			f = g
	var fid := str(f["id"])
	var prof: Dictionary = wn.call("profile", fid)
	var ppts: PackedVector2Array = prof["points"]
	var s: PackedFloat32Array = prof["s"]
	var at := ChannelProfile.station_index(prof, 1500.0)
	var c := ppts[at]
	var poly := PackedVector2Array([c + Vector2(-12.5, -12.5), c + Vector2(12.5, -12.5),
		c + Vector2(12.5, 12.5), c + Vector2(-12.5, 12.5)])
	var dug := bool(loader.call("pond_command", poly, 1.2, "Test swale", 0.85, false))
	_ok(dug, "a bowl was carved across %s at %.0f m" % [fid, s[at]])
	await _settle(main, wn)
	var bs: Array = (wn.call("basins") as Dictionary).get(fid, [])
	var basin: Dictionary = {}
	for b in bs:
		if int((b as Dictionary)["i0"]) <= at + 15 and int((b as Dictionary)["i1"]) >= at - 15:
			basin = b
	_ok(not basin.is_empty(), "the bowl is a basin on the stream (%d basins on %s)" % [bs.size(), fid])
	if basin.is_empty():
		return {"ok": false, "failures": _fails}
	var cap := float(basin["capacity_m3"])
	print("basin-check: basin stations %d..%d, %.0f m3, %.0f m2, spill %.2f, floor %.2f" % [
		int(basin["i0"]), int(basin["i1"]), cap, float(basin["area_m2"]), float(basin["spill_y"]), float(basin["floor_y"])])
	var below := mini(int(basin["i1"]) + 10, ppts.size() - 1)
	# The storm: 80 mm/h for 40 min over the stream's head.
	var head := ppts[mini(ppts.size() - 1, int(ppts.size() * 0.08))]
	var circle := PackedVector2Array()
	for k in 24:
		var a := TAU * float(k) / 24.0
		circle.append(head + Vector2(cos(a), sin(a)) * 180.0)
	var t_start := float(wn.call("_now_h")) + 0.05
	var sid := int(wn.call("add_storm", circle, 80.0, t_start, t_start + 0.667))
	await _settle(main, wn)
	# Step the clock and watch the basin and the station below it.
	var t_full := -1.0
	var t_below_wet := -1.0
	var max_v := 0.0
	var v_after := -1.0
	var shot_fill := false
	var cam := Camera3D.new()
	cam.far = 3000.0
	main.add_child(cam)
	var gy := float(loader.call("ground_height_at", c.x, c.y))
	cam.global_position = Vector3(c.x - 45.0, gy + 28.0, c.y + 45.0)
	cam.look_at(Vector3(c.x, gy, c.y), Vector3.UP)
	main.call("push_camera_claim", "basin_check", {"camera_id": cam.get_instance_id()})
	var dt := 2.0 / 60.0
	var tt := t_start
	while tt < t_start + 6.0:
		tt += dt
		main.call("set_absolute_hours", tt)
		await tree.process_frame
		wn.call("_ensure_rain_history")
		var bv: Vector2 = wn.call("basin_now", basin)
		max_v = maxf(max_v, bv.x)
		var q_below := float(wn.call("station_q_now", f, below))
		if t_full < 0.0 and bv.x >= cap * 0.99:
			t_full = tt
		if t_below_wet < 0.0 and q_below >= 0.5:
			t_below_wet = tt
		if not shot_fill and bv.x > cap * 0.4 and bv.x < cap * 0.9:
			shot_fill = true
			wn.call("_sync_basin_mesh", true)
			await _frames(tree, 25)
			main.get_viewport().get_texture().get_image().save_png("%s/basin_filling.png" % _dir)
		v_after = bv.x
	print("basin-check: storm %d — basin full at +%.0f min, below wet at +%.0f min, max %.0f of %.0f m3, %.0f m3 six hours on" % [
		sid, (t_full - t_start) * 60.0 if t_full > 0 else -1.0, (t_below_wet - t_start) * 60.0 if t_below_wet > 0 else -1.0,
		max_v, cap, v_after])
	_ok(max_v > 1.0, "the storm's water reaches the basin")
	_ok(t_full > 0.0, "the basin fills to its spill")
	_ok(t_below_wet < 0.0 or t_full < 0.0 or t_below_wet >= t_full - dt,
		"nothing runs on below the basin before it is full")
	_ok(t_below_wet > 0.0, "once full it spills and the water goes on")
	_ok(v_after > 0.0 and v_after < cap * 0.995,
		"hours after the rain the basin still holds water, slowly soaking away (%.0f of %.0f m3)" % [v_after, cap])
	# The spilling moment, for the eye.
	if t_full > 0.0:
		main.call("set_absolute_hours", t_full + 0.2)
		await tree.process_frame
		wn.call("_ensure_rain_history")
		wn.call("_sync_basin_mesh", true)
		wn.call("rebuild_surfaces")
		await _frames(tree, 25)
		main.get_viewport().get_texture().get_image().save_png("%s/basin_spilling.png" % _dir)
	main.call("pop_camera_claim", "basin_check")
	cam.queue_free()
	return {"ok": _fails.is_empty(), "failures": _fails}
