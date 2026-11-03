extends RefCounted

## Where the time goes when a living vehicle is placed, and what its graph
## node costs SolarUI afterwards (sandbox):
##   tools\harness.ps1 -World walton -RunScript res://tools/diag/vehicle_place_cost_probe.gd
## Places N vehicles step by step (record, node, spaces, graph node, timed
## apart) and prints `vpprobe …` lines, then samples the solar_ui sub-spans
## for a few seconds.

const N := 12
const PRESETS := ["van", "cargo_van", "shuttle_bus", "school_bus", "step_van", "rv", "box_truck", "ambulance"]


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	await tree.process_frame
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	var layer: PlacedPropLayer = loader.get("_placed_prop_layer")
	var pm: Node = main.get_node_or_null("/root/PerfMonitor")
	var sgv := ServiceLocator.graph()
	main.set("time_scale", 0.0)
	var player := main.get_node_or_null("Player") as Node3D
	var p0 := Vector2(player.global_position.x, player.global_position.z)
	var gy_fn := TerrainSurfaceQuery.ground_y_callable(main)
	var parent: Node = PlacedPropService._props_parent(main)
	var tot := {"record": 0, "node": 0, "spaces": 0, "graph": 0, "save": 0}
	var items0: int = sgv.get("model").call("get_items_in_scope", "root").size() if sgv != null else 0
	for k in N:
		var at := p0 + Vector2(20.0 + float(k % 4) * 10.0, float(k / 4) * 12.0)
		var t := Time.get_ticks_usec()
		var vid := layer.add_free_prop(VehicleBuilder.MODEL_ID, at.x, 0.0, at.y, 0.0, 0.0, 0.0, 1.0,
			TerrainSurfaceQuery.ground_height_at(main, at.x, at.y))
		layer.update_prop(vid, {"vehicle_spec": VehicleSpec.to_json_safe(VehiclePresets.builtin(str(PRESETS[k % PRESETS.size()]))),
			"collision_enabled": true})
		tot["record"] += Time.get_ticks_usec() - t
		t = Time.get_ticks_usec()
		PlacedPropService._save_layer(main, layer)
		tot["save"] += Time.get_ticks_usec() - t
		t = Time.get_ticks_usec()
		PlacedPropRuntime.add_one(parent, layer.find_by_id(vid), gy_fn)
		tot["node"] += Time.get_ticks_usec() - t
		t = Time.get_ticks_usec()
		PlacedPropService.sync_vehicle_graph(main, vid)
		tot["graph"] += Time.get_ticks_usec() - t
		t = Time.get_ticks_usec()
		PlacedPropService.tag_vehicle_spaces(main, vid)
		tot["spaces"] += Time.get_ticks_usec() - t
		await tree.process_frame
	var items1: int = sgv.get("model").call("get_items_in_scope", "root").size() if sgv != null else 0
	for key in tot:
		print("vpprobe: %-7s %.1f ms a vehicle" % [key, float(tot[key]) / 1000.0 / float(N)])
	print("vpprobe: root graph items %d -> %d" % [items0, items1])
	if pm == null:
		return {"ok": true}
	pm.call("set_enabled", true)
	main.set("time_scale", 60.0 / 3600.0)
	var acc := {}
	var peak := {}
	for i in 60:
		await tree.create_timer(0.1, true, false, true).timeout
		var snap: Dictionary = pm.call("snapshot")
		for s in (snap.get("sections_ms", {}) as Dictionary).keys():
			acc[s] = float(acc.get(s, 0.0)) + float(snap["sections_ms"][s]) / 60.0
			peak[s] = maxf(float(peak.get(s, 0.0)), float((snap.get("sections_peak_ms", {}) as Dictionary).get(s, 0.0)))
	for s in acc.keys():
		if float(acc[s]) >= 0.3 or str(s).begins_with("sui_") or str(s) == "solar_ui":
			print("vpprobe: %-16s avg %7.2f ms · peak %8.2f ms" % [str(s), float(acc[s]), float(peak[s])])
	pm.call("set_enabled", false)
	main.set("time_scale", 0.0)
	return {"ok": true}
