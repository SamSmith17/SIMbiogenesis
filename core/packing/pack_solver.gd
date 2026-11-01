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
## Opt-in rules (only where an item, the container or `opts` declares them,
## so a plain solve is unchanged):
##   item max_stack_kg  — the most mass that may rest on it, passed down
##                        through every box under the new one by footprint
##                        share (a pallet's static rating, a gaylord wall).
##   item top_only / fragile — nothing may go on it, and it is placed after
##                        the rest (so it ends up on top or at the door).
##   item fork_axis "w"|"d" — the forks run along that dimension; with
##                        forks entering from the door it must lie along z
##                        (the load length). Containers whose forks_from is
##                        "door", or opts.forks_from_door.
##   container floor_kg_m2 — floor pressure under each floor-standing box
##                        (its mass and everything above it over its area).
##   opts.max_fill_h_m  — load height limit below the roof.
##   opts.retry_pass    — a second, smallest-first pass for space overflow.
##
## Axes: x = container width (w_m), y = height (h_m), z = load length (l_m);
## the door is at high z, so the front of the load (z = 0) goes in first.
## Deterministic by construction: explicit sort comparators with index
## tie-breaks, no Dictionary-order iteration in placement decisions.

const SUPPORT_MIN_FRAC := 0.5
const MAX_ITEMS := 600
const EPS := 0.001
## CTU Code (IMO/ILO/UNECE 2014) Annex 7 guidance as warning bands: the
## load's centre of gravity near the middle of the length and the width.
const CTU_LEN_BAND := Vector2(0.40, 0.60)
const CTU_WIDTH_BAND := Vector2(0.45, 0.55)


## container: a ContainerCatalog entry. items: Array of PackedSpec-style
## dicts (w_m/d_m/h_m/mass_kg/stackable/this_side_up + optional label).
## Returns {fit, placements, overflow, utilization, placed_volume_m3,
## total_mass_kg, mass_unknown_count, payload_ok, com, com_len_frac,
## com_width_frac, axle_split, warnings}.
static func solve(container: Dictionary, items: Array, opts: Dictionary = {}) -> Dictionary:
	var interior: Dictionary = container.get("interior", {})
	var cw := float(interior.get("w_m", 0.0))
	var ch := float(interior.get("h_m", 0.0))
	var cl := float(interior.get("l_m", 0.0))
	var fill_h := float(opts.get("max_fill_h_m", 0.0))
	if fill_h > 0.0:
		ch = minf(ch, fill_h)
	var out := {
		"fit": false, "placements": [], "overflow": [],
		"utilization": 0.0, "placed_volume_m3": 0.0,
		"total_mass_kg": 0.0, "mass_unknown_count": 0,
		"payload_ok": true, "com": Vector3.ZERO, "com_len_frac": 0.5,
		"com_width_frac": 0.5, "axle_split": {"front": 0.5, "rear": 0.5},
		"warnings": [],
	}
	if cw <= 0.0 or ch <= 0.0 or cl <= 0.0 or items.is_empty():
		out["fit"] = items.is_empty()
		return out
	var ctx := {
		"cw": cw, "ch": ch, "cl": cl,
		"floor_kg_m2": float(container.get("floor_kg_m2", 0.0)),
		"forks_door": bool(opts.get("forks_from_door",
			str(container.get("forks_from", "")) == "door")),
	}

	# Largest-first order, mass then original index as tie-breaks; top-only
	# (fragile) items after everything else.
	var order: Array = []
	for i in mini(items.size(), MAX_ITEMS):
		order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool:
		var ia: Dictionary = items[a]
		var ib: Dictionary = items[b]
		var ta := _top_only(ia)
		var tb := _top_only(ib)
		if ta != tb:
			return tb
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
	var space_left: Array = []
	for idx in order:
		var res := _place(idx, items[idx], container, points, placed, ctx, out)
		if res == "space":
			space_left.append(idx)

	if bool(opts.get("retry_pass", false)) and not space_left.is_empty():
		# Smallest first: the gaps left are small, and a small box placed
		# early never blocks a bigger one that did not fit anyway.
		space_left.sort_custom(func(a: int, b: int) -> bool:
			var va := _volume(items[a])
			var vb := _volume(items[b])
			if absf(va - vb) > 1e-9:
				return va < vb
			return a < b)
		var still: Array = []
		var retry_out := {"overflow": [], "placements": out["placements"]}
		for idx in space_left:
			var res := _place(idx, items[idx], container, points, placed, ctx, retry_out)
			if res != "":
				still.append(idx)
		var kept: Array = []
		for o: Dictionary in out["overflow"]:
			if str(o["reason"]) != "space" or still.has(int(o["item_index"])):
				kept.append(o)
		out["overflow"] = kept

	if items.size() > MAX_ITEMS:
		for i in range(MAX_ITEMS, items.size()):
			(out["overflow"] as Array).append({"item_index": i,
				"label": str((items[i] as Dictionary).get("label", "item %d" % i)),
				"reason": "item_cap"})

	var placed_vol := 0.0
	var total_mass := 0.0
	var unknown_mass := 0
	var moment := Vector3.ZERO
	for k in placed.size():
		var box: Dictionary = placed[k]
		var pos: Vector3 = box["pos"]
		var size: Vector3 = box["size"]
		var mass := float(box["mass"])
		placed_vol += size.x * size.y * size.z
		if mass > 0.0:
			total_mass += mass
			moment += (pos + size * 0.5) * mass
		else:
			unknown_mass += 1
	for pl: Dictionary in out["placements"]:
		var k := int(pl.get("_slot", -1))
		if k >= 0:
			pl["load_kg"] = float((placed[k] as Dictionary)["load"])
			pl.erase("_slot")

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
		out["com_width_frac"] = clampf(com.x / cw, 0.0, 1.0)
		# Simply supported at the two ends of the load floor: front (z = 0)
		# takes the share of the rear's lever arm. An estimate of the axle
		# split, not a vehicle model.
		var rear := float(out["com_len_frac"])
		out["axle_split"] = {"front": 1.0 - rear, "rear": rear}
	out["warnings"] = warnings_for(out, container)
	return out


## Plain-language CTU Code style warnings for a solved load.
static func warnings_for(res: Dictionary, container: Dictionary) -> Array:
	var w: Array = []
	if not bool(res.get("payload_ok", true)):
		w.append({"code": "payload", "text": "Over the payload: %.0f kg loaded, %.0f kg allowed." % [
			float(res.get("total_mass_kg", 0.0)), float(container.get("payload_kg", 0.0))]})
	if float(res.get("total_mass_kg", 0.0)) > 0.0:
		var lf := float(res.get("com_len_frac", 0.5))
		if lf < CTU_LEN_BAND.x or lf > CTU_LEN_BAND.y:
			w.append({"code": "cog_length", "text":
				"Centre of gravity %.0f %% along the length: shift weight toward the middle." % (lf * 100.0)})
		var wf := float(res.get("com_width_frac", 0.5))
		if wf < CTU_WIDTH_BAND.x or wf > CTU_WIDTH_BAND.y:
			w.append({"code": "cog_width", "text":
				"Centre of gravity %.0f %% across the width: the load leans to one side." % (wf * 100.0)})
	if int(res.get("mass_unknown_count", 0)) > 0:
		w.append({"code": "mass_unknown", "text":
			"%s with no known mass: the weight checks leave them out." % UiText.count(
				int(res["mass_unknown_count"]), "item")})
	var reasons := {}
	for o: Dictionary in res.get("overflow", []):
		reasons[str(o.get("reason", ""))] = int(reasons.get(str(o.get("reason", "")), 0)) + 1
	if reasons.has("stack"):
		w.append({"code": "stack", "text": "%s left out: nothing under them can carry the weight." % UiText.count(int(reasons["stack"]), "item")})
	if reasons.has("floor"):
		w.append({"code": "floor", "text": "%s left out: too heavy for the floor rating." % UiText.count(int(reasons["floor"]), "item")})
	if reasons.has("fork"):
		w.append({"code": "fork", "text": "%s left out: the forks cannot reach them from the door." % UiText.count(int(reasons["fork"]), "item")})
	return w


static func _volume(item: Dictionary) -> float:
	return float(item.get("w_m", 0.0)) * float(item.get("d_m", 0.0)) * float(item.get("h_m", 0.0))


static func _top_only(item: Dictionary) -> bool:
	return bool(item.get("top_only", false)) or bool(item.get("fragile", false))


## Places one item; returns "" on success or the overflow reason.
static func _place(idx: int, item: Dictionary, container: Dictionary, points: Array,
		placed: Array, ctx: Dictionary, out: Dictionary) -> String:
	var label := str(item.get("label", "item %d" % idx))
	if not ContainerCatalog.fits_through_door(container, item):
		(out["overflow"] as Array).append({"item_index": idx, "label": label,
			"reason": "door"})
		return "door"
	var spot := _find_spot(item, points, placed, ctx)
	if not spot.has("pos"):
		var why := str(spot.get("reason", "space"))
		(out["overflow"] as Array).append({"item_index": idx, "label": label,
			"reason": why})
		return why
	var pos: Vector3 = spot["pos"]
	var size: Vector3 = spot["size"]
	var mass := float(item.get("mass_kg", PackedSpec.MASS_UNKNOWN))
	var added: Dictionary = spot.get("added", {})
	for k: int in added:
		var b: Dictionary = placed[k]
		b["load"] = float(b["load"]) + float(added[k])
	placed.append({"pos": pos, "size": size,
		"stackable": bool(item.get("stackable", true)) and not _top_only(item),
		"mass": mass, "load": 0.0, "under": spot.get("under", []),
		"max_stack_kg": float(item.get("max_stack_kg", -1.0))})
	(out["placements"] as Array).append({"item_index": idx, "label": label,
		"pos": pos, "size": size, "mass_kg": mass, "_slot": placed.size() - 1})
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
	return ""


## First feasible (point, orientation), points already sorted lowest-first.
## Returns {point, pos, size, under, added} or {reason} when nothing fits.
static func _find_spot(item: Dictionary, points: Array, placed: Array,
		ctx: Dictionary) -> Dictionary:
	var cw := float(ctx["cw"])
	var ch := float(ctx["ch"])
	var cl := float(ctx["cl"])
	var orients := _orientations(item)
	var fork_axis := str(item.get("fork_axis", ""))
	if bool(ctx.get("forks_door", false)) and (fork_axis == "w" or fork_axis == "d"):
		var along := float(item.get(fork_axis + "_m", 0.0))
		var kept: Array = []
		for s: Vector3 in orients:
			if absf(s.z - along) < EPS:
				kept.append(s)
		if kept.is_empty():
			return {"reason": "fork"}
		orients = kept
	var mass := maxf(0.0, float(item.get("mass_kg", 0.0)))
	var reason := "space"
	for p: Vector3 in points:
		for size: Vector3 in orients:
			if p.x + size.x > cw + EPS or p.y + size.y > ch + EPS \
					or p.z + size.z > cl + EPS:
				continue
			if _overlaps_any(p, size, placed):
				continue
			var under := _supports(p, size, placed)
			if p.y > EPS and under.is_empty():
				continue
			var added := _added_loads(under, mass, placed)
			var why := _load_check(p, size, mass, added, placed, float(ctx["floor_kg_m2"]))
			if why != "":
				if reason == "space":
					reason = why
				continue
			return {"point": p, "pos": p, "size": size, "under": under, "added": added}
	return {"reason": reason}


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
	return not _supports(p, size, placed).is_empty()


## The boxes a new box at p rests on, as [[index, share]] by contact area
## (shares sum to 1). Empty on the floor, or when the stackable contact is
## under SUPPORT_MIN_FRAC of the footprint.
static func _supports(p: Vector3, size: Vector3, placed: Array) -> Array:
	if p.y <= EPS:
		return []
	var need := size.x * size.z * SUPPORT_MIN_FRAC
	var have := 0.0
	var rows: Array = []
	for k in placed.size():
		var box: Dictionary = placed[k]
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
			rows.append([k, ox * oz])
	if have < need - 1e-9:
		return []
	for r: Array in rows:
		r[1] = float(r[1]) / have
	return rows


## Mass added to every box below a new one: its share, then the same share
## carried down through each support's own supports.
static func _added_loads(under: Array, mass: float, placed: Array) -> Dictionary:
	var added := {}
	if mass <= 0.0:
		return added
	var stack: Array = []
	for r: Array in under:
		stack.append([int(r[0]), mass * float(r[1])])
	while not stack.is_empty():
		var top: Array = stack.pop_back()
		var k := int(top[0])
		var m := float(top[1])
		added[k] = float(added.get(k, 0.0)) + m
		for r2: Array in (placed[k] as Dictionary).get("under", []):
			stack.append([int(r2[0]), m * float(r2[1])])
	return added


## "" when the new box keeps every rating, else "stack" or "floor".
static func _load_check(p: Vector3, size: Vector3, mass: float, added: Dictionary,
		placed: Array, floor_kg_m2: float) -> String:
	for k: int in added:
		var b: Dictionary = placed[k]
		var cap := float(b.get("max_stack_kg", -1.0))
		if cap >= 0.0 and float(b["load"]) + float(added[k]) > cap + 1e-6:
			return "stack"
	if floor_kg_m2 <= 0.0:
		return ""
	if p.y <= EPS and mass > 0.0:
		if mass / maxf(size.x * size.z, 1e-6) > floor_kg_m2 + 1e-6:
			return "floor"
	for k: int in added:
		var b: Dictionary = placed[k]
		if (b["pos"] as Vector3).y > EPS:
			continue
		var bs: Vector3 = b["size"]
		var total := maxf(0.0, float(b["mass"])) + float(b["load"]) + float(added[k])
		if total / maxf(bs.x * bs.z, 1e-6) > floor_kg_m2 + 1e-6:
			return "floor"
	return ""
