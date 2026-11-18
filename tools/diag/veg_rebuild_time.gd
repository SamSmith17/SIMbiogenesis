extends RefCounted

## Sandbox: how long a full rebuild of the painted vegetation layer takes
## (the same call three times, after the world has loaded).
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/diag/veg_rebuild_time.gd


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var loader: Node = main.get_node_or_null("TerrainLoader")
	if loader == null:
		return {"ok": false, "why": "no TerrainLoader"}
	for _i in 300:
		await tree.process_frame
	var terrain := main.get_node_or_null("Terrain") as Node3D
	var layer: VegetationLayer = loader.get("_vegetation_layer")
	if terrain == null or layer == null:
		return {"ok": false, "why": "no painted layer"}
	var settings: Dictionary = loader.call("_auto_veg_runtime_settings")
	var ground := Callable(loader, "ground_height_at")
	var times: Array = []
	for _r in 3:
		var t0 := Time.get_ticks_usec()
		VegetationRuntime.rebuild(terrain, layer, ground, false, settings)
		times.append(float(Time.get_ticks_usec() - t0) / 1000.0)
		for _i in 30:
			await tree.process_frame
	var root := terrain.get_node_or_null("Vegetation")
	var n := root.get_child_count() if root != null else 0
	print("vegrebuild ms %s  batches %d" % [str(times), n])
	return {"ok": true}
