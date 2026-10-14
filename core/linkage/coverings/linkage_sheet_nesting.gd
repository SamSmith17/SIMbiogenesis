class_name LinkageSheetNesting
extends RefCounted
## Sheet nesting for covering polygons (port of `js/linkage/sheet-nesting.js`,
## A4).
##
## Tiles a convex 2D polygon (a wall trapezoid, in inches, bottom edge on the
## x axis) with rectangular stock sheets, clips the polygon to each sheet and
## reports every piece as a cut list: which edges are factory (stock) edges,
## which are seams to a neighbouring sheet, and for every real cut its length,
## its angle from the sheet's bottom edge and where it meets the stock edges,
## measured from the nearest sheet corner. A piece's `polygon_2d` is re-based
## to its own sheet's bottom-left corner so it can be marked out on the stock.
##
## Pure. Points are Vector2 (x right, y up, inches); keys are snake_case.

const EPS := 1e-6
const SNAP := 1.0 / 64.0
const MIN_PIECE_AREA_IN2 := 0.5
const SLIVER_IN := 4.0


static func _snap(v: float) -> float:
	return roundf(v / SNAP) * SNAP


## JS `+(+v).toFixed(p)`.
static func rnd(v: float, places: int = 3) -> float:
	var m := pow(10.0, places)
	return roundf(v * m) / m


## Accepts Vector2, {x, y} or {s, t} points.
static func to_xy(pts: Array) -> Array:
	var out: Array = []
	for p in pts:
		if p is Vector2:
			out.append(p)
		elif p is Dictionary:
			var d: Dictionary = p
			out.append(Vector2(float(d.get("x", d.get("s", 0.0))), float(d.get("y", d.get("t", 0.0)))))
	return out


## Signed area (positive = counter-clockwise).
static func signed_area(poly: Array) -> float:
	var a := 0.0
	for i in poly.size():
		var p: Vector2 = poly[i]
		var q: Vector2 = poly[(i + 1) % poly.size()]
		a += p.x * q.y - q.x * p.y
	return a / 2.0


static func polygon_area(poly: Array) -> float:
	return absf(signed_area(poly))


static func bbox(poly: Array) -> Dictionary:
	var mn := Vector2(INF, INF)
	var mx := Vector2(-INF, -INF)
	for p in poly:
		mn = mn.min(p)
		mx = mx.max(p)
	return {"min_x": mn.x, "min_y": mn.y, "max_x": mx.x, "max_y": mx.y, "w": mx.x - mn.x, "h": mx.y - mn.y}


## Counter-clockwise copy.
static func ensure_ccw(poly: Array) -> Array:
	var out := poly.duplicate()
	if signed_area(poly) < 0.0:
		out.reverse()
	return out


## Sutherland–Hodgman clip of a polygon against an axis-aligned rectangle.
static func clip_polygon_to_rect(poly: Array, x0: float, y0: float, x1: float, y1: float) -> Array:
	var pts := poly.duplicate()
	if pts.is_empty():
		return pts
	pts = _clip_edge(pts, 0, x0)
	if pts.is_empty():
		return pts
	pts = _clip_edge(pts, 1, x1)
	if pts.is_empty():
		return pts
	pts = _clip_edge(pts, 2, y0)
	if pts.is_empty():
		return pts
	pts = _clip_edge(pts, 3, y1)
	return _dedupe(pts)


## side 0: x >= v, 1: x <= v, 2: y >= v, 3: y <= v.
static func _clip_edge(pts: Array, side: int, v: float) -> Array:
	var out: Array = []
	for i in pts.size():
		var cur: Vector2 = pts[i]
		var prev: Vector2 = pts[(i + pts.size() - 1) % pts.size()]
		var cur_in := _inside(cur, side, v)
		var prev_in := _inside(prev, side, v)
		if cur_in:
			if not prev_in:
				out.append(_intersect(prev, cur, side, v))
			out.append(cur)
		elif prev_in:
			out.append(_intersect(prev, cur, side, v))
	return out


static func _inside(p: Vector2, side: int, v: float) -> bool:
	match side:
		0:
			return p.x >= v - EPS
		1:
			return p.x <= v + EPS
		2:
			return p.y >= v - EPS
	return p.y <= v + EPS


static func _intersect(a: Vector2, b: Vector2, side: int, v: float) -> Vector2:
	if side < 2:
		return Vector2(v, a.y + (b.y - a.y) * ((v - a.x) / (b.x - a.x)))
	return Vector2(a.x + (b.x - a.x) * ((v - a.y) / (b.y - a.y)), v)


static func _dedupe(pts: Array) -> Array:
	var out: Array = []
	for p in pts:
		if out.is_empty() or absf((out[-1] as Vector2).x - p.x) > 1e-4 or absf((out[-1] as Vector2).y - p.y) > 1e-4:
			out.append(p)
	if out.size() > 1:
		var a: Vector2 = out[0]
		var b: Vector2 = out[-1]
		if absf(a.x - b.x) < 1e-4 and absf(a.y - b.y) < 1e-4:
			out.pop_back()
	return out


## Which sheet sides a sheet-local point lies on.
static func _side_of(p: Vector2, cw: float, ch: float, tol: float = 1e-3) -> Array:
	var sides: Array = []
	if absf(p.x) < tol:
		sides.append("left")
	if absf(p.x - cw) < tol:
		sides.append("right")
	if absf(p.y) < tol:
		sides.append("bottom")
	if absf(p.y - ch) < tol:
		sides.append("top")
	return sides


static func _edge_side(a: Vector2, b: Vector2, cw: float, ch: float):
	var sb := _side_of(b, cw, ch)
	for s in _side_of(a, cw, ch):
		if sb.has(s):
			return s
	return null


## Cut angle folded into [0, 180): the edge's angle from the sheet's bottom.
static func cut_angle_deg(a: Vector2, b: Vector2) -> float:
	var deg := rad_to_deg(atan2(b.y - a.y, b.x - a.x))
	deg = fmod(fmod(deg, 180.0) + 180.0, 180.0)
	return rnd(deg, 2)


static func _mark_for(p: Vector2, cw: float, ch: float) -> Dictionary:
	var sides := _side_of(p, cw, ch)
	if sides.size() != 1:
		return {}   # corners are not marks
	var side: String = sides[0]
	if side == "bottom" or side == "top":
		var from_left := p.x
		var from_right := cw - p.x
		var use_left := from_left <= from_right
		return {"side": side, "from_corner": ("B" if side == "bottom" else "T") + ("L" if use_left else "R"),
			"dist_in": rnd(from_left if use_left else from_right), "x": rnd(p.x), "y": rnd(p.y)}
	var from_bottom := p.y
	var from_top := ch - p.y
	var use_bottom := from_bottom <= from_top
	return {"side": side, "from_corner": ("B" if use_bottom else "T") + ("L" if side == "left" else "R"),
		"dist_in": rnd(from_bottom if use_bottom else from_top), "x": rnd(p.x), "y": rnd(p.y)}


## "top edge, 22.19 in from the top-left corner".
static func describe_mark(mark: Dictionary, fmt: Callable = Callable()) -> String:
	var corner: String = {"BL": "bottom-left", "BR": "bottom-right", "TL": "top-left", "TR": "top-right"}.get(
		str(mark["from_corner"]), str(mark["from_corner"]))
	var d := float(mark["dist_in"])
	var ds: String = fmt.call(d) if fmt.is_valid() else "%s in" % str(rnd(d, 2))
	return "%s edge, %s from the %s corner" % [str(mark["side"]), ds, corner]


static func _layout_for(poly: Array, box: Dictionary, cw: float, ch: float, align: String) -> Dictionary:
	var cols := maxi(1, int(ceil(float(box["w"]) / cw - EPS)))
	var rows := maxi(1, int(ceil(float(box["h"]) / ch - EPS)))
	var origin_x := float(box["min_x"]) + ((float(box["w"]) - cols * cw) / 2.0 if align == "center" else 0.0)
	var origin_y := float(box["min_y"])
	var cells: Array = []
	for r in rows:
		for c in cols:
			var x0 := origin_x + c * cw
			var y0 := origin_y + r * ch
			var clipped := clip_polygon_to_rect(poly, x0, y0, x0 + cw, y0 + ch)
			if clipped.size() < 3:
				continue
			var area := polygon_area(clipped)
			if area < MIN_PIECE_AREA_IN2:
				continue
			cells.append({"row": r, "col": c, "x0": x0, "y0": y0, "clipped": clipped, "area": area})
	return {"cols": cols, "rows": rows, "origin_x": origin_x, "origin_y": origin_y, "cells": cells}


## Nest one convex polygon on rectangular stock (`nestPolygonOnSheets`).
## stock: {widthIn, lengthIn, thicknessIn, orientation: auto|landscape|portrait,
## align: center|left, kerfIn} (the web's camelCase config keys).
static func nest(corners_2d: Array, stock: Dictionary = {}) -> Dictionary:
	var width_in := _pos(stock.get("widthIn"), 48.0)
	var length_in := _pos(stock.get("lengthIn"), 96.0)
	var kerf_in := _pos(stock.get("kerfIn"), 0.0)
	var poly := ensure_ccw(to_xy(corners_2d))
	if poly.size() < 3:
		return _empty_nest(stock)
	var box := bbox(poly)
	var poly_area := polygon_area(poly)
	var orientations: Array = ["landscape"] if str(stock.get("orientation", "")) == "landscape" \
		else (["portrait"] if str(stock.get("orientation", "")) == "portrait" else ["landscape", "portrait"])
	var aligns: Array = ["left"] if str(stock.get("align", "")) == "left" \
		else (["center"] if str(stock.get("align", "")) == "center" else ["center", "left"])
	var best: Dictionary = {}
	for orientation in orientations:
		var cw := maxf(width_in, length_in) if orientation == "landscape" else minf(width_in, length_in)
		var ch := minf(width_in, length_in) if orientation == "landscape" else maxf(width_in, length_in)
		for align in aligns:
			var lay := _layout_for(poly, box, cw, ch, align)
			var cells: Array = lay["cells"]
			var sheet_count := cells.size()
			var utilization := poly_area / (sheet_count * cw * ch) if sheet_count > 0 else 0.0
			var cut_pieces := 0
			var min_piece_dim := INF
			for c in cells:
				if absf(float(c["area"]) - cw * ch) > 1.0:
					cut_pieces += 1
				var b := bbox(c["clipped"])
				min_piece_dim = minf(min_piece_dim, minf(float(b["w"]), float(b["h"])))
			var cand := {"orientation": orientation, "align": align, "cw": cw, "ch": ch, "lay": lay,
				"sheet_count": sheet_count, "utilization": utilization, "cut_pieces": cut_pieces,
				"min_piece_dim": min_piece_dim}
			if _better(cand, best):
				best = cand
	var cw2 := float(best["cw"])
	var ch2 := float(best["ch"])
	var lay2: Dictionary = best["lay"]
	var occupied := {}
	for c in lay2["cells"]:
		occupied["%d:%d" % [int(c["row"]), int(c["col"])]] = true
	var warnings: Array = []
	var seam_count := 0
	var seam_linear := 0.0
	var pieces: Array = []
	for cell in lay2["cells"]:
		var local: Array = []
		for p in cell["clipped"]:
			local.append(Vector2(_snap((p as Vector2).x - float(cell["x0"])), _snap((p as Vector2).y - float(cell["y0"]))))
		var area := polygon_area(local)
		var is_full := absf(area - cw2 * ch2) < 1.0
		var edges: Array = []
		var marks: Array = []
		var has_cut := false
		var taper_on_seam := false
		for i in local.size():
			var a: Vector2 = local[i]
			var b: Vector2 = local[(i + 1) % local.size()]
			var ln := a.distance_to(b)
			if ln < 1e-4:
				continue
			var side = _edge_side(a, b, cw2, ch2)
			var is_stock := side != null
			var is_seam := is_stock and occupied.has(_neighbour(str(side), int(cell["row"]), int(cell["col"])))
			if is_seam:
				seam_count += 1
				seam_linear += ln
			edges.append({"from": Vector2(rnd(a.x), rnd(a.y)), "to": Vector2(rnd(b.x), rnd(b.y)),
				"length_in": rnd(ln), "angle_deg": cut_angle_deg(a, b), "is_stock": is_stock,
				"is_seam": is_seam, "side": side})
			if not is_stock:
				has_cut = true
				for pt in [a, b]:
					var m := _mark_for(pt, cw2, ch2)
					if m.is_empty():
						continue
					var dup := false
					for x in marks:
						if str(x["side"]) == str(m["side"]) and absf(float(x["dist_in"]) - float(m["dist_in"])) < 1e-3 \
								and str(x["from_corner"]) == str(m["from_corner"]):
							dup = true
					if not dup:
						marks.append(m)
					if occupied.has(_neighbour(str(m["side"]), int(cell["row"]), int(cell["col"]))):
						taper_on_seam = true
		var pb := bbox(local)
		var piece_id := "R%dC%d" % [int(cell["row"]) + 1, int(cell["col"]) + 1]
		if not is_full and minf(float(pb["w"]), float(pb["h"])) < SLIVER_IN:
			warnings.append({"code": "sliver", "piece_ids": [piece_id],
				"message": "Piece %s is only %s in across; consider shifting the sheet layout (align) or the split height." % [
					piece_id, str(rnd(minf(float(pb["w"]), float(pb["h"])), 2))]})
		if taper_on_seam:
			warnings.append({"code": "seam-on-taper", "piece_ids": [piece_id],
				"message": "A tapered cut on %s runs into a seam; cut both neighbouring pieces before fitting so the taper lines up." % piece_id})
		var poly_local: Array = []
		for p in local:
			poly_local.append(Vector2(rnd((p as Vector2).x), rnd((p as Vector2).y)))
		pieces.append({
			"piece_id": piece_id, "row": int(cell["row"]), "col": int(cell["col"]),
			"cell_x": rnd(float(cell["x0"])), "cell_y": rnd(float(cell["y0"])),
			"polygon_2d": poly_local, "is_full_sheet": is_full, "has_cut": has_cut,
			"bbox_w": rnd(float(pb["w"])), "bbox_h": rnd(float(pb["h"])),
			"area_in2": rnd(area, 1), "waste_in2": rnd(cw2 * ch2 - area, 1),
			"edges": edges, "marks": marks,
			"offcut": null if is_full else {"area_in2": rnd(maxf(0.0, cw2 * ch2 - area - kerf_in * (float(pb["w"]) + float(pb["h"]))), 1)},
		})
	var seams := seam_count / 2.0   # every seam is counted from both sides
	if seams > 0.0:
		var ids: Array = []
		for pc in pieces:
			ids.append(pc["piece_id"])
		warnings.append({"code": "batten", "piece_ids": ids,
			"message": "%s seam%s between sheets (%s ft): there is no framing between the uprights, so back each seam with a batten or cleat." % [
				_num_str(seams), "" if seams == 1.0 else "s", str(rnd(seam_linear / 2.0 / 12.0, 1))]})
	return {
		"orientation": best["orientation"], "align": best["align"],
		"cell_w": cw2, "cell_h": ch2, "cols": int(lay2["cols"]), "rows": int(lay2["rows"]),
		"origin_x": rnd(float(lay2["origin_x"])), "origin_y": rnd(float(lay2["origin_y"])),
		"polygon_bbox": {"w": rnd(float(box["w"])), "h": rnd(float(box["h"]))},
		"pieces": pieces, "sheet_count": pieces.size(),
		"polygon_area_in2": rnd(poly_area, 1), "used_area_in2": rnd(poly_area, 1),
		"stock_area_in2": rnd(pieces.size() * cw2 * ch2, 1),
		"utilization": rnd(float(best["utilization"]), 4),
		"seam_count": seams, "seam_linear_in": rnd(seam_linear / 2.0),
		"warnings": warnings,
		"stock": {"width_in": width_in, "length_in": length_in, "thickness_in": _pos(stock.get("thicknessIn"), 0.5), "kerf_in": kerf_in},
	}


static func _num_str(v: float) -> String:
	return str(int(v)) if v == floorf(v) else str(v)


static func _pos(v, def: float) -> float:
	return float(v) if (v is float or v is int) and float(v) != 0.0 else def


static func _neighbour(side: String, r: int, c: int) -> String:
	match side:
		"left":
			return "%d:%d" % [r, c - 1]
		"right":
			return "%d:%d" % [r, c + 1]
		"bottom":
			return "%d:%d" % [r - 1, c]
	return "%d:%d" % [r + 1, c]


## nestPolygonOnSheets's layout preference: fewer sheets; then (when the
## utilisations are within 2 %) no thin strips; then utilisation; then fewer
## cut pieces.
static func _better(cand: Dictionary, best: Dictionary) -> bool:
	if best.is_empty():
		return true
	if int(cand["sheet_count"]) != int(best["sheet_count"]):
		return int(cand["sheet_count"]) < int(best["sheet_count"])
	var close_util := absf(float(cand["utilization"]) - float(best["utilization"])) <= 0.02
	if close_util and minf(float(cand["min_piece_dim"]), 12.0) != minf(float(best["min_piece_dim"]), 12.0):
		return float(cand["min_piece_dim"]) > float(best["min_piece_dim"])
	if not close_util:
		return float(cand["utilization"]) > float(best["utilization"])
	return int(cand["cut_pieces"]) < int(best["cut_pieces"])


static func _empty_nest(stock: Dictionary) -> Dictionary:
	return {
		"orientation": "landscape", "align": "center",
		"cell_w": _pos(stock.get("lengthIn"), 96.0), "cell_h": _pos(stock.get("widthIn"), 48.0),
		"cols": 0, "rows": 0, "origin_x": 0.0, "origin_y": 0.0, "polygon_bbox": {"w": 0.0, "h": 0.0},
		"pieces": [], "sheet_count": 0, "polygon_area_in2": 0.0, "used_area_in2": 0.0,
		"stock_area_in2": 0.0, "utilization": 0.0, "seam_count": 0.0, "seam_linear_in": 0.0, "warnings": [],
		"stock": {"width_in": _pos(stock.get("widthIn"), 48.0), "length_in": _pos(stock.get("lengthIn"), 96.0),
			"thickness_in": _pos(stock.get("thicknessIn"), 0.5), "kerf_in": _pos(stock.get("kerfIn"), 0.0)},
	}
