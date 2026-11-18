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
## single viewpoint fits the quality tier's budget (measured_detail_distance).

const MIN_DETAIL_M := 60.0

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


## --- The detail budget ------------------------------------------------------
## The detail distance is the largest distance <= the requested one at which
## no viewpoint has more than `budget` full-mesh trees within it. MEASURED:
## the trees the distance controls are binned on a fine grid, and for every
## occupied cell the trees whose cell centre lies within the distance of its
## centre are counted (a disc, row by row through a summed-area table; a
## square round the disc rules most cells out first). Deterministic.
##
## What it replaced (2026-11-17) summed whole 256 m chunks out to the distance
## plus 363 m, and counted species drawn as full meshes at every distance,
## which the distance does not touch. On Mount Vernon that read the budget of
## 400 as spent at 60 m, where the real worst case was 202 trees (89 of them
## species the distance controls), and floored the distance there; measured,
## it is 168 m, for the same average GPU time.

const BUDGET_CELL_M := 16.0
## The grid covers the trees' bounding box; its cell doubles until it fits.
const BUDGET_MAX_CELLS := 262144
## The answer is a multiple of this: the distance rides the settings dict,
## which is the mesh cache key, so it should not move with every tree painted.
const BUDGET_STEP_M := 10.0
const _KEY_SHIFT := 4194304


## Does the detail distance decide where this species' full mesh ends? Not
## for a chain that does not start with the mesh, a mesh-only chain, or a
## style with the LOD handoff off: those draw the same at any distance.
static func detail_controls(species: String, settings: Dictionary) -> bool:
	var fam := VegSpeciesCatalog.mesh_family(species)
	if fam != "deciduous" and fam != "pine":
		return false
	var bs := VegSpeciesCatalog.settings_with_variant(species, settings,
		VegetationCardFactory.SPECS)
	if not VegetationCardFactory.canopy_lod_enabled(species, bs):
		return false
	var chain := VegetationCardFactory.lod_chain(species, bs)
	return chain.size() > 1 and str(chain[0]) == REP_MESH


## Positions of the trees the detail distance controls, from one or more layer
## `bulk` dictionaries (slot -> records). resolvers[i], when a valid Callable,
## turns bulks[i]'s slot into its species (the generated layer stores aliases).
static func detail_points(bulks: Array, settings: Dictionary,
		resolvers: Array = []) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in bulks.size():
		if not (bulks[i] is Dictionary):
			continue
		var bulk: Dictionary = bulks[i]
		var res: Variant = resolvers[i] if i < resolvers.size() else null
		for slot in bulk:
			var sp := str(slot)
			if res is Callable and (res as Callable).is_valid():
				sp = str((res as Callable).call(sp))
			if not detail_controls(sp, settings):
				continue
			for item in bulk[slot]:
				if item is Dictionary:
					var d: Dictionary = item
					out.append(Vector2(float(d.get("x", 0.0)), float(d.get("z", 0.0))))
	return out


## The trees binned for the budget: a dense grid over their bounding box with
## a summed-area table. {} for no trees.
static func detail_grid(points: PackedVector2Array) -> Dictionary:
	if points.is_empty():
		return {}
	var mn := points[0]
	var mx := points[0]
	for p in points:
		mn = Vector2(minf(mn.x, p.x), minf(mn.y, p.y))
		mx = Vector2(maxf(mx.x, p.x), maxf(mx.y, p.y))
	var cell := BUDGET_CELL_M
	var w := 1
	var h := 1
	while true:
		w = int(floor((mx.x - mn.x) / cell)) + 1
		h = int(floor((mx.y - mn.y) / cell)) + 1
		if w * h <= BUDGET_MAX_CELLS:
			break
		cell *= 2.0
	var counts := PackedInt32Array()
	counts.resize(w * h)
	for p in points:
		var ix := mini(int((p.x - mn.x) / cell), w - 1)
		var iz := mini(int((p.y - mn.y) / cell), h - 1)
		counts[iz * w + ix] += 1
	var sw := w + 1
	var sat := PackedInt32Array()
	sat.resize(sw * (h + 1))
	var occ := PackedInt32Array()
	for z in h:
		var run := 0
		var row := z * w
		var srow := (z + 1) * sw
		var prow := z * sw
		for x in w:
			var c := counts[row + x]
			if c > 0:
				occ.append(row + x)
			run += c
			sat[srow + x + 1] = sat[prow + x + 1] + run
	return {"cell": cell, "w": w, "h": h, "sat": sat, "occ": occ, "n": points.size()}


## Trees in the inclusive cell rectangle (clamped to the grid).
static func _grid_rect(g: Dictionary, x0: int, z0: int, x1: int, z1: int) -> int:
	var w := int(g["w"])
	var h := int(g["h"])
	x0 = maxi(x0, 0)
	z0 = maxi(z0, 0)
	x1 = mini(x1, w - 1)
	z1 = mini(z1, h - 1)
	if x0 > x1 or z0 > z1:
		return 0
	var sat: PackedInt32Array = g["sat"]
	var sw := w + 1
	return sat[(z1 + 1) * sw + x1 + 1] - sat[z0 * sw + x1 + 1] \
		- sat[(z1 + 1) * sw + x0] + sat[z0 * sw + x0]


## Trees whose cell centre lies within d of cell (cx, cz)'s centre.
static func _grid_disc(g: Dictionary, cx: int, cz: int, d: float, stop_above: int) -> int:
	var cell := float(g["cell"])
	var r := int(floor(d / cell))
	var total := 0
	for dz in range(-r, r + 1):
		var off := float(dz) * cell
		var rem := d * d - off * off
		if rem < 0.0:
			continue
		var hw := int(floor(sqrt(rem) / cell))
		total += _grid_rect(g, cx - hw, cz + dz, cx + hw, cz + dz)
		if total > stop_above:
			break
	return total


## The most trees within d of any occupied cell's centre (for checks and
## diagnostics; the budget search uses the pruned test below).
static func worst_near_count(g: Dictionary, d: float) -> int:
	if g.is_empty():
		return 0
	var w := int(g["w"])
	var worst := 0
	for i in (g["occ"] as PackedInt32Array):
		worst = maxi(worst, _grid_disc(g, i % w, i / w, d, 1 << 30))
	return worst


## Does no viewpoint have more than `budget` trees within d? Cells whose
## surrounding square already fits are skipped; the rest are tested most
## crowded first, so an overflow is found early.
static func _fits(g: Dictionary, d: float, budget: int) -> bool:
	if int(g["n"]) <= budget:
		return true
	var w := int(g["w"])
	var r := int(floor(d / float(g["cell"])))
	var keys := PackedInt64Array()
	for i in (g["occ"] as PackedInt32Array):
		var cx := i % w
		var cz := i / w
		var sq := _grid_rect(g, cx - r, cz - r, cx + r, cz + r)
		if sq > budget:
			keys.append(int(sq) * _KEY_SHIFT + i)
	if keys.is_empty():
		return true
	keys.sort()
	for k in range(keys.size() - 1, -1, -1):
		var i := int(keys[k] % _KEY_SHIFT)
		if _grid_disc(g, i % w, i / w, d, budget) > budget:
			return false
	return true


## The detail distance: the requested one when it fits the budget, else the
## largest multiple of BUDGET_STEP_M that does, never below MIN_DETAIL_M.
static func measured_detail_distance(g: Dictionary, requested_m: float, budget: int) -> float:
	var hi := maxf(requested_m, MIN_DETAIL_M)
	if g.is_empty() or budget <= 0 or _fits(g, hi, budget):
		return hi
	var lo := MIN_DETAIL_M
	if not _fits(g, lo, budget):
		return MIN_DETAIL_M
	var best := lo
	var a := int(ceil(lo / BUDGET_STEP_M))
	var b := int(floor(hi / BUDGET_STEP_M))
	# Largest step multiple in [lo, hi) that fits (fits is monotone in d).
	while a <= b:
		var mid := (a + b) / 2
		var dm := float(mid) * BUDGET_STEP_M
		if dm >= hi:
			b = mid - 1
			continue
		if _fits(g, dm, budget):
			best = maxf(best, dm)
			a = mid + 1
		else:
			b = mid - 1
	return best
