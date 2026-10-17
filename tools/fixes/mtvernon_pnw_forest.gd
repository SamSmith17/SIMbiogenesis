extends RefCounted

## Mount Vernon (2026-10-15): a Pacific Northwest lowland forest look, from the
## player's reference photos of the property — second-growth Douglas-fir,
## western red cedar and hemlock with bigleaf maple (and some red alder)
## turning gold in October, a fern-and-blackberry understory, old logging
## stumps and mossy fallen logs.
##
## What it changes, all in THIS world's own files:
##   * the world's vegetation style (vegetation_style_v3_<site>.json):
##     per-species looks for fir / cedar / hemlock / maple / alder / sword
##     fern / blackberry, a gold-orange autumn, the deadwood layer (the
##     player's imported "stump" and "huge_tree_stump" models + procedural
##     logs), and a PNW mix for generated forest if auto vegetation is
##     switched on;
##   * the painted plants (vegetation_<site>.json): every generic pine /
##     spruce / redwood / deciduous record becomes a regional species, in
##     patches (maples group on the slopes), standing where it stood, plus a
##     sword-fern understory and blackberry along the forest edges.
##
## Before anything is touched the current look is snapshotted
## (VegLookBackup): Terrain options → "Earlier vegetation looks" →
## "Before PNW forest look" → Restore puts it all back. Idempotent: run
## twice, the second run finds no generic records and no missing understory.

## The player's imported stumps (user://models/catalog.json). stump_03
## (47k vertices, a 6 m root plate) is left out on purpose: the two used here
## are 2.6k and 12.8k vertices.
const STUMP_MODELS := "user_1792091954_94381,user_1792092586_72037"
const GENERIC := ["pine", "spruce", "redwood", "deciduous"]
const TREE_SPECIES := ["fir", "cedar", "hemlock", "maple", "alder"]


func run(main: Node, _harness: Node) -> Dictionary:
	await main.get_tree().process_frame
	var loader: Node = main.get_node_or_null("TerrainLoader")
	if loader == null:
		return {"ok": false, "why": "no TerrainLoader"}
	var lat := float(loader.get("_lat"))
	var lon := float(loader.get("_lon"))
	var snap := str(loader.call("snapshot_veg_look", "Before PNW forest look"))
	if snap.is_empty():
		return {"ok": false, "why": "could not snapshot the current look"}
	print("mtvernon_pnw_forest: snapshot %s" % snap)

	_write_style(lat, lon)
	VegStyleStore.invalidate_cache()
	loader.set("_veg_style", VegetationStyleConfig.load_merged(lat, lon))

	var layer: VegetationLayer = loader.get("_vegetation_layer")
	if layer == null:
		return {"ok": false, "why": "no painted layer"}
	var settings: Dictionary = loader.call("_auto_veg_runtime_settings")
	var t_now := float(loader.call("_growth_year_now"))
	var excluded: Callable = loader.call("veg_point_excluded_callable")
	var report := _respecies(layer, settings, t_now)
	report.merge(_understory(layer, settings, t_now, excluded))
	layer.save(lat, lon)
	VegetationCardFactory.clear_foot_cache()
	loader.call("_rebuild_all_vegetation")
	for _i in 30:
		await main.get_tree().process_frame
	var dw: Node = main.get_node_or_null("Terrain/" + VegDeadwood.ROOT_NAME)
	var pieces := 0
	if dw != null:
		for c in dw.get_children():
			if c is MultiMeshInstance3D:
				pieces += (c as MultiMeshInstance3D).multimesh.instance_count
	report["deadwood_pieces"] = pieces
	report["snapshot"] = snap
	print("mtvernon_pnw_forest: %s" % JSON.stringify(report))
	return {"ok": pieces > 0 and int(report.get("trees_total", 0)) > 0, "report": report}


# --- style -------------------------------------------------------------------

func _write_style(lat: float, lon: float) -> void:
	var store := VegStyleStore.load_map_store(lat, lon)
	var g: Dictionary = store.get("global", {})
	g[VegDeadwood.KEY_DENSITY] = 5.0
	g[VegDeadwood.KEY_LOG_SHARE] = 0.55
	g[VegDeadwood.KEY_MODELS] = STUMP_MODELS
	g[VegDeadwood.KEY_VIS] = 180.0
	# Bigleaf maple turns gold to burnt orange, hardly ever red.
	g["autumn_warm"] = Color(0.95, 0.84, 0.28)
	g["autumn_orange"] = Color(0.95, 0.71, 0.20)
	g["autumn_hot"] = Color(0.91, 0.56, 0.14)
	# Generated forest (only when auto vegetation is on): woods and parks get
	# the regional mix, scrub becomes bramble.
	g["osm_species_map"] = {"wood": "mixed", "park": "mixed", "scrub": "blackberry"}
	g["mix_pine"] = 0.0
	g["mix_deciduous"] = 0.0
	g["mix_shrub"] = 0.0
	g["local_mix"] = {"fir": 0.40, "cedar": 0.22, "hemlock": 0.12, "maple": 0.18, "alder": 0.08}
	store["global"] = g
	var sp: Dictionary = store.get("species", {})
	# Douglas-fir: the tall one. Long clear bole in a stand, slightly
	# down-swept boughs, dark yellow-green, thick furrowed grey-brown bark.
	sp["fir"] = {"height_m": 38.0, "crown_width_m": 12.5, "trunk_diameter_cm": 105.0,
		"crown_base_pct": 28.0, "droop": 0.2,
		"albedo_tint": Color(0.09, 0.21, 0.10), "bark_tint": Color(0.30, 0.22, 0.16)}
	# Western red cedar: drooping sprays, a broad flared base, lighter
	# yellow-green foliage, fibrous red-grey bark.
	sp["cedar"] = {"height_m": 33.0, "crown_width_m": 13.5, "trunk_diameter_cm": 130.0,
		"crown_base_pct": 8.0, "droop": 0.7,
		"albedo_tint": Color(0.18, 0.31, 0.12), "bark_tint": Color(0.42, 0.27, 0.21)}
	# Hemlock's droop must be set here: this map's own pine-family droop edit
	# (0.13) would otherwise outrank the species' built-in hang.
	sp["hemlock"] = {"height_m": 30.0, "crown_width_m": 10.5, "trunk_diameter_cm": 75.0,
		"crown_base_pct": 18.0, "droop": 0.62}
	# Bigleaf maple: a spreading, often multi-stemmed crown leaning for light,
	# and a trunk furred green with moss (the second reference photo).
	sp["maple"] = {"height_m": 21.0, "crown_width_m": 13.0, "trunk_diameter_cm": 80.0,
		"crown_base_pct": 20.0, "archetype": "round",
		"branchiness": 0.6, "crookedness": 0.62, "droop": 0.22, "foliage_density": 0.66,
		"bark_tint": Color(0.27, 0.32, 0.17)}
	sp["alder"] = {"height_m": 20.0, "crown_width_m": 8.0, "trunk_diameter_cm": 38.0,
		"crown_base_pct": 42.0, "archetype": "round", "crookedness": 0.35}
	# The understory carries none of the shrub family's map edits (that family
	# was tuned huge and sunk 5 m for another purpose).
	sp["blackberry"] = {"bulk_scale": 1.0, "vertical_offset_m": 0.0,
		"cluster_count": 8.0, "cluster_spread": 1.4, "cluster_size": 1.0}
	sp["sword_fern"] = {"vertical_offset_m": 0.0}
	store["species"] = sp
	VegStyleStore._write_store(VegStyleStore.map_v2_path(lat, lon), store)


# --- painted plants ------------------------------------------------------------

## 0..1 hash of a position (same family of hash as VegDeadwood).
static func _h(x: float, z: float, salt: float) -> float:
	return VegDeadwood.hash01(x, z, salt)


## Smooth 0..1 noise on a ~70 m lattice: species come in PATCHES (a maple
## stand on a slope, a cedar grove in a wet hollow), not salt and pepper.
static func _patch(x: float, z: float, salt: float) -> float:
	var cell := 70.0
	var fx := x / cell
	var fz := z / cell
	var ix := floorf(fx)
	var iz := floorf(fz)
	var tx := fx - ix
	var tz := fz - iz
	tx = tx * tx * (3.0 - 2.0 * tx)
	tz = tz * tz * (3.0 - 2.0 * tz)
	var a := _h(ix, iz, salt)
	var b := _h(ix + 1.0, iz, salt)
	var c := _h(ix, iz + 1.0, salt)
	var d := _h(ix + 1.0, iz + 1.0, salt)
	return lerpf(lerpf(a, b, tx), lerpf(c, d, tx), tz)


func _respecies(layer: VegetationLayer, settings: Dictionary, t_now: float) -> Dictionary:
	var counts := {}
	for sid in TREE_SPECIES:
		if not layer.bulk.has(sid):
			layer.bulk[sid] = []
	var moved := 0
	for slot in GENERIC:
		var recs: Array = layer.bulk.get(slot, [])
		for item in recs:
			if not (item is Dictionary):
				continue
			var d: Dictionary = item
			var x := float(d.get("x", 0.0))
			var z := float(d.get("z", 0.0))
			var broad := _patch(x, z, 21.0)
			var sp := ""
			if broad > 0.66 or _h(x, z, 22.0) < 0.05:
				sp = "alder" if _h(x, z, 23.0) < 0.22 else "maple"
			elif slot == "redwood":
				sp = "cedar"   # the few giants painted as redwoods: old cedars
			else:
				# Cedar likes the wet hollows: more of it where its patch noise
				# is high; hemlock fills in under the rest.
				var r := _h(x, z, 24.0)
				var cedar_share := lerpf(0.18, 0.45, _patch(x, z, 25.0))
				if r < cedar_share:
					sp = "cedar"
				elif r < cedar_share + 0.16:
					sp = "hemlock"
				else:
					sp = "fir"
			var nd := d.duplicate(true)
			VegetationGrowth.stamp_established(nd, sp, settings, t_now)
			# A few old-growth veterans the loggers left.
			if (sp == "fir" or sp == "cedar") and _h(x, z, 26.0) < 0.05:
				nd["scale"] = float(nd.get("scale", 1.0)) * 1.4
			(layer.bulk[sp] as Array).append(nd)
			counts[sp] = int(counts.get(sp, 0)) + 1
			moved += 1
		layer.bulk[slot] = []
	var total := 0
	for sid in TREE_SPECIES:
		total += (layer.bulk.get(sid, []) as Array).size()
	return {"respecied": moved, "to": counts, "trees_total": total}


func _understory(layer: VegetationLayer, settings: Dictionary, t_now: float,
		excluded: Callable) -> Dictionary:
	if not (layer.bulk.get("sword_fern", []) as Array).is_empty():
		return {"understory": "already present"}
	# Neighbour grid over every tree, to find the forest EDGE (blackberry).
	var trees: Array = []
	for sid in TREE_SPECIES:
		for r in layer.bulk.get(sid, []):
			trees.append(r)
	var grid := {}
	for r in trees:
		var k := Vector2i(int(floor(float(r["x"]) / 14.0)), int(floor(float(r["z"]) / 14.0)))
		if not grid.has(k):
			grid[k] = 0
		grid[k] = int(grid[k]) + 1
	var ferns: Array = []
	var brambles: Array = []
	for r in trees:
		var x := float(r["x"])
		var z := float(r["z"])
		# Sword fern: one to three per tree, round its foot.
		var n := int(_h(x, z, 31.0) * 3.2)
		for j in n:
			var a := _h(x, z, 40.0 + j) * TAU
			var dist := 1.2 + _h(x, z, 50.0 + j) * 4.0
			var p := Vector2(x + cos(a) * dist, z + sin(a) * dist)
			if excluded.is_valid() and bool(excluded.call(p)):
				continue
			var f := {"x": p.x, "z": p.y, "yaw": _h(x, z, 60.0 + j) * TAU,
				"scale": lerpf(0.7, 1.35, _h(x, z, 70.0 + j))}
			VegetationGrowth.stamp_established(f, "sword_fern", settings, t_now)
			ferns.append(f)
		# Blackberry: where the canopy thins out (a sparse 14 m cell = an edge
		# or a clearing), a thicket or two a few metres out.
		var k := Vector2i(int(floor(x / 14.0)), int(floor(z / 14.0)))
		var around := 0
		for dx in [-1, 0, 1]:
			for dz in [-1, 0, 1]:
				around += int(grid.get(k + Vector2i(dx, dz), 0))
		if around <= 7 and _h(x, z, 80.0) < 0.75:
			for j in 1 + int(_h(x, z, 81.0) * 2.0):
				var a2 := _h(x, z, 90.0 + j) * TAU
				var d2 := 3.0 + _h(x, z, 95.0 + j) * 5.0
				var q := Vector2(x + cos(a2) * d2, z + sin(a2) * d2)
				if excluded.is_valid() and bool(excluded.call(q)):
					continue
				var bb := {"x": q.x, "z": q.y, "yaw": _h(x, z, 99.0 + j) * TAU,
					"scale": lerpf(0.8, 1.4, _h(x, z, 105.0 + j))}
				VegetationGrowth.stamp_established(bb, "blackberry", settings, t_now)
				brambles.append(bb)
	layer.bulk["sword_fern"] = ferns.slice(0, VegetationLayer.MAX_BULK_PER_SPECIES)
	layer.bulk["blackberry"] = brambles.slice(0, VegetationLayer.MAX_BULK_PER_SPECIES)
	return {"ferns": ferns.size(), "blackberry": brambles.size()}
