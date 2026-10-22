extends RefCounted

## Rain-tool storms running down the carved streams, with REAL input (sandbox):
##   tools\harness.ps1 -World <id> -RunScript res://tools/checks/stream_storm_check.gd -Label <dir>
## Turns on "Dry between storms", checks the longest stream is dry, draws a
## circle over its head with the terrain toolbar's Rain tool and holds the
## button (a storm), then runs the clock and logs, every few sim-minutes, how
## far down the channel the water has reached. Asserts the head wets first,
## the front only moves downstream while it rains, water reaches the lower
## half, and after the storm (plus the travel time) the channel is dry again.
## Shots: storm_00 (start) .. storm_NN.

const HarnessInputScript := preload("res://core/terrain/harness/harness_input.gd")

var _fails: Array = []
var _dir := "user://screenshots/stream_storm"


func _ok(cond: bool, what: String) -> void:
	print("storm-check %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


## Furthest arc length (m) down the feature where it carries water, and the
## fraction of stations that are wet.
func _front(wn: Node, f: Dictionary) -> Vector2:
	var prof: Dictionary = wn.call("profile", str(f["id"]))
	var s: PackedFloat32Array = prof.get("s", PackedFloat32Array())
	var far := -1.0
	var wet := 0
	for i in s.size():
		if float(wn.call("station_q_now", f, i)) >= 0.5:
			far = s[i]
			wet += 1
	return Vector2(far, float(wet) / maxf(float(s.size()), 1.0))


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	if harness != null and "shots_dir" in harness and str(harness.get("shots_dir")).begins_with("user://"):
		_dir = str(harness.get("shots_dir"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_dir))
	var loader: Node = main.find_child("TerrainLoader", true, false)
	var wn: Node = loader.call("water_network")
	var tb: Control = main.find_child("EditToolbarUI", true, false)
	wn.call("set_display_mode", "all")
	wn.call("set_dry_between_storms", true)
	# A known start whatever the saved world holds: the beds as drawn (no
	# saved flood cuts) and no weather rain (the clock may sit in a storm).
	wn.set("rain_override_mmh", 0.0)
	wn.call("reset_erosion")
	main.set("time_scale", 0.0)
	main.set("day_time", 13.0)
	# Wait for the re-resolve + drainage.
	var t0 := Time.get_ticks_msec()
	while ((wn.call("drainage") as Dictionary).is_empty() or bool(wn.call("is_busy"))) \
			and Time.get_ticks_msec() - t0 < 90000:
		await tree.process_frame
	await _frames(tree, 30)
	var feats: Array = wn.call("features")
	var f: Dictionary = feats[0]
	for g in feats:
		if StreamNetwork.polyline_length((g as Dictionary)["points"]) > StreamNetwork.polyline_length(f["points"]):
			f = g
	var prof: Dictionary = wn.call("profile", str(f["id"]))
	var ppts: PackedVector2Array = prof["points"]
	var total := float((prof["s"] as PackedFloat32Array)[ppts.size() - 1])
	var tcs: PackedFloat32Array = (wn.get("station_tc") as Dictionary).get(f["id"], PackedFloat32Array())
	print("storm-check: %s %.0f m long, Tc head %.0f min, end %.0f min" % [
		f["id"], total, tcs[0] * 60.0 if tcs.size() > 0 else -1.0, tcs[tcs.size() - 1] * 60.0 if tcs.size() > 0 else -1.0])
	_ok(_front(wn, f).y == 0.0, "dry between storms: the channel is dry before rain")
	var bed_before: PackedFloat32Array = (prof["bed"] as PackedFloat32Array).duplicate()
	var s_before: PackedFloat32Array = (prof["s"] as PackedFloat32Array).duplicate()
	# Camera straight-ish down over the head of the stream.
	var head := ppts[mini(ppts.size() - 1, int(ppts.size() * 0.08))]
	var gy := float(loader.call("ground_height_at", head.x, head.y))
	var cam := Camera3D.new()
	cam.far = 4000.0
	main.add_child(cam)
	cam.global_position = Vector3(head.x, gy + 420.0, head.y + 160.0)
	cam.look_at(Vector3(head.x, gy, head.y), Vector3.UP)
	main.call("push_camera_claim", "storm_check", {"camera_id": cam.get_instance_id()})
	await _frames(tree, 10)
	tb.call("open_with_section", "terrain")
	tb.call("_set_active_tool", "rain")
	var st: Object = tb.get("_state")
	st.call("set_shape", "rain", "circle")
	st.call("set_tool_param", "rain", "storm_mmh", 60.0)
	tb.call("_set_active_tool", "rain")
	await _frames(tree, 5)
	var vp := main.get_viewport()
	var c_scr := cam.unproject_position(Vector3(head.x, gy, head.y))
	var e_scr := cam.unproject_position(Vector3(head.x + 180.0, gy, head.y))
	await HarnessInputScript.drag(vp, c_scr, e_scr, 10)
	await _frames(tree, 10)
	_ok(bool(tb.get("_selection_locked")), "a circle is drawn over the stream's head")
	# Hold the Rain button: 4 s of real time at 60x = 4 sim-minutes (+ the
	# 15-minute minimum shower).
	main.set("time_scale", 1.0 / 60.0)
	await HarnessInputScript.mouse_move(vp, c_scr)
	await HarnessInputScript.mouse_press(vp, c_scr, true)
	for _i in 240:
		await tree.process_frame
	await HarnessInputScript.mouse_press(vp, c_scr, false)
	await _frames(tree, 5)
	print("storm-check: basin %s; status '%s'; user water %d" % [str(tb.get("_basin_cache")),
		str((tb.get("_status") as Label).text) if tb.get("_status") != null else "?",
		(loader.get("_user_water_data") as Array).size()])
	var storms: Array = wn.call("storms")
	_ok(storms.size() == 1, "holding Rain over open ground made a storm (%d)" % storms.size())
	if storms.is_empty():
		return {"ok": false, "failures": _fails}
	var storm: Dictionary = storms[0]
	print("storm-check: storm %.2f -> %.2f h (%.0f min), %.0f m2 of ground, %.0f m2 reaching %s" % [
		float(storm["start_h"]), float(storm["end_h"]), (float(storm["end_h"]) - float(storm["start_h"])) * 60.0,
		float(storm["area_m2"]), float(wn.call("storm_reach_m2", int(storm["id"]))), f["id"]])
	_ok(float(wn.call("storm_reach_m2", int(storm["id"]))) > 0.0, "the storm's runoff reaches the stream")
	tb.call("_exit_mode")
	# Run the clock fast and watch the front.
	main.set("time_scale", 20.0 / 60.0)   # 20 sim-minutes per real second
	var fronts: Array = []
	var shot := 0
	var monotone := true
	var gap := false
	var was_wet := false
	var prev_far := -1.0
	var end_h := float(storm["end_h"])
	var start_real := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start_real < 90000:
		await _frames(tree, 6)
		var now := float(wn.call("_now_h"))
		var fr := _front(wn, f)
		fronts.append(Vector3(now - float(storm["start_h"]), fr.x, fr.y))
		if now < end_h and fr.x + 1.0 < prev_far:
			monotone = false
		# Once water has shown up the channel must not go dry and wet again
		# (water skipping ahead) until it has drained for good.
		if was_wet and fr.y < 0.0:
			was_wet = false
			gap = true
		elif fr.y >= 0.0:
			if gap:
				_ok(false, "the water came back after the channel had dried (+%.0f min)" % ((now - float(storm["start_h"])) * 60.0))
				gap = false
			was_wet = true
		prev_far = fr.x
		if shot < 6 and fronts.size() % 8 == 1:
			await _frames(tree, 3)
			vp.get_texture().get_image().save_png("%s/storm_%02d.png" % [_dir, shot])
			shot += 1
		# The last water passes the end about one Tc (plus its spread) after
		# the storm; allow twice that.
		var tc_end := tcs[tcs.size() - 1] if tcs.size() > 0 else 1.0
		if now > end_h + 2.0 * tc_end + 0.5:
			break
	for fr3 in fronts:
		var v: Vector3 = fr3
		print("storm-check: +%5.0f min  front %6.0f m  wet %3.0f %%" % [v.x * 60.0, v.y, v.z * 100.0])
	var max_far := -1.0
	var first_wet_far := -1.0
	for fr3 in fronts:
		var v2: Vector3 = fr3
		if v2.y >= 0.0 and first_wet_far < 0.0:
			first_wet_far = v2.y
		max_far = maxf(max_far, v2.y)
	_ok(first_wet_far >= 0.0 and first_wet_far < total * 0.5, "the water shows up in the upper half first (%.0f m)" % first_wet_far)
	_ok(monotone, "while it rains the front only moves downstream")
	_ok(max_far > total * 0.5, "the water reaches the lower half (%.0f of %.0f m)" % [max_far, total])
	var last: Vector3 = fronts.back()
	_ok(last.z < 0.05, "after the storm and its travel time the channel drains (%.0f %% wet)" % (last.z * 100.0))
	# Erosion: the flood cut the bed; once past the re-carve step the carved
	# bed is lower where it cut most.
	var lay: WaterFeatureLayer = wn.get("layer")
	var ero := lay.erosion_of(str(f["id"]))
	var deepest := 0.0
	var deepest_k := 0
	for k in ero.size():
		if ero[k] > deepest:
			deepest = ero[k]
			deepest_k = k
	print("storm-check: erosion on %s up to %.3f m at %.0f m" % [f["id"], deepest, float(deepest_k) * ChannelProfile.EROSION_STEP_M])
	_ok(deepest > 0.0, "the flood eroded the channel bed")
	var t1 := Time.get_ticks_msec()
	while (bool(wn.call("is_busy")) or bool(wn.get("_rebuild_pending"))) and Time.get_ticks_msec() - t1 < 60000:
		await tree.process_frame
	await _frames(tree, 20)
	if deepest >= 0.02:
		var prof2: Dictionary = wn.call("profile", str(f["id"]))
		var s_at := float(deepest_k) * ChannelProfile.EROSION_STEP_M
		var i_old := ChannelProfile.station_index({"s": s_before}, s_at)
		var i_new := ChannelProfile.station_index(prof2, s_at)
		var drop := bed_before[i_old] - (prof2["bed"] as PackedFloat32Array)[i_new]
		print("storm-check: carved bed at %.0f m dropped %.3f m" % [s_at, drop])
		_ok(drop >= deepest * 0.5, "the carved bed is lower where the flood cut (%.3f of %.3f m)" % [drop, deepest])
	# Close-ups: everything is a function of the clock, so scrub to the moment.
	main.set("time_scale", 0.0)
	var t_rain := float(storm["start_h"]) + 0.08
	main.call("set_absolute_hours", t_rain)
	await _frames(tree, 40)
	cam.global_position = Vector3(head.x - 150.0, gy + 30.0, head.y + 170.0)
	cam.look_at(Vector3(head.x, gy + 15.0, head.y), Vector3.UP)
	await _frames(tree, 30)
	vp.get_texture().get_image().save_png("%s/close_raining.png" % _dir)
	# The front a third of the way down: stand over it, looking downstream.
	var best_t := t_rain
	for v4 in fronts:
		var v5: Vector3 = v4
		if v5.y > total * 0.3:
			best_t = float(storm["start_h"]) + v5.x
			break
	main.call("set_absolute_hours", best_t)
	await _frames(tree, 40)
	var fr2 := _front(wn, f)
	var si := ChannelProfile.station_index(prof, maxf(fr2.x - 60.0, 0.0))
	var pf := ppts[si]
	var pn := ppts[mini(si + 20, ppts.size() - 1)]
	var gy2 := float(loader.call("ground_height_at", pf.x, pf.y))
	var back := (pf - pn).normalized()
	cam.global_position = Vector3(pf.x + back.x * 25.0, gy2 + 14.0, pf.y + back.y * 25.0)
	cam.look_at(Vector3(pn.x, gy2, pn.y), Vector3.UP)
	await _frames(tree, 30)
	vp.get_texture().get_image().save_png("%s/close_front.png" % _dir)
	print("storm-check: close-ups at +%.0f min (raining) and +%.0f min (front at %.0f m)" % [
		(t_rain - float(storm["start_h"])) * 60.0, (best_t - float(storm["start_h"])) * 60.0, fr2.x])
	main.call("pop_camera_claim", "storm_check")
	cam.queue_free()
	return {"ok": _fails.is_empty(), "failures": _fails}
