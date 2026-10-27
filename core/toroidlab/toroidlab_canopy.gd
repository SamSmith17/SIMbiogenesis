class_name ToroidLabCanopy
extends RefCounted

## The toroid's origami canopy: one sector per bay hung under the ribs, each
## a diamond pleat — down the middle of the bay a valley, a peak and a second
## valley, at the ribs straight seams from the inner edge to the outer — cut
## from two sheets of scored corrugated plastic. Each half-sector is three
## triangles folded along two score lines, with a flange bent up along its
## seam; the flanges of neighbouring sectors meet back to back in the rib's
## plane and are bolted through. Pure; metres in 3D, millimetres flat.
##
## Corner points of the sector between ribs k and k+1 (θa, θb, θm the middle):
##   A  = (θa, φ_in,   seam_in)    the inner corner on the seam
##   B  = (θa, φ_out,  seam_out)   the outer corner on the seam
##   Vi = (θm, φ_in,   valley_in)  the inner valley
##   P  = (θm, φ_peak, peak)       the peak
##   Vo = (θm, φ_out,  valley_out) the outer valley
## (depths in from the rib circle). Faces of the half on rib k: (A, Vi, P),
## (A, P, B), (P, Vo, B); the other half is its mirror on rib k+1.
##
## build(spec, frame) → {
##   sectors: [{bay, halves: [{side, A, B, P, Vi, Vo, tris: [[p0,p1,p2]...],
##             flange: [4 points], normal (centre face), bolts: [{p, axis}]}]}]
##   pieces:  [{id, label, side, ring (FlatpackProfile ring, mm), holes,
##             fold: [[a, b, deg, "mountain"|"valley"|"flange"]], bbox, poly,
##             area_m2, w_mm, h_mm}]   (one piece per half; same geometry for
##             every bay)
##   classes: [{label, count, w_mm, h_mm, folds}]
##   nest:    FlatpackNesting.nest over the pieces
##   sheet:   {w, h, id, label}
##   material, area_m2 (cut), shade_m2 (projected), bolts, warnings
## }


static func rho(r: float, depth_mm: float) -> float:
	return r - depth_mm * 0.001


static func build(s: Dictionary, frame: Dictionary) -> Dictionary:
	var cn: Dictionary = s["canopy"]
	var out := {"sectors": [], "pieces": [], "classes": [], "nest": {}, "sheet": {}, "material": {},
		"area_m2": 0.0, "shade_m2": 0.0, "bolts": 0, "warnings": []}
	if not bool(cn["enabled"]):
		return out
	var t: Dictionary = s["torus"]
	var n := int(t["segments"])
	var r := float(frame["r"])
	var mat := ToroidLabMaterials.sheet(str(cn["sheet"]))
	out["material"] = mat
	var thick := float(mat["t_mm"]) * 0.001
	var fl_w := float(cn["flange_mm"]) * 0.001
	var nb := int(cn["bolts_per_seam"])
	var plain := str(cn["fold"]) == "plain"
	var phi_in := float(cn["phi_in_deg"])
	var phi_out := float(cn["phi_out_deg"])
	var phi_pk := float(cn["phi_peak_deg"])
	var d_si := float(cn["seam_in_mm"])
	var d_so := float(cn["seam_out_mm"])
	var d_pk := float(cn["peak_mm"])
	var d_vi := d_si if plain else float(cn["valley_in_mm"])
	var d_vo := d_so if plain else float(cn["valley_out_mm"])
	var sectors: Array = out["sectors"]
	var every := int(cn["every"])
	var shade := 0.0
	var half_tmpl: Array = []
	for bay in n:
		if posmod(bay, every) != 0:
			continue
		var tha := ToroidLabFrame.rib_theta(t, bay)
		var thb := ToroidLabFrame.rib_theta(t, bay + 1)
		var thm := (tha + thb) * 0.5
		var P := ToroidLabFrame.point(t, thm, phi_pk, rho(r, d_pk))
		var Vi := ToroidLabFrame.point(t, thm, phi_in, rho(r, d_vi))
		var Vo := ToroidLabFrame.point(t, thm, phi_out, rho(r, d_vo))
		var halves: Array = []
		for side in 2:
			var th := tha if side == 0 else thb
			var A := ToroidLabFrame.point(t, th, phi_in, rho(r, d_si))
			var B := ToroidLabFrame.point(t, th, phi_out, rho(r, d_so))
			var tris := [[A, Vi, P], [A, P, B], [P, Vo, B]]
			var ctr_minor := ToroidLabFrame.point(t, th, 0.0, 0.0)
			var plane_n := Vector3(-sin(deg_to_rad(th)), 0.0, cos(deg_to_rad(th)))
			var ab := (B - A).normalized()
			var u := plane_n.cross(ab).normalized()
			if u.dot((A + B) * 0.5 - ctr_minor) < 0.0:
				u = -u
			# The two flanges at one rib meet back to back: each sits half a
			# sheet's thickness to its own side of the rib plane.
			var side_off := plane_n * (thick * 0.5 * (1.0 if side == 0 else -1.0))
			var flange := [A + side_off, B + side_off, B + side_off + u * fl_w, A + side_off + u * fl_w]
			var face_n := (P - A).cross(B - A).normalized()
			if face_n.dot(ToroidLabFrame.normal(thm, phi_pk)) < 0.0:
				face_n = -face_n
			var bolts: Array = []
			for i in nb:
				var f := 0.5 if nb == 1 else 0.12 + 0.76 * float(i) / float(nb - 1)
				bolts.append({"p": A.lerp(B, f) + u * (fl_w * 0.5), "axis": plane_n})
			halves.append({"side": side, "theta": th, "A": A, "B": B, "P": P, "Vi": Vi, "Vo": Vo, "tris": tris,
				"flange": flange, "normal": face_n, "bolts": bolts})
			for tri in tris:
				var a2 := Vector2(tri[0].x, tri[0].z)
				var b2 := Vector2(tri[1].x, tri[1].z)
				var c2 := Vector2(tri[2].x, tri[2].z)
				shade += absf((b2 - a2).cross(c2 - a2)) * 0.5
			if half_tmpl.size() < 2:
				half_tmpl.append({"side": side, "A": A, "B": B, "P": P, "Vi": Vi, "Vo": Vo, "u": u})
		sectors.append({"bay": bay, "halves": halves})
	out["shade_m2"] = shade
	out["bolts"] = sectors.size() * 2 * nb
	if sectors.is_empty():
		return out
	# --- the flat pieces (every sector is the same; one of each hand) -------
	var hole_d := float(DomeLabMaterials.bolt(str(cn["bolt"]))["hole_mm"])
	var sw := float(mat["sheet_w"])
	var sh := float(mat["sheet_h"])
	var kerf := float(s["fabrication"]["kerf_mm"])
	var items: Array = []
	var cut_area := 0.0
	for h in half_tmpl:
		var pc := _flatten(h, float(cn["flange_mm"]), nb, hole_d, int(h["side"]) == 1)
		pc["id"] = "S%s" % ("L" if int(h["side"]) == 0 else "R")
		pc["label"] = str(pc["id"])
		pc["side"] = int(h["side"])
		# The smallest rectangle round it, turned to fit the sheet.
		_orient_to_sheet(pc, sw, sh)
		(out["pieces"] as Array).append(pc)
		cut_area += float(pc["area_m2"]) * sectors.size()
		(out["classes"] as Array).append({"label": str(pc["label"]), "count": sectors.size(),
			"w_mm": float(pc["w_mm"]), "h_mm": float(pc["h_mm"]), "folds": pc["fold"],
			"area_m2": float(pc["area_m2"])})
		var fits := (float(pc["w_mm"]) <= sw + 0.5 and float(pc["h_mm"]) <= sh + 0.5) \
			or (float(pc["w_mm"]) <= sh + 0.5 and float(pc["h_mm"]) <= sw + 0.5)
		if not fits:
			(out["warnings"] as Array).append("Canopy piece %s (%.0f × %.0f mm) does not fit a %.0f × %.0f mm sheet." % [
				str(pc["label"]), float(pc["w_mm"]), float(pc["h_mm"]), sw, sh])
		for i in sectors.size():
			items.append({"id": "%s_%02d" % [str(pc["id"]), i + 1], "w": float(pc["w_mm"]), "h": float(pc["h_mm"]),
				"rot_ok": true, "piece": str(pc["id"])})
	out["area_m2"] = cut_area
	out["sheet"] = {"w": sw, "h": sh, "id": str(cn["sheet"]), "label": str(mat["label"])}
	out["nest"] = FlatpackNesting.nest(items, sw, sh, kerf, 0.0)
	out["items"] = items
	return out


## One half-sector laid flat: the centre triangle (A, P, B) with A at the
## origin and B on +x, the two flaps unfolded about A–P and P–B, and the
## flange along A–B. Mirror pieces are flipped in x so the score lines land
## on the same face of every sheet.
static func _flatten(h: Dictionary, flange_mm: float, nb: int, hole_d: float, mirror: bool) -> Dictionary:
	var A: Vector3 = h["A"]
	var B: Vector3 = h["B"]
	var P: Vector3 = h["P"]
	var Vi: Vector3 = h["Vi"]
	var Vo: Vector3 = h["Vo"]
	var L := A.distance_to(B) * 1000.0
	var a2 := Vector2.ZERO
	var b2 := Vector2(L, 0.0)
	var p2 := _third(a2, b2, A.distance_to(P) * 1000.0, B.distance_to(P) * 1000.0, b2 + Vector2(0, -1))
	var vi2 := _third(a2, p2, A.distance_to(Vi) * 1000.0, P.distance_to(Vi) * 1000.0, b2)
	var vo2 := _third(p2, b2, P.distance_to(Vo) * 1000.0, B.distance_to(Vo) * 1000.0, a2)
	var w := flange_mm
	var poly := PackedVector2Array()
	if w > 0.0:
		poly = PackedVector2Array([a2, Vector2(minf(w, L * 0.25), -w), Vector2(L - minf(w, L * 0.25), -w), b2, vo2, p2, vi2])
	else:
		poly = PackedVector2Array([a2, b2, vo2, p2, vi2])
	if FlatpackProfile.signed_area(poly) < 0.0:
		poly.reverse()
	var holes: Array = []
	for i in nb:
		var f := 0.5 if nb == 1 else 0.12 + 0.76 * float(i) / float(nb - 1)
		holes.append(Vector2(L * f, -w * 0.5))
	# Fold lines with their angles (bend from flat) and sense.
	var u: Vector3 = h["u"]
	var fold: Array = []
	if w > 0.0:
		fold.append([a2, b2, _bend(A, B, P, A + u), "flange"])
	fold.append([a2, p2, _bend(A, P, B, Vi), _sense(A, P, B, Vi, h)])
	fold.append([p2, b2, _bend(P, B, A, Vo), _sense(P, B, A, Vo, h)])
	if mirror:
		var m := func(q: Vector2) -> Vector2: return Vector2(-q.x, q.y)
		var mp := PackedVector2Array()
		for q in poly:
			mp.append(m.call(q))
		mp.reverse()
		poly = mp
		var mh: Array = []
		for q in holes:
			mh.append(m.call(q))
		holes = mh
		for f in fold:
			f[0] = m.call(f[0])
			f[1] = m.call(f[1])
	var area := absf(FlatpackProfile.signed_area(poly)) * 1e-6
	return {"poly": poly, "holes_c": holes, "hole_d": hole_d, "fold": fold, "area_m2": area, "len_ab_mm": L}


## The point at distances da from a and db from b, on the side away from
## `away` (unfolding a flap across the edge a–b).
static func _third(a: Vector2, b: Vector2, da: float, db: float, away: Vector2) -> Vector2:
	var L := a.distance_to(b)
	if L < 1e-9:
		return a
	var x := (da * da - db * db + L * L) / (2.0 * L)
	var y := sqrt(maxf(da * da - x * x, 0.0))
	var ex := (b - a) / L
	var ey := Vector2(-ex.y, ex.x)
	var c1 := a + ex * x + ey * y
	var c2 := a + ex * x - ey * y
	var side_away := (away - a).dot(ey)
	return c2 if side_away > 0.0 else c1


## The bend (degrees from flat) along edge a–b between the face holding `p`
## and the face holding `q`.
static func _bend(a: Vector3, b: Vector3, p: Vector3, q: Vector3) -> float:
	var e := (b - a).normalized()
	var vp := (p - a) - e * (p - a).dot(e)
	var vq := (q - a) - e * (q - a).dot(e)
	if vp.length() < 1e-9 or vq.length() < 1e-9:
		return 0.0
	var interior := rad_to_deg(vp.angle_to(vq))
	return 180.0 - interior


## Mountain (the crease points up, away from the torus' minor centre) or
## valley.
static func _sense(a: Vector3, b: Vector3, p: Vector3, q: Vector3, h: Dictionary) -> String:
	# `u` points from the seam toward the rib, out of the torus: a crease that
	# stands proud of its two faces that way is a mountain.
	var away := (a + b) * 0.5 - (p + q) * 0.5
	return "mountain" if away.dot(h["u"] as Vector3) > 0.0 else "valley"


## Turns the piece to its smallest bounding rectangle that fits the sheet and
## stores the ring, holes, folds and bbox in that frame (lower-left at 0).
static func _orient_to_sheet(pc: Dictionary, sw: float, sh: float) -> void:
	var poly: PackedVector2Array = pc["poly"]
	var hull := Geometry2D.convex_hull(poly)
	var best_ang := 0.0
	var best_area := INF
	var best_fit := false
	for i in hull.size() - 1:
		var e := hull[i + 1] - hull[i]
		if e.length() < 1e-6:
			continue
		var ang := -atan2(e.y, e.x)
		var bb := FlatpackProfile.bbox(_rot_all(poly, ang))
		var fits := (bb.size.x <= sw + 0.5 and bb.size.y <= sh + 0.5) or (bb.size.x <= sh + 0.5 and bb.size.y <= sw + 0.5)
		var area := bb.size.x * bb.size.y
		if (fits and not best_fit) or (fits == best_fit and area < best_area - 1e-6):
			best_area = area
			best_ang = ang
			best_fit = fits
	var rp := _rot_all(poly, best_ang)
	var bb := FlatpackProfile.bbox(rp)
	var off := -bb.position
	var final := PackedVector2Array()
	for q in rp:
		final.append(q + off)
	pc["poly"] = final
	pc["ring"] = FlatpackProfile.make_ring(final)
	var holes: Array = []
	for c in pc["holes_c"]:
		holes.append(FlatpackProfile.circle_ring((c as Vector2).rotated(best_ang) + off, float(pc["hole_d"]) * 0.5))
	pc["holes"] = holes
	for f in pc["fold"]:
		f[0] = (f[0] as Vector2).rotated(best_ang) + off
		f[1] = (f[1] as Vector2).rotated(best_ang) + off
	pc["bbox"] = Rect2(Vector2.ZERO, bb.size)
	pc["w_mm"] = bb.size.x
	pc["h_mm"] = bb.size.y


static func _rot_all(poly: PackedVector2Array, ang: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for q in poly:
		out.append(q.rotated(ang))
	return out


static func piece(c: Dictionary, id: String) -> Dictionary:
	for p in c.get("pieces", []):
		if str(p["id"]) == id:
			return p
	return {}


## What goes on one sheet (the DomeLabCam content format): outlines, holes,
## score lines with their angles, labels.
static func sheet_content(c: Dictionary, sheet_index: int) -> Dictionary:
	var sheet: Dictionary = c["sheet"]
	var out := {"w": float(sheet["w"]), "h": float(sheet["h"]), "outside": [], "inside": [], "fold": [],
		"labels": []}
	for shd in (c["nest"] as Dictionary).get("sheets", []):
		if int(shd["index"]) != sheet_index:
			continue
		for pl in shd["placements"]:
			var pid := str(pl["id"]).get_slice("_", 0)
			var p := piece(c, pid)
			if p.is_empty():
				continue
			var bb: Rect2 = p["bbox"]
			(out["outside"] as Array).append(FlatpackNesting.ring_on_sheet(p["ring"], bb, pl))
			for h in p["holes"]:
				(out["inside"] as Array).append(FlatpackNesting.ring_on_sheet(h, bb, pl))
			for f in p["fold"]:
				(out["fold"] as Array).append({"a": FlatpackNesting.point_on_sheet(f[0], bb, pl),
					"b": FlatpackNesting.point_on_sheet(f[1], bb, pl),
					"text": "%s %.0f°" % [str(f[3]), float(f[2])], "kind": str(f[3])})
			var cen := Vector2.ZERO
			for q in (p["poly"] as PackedVector2Array):
				cen += q
			cen /= maxi((p["poly"] as PackedVector2Array).size(), 1)
			(out["labels"] as Array).append({"p": FlatpackNesting.point_on_sheet(cen, bb, pl), "size": 40.0,
				"text": str(pl["id"]), "rot": 0.0})
	return out
