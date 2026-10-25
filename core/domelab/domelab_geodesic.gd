class_name DomeLabGeodesic
extends RefCounted

## Geodesic triangulations of the sphere — the Goldberg–Coxeter construction
## on a base deltahedron (icosahedron, octahedron, tetrahedron), Class I
## (f, 0), Class II (f/2, f/2) and Class III (b, c), projected onto the
## sphere, optionally stretched into an ellipsoid and truncated at a ring.
## Pure static geometry; nothing here knows about struts or hubs.
##
## The construction (Coxeter 1971; Goldberg 1937; as used by Antiprism's
## `geodesic` and every GC-polyhedron tool): lay a triangular lattice over
## each face so that the lattice vectors (b, c) run from one corner to the
## next. Lattice points inside the face become vertices; unit lattice
## triangles whose centroid is inside the face become faces. For c ≠ 0 the
## unit triangles straddle the face edges, so a corner that falls OUTSIDE
## the face is carried across the edge into the neighbour, where the lattice
## continues: in the unfolded plane the neighbour's far corner is the
## reflection V4 = V1 + V2 − V3, so barycentric (λ1, λ2, λ3) with λ3 < 0
## becomes (λ1 + λ3, λ2 + λ3, −λ3) on (V1, V2, V4). Repeated until every
## coordinate is non-negative (a point near a base vertex may hop twice).
## Vertices are merged by position; faces by vertex set. V − E + F = 2 on the
## full sphere is checked by the selftest, as are the published chord
## factors (2V A 0.54653 / B 0.61803; 3V A 0.34862 / B 0.40355 / C 0.41241).
##
## build(g, radius) → {verts (PackedVector3Array, metres, y up, base at y 0),
##   faces: [PackedInt32Array(3)], edges: [[a, b]], base_ids, normals
##   (per vertex, the FULL polyhedron's surface normal), full_count: {v, e, f},
##   rings: [heights], cut_ring, fraction_actual, warnings, centre (Vector3)}

const EPS := 1e-7


static func base_polyhedron(base: String) -> Dictionary:
	var verts := PackedVector3Array()
	var faces: Array = []
	match base:
		"octa":
			verts = PackedVector3Array([Vector3(0, 1, 0), Vector3(1, 0, 0), Vector3(0, 0, 1),
				Vector3(-1, 0, 0), Vector3(0, 0, -1), Vector3(0, -1, 0)])
			for k in 4:
				faces.append(PackedInt32Array([0, 1 + k, 1 + (k + 1) % 4]))
				faces.append(PackedInt32Array([5, 1 + (k + 1) % 4, 1 + k]))
		"tetra":
			var h := -1.0 / 3.0
			var r := sqrt(8.0 / 9.0)
			verts.append(Vector3(0, 1, 0))
			for k in 3:
				var a := TAU * k / 3.0
				verts.append(Vector3(r * sin(a), h, r * cos(a)))
			faces.append(PackedInt32Array([0, 1, 2]))
			faces.append(PackedInt32Array([0, 2, 3]))
			faces.append(PackedInt32Array([0, 3, 1]))
			faces.append(PackedInt32Array([1, 3, 2]))
		_:
			# Icosahedron with a vertex at the top: two rings of five at
			# y = ±1/√5, radius 2/√5, the lower ring turned half a step.
			var y := 1.0 / sqrt(5.0)
			var r := 2.0 / sqrt(5.0)
			verts.append(Vector3(0, 1, 0))
			for k in 5:
				var a := TAU * k / 5.0
				verts.append(Vector3(r * sin(a), y, r * cos(a)))
			for k in 5:
				var a := TAU * (k + 0.5) / 5.0
				verts.append(Vector3(r * sin(a), -y, r * cos(a)))
			verts.append(Vector3(0, -1, 0))
			for k in 5:
				var u0 := 1 + k
				var u1 := 1 + (k + 1) % 5
				var l0 := 6 + k
				var l1 := 6 + (k + 1) % 5
				faces.append(PackedInt32Array([0, u0, u1]))
				faces.append(PackedInt32Array([u0, l0, u1]))
				faces.append(PackedInt32Array([u1, l0, l1]))
				faces.append(PackedInt32Array([11, l1, l0]))
	# Outward (counter-clockwise seen from outside).
	for i in faces.size():
		var f: PackedInt32Array = faces[i]
		var n := (verts[f[1]] - verts[f[0]]).cross(verts[f[2]] - verts[f[0]])
		var c := (verts[f[0]] + verts[f[1]] + verts[f[2]]) / 3.0
		if n.dot(c) < 0.0:
			faces[i] = PackedInt32Array([f[0], f[2], f[1]])
	return {"verts": verts, "faces": faces}


## Rotate the base so a vertex / face centre / edge midpoint points up.
## Note every mirror plane of the icosahedron holds two of its edges, and a
## Class II lattice straddles the icosa edges, so a Class II "hemisphere" is
## never a clean great circle: the straddling triangles are trimmed and the
## base is notched (4V edge-up keeps 116 of 240 faces). The checks say so.
static func orient(poly: Dictionary, orientation: String) -> Dictionary:
	var verts: PackedVector3Array = poly["verts"]
	var up := Vector3.UP
	match orientation:
		"face":
			var f: PackedInt32Array = poly["faces"][0]
			up = (verts[f[0]] + verts[f[1]] + verts[f[2]]).normalized()
		"edge":
			var f: PackedInt32Array = poly["faces"][0]
			up = (verts[f[0]] + verts[f[1]]).normalized()
		_:
			return poly
	var axis := up.cross(Vector3.UP)
	if axis.length() < 1e-9:
		return poly
	var ang := acos(clampf(up.dot(Vector3.UP), -1.0, 1.0))
	var b := Basis(axis.normalized(), ang)
	var out := PackedVector3Array()
	for v in verts:
		out.append(b * v)
	return {"verts": out, "faces": poly["faces"]}


static func lattice_params(g: Dictionary) -> Vector2i:
	var cls := int(g.get("cls", 1))
	var f := int(g.get("frequency", 3))
	if cls == 2:
		var half := maxi(1, int(round(f / 2.0)))
		return Vector2i(half, half)
	if cls == 3:
		return Vector2i(int(g.get("b", 2)), int(g.get("c", 1)))
	return Vector2i(f, 0)


## Triangulation number T = b² + bc + c²; faces = T × base faces.
static func triangulation_number(bc: Vector2i) -> int:
	return bc.x * bc.x + bc.x * bc.y + bc.y * bc.y


static func build(g: Dictionary, radius: float = 1.0) -> Dictionary:
	var warnings: Array = []
	var base := str(g.get("base", "icosa"))
	var bc := lattice_params(g)
	if int(g.get("cls", 1)) == 2 and int(g.get("frequency", 3)) % 2 == 1:
		warnings.append("Class II needs an even frequency; using %dV." % (bc.x * 2))
	var poly := orient(base_polyhedron(base), str(g.get("orientation", "vertex")))
	var sphere := subdivide(poly, bc)
	var verts: PackedVector3Array = sphere["verts"]
	var faces: Array = sphere["faces"]
	var stretch := float(g.get("stretch", 1.0))
	# Normals of the full surface (before the cut), then the ellipsoid stretch.
	var normals := _vertex_normals(verts, faces)
	for i in verts.size():
		var v := verts[i]
		verts[i] = Vector3(v.x, v.y * stretch, v.z) * radius
		var n := normals[i]
		normals[i] = Vector3(n.x, n.y / stretch, n.z).normalized()
	var full_edges := _edges_of(faces)
	var full_count := {"v": verts.size(), "e": full_edges.size(), "f": faces.size()}
	# Rings of vertex heights, merged within 3 % of the radius: a 3V dome's
	# "5/8" base is two heights a few centimetres apart, one ring to a builder.
	var rings := _rings(verts, 0.03 * radius * stretch)
	var fraction := clampf(float(g.get("fraction", 0.5)), 0.2, 1.0)
	var top := radius * stretch
	var y_cut := top * (1.0 - 2.0 * fraction)
	var cut_ring := 0
	var best := INF
	for i in rings.size():
		var d := absf(float(rings[i]) - y_cut)
		if d < best:
			best = d
			cut_ring = i
	var cut_h := float(rings[cut_ring]) - 0.03 * radius * stretch
	if fraction >= 0.999:
		cut_h = -INF
	var keep := PackedByteArray()
	keep.resize(verts.size())
	for i in verts.size():
		keep[i] = 1 if verts[i].y >= cut_h else 0
	# Base = kept vertices with a removed neighbour.
	var base_set := {}
	for e in full_edges:
		var a := int(e[0])
		var b := int(e[1])
		if keep[a] == 1 and keep[b] == 0:
			base_set[a] = true
		elif keep[b] == 1 and keep[a] == 0:
			base_set[b] = true
	# Flatten the base onto one plane (its mean height).
	if bool(g.get("flat_base", true)) and base_set.size() > 0:
		var mean := 0.0
		for id in base_set:
			mean += verts[int(id)].y
		mean /= base_set.size()
		for id in base_set:
			var v := verts[int(id)]
			verts[int(id)] = Vector3(v.x, mean, v.z)
	# Kept faces and a compact index.
	var remap := PackedInt32Array()
	remap.resize(verts.size())
	var out_verts := PackedVector3Array()
	var out_normals := PackedVector3Array()
	var out_base: Array = []
	for i in verts.size():
		if keep[i] == 1:
			remap[i] = out_verts.size()
			out_verts.append(verts[i])
			out_normals.append(normals[i])
			if base_set.has(i):
				out_base.append(remap[i])
		else:
			remap[i] = -1
	var out_faces: Array = []
	for f in faces:
		var pf: PackedInt32Array = f
		if keep[pf[0]] == 1 and keep[pf[1]] == 1 and keep[pf[2]] == 1:
			out_faces.append(PackedInt32Array([remap[pf[0]], remap[pf[1]], remap[pf[2]]]))
	# Drop vertices no kept face uses (none for a connected cut, but safe).
	var used := PackedByteArray()
	used.resize(out_verts.size())
	for f in out_faces:
		for k in 3:
			used[(f as PackedInt32Array)[k]] = 1
	var remap2 := PackedInt32Array()
	remap2.resize(out_verts.size())
	var v2 := PackedVector3Array()
	var n2 := PackedVector3Array()
	for i in out_verts.size():
		if used[i] == 1:
			remap2[i] = v2.size()
			v2.append(out_verts[i])
			n2.append(out_normals[i])
		else:
			remap2[i] = -1
	var f2: Array = []
	for f in out_faces:
		var pf: PackedInt32Array = f
		f2.append(PackedInt32Array([remap2[pf[0]], remap2[pf[1]], remap2[pf[2]]]))
	var base2: Array = []
	for id in out_base:
		if remap2[int(id)] >= 0:
			base2.append(remap2[int(id)])
	# Stand it on the ground: the lowest vertex at y = 0.
	var min_y := INF
	for v in v2:
		min_y = minf(min_y, v.y)
	for i in v2.size():
		v2[i] = Vector3(v2[i].x, v2[i].y - min_y, v2[i].z)
	var actual := (top - (float(rings[cut_ring]) if fraction < 0.999 else -top)) / (2.0 * top)
	return {"verts": v2, "faces": f2, "edges": _edges_of(f2), "base_ids": base2, "normals": n2,
		"full_count": full_count, "rings": rings, "cut_ring": cut_ring, "fraction_actual": actual,
		"warnings": warnings, "centre": Vector3(0, -min_y, 0), "bc": bc,
		"T": triangulation_number(bc)}


# ---------------------------------------------------------------------------
# The Goldberg–Coxeter subdivision
# ---------------------------------------------------------------------------

static func subdivide(poly: Dictionary, bc: Vector2i) -> Dictionary:
	var bverts: PackedVector3Array = poly["verts"]
	var bfaces: Array = poly["faces"]
	var b := bc.x
	var c := bc.y
	# Lattice basis e1 = (1, 0), e2 = (1/2, √3/2); master corners P0 = 0,
	# P1 = b e1 + c e2, P2 = −c e1 + (b + c) e2. All of it in 64-bit scalars:
	# a Vector2 is float32, and the "centroid exactly on the edge" ties that
	# Class II lives on fell to −1e-7 near two of the three corners.
	var s3 := sqrt(3.0) / 2.0
	var p1x := float(b) + 0.5 * float(c)
	var p1y := float(c) * s3
	var p2x := -float(c) + 0.5 * float(b + c)
	var p2y := float(b + c) * s3
	var det := p1x * p2y - p1y * p2x
	# Neighbour lookup: edge key → the two faces.
	var edge_faces := {}
	for fi in bfaces.size():
		var f: PackedInt32Array = bfaces[fi]
		for k in 3:
			var key := _ekey(f[k], f[(k + 1) % 3])
			if not edge_faces.has(key):
				edge_faces[key] = []
			(edge_faces[key] as Array).append(fi)
	var merge := {}       # quantised position → id
	var verts := PackedVector3Array()
	var faces: Array = []
	var face_keys := {}
	var lo_i := -c - 1
	var hi_i := b + 1
	var lo_j := -1
	var hi_j := b + c + 1
	for fi in bfaces.size():
		for i in range(lo_i, hi_i + 1):
			for j in range(lo_j, hi_j + 1):
				for up in [true, false]:
					var corners: Array = []
					if up:
						corners = [Vector2i(i, j), Vector2i(i + 1, j), Vector2i(i, j + 1)]
					else:
						corners = [Vector2i(i + 1, j), Vector2i(i + 1, j + 1), Vector2i(i, j + 1)]
					var cx := 0.0
					var cy := 0.0
					var barys: Array = []
					for cnr in corners:
						var px := float((cnr as Vector2i).x) + 0.5 * float((cnr as Vector2i).y)
						var py := float((cnr as Vector2i).y) * s3
						cx += px / 3.0
						cy += py / 3.0
						barys.append(_bary(px, py, p1x, p1y, p2x, p2y, det))
					var cb: Vector3 = _bary(cx, cy, p1x, p1y, p2x, p2y, det)
					if cb.x < -1e-7 or cb.y < -1e-7 or cb.z < -1e-7:
						continue
					var ids := PackedInt32Array()
					var ok := true
					for lam in barys:
						var res := _transfer(fi, lam as Vector3, bfaces, edge_faces)
						if res.is_empty():
							ok = false
							break
						var ff: PackedInt32Array = bfaces[int(res["face"])]
						var l: Vector3 = res["bary"]
						var pos := (bverts[ff[0]] * l.x + bverts[ff[1]] * l.y + bverts[ff[2]] * l.z).normalized()
						ids.append(_merge_vertex(pos, merge, verts))
					if not ok or ids[0] == ids[1] or ids[1] == ids[2] or ids[0] == ids[2]:
						continue
					var sorted := [ids[0], ids[1], ids[2]]
					sorted.sort()
					var fkey := "%d_%d_%d" % sorted
					if face_keys.has(fkey):
						continue
					face_keys[fkey] = true
					# Outward orientation.
					var n := (verts[ids[1]] - verts[ids[0]]).cross(verts[ids[2]] - verts[ids[0]])
					var cc := verts[ids[0]] + verts[ids[1]] + verts[ids[2]]
					if n.dot(cc) < 0.0:
						ids = PackedInt32Array([ids[0], ids[2], ids[1]])
					faces.append(ids)
	return {"verts": verts, "faces": faces}


## Barycentric coordinates of (x, y) against the master triangle, as a
## Vector3 (λ0, λ1, λ2) — the values are small enough for float32 once the
## subtraction has been done in doubles.
static func _bary(x: float, y: float, p1x: float, p1y: float, p2x: float, p2y: float, det: float) -> Vector3:
	var l1 := (x * p2y - y * p2x) / det
	var l2 := (p1x * y - p1y * x) / det
	return Vector3(1.0 - l1 - l2, l1, l2)


## Carry a barycentric point across face edges until it is inside a face.
static func _transfer(face: int, lam: Vector3, bfaces: Array, edge_faces: Dictionary) -> Dictionary:
	var fi := face
	var l := [lam.x, lam.y, lam.z]
	for _hop in 12:
		var k := -1
		var worst := -1e-6
		for m in 3:
			if float(l[m]) < worst:
				worst = float(l[m])
				k = m
		if k < 0:
			return {"face": fi, "bary": Vector3(maxf(float(l[0]), 0.0), maxf(float(l[1]), 0.0), maxf(float(l[2]), 0.0))}
		var f: PackedInt32Array = bfaces[fi]
		var va := f[(k + 1) % 3]
		var vb := f[(k + 2) % 3]
		var pair: Array = edge_faces.get(_ekey(va, vb), [])
		var nf := -1
		for cand in pair:
			if int(cand) != fi:
				nf = int(cand)
		if nf < 0:
			return {}
		var g: PackedInt32Array = bfaces[nf]
		var la := float(l[(k + 1) % 3]) + float(l[k])
		var lb := float(l[(k + 2) % 3]) + float(l[k])
		var lc := -float(l[k])
		var nl := [0.0, 0.0, 0.0]
		for m in 3:
			if g[m] == va:
				nl[m] = la
			elif g[m] == vb:
				nl[m] = lb
			else:
				nl[m] = lc
		l = nl
		fi = nf
	return {}


static func _merge_vertex(pos: Vector3, merge: Dictionary, verts: PackedVector3Array) -> int:
	var q := 2e5
	var key := Vector3i(int(round(pos.x * q)), int(round(pos.y * q)), int(round(pos.z * q)))
	if merge.has(key):
		return int(merge[key])
	for dx in [-1, 0, 1]:
		for dy in [-1, 0, 1]:
			for dz in [-1, 0, 1]:
				var k2 := key + Vector3i(dx, dy, dz)
				if merge.has(k2) and verts[int(merge[k2])].distance_to(pos) < 2e-5:
					merge[key] = merge[k2]
					return int(merge[k2])
	var id := verts.size()
	verts.append(pos)
	merge[key] = id
	return id


static func _ekey(a: int, b: int) -> String:
	return "%d_%d" % [mini(a, b), maxi(a, b)]


# ---------------------------------------------------------------------------
# Shared helpers (the zome module uses them too)
# ---------------------------------------------------------------------------

## Unique edges [a, b] (a < b) of a face list (3- or 4-gons).
static func _edges_of(faces: Array) -> Array:
	var seen := {}
	var out: Array = []
	for f in faces:
		var pf: PackedInt32Array = f
		var n := pf.size()
		for k in n:
			var a := pf[k]
			var b := pf[(k + 1) % n]
			var key := _ekey(a, b)
			if seen.has(key):
				continue
			seen[key] = true
			out.append([mini(a, b), maxi(a, b)])
	return out


static func _vertex_normals(verts: PackedVector3Array, faces: Array) -> PackedVector3Array:
	var acc := PackedVector3Array()
	acc.resize(verts.size())
	for f in faces:
		var pf: PackedInt32Array = f
		var n := (verts[pf[1]] - verts[pf[0]]).cross(verts[pf[2]] - verts[pf[0]])
		if n.length() < 1e-12:
			continue
		n = n.normalized()
		for k in pf.size():
			acc[pf[k]] = acc[pf[k]] + n
	for i in acc.size():
		if acc[i].length() < 1e-9:
			acc[i] = verts[i].normalized() if verts[i].length() > 1e-9 else Vector3.UP
		else:
			acc[i] = acc[i].normalized()
	return acc


## Distinct vertex heights (descending), merged within `tol`.
static func _rings(verts: PackedVector3Array, tol: float) -> Array:
	var ys: Array = []
	for v in verts:
		ys.append(v.y)
	ys.sort()
	ys.reverse()
	var out: Array = []
	var group: Array = []
	for y in ys:
		if group.is_empty() or absf(float(group[0]) - float(y)) <= tol:
			group.append(y)
		else:
			out.append(_mean(group))
			group = [y]
	if not group.is_empty():
		out.append(_mean(group))
	return out


static func _mean(a: Array) -> float:
	var s := 0.0
	for x in a:
		s += float(x)
	return s / maxf(a.size(), 1)
