extends SceneTree

## Folded-plate seam probe: for every two-face edge of a preset, the two
## flanges' outer-skin planes (angle, separation) and the convexity.
##   Godot --headless --path . --script tools/diag/domelab_seam_probe.gd -- --preset=helical_corten

func _initialize() -> void:
	var pid := "helical_corten"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--preset="):
			pid = a.substr(9)
	var spec: Dictionary = {}
	if pid.begins_with("lib:"):
		for des in DomeLabPresets.load_library():
			if str(des.get("id", "")) == pid.substr(4) or str(des.get("name", "")) == pid.substr(4):
				spec = DomeLabSpec.resolve(des["spec"])
	else:
		spec = DomeLabPresets.builtin(pid)["spec"]
	var d := DomeLabDesign.solve(spec)
	var geo: Dictionary = d["geo"]
	var verts: PackedVector3Array = geo["verts"]
	var faces: Array = geo["faces"]
	var pn: Dictionary = d["panels"]
	var fidx := DomeLabConnectors.face_index(geo)
	var concave := 0
	var nonplanar := 0.0
	var outward_bad := 0
	var ctr := Vector3.ZERO
	for v in verts:
		ctr += v
	ctr /= verts.size()
	for fi in faces.size():
		var f: PackedInt32Array = faces[fi]
		var n: Vector3 = fidx["normals"][fi]
		var c := Vector3.ZERO
		for id in f:
			c += verts[id]
		c /= f.size()
		for id in f:
			nonplanar = maxf(nonplanar, absf((verts[id] - c).dot(n)))
	for e in d["edges"]:
		var fl: Array = e["faces"]
		if fl.size() < 2:
			continue
		var n1: Vector3 = fidx["normals"][int(fl[0])]
		var n2: Vector3 = fidx["normals"][int(fl[1])]
		var c2 := Vector3.ZERO
		var f2: PackedInt32Array = faces[int(fl[1])]
		for id in f2:
			c2 += verts[id]
		c2 /= f2.size()
		var mid: Vector3 = e["mid"]
		if (c2 - mid).dot(n1) > 1e-6:
			concave += 1
	print("preset %s: faces %d, edges %d, nonplanar max %.4f m, concave edges %d" % [pid, faces.size(), (d["edges"] as Array).size(), nonplanar, concave])
	print("bend range: ", _bends(d["edges"]))
	print("panels %d, bolts3d %d" % [(pn["panels"] as Array).size(), (pn["bolts3d"] as Array).size()])
	_seams(d)
	_corners(d)
	_spikes(d)
	quit()


## Each panel's flange outer-skin plane per edge, in world: as the builder
## draws it (panel frame, face_poly, edge_ang, flange_section).
static func skin_planes(d: Dictionary) -> Dictionary:
	var geo: Dictionary = d["geo"]
	var verts: PackedVector3Array = geo["verts"]
	var pn: Dictionary = d["panels"]
	var gap := float(pn["gap_mm"])
	var out := {}
	for p in pn["panels"]:
		var fr: Transform3D = p["frame"]
		var fp: PackedVector2Array = p["face_poly"]
		var angs: Array = p["edge_ang"]
		var f: PackedInt32Array = geo["faces"][int(p["face"])]
		var m := fp.size()
		for k in m:
			var a := fp[k]
			var b := fp[(k + 1) % m]
			var wa := fr * Vector3(a.x, a.y, 0.0)
			var wb := fr * Vector3(b.x, b.y, 0.0)
			var ia := _nearest(verts, wa)
			var ib := _nearest(verts, wb)
			var sc := DomeLabPanels.flange_section(float(angs[k]), float(pn["t_mm"]), float(pn["fold_r_mm"]), gap, float(pn["flange_mm"]))
			var e := (b - a).normalized()
			var fin := Vector2(-e.y, e.x)
			var a2 := float(sc["a2"])
			var M := Vector3(fin.x * cos(a2), fin.y * cos(a2), sin(a2))
			var P := Vector3(a.x, a.y, 0.0) + M * (gap * 0.5 / maxf(M.length(), 1e-9))
			var key := DomeLabGeodesic._ekey(ia, ib)
			if not out.has(key):
				out[key] = []
			(out[key] as Array).append({"n": (fr.basis * M).normalized(), "p": fr * P, "face": int(p["face"])})
	return out


static func _nearest(verts: PackedVector3Array, q: Vector3) -> int:
	var best := -1
	var bd := INF
	for i in verts.size():
		var dd := verts[i].distance_squared_to(q)
		if dd < bd:
			bd = dd
			best = i
	return best


func _seams(d: Dictionary) -> void:
	var gap := float(d["panels"]["gap_mm"])
	var sp := skin_planes(d)
	var worst_ang := 0.0
	var worst_sep := 0.0
	var bad := 0
	for key in sp:
		var arr: Array = sp[key]
		if arr.size() < 2:
			continue
		var n1: Vector3 = arr[0]["n"]
		var n2: Vector3 = arr[1]["n"]
		var ang := rad_to_deg(n1.angle_to(-n2))
		var sep := ((arr[0]["p"] as Vector3) - (arr[1]["p"] as Vector3)).dot(n1) * 1000.0
		worst_ang = maxf(worst_ang, ang)
		worst_sep = maxf(worst_sep, absf(sep - gap))
		if ang > 0.5 or absf(sep - gap) > 0.5:
			bad += 1
	print("seams: worst angle %.3f deg, worst |sep - gap| %.3f mm, bad %d of %d" % [worst_ang, worst_sep, bad, sp.size()])


func _bends(edges: Array) -> String:
	var lo := INF
	var hi := -INF
	for e in edges:
		if (e["faces"] as Array).size() >= 2:
			lo = minf(lo, rad_to_deg(float(e["flange_bend"])))
			hi = maxf(hi, rad_to_deg(float(e["flange_bend"])))
	return "%.2f .. %.2f deg" % [lo, hi]


## Under each vertex every seam's flange pair lies on the edge's bisector
## plane; plate A's two flanges meet along S_e ∩ S_e'. Where two plates
## share edge e their two mitre lines in S_e differ unless the vertex is
## trihedral: the angle between them is the wedge one flange sticks past
## the other.
func _corners(d: Dictionary) -> void:
	var geo: Dictionary = d["geo"]
	var verts: PackedVector3Array = geo["verts"]
	var faces: Array = geo["faces"]
	var fidx := DomeLabConnectors.face_index(geo)
	var edges: Array = d["edges"]
	var by_key := {}
	for ei in edges.size():
		by_key[DomeLabGeodesic._ekey(int(edges[ei]["a"]), int(edges[ei]["b"]))] = ei
	# bisector plane normal per edge (unit, from face 0's side)
	var sn := {}
	for ei in edges.size():
		var e: Dictionary = edges[ei]
		var fl: Array = e["faces"]
		if fl.size() < 2:
			continue
		var n0: Vector3 = fidx["normals"][int(fl[0])]
		var ed: Vector3 = e["dir"]
		var f0: PackedInt32Array = faces[int(fl[0])]
		var cen := Vector3.ZERO
		for id in f0:
			cen += verts[id]
		cen /= f0.size()
		var fin := n0.cross(ed).normalized()
		if fin.dot(cen - (e["mid"] as Vector3)) < 0.0:
			fin = -fin
		var a2 := float(e["flange_bend"])
		sn[ei] = fin * cos(a2) + n0 * sin(a2)
	var valence := {}
	var worst := {}
	for fi in faces.size():
		var f: PackedInt32Array = faces[fi]
		var m := f.size()
		for k in m:
			var v := int(f[k])
			valence[v] = int(valence.get(v, 0)) + 1
			var e1 := int(by_key.get(DomeLabGeodesic._ekey(f[k], f[(k + 1) % m]), -1))
			var e0 := int(by_key.get(DomeLabGeodesic._ekey(f[(k - 1 + m) % m], f[k]), -1))
			if not sn.has(e1) or not sn.has(e0):
				continue
			var L := (sn[e0] as Vector3).cross(sn[e1]).normalized()
			if L.dot(fidx["normals"][fi]) > 0.0:
				L = -L
			for ei in [e0, e1]:
				var key := "%d|%d" % [v, ei]
				if not worst.has(key):
					worst[key] = []
				(worst[key] as Array).append(L)
	var by_val := {}
	for key in worst:
		var arr: Array = worst[key]
		if arr.size() < 2:
			continue
		var v := int(str(key).split("|")[0])
		var ang := rad_to_deg((arr[0] as Vector3).angle_to(arr[1]))
		var val := int(valence[v])
		by_val[val] = maxf(float(by_val.get(val, 0.0)), ang)
	print("corner wedge (angle between the two plates' mitre lines on a seam) by valence: ", by_val)


## Flanges whose drawn ends reach past their own vertices (spikes), with
## the same cut rules as the builder.
func _spikes(d: Dictionary) -> void:
	var geo: Dictionary = d["geo"]
	var verts: PackedVector3Array = geo["verts"]
	var faces: Array = geo["faces"]
	var fidx := DomeLabConnectors.face_index(geo)
	var fn: PackedVector3Array = fidx["normals"]
	var pn: Dictionary = d["panels"]
	var cuts: Dictionary = pn["node_cuts"]
	var gap := float(pn["gap_mm"])
	var n_sp := 0
	var worst := 0.0
	for fi in faces.size():
		var f: PackedInt32Array = faces[fi]
		var m := f.size()
		var frs: Array = []
		for k in m:
			var e: Dictionary = {}
			for ed in d["edges"]:
				if DomeLabGeodesic._ekey(int(ed["a"]), int(ed["b"])) == DomeLabGeodesic._ekey(f[k], f[(k + 1) % m]):
					e = ed
			var ang := float(e["flange_bend"]) * 2.0 if (e["faces"] as Array).size() >= 2 else 0.0
			var ff := DomeLabPanels._flange_frame(verts, f, fn[fi], f[k], f[(k + 1) % m], ang, gap)
			ff["sec"] = DomeLabPanels.flange_section(ang, float(pn["t_mm"]), float(pn["fold_r_mm"]), gap, float(pn["flange_mm"]))
			frs.append(ff)
		for k in m:
			var ff: Dictionary = frs[k]
			var prv: Dictionary = frs[(k - 1 + m) % m]
			var nxt: Dictionary = frs[(k + 1) % m]
			var c0: Array = cuts.get(DomeLabPanels._cut_key(fi, f[k], f[k], f[(k + 1) % m]), [])
			var c1: Array = cuts.get(DomeLabPanels._cut_key(fi, f[(k + 1) % m], f[k], f[(k + 1) % m]), [])
			var over := 0.0
			for q in (ff["sec"]["profile"] as PackedVector2Array):
				var P0 := DomeLabPanels._section_point(ff, q)
				var s0 := DomeLabPanels._cut_s(c0, P0, ff["E"]) if not c0.is_empty() else DomeLabPanels._mitre_s(ff, prv, P0, true, q.length())
				var s1 := DomeLabPanels._cut_s(c1, P0, ff["E"]) if not c1.is_empty() else DomeLabPanels._mitre_s(ff, nxt, P0, false, q.length())
				over = maxf(over, maxf(-s0, s1 - float(ff["L"])))
			if over > 1.5 * q_max(ff) + 1.0:
				n_sp += 1
				worst = maxf(worst, over)
				if n_sp <= 6:
					print("  spike face %d edge %d-%d bend %.1f prev %.1f next %.1f over %.0f mm cut0 %s cut1 %s" % [fi, f[k], f[(k + 1) % m],
						rad_to_deg(float(ff["ang"])) * 0.5, rad_to_deg(float(prv["ang"])) * 0.5, rad_to_deg(float(nxt["ang"])) * 0.5, over, not c0.is_empty(), not c1.is_empty()])
	print("spikes: %d flanges reach past the mitre cap, worst %.0f mm" % [n_sp, worst])


static func q_max(ff: Dictionary) -> float:
	var mx := 0.0
	for q in (ff["sec"]["profile"] as PackedVector2Array):
		mx = maxf(mx, q.length())
	return mx
