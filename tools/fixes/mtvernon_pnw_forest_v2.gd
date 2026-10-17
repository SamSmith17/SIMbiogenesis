extends RefCounted

## Mount Vernon, second PNW pass (2026-10-15, with the real-geometry conifer
## builder, Douglas-fir as its own species, ground / trunk moss and the shared
## mix). Snapshots the look first (Terrain options → Earlier vegetation looks
## → "Before PNW v2").
##
## Style clean-up — the player's saved edits that distort the new species:
##   * GLOBAL store: the family dims (height / crown / trunk / crown base) on
##     pine and deciduous, tuned against the OLD placeholder trees, scale every
##     named species by a ratio (a 166 cm pine trunk made a 3.3 m spruce
##     trunk); the generic pine/deciduous species dims, and the old spruce
##     override. Shape keys the old whorl builder read are left alone.
##   * THIS MAP: the same family dims, and the per-species dims / tints the
##     first PNW pass set (the species defaults now carry real PNW sizes and
##     colours). Understory offsets stay (the map's shrub family is tuned huge
##     and sunk 5 m) and salal / bracken get the same.
##   * Site look: floor moss, trunk moss, deadwood, and the PNW lowland mix as
##     the map's brush mix (`paint_mix`).
## Plants: every painted "fir" becomes "douglas_fir" (the PNW one; "fir" is now
## the true fir), and salal + bracken join the understory round the trees.
## Idempotent.

const FAMILY_DIMS := ["height_m", "crown_width_m", "trunk_diameter_cm", "crown_base_pct"]
const TREE_SPECIES := ["douglas_fir", "cedar", "hemlock", "maple", "alder"]


func run(main: Node, _harness: Node) -> Dictionary:
	await main.get_tree().process_frame
	var loader: Node = main.get_node_or_null("TerrainLoader")
	if loader == null:
		return {"ok": false, "why": "no TerrainLoader"}
	var lat := float(loader.get("_lat"))
	var lon := float(loader.get("_lon"))
	var snap := str(loader.call("snapshot_veg_look", "Before PNW v2 (tree builder)"))
	if snap.is_empty():
		return {"ok": false, "why": "snapshot failed"}
	var report := {"snapshot": snap}
	report["global"] = _clean_global()
	report["map"] = _clean_map(lat, lon)
	VegStyleStore.invalidate_cache()
	loader.set("_veg_style", VegetationStyleConfig.load_merged(lat, lon))

	var layer: VegetationLayer = loader.get("_vegetation_layer")
	var settings: Dictionary = loader.call("_auto_veg_runtime_settings")
	var t_now := float(loader.call("_growth_year_now"))
	var firs: Array = layer.bulk.get("fir", [])
	if not firs.is_empty():
		var df: Array = layer.bulk.get("douglas_fir", [])
		for r in firs:
			var d: Dictionary = (r as Dictionary).duplicate(true)
			VegetationGrowth.stamp_established(d, "douglas_fir", settings, t_now)
			df.append(d)
		layer.bulk["douglas_fir"] = df
		layer.bulk["fir"] = []
	report["douglas_fir"] = (layer.bulk.get("douglas_fir", []) as Array).size()
	report["understory_added"] = _add_understory(layer, settings, t_now,
		loader.call("veg_point_excluded_callable"))
	layer.save(lat, lon)
	VegetationCardFactory.clear_foot_cache()
	loader.call("_rebuild_all_vegetation")
	for _i in 20:
		await main.get_tree().process_frame
	print("mtvernon_pnw_forest_v2: %s" % JSON.stringify(report))
	return {"ok": int(report["douglas_fir"]) > 0, "report": report}


func _clean_global() -> Dictionary:
	var store := VegStyleStore.load_global_store()
	var removed: Array = []
	var fam: Dictionary = store.get("family", {})
	for f in ["pine", "deciduous"]:
		if fam.get(f) is Dictionary:
			for k in FAMILY_DIMS:
				if (fam[f] as Dictionary).erase(k):
					removed.append("family.%s.%s" % [f, k])
	var sp: Dictionary = store.get("species", {})
	for s in ["pine", "deciduous"]:
		if sp.get(s) is Dictionary:
			for k in FAMILY_DIMS:
				if (sp[s] as Dictionary).erase(k):
					removed.append("species.%s.%s" % [s, k])
	if sp.erase("spruce"):
		removed.append("species.spruce")
	store["family"] = fam
	store["species"] = sp
	VegStyleStore._write_store(VegStyleStore.global_v2_path(), store)
	return {"removed": removed}


func _clean_map(lat: float, lon: float) -> Dictionary:
	var store := VegStyleStore.load_map_store(lat, lon)
	var removed: Array = []
	var fam: Dictionary = store.get("family", {})
	for f in ["pine", "deciduous"]:
		if fam.get(f) is Dictionary:
			for k in FAMILY_DIMS:
				if (fam[f] as Dictionary).erase(k):
					removed.append("family.%s.%s" % [f, k])
	store["family"] = fam
	var sp: Dictionary = store.get("species", {})
	for s in ["fir", "cedar", "hemlock", "maple", "alder"]:
		if sp.erase(s):
			removed.append("species.%s" % s)
	# Card sizes too: this map's shrub family carries a 3.25 x 2.4 m card the
	# named shrubs would otherwise be ratio-scaled by.
	sp["salal"] = {"bulk_scale": 1.0, "vertical_offset_m": 0.0, "card_w": 1.8,
		"card_h": 1.0, "cluster_count": 7.0, "cluster_spread": 1.3, "cluster_size": 1.0}
	sp["bracken"] = {"vertical_offset_m": 0.0}
	var bb: Dictionary = sp.get("blackberry", {}) if sp.get("blackberry") is Dictionary else {}
	bb.merge({"bulk_scale": 1.0, "vertical_offset_m": 0.0, "card_w": 2.6, "card_h": 1.5}, true)
	sp["blackberry"] = bb
	store["species"] = sp
	var g: Dictionary = store.get("global", {})
	var mix := VegMix.preset("pnw_lowland")
	g[VegMix.KEY_STYLE] = mix
	g.merge(VegMix.style_extras(mix), true)
	g[VegDeadwood.KEY_MODELS] = "user_1792091954_94381,user_1792092586_72037"
	g["bark_moss_height_m"] = 7.0
	g["local_mix"] = mix["trees"]
	store["global"] = g
	VegStyleStore._write_store(VegStyleStore.map_v2_path(lat, lon), store)
	return {"removed": removed}


## Salal and bracken round the standing trees (the first pass added sword fern
## and blackberry only), placed like the PNW mix places them.
func _add_understory(layer: VegetationLayer, settings: Dictionary, t_now: float,
		excluded: Callable) -> Dictionary:
	var out := {}
	for sid in ["salal", "bracken"]:
		if not (layer.bulk.get(sid, []) as Array).is_empty():
			out[sid] = "already present"
			continue
		var rate := 0.35 if sid == "salal" else 0.15
		var recs: Array = []
		for tid in TREE_SPECIES:
			for r in layer.bulk.get(tid, []):
				var x := float(r["x"])
				var z := float(r["z"])
				var salt := 300.0 if sid == "salal" else 400.0
				if VegDeadwood.hash01(x, z, salt) >= rate:
					continue
				var a := VegDeadwood.hash01(x, z, salt + 1.0) * TAU
				var d := lerpf(1.6, 5.5, VegDeadwood.hash01(x, z, salt + 2.0))
				var p := Vector2(x + cos(a) * d, z + sin(a) * d)
				if excluded.is_valid() and bool(excluded.call(p)):
					continue
				var rec := {"x": p.x, "z": p.y, "yaw": VegDeadwood.hash01(x, z, salt + 3.0) * TAU,
					"scale": lerpf(0.75, 1.3, VegDeadwood.hash01(x, z, salt + 4.0))}
				VegetationGrowth.stamp_established(rec, sid, settings, t_now)
				recs.append(rec)
		layer.bulk[sid] = recs
		out[sid] = recs.size()
	return out
