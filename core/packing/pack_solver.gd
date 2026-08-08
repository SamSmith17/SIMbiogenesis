class_name PackSolver
extends RefCounted
## Deterministic 3D bin-packing heuristic — PACKING_PLAN.md Phase 2.
##
## Greedy extreme-point / largest-first (Crainic et al.'s extreme-point
## family): items sorted by volume descending are placed first-fit at the
## lowest feasible candidate point, spawning three new candidate points per
## placement. Deliberately NOT optimal — 3D bin packing is NP-hard, and a
## greedy heuristic's 70-85% fill is what a competent human crew achieves,
## which is the honest number for a "will my camp fit the truck" report.
##
## Constraints honoured: container interior bounds, no overlap, gravity
## support (floor, or >=50% footprint on a STACKABLE box top), this_side_up
## (vertical-axis orientations only), door aperture (via
## ContainerCatalog.fits_through_door), payload (reported, not blocking —
## an overweight load still physically packs).
##
## Axes: x = container width (w_m), y = height (h_m), z = load length (l_m).
## Deterministic by construction: explicit sort comparators with index
## tie-breaks, no Dictionary-order iteration in placement decisions.

const SUPPORT_MIN_FRAC := 0.5
const MAX_ITEMS := 600
const EPS := 0.001


## container: a ContainerCatalog entry. items: Array of PackedSpec-style
## dicts (w_m/d_m/h_m/mass_kg/stackable/this_side_up + optional label).
## Returns {fit, placements, overflow, utilization, placed_volume_m3,
## total_mass_kg, mass_unknown_count, payload_ok, com, com_len_frac}.
static func solve(container: Dictionary, items: Array) -> Dictionary:
	var interior: Dictionary = container.get("interior", {})
	var cw := float(interior.get("w_m", 0.0))
	var ch := float(interior.get("h_m", 0.0))
	var cl := float(interior.get("l_m", 0.0))
	var out := {
		"fit": false, "placements": [], "overflow": [],
		"utilization": 0.0, "placed_volume_m3": 0.0,
		"total_mass_kg": 0.0, "mass_unknown_count": 0,
		"payload_ok": true, "com": Vector3.ZERO, "com_len_frac": 0.5,
	}
	if cw <= 0.0 or ch <= 0.0 or cl <= 0.0 or items.is_empty():
		out["fit"] = items.is_empty()
		return out

	# Largest-first order, mass then original index as tie-breaks.
	var order: Array = []
	for i in mini(items.size(), MAX_ITEMS):
		order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool:
		var ia: Dictionary = items[a]
		var ib: Dictionary = items[b]
		var va := float(ia.get("w_m", 0.0)) * float(ia.get("d_m", 0.0)) * float(ia.get("h_m", 0.0))
		var vb := float(ib.get("w_m", 0.0)) * float(ib.get("d_m", 0.0)) * float(ib.get("h_m", 0.0))
		if absf(va - vb) > 1e-9:
			return va > vb
		var ma := float(ia.get("mass_kg", 0.0))
		var mb := float(ib.get("mass_kg", 0.0))
		if absf(ma - mb) > 1e-9:
			return ma > mb
		return a < b)

	var placed: Array = []
	var points: Array = [Vector3.ZERO]
	var placed_vol := 0.0
	var total_mass := 0.0
	var unknown_mass := 0
	var moment := Vector3.ZERO

	for idx in order:
		var item: Dictionary = items[idx]
		var label := str(item.get("label", "item %d" % idx))
		if not ContainerCatalog.fits_through_door(container, item):
			(out["overflow"] as Array).append({"item_index": idx, "label": label,
				"reason": "door"})
			continue
		var spot := _find_spot(item, points, placed, cw, ch, cl)
		if spot.is_empty():
			(out["overflow"] as Array).append({"item_index": idx, "label": label,
				"reason": "space"})
			continue
		var pos: Vector3 = spot["pos"]
		var size: Vector3 = spot["size"]
		var mass := float(item.get("mass_kg", PackedSpec.MASS_UNKNOWN))
		placed.append({"pos": pos, "size": size,
			"stackable": bool(item.get("stackable", true)), "mass": mass})
		(out["placements"] as Array).append({"item_index": idx, "label": label,
			"pos": pos, "size": size, "mass_kg": mass})
		placed_vol += size.x * size.y * size.z
		if mass > 0.0:
			total_mass += mass
			moment += (pos + size * 0.5) * mass
		else:
			unknown_mass += 1
		points.erase(spot["point"])
		for np: Vector3 in [pos + Vector3(size.x, 0, 0), pos + Vector3(0, size.y, 0),
				pos + Vector3(0, 0, size.z)]:
			if not points.has(np):
				points.append(np)
		# Lowest-first: floor before stacking, front before rear, left first.
		points.sort_custom(func(a: Vector3, b: Vector3) -> bool:
			if absf(a.y - b.y) > EPS:
				return a.y < b.y
			if absf(a.z - b.z) > EPS:
				return a.z < b.z
			return a.x < b.x)

	if items.size() > MAX_ITEMS:
		for i in range(MAX_ITEMS, items.size()):
			(out["overflow"] as Array).append({"item_index": i,
				"label": str((items[i] as Dictionary).get("label", "item %d" % i)),
				"reason": "item_cap"})

	out["fit"] = (out["overflow"] as Array).is_empty()
	out["placed_volume_m3"] = placed_vol
	out["utilization"] = placed_vol / (cw * ch * cl)
	out["total_mass_kg"] = total_mass
	out["mass_unknown_count"] = unknown_mass
	var payload := float(container.get("payload_kg", 0.0))
	out["payload_ok"] = payload <= 0.0 or total_mass <= payload
	if total_mass > 0.0:
		var com: Vector3 = moment / total_mass
		out["com"] = com
		out["com_len_frac"] = clampf(com.z / cl, 0.0, 1.0)
	return out


## First feasible (point, orientation), points already sorted lowest-first.
static func _find_spot(item: Dictionary, points: Array, placed: Array,
		cw: float, ch: float, cl: float) -> Dictionary:
	var orients := _orientations(item)
	for p: Vector3 in points:
		for size: Vector3 in orients:
			if p.x + size.x > cw + EPS or p.y + size.y > ch + EPS \
					or p.z + size.z > cl + EPS:
				continue
			if _overlaps_any(p, size, placed):
				continue
			if not _supported(p, size, placed):
				continue
			return {"point": p, "pos": p, "size": size}
	return {}


## Orientation set as Vector3(x=width, y=height, z=depth). this_side_up locks
## the authored height on the vertical axis (2 yaw options); free items get
## every unique axis permutation.
static func _orientations(item: Dictionary) -> Array:
	var w := float(item.get("w_m", 0.0))
	var d := float(item.get("d_m", 0.0))
	var h := float(item.get("h_m", 0.0))
	if bool(item.get("this_side_up", false)):
		return [Vector3(w, h, d), Vector3(d, h, w)]
	var dims := [w, d, h]
	var out: Array = []
	for a in 3:
		for b in 3:
			if b == a:
				continue
			var c: int = 3 - a - b
			var v := Vector3(dims[a], dims[b], dims[c])
			if not out.has(v):
				out.append(v)
	return out


static func _overlaps_any(p: Vector3, size: Vector3, placed: Array) -> bool:
	for box: Dictionary in placed:
		var bp: Vector3 = box["pos"]
		var bs: Vector3 = box["size"]
		if p.x < bp.x + bs.x - EPS and p.x + size.x > bp.x + EPS \
				and p.y < bp.y + bs.y - EPS and p.y + size.y > bp.y + EPS \
				and p.z < bp.z + bs.z - EPS and p.z + size.z > bp.z + EPS:
			return true
	return false


## Floor, or >=SUPPORT_MIN_FRAC of the footprint resting on stackable tops
## level with p.y. Non-stackable tops (glass, tanks) support nothing.
static func _supported(p: Vector3, size: Vector3, placed: Array) -> bool:
	if p.y <= EPS:
		return true
	var need := size.x * size.z * SUPPORT_MIN_FRAC
	var have := 0.0
	for box: Dictionary in placed:
		if not bool(box.get("stackable", true)):
			continue
		var bp: Vector3 = box["pos"]
		var bs: Vector3 = box["size"]
		if absf(bp.y + bs.y - p.y) > EPS:
			continue
		var ox := minf(p.x + size.x, bp.x + bs.x) - maxf(p.x, bp.x)
		var oz := minf(p.z + size.z, bp.z + bs.z) - maxf(p.z, bp.z)
		if ox > 0.0 and oz > 0.0:
			have += ox * oz
			if have >= need - 1e-9:
				return true
	return false
