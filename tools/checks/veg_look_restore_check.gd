extends RefCounted

## Sandbox check of the in-game "Restore an earlier vegetation look" path
## (TerrainLoader.snapshot_veg_look / restore_veg_look):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/veg_look_restore_check.gd
## Snapshots the look, wipes one painted species and a style key, restores
## the snapshot through the loader and checks the layer, the style and the
## rebuilt batches all came back.


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var loader: Node = main.get_node_or_null("TerrainLoader")
	var layer: VegetationLayer = loader.get("_vegetation_layer")
	var lat := float(loader.get("_lat"))
	var lon := float(loader.get("_lon"))
	var sid := "fir" if not (layer.bulk.get("fir", []) as Array).is_empty() else "pine"
	var before := (layer.bulk.get(sid, []) as Array).size()
	var style_before := VegStyleStore.load_map_store(lat, lon)
	var snap := str(loader.call("snapshot_veg_look", "restore check"))
	if snap.is_empty():
		return {"ok": false, "why": "snapshot failed"}
	layer.bulk[sid] = []
	layer.save(lat, lon)
	var st := VegStyleStore.load_map_store(lat, lon)
	st["global"] = {}
	VegStyleStore._write_store(VegStyleStore.map_v2_path(lat, lon), st)
	var ok_restore := bool(loader.call("restore_veg_look", snap))
	for _i in 60:
		await tree.process_frame
	var layer2: VegetationLayer = loader.get("_vegetation_layer")
	var after := (layer2.bulk.get(sid, []) as Array).size()
	var style_after := VegStyleStore.load_map_store(lat, lon)
	var batches := 0
	var veg: Node = main.get_node_or_null("Terrain/Vegetation")
	if veg != null:
		for c in veg.get_children():
			if str(c.name).begins_with("Bulk_%s_" % sid):
				batches += 1
	var names: Array = []
	if veg != null:
		for c in veg.get_children():
			if names.size() < 12:
				names.append(str(c.name))
	print("veg_look_restore_check: children %d %s" % [veg.get_child_count() if veg != null else -1, str(names)])
	var listed: Array = loader.call("veg_look_backups")
	var res := {"species": sid, "before": before, "after": after, "restore_ok": ok_restore,
		"style_back": JSON.stringify(style_after.get("global")) == JSON.stringify(style_before.get("global")),
		"batches": batches, "backups_listed": listed.size()}
	print("veg_look_restore_check: %s" % JSON.stringify(res))
	res["ok"] = ok_restore and after == before and bool(res["style_back"]) and batches > 0 \
		and listed.size() >= 2
	return res
