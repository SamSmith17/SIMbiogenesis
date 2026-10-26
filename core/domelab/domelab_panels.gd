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
## In 3D a plate is a SOLID folded sheet (flange_section): the face plate,
## a bend of the chosen inside radius, and a flange lying parallel to the
## plane that bisects the dihedral, so two neighbours' flanges meet back to
## back with the seam gap between them — the bolted flange pair IS the strut
## (SPACEPLATES). Bolt holes are laid out per EDGE, so both plates of an
## edge are drilled at the same places. An opening (oculus) is the face
## inset by oculus_mm with rounded corners; a glazing pane laps it.
##
## build(geo, edges, fidx, spec) → {panels: [{id, face, n_sides, ring, holes
##   (rings), fold: [[a, b, bend_deg]], bbox (Rect2 mm), area_mm2, frame:
##   Transform3D (panel mm → world m), label, class_key}], classes: [{label,
##   count, sides_mm, area_mm2, ids}], nest, sheet: {w, h}, area_m2,
##   unplaced, warnings}

const MIN_HOLES_PER_EDGE := 2
const HOLE_END_MARGIN_MM := 20.0
const PANE_LAP_MM := 25.0
const ARC_STEPS := 6


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
	var t_mm := float(face["thickness_mm"]) if float(face["thickness_mm"]) > 0.0 else float(mat.get("t_mm", 3.0))
	var fold_r := float(face["fold_radius_mm"]) if float(face["fold_radius_mm"]) > 0.0 else t_mm
	var zone_of: Array = geo.get("face_zone", [])
	var glaze := DomeLabMaterials.sheet(str(face["glazing"]))
	var oculus_on := bool(face["oculus"])
	var zones: Array = face["oculus_zones"]
	var strut_w := DomeLabMaterials.strut_width_mm(DomeLabMaterials.strut(str(spec["strut"]["material"])))
	var warnings: Array = []
	var panels: Array = []
	var edge_by_key := {}
	for ei in edges.size():
		var e: Dictionary = edges[ei]
		edge_by_key[DomeLabGeodesic._ekey(int(e["a"]), int(e["b"]))] = ei
	# Plates: bolt holes per EDGE (distances from the edge's vertex a, mm) and
	# the bolts in 3D, on the mid-plane between the two flanges.
	var edge_holes := {}
	var bolts3d: Array = []
	var anchors := 0
	if plate:
		var corner := _corner_angles(verts, faces)
		var hole_d := _bolt_hole(spec)
		for ei in edges.size():
			var e: Dictionary = edges[ei]
			var fl: Array = e["faces"]
			if fl.is_empty():
				continue
			var ang := float(e["flange_bend"]) * 2.0 if fl.size() >= 2 else 0.0
			var sec := flange_section(ang, t_mm, fold_r, gap, flange)
			var q: Vector2 = sec["hole"]
			var q_eff := (q - (sec["v"] as Vector2)).length() + (sec["v"] as Vector2).x
			var margin := [HOLE_END_MARGIN_MM, HOLE_END_MARGIN_MM]
			for end in 2:
				var vid := int(e["a"]) if end == 0 else int(e["b"])
				var alpha := PI
				for fi in fl:
					alpha = minf(alpha, float((corner[int(fi)] as Dictionary).get(vid, PI)))
				margin[end] = maxf(HOLE_END_MARGIN_MM, q_eff / tan(alpha * 0.5) + hole_d + 10.0)
			var Lmm := float(e["len"]) * 1000.0
			var usable := Lmm - float(margin[0]) - float(margin[1])
			var ss: Array = []
			if usable <= 0.0:
				ss.append(Lmm * 0.5)
			else:
				var cnt := maxi(MIN_HOLES_PER_EDGE, int(floor(usable / pitch)) + 1)
				for i in cnt:
					ss.append(float(margin[0]) + usable * float(i) / float(cnt - 1))
			edge_holes[ei] = ss
			if fl.size() < 2:
				anchors += ss.size()
				continue
			# 3D: face 0's frame along the edge.
			var f0: PackedInt32Array = faces[int(fl[0])]
			var n0: Vector3 = fnormals[int(fl[0])]
			var pa := verts[int(e["a"])]
			var pb := verts[int(e["b"])]
			var ed := (pb - pa).normalized()
			var cen := Vector3.ZERO
			for id in f0:
				cen += verts[id]
			cen /= f0.size()
			var fin := n0.cross(ed).normalized()
			if fin.dot(cen - pa) < 0.0:
				fin = -fin
			var a2 := ang * 0.5
			var mw := fin * cos(a2) + n0 * sin(a2)
			var hp := q - (sec["m"] as Vector2) * (gap * 0.5)
			for sv in ss:
				var p3 := pa + ed * (float(sv) * 0.001) + fin * (hp.x * 0.001) + n0 * (hp.y * 0.001)
				bolts3d.append({"p": p3, "axis": mw, "edge": ei})
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
		var edge_ang: Array = []
		for k in m:
			var key := DomeLabGeodesic._ekey(f[k], f[(k + 1) % m])
			var ei := int(edge_by_key.get(key, -1))
			var two := ei >= 0 and ((edges[ei] as Dictionary)["faces"] as Array).size() >= 2
			edge_ang.append(float((edges[ei] as Dictionary)["flange_bend"]) * 2.0 if two else 0.0)
		if plate:
			ring_pts = _with_flanges(inner, flange, t_mm)
			for k in m:
				var mn := _outward(inner, k)
				var key := DomeLabGeodesic._ekey(f[k], f[(k + 1) % m])
				var ei := int(edge_by_key.get(key, -1))
				if ei < 0 or not edge_holes.has(ei):
					continue
				var e: Dictionary = edges[ei]
				var rev := int(e["a"]) != int(f[k])
				var Lmm := float(e["len"]) * 1000.0
				var tdir := (poly[(k + 1) % m] - poly[k]).normalized()
				for sv in edge_holes[ei]:
					var sp := Lmm - float(sv) if rev else float(sv)
					var on_edge := poly[k] + tdir * sp - mn * (gap * 0.5)
					holes.append(FlatpackProfile.circle_ring(on_edge + mn * (flange * 0.5), _bolt_hole(spec) * 0.5))
		else:
			var inset := maxf(strut_w * 0.5, 8.0) - gap * 0.5
			for k in m:
				var a := inner[k]
				var b := inner[(k + 1) % m]
				var mn := _outward(inner, k)
				for q in _spaced(a, b, pitch, HOLE_END_MARGIN_MM + inset):
					holes.append(FlatpackProfile.circle_ring(q - mn * inset, screw * 0.5))
		# The opening and its pane.
		var zone := int(zone_of[fi]) if fi < zone_of.size() else 0
		var oculus := PackedVector2Array()
		var pane := PackedVector2Array()
		if oculus_on and (zones.is_empty() or zones.has(zone)):
			oculus = rounded_inset(poly, float(face["oculus_mm"]), float(face["oculus_round"]), 0.0)
			if oculus.is_empty():
				warnings.append("face %d is too small for a %s opening offset" % [fi, DomeLabSpec.fmt_len(float(face["oculus_mm"]))])
			else:
				holes.append(FlatpackProfile.make_ring(oculus))
				if str(face["glazing"]) != "none":
					pane = rounded_inset(poly, maxf(float(face["oculus_mm"]) - PANE_LAP_MM, gap * 0.5 + t_mm + fold_r),
						float(face["oculus_round"]), PANE_LAP_MM)
		var face_poly := poly.duplicate()
		# Turn the part so its bounding box is smallest (an edge along x):
		# that is what lets a 3V panel on a 4 x 8 sheet fit at all.
		var ang := _best_rotation(ring_pts)
		if absf(ang) > 1e-9:
			inner = _rot_poly(inner, ang)
			ring_pts = _rot_poly(ring_pts, ang)
			face_poly = _rot_poly(face_poly, ang)
			oculus = _rot_poly(oculus, ang)
			pane = _rot_poly(pane, ang)
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
			"outer": ring_pts, "face_poly": face_poly, "edge_ang": edge_ang, "zone": zone, "oculus": oculus,
			"pane": pane})
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
	var panes := 0
	var pane_area := 0.0
	var open_area := 0.0
	for p in panels:
		if not (p["oculus"] as PackedVector2Array).is_empty():
			open_area += absf(_signed_area(p["oculus"])) * 1e-6
		if not (p["pane"] as PackedVector2Array).is_empty():
			panes += 1
			pane_area += absf(_signed_area(p["pane"])) * 1e-6
	var kg_scale := t_mm / maxf(float(mat.get("t_mm", t_mm)), 1e-6)
	return {"panels": panels, "classes": clist, "nest": nest, "sheet": {"w": sw, "h": sh},
		"area_m2": area_m2, "unplaced": nest["unplaced"], "warnings": warnings,
		"mass_kg": (area_m2 - open_area) * float(mat.get("kg_m2", 0.0)) * kg_scale + pane_area * float(glaze.get("kg_m2", 0.0)),
		"material": mat, "sheets": (nest["sheets"] as Array).size(), "t_mm": t_mm, "fold_r_mm": fold_r,
		"gap_mm": gap, "flange_mm": flange, "bolts3d": bolts3d, "anchors": anchors, "panes": panes,
		"pane_area_m2": pane_area, "open_area_m2": open_area, "glazing": glaze,
		"glazing_id": str(face["glazing"])}


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
		# Triangles alternate up / down. (Rhombi in edge-to-edge rows were
		# tried: no better on a 2 m plate, worse on small sheets.)
		var tri := int(c["n_sides"]) == 3
		var strip := tri and ids.size() >= 2
		if strip:
			pitch = _pair_pitch(first["outer"], bb, kerf, true)
		var per_row := maxi(1, int(floor((row_max - 4.0 * kerf - bb.size.x) / pitch)) + 1) if strip else 1
		var k := 0
		while k < ids.size():
			var take := mini(per_row, ids.size() - k)
			var parts: Array = []
			for j in take:
				var pid := str(ids[k + j])
				if tri and j % 2 == 1:
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


## The smallest shift along x at which a copy of the outline (turned 180°
## for triangles, as it is for rhombi) no longer overlaps it (bisection on
## polygon intersection), plus the kerf.
static func _pair_pitch(outer: PackedVector2Array, bb: Rect2, kerf: float, turn: bool = true) -> float:
	var c := bb.get_center()
	var turned := PackedVector2Array()
	for q in outer:
		turned.append(c * 2.0 - q if turn else q)
	var lo := bb.size.x * 0.05
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
	for k in ["face_poly", "oculus", "pane"]:
		var pk := PackedVector2Array()
		for q in (p.get(k, PackedVector2Array()) as PackedVector2Array):
			pk.append(turn.call(q))
		p[k] = pk
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



# ---------------------------------------------------------------------------
# The folded sheet in section, openings
# ---------------------------------------------------------------------------

## A flange in section, perpendicular to its edge (mm): x runs INTO the face
## from the edge, y along the face's outward normal; the face's outer skin is
## y = 0. `ang` is the angle between the two faces' normals (0 for a lone
## edge: the flange turns down square). The flange lies parallel to the
## dihedral's bisector plane, its outer skin gap/2 off it, so the
## neighbour's flange meets it back to back; the bend is an arc of inside
## radius r (outside r + t) swept through 90° + ang/2, and the flange runs
## `depth` from the face's skin down the bisector.
## → {a2, R, r, t, xc (where the flat plate ends), c (bend centre), m (unit
##    normal of the bisector plane, into the face), d (down the flange),
##    v (where the skin meets the flange's outer plane), run (straight
##    length), hole (bolt centre on the flange's outer skin), profile
##    (closed outline: outer arc, flange, inner arc)}
static func flange_section(ang: float, t: float, r: float, gap: float, depth: float) -> Dictionary:
	var a2 := clampf(ang * 0.5, 0.0, 1.4)
	var R := r + t
	var ca := cos(a2)
	var sa := sin(a2)
	var m := Vector2(ca, sa)
	var dd := Vector2(sa, -ca)
	var xc := (gap * 0.5 + R * (1.0 + sa)) / ca
	var c := Vector2(xc, -R)
	var v := Vector2(gap * 0.5 / ca, 0.0)
	var t2o := c - m * R
	var run := maxf(depth - (t2o - v).dot(dd), t)
	var prof := PackedVector2Array()
	var sweep := PI * 0.5 + a2
	for i in ARC_STEPS + 1:
		var phi := PI * 0.5 + sweep * float(i) / ARC_STEPS
		prof.append(c + Vector2(cos(phi), sin(phi)) * R)
	var fo := t2o + dd * run
	prof.append(fo)
	prof.append(fo + m * t)
	for i in range(ARC_STEPS, -1, -1):
		var phi := PI * 0.5 + sweep * float(i) / ARC_STEPS
		prof.append(c + Vector2(cos(phi), sin(phi)) * r)
	return {"a2": a2, "R": R, "r": r, "t": t, "xc": xc, "c": c, "m": m, "d": dd, "v": v, "run": run,
		"hole": t2o + dd * (run * 0.5), "profile": prof, "steps": ARC_STEPS}


## A convex CCW polygon inset by `d`, its corners rounded: `round_` 0 = sharp,
## 1 = the largest radius every corner can take; `extra` grows the radius
## (a pane's lap round an opening). Empty when the inset vanishes.
static func rounded_inset(poly: PackedVector2Array, d: float, round_: float, extra: float) -> PackedVector2Array:
	var q := _inset(poly, d)
	var n := q.size()
	if n < 3:
		return PackedVector2Array()
	var rmax := INF
	var ints: Array = []
	for k in n:
		var a := q[(k - 1 + n) % n]
		var b := q[k]
		var c := q[(k + 1) % n]
		var beta := absf((a - b).angle_to(c - b))
		ints.append(beta)
		var half := minf(a.distance_to(b), c.distance_to(b)) * 0.5
		rmax = minf(rmax, half * tan(beta * 0.5))
	var rr := clampf(round_, 0.0, 1.0) * rmax * 0.999
	if extra > 0.0 and round_ > 0.0:
		rr = minf(rr + extra, rmax * 0.999)
	if rr <= 0.01:
		return q
	var out := PackedVector2Array()
	for k in n:
		var a := q[(k - 1 + n) % n]
		var b := q[k]
		var c := q[(k + 1) % n]
		var beta := float(ints[k])
		var u1 := (a - b).normalized()
		var u2 := (c - b).normalized()
		var tl := rr / tan(beta * 0.5)
		var p1 := b + u1 * tl
		var p2 := b + u2 * tl
		var bis := (u1 + u2).normalized()
		var cen := b + bis * (rr / sin(beta * 0.5))
		var s0 := (p1 - cen).angle()
		var s1 := (p2 - cen).angle()
		var sweep := wrapf(s1 - s0, -PI, PI)
		var steps := maxi(2, int(ceil(absf(sweep) / (PI / 12.0))))
		for i in steps + 1:
			var ph := s0 + sweep * float(i) / steps
			out.append(cen + Vector2(cos(ph), sin(ph)) * rr)
	return out


## Each face's interior angle at each of its vertices: [{vertex id: radians}].
static func _corner_angles(verts: PackedVector3Array, faces: Array) -> Array:
	var out: Array = []
	for f in faces:
		var pf: PackedInt32Array = f
		var m := pf.size()
		var d := {}
		for k in m:
			var a := verts[pf[(k - 1 + m) % m]]
			var b := verts[pf[k]]
			var c := verts[pf[(k + 1) % m]]
			d[int(pf[k])] = (a - b).angle_to(c - b)
		out.append(d)
	return out
