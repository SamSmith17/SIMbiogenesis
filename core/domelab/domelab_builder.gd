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
## ghost_highlight (the placement ghost's tint).

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
	var any := {}
	var add_prism := func(key: String, a: Vector3, b: Vector3, across: Vector3, w: float, t: float, round_: bool) -> void:
		if not sts.has(key):
			var st0 := SurfaceTool.new()
			st0.begin(Mesh.PRIMITIVE_TRIANGLES)
			sts[key] = st0
		_prism(sts[key], a, b, across, w, t, round_)
		any[key] = true

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
	# --- panels -------------------------------------------------------------
	var pn: Dictionary = d["panels"]
	var panels: Array = pn.get("panels", [])
	if not panels.is_empty():
		var pmat: Dictionary = pn["material"]
		var t := maxf(float(pmat.get("t_mm", 3.0)) * 0.001, 0.004)
		var faces: Array = geo["faces"]
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
			# Panels sit just under the struts' outer surface (plates ARE the surface).
			if sys != "plate" and not nx.is_empty():
				off -= nm * (strut_t * 0.5)
			elif sys != "plate":
				off -= nm * (strut_t * 0.5 + t)
			var key := "hl" if str(p.get("type", "")) == highlight else "panel"
			if not sts.has(key):
				var st0 := SurfaceTool.new()
				st0.begin(Mesh.PRIMITIVE_TRIANGLES)
				sts[key] = st0
			var tris := _slab(sts[key], p["poly"], fr, t, off)
			any[key] = true
			if record:
				picks.append({"kind": "panel", "id": str(p.get("type", "")), "tris": tris, "label": str(p.get("label", ""))})
	# --- commit -------------------------------------------------------------
	var mesh := ArrayMesh.new()
	var order := ["strut", "slat", "hub", "panel", "hl"]
	for key in order:
		if not sts.has(key) or not any.has(key):
			continue
		var st: SurfaceTool = sts[key]
		# ⚠ Never generate_normals() here: SurfaceTool's default smooth group
		# merges every vertex by position, so a dome's flat panels and the
		# prisms' crisp edges rendered as one rounded "bubble". Every emitter
		# below writes the normal it means.
		var arrays := st.commit_to_arrays()
		if arrays[Mesh.ARRAY_VERTEX] == null or (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).is_empty():
			continue
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(mesh.get_surface_count() - 1, _material_for(key, d, ghost))
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = mesh
	root.add_child(mi)
	if record:
		root.set_meta("picks", picks)
	var st_: Dictionary = d["stats"]
	root.set_meta("size_m", Vector3(float(st_["radius_max_m"]) * 2.0, float(st_["height_m"]), float(st_["radius_max_m"]) * 2.0))
	return root


# ---------------------------------------------------------------------------
# Geometry emitters
# ---------------------------------------------------------------------------

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
