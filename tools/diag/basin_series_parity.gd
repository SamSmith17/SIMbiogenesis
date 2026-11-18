extends RefCounted

## Sandbox, read-only: WaterNetwork._refresh_basin_series (per-basin plan,
## written-out arithmetic) against the original loop over _q_at and
## StreamBasins.step_volume, bit for bit, and what each costs.
##   tools\harness.ps1 -World walton -RunScript res://tools/diag/basin_series_parity.gd -Timeout 900
## Scenarios: the world as it is; weather rain forced; a storm over the head
## of every stream with a basin (started 3 h ago, 2 h long); the same with
## "dry between storms". A world with no basins gets a bowl dug across its
## longest stream (sandbox only). Prints one "basin-parity PASS|FAIL" line per
## scenario and the ms per refresh, new and old.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("basin-parity %s: %s" % ["PASS" if cond else "FAIL", what])
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
			and Time.get_ticks_msec() - t0 < 120000:
		await tree.process_frame
	await _frames(tree, 30)


## The loop as it was before the per-basin plan (7b2fbe9).
func _reference(wn: Node) -> void:
	var basins: Dictionary = wn.get("_basins")
	var steps := int(ceil(WaterNetwork.BASIN_HORIZON_H / WaterNetwork.BASIN_STEP_H))
	var t0 := float(wn.get("_hist_now_h")) - WaterNetwork.BASIN_HORIZON_H
	for fid in basins.keys():
		var f: Dictionary = wn.call("feature", str(fid))
		if f.is_empty():
			continue
		for bv in basins[fid]:
			var bd: Dictionary = bv
			bd["t0"] = t0
			bd["full"] = PackedByteArray()
			var vol := PackedFloat32Array()
			var full := PackedByteArray()
			vol.resize(steps + 1)
			full.resize(steps + 1)
			var cap := float(bd["capacity_m3"])
			var stage: PackedVector3Array = bd["stage"]
			var i_in := maxi(int(bd["i0"]) - 1, 0)
			var v := 0.0
			for k in steps + 1:
				var tau := t0 + float(k) * WaterNetwork.BASIN_STEP_H
				if k > 0:
					v = StreamBasins.step_volume(v, float(wn.call("_q_at", f, i_in, tau)),
						WaterNetwork.BASIN_STEP_H, stage, cap)
				vol[k] = v
				full[k] = 1 if v >= cap * 0.995 else 0
			bd["vol"] = vol
			bd["full"] = full


func _snapshot(wn: Node) -> Array:
	var out: Array = []
	var basins: Dictionary = wn.get("_basins")
	for fid in basins.keys():
		for bv in basins[fid]:
			var bd: Dictionary = bv
			out.append([str(fid), int(bd["i0"]), (bd.get("vol", PackedFloat32Array()) as PackedFloat32Array).duplicate(),
				(bd.get("full", PackedByteArray()) as PackedByteArray).duplicate(), float(bd.get("t0", 0.0))])
	return out


func _scenario(wn: Node, label: String) -> void:
	# A fresh rain history at this clock, then the new series.
	wn.set("_hist_now_h", NAN)
	wn.call("_ensure_rain_history")
	var best_new := INF
	for _r in 3:
		var u := Time.get_ticks_usec()
		wn.call("_refresh_basin_series")
		best_new = minf(best_new, float(Time.get_ticks_usec() - u) / 1000.0)
	var a := _snapshot(wn)
	var best_old := INF
	for _r in 2:
		var u2 := Time.get_ticks_usec()
		_reference(wn)
		best_old = minf(best_old, float(Time.get_ticks_usec() - u2) / 1000.0)
	var b := _snapshot(wn)
	var same := a.size() == b.size() and a.size() > 0
	var diff := ""
	var wet := 0
	var spilled := 0
	var vmax := 0.0
	for k in mini(a.size(), b.size()):
		var x: Array = a[k]
		var y: Array = b[k]
		if not (x[2] == y[2] and x[3] == y[3] and x[4] == y[4]):
			same = false
			if diff.is_empty():
				var va: PackedFloat32Array = x[2]
				var vb: PackedFloat32Array = y[2]
				for s in mini(va.size(), vb.size()):
					if va[s] != vb[s]:
						diff = "%s basin at %d differs first at step %d: %.9g vs %.9g" % [x[0], x[1], s, va[s], vb[s]]
						break
				if diff.is_empty():
					diff = "%s basin at %d: full flags differ" % [x[0], x[1]]
		var vv: PackedFloat32Array = x[2]
		for s in vv.size():
			vmax = maxf(vmax, vv[s])
		if vv.size() > 0 and vv[vv.size() - 1] > 0.0:
			wet += 1
		for fl in (x[3] as PackedByteArray):
			if fl == 1:
				spilled += 1
				break
	print("basin-parity: %s — %d basins, %d hold water now, %d spilled in the window, max %.1f m3; new %.2f ms, old %.2f ms" % [
		label, a.size(), wet, spilled, vmax, best_new, best_old])
	_ok(same, "%s: series bit-identical%s" % [label, "" if diff.is_empty() else " (" + diff + ")"])


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var loader: Node = main.find_child("TerrainLoader", true, false)
	if loader == null:
		return {"ok": false, "why": "no TerrainLoader"}
	var wn: Node = loader.call("water_network")
	main.set("time_scale", 0.0)
	await _settle(main, wn)
	var basins: Dictionary = wn.get("_basins")
	if basins.is_empty():
		var feats: Array = wn.call("features")
		if feats.is_empty():
			return {"ok": false, "why": "no streams"}
		var f: Dictionary = feats[0]
		for g in feats:
			if StreamNetwork.polyline_length((g as Dictionary)["points"]) > StreamNetwork.polyline_length(f["points"]):
				f = g
		var prof: Dictionary = (wn.get("_profiles") as Dictionary).get(f["id"], {})
		var ppts: PackedVector2Array = prof["points"]
		var at := ChannelProfile.station_index(prof, 1500.0)
		var c := ppts[at]
		var poly := PackedVector2Array([c + Vector2(-12.5, -12.5), c + Vector2(12.5, -12.5),
			c + Vector2(12.5, 12.5), c + Vector2(-12.5, 12.5)])
		loader.call("pond_command", poly, 1.2, "Parity swale", 0.85, false)
		await _settle(main, wn)
		basins = wn.get("_basins")
	var n := 0
	for fid in basins.keys():
		n += (basins[fid] as Array).size()
	print("basin-parity: %d basins on %d streams" % [n, basins.size()])
	# The rain history: WaterNetwork.rain_mmh_series + history_prefix_values
	# against history_prefix over rain_mmh_at, at a clock every 5 days and 7 h
	# across a year (rainy spells, day boundaries, the time change).
	var now0 := float(wn.call("_now_h"))
	var samples := 330
	var same_hist := true
	var wet_days := 0
	var t_new := 0.0
	var t_old := 0.0
	var first_bad := ""
	for d in 73:
		var t := now0 - float(d) * (5.0 * 24.0 + 7.0)
		var u := Time.get_ticks_usec()
		var pa := StreamRunoff.history_prefix_values(wn.call("rain_mmh_series", t, samples))
		t_new += float(Time.get_ticks_usec() - u) / 1000.0
		u = Time.get_ticks_usec()
		var pb := StreamRunoff.history_prefix(Callable(wn, "rain_mmh_at"), t, samples)
		t_old += float(Time.get_ticks_usec() - u) / 1000.0
		if pa[pa.size() - 1] > 0.0:
			wet_days += 1
		if pa != pb:
			same_hist = false
			if first_bad.is_empty():
				first_bad = " (clock %.2f h: %.9g vs %.9g)" % [t, pa[pa.size() - 1], pb[pb.size() - 1]]
	print("basin-parity: rain history over 73 clocks (%d with rain in the window): new %.2f ms, old %.2f ms each" % [
		wet_days, t_new / 73.0, t_old / 73.0])
	_ok(same_hist, "rain history bit-identical%s" % first_bad)
	if n == 0:
		return {"ok": false, "why": "no basins"}
	_scenario(wn, "as saved")
	wn.set("rain_override_mmh", 30.0)
	_scenario(wn, "weather rain 30 mm/h")
	wn.set("rain_override_mmh", 0.0)
	# A storm over the head of each stream with a basin, upstream of its first.
	var now := float(wn.call("_now_h"))
	for fid in basins.keys():
		var prof2: Dictionary = (wn.get("_profiles") as Dictionary).get(fid, {})
		var pts: PackedVector2Array = prof2.get("points", PackedVector2Array())
		if pts.size() < 3:
			continue
		var i_head := maxi(int(((basins[fid] as Array)[0] as Dictionary)["i0"]) / 3, 0)
		var head := pts[i_head]
		var circle := PackedVector2Array()
		for k in 24:
			var ang := TAU * float(k) / 24.0
			circle.append(head + Vector2(cos(ang), sin(ang)) * 220.0)
		wn.call("add_storm", circle, 60.0, now - 3.0, now - 1.0)
	await _settle(main, wn)
	_scenario(wn, "storms 3 h ago")
	wn.call("set_dry_between_storms", true)
	await _settle(main, wn)
	_scenario(wn, "storms, dry between storms")
	return {"ok": _fails.is_empty(), "failures": _fails}
