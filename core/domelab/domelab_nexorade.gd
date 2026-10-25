class_name DomeLabNexorade
extends RefCounted

## Nexorades (reciprocal frames, Baverel et al. 2000) and Fischbeck's
## rotegrity: a hubless dome in which every edge of the triangulation becomes
## a SLAT (nexor) turned about its midpoint in the tangent plane by the
## ENGAGEMENT ANGLE ρ and lengthened, so that at each former vertex the k
## slats form a fan where each rests on the next. Pure static.
##
## For edge e with midpoint M, direction d and surface normal N_M:
##   d' = d rotated about N_M by ρ,   the slat's line  ℓ_e(t) = M + t d'.
## Round vertex v the slats of its edges, taken counter-clockwise, meet in
## pairs: the closest points of the skew lines ℓ_i and ℓ_{i+1} are where
## slat i's END fastens onto slat i+1. The distance between those lines is
## the ECCENTRICITY; for flat slats stacked one over the other it must equal
## the slat thickness, which is what fixes ρ — "auto" bisects ρ until the
## mean eccentricity matches. A slat therefore has four holes: one at each
## end (where it rests on a neighbour) and two inboard (where neighbours
## rest on it); its length is the span between the end holes plus overhang.
##
## solve(geo, edges, fans, spec) → {nexors: [{edge, p0, p1 (metres, world),
##   dir, len, holes: [t from p0 …], ecc: [...], label}], classes, rho_deg,
##   mean_ecc_mm, max_ecc_mm, min_ecc_mm, warnings}


static func solve(geo: Dictionary, edges: Array, fans: Array, spec: Dictionary) -> Dictionary:
	var nx: Dictionary = spec["nexorade"]
	var slat := DomeLabMaterials.strut(str(nx["slat"]))
	var t_mm := float(slat.get("t_mm", 6.0))
	var mode := str(nx.get("mode", "band"))
	var rho_deg := float(nx["engagement_deg"])
	if rho_deg <= 0.01:
		if mode == "rigid":
			rho_deg = fit_engagement(geo, edges, fans, t_mm / 1000.0)
		else:
			rho_deg = fit_engagement_length(geo, edges, fans, float(nx.get("engage_frac", 0.3)))
	var res := evaluate(geo, edges, fans, deg_to_rad(rho_deg), float(nx["overhang_mm"]) / 1000.0)
	res["rho_deg"] = rho_deg
	res["mode"] = mode
	res["auto"] = float(nx["engagement_deg"]) <= 0.01
	if mode == "band":
		_bands_follow_the_surface(res, edges)
	# Classes by (length, hole positions).
	var fab: Dictionary = spec["fabrication"]
	var tol := float(fab["group_tol_mm"]) / 1000.0
	var classes := {}
	for i in (res["nexors"] as Array).size():
		var n: Dictionary = res["nexors"][i]
		var parts: PackedStringArray = [str(int(round(float(n["len"]) / tol)))]
		for h in n["holes"]:
			parts.append(str(int(round(float(h) / tol))))
		var key := "|".join(parts)
		if not classes.has(key):
			classes[key] = {"key": key, "len": float(n["len"]), "holes": (n["holes"] as Array).duplicate(),
				"count": 0, "ids": []}
		(classes[key] as Dictionary)["count"] = int((classes[key] as Dictionary)["count"]) + 1
		((classes[key] as Dictionary)["ids"] as Array).append(i)
		n["key"] = key
	var clist: Array = classes.values()
	clist.sort_custom(func(x, y): return float(x["len"]) < float(y["len"]))
	for i in clist.size():
		(clist[i] as Dictionary)["label"] = "N%d" % (i + 1)
	var by_key := {}
	for c in clist:
		by_key[c["key"]] = c["label"]
	for n in res["nexors"]:
		n["label"] = str(by_key[n["key"]])
	res["classes"] = clist
	res["slat"] = slat
	return res


## The engagement angle at which the slats' centre lines sit one thickness
## apart (bisection; eccentricity grows with ρ from 0 at ρ = 0).
static func fit_engagement(geo: Dictionary, edges: Array, fans: Array, thickness_m: float) -> float:
	var lo := 0.2
	var hi := 35.0
	for _i in 30:
		var mid := (lo + hi) * 0.5
		var r := evaluate(geo, edges, fans, deg_to_rad(mid), 0.0)
		if float(r["mean_ecc_mm"]) / 1000.0 < thickness_m:
			lo = mid
		else:
			hi = mid
	return (lo + hi) * 0.5


## The engagement angle at which a slat's end hole sits `frac` of its edge's
## length from the inboard hole where the neighbour rests on it (bisection;
## the engagement length grows with rho from 0 at rho = 0).
static func fit_engagement_length(geo: Dictionary, edges: Array, fans: Array, frac: float) -> float:
	var lo := 0.2
	var hi := 40.0
	for _i in 30:
		var mid := (lo + hi) * 0.5
		var r := evaluate(geo, edges, fans, deg_to_rad(mid), 0.0)
		if float(r["engage_frac"]) < frac:
			lo = mid
		else:
			hi = mid
	return (lo + hi) * 0.5


## A flexible band lies on the surface, so its holes are spaced along the
## ARC between hubs, not the chord: every distance is scaled by arc / chord
## (the flat-bar rule, d / sin d with d the mean dip of the edge).
static func _bands_follow_the_surface(res: Dictionary, edges: Array) -> void:
	for n in res["nexors"]:
		var e: Dictionary = edges[int(n["edge"])]
		var dm := (float(e["dip_a"]) + float(e["dip_b"])) * 0.5
		var k := 1.0
		if dm > 1e-6:
			k = dm / sin(dm)
		n["arc_scale"] = k
		n["len"] = float(n["len"]) * k
		var holes: Array = []
		for h in n["holes"]:
			holes.append(float(h) * k)
		n["holes"] = holes


static func evaluate(geo: Dictionary, edges: Array, fans: Array, rho: float, overhang: float) -> Dictionary:
	var verts: PackedVector3Array = geo["verts"]
	var normals: PackedVector3Array = geo["normals"]
	var lines: Array = []
	for e in edges:
		var a := int(e["a"])
		var b := int(e["b"])
		var nm := (normals[a] + normals[b]).normalized()
		var d: Vector3 = e["dir"]
		var dp := d.rotated(nm, rho).normalized()
		lines.append({"m": e["mid"], "d": dp, "n": nm, "hits": []})
	var eccs: Array = []
	var warnings: Array = []
	for v in fans.size():
		var fan: Array = fans[v]
		var m := fan.size()
		if m < 2:
			continue
		for k in m:
			var i := int(fan[k])
			var j := int(fan[(k + 1) % m])
			if i == j:
				continue
			var li: Dictionary = lines[i]
			var lj: Dictionary = lines[j]
			var cp := _closest(li["m"], li["d"], lj["m"], lj["d"])
			if cp.is_empty():
				continue
			# Only crossings near THIS vertex count (a fan of two slats meets
			# again at the far end).
			var pv := verts[v]
			var ei: Dictionary = edges[i]
			var reach := maxf(float(ei["len"]), float((edges[j] as Dictionary)["len"])) * 0.75
			if (cp["pi"] as Vector3).distance_to(pv) > reach:
				continue
			(li["hits"] as Array).append({"t": float(cp["ti"]), "role": "end", "vertex": v, "other": j})
			(lj["hits"] as Array).append({"t": float(cp["tj"]), "role": "in", "vertex": v, "other": i})
			eccs.append(float(cp["dist"]))
	var nexors: Array = []
	var eng_sum := 0.0
	var eng_n := 0
	var ecc_sum := 0.0
	var ecc_max := 0.0
	var ecc_min := INF
	for x in eccs:
		ecc_sum += float(x)
		ecc_max = maxf(ecc_max, float(x))
		ecc_min = minf(ecc_min, float(x))
	for i in lines.size():
		var li: Dictionary = lines[i]
		var hits: Array = li["hits"]
		if hits.size() < 2:
			var e: Dictionary = edges[i]
			var half := float(e["len"]) * 0.5
			nexors.append({"edge": i, "p0": (li["m"] as Vector3) - (li["d"] as Vector3) * half,
				"p1": (li["m"] as Vector3) + (li["d"] as Vector3) * half, "dir": li["d"], "n": li["n"],
				"len": float(e["len"]), "holes": [], "ends": [], "warn": true})
			warnings.append("slat %d has no neighbour to rest on" % i)
			continue
		var ts: Array = []
		for h in hits:
			ts.append(float(h["t"]))
		ts.sort()
		var t0 := float(ts[0]) - overhang
		var t1 := float(ts[ts.size() - 1]) + overhang
		var holes: Array = []
		for t in ts:
			holes.append(float(t) - t0)
		# Engagement length at each end: end hole to the nearest inboard hole,
		# as a share of the edge.
		if ts.size() >= 4:
			var e_len := float((edges[i] as Dictionary)["len"])
			eng_sum += ((float(ts[1]) - float(ts[0])) + (float(ts[ts.size() - 1]) - float(ts[ts.size() - 2]))) * 0.5 / maxf(e_len, 1e-9)
			eng_n += 1
		nexors.append({"edge": i, "p0": (li["m"] as Vector3) + (li["d"] as Vector3) * t0,
			"p1": (li["m"] as Vector3) + (li["d"] as Vector3) * t1, "dir": li["d"], "n": li["n"],
			"len": t1 - t0, "holes": holes, "hits": hits, "warn": false})
	return {"nexors": nexors, "engage_frac": eng_sum / maxf(eng_n, 1),
		"mean_ecc_mm": (ecc_sum / maxf(eccs.size(), 1)) * 1000.0,
		"max_ecc_mm": ecc_max * 1000.0, "min_ecc_mm": (ecc_min if ecc_min < INF else 0.0) * 1000.0,
		"warnings": warnings, "crossings": eccs.size()}


## Closest points of two lines: {ti, tj, pi, pj, dist}; {} when parallel.
static func _closest(p1: Vector3, d1: Vector3, p2: Vector3, d2: Vector3) -> Dictionary:
	var r := p1 - p2
	var a := d1.dot(d1)
	var b := d1.dot(d2)
	var c := d2.dot(d2)
	var d := d1.dot(r)
	var e := d2.dot(r)
	var den := a * c - b * b
	if absf(den) < 1e-12:
		return {}
	var ti := (b * e - c * d) / den
	var tj := (a * e - b * d) / den
	var pi_ := p1 + d1 * ti
	var pj := p2 + d2 * tj
	return {"ti": ti, "tj": tj, "pi": pi_, "pj": pj, "dist": pi_.distance_to(pj)}
