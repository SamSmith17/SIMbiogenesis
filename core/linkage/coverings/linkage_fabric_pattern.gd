class_name LinkageFabricPattern
extends RefCounted
## Flat patterns for fabric bands (port of `js/linkage/fabric-patterns.js`,
## A4): the band shrunk for stretch, split into roll-width panels, each with
## its seam / hem allowances offset outward and grommets along the hems.
##
## Pure. Points are Vector2 (inches); keys are snake_case.

const EPS := 1e-6


## Offset a convex CCW polygon outward edge by edge (`offsetConvexPolygon`).
## `allowance` is one distance or an Array, one per edge (edge i = p[i]→p[i+1]).
static func offset_convex_polygon(poly: Array, allowance) -> Array:
	var n := poly.size()
	if n < 3:
		return poly.duplicate()
	var lines: Array = []
	for i in n:
		var a: Vector2 = poly[i]
		var b: Vector2 = poly[(i + 1) % n]
		var dv := b - a
		var ln := dv.length()
		if ln == 0.0:
			ln = 1.0
		var nrm := Vector2(dv.y / ln, -dv.x / ln)   # outward for CCW
		var d: float = (float(allowance[i]) if i < (allowance as Array).size() else 0.0) if allowance is Array else float(allowance)
		lines.append({"p": a + nrm * d, "d": dv / ln})
	var out: Array = []
	for i in n:
		var l1: Dictionary = lines[(i + n - 1) % n]
		var l2: Dictionary = lines[i]
		var d1: Vector2 = l1["d"]
		var d2: Vector2 = l2["d"]
		var den := d1.x * d2.y - d1.y * d2.x
		if absf(den) < 1e-9:
			out.append(l2["p"])
			continue
		var w: Vector2 = (l2["p"] as Vector2) - (l1["p"] as Vector2)
		var t := (w.x * d2.y - w.y * d2.x) / den
		out.append((l1["p"] as Vector2) + d1 * t)
	return out


static func _scale_about_centroid(poly: Array, k: float) -> Array:
	var c := Vector2.ZERO
	for p in poly:
		c += p
	c /= poly.size()
	var out: Array = []
	for p in poly:
		out.append(c + ((p as Vector2) - c) * k)
	return out


static func _grommets_along_edge(a: Vector2, b: Vector2, spacing: float) -> Array:
	var ln := a.distance_to(b)
	var count := maxi(2, int(floor(ln / spacing + EPS)) + 1)
	var pts: Array = []
	for i in count:
		var t := 0.0 if count == 1 else float(i) / float(count - 1)
		pts.append(a + (b - a) * t)
	return pts


static func _pos(v, def: float) -> float:
	return float(v) if (v is float or v is int) and float(v) != 0.0 else def


## The pattern for one band (`buildFabricPattern`). cfg: {rollWidthIn,
## hemIn, seamIn, stretchPct, grommetSpacingIn} (the web's config keys).
static func build(corners_2d: Array, cfg: Dictionary = {}) -> Dictionary:
	var roll := _pos(cfg.get("rollWidthIn"), 60.0)
	var hem := _pos(cfg.get("hemIn"), 0.0)
	var seam := _pos(cfg.get("seamIn"), 0.0)
	var stretch := _pos(cfg.get("stretchPct"), 0.0)
	var spacing := _pos(cfg.get("grommetSpacingIn"), 12.0)
	var geom := LinkageSheetNesting.ensure_ccw(LinkageSheetNesting.to_xy(corners_2d))
	if geom.size() < 3:
		return {"finished_2d": [], "panels": [], "panel_count": 0, "grommet_count": 0, "seam_count": 0,
			"seam_linear_in": 0.0, "fabric_linear_in": 0.0, "fabric_yards": 0.0, "area_in2": 0.0,
			"finished_area_in2": 0.0, "roll_width_in": roll}
	var k := maxf(0.5, 1.0 - stretch / 100.0)
	var finished := _scale_about_centroid(geom, k)
	var fb := LinkageSheetNesting.bbox(finished)
	var usable := maxf(1.0, roll - 2.0 * seam)
	var panel_count := maxi(1, int(ceil(float(fb["w"]) / usable - EPS)))
	var strip_w := float(fb["w"]) / panel_count
	var panels: Array = []
	var grommet_count := 0
	var seam_linear := 0.0
	var fabric_linear := 0.0
	var area := 0.0
	for i in panel_count:
		var x0 := float(fb["min_x"]) + i * strip_w
		var x1 := float(fb["max_x"]) if i == panel_count - 1 else float(fb["min_x"]) + (i + 1) * strip_w
		var piece := LinkageSheetNesting.ensure_ccw(LinkageSheetNesting.clip_polygon_to_rect(
			finished, x0, float(fb["min_y"]) - 1.0, x1, float(fb["max_y"]) + 1.0))
		if piece.size() < 3:
			continue
		var seam_edges: Array = []
		var hem_edges: Array = []
		var allowance: Array = []
		for e in piece.size():
			var a: Vector2 = piece[e]
			var b: Vector2 = piece[(e + 1) % piece.size()]
			var on_left := i > 0 and absf(a.x - x0) < 1e-3 and absf(b.x - x0) < 1e-3
			var on_right := i < panel_count - 1 and absf(a.x - x1) < 1e-3 and absf(b.x - x1) < 1e-3
			if on_left or on_right:
				seam_edges.append(e)
				allowance.append(seam)
				seam_linear += a.distance_to(b)
			else:
				hem_edges.append(e)
				allowance.append(hem)
		var cut := offset_convex_polygon(piece, allowance)
		# Grommets on the hem edges of the finished outline, one per shared corner.
		var grommets: Array = []
		for e in hem_edges:
			var a2: Vector2 = piece[e]
			var b2: Vector2 = piece[(e + 1) % piece.size()]
			for g in _grommets_along_edge(a2, b2, spacing):
				var dup := false
				for q in grommets:
					if absf((q as Vector2).x - g.x) < 0.05 and absf((q as Vector2).y - g.y) < 0.05:
						dup = true
				if not dup:
					grommets.append(g)
		grommet_count += grommets.size()
		var cb := LinkageSheetNesting.bbox(cut)
		var piece_area := LinkageSheetNesting.polygon_area(cut)
		area += piece_area
		fabric_linear += float(cb["h"])
		var base := Vector2(float(cb["min_x"]), float(cb["min_y"]))
		var rb := func(p: Vector2) -> Vector2: return Vector2(LinkageSheetNesting.rnd(p.x - base.x), LinkageSheetNesting.rnd(p.y - base.y))
		panels.append({
			"index": i,
			"label": "Panel %d of %d" % [i + 1, panel_count] if panel_count > 1 else "Panel",
			"cut_2d": cut.map(rb), "finished_2d": piece.map(rb), "grommets": grommets.map(rb),
			"seam_edges": seam_edges, "hem_edges": hem_edges,
			"bbox_w": LinkageSheetNesting.rnd(float(cb["w"])), "bbox_h": LinkageSheetNesting.rnd(float(cb["h"])),
			"area_in2": LinkageSheetNesting.rnd(piece_area, 1), "fits_roll": float(cb["w"]) <= roll + 1e-3,
		})
	var gb := LinkageSheetNesting.bbox(geom)
	var fbase := Vector2(float(fb["min_x"]), float(fb["min_y"]))
	return {
		"finished_2d": finished.map(func(p: Vector2) -> Vector2: return Vector2(LinkageSheetNesting.rnd(p.x - fbase.x), LinkageSheetNesting.rnd(p.y - fbase.y))),
		"finished_bbox": {"w": LinkageSheetNesting.rnd(float(fb["w"])), "h": LinkageSheetNesting.rnd(float(fb["h"]))},
		"geometry_bbox": {"w": LinkageSheetNesting.rnd(float(gb["w"])), "h": LinkageSheetNesting.rnd(float(gb["h"]))},
		"shrink_factor": LinkageSheetNesting.rnd(k, 4),
		"panels": panels, "panel_count": panels.size(), "grommet_count": grommet_count,
		"seam_count": maxi(0, panels.size() - 1), "seam_linear_in": LinkageSheetNesting.rnd(seam_linear / 2.0),
		"fabric_linear_in": LinkageSheetNesting.rnd(fabric_linear), "fabric_yards": LinkageSheetNesting.rnd(fabric_linear / 36.0, 2),
		"area_in2": LinkageSheetNesting.rnd(area, 1), "finished_area_in2": LinkageSheetNesting.rnd(LinkageSheetNesting.polygon_area(finished), 1),
		"roll_width_in": roll, "hem_in": hem, "seam_in": seam, "stretch_pct": stretch, "grommet_spacing_in": spacing,
	}
