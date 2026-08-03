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
