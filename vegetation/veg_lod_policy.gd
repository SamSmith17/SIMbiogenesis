class_name VegLodPolicy
extends RefCounted

## Vegetation Overhaul v2: budget-aware tree detail distance.
##
## The LOD model is "real 3D mesh within a camera-based detail range, baked
## impostor beyond". The range the player ASKS for (tree_detail_distance_m)
## must be affordable on any map: a dense 30 km forest with a 400 m range
## would put tens of thousands of ~6k-tri meshes in the potential near set —
## exactly the prim bomb the old force_far flattening existed to prevent (by
## never showing a real tree at all). Instead of flattening, SHRINK the
## effective range until the worst-case count of full-mesh trees around any
## single viewpoint fits the quality tier's budget.
##
## Deterministic and cheap: counts are aggregated per 256 m chunk once per
## rebuild; the worst-case near set for a viewpoint in chunk C is the sum of
## records in every chunk whose centre lies within (range + chunk diagonal)
## of C's centre. O(chunks²) with a few hundred chunks.

const MIN_DETAIL_M := 60.0
const SHRINK_STEP := 0.85

## --- Configurable LOD ladder (Overhaul v2.1) --------------------------------
## The player picks the ORDER of tree representations per species and may
## disable any: "mesh,impostor" (the default = the shipped two-band model),
## "photocard" alone (texture card at ALL distances), "mesh,photocard,
## impostor", … Style key: `<family>_detail_chain` — family-prefixed so it
## rides the per-species override ladder AND lands in the impostor bake key
## (the baked silhouette must follow the nearest representation). It is
## deliberately NOT named `<family>_lod_chain`: VegImpostorBaker.bake_key
## excludes any key containing "_lod_" as a LOD-reach key, which would
## silently drop the chain from the bake key and serve a stale silhouette.
const REP_MESH := "mesh"
const REP_PHOTOCARD := "photocard"
const REP_IMPOSTOR := "impostor"
const DEFAULT_CHAIN := "mesh,impostor"
const REPS: Array = [REP_MESH, REP_PHOTOCARD, REP_IMPOSTOR]


## Runtime settings key (injected by TerrainLoader._auto_veg_runtime_settings,
## never persisted): where the cheap FAR tier (impostor / photocard) stops,
## when that is further than the style's cull end. The Globe lens and the
## snowglobe orbit up to 4.5 x the SoI radius out, and visibility range is
## measured to each 256 m chunk's centre, so a far tier that stopped at the
## first-person cull end (480 m on large maps) blinked whole chunks of forest
## in and out as the camera orbited. Unprefixed on purpose: the impostor
## bake key only hashes family-prefixed keys, so a radius change never
## re-bakes the atlas.
const KEY_FAR_TIER_END := "far_tier_end_m"

## Fade band at a LOD handoff, as a share of the handoff distance. A fixed
## 24 m band is crossed by ONE wheel notch of the orbit lenses (6 % of ~400 m)
## and so never seen as a fade; scaling it keeps the dither visible at range.
const FADE_SHARE := 0.12
const MIN_FADE_M := 24.0
const MAX_FADE_M := 140.0


static func fade_margin_for(distance_m: float) -> float:
	return clampf(distance_m * FADE_SHARE, MIN_FADE_M, MAX_FADE_M)


## Where a chain's LAST band ends: the far tier may reach past the cull end
## (KEY_FAR_TIER_END) because it costs two triangles a tree; a chain that
## ends in the full mesh keeps the cull end — that tier is the prim budget.
static func far_tier_end(chain: Array, cull_end_m: float, settings: Dictionary) -> float:
	if chain.is_empty() or cull_end_m <= 0.0:
		return cull_end_m
	if str(chain[chain.size() - 1]) == REP_MESH:
		return cull_end_m
	return maxf(cull_end_m, float(settings.get(KEY_FAR_TIER_END, 0.0)))


## Parse + validate a chain string ("mesh,photocard,impostor"). Unknown
## tokens are dropped, duplicates keep their first position, empty/invalid
## input falls back to the default chain. Always returns ≥1 entry.
static func parse_chain(raw: String) -> Array:
	var out: Array = []
	for tok in raw.to_lower().split(","):
		var t := str(tok).strip_edges()
		if t in REPS and not (t in out):
			out.append(t)
	if out.is_empty():
		for tok in DEFAULT_CHAIN.split(","):
			out.append(str(tok))
	return out


## Distance bands for a chain: [{rep, begin_m, end_m}] tiling 0..cull_end_m.
## Interior boundaries come from the two distance knobs — after band 0 the
## (budget-shrunk) detail distance, after band 1 the photocard distance
## (forced past the first boundary). Boundaries are clamped monotonic; the
## LAST band always extends to the cull end; zero-width bands are dropped
## (e.g. detail ≥ cull collapses a 2-band chain to a single full-range band,
## matching the old single-batch special case).
static func chain_bands(chain: Array, detail_m: float, photocard_m: float,
		cull_end_m: float) -> Array:
	var n := chain.size()
	var bands: Array = []
	if n == 0 or cull_end_m <= 0.0:
		return bands
	var bounds: Array = []
	if n >= 2:
		bounds.append(detail_m)
	if n >= 3:
		bounds.append(maxf(photocard_m, detail_m + 40.0))
	var prev := 0.0
	for i in bounds.size():
		var b := clampf(float(bounds[i]), prev + 1.0, cull_end_m)
		bounds[i] = b
		prev = b
	var begin := 0.0
	for i in n:
		var end: float = cull_end_m if i >= bounds.size() or i == n - 1 \
				else float(bounds[i])
		if end > begin + 1.0:
			bands.append({"rep": str(chain[i]), "begin_m": begin, "end_m": end})
			begin = end
	return bands


## chunk_counts: {Vector2i chunk coord -> int tree records}. Returns the
## largest distance ≤ requested_m whose worst-case near-set count fits the
## budget (never below MIN_DETAIL_M).
static func effective_detail_distance(chunk_counts: Dictionary, requested_m: float,
		budget: int, chunk_size_m: float = 256.0) -> float:
	if chunk_counts.is_empty() or budget <= 0:
		return requested_m
	var centers: Array[Vector2] = []
	var counts: Array[int] = []
	for key in chunk_counts:
		var c: Vector2i = key
		centers.append((Vector2(c) + Vector2(0.5, 0.5)) * chunk_size_m)
		counts.append(int(chunk_counts[key]))
	var d := maxf(requested_m, MIN_DETAIL_M)
	var diag := chunk_size_m * 1.42
	while d > MIN_DETAIL_M:
		var worst := 0
		var reach := d + diag
		var reach2 := reach * reach
		for i in centers.size():
			var total := 0
			for j in centers.size():
				if centers[i].distance_squared_to(centers[j]) <= reach2:
					total += counts[j]
			worst = maxi(worst, total)
			if worst > budget:
				break
		if worst <= budget:
			return d
		d *= SHRINK_STEP
	return MIN_DETAIL_M


## Convenience: aggregate per-chunk tree-record counts from one or more layer
## `bulk` dictionaries (species slot -> record array). Only tree families
## count — grass/shrub never build the expensive NEAR mesh.
static func chunk_tree_counts(bulks: Array, chunk_size_m: float = 256.0) -> Dictionary:
	var out := {}
	for bulk in bulks:
		if not (bulk is Dictionary):
			continue
		for slot in (bulk as Dictionary):
			var fam := VegSpeciesCatalog.mesh_family(str(slot))
			if fam != "deciduous" and fam != "pine":
				continue
			for item in (bulk as Dictionary)[slot]:
				if not (item is Dictionary):
					continue
				var d: Dictionary = item
				var key := Vector2i(
					int(floor(float(d.get("x", 0.0)) / chunk_size_m)),
					int(floor(float(d.get("z", 0.0)) / chunk_size_m)))
				out[key] = int(out.get(key, 0)) + 1
	return out
