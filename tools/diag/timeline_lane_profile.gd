extends RefCounted

## Sandbox: what one timeline track redraw costs, lane by lane. Waits for the
## lanes' bins to be made, then forces TL_RUNS redraws (default 30) at 60x and
## times a second pass of the track's draw from inside its draw signal.
## Prints the shown tracks (source / channel / bins), then mean and worst ms
## per span.
##   tools\harness.ps1 -World walton -RunScript res://tools/diag/timeline_lane_profile.gd -Timeout 900

func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	for _i in 300:
		await tree.process_frame
	var pm: Node = main.get_node_or_null("/root/PerfMonitor")
	var tl: Node = main.find_child("TimelineUI", true, false)
	if pm == null or tl == null:
		return {"ok": false, "why": "no PerfMonitor / TimelineUI"}
	main.set("time_scale", 60.0 / 3600.0)
	var t0 := Time.get_ticks_msec()
	while int(tl.call("lane_jobs_pending")) > 0 and Time.get_ticks_msec() - t0 < 60000:
		await tree.process_frame
	for _i in 30:
		await tree.process_frame
	var layout: Object = tl.get("_track_layout")
	var cache: Dictionary = tl.get("_waveform_cache")
	var win: PackedFloat64Array = tl.call("_track_window")
	print("tlprof: window %.1f h; imperial %s" % [win[1], str(tl.call("_weather_imperial"))])
	for t in (layout.call("shown_tracks") as Array):
		var td: Object = t
		var c: Dictionary = cache.get(str(td.get("id")), {})
		var n := int((c.get("bins", {}) as Dictionary).get("n", -1))
		print("tlprof: track %s / %s kind %s h %.0f bins %d" % [str(td.get("source")), str(td.get("channel")),
			str(td.get("kind")), float(td.get("height")), n])
	pm.call("set_enabled", true)
	var track: Control = tl.get("_track")
	var n_runs := int(OS.get_environment("TL_RUNS")) if OS.get_environment("TL_RUNS") != "" else 30
	var tot: Dictionary = {}
	var mx: Dictionary = {}
	var got := [0]
	# Time a second pass of the track's own draw from inside its draw signal
	# (draw calls are only allowed there); the spans are read off
	# PerfMonitor's accumulators before and after it.
	var timed := func() -> void:
		var acc: Dictionary = pm.get("_accum")
		var before := acc.duplicate()
		var u := Time.get_ticks_usec()
		tl.call("_draw_track_inner")
		var whole := float(Time.get_ticks_usec() - u) / 1000.0
		acc = pm.get("_accum")
		tot["(whole track draw)"] = float(tot.get("(whole track draw)", 0.0)) + whole
		mx["(whole track draw)"] = maxf(float(mx.get("(whole track draw)", 0.0)), whole)
		for key in acc.keys():
			if str(key).begins_with("tl_"):
				var d := (float(acc[key]) - float(before.get(key, 0.0))) / 1000.0
				tot[key] = float(tot.get(key, 0.0)) + d
				mx[key] = maxf(float(mx.get(key, 0.0)), d)
		got[0] += 1
	track.draw.connect(timed)
	for k in n_runs:
		track.queue_redraw()
		await tree.process_frame
		await tree.process_frame
	track.draw.disconnect(timed)
	pm.call("set_enabled", false)
	var rows: Array = []
	for key in tot.keys():
		rows.append([float(tot[key]) / maxf(float(got[0]), 1.0), str(key)])
	rows.sort_custom(func(a, b): return a[0] > b[0])
	print("tlprof: %d of %d redraws timed" % [got[0], n_runs])
	for r in rows:
		print("tlprof:   %-44s mean %6.3f ms  worst %6.3f ms" % [r[1], r[0], float(mx[r[1]])])
	return {"ok": got[0] > 0}
