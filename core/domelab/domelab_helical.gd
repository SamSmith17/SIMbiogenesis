class_name DomeLabHelical
extends RefCounted

## Helical zomes: a polar zonohedron swept along its own edge path. Pure
## static geometry, the same output shape as DomeLabZome.build.
##
## Take the zome's n generators g_j (length L, polar angle θ from the axis,
## azimuths 2πj/n), now indexed over all integers (g_{j+n} = g_j). A CELL is
## the zonohedron of w consecutive generators g_a … g_{a+w−1} (w = n: the
## whole polar zonohedron; w = 3: a rhombohedron, the "cube"). The helical
## zome is a chain of cells, each one generator step further round and down
## the helix:
##   cell a at base b(a), window [a, a + w),  b(a − 1) = b(a) + g_{a+w−1}
## so consecutive cells overlap (w ≥ 4) or meet face to face (w = 3) and the
## union winds round the axis — the stacked cubes / stacked rhombic
## dodecahedra of the zonohedron literature, and in the limit w = n the
## polar zonohedron Minkowski-summed with a helix (n steps = one turn).
##
## The union's surface is found EXACTLY: every cell is tiled by its
## parallelepipeds {i < j < k} at offset
##   Σ_{i<l<j} g_l + Σ_{l>k, l<top} g_l
## — a tiling of a polar zonotope (checked for w = 3 … 16), and one whose
## offsets do not depend on the cell, so overlapping cells tile their
## overlap with the SAME bricks. The union is then the set of distinct
## bricks with k − i < w, and its boundary the brick faces that occur once.
## Every face is a rhombus spanned by two generators; its "zone" is their
## index distance min(d, n − d), 1 … n/2 (one rhombus shape per zone).
##
## The reference build (a 10-sided corten home, 21 cells, θ 57.1°, strut
## 1.585 m) is reproduced node for node by w = n = 10, 20 steps.
##
## A floor: `levels` keeps that many rows of nodes from the apex (each
## generator drops one level, L cos θ); rhombi straddling the cut keep their
## upper triangle, as the zome's "cut" base. Nodes are integer generator
## counts until the very end: float keys split coincident faces (one pair in
## 2700 landed on a rounding boundary and left a hole).


static func build(h: Dictionary, radius: float = 1.0) -> Dictionary:
	var n := clampi(int(h.get("sides", 10)), 3, 16)
	var w := clampi(int(h.get("window", n)), 3, n)
	var steps := clampi(int(h.get("steps", 10)), 0, 48)
	var theta := deg_to_rad(clampf(float(h.get("pitch_deg", 57.0)), 10.0, 80.0))
	var stretch := float(h.get("stretch", 1.0))
	var sgn := -1.0 if str(h.get("hand", "right")) == "left" else 1.0
	var levels := int(h.get("levels", 0))
	var L := radius * sin(PI / n) / sin(theta)
	var gx := PackedFloat64Array()
	var gy := PackedFloat64Array()
	var gz := PackedFloat64Array()
	for j in n:
		var phi := sgn * TAU * j / n
		gx.append(L * sin(theta) * sin(phi))
		gy.append(-L * cos(theta) * stretch)
		gz.append(L * sin(theta) * cos(phi))
	var lo := -steps
	var hi := w
	# Prefix COUNTS over the generator index m ∈ [lo, hi]: pc[m − lo][j] is how
	# many of g_lo … g_{m−1} are g_j. Points are kept as integer count vectors
	# (Σ c_j g_j) — exact keys, so two coincident brick faces always meet.
	var pc: Array = []
	var run := PackedInt32Array()
	run.resize(n)
	pc.append(run.duplicate())
	for m in range(lo, hi):
		run[posmod(m, n)] += 1
		pc.append(run.duplicate())
	var count := {}
	var store := {}
	var add_face := func(o: PackedInt32Array, a: int, b: int, t: int, top: bool) -> void:
		var ua := posmod(a, n)
		var vb := posmod(b, n)
		var tg := posmod(t, n)
		var parts := PackedStringArray([str(mini(ua, vb)), str(maxi(ua, vb))])
		for j in n:
			var c := 2 * o[j]
			if top and j == tg:
				c += 2
			if j == ua:
				c += 1
			if j == vb:
				c += 1
			parts.append(str(c))
		var key := ",".join(parts)
		count[key] = int(count.get(key, 0)) + 1
		if not store.has(key):
			var base := o.duplicate()
			if top:
				base[tg] += 1
			# Outward: away from the brick's interior, which lies along +g_t
			# from the base face and along −g_t from the face at base + g_t.
			var nx := gy[ua] * gz[vb] - gz[ua] * gy[vb]
			var ny := gz[ua] * gx[vb] - gx[ua] * gz[vb]
			var nz := gx[ua] * gy[vb] - gy[ua] * gx[vb]
			var dot := nx * gx[tg] + ny * gy[tg] + nz * gz[tg]
			var flip := dot > 0.0 if not top else dot < 0.0
			store[key] = [base, ua, vb, flip]
	var top_c: PackedInt32Array = pc[hi - lo]
	for i in range(lo, hi):
		for j in range(i + 1, hi):
			for k in range(j + 1, mini(hi, i + w)):
				var c_i1: PackedInt32Array = pc[i + 1 - lo]
				var c_j: PackedInt32Array = pc[j - lo]
				var c_k1: PackedInt32Array = pc[k + 1 - lo]
				var o := PackedInt32Array()
				o.resize(n)
				for q in n:
					o[q] = (c_j[q] - c_i1[q]) + (top_c[q] - c_k1[q])
				add_face.call(o, i, j, k, false)
				add_face.call(o, i, j, k, true)
				add_face.call(o, i, k, j, false)
				add_face.call(o, i, k, j, true)
				add_face.call(o, j, k, i, false)
				add_face.call(o, j, k, i, true)
	var pos := func(c: PackedInt32Array) -> Array:
		var x := 0.0
		var y := 0.0
		var z := 0.0
		for j in n:
			if c[j] != 0:
				x += c[j] * gx[j]
				y += c[j] * gy[j]
				z += c[j] * gz[j]
		return [x, y, z, c]
	# The boundary: faces that occur once.
	var level_h := L * cos(theta) * stretch
	var quads: Array = []   # [[x, y, z, counts] × 4] outward-wound, corner 2 the lowest
	var zones: Array = []
	var pairs: Array = []
	var max_level := 0
	for key in count:
		if int(count[key]) != 1:
			continue
		var r: Array = store[key]
		var o: PackedInt32Array = r[0]
		var ua := int(r[1])
		var vb := int(r[2])
		var c1 := o.duplicate()
		c1[ua] += 1
		var c3 := o.duplicate()
		c3[vb] += 1
		var c2 := c1.duplicate()
		c2[vb] += 1
		var p0: Array = pos.call(o)
		var p1: Array = pos.call(c1)
		var p2: Array = pos.call(c2)
		var p3: Array = pos.call(c3)
		quads.append([p0, p3, p2, p1] if bool(r[3]) else [p0, p1, p2, p3])
		var d := posmod(vb - ua, n)
		zones.append(mini(d, n - d))
		pairs.append([ua, vb])
		var lv := 0
		for q in n:
			lv += c2[q]
		max_level = maxi(max_level, lv)
	var full_quads := quads.size()
	# The closed surface's counts (before the floor cut), for the Euler check.
	var full_v := {}
	var full_e := {}
	for qd in quads:
		var ks: Array = []
		for p in qd:
			var kk := _pkey(p)
			full_v[kk] = true
			ks.append(kk)
		for m in 4:
			var a := str(ks[m])
			var b := str(ks[(m + 1) % 4])
			full_e[a + "#" + b if a < b else b + "#" + a] = true
	# Floor cut.
	var K := levels if levels > 0 and levels < max_level else max_level
	var cut := K < max_level
	var polys: Array = []
	var pzone: Array = []
	var ppair: Array = []
	for qi in quads.size():
		var qd: Array = quads[qi]
		var top := _level(qd[0])
		if top + 2 <= K:
			polys.append(qd)
		elif cut and top + 1 == K:
			polys.append([qd[0], qd[1], qd[3]])
		else:
			continue
		pzone.append(zones[qi])
		ppair.append(pairs[qi])
	# Axis: the circle through three consecutive cell centres (the path is a
	# regular polygon in plan), else the one cell's centre.
	var cells: Array = []
	var cpos := func(c: PackedInt32Array) -> Vector2:
		var x := 0.0
		var z := 0.0
		for j in n:
			x += c[j] * gx[j]
			z += c[j] * gz[j]
		return Vector2(x, z)
	for t in range(0, mini(steps, 2) + 1):
		var a := -t
		var b0: Vector2 = cpos.call(top_c) - cpos.call(pc[a + w - lo])
		var win: Vector2 = cpos.call(pc[a + w - lo]) - cpos.call(pc[a - lo])
		cells.append(b0 + win * 0.5)
	var axis := cells[0] as Vector2
	if cells.size() == 3:
		axis = _circumcentre(cells[0], cells[1], cells[2], axis)
	# Vertices, deduplicated, floor at y = 0, axis at x = z = 0.
	var floor_y := -K * level_h
	var idx := {}
	var verts := PackedVector3Array()
	var faces: Array = []
	var levels_of := PackedInt32Array()
	for poly in polys:
		var f := PackedInt32Array()
		for p in poly:
			var kk := _pkey(p)
			if not idx.has(kk):
				idx[kk] = verts.size()
				verts.append(Vector3(float(p[0]) - axis.x, float(p[1]) - floor_y, float(p[2]) - axis.y))
				levels_of.append(_level(p))
			f.append(int(idx[kk]))
		faces.append(f)
	var normals := DomeLabGeodesic._vertex_normals(verts, faces)
	var base_ids: Array = []
	for i in verts.size():
		if levels_of[i] == K:
			base_ids.append(i)
	# Edge tags: the generator an edge is a translate of (its zone line).
	var tags := {}
	for fi in faces.size():
		var f: PackedInt32Array = faces[fi]
		for m in f.size():
			var a := int(f[m])
			var b := int(f[(m + 1) % f.size()])
			var key := DomeLabGeodesic._ekey(a, b)
			if tags.has(key):
				continue
			var dvec := verts[b] - verts[a]
			if levels_of[a] == levels_of[b]:
				tags[key] = {"rib": "base", "index": 0}
				continue
			if dvec.y > 0.0:
				dvec = -dvec
			var best := 0
			var bd := -INF
			for j in n:
				var dd := dvec.x * gx[j] + dvec.y * gy[j] + dvec.z * gz[j]
				if dd > bd:
					bd = dd
					best = j
			tags[key] = {"rib": "g", "index": best}
	var edges := DomeLabGeodesic._edges_of(faces)
	var top_y := -floor_y
	var warnings: Array = []
	if levels > 0 and levels >= max_level:
		warnings.append("Floor cut at %d rows keeps the whole body (it has %d)" % [levels, max_level])
	return {"verts": verts, "faces": faces, "edges": edges, "base_ids": base_ids, "normals": normals,
		"full_count": {"v": full_v.size(), "e": full_e.size(), "f": full_quads},
		"rings": [], "cut_ring": K, "fraction_actual": float(K) / float(maxi(max_level, 1)),
		"warnings": warnings, "centre": Vector3(0, top_y * 0.5, 0), "edge_tags": tags,
		"face_zone": pzone, "face_pair": ppair, "gen_len_m": L, "sides": n, "window": w, "steps": steps,
		"theta": theta, "stretch": stretch, "top_y": top_y, "level_h": level_h, "levels_total": max_level,
		"levels_kept": K, "zones": int(n / 2)}


## A point's key: its generator counts (exact).
static func _pkey(p: Array) -> String:
	return ",".join(Array(p[3]).map(func(v): return str(v)))


## A node's row from the apex: how many generators it is down.
static func _level(p: Array) -> int:
	var lv := 0
	for v in (p[3] as PackedInt32Array):
		lv += v
	return lv


static func _circumcentre(a: Vector2, b: Vector2, c: Vector2, fallback: Vector2) -> Vector2:
	var d := 2.0 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y))
	if absf(d) < 1e-9:
		return fallback
	var a2 := a.length_squared()
	var b2 := b.length_squared()
	var c2 := c.length_squared()
	return Vector2((a2 * (b.y - c.y) + b2 * (c.y - a.y) + c2 * (a.y - b.y)) / d,
		(a2 * (c.x - b.x) + b2 * (a.x - c.x) + c2 * (b.x - a.x)) / d)


## The rhombus's corner angle (degrees, the acute one) for a zone.
static func zone_angle_deg(n: int, theta: float, zone: int) -> float:
	var c := cos(theta) * cos(theta) + sin(theta) * sin(theta) * cos(TAU * zone / n)
	var a := rad_to_deg(acos(clampf(c, -1.0, 1.0)))
	return minf(a, 180.0 - a)
