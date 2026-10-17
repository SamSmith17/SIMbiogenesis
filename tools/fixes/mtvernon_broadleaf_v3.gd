extends RefCounted

## Mount Vernon, third vegetation pass (2026-10-15, the broadleaf rebuild):
## deciduous trees grow leaf SPRAYS on their twigs (VegBroadleafBuilder) and
## every broadleaf species carries its own shape sliders (branchiness,
## crookedness, droop, foliage density) and autumn colours in SPECS.
##
## The player's saved FAMILY-wide deciduous sliders were tuned against the old
## leaf-shell blobs (global store: branchiness 0.35, crookedness 0.41, droop
## 0.14, foliage 0.72). A family value now SHIFTS each species' own value by
## its distance from the default, so those four would push every maple, alder
## and oak off its real habit. Removed here (global + this map's store); the
## family growth_years / variant_seed edits stay. Snapshots the look first
## (Terrain options -> Earlier vegetation looks -> "Before broadleaf rebuild").
## Idempotent.

const MACROS := ["branchiness", "crookedness", "droop", "foliage_density"]


func run(main: Node, _harness: Node) -> Dictionary:
	await main.get_tree().process_frame
	var loader: Node = main.get_node_or_null("TerrainLoader")
	if loader == null:
		return {"ok": false, "why": "no TerrainLoader"}
	var lat := float(loader.get("_lat"))
	var lon := float(loader.get("_lon"))
	var snap := str(loader.call("snapshot_veg_look", "Before broadleaf rebuild"))
	if snap.is_empty():
		return {"ok": false, "why": "snapshot failed"}
	var removed: Array = []
	var g := VegStyleStore.load_global_store()
	removed.append_array(_strip(g, "global"))
	VegStyleStore._write_store(VegStyleStore.global_v2_path(), g)
	var m := VegStyleStore.load_map_store(lat, lon)
	removed.append_array(_strip(m, "map"))
	VegStyleStore._write_store(VegStyleStore.map_v2_path(lat, lon), m)
	VegStyleStore.invalidate_cache()
	loader.set("_veg_style", VegetationStyleConfig.load_merged(lat, lon))
	VegetationCardFactory.clear_foot_cache()
	loader.call("_rebuild_all_vegetation")
	for _i in 20:
		await main.get_tree().process_frame
	print("mtvernon_broadleaf_v3: snapshot %s, removed %s" % [snap, JSON.stringify(removed)])
	return {"ok": true, "snapshot": snap, "removed": removed}


func _strip(store: Dictionary, label: String) -> Array:
	var out: Array = []
	var fam: Dictionary = store.get("family", {})
	if fam.get("deciduous") is Dictionary:
		for k in MACROS:
			if (fam["deciduous"] as Dictionary).erase(k):
				out.append("%s.family.deciduous.%s" % [label, k])
	store["family"] = fam
	var sp: Dictionary = store.get("species", {})
	if sp.get("deciduous") is Dictionary:
		for k in MACROS:
			if (sp["deciduous"] as Dictionary).erase(k):
				out.append("%s.species.deciduous.%s" % [label, k])
	store["species"] = sp
	return out
