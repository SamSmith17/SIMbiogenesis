extends RefCounted

## What a camp of living vehicles costs a frame (transport polish Phase 5).
##
## Sandbox, Walton (festival mode for the people):
##   tools\harness.ps1 -World walton -RunScript res://tools/bench/vehicle_site_bench.gd -Timeout 1500
##
## Places VEHICLES preset vehicles round the painted camps, loads a kit into
## every one with a cargo bay, then samples:
##   idle   — all parked, nothing scheduled, 1x (the cost of standing there);
##   1x / 60x / 450x — through an arrival window (every vehicle driving in
##   through the gate, a few seconds apart).
## Prints `vsbench …` lines: frame median / peak, the vehicle sections
## (vehicle_drive, vehicle_cargo, forklift, npc_beds, prop_rev) beside
## prop_ticks / npc_population / site_deploy / npc_host / crowd_render, draw
## calls, how often the bridge's prop revision moved and how many
## VehicleDesign solves were asked for and computed per second.

const VEHICLES := 40
const SAMPLE_S := 8.0
const QUICK_ENV := "VSB_QUICK"
const SAMPLE_DT := 0.1
const PRESETS := ["van", "cargo_van", "shuttle_bus", "school_bus", "step_van", "rv", "box_truck", "ambulance"]
const SECTIONS: Array[String] = ["vehicle_drive", "vehicle_cargo", "forklift", "npc_beds", "prop_rev",
	"prop_ticks", "npc_population", "site_deploy", "npc_host", "crowd_render", "flow_engine"]


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	await tree.process_frame
	var pm: Node = main.get_node_or_null("/root/PerfMonitor")
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	var sgv := ServiceLocator.graph()
	if pm == null or loader == null or sgv == null:
		return {"ok": false, "why": "no PerfMonitor / loader / graph"}
	main.set("time_scale", 0.0)
	var day0: float = floor(float(main.call("get_absolute_hours")) / 24.0) * 24.0
	main.call("set_absolute_hours", day0 + 12.0)
	if main.has_method("open_festival_mode"):
		main.call("open_festival_mode")
		for _i in 240:
			await tree.process_frame
		if main.has_method("close_settlement_view"):
			main.call("close_settlement_view")
	await _wait(tree, 3.0)
	# The festival alone first: what the vehicles add is the difference.
	pm.call("set_enabled", true)
	main.set("time_scale", 1.0 / 3600.0)
	await _wait(tree, 2.0)
	_print("festival only", await _sample(tree, pm, sgv))
	main.set("time_scale", 0.0)
	# Vehicles round the camps.
	var place_ms := 0
	var stow_ms := 0
	var tag_ms := 0
	var areas: Array = loader.get("camp_areas").get("areas") if loader.get("camp_areas") != null else []
	var t0 := Time.get_ticks_msec()
	var placed := 0
	var crates := 0
	for k in VEHICLES:
		var c := Vector2.ZERO
		if not areas.is_empty():
			var poly: PackedVector2Array = (areas[k % areas.size()] as Dictionary).get("polygon", PackedVector2Array())
			for p in poly:
				c += p
			c /= maxf(float(poly.size()), 1.0)
		c += Vector2(float((k / areas.size()) if not areas.is_empty() else k) * 9.0 - 9.0, 12.0)
		var preset := str(PRESETS[k % PRESETS.size()])
		var ta := Time.get_ticks_usec()
		var vid := PlacedPropService.place_prepped_at(main, VehicleBuilder.MODEL_ID,
			{"record_extra": {"vehicle_spec": VehicleSpec.to_json_safe(VehiclePresets.builtin(preset)),
				"collision_enabled": true}}, c.x, c.y, float((k * 37) % 360))
		place_ms += (Time.get_ticks_usec() - ta) / 1000
		if vid.is_empty():
			continue
		# How much of a placement is the vehicle's spaces + graph node.
		var tb := Time.get_ticks_usec()
		PlacedPropService.sync_vehicle_graph(main, vid)
		tag_ms += (Time.get_ticks_usec() - tb) / 1000
		var tc := Time.get_ticks_usec()
		placed += 1
		# Stowed straight in (no unload queued): the bench measures the
		# vehicles and their cargo, not 40 crews unloading at once.
		var res: Dictionary = VehicleCargo.spawn_into(loader.get("_placed_prop_layer"), "starter_camp", vid,
			float(main.call("get_absolute_hours")))
		crates += (res.get("crate_ids", []) as Array).size()
		loader.call("_show_props", res.get("crate_ids", []))
		stow_ms += (Time.get_ticks_usec() - tc) / 1000
	print("vsbench: placed %d vehicles, %d crates stowed, in %d ms (placing %d ms, of which a second graph sync %d ms; stowing %d ms)" % [
		placed, crates, Time.get_ticks_msec() - t0, place_ms, tag_ms, stow_ms])
	await _wait(tree, 4.0)
	pm.call("set_enabled", true)
	main.set("time_scale", 1.0 / 3600.0)
	await _wait(tree, 2.0)
	_print("idle", await _sample(tree, pm, sgv))
	if not OS.get_environment(QUICK_ENV).is_empty():
		pm.call("set_enabled", false)
		main.set("time_scale", 0.0)
		return {"ok": true}
	# Every vehicle drives in, 20 s apart, from a minute from now.
	var now := float(main.call("get_absolute_hours"))
	var n := int(loader.call("schedule_vehicle_arrivals", now + 1.0 / 60.0, 20.0 / 3600.0))
	print("vsbench: %d arrivals scheduled" % n)
	main.call("set_absolute_hours", now + 1.5 / 60.0)
	main.set("time_scale", 1.0 / 3600.0)
	await _wait(tree, 2.0)
	_print("1x", await _sample(tree, pm, sgv))
	main.set("time_scale", 60.0 / 3600.0)
	await _wait(tree, 2.0)
	_print("60x", await _sample(tree, pm, sgv))
	main.call("set_absolute_hours", now + 1.5 / 60.0)
	main.set("time_scale", 450.0 / 3600.0)
	await _wait(tree, 1.0)
	_print("450x", await _sample(tree, pm, sgv))
	main.set("time_scale", 0.0)
	pm.call("set_enabled", false)
	loader.call("clear_vehicle_arrivals")
	return {"ok": true}


func _sample(tree: SceneTree, pm: Node, sgv: Node) -> Dictionary:
	var bridge: Object = sgv.get("_npc_population")
	var rev0 := int(bridge.get("prop_rev_changes")) if bridge != null else 0
	var calls0 := VehicleDesign.solve_calls
	var miss0 := VehicleDesign.solve_misses
	var acc := {}
	var peak := {}
	var frames: Array = []
	var frame_peak := 0.0
	var draws := 0.0
	var n := int(SAMPLE_S / SAMPLE_DT)
	for i in n:
		await _wait(tree, SAMPLE_DT)
		var snap: Dictionary = pm.call("snapshot")
		var sec: Dictionary = snap.get("sections_ms", {})
		var pk: Dictionary = snap.get("sections_peak_ms", {})
		for s in sec.keys():
			acc[s] = float(acc.get(s, 0.0)) + float(sec[s])
			peak[s] = maxf(float(peak.get(s, 0.0)), float(pk.get(s, 0.0)))
		frames.append(float(snap.get("frame_ms", 0.0)))
		frame_peak = maxf(frame_peak, float(snap.get("frame_ms_peak", 0.0)))
		draws += float((snap.get("render", {}) as Dictionary).get("draw_calls", 0.0))
	frames.sort()
	for s in acc.keys():
		acc[s] = float(acc[s]) / float(n)
	return {"acc": acc, "peak": peak, "frame": frames[frames.size() / 2], "frame_peak": frame_peak,
		"draws": draws / float(n),
		"rev_per_s": float((int(bridge.get("prop_rev_changes")) if bridge != null else 0) - rev0) / SAMPLE_S,
		"solves_per_s": float(VehicleDesign.solve_calls - calls0) / SAMPLE_S,
		"misses_per_s": float(VehicleDesign.solve_misses - miss0) / SAMPLE_S}


func _print(label: String, s: Dictionary) -> void:
	print("vsbench %s: frame %.1f ms (median) / %.1f ms (peak) · %.0f draw calls · prop rev %.1f/s · design solves %.0f/s (%.1f computed)" % [
		label, float(s["frame"]), float(s["frame_peak"]), float(s["draws"]), float(s["rev_per_s"]),
		float(s["solves_per_s"]), float(s["misses_per_s"])])
	var acc: Dictionary = s["acc"]
	var peak: Dictionary = s["peak"]
	var shown := {}
	for key in SECTIONS:
		if acc.has(key):
			shown[key] = true
			print("vsbench %s: %-16s avg %6.2f ms · peak %6.2f ms" % [label, key, float(acc[key]), float(peak[key])])
	for key in acc.keys():
		if not shown.has(key) and float(acc[key]) >= 0.5:
			print("vsbench %s: %-16s avg %6.2f ms · peak %6.2f ms" % [label, str(key), float(acc[key]), float(peak[key])])


func _wait(tree: SceneTree, s: float) -> void:
	await tree.create_timer(s, true, false, true).timeout
