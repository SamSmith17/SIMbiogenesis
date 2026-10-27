class_name DomeLabConnectors
extends RefCounted

## What happens where struts meet: the angles every connector system is cut
## and bent to, read off the geometry alone. Pure static.
##
## At a vertex with surface normal N (the hub axis), an edge leaving along the
## unit vector d DIPS below the tangent plane by
##   dip = asin(−d · N)
## — on a sphere that is half the edge's central angle, the angle a conduit
## dome's flattened end is bent through so the flat lies on the bolt. The
## edge's AZIMUTH round the hub is measured in the tangent plane from a fixed
## reference (north, else east at the poles), counter-clockwise seen from
## outside; the sorted azimuths are the hub's arm pattern.
##
## Two faces meeting along an edge make the DIHEDRAL; a plate's flange is
## folded through half of (180° − dihedral) so two flanges meet face to face:
##   flange_bend = ±angle(n1, n2) / 2   (negative in a valley).
##
## A flat bar bent along the surface between two hubs follows (near enough) a
## circular arc whose end tangents leave the chord by the two dips, so
##   arc = chord · δ / sin δ,   bend radius = chord / (2 sin δ),   δ = mean dip.

const LETTERS := "ABCDEFGHIJKLMNOPQRSTUVWXYZ"


## Per-vertex frames: {normal, t1, t2} with t1 the azimuth reference.
static func vertex_frames(geo: Dictionary) -> Array:
	var verts: PackedVector3Array = geo["verts"]
	var normals: PackedVector3Array = geo["normals"]
	var out: Array = []
	for i in verts.size():
		var n: Vector3 = normals[i].normalized()
		var ref := Vector3(0, 0, 1)
		if absf(n.dot(ref)) > 0.95:
			ref = Vector3(1, 0, 0)
		var t1 := (ref - n * ref.dot(n)).normalized()
		var t2 := n.cross(t1)
		out.append({"normal": n, "t1": t1, "t2": t2})
	return out


## Faces by edge key → [face index, ...] and face normals.
static func face_index(geo: Dictionary) -> Dictionary:
	var verts: PackedVector3Array = geo["verts"]
	var faces: Array = geo["faces"]
	var by_edge := {}
	var fnormals: PackedVector3Array = PackedVector3Array()
	for fi in faces.size():
		var f: PackedInt32Array = faces[fi]
		var n := (verts[f[1]] - verts[f[0]]).cross(verts[f[2]] - verts[f[0]])
		fnormals.append(n.normalized() if n.length() > 1e-12 else Vector3.UP)
		for k in f.size():
			var key := DomeLabGeodesic._ekey(f[k], f[(k + 1) % f.size()])
			if not by_edge.has(key):
				by_edge[key] = []
			(by_edge[key] as Array).append(fi)
	return {"by_edge": by_edge, "normals": fnormals}


## Every edge with its length, dips, azimuths and dihedral:
## {a, b, len, dir, mid, dip_a, dip_b, az_a, az_b, dihedral (radians, PI
## for a boundary edge; over PI in a valley), flange_bend (SIGNED: negative
## in a valley, where the second face rises above the first's plane),
## faces: [fi...], tag}.
static func edge_records(geo: Dictionary, frames: Array, fidx: Dictionary) -> Array:
	var verts: PackedVector3Array = geo["verts"]
	var tags: Dictionary = geo.get("edge_tags", {})
	var out: Array = []
	for e in geo["edges"]:
		var a := int(e[0])
		var b := int(e[1])
		var pa := verts[a]
		var pb := verts[b]
		var L := pa.distance_to(pb)
		var d := (pb - pa) / maxf(L, 1e-9)
		var fa: Dictionary = frames[a]
		var fb: Dictionary = frames[b]
		var na: Vector3 = fa["normal"]
		var nb: Vector3 = fb["normal"]
		var dip_a := asin(clampf(-d.dot(na), -1.0, 1.0))
		var dip_b := asin(clampf(d.dot(nb), -1.0, 1.0))
		var key := DomeLabGeodesic._ekey(a, b)
		var fl: Array = (fidx["by_edge"] as Dictionary).get(key, [])
		var dihedral := PI
		var bend := 0.0
		if fl.size() >= 2:
			var n1: Vector3 = (fidx["normals"] as PackedVector3Array)[int(fl[0])]
			var n2: Vector3 = (fidx["normals"] as PackedVector3Array)[int(fl[1])]
			var ang := acos(clampf(n1.dot(n2), -1.0, 1.0))
			# A VALLEY: the second face rises above the first one's plane
			# (a helical zome's cells meet in valleys). Its flanges fold less
			# than square, so the angle carries the sign.
			if _valley(verts, geo["faces"][int(fl[1])], (pa + pb) * 0.5, n1):
				ang = -ang
			dihedral = PI - ang
			bend = ang * 0.5
		out.append({"a": a, "b": b, "len": L, "dir": d, "mid": (pa + pb) * 0.5,
			"dip_a": dip_a, "dip_b": dip_b, "az_a": azimuth(fa, d), "az_b": azimuth(fb, -d),
			"dihedral": dihedral, "flange_bend": bend, "faces": fl,
			"tag": tags.get(key, {})})
	return out


## True when face `f` rises above the plane through `mid` with normal `n`
## (its centroid is on the outside): the edge between them is a valley.
static func _valley(verts: PackedVector3Array, f: PackedInt32Array, mid: Vector3, n: Vector3) -> bool:
	var c := Vector3.ZERO
	for id in f:
		c += verts[id]
	c /= f.size()
	return (c - mid).dot(n) > 1e-9


static func azimuth(frame: Dictionary, d: Vector3) -> float:
	var n: Vector3 = frame["normal"]
	var p := d - n * d.dot(n)
	if p.length() < 1e-9:
		return 0.0
	return atan2(p.dot(frame["t2"]), p.dot(frame["t1"]))


## The edges round each vertex, counter-clockwise: [[edge index, ...], ...].
static func fans(geo: Dictionary, edges: Array) -> Array:
	var n: int = (geo["verts"] as PackedVector3Array).size()
	var fans_out: Array = []
	for _i in n:
		fans_out.append([])
	for ei in edges.size():
		var e: Dictionary = edges[ei]
		(fans_out[int(e["a"])] as Array).append([float(e["az_a"]), ei])
		(fans_out[int(e["b"])] as Array).append([float(e["az_b"]), ei])
	for i in n:
		var arr: Array = fans_out[i]
		arr.sort_custom(func(x, y): return float(x[0]) < float(y[0]))
		var ids: Array = []
		for pair in arr:
			ids.append(int(pair[1]))
		fans_out[i] = ids
	return fans_out


## Hubs: one record per vertex, grouped into types by their arm pattern
## (valence, the gaps between arms and each arm's dip, rotated to a
## canonical start). Base hubs are typed apart — they usually get feet.
static func hubs(geo: Dictionary, edges: Array, fans_in: Array, angle_tol_deg: float) -> Dictionary:
	var base: Array = geo.get("base_ids", [])
	var base_set := {}
	for id in base:
		base_set[int(id)] = true
	var hub_list: Array = []
	var types := {}
	for v in fans_in.size():
		var fan: Array = fans_in[v]
		var arms: Array = []
		for ei in fan:
			var e: Dictionary = edges[int(ei)]
			var at_a := int(e["a"]) == v
			arms.append({"edge": int(ei), "az": float(e["az_a"] if at_a else e["az_b"]),
				"dip": float(e["dip_a"] if at_a else e["dip_b"]), "len": float(e["len"]),
				"other": int(e["b"] if at_a else e["a"])})
		var m := arms.size()
		var gaps: Array = []
		for k in m:
			var g := float(arms[(k + 1) % m]["az"]) - float(arms[k]["az"])
			if k == m - 1:
				g += TAU
			gaps.append(rad_to_deg(g))
		var pattern := _canonical_pattern(gaps, arms, angle_tol_deg)
		var key := "%d|%s|%s" % [m, "B" if base_set.has(v) else "I", pattern]
		if not types.has(key):
			types[key] = {"key": key, "valence": m, "base": base_set.has(v), "count": 0, "ids": [],
				"pattern": pattern, "gaps": gaps, "dips": arms.map(func(a): return float(a["dip"]))}
		(types[key] as Dictionary)["count"] = int((types[key] as Dictionary)["count"]) + 1
		((types[key] as Dictionary)["ids"] as Array).append(v)
		hub_list.append({"id": v, "valence": m, "arms": arms, "type_key": key, "base": base_set.has(v)})
	# Label the types: H1, H2 … by valence then count.
	var tlist: Array = types.values()
	tlist.sort_custom(func(x, y):
		if int(x["valence"]) != int(y["valence"]):
			return int(x["valence"]) < int(y["valence"])
		if bool(x["base"]) != bool(y["base"]):
			return not bool(x["base"])
		return int(x["count"]) > int(y["count"]))
	for i in tlist.size():
		var t: Dictionary = tlist[i]
		t["label"] = "H%d" % (i + 1)
		var mean_dip := 0.0
		for dp in t["dips"]:
			mean_dip += float(dp)
		t["mean_dip_deg"] = rad_to_deg(mean_dip / maxf((t["dips"] as Array).size(), 1))
	for h in hub_list:
		h["type"] = str((types[h["type_key"]] as Dictionary)["label"])
	return {"hubs": hub_list, "types": tlist}


static func _canonical_pattern(gaps: Array, arms: Array, tol: float) -> String:
	var m := gaps.size()
	var best := ""
	for start in m:
		var parts: PackedStringArray = []
		for k in m:
			var idx := (start + k) % m
			parts.append("%d/%d" % [int(round(float(gaps[idx]) / tol)),
				int(round(rad_to_deg(float(arms[idx]["dip"])) / tol))])
		var s := ",".join(parts)
		if best.is_empty() or s < best:
			best = s
	return best


## Strut classes: edges cut the same, as the builder sorts them — by length
## (group_tol) and the two end bend angles (angle_tol), the shorter class
## first (A). Each class: {label, len, cut, hole_len, bend_a, bend_b, count,
## ids, arc_len, bend_radius, …} per the system.
static func strut_classes(edges: Array, spec: Dictionary) -> Dictionary:
	var sys := str(spec["system"])
	var fab: Dictionary = spec["fabrication"]
	var ends: Dictionary = spec["ends"]
	var hub: Dictionary = spec["hub"]
	var mat := DomeLabMaterials.strut(str(spec["strut"]["material"]))
	var tol := float(fab["group_tol_mm"]) / 1000.0
	var atol := float(fab["angle_tol_deg"])
	var hole_off := float(ends["hole_offset_mm"]) / 1000.0
	var reach := float(hub["reach_mm"]) / 1000.0
	var hub_kind := str(hub["kind"])
	var classes := {}
	var per_edge: Array = []
	for ei in edges.size():
		var e: Dictionary = edges[ei]
		var L := float(e["len"])
		var d1 := rad_to_deg(float(e["dip_a"]))
		var d2 := rad_to_deg(float(e["dip_b"]))
		var rec := {"edge": ei, "len": L, "dip_a": d1, "dip_b": d2}
		match sys:
			"bolt_stack":
				rec["hole_len"] = L
				rec["cut"] = L + 2.0 * hole_off
				rec["bend_a"] = d1
				rec["bend_b"] = d2
			"hub":
				if hub_kind == "plate" or hub_kind == "bolt":
					rec["hole_len"] = L - 2.0 * reach if hub_kind == "plate" else L
					rec["cut"] = float(rec["hole_len"]) + 2.0 * hole_off
					rec["bend_a"] = d1
					rec["bend_b"] = d2
				else:
					rec["hole_len"] = 0.0
					rec["cut"] = maxf(L - 2.0 * reach, 0.01)
					rec["bend_a"] = 0.0
					rec["bend_b"] = 0.0
			"flat_bar":
				var dm := deg_to_rad((d1 + d2) * 0.5)
				var arc := L
				var bend_r := INF
				if dm > 1e-6:
					arc = L * dm / sin(dm)
					bend_r = L / (2.0 * sin(dm))
				rec["arc_len"] = arc
				rec["bend_radius"] = bend_r
				rec["hole_len"] = arc
				rec["cut"] = arc + 2.0 * hole_off
				rec["bend_a"] = 0.0
				rec["bend_b"] = 0.0
				var t_mm := float(mat.get("t_mm", 6.0))
				rec["strain"] = (t_mm / 1000.0) / (2.0 * bend_r) if bend_r < INF else 0.0
			_:
				rec["hole_len"] = L
				rec["cut"] = L
				rec["bend_a"] = 0.0
				rec["bend_b"] = 0.0
		# Class key: ends sorted so a strut and its mirror are one class.
		var ba := float(rec["bend_a"])
		var bb := float(rec["bend_b"])
		var lo := minf(ba, bb)
		var hi := maxf(ba, bb)
		var key := "%d|%d|%d" % [int(round(float(rec["cut"]) / tol)), int(round(lo / atol)), int(round(hi / atol))]
		rec["key"] = key
		if not classes.has(key):
			classes[key] = {"key": key, "len": L, "cut": float(rec["cut"]), "hole_len": float(rec["hole_len"]),
				"bend_a": lo, "bend_b": hi, "count": 0, "ids": [], "arc_len": float(rec.get("arc_len", L)),
				"bend_radius": float(rec.get("bend_radius", INF)), "strain": float(rec.get("strain", 0.0)),
				"dip_a": minf(d1, d2), "dip_b": maxf(d1, d2)}
		var c: Dictionary = classes[key]
		c["count"] = int(c["count"]) + 1
		(c["ids"] as Array).append(ei)
		per_edge.append(rec)
	var clist: Array = classes.values()
	clist.sort_custom(func(x, y):
		if absf(float(x["cut"]) - float(y["cut"])) > 1e-9:
			return float(x["cut"]) < float(y["cut"])
		return float(x["bend_a"]) < float(y["bend_a"]))
	for i in clist.size():
		var c: Dictionary = clist[i]
		c["label"] = LETTERS[i % 26] if i < 26 else "%s%d" % [LETTERS[i % 26], i / 26 + 1]
	var by_key := {}
	for c in clist:
		by_key[c["key"]] = c["label"]
	for rec in per_edge:
		rec["label"] = str(by_key[rec["key"]])
	return {"classes": clist, "per_edge": per_edge}


## A conduit dome's bolt: the stack of flattened ends plus nut and washers.
static func bolt_length_mm(valence: int, strut_mat: Dictionary, bolt: Dictionary, flattened: bool) -> int:
	var stack := valence * DomeLabMaterials.strut_stack_mm(strut_mat, flattened)
	var need := stack + float(bolt["nut_mm"]) + 2.0 * float(bolt["washer_mm"]) + 2.0 * float(bolt["d_mm"]) * 0.5
	return DomeLabMaterials.bolt_length_mm(bolt, need)
