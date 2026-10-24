class_name FlatpackNesting
extends RefCounted

## Laying the parts out on plywood sheets.
##
## MaxRects bin packing with the best-short-side-fit rule (Jylänkä, "A
## Thousand Ways to Pack the Bin", 2010) on each part's bounding rectangle.
## Every free rectangle of every sheet already started is tried before a new
## sheet is opened, parts turn 90° unless their grain is locked, and each part
## is grown by the spacing (bit + margin between cuts) so neighbours never
## share a cut. Deterministic: parts are taken longest side first, then by
## area, then by id.
##
## Bounding rectangles waste the hollow of an L-shaped part; true-shape
## nesting is a later refinement. PlayaTech parts are mostly rectangles, and
## the sample design nests onto exactly three 4×8 sheets this way.

const EPS := 1e-4


## items: [{id, w, h, rot_ok}]. Returns {sheets: [{index, placements:
## [{id, x, y, w, h, rot}]}], unplaced: [id], sheet_w, sheet_h}.
## (x, y) is the part's lower-left corner on its sheet; with `rot` the part
## is turned 90° counter-clockwise and occupies h × w.
static func nest(items: Array, sheet_w: float, sheet_h: float, spacing: float = 0.5,
		margin: float = 0.5) -> Dictionary:
	var bin_w := sheet_w - 2.0 * margin + spacing
	var bin_h := sheet_h - 2.0 * margin + spacing
	var order := items.duplicate()
	order.sort_custom(func(a, b):
		var la := maxf(float(a["w"]), float(a["h"]))
		var lb := maxf(float(b["w"]), float(b["h"]))
		if absf(la - lb) > EPS:
			return la > lb
		var aa := float(a["w"]) * float(a["h"])
		var ab := float(b["w"]) * float(b["h"])
		if absf(aa - ab) > EPS:
			return aa > ab
		return str(a["id"]) < str(b["id"]))
	var sheets: Array = []      # {index, free: [Rect2], placements}
	var unplaced: Array = []
	for it in order:
		var w := float(it["w"]) + spacing
		var h := float(it["h"]) + spacing
		var rot_ok := bool(it.get("rot_ok", true))
		var best := {}
		for si in sheets.size():
			var cand := _find(sheets[si]["free"], w, h, rot_ok)
			if cand.is_empty():
				continue
			if best.is_empty() or _better(cand, best):
				cand["sheet"] = si
				best = cand
		if best.is_empty():
			var fresh := {"index": sheets.size(), "free": [Rect2(0, 0, bin_w, bin_h)], "placements": []}
			var cand2 := _find(fresh["free"], w, h, rot_ok)
			if cand2.is_empty():
				unplaced.append(str(it["id"]))
				continue
			sheets.append(fresh)
			cand2["sheet"] = sheets.size() - 1
			best = cand2
		var sh: Dictionary = sheets[int(best["sheet"])]
		var r: Rect2 = best["rect"]
		_place(sh["free"], r)
		(sh["placements"] as Array).append({"id": str(it["id"]), "x": r.position.x + margin,
			"y": r.position.y + margin, "w": float(it["w"]), "h": float(it["h"]),
			"rot": bool(best["rot"])})
	var out_sheets: Array = []
	for sh in sheets:
		out_sheets.append({"index": int(sh["index"]), "placements": sh["placements"]})
	return {"sheets": out_sheets, "unplaced": unplaced, "sheet_w": sheet_w, "sheet_h": sheet_h,
		"spacing": spacing, "margin": margin}


static func _better(a: Dictionary, b: Dictionary) -> bool:
	if absf(float(a["short"]) - float(b["short"])) > EPS:
		return float(a["short"]) < float(b["short"])
	if absf(float(a["long"]) - float(b["long"])) > EPS:
		return float(a["long"]) < float(b["long"])
	return int(a.get("sheet", 0)) < int(b.get("sheet", 0))


static func _find(free: Array, w: float, h: float, rot_ok: bool) -> Dictionary:
	var best := {}
	for r: Rect2 in free:
		for pass_i in (2 if rot_ok else 1):
			var pw := w if pass_i == 0 else h
			var ph := h if pass_i == 0 else w
			if pw > r.size.x + EPS or ph > r.size.y + EPS:
				continue
			var lw: float = r.size.x - pw
			var lh: float = r.size.y - ph
			var cand := {"rect": Rect2(r.position, Vector2(pw, ph)), "rot": pass_i == 1,
				"short": minf(lw, lh), "long": maxf(lw, lh)}
			if best.is_empty() or _better(cand, best):
				best = cand
	return best


static func _place(free: Array, used: Rect2) -> void:
	var out: Array = []
	for r: Rect2 in free:
		if not _overlaps(r, used):
			out.append(r)
			continue
		# Split into the (up to four) maximal rectangles round `used`.
		if used.position.x > r.position.x + EPS:
			out.append(Rect2(r.position, Vector2(used.position.x - r.position.x, r.size.y)))
		if used.end.x < r.end.x - EPS:
			out.append(Rect2(Vector2(used.end.x, r.position.y), Vector2(r.end.x - used.end.x, r.size.y)))
		if used.position.y > r.position.y + EPS:
			out.append(Rect2(r.position, Vector2(r.size.x, used.position.y - r.position.y)))
		if used.end.y < r.end.y - EPS:
			out.append(Rect2(Vector2(r.position.x, used.end.y), Vector2(r.size.x, r.end.y - used.end.y)))
	# Prune rectangles contained in another.
	var pruned: Array = []
	for i in out.size():
		var a: Rect2 = out[i]
		if a.size.x < EPS or a.size.y < EPS:
			continue
		var contained := false
		for k in out.size():
			if k == i:
				continue
			var b: Rect2 = out[k]
			if _contains(b, a) and not (_contains(a, b) and k > i):
				contained = true
				break
		if not contained:
			pruned.append(a)
	free.clear()
	free.append_array(pruned)


static func _overlaps(a: Rect2, b: Rect2) -> bool:
	return a.position.x < b.end.x - EPS and b.position.x < a.end.x - EPS \
		and a.position.y < b.end.y - EPS and b.position.y < a.end.y - EPS


static func _contains(outer: Rect2, inner: Rect2) -> bool:
	return inner.position.x >= outer.position.x - EPS and inner.position.y >= outer.position.y - EPS \
		and inner.end.x <= outer.end.x + EPS and inner.end.y <= outer.end.y + EPS


## The largest size n parts can be across a sheet dimension and still rip
## cleanly, floored to 1/8": (sheet - 2·margin - (n-1)·spacing) / n.
static func fit_to_sheet(n: int, sheet_dim: float, spacing: float, margin: float) -> float:
	var v := (sheet_dim - 2.0 * margin - float(maxi(n - 1, 0)) * spacing) / float(maxi(n, 1))
	return floor(v * 8.0 + 1e-6) / 8.0


## A placed part's ring on its sheet: the part's ring moved so its bounding
## box's lower-left corner sits at the placement, turned 90° CCW when `rot`.
static func ring_on_sheet(ring: Dictionary, part_bbox: Rect2, pl: Dictionary) -> Dictionary:
	var moved := FlatpackProfile.transform_ring(ring, 0.0, -part_bbox.position)
	if bool(pl.get("rot", false)):
		# (x, y) -> (-y, x): the turned part spans [-h, 0] × [0, w]; shift by +h.
		moved = FlatpackProfile.transform_ring(moved, PI * 0.5, Vector2(part_bbox.size.y, 0.0))
	return FlatpackProfile.transform_ring(moved, 0.0, Vector2(float(pl["x"]), float(pl["y"])))


static func point_on_sheet(q: Vector2, part_bbox: Rect2, pl: Dictionary) -> Vector2:
	var m := q - part_bbox.position
	if bool(pl.get("rot", false)):
		m = Vector2(-m.y + part_bbox.size.y, m.x)
	return m + Vector2(float(pl["x"]), float(pl["y"]))
