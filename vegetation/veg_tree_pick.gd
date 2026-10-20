class_name VegTreePick
extends RefCounted

## Ray → the individual plant under the pointer, over BOTH vegetation layers:
## the painted VegetationLayer and the OSM-generated AutoVegetationLayer.
##
## The V toolbar's Select tool used to resolve a click to the nearest PAINTED
## plant around the terrain point under the cursor, so (a) the trees the map
## grew from OpenStreetMap could not be picked at all, and (b) aiming at a
## crown picked whatever stood on the ground behind it, often 30 m away. Here
## each plant is a vertical cylinder (ground → its height, radius ≈ its crown)
## and the pick is the nearest one the RAY actually passes through.
##
## Records carry no ids, so a pick is a descriptor {source, slot, index, …}:
## valid until the layer is edited (the same contract as
## VegetationLayer.nearest_plant). Pure apart from the ground-height Callable,
## so the selftest drives it with synthetic layers.

const CELL_M := 16.0
## Never test further than this along the ray.
const MAX_RANGE_M := 1600.0
## Past the terrain hit, a crown standing in front of it still counts.
const BEHIND_TERRAIN_SLACK_M := 6.0

## [{source, slot, index, x, z, h, r, kind}] bucketed by Vector2i cell.
var _cells: Dictionary = {}
var _sig := -1
var _count := 0


## Sources: [{source: "painted"|"auto", bulk: Dictionary, hero: Array}].
## `height_of(slot, record) -> float` gives a plant's height in metres.
func rebuild_if_changed(sources: Array, height_of: Callable) -> void:
	var sig := signature(sources)
	if sig == _sig:
		return
	_sig = sig
	_cells = {}
	_count = 0
	for s in sources:
		if not (s is Dictionary):
			continue
		var src: Dictionary = s
		var source := str(src.get("source", ""))
		var bulk: Dictionary = src.get("bulk", {}) if src.get("bulk") is Dictionary else {}
		for slot in bulk:
			var arr: Variant = bulk[slot]
			if not (arr is Array):
				continue
			if VegSpeciesCatalog.mesh_family(str(slot)).begins_with("grass_"):
				continue
			var records: Array = arr
			for i in records.size():
				if records[i] is Dictionary:
					_add(source, str(slot), i, records[i] as Dictionary, "bulk", height_of)
		var hero: Array = src.get("hero", []) if src.get("hero") is Array else []
		for i in hero.size():
			if hero[i] is Dictionary:
				var h: Dictionary = hero[i]
				_add(source, str(h.get("preset", "")), i, h, "hero", height_of)


## Cheap change detector: record counts per slot per layer + each layer's
## identity. A pick index survives camera motion; an edit that adds or removes
## plants (or a regenerated layer) rebuilds it.
static func signature(sources: Array) -> int:
	var h := 17
	for s in sources:
		if not (s is Dictionary):
			continue
		var src: Dictionary = s
		var bulk: Variant = src.get("bulk", {})
		if bulk is Dictionary:
			h = h * 31 + hash(str(src.get("source", "")))
			for slot in (bulk as Dictionary):
				var arr: Variant = (bulk as Dictionary)[slot]
				h = h * 31 + hash(str(slot)) + (arr.size() if arr is Array else 0)
		var hero: Variant = src.get("hero", [])
		h = h * 31 + (hero.size() if hero is Array else 0)
		h = h * 31 + int(src.get("rev", 0))
	return h


func count() -> int:
	return _count


func _add(source: String, slot: String, index: int, rec: Dictionary, kind: String,
		height_of: Callable) -> void:
	var x := float(rec.get("x", 0.0))
	var z := float(rec.get("z", 0.0))
	var h := maxf(float(height_of.call(slot, rec)), 0.3)
	var shrubby := VegSpeciesCatalog.mesh_family(slot) == "shrub"
	var r := clampf(h * (0.5 if shrubby else 0.28), 0.5, 9.0)
	var key := Vector2i(floori(x / CELL_M), floori(z / CELL_M))
	if not _cells.has(key):
		_cells[key] = []
	(_cells[key] as Array).append({
		"source": source, "slot": slot, "index": index, "x": x, "z": z,
		"h": h, "r": r, "kind": kind,
		"ground_y": float(rec.get("ground_y", NAN)),
	})
	_count += 1


## The nearest plant the ray passes through, or {}. `terrain_t` is the
## distance to the ground hit along the ray (INF when none): a plant wholly
## behind the ground is hidden. Returns the entry plus {t, y_base}.
func pick(origin: Vector3, dir: Vector3, terrain_t: float, ground_y_at: Callable) -> Dictionary:
	if _cells.is_empty() or dir.length_squared() < 1e-8:
		return {}
	var d := dir.normalized()
	var max_t := MAX_RANGE_M
	if is_finite(terrain_t):
		max_t = minf(max_t, terrain_t + BEHIND_TERRAIN_SLACK_M + 9.0)
	var best := {}
	var best_t := INF
	for key in _cells_along(origin, d, max_t):
		for e in (_cells[key] as Array):
			var ent: Dictionary = e
			var gy := float(ent["ground_y"])
			var t := hit_t(origin, d, float(ent["x"]), float(ent["z"]), float(ent["r"]),
				float(ent["h"]), gy, ground_y_at)
			if t < 0.0 or t >= best_t:
				continue
			if is_finite(terrain_t) and t > terrain_t + BEHIND_TERRAIN_SLACK_M:
				continue
			best_t = t
			best = ent.duplicate()
	if best.is_empty():
		return {}
	best["t"] = best_t
	return best


## Distance along a (normalised) ray to where it first enters the plant's
## cylinder inside its height band, or -1. Ground height comes from the
## record when it carries one, else the callable (only reached once the ray
## already passes within the crown radius horizontally).
static func hit_t(o: Vector3, d: Vector3, x: float, z: float, r: float, h: float,
		gy_in: float, ground_y_at: Callable) -> float:
	var lxz := d.x * d.x + d.z * d.z
	var t_lo := 0.0
	var t_hi := INF
	if lxz < 1e-8:
		# Looking straight down (or up): inside the crown disc or not at all.
		if Vector2(o.x - x, o.z - z).length() > r:
			return -1.0
	else:
		var tc := ((x - o.x) * d.x + (z - o.z) * d.z) / lxz
		var cx := o.x + d.x * tc - x
		var cz := o.z + d.z * tc - z
		var dist2 := cx * cx + cz * cz
		if dist2 > r * r:
			return -1.0
		var half := sqrt((r * r - dist2) / lxz)
		t_lo = tc - half
		t_hi = tc + half
	var gy := gy_in
	if is_nan(gy):
		gy = float(ground_y_at.call(x, z)) if ground_y_at.is_valid() else 0.0
	var top := gy + h
	if absf(d.y) < 1e-6:
		if o.y < gy or o.y > top:
			return -1.0
	else:
		var ta := (gy - o.y) / d.y
		var tb := (top - o.y) / d.y
		t_lo = maxf(t_lo, minf(ta, tb))
		t_hi = minf(t_hi, maxf(ta, tb))
	t_lo = maxf(t_lo, 0.0)
	if t_lo > t_hi:
		return -1.0
	return t_lo


## Grid cells the ray's ground track crosses (with a one-cell margin for
## crowns that overhang a cell edge), nearest first.
func _cells_along(o: Vector3, d: Vector3, max_t: float) -> Array:
	var out: Array = []
	var seen := {}
	var lxz := sqrt(d.x * d.x + d.z * d.z)
	var steps := 1 if lxz < 1e-4 else int(ceil(max_t * lxz / (CELL_M * 0.5))) + 1
	for s in steps + 1:
		var t := 0.0 if steps <= 0 else max_t * float(s) / float(steps)
		var p := o + d * t
		var c := Vector2i(floori(p.x / CELL_M), floori(p.z / CELL_M))
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				var k := Vector2i(c.x + dx, c.y + dz)
				if seen.has(k):
					continue
				seen[k] = true
				if _cells.has(k):
					out.append(k)
	return out


## Every position of one slot in one source layer — the subtle "all of these"
## markers and the instance counts read this.
static func slot_count(sources: Array, slot: String) -> int:
	var n := 0
	for s in sources:
		if not (s is Dictionary):
			continue
		var bulk: Variant = (s as Dictionary).get("bulk", {})
		if bulk is Dictionary and (bulk as Dictionary).get(slot) is Array:
			n += ((bulk as Dictionary)[slot] as Array).size()
	return n
