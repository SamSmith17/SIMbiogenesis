class_name ToroidLabBuilder
extends RefCounted

## The toroid in 3D: bent tubes swept along their centrelines, a sleeve per
## tube end at every pipe fitting, tension lines, the pleated canopy (each
## half-sector three folded triangles of sheet with its flange and bolts) and
## the panels bent over the crown. One MeshInstance3D "Mesh" with a surface
## per material, so PlacedProp's collision and pick box just work. Metres,
## y up, the ground at y = 0, the axis through the origin.
##
## opts: explode (0..1: canopy and panels lift off), assembly (0..1: the
## build stages appear in order), highlight (a member class, fitting kind,
## canopy piece or "panel"), record (keep pick data on the node),
## ghost_highlight (the placement ghost's tint), pieces (one MeshInstance3D
## per part a crew carries — a tube, a fitting, a line, a solar panel, and a
## canopy panel: one bay's origami fold, both halves' six triangles with its
## flange and bolts — tagged for StructureUnits instead of the one "Mesh").

const MODEL_ID := "toroidlab_structure"
const DROP_M := 0.6
const HIGHLIGHT := Color(1.0, 0.72, 0.25)
const TUBE_SIDES := 10
const SLEEVE_LEN_M := 0.06
const PANEL_T_M := 0.004
const N_STAGES := 7


static func build_node(spec: Dictionary = {}, node_name: String = "ToroidStructure", opts: Dictionary = {}) -> Node3D:
	return build_from_design(ToroidLabDesign.solve(spec), node_name, opts)


static func build_from_design(d: Dictionary, node_name: String = "ToroidStructure", opts: Dictionary = {}) -> Node3D:
	var root := Node3D.new()
	root.name = node_name
	var s: Dictionary = d["spec"]
	root.set_meta("toroid_spec", ToroidLabSpec.to_json_safe(s))
	var explode := clampf(float(opts.get("explode", 0.0)), 0.0, 1.0)
	var assembly := clampf(float(opts.get("assembly", 1.0)), 0.0, 1.0)
	var highlight := str(opts.get("highlight", ""))
	var record := bool(opts.get("record", false))
	var ghost := bool(opts.get("ghost_highlight", false))
	var pieces := bool(opts.get("pieces", false))
	var fr: Dictionary = d["frame"]
	var tube := ToroidLabMaterials.tube(str(s["tube"]["material"]))
	var od := float(tube["od_mm"]) * 0.001
	var accs := {}
	var picks: Array = []
	# Pieces mode: the part being drawn collects in pc and flush makes it its
	# own node (`order` = the build stage it goes up in).
	var pc := {"accs": {}}
	var piece_nodes: Array = []
	var flush := func(kind: String, words: Array, order: int, packed: ArrayMesh = null) -> void:
		if not pieces:
			return
		var pm := _commit(pc["accs"], d, ghost)
		pc["accs"] = {}
		if pm.get_surface_count() > 0:
			var pmi := MeshInstance3D.new()
			pmi.mesh = pm
			StructureUnits.tag_piece(pmi, kind, words, order, packed)
			piece_nodes.append(pmi)
	var shown := func(stage: int) -> float:
		return assembly * float(N_STAGES) - float(stage) + 0.001
	var lift := func(k: float) -> Vector3:
		return Vector3(0, DROP_M * (1.0 - clampf(k, 0.0, 1.0)), 0)
	# --- tubes and lines -----------------------------------------------------
	for m in fr["members"]:
		var k: float = shown.call(int(m["stage"]))
		if k <= 0.0:
			continue
		var off: Vector3 = lift.call(k)
		var cls := str(m.get("cls", ""))
		var kind := str(m["kind"])
		var cable := kind == "cable"
		var key := "hl" if cls == highlight else ("cable" if cable else "tube")
		var rad := od * 0.5
		if cable:
			rad = maxf(float(ToroidLabMaterials.cable(str(m["cable"]))["d_mm"]) * 0.0005, 0.003)
		var pts := PackedVector3Array()
		for p in (m["pts"] as PackedVector3Array):
			pts.append(p + off)
		_sweep(_acc(pc["accs"] if pieces else accs, key), pts, rad, 6 if cable else TUBE_SIDES)
		if record:
			for i in pts.size() - 1:
				picks.append({"kind": "cable" if cable else "tube", "id": cls, "a": pts[i], "b": pts[i + 1],
					"r": maxf(rad * 2.5, 0.03), "member": int(m["id"])})
		flush.call("", ["a line", "lines"] if cable else ["a tube", "tubes"], int(m["stage"]))
	# --- fittings --------------------------------------------------------------
	for f in fr["fittings"]:
		var k: float = shown.call(int(f["stage"]))
		if k <= 0.0:
			continue
		var off: Vector3 = lift.call(k)
		var typ := str(f["type"])
		var key := "hl" if typ == highlight else "fitting"
		var p: Vector3 = (f["p"] as Vector3) + off
		var acc := _acc(pc["accs"] if pieces else accs, key)
		var sr := od * 0.66
		var dirs: Array = f["dirs"]
		if typ == "crossover":
			# Two sleeves one tube diameter apart, joined by the clamp body.
			var a0: Vector3 = dirs[0]
			var t0: Vector3 = dirs[2]
			var nrm := a0.cross(t0).normalized()
			var c_rib := p + nrm * od * 0.5
			var c_ring := p - nrm * od * 0.5
			if (c_rib - Vector3(0, p.y, 0)).length() < (c_ring - Vector3(0, p.y, 0)).length():
				var tmp := c_rib
				c_rib = c_ring
				c_ring = tmp
			_sweep(acc, PackedVector3Array([c_rib - a0 * SLEEVE_LEN_M, c_rib + a0 * SLEEVE_LEN_M]), sr, 8)
			_sweep(acc, PackedVector3Array([c_ring - t0 * SLEEVE_LEN_M, c_ring + t0 * SLEEVE_LEN_M]), sr, 8)
			_sweep(acc, PackedVector3Array([c_rib, c_ring]), sr * 0.9, 6)
		elif typ == "eye":
			var dv: Vector3 = dirs[0]
			_sweep(acc, PackedVector3Array([p - dv * 0.01, p + dv * 0.035]), od * 0.35, 6)
		else:
			var long := SLEEVE_LEN_M if typ != "foot" else 0.03
			for dv in dirs:
				_sweep(acc, PackedVector3Array([p, p + (dv as Vector3) * long]), sr, 8)
			if typ == "foot":
				_sweep(acc, PackedVector3Array([p - Vector3(0, 0.02, 0), p - Vector3(0, 0.026, 0)]), od * 2.2, 8)
			elif dirs.size() >= 3:
				_box(acc, p, sr * 1.15)
		if record:
			picks.append({"kind": "fitting", "id": typ, "c": p, "r": maxf(sr * 1.6, 0.05)})
		flush.call("", ["a fitting", "fittings"], int(f["stage"]))
	# --- canopy ------------------------------------------------------------------
	var cn: Dictionary = d["canopy"]
	var k_cn: float = shown.call(5)
	if k_cn > 0.0 and not (cn.get("sectors", []) as Array).is_empty():
		var mat: Dictionary = cn["material"]
		var th := maxf(float(mat["t_mm"]) * 0.001, 0.003)
		var cs: Dictionary = s["canopy"]
		var bolt := DomeLabMaterials.bolt(str(cs["bolt"]))
		var bd := float(bolt["d_mm"]) * 0.001
		# Packed, a fold is the flat cut pieces it is scored from (the
		# corrugated plastic folds along its score lines): the same for
		# every bay.
		var canopy_flat: ArrayMesh = _packed_canopy(cn, th, d, ghost) if pieces else null
		for sec in cn["sectors"]:
			for h in sec["halves"]:
				var pid := "SL" if int(h["side"]) == 0 else "SR"
				var key := "hl" if pid == highlight else "canopy"
				var nrm: Vector3 = h["normal"]
				var off: Vector3 = nrm * (0.6 * explode) + lift.call(k_cn)
				var acc := _acc(pc["accs"] if pieces else accs, key)
				var tris_out := PackedVector3Array()
				for tri in h["tris"]:
					var a: Vector3 = (tri[0] as Vector3) + off
					var b: Vector3 = (tri[1] as Vector3) + off
					var c: Vector3 = (tri[2] as Vector3) + off
					var tn := (b - a).cross(c - a).normalized()
					if tn.dot(nrm) < 0.0:
						tn = -tn
					_slab_tri(acc, a, b, c, tn, th)
					tris_out.append_array(PackedVector3Array([a, b, c]))
				var fl: Array = h["flange"]
				if float(cs["flange_mm"]) > 0.0:
					var q0: Vector3 = (fl[0] as Vector3) + off
					var q1: Vector3 = (fl[1] as Vector3) + off
					var q2: Vector3 = (fl[2] as Vector3) + off
					var q3: Vector3 = (fl[3] as Vector3) + off
					var fn := (q1 - q0).cross(q3 - q0).normalized()
					_slab_tri(acc, q0, q1, q2, fn, th)
					_slab_tri(acc, q0, q2, q3, fn, th)
				if explode < 0.01 and int(h["side"]) == 0:
					var hacc := _acc(pc["accs"] if pieces else accs, "bolt")
					for bt in h["bolts"]:
						var c: Vector3 = (bt["p"] as Vector3) + off
						var ax: Vector3 = bt["axis"]
						var side := ax.cross(Vector3.UP if absf(ax.y) < 0.9 else Vector3.RIGHT).normalized()
						var reach := th * 1.05
						DomeLabBuilder._hex(hacc, c + ax * reach, c + ax * (reach + bd * 0.65), side, bd * 1.8)
						DomeLabBuilder._hex(hacc, c - ax * reach, c - ax * (reach + bd * 0.85), side, bd * 1.7)
						DomeLabBuilder._hex(hacc, c - ax * (reach + bd * 0.85), c - ax * (reach + bd * 1.3), side, bd * 0.95)
				if record:
					picks.append({"kind": "canopy", "id": pid, "tris": tris_out, "label": "%s · bay %d" % [pid, int(sec["bay"]) + 1]})
			# One bay's fold is one canopy panel: it goes up and comes down
			# folded, not triangle by triangle.
			flush.call("sheets", ["a canopy panel", "canopy panels"], 5, canopy_flat)
	# --- panels --------------------------------------------------------------------
	var so: Dictionary = d["solar"]
	var k_pv: float = shown.call(6)
	if k_pv > 0.0:
		for pnl in so["panels"]:
			var off: Vector3 = (pnl["normal"] as Vector3) * (0.8 * explode) + lift.call(k_pv)
			var key := "hl" if highlight == "panel" else "panel"
			var acc := _acc(pc["accs"] if pieces else accs, key)
			var back := _acc(pc["accs"] if pieces else accs, "panel_back")
			var rows: Array = pnl["rows"]
			var tris_out := PackedVector3Array()
			for i in rows.size() - 1:
				var a0: Vector3 = (rows[i][0] as Vector3) + off
				var a1: Vector3 = (rows[i][1] as Vector3) + off
				var b0: Vector3 = (rows[i + 1][0] as Vector3) + off
				var b1: Vector3 = (rows[i + 1][1] as Vector3) + off
				var n := (b0 - a0).cross(a1 - a0).normalized()
				if n.dot(pnl["normal"]) < 0.0:
					n = -n
				var up := n * PANEL_T_M * 0.5
				DomeLabBuilder._atri(acc, a0 + up, a1 + up, b1 + up, n, n, n)
				DomeLabBuilder._atri(acc, a0 + up, b1 + up, b0 + up, n, n, n)
				DomeLabBuilder._atri(back, a0 - up, b1 - up, a1 - up, -n, -n, -n)
				DomeLabBuilder._atri(back, a0 - up, b0 - up, b1 - up, -n, -n, -n)
				tris_out.append_array(PackedVector3Array([a0 + up, a1 + up, b1 + up, a0 + up, b1 + up, b0 + up]))
			if record:
				picks.append({"kind": "panel", "id": "panel", "tris": tris_out, "label": "panel · bay %d" % (int(pnl["bay"]) + 1)})
			flush.call("sheets", ["a solar panel", "solar panels"], 6,
				_packed_panel(rows, d, ghost) if pieces else null)
	# --- commit ----------------------------------------------------------------------
	if pieces:
		for i in piece_nodes.size():
			var pn_i: MeshInstance3D = piece_nodes[i]
			pn_i.name = "P%d" % i
			root.add_child(pn_i)
	else:
		var mi := MeshInstance3D.new()
		mi.name = "Mesh"
		mi.mesh = _commit(accs, d, ghost)
		root.add_child(mi)
	if record:
		root.set_meta("picks", picks)
	var st: Dictionary = d["stats"]
	var dia := float(st["radius_max_m"]) * 2.0
	root.set_meta("size_m", Vector3(dia, float(st["height_m"]) + 0.05, dia))
	return root


# ---------------------------------------------------------------------------
# Emitters (Godot's front face winds clockwise; DomeLabBuilder._atri flips a
# triangle whose geometric normal disagrees with the one it is given)
# ---------------------------------------------------------------------------

## A canopy fold packed flat: its two cut pieces (ToroidLabCanopy's unfold,
## flange included) stacked one on the other, each centred, in the packed
## frame StructureUnits expects (x across, y up through the stack, z along;
## metres).
static func _packed_canopy(cn: Dictionary, th: float, d: Dictionary, ghost: bool) -> ArrayMesh:
	var accs := {}
	var acc := _acc(accs, "canopy")
	var flat: Array = cn.get("pieces", [])
	for i in flat.size():
		var poly: PackedVector2Array = flat[i]["poly"]
		var bb: Rect2 = flat[i].get("bbox", FlatpackProfile.bbox(poly))
		var c := bb.get_center()
		var pm := PackedVector2Array()
		for q in poly:
			pm.append((q - c) * 0.001)
		_flat_slab(acc, acc, pm, float(i) * th, th)
	return _commit(accs, d, ghost)


## A flexible solar panel packed flat: its width across, its length the
## length of the curve it is bent to.
static func _packed_panel(rows: Array, d: Dictionary, ghost: bool) -> ArrayMesh:
	if rows.size() < 2:
		return null
	var w := (rows[0][0] as Vector3).distance_to(rows[0][1])
	var l := 0.0
	for i in rows.size() - 1:
		l += ((rows[i + 1][0] as Vector3).distance_to(rows[i][0]) + (rows[i + 1][1] as Vector3).distance_to(rows[i][1])) * 0.5
	var accs := {}
	var poly := PackedVector2Array([Vector2(-w * 0.5, -l * 0.5), Vector2(w * 0.5, -l * 0.5),
		Vector2(w * 0.5, l * 0.5), Vector2(-w * 0.5, l * 0.5)])
	_flat_slab(_acc(accs, "panel"), _acc(accs, "panel_back"), poly, 0.0, PANEL_T_M)
	return _commit(accs, d, ghost)


## A flat polygon (x, z) as a slab from y0 to y0 + t: the top face into
## `top`, the underside and the edges into `rest`.
static func _flat_slab(top: Dictionary, rest: Dictionary, poly: PackedVector2Array, y0: float, t: float) -> void:
	var m := poly.size()
	if m < 3:
		return
	var idx := Geometry2D.triangulate_polygon(poly)
	var p3 := func(q: Vector2, y: float) -> Vector3:
		return Vector3(q.x, y, q.y)
	for k in idx.size() / 3:
		var a := poly[idx[k * 3]]
		var b := poly[idx[k * 3 + 1]]
		var c := poly[idx[k * 3 + 2]]
		DomeLabBuilder._atri(top, p3.call(a, y0 + t), p3.call(b, y0 + t), p3.call(c, y0 + t), Vector3.UP, Vector3.UP, Vector3.UP)
		DomeLabBuilder._atri(rest, p3.call(a, y0), p3.call(b, y0), p3.call(c, y0), Vector3.DOWN, Vector3.DOWN, Vector3.DOWN)
	# Edges: the outward normal of each side in the plane.
	var area := 0.0
	for i in m:
		var q := poly[(i + 1) % m]
		area += poly[i].x * q.y - q.x * poly[i].y
	for i in m:
		var a := poly[i]
		var b := poly[(i + 1) % m]
		var e := b - a
		if e.length() < 1e-6:
			continue
		var o := Vector2(e.y, -e.x).normalized() if area > 0.0 else Vector2(-e.y, e.x).normalized()
		var nn := Vector3(o.x, 0.0, o.y)
		DomeLabBuilder._atri(rest, p3.call(a, y0), p3.call(b, y0), p3.call(b, y0 + t), nn, nn, nn)
		DomeLabBuilder._atri(rest, p3.call(a, y0), p3.call(b, y0 + t), p3.call(a, y0 + t), nn, nn, nn)


## The accumulators of one build as a mesh, a surface per material.
static func _commit(accs: Dictionary, d: Dictionary, ghost: bool) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	for key in ["tube", "fitting", "cable", "canopy", "bolt", "panel", "panel_back", "hl"]:
		if not accs.has(key):
			continue
		var a: Dictionary = accs[key]
		if (a["v"] as PackedVector3Array).is_empty():
			continue
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = a["v"]
		arr[Mesh.ARRAY_NORMAL] = a["n"]
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		mesh.surface_set_material(mesh.get_surface_count() - 1, _material_for(key, d, ghost))
	return mesh


static func _acc(accs: Dictionary, key: String) -> Dictionary:
	if not accs.has(key):
		accs[key] = {"v": PackedVector3Array(), "n": PackedVector3Array()}
	return accs[key]


## A round tube swept along a polyline with parallel-transported rings, so a
## bent arc reads as one smooth tube; flat end caps.
static func _sweep(acc: Dictionary, pts: PackedVector3Array, radius: float, sides: int) -> void:
	var n := pts.size()
	if n < 2:
		return
	var tans: Array = []
	for i in n:
		var t := Vector3.ZERO
		if i > 0:
			t += (pts[i] - pts[i - 1]).normalized()
		if i < n - 1:
			t += (pts[i + 1] - pts[i]).normalized()
		if t.length() < 1e-9:
			t = (pts[mini(i + 1, n - 1)] - pts[maxi(i - 1, 0)]).normalized()
		tans.append(t.normalized())
	var t0: Vector3 = tans[0]
	var u := t0.cross(Vector3.UP)
	if u.length() < 1e-4:
		u = t0.cross(Vector3.RIGHT)
	u = u.normalized()
	var rings: Array = []
	for i in n:
		var t: Vector3 = tans[i]
		u = (u - t * u.dot(t))
		if u.length() < 1e-6:
			u = t.cross(Vector3.UP if absf(t.y) < 0.9 else Vector3.RIGHT)
		u = u.normalized()
		var v := t.cross(u).normalized()
		var ring: Array = []
		for j in sides:
			var ang := TAU * j / sides
			ring.append(u * cos(ang) + v * sin(ang))
		rings.append(ring)
	for i in n - 1:
		var r0: Array = rings[i]
		var r1: Array = rings[i + 1]
		for j in sides:
			var j1 := (j + 1) % sides
			var n00: Vector3 = r0[j]
			var n01: Vector3 = r0[j1]
			var n10: Vector3 = r1[j]
			var n11: Vector3 = r1[j1]
			DomeLabBuilder._atri(acc, pts[i] + n00 * radius, pts[i + 1] + n10 * radius, pts[i + 1] + n11 * radius, n00, n10, n11)
			DomeLabBuilder._atri(acc, pts[i] + n00 * radius, pts[i + 1] + n11 * radius, pts[i] + n01 * radius, n00, n11, n01)
	var ta: Vector3 = -(tans[0] as Vector3)
	var tb: Vector3 = tans[n - 1]
	var ra: Array = rings[0]
	var rb: Array = rings[n - 1]
	for j in range(1, sides - 1):
		DomeLabBuilder._atri(acc, pts[0] + (ra[0] as Vector3) * radius, pts[0] + (ra[j] as Vector3) * radius,
			pts[0] + (ra[j + 1] as Vector3) * radius, ta, ta, ta)
		DomeLabBuilder._atri(acc, pts[n - 1] + (rb[0] as Vector3) * radius, pts[n - 1] + (rb[j] as Vector3) * radius,
			pts[n - 1] + (rb[j + 1] as Vector3) * radius, tb, tb, tb)


## A cube of half-size h (a fitting's body).
static func _box(acc: Dictionary, c: Vector3, h: float) -> void:
	var axes := [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
	for ax in axes:
		for sgn in [-1.0, 1.0]:
			var n: Vector3 = ax * sgn
			var u: Vector3 = axes[(axes.find(ax) + 1) % 3]
			var v: Vector3 = axes[(axes.find(ax) + 2) % 3]
			var f := c + n * h
			var p0 := f - u * h - v * h
			var p1 := f + u * h - v * h
			var p2 := f + u * h + v * h
			var p3 := f - u * h + v * h
			DomeLabBuilder._atri(acc, p0, p1, p2, n, n, n)
			DomeLabBuilder._atri(acc, p0, p2, p3, n, n, n)


## A triangle of sheet: both faces, thickness t along n (the edges are thin
## enough not to need walls).
static func _slab_tri(acc: Dictionary, a: Vector3, b: Vector3, c: Vector3, n: Vector3, t: float) -> void:
	var h := n * t * 0.5
	DomeLabBuilder._atri(acc, a + h, b + h, c + h, n, n, n)
	DomeLabBuilder._atri(acc, a - h, c - h, b - h, -n, -n, -n)


static func _part_color(cols: Dictionary, key: String, own: Variant) -> Color:
	var col: Color = cols[key]
	if col.is_equal_approx(ToroidLabSpec.COLOR_DEFAULTS[key]) and own is Color:
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
		"tube":
			var tube := ToroidLabMaterials.tube(str(s["tube"]["material"]))
			m = StructureMaterials.make(DomeLabBuilder.kind_for_look(str(tube["look"])), _part_color(cols, "tube", tube["color"]))
		"fitting":
			m = StructureMaterials.make(StructureMaterials.Kind.ALUMINIUM, cols["connector"])
		"bolt":
			m = StructureMaterials.make(StructureMaterials.Kind.HARDWARE_METAL, Color(0.6, 0.62, 0.64))
		"cable":
			m = StructureMaterials.make(StructureMaterials.Kind.HARDWARE_METAL, cols["cable"])
		"canopy":
			var sh := ToroidLabMaterials.sheet(str(s["canopy"]["sheet"]))
			m = StructureMaterials.make(StructureMaterials.Kind.PLASTIC, _part_color(cols, "canopy", sh["color"]))
		"panel":
			m = StructureMaterials.make(StructureMaterials.Kind.PANEL, cols["panel"])
		"panel_back":
			m = StructureMaterials.make(StructureMaterials.Kind.PLASTIC, Color(0.82, 0.83, 0.85))
		_:
			m = StandardMaterial3D.new()
	if key != "hl" and key != "canopy":
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
		if kind == "canopy" or kind == "panel":
			var tris: PackedVector3Array = p["tris"]
			for i in range(0, tris.size() - 2, 3):
				var hit: Variant = Geometry3D.ray_intersects_triangle(origin, dir, tris[i], tris[i + 1], tris[i + 2])
				if hit == null:
					hit = Geometry3D.ray_intersects_triangle(origin, dir, tris[i], tris[i + 2], tris[i + 1])
				if hit != null:
					t = minf(t, origin.distance_to(hit as Vector3))
		elif kind == "fitting":
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
				"member": int(p.get("member", -1))}
	return best


## The graph handoff numbers for a placed toroid (local frame).
static func panel_summary(spec: Dictionary) -> Dictionary:
	return (ToroidLabDesign.solve(spec)["solar"] as Dictionary)["summary"]
