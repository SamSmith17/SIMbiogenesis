extends RefCounted

## Sandbox: WaterNetwork._accumulate_erosion (eroding stations kept per flow
## state, _erosion_rates) against the loop it replaced, bit for bit, and what
## each costs per poll.
##   tools\harness.ps1 -World walton -RunScript res://tools/diag/erosion_parity.gd -Timeout 900
## Scenarios: the world as saved; weather rain forced to 100 mm/h until the
## flow has re-meshed (so stations erode). Prints one "erosion-parity
## PASS|FAIL" line per scenario and ms per poll, old vs new (first poll after
## a re-mesh builds the list; the next ones reuse it).

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("erosion-parity %s: %s" % ["PASS" if cond else "FAIL", what])
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


## The loop before _erosion_rates (c1e6599), writing to a dict instead of the
## layer: {fid: erosion array} for every stream that eroded, and "grew".
func _reference(wn: Node, dt_s: float) -> Dictionary:
	var layer: WaterFeatureLayer = wn.get("layer")
	var out := {}
	var step := ChannelProfile.EROSION_STEP_M
	var grew := 0.0
	var states_all: Dictionary = wn.get("_states")
	var profiles: Dictionary = wn.get("_profiles")
	var ero_cache: Dictionary = wn.get("_ero_cache")
	for f in (wn.call("features") as Array):
		var fid: String = f["id"]
		var states: Array = states_all.get(fid, [])
		var prof: Dictionary = profiles.get(fid, {})
		var s: PackedFloat32Array = prof.get("s", PackedFloat32Array())
		if states.is_empty() or states.size() != s.size() or not bool(f.get("carve", true)):
			continue
		var ec: Dictionary = ero_cache.get(fid, {})
		if ec.is_empty():
			continue
		var slope: PackedFloat32Array = ec["slope"]
		var sec: Dictionary = f["section"]
		var b := float(sec.get("bed_w", 2.0))
		var z := float(sec.get("bank_slope", 1.5))
		var ero := PackedFloat32Array()
		var bins := int(ceil(s[s.size() - 1] / step)) + 1
		var any := false
		for i in (wn.call("_erosion_candidates", fid, states, ec["mask"]) as PackedInt32Array):
			var y := float((states[i] as Dictionary).get("depth_m", 0.0))
			var rate := StreamHydraulics.erosion_rate_mps(StreamHydraulics.bed_shear_pa(b, z, y, slope[i]))
			if rate <= 0.0:
				continue
			if not any:
				any = true
				ero = layer.erosion_of(fid).duplicate()
				if ero.size() < bins:
					var old := ero.size()
					ero.resize(bins)
					for k in range(old, bins):
						ero[k] = 0.0
			var k := clampi(int(round(s[i] / step)), 0, bins - 1)
			var dz := rate * dt_s * (s[i] - s[i - 1]) / step
			var before := ero[k]
			ero[k] = minf(ero[k] + dz, WaterNetwork.EROSION_MAX_M)
			grew = maxf(grew, ero[k] - before)
		if any:
			out[fid] = ero
	out["grew"] = grew
	return out


func _put_back(wn: Node, saved: Dictionary) -> void:
	var layer: WaterFeatureLayer = wn.get("layer")
	layer.erosion = saved.duplicate(true)
	for f in (wn.call("features") as Array):
		var fid: String = (f as Dictionary)["id"]
		if saved.has(fid):
			(f as Dictionary)["erosion"] = saved[fid]
		else:
			(f as Dictionary).erase("erosion")


func _scenario(wn: Node, label: String) -> void:
	var layer: WaterFeatureLayer = wn.get("layer")
	var now := float(wn.call("_now_h"))
	var dt_h := 0.25
	var last := now - dt_h
	var dt_s := (now - last) * 3600.0
	# Make sure every stream's carve facts exist (the poll makes them lazily).
	wn.set("_erosion_last_h", last)
	var saved: Dictionary = layer.erosion.duplicate(true)
	wn.set("_ero_rates", {})
	wn.call("_accumulate_erosion")
	_put_back(wn, saved)
	# The old loop.
	var best_old := INF
	var ref := {}
	for _r in 3:
		var u := Time.get_ticks_usec()
		ref = _reference(wn, dt_s)
		best_old = minf(best_old, float(Time.get_ticks_usec() - u) / 1000.0)
	# The new one: first poll (builds the lists), then warm polls.
	wn.set("_ero_rates", {})
	wn.set("_erosion_last_h", last)
	var u1 := Time.get_ticks_usec()
	wn.call("_accumulate_erosion")
	var t_first := float(Time.get_ticks_usec() - u1) / 1000.0
	var got: Dictionary = layer.erosion.duplicate(true)
	_put_back(wn, saved)
	var best_warm := INF
	for _r in 3:
		wn.set("_erosion_last_h", last)
		var u2 := Time.get_ticks_usec()
		wn.call("_accumulate_erosion")
		best_warm = minf(best_warm, float(Time.get_ticks_usec() - u2) / 1000.0)
		var again: Dictionary = layer.erosion.duplicate(true)
		_put_back(wn, saved)
		if again != got:
			_ok(false, "%s: a warm poll gave the same cut as the first" % label)
	var same := true
	var why := ""
	var eroding := 0
	for fid in ref.keys():
		if str(fid) == "grew":
			continue
		eroding += 1
		if not got.has(fid) or (got[fid] as PackedFloat32Array) != (ref[fid] as PackedFloat32Array):
			same = false
			if why.is_empty():
				why = " (%s differs)" % str(fid)
	for fid in got.keys():
		if not ref.has(fid) and (not saved.has(fid) or (saved[fid] as PackedFloat32Array) != (got[fid] as PackedFloat32Array)):
			same = false
			if why.is_empty():
				why = " (%s eroded only in the new loop)" % str(fid)
	var stations := 0
	var wet := 0
	for f in (wn.call("features") as Array):
		var st: Array = (wn.get("_states") as Dictionary).get((f as Dictionary)["id"], [])
		stations += st.size()
		for d in st:
			if float((d as Dictionary).get("depth_m", 0.0)) >= 0.02:
				wet += 1
	var max_cut := 0.0
	for fid in got.keys():
		for v in (got[fid] as PackedFloat32Array):
			max_cut = maxf(max_cut, v)
	print("erosion-parity: %s — %d stations, %d wet, %d streams eroding, deepest cut %.4f m; old %.2f ms, new first %.2f ms, new warm %.3f ms" % [
		label, stations, wet, eroding, max_cut, best_old, t_first, best_warm])
	_ok(same, "%s: erosion bit-identical%s" % [label, why])


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var loader: Node = main.find_child("TerrainLoader", true, false)
	if loader == null:
		return {"ok": false, "why": "no TerrainLoader"}
	var wn: Node = loader.call("water_network")
	main.set("time_scale", 0.0)
	await _settle(main, wn)
	_scenario(wn, "as saved")
	# Heavy rain until the flow re-meshes with deeper water.
	var states_before: Dictionary = wn.get("_states")
	wn.set("rain_override_mmh", 100.0)
	wn.set("_hist_now_h", NAN)
	wn.set("_hyd_t", 0.0)
	var t0 := Time.get_ticks_msec()
	while is_same(wn.get("_states"), states_before) and Time.get_ticks_msec() - t0 < 60000:
		await tree.process_frame
	await _frames(tree, 120)
	_scenario(wn, "rain 100 mm/h")
	wn.set("rain_override_mmh", -1.0)
	return {"ok": _fails.is_empty(), "failures": _fails}
