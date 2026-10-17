extends RefCounted

## Sandbox: does Tune look show the tree the world draws?
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/tune_look_world_parity.gd
##
## For every tree species the painted layer has near-mesh batches for, opens
## Tune look on that species, builds the preview's NEAR mesh from the editor's
## own merged settings, and compares it with the meshes the world's batches
## actually carry. Height is normalised to the resolved height_m exactly, so a
## setting applied twice shows up there first (the world used to resolve a
## species twice: a family-wide size edit was ratio-scaled twice). Crown width
## is printed; it varies a little between tree variants.


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var loader: Node = main.get_node_or_null("TerrainLoader")
	if loader == null:
		return {"ok": false, "why": "no TerrainLoader"}
	# Painted trees build after the load; wait until near batches exist.
	var world: Dictionary = {}
	var seen: Array = []
	for _w in 40:
		for _i in 15:
			await tree.process_frame
		world = _scan(main, seen)
		if not world.is_empty():
			break
	if world.is_empty():
		return {"ok": false, "why": "no near tree batches found; Bulk nodes: %s" % str(seen.slice(0, 12))}
	var rows: Array = []
	var bad := 0
	for sid in world:
		loader.call("open_vegetation_preview_editor", -1, str(sid))
		for _i in 6:
			await tree.process_frame
		var ed: Node = loader.get("_vegetation_preview_ui")
		if ed == null:
			return {"ok": false, "why": "Tune look did not open"}
		var merged: Dictionary = ed.call("_merged_settings")
		VegAssetCache.clear()
		var pm := VegetationCardFactory.mesh_for_canopy_lod(str(sid), merged,
			VegetationCardFactory.CanopyLodTier.NEAR)
		var psz := pm.get_aabb().size if pm != null else Vector3.ZERO
		var hs: Array = []
		var best := INF
		for s in world[sid]:
			var v: Vector3 = s
			hs.append("%.2f x %.2f" % [v.y, maxf(v.x, v.z)])
			best = minf(best, absf(v.y - psz.y) / maxf(psz.y, 0.01))
		var ok := best < 0.01
		if not ok:
			bad += 1
		var line := "tune_parity %-12s preview h %.2f w %.2f | world h x w: %s  %s" % [
			sid, psz.y, maxf(psz.x, psz.z), ", ".join(hs), "PASS" if ok else "FAIL"]
		print(line)
		rows.append(line)
		if ed.has_method("close"):
			ed.call("close")
		for _i in 4:
			await tree.process_frame
	print("tune_parity: %s (%d species, %d mismatched)" % ["PASS" if bad == 0 else "FAIL",
		world.size(), bad])
	return {"ok": bad == 0, "rows": rows}


func _scan(main: Node, seen: Array) -> Dictionary:
	var world: Dictionary = {}
	seen.clear()
	var stack: Array = [main]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if not (n is MultiMeshInstance3D) or not str(n.name).begins_with("Bulk_"):
			continue
		var mm := (n as MultiMeshInstance3D).multimesh
		seen.append("%s/%d" % [n.name, mm.mesh.get_surface_count() if mm and mm.mesh else -1])
		if "_imp_" in str(n.name):
			continue
		if mm == null or mm.mesh == null or mm.mesh.get_surface_count() < 2:
			continue
		var sid := VegetationRuntime.species_from_bulk_name(str(n.name))
		var fam := VegSpeciesCatalog.mesh_family(sid)
		if fam != "pine" and fam != "deciduous":
			continue
		var list: Array = world.get(sid, [])
		var sz := mm.mesh.get_aabb().size
		if list.find(sz) < 0:
			list.append(sz)
		world[sid] = list
	return world
