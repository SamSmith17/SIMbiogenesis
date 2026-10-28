class_name DomeLabBuilder
extends RefCounted

## The dome in 3D: struts as tubes / bars along the edges (bars lie flat on
## the surface, lumber and ribs stand on edge), hubs at the vertices, slats
## for a nexorade, curved ribs for a helix zome, panels in the faces. One
## MeshInstance3D "Mesh" with a surface per material, so PlacedProp's
## collision and pick box just work. Metres, y up, the floor at y = 0 with
## the structure centred on its axis.
##
## opts: explode (0..1, parts move out along the surface normal), assembly
## (0..1, rings appear from the base up), highlight (a strut class, hub type,
## panel type, slat class or rib label), record (keep pick data on the node),
## ghost_highlight (the placement ghost's tint), pieces (one MeshInstance3D
## per part a crew carries — a strut, a hub, a rib length, a slat, a panel
## with its pane; a folded plate WITH its flanges and bolts, since a plate
## system has no struts or hubs — tagged for StructureUnits instead of the
## one "Mesh").

const MODEL_ID := "domelab_structure"
const EXPLODE_M := 0.35
const DROP_M := 0.6
const HIGHLIGHT := Color(1.0, 0.72, 0.25)

static var _mat_cache := {}


static func build_node(spec: Dictionary = {}, node_name: String = "DomeStructure", opts: Dictionary = {}) -> Node3D:
	var design := DomeLabDesign.solve(spec)
	return build_from_design(design, node_name, opts)


static func build_from_design(d: Dictionary, node_name: String = "DomeStructure", opts: Dictionary = {}) -> Node3D:
	var root := Node3D.new()
	root.name = node_name
	var s: Dictionary = d["spec"]
	root.set_meta("domelab_spec", DomeLabSpec.to_json_safe(s))
	var explode := clampf(float(opts.get("explode", 0.0)), 0.0, 1.0)
	var assembly := clampf(float(opts.get("assembly", 1.0)), 0.0, 1.0)
	var highlight := str(opts.get("highlight", ""))
	var record := bool(opts.get("record", false))
	var ghost := bool(opts.get("ghost_highlight", false))
	var pieces := bool(opts.get("pieces", false))
	var geo: Dictionary = d["geo"]
	var verts: PackedVector3Array = geo["verts"]
	var normals: PackedVector3Array = geo["normals"]
	var radius := float(s["radius_m"])
	var sys := str(s["system"])
	var mat := DomeLabMaterials.strut(str(s["strut"]["material"]))
	var cols: Dictionary = s["colors"]
	# Assembly: ring index per vertex, shown when below the scrub.
	var ring_of := PackedInt32Array()
	ring_of.resize(verts.size())
	var n_rings := (d["order"] as Array).size()
	for rg in d["order"]:
		for vid in rg["vertices"]:
			ring_of[int(vid)] = int(rg["ring"])
	var shown := func(vid: int) -> float:
		# 1 = fully there, (0, 1) = dropping in, <= 0 hidden.
		return assembly * float(n_rings) - float(ring_of[vid]) + 0.001
	var lift := func(k: float) -> Vector3:
		return Vector3(0, DROP_M * (1.0 - clampf(k, 0.0, 1.0)), 0)

	var sts := {}   # material key → SurfaceTool
	var picks: Array = []
	# Pieces mode: the part being drawn collects in pc and is committed as
	# its own node by flush.
	var pc := {"sts": {}, "accs": {}}
	var piece_nodes: Array = []
	var add_prism := func(key: String, a: Vector3, b: Vector3, across: Vector3, w: float, t: float, round_: bool) -> void:
		var into: Dictionary = pc["sts"] if pieces else sts
		if not into.has(key):
			var st0 := SurfaceTool.new()
			st0.begin(Mesh.PRIMITIVE_TRIANGLES)
			into[key] = st0
		_prism(into[key], a, b, across, w, t, round_)
	var flush := func(kind: String, words: Array, order: int) -> void:
		if not pieces:
			return
		var pm := _commit(pc["sts"], pc["accs"], d, ghost)
		pc["sts"] = {}
		pc["accs"] = {}
		if pm.get_surface_count() > 0:
			var pmi := MeshInstance3D.new()
			pmi.mesh = pm
			StructureUnits.tag_piece(pmi, kind, words, order)
			piece_nodes.append(pmi)

	# --- struts -------------------------------------------------------------
	var strut_mat_key := "strut"
	var strut_w := DomeLabMaterials.strut_width_mm(mat) * 0.001
	var strut_t := strut_w
	var kind := str(mat.get("kind", "tube"))
	var round_ := kind == "tube"
	if kind in ["bar", "lumber", "beam"]:
		strut_w = float(mat.get("w_mm", 40.0)) * 0.001
		strut_t = float(mat.get("t_mm", 40.0)) * 0.001
	for st in d["struts"]:
		var e: Dictionary = d["edges"][int(st["edge"])]
		var a := int(e["a"])
		var b := int(e["b"])
		var ka: float = shown.call(a)
		var kb: float = shown.call(b)
		var k := minf(ka, kb)
		if k <= 0.0:
			continue
		var nm := (normals[a] + normals[b]).normalized()
		var off: Vector3 = nm * (EXPLODE_M * radius * 0.3 * explode) + lift.call(k)
		var key := "hl" if str(st["label"]) == highlight else strut_mat_key
		var pa := verts[a] + off
		var pb := verts[b] + off
		# Bars lie flat on the surface (thickness along the normal); lumber /
		# beams stand on edge (the deep side along the normal); tubes are round.
		var w := strut_w
		var t := strut_t
		if kind == "bar":
			add_prism.call(key, pa, pb, nm, t, w, false)
		elif kind in ["lumber", "beam"]:
			add_prism.call(key, pa, pb, nm, w, t, false)
		else:
			add_prism.call(key, pa, pb, (pb - pa).cross(nm).normalized(), w, t, round_)
		if record:
			picks.append({"kind": "strut", "id": str(st["label"]), "a": pa, "b": pb, "r": maxf(w, t) * 0.6,
				"edge": int(st["edge"])})
		flush.call("", ["a strut", "struts"], 0)
	# --- helix ribs ---------------------------------------------------------
	for rb in d["ribs"]:
		var fam := str(rb["fam"])
		var idx := int(rb["index"])
		var key := "hl" if str(rb.get("label", "")) == highlight else strut_mat_key
		for sg in rb["segs"]:
			var e: Dictionary = d["edges"][int(sg["edge"])]
			var k := minf(shown.call(int(e["a"])), shown.call(int(e["b"])))
			if k <= 0.0:
				continue
			var k0 := float(sg["k0"])
			var k1 := float(sg["k1"])
			var steps := 6
			var prev := DomeLabZome.rib_point(geo, fam, idx, k0)
			for i in range(1, steps + 1):
				var kk := lerpf(k0, k1, float(i) / steps)
				var p := DomeLabZome.rib_point(geo, fam, idx, kk)
				var mid := (prev + p) * 0.5
				var nm := Vector3(mid.x, 0.0, mid.z)
				nm = (nm.normalized() if nm.length() > 1e-6 else Vector3.UP) * 0.7 + Vector3.UP * 0.5
				nm = nm.normalized()
				var off: Vector3 = nm * (EXPLODE_M * radius * 0.3 * explode) + lift.call(k)
				var across := (p - prev).cross(nm).normalized()
				add_prism.call(key, prev + off, p + off, across, float(mat.get("w_mm", 90.0)) * 0.001,
					float(mat.get("t_mm", 18.0)) * 0.001, false)
				if record:
					picks.append({"kind": "rib", "id": str(rb.get("label", "")), "a": prev + off, "b": p + off,
						"r": float(mat.get("w_mm", 90.0)) * 0.0006, "edge": int(sg["edge"])})
				prev = p
			flush.call("", ["a rib length", "rib lengths"], 0)
	# --- nexors -------------------------------------------------------------
	var nx: Dictionary = d["nexorade"]
	if not nx.is_empty():
		var slat: Dictionary = nx.get("slat", mat)
		var w := float(slat.get("w_mm", 50.0)) * 0.001
		var t := float(slat.get("t_mm", 6.0)) * 0.001
		for n in nx["nexors"]:
			var e: Dictionary = d["edges"][int(n["edge"])]
			var k := minf(shown.call(int(e["a"])), shown.call(int(e["b"])))
			if k <= 0.0:
				continue
			var nm: Vector3 = n["n"]
			var off: Vector3 = nm * (t * 0.5 + EXPLODE_M * radius * 0.3 * explode) + lift.call(k)
			var key := "hl" if str(n.get("label", "")) == highlight else "slat"
			add_prism.call(key, (n["p0"] as Vector3) + off, (n["p1"] as Vector3) + off, nm, t, w, false)
			if record:
				picks.append({"kind": "slat", "id": str(n.get("label", "")), "a": (n["p0"] as Vector3) + off,
					"b": (n["p1"] as Vector3) + off, "r": w * 0.6, "edge": int(n["edge"])})
			flush.call("", ["a slat", "slats"], 0)
	# --- hubs ---------------------------------------------------------------
	if sys != "plate":
		var hub: Dictionary = s["hub"]
		var hub_kind := str(hub["kind"]) if sys == "hub" else "bolt"
		if sys == "nexorade":
			hub_kind = "none"
		for h in d["hubs"]:
			var vid := int(h["id"])
			var k: float = shown.call(vid)
			if k <= 0.0 or hub_kind == "none":
				continue
			var nm := normals[vid]
			var off: Vector3 = nm * (EXPLODE_M * radius * 0.3 * explode) + lift.call(k)
			var p := verts[vid] + off
			var key := "hl" if str(h["type"]) == highlight else "hub"
			var r := 0.0
			match hub_kind:
				"socket":
					r = strut_w * 1.1
					add_prism.call(key, p - nm * r, p + nm * r, nm.cross(Vector3.UP if absf(nm.y) < 0.9 else Vector3.RIGHT).normalized(), r * 2.0, r * 2.0, true)
				"plate":
					r = (float(hub["reach_mm"]) + 25.0) * 0.001
					var th := float(hub["plate_t_mm"]) * 0.001
					add_prism.call(key, p - nm * th * 0.5, p + nm * th * 0.5, nm.cross(Vector3.UP if absf(nm.y) < 0.9 else Vector3.RIGHT).normalized(), r * 2.0, r * 2.0, true)
				"ring":
					r = strut_w * 1.6
					add_prism.call(key, p - nm * strut_w * 0.5, p + nm * strut_w * 0.5, nm.cross(Vector3.UP if absf(nm.y) < 0.9 else Vector3.RIGHT).normalized(), r * 2.0, r * 2.0, true)
				_:
					# The bolt through a stack of flattened ends.
					var bolt := DomeLabMaterials.bolt(str(hub["bolt"]))
					var L := DomeLabConnectors.bolt_length_mm(int(h["valence"]), mat, bolt, true) * 0.001
					r = float(bolt["d_mm"]) * 0.001 * 0.5
					var across := nm.cross(Vector3.UP if absf(nm.y) < 0.9 else Vector3.RIGHT).normalized()
					add_prism.call(key, p - nm * L * 0.35, p + nm * L * 0.65, across, r * 2.0, r * 2.0, true)
					# The nut.
					add_prism.call(key, p + nm * L * 0.45, p + nm * L * 0.65, across, r * 4.0, r * 4.0, true)
					r = maxf(r * 4.0, strut_w * 0.6)
			if record:
				picks.append({"kind": "hub", "id": str(h["type"]), "c": p, "r": maxf(r, 0.04), "vertex": vid})
			flush.call("parts", ["a hub", "hubs"], 0)
	# --- panels -------------------------------------------------------------
	# Faces go into packed arrays (accs), not SurfaceTool: a folded-plate
	# tower is a few hundred thousand vertices and SurfaceTool's per-vertex
	# calls were most of the build.
	var accs := {}
	var pn: Dictionary = d["panels"]
	var panels: Array = pn.get("panels", [])
	if not panels.is_empty():
		var t_mm := float(pn.get("t_mm", 3.0))
		var faces: Array = geo["faces"]
		var plate := sys == "plate"
		var glz: Dictionary = pn.get("glazing", {})
		var pane_t := maxf(float(glz.get("t_mm", 4.0)), 2.0)
		var secs := {}
		for p in panels:
			var f: PackedInt32Array = faces[int(p["face"])]
			var k := INF
			for id in f:
				k = minf(k, shown.call(int(id)))
			if k <= 0.0:
				continue
			var fr: Transform3D = p["frame"]
			var nm := fr.basis.z.normalized()
			var off: Vector3 = nm * (EXPLODE_M * radius * 0.6 * explode) + lift.call(k)
			var key := "hl" if str(p.get("type", "")) == highlight else "panel"
			var pac: Dictionary = pc["accs"] if pieces else accs
			var acc := _acc(pac, key)
			var tris := PackedVector3Array()
			var oculus: PackedVector2Array = p.get("oculus", PackedVector2Array())
			var z_under := 0.0
			if plate:
				tris = _folded_plate(acc, p, pn, secs, off)
				z_under = -t_mm
			else:
				# A covering sits just under the struts' outer surface.
				var t_cov := maxf(t_mm, 4.0)
				var sink := 0.0
				if not nx.is_empty():
					sink = strut_t * 500.0
				else:
					sink = strut_t * 500.0 + t_cov
				tris = _plate_slab(acc, p["poly"], oculus, fr, -sink + t_cov * 0.5, -sink - t_cov * 0.5, off)
				z_under = -sink - t_cov * 0.5
			var pane: PackedVector2Array = p.get("pane", PackedVector2Array())
			if not pane.is_empty():
				_plate_slab(_acc(pac, "glass"), pane, PackedVector2Array(), fr, z_under - 0.5, z_under - 0.5 - pane_t, off)
			if record:
				picks.append({"kind": "panel", "id": str(p.get("type", "")), "tris": tris, "label": str(p.get("label", ""))})
			# A plate system's plates ARE the structure (order 0, bottom up);
			# a covering goes on once the frame stands.
			flush.call("sheets", ["a plate", "plates"] if plate else ["a panel", "panels"], 0 if plate else 1)
		# Bolts through each flange pair (hidden while the plates are pulled apart).
		if plate and bool(s["face"]["bolts"]) and explode < 0.01:
			var bolt := DomeLabMaterials.bolt(str(s["hub"]["bolt"]))
			var bd := float(bolt["d_mm"]) * 0.001
			var reach := (float(pn.get("gap_mm", 0.0)) * 0.5 + t_mm) * 0.001
			for bt in pn.get("bolts3d", []):
				var e: Dictionary = d["edges"][int(bt["edge"])]
				var kk := minf(shown.call(int(e["a"])), shown.call(int(e["b"])))
				if kk < 1.0:
					continue
				var c: Vector3 = bt["p"]
				var ax: Vector3 = bt["axis"]
				var side := ax.cross(Vector3.UP if absf(ax.y) < 0.9 else Vector3.RIGHT).normalized()
				# Pieces mode: each bolt its own small piece, which StructureUnits
				# hands to the plate it is nearest.
				var acc := _acc(pc["accs"] if pieces else accs, "hub")
				_hex(acc, c + ax * reach, c + ax * (reach + bd * 0.65), side, bd * 1.7)
				_hex(acc, c - ax * reach, c - ax * (reach + bd * 0.85), side, bd * 1.6)
				_hex(acc, c - ax * (reach + bd * 0.85), c - ax * (reach + bd * 1.25), side, bd * 0.95)
				flush.call("", ["a bolt", "bolts"], 0)
	# --- commit -------------------------------------------------------------
	if pieces:
		for i in piece_nodes.size():
			var pn_i: MeshInstance3D = piece_nodes[i]
			pn_i.name = "P%d" % i
			root.add_child(pn_i)
	else:
		var mi := MeshInstance3D.new()
		mi.name = "Mesh"
		mi.mesh = _commit(sts, accs, d, ghost)
		root.add_child(mi)
	if record:
		root.set_meta("picks", picks)
	var st_: Dictionary = d["stats"]
	root.set_meta("size_m", Vector3(float(st_["radius_max_m"]) * 2.0, float(st_["height_m"]), float(st_["radius_max_m"]) * 2.0))
	return root


## The SurfaceTools (prisms) and packed accumulators (faces) of one build
## as a mesh, a surface per material.
static func _commit(sts: Dictionary, accs: Dictionary, d: Dictionary, ghost: bool) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	for key in ["strut", "slat", "hub", "panel", "glass", "hl"]:
		var verts_k := PackedVector3Array()
		var norms_k := PackedVector3Array()
		if sts.has(key):
			var st: SurfaceTool = sts[key]
			# ⚠ Never generate_normals() here: SurfaceTool's default smooth group
			# merges every vertex by position, so a dome's flat panels and the
			# prisms' crisp edges rendered as one rounded "bubble". Every emitter
			# writes the normal it means.
			var arrays := st.commit_to_arrays()
			if arrays[Mesh.ARRAY_VERTEX] != null:
				verts_k.append_array(arrays[Mesh.ARRAY_VERTEX])
				norms_k.append_array(arrays[Mesh.ARRAY_NORMAL])
		if accs.has(key):
			verts_k.append_array((accs[key] as Dictionary)["v"])
			norms_k.append_array((accs[key] as Dictionary)["n"])
		if verts_k.is_empty():
			continue
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = verts_k
		arr[Mesh.ARRAY_NORMAL] = norms_k
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		mesh.surface_set_material(mesh.get_surface_count() - 1, _material_for(key, d, ghost))
	return mesh


# ---------------------------------------------------------------------------
# Geometry emitters
# ---------------------------------------------------------------------------

static func _acc(accs: Dictionary, key: String) -> Dictionary:
	if not accs.has(key):
		accs[key] = {"v": PackedVector3Array(), "n": PackedVector3Array()}
	return accs[key]


## A triangle into a packed accumulator, wound clockwise seen from where its
## normals point (Godot's front face).
static func _atri(acc: Dictionary, p0: Vector3, p1: Vector3, p2: Vector3, n0: Vector3, n1: Vector3, n2: Vector3) -> void:
	var v: PackedVector3Array = acc["v"]
	var n: PackedVector3Array = acc["n"]
	if (p1 - p0).cross(p2 - p0).dot(n0 + n1 + n2) > 0.0:
		v.append(p0)
		v.append(p2)
		v.append(p1)
		n.append(n0)
		n.append(n2)
		n.append(n1)
	else:
		v.append(p0)
		v.append(p1)
		v.append(p2)
		n.append(n0)
		n.append(n1)
		n.append(n2)


## A hexagon prism (bolt head, nut) from a to b, `w` across corners.
static func _hex(acc: Dictionary, a: Vector3, b: Vector3, side: Vector3, w: float) -> void:
	var axis := (b - a).normalized()
	var u := (side - axis * side.dot(axis)).normalized()
	var v := axis.cross(u)
	var ring: Array = []
	for i in 6:
		var ang := TAU * i / 6.0
		ring.append(u * (cos(ang) * w * 0.5) + v * (sin(ang) * w * 0.5))
	for i in 6:
		var r0: Vector3 = ring[i]
		var r1: Vector3 = ring[(i + 1) % 6]
		var nn := (r0 + r1).normalized()
		_atri(acc, a + r0, b + r0, b + r1, nn, nn, nn)
		_atri(acc, a + r0, b + r1, a + r1, nn, nn, nn)
	for i in range(1, 5):
		_atri(acc, a + ring[0], a + ring[i], a + ring[i + 1], -axis, -axis, -axis)
		_atri(acc, b + ring[0], b + ring[i], b + ring[i + 1], axis, axis, axis)


## A flat part between z0 (its outer face) and z1 in the panel frame (mm):
## `outer` convex and CCW, `hole` (optional, convex) cut through it. Returns
## the outer face's world triangles (picking).
static func _plate_slab(acc: Dictionary, outer: PackedVector2Array, hole: PackedVector2Array, fr: Transform3D,
		z0: float, z1: float, off: Vector3) -> PackedVector3Array:
	var nrm := fr.basis.z.normalized()
	var up := nrm if z0 > z1 else -nrm
	var tris := PackedVector3Array()
	var w := func(q: Vector2, z: float) -> Vector3: return fr * Vector3(q.x, q.y, z) + off
	var faces2: Array = _ring_tris(outer, hole)
	for t3 in faces2:
		var a: Vector2 = t3[0]
		var b: Vector2 = t3[1]
		var c: Vector2 = t3[2]
		var pa: Vector3 = w.call(a, z0)
		var pb: Vector3 = w.call(b, z0)
		var pc: Vector3 = w.call(c, z0)
		_atri(acc, pa, pb, pc, up, up, up)
		tris.append_array(PackedVector3Array([pa, pb, pc]))
		_atri(acc, w.call(a, z1), w.call(b, z1), w.call(c, z1), -up, -up, -up)
	for ri in 2:
		var rr: PackedVector2Array = outer if ri == 0 else hole
		var n := rr.size()
		var inside := ri == 1
		for i in n:
			var a2: Vector2 = rr[i]
			var b2: Vector2 = rr[(i + 1) % n]
			var e := (b2 - a2).normalized()
			# Outer rim faces out of the polygon, a hole's wall into the hole.
			var n2 := Vector2(-e.y, e.x) if inside else Vector2(e.y, -e.x)
			var sn := (fr.basis * Vector3(n2.x, n2.y, 0.0)).normalized()
			var p00: Vector3 = w.call(a2, z0)
			var p10: Vector3 = w.call(b2, z0)
			var p11: Vector3 = w.call(b2, z1)
			var p01: Vector3 = w.call(a2, z1)
			_atri(acc, p00, p10, p11, sn, sn, sn)
			_atri(acc, p00, p11, p01, sn, sn, sn)
	return tris


## Triangles covering a convex polygon, or the band between it and a convex
## hole inside it (zipped round by angle from the hole's centre).
static func _ring_tris(outer: PackedVector2Array, hole: PackedVector2Array) -> Array:
	var out: Array = []
	var n := outer.size()
	if hole.size() < 3:
		for i in range(1, n - 1):
			out.append([outer[0], outer[i], outer[i + 1]])
		return out
	var m := hole.size()
	var c := Vector2.ZERO
	for q in hole:
		c += q
	c /= m
	var a0 := (outer[0] - c).angle()
	var ang := func(q: Vector2) -> float: return fposmod((q - c).angle() - a0, TAU)
	# The hole vertex at the smallest angle past outer[0].
	var j0 := 0
	var best := INF
	for j in m:
		var aj: float = ang.call(hole[j])
		if aj < best:
			best = aj
			j0 = j
	var i := 0
	var j := 0
	while i < n or j < m:
		var oi := outer[i % n]
		var hj := hole[(j0 + j) % m]
		var a_o: float = ang.call(outer[(i + 1) % n]) if i + 1 < n else TAU
		var a_h: float = ang.call(hole[(j0 + j + 1) % m]) if j + 1 < m else TAU + best
		if j >= m or (i < n and a_o <= a_h):
			out.append([oi, outer[(i + 1) % n], hj])
			i += 1
		else:
			out.append([oi, hole[(j0 + j + 1) % m], hj])
			j += 1
	return out


## One plate as folded sheet: the flat face (skin on the face plane, the
## sheet inward), and along every edge a bend + flange from
## DomeLabPanels.flange_section, mitred where two flanges meet on the plane
## that bisects them (so the corner closes like a folded box) — or, at a
## node of four or more plates, ended on the seam's node cut (pn.node_cuts,
## world mm), the plane its partner flange ends on too.
static func _folded_plate(acc: Dictionary, p: Dictionary, pn: Dictionary, secs: Dictionary, off: Vector3) -> PackedVector3Array:
	var fr: Transform3D = p["frame"]
	var fp: PackedVector2Array = p["face_poly"]
	var angs: Array = p["edge_ang"]
	var m := fp.size()
	var t := float(pn["t_mm"])
	var r := float(pn["fold_r_mm"])
	var gap := float(pn["gap_mm"])
	var depth := float(pn["flange_mm"])
	var sec: Array = []
	var dists := PackedFloat64Array()
	var planes: Array = []   # [M (Vector3, panel mm frame), d]
	for k in m:
		var sk := "%.5f" % float(angs[k])
		if not secs.has(sk):
			secs[sk] = DomeLabPanels.flange_section(float(angs[k]), t, r, gap, depth)
		var sc: Dictionary = secs[sk]
		sec.append(sc)
		dists.append(float(sc["xc"]))
		var a := fp[k]
		var b := fp[(k + 1) % m]
		var e := (b - a).normalized()
		var fin := Vector2(-e.y, e.x)
		var a2 := float(sc["a2"])
		var M := Vector3(fin.x * cos(a2), fin.y * cos(a2), sin(a2))
		planes.append([M, M.dot(Vector3(a.x, a.y, 0.0)) + gap * 0.5])
	var face := DomeLabPanels.inset_edges(fp, dists)
	# Node cuts into this panel's mm frame: world mm X = 1000·origin + R q.
	var cuts: Dictionary = pn.get("node_cuts", {})
	var vids: PackedInt32Array = p.get("vids", PackedInt32Array())
	var fid := int(p["face"])
	var rt := fr.basis.transposed() * 1000.0
	var o_mm := fr.origin * 1000.0
	var to_panel := func(cut: Array) -> Array:
		var nw: Vector3 = cut[0]
		return [rt * nw, float(cut[1]) - nw.dot(o_mm)]
	var tris := PackedVector3Array()
	if face.size() >= 3:
		tris = _plate_slab(acc, face, p.get("oculus", PackedVector2Array()), fr, 0.0, -t, off)
	var w := func(q: Vector3) -> Vector3: return fr * q + off
	for k in m:
		var sc: Dictionary = sec[k]
		var prof: PackedVector2Array = sc["profile"]
		var steps := int(sc["steps"])
		var c2: Vector2 = sc["c"]
		var a := fp[k]
		var b := fp[(k + 1) % m]
		var L := a.distance_to(b)
		var e := (b - a).normalized()
		var fin := Vector2(-e.y, e.x)
		var E := Vector3(e.x, e.y, 0.0)
		var F := Vector3(fin.x, fin.y, 0.0)
		var A := Vector3(a.x, a.y, 0.0)
		var Mk: Vector3 = planes[k][0]
		var dk: float = planes[k][1]
		var Mp: Vector3 = planes[(k - 1 + m) % m][0]
		var dp: float = planes[(k - 1 + m) % m][1]
		var Mn: Vector3 = planes[(k + 1) % m][0]
		var dn: float = planes[(k + 1) % m][1]
		var Ds := Mk - Mp
		var De := Mk - Mn
		var relief := DomeLabPanels.MITRE_RELIEF_MM
		var cut0: Array = []
		var cut1: Array = []
		if vids.size() == m and not cuts.is_empty():
			var c0: Array = cuts.get(DomeLabPanels._cut_key(fid, vids[k], vids[k], vids[(k + 1) % m]), [])
			var c1: Array = cuts.get(DomeLabPanels._cut_key(fid, vids[(k + 1) % m], vids[k], vids[(k + 1) % m]), [])
			if not c0.is_empty():
				cut0 = to_panel.call(c0)
			if not c1.is_empty():
				cut1 = to_panel.call(c1)
		var np := prof.size()
		var p0s: Array = []
		var p1s: Array = []
		for i in np:
			var q := prof[i]
			var P0 := A + F * q.x + Vector3(0, 0, q.y)
			var s0 := 0.0
			var s1 := L
			if not cut0.is_empty():
				s0 = DomeLabPanels._cut_s(cut0, P0, E)
			elif absf(Ds.dot(E)) > 1e-6:
				s0 = (dk - dp - relief * Ds.length() - Ds.dot(P0)) / Ds.dot(E)
			if not cut1.is_empty():
				s1 = DomeLabPanels._cut_s(cut1, P0, E)
			elif absf(De.dot(E)) > 1e-6:
				s1 = (dk - dn - relief * De.length() - De.dot(P0)) / De.dot(E)
			# Never past the corner by more than the flat pattern's cap.
			s0 = maxf(s0, -DomeLabPanels.MITRE_CAP * q.length())
			s1 = minf(s1, L + DomeLabPanels.MITRE_CAP * q.length())
			if s1 < s0 + 0.5:
				var mid := (s0 + s1) * 0.5
				s0 = mid
				s1 = mid
			p0s.append(w.call(P0 + E * s0))
			p1s.append(w.call(P0 + E * s1))
		# Vertex normals: radial on the bend, flat on the flange.
		var vn: Array = []
		for i in np:
			var q := prof[i]
			var n2 := Vector2.ZERO
			if i <= steps:
				n2 = (q - c2).normalized()
			elif i >= np - steps - 1:
				n2 = -(q - c2).normalized()
			vn.append(n2)
		for i in np - 1:
			var qa := prof[i]
			var qb := prof[i + 1]
			var seg := (qb - qa).normalized()
			# The outline runs outer arc → flange → inner arc, counter-clockwise
			# round the bend centre: the material is on the segment's left, the
			# outside on its right.
			var flat := Vector2(seg.y, -seg.x)
			var na: Vector2 = vn[i] if (vn[i] as Vector2) != Vector2.ZERO and (i < steps or i >= np - steps - 1) else flat
			var nb: Vector2 = vn[i + 1] if (vn[i + 1] as Vector2) != Vector2.ZERO and (i + 1 <= steps or i + 1 > np - steps - 1) else flat
			if i == steps or i == steps + 1:
				na = flat
				nb = flat
			var wa := (fr.basis * (F * na.x + Vector3(0, 0, na.y))).normalized()
			var wb := (fr.basis * (F * nb.x + Vector3(0, 0, nb.y))).normalized()
			_atri(acc, p0s[i], p1s[i], p1s[i + 1], wa, wa, wb)
			_atri(acc, p0s[i], p1s[i + 1], p0s[i + 1], wa, wb, wb)
		# End caps on the mitre planes.
		var idx := Geometry2D.triangulate_polygon(prof)
		# A node cut's cap faces the way the mitre's would (its sense along the edge).
		var cs := Ds
		if not cut0.is_empty():
			cs = (cut0[0] as Vector3) * signf((cut0[0] as Vector3).dot(E)) * signf(Ds.dot(E) if absf(Ds.dot(E)) > 1e-9 else -1.0)
		var ce := De
		if not cut1.is_empty():
			ce = (cut1[0] as Vector3) * signf((cut1[0] as Vector3).dot(E)) * signf(De.dot(E) if absf(De.dot(E)) > 1e-9 else 1.0)
		var ns := (fr.basis * cs).normalized()
		var ne := (fr.basis * ce).normalized()
		for ti in range(0, idx.size() - 2, 3):
			_atri(acc, p0s[idx[ti]], p0s[idx[ti + 1]], p0s[idx[ti + 2]], ns, ns, ns)
			_atri(acc, p1s[idx[ti]], p1s[idx[ti + 1]], p1s[idx[ti + 2]], ne, ne, ne)
	return tris


## A prism from a to b: `across` is the direction of the W side (the other
## side, T, is perpendicular to both); round_ makes a tube of diameter W
## (8 sides for a strut, 16 for anything wider than 6 cm) with RADIAL
## normals, so it shades as a cylinder while a flat prism keeps hard edges.
static func _prism(st: SurfaceTool, a: Vector3, b: Vector3, across: Vector3, w: float, t: float, round_: bool) -> void:
	var axis := b - a
	var L := axis.length()
	if L < 1e-6:
		return
	axis /= L
	var u := across - axis * across.dot(axis)
	if u.length() < 1e-6:
		u = axis.cross(Vector3.UP)
		if u.length() < 1e-6:
			u = axis.cross(Vector3.RIGHT)
	u = u.normalized()
	var v := axis.cross(u).normalized()
	var ring: Array = []
	if round_:
		var n := 8 if w < 0.06 else 16
		for i in n:
			var ang := TAU * i / n
			ring.append(u * (cos(ang) * w * 0.5) + v * (sin(ang) * w * 0.5))
	else:
		ring = [u * (w * 0.5) + v * (t * 0.5), u * (-w * 0.5) + v * (t * 0.5), u * (-w * 0.5) + v * (-t * 0.5),
			u * (w * 0.5) + v * (-t * 0.5)]
	var n := ring.size()
	for i in n:
		var r0: Vector3 = ring[i]
		var r1: Vector3 = ring[(i + 1) % n]
		if round_:
			var n0 := r0.normalized()
			var n1 := r1.normalized()
			_tri_n(st, a + r0, b + r0, b + r1, n0, n0, n1)
			_tri_n(st, a + r0, b + r1, a + r1, n0, n1, n1)
		else:
			_quad(st, a + r0, b + r0, b + r1, a + r1, (r0 + r1).normalized())
	# End caps.
	for i in range(1, n - 1):
		_tri(st, a + ring[0], a + ring[i + 1], a + ring[i], -axis)
		_tri(st, b + ring[0], b + ring[i], b + ring[i + 1], axis)


static func _quad(st: SurfaceTool, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, n: Vector3) -> void:
	_tri(st, p0, p1, p2, n)
	_tri(st, p0, p2, p3, n)


static func _tri(st: SurfaceTool, p0: Vector3, p1: Vector3, p2: Vector3, n: Vector3) -> void:
	_tri_n(st, p0, p1, p2, n, n, n)


## A triangle with a normal per vertex (a round tube's wall). Godot's front
## face winds clockwise seen from outside: the winding is flipped when the
## geometric normal disagrees with the intended one.
static func _tri_n(st: SurfaceTool, p0: Vector3, p1: Vector3, p2: Vector3, n0: Vector3, n1: Vector3, n2: Vector3) -> void:
	var g := (p1 - p0).cross(p2 - p0)
	if g.dot(n0 + n1 + n2) > 0.0:
		var tp := p1
		p1 = p2
		p2 = tp
		var tn := n1
		n1 = n2
		n2 = tn
	st.set_normal(n0)
	st.add_vertex(p0)
	st.set_normal(n1)
	st.add_vertex(p1)
	st.set_normal(n2)
	st.add_vertex(p2)


## A flat polygon (panel frame, mm) extruded by t along the frame's normal;
## returns the world triangles for picking.
static func _slab(st: SurfaceTool, poly: PackedVector2Array, fr: Transform3D, t: float, off: Vector3) -> PackedVector3Array:
	var n := poly.size()
	var nrm := fr.basis.z.normalized()
	var top: Array = []
	var bot: Array = []
	for q in poly:
		var p := fr * Vector3(q.x, q.y, 0.0) + off
		top.append(p + nrm * (t * 0.5))
		bot.append(p - nrm * (t * 0.5))
	var tris := PackedVector3Array()
	for i in range(1, n - 1):
		_tri(st, top[0], top[i], top[i + 1], nrm)
		_tri(st, bot[0], bot[i + 1], bot[i], -nrm)
		tris.append_array(PackedVector3Array([top[0], top[i], top[i + 1]]))
	for i in n:
		var a: Vector3 = top[i]
		var b: Vector3 = top[(i + 1) % n]
		var c: Vector3 = bot[(i + 1) % n]
		var dd: Vector3 = bot[i]
		var side := (b - a).cross(nrm).normalized()
		_quad(st, a, b, c, dd, side)
	return tris


## The StructureMaterials finish for a DomeLabMaterials look.
static func kind_for_look(look: String) -> int:
	match look:
		"galv": return StructureMaterials.Kind.GALVANISED
		"alu": return StructureMaterials.Kind.ALUMINIUM
		"paint": return StructureMaterials.Kind.PAINTED_METAL
		"wood": return StructureMaterials.Kind.WOOD
		"corten": return StructureMaterials.Kind.WEATHERING_STEEL
		"ply": return StructureMaterials.Kind.PLYWOOD
		"glazing": return StructureMaterials.Kind.GLAZING
		"fabric": return StructureMaterials.Kind.FABRIC
	return StructureMaterials.Kind.PLASTIC


## The colour a part is drawn in: the player's pick, or — while the pick is
## still the default — the stock's own colour, so swapping EMT for bamboo
## changes the look without a trip to the colour rows.
static func _part_color(cols: Dictionary, key: String, stock: Dictionary) -> Color:
	var col: Color = cols[key]
	if col.is_equal_approx(DomeLabSpec.COLOR_DEFAULTS[key]):
		var own: Variant = stock.get("color", null)
		if own is Color:
			return own
	return col


static func _material_for(key: String, d: Dictionary, ghost: bool) -> Material:
	var s: Dictionary = d["spec"]
	var cols: Dictionary = s["colors"]
	var m: StandardMaterial3D
	match key:
		"hl":
			m = StandardMaterial3D.new()
			m.albedo_color = HIGHLIGHT
			m.emission_enabled = true
			m.emission = HIGHLIGHT * 0.4
			m.cull_mode = BaseMaterial3D.CULL_DISABLED
		"panel":
			var sheet_id := str(s["face"]["material"])
			var pmat: Dictionary = (d["panels"] as Dictionary).get("material", DomeLabMaterials.sheet(sheet_id))
			var look := DomeLabMaterials.sheet_look(sheet_id)
			var col := _part_color(cols, "face", pmat)
			# A translucent sheet keeps its translucency whatever colour it is painted.
			var own_a := float((pmat.get("color", Color.WHITE) as Color).a)
			if own_a < 0.99 and col.a > 0.99:
				col.a = own_a
			m = StructureMaterials.make(kind_for_look(look), col)
			if look == "ply":
				# The shared plywood grain is sized for rack decking; on a
				# metre-wide panel it read as soft cloud blotches.
				m.uv1_scale = Vector3(5.0, 5.0, 5.0)
				m.normal_scale = 0.05
			if col.a < 0.99:
				m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
			if look == "glazing":
				# Both faces of a clear sheet catch the light.
				m.cull_mode = BaseMaterial3D.CULL_DISABLED
		"hub":
			m = StructureMaterials.make(StructureMaterials.Kind.HARDWARE_METAL, cols["hub"])
		"glass":
			var gid := str(s["face"]["glazing"])
			var gmat := DomeLabMaterials.sheet(gid)
			var gc: Color = gmat.get("color", Color(0.8, 0.9, 1.0, 0.4))
			m = StructureMaterials.make(StructureMaterials.Kind.GLAZING, gc)
			if gc.a < 0.99:
				m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
		"slat":
			var slat_id := str(s["nexorade"]["slat"])
			var slat: Dictionary = (d["nexorade"] as Dictionary).get("slat", DomeLabMaterials.strut(slat_id))
			m = StructureMaterials.make(kind_for_look(DomeLabMaterials.strut_look(slat_id)), _part_color(cols, "strut", slat))
		_:
			var strut_id := str(s["strut"]["material"])
			var mat := DomeLabMaterials.strut(strut_id)
			m = StructureMaterials.make(kind_for_look(DomeLabMaterials.strut_look(strut_id)), _part_color(cols, "strut", mat))
	# Closed prisms and slabs: back faces are never seen, and culling them
	# keeps a translucent sheet from drawing its inside through its outside.
	if key != "hl" and m.cull_mode == BaseMaterial3D.CULL_DISABLED and m.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED:
		m.cull_mode = BaseMaterial3D.CULL_BACK
	if ghost:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_color = Color(m.albedo_color, 0.55)
		m.emission_enabled = true
		m.emission = Color(0.3, 0.8, 1.0) * 0.25
	return m


# ---------------------------------------------------------------------------
# Picking
# ---------------------------------------------------------------------------

## The part a ray (in the node's frame) hits first: {kind, id, label} or {}.
static func pick(node: Node3D, origin: Vector3, dir: Vector3) -> Dictionary:
	var picks: Array = node.get_meta("picks", [])
	var best := {}
	var best_t := INF
	for p in picks:
		var kind := str(p["kind"])
		var t := INF
		if kind == "panel":
			var tris: PackedVector3Array = p["tris"]
			for i in range(0, tris.size() - 2, 3):
				var hit: Variant = Geometry3D.ray_intersects_triangle(origin, dir, tris[i], tris[i + 1], tris[i + 2])
				if hit != null:
					t = minf(t, origin.distance_to(hit as Vector3))
		elif kind == "hub":
			var hits := Geometry3D.segment_intersects_sphere(origin, origin + dir * 500.0, p["c"], float(p["r"]))
			if not hits.is_empty():
				t = origin.distance_to(hits[0])
		else:
			var cp := Geometry3D.get_closest_points_between_segments(origin, origin + dir * 500.0, p["a"], p["b"])
			if cp[0].distance_to(cp[1]) <= float(p["r"]):
				t = origin.distance_to(cp[0])
		if t < best_t:
			best_t = t
			best = {"kind": kind, "id": str(p["id"]), "label": str(p.get("label", p["id"])),
				"edge": int(p.get("edge", -1)), "vertex": int(p.get("vertex", -1))}
	return best
