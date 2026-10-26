class_name GantryLabClash
extends RefCounted

## What a real build would bump into: every solid part as oriented boxes
## (shrunk a little so parts that merely touch — a bracket on its beam, a
## plate on its spacers — do not count), tested at home and at the eight
## corners of travel, so a carriage that hits the motor at the end of X or
## a bed whose wheels run into the rail's end brackets is caught. Parts
## that are mated (and their grandparents: a pulley in its plate's pilot
## hole, a screw through its nut) are exempt by construction. Belts: every
## straight span must clear every part that is not on the belt, and a loop
## must not cross itself or another belt in its plane.
##
## check(spec, lay) → [{level, text, parts}]

const SHRINK := 0.0004
const BELT_SHRINK := 0.0006
const MAX_ISSUES := 24


static func check(spec: Dictionary, lay: Dictionary) -> Array:
	var res: Dictionary = lay.get("assembly", {})
	if res.is_empty():
		return []
	var out: Array = []
	var solids := _solids(res)
	var poses := _poses(spec)
	var seen := {}
	var static_done := false
	for pz in poses:
		var pd: Dictionary = pz
		var po := GantryLabFrame.pose(spec, lay, pd["mm"])
		var offs := {}
		for name in lay["assemblies"]:
			offs[name] = GantryLabFrame.assembly_origin(lay, po, str(name))
		var n := solids.size()
		var aabbs: Array = []
		for sd in solids:
			var o: Vector3 = offs.get(str(sd["asm"]), Vector3.ZERO)
			var ab: AABB = (sd["aabb"] as AABB).grow(-SHRINK)
			aabbs.append(AABB(ab.position + o, ab.size))
		for i in n:
			var a: Dictionary = solids[i]
			for j in range(i + 1, n):
				var b: Dictionary = solids[j]
				if str(a["id"]) == str(b["id"]):
					continue
				var moving := not str(a["asm"]).is_empty() or not str(b["asm"]).is_empty()
				if not moving and static_done:
					continue
				if str(a["asm"]) == str(b["asm"]) and not str(a["asm"]).is_empty() and pd["name"] != "home":
					continue
				if not (aabbs[i] as AABB).intersects(aabbs[j]):
					continue
				if _exempt(res, a, b):
					continue
				var oa: Vector3 = offs.get(str(a["asm"]), Vector3.ZERO)
				var ob: Vector3 = offs.get(str(b["asm"]), Vector3.ZERO)
				if not _sat(_shift(a["xf"], oa), a["s"], _shift(b["xf"], ob), b["s"]):
					continue
				var key := "%s|%s" % [a["id"], b["id"]]
				if seen.has(key):
					continue
				seen[key] = true
				out.append({"level": "error", "text": "%s hits the %s%s." % [_name(res, str(a["id"])), _name(res, str(b["id"])).to_lower() if _name(res, str(b["id"])).length() > 0 else "?",
					"" if pd["name"] == "home" else " at %s" % pd["name"]], "parts": [str(a["id"]), str(b["id"])]})
				if out.size() >= MAX_ISSUES:
					return out
		static_done = true
		# Belts at this pose.
		for br in GantryLabFrame.belt_routes(spec, lay, po):
			_check_belt(res, lay, br, solids, offs, pd, out, seen)
		if out.size() >= MAX_ISSUES:
			return out
	# Belt crossings, at home.
	_check_crossings(spec, lay, out)
	return out


static func _shift(xf: Transform3D, o: Vector3) -> Transform3D:
	return Transform3D(xf.basis, xf.origin + o)


static func _name(res: Dictionary, id: String) -> String:
	if not res["parts"].has(id):
		return id
	return GantryLabAssembly.label_of(res["parts"][id]["part"])


## Solid boxes: parts (their OBBs) and the generated wheels (owned by their
## carriage plate). [{id, asm, xf, s, aabb}]
static func _solids(res: Dictionary) -> Array:
	var out: Array = []
	for id in res["parts"]:
		var rp: Dictionary = res["parts"][id]
		for ob in rp["boxes"]:
			var o: Dictionary = ob
			var s: Vector3 = o["s"]
			out.append({"id": str(id), "asm": str(rp["asm"]), "xf": o["xf"], "s": s, "aabb": _aabb(o["xf"], s)})
	for fz in res["fasteners"]:
		var fd: Dictionary = fz
		if str(fd["kind"]) != "wheel":
			continue
		var r := float(fd.get("r", 0.012))
		var w := float(fd.get("w", 0.0102))
		var s2 := Vector3(r * 2.0, w, r * 2.0)
		out.append({"id": str(fd["owner"]), "asm": str(fd["asm"]), "xf": fd["xf"], "s": s2, "aabb": _aabb(fd["xf"], s2), "wheel": true})
	return out


static func _aabb(xf: Transform3D, s: Vector3) -> AABB:
	var hs := s * 0.5
	var e := Vector3(
		absf(xf.basis.x.x) * hs.x + absf(xf.basis.y.x) * hs.y + absf(xf.basis.z.x) * hs.z,
		absf(xf.basis.x.y) * hs.x + absf(xf.basis.y.y) * hs.y + absf(xf.basis.z.y) * hs.z,
		absf(xf.basis.x.z) * hs.x + absf(xf.basis.y.z) * hs.y + absf(xf.basis.z.z) * hs.z)
	return AABB(xf.origin - e, e * 2.0)


static func _exempt(res: Dictionary, a: Dictionary, b: Dictionary) -> bool:
	var ia := str(a["id"])
	var ib := str(b["id"])
	if res["pairs"].has(ia + "|" + ib):
		return true
	# A wheel rides its plate's track (the plate's mate target).
	if bool(a.get("wheel", false)) or bool(b.get("wheel", false)):
		var w := ia if bool(a.get("wheel", false)) else ib
		var other := ib if w == ia else ia
		var p: Dictionary = res["parts"][w]["part"] if res["parts"].has(w) else {}
		if str((p.get("mate", {}) as Dictionary).get("to", "")) == other:
			return true
	return false


## Separating-axis test between two OBBs (shrunk by SHRINK).
static func _sat(xa: Transform3D, sa: Vector3, xb: Transform3D, sb: Vector3) -> bool:
	var ha := (sa * 0.5 - Vector3.ONE * SHRINK).max(Vector3.ZERO)
	var hb := (sb * 0.5 - Vector3.ONE * SHRINK).max(Vector3.ZERO)
	var A := [xa.basis.x.normalized(), xa.basis.y.normalized(), xa.basis.z.normalized()]
	var Bv := [xb.basis.x.normalized(), xb.basis.y.normalized(), xb.basis.z.normalized()]
	var t := xb.origin - xa.origin
	var axes: Array = []
	axes.append_array(A)
	axes.append_array(Bv)
	for i in 3:
		for j in 3:
			var c: Vector3 = (A[i] as Vector3).cross(Bv[j])
			if c.length_squared() > 1e-10:
				axes.append(c.normalized())
	for ax in axes:
		var l: Vector3 = ax
		var ra := absf((A[0] as Vector3).dot(l)) * ha.x + absf((A[1] as Vector3).dot(l)) * ha.y + absf((A[2] as Vector3).dot(l)) * ha.z
		var rb := absf((Bv[0] as Vector3).dot(l)) * hb.x + absf((Bv[1] as Vector3).dot(l)) * hb.y + absf((Bv[2] as Vector3).dot(l)) * hb.z
		if absf(t.dot(l)) > ra + rb:
			return false
	return true


## Home and the eight corners of travel (work mm).
static func _poses(spec: Dictionary) -> Array:
	var v: Dictionary = spec["volume"]
	var mx := float(v["x_mm"])
	var my := float(v["y_mm"])
	var mz := float(v["z_mm"])
	var out: Array = [{"name": "home", "mm": Vector3.ZERO}]
	for i in 8:
		var p := Vector3(mx if i & 1 else 0.0, my if i & 2 else 0.0, mz if i & 4 else 0.0)
		if p == Vector3.ZERO:
			continue
		var nm: Array = []
		nm.append("X max" if i & 1 else "X min")
		nm.append("Y max" if i & 2 else "Y min")
		nm.append("Z max" if i & 4 else "Z min")
		out.append({"name": ", ".join(nm), "mm": p})
	return out


static func _check_belt(res: Dictionary, lay: Dictionary, br: Dictionary, solids: Array, offs: Dictionary, pd: Dictionary, out: Array, seen: Dictionary) -> void:
	var loop := {}
	for lp in lay["loops"]:
		if str((lp as Dictionary)["name"]) == str(br["name"]):
			loop = lp
	if loop.is_empty():
		return
	var mine := {}
	for nd in loop["nodes"]:
		var id := str((nd as Dictionary).get("part", ""))
		mine[id] = true
		if res["parts"].has(id):
			var to := str(((res["parts"][id]["part"] as Dictionary).get("mate", {}) as Dictionary).get("to", ""))
			if not to.is_empty():
				mine[to] = true
	var pts: PackedVector3Array = br["points"]
	var w := float(br["w"])
	for i in pts.size() - 1:
		var a := pts[i]
		var b := pts[i + 1]
		var L := a.distance_to(b)
		if L < 0.004:
			continue
		var dirv := (b - a) / L
		a += dirv * 0.002
		b -= dirv * 0.002
		for sd in solids:
			if mine.has(str(sd["id"])):
				continue
			var o: Vector3 = offs.get(str(sd["asm"]), Vector3.ZERO)
			var xf := _shift(sd["xf"], o)
			if not _seg_hits_obb(a, b, xf, sd["s"], w * 0.5):
				continue
			var key := "belt|%s|%s" % [br["name"], sd["id"]]
			if seen.has(key):
				continue
			seen[key] = true
			out.append({"level": "error", "text": "The %s runs through the %s%s." % [str(br["name"]), _name(res, str(sd["id"])).to_lower(),
				"" if pd["name"] == "home" else " at %s" % pd["name"]], "parts": [str(sd["id"])]})
			if out.size() >= MAX_ISSUES:
				return


## Segment vs OBB, the box grown by `pad` (half the belt's width).
static func _seg_hits_obb(a: Vector3, b: Vector3, xf: Transform3D, s: Vector3, pad: float) -> bool:
	var inv := xf.affine_inverse()
	var la := inv * a
	var lb := inv * b
	var h := (s * 0.5 - Vector3.ONE * BELT_SHRINK).max(Vector3.ZERO)
	var d := lb - la
	var t0 := 0.0
	var t1 := 1.0
	for k in 3:
		var lo := -h[k]
		var hi := h[k]
		if absf(d[k]) < 1e-9:
			if la[k] < lo or la[k] > hi:
				return false
			continue
		var ta := (lo - la[k]) / d[k]
		var tb := (hi - la[k]) / d[k]
		if ta > tb:
			var tmp := ta
			ta = tb
			tb = tmp
		t0 = maxf(t0, ta)
		t1 = minf(t1, tb)
		if t0 > t1:
			return false
	var _p := pad
	return true


static func _check_crossings(spec: Dictionary, lay: Dictionary, out: Array) -> void:
	var po := GantryLabFrame.pose(spec, lay, Vector3.ZERO)
	var routes := GantryLabFrame.belt_routes(spec, lay, po)
	var flat: Array = []
	for br in routes:
		var n: Vector3 = (br["n"] as Vector3).normalized()
		var u := GantryLabDetail.basis_y(n).x
		var v := n.cross(u).normalized()
		var pts: PackedVector3Array = br["points"]
		var p2 := PackedVector2Array()
		for p in pts:
			p2.append(Vector2(p.dot(u), p.dot(v)))
		flat.append({"name": str(br["name"]), "n": n, "d": pts[0].dot(n) if pts.size() > 0 else 0.0, "p": p2, "w": float(br["w"]), "u": u, "v": v})
	for f in flat:
		var p2: PackedVector2Array = f["p"]
		if _self_crosses(p2):
			out.append({"level": "error", "text": "The %s crosses itself — a pulley wraps the wrong way." % str(f["name"]), "parts": []})
	for i in flat.size():
		for j in range(i + 1, flat.size()):
			var a: Dictionary = flat[i]
			var b: Dictionary = flat[j]
			if absf((a["n"] as Vector3).dot(b["n"])) < 0.999:
				continue
			if absf(float(a["d"]) - float(b["d"]) * (a["n"] as Vector3).dot(b["n"])) > (float(a["w"]) + float(b["w"])) * 0.5 + 0.0015:
				continue
			# Same plane: b in a's 2D frame.
			var pb := PackedVector2Array()
			var u: Vector3 = a["u"]
			var v: Vector3 = a["v"]
			var pts_b: PackedVector3Array = []
			for br in routes:
				if str(br["name"]) == str(b["name"]):
					pts_b = br["points"]
			for p in pts_b:
				pb.append(Vector2(p.dot(u), p.dot(v)))
			if _polys_cross(a["p"], pb):
				out.append({"level": "error", "text": "The %s and the %s cross in the same plane." % [str(a["name"]), str(b["name"])], "parts": []})


static func _seg_x(a: Vector2, b: Vector2, c: Vector2, d: Vector2) -> bool:
	var r: Variant = Geometry2D.segment_intersects_segment(a, b, c, d)
	return r != null


static func _self_crosses(p: PackedVector2Array) -> bool:
	var n := p.size()
	if n < 4:
		return false
	for i in n - 1:
		for j in range(i + 2, n - 1):
			if i == 0 and j == n - 2:
				continue
			if p[i].distance_to(p[i + 1]) < 1e-5 or p[j].distance_to(p[j + 1]) < 1e-5:
				continue
			if _seg_x(p[i], p[i + 1], p[j], p[j + 1]):
				return true
	return false


static func _polys_cross(a: PackedVector2Array, b: PackedVector2Array) -> bool:
	for i in a.size() - 1:
		for j in b.size() - 1:
			if _seg_x(a[i], a[i + 1], b[j], b[j + 1]):
				return true
	return false
