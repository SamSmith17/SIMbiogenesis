extends RefCounted

## A large storm deepens the channel it floods (sandbox):
##   tools\harness.ps1 -World <id> -RunScript res://tools/checks/stream_erosion_check.gd
## 100 mm/h for an hour over a 400 m circle at the head of the longest stream,
## the clock run forward (erosion only accrues while it runs), then: the layer
## holds a cut, the channel was re-carved, and the carved bed is lower where it
## cut most. Ends with Reset erosion and checks the bed came back.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("erosion-check %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _idle(main: Node, wn: Node) -> void:
	var tree := main.get_tree()
	for _i in 20:
		await tree.process_frame
	var t0 := Time.get_ticks_msec()
	while (bool(wn.call("is_busy")) or bool(wn.get("_rebuild_pending")) or bool(wn.get("_drain_pending"))
			or int(wn.get("_drain_task")) >= 0) and Time.get_ticks_msec() - t0 < 90000:
		await tree.process_frame
	for _i in 20:
		await tree.process_frame


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var loader: Node = main.find_child("TerrainLoader", true, false)
	var wn: Node = loader.call("water_network")
	wn.call("set_dry_between_storms", true)
	# A known start whatever the saved world holds: the beds as drawn (no
	# saved flood cuts) and no weather rain (the clock may sit in a storm).
	wn.set("rain_override_mmh", 0.0)
	wn.call("reset_erosion")
	main.set("time_scale", 0.0)
	main.set("day_time", 12.0)
	await _idle(main, wn)
	var feats: Array = wn.call("features")
	var f: Dictionary = feats[0]
	for g in feats:
		if StreamNetwork.polyline_length((g as Dictionary)["points"]) > StreamNetwork.polyline_length(f["points"]):
			f = g
	var fid := str(f["id"])
	var prof0: Dictionary = wn.call("profile", fid)
	var bed0: PackedFloat32Array = (prof0["bed"] as PackedFloat32Array).duplicate()
	var s0: PackedFloat32Array = (prof0["s"] as PackedFloat32Array).duplicate()
	var ppts: PackedVector2Array = prof0["points"]
	var head := ppts[mini(ppts.size() - 1, int(ppts.size() * 0.08))]
	var circle := PackedVector2Array()
	for k in 32:
		var a := TAU * float(k) / 32.0
		circle.append(head + Vector2(cos(a), sin(a)) * 400.0)
	var t_start := float(wn.call("_now_h"))
	wn.call("add_storm", circle, 100.0, t_start, t_start + 1.0)
	await _idle(main, wn)
	# Run the clock forward: 20 sim-minutes a second for ~5 sim-hours.
	main.set("time_scale", 20.0 / 60.0)
	var t_real := Time.get_ticks_msec()
	while float(wn.call("_now_h")) < t_start + 5.0 and Time.get_ticks_msec() - t_real < 60000:
		await tree.process_frame
	main.set("time_scale", 0.0)
	await _idle(main, wn)
	var lay: WaterFeatureLayer = wn.get("layer")
	var ero := lay.erosion_of(fid)
	var deepest := 0.0
	var dk := 0
	for k in ero.size():
		if ero[k] > deepest:
			deepest = ero[k]
			dk = k
	var s_at := float(dk) * ChannelProfile.EROSION_STEP_M
	print("erosion-check: %s cut up to %.2f m at %.0f m" % [fid, deepest, s_at])
	_ok(deepest >= 0.05, "a large storm cut the bed at least 5 cm (%.2f m)" % deepest)
	var prof1: Dictionary = wn.call("profile", fid)
	var drop := bed0[ChannelProfile.station_index({"s": s0}, s_at)] \
		- (prof1["bed"] as PackedFloat32Array)[ChannelProfile.station_index(prof1, s_at)]
	print("erosion-check: carved bed at %.0f m dropped %.2f m" % [s_at, drop])
	_ok(drop >= deepest * 0.5, "the channel was re-carved deeper there")
	_ok(ChannelProfile.is_monotone(prof1["bed"]), "the eroded bed still runs downhill")
	var file := FileAccess.get_file_as_string(str(wn.call("layer_path")))
	_ok(file.contains("\"erosion\"") and file.contains(fid), "the cut is saved with the map")
	wn.call("reset_erosion")
	await _idle(main, wn)
	var prof2: Dictionary = wn.call("profile", fid)
	var back := (prof2["bed"] as PackedFloat32Array)[ChannelProfile.station_index(prof2, s_at)] \
		- bed0[ChannelProfile.station_index({"s": s0}, s_at)]
	_ok(absf(back) < 0.02, "Reset erosion fills the channel back (%.3f m)" % back)
	return {"ok": _fails.is_empty(), "failures": _fails}
