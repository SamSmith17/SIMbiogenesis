class_name DomeLabPanels
extends RefCounted

## Faces as flat parts: a panel per face (triangle or rhombus), inset by the
## seam gap, with screw holes along its edges for a covered strut frame, or —
## for the plate system — with a FLANGE folded along every edge so the plates
## bolt to each other and ARE the structure. Nested onto sheets with
## FlatpackNesting; the rings are FlatpackProfile rings in MILLIMETRES.
##
## A flange is a strip `w` wide outside each edge, mitred at the corners
## along the exterior angle's bisector (ext = w · tan(exterior / 2)) and cut
## back by a small relief so the two folded flanges clear each other; the
## flat pattern is one ring that dips to each vertex. Fold lines run along
## the face edges and carry the bend angle (half the angle between the two
## face normals). Pure static.
##
## build(geo, edges, fidx, spec) → {panels: [{id, face, n_sides, ring, holes
##   (rings), fold: [[a, b, bend_deg]], bbox (Rect2 mm), area_mm2, frame:
##   Transform3D (panel mm → world m), label, class_key}], classes: [{label,
##   count, sides_mm, area_mm2, ids}], nest, sheet: {w, h}, area_m2,
##   unplaced, warnings}

const MIN_HOLES_PER_EDGE := 2
const HOLE_END_MARGIN_MM := 20.0


static func build(geo: Dictionary, edges: Array, fidx: Dictionary, spec: Dictionary) -> Dictionary:
	var face: Dictionary = spec["face"]
	var mat := DomeLabMaterials.sheet(str(face["material"]))
	var empty := {"panels": [], "classes": [], "nest": {"sheets": [], "unplaced": []},
		"sheet": {"w": 0.0, "h": 0.0}, "area_m2": 0.0, "unplaced": [], "warnings": [], "mass_kg": 0.0}
	if str(face["material"]) == "none":
		return empty
	var plate := str(spec["system"]) == "plate"
	var verts: PackedVector3Array = geo["verts"]
	var faces: Array = geo["faces"]
	var fnormals: PackedVector3Array = fidx["normals"]
	var by_edge: Dictionary = fidx["by_edge"]
	var gap := float(face["gap_mm"])
	var flange := float(face["flange_mm"]) if plate else 0.0
	var pitch := float(face["hole_pitch_mm"])
	var screw := float(face["screw_mm"])
	var t_mm := float(mat.get("t_mm", 3.0))
	var strut_w := DomeLabMaterials.strut_width_mm(DomeLabMaterials.strut(str(spec["strut"]["material"])))
	var warnings: Array = []
	var panels: Array = []
	var edge_by_key := {}
	for ei in edges.size():
		var e: Dictionary = edges[ei]
		edge_by_key[DomeLabGeodesic._ekey(int(e["a"]), int(e["b"]))] = ei
	for fi in faces.size():
		var f: PackedInt32Array = faces[fi]
		var m := f.size()
		var c := Vector3.ZERO
		for id in f:
			c += verts[id]
		c /= m
		var n := fnormals[fi]
		var u := (verts[f[1]] - verts[f[0]]).normalized()
		var v := n.cross(u).normalized()
		u = v.cross(n).normalized()
		var poly := PackedVector2Array()
		for id in f:
			var d := verts[id] - c
			poly.append(Vector2(d.dot(u), d.dot(v)) * 1000.0)
		# Faces are CCW seen from outside; make the 2D ring CCW as drawn.
		if _signed_area(poly) < 0.0:
			poly.reverse()
			f = f.duplicate()
			f.reverse()
		var inner := _inset(poly, gap * 0.5)
		if inner.is_empty():
			warnings.append("face %d is too small for a %s gap" % [fi, DomeLabSpec.fmt_len(gap)])
			continue
		var folds: Array = []
		var bends: Array = []
		for k in m:
			var key := DomeLabGeodesic._ekey(f[k], f[(k + 1) % m])
			var ei := int(edge_by_key.get(key, -1))
			var bend := rad_to_deg(float((edges[ei] as Dictionary)["flange_bend"])) if ei >= 0 else 0.0
			bends.append(bend)
			folds.append([inner[k], inner[(k + 1) % m], bend])
		var ring_pts := inner
		var holes: Array = []
		if plate:
			ring_pts = _with_flanges(inner, flange, t_mm)
			for k in m:
				var a := inner[k]
				var b := inner[(k + 1) % m]
				var mn := _outward(inner, k)
				for q in _spaced(a, b, pitch, HOLE_END_MARGIN_MM + flange * 0.3):
					holes.append(FlatpackProfile.circle_ring(q + mn * (flange * 0.5), _bolt_hole(spec) * 0.5))
		else:
			var inset := maxf(strut_w * 0.5, 8.0) - gap * 0.5
			for k in m:
				var a := inner[k]
				var b := inner[(k + 1) % m]
				var mn := _outward(inner, k)
				for q in _spaced(a, b, pitch, HOLE_END_MARGIN_MM + inset):
					holes.append(FlatpackProfile.circle_ring(q - mn * inset, screw * 0.5))
		# Turn the part so its bounding box is smallest (an edge along x):
		# that is what lets a 3V panel on a 4 x 8 sheet fit at all.
		var ang := _best_rotation(ring_pts)
		if absf(ang) > 1e-9:
			inner = _rot_poly(inner, ang)
			ring_pts = _rot_poly(ring_pts, ang)
			for hi in holes.size():
				holes[hi] = FlatpackProfile.transform_ring(holes[hi], -ang, Vector2.ZERO)
			for fi2 in folds.size():
				folds[fi2] = [(folds[fi2][0] as Vector2).rotated(-ang), (folds[fi2][1] as Vector2).rotated(-ang), folds[fi2][2]]
			var u2 := u * cos(ang) + v * sin(ang)
			var v2 := -u * sin(ang) + v * cos(ang)
			u = u2
			v = v2
		var ring := FlatpackProfile.make_ring(ring_pts)
		var tess := ring_pts
		var bb := FlatpackProfile.bbox(tess)
		var sides: Array = []
		for k in m:
			sides.append(inner[k].distance_to(inner[(k + 1) % m]))
		var sorted_sides := sides.duplicate()
		sorted_sides.sort()
		var tol := float(spec["fabrication"]["group_tol_mm"])
		var parts: PackedStringArray = []
		for sd in sorted_sides:
			parts.append(str(int(round(float(sd) / tol))))
		var bkey := "|".join(parts)
		var frame := Transform3D(Basis(u * 0.001, v * 0.001, n * 0.001), c)
		panels.append({"id": "p%d" % fi, "face": fi, "n_sides": m, "ring": ring, "holes": holes,
			"fold": folds, "bends": bends, "bbox": bb, "area_mm2": absf(_signed_area(tess)),
			"frame": frame, "class_key": bkey, "sides_mm": sides, "poly": inner, "flange_mm": flange,
			"outer": ring_pts})
	# Classes (congruent panels).
	var classes := {}
	for p in panels:
		var k := str(p["class_key"])
		if not classes.has(k):
			classes[k] = {"key": k, "count": 0, "ids": [], "sides_mm": p["sides_mm"],
				"area_mm2": float(p["area_mm2"]), "n_sides": int(p["n_sides"]), "bends": p["bends"]}
		(classes[k] as Dictionary)["count"] = int((classes[k] as Dictionary)["count"]) + 1
		((classes[k] as Dictionary)["ids"] as Array).append(str(p["id"]))
	var clist: Array = classes.values()
	clist.sort_custom(func(x, y): return float(x["area_mm2"]) < float(y["area_mm2"]))
	for i in clist.size():
		(clist[i] as Dictionary)["label"] = "P%d" % (i + 1)
	var by_key := {}
	for cl in clist:
		by_key[cl["key"]] = cl["label"]
	var counters := {}
	for p in panels:
		var lab := str(by_key[p["class_key"]])
		counters[lab] = int(counters.get(lab, 0)) + 1
		p["label"] = "%s-%d" % [lab, int(counters[lab])]
		p["type"] = lab
	# Nest onto sheets.
	var fab: Dictionary = spec["fabrication"]
	var sw := float(fab["sheet_w_mm"]) if float(fab["sheet_w_mm"]) > 0.0 else float(mat["sheet_w"])
	var sh := float(fab["sheet_h_mm"]) if float(fab["sheet_h_mm"]) > 0.0 else float(mat["sheet_h"])
	var area := 0.0
	for p in panels:
		area += float(p["area_mm2"])
	var kerf := float(fab["kerf_mm"])
	# Congruent triangles go down as STRIPS of alternating up / down parts
	# (the way triangles are really cut from a sheet): a row is one nest
	# item, its parts `pitch` apart, every second one turned 180°. The pitch
	# is found by sliding the turned copy along the row until the outlines
	# just clear each other plus the kerf.
	var rows := _strip_rows(panels, clist, maxf(sw, sh), kerf)
	var items: Array = []
	var by_item := {}
	for r in rows:
		items.append({"id": str(r["id"]), "w": float(r["w"]), "h": float(r["h"]), "rot_ok": true})
		by_item[str(r["id"])] = r
	var nest := FlatpackNesting.nest(items, sw, sh, kerf, kerf * 2.0) \
		if sw > 0.0 and sh > 0.0 else {"sheets": [], "unplaced": [], "sheet_w": 0.0, "sheet_h": 0.0}
	var unplaced: Array = []
	for un in nest["unplaced"]:
		var r: Dictionary = by_item[str(un)]
		for pid in r["parts"]:
			unplaced.append(str(pid))
			var p := _panel({"panels": panels}, str(pid))
			if not p.is_empty():
				var bb: Rect2 = p["bbox"]
				warnings.append("%s (%s × %s) does not fit a %s × %s sheet" % [str(p["label"]),
					DomeLabSpec.fmt_len(bb.size.x), DomeLabSpec.fmt_len(bb.size.y),
					DomeLabSpec.fmt_len(sw), DomeLabSpec.fmt_len(sh)])
	# Expand the rows into one placement per part, in FlatpackNesting's
	# {x, y, rot} form so the sheet geometry helpers read them unchanged.
	var out_sheets: Array = []
	for shd in nest["sheets"]:
		var pls: Array = []
		for pl in shd["placements"]:
			var r: Dictionary = by_item[str(pl["id"])]
			var row_pitch := float(r["pitch"])
			for k in (r["parts"] as Array).size():
				var pid := str(r["parts"][k])
				var p := _panel({"panels": panels}, pid)
				var off := k * row_pitch
				var ppl := {"id": pid, "w": float(p["bbox"].size.x), "h": float(p["bbox"].size.y),
					"rot": bool(pl["rot"]), "x": float(pl["x"]), "y": float(pl["y"])}
				if bool(pl["rot"]):
					ppl["y"] = float(pl["y"]) + off
				else:
					ppl["x"] = float(pl["x"]) + off
				p["sheet"] = int(shd["index"])
				p["placement"] = ppl
				pls.append(ppl)
		out_sheets.append({"index": int(shd["index"]), "placements": pls})
	nest["sheets"] = out_sheets
	nest["unplaced"] = unplaced
	var area_m2 := area * 1e-6
	return {"panels": panels, "classes": clist, "nest": nest, "sheet": {"w": sw, "h": sh},
		"area_m2": area_m2, "unplaced": nest["unplaced"], "warnings": warnings,
		"mass_kg": area_m2 * float(mat.get("kg_m2", 0.0)), "material": mat,
		"sheets": (nest["sheets"] as Array).size()}


## Rows of congruent triangles, alternating up / down; every other part's
## 2D data is turned 180° about its bounding-box centre (the box is
## unchanged, the 3D frame follows). Returns [{id, w, h, pitch, parts}];
## other panels become rows of one.
static func _strip_rows(panels: Array, classes: Array, row_max: float, kerf: float) -> Array:
	var rows: Array = []
	var done := {}
	for c in classes:
		var ids: Array = c["ids"]
		var first := _panel({"panels": panels}, str(ids[0]))
		if first.is_empty():
			continue
		var bb: Rect2 = first["bbox"]
		var pitch := bb.size.x + kerf
		var strip := int(c["n_sides"]) == 3 and ids.size() >= 2
		if strip:
			pitch = _pair_pitch(first["outer"], bb, kerf)
		var per_row := maxi(1, int(floor((row_max - 4.0 * kerf - bb.size.x) / pitch)) + 1) if strip else 1
		var k := 0
		while k < ids.size():
			var take := mini(per_row, ids.size() - k)
			var parts: Array = []
			for j in take:
				var pid := str(ids[k + j])
				if j % 2 == 1:
					_turn_panel(_panel({"panels": panels}, pid))
				parts.append(pid)
				done[pid] = true
			rows.append({"id": "row_%d" % rows.size(), "w": bb.size.x + (take - 1) * pitch, "h": bb.size.y,
				"pitch": pitch, "parts": parts})
			k += take
	for p in panels:
		if not done.has(str(p["id"])):
			var bb: Rect2 = p["bbox"]
			rows.append({"id": "row_%d" % rows.size(), "w": bb.size.x, "h": bb.size.y, "pitch": 0.0,
				"parts": [str(p["id"])]})
	return rows


## The smallest shift along x at which a 180°-turned copy of the outline no
## longer overlaps it (bisection on polygon intersection), plus the kerf.
static func _pair_pitch(outer: PackedVector2Array, bb: Rect2, kerf: float) -> float:
	var c := bb.get_center()
	var turned := PackedVector2Array()
	for q in outer:
		turned.append(c * 2.0 - q)
	var lo := bb.size.x * 0.3
	var hi := bb.size.x
	for _i in 22:
		var mid := (lo + hi) * 0.5
		var shifted := PackedVector2Array()
		for q in turned:
			shifted.append(q + Vector2(mid, 0.0))
		if Geometry2D.intersect_polygons(outer, shifted).is_empty():
			hi = mid
		else:
			lo = mid
	return hi + kerf


static func _turn_panel(p: Dictionary) -> void:
	if p.is_empty():
		return
	var bb: Rect2 = p["bbox"]
	var c := bb.get_center()
	var turn := func(q: Vector2) -> Vector2: return c * 2.0 - q
	var poly := PackedVector2Array()
	for q in (p["poly"] as PackedVector2Array):
		poly.append(turn.call(q))
	p["poly"] = poly
	var outer := PackedVector2Array()
	for q in (p["outer"] as PackedVector2Array):
		outer.append(turn.call(q))
	p["outer"] = outer
	p["ring"] = FlatpackProfile.transform_ring(p["ring"], PI, c * 2.0)
	var holes: Array = []
	for h in p["holes"]:
		holes.append(FlatpackProfile.transform_ring(h, PI, c * 2.0))
	p["holes"] = holes
	var folds: Array = []
	for f in p["fold"]:
		folds.append([turn.call(f[0]), turn.call(f[1]), f[2]])
	p["fold"] = folds
	var fr: Transform3D = p["frame"]
	var o := fr * Vector3(c.x * 2.0, c.y * 2.0, 0.0) - fr.basis.z * 0.0
	# q' = 2c − q  ⇒  world = fr(2c) − fr.basis(q'): flip u and v, move the origin.
	p["frame"] = Transform3D(Basis(-fr.basis.x, -fr.basis.y, fr.basis.z), o)
	p["turned"] = true


## The rotation (radians) putting one of the polygon's edges along x that
## gives the smallest bounding box.
static func _best_rotation(poly: PackedVector2Array) -> float:
	var n := poly.size()
	var best := 0.0
	var best_area := INF
	for k in n:
		var e := poly[(k + 1) % n] - poly[k]
		if e.length() < 1e-9:
			continue
		var a := e.angle()
		var bb := FlatpackProfile.bbox(_rot_poly(poly, a))
		var area := bb.size.x * bb.size.y
		if area < best_area - 1e-6:
			best_area = area
			best = a
	return best


static func _rot_poly(poly: PackedVector2Array, ang: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for q in poly:
		out.append(q.rotated(-ang))
	return out


static func _bolt_hole(spec: Dictionary) -> float:
	return float(DomeLabMaterials.bolt(str(spec["hub"]["bolt"]))["hole_mm"])


static func _signed_area(p: PackedVector2Array) -> float:
	var a := 0.0
	var n := p.size()
	for i in n:
		var q := p[i]
		var r := p[(i + 1) % n]
		a += q.x * r.y - r.x * q.y
	return a * 0.5


## Outward unit normal of edge k of a CCW polygon.
static func _outward(poly: PackedVector2Array, k: int) -> Vector2:
	var a := poly[k]
	var b := poly[(k + 1) % poly.size()]
	var e := (b - a).normalized()
	return Vector2(e.y, -e.x)


## Inset a convex CCW polygon by `d` (every edge moved inward).
static func _inset(poly: PackedVector2Array, d: float) -> PackedVector2Array:
	var n := poly.size()
	if d <= 1e-9:
		return poly.duplicate()
	var out := PackedVector2Array()
	for k in n:
		var a_prev := poly[(k - 1 + n) % n]
		var a := poly[k]
		var a_next := poly[(k + 1) % n]
		var n1 := _outward_of(a_prev, a)
		var n2 := _outward_of(a, a_next)
		var p1 := a - n1 * d
		var p2 := a - n2 * d
		var d1 := (a - a_prev).normalized()
		var d2 := (a_next - a).normalized()
		var hit := _line_hit(p1, d1, p2, d2)
		if hit.is_empty():
			out.append(a - (n1 + n2).normalized() * d)
		else:
			out.append(hit["p"])
	if _signed_area(out) <= 1.0:
		return PackedVector2Array()
	return out


static func _outward_of(a: Vector2, b: Vector2) -> Vector2:
	var e := (b - a).normalized()
	return Vector2(e.y, -e.x)


static func _line_hit(p1: Vector2, d1: Vector2, p2: Vector2, d2: Vector2) -> Dictionary:
	var den := d1.x * d2.y - d1.y * d2.x
	if absf(den) < 1e-9:
		return {}
	var r := p2 - p1
	var t := (r.x * d2.y - r.y * d2.x) / den
	return {"p": p1 + d1 * t}


## The flat pattern of a plate: face polygon + a mitred flange on each edge.
static func _with_flanges(poly: PackedVector2Array, w: float, t_mm: float) -> PackedVector2Array:
	var n := poly.size()
	var relief := clampf(t_mm * 2.0, 2.0, w * 0.3)
	var out := PackedVector2Array()
	for k in n:
		var a := poly[k]
		var b := poly[(k + 1) % n]
		var e := (b - a).normalized()
		var mn := _outward(poly, k)
		var ext_a := _mitre_ext(poly, k, w) - relief
		var ext_b := _mitre_ext(poly, (k + 1) % n, w) - relief
		out.append(a)
		out.append(a + mn * w - e * maxf(ext_a, 0.0))
		out.append(b + mn * w + e * maxf(ext_b, 0.0))
	# Each vertex appears once (the dip to the corner between two flanges).
	return out


## How far a flange's end extends past the vertex along the edge: the mitre
## along the exterior angle's bisector.
static func _mitre_ext(poly: PackedVector2Array, k: int, w: float) -> float:
	var n := poly.size()
	var a := poly[(k - 1 + n) % n]
	var b := poly[k]
	var c := poly[(k + 1) % n]
	var d1 := (b - a).normalized()
	var d2 := (c - b).normalized()
	var interior := PI - acos(clampf(d1.dot(d2), -1.0, 1.0))
	var exterior := PI - interior
	# An acute corner's full mitre runs away (tan → ∞); past 1.5 × w the
	# flanges are simply cut short and the corner left open.
	return minf(w * tan(clampf(exterior * 0.5, 0.0, 1.3)), 1.5 * w)


## Points along a → b at `pitch` (at least MIN_HOLES_PER_EDGE), `margin` in
## from both ends.
static func _spaced(a: Vector2, b: Vector2, pitch: float, margin: float) -> Array:
	var L := a.distance_to(b)
	var usable := L - 2.0 * margin
	var out: Array = []
	if usable <= 0.0:
		out.append((a + b) * 0.5)
		return out
	var count := maxi(MIN_HOLES_PER_EDGE, int(floor(usable / pitch)) + 1)
	var e := (b - a).normalized()
	for i in count:
		var t := margin + usable * (float(i) / float(count - 1)) if count > 1 else L * 0.5
		out.append(a + e * t)
	return out


## Everything on one sheet in FlatpackCam's content shape (mm, y up), plus
## fold lines: {w, h, outside, inside, fold: [{a, b, text}], labels}.
static func sheet_content(result: Dictionary, sheet_index: int) -> Dictionary:
	var nest: Dictionary = result["nest"]
	var out := {"w": float(result["sheet"]["w"]), "h": float(result["sheet"]["h"]), "outside": [],
		"inside": [], "fold": [], "labels": []}
	for shd in nest.get("sheets", []):
		if int(shd["index"]) != sheet_index:
			continue
		for pl in shd["placements"]:
			var p := _panel(result, str(pl["id"]))
			if p.is_empty():
				continue
			var bb: Rect2 = p["bbox"]
			(out["outside"] as Array).append(FlatpackNesting.ring_on_sheet(p["ring"], bb, pl))
			for h in p["holes"]:
				(out["inside"] as Array).append(FlatpackNesting.ring_on_sheet(h, bb, pl))
			if float(p.get("flange_mm", 0.0)) > 0.0:
				for fl in p["fold"]:
					(out["fold"] as Array).append({"a": FlatpackNesting.point_on_sheet(fl[0], bb, pl),
						"b": FlatpackNesting.point_on_sheet(fl[1], bb, pl), "text": "%.1f°" % float(fl[2])})
			var cen := Vector2.ZERO
			for q in (p["poly"] as PackedVector2Array):
				cen += q
			cen /= maxi((p["poly"] as PackedVector2Array).size(), 1)
			(out["labels"] as Array).append({"p": FlatpackNesting.point_on_sheet(cen, bb, pl),
				"size": clampf(minf(bb.size.x, bb.size.y) * 0.12, 8.0, 40.0), "text": str(p["label"]),
				"rot": 0.0})
	return out


static func _panel(result: Dictionary, id: String) -> Dictionary:
	for p in result["panels"]:
		if str(p["id"]) == id:
			return p
	return {}
