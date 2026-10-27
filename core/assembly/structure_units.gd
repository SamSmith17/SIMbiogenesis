class_name StructureUnits
extends RefCounted
## Any placed structure cut into the PIECES a crew carries and fits — the
## generic half of the crew build (PalletRackBuildSite draws it, the rack plan
## schedules it). A pallet rack has its own build units (PalletRackBuilder.
## build_units_node, named and ordered by the rack's own logic); everything
## else — a dome, a zome, a toroid, a Linkage Lab frame, a gantry, flat-pack
## furniture, a GLB — is cut here from its REAL model:
##   - every MultiMesh instance is one piece (a linkage beam, bracket, bolt,
##     panel);
##   - every MeshInstance3D surface is cut into its CONNECTED pieces (the
##     triangles that share a welded vertex): a dome strut, a hub, a plate, a
##     toroid rib arc, a canopy sheet each come out on their own;
##   - small bits (bolts, nuts, washers — under SMALL_M) ride with the
##     nearest real piece, the way a hub's bolts go up with its strut;
##   - more than MAX_UNITS pieces are gathered by place into that many.
## Each piece gets a `flat` frame (PalletRackBuilder.flat_frame: thinnest way
## up, long way along, so a yard lays it flat), a pile `kind` (frames = long
## and upright, beams = long, sheets = thin and wide, parts = the rest) and a
## `stage`: bottom up in HEIGHT bands, and inside a band frames, then beams,
## then parts, then sheets — the skeleton before the skin.
##
## Coordinates: the BUILD frame = the prop's ModelRoot frame with its scale
## baked in (metres) and shifted so the lowest piece sits at y = 0. The site
## stands at the ModelRoot's origin + `ground_shift` with its rotation only.
##
## Pure over a model node: no scene, no autoloads (the selftest cuts builders
## under --script). Cut geometry is cached by the record's look, so a prop
## rebuilt during a build (a chore effect, a reload) does not re-cut.

const SMALL_M := 0.16
const MAX_UNITS := 420
const WELD := 2000.0           # vertex weld grid: 0.5 mm
const BAND_M := 1.2            # height band of one stage
const MAX_FLAT_PTS := 240
const KIND_RANK := {"frames": 0, "beams": 1, "parts": 2, "sheets": 3}

## look key -> {pieces: [{arrays: [[surface arrays, Material]], aabb}], shift}
static var _cache: Dictionary = {}


## Cut the record's model into a units node (children: one Node3D per piece
## carrying MeshInstance3Ds, meta unit_id; root meta `units` = {id: {aabb,
## kind, flat, stage}} and `ground_shift`). `model_scale` = the placed
## ModelRoot's scale. `host` (optional, in the tree) lets builders that only
## draw in _ready run. {} model -> an empty node.
static func units_node(rec: Dictionary, model_scale: Vector3 = Vector3.ONE, host: Node = null,
		node_name: String = "RackUnits") -> Node3D:
	var key := look_key(rec, model_scale)
	var cut: Dictionary = _cache.get(key, {})
	if cut.is_empty():
		var model := _instantiate(rec)
		if model == null:
			var empty := Node3D.new()
			empty.name = node_name
			empty.set_meta("units", {})
			return empty
		if host != null and host.is_inside_tree():
			host.add_child(model)
		cut = cut_model(model, model_scale)
		if model.get_parent() != null:
			model.get_parent().remove_child(model)
		model.free()
		if _cache.size() > 8:
			_cache.clear()
		_cache[key] = cut
	return _nodes_for(cut, node_name)


## What decides the cut: the model and everything its look is built from.
static func look_key(rec: Dictionary, model_scale: Vector3) -> String:
	var extras := PlacedPropRuntime.model_extras(rec)
	return "%s|%d|%s" % [str(rec.get("model_id", "")), hash(JSON.stringify(extras, "", true)),
		str(model_scale.snapped(Vector3.ONE * 0.0001))]


static func _instantiate(rec: Dictionary) -> Node3D:
	var mid := str(rec.get("model_id", ""))
	var model := ModelCatalog.instantiate(mid, PlacedPropRuntime.model_extras(rec))
	if model == null:
		return null
	PlacedPropRuntime._disable_embedded_physics(model)
	# A Linkage Lab frame is put together FOLDED (stowed): the crew bolts the
	# scissor frame up compact and the raise unfolds it — which is what the
	# unpack plays once the last piece is on.
	if model is LinkageStructureBuilder:
		var lb := model as LinkageStructureBuilder
		lb.collision_mesh_enabled = false
		lb.set_fold_angle(maxf(LinkageKinematics.effective_min_fold_angle(lb.params),
			LinkageKinematics.MIN_FOLD_ANGLE))
	return model


# ---------------------------------------------------------------------------
# Cutting
# ---------------------------------------------------------------------------

## The pieces of a model: [{arrays: [[surface arrays, Material], ...], aabb,
## pts}] in the build frame, plus `shift` (the ground shift).
static func cut_model(model: Node3D, model_scale: Vector3 = Vector3.ONE) -> Dictionary:
	var raw: Array = []
	var root_xf := Transform3D(Basis.from_scale(model_scale), Vector3.ZERO)
	# A builder that keeps its instance poses on the CPU (the linkage frame)
	# says where each MultiMesh instance is.
	var inst_xfs: Dictionary = model.call("instance_transforms") if model.has_method("instance_transforms") else {}
	for c in model.get_children():
		_collect(c, root_xf, raw, inst_xfs)
	# Ground: the lowest piece at y = 0.
	var low := INF
	for p in raw:
		low = minf(low, (p["aabb"] as AABB).position.y)
	if is_inf(low):
		return {"pieces": [], "shift": 0.0}
	for p in raw:
		var shift_xf := Transform3D(Basis.IDENTITY, Vector3(0.0, -low, 0.0))
		for sa in p["arrays"]:
			var arr: Array = sa[0]
			var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			for i in vs.size():
				vs[i] = shift_xf * vs[i]
			arr[Mesh.ARRAY_VERTEX] = vs
		var bb: AABB = p["aabb"]
		bb.position.y -= low
		p["aabb"] = bb
		var pts: PackedVector3Array = p["pts"]
		for i in pts.size():
			pts[i].y -= low
		p["pts"] = pts
	var pieces := _merge_small(raw)
	pieces = _cap(pieces)
	return {"pieces": pieces, "shift": low}


static func _collect(node: Node, parent_xf: Transform3D, out: Array, inst_xfs: Dictionary = {}) -> void:
	if node is Node3D and not (node as Node3D).visible:
		return
	var xf := parent_xf
	if node is Node3D:
		xf = parent_xf * (node as Node3D).transform
	if node is MultiMeshInstance3D:
		var mmi := node as MultiMeshInstance3D
		var mm := mmi.multimesh
		if mm != null and mm.mesh != null:
			var n := mm.instance_count if mm.visible_instance_count < 0 else mini(mm.visible_instance_count, mm.instance_count)
			var known: Array = inst_xfs.get(mmi, [])
			if not known.is_empty():
				n = mini(n, known.size())
			for i in n:
				var ixf := xf * ((known[i] as Transform3D) if not known.is_empty() else mm.get_instance_transform(i))
				if ixf.basis.determinant() == 0.0:
					continue
				var piece := {"arrays": [], "aabb": AABB(), "pts": PackedVector3Array()}
				for s in mm.mesh.get_surface_count():
					var arr := _transformed(mm.mesh.surface_get_arrays(s), ixf)
					if arr.is_empty():
						continue
					var mat: Material = mmi.material_override if mmi.material_override != null \
						else mm.mesh.surface_get_material(s)
					_add_arrays(piece, arr, mat)
				if not (piece["arrays"] as Array).is_empty():
					out.append(piece)
	elif node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		var mi := node as MeshInstance3D
		for s in mi.mesh.get_surface_count():
			var mat: Material = mi.material_override
			if mat == null:
				mat = mi.get_surface_override_material(s)
			if mat == null:
				mat = mi.mesh.surface_get_material(s)
			var arr := _transformed(mi.mesh.surface_get_arrays(s), xf)
			if arr.is_empty():
				continue
			for comp in _components(arr):
				var piece := {"arrays": [], "aabb": AABB(), "pts": PackedVector3Array()}
				_add_arrays(piece, comp, mat)
				out.append(piece)
	for c in node.get_children():
		_collect(c, xf, out, inst_xfs)


## Surface arrays into the build frame (positions, normals, tangents).
static func _transformed(arrays: Array, xf: Transform3D) -> Array:
	if arrays.is_empty() or arrays[Mesh.ARRAY_VERTEX] == null:
		return []
	var vs: PackedVector3Array = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).duplicate()
	if vs.is_empty():
		return []
	var out := arrays.duplicate()
	for i in vs.size():
		vs[i] = xf * vs[i]
	out[Mesh.ARRAY_VERTEX] = vs
	var nb := xf.basis.inverse().transposed()
	if arrays[Mesh.ARRAY_NORMAL] != null:
		var ns: PackedVector3Array = (arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array).duplicate()
		for i in ns.size():
			ns[i] = (nb * ns[i]).normalized()
		out[Mesh.ARRAY_NORMAL] = ns
	if arrays[Mesh.ARRAY_TANGENT] != null:
		var ts: PackedFloat32Array = (arrays[Mesh.ARRAY_TANGENT] as PackedFloat32Array).duplicate()
		for i in ts.size() / 4:
			var t := (xf.basis * Vector3(ts[i * 4], ts[i * 4 + 1], ts[i * 4 + 2])).normalized()
			ts[i * 4] = t.x
			ts[i * 4 + 1] = t.y
			ts[i * 4 + 2] = t.z
		out[Mesh.ARRAY_TANGENT] = ts
	# A mirroring transform flips the winding: put it back.
	if xf.basis.determinant() < 0.0:
		_flip_winding(out)
	return out


static func _flip_winding(arr: Array) -> void:
	if arr[Mesh.ARRAY_INDEX] != null and not (arr[Mesh.ARRAY_INDEX] as PackedInt32Array).is_empty():
		var idx: PackedInt32Array = (arr[Mesh.ARRAY_INDEX] as PackedInt32Array).duplicate()
		for t in idx.size() / 3:
			var a := idx[t * 3 + 1]
			idx[t * 3 + 1] = idx[t * 3 + 2]
			idx[t * 3 + 2] = a
		arr[Mesh.ARRAY_INDEX] = idx
		return
	# Unindexed: swap the second and third vertex of every triangle in every
	# per-vertex array.
	for k in Mesh.ARRAY_MAX:
		if k == Mesh.ARRAY_INDEX or arr[k] == null:
			continue
		var a: Variant = arr[k]
		var stride := _stride(a, (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size())
		if stride <= 0:
			continue
		var b: Variant = a.duplicate()
		var nv := (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		for t in nv / 3:
			for s in stride:
				b[(t * 3 + 1) * stride + s] = a[(t * 3 + 2) * stride + s]
				b[(t * 3 + 2) * stride + s] = a[(t * 3 + 1) * stride + s]
		arr[k] = b


static func _stride(a: Variant, nv: int) -> int:
	if nv <= 0:
		return 0
	var n := 0
	if a is PackedVector3Array or a is PackedVector2Array or a is PackedColorArray:
		n = a.size()
	elif a is PackedFloat32Array or a is PackedInt32Array or a is PackedByteArray:
		n = a.size()
	else:
		return 0
	return n / nv if n % nv == 0 else 0


## A surface's connected pieces: triangles joined by a welded vertex. Each
## comes back as its own (unindexed) surface arrays.
static func _components(arr: Array) -> Array:
	var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var idx := PackedInt32Array()
	if arr[Mesh.ARRAY_INDEX] != null:
		idx = arr[Mesh.ARRAY_INDEX]
	var n_tri := (idx.size() if not idx.is_empty() else vs.size()) / 3
	if n_tri <= 0:
		return []
	# Weld vertex positions, then union the corners of every triangle.
	var weld := {}
	var wid := PackedInt32Array()
	wid.resize(vs.size())
	for i in vs.size():
		var v := vs[i]
		var k := Vector3i(roundi(v.x * WELD), roundi(v.y * WELD), roundi(v.z * WELD))
		var w: int = weld.get(k, -1)
		if w < 0:
			w = weld.size()
			weld[k] = w
		wid[i] = w
	var parent := PackedInt32Array()
	parent.resize(weld.size())
	for i in parent.size():
		parent[i] = i
	var corner := func(t: int, c: int) -> int:
		return idx[t * 3 + c] if not idx.is_empty() else t * 3 + c
	for t in n_tri:
		var a := _find(parent, wid[corner.call(t, 0)])
		for c in [1, 2]:
			var b := _find(parent, wid[corner.call(t, c)])
			if a != b:
				parent[b] = a
	# Triangles per component root.
	var by_root := {}
	for t in n_tri:
		var r := _find(parent, wid[corner.call(t, 0)])
		if not by_root.has(r):
			by_root[r] = []   # an Array: a packed array held in a Dictionary appends to a copy
		(by_root[r] as Array).append(t)
	if by_root.size() == 1:
		return [arr]
	var out: Array = []
	for r in by_root:
		out.append(_subset(arr, by_root[r], idx))
	return out


static func _find(parent: PackedInt32Array, i: int) -> int:
	var r := i
	while parent[r] != r:
		r = parent[r]
	var j := i
	while parent[j] != r:
		var nx := parent[j]
		parent[j] = r
		j = nx
	return r


## The triangles `tris` of a surface as their own unindexed arrays.
static func _subset(arr: Array, tris: Array, idx: PackedInt32Array) -> Array:
	var nv := (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var src_ids := PackedInt32Array()
	src_ids.resize(tris.size() * 3)
	for k in tris.size():
		var t: int = tris[k]
		for c in 3:
			src_ids[k * 3 + c] = idx[t * 3 + c] if not idx.is_empty() else t * 3 + c
	var out: Array = []
	out.resize(Mesh.ARRAY_MAX)
	for a in Mesh.ARRAY_MAX:
		if a == Mesh.ARRAY_INDEX or arr[a] == null:
			continue
		var src: Variant = arr[a]
		var stride := _stride(src, nv)
		if stride <= 0:
			continue
		var dst: Variant = src.duplicate()
		dst.resize(src_ids.size() * stride)
		for i in src_ids.size():
			for s in stride:
				dst[i * stride + s] = src[src_ids[i] * stride + s]
		out[a] = dst
	return out


static func _add_arrays(piece: Dictionary, arr: Array, mat: Material) -> void:
	(piece["arrays"] as Array).append([arr, mat])
	var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var bb := AABB(vs[0], Vector3.ZERO)
	for v in vs:
		bb = bb.expand(v)
	var had := not ((piece["pts"] as PackedVector3Array).is_empty())
	piece["aabb"] = (piece["aabb"] as AABB).merge(bb) if had else bb
	var pts: PackedVector3Array = piece["pts"]
	var step := maxi(1, vs.size() / 64)
	for i in range(0, vs.size(), step):
		pts.append(vs[i])
	piece["pts"] = pts


## Bolts, nuts, washers and other bits under SMALL_M go up with the nearest
## real piece.
static func _merge_small(raw: Array) -> Array:
	var big: Array = []
	var small: Array = []
	for p in raw:
		var s: Vector3 = (p["aabb"] as AABB).size
		(small if maxf(s.x, maxf(s.y, s.z)) < SMALL_M else big).append(p)
	if big.is_empty():
		return raw
	for p in small:
		var c: Vector3 = (p["aabb"] as AABB).get_center()
		var best := 0
		var bd := INF
		for i in big.size():
			var d := _aabb_dist((big[i]["aabb"] as AABB), c)
			if d < bd:
				bd = d
				best = i
		_absorb(big[best], p)
	return big


static func _aabb_dist(bb: AABB, p: Vector3) -> float:
	var q := p.clamp(bb.position, bb.end)
	return q.distance_squared_to(p)


static func _absorb(into: Dictionary, p: Dictionary) -> void:
	(into["arrays"] as Array).append_array(p["arrays"])
	into["aabb"] = (into["aabb"] as AABB).merge(p["aabb"])
	var pts: PackedVector3Array = into["pts"]
	pts.append_array(p["pts"])
	into["pts"] = pts


## More than MAX_UNITS pieces: gather them by place (a grid that grows until
## it has few enough cells).
static func _cap(pieces: Array) -> Array:
	if pieces.size() <= MAX_UNITS:
		return pieces
	var cell := 0.5
	var groups := {}
	while true:
		groups = {}
		for p in pieces:
			var c: Vector3 = (p["aabb"] as AABB).get_center()
			var k := Vector3i(floori(c.x / cell), floori(c.y / cell), floori(c.z / cell))
			if not groups.has(k):
				groups[k] = []
			(groups[k] as Array).append(p)
		if groups.size() <= MAX_UNITS:
			break
		cell *= 1.4
	var out: Array = []
	for k in groups:
		var g: Array = groups[k]
		var head: Dictionary = g[0]
		for i in range(1, g.size()):
			_absorb(head, g[i])
		out.append(head)
	return out


# ---------------------------------------------------------------------------
# Nodes + piece info
# ---------------------------------------------------------------------------

static func _nodes_for(cut: Dictionary, node_name: String) -> Node3D:
	var root := Node3D.new()
	root.name = node_name
	var info := {}
	var pieces: Array = cut.get("pieces", [])
	# Ids in build order, so a sorted id list reads bottom up.
	var bounds := AABB()
	for i in pieces.size():
		bounds = (pieces[i]["aabb"] as AABB) if i == 0 else bounds.merge(pieces[i]["aabb"])
	var c := bounds.get_center()
	var recs: Array = []
	for p in pieces:
		var flat := _flat(p)
		var kind := kind_of(flat, p["aabb"])
		var bb: AABB = p["aabb"]
		var band := floori(bb.position.y / BAND_M + 0.001)
		var stage := band * 4 + int(KIND_RANK[kind])
		var pc := bb.get_center()
		var ang := atan2(pc.z - c.z, pc.x - c.x)
		recs.append({"p": p, "flat": flat, "kind": kind, "stage": stage, "ang": ang})
	recs.sort_custom(func(a, b) -> bool:
		if int(a["stage"]) != int(b["stage"]):
			return int(a["stage"]) < int(b["stage"])
		return float(a["ang"]) < float(b["ang"]))
	for i in recs.size():
		var r: Dictionary = recs[i]
		var p: Dictionary = r["p"]
		var id := "piece:%04d" % i
		var node := Node3D.new()
		node.name = "U%d" % i
		node.set_meta("unit_id", id)
		# One mesh per material.
		var by_mat := {}
		for sa in p["arrays"]:
			var mat: Material = sa[1]
			var k: Variant = mat if mat != null else "none"
			if not by_mat.has(k):
				by_mat[k] = []
			(by_mat[k] as Array).append(sa[0])
		var mesh := ArrayMesh.new()
		for k in by_mat:
			# One surface per material (a merged piece can carry hundreds of
			# bits; a mesh holds at most 256 surfaces).
			var arr := _concat(by_mat[k])
			if arr.is_empty():
				continue
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
			if k is Material:
				mesh.surface_set_material(mesh.get_surface_count() - 1, k)
			if mesh.get_surface_count() >= 255:
				break
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		node.add_child(mi)
		root.add_child(node)
		info[id] = {"aabb": p["aabb"], "kind": r["kind"], "flat": r["flat"], "stage": r["stage"],
			"node": node.name}
	root.set_meta("units", info)
	root.set_meta("ground_shift", float(cut.get("shift", 0.0)))
	return root


## Surface arrays joined into one unindexed surface: the vertex arrays every
## part carries (positions always; normals, tangents, colours and UVs where
## all of them have them).
static func _concat(list: Array) -> Array:
	if list.is_empty():
		return []
	if list.size() == 1 and (list[0][Mesh.ARRAY_INDEX] == null
			or (list[0][Mesh.ARRAY_INDEX] as PackedInt32Array).is_empty()):
		return list[0]
	var keep := [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_TANGENT, Mesh.ARRAY_COLOR,
		Mesh.ARRAY_TEX_UV, Mesh.ARRAY_TEX_UV2]
	var present := {}
	for k in keep:
		var all_have := true
		for a in list:
			if (a as Array)[k] == null:
				all_have = false
				break
		present[k] = all_have
	var out: Array = []
	out.resize(Mesh.ARRAY_MAX)
	var acc := {Mesh.ARRAY_VERTEX: PackedVector3Array(), Mesh.ARRAY_NORMAL: PackedVector3Array(),
		Mesh.ARRAY_TANGENT: PackedFloat32Array(), Mesh.ARRAY_COLOR: PackedColorArray(),
		Mesh.ARRAY_TEX_UV: PackedVector2Array(), Mesh.ARRAY_TEX_UV2: PackedVector2Array()}
	for a in list:
		var arr: Array = a
		var nv := (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		var idx := PackedInt32Array()
		if arr[Mesh.ARRAY_INDEX] != null:
			idx = arr[Mesh.ARRAY_INDEX]
		var order := idx
		if order.is_empty():
			order.resize(nv)
			for i in nv:
				order[i] = i
		for k in keep:
			if not bool(present[k]):
				continue
			var src: Variant = arr[k]
			var stride := _stride(src, nv)
			if stride <= 0:
				present[k] = false
				continue
			var dst: Variant = acc[k]
			for i in order:
				for s in stride:
					dst.append(src[i * stride + s])
			acc[k] = dst
	for k in keep:
		if bool(present[k]):
			out[k] = acc[k]
	if out[Mesh.ARRAY_VERTEX] == null or (out[Mesh.ARRAY_VERTEX] as PackedVector3Array).is_empty():
		return []
	return out


## The piece's own frame: PalletRackBuilder.flat_frame over its points, with
## its principal axes as the candidate directions.
static func _flat(p: Dictionary) -> Dictionary:
	var pts: PackedVector3Array = p["pts"]
	var arr: Array = []
	var step := maxi(1, pts.size() / MAX_FLAT_PTS)
	for i in range(0, pts.size(), step):
		arr.append(pts[i])
	if arr.is_empty():
		return {}
	return PalletRackBuilder.flat_frame(arr, principal_axes(arr))


## The three principal directions of a point cloud (Jacobi on the covariance).
static func principal_axes(pts: Array) -> Array:
	var n := pts.size()
	if n < 3:
		return []
	var m := Vector3.ZERO
	for q in pts:
		m += q
	m /= float(n)
	var a := [[0.0, 0.0, 0.0], [0.0, 0.0, 0.0], [0.0, 0.0, 0.0]]
	for q in pts:
		var d: Vector3 = q - m
		for i in 3:
			for j in 3:
				a[i][j] += d[i] * d[j]
	var v := [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]
	for _sweep in 12:
		for pq in [[0, 1], [0, 2], [1, 2]]:
			var p: int = pq[0]
			var q: int = pq[1]
			if absf(a[p][q]) < 1e-12:
				continue
			var theta: float = (float(a[q][q]) - float(a[p][p])) / (2.0 * float(a[p][q]))
			var t := signf(theta) / (absf(theta) + sqrt(theta * theta + 1.0))
			if theta == 0.0:
				t = 1.0
			var cs := 1.0 / sqrt(t * t + 1.0)
			var sn := t * cs
			for k in 3:
				var akp: float = a[k][p]
				var akq: float = a[k][q]
				a[k][p] = cs * akp - sn * akq
				a[k][q] = sn * akp + cs * akq
			for k in 3:
				var apk: float = a[p][k]
				var aqk: float = a[q][k]
				a[p][k] = cs * apk - sn * aqk
				a[q][k] = sn * apk + cs * aqk
			for k in 3:
				var vkp: float = v[k][p]
				var vkq: float = v[k][q]
				v[k][p] = cs * vkp - sn * vkq
				v[k][q] = sn * vkp + cs * vkq
	var out: Array = []
	for j in 3:
		var e := Vector3(v[0][j], v[1][j], v[2][j])
		if e.length() > 1e-6:
			out.append(e.normalized())
	return out


## The pile a piece goes on, from its flat frame (size = across, thin, long).
static func kind_of(flat: Dictionary, bb: AABB) -> String:
	var sz: Vector3 = flat.get("size", bb.size)
	var across := sz.x
	var thin := sz.y
	var long := sz.z
	if long >= 0.6 and long >= 4.0 * maxf(across, thin):
		var axis: Vector3 = (flat.get("basis", Basis()) as Basis).z
		return "frames" if absf(axis.dot(Vector3.UP)) > 0.7 else "beams"
	if thin <= 0.06 and across >= 0.25:
		return "sheets"
	return "parts"
