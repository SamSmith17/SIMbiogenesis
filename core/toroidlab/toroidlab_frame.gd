class_name ToroidLabFrame
extends RefCounted

## The toroid's tube frame: ribs (the minor circle, cut where it meets the
## ground, split into bent arcs), rings round the axis, the inner column's
## posts, bracing and tension lines between rings, and every pipe fitting
## where tubes meet. Pure; metres, y up, the axis through the origin.
##
## A point on the frame is (θ, φ, ρ): θ the bearing round the axis, φ the
## angle on the minor circle from its outer equator up over the top, ρ the
## distance from the minor circle's centre (= r on the ribs; a ring that
## passes under a rib sits one tube diameter inside).
##
## build(spec) → {
##   R, r, hc, base, n, od, thetas: [deg], ground_deg, inner_top_deg,
##   rings:    [{index, name, deg, rho, radius_m, y, on_node, stage}]
##             ordered by φ (outer ground = 0, over the top, inner ground last)
##   members:  [{id, kind: "rib" | "inner" | "post" | "ring" | "brace" |
##              "cable", cls, pts: PackedVector3Array (centreline), len_m,
##              bend_r_m (0 = straight), bend_deg, stage, rib, ring, cable}]
##   classes:  [{label, kind, count, len_m, cut_m, bend_r_m, bend_deg, chord_m,
##              rise_m, desc}]
##   fittings: [{type, p, dirs: [Vector3], stage, rib, ring}]
##   warnings: [String]
## }

const ON_NODE_DEG := 0.75
const RIB_STEP_DEG := 3.0
const RING_STEPS_PER_BAY := 8


static func point(t: Dictionary, theta_deg: float, phi_deg: float, rho: float) -> Vector3:
	var R := float(t["major_r_m"])
	var hc := float(t["centre_h_m"])
	var th := deg_to_rad(theta_deg)
	var ph := deg_to_rad(phi_deg)
	var rr := R + rho * cos(ph)
	return Vector3(rr * cos(th), hc + rho * sin(ph), rr * sin(th))


## The outward surface normal of the torus at (θ, φ).
static func normal(theta_deg: float, phi_deg: float) -> Vector3:
	var th := deg_to_rad(theta_deg)
	var ph := deg_to_rad(phi_deg)
	return Vector3(cos(ph) * cos(th), sin(ph), cos(ph) * sin(th)).normalized()


static func rib_theta(t: Dictionary, k: int) -> float:
	return float(t["rotation_deg"]) + float(k) * 360.0 / float(int(t["segments"]))


static func inner_top_deg(t: Dictionary) -> float:
	var it := float(t["inner_top_deg"])
	if it < 0.0:
		return 180.0 - ToroidLabSpec.ground_deg(t)
	return clampf(it, 100.0, 180.0 + ToroidLabSpec.ground_deg(t) - 1.0)


## The φ of every node along a rib between the outer ground and the inner
## top ring (inclusive): the ends of its `pieces` equal arcs.
static func rib_nodes(t: Dictionary, pieces: int) -> PackedFloat64Array:
	var g := ToroidLabSpec.ground_deg(t)
	var a := -g
	var b := inner_top_deg(t)
	var out := PackedFloat64Array()
	for i in pieces + 1:
		out.append(lerpf(a, b, float(i) / pieces))
	return out


static func has_inner(s: Dictionary, k: int) -> bool:
	var rb: Dictionary = s["ribs"]
	var every := int(rb["inner_every"])
	if every <= 0:
		return false
	if (rb["inner_skip"] as Array).has(k):
		return false
	return posmod(k - int(rb["inner_offset"]), every) == 0


static func build(s: Dictionary) -> Dictionary:
	var t: Dictionary = s["torus"]
	var tube := ToroidLabMaterials.tube(str(s["tube"]["material"]))
	var od := float(tube["od_mm"]) * 0.001
	var n := int(t["segments"])
	var R := float(t["major_r_m"])
	var r := float(t["minor_r_m"])
	var g := ToroidLabSpec.ground_deg(t)
	var it := inner_top_deg(t)
	var gi := 180.0 + g
	var pieces := int(s["ribs"]["pieces"])
	var nodes := rib_nodes(t, pieces)
	var warnings: Array = []
	var d := {"R": R, "r": r, "hc": float(t["centre_h_m"]), "base": float(t["base_y_m"]), "n": n, "od": od,
		"thetas": [], "ground_deg": g, "inner_top_deg": it, "inner_ground_deg": gi, "rings": [],
		"members": [], "classes": [], "fittings": [], "warnings": warnings}
	for k in n:
		(d["thetas"] as Array).append(rib_theta(t, k))
	var any_inner := false
	for k in n:
		if has_inner(s, k):
			any_inner = true
			break
	# --- rings, ordered by φ -------------------------------------------------
	var rg: Dictionary = s["rings"]
	var ring_defs: Array = []
	if bool(rg["ground_out"]):
		ring_defs.append({"name": "Outer ground ring", "deg": -g})
	for e in rg["extra_deg"]:
		ring_defs.append({"name": "Ring at %.0f°" % float(e), "deg": float(e)})
	if bool(rg["crown"]):
		ring_defs.append({"name": "Crown ring", "deg": float(rg["crown_deg"])})
	if bool(rg["inner_top"]):
		ring_defs.append({"name": "Inner top ring", "deg": it})
	if bool(rg["ground_in"]) and any_inner:
		ring_defs.append({"name": "Inner ground ring", "deg": gi})
	ring_defs.sort_custom(func(a, b): return float(a["deg"]) < float(b["deg"]))
	var rings: Array = d["rings"]
	for rd in ring_defs:
		var deg := clampf(float(rd["deg"]), -g, gi)
		var on := false
		for nd in nodes:
			if absf(nd - deg) < ON_NODE_DEG:
				on = true
				deg = nd
		if absf(deg - gi) < ON_NODE_DEG:
			on = true
			deg = gi
		# A ring off the rib nodes passes under the ribs, one diameter inside.
		var rho := r if on else r - od
		var rr := R + rho * cos(deg_to_rad(deg))
		if rr <= od * 2.0:
			warnings.append("%s at %.0f° would sit on the axis; left out." % [str(rd["name"]), deg])
			continue
		var stage := 3
		if absf(deg + g) < 0.01:
			stage = 0
		elif absf(deg - gi) < 0.01:
			stage = 1
		rings.append({"index": rings.size(), "name": str(rd["name"]), "deg": deg, "rho": rho, "radius_m": rr,
			"y": float(t["centre_h_m"]) + rho * sin(deg_to_rad(deg)), "on_node": on, "stage": stage})
	var members: Array = d["members"]
	var fittings: Array = d["fittings"]
	# --- ribs ----------------------------------------------------------------
	for k in n:
		var th := rib_theta(t, k)
		for i in pieces:
			var a := nodes[i]
			var b := nodes[i + 1]
			members.append(_arc_member("rib", th, a, b, r, t, 2 if i == 0 else 3, k))
		if has_inner(s, k):
			members.append(_arc_member("inner", th, it, gi, r, t, 1, k))
			if bool(s["ribs"]["inner_posts"]):
				var pa := point(t, th, gi, r)
				var pb := point(t, th, it, r)
				members.append({"kind": "post", "pts": PackedVector3Array([pa, pb]), "len_m": pa.distance_to(pb),
					"bend_r_m": 0.0, "bend_deg": 0.0, "stage": 1, "rib": k, "ring": -1})
	# --- rings ---------------------------------------------------------------
	var pb_bays := int(rg["piece_bays"])
	for ring in rings:
		var rr := float(ring["radius_m"])
		var y := float(ring["y"])
		var start := 0
		while start < n:
			var bays := mini(pb_bays, n - start)
			var th0 := rib_theta(t, start)
			var th1 := rib_theta(t, start + bays)
			var pts := PackedVector3Array()
			var steps := bays * RING_STEPS_PER_BAY
			for i in steps + 1:
				var th := deg_to_rad(lerpf(th0, th1, float(i) / steps))
				pts.append(Vector3(rr * cos(th), y, rr * sin(th)))
			var span := deg_to_rad(th1 - th0)
			members.append({"kind": "ring", "pts": pts, "len_m": rr * span, "bend_r_m": rr,
				"bend_deg": rad_to_deg(span), "stage": int(ring["stage"]), "rib": start, "ring": int(ring["index"])})
			start += bays
	# --- the fittings where ribs meet rings ---------------------------------
	for k in n:
		var th := rib_theta(t, k)
		var inner := has_inner(s, k)
		var rib_end_phis: Array = []   # [φ, ends at that node]
		for i in pieces + 1:
			var ends := 2 if i > 0 and i < pieces else 1
			if i == pieces and inner:
				ends = 2
			rib_end_phis.append([nodes[i], ends])
		if inner:
			rib_end_phis.append([gi, 1])
		for ne in rib_end_phis:
			var ph := float(ne[0])
			var ends := int(ne[1])
			var ring_here := _ring_at(rings, ph, true)
			var post := 0
			if inner and bool(s["ribs"]["inner_posts"]) and (absf(ph - gi) < 0.01 or absf(ph - it) < 0.01):
				post = 1
			var dirs: Array = _rib_dirs(t, th, ph, ends, -g, gi if inner else it)
			if post == 1:
				var other := point(t, th, it if absf(ph - gi) < 0.01 else gi, r)
				dirs.append((other - point(t, th, ph, r)).normalized())
			var p := point(t, th, ph, r)
			var e := ends + post
			if not ring_here.is_empty():
				var tan := Vector3(-sin(deg_to_rad(th)), 0.0, cos(deg_to_rad(th)))
				dirs.append(tan)
				dirs.append(-tan)
				e += 2
			var typ := ""
			if e >= 5:
				typ = "cross5"
			elif e == 4:
				typ = "cross"
			elif e == 3:
				typ = "tee"
			elif e == 2:
				typ = "coupler" if ring_here.is_empty() and post == 0 else "elbow"
			elif e == 1 and absf(ph + g) < 0.01 and bool(s["ribs"]["feet"]):
				typ = "foot"
			if typ.is_empty():
				continue
			var stage := 0 if absf(ph + g) < 0.01 else (1 if absf(ph - gi) < 0.01 else (2 if ph < nodes[min(1, pieces)] + 0.01 else 3))
			fittings.append({"type": typ, "p": p, "dirs": dirs, "stage": stage, "rib": k,
				"ring": int(ring_here.get("index", -1))})
		# Crossover clamps where a ring passes under a continuous rib.
		for ring in rings:
			if bool(ring["on_node"]):
				continue
			var ph := float(ring["deg"])
			if ph > it + 0.01 and not inner:
				continue
			var pr := point(t, th, ph, r)
			var tan := Vector3(-sin(deg_to_rad(th)), 0.0, cos(deg_to_rad(th)))
			var along := _rib_tangent(th, ph)
			fittings.append({"type": "crossover", "p": pr - normal(th, ph) * od * 0.5, "dirs": [along, -along, tan, -tan],
				"stage": int(ring["stage"]), "rib": k, "ring": int(ring["index"])})
	# Ring splices that no tee takes up: an in-line coupler.
	for ring in rings:
		var start := 0
		while start < n:
			if not bool(ring["on_node"]):
				var th := rib_theta(t, start) + 360.0 / n * 0.5
				var rr := float(ring["radius_m"])
				var thr := deg_to_rad(th)
				var tan := Vector3(-sin(thr), 0.0, cos(thr))
				fittings.append({"type": "coupler", "p": Vector3(rr * cos(thr), float(ring["y"]), rr * sin(thr)),
					"dirs": [tan, -tan], "stage": int(ring["stage"]), "rib": start, "ring": int(ring["index"])})
			start += pb_bays
	# --- bracing and tension lines ------------------------------------------
	for bi in (s["bracing"] as Array).size():
		var br: Dictionary = s["bracing"][bi]
		var ia := int(br["from"])
		var ib := int(br["to"])
		if ia < 0 or ib < 0 or ia >= rings.size() or ib >= rings.size() or ia == ib:
			warnings.append("Bracing %d names a ring that is not there (rings 0–%d)." % [bi + 1, rings.size() - 1])
			continue
		var ra: Dictionary = rings[ia]
		var rbg: Dictionary = rings[ib]
		var cable := str(br["member"]) == "cable"
		var every := int(br["every"])
		for bay in n:
			if posmod(bay - int(br["start"]), every) != 0:
				continue
			var k0 := bay
			var k1 := bay + 1
			var pairs: Array = []
			match str(br["pattern"]):
				"x":
					pairs = [[k0, k1], [k1, k0]]
				"diag":
					pairs = [[k0, k1]]
				_:
					pairs = [[k0, k1]] if posmod(bay - int(br["start"]), 2 * every) == 0 else [[k1, k0]]
			for pr in pairs:
				var pa := _ring_point(t, ra, int(pr[0]))
				var pb := _ring_point(t, rbg, int(pr[1]))
				var m := {"kind": "cable" if cable else "brace", "pts": PackedVector3Array([pa, pb]),
					"len_m": pa.distance_to(pb), "bend_r_m": 0.0, "bend_deg": 0.0, "stage": 4, "rib": int(pr[0]) % n,
					"ring": ia, "cable": str(br["cable"]) if cable else "", "brace": bi}
				members.append(m)
				var dirv := (pb - pa).normalized()
				fittings.append({"type": "eye" if cable else "swivel", "p": pa, "dirs": [dirv], "stage": 4,
					"rib": int(pr[0]) % n, "ring": ia})
				fittings.append({"type": "eye" if cable else "swivel", "p": pb, "dirs": [-dirv], "stage": 4,
					"rib": int(pr[1]) % n, "ring": ib})
	_classify(d, s)
	# --- checks the geometry can make ---------------------------------------
	var min_r := float(tube["min_bend_r_m"])
	for c in d["classes"]:
		var br := float(c["bend_r_m"])
		if br > 0.0 and br < min_r:
			warnings.append("%s bends to R %.2f m — tighter than %s takes (~%.2f m)." % [str(c["label"]), br,
				str(tube["label"]), min_r])
	return d


static func _arc_member(kind: String, th: float, a: float, b: float, r: float, t: Dictionary, stage: int,
		k: int) -> Dictionary:
	var steps := maxi(2, int(ceil(absf(b - a) / RIB_STEP_DEG)))
	var pts := PackedVector3Array()
	for i in steps + 1:
		pts.append(point(t, th, lerpf(a, b, float(i) / steps), r))
	var span := deg_to_rad(absf(b - a))
	return {"kind": kind, "pts": pts, "len_m": r * span, "bend_r_m": r, "bend_deg": rad_to_deg(span),
		"stage": stage, "rib": k, "ring": -1, "phi0": a, "phi1": b}


static func _ring_at(rings: Array, ph: float, need_on_node: bool) -> Dictionary:
	for ring in rings:
		if need_on_node and not bool(ring["on_node"]):
			continue
		if absf(float(ring["deg"]) - ph) < 0.01:
			return ring
	return {}


static func _ring_point(t: Dictionary, ring: Dictionary, k: int) -> Vector3:
	return point(t, rib_theta(t, k), float(ring["deg"]), float(ring["rho"]))


## The tangent along a rib at φ, pointing toward increasing φ.
static func _rib_tangent(th: float, ph: float) -> Vector3:
	var t := deg_to_rad(th)
	var p := deg_to_rad(ph)
	return Vector3(-sin(p) * cos(t), cos(p), -sin(p) * sin(t)).normalized()


## The directions tube ends leave a rib node in: up the rib (toward larger
## φ) unless it is the last node, down unless it is the first.
static func _rib_dirs(t: Dictionary, th: float, ph: float, ends: int, first: float, last: float) -> Array:
	var tg := _rib_tangent(th, ph)
	var out: Array = []
	if ends >= 2:
		out = [tg, -tg]
	elif absf(ph - first) < 0.01:
		out = [tg]
	else:
		out = [-tg]
	return out


## Groups members into classes (same kind, length to the millimetre and
## bend radius to the millimetre) and labels them.
static func _classify(d: Dictionary, s: Dictionary) -> void:
	var gap := float(s["fabrication"]["fitting_gap_mm"]) * 0.001
	var prefix := {"rib": "A", "inner": "I", "post": "P", "ring": "R", "brace": "X", "cable": "T"}
	var counters := {}
	var by_key := {}
	var classes: Array = d["classes"]
	for i in (d["members"] as Array).size():
		var m: Dictionary = d["members"][i]
		m["id"] = i
		var key := "%s|%d|%d|%s" % [str(m["kind"]), roundi(float(m["len_m"]) * 1000.0),
			roundi(float(m["bend_r_m"]) * 1000.0), str(m.get("cable", ""))]
		if not by_key.has(key):
			var kind := str(m["kind"])
			counters[kind] = int(counters.get(kind, 0)) + 1
			var label := "%s%d" % [str(prefix.get(kind, "M")), int(counters[kind])]
			var L := float(m["len_m"])
			var br := float(m["bend_r_m"])
			var bd := float(m["bend_deg"])
			var chord := L
			var rise := 0.0
			if br > 0.0:
				var half := deg_to_rad(bd) * 0.5
				chord = 2.0 * br * sin(half)
				rise = br * (1.0 - cos(half))
			var cut := L if kind == "cable" else maxf(L - 2.0 * gap, 0.0)
			var desc := ""
			match kind:
				"rib": desc = "Rib arc"
				"inner": desc = "Inner wall arc"
				"post": desc = "Inner post (straight)"
				"ring":
					var ring: Dictionary = d["rings"][int(m["ring"])]
					desc = "%s segment" % str(ring["name"])
				"brace": desc = "Brace (straight tube)"
				"cable": desc = "Tension line"
			by_key[key] = classes.size()
			classes.append({"label": label, "kind": kind, "count": 0, "len_m": L, "cut_m": cut, "bend_r_m": br,
				"bend_deg": bd, "chord_m": chord, "rise_m": rise, "desc": desc, "cable": str(m.get("cable", ""))})
		var c: Dictionary = classes[int(by_key[key])]
		c["count"] = int(c["count"]) + 1
		m["cls"] = str(c["label"])
